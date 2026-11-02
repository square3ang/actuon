//! A versus room on the IR server: one thread keeps asking it for the room and telling it this player's score.
const std = @import("std");
const c = @import("c");
const fs = @import("../platform/fs.zig");
const http = @import("../platform/http.zig");

pub const code_len = 6;
pub const max_players = 8;
const poll_ms = 250;
/// While live scores arrive over UDP, HTTP only carries names, the chart and checked scores.
const poll_with_live_ms = 1000;
const live_ms = 100;
/// This long with no UDP answer, as on a network that blocks it, and HTTP carries the scores again.
const live_stale_ms = 2000;
const live_request = "AU1Q";
const live_reply = "AU1R";
const live_request_len = 47;
const live_header_len = 17;
const live_entry_len = 17;
const no_start = std.math.maxInt(u32);
/// Polls in a row that may fail before the room counts as lost.
const lost_after = 20;

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

pub fn encodeLive(out: *[live_request_len]u8, code: *const [code_len]u8, key: *const [16]u8, seq: u32, r: Report) void {
    out[0..4].* = live_request.*;
    out[4..10].* = code.*;
    out[10..26].* = key.*;
    std.mem.writeInt(u32, out[26..30], seq, .little);
    std.mem.writeInt(u32, out[30..34], r.round, .little);
    std.mem.writeInt(u32, out[34..38], r.ex, .little);
    std.mem.writeInt(u32, out[38..42], r.judged, .little);
    std.mem.writeInt(u32, out[42..46], @bitCast(r.gauge), .little);
    out[46] = @as(u8, @intFromBool(r.has_chart)) | @as(u8, @intFromBool(r.done)) << 1;
}

/// A UDP answer updates scores only. False for a broken packet, or one that arrived after a newer one.
pub fn applyLive(v: *View, data: []const u8, last_seq: *u32, now: u64) bool {
    if (data.len < live_header_len or !std.mem.eql(u8, data[0..4], live_reply)) return false;
    const count = data[16];
    if (count > max_players or data.len != live_header_len + @as(usize, count) * live_entry_len) return false;
    const seq = std.mem.readInt(u32, data[4..8], .little);
    if (seq <= last_seq.*) return false;
    last_seq.* = seq;
    const round = std.mem.readInt(u32, data[8..12], .little);
    const starts_in = std.mem.readInt(u32, data[12..16], .little);
    if (starts_in != no_start) setStart(v, round, starts_in, now);
    var at: usize = live_header_len;
    for (0..count) |_| {
        defer at += live_entry_len;
        const id = std.mem.readInt(u32, data[at..][0..4], .little);
        for (v.players[0..v.count]) |*p| {
            if (p.id != id) continue;
            p.ex = std.mem.readInt(u32, data[at + 4 ..][0..4], .little);
            p.judged = std.mem.readInt(u32, data[at + 8 ..][0..4], .little);
            const gauge: f32 = @bitCast(std.mem.readInt(u32, data[at + 12 ..][0..4], .little));
            p.gauge = if (std.math.isFinite(gauge)) gauge else 0;
            p.done = data[at + 16] != 0;
        }
    }
    return true;
}

/// "host:port", the host possibly a bracketed IPv6 address.
fn parseLiveAddress(text: []const u8) ?struct { host: []const u8, port: u16 } {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    if (colon == 0) return null;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    if (port == 0) return null;
    return .{ .host = std.mem.trim(u8, text[0..colon], "[]"), .port = port };
}

