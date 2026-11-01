//! actuon internet ranking server. Clients never report scores: they upload a replay and the chart
//! it needs, and the score is what re-simulating that replay with the shared Zig core produces.
mod core;

use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tiny_http::{Header, Method, Request, Response, Server};

const MAX_CHART: usize = 16 << 20;
const MAX_REPLAY: usize = 16 << 20;
const MAX_JSON: usize = 1 << 20;
const VERIFY_TIMEOUT: Duration = Duration::from_secs(30);
const LOGIN_WINDOW: Duration = Duration::from_secs(60);
const LOGIN_ATTEMPTS: u32 = 10;

const SCHEMA: &str = "
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS user(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, pass TEXT NOT NULL, token TEXT UNIQUE NOT NULL);
CREATE TABLE IF NOT EXISTS chart(sha256 TEXT PRIMARY KEY, format INTEGER NOT NULL, owner INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS score(
  user INTEGER NOT NULL, sha256 TEXT NOT NULL, clear INTEGER, ex INTEGER, max_combo INTEGER, miss INTEGER,
  notes INTEGER, gauge_type INTEGER, date INTEGER, PRIMARY KEY(user, sha256));
CREATE INDEX IF NOT EXISTS score_rank ON score(sha256, ex DESC);
CREATE TABLE IF NOT EXISTS rival(user INTEGER NOT NULL, rival INTEGER NOT NULL, PRIMARY KEY(user, rival));
";

struct Ctx {
    data: PathBuf,
    /// shortcut: per-process login throttle, move to a shared store if the server ever runs multiple instances
    attempts: Mutex<HashMap<String, (Instant, u32)>>,
}

#[derive(Debug)]
struct ApiError(u16, String);

impl ApiError {
    fn new(code: u16, msg: &str) -> Self {
        ApiError(code, msg.to_string())
    }
}

impl From<rusqlite::Error> for ApiError {
    fn from(e: rusqlite::Error) -> Self {
        eprintln!("db error: {e}");
        ApiError::new(500, "internal error")
    }
}

impl From<std::io::Error> for ApiError {
    fn from(e: std::io::Error) -> Self {
        eprintln!("io error: {e}");
        ApiError::new(500, "internal error")
    }
}

type ApiResult = Result<Value, ApiError>;

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn valid_sha(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn token_hash(token: &str) -> String {
    hex(&Sha256::digest(token.as_bytes()))
}

fn new_token() -> Result<String, ApiError> {
    let mut raw = [0u8; 32];
    getrandom::getrandom(&mut raw).map_err(|_| ApiError::new(500, "internal error"))?;
    Ok(hex(&raw))
}

fn read_body(req: &mut Request, limit: usize) -> Result<Vec<u8>, ApiError> {
    if req.body_length().is_some_and(|n| n > limit) {
        return Err(ApiError::new(413, "body too large"));
    }
    let mut body = Vec::new();
    req.as_reader().take(limit as u64 + 1).read_to_end(&mut body)?;
    if body.len() > limit {
        return Err(ApiError::new(413, "body too large"));
    }
    Ok(body)
}

fn auth(req: &Request, db: &Connection) -> Result<i64, ApiError> {
    let header = req.headers().iter().find(|h| h.field.equiv("Authorization")).map(|h| h.value.as_str().to_string());
    let token = header.as_deref().and_then(|v| v.strip_prefix("Bearer ")).ok_or(ApiError::new(401, "missing token"))?;
    db.query_row("SELECT id FROM user WHERE token=?1", [token_hash(token)], |r| r.get(0))
        .optional()?
        .ok_or(ApiError::new(401, "bad token"))
}

fn query_of(url: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    if let Some((_, q)) = url.split_once('?') {
        for kv in q.split('&') {
            if let Some((k, v)) = kv.split_once('=') {
                out.insert(k.to_string(), v.to_string());
            }
        }
    }
    out
}

#[derive(Deserialize)]
struct Credentials {
    name: String,
    password: String,
}

fn valid_name(n: &str) -> bool {
    (1..=32).contains(&n.chars().count()) && !n.chars().any(char::is_control)
}

fn register(req: &mut Request, db: &Connection) -> ApiResult {
    let c: Credentials = serde_json::from_slice(&read_body(req, MAX_JSON)?).map_err(|_| ApiError::new(400, "bad json"))?;
    if !valid_name(&c.name) || c.password.len() < 8 || c.password.len() > 1024 {
        return Err(ApiError::new(400, "name must be 1-32 characters and password at least 8"));
    }
    let mut salt_bytes = [0u8; 16];
    getrandom::getrandom(&mut salt_bytes).map_err(|_| ApiError::new(500, "internal error"))?;
    let salt = SaltString::encode_b64(&salt_bytes).map_err(|_| ApiError::new(500, "internal error"))?;
    let pass = Argon2::default().hash_password(c.password.as_bytes(), &salt).map_err(|_| ApiError::new(500, "internal error"))?.to_string();
    let token = new_token()?;
    match db.execute("INSERT INTO user(name,pass,token) VALUES(?1,?2,?3)", params![c.name, pass, token_hash(&token)]) {
        Ok(_) => Ok(json!({"token": token})),
        Err(rusqlite::Error::SqliteFailure(e, _)) if e.code == rusqlite::ErrorCode::ConstraintViolation => Err(ApiError::new(409, "name taken")),
        Err(e) => Err(e.into()),
    }
}

fn throttle(ctx: &Ctx, name: &str) -> Result<(), ApiError> {
    let mut map = ctx.attempts.lock().unwrap_or_else(|p| p.into_inner());
    let entry = map.entry(name.to_string()).or_insert((Instant::now(), 0));
    if entry.0.elapsed() > LOGIN_WINDOW {
        *entry = (Instant::now(), 0);
    }
    entry.1 += 1;
    if entry.1 > LOGIN_ATTEMPTS {
        return Err(ApiError::new(429, "too many attempts"));
    }
    Ok(())
}

/// Login rotates the token, so a leaked one dies at the next login.
fn login(req: &mut Request, db: &Connection, ctx: &Ctx) -> ApiResult {
    let c: Credentials = serde_json::from_slice(&read_body(req, MAX_JSON)?).map_err(|_| ApiError::new(400, "bad json"))?;
    throttle(ctx, &c.name)?;
    let row: Option<(i64, String)> = db.query_row("SELECT id, pass FROM user WHERE name=?1", [&c.name], |r| Ok((r.get(0)?, r.get(1)?))).optional()?;
    let denied = || ApiError::new(401, "wrong name or password");
    let (id, pass) = row.ok_or_else(denied)?;
    let parsed = PasswordHash::new(&pass).map_err(|_| ApiError::new(500, "internal error"))?;
    Argon2::default().verify_password(c.password.as_bytes(), &parsed).map_err(|_| denied())?;
    let token = new_token()?;
    db.execute("UPDATE user SET token=?1 WHERE id=?2", params![token_hash(&token), id])?;
    Ok(json!({"token": token}))
}

fn chart_path(ctx: &Ctx, sha: &str) -> PathBuf {
    // sha is validated hex, so this cannot leave the directory.
    ctx.data.join("charts").join(sha)
}

fn upload_chart(req: &mut Request, db: &Connection, ctx: &Ctx, sha: &str) -> ApiResult {
    let user = auth(req, db)?;
    let q = query_of(req.url());
    let format: u8 = q.get("format").and_then(|f| f.parse().ok()).filter(|f| (1..=3).contains(f)).ok_or(ApiError::new(400, "format must be 1, 2 or 3"))?;
    let body = read_body(req, MAX_CHART)?;
    if core::chart_sha256(&body) != sha {
        return Err(ApiError::new(400, "chart does not match its hash"));
    }
    let path = chart_path(ctx, sha);
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&tmp, &body)?;
    std::fs::rename(&tmp, &path)?;
    db.execute("INSERT OR IGNORE INTO chart(sha256,format,owner) VALUES(?1,?2,?3)", params![sha, format, user])?;
    Ok(json!({"stored": true}))
}

/// Runs the core in a child process: a chart that crashes or hangs the parser must not take the server down.
fn verify_isolated(ctx: &Ctx, sha: &str, format: u8, replay: &[u8]) -> Result<core::Verified, ApiError> {
    let exe = std::env::current_exe()?;
    let mut child = Command::new(exe)
        .arg("--verify")
        .arg(chart_path(ctx, sha))
        .arg(format.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut stdin = child.stdin.take().ok_or(ApiError::new(500, "internal error"))?;
    let bytes = replay.to_vec();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(&bytes);
    });
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            let _ = writer.join();
            if !status.success() {
                return Err(ApiError::new(422, "replay could not be verified"));
            }
            let mut out = String::new();
            child.stdout.take().ok_or(ApiError::new(500, "internal error"))?.read_to_string(&mut out)?;
            return serde_json::from_str(&out).map_err(|_| ApiError::new(422, "replay could not be verified"));
        }
        if started.elapsed() > VERIFY_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            return Err(ApiError::new(422, "verification timed out"));
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn submit(req: &mut Request, db: &Connection, ctx: &Ctx, sha: &str) -> ApiResult {
    let user = auth(req, db)?;
    let format: Option<u8> = db.query_row("SELECT format FROM chart WHERE sha256=?1", [sha], |r| r.get(0)).optional()?;
    let Some(format) = format else {
        // 428: the client uploads the chart, then retries.
        return Err(ApiError::new(428, "chart required"));
    };
    let replay = read_body(req, MAX_REPLAY)?;
    let v = verify_isolated(ctx, sha, format, &replay)?;
    if !v.ok {
        return Err(ApiError::new(422, "replay could not be verified"));
    }
    db.execute(
        "INSERT INTO score(user,sha256,clear,ex,max_combo,miss,notes,gauge_type,date) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
         ON CONFLICT(user,sha256) DO UPDATE SET clear=MAX(clear,excluded.clear), ex=MAX(ex,excluded.ex),
           max_combo=MAX(max_combo,excluded.max_combo), miss=MIN(miss,excluded.miss), date=excluded.date",
        params![user, sha, v.clear, v.ex_score, v.max_combo, v.miss, v.total_notes, v.gauge_type, now()],
    )?;
    Ok(json!({"clear": v.clear, "ex": v.ex_score, "max_combo": v.max_combo, "miss": v.miss, "notes": v.total_notes}))
}

