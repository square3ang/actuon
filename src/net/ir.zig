//! IR client: uploads replays and fetches rankings on background threads, never during play timing.
const std = @import("std");
const c = @import("c");
const http = @import("../platform/http.zig");
const fs = @import("../platform/fs.zig");
const db_mod = @import("../db/db.zig");

pub const Upload = struct {
    gpa: std.mem.Allocator,
    base: []u8,
    token: []u8,
    sha: []u8,
    chart_path: []u8,
    replay: []u8,
    board: *Board,
};

/// One upload's outcome and the chart's ranking around it, for the result screen. Two owners, because
/// the player can start the next chart while a slow upload is still running.
pub const Board = struct {
    pub const Row = struct { name_buf: [160]u8 = undefined, name_len: usize = 0, ex: i64 = 0, clear: i64 = 0 };
    pub const pending = 0;
    pub const accepted = 1;
    pub const failed = 2;

    gpa: std.mem.Allocator,
    refs: std.atomic.Value(u8) = .init(2),
    /// The fields below are written before this leaves pending.
    state: std.atomic.Value(u8) = .init(pending),
    rank: i64 = 0,
    prev_rank: i64 = 0,
    total: i64 = 0,
    clears: [11]i64 = @splat(0),
    rows: []Row = &.{},
    /// The row at the top of the skin's list. Only the UI thread touches it once the board is ready.
    offset: usize = 0,

    pub fn release(b: *Board) void {
        if (b.refs.fetchSub(1, .acq_rel) != 1) return;
        b.gpa.free(b.rows);
        b.gpa.destroy(b);
    }

    /// The rest follow beatoraja's AbstractResult: a wheel step is one row, and the last place on
    /// the slider does nothing.
    pub fn scroll(b: *Board, rows: i32) void {
        if (!b.ready() or b.rows.len == 0) return;
        const to = @as(i64, @intCast(b.offset)) + rows;
        b.offset = @intCast(std.math.clamp(to, 0, @as(i64, @intCast(b.rows.len)) - 1));
    }

    pub fn position(b: *const Board) f32 {
        if (!b.ready()) return 0;
        return @as(f32, @floatFromInt(b.offset)) / @as(f32, @floatFromInt(@max(b.rows.len, 1)));
    }

    pub fn setPosition(b: *Board, value: f32) void {
        if (!b.ready() or value < 0 or value >= 1) return;
        b.offset = @intFromFloat(@as(f32, @floatFromInt(b.rows.len)) * value);
    }

    pub fn ready(b: *const Board) bool {
        return b.state.load(.acquire) != pending;
    }

    /// The one line a built-in screen shows.
    pub fn placeText(b: *const Board, buf: []u8) []const u8 {
        return switch (b.state.load(.acquire)) {
            pending => "IR: loading...",
            failed => "IR: unavailable",
            else => if (b.total == 0)
                "IR: no scores yet"
            else if (b.rank == 0)
                std.fmt.bufPrint(buf, "IR: {d} players", .{b.total}) catch ""
            else
                std.fmt.bufPrint(buf, "IR: #{d} of {d}", .{ b.rank, b.total }) catch "",
        };
    }

    fn percent(b: *const Board, n: i64) i64 {
        return if (b.total > 0) @divTrunc(n * 100, b.total) else 0;
    }

    fn sum(b: *const Board, from: usize) i64 {
        var n: i64 = 0;
        for (b.clears[from..]) |v| n += v;
        return n;
    }

    /// beatoraja's IR number ids. 10390 up is the clear of a row: see Renderer.blit.
    pub fn number(b: *const Board, id: i32) ?i64 {
        if (!b.ready()) return null;
        // Which clear each pair of count and percent ids is about, from id 202.
        const pairs = [_]usize{ 0, 2, 3, 7, 1, 4, 5, 6, 8 };
        return switch (id) {
            179 => b.rank,
            180, 200 => b.total,
            181 => b.percent(b.sum(4)),
            182 => b.prev_rank,
            202...219 => blk: {
                const n = b.clears[pairs[@intCast(@divTrunc(id - 202, 2))]];
                break :blk if (@mod(id, 2) == 0) n else b.percent(n);
            },
            222 => b.clears[9],
            223 => b.percent(b.clears[9]),
            224 => b.clears[10],
            225 => b.percent(b.clears[10]),
            226 => b.sum(4),
            227 => b.percent(b.sum(4)),
            228 => b.sum(8),
            229 => b.percent(b.sum(8)),
            380...389 => if (b.rowAt(id - 380)) |r| r.ex else std.math.minInt(i32),
            390...399 => if (b.rowAt(id - 390) != null) @as(i64, id - 389) + @as(i64, @intCast(b.offset)) else std.math.minInt(i32),
            10390...10399 => if (b.rowAt(id - 10390)) |r| r.clear else 0,
            else => null,
        };
    }

    /// Text ids 120 to 129. Skins find the player's own row by the name YOU.
    pub fn name(b: *const Board, id: i32) []const u8 {
        if (!b.ready()) return "";
        const r = b.rowAt(id - 120) orelse return "";
        return r.name_buf[0..r.name_len];
    }

    fn rowAt(b: *const Board, i: i32) ?*const Row {
        if (i < 0) return null;
        const at = b.offset + @as(usize, @intCast(i));
        return if (at < b.rows.len) &b.rows[at] else null;
    }
};

const Standing = struct {
    const Score = struct { name: []const u8, ex: i64, clear: i64, verified: bool = true, you: bool = false };
    scores: []Score,
    rank: i64 = 0,
    total: i64 = 0,
    clears: []const i64 = &.{},
};

