//! A versus room on the IR server: one thread holds the player's WebSocket, sends commands and the score, and
//! keeps the room the server answers with. Nothing about a room goes over plain HTTP.
const std = @import("std");
const c = @import("c");
const http = @import("../platform/http.zig");

pub const code_len = 6;
pub const max_players = 8;
/// How often the score goes out, and the room comes back.
const report_ms = 100;
/// Tries to reconnect in a row before the room counts as lost.
const reconnect_tries = 5;
const reconnect_ms = 1000;
/// Far above any room: eight names and a title.
const max_message = 16 << 10;

pub const Player = struct {
    id: u32 = 0,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    you: bool = false,
    host: bool = false,
    has_chart: bool = false,
    ex: u32 = 0,
    judged: u32 = 0,
    gauge: f32 = 0,
    done: bool = false,
    /// Set by the server's replay check. Nothing else decides a winner.
    final_ex: ?u32 = null,

    pub fn name(p: *const Player) []const u8 {
        return p.name_buf[0..p.name_len];
    }
};

pub const Status = enum { connecting, joined, full, not_found, failed, lost };

pub const View = struct {
    status: Status = .connecting,
    code: [code_len]u8 = @splat(' '),
    sha256: [64]u8 = @splat(0),
    title_buf: [256]u8 = undefined,
    title_len: u16 = 0,
    round: u32 = 0,
    seed: u64 = 0,
    /// SDL ticks when this round's song starts, 0 before a start.
    start_tick: u64 = 0,
    start_round: u32 = 0,
    host: bool = false,
    /// The server did not take the host's last start or chart.
    order_failed: bool = false,
    players: [max_players]Player = @splat(.{}),
    count: u8 = 0,

    pub fn title(v: *const View) []const u8 {
        return v.title_buf[0..v.title_len];
    }
};

pub const Report = struct {
    round: u32 = 0,
    has_chart: bool = false,
    ex: u32 = 0,
    judged: u32 = 0,
    gauge: f32 = 0,
    done: bool = false,
};

const Wire = struct {
    code: []const u8 = "",
    sha256: []const u8 = "",
    title: []const u8 = "",
    round: u32 = 0,
    seed: []const u8 = "0",
    starts_in_ms: ?u64 = null,
    host: bool = false,
    players: []const struct {
        id: u32 = 0,
        name: []const u8 = "",
        you: bool = false,
        host: bool = false,
        has_chart: bool = false,
        ex: u32 = 0,
        judged: u32 = 0,
        gauge: f32 = 0,
        done: bool = false,
        final_ex: ?u32 = null,
    } = &.{},
};

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// The first answer sets the clock: a later, slower one would move it under a loading player.
fn setStart(v: *View, round: u32, ms: u64, now: u64) void {
    if (v.start_round == round) return;
    v.start_round = round;
    v.start_tick = now + @min(ms, 60_000);
}

/// The server may be anyone's, so what it sends is cut to size. `now` is when the answer arrived.
pub fn applyAnswer(v: *View, a: std.mem.Allocator, body: []const u8, now: u64) !void {
    const w = try std.json.parseFromSliceLeaky(Wire, a, body, .{ .ignore_unknown_fields = true });
    if (validCode(w.code)) @memcpy(&v.code, w.code);
    if (w.sha256.len == v.sha256.len) @memcpy(&v.sha256, w.sha256);
    v.title_len = @intCast(copyInto(&v.title_buf, w.title));
    v.round = w.round;
    v.seed = std.fmt.parseInt(u64, w.seed, 10) catch 0;
    v.host = w.host;
    if (w.starts_in_ms) |ms| setStart(v, w.round, ms, now);
    v.count = @intCast(@min(w.players.len, max_players));
    for (w.players[0..v.count], v.players[0..v.count]) |in, *out| {
        out.* = .{ .id = in.id, .you = in.you, .host = in.host, .has_chart = in.has_chart, .ex = in.ex, .judged = in.judged, .gauge = if (std.math.isFinite(in.gauge)) in.gauge else 0, .done = in.done, .final_ex = in.final_ex };
        out.name_len = @intCast(copyInto(&out.name_buf, in.name));
    }
}

/// A code goes into a URL, and both the player and the server can send anything.
pub fn validCode(code: []const u8) bool {
    if (code.len != code_len) return false;
    for (code) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    return true;
}