fn ranking(db: &Connection, sha: &str, url: &str) -> ApiResult {
    let limit: i64 = query_of(url).get("limit").and_then(|l| l.parse().ok()).unwrap_or(100).clamp(1, 1000);
    let mut st = db.prepare_cached(
        "SELECT u.name,s.ex,s.clear,s.miss,s.max_combo,s.date FROM score s JOIN user u ON u.id=s.user WHERE s.sha256=?1 ORDER BY s.ex DESC, s.date LIMIT ?2",
    )?;
    let rows = st.query_map(params![sha, limit], |r| {
        Ok(json!({"name": r.get::<_, String>(0)?, "ex": r.get::<_, i64>(1)?, "clear": r.get::<_, i64>(2)?, "miss": r.get::<_, i64>(3)?, "max_combo": r.get::<_, i64>(4)?, "date": r.get::<_, i64>(5)?}))
    })?;
    Ok(json!({"scores": rows.collect::<Result<Vec<_>, _>>()?}))
}

fn add_rival(req: &Request, db: &Connection, name: &str) -> ApiResult {
    let user = auth(req, db)?;
    let rival: i64 = db.query_row("SELECT id FROM user WHERE name=?1", [name], |r| r.get(0)).optional()?.ok_or(ApiError::new(404, "no such player"))?;
    db.execute("INSERT OR IGNORE INTO rival(user,rival) VALUES(?1,?2)", params![user, rival])?;
    Ok(json!({"added": name}))
}

