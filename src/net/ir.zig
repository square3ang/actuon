//! Background threads only, never during play timing.
const std = @import("std");
const i18n = @import("../ui/i18n.zig");
const tr = i18n.tr;
const c = @import("c");
const core = @import("actuon_core");
const http = @import("../platform/http.zig");
const fs = @import("../platform/fs.zig");
const db_mod = @import("../db/db.zig");

pub const Upload = struct {
    gpa: std.mem.Allocator,
    chart_path: []u8,
    replay: []u8,
    /// Empty outside a versus room.
    room: []u8,
    board: *Board,
};

/// Two owners: the player can start the next chart while a slow upload runs.
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
    /// One page of the ranking: place `first` + 1 onwards.
    rows: []Row = &.{},
    first: usize = 0,
    /// Only the UI thread touches it once the board is ready. A place, counted from 0 over the whole ranking.
    offset: usize = 0,
    /// Null in tests: no more pages are fetched.
    source: ?Source = null,
    page: std.atomic.Value(u8) = .init(page_idle),
    /// Written by the page thread before `page` becomes page_ready.
    next_rows: []Row = &.{},
    next_first: usize = 0,
    /// A page asked once is not asked again, so a server that ignores the offset is not asked every frame.
    asked: ?usize = null,

    pub const Source = struct { io: std.Io, base: []u8, token: []u8, sha: []u8 };
    pub const page_idle = 0;
    const page_busy = 1;
    pub const page_ready = 2;

    pub fn release(b: *Board) void {
        if (b.refs.fetchSub(1, .acq_rel) != 1) return;
        b.gpa.free(b.rows);
        b.gpa.free(b.next_rows);
        if (b.source) |s| {
            b.gpa.free(s.base);
            b.gpa.free(s.token);
            b.gpa.free(s.sha);
        }
        b.gpa.destroy(b);
    }

    fn places(b: *const Board) usize {
        return @intCast(@max(b.total, 0));
    }

    /// As beatoraja's AbstractResult: a wheel step is one row, and the slider's last place does nothing.
    pub fn scroll(b: *Board, rows: i32) void {
        if (!b.ready() or b.places() == 0) return;
        const to = @as(i64, @intCast(b.offset)) + rows;
        b.offset = @intCast(std.math.clamp(to, 0, @as(i64, @intCast(b.places())) - 1));
        b.update();
    }

    pub fn position(b: *const Board) f32 {
        if (!b.ready()) return 0;
        return @as(f32, @floatFromInt(b.offset)) / @as(f32, @floatFromInt(@max(b.places(), 1)));
    }

    pub fn setPosition(b: *Board, value: f32) void {
        if (!b.ready() or value < 0 or value >= 1) return;
        b.offset = @intFromFloat(@as(f32, @floatFromInt(b.places())) * value);
        b.update();
    }

    /// UI thread, every frame: takes a fetched page, and asks for the one the shown rows need.
    pub fn update(b: *Board) void {
        if (!b.ready()) return;
        switch (b.page.load(.acquire)) {
            page_busy => return,
            page_ready => {
                b.gpa.free(b.rows);
                b.rows = b.next_rows;
                b.first = b.next_first;
                b.next_rows = &.{};
                b.page.store(page_idle, .release);
            },
            else => {},
        }
        const start = b.pageWanted() orelse return;
        const src = b.source orelse return;
        b.asked = start;
        b.page.store(page_busy, .release);
        _ = b.refs.fetchAdd(1, .acq_rel);
        const f = b.gpa.create(PageFetch) catch return b.pageFailed();
        f.* = .{ .src = src, .board = b, .start = start };
        if (!runDetached(pageThread, "ir-page", f)) {
            b.gpa.destroy(f);
            b.pageFailed();
        }
    }

    fn pageFailed(b: *Board) void {
        b.page.store(page_idle, .release);
        b.release();
    }

    /// Centred on the shown rows, so scrolling either way stays inside it for a while.
    fn pageWanted(b: *const Board) ?usize {
        const end = @min(b.offset + rows_shown, b.places());
        if (b.offset >= b.first and end <= b.first + b.rows.len) return null;
        const start = b.offset -| page_len / 2;
        return if (b.asked == start) null else start;
    }

    pub fn ready(b: *const Board) bool {
        return b.state.load(.acquire) != pending;
    }

    pub fn placeText(b: *const Board, buf: []u8) []const u8 {
        return switch (b.state.load(.acquire)) {
            pending => tr("IR: loading..."),
            failed => tr("IR: unavailable"),
            else => if (b.total == 0)
                tr("IR: no scores yet")
            else if (b.rank == 0)
                i18n.bufPrint(buf, "IR: {d} players", .{b.total}) catch ""
            else
                i18n.bufPrint(buf, "IR: #{d} of {d}", .{ b.rank, b.total }) catch "",
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
        return if (at >= b.first and at - b.first < b.rows.len) &b.rows[at - b.first] else null;
    }
};