fn fetchStanding(a: std.mem.Allocator, base: []const u8, token: []const u8, sha: []const u8) !Standing {
    // shortcut: the server's limit, so places past 1000 cannot be scrolled to; page if a chart ever gets there
    const url = try std.fmt.allocPrint(a, "{s}/scores/{s}?limit=1000", .{ base, sha });
    const r = try http.request(a, .GET, url, null, try bearer(a, token));
    if (r.status != 200) return error.HttpStatus;
    return std.json.parseFromSliceLeaky(Standing, a, r.body, .{ .ignore_unknown_fields = true });
}

fn fillBoard(b: *Board, s: Standing) void {
    b.rank = s.rank;
    b.total = s.total;
    for (b.clears[0..@min(b.clears.len, s.clears.len)], s.clears[0..@min(b.clears.len, s.clears.len)]) |*d, v| d.* = v;
    b.rows = b.gpa.alloc(Board.Row, s.scores.len) catch return;
    // Opens on the player's own place, like beatoraja's MusicResult.
    b.offset = if (s.rank > 10) @intCast(@min(s.rank - 5, @as(i64, @intCast(s.scores.len -| 1)))) else 0;
    for (b.rows, s.scores) |*row, score| {
        // Short: skins leave little room before the score column.
        const label = if (score.you or score.verified) "" else " (unv.)";
        const shown = std.fmt.bufPrint(&row.name_buf, "{s}{s}", .{ if (score.you) "YOU" else score.name, label }) catch row.name_buf[0..0];
        row.name_len = shown.len;
        row.ex = score.ex;
        row.clear = score.clear;
    }
}

pub fn chartFormat(path: []const u8) u8 {
    if (std.ascii.endsWithIgnoreCase(path, ".bmson")) return 3;
    if (std.ascii.endsWithIgnoreCase(path, ".pms")) return 2;
    return 1;
}

fn bearer(a: std.mem.Allocator, token: []const u8) ![]const std.http.Header {
    const hs = try a.alloc(std.http.Header, 1);
    hs[0] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) };
    return hs;
}

/// Submit, and when the server has never seen this chart (428) upload it and submit again.
/// `prev_rank` gets the player's place from before this score, when the caller wants it.
pub fn submit(gpa: std.mem.Allocator, client: *std.http.Client, base: []const u8, token: []const u8, sha: []const u8, chart_path: []const u8, replay: []const u8, prev_rank: ?*i64) !u16 {
    // Without the file nothing says how the chart should be parsed.
    if (chart_path.len == 0) return error.NoChart;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const hs = try bearer(a, token);
    const format = chartFormat(chart_path);
    const url = try std.fmt.allocPrint(a, "{s}/scores/{s}?format={d}", .{ base, sha, format });
    var r = try http.send(client, a, .POST, url, replay, hs);
    if (r.status == 428) {
        const chart = try fs.readAlloc(a, chart_path, 16 << 20);
        const put = try std.fmt.allocPrint(a, "{s}/charts/{s}?format={d}", .{ base, sha, format });
        const up = try http.send(client, a, .PUT, put, chart, hs);
        if (up.status != 200) return up.status;
        r = try http.send(client, a, .POST, url, replay, hs);
    }
    if (prev_rank) |out| if (r.status == 200) {
        const v = std.json.parseFromSliceLeaky(struct { prev_rank: i64 = 0 }, a, r.body, .{ .ignore_unknown_fields = true }) catch return r.status;
        out.* = v.prev_rank;
    };
    return r.status;
}

