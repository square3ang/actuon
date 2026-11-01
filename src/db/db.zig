//! SQLite wrapper and the song/score store.
const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");

pub const Error = error{ Sqlite, OutOfMemory };

// SQLITE_TRANSIENT is the destructor -1, and zig rejects that as a misaligned function pointer on arm64.
const sqlite_transient: isize = -1;
extern fn sqlite3_bind_text(*c.sqlite3_stmt, c_int, [*]const u8, c_int, isize) c_int;
extern fn sqlite3_bind_blob(*c.sqlite3_stmt, c_int, [*]const u8, c_int, isize) c_int;

pub const Stmt = struct {
    s: *c.sqlite3_stmt,

    pub fn bindText(st: Stmt, i: c_int, v: []const u8) void {
        _ = sqlite3_bind_text(st.s, i, v.ptr, @intCast(v.len), sqlite_transient);
    }
    pub fn bindInt(st: Stmt, i: c_int, v: i64) void {
        _ = c.sqlite3_bind_int64(st.s, i, v);
    }
    pub fn bindFloat(st: Stmt, i: c_int, v: f64) void {
        _ = c.sqlite3_bind_double(st.s, i, v);
    }
    pub fn bindBlob(st: Stmt, i: c_int, v: []const u8) void {
        _ = sqlite3_bind_blob(st.s, i, v.ptr, @intCast(v.len), sqlite_transient);
    }
    pub fn step(st: Stmt) Error!bool {
        const rc = c.sqlite3_step(st.s);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return error.Sqlite;
    }
    pub fn reset(st: Stmt) void {
        _ = c.sqlite3_reset(st.s);
    }
    pub fn int(st: Stmt, i: c_int) i64 {
        return c.sqlite3_column_int64(st.s, i);
    }
    pub fn float(st: Stmt, i: c_int) f64 {
        return c.sqlite3_column_double(st.s, i);
    }
    pub fn blob(st: Stmt, i: c_int) []const u8 {
        const p = c.sqlite3_column_blob(st.s, i) orelse return "";
        return @as([*]const u8, @ptrCast(p))[0..@intCast(c.sqlite3_column_bytes(st.s, i))];
    }

    pub fn text(st: Stmt, i: c_int) []const u8 {
        const p = c.sqlite3_column_text(st.s, i);
        if (p == null) return "";
        return p[0..@intCast(c.sqlite3_column_bytes(st.s, i))];
    }
    pub fn deinit(st: Stmt) void {
        _ = c.sqlite3_finalize(st.s);
    }
};

pub const Db = struct {
    h: *c.sqlite3,

    pub fn open(path: []const u8, gpa: std.mem.Allocator, read_only: bool) !Db {
        const z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(z);
        var h: ?*c.sqlite3 = null;
        const flags: c_int = if (read_only) c.SQLITE_OPEN_READONLY else c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
        if (c.sqlite3_open_v2(z.ptr, &h, flags, null) != c.SQLITE_OK) {
            if (h != null) _ = c.sqlite3_close(h);
            return error.Sqlite;
        }
        _ = c.sqlite3_busy_timeout(h, 5000);
        return .{ .h = h.? };
    }

    pub fn close(d: Db) void {
        _ = c.sqlite3_close(d.h);
    }

    pub fn exec(d: Db, sql: [:0]const u8) Error!void {
        var msg: [*c]u8 = null;
        if (c.sqlite3_exec(d.h, sql.ptr, null, null, &msg) != c.SQLITE_OK) {
            std.log.err("sqlite: {s}", .{if (msg != null) std.mem.span(msg) else "?"});
            c.sqlite3_free(msg);
            return error.Sqlite;
        }
    }

    pub fn prepare(d: Db, sql: []const u8) Error!Stmt {
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(d.h, sql.ptr, @intCast(sql.len), &s, null) != c.SQLITE_OK or s == null) {
            std.log.err("sqlite prepare: {s}: {s}", .{ sql, std.mem.span(c.sqlite3_errmsg(d.h)) });
            return error.Sqlite;
        }
        return .{ .s = s.? };
    }
};

