//! actuon internet ranking server. Clients never report scores: they upload a replay and the chart
//! it needs, and the score is what re-simulating that replay with the shared Zig core produces.
mod core;
mod play;
mod rooms;

use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use rusqlite::{params, Connection, ErrorCode, OptionalExtension};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tiny_http::{Header, Method, Request, Response, Server};

const MAX_CHART: usize = 16 << 20;
const MAX_REPLAY: usize = 16 << 20;
const MAX_JSON: usize = 1 << 20;
const VERIFY_TIMEOUT: Duration = Duration::from_secs(30);
const LOGIN_WINDOW_SECS: u64 = 60;
const LOGIN_ATTEMPTS: u32 = 10;
const REGISTER_WINDOW_SECS: u64 = 3600;
const REGISTER_ATTEMPTS: u32 = 10;
/// A chart another player already stored costs nothing, so this only counts charts new to the server.
const MAX_OWNER_CHART_BYTES: i64 = 64 << 20;
/// However many accounts someone makes, the disk stays usable.
const MAX_TOTAL_CHART_BYTES: i64 = 10 << 30;
const MAX_OWNER_CLAIMS: i64 = 50_000;
/// Checks plus hashes stay below the 8 workers, so reads still get through.
const MAX_CHECKS: usize = 2;
const MAX_HASHES: usize = 4;
/// A real chart takes far less: about 500 bytes a note.
const CHILD_MEMORY_BYTES: libc::rlim_t = 1 << 30;
const RANK_ORDER: &str = "ORDER BY s.verified DESC, s.ex DESC, s.date, s.user";

const SCHEMA: &str = "
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS user(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, pass TEXT NOT NULL, token TEXT UNIQUE NOT NULL);
CREATE TABLE IF NOT EXISTS chart(sha256 TEXT PRIMARY KEY, owner INTEGER NOT NULL, size INTEGER NOT NULL DEFAULT 0, title TEXT NOT NULL DEFAULT '', artist TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS score(
  user INTEGER NOT NULL, sha256 TEXT NOT NULL, clear INTEGER NOT NULL, ex INTEGER NOT NULL, max_combo INTEGER NOT NULL, miss INTEGER NOT NULL,
  notes INTEGER NOT NULL, gauge_type INTEGER NOT NULL, date INTEGER NOT NULL, PRIMARY KEY(user, sha256));
CREATE INDEX IF NOT EXISTS score_rank ON score(sha256, ex DESC);
CREATE INDEX IF NOT EXISTS score_date ON score(date DESC);
CREATE TABLE IF NOT EXISTS rival(user INTEGER NOT NULL, rival INTEGER NOT NULL, PRIMARY KEY(user, rival));
CREATE TABLE IF NOT EXISTS claim(
  user INTEGER NOT NULL, sha256 TEXT NOT NULL, clear INTEGER NOT NULL, ex INTEGER NOT NULL, max_combo INTEGER NOT NULL, miss INTEGER NOT NULL,
  date INTEGER NOT NULL, PRIMARY KEY(user, sha256));
CREATE INDEX IF NOT EXISTS claim_rank ON claim(sha256, ex DESC);
DROP VIEW IF EXISTS best;
CREATE VIEW best AS
  SELECT user,sha256,clear,ex,max_combo,miss,date,1 AS verified FROM score s
  UNION ALL
  SELECT user,sha256,clear,ex,max_combo,miss,date,0 AS verified FROM claim c
    WHERE NOT EXISTS (SELECT 1 FROM score s WHERE s.user=c.user AND s.sha256=c.sha256);
";

struct Ctx {
    data: PathBuf,
    /// shortcut: per-process and lost on restart, move to a shared store if the server ever runs multiple instances
    attempts: Mutex<HashMap<String, (Instant, u32)>>,
    /// The players with a check running, so one player cannot hold every slot.
    checks: Mutex<HashSet<i64>>,
    hashes: AtomicUsize,
    rooms: Mutex<rooms::Rooms>,
    /// Open multiplayer connections per player: each holds a thread.
    online: Mutex<HashMap<i64, usize>>,
}

/// Holds the slot of naming old charts: no account has this id.
const SERVER_USER: i64 = 0;
/// shortcut: a thread per multiplayer connection, move to async I/O if this many players are ever online.
const MAX_PLAYERS_ONLINE: usize = 1024;
/// A dropped connection stays open here until the proxy gives up on it, so a reconnect overlaps it.
const MAX_CONNECTIONS_PER_PLAYER: usize = 4;

/// A place among the running chart and replay checks, given back when dropped.
struct CheckSlot<'a> {
    checks: &'a Mutex<HashSet<i64>>,
    user: i64,
}

impl<'a> CheckSlot<'a> {
    /// 503 for both limits: clients already try that again, and a sync sends replays in parallel.
    fn take(ctx: &'a Ctx, user: i64) -> Result<Self, ApiError> {
        let mut running = ctx.checks.lock().unwrap_or_else(|e| e.into_inner());
        if running.len() >= MAX_CHECKS || !running.insert(user) {
            return Err(ApiError::new(503, "server is busy"));
        }
        Ok(CheckSlot {
            checks: &ctx.checks,
            user,
        })
    }
}

impl Drop for CheckSlot<'_> {
    fn drop(&mut self) {
        let mut running = self.checks.lock().unwrap_or_else(|e| e.into_inner());
        running.remove(&self.user);
    }
}

/// A place among the running password hashes: each takes 19 MiB and a core.
struct HashSlot<'a>(&'a AtomicUsize);

impl<'a> HashSlot<'a> {
    fn take(ctx: &'a Ctx) -> Result<Self, ApiError> {
        if ctx.hashes.fetch_add(1, Ordering::AcqRel) >= MAX_HASHES {
            ctx.hashes.fetch_sub(1, Ordering::AcqRel);
            return Err(ApiError::new(503, "server is busy"));
        }
        Ok(HashSlot(&ctx.hashes))
    }
}