fn remove_rival(req: &Request, db: &Connection, name: &str) -> ApiResult {
    let user = auth(req, db)?;
    db.execute("DELETE FROM rival WHERE user=?1 AND rival=(SELECT id FROM user WHERE name=?2)", params![user, name])?;
    Ok(json!({"removed": name}))
}

fn rivals(req: &Request, db: &Connection) -> ApiResult {
    let user = auth(req, db)?;
    let mut st = db.prepare_cached("SELECT u.name FROM rival r JOIN user u ON u.id=r.rival WHERE r.user=?1 ORDER BY u.name")?;
    let rows = st.query_map([user], |r| r.get::<_, String>(0))?;
    Ok(json!({"rivals": rows.collect::<Result<Vec<_>, _>>()?}))
}

/// The caller and their rivals on one chart.
fn rival_scores(req: &Request, db: &Connection, sha: &str) -> ApiResult {
    let user = auth(req, db)?;
    let mut st = db.prepare_cached(
        "SELECT u.name,s.ex,s.clear,s.miss FROM score s JOIN user u ON u.id=s.user
         WHERE s.sha256=?1 AND (s.user=?2 OR s.user IN (SELECT rival FROM rival WHERE user=?2)) ORDER BY s.ex DESC",
    )?;
    let rows = st.query_map(params![sha, user], |r| Ok(json!({"name": r.get::<_, String>(0)?, "ex": r.get::<_, i64>(1)?, "clear": r.get::<_, i64>(2)?, "miss": r.get::<_, i64>(3)?})))?;
    Ok(json!({"scores": rows.collect::<Result<Vec<_>, _>>()?}))
}