pub const schema =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA synchronous=NORMAL;
    \\CREATE TABLE IF NOT EXISTS song(
    \\  path TEXT PRIMARY KEY, folder TEXT NOT NULL, sha256 TEXT NOT NULL, md5 TEXT NOT NULL,
    \\  title TEXT, subtitle TEXT, artist TEXT, subartist TEXT, genre TEXT, level TEXT,
    \\  difficulty INTEGER, mode INTEGER, notes INTEGER, total REAL, judgerank INTEGER,
    \\  min_bpm REAL, max_bpm REAL, length_ms INTEGER, has_ln INTEGER, has_mine INTEGER, has_random INTEGER,
    \\  stagefile TEXT, banner TEXT, preview TEXT, mtime INTEGER, size INTEGER);
    \\CREATE INDEX IF NOT EXISTS song_sha ON song(sha256);
    \\CREATE INDEX IF NOT EXISTS song_md5 ON song(md5);
    \\CREATE INDEX IF NOT EXISTS song_folder ON song(folder);
    \\CREATE TABLE IF NOT EXISTS score(
    \\  sha256 TEXT PRIMARY KEY, clear INTEGER DEFAULT 0, ex INTEGER DEFAULT 0,
    \\  pg INTEGER DEFAULT 0, gr INTEGER DEFAULT 0, gd INTEGER DEFAULT 0, bd INTEGER DEFAULT 0, pr INTEGER DEFAULT 0, ms INTEGER DEFAULT 0,
    \\  max_combo INTEGER DEFAULT 0, min_bp INTEGER DEFAULT 2147483647, playcount INTEGER DEFAULT 0, clearcount INTEGER DEFAULT 0,
    \\  date INTEGER DEFAULT 0, source TEXT DEFAULT '');
    \\CREATE TABLE IF NOT EXISTS replay(id INTEGER PRIMARY KEY, sha256 TEXT, date INTEGER, ex INTEGER, clear INTEGER, data BLOB);
    \\CREATE INDEX IF NOT EXISTS replay_sha ON replay(sha256);
    \\CREATE TABLE IF NOT EXISTS dir(path TEXT PRIMARY KEY, mtime INTEGER);
    \\CREATE TABLE IF NOT EXISTS bms_table(url TEXT PRIMARY KEY, name TEXT, symbol TEXT, fetched INTEGER);
    \\CREATE TABLE IF NOT EXISTS table_song(url TEXT, level TEXT, ord INTEGER, md5 TEXT, sha256 TEXT, title TEXT, artist TEXT, zip_url TEXT, name_diff TEXT);
    \\CREATE INDEX IF NOT EXISTS table_song_url ON table_song(url, ord);
    \\CREATE INDEX IF NOT EXISTS table_song_md5 ON table_song(md5);
    \\CREATE INDEX IF NOT EXISTS table_song_sha ON table_song(sha256);
    \\CREATE TABLE IF NOT EXISTS course(id INTEGER PRIMARY KEY, table_url TEXT, name TEXT, hashes TEXT, constraints TEXT, UNIQUE(table_url, name));
    \\CREATE TABLE IF NOT EXISTS course_score(course_id INTEGER, clear INTEGER, ex INTEGER, date INTEGER, PRIMARY KEY(course_id));
;

pub fn initSchema(d: Db) !void {
    try d.exec(schema);
}

pub fn openMain(gpa: std.mem.Allocator) !Db {
    const dir = try fs.dataDir(gpa);
    defer gpa.free(dir);
    const p = try std.fmt.allocPrint(gpa, "{s}actuon.db", .{dir});
    defer gpa.free(p);
    const d = try Db.open(p, gpa, false);
    errdefer d.close();
    try d.exec(schema);
    return d;
}

pub const chart_exts = [_][]const u8{ ".bms", ".bme", ".bml", ".pms", ".bmson" };

fn isChart(name: []const u8) bool {
    for (chart_exts) |e| if (std.ascii.endsWithIgnoreCase(name, e)) return true;
    return false;
}

pub const ScanStats = struct { parsed: u32 = 0, removed: u32 = 0, dirs: u32 = 0, failed: u32 = 0 };

/// Charts parsed at once. It bounds memory, as parsed charts wait in memory for their insert.
const scan_batch = 256;