impl Drop for HashSlot<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
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
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn valid_sha(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
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
    req.as_reader()
        .take(limit as u64 + 1)
        .read_to_end(&mut body)?;
    if body.len() > limit {
        return Err(ApiError::new(413, "body too large"));
    }
    Ok(body)
}

fn auth(req: &Request, db: &Connection) -> Result<i64, ApiError> {
    let header = req
        .headers()
        .iter()
        .find(|h| h.field.equiv("Authorization"))
        .map(|h| h.value.as_str().to_string());
    let token = header
        .as_deref()
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or(ApiError::new(401, "missing token"))?;
    db.prepare_cached("SELECT id FROM user WHERE token=?1")?
        .query_row([token_hash(token)], |r| r.get(0))
        .optional()?
        .ok_or(ApiError::new(401, "bad token"))
}

/// Who a request is from when throttling. nginx sets X-Real-IP (docs/ir.md), and only it can reach this port.
/// An IPv6 client owns a whole /64, so that is what counts as one client.
fn client_key(real_ip: Option<&str>, peer: Option<IpAddr>) -> String {
    match real_ip.and_then(|ip| ip.trim().parse().ok()).or(peer) {
        Some(IpAddr::V6(ip)) => format!("{:x?}", &ip.segments()[..4]),
        Some(ip) => ip.to_string(),
        None => "unknown".to_string(),
    }
}