pub const Room = struct {
    gpa: std.mem.Allocator,
    base: []u8,
    token: []u8,
    join_code: [code_len]u8,
    /// Null opens the room with no chart, for the host to pick one in it.
    create_sha: ?[64]u8,
    create_title: []u8,
    creating: bool,
    lock: *c.SDL_Mutex,
    view: View = .{},
    report: Report = .{},
    want_start: bool = false,
    want_sha: ?[64]u8 = null,
    want_title: []u8 = &.{},
    quit: std.atomic.Value(bool) = .init(false),

    fn open(gpa: std.mem.Allocator, base: []const u8, token: []const u8) !*Room {
        const r = try gpa.create(Room);
        errdefer gpa.destroy(r);
        r.* = .{
            .gpa = gpa,
            .base = try gpa.dupe(u8, base),
            .token = try gpa.dupe(u8, token),
            .join_code = @splat(' '),
            .create_sha = null,
            .create_title = &.{},
            .creating = false,
            .lock = c.SDL_CreateMutex() orelse return error.NoMutex,
        };
        return r;
    }

    fn run(r: *Room) !void {
        const t = c.SDL_CreateThread(thread, "versus", r) orelse return error.NoThread;
        c.SDL_DetachThread(t);
    }

    pub fn create(gpa: std.mem.Allocator, base: []const u8, token: []const u8, sha: []const u8, title: []const u8) !*Room {
        const r = try open(gpa, base, token);
        r.creating = true;
        if (sha.len == 64) r.create_sha = sha[0..64].*;
        r.create_title = try gpa.dupe(u8, title);
        try r.run();
        return r;
    }

    pub fn join(gpa: std.mem.Allocator, base: []const u8, token: []const u8, code: []const u8) !*Room {
        if (!validCode(code)) return error.BadCode;
        const r = try open(gpa, base, token);
        _ = copyInto(&r.join_code, code);
        for (&r.join_code) |*ch| ch.* = std.ascii.toUpper(ch.*);
        try r.run();
        return r;
    }

    /// Lets go of the room. A hung request cannot hold the game: the thread cleans up after itself.
    pub fn leave(r: *Room) void {
        r.quit.store(true, .release);
    }

    pub fn snapshot(r: *Room) View {
        _ = c.SDL_LockMutex(r.lock);
        defer _ = c.SDL_UnlockMutex(r.lock);
        return r.view;
    }

    pub fn setReport(r: *Room, report: Report) void {
        _ = c.SDL_LockMutex(r.lock);
        defer _ = c.SDL_UnlockMutex(r.lock);
        r.report = report;
    }

    pub fn start(r: *Room) void {
        _ = c.SDL_LockMutex(r.lock);
        defer _ = c.SDL_UnlockMutex(r.lock);
        r.want_start = true;
    }

    pub fn setChart(r: *Room, sha: []const u8, title: []const u8) void {
        if (sha.len != 64) return;
        const copy = r.gpa.dupe(u8, title) catch return;
        _ = c.SDL_LockMutex(r.lock);
        defer _ = c.SDL_UnlockMutex(r.lock);
        r.gpa.free(r.want_title);
        r.want_title = copy;
        r.want_sha = sha[0..64].*;
    }

    fn setStatus(r: *Room, status: Status) void {
        _ = c.SDL_LockMutex(r.lock);
        defer _ = c.SDL_UnlockMutex(r.lock);
        r.view.status = status;
    }

    fn command(a: std.mem.Allocator, fields: anytype) ![]u8 {
        return std.json.Stringify.valueAlloc(a, fields, .{});
    }

    /// One command and its answer: the room, applied, or the status of an error.
    fn ask(r: *Room, a: std.mem.Allocator, ws: *http.WebSocket, buf: []u8, text: []const u8) !u16 {
        try ws.send(text);
        const body = try ws.receive(buf);
        const kind = try std.json.parseFromSliceLeaky(struct { type: []const u8 = "", status: u16 = 0 }, a, body, .{ .ignore_unknown_fields = true });
        if (!std.mem.eql(u8, kind.type, "room")) return if (kind.status != 0) kind.status else 500;
        const now = c.SDL_GetTicks();
        _ = c.SDL_LockMutex(r.lock);
        defer _ = c.SDL_UnlockMutex(r.lock);
        r.view.status = .joined;
        try applyAnswer(&r.view, a, body, now);
        r.join_code = r.view.code;
        return 200;
    }

    /// The host's start or chart. Refused, it is not sent again: by then the host may want something else.
    fn order(r: *Room, a: std.mem.Allocator, ws: *http.WebSocket, buf: []u8, text: []const u8) !void {
        if (try r.ask(a, ws, buf, text) == 200) return;
        _ = c.SDL_LockMutex(r.lock);
        defer _ = c.SDL_UnlockMutex(r.lock);
        r.view.order_failed = true;
    }

    /// Enters the room, then reports until the game lets go. Null when the server refused the room.
    fn session(r: *Room, step: *std.heap.ArenaAllocator, ws: *http.WebSocket, entered: *bool, misses: *u32) !?Status {
        var buf: [max_message]u8 = undefined;
        const a = step.allocator();
        const enter = if (r.creating and !entered.*)
            try command(a, .{ .type = "create", .sha256 = if (r.create_sha) |*s| @as([]const u8, s) else "", .title = r.create_title })
        else
            try command(a, .{ .type = "join", .code = @as([]const u8, &r.join_code) });
        switch (try r.ask(a, ws, &buf, enter)) {
            200 => {},
            404 => return .not_found,
            409 => return .full,
            else => return .failed,
        }
        entered.* = true;
        misses.* = 0;
        while (!r.quit.load(.acquire)) {
            _ = step.reset(.retain_capacity);
            const sent_at = c.SDL_GetTicks();
            _ = c.SDL_LockMutex(r.lock);
            const start_it = r.want_start;
            r.want_start = false;
            const sha = r.want_sha;
            r.want_sha = null;
            const title = a.dupe(u8, r.want_title) catch "";
            if (start_it or sha != null) r.view.order_failed = false;
            const report = r.report;
            _ = c.SDL_UnlockMutex(r.lock);
            if (sha) |*s| try r.order(a, ws, &buf, try command(a, .{ .type = "chart", .sha256 = @as([]const u8, s), .title = title }));
            if (start_it) try r.order(a, ws, &buf, try command(a, .{ .type = "start" }));
            if (try r.ask(a, ws, &buf, try command(a, .{ .type = "report", .round = report.round, .has_chart = report.has_chart, .ex = report.ex, .judged = report.judged, .gauge = report.gauge, .done = report.done })) != 200) return .lost;
            const spent = c.SDL_GetTicks() - sent_at;
            if (spent < report_ms) c.SDL_Delay(@intCast(report_ms - spent));
        }
        return null;
    }

    fn thread(ud: ?*anyopaque) callconv(.c) c_int {
        const r: *Room = @ptrCast(@alignCast(ud));
        r.loop();
        // The game still holds the room until it lets go, even after the server has dropped it.
        while (!r.quit.load(.acquire)) c.SDL_Delay(report_ms);
        const gpa = r.gpa;
        gpa.free(r.base);
        gpa.free(r.token);
        gpa.free(r.create_title);
        gpa.free(r.want_title);
        c.SDL_DestroyMutex(r.lock);
        gpa.destroy(r);
        return 0;
    }

    /// A dropped connection is tried again, and joins the same room: closing it left the room on the server.
    fn loop(r: *Room) void {
        var arena = std.heap.ArenaAllocator.init(r.gpa);
        defer arena.deinit();
        var client = http.client(r.gpa);
        defer client.deinit();
        const al = arena.allocator();
        const auth = std.fmt.allocPrint(al, "Bearer {s}", .{r.token}) catch return r.setStatus(.failed);
        const hs = [_]std.http.Header{.{ .name = "authorization", .value = auth }};
        const url = std.fmt.allocPrint(al, "{s}/play", .{r.base}) catch return r.setStatus(.failed);
        var step = std.heap.ArenaAllocator.init(r.gpa);
        defer step.deinit();
        var entered = false;
        var misses: u32 = 0;
        while (!r.quit.load(.acquire)) {
            _ = step.reset(.retain_capacity);
            var ws: http.WebSocket = undefined;
            const ended = if (ws.open(&client, url, &hs)) blk: {
                defer ws.close();
                break :blk r.session(&step, &ws, &entered, &misses);
            } else |e| e;
            const status = ended catch |e| {
                std.log.warn("versus room: {t}", .{e});
                misses += 1;
                if (!entered) return r.setStatus(.failed);
                if (misses >= reconnect_tries) return r.setStatus(.lost);
                c.SDL_Delay(reconnect_ms);
                continue;
            };
            if (status) |st| return r.setStatus(if (entered and st != .lost) .lost else st);
            return;
        }
    }
};