const ScanJob = struct {
    path: []const u8,
    folder: []const u8,
    mtime: i64,
    size: u64,
    bytes: []u8 = &.{},
    chart: ?core.types.Chart = null,
};

const ScanWork = struct {
    gpa: std.mem.Allocator,
    jobs: []ScanJob,
    next: std.atomic.Value(usize) = .init(0),
    progress: ?*std.atomic.Value(u32),
};

fn scanWorker(ud: ?*anyopaque) callconv(.c) c_int {
    const w: *ScanWork = @ptrCast(@alignCast(ud));
    while (true) {
        const i = w.next.fetchAdd(1, .monotonic);
        if (i >= w.jobs.len) return 0;
        const job = &w.jobs[i];
        job.bytes = fs.readAlloc(w.gpa, job.path, 1 << 26) catch continue;
        job.chart = (if (std.ascii.endsWithIgnoreCase(job.path, ".bmson"))
            core.bmson.parse(w.gpa, job.bytes)
        else
            core.bms.parse(w.gpa, job.bytes, .{ .is_pms = std.ascii.endsWithIgnoreCase(job.path, ".pms") })) catch continue;
        if (w.progress) |p| _ = p.fetchAdd(1, .monotonic);
    }
}

/// Parses on every core; the inserts stay on this thread, which owns the connection.
fn insertBatch(gpa: std.mem.Allocator, d: Db, ins: anytype, jobs: []ScanJob, stats: *ScanStats, progress: ?*std.atomic.Value(u32)) !void {
    var work: ScanWork = .{ .gpa = gpa, .jobs = jobs, .progress = progress };
    var threads: [31]?*c.SDL_Thread = @splat(null);
    const extra: usize = @intCast(std.math.clamp(c.SDL_GetNumLogicalCPUCores() - 1, 0, threads.len));
    for (threads[0..@min(extra, jobs.len -| 1)]) |*t| t.* = c.SDL_CreateThread(scanWorker, "scan-parse", &work);
    _ = scanWorker(&work);
    for (threads) |t| if (t != null) c.SDL_WaitThread(t, null);
    defer for (jobs) |*job| {
        if (job.chart) |*chart| chart.deinit();
        gpa.free(job.bytes);
    };
    // Held only for the inserts: a score saved during a long scan must not wait for the scan.
    try d.exec("BEGIN IMMEDIATE");
    errdefer d.exec("ROLLBACK") catch {};
    for (jobs) |*job| {
        const chart = &(job.chart orelse {
            stats.failed += 1;
            continue;
        });
        ins.bindText(1, job.path);
        ins.bindText(2, job.folder);
        ins.bindText(3, &chart.sha256);
        ins.bindText(4, if (std.ascii.endsWithIgnoreCase(job.path, ".bmson")) "" else &chart.md5);
        ins.bindText(5, chart.title);
        ins.bindText(6, chart.subtitle);
        ins.bindText(7, chart.artist);
        ins.bindText(8, chart.subartist);
        ins.bindText(9, chart.genre);
        ins.bindText(10, chart.playlevel);
        ins.bindInt(11, chart.difficulty);
        ins.bindInt(12, @backingInt(chart.mode));
        ins.bindInt(13, chart.total_notes);
        ins.bindFloat(14, chart.total);
        ins.bindInt(15, chart.judgerank);
        ins.bindFloat(16, chart.min_bpm);
        ins.bindFloat(17, chart.max_bpm);
        ins.bindInt(18, @divTrunc(chart.last_time_us, 1000));
        ins.bindInt(19, @intFromBool(chart.has_ln));
        ins.bindInt(20, @intFromBool(chart.has_mine));
        ins.bindInt(21, @intFromBool(chart.has_random));
        ins.bindText(22, chart.stagefile);
        ins.bindText(23, chart.banner);
        ins.bindText(24, chart.preview);
        ins.bindInt(25, job.mtime);
        ins.bindInt(26, @intCast(job.size));
        _ = try ins.step();
        ins.reset();
        stats.parsed += 1;
    }
    try d.exec("COMMIT");
}