fn client_of(req: &Request) -> String {
    let real_ip = req
        .headers()
        .iter()
        .find(|h| h.field.equiv("X-Real-IP"))
        .map(|h| h.value.as_str());
    client_key(real_ip, req.remote_addr().map(|a| a.ip()))
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

/// A path segment as the client meant it, so names outside ASCII can travel in a URL.
fn percent_decode(s: &str) -> Result<String, ApiError> {
    let bad = || ApiError::new(400, "bad name");
    let b = s.as_bytes();
    let (mut out, mut i) = (Vec::with_capacity(b.len()), 0);
    while i < b.len() {
        if b[i] == b'%' {
            let hex = s.get(i + 1..i + 3).ok_or_else(bad)?;
            out.push(u8::from_str_radix(hex, 16).map_err(|_| bad())?);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).map_err(|_| bad())
}

#[derive(Deserialize)]
struct Credentials {
    name: String,
    password: String,
}

fn valid_name(n: &str) -> bool {
    (1..=32).contains(&n.chars().count()) && !n.chars().any(char::is_control)
}

fn register(req: &mut Request, db: &Connection, ctx: &Ctx) -> ApiResult {
    let c: Credentials = serde_json::from_slice(&read_body(req, MAX_JSON)?)
        .map_err(|_| ApiError::new(400, "bad json"))?;
    if !valid_name(&c.name) || c.password.len() < 8 || c.password.len() > 1024 {
        return Err(ApiError::new(
            400,
            "name must be 1-32 characters and password at least 8",
        ));
    }
    throttle(
        ctx,
        &format!("register:{}", client_of(req)),
        REGISTER_WINDOW_SECS,
        REGISTER_ATTEMPTS,
    )?;
    let _slot = HashSlot::take(ctx)?;
    let mut salt_bytes = [0u8; 16];
    getrandom::getrandom(&mut salt_bytes).map_err(|_| ApiError::new(500, "internal error"))?;
    let salt =
        SaltString::encode_b64(&salt_bytes).map_err(|_| ApiError::new(500, "internal error"))?;
    let pass = Argon2::default()
        .hash_password(c.password.as_bytes(), &salt)
        .map_err(|_| ApiError::new(500, "internal error"))?
        .to_string();
    let token = new_token()?;
    db.execute(
        "INSERT INTO user(name,pass,token) VALUES(?1,?2,?3)",
        params![c.name, pass, token_hash(&token)],
    )
    .map_err(name_conflict)?;
    Ok(json!({"token": token}))
}

fn name_conflict(e: rusqlite::Error) -> ApiError {
    match e {
        rusqlite::Error::SqliteFailure(f, _) if f.code == ErrorCode::ConstraintViolation => {
            ApiError::new(409, "name taken")
        }
        e => e.into(),
    }
}

#[derive(Deserialize)]
struct NewName {
    name: String,
}

/// Everything else points at the id, so scores and rivals follow. The login name changes with it.
fn rename(req: &mut Request, db: &Connection) -> ApiResult {
    let user = auth(req, db)?;
    let q: NewName = serde_json::from_slice(&read_body(req, MAX_JSON)?)
        .map_err(|_| ApiError::new(400, "bad json"))?;
    if !valid_name(&q.name) {
        return Err(ApiError::new(400, "name must be 1-32 characters"));
    }
    db.execute("UPDATE user SET name=?1 WHERE id=?2", params![q.name, user])
        .map_err(name_conflict)?;
    Ok(json!({"name": q.name}))
}

fn throttle(ctx: &Ctx, key: &str, window_secs: u64, limit: u32) -> Result<(), ApiError> {
    let mut attempts = ctx.attempts.lock().unwrap_or_else(|e| e.into_inner());
    let now = Instant::now();
    attempts.retain(|_, (expires, _)| *expires > now);
    let (_, count) = attempts
        .entry(key.to_string())
        .or_insert((now + Duration::from_secs(window_secs), 0));
    *count += 1;
    if *count > limit {
        return Err(ApiError::new(429, "too many attempts"));
    }
    Ok(())
}

/// Login rotates the token, so a leaked one dies at the next login.
fn login(req: &mut Request, db: &Connection, ctx: &Ctx) -> ApiResult {
    let c: Credentials = serde_json::from_slice(&read_body(req, MAX_JSON)?)
        .map_err(|_| ApiError::new(400, "bad json"))?;
    // Hashed because the name is still unchecked and can be 1 MiB long.
    throttle(
        ctx,
        &format!("login:{}:{}", client_of(req), token_hash(&c.name)),
        LOGIN_WINDOW_SECS,
        LOGIN_ATTEMPTS,
    )?;
    let row = db
        .query_row("SELECT id, pass FROM user WHERE name=?1", [&c.name], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })
        .optional()?;
    let denied = || ApiError::new(401, "wrong name or password");
    let (id, pass) = row.ok_or_else(denied)?;
    let parsed = PasswordHash::new(&pass).map_err(|_| ApiError::new(500, "internal error"))?;
    let _slot = HashSlot::take(ctx)?;
    Argon2::default()
        .verify_password(c.password.as_bytes(), &parsed)
        .map_err(|_| denied())?;
    let token = new_token()?;
    db.execute(
        "UPDATE user SET token=?1 WHERE id=?2",
        params![token_hash(&token), id],
    )?;
    Ok(json!({"token": token}))
}

fn chart_path(ctx: &Ctx, sha: &str) -> PathBuf {
    // sha is validated hex, so this cannot leave the directory.
    ctx.data.join("charts").join(sha)
}

fn format_of(url: &str) -> Result<u8, ApiError> {
    query_of(url)
        .get("format")
        .and_then(|f| f.parse().ok())
        .filter(|f| (1..=3).contains(f))
        .ok_or(ApiError::new(400, "format must be 1, 2 or 3"))
}

fn chart_known(db: &Connection, sha: &str) -> Result<bool, ApiError> {
    Ok(db
        .query_row("SELECT 1 FROM chart WHERE sha256=?1", [sha], |_| Ok(()))
        .optional()?
        .is_some())
}

fn chart_room(db: &Connection, user: i64, size: i64) -> Result<(), ApiError> {
    let (mine, total): (i64, i64) = db.query_row(
        "SELECT COALESCE(SUM(size) FILTER (WHERE owner=?1),0), COALESCE(SUM(size),0) FROM chart",
        [user],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    if mine + size > MAX_OWNER_CHART_BYTES || total + size > MAX_TOTAL_CHART_BYTES {
        return Err(ApiError::new(429, "chart storage limit reached"));
    }
    Ok(())
}

fn upload_chart(req: &mut Request, db: &Connection, ctx: &Ctx, sha: &str) -> ApiResult {
    let user = auth(req, db)?;
    let format = format_of(req.url())?;
    let body = read_body(req, MAX_CHART)?;
    if core::chart_sha256(&body) != sha {
        return Err(ApiError::new(400, "chart does not match its hash"));
    }
    let path = chart_path(ctx, sha);
    if path.exists() && chart_known(db, sha)? {
        return Ok(json!({"stored": true}));
    }
    chart_room(db, user, body.len() as i64)?;
    let _slot = CheckSlot::take(ctx, user)?;
    // Random: two players can upload the same new chart at once.
    let tmp = path.with_extension(format!("tmp{}", new_token()?));
    std::fs::write(&tmp, &body)?;
    let info = match check_isolated(&tmp, format).and_then(|info| {
        std::fs::rename(&tmp, &path)?;
        Ok(info)
    }) {
        Ok(info) => info,
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
    };
    db.execute(
        "INSERT INTO chart(sha256,owner,size,title,artist) VALUES(?1,?2,?3,?4,?5) ON CONFLICT DO NOTHING",
        params![sha, user, body.len() as i64, info.title, info.artist],
    )?;
    Ok(json!({"stored": true}))
}

/// Runs this binary as a child: a chart that crashes or hangs the parser must not take the server down.
fn run_child(
    args: &[std::ffi::OsString],
    input: &[u8],
    rejected: &str,
) -> Result<String, ApiError> {
    let exe = std::env::current_exe()?;
    let mut child = Command::new(exe)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or(ApiError::new(500, "internal error"))?;
    let bytes = input.to_vec();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(&bytes);
    });
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            let _ = writer.join();
            if !status.success() {
                return Err(ApiError::new(422, rejected));
            }
            let mut out = String::new();
            child
                .stdout
                .take()
                .ok_or(ApiError::new(500, "internal error"))?
                .read_to_string(&mut out)?;
            return Ok(out);
        }
        if started.elapsed() > VERIFY_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            return Err(ApiError::new(422, "verification timed out"));
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn check_isolated(path: &Path, format: u8) -> Result<core::ChartInfo, ApiError> {
    let rejected = "file is not a playable chart";
    let args = [
        "--check-chart".into(),
        path.as_os_str().to_owned(),
        format.to_string().into(),
    ];
    serde_json::from_str(&run_child(&args, &[], rejected)?)
        .map_err(|_| ApiError::new(422, rejected))
}

/// Charts stored before titles were kept. No format is stored, and PMS names a chart as BMS does.
/// Runs once, because a chart that cannot be named would otherwise be parsed again at every start.
fn name_old_charts(db: &Connection, ctx: &Ctx) -> Result<(), ApiError> {
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version >= 1 {
        return Ok(());
    }
    let shas = db
        .prepare("SELECT sha256 FROM chart WHERE title=''")?
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    for sha in shas {
        let path = chart_path(ctx, &sha);
        // Players go first: this only takes a slot that is free.
        let _slot = loop {
            match CheckSlot::take(ctx, SERVER_USER) {
                Ok(slot) => break slot,
                Err(_) => std::thread::sleep(Duration::from_secs(1)),
            }
        };
        let Ok(info) = check_isolated(&path, 1).or_else(|_| check_isolated(&path, 3)) else {
            eprintln!("chart {sha} could not be named");
            continue;
        };
        db.execute(
            "UPDATE chart SET title=?1, artist=?2 WHERE sha256=?3",
            params![info.title, info.artist, sha],
        )?;
    }
    db.execute_batch("PRAGMA user_version=1")?;
    Ok(())
}