fn uploadThread(ud: ?*anyopaque) callconv(.c) c_int {
    const u: *Upload = @ptrCast(@alignCast(ud));
    var arena = std.heap.ArenaAllocator.init(u.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var client = http.client(u.gpa);
    defer client.deinit();
    const code = submit(u.gpa, &client, u.base, u.token, u.sha, u.chart_path, u.replay, &u.board.prev_rank) catch |e| blk: {
        std.log.warn("IR upload: {t}", .{e});
        break :blk 0;
    };
    // Rankings are a bonus: without them the upload still counts.
    if (fetchStanding(a, u.base, u.token, u.sha)) |after| fillBoard(u.board, after) else |e| std.log.warn("IR ranking: {t}", .{e});
    u.board.state.store(if (code == 200) Board.accepted else Board.failed, .release);
    u.board.release();
    const gpa = u.gpa;
    gpa.free(u.base);
    gpa.free(u.token);
    gpa.free(u.sha);
    gpa.free(u.chart_path);
    gpa.free(u.replay);
    gpa.destroy(u);
    return 0;
}

const RankingFetch = struct { base: []u8, token: []u8, sha: []u8, board: *Board };

fn rankingThread(ud: ?*anyopaque) callconv(.c) c_int {
    const f: *RankingFetch = @ptrCast(@alignCast(ud));
    const gpa = f.board.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    if (fetchStanding(arena.allocator(), f.base, f.token, f.sha)) |s| {
        fillBoard(f.board, s);
        f.board.state.store(Board.accepted, .release);
    } else |e| {
        std.log.warn("IR ranking: {t}", .{e});
        f.board.state.store(Board.failed, .release);
    }
    f.board.release();
    gpa.free(f.base);
    gpa.free(f.token);
    gpa.free(f.sha);
    gpa.destroy(f);
    return 0;
}

/// A chart's ranking with no upload, for song select. The caller owns one reference, as with startUpload.
pub fn startRanking(gpa: std.mem.Allocator, base: []const u8, token: []const u8, sha: []const u8) ?*Board {
    const board = gpa.create(Board) catch return null;
    board.* = .{ .gpa = gpa };
    const f = gpa.create(RankingFetch) catch return null;
    f.* = .{
        .base = gpa.dupe(u8, base) catch return null,
        .token = gpa.dupe(u8, token) catch return null,
        .sha = gpa.dupe(u8, sha) catch return null,
        .board = board,
    };
    if (c.SDL_CreateThread(rankingThread, "ir-ranking", f)) |t| {
        c.SDL_DetachThread(t);
    } else {
        board.state.store(Board.failed, .release);
        board.release();
    }
    return board;
}

/// The caller owns one reference to the answer and gives it back with release.
pub fn startUpload(gpa: std.mem.Allocator, base: []const u8, token: []const u8, sha: []const u8, chart_path: []const u8, replay: []const u8) ?*Board {
    const board = gpa.create(Board) catch return null;
    board.* = .{ .gpa = gpa };
    const u = gpa.create(Upload) catch return null;
    u.* = .{
        .gpa = gpa,
        .base = gpa.dupe(u8, base) catch return null,
        .token = gpa.dupe(u8, token) catch return null,
        .sha = gpa.dupe(u8, sha) catch return null,
        .chart_path = gpa.dupe(u8, chart_path) catch return null,
        .replay = gpa.dupe(u8, replay) catch return null,
        .board = board,
    };
    if (c.SDL_CreateThread(uploadThread, "ir-upload", u)) |t| {
        c.SDL_DetachThread(t);
    } else {
        board.state.store(Board.failed, .release);
        board.release();
    }
    return board;
}

/// A background GET or POST whose JSON answer is parsed into display lines. Two owners, because a
/// request has no timeout: the UI can leave one that hangs without waiting for it.
pub const Query = struct {
    gpa: std.mem.Allocator,
    url: []u8,
    token: []u8,
    body: ?[]u8,
    lines: std.ArrayList([]u8) = .empty,
    done: std.atomic.Value(bool) = .init(false),
    failed: bool = false,
    refs: std.atomic.Value(u8) = .init(2),

    pub fn destroy(q: *Query) void {
        if (q.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = q.gpa;
        for (q.lines.items) |l| gpa.free(l);
        q.lines.deinit(gpa);
        gpa.free(q.url);
        gpa.free(q.token);
        if (q.body) |b| gpa.free(b);
        gpa.destroy(q);
    }
};

pub fn formatRow(a: std.mem.Allocator, row: std.json.Value, rank: usize) ![]u8 {
    if (row != .object) return a.dupe(u8, "");
    const o = row.object;
    const name = if (o.get("name")) |n| (if (n == .string) n.string else "?") else "?";
    const num = struct {
        fn f(m: std.json.ObjectMap, k: []const u8) i64 {
            const v = m.get(k) orelse return -1;
            return if (v == .integer) v.integer else -1;
        }
    }.f;
    if (o.get("clears") != null) {
        return std.fmt.allocPrint(a, "{d}. {s}   EX {d}   clears {d}   played {d}", .{ rank, name, num(o, "ex"), num(o, "clears"), num(o, "played") });
    }
    const unverified = if (o.get("verified")) |v| v == .bool and !v.bool else false;
    return std.fmt.allocPrint(a, "{d}. {s}   EX {d}   BP {d}{s}", .{ rank, name, num(o, "ex"), num(o, "miss"), if (unverified) "   (unverified)" else "" });
}

fn queryThread(ud: ?*anyopaque) callconv(.c) c_int {
    const q: *Query = @ptrCast(@alignCast(ud));
    run(q) catch |e| {
        std.log.warn("IR query: {t}", .{e});
        q.failed = true;
    };
    q.done.store(true, .release);
    q.destroy();
    return 0;
}

fn run(q: *Query) !void {
    var arena = std.heap.ArenaAllocator.init(q.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const hs: []const std.http.Header = if (q.token.len > 0) try bearer(a, q.token) else &.{};
    const r = try http.request(a, if (q.body != null) .POST else .GET, q.url, q.body, hs);
    if (r.status != 200) return error.HttpStatus;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, r.body, .{});
    if (v != .object) return error.BadAnswer;
    const list = v.object.get("scores") orelse v.object.get("players") orelse return error.BadAnswer;
    if (list != .array) return error.BadAnswer;
    for (list.array.items, 1..) |row, i| try q.lines.append(q.gpa, try formatRow(q.gpa, row, i));
}

pub fn startQuery(gpa: std.mem.Allocator, url: []const u8, token: []const u8, body: ?[]const u8) ?*Query {
    const q = gpa.create(Query) catch return null;
    q.* = .{
        .gpa = gpa,
        .url = gpa.dupe(u8, url) catch return null,
        .token = gpa.dupe(u8, token) catch return null,
        .body = if (body) |b| gpa.dupe(u8, b) catch return null else null,
    };
    if (c.SDL_CreateThread(queryThread, "ir-query", q)) |t| {
        c.SDL_DetachThread(t);
    } else {
        q.failed = true;
        q.done.store(true, .release);
        q.destroy();
    }
    return q;
}

const MyScore = struct { sha256: []const u8, ex: u32, clear: u32, miss: u32, max_combo: u32, date: i64, verified: bool = true };

fn fetchMine(a: std.mem.Allocator, base: []const u8, token: []const u8) ![]MyScore {
    const r = try http.request(a, .GET, try std.fmt.allocPrint(a, "{s}/me/scores", .{base}), null, try bearer(a, token));
    if (r.status != 200) return error.HttpStatus;
    const v = try std.json.parseFromSliceLeaky(struct { scores: []MyScore }, a, r.body, .{ .ignore_unknown_fields = true });
    return v.scores;
}

/// Bests only ever rise on both sides, and counts stay out of it: the server does not keep judge counts.
/// Play counts stay local, so downloading twice changes nothing.
fn mergeMine(d: db_mod.Db, scores: []const MyScore) !u32 {
    var merged: u32 = 0;
    try d.exec("BEGIN");
    errdefer d.exec("ROLLBACK") catch {};
    for (scores) |s| {
        if (!validSha(s.sha256)) continue;
        try db_mod.recordScore(d, .{
            .sha256 = s.sha256,
            .clear = @intCast(@min(s.clear, 10)),
            .ex = s.ex,
            .counts = @splat(0),
            .max_combo = s.max_combo,
            .miss = s.miss,
            .played = 0,
            .date = s.date,
            .source = "IR",
        });
        merged += 1;
    }
    try d.exec("COMMIT");
    return merged;
}

/// What the server accepts as a chart hash. Imported databases hold others, such as course hashes.
fn validSha(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch) and (ch < 'a' or ch > 'f')) return false;
    return true;
}