/// Incremental: a chart is only re-parsed if its mtime or size changed.
/// shortcut: every chart is stat'ed on each pass, move to OS file notifications if huge libraries feel slow.
pub fn scan(gpa: std.mem.Allocator, d: Db, roots: []const []const u8, progress: ?*std.atomic.Value(u32)) !ScanStats {
    var stats: ScanStats = .{};
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const known = try d.prepare("SELECT mtime, size FROM song WHERE path=?1");
    defer known.deinit();
    const ins = try d.prepare(
        \\INSERT OR REPLACE INTO song(path,folder,sha256,md5,title,subtitle,artist,subartist,genre,level,difficulty,mode,notes,total,judgerank,min_bpm,max_bpm,length_ms,has_ln,has_mine,has_random,stagefile,banner,preview,mtime,size)
        \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25,?26)
    );
    defer ins.deinit();

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var batch: std.ArrayList(ScanJob) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    var unread: std.ArrayList([]const u8) = .empty;
    for (roots) |r| try stack.append(arena.allocator(), try arena.allocator().dupe(u8, r));
    while (stack.pop()) |dir| {
        var it = std.heap.ArenaAllocator.init(gpa);
        defer it.deinit();
        const a = it.allocator();
        stats.dirs += 1;
        const entries = fs.listChecked(a, dir) catch |e| {
            std.log.warn("cannot read {s}: {t}", .{ dir, e });
            try unread.append(arena.allocator(), dir);
            continue;
        };
        for (entries) |e| {
            const full = try std.fs.path.join(arena.allocator(), &.{ dir, e.name });
            if (e.is_dir) {
                if (e.name.len > 0 and e.name[0] != '.') try stack.append(arena.allocator(), full);
                continue;
            }
            if (!isChart(e.name)) continue;
            try seen.put(arena.allocator(), full, {});
            const st = fs.stat(full) orelse continue;
            known.bindText(1, full);
            const hit = try known.step();
            const same = hit and known.int(0) == st.mtime and known.int(1) == @as(i64, @intCast(st.size));
            known.reset();
            if (same) continue;
            try batch.append(arena.allocator(), .{ .path = full, .folder = dir, .mtime = st.mtime, .size = st.size });
            if (batch.items.len == scan_batch) {
                try insertBatch(gpa, d, ins, batch.items, &stats, progress);
                batch.clearRetainingCapacity();
            }
        }
    }
    try insertBatch(gpa, d, ins, batch.items, &stats, progress);
    try d.exec("BEGIN IMMEDIATE");
    errdefer d.exec("ROLLBACK") catch {};
    // Drop rows only under the scanned roots: an unplugged library must not vanish because
    // its root is gone, so a folder that could not be read keeps its rows.
    for (roots) |r| {
        const sel = try d.prepare("SELECT path FROM song WHERE path LIKE ?1 ESCAPE '\\'");
        defer sel.deinit();
        const del = try d.prepare("DELETE FROM song WHERE path=?1");
        defer del.deinit();
        const pat = try likePrefix(arena.allocator(), r);
        sel.bindText(1, pat);
        while (try sel.step()) {
            const path = sel.text(0);
            if (!isUnder(path, r) or seen.contains(path)) continue;
            for (unread.items) |dir| {
                if (isUnder(path, dir)) break;
            } else {
                del.bindText(1, path);
                _ = try del.step();
                del.reset();
                stats.removed += 1;
            }
        }
    }
    try d.exec("COMMIT");
    return stats;
}

/// A whole folder name must match: /mnt/bms does not hold /mnt/bms2/a.bms.
fn isUnder(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0 or path.len <= dir.len or !std.mem.startsWith(u8, path, dir)) return false;
    return std.fs.path.isSep(dir[dir.len - 1]) or std.fs.path.isSep(path[dir.len]);
}

fn likePrefix(a: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (prefix) |ch| {
        if (ch == '%' or ch == '_' or ch == '\\') try out.append(a, '\\');
        try out.append(a, ch);
    }
    try out.append(a, '%');
    return out.toOwnedSlice(a);
}

