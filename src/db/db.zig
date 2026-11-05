const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");
pub const Watch = @import("watch.zig").Watch;

pub const Error = error{ Sqlite, OutOfMemory };

// SQLITE_TRANSIENT is the destructor -1, and zig rejects that as a misaligned function pointer on arm64.
const sqlite_transient: isize = -1;
extern fn sqlite3_bind_text(*c.sqlite3_stmt, c_int, [*]const u8, c_int, isize) c_int;
extern fn sqlite3_bind_blob(*c.sqlite3_stmt, c_int, [*]const u8, c_int, isize) c_int;

/// SQLite's LIKE folds ASCII only, so search compares `fold(column) LIKE fold(pattern)`.
fn foldSql(ctx: ?*c.sqlite3_context, _: c_int, argv: [*c]?*c.sqlite3_value) callconv(.c) void {
    const p = c.sqlite3_value_text(argv[0]);
    if (p == null) return c.sqlite3_result_null(ctx);
    const text = p[0..@intCast(c.sqlite3_value_bytes(argv[0]))];
    // One spare byte, as sqlite3_malloc64(0) may answer null.
    const out: [*]u8 = @ptrCast(c.sqlite3_malloc64(text.len + 1) orelse return c.sqlite3_result_error_nomem(ctx));
    foldCase(text, out[0..text.len]);
    c.sqlite3_result_text64(ctx, out, text.len, c.sqlite3_free, c.SQLITE_UTF8);
}

/// Every mapping keeps the UTF-8 length, so `out` is as long as `text`; bytes that are not UTF-8 pass through.
fn foldCase(text: []const u8, out: []u8) void {
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const r = if (i + n <= text.len) std.unicode.utf8Decode(text[i .. i + n]) catch null else null;
        if (r) |cp| {
            _ = std.unicode.utf8Encode(foldRune(cp), out[i .. i + n]) catch unreachable;
            i += n;
        } else {
            out[i] = text[i];
            i += 1;
        }
    }
}

/// Latin with accents, Greek, Cyrillic and full-width Latin; no ICU, so other scripts compare as written.
fn foldRune(r: u21) u21 {
    return switch (r) {
        'A'...'Z', 0xC0...0xD6, 0xD8...0xDE, 0x391...0x3A1, 0x3A3...0x3AB, 0x410...0x42F, 0xFF21...0xFF3A => r + 32,
        0x400...0x40F => r + 80,
        0x386 => 0x3AC,
        0x388...0x38A => r + 37,
        0x38C => 0x3CC,
        0x38E, 0x38F => r + 63,
        0x3C2 => 0x3C3,
        0x178 => 0xFF,
        0x4C0 => 0x4CF,
        0x100...0x12F, 0x132...0x137, 0x14A...0x177, 0x1A0, 0x1DE...0x1EF, 0x1F8...0x21F, 0x460...0x481, 0x48A...0x4BF, 0x4D0...0x52F, 0x1E00...0x1E95, 0x1EA0...0x1EFF => r | 1,
        0x139...0x148, 0x179...0x17E, 0x1AF, 0x1CD...0x1DC, 0x4C1...0x4CE => r + (r & 1),
        else => r,
    };
}

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
        const fn_flags = c.SQLITE_UTF8 | c.SQLITE_DETERMINISTIC | c.SQLITE_INNOCUOUS;
        if (c.sqlite3_create_function_v2(h, "fold", 1, fn_flags, null, foldSql, null, null, null) != c.SQLITE_OK) {
            _ = c.sqlite3_close(h);
            return error.Sqlite;
        }
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
    \\  difficulty INTEGER, mode INTEGER, notes INTEGER,
    \\  min_bpm REAL, max_bpm REAL, length_ms INTEGER, has_ln INTEGER,
    \\  stagefile TEXT, banner TEXT, preview TEXT, mtime INTEGER, size INTEGER, has_open_ln INTEGER DEFAULT 0);
    \\CREATE INDEX IF NOT EXISTS song_sha ON song(sha256);
    \\CREATE INDEX IF NOT EXISTS song_md5 ON song(md5);
    \\CREATE INDEX IF NOT EXISTS song_folder ON song(folder);
    \\CREATE TABLE IF NOT EXISTS score(
    \\  sha256 TEXT NOT NULL, mode INTEGER NOT NULL DEFAULT 0, clear INTEGER DEFAULT 0, ex INTEGER DEFAULT 0,
    \\  pg INTEGER DEFAULT 0, gr INTEGER DEFAULT 0, gd INTEGER DEFAULT 0, bd INTEGER DEFAULT 0, pr INTEGER DEFAULT 0, ms INTEGER DEFAULT 0,
    \\  max_combo INTEGER DEFAULT 0, min_bp INTEGER DEFAULT 2147483647, playcount INTEGER DEFAULT 0, clearcount INTEGER DEFAULT 0,
    \\  date INTEGER DEFAULT 0, assist INTEGER DEFAULT 0, PRIMARY KEY(sha256, mode));
    \\CREATE TABLE IF NOT EXISTS score_import(sha256 TEXT NOT NULL, mode INTEGER NOT NULL, source TEXT NOT NULL,
    \\  playcount INTEGER DEFAULT 0, clearcount INTEGER DEFAULT 0, PRIMARY KEY(sha256, mode, source));
    \\CREATE TABLE IF NOT EXISTS replay(id INTEGER PRIMARY KEY, sha256 TEXT, date INTEGER, ex INTEGER, clear INTEGER, data BLOB, ln_mode INTEGER NOT NULL DEFAULT 0,
    \\  max_combo INTEGER NOT NULL DEFAULT 0, miss INTEGER NOT NULL DEFAULT 2147483647);
    \\CREATE INDEX IF NOT EXISTS replay_sha ON replay(sha256);
    \\CREATE TABLE IF NOT EXISTS dir(path TEXT PRIMARY KEY, mtime INTEGER);
    \\CREATE TABLE IF NOT EXISTS unparsed(path TEXT PRIMARY KEY, mtime INTEGER, size INTEGER);
    \\CREATE TABLE IF NOT EXISTS bms_table(url TEXT PRIMARY KEY, name TEXT, symbol TEXT);
    \\CREATE TABLE IF NOT EXISTS table_song(url TEXT, level TEXT, ord INTEGER, md5 TEXT, sha256 TEXT, title TEXT, artist TEXT, zip_url TEXT);
    \\CREATE INDEX IF NOT EXISTS table_song_url ON table_song(url, ord);
    \\CREATE INDEX IF NOT EXISTS table_song_md5 ON table_song(md5);
    \\CREATE INDEX IF NOT EXISTS table_song_sha ON table_song(sha256);
    \\CREATE TABLE IF NOT EXISTS course(id INTEGER PRIMARY KEY, table_url TEXT, name TEXT, hashes TEXT, constraints TEXT, UNIQUE(table_url, name));
    \\CREATE TABLE IF NOT EXISTS course_score(course_id INTEGER, clear INTEGER, ex INTEGER, PRIMARY KEY(course_id));
    \\CREATE TABLE IF NOT EXISTS favorite(sha256 TEXT PRIMARY KEY);
    \\CREATE TEMP TABLE IF NOT EXISTS play_setting(ln_mode INTEGER NOT NULL);
    \\INSERT INTO play_setting SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM play_setting);
;

fn hasColumn(d: Db, table: []const u8, column: []const u8) !bool {
    var buf: [64]u8 = undefined;
    const st = try d.prepare(try std.fmt.bufPrint(&buf, "PRAGMA table_info({s})", .{table}));
    defer st.deinit();
    while (try st.step()) if (std.mem.eql(u8, st.text(1), column)) return true;
    return false;
}