/// The server may be anyone's, so what it sends is cut to size. `now` is when the answer arrived.
pub fn applyAnswer(v: *View, a: std.mem.Allocator, body: []const u8, now: u64) !void {
    const w = try std.json.parseFromSliceLeaky(Wire, a, body, .{ .ignore_unknown_fields = true });
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
    create_sha: [64]u8,
    create_title: []u8,
    creating: bool,
    lock: *c.SDL_Mutex,
    view: View = .{},
    report: Report = .{},
    want_start: bool = false,
    want_sha: ?[64]u8 = null,
    want_title: []u8 = &.{},
    quit: std.atomic.Value(bool) = .init(false),
    /// When UDP last answered, in SDL ticks.
    live_at: std.atomic.Value(u64) = .init(0),
    live_key: [16]u8 = @splat(0),
    live_address: [128]u8 = undefined,
    live_address_len: usize = 0,

    fn open(gpa: std.mem.Allocator, base: []const u8, token: []const u8) !*Room {
        const r = try gpa.create(Room);
        errdefer gpa.destroy(r);
        r.* = .{
            .gpa = gpa,
            .base = try gpa.dupe(u8, base),
            .token = try gpa.dupe(u8, token),
            .join_code = @splat(' '),
            .create_sha = @splat(0),
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
        if (sha.len == r.create_sha.len) @memcpy(&r.create_sha, sha);
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

    fn chartBody(a: std.mem.Allocator, sha: []const u8, title: []const u8) ![]u8 {
        return std.json.Stringify.valueAlloc(a, .{ .sha256 = sha, .title = title }, .{});
    }

    fn enter(r: *Room, a: std.mem.Allocator, client: *std.http.Client, hs: []const std.http.Header) !Status {
        const ans = if (r.creating)
            try http.send(client, a, .POST, try std.fmt.allocPrint(a, "{s}/rooms", .{r.base}), try chartBody(a, &r.create_sha, r.create_title), hs)
        else
            try http.send(client, a, .POST, try std.fmt.allocPrint(a, "{s}/rooms/{s}/join", .{ r.base, &r.join_code }), "", hs);
        switch (ans.status) {
            200 => {},
            404 => return .not_found,
            409 => return .full,
            else => return .failed,
        }
        const w = try std.json.parseFromSliceLeaky(struct { code: []const u8, key: []const u8 = "", udp: ?[]const u8 = null }, a, ans.body, .{ .ignore_unknown_fields = true });
        if (!validCode(w.code)) return .failed;
        @memcpy(&r.join_code, w.code);
        // Without both, this room's scores stay on HTTP.
        const udp = w.udp orelse return .joined;
        if (udp.len > r.live_address.len or w.key.len != 2 * r.live_key.len) return .joined;
        _ = std.fmt.hexToBytes(&r.live_key, w.key) catch return .joined;
        @memcpy(r.live_address[0..udp.len], udp);
        r.live_address_len = udp.len;
        return .joined;
    }

    fn openLive(r: *Room) !struct { std.Io.net.Socket, std.Io.net.IpAddress } {
        const target = parseLiveAddress(r.live_address[0..r.live_address_len]) orelse return error.BadAddress;
        const dest = try std.Io.net.IpAddress.resolve(fs.io, target.host, target.port);
        const any = try std.Io.net.IpAddress.parse(if (dest == .ip4) "0.0.0.0" else "::", 0);
        return .{ try any.bind(fs.io, .{ .mode = .dgram, .protocol = .udp }), dest };
    }

    fn liveThread(ud: ?*anyopaque) callconv(.c) c_int {
        const r: *Room = @ptrCast(@alignCast(ud));
        const socket, const dest = r.openLive() catch |e| {
            std.log.warn("versus live scores off: {t}", .{e});
            return 0;
        };
        defer socket.close(fs.io);
        var seq: u32 = 0;
        var last_seq: u32 = 0;
        var warned = false;
        var packet: [live_request_len]u8 = undefined;
        var reply: [live_header_len + max_players * live_entry_len + 1]u8 = undefined;
        while (!r.quit.load(.acquire)) {
            const sent_at = c.SDL_GetTicks();
            seq += 1;
            _ = c.SDL_LockMutex(r.lock);
            const report = r.report;
            _ = c.SDL_UnlockMutex(r.lock);
            encodeLive(&packet, &r.join_code, &r.live_key, seq, report);
            socket.send(fs.io, &dest, &packet) catch |e| if (!warned) {
                warned = true;
                std.log.warn("versus live scores: {t}", .{e});
            };
            if (socket.receiveTimeout(fs.io, &reply, .{ .duration = .{ .raw = .fromMilliseconds(live_ms), .clock = .awake } })) |msg| {
                const now = c.SDL_GetTicks();
                _ = c.SDL_LockMutex(r.lock);
                const applied = applyLive(&r.view, msg.data, &last_seq, now);
                _ = c.SDL_UnlockMutex(r.lock);
                if (applied) r.live_at.store(now, .release);
            } else |_| {}
            const spent = c.SDL_GetTicks() - sent_at;
            if (spent < live_ms) c.SDL_Delay(@intCast(live_ms - spent));
        }
        return 0;
    }

    fn liveHealthy(r: *Room) bool {
        const at = r.live_at.load(.acquire);
        return at != 0 and c.SDL_GetTicks() - at < live_stale_ms;
    }

    /// Cut short when UDP announces a round: its seed and chart come over HTTP.
    fn waitForNextPoll(r: *Room) void {
        const until = c.SDL_GetTicks() + @as(u64, if (r.liveHealthy()) poll_with_live_ms else poll_ms);
        while (c.SDL_GetTicks() < until and !r.quit.load(.acquire)) {
            _ = c.SDL_LockMutex(r.lock);
            const behind = r.view.start_round != 0 and r.view.start_round != r.view.round;
            _ = c.SDL_UnlockMutex(r.lock);
            if (behind) return;
            c.SDL_Delay(10);
        }
    }

    fn sendOrders(r: *Room, a: std.mem.Allocator, client: *std.http.Client, hs: []const std.http.Header) !void {
        _ = c.SDL_LockMutex(r.lock);
        const start_it = r.want_start;
        r.want_start = false;
        const sha = r.want_sha;
        r.want_sha = null;
        const title = a.dupe(u8, r.want_title) catch "";
        _ = c.SDL_UnlockMutex(r.lock);
        if (sha) |*s| _ = try http.send(client, a, .POST, try std.fmt.allocPrint(a, "{s}/rooms/{s}/chart", .{ r.base, &r.join_code }), try chartBody(a, s, title), hs);
        if (start_it) _ = try http.send(client, a, .POST, try std.fmt.allocPrint(a, "{s}/rooms/{s}/start", .{ r.base, &r.join_code }), "", hs);
    }

    fn poll(r: *Room, a: std.mem.Allocator, client: *std.http.Client, hs: []const std.http.Header, url: []const u8) !u16 {
        try r.sendOrders(a, client, hs);
        _ = c.SDL_LockMutex(r.lock);
        const report = r.report;
        _ = c.SDL_UnlockMutex(r.lock);
        const ans = try http.send(client, a, .POST, url, try std.json.Stringify.valueAlloc(a, report, .{}), hs);
        if (ans.status != 200) return ans.status;
        const now = c.SDL_GetTicks();
        _ = c.SDL_LockMutex(r.lock);
        defer _ = c.SDL_UnlockMutex(r.lock);
        r.view.code = r.join_code;
        r.view.status = .joined;
        try applyAnswer(&r.view, a, ans.body, now);
        return 200;
    }

    fn thread(ud: ?*anyopaque) callconv(.c) c_int {
        const r: *Room = @ptrCast(@alignCast(ud));
        r.loop();
        // The game still holds the room until it lets go, even after the server has dropped it.
        while (!r.quit.load(.acquire)) c.SDL_Delay(poll_ms);
        const gpa = r.gpa;
        gpa.free(r.base);
        gpa.free(r.token);
        gpa.free(r.create_title);
        gpa.free(r.want_title);
        c.SDL_DestroyMutex(r.lock);
        gpa.destroy(r);
        return 0;
    }

    fn loop(r: *Room) void {
        var arena = std.heap.ArenaAllocator.init(r.gpa);
        defer arena.deinit();
        var client = http.client(r.gpa);
        defer client.deinit();
        const al = arena.allocator();
        const auth = std.fmt.allocPrint(al, "Bearer {s}", .{r.token}) catch return r.setStatus(.failed);
        const hs = [_]std.http.Header{.{ .name = "authorization", .value = auth }};
        const first = r.enter(al, &client, &hs) catch .failed;
        if (first != .joined) return r.setStatus(first);
        const live = if (r.live_address_len > 0) c.SDL_CreateThread(liveThread, "versus-live", r) else null;
        defer if (live) |t| {
            r.quit.store(true, .release);
            c.SDL_WaitThread(t, null);
        };
        const url = std.fmt.allocPrint(al, "{s}/rooms/{s}/report", .{ r.base, &r.join_code }) catch return r.setStatus(.failed);
        const leave_url = std.fmt.allocPrint(al, "{s}/rooms/{s}/leave", .{ r.base, &r.join_code }) catch return r.setStatus(.failed);
        var misses: u32 = 0;
        var step = std.heap.ArenaAllocator.init(r.gpa);
        defer step.deinit();
        while (!r.quit.load(.acquire)) {
            _ = step.reset(.retain_capacity);
            const code = r.poll(step.allocator(), &client, &hs, url) catch |e| blk: {
                std.log.warn("versus room: {t}", .{e});
                break :blk @as(u16, 0);
            };
            if (code == 404) return r.setStatus(.lost);
            misses = if (code == 200) 0 else misses + 1;
            if (misses == lost_after) r.setStatus(.lost);
            r.waitForNextPoll();
        }
        _ = step.reset(.retain_capacity);
        _ = http.send(&client, step.allocator(), .POST, leave_url, "", &hs) catch {};
    }
};

test "a UDP answer updates scores, and a broken or old one is ignored" {
    var v: View = .{ .count = 2, .round = 1 };
    v.players[0].id = 5;
    v.players[1].id = 6;
    var data: [live_header_len + live_entry_len]u8 = @splat(0);
    data[0..4].* = live_reply.*;
    std.mem.writeInt(u32, data[4..8], 3, .little);
    std.mem.writeInt(u32, data[8..12], 2, .little);
    std.mem.writeInt(u32, data[12..16], 4000, .little);
    data[16] = 1;
    std.mem.writeInt(u32, data[17..21], 6, .little);
    std.mem.writeInt(u32, data[21..25], 77, .little);
    std.mem.writeInt(u32, data[29..33], @bitCast(std.math.nan(f32)), .little);
    var seq: u32 = 0;
    try std.testing.expect(!applyLive(&v, data[0 .. data.len - 1], &seq, 10));
    data[16] = 200;
    try std.testing.expect(!applyLive(&v, &data, &seq, 10));
    data[16] = 1;
    try std.testing.expect(applyLive(&v, &data, &seq, 10));
    try std.testing.expectEqual(@as(u32, 77), v.players[1].ex);
    try std.testing.expectEqual(@as(f32, 0), v.players[1].gauge);
    try std.testing.expectEqual(@as(u32, 0), v.players[0].ex);
    try std.testing.expectEqual(@as(u32, 2), v.start_round);
    try std.testing.expectEqual(@as(u64, 4010), v.start_tick);
    try std.testing.expectEqual(@as(u32, 1), v.round);
    try std.testing.expect(!applyLive(&v, &data, &seq, 10));
}

test "a live request has the layout the server reads" {
    var out: [live_request_len]u8 = undefined;
    encodeLive(&out, "ABC234", &@as([16]u8, @splat(9)), 7, .{ .round = 2, .has_chart = true, .ex = 3, .judged = 4, .gauge = 1, .done = true });
    try std.testing.expectEqualStrings("AU1QABC234", out[0..10]);
    try std.testing.expectEqual(@as(u8, 9), out[25]);
    try std.testing.expectEqual(@as(u8, 7), out[26]);
    try std.testing.expectEqual(@as(u8, 2), out[30]);
    try std.testing.expectEqual(@as(u8, 3), out[46]);
}

test "a live address is parsed or refused" {
    const v6 = parseLiveAddress("[::1]:8740").?;
    try std.testing.expectEqualStrings("::1", v6.host);
    try std.testing.expectEqual(@as(u16, 8740), parseLiveAddress("a.example:8740").?.port);
    try std.testing.expect(parseLiveAddress("a.example") == null);
    try std.testing.expect(parseLiveAddress(":1") == null);
    try std.testing.expect(parseLiveAddress("a:99999") == null);
    try std.testing.expect(parseLiveAddress("a:0") == null);
}

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
