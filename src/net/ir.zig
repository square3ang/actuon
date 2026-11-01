//! IR client: uploads replays and fetches rankings on background threads, never during play timing.
const std = @import("std");
const c = @import("c");
const http = @import("../platform/http.zig");
const fs = @import("../platform/fs.zig");

pub const Upload = struct {
    gpa: std.mem.Allocator,
    base: []u8,
    token: []u8,
    sha: []u8,
    chart_path: []u8,
    replay: []u8,
    /// 0 pending, 1 accepted, 2 failed. Owned by the app, so it outlives the job.
    status: *std.atomic.Value(u8),
};

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
pub fn submit(gpa: std.mem.Allocator, base: []const u8, token: []const u8, sha: []const u8, chart_path: []const u8, replay: []const u8) !u16 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const hs = try bearer(a, token);
    const url = try std.fmt.allocPrint(a, "{s}/scores/{s}", .{ base, sha });
    var r = try http.request(a, .POST, url, replay, hs);
    if (r.status == 428) {
        const chart = try fs.readAlloc(a, chart_path, 16 << 20);
        const put = try std.fmt.allocPrint(a, "{s}/charts/{s}?format={d}", .{ base, sha, chartFormat(chart_path) });
        const up = try http.request(a, .PUT, put, chart, hs);
        if (up.status != 200) return up.status;
        r = try http.request(a, .POST, url, replay, hs);
    }
    return r.status;
}

fn uploadThread(ud: ?*anyopaque) callconv(.c) c_int {
    const u: *Upload = @ptrCast(@alignCast(ud));
    const code = submit(u.gpa, u.base, u.token, u.sha, u.chart_path, u.replay) catch |e| blk: {
        std.log.warn("IR upload: {t}", .{e});
        break :blk 0;
    };
    u.status.store(if (code == 200) 1 else 2, .release);
    const gpa = u.gpa;
    gpa.free(u.base);
    gpa.free(u.token);
    gpa.free(u.sha);
    gpa.free(u.chart_path);
    gpa.free(u.replay);
    gpa.destroy(u);
    return 0;
}

pub fn startUpload(gpa: std.mem.Allocator, base: []const u8, token: []const u8, sha: []const u8, chart_path: []const u8, replay: []const u8, status: *std.atomic.Value(u8)) void {
    const u = gpa.create(Upload) catch return;
    u.* = .{
        .gpa = gpa,
        .base = gpa.dupe(u8, base) catch return,
        .token = gpa.dupe(u8, token) catch return,
        .sha = gpa.dupe(u8, sha) catch return,
        .chart_path = gpa.dupe(u8, chart_path) catch return,
        .replay = gpa.dupe(u8, replay) catch return,
        .status = status,
    };
    status.store(0, .release);
    if (c.SDL_CreateThread(uploadThread, "ir-upload", u)) |t| c.SDL_DetachThread(t);
}

/// A background GET or POST whose JSON answer is parsed into display lines.
pub const Query = struct {
    gpa: std.mem.Allocator,
    url: []u8,
    token: []u8,
    body: ?[]u8,
    lines: std.ArrayList([]u8) = .empty,
    done: std.atomic.Value(bool) = .init(false),
    failed: bool = false,
    thread: ?*c.SDL_Thread = null,

    pub fn destroy(q: *Query) void {
        if (q.thread) |t| c.SDL_WaitThread(t, null);
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
    return std.fmt.allocPrint(a, "{d}. {s}   EX {d}   BP {d}", .{ rank, name, num(o, "ex"), num(o, "miss") });
}

fn queryThread(ud: ?*anyopaque) callconv(.c) c_int {
    const q: *Query = @ptrCast(@alignCast(ud));
    defer q.done.store(true, .release);
    run(q) catch |e| {
        std.log.warn("IR query: {t}", .{e});
        q.failed = true;
    };
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
    q.thread = c.SDL_CreateThread(queryThread, "ir-query", q);
    return q;
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
}