/// Before CN and HCN had own scores, every row was an LN play; charts are reread to learn which leave LN type open.
fn migrateLnModes(d: Db) !void {
    if (try hasColumn(d, "score", "mode")) return;
    try d.exec("BEGIN IMMEDIATE");
    errdefer d.exec("ROLLBACK") catch {};
    try d.exec(
        \\ALTER TABLE score RENAME TO score_v0;
        \\CREATE TABLE score(
        \\  sha256 TEXT NOT NULL, mode INTEGER NOT NULL DEFAULT 0, clear INTEGER DEFAULT 0, ex INTEGER DEFAULT 0,
        \\  pg INTEGER DEFAULT 0, gr INTEGER DEFAULT 0, gd INTEGER DEFAULT 0, bd INTEGER DEFAULT 0, pr INTEGER DEFAULT 0, ms INTEGER DEFAULT 0,
        \\  max_combo INTEGER DEFAULT 0, min_bp INTEGER DEFAULT 2147483647, playcount INTEGER DEFAULT 0, clearcount INTEGER DEFAULT 0,
        \\  date INTEGER DEFAULT 0, source TEXT DEFAULT '', PRIMARY KEY(sha256, mode));
        \\INSERT INTO score(sha256,clear,ex,pg,gr,gd,bd,pr,ms,max_combo,min_bp,playcount,clearcount,date,source)
        \\ SELECT sha256,clear,ex,pg,gr,gd,bd,pr,ms,max_combo,min_bp,playcount,clearcount,date,source FROM score_v0;
        \\DROP TABLE score_v0;
    );
    if (!try hasColumn(d, "replay", "ln_mode")) try d.exec("ALTER TABLE replay ADD COLUMN ln_mode INTEGER NOT NULL DEFAULT 0");
    if (!try hasColumn(d, "song", "has_open_ln")) {
        try d.exec("ALTER TABLE song ADD COLUMN has_open_ln INTEGER DEFAULT 0; UPDATE song SET mtime=0 WHERE has_ln=1");
    }
    try d.exec("COMMIT");
}

pub fn initSchema(d: Db) !void {
    try d.exec(schema);
    try migrateLnModes(d);
    if (!try hasColumn(d, "score", "assist")) try d.exec("ALTER TABLE score ADD COLUMN assist INTEGER DEFAULT 0");
    // Older replays get the "no play" combo and BP, so IR sync never sends one for an improvement it cannot know.
    if (!try hasColumn(d, "replay", "max_combo")) try d.exec("ALTER TABLE replay ADD COLUMN max_combo INTEGER NOT NULL DEFAULT 0");
    if (!try hasColumn(d, "replay", "miss")) try d.exec("ALTER TABLE replay ADD COLUMN miss INTEGER NOT NULL DEFAULT 2147483647");
    try labelReplayModes(d);
    // An old row names only its last import, which takes the whole count; any earlier source adds its counts once more on its next import, as the old DB never kept them.
    if (try hasColumn(d, "score", "source")) {
        try d.exec("INSERT OR IGNORE INTO score_import(sha256,mode,source,playcount,clearcount) SELECT sha256,mode,source,playcount,clearcount FROM score WHERE source<>''");
    }
    try dropUnusedColumns(d);
}

/// Rescans refill these chart facts and score_import holds what score.source told; judge counts and clearcount stay, as no file could give them back.
fn dropUnusedColumns(d: Db) !void {
    const gone = [_][2][]const u8{
        .{ "song", "total" },           .{ "song", "judgerank" },    .{ "song", "has_mine" }, .{ "song", "has_random" },
        .{ "table_song", "name_diff" }, .{ "bms_table", "fetched" }, .{ "favorite", "date" }, .{ "course_score", "date" },
        .{ "score", "source" },
    };
    var buf: [64]u8 = undefined;
    for (gone) |g| {
        if (!try hasColumn(d, g[0], g[1])) continue;
        // DROP COLUMN needs SQLite 3.35; on an older system library the column stays, unread.
        d.exec(try std.fmt.bufPrintSentinel(&buf, "ALTER TABLE {s} DROP COLUMN {s}", .{ g[0], g[1] }, 0)) catch |e|
            std.log.warn("left unused column {s}.{s}: {t}", .{ g[0], g[1], e });
    }
}

/// Once per database: a beta filed every replay as LN, so each is labelled from the byte after its gauge (core.replay.encode).
fn labelReplayModes(d: Db) !void {
    const version = try d.prepare("PRAGMA user_version");
    const done = (try version.step()) and version.int(0) >= 1;
    version.deinit();
    if (done) return;
    try d.exec("BEGIN IMMEDIATE");
    errdefer d.exec("ROLLBACK") catch {};
    try d.exec("UPDATE replay SET ln_mode=CASE WHEN hex(substr(data,71,1))>='80' THEN 2 WHEN hex(substr(data,71,1))>='40' THEN 1 ELSE 0 END WHERE data IS NOT NULL");
    try d.exec("PRAGMA user_version=1");
    try d.exec("COMMIT");
}

pub fn setLnMode(d: Db, mode: u8) !void {
    const st = try d.prepare("UPDATE temp.play_setting SET ln_mode=?1");
    defer st.deinit();
    st.bindInt(1, mode);
    _ = try st.step();
}

pub fn openMain(gpa: std.mem.Allocator) !Db {
    const dir = try fs.dataDir(gpa);
    defer gpa.free(dir);
    const p = try std.fmt.allocPrint(gpa, "{s}actuon.db", .{dir});
    defer gpa.free(p);
    const d = try Db.open(p, gpa, false);
    errdefer d.close();
    try initSchema(d);
    return d;
}

pub const chart_exts = [_][]const u8{ ".bms", ".bme", ".bml", ".pms", ".bmson" };

fn isChart(name: []const u8) bool {
    for (chart_exts) |e| if (std.ascii.endsWithIgnoreCase(name, e)) return true;
    return false;
}

pub const ScanStats = struct { parsed: u32 = 0, removed: u32 = 0, failed: u32 = 0 };

/// Bounds memory, as parsed charts wait in memory for their insert.
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
    io: std.Io,
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
        job.bytes = fs.readAlloc(w.gpa, w.io, job.path, 1 << 26) catch continue;
        job.chart = core.parse(w.gpa, .of(job.path), job.bytes, .{}) catch continue;
        if (w.progress) |p| _ = p.fetchAdd(1, .monotonic);
    }
}

/// The scan parses one #RANDOM branch, and LN in another counts too: a CN play there must not land in the LN row.
fn mayOpenLn(chart: *const core.types.Chart, bytes: []const u8) bool {
    for (chart.notes) |n| if (n.ln_open) return true;
    if (!chart.has_random) return false;
    // Erring towards open only keeps more plays apart by LN mode.
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |l| {
        if (std.ascii.startsWithIgnoreCase(l, "#LNOBJ")) return true;
        if (l.len > 6 and l[0] == '#' and std.ascii.isDigit(l[1]) and std.ascii.isDigit(l[2]) and std.ascii.isDigit(l[3]) and (l[4] == '5' or l[4] == '6')) return true;
    }
    return false;
}