/// Skins show ten rows: ids 120 to 129 and 380 to 389.
const rows_shown = 10;
/// The most the server sends at once.
const page_len = 1000;

const PageFetch = struct { src: Board.Source, board: *Board, start: usize };

fn fetchPage(a: std.mem.Allocator, f: *PageFetch) !void {
    const s = f.src;
    const got = try fetchStanding(a, s.io, s.base, s.token, s.sha, f.start);
    f.board.next_rows = try toRows(f.board.gpa, got.scores);
    f.board.next_first = got.offset;
}

fn pageThread(ud: ?*anyopaque) callconv(.c) c_int {
    const f: *PageFetch = @ptrCast(@alignCast(ud));
    const b = f.board;
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    if (fetchPage(arena.allocator(), f)) |_| {
        b.page.store(Board.page_ready, .release);
    } else |e| {
        std.log.warn("IR ranking page: {t}", .{e});
        b.page.store(Board.page_idle, .release);
    }
    b.gpa.destroy(f);
    b.release();
    _ = detached_threads.fetchSub(1, .acq_rel);
    return 0;
}

const Standing = struct {
    const Score = struct { name: []const u8, ex: i64, clear: i64, verified: bool = true, you: bool = false };
    scores: []Score,
    /// An older server sends no offset and always its top rows, which this default then places right.
    offset: usize = 0,
    rank: i64 = 0,
    total: i64 = 0,
    clears: []const i64 = &.{},
};

fn fetchStanding(a: std.mem.Allocator, io: std.Io, base: []const u8, token: []const u8, sha: []const u8, offset: usize) !Standing {
    const url = try std.fmt.allocPrint(a, "{s}/scores/{s}?limit={d}&offset={d}", .{ base, sha, page_len, offset });
    const r = try http.request(a, io, .GET, url, null, try bearer(a, token));
    if (r.status != 200) return error.HttpStatus;
    return parseStanding(a, r.body);
}

/// The server may be anyone's: out-of-range places would overflow the board's sums and percents.
fn parseStanding(a: std.mem.Allocator, body: []const u8) !Standing {
    const got = try std.json.parseFromSliceLeaky(Standing, a, body, .{ .ignore_unknown_fields = true });
    if (got.total < 0 or got.total > std.math.maxInt(u32) or got.offset > got.total or got.rank < 0 or got.rank > got.total)
        return error.BadStanding;
    for (got.clears) |n| if (n < 0 or n > got.total) return error.BadStanding;
    return got;
}

fn toRows(gpa: std.mem.Allocator, scores: []const Standing.Score) ![]Board.Row {
    const rows = try gpa.alloc(Board.Row, scores.len);
    for (rows, scores) |*row, score| {
        // Short: skins leave little room before the score column.
        const label = if (score.you or score.verified) "" else " (unv.)";
        const shown = std.fmt.bufPrint(&row.name_buf, "{s}{s}", .{ if (score.you) "YOU" else score.name, label }) catch row.name_buf[0..0];
        row.name_len = shown.len;
        row.ex = score.ex;
        row.clear = score.clear;
    }
    return rows;
}

fn fillBoard(b: *Board, s: Standing) void {
    b.rank = s.rank;
    b.total = s.total;
    for (b.clears[0..@min(b.clears.len, s.clears.len)], s.clears[0..@min(b.clears.len, s.clears.len)]) |*d, v| d.* = v;
    // Opens on the player's own place, like beatoraja's MusicResult; a place past this page is fetched by update.
    b.offset = if (s.rank > 10) @intCast(@max(@min(s.rank - 5, s.total - 1), 0)) else 0;
    b.rows = toRows(b.gpa, s.scores) catch |e| {
        std.log.warn("IR ranking: {t}", .{e});
        return;
    };
    b.first = s.offset;
}

fn bearer(a: std.mem.Allocator, token: []const u8) ![]const std.http.Header {
    const hs = try a.alloc(std.http.Header, 1);
    hs[0] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) };
    return hs;
}