#[derive(Deserialize)]
struct TableQuery {
    sha256: Vec<String>,
}

/// Standings across a difficulty table's charts: the client sends the chart list it resolved.
fn table_ranking(req: &mut Request, db: &Connection) -> ApiResult {
    let q: TableQuery = serde_json::from_slice(&read_body(req, MAX_JSON)?).map_err(|_| ApiError::new(400, "bad json"))?;
    if q.sha256.len() > 8192 || !q.sha256.iter().all(|s| valid_sha(s)) {
        return Err(ApiError::new(400, "bad chart list"));
    }
    let mut totals: HashMap<String, (i64, i64, i64)> = HashMap::new();
    let mut st = db.prepare_cached("SELECT u.name,s.ex,s.clear FROM score s JOIN user u ON u.id=s.user WHERE s.sha256=?1")?;
    for sha in &q.sha256 {
        let rows = st.query_map([sha], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?)))?;
        for row in rows {
            let (name, ex, clear) = row?;
            let t = totals.entry(name).or_insert((0, 0, 0));
            t.0 += ex;
            // 4 is EASY in beatoraja's clear numbering, the first real clear.
            t.1 += i64::from(clear >= 4);
            t.2 += 1;
        }
    }
    let mut out: Vec<_> = totals.into_iter().collect();
    out.sort_by(|a, b| b.1 .1.cmp(&a.1 .1).then(b.1 .0.cmp(&a.1 .0)));
    Ok(json!({"players": out.into_iter().map(|(n, t)| json!({"name": n, "ex": t.0, "clears": t.1, "played": t.2})).collect::<Vec<_>>()}))
}