/// Parses on every core; the inserts stay on this thread, which owns the connection.
fn insertBatch(gpa: std.mem.Allocator, io: std.Io, d: Db, ins: anytype, jobs: []ScanJob, stats: *ScanStats, progress: ?*std.atomic.Value(u32)) !void {
    var work: ScanWork = .{ .gpa = gpa, .io = io, .jobs = jobs, .progress = progress };
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
    const unparsed = try d.prepare("INSERT OR REPLACE INTO unparsed(path,mtime,size) VALUES(?1,?2,?3)");
    defer unparsed.deinit();
    for (jobs) |*job| {
        const chart = &(job.chart orelse {
            std.log.warn("not a chart this player can read: {s}", .{job.path});
            unparsed.bindText(1, job.path);
            unparsed.bindInt(2, job.mtime);
            unparsed.bindInt(3, @intCast(job.size));
            _ = try unparsed.step();
            unparsed.reset();
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
        ins.bindFloat(14, chart.min_bpm);
        ins.bindFloat(15, chart.max_bpm);
        ins.bindInt(16, @divTrunc(chart.last_time_us, 1000));
        ins.bindInt(17, @intFromBool(chart.has_ln));
        ins.bindText(18, chart.stagefile);
        ins.bindText(19, chart.banner);
        ins.bindText(20, chart.preview);
        ins.bindInt(21, job.mtime);
        ins.bindInt(22, @intCast(job.size));
        ins.bindInt(23, @intFromBool(mayOpenLn(chart, job.bytes)));
        _ = try ins.step();
        ins.reset();
        stats.parsed += 1;
    }
    try d.exec("COMMIT");
}

const Walk = struct { dir: []const u8, deep: bool };

pub fn scan(gpa: std.mem.Allocator, io: std.Io, d: Db, roots: []const []const u8, progress: ?*std.atomic.Value(u32), watch: ?*Watch) !ScanStats {
    var stats: ScanStats = .{};
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    // The watch has handed over its changes, and a scan that stops short would lose them.
    errdefer if (watch) |w| {
        w.lost = true;
    };

    const known = try d.prepare("SELECT mtime, size FROM song WHERE path=?1 UNION ALL SELECT mtime, size FROM unparsed WHERE path=?1 LIMIT 1");
    defer known.deinit();
    const ins = try d.prepare(
        \\INSERT OR REPLACE INTO song(path,folder,sha256,md5,title,subtitle,artist,subartist,genre,level,difficulty,mode,notes,min_bpm,max_bpm,length_ms,has_ln,stagefile,banner,preview,mtime,size,has_open_ln)
        \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23)
    );
    defer ins.deinit();

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var batch: std.ArrayList(ScanJob) = .empty;
    var stack: std.ArrayList(Walk) = .empty;
    var unread: std.ArrayList([]const u8) = .empty;
    // Charts not seen lose their rows: every one under a tree, and those directly in a flat folder.
    var trees: std.ArrayList([]const u8) = .empty;
    var flat: std.ArrayList([]const u8) = .empty;
    // Real paths of listed folders: links like `a -> .` would otherwise branch until ELOOP.
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    const outer = try outerRoots(aa, roots);
    if (if (watch) |w| try w.changed(aa, outer) else null) |dirs| {
        // Before any walk: a folder now under the same name, or moved into another watched one, must be walked afresh.
        for (dirs.keys(), dirs.values()) |dir, gone| {
            if (!gone) {
                try stack.append(aa, .{ .dir = dir, .deep = false });
            } else if (watch.?.watched(dir)) {
                watch.?.drop(dir);
                try trees.append(aa, dir);
            }
        }
    } else for (outer) |r| {
        try stack.append(aa, .{ .dir = r, .deep = true });
        try trees.append(aa, r);
    }
    while (stack.pop()) |job| {
        const dir = job.dir;
        if (job.deep) {
            const real = fs.realPath(aa, io, dir) catch dir;
            if ((try visited.getOrPut(aa, real)).found_existing) continue;
            if (watch) |w| {
                if (w.has(real)) continue;
                try w.add(dir, real);
            }
        }
        var it = std.heap.ArenaAllocator.init(gpa);
        defer it.deinit();
        const a = it.allocator();
        const entries = fs.listChecked(a, io, dir) catch |e| {
            // A changed folder that is gone shows as missing from its parent's listing.
            if (job.deep or e != error.FileNotFound) std.log.warn("cannot read {s}: {t}", .{ dir, e });
            if (job.deep) try unread.append(aa, dir);
            continue;
        };
        if (!job.deep) {
            const w = watch.?;
            try flat.append(aa, dir);
            for (try w.children(aa, dir)) |child| {
                const name = std.fs.path.basename(child);
                for (entries) |e| {
                    if (e.is_dir and std.mem.eql(u8, e.name, name)) break;
                } else {
                    w.drop(child);
                    try trees.append(aa, child);
                }
            }
        }
        for (entries) |e| {
            const full = try std.fs.path.join(aa, &.{ dir, e.name });
            if (e.is_dir) {
                if (e.name.len == 0 or e.name[0] == '.') continue;
                if (job.deep) {
                    try stack.append(aa, .{ .dir = full, .deep = true });
                } else if (!watch.?.watched(full)) {
                    try stack.append(aa, .{ .dir = full, .deep = true });
                    try trees.append(aa, full);
                }
                continue;
            }
            if (!isChart(e.name)) continue;
            // A changed folder may also be walked from its parent's listing.
            if ((try seen.getOrPut(aa, full)).found_existing) continue;
            const st = fs.stat(io, full) orelse continue;
            known.bindText(1, full);
            const hit = try known.step();
            const same = hit and known.int(0) == st.mtime and known.int(1) == @as(i64, @intCast(st.size));
            known.reset();
            if (same) continue;
            try batch.append(aa, .{ .path = full, .folder = dir, .mtime = st.mtime, .size = st.size });
            if (batch.items.len == scan_batch) {
                try insertBatch(gpa, io, d, ins, batch.items, &stats, progress);
                batch.clearRetainingCapacity();
            }
        }
    }
    try insertBatch(gpa, io, d, ins, batch.items, &stats, progress);
    try d.exec("BEGIN IMMEDIATE");
    errdefer d.exec("ROLLBACK") catch {};
    // A tree inside another adds nothing, and deleting a pack reports every folder in it.
    for (trees.items) |dir| {
        for (trees.items) |outer_tree| {
            if (isUnder(dir, outer_tree)) break;
        } else try dropUnseen(d, aa, dir, false, &seen, unread.items, &stats);
    }
    for (flat.items) |dir| try dropUnseen(d, aa, dir, true, &seen, unread.items, &stats);
    try d.exec("COMMIT");
    return stats;
}

/// A folder that could not be read keeps its rows, so an unplugged library does not vanish.
fn dropUnseen(d: Db, a: std.mem.Allocator, dir: []const u8, direct: bool, seen: *const std.StringHashMapUnmanaged(void), unread: []const []const u8, stats: *ScanStats) !void {
    const unparsed = " UNION ALL SELECT path, 1 FROM unparsed WHERE path LIKE ?1 ESCAPE '\\'";
    // By folder, which is indexed, where it can: a LIKE reads the whole table.
    const sel = try d.prepare(if (direct) "SELECT path, 0 FROM song WHERE folder=?2" ++ unparsed else "SELECT path, 0 FROM song WHERE path LIKE ?1 ESCAPE '\\'" ++ unparsed);
    defer sel.deinit();
    const del = try d.prepare("DELETE FROM song WHERE path=?1");
    defer del.deinit();
    const forget = try d.prepare("DELETE FROM unparsed WHERE path=?1");
    defer forget.deinit();
    sel.bindText(1, try likePrefix(a, dir));
    if (direct) sel.bindText(2, dir);
    while (try sel.step()) {
        const path = sel.text(0);
        if (!isUnder(path, dir) or seen.contains(path)) continue;
        if (direct and !isDirectlyIn(path, dir)) continue;
        for (unread) |u| {
            if (isUnder(path, u)) break;
        } else {
            const chart = sel.int(1) == 0;
            const st = if (chart) del else forget;
            st.bindText(1, path);
            _ = try st.step();
            st.reset();
            if (chart) stats.removed += 1;
        }
    }
}

/// Else a folder added inside another root would be scanned and listed twice.
pub fn outerRoots(a: std.mem.Allocator, roots: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (roots, 0..) |r, i| {
        const held = for (roots, 0..) |o, j| {
            if (isUnder(r, o) or (j < i and std.mem.eql(u8, r, o))) break true;
        } else false;
        if (!held) try out.append(a, r);
    }
    return out.toOwnedSlice(a);
}

pub fn holds(dir: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, dir, path) or isUnder(path, dir);
}

