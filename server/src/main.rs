//! Clients never report scores: the score comes from re-simulating their uploaded replay with the shared Zig core.
mod core;
mod play;
mod rooms;

use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;
use http_body_util::{BodyExt, Full, LengthLimitError, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::header::{CONNECTION, CONTENT_TYPE, UPGRADE};
use hyper::{Method, Request, Response};
use hyper_util::rt::{TokioIo, TokioTimer};
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
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

const MAX_CHART: usize = 16 << 20;
const MAX_REPLAY: usize = 16 << 20;
const MAX_JSON: usize = 1 << 20;
const VERIFY_TIMEOUT: Duration = Duration::from_secs(30);
const LOGIN_WINDOW_SECS: u64 = 60;
const LOGIN_ATTEMPTS: u32 = 10;
/// A day, not an hour: every per-account limit multiplies by the accounts one address can make.
const REGISTER_WINDOW_SECS: u64 = 24 * 3600;
const REGISTER_ATTEMPTS: u32 = 10;
const MAX_OWNER_CLAIMS: i64 = 50_000;
/// Checks plus hashes stay below DB_CONNECTIONS, so reads still get through.
const MAX_CHECKS: usize = 2;
const MAX_HASHES: usize = 4;
const MAX_UPLOADS: usize = 8;
/// A 32 MiB upload at 2 Mbit/s still makes it.
const BODY_TIMEOUT: Duration = Duration::from_secs(150);
/// A real chart takes far less: about 500 bytes a note.
const CHILD_MEMORY_BYTES: libc::rlim_t = 1 << 30;
const RANK_ORDER: &str = "ORDER BY s.verified DESC, s.ex DESC, s.date, s.user";

const SCHEMA: &str = "
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS user(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, pass TEXT NOT NULL, token TEXT UNIQUE NOT NULL);
CREATE TABLE IF NOT EXISTS chart(sha256 TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', artist TEXT NOT NULL DEFAULT '');
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
CREATE TABLE IF NOT EXISTS attempt(key TEXT PRIMARY KEY, expires INTEGER NOT NULL, count INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS attempt_expires ON attempt(expires);
DROP VIEW IF EXISTS best;
CREATE VIEW best AS
  SELECT user,sha256,clear,ex,max_combo,miss,date,1 AS verified FROM score s
  UNION ALL
  SELECT user,sha256,clear,ex,max_combo,miss,date,0 AS verified FROM claim c
    WHERE NOT EXISTS (SELECT 1 FROM score s WHERE s.user=c.user AND s.sha256=c.sha256);
";

struct Ctx {
    checks: Mutex<HashSet<i64>>,
    hashes: AtomicUsize,
    uploads: Arc<Semaphore>,
    rooms: Mutex<rooms::Rooms>,
    online: Mutex<HashMap<i64, usize>>,
}

/// Each connection serves one request at a time: WAL lets them read while another writes.
struct Pool {
    free: Arc<Semaphore>,
    conns: Mutex<Vec<Connection>>,
}

impl Pool {
    /// Database work blocks, so it runs off the async threads.
    async fn run<T: Send + 'static>(
        self: &Arc<Self>,
        job: impl FnOnce(&Connection) -> T + Send + 'static,
    ) -> Result<T, ApiError> {
        let busy = || ApiError::new(500, "internal error");
        let permit = self
            .free
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| busy())?;
        let db = self
            .conns
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .pop()
            .ok_or_else(busy)?;
        let lease = Lease(self.clone(), Some(db), permit);
        tokio::task::spawn_blocking(move || job(lease.1.as_ref().expect("leased")))
            .await
            .map_err(|e| {
                eprintln!("request failed: {e}");
                busy()
            })
    }
}

/// Gives the connection back even when the job panics, or the pool would shrink for good.
/// Holds the permit too: a request dropped mid-job must not free a slot whose connection is still out.
struct Lease(
    Arc<Pool>,
    Option<Connection>,
    #[allow(dead_code)] OwnedSemaphorePermit,
);

impl Drop for Lease {
    fn drop(&mut self) {
        if let Some(db) = self.1.take() {
            self.0
                .conns
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(db);
        }
    }
}

const DB_CONNECTIONS: usize = 8;
const MAX_PLAYERS_ONLINE: usize = 1024;
/// A dropped connection stays open here until the proxy gives up on it, so a reconnect overlaps it.
const MAX_CONNECTIONS_PER_PLAYER: usize = 4;

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

/// Each running password hash takes 19 MiB and a core.
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

/// The body comes whole, read up to its route's limit.
type Req = Request<Bytes>;

fn body_limit(method: &Method, path: &str) -> usize {
    if method == Method::POST && path.starts_with("/scores/") {
        MAX_CHART + MAX_REPLAY
    } else {
        MAX_JSON
    }
}

/// A score upload stays in memory until its check ends, so only a few are taken at once, as the old eight workers did.
fn upload_slot(
    uploads: &Arc<Semaphore>,
    limit: usize,
) -> Result<Option<OwnedSemaphorePermit>, ApiError> {
    if limit <= MAX_JSON {
        return Ok(None);
    }
    uploads
        .clone()
        .try_acquire_owned()
        .map(Some)
        .map_err(|_| ApiError::new(503, "server is busy"))
}

/// The permit, if any, must live as long as the body.
async fn read_body(
    req: Request<Incoming>,
    uploads: &Arc<Semaphore>,
) -> Result<(Req, Option<OwnedSemaphorePermit>), ApiError> {
    let limit = body_limit(req.method(), req.uri().path());
    let permit = upload_slot(uploads, limit)?;
    let (head, body) = req.into_parts();
    let body = tokio::time::timeout(BODY_TIMEOUT, Limited::new(body, limit).collect())
        .await
        .map_err(|_| ApiError::new(408, "body too slow"))?
        .map_err(|e| {
            if e.is::<LengthLimitError>() {
                ApiError::new(413, "body too large")
            } else {
                ApiError::new(400, "body could not be read")
            }
        })?
        .to_bytes();
    Ok((Request::from_parts(head, body), permit))
}

fn url_of<B>(req: &Request<B>) -> &str {
    req.uri().path_and_query().map_or("/", |p| p.as_str())
}

fn auth<B>(req: &Request<B>, db: &Connection) -> Result<i64, ApiError> {
    let header = header_of(req, "Authorization");
    let token = header
        .as_deref()
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or(ApiError::new(401, "missing token"))?;
    db.prepare_cached("SELECT id FROM user WHERE token=?1")?
        .query_row([token_hash(token)], |r| r.get(0))
        .optional()?
        .ok_or(ApiError::new(401, "bad token"))
}

/// Only nginx reaches this port and it sets X-Real-IP (docs/ir.md). An IPv6 client owns a whole /64.
fn client_key(real_ip: Option<&str>, peer: Option<IpAddr>) -> String {
    match real_ip.and_then(|ip| ip.trim().parse().ok()).or(peer) {
        Some(IpAddr::V6(ip)) => format!("{:x?}", &ip.segments()[..4]),
        Some(ip) => ip.to_string(),
        None => "unknown".to_string(),
    }
}

fn client_of(req: &Req) -> String {
    client_key(
        header_of(req, "X-Real-IP").as_deref(),
        req.extensions().get::<IpAddr>().copied(),
    )
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

/// Invisible or direction-changing characters and edge spaces would let one name pass for another in rankings.
fn valid_name(n: &str) -> bool {
    (1..=32).contains(&n.chars().count())
        && n.trim() == n
        && n.chars()
            .all(|c| c.is_alphanumeric() || "_-./ ".contains(c))
}

fn register(req: &Req, db: &Connection, ctx: &Ctx) -> ApiResult {
    let c: Credentials =
        serde_json::from_slice(req.body()).map_err(|_| ApiError::new(400, "bad json"))?;
    if !valid_name(&c.name) || c.password.len() < 8 || c.password.len() > 1024 {
        return Err(ApiError::new(
            400,
            "name must be 1-32 letters, digits or _ - . /, and password at least 8",
        ));
    }
    throttle(
        db,
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

fn rename(req: &Req, db: &Connection) -> ApiResult {
    let user = auth(req, db)?;
    let q: NewName =
        serde_json::from_slice(req.body()).map_err(|_| ApiError::new(400, "bad json"))?;
    if !valid_name(&q.name) {
        return Err(ApiError::new(
            400,
            "name must be 1-32 letters, digits or _ - . /",
        ));
    }
    db.execute("UPDATE user SET name=?1 WHERE id=?2", params![q.name, user])
        .map_err(name_conflict)?;
    Ok(json!({"name": q.name}))
}

/// In the database, so a restart or a second instance does not reset the counts. An unsalted hash only fixes the key's
/// size: an IPv4 address is easy to recover from it, so every try deletes the rows whose window has ended.
fn throttle(db: &Connection, key: &str, window_secs: u64, limit: u32) -> Result<(), ApiError> {
    let now = now();
    // One write transaction, not two: a login flood would otherwise hold the write lock twice per try.
    let tx = db.unchecked_transaction()?;
    tx.prepare_cached("DELETE FROM attempt WHERE expires<=?1")?
        .execute([now])?;
    let count: u32 = tx
        .prepare_cached(
            "INSERT INTO attempt(key,expires,count) VALUES(?1,?2,1)
             ON CONFLICT(key) DO UPDATE SET count=count+1 RETURNING count",
        )?
        .query_row(params![token_hash(key), now + window_secs as i64], |r| {
            r.get(0)
        })?;
    tx.commit()?;
    if count > limit {
        return Err(ApiError::new(429, "too many attempts"));
    }
    Ok(())
}

/// Login rotates the token, so a leaked one dies at the next login.
fn login(req: &Req, db: &Connection, ctx: &Ctx) -> ApiResult {
    let c: Credentials =
        serde_json::from_slice(req.body()).map_err(|_| ApiError::new(400, "bad json"))?;
    // Hashed because the name is still unchecked and can be 1 MiB long.
    throttle(
        db,
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

fn format_of(url: &str) -> Result<u8, ApiError> {
    query_of(url)
        .get("format")
        .and_then(|f| f.parse().ok())
        .filter(|f| (1..=3).contains(f))
        .ok_or(ApiError::new(400, "format must be 1, 2 or 3"))
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

/// The upload is the chart then the replay.
fn verify_isolated(
    format: u8,
    chart_len: usize,
    upload: &[u8],
) -> Result<(core::ChartInfo, core::Verified), ApiError> {
    let rejected = "chart or replay could not be verified";
    let args = [
        "--verify".into(),
        format.to_string().into(),
        chart_len.to_string().into(),
    ];
    serde_json::from_str(&run_child(&args, upload, rejected)?)
        .map_err(|_| ApiError::new(422, rejected))
}

fn submit(req: &Req, db: &Connection, ctx: &Ctx, sha: &str) -> ApiResult {
    let user = auth(req, db)?;
    // Per score, not per chart: a wrong format then costs only the one who sent it.
    let format = format_of(url_of(req))?;
    let upload = req.body();
    // The chart comes with every score and is dropped after the check, so the server holds no charts.
    let chart_len = query_of(url_of(req))
        .get("chart")
        .and_then(|n| n.parse::<usize>().ok())
        .filter(|n| *n <= MAX_CHART && *n <= upload.len())
        .ok_or(ApiError::new(400, "chart length must come with the upload"))?;
    if core::chart_sha256(&upload[..chart_len]) != sha {
        return Err(ApiError::new(400, "chart does not match its hash"));
    }
    let (info, v) = {
        let _slot = CheckSlot::take(ctx, user)?;
        verify_isolated(format, chart_len, upload)?
    };
    if !v.ok {
        return Err(ApiError::new(422, "replay could not be verified"));
    }
    db.execute(
        "INSERT INTO chart(sha256,title,artist) VALUES(?1,?2,?3)
         ON CONFLICT(sha256) DO UPDATE SET title=excluded.title, artist=excluded.artist",
        params![sha, info.title, info.artist],
    )?;
    let (prev_rank, _, _) = standing(db, sha, Some(user))?;
    db.execute(
        "INSERT INTO score(user,sha256,clear,ex,max_combo,miss,notes,gauge_type,date) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
         ON CONFLICT(user,sha256) DO UPDATE SET clear=MAX(score.clear,excluded.clear), ex=MAX(score.ex,excluded.ex),
           max_combo=MAX(score.max_combo,excluded.max_combo), miss=MIN(score.miss,excluded.miss),
           date=CASE WHEN excluded.ex>score.ex THEN excluded.date ELSE score.date END",
        params![user, sha, v.clear, v.ex_score, v.max_combo, v.miss, v.total_notes, v.gauge_type, now()],
    )?;
    // After the save: the room must not show a final score the database does not hold.
    if let Some(code) = query_of(url_of(req)).get("room") {
        lock_rooms(ctx).record_final(code, user, sha, v.seed, v.ex_score as u32);
    }
    Ok(
        json!({"clear": v.clear, "ex": v.ex_score, "max_combo": v.max_combo, "miss": v.miss, "notes": v.total_notes, "prev_rank": prev_rank}),
    )
}

fn lock_rooms(ctx: &Ctx) -> std::sync::MutexGuard<'_, rooms::Rooms> {
    ctx.rooms.lock().unwrap_or_else(|e| e.into_inner())
}

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

/// `offset` is echoed, so a client can tell a page from an older server's top rows.
fn ranking(req: &Req, db: &Connection, sha: &str, url: &str) -> ApiResult {
    let me = auth(req, db).ok();
    let query = query_of(url);
    let limit: i64 = query
        .get("limit")
        .and_then(|l| l.parse().ok())
        .unwrap_or(100)
        .clamp(1, 1000);
    let offset: i64 = query
        .get("offset")
        .and_then(|o| o.parse().ok())
        .unwrap_or(0)
        .max(0);
    let mut st = db.prepare_cached(&format!("SELECT u.name,s.ex,s.clear,s.miss,s.max_combo,s.date,s.verified,s.user FROM best s JOIN user u ON u.id=s.user WHERE s.sha256=?1 {RANK_ORDER} LIMIT ?2 OFFSET ?3"))?;
    let scores = st
        .query_map(params![sha, limit, offset], |r| {
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
        json!({"scores": scores, "offset": offset, "rank": rank, "total": total, "clears": clears, "title": title, "artist": artist}),
    )
}

/// Claims stay out: nothing has checked them.
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

/// For IR sync: the client must see a verified score beside a claim to know which replays are still worth sending.
fn my_scores(req: &Req, db: &Connection) -> ApiResult {
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

/// Scores without a replay are unchecked: they rank below every verified score, and any verified score replaces them.
fn add_claims(req: &Req, db: &Connection) -> ApiResult {
    let user = auth(req, db)?;
    let q: Claims =
        serde_json::from_slice(req.body()).map_err(|_| ApiError::new(400, "bad json"))?;
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

fn add_rival(req: &Req, db: &Connection, name: &str) -> ApiResult {
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

fn remove_rival(req: &Req, db: &Connection, name: &str) -> ApiResult {
    let user = auth(req, db)?;
    db.execute(
        "DELETE FROM rival WHERE user=?1 AND rival=(SELECT id FROM user WHERE name=?2)",
        params![user, name],
    )?;
    Ok(json!({"removed": name}))
}

fn rivals(req: &Req, db: &Connection) -> ApiResult {
    let user = auth(req, db)?;
    let mut st = db.prepare_cached(
        "SELECT u.name FROM rival r JOIN user u ON u.id=r.rival WHERE r.user=?1 ORDER BY u.name",
    )?;
    let names = st
        .query_map([user], |r| r.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(json!({"rivals": names}))
}

fn rival_scores(req: &Req, db: &Connection, sha: &str) -> ApiResult {
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

fn table_ranking(req: &Req, db: &Connection) -> ApiResult {
    let q: TableQuery =
        serde_json::from_slice(req.body()).map_err(|_| ApiError::new(400, "bad json"))?;
    if q.sha256.len() > 8192 || !q.sha256.iter().all(|s| valid_sha(s)) {
        return Err(ApiError::new(400, "bad chart list"));
    }
    // Verified only, so one claim cannot outweigh a table. clear>=4 is EASY or better in beatoraja numbering.
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

fn route(req: &Req, db: &Connection, ctx: &Ctx) -> ApiResult {
    let url = url_of(req);
    let parts: Vec<&str> = req.uri().path().trim_matches('/').split('/').collect();
    let sha_ok = |s: &str| {
        if valid_sha(s) {
            Ok(())
        } else {
            Err(ApiError::new(400, "bad hash"))
        }
    };
    match (req.method(), parts.as_slice()) {
        (&Method::GET, ["health"]) => Ok(json!({"ok": true})),
        (&Method::POST, ["register"]) => register(req, db, ctx),
        (&Method::POST, ["login"]) => login(req, db, ctx),
        (&Method::POST, ["scores", sha]) => {
            sha_ok(sha)?;
            submit(req, db, ctx, sha)
        }
        (&Method::GET, ["scores", sha]) => {
            sha_ok(sha)?;
            ranking(req, db, sha, url)
        }
        (&Method::GET, ["scores", sha, "rivals"]) => {
            sha_ok(sha)?;
            rival_scores(req, db, sha)
        }
        (&Method::GET, ["recent"]) => recent(db, url),
        (&Method::GET, ["me", "scores"]) => my_scores(req, db),
        (&Method::POST, ["me", "claims"]) => add_claims(req, db),
        (&Method::POST, ["me", "name"]) => rename(req, db),
        (&Method::GET, ["rivals"]) => rivals(req, db),
        (&Method::PUT, ["rivals", name]) => add_rival(req, db, &percent_decode(name)?),
        (&Method::DELETE, ["rivals", name]) => remove_rival(req, db, &percent_decode(name)?),
        (&Method::POST, ["table-ranking"]) => table_ranking(req, db),
        _ => Err(ApiError::new(404, "not found")),
    }
}

fn header_of<B>(req: &Request<B>, name: &'static str) -> Option<String> {
    req.headers()
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string)
}

fn user_name(db: &Connection, user: i64) -> Result<String, ApiError> {
    Ok(db.query_row("SELECT name FROM user WHERE id=?1", [user], |r| r.get(0))?)
}

type Reply = Response<Full<Bytes>>;

fn reply(result: ApiResult) -> Reply {
    let (code, body) = match result {
        Ok(v) => (200, v),
        Err(ApiError(code, msg)) => (code, json!({"error": msg})),
    };
    let mut out = Response::new(Full::new(Bytes::from(body.to_string())));
    *out.status_mut() =
        hyper::StatusCode::from_u16(code).unwrap_or(hyper::StatusCode::INTERNAL_SERVER_ERROR);
    out.headers_mut().insert(
        CONTENT_TYPE,
        "application/json".parse().expect("static header"),
    );
    out
}

fn admit(head: &Request<()>, db: &Connection) -> Result<(i64, String, String), ApiError> {
    let user = auth(head, db)?;
    let key = header_of(head, "Sec-WebSocket-Key")
        .filter(|_| header_of(head, "Upgrade").is_some_and(|u| u.eq_ignore_ascii_case("websocket")))
        .ok_or(ApiError::new(400, "websocket required"))?;
    Ok((user, user_name(db, user)?, key))
}

/// Counts the connection before the upgrade, so the limits hold while it is being opened.
fn open_slot(ctx: &Ctx, user: i64) -> Result<(), ApiError> {
    let mut online = ctx.online.lock().unwrap_or_else(|e| e.into_inner());
    if online.values().sum::<usize>() >= MAX_PLAYERS_ONLINE {
        return Err(ApiError::new(503, "server is busy"));
    }
    let mine = online.entry(user).or_default();
    if *mine >= MAX_CONNECTIONS_PER_PLAYER {
        return Err(ApiError::new(429, "too many connections"));
    }
    *mine += 1;
    Ok(())
}

fn close_play(ctx: &Ctx, user: i64) {
    let mut online = ctx.online.lock().unwrap_or_else(|e| e.into_inner());
    let mine = online.entry(user).or_default();
    *mine = mine.saturating_sub(1);
    // A player leaves with their last connection: one who reconnected is already back in the room.
    if *mine == 0 {
        online.remove(&user);
        lock_rooms(ctx).leave(user);
    }
}

/// An open room connection is a task, not a thread, so it holds nothing while it waits.
async fn open_play(mut req: Request<Incoming>, ctx: Arc<Ctx>, pool: Arc<Pool>) -> Reply {
    let upgrade = hyper::upgrade::on(&mut req);
    let head = Request::from_parts(req.into_parts().0, ());
    let admitted = pool.run(move |db| admit(&head, db)).await;
    // Counted here, with no await before the spawn below, so a client that drops now cannot leak the count.
    let (user, name, key) = match admitted
        .and_then(|got| got)
        .and_then(|got| open_slot(&ctx, got.0).map(|_| got))
    {
        Ok(got) => got,
        Err(e) => return reply(Err(e)),
    };
    let session = play::Session::new(user, name);
    tokio::spawn(async move {
        match upgrade.await {
            Ok(stream) => play::serve(TokioIo::new(stream), &ctx.rooms, session).await,
            Err(e) => eprintln!("websocket upgrade: {e}"),
        }
        close_play(&ctx, user);
    });
    let accept = tokio_tungstenite::tungstenite::handshake::derive_accept_key(key.as_bytes());
    let mut out = Response::new(Full::new(Bytes::new()));
    *out.status_mut() = hyper::StatusCode::SWITCHING_PROTOCOLS;
    let headers = out.headers_mut();
    headers.insert(UPGRADE, "websocket".parse().expect("static header"));
    headers.insert(CONNECTION, "Upgrade".parse().expect("static header"));
    headers.insert(
        "Sec-WebSocket-Accept",
        accept.parse().expect("accept key is a header value"),
    );
    out
}

async fn handle(mut req: Request<Incoming>, peer: IpAddr, ctx: Arc<Ctx>, pool: Arc<Pool>) -> Reply {
    if req.method() == Method::GET && req.uri().path() == "/play" {
        return open_play(req, ctx, pool).await;
    }
    req.extensions_mut().insert(peer);
    let result = match read_body(req, &ctx.uploads).await {
        Ok((req, permit)) => pool
            .run(move |db| {
                let _permit = permit;
                route(&req, db, &ctx)
            })
            .await
            .and_then(|r| r),
        Err(e) => Err(e),
    };
    reply(result)
}

async fn serve(listener: tokio::net::TcpListener, ctx: Arc<Ctx>, pool: Arc<Pool>) {
    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(got) => got,
            Err(e) => {
                // Out of file descriptors, most likely: retrying at once would spin.
                eprintln!("accept: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let (ctx, pool) = (ctx.clone(), pool.clone());
        tokio::spawn(async move {
            let service = hyper::service::service_fn(move |req| {
                let reply = handle(req, peer.ip(), ctx.clone(), pool.clone());
                async move { Ok::<_, std::convert::Infallible>(reply.await) }
            });
            // A client that drops mid-request is no fault of the server's.
            let _ = hyper::server::conn::http1::Builder::new()
                .timer(TokioTimer::new())
                .serve_connection(TokioIo::new(stream), service)
                .with_upgrades()
                .await;
        });
    }
}

/// Called once input is read: a hostile chart must not exhaust the host or let a parser bug open a file or socket.
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

/// Child of verify_isolated: format and chart length in argv, chart then replay on stdin, name and result JSON on stdout.
fn verify_main(args: &[String]) -> i32 {
    let (Some(format), Some(chart_len)) = (
        args.get(2).and_then(|f| f.parse::<u8>().ok()),
        args.get(3).and_then(|n| n.parse::<usize>().ok()),
    ) else {
        return 2;
    };
    let mut upload = Vec::new();
    if std::io::stdin()
        .take((MAX_CHART + MAX_REPLAY) as u64)
        .read_to_end(&mut upload)
        .is_err()
        || chart_len > upload.len()
    {
        return 2;
    }
    confine_child();
    let (chart, replay) = upload.split_at(chart_len);
    match core::check_chart(chart, format)
        .and_then(|info| Ok((info, core::verify(chart, replay, format)?)))
    {
        Ok(checked) => {
            println!("{}", serde_json::to_string(&checked).unwrap_or_default());
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
    // Older databases: format comes with each score, and charts are no longer stored, so nothing has an owner or a size.
    let has_column = |name: &str| {
        db.query_row(
            "SELECT 1 FROM pragma_table_info('chart') WHERE name=?1",
            [name],
            |_| Ok(()),
        )
        .optional()
        .map(|row| row.is_some())
    };
    if !has_column("title")? {
        db.execute_batch(
            "ALTER TABLE chart ADD COLUMN title TEXT NOT NULL DEFAULT ''; ALTER TABLE chart ADD COLUMN artist TEXT NOT NULL DEFAULT ''",
        )?;
    }
    for old in ["format", "owner", "size"] {
        if has_column(old)? {
            db.execute_batch(&format!("ALTER TABLE chart DROP COLUMN {old}"))?;
        }
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--verify") {
        std::process::exit(verify_main(&args));
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
    std::fs::create_dir_all(&data).expect("create data directory");
    let db_path = data.join("ir.db");
    initialize(&open_db(&db_path).expect("open database")).expect("initialize database");
    let pool = Arc::new(Pool {
        free: Arc::new(Semaphore::new(DB_CONNECTIONS)),
        conns: Mutex::new(
            (0..DB_CONNECTIONS)
                .map(|_| open_db(&db_path).expect("open database"))
                .collect(),
        ),
    });
    let ctx = Arc::new(Ctx {
        checks: Mutex::new(HashSet::new()),
        hashes: AtomicUsize::new(0),
        uploads: Arc::new(Semaphore::new(MAX_UPLOADS)),
        rooms: Mutex::new(rooms::Rooms::default()),
        online: Mutex::new(HashMap::new()),
    });
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("start runtime");
    runtime.block_on(async {
        let listener = tokio::net::TcpListener::bind(&addr)
            .await
            .expect("bind address");
        eprintln!("actuon IR on http://{addr}");
        serve(listener, ctx, pool).await
    });
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
        // Five measures at 0.001 BPM: a check of it would take minutes.
        assert!(core::check_chart(b"#BPM 0.001\n#WAV01 a.wav\n#00511:01\n", 1).is_err());
    }

    fn replay_with_press(chart: &[u8], time_us: u64) -> Vec<u8> {
        let mut out = b"ACTR\x02".to_vec();
        out.extend_from_slice(core::chart_sha256(chart).as_bytes());
        // gauge NORMAL, then random, gauge shift, 2P side, algorithm, seed, #RANDOM count, event count
        out.extend_from_slice(&[2, 0, 0, 0, 0, 0, 0, 1]);
        let mut zigzag = time_us << 1;
        while zigzag >= 0x80 {
            out.push(zigzag as u8 | 0x80);
            zigzag >>= 7;
        }
        out.push(zigzag as u8);
        out.push(0x80);
        out
    }

    #[test]
    fn a_replay_running_far_past_the_chart_is_refused() {
        let chart = b"#BPM 120\n#WAV01 a.wav\n#00111:01\n";
        assert!(core::verify(chart, &replay_with_press(chart, 2_000_000), 1).is_ok());
        assert_eq!(
            core::verify(chart, &replay_with_press(chart, 3_600_000_000), 1).unwrap_err(),
            -1
        );
    }

    #[test]
    fn a_name_cannot_hide_characters() {
        assert!(valid_name("square3ang"));
        assert!(valid_name("\u{D55C}\u{AE00} a_b-c.d/e"));
        assert!(!valid_name("square3ang\u{200B}"));
        assert!(!valid_name("\u{202E}gna3erauqs"));
        assert!(!valid_name("square3ang "));
        assert!(!valid_name(""));
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
    fn databases_that_stored_charts_open() {
        for old in [
            "CREATE TABLE chart(sha256 TEXT PRIMARY KEY, format INTEGER NOT NULL, owner INTEGER NOT NULL); INSERT INTO chart VALUES('a',1,7);",
            "CREATE TABLE chart(sha256 TEXT PRIMARY KEY, owner INTEGER NOT NULL, size INTEGER NOT NULL DEFAULT 0, title TEXT NOT NULL DEFAULT '', artist TEXT NOT NULL DEFAULT ''); INSERT INTO chart VALUES('a',7,5,'t','r');",
        ] {
            let db = Connection::open_in_memory().unwrap();
            db.execute_batch(old).unwrap();
            initialize(&db).unwrap();
            initialize(&db).unwrap();
            db.execute("INSERT INTO chart(sha256,title,artist) VALUES('b','t','r')", [])
                .unwrap();
            let rows: i64 = db
                .query_row("SELECT COUNT(*) FROM chart", [], |r| r.get(0))
                .unwrap();
            assert_eq!(rows, 2, "the old rows stay");
        }
    }

    fn test_ctx() -> Ctx {
        Ctx {
            checks: Mutex::new(HashSet::new()),
            hashes: AtomicUsize::new(0),
            uploads: Arc::new(Semaphore::new(MAX_UPLOADS)),
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
    fn large_bodies_are_capped_and_small_ones_are_not() {
        let ctx = test_ctx();
        let held: Vec<_> = (0..MAX_UPLOADS)
            .map(|_| upload_slot(&ctx.uploads, MAX_CHART + MAX_REPLAY).unwrap())
            .collect();
        assert_eq!(
            upload_slot(&ctx.uploads, MAX_CHART + MAX_REPLAY)
                .err()
                .unwrap()
                .0,
            503
        );
        assert!(upload_slot(&ctx.uploads, MAX_JSON).unwrap().is_none());
        drop(held);
        assert!(upload_slot(&ctx.uploads, MAX_CHART + MAX_REPLAY)
            .unwrap()
            .is_some());
    }

    #[test]
    fn a_dropped_request_holds_its_slot_until_its_job_ends() {
        let pool = Arc::new(Pool {
            free: Arc::new(Semaphore::new(1)),
            conns: Mutex::new(vec![Connection::open_in_memory().unwrap()]),
        });
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let slow = pool.run(|_| std::thread::sleep(Duration::from_millis(200)));
            assert!(tokio::time::timeout(Duration::from_millis(20), slow)
                .await
                .is_err());
            assert!(
                pool.run(|_| ()).await.is_ok(),
                "the next request waits for the connection"
            );
        });
    }

    #[test]
    fn room_connections_are_capped_per_player() {
        let ctx = test_ctx();
        for _ in 0..MAX_CONNECTIONS_PER_PLAYER {
            open_slot(&ctx, 1).unwrap();
        }
        assert_eq!(open_slot(&ctx, 1).unwrap_err().0, 429);
        assert!(open_slot(&ctx, 2).is_ok());
        close_play(&ctx, 1);
        assert!(
            open_slot(&ctx, 1).is_ok(),
            "a closed connection frees its place"
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
    fn throttle_counts_per_key_within_window_across_restarts() {
        let path = std::env::temp_dir().join(format!("actuon-throttle-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let db = open_db(&path).unwrap();
        initialize(&db).unwrap();
        assert!(throttle(&db, "a", 60, 1).is_ok());
        assert_eq!(throttle(&db, "a", 60, 1).unwrap_err().0, 429);
        assert!(throttle(&db, "b", 60, 1).is_ok());
        assert!(throttle(&db, "c", 0, 1).is_ok());
        assert!(
            throttle(&db, "c", 0, 1).is_ok(),
            "an expired window starts over"
        );
        drop(db);
        let other = open_db(&path).unwrap();
        assert_eq!(
            throttle(&other, "a", 60, 1).unwrap_err().0,
            429,
            "a restart keeps the count"
        );
        let stored: String = other
            .query_row("SELECT key FROM attempt LIMIT 1", [], |r| r.get(0))
            .unwrap();
        assert!(valid_sha(&stored), "keys are stored hashed");
        drop(other);
        for end in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{end}", path.display()));
        }
    }

    #[test]
    fn a_page_of_the_ranking_starts_at_its_offset() {
        let db = Connection::open_in_memory().unwrap();
        initialize(&db).unwrap();
        let sha = "a".repeat(64);
        for (id, ex) in [(1, 30), (2, 20), (3, 10)] {
            db.execute(
                "INSERT INTO user(id,name,pass,token) VALUES(?1,?2,'','t'||?1)",
                params![id, format!("p{id}")],
            )
            .unwrap();
            db.execute(
                "INSERT INTO score VALUES(?1,?2,0,?3,0,0,0,0,0)",
                params![id, sha, ex],
            )
            .unwrap();
        }
        let req = Request::new(Bytes::new());
        let names = |url: &str| {
            let v = ranking(&req, &db, &sha, url).unwrap();
            let names: Vec<String> = v["scores"]
                .as_array()
                .unwrap()
                .iter()
                .map(|s| s["name"].as_str().unwrap().to_string())
                .collect();
            (
                names,
                v["offset"].as_i64().unwrap(),
                v["total"].as_i64().unwrap(),
            )
        };
        assert_eq!(names("/x?limit=2"), (vec!["p1".into(), "p2".into()], 0, 3));
        assert_eq!(
            names("/x?limit=2&offset=1"),
            (vec!["p2".into(), "p3".into()], 1, 3)
        );
        assert_eq!(
            names("/x?offset=-5"),
            (vec!["p1".into(), "p2".into(), "p3".into()], 0, 3)
        );
        assert_eq!(names("/x?offset=9").0, Vec::<String>::new());
    }

    #[test]
    fn only_score_uploads_take_a_large_body() {
        assert_eq!(
            body_limit(&Method::POST, &format!("/scores/{}", "a".repeat(64))),
            MAX_CHART + MAX_REPLAY
        );
        assert_eq!(body_limit(&Method::POST, "/login"), MAX_JSON);
        assert_eq!(body_limit(&Method::GET, "/scores/x"), MAX_JSON);
    }

    #[test]
    fn query_parse() {
        assert_eq!(query_of("/x?limit=5&a=b").get("limit").unwrap(), "5");
    }
}
