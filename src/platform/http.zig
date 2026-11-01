//! HTTP GET/POST over std.http; the only place the rest of the code touches the HTTP client.
const std = @import("std");
const fs = @import("fs.zig");

pub const Response = struct { status: u16, body: []u8 };

pub fn request(gpa: std.mem.Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header) !Response {
    var c = client(gpa);
    defer c.deinit();
    return send(&c, gpa, method, url, payload, headers);
}

pub fn client(gpa: std.mem.Allocator) std.http.Client {
    return .{ .allocator = gpa, .io = fs.io };
}

/// Keeps the client's connection for the next call, which spares a TLS handshake per request.
pub fn send(c: *std.http.Client, gpa: std.mem.Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header) !Response {
    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    const res = try c.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &body.writer,
        // Not privileged_headers: Zig 0.17 never sends those. Extra headers follow a redirect to any
        // host, so a request carrying the IR token does not follow one and sees it as a status.
        .extra_headers = headers,
        .redirect_behavior = if (headers.len > 0) .unhandled else null,
    });
    return .{ .status = @backingInt(res.status), .body = try body.toOwnedSlice() };
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
    var c = client(gpa);
    defer c.deinit();
    const file = try std.Io.Dir.cwd().createFile(fs.io, path, .{});
    defer file.close(fs.io);
    var buf: [1 << 16]u8 = undefined;
    var w = file.writer(fs.io, &buf);
    var req = try c.request(.GET, try std.Uri.parse(url), .{ .redirect_behavior = @fromBackingInt(@intCast(3)), .headers = .{ .accept_encoding = .omit } });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [8192]u8 = undefined;
    var res = try req.receiveHead(&redirect_buf);
    if (@backingInt(res.head.status) >= 400) return error.HttpStatus;
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

test "a request sends its headers and does not follow a redirect with them" {
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(fs.io, .{ .reuse_address = true });
    defer server.deinit(fs.io);
    const Peer = struct {
        fn run(s: *std.Io.net.Server, seen: *[1024]u8, len: *usize, accepted: *usize) void {
            const stream = s.accept(fs.io) catch return;
            defer stream.close(fs.io);
            accepted.* += 1;
            var in_buf: [1024]u8 = undefined;
            var reader = stream.reader(fs.io, &in_buf);
            while (!std.mem.endsWith(u8, seen[0..len.*], "\r\n\r\n")) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                @memcpy(seen[len.*..][0..line.len], line);
                len.* += line.len;
            }
            var out_buf: [256]u8 = undefined;
            var writer = stream.writer(fs.io, &out_buf);
            writer.interface.writeAll("HTTP/1.1 302 Found\r\nlocation: http://127.0.0.1:1/x\r\ncontent-length: 0\r\nconnection: close\r\n\r\n") catch return;
            writer.interface.flush() catch return;
        }
    };
    var seen: [1024]u8 = undefined;
    var len: usize = 0;
    var accepted: usize = 0;
    const thread = try std.Thread.spawn(.{}, Peer.run, .{ &server, &seen, &len, &accepted });
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    const r = try request(a, .GET, url, null, &.{.{ .name = "Authorization", .value = "Bearer t" }});
    defer a.free(r.body);
    thread.join();
    try std.testing.expectEqual(@as(u16, 302), r.status);
    try std.testing.expect(std.mem.indexOf(u8, seen[0..len], "Authorization: Bearer t\r\n") != null);
    try std.testing.expectEqual(@as(usize, 1), accepted);
}

test "one client sends two requests over one connection" {
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(fs.io, .{ .reuse_address = true });
    defer server.deinit(fs.io);
    const Peer = struct {
        fn run(s: *std.Io.net.Server, answered: *usize) void {
            const stream = s.accept(fs.io) catch return;
            defer stream.close(fs.io);
            var in_buf: [1024]u8 = undefined;
            var reader = stream.reader(fs.io, &in_buf);
            var out_buf: [256]u8 = undefined;
            var writer = stream.writer(fs.io, &out_buf);
            while (answered.* < 2) {
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                    if (line.len == 2) break;
                }
                writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n") catch return;
                writer.interface.flush() catch return;
                answered.* += 1;
            }
        }
    };
    var answered: usize = 0;
    const thread = try std.Thread.spawn(.{}, Peer.run, .{ &server, &answered });
    defer thread.join();
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    var c = client(a);
    defer c.deinit();
    for (0..2) |_| {
        const r = try send(&c, a, .GET, url, null, &.{});
        defer a.free(r.body);
        try std.testing.expectEqual(@as(u16, 200), r.status);
    }
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