/// A whole folder name must match: /mnt/bms does not hold /mnt/bms2/a.bms.
pub fn isUnder(path: []const u8, dir: []const u8) bool {
    if (dir.len == 0 or path.len <= dir.len or !std.mem.startsWith(u8, path, dir)) return false;
    return std.fs.path.isSep(dir[dir.len - 1]) or std.fs.path.isSep(path[dir.len]);
}

/// Right inside `dir`, not deeper; a root may end in a separator, so dirname would not match it.
pub fn isDirectlyIn(path: []const u8, dir: []const u8) bool {
    if (!isUnder(path, dir)) return false;
    var rest = path[dir.len..];
    while (rest.len > 0 and std.fs.path.isSep(rest[0])) rest = rest[1..];
    for (rest) |ch| if (std.fs.path.isSep(ch)) return false;
    return true;
}

pub fn likePrefix(a: std.mem.Allocator, prefix: []const u8) ![]u8 {
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
    has_open_ln: bool = false,
    favorite: bool = false,
    stagefile: []const u8,
    banner: []const u8,
    preview: []const u8,
    clear: u8,
    ex: u32,
    miss: i64,
    played: u32,
    table_level: []const u8 = "",

    /// A table's level says more than the number the chart's author chose.
    pub fn shownLevel(s: Song) []const u8 {
        return if (s.table_level.len > 0) s.table_level else s.level;
    }
};

/// The lamp shown for score row `c`: an assist lamp counts here, never in `clear`, which IR sync claims from.
pub const lamp = "MAX(COALESCE(c.clear,0),COALESCE(c.assist,0))";

pub const song_select =
    \\SELECT s.path,s.folder,s.sha256,s.md5,s.title,s.subtitle,s.artist,s.genre,s.level,s.difficulty,s.mode,s.notes,s.min_bpm,s.max_bpm,s.length_ms,s.has_ln,s.stagefile,s.banner,s.preview,
++ "\n " ++ lamp ++ ",COALESCE(c.ex,0),COALESCE(NULLIF(c.min_bp,2147483647),-1),COALESCE(c.playcount,0),\n" ++
    \\ (SELECT COALESCE(b.symbol,'')||t.level FROM table_song t JOIN bms_table b ON b.url=t.url
    \\  WHERE (t.md5=s.md5 AND t.md5<>'') OR (t.sha256=s.sha256 AND t.sha256<>'') ORDER BY b.name LIMIT 1),
    \\ COALESCE(s.has_open_ln,0),
    \\ EXISTS(SELECT 1 FROM favorite f WHERE f.sha256=s.sha256)
    \\ FROM song s LEFT JOIN score c ON c.sha256=s.sha256 AND c.mode=CASE WHEN s.has_open_ln THEN (SELECT ln_mode FROM temp.play_setting) ELSE 0 END
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
        // Imports clamp each count, but later plays and imports add to it past u32.
        .played = std.math.lossyCast(u32, st.int(22)),
        .table_level = try dup(a, st, 23),
        .has_open_ln = st.int(24) != 0,
        .favorite = st.int(25) != 0,
    };
}

/// By chart hash, so a favorite survives moving the files.
pub fn toggleFavorite(d: Db, sha256: []const u8) !bool {
    const del = try d.prepare("DELETE FROM favorite WHERE sha256=?1");
    defer del.deinit();
    del.bindText(1, sha256);
    _ = try del.step();
    if (c.sqlite3_changes(d.h) > 0) return false;
    const ins = try d.prepare("INSERT INTO favorite(sha256) VALUES(?1)");
    defer ins.deinit();
    ins.bindText(1, sha256);
    _ = try ins.step();
    return true;
}

/// Replays offered per chart, as beatoraja's slots.
pub const max_replays = 4;

/// Drops replays nothing can reach: the song select's newest ones, and the best EX, lamp, combo and BP IR sync uploads.
pub fn pruneReplays(d: Db, sha256: []const u8, ln_mode: u8) !void {
    const st = try d.prepare(
        \\DELETE FROM replay WHERE sha256=?1 AND ln_mode=?3
        \\ AND id NOT IN (SELECT id FROM replay WHERE sha256=?1 AND ln_mode=?3 ORDER BY date DESC, id DESC LIMIT ?2)
        \\ AND id NOT IN (SELECT id FROM replay WHERE sha256=?1 AND ln_mode=?3 ORDER BY ex DESC, clear DESC LIMIT 1)
        \\ AND id NOT IN (SELECT id FROM replay WHERE sha256=?1 AND ln_mode=?3 ORDER BY clear DESC, ex DESC LIMIT 1)
        \\ AND id NOT IN (SELECT id FROM replay WHERE sha256=?1 AND ln_mode=?3 ORDER BY max_combo DESC, ex DESC LIMIT 1)
        \\ AND id NOT IN (SELECT id FROM replay WHERE sha256=?1 AND ln_mode=?3 ORDER BY miss, ex DESC LIMIT 1)
    );
    defer st.deinit();
    st.bindText(1, sha256);
    st.bindInt(2, max_replays);
    st.bindInt(3, ln_mode);
    _ = try st.step();
}

pub const ScoreIn = struct {
    sha256: []const u8,
    /// 0 LN, 1 CN, 2 HCN. A chart that sets its own LN type is always 0, as in beatoraja.
    mode: u8 = 0,
    clear: u8,
    ex: u32,
    counts: [6]u32,
    max_combo: u32,
    miss: u32,
    played: u32 = 1,
    cleared: u32 = 0,
    date: i64,
    source: []const u8 = "",
    /// The lamp of an assisted play: shown in the list, never in `clear`, which IR sync claims from.
    assist: u8 = 0,
};

/// The list reads the asked mode's row for a chart any #RANDOM branch may leave open, so a play there is filed as asked.
/// Elsewhere it is filed as played, which keeps a CN or HCN judged play out of the LN row the IR claims from.
pub fn scoreMode(d: Db, sha256: []const u8, asked: u8, played: u8) !u8 {
    const st = try d.prepare("SELECT CASE WHEN EXISTS(SELECT 1 FROM song WHERE sha256=?1 AND has_open_ln) THEN ?2 ELSE ?3 END");
    defer st.deinit();
    st.bindText(1, sha256);
    st.bindInt(2, asked);
    st.bindInt(3, played);
    _ = try st.step();
    return @intCast(st.int(0));
}