test "a room code that could change the URL is refused" {
    try std.testing.expect(validCode("ABC234"));
    try std.testing.expect(!validCode("ABC23"));
    try std.testing.expect(!validCode("A/../B"));
    try std.testing.expect(!validCode("AB&C=1"));
    try std.testing.expectError(error.BadCode, Room.join(std.testing.allocator, "http://x", "t", "a b c"));
}

test "an answer is cut to size and the start clock is set once a round" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v: View = .{};
    const long: [300]u8 = @splat('x');
    const sha: [64]u8 = @splat('a');
    var players: std.ArrayList(u8) = .empty;
    for (0..12) |i| try players.print(a, "{s}{{\"name\":\"{s}\",\"ex\":{d},\"final_ex\":{s}}}", .{ if (i > 0) "," else "", &long, i, if (i == 1) "9" else "null" });
    const body = try std.fmt.allocPrint(a, "{{\"sha256\":\"{s}\",\"title\":\"{s}\",\"round\":2,\"seed\":\"18446744073709551615\",\"starts_in_ms\":5000,\"host\":true,\"players\":[{s}]}}", .{ &sha, &long, players.items });
    try applyAnswer(&v, a, body, 100);
    try std.testing.expectEqual(@as(u8, max_players), v.count);
    try std.testing.expectEqual(@as(usize, v.title_buf.len), v.title().len);
    try std.testing.expectEqual(@as(u8, 64), v.players[0].name_len);
    try std.testing.expectEqual(@as(?u32, 9), v.players[1].final_ex);
    try std.testing.expectEqual(std.math.maxInt(u64), v.seed);
    try std.testing.expectEqual(@as(u64, 5100), v.start_tick);
    try applyAnswer(&v, a, body, 400);
    try std.testing.expectEqual(@as(u64, 5100), v.start_tick);
    try std.testing.expectError(error.SyntaxError, applyAnswer(&v, a, "not json", 0));
}