const Best = struct { ex: u32, clear: u32 };
const Pending = struct { id: i64, sha: []const u8, path: []const u8 };

/// Replays the server's bests do not already cover, best first so that one upload can cover the rest of its chart.
/// shortcut: a replay that only improves combo or BP is not sent, compare those too if players ask for it.
fn pendingReplays(a: std.mem.Allocator, d: db_mod.Db, mine: []const MyScore) ![]Pending {
    var best: std.StringHashMapUnmanaged(Best) = .empty;
    // A claim does not count: a replay that only matches it still turns it into a verified score.
    for (mine) |s| if (s.verified) try best.put(a, s.sha256, .{ .ex = s.ex, .clear = s.clear });
    const st = try d.prepare(
        \\SELECT r.id,r.sha256,r.ex,r.clear,COALESCE((SELECT path FROM song s WHERE s.sha256=r.sha256 LIMIT 1),'')
        \\FROM replay r ORDER BY r.sha256, r.ex DESC, r.clear DESC
    );
    defer st.deinit();
    var out: std.ArrayList(Pending) = .empty;
    while (try st.step()) {
        const ex: u32 = @intCast(st.int(2));
        const clear: u32 = @intCast(st.int(3));
        const sha = try a.dupe(u8, st.text(1));
        const got = try best.getOrPut(a, sha);
        if (got.found_existing and ex <= got.value_ptr.ex and clear <= got.value_ptr.clear) continue;
        got.value_ptr.* = if (got.found_existing) .{ .ex = @max(ex, got.value_ptr.ex), .clear = @max(clear, got.value_ptr.clear) } else .{ .ex = ex, .clear = clear };
        try out.append(a, .{ .id = st.int(0), .sha = sha, .path = try a.dupe(u8, st.text(4)) });
    }
    return out.items;
}

/// Local bests the server has no row to match, whether verified or not. Imported scores land here,
/// and so do plays whose replay the server refused.
fn pendingClaims(a: std.mem.Allocator, d: db_mod.Db, mine: []const MyScore) ![]MyScore {
    var best: std.StringHashMapUnmanaged(Best) = .empty;
    for (mine) |s| {
        const got = try best.getOrPutValue(a, s.sha256, .{ .ex = 0, .clear = 0 });
        got.value_ptr.* = .{ .ex = @max(s.ex, got.value_ptr.ex), .clear = @max(s.clear, got.value_ptr.clear) };
    }
    const st = try d.prepare("SELECT sha256,ex,clear,min_bp,max_combo,date FROM score WHERE ex>0 OR clear>0");
    defer st.deinit();
    var out: std.ArrayList(MyScore) = .empty;
    while (try st.step()) {
        // One the server refuses would take the rest of its batch down with it.
        if (!validSha(st.text(0))) continue;
        const ex: u32 = @intCast(st.int(1));
        const clear: u32 = @intCast(st.int(2));
        if (best.get(st.text(0))) |b| if (ex <= b.ex and clear <= b.clear) continue;
        try out.append(a, .{ .sha256 = try a.dupe(u8, st.text(0)), .ex = ex, .clear = clear, .miss = @intCast(st.int(3)), .max_combo = @intCast(st.int(4)), .date = st.int(5), .verified = false });
    }
    return out.items;
}

/// Fits the server's 1 MiB JSON limit, at about 150 bytes a score.
const claim_batch = 4096;

fn sendClaims(s: *Sync, a: std.mem.Allocator, claims: []const MyScore) !void {
    const url = try std.fmt.allocPrint(a, "{s}/me/claims", .{s.base});
    const hs = try bearer(a, s.token);
    var i: usize = 0;
    while (i < claims.len) : (i += claim_batch) {
        const part = claims[i..@min(i + claim_batch, claims.len)];
        const body = try std.json.Stringify.valueAlloc(a, .{ .scores = part }, .{});
        const r = try http.request(a, .POST, url, body, hs);
        if (r.status == 200) s.claimed += @intCast(part.len) else s.failed += @intCast(part.len);
    }
}

/// One run of IR sync on a background thread with its own database connection.
pub const Sync = struct {
    gpa: std.mem.Allocator,
    base: []u8,
    token: []u8,
    upload: bool,
    /// Replays handled, of total. Downloads leave these at 0 until they finish.
    progress: std.atomic.Value(u32) = .init(0),
    total: std.atomic.Value(u32) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    /// Read these only after done.
    accepted: u32 = 0,
    claimed: u32 = 0,
    failed: u32 = 0,
    err: ?anyerror = null,
    thread: ?*c.SDL_Thread = null,

    pub fn destroy(s: *Sync) void {
        if (s.thread) |t| c.SDL_WaitThread(t, null);
        const gpa = s.gpa;
        gpa.free(s.base);
        gpa.free(s.token);
        gpa.destroy(s);
    }
};