pub const Song = struct {
    path: []const u8,
    folder: []const u8,
    sha256: []const u8,
    md5: []const u8,
    title: []const u8,
    subtitle: []const u8,
    artist: []const u8,
    genre: []const u8,
    level: []const u8,
    difficulty: i32,
    mode: u8,
    notes: u32,
    min_bpm: f64,
    max_bpm: f64,
    length_ms: i64,
    has_ln: bool,
    stagefile: []const u8,
    banner: []const u8,
    preview: []const u8,
    clear: u8,
    ex: u32,
    miss: i64,
    played: u32,
    /// Symbol and level from a difficulty table, empty when the chart is in none.
    table_level: []const u8 = "",

    /// A table's level says more than the number the chart's author chose.
    pub fn shownLevel(s: Song) []const u8 {
        return if (s.table_level.len > 0) s.table_level else s.level;
    }
};

pub const song_select =
    \\SELECT s.path,s.folder,s.sha256,s.md5,s.title,s.subtitle,s.artist,s.genre,s.level,s.difficulty,s.mode,s.notes,s.min_bpm,s.max_bpm,s.length_ms,s.has_ln,s.stagefile,s.banner,s.preview,
    \\ COALESCE(c.clear,0),COALESCE(c.ex,0),COALESCE(c.min_bp,-1),COALESCE(c.playcount,0),
    \\ (SELECT COALESCE(b.symbol,'')||t.level FROM table_song t JOIN bms_table b ON b.url=t.url
    \\  WHERE (t.md5=s.md5 AND t.md5<>'') OR (t.sha256=s.sha256 AND t.sha256<>'') ORDER BY b.name LIMIT 1)
    \\ FROM song s LEFT JOIN score c ON c.sha256=s.sha256
;

pub fn readSong(a: std.mem.Allocator, st: Stmt) !Song {
    const dup = struct {
        fn f(al: std.mem.Allocator, s: Stmt, i: c_int) ![]const u8 {
            return al.dupe(u8, s.text(i));
        }
    }.f;
    return .{
        .path = try dup(a, st, 0),
        .folder = try dup(a, st, 1),
        .sha256 = try dup(a, st, 2),
        .md5 = try dup(a, st, 3),
        .title = try dup(a, st, 4),
        .subtitle = try dup(a, st, 5),
        .artist = try dup(a, st, 6),
        .genre = try dup(a, st, 7),
        .level = try dup(a, st, 8),
        .difficulty = @intCast(st.int(9)),
        .mode = @intCast(st.int(10)),
        .notes = @intCast(st.int(11)),
        .min_bpm = st.float(12),
        .max_bpm = st.float(13),
        .length_ms = st.int(14),
        .has_ln = st.int(15) != 0,
        .stagefile = try dup(a, st, 16),
        .banner = try dup(a, st, 17),
        .preview = try dup(a, st, 18),
        .clear = @intCast(st.int(19)),
        .ex = @intCast(st.int(20)),
        .miss = st.int(21),
        .played = @intCast(st.int(22)),
        .table_level = try dup(a, st, 23),
    };
}

/// Replays offered per chart, as beatoraja's slots.
pub const max_replays = 4;

/// Drops replays nothing can reach: the song select's newest ones, and the best one IR sync uploads.
pub fn pruneReplays(d: Db, sha256: []const u8) !void {
    const st = try d.prepare(
        \\DELETE FROM replay WHERE sha256=?1
        \\ AND id NOT IN (SELECT id FROM replay WHERE sha256=?1 ORDER BY date DESC, id DESC LIMIT ?2)
        \\ AND id NOT IN (SELECT id FROM replay WHERE sha256=?1 ORDER BY ex DESC, clear DESC LIMIT 1)
    );
    defer st.deinit();
    st.bindText(1, sha256);
    st.bindInt(2, max_replays);
    _ = try st.step();
}

pub const ScoreIn = struct {
    sha256: []const u8,
    clear: u8,
    ex: u32,
    counts: [6]u32,
    max_combo: u32,
    miss: u32,
    played: u32 = 1,
    cleared: u32 = 0,
    date: i64,
    source: []const u8 = "",
};