/// As beatoraja's ScoreData.update. An import adds only the plays and clears its source gained since it was last imported.
pub fn recordScore(d: Db, s: ScoreIn) !void {
    var played: i64 = s.played;
    var cleared: i64 = s.cleared;
    if (s.source.len > 0) {
        const prev = try d.prepare("SELECT playcount,clearcount FROM score_import WHERE sha256=?1 AND mode=?2 AND source=?3");
        defer prev.deinit();
        prev.bindText(1, s.sha256);
        prev.bindInt(2, s.mode);
        prev.bindText(3, s.source);
        if (try prev.step()) {
            played = @max(played - prev.int(0), 0);
            cleared = @max(cleared - prev.int(1), 0);
        }
        const keep = try d.prepare(
            \\INSERT INTO score_import(sha256,mode,source,playcount,clearcount) VALUES(?1,?2,?3,?4,?5)
            \\ON CONFLICT(sha256,mode,source) DO UPDATE SET playcount=MAX(playcount,excluded.playcount), clearcount=MAX(clearcount,excluded.clearcount)
        );
        defer keep.deinit();
        keep.bindText(1, s.sha256);
        keep.bindInt(2, s.mode);
        keep.bindText(3, s.source);
        keep.bindInt(4, s.played);
        keep.bindInt(5, s.cleared);
        _ = try keep.step();
    }
    const st = try d.prepare(
        \\INSERT INTO score(sha256,clear,ex,pg,gr,gd,bd,pr,ms,max_combo,min_bp,playcount,clearcount,date,mode,assist)
        \\VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)
        \\ON CONFLICT(sha256,mode) DO UPDATE SET
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
        \\ playcount=playcount+excluded.playcount,
        \\ clearcount=clearcount+excluded.clearcount,
        \\ date=MAX(date,excluded.date),
        \\ assist=MAX(assist,excluded.assist)
    );
    defer st.deinit();
    st.bindText(1, s.sha256);
    st.bindInt(2, s.clear);
    st.bindInt(3, s.ex);
    for (s.counts, 0..) |v, i| st.bindInt(@intCast(4 + i), v);
    st.bindInt(10, s.max_combo);
    st.bindInt(11, s.miss);
    st.bindInt(12, played);
    st.bindInt(13, cleared);
    st.bindInt(14, s.date);
    st.bindInt(15, s.mode);
    st.bindInt(16, s.assist);
    _ = try st.step();
}

pub const ImportStats = struct { imported: u32 = 0, skipped: u32 = 0 };

/// The source is opened read-only.
pub fn importBeatoraja(gpa: std.mem.Allocator, d: Db, path: []const u8) !ImportStats {
    const src = try Db.open(path, gpa, true);
    defer src.close();
    const st = try src.prepare("SELECT sha256,clear,epg,lpg,egr,lgr,egd,lgd,ebd,lbd,epr,lpr,ems,lms,combo,minbp,playcount,clearcount,date,mode FROM score WHERE mode IN (0,1,2)");
    defer st.deinit();
    var stats: ImportStats = .{};
    // IMMEDIATE: recordScore reads score_import before it writes, and SQLite will not wait to turn a read into a write.
    try d.exec("BEGIN IMMEDIATE");
    errdefer d.exec("ROLLBACK") catch {};
    // The file is untrusted: clamp every count instead of trapping on -1 or overflow.
    const lossy = std.math.lossyCast;
    while (try st.step()) {
        const pg = st.int(2) +| st.int(3);
        const gr = st.int(4) +| st.int(5);
        try recordScore(d, .{
            .sha256 = st.text(0),
            .mode = @intCast(st.int(19)),
            .clear = @intCast(std.math.clamp(st.int(1), 0, 10)),
            .ex = lossy(u32, @max(pg, 0) *| 2 +| @max(gr, 0)),
            .counts = .{ lossy(u32, pg), lossy(u32, gr), lossy(u32, st.int(6) +| st.int(7)), lossy(u32, st.int(8) +| st.int(9)), lossy(u32, st.int(10) +| st.int(11)), lossy(u32, st.int(12) +| st.int(13)) },
            .max_combo = lossy(u32, st.int(14)),
            .miss = lossy(u32, st.int(15)),
            .played = lossy(u32, st.int(16)),
            .cleared = lossy(u32, st.int(17)),
            .date = st.int(18),
            .source = "beatoraja",
        });
        stats.imported += 1;
    }
    try d.exec("COMMIT");
    return stats;
}

/// LR2 keys scores by MD5, so unscanned charts are skipped, as in ScoreDataImporter.
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
    // IMMEDIATE: it reads before it writes, and SQLite will not wait to turn a read into a write.
    try d.exec("BEGIN IMMEDIATE");
    errdefer d.exec("ROLLBACK") catch {};
    while (try st.step()) {
        look.bindText(1, col.hash(st));
        defer look.reset();
        if (!try look.step()) {
            stats.skipped += 1;
            continue;
        }
        const clear_i: usize = @intCast(std.math.clamp(col.f(st, "clear"), 0, clears.len - 1));
        const pg = @max(col.f(st, "perfect"), 0);
        const gr = @max(col.f(st, "great"), 0);
        const lossy = std.math.lossyCast;
        try recordScore(d, .{
            .sha256 = look.text(0),
            .clear = clears[clear_i],
            .ex = lossy(u32, pg *| 2 +| gr),
            .counts = .{ lossy(u32, pg), lossy(u32, gr), lossy(u32, col.f(st, "good")), lossy(u32, col.f(st, "bad")), lossy(u32, col.f(st, "poor")), 0 },
            .max_combo = lossy(u32, col.f(st, "maxcombo")),
            .miss = lossy(u32, col.f(st, "minbp")),
            .played = lossy(u32, col.f(st, "playcount")),
            .cleared = lossy(u32, col.f(st, "clearcount")),
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
    const lr2 = "actuon_test_lr2.db";
    fs.remove(std.testing.io, lr2);
    defer fs.remove(std.testing.io, lr2);
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
    const first = try scan(gpa, std.testing.io, d, &roots, null, null);
    try std.testing.expect(first.parsed > 0);
    const count = try d.prepare("SELECT COUNT(*) FROM song");
    defer count.deinit();
    try std.testing.expect(try count.step());
    try std.testing.expectEqual(@as(i64, first.parsed), count.int(0));
    try std.testing.expectEqual(@as(u32, 0), (try scan(gpa, std.testing.io, d, &roots, null, null)).parsed);
}

test "a root inside another, or added twice, is scanned once" {
    const a = std.testing.allocator;
    const outer = try outerRoots(a, &.{ "/bms/pack", "/bms", "/bms2", "/bms" });
    defer a.free(outer);
    try std.testing.expectEqual(@as(usize, 2), outer.len);
    try std.testing.expectEqualStrings("/bms", outer[0]);
    try std.testing.expectEqualStrings("/bms2", outer[1]);
}

test "a scan drops gone charts only in folders it could read" {
    const gpa = std.testing.allocator;
    const root = "actuon_test_roots";
    fs.removeTree(std.testing.io, root);
    defer fs.removeTree(std.testing.io, root);
    try fs.mkdirs(std.testing.io, root ++ "/bms");
    try fs.mkdirs(std.testing.io, root ++ "/bms2");
    try fs.write(std.testing.io, root ++ "/file", "not a folder");
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try initSchema(d);
    try d.exec("INSERT INTO song(path,folder,sha256,md5,mtime,size) VALUES('" ++ root ++ "/bms/gone.bms','','a','a',0,0),('" ++ root ++ "/bms2/kept.bms','','b','b',0,0),('" ++ root ++ "/file/kept.bms','','c','c',0,0)");
    const roots = [_][]const u8{ root ++ "/bms", root ++ "/file" };
    try std.testing.expectEqual(@as(u32, 1), (try scan(gpa, std.testing.io, d, &roots, null, null)).removed);
    const st = try d.prepare("SELECT COUNT(*) FROM song WHERE path LIKE '%kept.bms'");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 2), st.int(0));
}