/// Below the server's 4 checks at once, so that one player's sync leaves room for a score just played.
const push_workers = 3;
const push_tries = 3;

const Push = struct {
    s: *Sync,
    pending: []const Pending,
    next: *std.atomic.Value(usize),
    accepted: u32 = 0,
    failed: u32 = 0,
};

/// A kept connection the server has closed fails once, and a busy server says 503: both pass on another try.
fn submitPatiently(s: *Sync, client: *std.http.Client, p: Pending, replay: []const u8) u16 {
    var tries: u32 = 1;
    while (true) : (tries += 1) {
        const code = submit(s.gpa, client, s.base, s.token, p.sha, p.path, replay, null) catch |e| switch (e) {
            error.NoChart => return 0,
            else => @as(u16, 0),
        };
        if (tries == push_tries or (code != 0 and code != 503)) return code;
        if (code == 503) c.SDL_Delay(1000);
    }
}

fn pushReplays(w: *Push) !void {
    const d = try db_mod.openMain(w.s.gpa);
    defer d.close();
    const load = try d.prepare("SELECT data FROM replay WHERE id=?1");
    defer load.deinit();
    var client = http.client(w.s.gpa);
    defer client.deinit();
    while (true) {
        const i = w.next.fetchAdd(1, .monotonic);
        if (i >= w.pending.len) return;
        defer _ = w.s.progress.fetchAdd(1, .release);
        load.bindInt(1, w.pending[i].id);
        defer load.reset();
        // One bad replay or missing chart must not stop the rest.
        const code = if (try load.step()) submitPatiently(w.s, &client, w.pending[i], load.text(0)) else 0;
        if (code == 200) w.accepted += 1 else w.failed += 1;
    }
}

fn pushThread(ud: ?*anyopaque) callconv(.c) c_int {
    const w: *Push = @ptrCast(@alignCast(ud));
    pushReplays(w) catch |e| std.log.warn("IR sync worker: {t}", .{e});
    return 0;
}

/// shortcut: every new chart still costs a refused POST before its PUT, ask for the known list first if that shows.
fn pushAllReplays(s: *Sync, pending: []const Pending) !void {
    var next: std.atomic.Value(usize) = .init(0);
    var workers: [push_workers]Push = @splat(.{ .s = s, .pending = pending, .next = &next });
    var threads: [push_workers - 1]?*c.SDL_Thread = @splat(null);
    // A worker that fails to start only slows the rest down; this thread sees every replay handled.
    for (&threads, workers[1..]) |*t, *w| t.* = c.SDL_CreateThread(pushThread, "ir-push", w);
    const own = pushReplays(&workers[0]);
    for (threads) |t| if (t) |started| c.SDL_WaitThread(started, null);
    for (workers) |w| {
        s.accepted += w.accepted;
        s.failed += w.failed;
    }
    return own;
}

fn pushAll(s: *Sync, d: db_mod.Db) !void {
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const pending = try pendingReplays(a, d, try fetchMine(a, s.base, s.token));
    s.total.store(@intCast(pending.len), .release);
    try pushAllReplays(s, pending);
    // Asked again because the replays above just changed the answer.
    try sendClaims(s, a, try pendingClaims(a, d, try fetchMine(a, s.base, s.token)));
}

fn pullAll(s: *Sync, d: db_mod.Db) !void {
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    s.accepted = try mergeMine(d, try fetchMine(arena.allocator(), s.base, s.token));
}

fn syncThread(ud: ?*anyopaque) callconv(.c) c_int {
    const s: *Sync = @ptrCast(@alignCast(ud));
    defer s.done.store(true, .release);
    const d = db_mod.openMain(s.gpa) catch |e| {
        s.err = e;
        return 0;
    };
    defer d.close();
    (if (s.upload) pushAll(s, d) else pullAll(s, d)) catch |e| {
        std.log.warn("IR sync: {t}", .{e});
        s.err = e;
    };
    return 0;
}

pub fn startSync(gpa: std.mem.Allocator, base: []const u8, token: []const u8, upload: bool) ?*Sync {
    const s = gpa.create(Sync) catch return null;
    s.* = .{
        .gpa = gpa,
        .base = gpa.dupe(u8, base) catch return null,
        .token = gpa.dupe(u8, token) catch return null,
        .upload = upload,
    };
    s.thread = c.SDL_CreateThread(syncThread, "ir-sync", s);
    if (s.thread == null) {
        s.err = error.NoThread;
        s.done.store(true, .release);
    }
    return s;
}

pub const AccountReply = struct { status: u16, body: []const u8, token: ?[]const u8 };

/// Asks the server for a token. Anything but a 200 comes back as a status for the caller to explain.
pub fn requestToken(a: std.mem.Allocator, base: []const u8, name: []const u8, password: []const u8, register: bool) !AccountReply {
    const body = try std.json.Stringify.valueAlloc(a, .{ .name = name, .password = password }, .{});
    const url = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, if (register) "register" else "login" });
    const r = try http.request(a, .POST, url, body, &.{});
    if (r.status != 200) return .{ .status = r.status, .body = r.body, .token = null };
    const v = try std.json.parseFromSliceLeaky(struct { token: []const u8 }, a, r.body, .{ .ignore_unknown_fields = true });
    return .{ .status = r.status, .body = r.body, .token = v.token };
}

pub const AccountAction = enum { register, login, rename };

pub fn accountRefusal(status: u16, action: AccountAction) []const u8 {
    return switch (status) {
        400 => if (action == .rename) "Name must be 1-32 characters" else "Name must be 1-32 characters and password at least 8",
        401 => if (action == .rename) "Sign in again first" else "Wrong name or password",
        409 => "That name is taken",
        429 => "Too many attempts, try again later",
        else => "The IR server refused",
    };
}

