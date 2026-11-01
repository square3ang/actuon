//! HTTP GET/POST over std.http; the only place the rest of the code touches the HTTP client.
const std = @import("std");
const fs = @import("fs.zig");

pub const Response = struct { status: u16, body: []u8 };

/// Far above any table or IR answer. Servers are untrusted, and an endless body must not fill memory.
const max_body: usize = 64 << 20;
/// The largest package download.zig would unpack.
const max_download: u64 = 8 << 30;

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
    return sendCapped(c, gpa, method, url, payload, headers, max_body);
}

/// Keeps an answer in memory, and stops reading it past `limit`.
const CappedBody = struct {
    out: std.Io.Writer.Allocating,
    limit: usize,
    too_large: bool = false,
    writer: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn add(b: *CappedBody, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len > b.limit - b.out.written().len) {
            b.too_large = true;
            return error.WriteFailed;
        }
        try b.out.writer.writeAll(bytes);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const b: *CappedBody = @fieldParentPtr("writer", w);
        const buffered = w.buffered();
        if (buffered.len > 0) {
            try b.add(buffered);
            return w.consume(buffered.len);
        }
        for (data[0 .. data.len - 1]) |bytes| if (bytes.len > 0) {
            try b.add(bytes);
            return bytes.len;
        };
        const pattern = data[data.len - 1];
        for (0..splat) |_| try b.add(pattern);
        return pattern.len * splat;
    }
};

fn sendCapped(c: *std.http.Client, gpa: std.mem.Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header, limit: usize) !Response {
    var buf: [1 << 16]u8 = undefined;
    var body: CappedBody = .{
        .out = .init(gpa),
        .limit = limit,
        .writer = .{ .vtable = &CappedBody.vtable, .buffer = &buf },
    };
    errdefer body.out.deinit();
    const res = c.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &body.writer,
        // Not privileged_headers: Zig 0.17 never sends those. Extra headers follow a redirect to any
        // host, so a request carrying the IR token does not follow one and sees it as a status.
        .extra_headers = headers,
        .redirect_behavior = if (headers.len > 0) .unhandled else null,
    }) catch |e| return if (body.too_large) error.TooLarge else e;
    body.writer.flush() catch return error.TooLarge;
    return .{ .status = @backingInt(res.status), .body = try body.out.toOwnedSlice() };
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
    return downloadCapped(gpa, url, path, progress, max_download);
}

fn downloadCapped(gpa: std.mem.Allocator, url: []const u8, path: []const u8, progress: *Progress, limit: u64) !void {
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
        done += n;
        if (done > limit) return error.TooLarge;
        try w.interface.writeAll(chunk[0..n]);
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

/// Answers one request with `body`, wherever the test listens.
const TestPeer = struct {
    fn run(s: *std.Io.net.Server, body: []const u8) void {
        const stream = s.accept(fs.io) catch return;
        defer stream.close(fs.io);
        var in_buf: [1024]u8 = undefined;
        var reader = stream.reader(fs.io, &in_buf);
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            if (line.len == 2) break;
        }
        var out_buf: [256]u8 = undefined;
        var writer = stream.writer(fs.io, &out_buf);
        writer.interface.print("HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body.len}) catch return;
        writer.interface.writeAll(body) catch return;
        writer.interface.flush() catch return;
    }
};

test "an answer past the limit is refused, and one at the limit is kept" {
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const body: [100]u8 = @splat('x');
    var url_buf: [64]u8 = undefined;
    for ([_]usize{ 99, 100 }) |limit| {
        var server = try address.listen(fs.io, .{ .reuse_address = true });
        defer server.deinit(fs.io);
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
        const thread = try std.Thread.spawn(.{}, TestPeer.run, .{ &server, &body });
        defer thread.join();
        var c = client(a);
        defer c.deinit();
        const got = sendCapped(&c, a, .GET, url, null, &.{}, limit);
        if (limit == 99) {
            try std.testing.expectError(error.TooLarge, got);
        } else {
            const r = try got;
            defer a.free(r.body);
            try std.testing.expectEqualStrings(&body, r.body);
        }
    }
}

test "a download past the limit stops" {
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(fs.io, .{ .reuse_address = true });
    defer server.deinit(fs.io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/part", .{tmp.sub_path});
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
    const body: [100]u8 = @splat('x');
    const thread = try std.Thread.spawn(.{}, TestPeer.run, .{ &server, &body });
    defer thread.join();
    var progress: Progress = .{};
    try std.testing.expectError(error.TooLarge, downloadCapped(a, url, path, &progress, 99));
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