/// Keeps per-field bests, like beatoraja's ScoreData.update. Local plays add to the play counts; an import
/// of a source already taken in repeats its totals, so it only raises them.
// shortcut: a row remembers one source, so alternating two imports still adds up, keep counts per source if that is reported.
pub fn recordScore(d: Db, s: ScoreIn) !void {
    const st = try d.prepare(
        \\INSERT INTO score(sha256,clear,ex,pg,gr,gd,bd,pr,ms,max_combo,min_bp,playcount,clearcount,date,source)
        \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)
        \\ON CONFLICT(sha256) DO UPDATE SET
        \\ clear=MAX(clear,excluded.clear),
        \\ pg=CASE WHEN excluded.ex>ex THEN excluded.pg ELSE pg END,
        \\ gr=CASE WHEN excluded.ex>ex THEN excluded.gr ELSE gr END,
        \\ gd=CASE WHEN excluded.ex>ex THEN excluded.gd ELSE gd END,
        \\ bd=CASE WHEN excluded.ex>ex THEN excluded.bd ELSE bd END,
        \\ pr=CASE WHEN excluded.ex>ex THEN excluded.pr ELSE pr END,
        \\ ms=CASE WHEN excluded.ex>ex THEN excluded.ms ELSE ms END,
        \\ ex=MAX(ex,excluded.ex),
        \\ max_combo=MAX(max_combo,excluded.max_combo),
        \\ min_bp=MIN(min_bp,excluded.min_bp),
        \\ playcount=CASE WHEN excluded.source='' OR source<>excluded.source THEN playcount+excluded.playcount ELSE MAX(playcount,excluded.playcount) END,
        \\ clearcount=CASE WHEN excluded.source='' OR source<>excluded.source THEN clearcount+excluded.clearcount ELSE MAX(clearcount,excluded.clearcount) END,
        \\ source=CASE WHEN excluded.source='' THEN source ELSE excluded.source END,
        \\ date=MAX(date,excluded.date)
    );
    defer st.deinit();
    st.bindText(1, s.sha256);
    st.bindInt(2, s.clear);
    st.bindInt(3, s.ex);
    for (s.counts, 0..) |v, i| st.bindInt(@intCast(4 + i), v);
    st.bindInt(10, s.max_combo);
    st.bindInt(11, s.miss);
    st.bindInt(12, s.played);
    st.bindInt(13, s.cleared);
    st.bindInt(14, s.date);
    st.bindText(15, s.source);
    _ = try st.step();
}

pub const ImportStats = struct { imported: u32 = 0, skipped: u32 = 0 };

/// Imports a beatoraja/lr2oraja player score.db. The source is opened read-only.
pub fn importBeatoraja(gpa: std.mem.Allocator, d: Db, path: []const u8) !ImportStats {
    const src = try Db.open(path, gpa, true);
    defer src.close();
    const st = try src.prepare("SELECT sha256,clear,epg,lpg,egr,lgr,egd,lgd,ebd,lbd,epr,lpr,ems,lms,combo,minbp,playcount,clearcount,date FROM score WHERE mode=0");
    defer st.deinit();
    var stats: ImportStats = .{};
    try d.exec("BEGIN");
    errdefer d.exec("ROLLBACK") catch {};
    while (try st.step()) {
        const pg = st.int(2) + st.int(3);
        const gr = st.int(4) + st.int(5);
        try recordScore(d, .{
            .sha256 = st.text(0),
            .clear = @intCast(std.math.clamp(st.int(1), 0, 10)),
            .ex = @intCast(pg * 2 + gr),
            .counts = .{ @intCast(pg), @intCast(gr), @intCast(st.int(6) + st.int(7)), @intCast(st.int(8) + st.int(9)), @intCast(st.int(10) + st.int(11)), @intCast(st.int(12) + st.int(13)) },
            .max_combo = @intCast(st.int(14)),
            .miss = @intCast(@max(st.int(15), 0)),
            .played = @intCast(st.int(16)),
            .cleared = @intCast(st.int(17)),
            .date = st.int(18),
            .source = "beatoraja",
        });
        stats.imported += 1;
    }
    try d.exec("COMMIT");
    return stats;
}