test "an old database drops the columns nothing reads and keeps its rows" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try d.exec(
        \\CREATE TABLE song(path TEXT PRIMARY KEY, folder TEXT NOT NULL, sha256 TEXT NOT NULL, md5 TEXT NOT NULL, title TEXT, total REAL, judgerank INTEGER, has_mine INTEGER, has_random INTEGER);
        \\CREATE TABLE table_song(url TEXT, level TEXT, ord INTEGER, md5 TEXT, sha256 TEXT, title TEXT, artist TEXT, zip_url TEXT, name_diff TEXT);
        \\INSERT INTO song(path,folder,sha256,md5,title,total) VALUES('p','f','s','m','kept',300);
        \\INSERT INTO table_song(url,title,name_diff) VALUES('u','kept','x');
        \\CREATE TABLE favorite(sha256 TEXT PRIMARY KEY, date INTEGER);
        \\INSERT INTO favorite VALUES('s', 5);
    );
    try initSchema(d);
    for ([_][2][]const u8{ .{ "song", "total" }, .{ "song", "has_random" }, .{ "table_song", "name_diff" }, .{ "favorite", "date" } }) |g| try std.testing.expect(!try hasColumn(d, g[0], g[1]));
    try std.testing.expect(try hasColumn(d, "song", "title"));
    try std.testing.expect(try hasColumn(d, "score", "clearcount"));
    try std.testing.expect(try hasColumn(d, "score", "pg"));
    try std.testing.expect(!try toggleFavorite(d, "s")); // still a favorite, so this takes it off
    const st = try d.prepare("SELECT (SELECT title FROM song) || (SELECT title FROM table_song)");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("keptkept", st.text(0));
}

test "a chart that fails to parse is read once, then again only when it changes, and forgotten when gone" {
    const gpa = std.testing.allocator;
    const root = "actuon_test_unparsed";
    fs.removeTree(std.testing.io, root);
    defer fs.removeTree(std.testing.io, root);
    try fs.mkdirs(std.testing.io, root);
    try fs.write(std.testing.io, root ++ "/broken.bmson", "{");
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try initSchema(d);
    try std.testing.expectEqual(@as(u32, 1), (try scan(gpa, std.testing.io, d, &.{root}, null, null)).failed);
    try std.testing.expectEqual(@as(u32, 0), (try scan(gpa, std.testing.io, d, &.{root}, null, null)).failed);
    try fs.write(std.testing.io, root ++ "/broken.bmson", "{\"");
    try std.testing.expectEqual(@as(u32, 1), (try scan(gpa, std.testing.io, d, &.{root}, null, null)).failed);
    fs.remove(std.testing.io, root ++ "/broken.bmson");
    _ = try scan(gpa, std.testing.io, d, &.{root}, null, null);
    const st = try d.prepare("SELECT COUNT(*) FROM unparsed");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.int(0));
}

test "a scan through links back to the root ends and stores each chart once" {
    const gpa = std.testing.allocator;
    const root = "actuon_test_loop";
    fs.removeTree(std.testing.io, root);
    defer fs.removeTree(std.testing.io, root);
    try fs.mkdirs(std.testing.io, root);
    const chart = try fs.readAlloc(gpa, std.testing.io, "tests/charts/five_key.bms", 1 << 20);
    defer gpa.free(chart);
    try fs.write(std.testing.io, root ++ "/song.bms", chart);
    try std.Io.Dir.cwd().symLink(std.testing.io, ".", root ++ "/a", .{ .is_directory = true });
    try std.Io.Dir.cwd().symLink(std.testing.io, ".", root ++ "/b", .{ .is_directory = true });
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try initSchema(d);
    try std.testing.expectEqual(@as(u32, 1), (try scan(gpa, std.testing.io, d, &.{root}, null, null)).parsed);
    const st = try d.prepare("SELECT COUNT(*) FROM song");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 1), st.int(0));
}

test "imports clamp negative and huge counts instead of trapping" {
    const gpa = std.testing.allocator;
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try d.exec(schema);
    try d.exec("INSERT INTO song(path,folder,sha256,md5) VALUES('p','f','shaL','md5L')");
    const files = [_][]const u8{ "actuon_test_clamp_bo.db", "actuon_test_clamp_lr2.db" };
    const tables = [_][:0]const u8{
        "CREATE TABLE score(sha256 TEXT,clear INT,epg INT,lpg INT,egr INT,lgr INT,egd INT,lgd INT,ebd INT,lbd INT,epr INT,lpr INT,ems INT,lms INT,combo INT,minbp INT,playcount INT,clearcount INT,date INT,mode INT);" ++
            "INSERT INTO score VALUES('shaB',5,9223372036854775807,1,-5,0,0,0,0,0,0,0,0,0,-1,-1,-1,-1,0,0)",
        "CREATE TABLE score(hash TEXT,clear INT,perfect INT,great INT,good INT,bad INT,poor INT,minbp INT,playcount INT,clearcount INT);" ++
            "INSERT INTO score VALUES('md5L',4,-1,9999999999,0,0,0,-1,-1,-1)",
    };
    for (files, tables) |f, t| {
        fs.remove(std.testing.io, f);
        const src = try Db.open(f, gpa, false);
        try src.exec(t);
        src.close();
    }
    defer for (files) |f| fs.remove(std.testing.io, f);
    _ = try importBeatoraja(gpa, d, files[0]);
    _ = try importLr2(gpa, d, files[1]);
    const max: i64 = std.math.maxInt(u32);
    const want = [_]struct { []const u8, [4]i64 }{ .{ "shaB", .{ max, 0, max, 0 } }, .{ "shaL", .{ 0, max, max, 0 } } };
    const q = try d.prepare("SELECT pg,gr,ex,playcount FROM score WHERE sha256=?1");
    defer q.deinit();
    for (want) |w| {
        q.bindText(1, w[0]);
        defer q.reset();
        try std.testing.expect(try q.step());
        for (w[1], 0..) |v, i| try std.testing.expectEqual(v, q.int(@intCast(i)));
    }
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
    const st = try d.prepare("SELECT playcount,clearcount FROM score");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 6), st.int(0));
    try std.testing.expectEqual(@as(i64, 3), st.int(1));
}

test "alternating two imports adds each source's counts once, and only what it gained since" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    // A database from before score_import, whose row last took 5 plays from LR2.
    try d.exec(
        \\CREATE TABLE score(sha256 TEXT NOT NULL, mode INTEGER NOT NULL DEFAULT 0, clear INTEGER DEFAULT 0, ex INTEGER DEFAULT 0, pg INTEGER DEFAULT 0, gr INTEGER DEFAULT 0, gd INTEGER DEFAULT 0, bd INTEGER DEFAULT 0, pr INTEGER DEFAULT 0, ms INTEGER DEFAULT 0, max_combo INTEGER DEFAULT 0, min_bp INTEGER DEFAULT 2147483647, playcount INTEGER DEFAULT 0, clearcount INTEGER DEFAULT 0, date INTEGER DEFAULT 0, source TEXT DEFAULT '', PRIMARY KEY(sha256, mode));
        \\INSERT INTO score(sha256,playcount,clearcount,source) VALUES('a',5,2,'LR2');
    );
    try initSchema(d);
    try std.testing.expect(!try hasColumn(d, "score", "source"));
    var lr2: ScoreIn = .{ .sha256 = "a", .clear = 1, .ex = 1, .counts = @splat(0), .max_combo = 0, .miss = 0, .played = 5, .cleared = 2, .date = 1, .source = "LR2" };
    var bo = lr2;
    bo.played = 3;
    bo.cleared = 1;
    bo.source = "beatoraja";
    try recordScore(d, lr2);
    try recordScore(d, bo);
    try recordScore(d, lr2);
    try recordScore(d, bo);
    lr2.played = 7;
    try recordScore(d, lr2);
    const st = try d.prepare("SELECT playcount,clearcount FROM score");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 10), st.int(0));
    try std.testing.expectEqual(@as(i64, 3), st.int(1));
}