fn verify_isolated(
    ctx: &Ctx,
    sha: &str,
    format: u8,
    replay: &[u8],
) -> Result<core::Verified, ApiError> {
    let rejected = "replay could not be verified";
    let args = [
        "--verify".into(),
        chart_path(ctx, sha).into_os_string(),
        format.to_string().into(),
    ];
    serde_json::from_str(&run_child(&args, replay, rejected)?)
        .map_err(|_| ApiError::new(422, rejected))
}

fn submit(req: &mut Request, db: &Connection, ctx: &Ctx, sha: &str) -> ApiResult {
    let user = auth(req, db)?;
    // Per score, not per chart: a wrong format then costs only the one who sent it.
    let format = format_of(req.url())?;
    if !chart_known(db, sha)? {
        // 428: the client uploads the chart, then retries.
        return Err(ApiError::new(428, "chart required"));
    }
    let replay = read_body(req, MAX_REPLAY)?;
    let v = {
        let _slot = CheckSlot::take(ctx, user)?;
        verify_isolated(ctx, sha, format, &replay)?
    };
    if !v.ok {
        return Err(ApiError::new(422, "replay could not be verified"));
    }
    if let Some(code) = query_of(req.url()).get("room") {
        lock_rooms(ctx).record_final(code, user, sha, v.seed, v.ex_score as u32);
    }
    let (prev_rank, _, _) = standing(db, sha, Some(user))?;
    db.execute(
        "INSERT INTO score(user,sha256,clear,ex,max_combo,miss,notes,gauge_type,date) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
         ON CONFLICT(user,sha256) DO UPDATE SET clear=MAX(score.clear,excluded.clear), ex=MAX(score.ex,excluded.ex),
           max_combo=MAX(score.max_combo,excluded.max_combo), miss=MIN(score.miss,excluded.miss),
           date=CASE WHEN excluded.ex>score.ex THEN excluded.date ELSE score.date END",
        params![user, sha, v.clear, v.ex_score, v.max_combo, v.miss, v.total_notes, v.gauge_type, now()],
    )?;
    Ok(
        json!({"clear": v.clear, "ex": v.ex_score, "max_combo": v.max_combo, "miss": v.miss, "notes": v.total_notes, "prev_rank": prev_rank}),
    )
}

fn lock_rooms(ctx: &Ctx) -> std::sync::MutexGuard<'_, rooms::Rooms> {
    ctx.rooms.lock().unwrap_or_else(|e| e.into_inner())
}

/// The player's place on a chart (0 when they have no score there), the row count, and the clear counts.
fn standing(
    db: &Connection,
    sha: &str,
    me: Option<i64>,
) -> Result<(i64, i64, [i64; 11]), ApiError> {
    let (mut rank, mut total, mut clears) = (0, 0, [0i64; 11]);
    let mut st = db.prepare_cached(&format!(
        "SELECT s.user,s.clear FROM best s WHERE s.sha256=?1 {RANK_ORDER}"
    ))?;
    let mut rows = st.query([sha])?;
    while let Some(r) = rows.next()? {
        total += 1;
        clears[r.get::<_, i64>(1)?.clamp(0, 10) as usize] += 1;
        if Some(r.get::<_, i64>(0)?) == me {
            rank = total;
        }
    }
    Ok((rank, total, clears))
}