/// A whole room finishes at once and the server checks few replays at a time, and a round has no later sync.
fn sendScore(client: *std.http.Client, a: std.mem.Allocator, url: []const u8, upload: []const u8, hs: []const std.http.Header, room: []const u8) !http.Response {
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        const r = try http.send(client, a, .POST, url, upload, hs);
        if (!shouldRetryScore(r.status, room, tries)) return r;
        c.SDL_Delay(score_retry_ms);
    }
}

fn shouldRetryScore(status: u16, room: []const u8, tries: u32) bool {
    return status == 503 and room.len > 0 and tries < score_retries;
}

/// Sends chart and replay together, as the server keeps no chart. `prev_rank` gets the place before this score.
pub fn submit(gpa: std.mem.Allocator, client: *std.http.Client, base: []const u8, token: []const u8, sha: []const u8, chart_path: []const u8, replay: []const u8, room: []const u8, prev_rank: ?*i64) !u16 {
    // Without the file nothing says how the chart should be parsed.
    if (chart_path.len == 0) return error.NoChart;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const hs = try bearer(a, token);
    const chart = fs.readAlloc(a, client.io, chart_path, 16 << 20) catch return error.NoChart;
    const upload = try std.mem.concat(a, u8, &.{ chart, replay });
    const format = @backingInt(core.Format.of(chart_path));
    const url = try std.fmt.allocPrint(a, "{s}/scores/{s}?format={d}&chart={d}{s}{s}", .{ base, sha, format, chart.len, if (room.len > 0) "&room=" else "", room });
    const r = try sendScore(client, a, url, upload, hs, room);
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
    const s = u.board.source.?;
    var client = http.client(u.gpa, s.io);
    defer client.deinit();
    const code = submit(u.gpa, &client, s.base, s.token, s.sha, u.chart_path, u.replay, u.room, &u.board.prev_rank) catch |e| blk: {
        std.log.warn("IR upload: {t}", .{e});
        break :blk 0;
    };
    // Rankings are a bonus: without them the upload still counts.
    if (fetchStanding(a, s.io, s.base, s.token, s.sha, 0)) |after| fillBoard(u.board, after) else |e| std.log.warn("IR ranking: {t}", .{e});
    u.board.state.store(if (code == 200) Board.accepted else Board.failed, .release);
    u.board.release();
    const gpa = u.gpa;
    gpa.free(u.chart_path);
    gpa.free(u.replay);
    gpa.free(u.room);
    gpa.destroy(u);
    _ = detached_threads.fetchSub(1, .acq_rel);
    return 0;
}

var detached_threads: std.atomic.Value(u32) = .init(0);

fn runDetached(entry: *const fn (?*anyopaque) callconv(.c) c_int, name: [*:0]const u8, ud: ?*anyopaque) bool {
    _ = detached_threads.fetchAdd(1, .acq_rel);
    const t = c.SDL_CreateThread(entry, name, ud) orelse {
        _ = detached_threads.fetchSub(1, .acq_rel);
        return false;
    };
    c.SDL_DetachThread(t);
    return true;
}

/// At exit, because these threads allocate until they end. False when one is still stuck on a connection.
pub fn waitForThreads() bool {
    for (0..60) |_| {
        if (detached_threads.load(.acquire) == 0) return true;
        c.SDL_Delay(50);
    }
    return false;
}

fn rankingThread(ud: ?*anyopaque) callconv(.c) c_int {
    const b: *Board = @ptrCast(@alignCast(ud));
    const s = b.source.?;
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    if (fetchStanding(arena.allocator(), s.io, s.base, s.token, s.sha, 0)) |got| {
        fillBoard(b, got);
        b.state.store(Board.accepted, .release);
    } else |e| {
        std.log.warn("IR ranking: {t}", .{e});
        b.state.store(Board.failed, .release);
    }
    b.release();
    _ = detached_threads.fetchSub(1, .acq_rel);
    return 0;
}

/// Keeps where it came from, to fetch more pages as the player scrolls.
fn newBoard(gpa: std.mem.Allocator, io: std.Io, base: []const u8, token: []const u8, sha: []const u8) ?*Board {
    const board = gpa.create(Board) catch return null;
    board.* = .{ .gpa = gpa, .source = .{
        .io = io,
        .base = gpa.dupe(u8, base) catch return null,
        .token = gpa.dupe(u8, token) catch return null,
        .sha = gpa.dupe(u8, sha) catch return null,
    } };
    return board;
}