fn requestRename(a: std.mem.Allocator, base: []const u8, name: []const u8, token: []const u8) !u16 {
    const body = try std.json.Stringify.valueAlloc(a, .{ .name = name }, .{});
    const url = try std.fmt.allocPrint(a, "{s}/me/name", .{base});
    return (try http.request(a, .POST, url, body, try bearer(a, token))).status;
}

/// One sign-up, sign-in or rename on a background thread, so a slow server cannot stall the menu.
pub const Account = struct {
    gpa: std.mem.Allocator,
    base: []u8,
    name: []u8,
    /// The password, or for a rename the token.
    secret: []u8,
    action: AccountAction,
    done: std.atomic.Value(bool) = .init(false),
    /// Read these only after done.
    token: ?[]u8 = null,
    status: u16 = 0,
    err: ?anyerror = null,
    thread: ?*c.SDL_Thread = null,

    pub fn destroy(s: *Account) void {
        if (s.thread) |t| c.SDL_WaitThread(t, null);
        const gpa = s.gpa;
        gpa.free(s.base);
        gpa.free(s.name);
        gpa.free(s.secret);
        if (s.token) |t| gpa.free(t);
        gpa.destroy(s);
    }
};

fn accountThread(ud: ?*anyopaque) callconv(.c) c_int {
    const s: *Account = @ptrCast(@alignCast(ud));
    defer s.done.store(true, .release);
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    runAccount(s, arena.allocator()) catch |e| {
        std.log.warn("IR account: {t}", .{e});
        s.err = e;
    };
    return 0;
}

fn runAccount(s: *Account, a: std.mem.Allocator) !void {
    if (s.action == .rename) {
        s.status = try requestRename(a, s.base, s.name, s.secret);
        return;
    }
    const r = try requestToken(a, s.base, s.name, s.secret, s.action == .register);
    s.status = r.status;
    if (r.token) |t| s.token = try s.gpa.dupe(u8, t);
}

pub fn startAccount(gpa: std.mem.Allocator, base: []const u8, name: []const u8, secret: []const u8, action: AccountAction) ?*Account {
    const s = gpa.create(Account) catch return null;
    s.* = .{
        .gpa = gpa,
        .base = gpa.dupe(u8, base) catch return null,
        .name = gpa.dupe(u8, name) catch return null,
        .secret = gpa.dupe(u8, secret) catch return null,
        .action = action,
    };
    s.thread = c.SDL_CreateThread(accountThread, "ir-account", s);
    if (s.thread == null) {
        s.err = error.NoThread;
        s.done.store(true, .release);
    }
    return s;
}

test "a board says where the player stands" {
    var buf: [64]u8 = undefined;
    var b: Board = .{ .gpa = std.testing.allocator };
    try std.testing.expectEqualStrings("IR: loading...", b.placeText(&buf));
    b.state.store(Board.failed, .release);
    try std.testing.expectEqualStrings("IR: unavailable", b.placeText(&buf));
    b.state.store(Board.accepted, .release);
    try std.testing.expectEqualStrings("IR: no scores yet", b.placeText(&buf));
    b.total = 12;
    try std.testing.expectEqualStrings("IR: 12 players", b.placeText(&buf));
    b.rank = 3;
    try std.testing.expectEqualStrings("IR: #3 of 12", b.placeText(&buf));
}

test "a ranking that cannot be fetched fails instead of hanging" {
    const b = startRanking(std.testing.allocator, "http://127.0.0.1:1", "t", "a").?;
    defer b.release();
    while (!b.ready()) c.SDL_Delay(5);
    try std.testing.expectEqual(@as(u8, Board.failed), b.state.load(.acquire));
}

test "every refusal explains itself" {
    try std.testing.expectEqualStrings("That name is taken", accountRefusal(409, .register));
    try std.testing.expectEqualStrings("Wrong name or password", accountRefusal(401, .login));
    try std.testing.expectEqualStrings("Sign in again first", accountRefusal(401, .rename));
    try std.testing.expectEqualStrings("The IR server refused", accountRefusal(500, .rename));
}

test "sync uploads only what the server lacks, once per improvement" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const d = try db_mod.Db.open(":memory:", a, false);
    defer d.close();
    try db_mod.initSchema(d);
    try d.exec("INSERT INTO song(path,folder,sha256,md5) VALUES('/c.bms','f','same','m'),('/d.bms','f','new','n');" ++
        "INSERT INTO replay(sha256,ex,clear) VALUES('same',100,4),('same',90,4),('new',50,1),('new',40,1),('new',30,5),('gone',7,1)");
    const mine = [_]MyScore{.{ .sha256 = "same", .ex = 100, .clear = 4, .miss = 0, .max_combo = 0, .date = 0 }};
    const p = try pendingReplays(arena.allocator(), d, &mine);
    try std.testing.expectEqual(@as(usize, 3), p.len);
    try std.testing.expectEqualStrings("gone", p[0].sha);
    try std.testing.expectEqualStrings("", p[0].path);
    try std.testing.expectEqualStrings("new", p[1].sha);
    try std.testing.expectEqualStrings("/d.bms", p[1].path);
    try std.testing.expectEqualStrings("new", p[2].sha); // lower EX, but the only HARD clear
}