/// Imports an LR2 score database. LR2 keys scores by MD5, so a chart must be scanned first to
/// learn its SHA-256; unknown charts are skipped (same as ScoreDataImporter).
pub fn importLr2(gpa: std.mem.Allocator, d: Db, path: []const u8) !ImportStats {
    const clears = [_]u8{ 0, 1, 4, 5, 6, 8, 9 };
    const src = try Db.open(path, gpa, true);
    defer src.close();
    const st = try src.prepare("SELECT * FROM score");
    defer st.deinit();
    const look = try d.prepare("SELECT sha256 FROM song WHERE md5=?1 LIMIT 1");
    defer look.deinit();
    const col = struct {
        fn f(q: Stmt, name: []const u8) i64 {
            for (0..@intCast(c.sqlite3_column_count(q.s))) |i| {
                const n = std.mem.span(c.sqlite3_column_name(q.s, @intCast(i)));
                if (std.ascii.eqlIgnoreCase(n, name)) return q.int(@intCast(i));
            }
            return 0;
        }
        fn hash(q: Stmt) []const u8 {
            for (0..@intCast(c.sqlite3_column_count(q.s))) |i| {
                if (std.ascii.eqlIgnoreCase(std.mem.span(c.sqlite3_column_name(q.s, @intCast(i))), "hash")) return q.text(@intCast(i));
            }
            return "";
        }
    };
    var stats: ImportStats = .{};
    try d.exec("BEGIN");
    errdefer d.exec("ROLLBACK") catch {};
    while (try st.step()) {
        look.bindText(1, col.hash(st));
        defer look.reset();
        if (!try look.step()) {
            stats.skipped += 1;
            continue;
        }
        const clear_i: usize = @intCast(std.math.clamp(col.f(st, "clear"), 0, clears.len - 1));
        const pg = col.f(st, "perfect");
        const gr = col.f(st, "great");
        try recordScore(d, .{
            .sha256 = look.text(0),
            .clear = clears[clear_i],
            .ex = @intCast(pg * 2 + gr),
            .counts = .{ @intCast(pg), @intCast(gr), @intCast(col.f(st, "good")), @intCast(col.f(st, "bad")), @intCast(col.f(st, "poor")), 0 },
            .max_combo = @intCast(@max(col.f(st, "maxcombo"), 0)),
            .miss = @intCast(@max(col.f(st, "minbp"), 0)),
            .played = @intCast(col.f(st, "playcount")),
            .cleared = @intCast(col.f(st, "clearcount")),
            .date = 0,
            .source = "LR2",
        });
        stats.imported += 1;
    }
    try d.exec("COMMIT");
    return stats;
}

test "LR2 import maps clears through md5 and skips unknown charts" {
    const gpa = std.testing.allocator;
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try d.exec(schema);
    try d.exec("INSERT INTO song(path,folder,sha256,md5) VALUES('p','f','shaA','md5A')");
    fs.io = std.testing.io;
    const lr2 = "actuon_test_lr2.db";
    fs.remove(lr2);
    defer fs.remove(lr2);
    const src = try Db.open(lr2, gpa, false);
    try src.exec("CREATE TABLE score(hash TEXT, clear INT, perfect INT, great INT, good INT, bad INT, poor INT, minbp INT, playcount INT, clearcount INT);" ++
        "INSERT INTO score VALUES('md5A',4,10,5,1,1,1,3,7,2),('nope',1,1,1,1,1,1,1,1,1)");
    src.close();
    const st = try importLr2(gpa, d, lr2);
    try std.testing.expectEqual(@as(u32, 1), st.imported);
    try std.testing.expectEqual(@as(u32, 1), st.skipped);
    const q = try d.prepare("SELECT clear,ex,playcount FROM score WHERE sha256='shaA'");
    defer q.deinit();
    try std.testing.expect(try q.step());
    try std.testing.expectEqual(@as(i64, 6), q.int(0)); // LR2 clear 4 = HARD
    try std.testing.expectEqual(@as(i64, 25), q.int(1));
    try std.testing.expectEqual(@as(i64, 7), q.int(2));
}

test "score bests are per field and import reads beatoraja schema" {
    const gpa = std.testing.allocator;
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try d.exec(schema);
    try recordScore(d, .{ .sha256 = "a", .clear = 5, .ex = 100, .counts = @splat(1), .max_combo = 10, .miss = 5, .date = 1 });
    try recordScore(d, .{ .sha256 = "a", .clear = 1, .ex = 90, .counts = @splat(2), .max_combo = 20, .miss = 9, .date = 2 });
    const st = try d.prepare("SELECT clear,ex,pg,max_combo,min_bp,playcount FROM score WHERE sha256='a'");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 5), st.int(0));
    try std.testing.expectEqual(@as(i64, 100), st.int(1));
    try std.testing.expectEqual(@as(i64, 1), st.int(2));
    try std.testing.expectEqual(@as(i64, 20), st.int(3));
    try std.testing.expectEqual(@as(i64, 5), st.int(4));
    try std.testing.expectEqual(@as(i64, 2), st.int(5));
}