test "an old database's replays keep the LN mode written inside them" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try d.exec("CREATE TABLE score(sha256 TEXT PRIMARY KEY, clear INTEGER DEFAULT 0, ex INTEGER DEFAULT 0, pg INTEGER DEFAULT 0, gr INTEGER DEFAULT 0, gd INTEGER DEFAULT 0, bd INTEGER DEFAULT 0, pr INTEGER DEFAULT 0, ms INTEGER DEFAULT 0, max_combo INTEGER DEFAULT 0, min_bp INTEGER DEFAULT 2147483647, playcount INTEGER DEFAULT 0, clearcount INTEGER DEFAULT 0, date INTEGER DEFAULT 0, source TEXT DEFAULT ''); CREATE TABLE replay(id INTEGER PRIMARY KEY, sha256 TEXT, date INTEGER, ex INTEGER, clear INTEGER, data BLOB)");
    for ([_]core.options.LnMode{ .ln, .cn, .hcn }, 1..) |mode, id| {
        const bytes = try core.replay.encode(std.testing.allocator, .{ .ln_mode = mode, .random = @fromBackingInt(@intCast(1)) });
        defer std.testing.allocator.free(bytes);
        const ins = try d.prepare("INSERT INTO replay(id,data) VALUES(?1,?2)");
        defer ins.deinit();
        ins.bindInt(1, @intCast(id));
        ins.bindBlob(2, bytes);
        _ = try ins.step();
    }
    try d.exec("INSERT INTO replay(id) VALUES(4)");
    try initSchema(d);
    const st = try d.prepare("SELECT ln_mode, max_combo, miss FROM replay ORDER BY id");
    defer st.deinit();
    for ([_]i64{ 0, 1, 2, 0 }) |want| {
        try std.testing.expect(try st.step());
        try std.testing.expectEqual(want, st.int(0));
        try std.testing.expectEqual(@as(i64, 0), st.int(1));
        try std.testing.expectEqual(@as(i64, std.math.maxInt(i32)), st.int(2));
    }
}

test "a replay table that got only its combo column still gets its BP column" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try d.exec("CREATE TABLE replay(id INTEGER PRIMARY KEY, sha256 TEXT, date INTEGER, ex INTEGER, clear INTEGER, data BLOB, ln_mode INTEGER NOT NULL DEFAULT 0, max_combo INTEGER NOT NULL DEFAULT 0)");
    try initSchema(d);
    try std.testing.expect(try hasColumn(d, "replay", "miss"));
}

test "a database a beta already migrated gets its replays relabelled, once" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try d.exec(schema);
    const bytes = try core.replay.encode(std.testing.allocator, .{ .sha256 = @splat('a'), .ln_mode = .hcn, .events = &.{} });
    defer std.testing.allocator.free(bytes);
    const ins = try d.prepare("INSERT INTO replay(id,data,ln_mode) VALUES(1,?1,0)");
    defer ins.deinit();
    ins.bindBlob(1, bytes);
    _ = try ins.step();
    try initSchema(d);
    const read = try d.prepare("SELECT ln_mode FROM replay");
    defer read.deinit();
    try std.testing.expect(try read.step());
    try std.testing.expectEqual(@as(i64, 2), read.int(0));
    read.reset();
    try d.exec("UPDATE replay SET ln_mode=1");
    try initSchema(d);
    try std.testing.expect(try read.step());
    try std.testing.expectEqual(@as(i64, 1), read.int(0));
}

test "an old database keeps its scores as LN plays, and each LN mode has its own best" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try d.exec(
        \\CREATE TABLE score(sha256 TEXT PRIMARY KEY, clear INTEGER DEFAULT 0, ex INTEGER DEFAULT 0, pg INTEGER DEFAULT 0, gr INTEGER DEFAULT 0, gd INTEGER DEFAULT 0, bd INTEGER DEFAULT 0, pr INTEGER DEFAULT 0, ms INTEGER DEFAULT 0, max_combo INTEGER DEFAULT 0, min_bp INTEGER DEFAULT 2147483647, playcount INTEGER DEFAULT 0, clearcount INTEGER DEFAULT 0, date INTEGER DEFAULT 0, source TEXT DEFAULT '');
        \\CREATE TABLE replay(id INTEGER PRIMARY KEY, sha256 TEXT, date INTEGER, ex INTEGER, clear INTEGER, data BLOB);
        \\CREATE TABLE song(path TEXT PRIMARY KEY, folder TEXT NOT NULL, sha256 TEXT NOT NULL, md5 TEXT NOT NULL, has_ln INTEGER, mtime INTEGER, title TEXT, subtitle TEXT, artist TEXT, subartist TEXT, genre TEXT, level TEXT, difficulty INTEGER, mode INTEGER, notes INTEGER, min_bpm REAL, max_bpm REAL, length_ms INTEGER, stagefile TEXT, banner TEXT, preview TEXT);
        \\INSERT INTO score(sha256,ex) VALUES('a',50);
        \\INSERT INTO song(path,folder,sha256,md5,has_ln,mtime) VALUES('p','f','a','m',1,9);
    );
    try initSchema(d);
    try initSchema(d);
    try recordScore(d, .{ .sha256 = "a", .mode = 2, .clear = 1, .ex = 7, .counts = @splat(0), .max_combo = 0, .miss = 0, .date = 1 });
    const q = try d.prepare("SELECT group_concat(mode||':'||ex) FROM (SELECT mode,ex FROM score ORDER BY mode)");
    defer q.deinit();
    try std.testing.expect(try q.step());
    try std.testing.expectEqualStrings("0:50,2:7", q.text(0));
    const m = try d.prepare("SELECT mtime FROM song");
    defer m.deinit();
    try std.testing.expect(try m.step());
    try std.testing.expectEqual(@as(i64, 0), m.int(0));
}

test "song select shows the score of its LN mode only on charts that leave it open" {
    const gpa = std.testing.allocator;
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try initSchema(d);
    try d.exec("INSERT INTO song(path,folder,sha256,md5,has_open_ln,title) VALUES('open','f','o','',1,'a'),('set','f','s','',0,'b'); INSERT INTO score(sha256,mode,ex) VALUES('o',0,10),('o',1,20),('s',0,30)");
    try setLnMode(d, 1);
    const st = try d.prepare(song_select ++ " ORDER BY s.title");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 20), st.int(20));
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 30), st.int(20));
}

test "a favorite toggles and shows in the song list" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try initSchema(d);
    try d.exec("INSERT INTO song(path,folder,sha256,md5) VALUES('p','f','a','')");
    try std.testing.expect(try toggleFavorite(d, "a"));
    {
        const st = try d.prepare(song_select);
        defer st.deinit();
        try std.testing.expect(try st.step());
        try std.testing.expectEqual(@as(i64, 1), st.int(25));
    }
    try std.testing.expect(!try toggleFavorite(d, "a"));
    const st = try d.prepare(song_select);
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 0), st.int(25));
}

test "pruning keeps the newest replays and the best one" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try initSchema(d);
    // 1 holds the best lamp, 2 the best EX, 3 the best combo, 4 the fewest BP: IR sync wants each.
    try d.exec("INSERT INTO replay(id,sha256,date,ex,clear,max_combo,miss) VALUES(1,'a',1,1,6,1,9),(2,'a',2,99,1,1,9),(3,'a',3,1,1,50,9),(4,'a',4,1,1,1,0)," ++
        "(5,'a',5,1,1,1,9),(6,'a',6,1,1,1,9),(7,'a',7,1,1,1,9),(8,'a',8,1,1,1,9),(9,'a',9,1,1,1,9),(10,'b',1,1,1,1,9)");
    try pruneReplays(d, "a", 0);
    const st = try d.prepare("SELECT group_concat(id) FROM (SELECT id FROM replay ORDER BY id)");
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("1,2,3,4,6,7,8,9,10", st.text(0));
}

test "a play count past u32 still lists its chart" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try initSchema(d);
    try d.exec("INSERT INTO song(path,folder,sha256,md5) VALUES('p','f','a',''); INSERT INTO score(sha256,mode,playcount) VALUES('a',0,8589934590)");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try d.prepare(song_select);
    defer st.deinit();
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), (try readSong(arena.allocator(), st)).played);
}