fn route(req: &mut Request, db: &Connection, ctx: &Ctx) -> ApiResult {
    let url = req.url().to_string();
    let path = url.split('?').next().unwrap_or("").to_string();
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    let method = req.method().clone();
    let sha_ok = |s: &str| if valid_sha(s) { Ok(()) } else { Err(ApiError::new(400, "bad hash")) };
    match (&method, parts.as_slice()) {
        (Method::Get, ["health"]) => Ok(json!({"ok": true})),
        (Method::Post, ["register"]) => register(req, db),
        (Method::Post, ["login"]) => login(req, db, ctx),
        (Method::Put, ["charts", sha]) => {
            sha_ok(sha)?;
            upload_chart(req, db, ctx, sha)
        }
        (Method::Post, ["scores", sha]) => {
            sha_ok(sha)?;
            submit(req, db, ctx, sha)
        }
        (Method::Get, ["scores", sha]) => {
            sha_ok(sha)?;
            ranking(db, sha, &url)
        }
        (Method::Get, ["scores", sha, "rivals"]) => {
            sha_ok(sha)?;
            rival_scores(req, db, sha)
        }
        (Method::Get, ["rivals"]) => rivals(req, db),
        (Method::Put, ["rivals", name]) => add_rival(req, db, name),
        (Method::Delete, ["rivals", name]) => remove_rival(req, db, name),
        (Method::Post, ["table-ranking"]) => table_ranking(req, db),
        _ => Err(ApiError::new(404, "not found")),
    }
}

fn worker(server: Arc<Server>, ctx: Arc<Ctx>, db_path: PathBuf) {
    let db = match Connection::open(&db_path) {
        Ok(db) => db,
        Err(e) => {
            eprintln!("cannot open database: {e}");
            return;
        }
    };
    let _ = db.busy_timeout(Duration::from_secs(5));
    loop {
        let Ok(mut req) = server.recv() else { return };
        let (code, body) = match route(&mut req, &db, &ctx) {
            Ok(v) => (200, v),
            Err(ApiError(code, msg)) => (code, json!({"error": msg})),
        };
        let header = Header::from_bytes("Content-Type", "application/json").expect("static header");
        let _ = req.respond(Response::from_string(body.to_string()).with_status_code(code).with_header(header));
    }
}

/// Child mode of verify_isolated: chart path and format in argv, replay on stdin, result JSON on stdout.
fn verify_main(args: &[String]) -> i32 {
    let (Some(path), Some(format)) = (args.get(2), args.get(3).and_then(|f| f.parse::<u8>().ok())) else { return 2 };
    let Ok(chart) = std::fs::read(Path::new(path)) else { return 2 };
    let mut replay = Vec::new();
    if std::io::stdin().take(MAX_REPLAY as u64).read_to_end(&mut replay).is_err() {
        return 2;
    }
    match core::verify(&chart, &replay, format) {
        Ok(v) => {
            println!("{}", serde_json::to_string(&v).unwrap_or_default());
            0
        }
        Err(_) => 1,
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--verify") {
        std::process::exit(verify_main(&args));
    }
    let addr = args.get(1).cloned().unwrap_or_else(|| "127.0.0.1:8730".to_string());
    let data = PathBuf::from(args.get(2).cloned().unwrap_or_else(|| "ir-data".to_string()));
    std::fs::create_dir_all(data.join("charts")).expect("create data directory");
    let db_path = data.join("ir.db");
    Connection::open(&db_path).and_then(|db| db.execute_batch(SCHEMA)).expect("initialize database");
    let server = Arc::new(Server::http(&addr).expect("bind address"));
    let ctx = Arc::new(Ctx { data, attempts: Mutex::new(HashMap::new()) });
    eprintln!("actuon IR on http://{addr}");
    let threads: Vec<_> = (0..8)
        .map(|_| {
            let (s, c, d) = (server.clone(), ctx.clone(), db_path.clone());
            std::thread::spawn(move || worker(s, c, d))
        })
        .collect();
    for t in threads {
        let _ = t.join();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_validation_rejects_paths() {
        assert!(valid_sha(&"a".repeat(64)));
        assert!(!valid_sha("../../etc/passwd"));
        assert!(!valid_sha(&"A".repeat(64)));
    }

    #[test]
    fn core_rejects_garbage_replay() {
        assert_eq!(core::verify(b"#TITLE x\n", b"not a replay", 1).unwrap_err(), -1);
    }

    #[test]
    fn query_parse() {
        assert_eq!(query_of("/x?limit=5&a=b").get("limit").unwrap(), "5");
    }
}