test "scan parses in parallel, stores every chart and skips them next time" {
    const gpa = std.testing.allocator;
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try initSchema(d);
    const roots = [_][]const u8{"tests/charts"};
    const first = try scan(gpa, d, &roots, null);
    try std.testing.expect(first.parsed > 0);
    const count = try d.prepare("SELECT COUNT(*) FROM song");
    defer count.deinit();
    try std.testing.expect(try count.step());
    try std.testing.expectEqual(@as(i64, first.parsed), count.int(0));
    try std.testing.expectEqual(@as(u32, 0), (try scan(gpa, d, &roots, null)).parsed);
}

test "a scan drops gone charts only in folders it could read" {
    const gpa = std.testing.allocator;
    fs.io = std.testing.io;
    const root = "actuon_test_roots";
    fs.removeTree(root);
    defer fs.removeTree(root);
    try fs.mkdirs(root ++ "/bms");
    try fs.mkdirs(root ++ "/bms2");
    try fs.write(root ++ "/file", "not a folder");
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try initSchema(d);
    try d.exec("INSERT INTO song(path,folder,sha256,md5,mtime,size) VALUES('" ++ root ++ "/bms/gone.bms','','a','a',0,0),('" ++ root ++ "/bms2/kept.bms','','b','b',0,0),('" ++ root ++ "/file/kept.bms','','c','c',0,0)");
    const roots = [_][]const u8{ root ++ "/bms", root ++ "/file" };
    try std.testing.expectEqual(@as(u32, 1), (try scan(gpa, d, &roots, null)).removed);
    const st = try d.prepare("SELECT COUNT(*) FROM song WHERE path LIKE '%kept.bms'");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 2), st.int(0));
}

test "importing the same scores twice does not double the play counts, local plays still add" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try initSchema(d);
    const imported: ScoreIn = .{ .sha256 = "a", .clear = 1, .ex = 1, .counts = @splat(0), .max_combo = 0, .miss = 0, .played = 5, .cleared = 2, .date = 1, .source = "LR2" };
    try recordScore(d, imported);
    try recordScore(d, imported);
    var local = imported;
    local.played = 1;
    local.cleared = 1;
    local.source = "";
    try recordScore(d, local);
    const st = try d.prepare("SELECT playcount,clearcount,source FROM score");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 6), st.int(0));
    try std.testing.expectEqual(@as(i64, 3), st.int(1));
    try std.testing.expectEqualStrings("LR2", st.text(2));
}

test "pruning keeps the newest replays and the best one" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try initSchema(d);
    try d.exec("INSERT INTO replay(id,sha256,date,ex,clear) VALUES(1,'a',1,1,1),(2,'a',2,99,1),(3,'a',3,1,1),(4,'a',4,1,1),(5,'a',5,1,1),(6,'a',6,1,1),(7,'a',7,1,1),(8,'b',1,1,1)");
    try pruneReplays(d, "a");
    const st = try d.prepare("SELECT group_concat(id) FROM (SELECT id FROM replay ORDER BY id)");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("2,4,5,6,7,8", st.text(0));
}

test "a scan leaves the database free for other writers between batches" {
    const gpa = std.testing.allocator;
    fs.io = std.testing.io;
    const path = "actuon_test_scan.db";
    fs.remove(path);
    defer {
        fs.remove(path);
        fs.remove(path ++ "-wal");
        fs.remove(path ++ "-shm");
    }
    const d = try Db.open(path, gpa, false);
    defer d.close();
    try initSchema(d);
    const roots = [_][]const u8{"tests/charts"};
    _ = try scan(gpa, d, &roots, null);
    const other = try Db.open(path, gpa, false);
    defer other.close();
    try recordScore(other, .{ .sha256 = "a", .clear = 1, .ex = 1, .counts = @splat(0), .max_combo = 1, .miss = 0, .date = 1 });
}