test "a scan leaves the database free for other writers between batches" {
    const gpa = std.testing.allocator;
    const path = "actuon_test_scan.db";
    fs.remove(std.testing.io, path);
    defer {
        fs.remove(std.testing.io, path);
        fs.remove(std.testing.io, path ++ "-wal");
        fs.remove(std.testing.io, path ++ "-shm");
    }
    const d = try Db.open(path, gpa, false);
    defer d.close();
    try initSchema(d);
    const roots = [_][]const u8{"tests/charts"};
    _ = try scan(gpa, std.testing.io, d, &roots, null, null);
    const other = try Db.open(path, gpa, false);
    defer other.close();
    try recordScore(other, .{ .sha256 = "a", .clear = 1, .ex = 1, .counts = @splat(0), .max_combo = 1, .miss = 0, .date = 1 });
}

test "LN on any #RANDOM branch files plays as asked, and a CN judged play never lands in the LN row" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "actuon_test_random_ln";
    fs.removeTree(io, root);
    defer fs.removeTree(io, root);
    try fs.mkdirs(io, root);
    const head = "#BPM 120\n#WAV01 a.wav\n#00111:01\n#RANDOM 2\n#IF 1\n#00112:01\n#ENDIF\n#IF 2\n";
    try fs.write(io, root ++ "/ln.bms", head ++ "#TITLE ln\n#00151:0101\n#ENDIF\n#ENDRANDOM\n");
    try fs.write(io, root ++ "/plain.bms", head ++ "#TITLE plain\n#00113:01\n#ENDIF\n#ENDRANDOM\n");
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try initSchema(d);
    _ = try scan(gpa, io, d, &.{root}, null, null);
    const q = try d.prepare("SELECT group_concat(title||has_open_ln) FROM (SELECT * FROM song ORDER BY title)");
    defer q.deinit();
    try std.testing.expect(try q.step());
    try std.testing.expectEqualStrings("ln1,plain0", q.text(0));
    const sha = try d.prepare("SELECT sha256 FROM song ORDER BY title");
    defer sha.deinit();
    try std.testing.expect(try sha.step());
    // CN asked on a branch with no open LN is judged as LN, yet the list reads the CN row.
    try std.testing.expectEqual(@as(u8, 1), try scoreMode(d, sha.text(0), 1, 0));
    try std.testing.expect(try sha.step());
    try std.testing.expectEqual(@as(u8, 0), try scoreMode(d, sha.text(0), 1, 0));
    // A chart scanned before this rule, or never scanned, keeps a CN judged play off the IR.
    try std.testing.expectEqual(@as(u8, 1), try scoreMode(d, sha.text(0), 1, 1));
    try std.testing.expectEqual(@as(u8, 2), try scoreMode(d, "unscanned", 0, 2));
}

test "an assist lamp shows in the list, apart from the lamp IR sync claims" {
    const d = try Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try initSchema(d);
    try d.exec("INSERT INTO song(path,folder,sha256,md5) VALUES('p','f','a','')");
    const st = try d.prepare(song_select);
    defer st.deinit();
    try recordScore(d, .{ .sha256 = "a", .clear = 0, .assist = 3, .ex = 0, .counts = @splat(0), .max_combo = 0, .miss = std.math.maxInt(i32), .date = 1 });
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 3), st.int(19));
    try std.testing.expectEqual(@as(i64, -1), st.int(21)); // no BP from a lamp alone
    st.reset();
    try recordScore(d, .{ .sha256 = "a", .clear = 1, .ex = 5, .counts = @splat(0), .max_combo = 0, .miss = 9, .date = 2 });
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 3), st.int(19));
    try std.testing.expectEqual(@as(i64, 9), st.int(21));
    const claimed = try d.prepare("SELECT clear FROM score");
    defer claimed.deinit();
    try std.testing.expect(try claimed.step());
    try std.testing.expectEqual(@as(i64, 1), claimed.int(0));
}

test "a watched rescan lists only changed folders, drops removed ones and falls back when events are lost" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "actuon_test_watch";
    fs.removeTree(io, root);
    defer fs.removeTree(io, root);
    try fs.mkdirs(io, root ++ "/old");
    try fs.mkdirs(io, root ++ "/gone/deep");
    const chart = try fs.readAlloc(gpa, io, "tests/charts/five_key.bms", 1 << 20);
    defer gpa.free(chart);
    try fs.write(io, root ++ "/old/a.bms", chart);
    try fs.write(io, root ++ "/gone/deep/b.bms", chart);
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try initSchema(d);
    var w: Watch = .init(gpa);
    defer w.deinit();
    // A root as typed may end in a separator.
    const roots = [_][]const u8{root ++ "/"};
    try std.testing.expectEqual(@as(u32, 2), (try scan(gpa, io, d, &roots, null, &w)).parsed);
    // A stat pass would read every chart again now.
    try d.exec("UPDATE song SET mtime=1");
    try std.testing.expectEqual(ScanStats{}, try scan(gpa, io, d, &roots, null, &w));
    try fs.mkdirs(io, root ++ "/new");
    try fs.write(io, root ++ "/new/c.bms", chart);
    fs.removeTree(io, root ++ "/gone");
    try std.testing.expectEqual(ScanStats{ .parsed = 1, .removed = 1 }, try scan(gpa, io, d, &roots, null, &w));
    try fs.write(io, root ++ "/old/d.bms", chart);
    try std.testing.expectEqual(ScanStats{ .parsed = 2 }, try scan(gpa, io, d, &roots, null, &w));
    try d.exec("UPDATE song SET mtime=1");
    w.lost = true;
    try std.testing.expectEqual(ScanStats{ .parsed = 3 }, try scan(gpa, io, d, &roots, null, &w));
}

test "a watched folder made again under its name, or moved to another watched one, stays watched" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "actuon_test_watch_again";
    fs.removeTree(io, root);
    defer fs.removeTree(io, root);
    try fs.mkdirs(io, root ++ "/a/pack/sub");
    try fs.mkdirs(io, root ++ "/b");
    const chart = try fs.readAlloc(gpa, io, "tests/charts/five_key.bms", 1 << 20);
    defer gpa.free(chart);
    try fs.write(io, root ++ "/a/pack/sub/1.bms", chart);
    const d = try Db.open(":memory:", gpa, false);
    defer d.close();
    try initSchema(d);
    var w: Watch = .init(gpa);
    defer w.deinit();
    const roots = [_][]const u8{root};
    try std.testing.expectEqual(ScanStats{ .parsed = 1 }, try scan(gpa, io, d, &roots, null, &w));
    // As re-extracting an archive does.
    fs.removeTree(io, root ++ "/a/pack");
    try fs.mkdirs(io, root ++ "/a/pack");
    try fs.write(io, root ++ "/a/pack/2.bms", chart);
    try std.testing.expectEqual(ScanStats{ .parsed = 1, .removed = 1 }, try scan(gpa, io, d, &roots, null, &w));
    try fs.write(io, root ++ "/a/pack/3.bms", chart);
    try std.testing.expectEqual(ScanStats{ .parsed = 1 }, try scan(gpa, io, d, &roots, null, &w));
    try fs.rename(root ++ "/a/pack", root ++ "/b/pack");
    try std.testing.expectEqual(ScanStats{ .parsed = 2, .removed = 2 }, try scan(gpa, io, d, &roots, null, &w));
    try fs.write(io, root ++ "/b/pack/4.bms", chart);
    try std.testing.expectEqual(ScanStats{ .parsed = 1 }, try scan(gpa, io, d, &roots, null, &w));
}