/// A token is optional here: with one, the answer also says which row and rank are the caller's.
fn ranking(req: &Request, db: &Connection, sha: &str, url: &str) -> ApiResult {
    let me = auth(req, db).ok();
    let limit: i64 = query_of(url)
        .get("limit")
        .and_then(|l| l.parse().ok())
        .unwrap_or(100)
        .clamp(1, 1000);
    let mut st = db.prepare_cached(&format!("SELECT u.name,s.ex,s.clear,s.miss,s.max_combo,s.date,s.verified,s.user FROM best s JOIN user u ON u.id=s.user WHERE s.sha256=?1 {RANK_ORDER} LIMIT ?2"))?;
    let scores = st
        .query_map(params![sha, limit], |r| {
            Ok(json!({"name": r.get::<_, String>(0)?, "ex": r.get::<_, i64>(1)?, "clear": r.get::<_, i64>(2)?, "miss": r.get::<_, i64>(3)?, "max_combo": r.get::<_, i64>(4)?, "date": r.get::<_, i64>(5)?, "verified": r.get::<_, i64>(6)? != 0, "you": Some(r.get::<_, i64>(7)?) == me}))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let (rank, total, clears) = standing(db, sha, me)?;
    let (title, artist) = db
        .query_row(
            "SELECT title,artist FROM chart WHERE sha256=?1",
            [sha],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()?
        .unwrap_or_default();
    Ok(
        json!({"scores": scores, "rank": rank, "total": total, "clears": clears, "title": title, "artist": artist}),
    )
}

/// The newest verified scores, for the web page. Claims stay out: nothing has checked them.
fn recent(db: &Connection, url: &str) -> ApiResult {
    let limit: i64 = query_of(url)
        .get("limit")
        .and_then(|l| l.parse().ok())
        .unwrap_or(50)
        .clamp(1, 100);
    let mut st = db.prepare_cached("SELECT s.sha256,u.name,s.ex,s.clear,s.miss,s.date,COALESCE(c.title,'') FROM score s JOIN user u ON u.id=s.user LEFT JOIN chart c ON c.sha256=s.sha256 ORDER BY s.date DESC LIMIT ?1")?;
    let scores = st
        .query_map([limit], |r| {
            Ok(json!({"sha256": r.get::<_, String>(0)?, "name": r.get::<_, String>(1)?, "ex": r.get::<_, i64>(2)?, "clear": r.get::<_, i64>(3)?, "miss": r.get::<_, i64>(4)?, "date": r.get::<_, i64>(5)?, "title": r.get::<_, String>(6)?}))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json!({"scores": scores}))
}

/// Every row the caller holds, for IR sync. A chart can have both a verified score and a claim:
/// the client must see the verified one to know which replays are still worth sending.
fn my_scores(req: &Request, db: &Connection) -> ApiResult {
    let user = auth(req, db)?;
    let mut st = db.prepare_cached(
        "SELECT sha256,ex,clear,miss,max_combo,date,1 FROM score WHERE user=?1 UNION ALL SELECT sha256,ex,clear,miss,max_combo,date,0 FROM claim WHERE user=?1",
    )?;
    let scores = st
        .query_map([user], |r| {
            Ok(json!({"sha256": r.get::<_, String>(0)?, "ex": r.get::<_, i64>(1)?, "clear": r.get::<_, i64>(2)?, "miss": r.get::<_, i64>(3)?, "max_combo": r.get::<_, i64>(4)?, "date": r.get::<_, i64>(5)?, "verified": r.get::<_, i64>(6)? != 0}))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json!({"scores": scores}))
}

#[derive(Deserialize)]
struct Claim {
    sha256: String,
    clear: u8,
    ex: u32,
    max_combo: u32,
    miss: u32,
    date: i64,
}

#[derive(Deserialize)]
struct Claims {
    scores: Vec<Claim>,
}

/// Scores without a replay, such as ones imported from another player. Nothing checks them, so they
/// rank below every verified score under an unverified label, and any verified score replaces them.
fn add_claims(req: &mut Request, db: &Connection) -> ApiResult {
    let user = auth(req, db)?;
    let q: Claims = serde_json::from_slice(&read_body(req, MAX_JSON)?)
        .map_err(|_| ApiError::new(400, "bad json"))?;
    if !q
        .scores
        .iter()
        .all(|s| valid_sha(&s.sha256) && s.clear <= 10)
    {
        return Err(ApiError::new(400, "bad score"));
    }
    let tx = db.unchecked_transaction()?;
    {
        let mut st = tx.prepare_cached(
            "INSERT INTO claim(user,sha256,clear,ex,max_combo,miss,date) VALUES(?1,?2,?3,?4,?5,?6,?7)
             ON CONFLICT(user,sha256) DO UPDATE SET clear=MAX(claim.clear,excluded.clear), ex=MAX(claim.ex,excluded.ex),
               max_combo=MAX(claim.max_combo,excluded.max_combo), miss=MIN(claim.miss,excluded.miss),
               date=CASE WHEN excluded.ex>claim.ex THEN excluded.date ELSE claim.date END",
        )?;
        for s in &q.scores {
            st.execute(params![
                user,
                s.sha256,
                s.clear,
                s.ex,
                s.max_combo,
                s.miss,
                s.date.min(now())
            ])?;
        }
    }
    // Counted after the inserts, because sending a row again adds nothing. Returning rolls them back.
    let held: i64 = tx.query_row("SELECT COUNT(*) FROM claim WHERE user=?1", [user], |r| {
        r.get(0)
    })?;
    if held > MAX_OWNER_CLAIMS {
        return Err(ApiError::new(429, "claim limit reached"));
    }
    tx.commit()?;
    Ok(json!({"stored": q.scores.len()}))
}

fn add_rival(req: &Request, db: &Connection, name: &str) -> ApiResult {
    let user = auth(req, db)?;
    let rival: i64 = db
        .query_row("SELECT id FROM user WHERE name=?1", [name], |r| r.get(0))
        .optional()?
        .ok_or(ApiError::new(404, "no such player"))?;
    db.execute(
        "INSERT INTO rival(user,rival) VALUES(?1,?2) ON CONFLICT DO NOTHING",
        params![user, rival],
    )?;
    Ok(json!({"added": name}))
}

fn remove_rival(req: &Request, db: &Connection, name: &str) -> ApiResult {
    let user = auth(req, db)?;
    db.execute(
        "DELETE FROM rival WHERE user=?1 AND rival=(SELECT id FROM user WHERE name=?2)",
        params![user, name],
    )?;
    Ok(json!({"removed": name}))
}

fn rivals(req: &Request, db: &Connection) -> ApiResult {
    let user = auth(req, db)?;
    let mut st = db.prepare_cached(
        "SELECT u.name FROM rival r JOIN user u ON u.id=r.rival WHERE r.user=?1 ORDER BY u.name",
    )?;
    let names = st
        .query_map([user], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json!({"rivals": names}))
}

/// The caller and their rivals on one chart.
fn rival_scores(req: &Request, db: &Connection, sha: &str) -> ApiResult {
    let user = auth(req, db)?;
    let mut st = db.prepare_cached(&format!(
        "SELECT u.name,s.ex,s.clear,s.miss,s.verified FROM best s JOIN user u ON u.id=s.user
         WHERE s.sha256=?1 AND (s.user=?2 OR s.user IN (SELECT rival FROM rival WHERE user=?2)) {RANK_ORDER}"
    ))?;
    let scores = st
        .query_map(params![sha, user], |r| {
            Ok(json!({"name": r.get::<_, String>(0)?, "ex": r.get::<_, i64>(1)?, "clear": r.get::<_, i64>(2)?, "miss": r.get::<_, i64>(3)?, "verified": r.get::<_, i64>(4)? != 0}))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json!({"scores": scores}))
}

#[derive(Deserialize)]
struct TableQuery {
    sha256: Vec<String>,
}

/// Standings across a difficulty table's charts: the client sends the chart list it resolved.
fn table_ranking(req: &mut Request, db: &Connection) -> ApiResult {
    let q: TableQuery = serde_json::from_slice(&read_body(req, MAX_JSON)?)
        .map_err(|_| ApiError::new(400, "bad json"))?;
    if q.sha256.len() > 8192 || !q.sha256.iter().all(|s| valid_sha(s)) {
        return Err(ApiError::new(400, "bad chart list"));
    }
    // Verified scores only: one unchecked claim could otherwise outweigh a whole table.
    // 4 is EASY in beatoraja's clear numbering, the first real clear.
    let mut st = db.prepare_cached(
        "SELECT u.name,SUM(s.ex),COUNT(*) FILTER (WHERE s.clear>=4),COUNT(*) FROM score s JOIN user u ON u.id=s.user
         WHERE s.sha256 IN (SELECT value FROM json_each(?1)) GROUP BY u.name ORDER BY 3 DESC, 2 DESC, 1 LIMIT 1000",
    )?;
    let list =
        serde_json::to_string(&q.sha256).map_err(|_| ApiError::new(500, "internal error"))?;
    let players = st
        .query_map([list], |r| {
            Ok(json!({"name": r.get::<_, String>(0)?, "ex": r.get::<_, i64>(1)?, "clears": r.get::<_, i64>(2)?, "played": r.get::<_, i64>(3)?}))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json!({"players": players}))
}

fn route(req: &mut Request, db: &Connection, ctx: &Ctx) -> ApiResult {
    let url = req.url().to_string();
    let path = url.split('?').next().unwrap_or("").to_string();
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    let method = req.method().clone();
    let sha_ok = |s: &str| {
        if valid_sha(s) {
            Ok(())
        } else {
            Err(ApiError::new(400, "bad hash"))
        }
    };
    match (&method, parts.as_slice()) {
        (Method::Get, ["health"]) => Ok(json!({"ok": true})),
        (Method::Post, ["register"]) => register(req, db, ctx),
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
            ranking(req, db, sha, &url)
        }
        (Method::Get, ["scores", sha, "rivals"]) => {
            sha_ok(sha)?;
            rival_scores(req, db, sha)
        }
        (Method::Get, ["recent"]) => recent(db, &url),
        (Method::Get, ["me", "scores"]) => my_scores(req, db),
        (Method::Post, ["me", "claims"]) => add_claims(req, db),
        (Method::Post, ["me", "name"]) => rename(req, db),
        (Method::Get, ["rivals"]) => rivals(req, db),
        (Method::Put, ["rivals", name]) => add_rival(req, db, &percent_decode(name)?),
        (Method::Delete, ["rivals", name]) => remove_rival(req, db, &percent_decode(name)?),
        (Method::Post, ["table-ranking"]) => table_ranking(req, db),
        _ => Err(ApiError::new(404, "not found")),
    }
}

fn header_of(req: &Request, name: &'static str) -> Option<String> {
    req.headers()
        .iter()
        .find(|h| h.field.equiv(name))
        .map(|h| h.value.as_str().to_string())
}

fn user_name(db: &Connection, user: i64) -> Result<String, ApiError> {
    Ok(db.query_row("SELECT name FROM user WHERE id=?1", [user], |r| r.get(0))?)
}

/// Hands the request's socket to a thread of its own, so a connection that stays open holds no worker.
fn open_play(req: Request, db: &Connection, ctx: &Arc<Ctx>) {
    let accepted = (|| {
        let user = auth(&req, db)?;
        let key = header_of(&req, "Sec-WebSocket-Key")
            .filter(|_| {
                header_of(&req, "Upgrade").is_some_and(|u| u.eq_ignore_ascii_case("websocket"))
            })
            .ok_or(ApiError::new(400, "websocket required"))?;
        let name = user_name(db, user)?;
        let mut online = ctx.online.lock().unwrap_or_else(|e| e.into_inner());
        if online.values().sum::<usize>() >= MAX_PLAYERS_ONLINE {
            return Err(ApiError::new(503, "server is busy"));
        }
        let mine = online.entry(user).or_default();
        if *mine >= MAX_CONNECTIONS_PER_PLAYER {
            return Err(ApiError::new(429, "too many connections"));
        }
        *mine += 1;
        Ok((user, play::Session::new(user, name), key))
    })();
    let (user, session, key) = match accepted {
        Ok(got) => got,
        Err(ApiError(code, msg)) => {
            let _ = req.respond(
                Response::from_string(json!({"error": msg}).to_string()).with_status_code(code),
            );
            return;
        }
    };
    let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
    let header =
        Header::from_bytes("Sec-WebSocket-Accept", accept).expect("accept key is a header value");
    let stream = req.upgrade("websocket", Response::empty(101).with_header(header));
    let ctx = ctx.clone();
    std::thread::spawn(move || {
        play::serve(stream, &ctx.rooms, session);
        let mut online = ctx.online.lock().unwrap_or_else(|e| e.into_inner());
        let mine = online.entry(user).or_default();
        *mine = mine.saturating_sub(1);
        // A player leaves with their last connection: one who reconnected is already back in the room.
        if *mine == 0 {
            online.remove(&user);
            lock_rooms(&ctx).leave(user);
        }
    });
}

/// Each worker keeps its own connection: WAL lets them read while another writes.
fn worker(server: Arc<Server>, ctx: Arc<Ctx>, db: Connection) {
    loop {
        let Ok(mut req) = server.recv() else { return };
        if req.method() == &Method::Get && req.url() == "/play" {
            open_play(req, &db, &ctx);
            continue;
        }
        let result = route(&mut req, &db, &ctx);
        let (code, body) = match result {
            Ok(v) => (200, v),
            Err(ApiError(code, msg)) => (code, json!({"error": msg})),
        };
        let header = Header::from_bytes("Content-Type", "application/json").expect("static header");
        let _ = req.respond(
            Response::from_string(body.to_string())
                .with_status_code(code)
                .with_header(header),
        );
    }
}

/// Called once the input is read. A hostile chart must not use up the host, and a parser bug it reaches
/// must find no way to open a file or socket. The core's allocations then just fail.
fn confine_child() {
    let limits = [
        (libc::RLIMIT_AS, CHILD_MEMORY_BYTES),
        (libc::RLIMIT_CPU, VERIFY_TIMEOUT.as_secs() as libc::rlim_t),
        (libc::RLIMIT_NOFILE, 0),
    ];
    for (resource, value) in limits {
        let limit = libc::rlimit {
            rlim_cur: value,
            rlim_max: value,
        };
        // SAFETY: the pointer is valid for the call, and the callee only reads through it.
        if unsafe { libc::setrlimit(resource, &limit) } != 0 {
            std::process::exit(2);
        }
    }
}

/// Child mode of upload_chart: chart path and format in argv.
fn check_chart_main(args: &[String]) -> i32 {
    let (Some(path), Some(format)) = (args.get(2), args.get(3).and_then(|f| f.parse::<u8>().ok()))
    else {
        return 2;
    };
    let Ok(chart) = std::fs::read(Path::new(path)) else {
        return 2;
    };
    confine_child();
    match core::check_chart(&chart, format) {
        Ok(info) => {
            println!("{}", serde_json::to_string(&info).unwrap_or_default());
            0
        }
        Err(_) => 1,
    }
}

/// Child mode of verify_isolated: chart path and format in argv, replay on stdin, result JSON on stdout.
fn verify_main(args: &[String]) -> i32 {
    let (Some(path), Some(format)) = (args.get(2), args.get(3).and_then(|f| f.parse::<u8>().ok()))
    else {
        return 2;
    };
    let Ok(chart) = std::fs::read(Path::new(path)) else {
        return 2;
    };
    let mut replay = Vec::new();
    if std::io::stdin()
        .take(MAX_REPLAY as u64)
        .read_to_end(&mut replay)
        .is_err()
    {
        return 2;
    }
    confine_child();
    match core::verify(&chart, &replay, format) {
        Ok(v) => {
            println!("{}", serde_json::to_string(&v).unwrap_or_default());
            0
        }
        Err(_) => 1,
    }
}

fn open_db(path: &Path) -> rusqlite::Result<Connection> {
    let db = Connection::open(path)?;
    db.busy_timeout(Duration::from_secs(5))?;
    Ok(db)
}

fn initialize(db: &Connection) -> rusqlite::Result<()> {
    db.execute_batch(SCHEMA)?;
    // A database from before the storage limit: its charts count as size 0, and format comes with each score now.
    let has_column = |name: &str| {
        db.query_row(
            "SELECT 1 FROM pragma_table_info('chart') WHERE name=?1",
            [name],
            |_| Ok(()),
        )
        .optional()
        .map(|row| row.is_some())
    };
    if !has_column("size")? {
        db.execute_batch("ALTER TABLE chart ADD COLUMN size INTEGER NOT NULL DEFAULT 0")?;
    }
    if !has_column("title")? {
        db.execute_batch(
            "ALTER TABLE chart ADD COLUMN title TEXT NOT NULL DEFAULT ''; ALTER TABLE chart ADD COLUMN artist TEXT NOT NULL DEFAULT ''",
        )?;
    }
    if has_column("format")? {
        db.execute_batch("ALTER TABLE chart DROP COLUMN format")?;
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--verify") {
        std::process::exit(verify_main(&args));
    }
    if args.get(1).map(String::as_str) == Some("--check-chart") {
        std::process::exit(check_chart_main(&args));
    }
    let addr = args
        .get(1)
        .cloned()
        .unwrap_or_else(|| "127.0.0.1:8730".to_string());
    let data = PathBuf::from(
        args.get(2)
            .cloned()
            .unwrap_or_else(|| "ir-data".to_string()),
    );
    std::fs::create_dir_all(data.join("charts")).expect("create data directory");
    let db_path = data.join("ir.db");
    initialize(&open_db(&db_path).expect("open database")).expect("initialize database");
    let server = Arc::new(Server::http(&addr).expect("bind address"));
    let ctx = Arc::new(Ctx {
        data,
        attempts: Mutex::new(HashMap::new()),
        checks: Mutex::new(HashSet::new()),
        hashes: AtomicUsize::new(0),
        rooms: Mutex::new(rooms::Rooms::default()),
        online: Mutex::new(HashMap::new()),
    });
    eprintln!("actuon IR on http://{addr}");
    let threads: Vec<_> = (0..8)
        .map(|_| {
            let (s, c) = (server.clone(), ctx.clone());
            let db = open_db(&db_path).expect("open database");
            std::thread::spawn(move || worker(s, c, db))
        })
        .collect();
    // Behind the workers: deploy waits for /health, and this can take minutes.
    let (naming_ctx, naming_db) = (ctx.clone(), open_db(&db_path).expect("open database"));
    std::thread::spawn(move || {
        if let Err(e) = name_old_charts(&naming_db, &naming_ctx) {
            eprintln!("naming old charts failed: {}", e.1);
        }
    });
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
        assert_eq!(
            core::verify(b"#TITLE x\n", b"not a replay", 1).unwrap_err(),
            -1
        );
    }

    #[test]
    fn core_rejects_files_without_notes() {
        assert!(core::check_chart(b"not a chart", 1).is_err());
        let named = core::check_chart(
            b"#TITLE A\n#ARTIST B\n#BPM 120\n#WAV01 a.wav\n#00111:01\n",
            1,
        );
        assert_eq!(named.unwrap().title, "A");
        let long = format!(
            "#TITLE {}\n#BPM 120\n#WAV01 a.wav\n#00111:01\n",
            "a".repeat(999)
        );
        assert_eq!(
            core::check_chart(long.as_bytes(), 1).unwrap().title.len(),
            255
        );
    }

    #[test]
    fn names_decode() {
        assert_eq!(percent_decode("a%20b%2Fc").unwrap(), "a b/c");
        assert_eq!(percent_decode("%ED%95%9C").unwrap(), "\u{D55C}");
        assert!(percent_decode("%zz").is_err());
        assert!(percent_decode("%4").is_err());
        assert!(percent_decode("%FF").is_err());
    }

    #[test]
    fn database_before_storage_limit_opens() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch(
            "CREATE TABLE chart(sha256 TEXT PRIMARY KEY, format INTEGER NOT NULL, owner INTEGER NOT NULL);
             INSERT INTO chart VALUES('a',1,7);",
        )
        .unwrap();
        initialize(&db).unwrap();
        initialize(&db).unwrap();
        db.execute("INSERT INTO chart(sha256,owner,size) VALUES('b',7,5)", [])
            .unwrap();
        let used: i64 = db
            .query_row("SELECT SUM(size) FROM chart WHERE owner=7", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(used, 5);
    }

    fn test_ctx() -> Ctx {
        Ctx {
            data: PathBuf::new(),
            attempts: Mutex::new(HashMap::new()),
            checks: Mutex::new(HashSet::new()),
            hashes: AtomicUsize::new(0),
            rooms: Mutex::default(),
            online: Mutex::new(HashMap::new()),
        }
    }

    #[test]
    fn checks_are_capped_overall_and_per_player() {
        let ctx = test_ctx();
        let first = CheckSlot::take(&ctx, 1).unwrap();
        assert_eq!(CheckSlot::take(&ctx, 1).err().unwrap().0, 503);
        let _second = CheckSlot::take(&ctx, 2).unwrap();
        assert_eq!(CheckSlot::take(&ctx, 3).err().unwrap().0, 503);
        drop(first);
        assert!(
            CheckSlot::take(&ctx, 1).is_ok(),
            "a finished check frees its place"
        );
    }

    #[test]
    fn hashes_are_capped() {
        let ctx = test_ctx();
        let held: Vec<_> = (0..MAX_HASHES)
            .map(|_| HashSlot::take(&ctx).unwrap())
            .collect();
        assert_eq!(HashSlot::take(&ctx).err().unwrap().0, 503);
        drop(held);
        assert!(HashSlot::take(&ctx).is_ok());
    }

    #[test]
    fn chart_storage_is_capped_per_owner_and_overall() {
        let db = Connection::open_in_memory().unwrap();
        initialize(&db).unwrap();
        let store = |sha: &str, owner: i64, size: i64| {
            db.execute(
                "INSERT INTO chart(sha256,owner,size) VALUES(?1,?2,?3)",
                params![sha, owner, size],
            )
            .unwrap();
        };
        store("a", 1, MAX_OWNER_CHART_BYTES);
        assert_eq!(chart_room(&db, 1, 1).unwrap_err().0, 429);
        assert!(chart_room(&db, 2, MAX_OWNER_CHART_BYTES).is_ok());
        assert_eq!(
            chart_room(&db, 2, MAX_OWNER_CHART_BYTES + 1).unwrap_err().0,
            429
        );
        store("b", 3, MAX_TOTAL_CHART_BYTES - MAX_OWNER_CHART_BYTES);
        assert_eq!(
            chart_room(&db, 2, 1).unwrap_err().0,
            429,
            "the server's total counts everyone"
        );
    }

    #[test]
    fn throttling_sees_the_client_behind_the_proxy() {
        let proxy: Option<IpAddr> = "127.0.0.1".parse().ok();
        assert_eq!(client_key(Some("198.51.100.7"), proxy), "198.51.100.7");
        assert_eq!(client_key(Some("not an address"), proxy), "127.0.0.1");
        assert_eq!(client_key(None, proxy), "127.0.0.1");
        assert_eq!(client_key(None, None), "unknown");
        assert_eq!(
            client_key(Some("2001:db8:1:2::a"), proxy),
            client_key(Some("2001:db8:1:2::b"), proxy),
            "a /64 is one client"
        );
        assert_ne!(
            client_key(Some("2001:db8:1:2::a"), proxy),
            client_key(Some("2001:db8:1:3::a"), proxy)
        );
    }

    #[test]
    fn a_confined_child_cannot_open_files() {
        // SAFETY: the forked child only sets limits, tries an open and exits.
        unsafe {
            let pid = libc::fork();
            assert!(pid >= 0);
            if pid == 0 {
                confine_child();
                libc::_exit(if std::fs::File::open("/").is_err() {
                    0
                } else {
                    1
                });
            }
            let mut status = 0;
            assert_eq!(libc::waitpid(pid, &mut status, 0), pid);
            assert_eq!(libc::WEXITSTATUS(status), 0);
        }
    }

    #[test]
    fn throttle_counts_per_key_within_window() {
        let ctx = test_ctx();
        assert!(throttle(&ctx, "a", 60, 1).is_ok());
        assert_eq!(throttle(&ctx, "a", 60, 1).unwrap_err().0, 429);
        assert!(throttle(&ctx, "b", 60, 1).is_ok());
        assert!(throttle(&ctx, "c", 0, 1).is_ok());
        assert!(
            throttle(&ctx, "c", 0, 1).is_ok(),
            "an expired window starts over"
        );
    }

    #[test]
    fn query_parse() {
        assert_eq!(query_of("/x?limit=5&a=b").get("limit").unwrap(), "5");
    }
}