/// The caller owns one reference, as with startUpload.
pub fn startRanking(gpa: std.mem.Allocator, io: std.Io, base: []const u8, token: []const u8, sha: []const u8) ?*Board {
    const board = newBoard(gpa, io, base, token, sha) orelse return null;
    if (!runDetached(rankingThread, "ir-ranking", board)) {
        board.state.store(Board.failed, .release);
        board.release();
    }
    return board;
}

/// The caller owns one reference to the answer and gives it back with release.
pub fn startUpload(gpa: std.mem.Allocator, io: std.Io, base: []const u8, token: []const u8, sha: []const u8, chart_path: []const u8, replay: []const u8, room: []const u8) ?*Board {
    const board = newBoard(gpa, io, base, token, sha) orelse return null;
    const u = gpa.create(Upload) catch return null;
    u.* = .{
        .gpa = gpa,
        .chart_path = gpa.dupe(u8, chart_path) catch return null,
        .replay = gpa.dupe(u8, replay) catch return null,
        .room = gpa.dupe(u8, room) catch return null,
        .board = board,
    };
    if (!runDetached(uploadThread, "ir-upload", u)) {
        board.state.store(Board.failed, .release);
        board.release();
    }
    return board;
}

/// Two owners: with no timeout, the UI may leave one hanging.
pub const Query = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
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
    _ = detached_threads.fetchSub(1, .acq_rel);
    return 0;
}

fn run(q: *Query) !void {
    var arena = std.heap.ArenaAllocator.init(q.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const hs: []const std.http.Header = if (q.token.len > 0) try bearer(a, q.token) else &.{};
    const r = try http.request(a, q.io, if (q.body != null) .POST else .GET, q.url, q.body, hs);
    if (r.status != 200) return error.HttpStatus;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, r.body, .{});
    if (v != .object) return error.BadAnswer;
    const list = v.object.get("scores") orelse v.object.get("players") orelse return error.BadAnswer;
    if (list != .array) return error.BadAnswer;
    for (list.array.items, 1..) |row, i| try q.lines.append(q.gpa, try formatRow(q.gpa, row, i));
}

pub fn startQuery(gpa: std.mem.Allocator, io: std.Io, url: []const u8, token: []const u8, body: ?[]const u8) ?*Query {
    const q = gpa.create(Query) catch return null;
    q.* = .{
        .gpa = gpa,
        .io = io,
        .url = gpa.dupe(u8, url) catch return null,
        .token = gpa.dupe(u8, token) catch return null,
        .body = if (body) |b| gpa.dupe(u8, b) catch return null else null,
    };
    if (!runDetached(queryThread, "ir-query", q)) {
        q.failed = true;
        q.done.store(true, .release);
        q.destroy();
    }
    return q;
}

const MyScore = struct { sha256: []const u8, ex: u32, clear: u32, miss: u32, max_combo: u32, date: i64, verified: bool = true };

fn fetchMine(a: std.mem.Allocator, io: std.Io, base: []const u8, token: []const u8) ![]MyScore {
    const r = try http.request(a, io, .GET, try std.fmt.allocPrint(a, "{s}/me/scores", .{base}), null, try bearer(a, token));
    if (r.status != 200) return error.HttpStatus;
    const v = try std.json.parseFromSliceLeaky(struct { scores: []MyScore }, a, r.body, .{ .ignore_unknown_fields = true });
    return v.scores;
}

/// Bests only rise; judge and play counts stay local (the server keeps none), so downloading twice changes nothing.
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
            // No source: it brings no counts, and naming one would make the next import look new and add its totals again.
            .source = "",
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