test "workers send every replay once and try again on a busy server" {
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(fs.io, .{ .reuse_address = true });
    defer server.deinit(fs.io);
    const total = 5;
    const Peer = struct {
        fn run(listener: *std.Io.net.Server, seen: *[total + 1][]const u8, names: *[total + 1][64]u8) void {
            for (seen, names, 0..) |*one, *name, n| {
                const stream = listener.accept(fs.io) catch return;
                defer stream.close(fs.io);
                var in_buf: [1024]u8 = undefined;
                var reader = stream.reader(fs.io, &in_buf);
                const start = reader.interface.takeDelimiterInclusive('\n') catch return;
                const at = std.mem.indexOf(u8, start, "/scores/") orelse return;
                one.* = std.fmt.bufPrint(name, "{s}", .{start[at + 8 ..][0..1]}) catch return;
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                    if (line.len == 2) break;
                }
                reader.interface.discardAll(1) catch return;
                var out_buf: [128]u8 = undefined;
                var writer = stream.writer(fs.io, &out_buf);
                const status = if (n == 0) "503 Busy" else "200 OK";
                writer.interface.print("HTTP/1.1 {s}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", .{status}) catch return;
                writer.interface.flush() catch return;
            }
        }
    };
    var seen: [total + 1][]const u8 = @splat("");
    var names: [total + 1][64]u8 = undefined;
    const thread = try std.Thread.spawn(.{}, Peer.run, .{ &server, &seen, &names });
    defer thread.join();

    const d = try db_mod.openMain(a);
    defer d.close();
    try d.exec("DELETE FROM replay; INSERT INTO replay(id,sha256,ex,clear,data) VALUES(1,'a',1,1,'r'),(2,'b',1,1,'r'),(3,'c',1,1,'r'),(4,'d',1,1,'r'),(5,'e',1,1,'r')");
    defer d.exec("DELETE FROM replay") catch {};
    const pending = [total]Pending{
        .{ .id = 1, .sha = "a", .path = "/a.bms" }, .{ .id = 2, .sha = "b", .path = "/b.bms" }, .{ .id = 3, .sha = "c", .path = "/c.bms" },
        .{ .id = 4, .sha = "d", .path = "/d.bms" }, .{ .id = 5, .sha = "e", .path = "/e.bms" },
    };
    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var s: Sync = .{ .gpa = a, .base = base, .token = @constCast("t"), .upload = true };
    try pushAllReplays(&s, &pending);
    try std.testing.expectEqual(@as(u32, total), s.accepted);
    try std.testing.expectEqual(@as(u32, 0), s.failed);
    try std.testing.expectEqual(@as(u32, total), s.progress.load(.acquire));
}

test "only scores the server cannot match become claims" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const d = try db_mod.Db.open(":memory:", a, false);
    defer d.close();
    try db_mod.initSchema(d);
    const imported: [64]u8 = @splat('a');
    const matched: [64]u8 = @splat('b');
    const claimed: [64]u8 = @splat('c');
    const upper: [64]u8 = @splat('A');
    const empty: [64]u8 = @splat('d');
    for ([_]db_mod.ScoreIn{
        .{ .sha256 = "too short", .clear = 5, .ex = 50, .counts = @splat(0), .max_combo = 9, .miss = 3, .date = 7 },
        .{ .sha256 = &upper, .clear = 5, .ex = 50, .counts = @splat(0), .max_combo = 9, .miss = 3, .date = 7 },
        .{ .sha256 = &imported, .clear = 5, .ex = 50, .counts = @splat(0), .max_combo = 9, .miss = 3, .date = 7 },
        .{ .sha256 = &matched, .clear = 4, .ex = 100, .counts = @splat(0), .max_combo = 9, .miss = 3, .date = 7 },
        .{ .sha256 = &claimed, .clear = 4, .ex = 80, .counts = @splat(0), .max_combo = 9, .miss = 3, .date = 7 },
        .{ .sha256 = &empty, .clear = 0, .ex = 0, .counts = @splat(0), .max_combo = 0, .miss = 0, .date = 7 },
    }) |s| try db_mod.recordScore(d, s);
    const mine = [_]MyScore{
        .{ .sha256 = &matched, .ex = 100, .clear = 4, .miss = 0, .max_combo = 0, .date = 0 },
        .{ .sha256 = &claimed, .ex = 80, .clear = 4, .miss = 0, .max_combo = 0, .date = 0, .verified = false },
    };
    const p = try pendingClaims(arena.allocator(), d, &mine);
    try std.testing.expectEqual(@as(usize, 1), p.len);
    try std.testing.expectEqualStrings(&imported, p[0].sha256);
    try std.testing.expectEqual(@as(u32, 50), p[0].ex);
    try std.testing.expectEqual(@as(u32, 3), p[0].miss);
}

test "a claim does not stop a replay from being sent" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const d = try db_mod.Db.open(":memory:", a, false);
    defer d.close();
    try db_mod.initSchema(d);
    try d.exec("INSERT INTO replay(sha256,ex,clear) VALUES('x',50,1)");
    const mine = [_]MyScore{.{ .sha256 = "x", .ex = 90, .clear = 4, .miss = 0, .max_combo = 0, .date = 0, .verified = false }};
    try std.testing.expectEqual(@as(usize, 1), (try pendingReplays(arena.allocator(), d, &mine)).len);
}

