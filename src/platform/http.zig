//! HTTP GET/POST over std.http; the only place the rest of the code touches the HTTP client.
const std = @import("std");
const fs = @import("fs.zig");

pub const Response = struct { status: u16, body: []u8 };

pub fn request(gpa: std.mem.Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header) !Response {
    var client: std.http.Client = .{ .allocator = gpa, .io = fs.io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &body.writer,
        .extra_headers = headers,
    });
    return .{ .status = @intFromEnum(res.status), .body = try body.toOwnedSlice() };
}

pub fn get(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    const r = try request(gpa, .GET, url, null, &.{});
    if (r.status >= 400) {
        gpa.free(r.body);
        return error.HttpStatus;
    }
    return r.body;
}

/// Written by the downloading thread, read by the UI. `cancel` is read back between chunks.
pub const Progress = struct {
    done: std.atomic.Value(u64) = .init(0),
    /// 0 until the response head arrives, and when the server names no size.
    total: std.atomic.Value(u64) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
};

/// Streams a response to a file, so a big package never sits in memory.
pub fn download(gpa: std.mem.Allocator, url: []const u8, path: []const u8, progress: *Progress) !void {
    var client: std.http.Client = .{ .allocator = gpa, .io = fs.io };
    defer client.deinit();
    const file = try std.Io.Dir.cwd().createFile(fs.io, path, .{});
    defer file.close(fs.io);
    var buf: [1 << 16]u8 = undefined;
    var w = file.writer(fs.io, &buf);
    var req = try client.request(.GET, try std.Uri.parse(url), .{ .redirect_behavior = @enumFromInt(3), .headers = .{ .accept_encoding = .omit } });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [8192]u8 = undefined;
    var res = try req.receiveHead(&redirect_buf);
    if (@intFromEnum(res.head.status) >= 400) return error.HttpStatus;
    progress.done.store(0, .release);
    progress.total.store(res.head.content_length orelse 0, .release);
    var transfer: [64]u8 = undefined;
    const body = res.reader(&transfer);
    var chunk: [1 << 16]u8 = undefined;
    var done: u64 = 0;
    while (true) {
        if (progress.cancel.load(.acquire)) return error.Canceled;
        const n = body.readSliceShort(&chunk) catch return res.bodyErr() orelse error.ReadFailed;
        if (n == 0) break;
        try w.interface.writeAll(chunk[0..n]);
        done += n;
        progress.done.store(done, .release);
    }
    try w.interface.flush();
}

/// Resolves `ref` against the page at `base`.
pub fn join(a: std.mem.Allocator, base: []const u8, ref: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, ref, "://") != null) return a.dupe(u8, ref);
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return error.BadUrl) + 3;
    const host_end = if (std.mem.indexOfScalarPos(u8, base, scheme_end, '/')) |i| i else base.len;
    if (ref.len > 0 and ref[0] == '/') return std.fmt.allocPrint(a, "{s}{s}", .{ base[0..host_end], ref });
    const query = std.mem.indexOfAny(u8, base, "?#") orelse base.len;
    const dir_end = if (std.mem.lastIndexOfScalar(u8, base[0..query], '/')) |i| (if (i >= host_end) i else host_end) else host_end;
    var rest = ref;
    while (std.mem.startsWith(u8, rest, "./")) rest = rest[2..];
    return std.fmt.allocPrint(a, "{s}/{s}", .{ base[0..dir_end], rest });
}

test "url join" {
    const a = std.testing.allocator;
    const cases = [_][3][]const u8{
        .{ "https://x.y/st/table.html", "head.json", "https://x.y/st/head.json" },
        .{ "https://x.y/st/table.html", "./head.json", "https://x.y/st/head.json" },
        .{ "https://x.y/st/table.html", "/head.json", "https://x.y/head.json" },
        .{ "https://x.y", "head.json", "https://x.y/head.json" },
        .{ "https://x.y/a/", "https://z/d.json", "https://z/d.json" },
    };
    for (cases) |k| {
        const r = try join(a, k[0], k[1]);
        defer a.free(r);
        try std.testing.expectEqualStrings(k[2], r);
    }
}