/// Best first, so one upload covers its chart. shortcut: a replay that only improves combo or BP is not sent, compare those too if players ask for it.
fn pendingReplays(a: std.mem.Allocator, d: db_mod.Db, mine: []const MyScore) ![]Pending {
    var best: std.StringHashMapUnmanaged(Best) = .empty;
    // A claim does not count: a replay that only matches it still turns it into a verified score.
    for (mine) |s| if (s.verified) try best.put(a, s.sha256, .{ .ex = s.ex, .clear = s.clear });
    const st = try d.prepare(
        \\SELECT r.id,r.sha256,r.ex,r.clear,COALESCE((SELECT path FROM song s WHERE s.sha256=r.sha256 LIMIT 1),'')
        \\FROM replay r WHERE r.ln_mode=0 ORDER BY r.sha256, r.ex DESC, r.clear DESC
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

fn pendingClaims(a: std.mem.Allocator, d: db_mod.Db, mine: []const MyScore) ![]MyScore {
    var best: std.StringHashMapUnmanaged(Best) = .empty;
    for (mine) |s| {
        const got = try best.getOrPutValue(a, s.sha256, .{ .ex = 0, .clear = 0 });
        got.value_ptr.* = .{ .ex = @max(s.ex, got.value_ptr.ex), .clear = @max(s.clear, got.value_ptr.clear) };
    }
    const st = try d.prepare("SELECT sha256,ex,clear,min_bp,max_combo,date FROM score WHERE mode=0 AND (ex>0 OR clear>0)");
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
const score_retries = 30;
const score_retry_ms = 1000;

fn sendClaims(s: *Sync, a: std.mem.Allocator, claims: []const MyScore) !void {
    const url = try std.fmt.allocPrint(a, "{s}/me/claims", .{s.base});
    const hs = try bearer(a, s.token);
    var i: usize = 0;
    while (i < claims.len) : (i += claim_batch) {
        const part = claims[i..@min(i + claim_batch, claims.len)];
        const body = try std.json.Stringify.valueAlloc(a, .{ .scores = part }, .{});
        const r = try http.request(a, s.io, .POST, url, body, hs);
        if (r.status == 200) s.claimed += @intCast(part.len) else s.failed += @intCast(part.len);
    }
}

pub const Sync = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
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

/// The server checks one replay per player at a time and answers 503 to a second.
const push_workers = 1;
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
        const code = submit(s.gpa, client, s.base, s.token, p.sha, p.path, replay, "", null) catch |e| switch (e) {
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
    var client = http.client(w.s.gpa, w.s.io);
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
    const pending = try pendingReplays(a, d, try fetchMine(a, s.io, s.base, s.token));
    s.total.store(@intCast(pending.len), .release);
    try pushAllReplays(s, pending);
    // Asked again because the replays above just changed the answer.
    try sendClaims(s, a, try pendingClaims(a, d, try fetchMine(a, s.io, s.base, s.token)));
}

fn pullAll(s: *Sync, d: db_mod.Db) !void {
    var arena = std.heap.ArenaAllocator.init(s.gpa);
    defer arena.deinit();
    s.accepted = try mergeMine(d, try fetchMine(arena.allocator(), s.io, s.base, s.token));
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

pub fn startSync(gpa: std.mem.Allocator, io: std.Io, base: []const u8, token: []const u8, upload: bool) ?*Sync {
    const s = gpa.create(Sync) catch return null;
    s.* = .{
        .gpa = gpa,
        .io = io,
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

pub fn requestToken(a: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8, password: []const u8, register: bool) !AccountReply {
    const body = try std.json.Stringify.valueAlloc(a, .{ .name = name, .password = password }, .{});
    const url = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, if (register) "register" else "login" });
    const r = try http.request(a, io, .POST, url, body, &.{});
    if (r.status != 200) return .{ .status = r.status, .body = r.body, .token = null };
    const v = try std.json.parseFromSliceLeaky(struct { token: []const u8 }, a, r.body, .{ .ignore_unknown_fields = true });
    return .{ .status = r.status, .body = r.body, .token = v.token };
}

pub const AccountAction = enum { register, login, rename };

pub fn accountRefusal(status: u16, action: AccountAction) []const u8 {
    return switch (status) {
        400 => if (action == .rename) tr("Name must be 1-32 letters, digits or _ - . /") else tr("Name must be 1-32 letters, digits or _ - . /, and password at least 8"),
        401 => if (action == .rename) tr("Sign in again first") else tr("Wrong name or password"),
        409 => tr("That name is taken"),
        429 => tr("Too many attempts, try again later"),
        else => tr("The IR server refused"),
    };
}

fn requestRename(a: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8, token: []const u8) !u16 {
    const body = try std.json.Stringify.valueAlloc(a, .{ .name = name }, .{});
    const url = try std.fmt.allocPrint(a, "{s}/me/name", .{base});
    return (try http.request(a, io, .POST, url, body, try bearer(a, token))).status;
}

pub const Account = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
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
        s.status = try requestRename(a, s.io, s.base, s.name, s.secret);
        return;
    }
    const r = try requestToken(a, s.io, s.base, s.name, s.secret, s.action == .register);
    s.status = r.status;
    if (r.token) |t| s.token = try s.gpa.dupe(u8, t);
}

pub fn startAccount(gpa: std.mem.Allocator, io: std.Io, base: []const u8, name: []const u8, secret: []const u8, action: AccountAction) ?*Account {
    const s = gpa.create(Account) catch return null;
    s.* = .{
        .gpa = gpa,
        .io = io,
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
    const b = startRanking(std.testing.allocator, std.testing.io, "http://127.0.0.1:1", "t", "a").?;
    defer b.release();
    while (!b.ready()) c.SDL_Delay(5);
    try std.testing.expectEqual(@as(u8, Board.failed), b.state.load(.acquire));
    try std.testing.expect(waitForThreads());
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
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const total = 5;
    const Peer = struct {
        fn run(listener: *std.Io.net.Server, seen: *[total + 1][]const u8, names: *[total + 1][64]u8, sizes: *[total + 1]usize, charts: *[total + 1]usize) void {
            for (seen, names, sizes, charts, 0..) |*one, *name, *size, *chart, n| {
                const stream = listener.accept(std.testing.io) catch return;
                defer stream.close(std.testing.io);
                var in_buf: [1024]u8 = undefined;
                var reader = stream.reader(std.testing.io, &in_buf);
                const start = reader.interface.takeDelimiterInclusive('\n') catch return;
                const at = std.mem.indexOf(u8, start, "/scores/") orelse return;
                one.* = std.fmt.bufPrint(name, "{s}", .{start[at + 8 ..][0..1]}) catch return;
                if (std.mem.indexOf(u8, start, "&chart=")) |c_at| {
                    const digits = start[c_at + 7 ..];
                    const end = std.mem.indexOfNone(u8, digits, "0123456789") orelse digits.len;
                    chart.* = std.fmt.parseInt(usize, digits[0..end], 10) catch 0;
                }
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                    if (line.len == 2) break;
                    if (std.ascii.startsWithIgnoreCase(line, "content-length: "))
                        size.* = std.fmt.parseInt(usize, std.mem.trim(u8, line[16..], " \r\n"), 10) catch return;
                }
                reader.interface.discardAll(size.*) catch return;
                var out_buf: [128]u8 = undefined;
                var writer = stream.writer(std.testing.io, &out_buf);
                const status = if (n == 0) "503 Busy" else "200 OK";
                writer.interface.print("HTTP/1.1 {s}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", .{status}) catch return;
                writer.interface.flush() catch return;
            }
        }
    };
    var seen: [total + 1][]const u8 = @splat("");
    var names: [total + 1][64]u8 = undefined;
    var sizes: [total + 1]usize = @splat(0);
    var charts: [total + 1]usize = @splat(0);
    const thread = try std.Thread.spawn(.{}, Peer.run, .{ &server, &seen, &names, &sizes, &charts });
    defer thread.join();

    const d = try db_mod.openMain(a);
    defer d.close();
    try d.exec("DELETE FROM replay; INSERT INTO replay(id,sha256,ex,clear,data) VALUES(1,'a',1,1,'r'),(2,'b',1,1,'r'),(3,'c',1,1,'r'),(4,'d',1,1,'r'),(5,'e',1,1,'r')");
    defer d.exec("DELETE FROM replay") catch {};
    // Each upload is the chart, then the one-byte replay. Its size is read here: a Windows checkout adds CRs.
    const chart = "tests/charts/stop.bms";
    const chart_bytes = try fs.readAlloc(a, std.testing.io, chart, 1 << 20);
    defer a.free(chart_bytes);
    const chart_len = chart_bytes.len;
    const pending = [total]Pending{
        .{ .id = 1, .sha = "a", .path = chart }, .{ .id = 2, .sha = "b", .path = chart }, .{ .id = 3, .sha = "c", .path = chart },
        .{ .id = 4, .sha = "d", .path = chart }, .{ .id = 5, .sha = "e", .path = chart },
    };
    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var s: Sync = .{ .gpa = a, .io = std.testing.io, .base = base, .token = @constCast("t"), .upload = true };
    try pushAllReplays(&s, &pending);
    try std.testing.expectEqual(@as(u32, total), s.accepted);
    try std.testing.expectEqual(@as(u32, 0), s.failed);
    try std.testing.expectEqual(@as(u32, total), s.progress.load(.acquire));
    for (sizes, charts) |n, len| {
        try std.testing.expectEqual(chart_len, len);
        try std.testing.expectEqual(chart_len + 1, n);
    }
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
    fillBoard(&b, .{ .scores = &scores, .rank = 3, .total = 3, .clears = &clears });
    defer a.free(b.rows);
    b.prev_rank = 4;
    try std.testing.expectEqual(@as(?i64, null), b.number(179)); // still pending
    try std.testing.expectEqualStrings("", b.name(120));
    b.state.store(Board.accepted, .release);
    try std.testing.expectEqual(@as(?i64, 3), b.number(179));
    try std.testing.expectEqual(@as(?i64, 3), b.number(180));
    try std.testing.expectEqual(@as(?i64, 100), b.number(181));
    try std.testing.expectEqual(@as(?i64, 4), b.number(182));
    try std.testing.expectEqual(@as(?i64, 1), b.number(210)); // failed count
    try std.testing.expectEqual(@as(?i64, 33), b.number(211)); // failed percent
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

test "scrolling past the loaded page asks for the next and shows it once it comes" {
    const a = std.testing.allocator;
    const scores = try a.alloc(Standing.Score, page_len);
    defer a.free(scores);
    @memset(scores, .{ .name = "top", .ex = 1, .clear = 1 });
    var b: Board = .{ .gpa = a };
    fillBoard(&b, .{ .scores = scores, .rank = 2000, .total = 2500 });
    defer a.free(b.rows);
    b.state.store(Board.accepted, .release);
    try std.testing.expectEqual(@as(usize, 1995), b.offset);
    try std.testing.expectEqualStrings("", b.name(120));
    try std.testing.expectEqual(@as(?usize, 1495), b.pageWanted());
    b.scroll(-1995);
    try std.testing.expectEqual(@as(?usize, null), b.pageWanted());
    b.scroll(9999);
    try std.testing.expectEqual(@as(usize, 2499), b.offset);
    const page = try a.alloc(Standing.Score, 1);
    defer a.free(page);
    page[0] = .{ .name = "last", .ex = 1, .clear = 1 };
    b.next_rows = try toRows(a, page);
    b.next_first = 2499;
    b.page.store(Board.page_ready, .release);
    b.update();
    try std.testing.expectEqualStrings("last", b.name(120));
    try std.testing.expectEqual(@as(?i64, 2500), b.number(390));
    try std.testing.expectEqual(@as(u8, Board.page_idle), b.page.load(.acquire));
    b.asked = 0;
    b.scroll(-9999);
    try std.testing.expectEqual(@as(?usize, null), b.pageWanted());
}

test "a server's place numbers cannot underflow the list" {
    var b: Board = .{ .gpa = std.testing.allocator };
    fillBoard(&b, .{ .scores = &.{}, .rank = 50, .total = 0 });
    defer std.testing.allocator.free(b.rows);
    try std.testing.expectEqual(@as(usize, 0), b.offset);
}

test "a standing with places out of range is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try parseStanding(a, "{\"scores\":[],\"offset\":2,\"rank\":3,\"total\":3,\"clears\":[1,2]}");
    try std.testing.expectEqual(@as(usize, 2), got.offset);
    for ([_][]const u8{
        "{\"scores\":[],\"offset\":18446744073709551615,\"total\":3}",
        "{\"scores\":[],\"rank\":50,\"total\":-9223372036854775808}",
        "{\"scores\":[],\"rank\":50,\"total\":3}",
        "{\"scores\":[],\"total\":3,\"clears\":[9223372036854775807]}",
        "{\"scores\":[],\"total\":9223372036854775807}",
    }) |body| try std.testing.expectError(error.BadStanding, parseStanding(a, body));
}

test "the format numbers sent to the IR stay what the server reads" {
    try std.testing.expectEqual(@as(u8, 3), @backingInt(core.Format.of("a.BMSON")));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(core.Format.of("a.pms")));
    try std.testing.expectEqual(@as(u8, 1), @backingInt(core.Format.of("a.bme")));
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

test "a score in a room waits out a busy server, for a while" {
    try std.testing.expect(shouldRetryScore(503, "ABC234", 0));
    try std.testing.expect(!shouldRetryScore(503, "", 0));
    try std.testing.expect(!shouldRetryScore(200, "ABC234", 0));
    try std.testing.expect(!shouldRetryScore(503, "ABC234", score_retries));
}