test "downloaded scores keep local bests and play counts, and repeat safely" {
    const a = std.testing.allocator;
    const d = try db_mod.Db.open(":memory:", a, false);
    defer d.close();
    try db_mod.initSchema(d);
    const sha: [64]u8 = @splat('a');
    const other: [64]u8 = @splat('b');
    try db_mod.recordScore(d, .{ .sha256 = &sha, .clear = 6, .ex = 80, .counts = @splat(1), .max_combo = 9, .miss = 2, .date = 5 });
    const down = [_]MyScore{
        .{ .sha256 = &sha, .ex = 100, .clear = 4, .miss = 7, .max_combo = 30, .date = 9 },
        .{ .sha256 = &other, .ex = 10, .clear = 1, .miss = 3, .max_combo = 4, .date = 2 },
        .{ .sha256 = "short", .ex = 1, .clear = 1, .miss = 0, .max_combo = 1, .date = 1 },
    };
    try std.testing.expectEqual(@as(u32, 2), try mergeMine(d, &down));
    try std.testing.expectEqual(@as(u32, 2), try mergeMine(d, &down));
    const q = try d.prepare("SELECT clear,ex,max_combo,min_bp,playcount,date FROM score ORDER BY sha256");
    defer q.deinit();
    try std.testing.expect(try q.step());
    for ([_]i64{ 6, 100, 30, 2, 1, 9 }, 0..) |want, i| try std.testing.expectEqual(want, q.int(@intCast(i)));
    try std.testing.expect(try q.step());
    for ([_]i64{ 1, 10, 4, 3, 0, 2 }, 0..) |want, i| try std.testing.expectEqual(want, q.int(@intCast(i)));
    try std.testing.expect(!try q.step());
}

test "board answers the ids skins read" {
    const a = std.testing.allocator;
    var scores = [_]Standing.Score{
        .{ .name = "alice", .ex = 90, .clear = 6 },
        .{ .name = "bob", .ex = 80, .clear = 4, .verified = false },
        .{ .name = "me", .ex = 70, .clear = 8, .you = true },
    };
    const clears = [_]i64{ 0, 1, 0, 0, 1, 0, 1, 0, 1, 0, 0 };
    var b: Board = .{ .gpa = a };
    fillBoard(&b, .{ .scores = &scores, .rank = 3, .total = 4, .clears = &clears });
    defer a.free(b.rows);
    b.prev_rank = 4;
    try std.testing.expectEqual(@as(?i64, null), b.number(179)); // still pending
    try std.testing.expectEqualStrings("", b.name(120));
    b.state.store(Board.accepted, .release);
    try std.testing.expectEqual(@as(?i64, 3), b.number(179));
    try std.testing.expectEqual(@as(?i64, 4), b.number(180));
    try std.testing.expectEqual(@as(?i64, 75), b.number(181));
    try std.testing.expectEqual(@as(?i64, 4), b.number(182));
    try std.testing.expectEqual(@as(?i64, 1), b.number(210)); // failed count
    try std.testing.expectEqual(@as(?i64, 25), b.number(211)); // failed percent
    try std.testing.expectEqual(@as(?i64, 1), b.number(216)); // hard count
    try std.testing.expectEqual(@as(?i64, 1), b.number(218)); // full combo count
    try std.testing.expectEqual(@as(?i64, 90), b.number(380));
    try std.testing.expectEqual(@as(?i64, 3), b.number(392)); // place shown for row 3
    try std.testing.expectEqual(@as(?i64, 8), b.number(10392));
    try std.testing.expectEqual(@as(?i64, std.math.minInt(i32)), b.number(383)); // an empty row hides
    try std.testing.expectEqualStrings("alice", b.name(120));
    try std.testing.expectEqualStrings("bob (unv.)", b.name(121));
    try std.testing.expectEqualStrings("YOU", b.name(122));
    try std.testing.expectEqualStrings("", b.name(123));
    b.scroll(1);
    try std.testing.expectEqualStrings("bob (unv.)", b.name(120));
    try std.testing.expectEqual(@as(?i64, 2), b.number(390));
    try std.testing.expectEqual(@as(?i64, 80), b.number(380));
    b.scroll(99);
    try std.testing.expectEqualStrings("YOU", b.name(120));
    b.scroll(-99);
    try std.testing.expectEqualStrings("alice", b.name(120));
    b.setPosition(0.5);
    try std.testing.expectEqual(@as(usize, 1), b.offset);
    b.setPosition(1);
    try std.testing.expectEqual(@as(usize, 1), b.offset);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), b.position(), 0.001);
}

test "the list opens on a player far down it" {
    const a = std.testing.allocator;
    const scores = try a.alloc(Standing.Score, 30);
    defer a.free(scores);
    @memset(scores, .{ .name = "x", .ex = 1, .clear = 1 });
    scores[19].you = true;
    var b: Board = .{ .gpa = a };
    fillBoard(&b, .{ .scores = scores, .rank = 20, .total = 30 });
    defer a.free(b.rows);
    b.state.store(Board.accepted, .release);
    try std.testing.expectEqual(@as(usize, 15), b.offset);
    try std.testing.expectEqualStrings("YOU", b.name(124));
    try std.testing.expectEqual(@as(?i64, 20), b.number(394));
}

test "format selection" {
    try std.testing.expectEqual(@as(u8, 3), chartFormat("a.BMSON"));
    try std.testing.expectEqual(@as(u8, 2), chartFormat("a.pms"));
    try std.testing.expectEqual(@as(u8, 1), chartFormat("a.bme"));
}

test "rows" {
    const a = std.testing.allocator;
    const v = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"x\",\"ex\":5,\"miss\":1}", .{});
    defer v.deinit();
    const s = try formatRow(a, v.value, 1);
    defer a.free(s);
    try std.testing.expectEqualStrings("1. x   EX 5   BP 1", s);
    const w = try std.json.parseFromSlice(std.json.Value, a, "{\"name\":\"x\",\"ex\":5,\"miss\":1,\"verified\":false}", .{});
    defer w.deinit();
    const t = try formatRow(a, w.value, 1);
    defer a.free(t);
    try std.testing.expectEqualStrings("1. x   EX 5   BP 1   (unverified)", t);
}
