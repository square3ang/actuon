//! HTTP GET/POST over std.http; the only place the rest of the code touches the HTTP client.
const std = @import("std");

pub const Response = struct { status: u16, body: []u8 };

/// Far above any table or IR answer. Servers are untrusted, and an endless body must not fill memory.
const max_body: usize = 64 << 20;
/// The largest package download.zig would unpack.
const max_download: u64 = 8 << 30;

pub fn request(gpa: std.mem.Allocator, io: std.Io, method: std.http.Method, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header) !Response {
    var c = client(gpa, io);
    defer c.deinit();
    return send(&c, gpa, method, url, payload, headers);
}

pub fn client(gpa: std.mem.Allocator, io: std.Io) std.http.Client {
    return .{ .allocator = gpa, .io = io };
}

pub fn send(c: *std.http.Client, gpa: std.mem.Allocator, method: std.http.Method, url: []const u8, payload: ?[]const u8, headers: []const std.http.Header) !Response {
    return sendCapped(c, gpa, method, url, payload, headers, max_body);
}

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
        // Zig 0.17 never sends privileged_headers, and extra ones follow any redirect, so token requests do not.
        .extra_headers = headers,
        .redirect_behavior = if (headers.len > 0) .unhandled else null,
    }) catch |e| return if (body.too_large) error.TooLarge else e;
    body.writer.flush() catch return error.TooLarge;
    return .{ .status = @backingInt(res.status), .body = try body.out.toOwnedSlice() };
}

pub fn get(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    const r = try request(gpa, io, .GET, url, null, &.{});
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

pub fn download(gpa: std.mem.Allocator, io: std.Io, url: []const u8, path: []const u8, progress: *Progress) !void {
    return downloadCapped(gpa, io, url, path, progress, max_download);
}

fn downloadCapped(gpa: std.mem.Allocator, io: std.Io, url: []const u8, path: []const u8, progress: *Progress, limit: u64) !void {
    var c = client(gpa, io);
    defer c.deinit();
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [1 << 16]u8 = undefined;
    var w = file.writer(io, &buf);
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

const TestPeer = struct {
    fn run(s: *std.Io.net.Server, body: []const u8) void {
        const stream = s.accept(std.testing.io) catch return;
        defer stream.close(std.testing.io);
        var in_buf: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &in_buf);
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            if (line.len == 2) break;
        }
        var out_buf: [256]u8 = undefined;
        var writer = stream.writer(std.testing.io, &out_buf);
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
        var server = try address.listen(std.testing.io, .{ .reuse_address = true });
        defer server.deinit(std.testing.io);
        const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{server.socket.address.getPort()});
        const thread = try std.Thread.spawn(.{}, TestPeer.run, .{ &server, &body });
        defer thread.join();
        var c = client(a, std.testing.io);
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
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
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
    try std.testing.expectError(error.TooLarge, downloadCapped(a, std.testing.io, url, path, &progress, 99));
}

test "a request sends its headers and does not follow a redirect with them" {
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const Peer = struct {
        fn run(s: *std.Io.net.Server, seen: *[1024]u8, len: *usize, accepted: *usize) void {
            const stream = s.accept(std.testing.io) catch return;
            defer stream.close(std.testing.io);
            accepted.* += 1;
            var in_buf: [1024]u8 = undefined;
            var reader = stream.reader(std.testing.io, &in_buf);
            while (!std.mem.endsWith(u8, seen[0..len.*], "\r\n\r\n")) {
                const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                @memcpy(seen[len.*..][0..line.len], line);
                len.* += line.len;
            }
            var out_buf: [256]u8 = undefined;
            var writer = stream.writer(std.testing.io, &out_buf);
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
    const r = try request(a, std.testing.io, .GET, url, null, &.{.{ .name = "Authorization", .value = "Bearer t" }});
    defer a.free(r.body);
    thread.join();
    try std.testing.expectEqual(@as(u16, 302), r.status);
    try std.testing.expect(std.mem.indexOf(u8, seen[0..len], "Authorization: Bearer t\r\n") != null);
    try std.testing.expectEqual(@as(usize, 1), accepted);
}

test "one client sends two requests over one connection" {
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    const Peer = struct {
        fn run(s: *std.Io.net.Server, answered: *usize) void {
            const stream = s.accept(std.testing.io) catch return;
            defer stream.close(std.testing.io);
            var in_buf: [1024]u8 = undefined;
            var reader = stream.reader(std.testing.io, &in_buf);
            var out_buf: [256]u8 = undefined;
            var writer = stream.writer(std.testing.io, &out_buf);
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
    var c = client(a, std.testing.io);
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

// shortcut: reads block, so a network that drops silently holds the reader until TCP gives up; add a read timeout if players see frozen rooms.
pub const WebSocket = struct {
    req: std.http.Client.Request,

    /// `ws` must stay where it is until `close`: the request holds the connection.
    pub fn open(ws: *WebSocket, c: *std.http.Client, url: []const u8, auth: []const std.http.Header) !void {
        var raw: [16]u8 = undefined;
        c.io.random(&raw);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &raw);
        var headers: [4]std.http.Header = undefined;
        if (auth.len > 1) return error.TooManyHeaders;
        headers[0] = .{ .name = "upgrade", .value = "websocket" };
        headers[1] = .{ .name = "sec-websocket-version", .value = "13" };
        headers[2] = .{ .name = "sec-websocket-key", .value = &key };
        @memcpy(headers[3..][0..auth.len], auth);
        ws.req = try c.request(.GET, try std.Uri.parse(url), .{
            .headers = .{ .connection = .{ .override = "Upgrade" }, .accept_encoding = .omit },
            .extra_headers = headers[0 .. 3 + auth.len],
            .redirect_behavior = .unhandled,
        });
        errdefer ws.req.deinit();
        try ws.req.sendBodiless();
        const res = try ws.req.receiveHead(&.{});
        if (res.head.status != .switching_protocols) return error.Refused;
        const want = acceptKey(&key);
        var it = res.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "sec-websocket-accept") and std.mem.eql(u8, h.value, &want)) return;
        }
        return error.Refused;
    }

    pub fn send(ws: *WebSocket, text: []const u8) !void {
        const conn = ws.req.connection.?;
        var mask: [4]u8 = undefined;
        ws.req.client.io.random(&mask);
        try writeFrame(conn.writer(), 0x1, text, mask);
        try conn.flush();
    }

    pub fn receive(ws: *WebSocket, buf: []u8) ![]u8 {
        const conn = ws.req.connection.?;
        while (true) {
            const f = try readFrame(conn.reader(), buf);
            switch (f.opcode) {
                0x1, 0x2 => return f.payload,
                0x9 => {
                    var mask: [4]u8 = undefined;
                    ws.req.client.io.random(&mask);
                    try writeFrame(conn.writer(), 0xA, f.payload, mask);
                    try conn.flush();
                },
                0xA => {},
                0x8 => return error.Closed,
                else => return error.BadFrame,
            }
        }
    }

    pub fn close(ws: *WebSocket) void {
        const conn = ws.req.connection.?;
        writeFrame(conn.writer(), 0x8, "", @splat(0)) catch {};
        conn.flush() catch {};
        conn.closing = true;
        ws.req.deinit();
    }
};

fn acceptKey(key: []const u8) [28]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &sha.finalResult());
    return out;
}

/// A client's frame is always masked, and never split.
fn writeFrame(w: *std.Io.Writer, opcode: u4, payload: []const u8, mask: [4]u8) !void {
    try w.writeByte(0x80 | @as(u8, opcode));
    if (payload.len < 126) {
        try w.writeByte(0x80 | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xffff) {
        try w.writeByte(0x80 | 126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    } else return error.TooLarge;
    try w.writeAll(&mask);
    for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
}

const Frame = struct { opcode: u4, payload: []u8 };

/// The server is untrusted: a frame larger than `buf`, split, or masked is refused.
fn readFrame(r: *std.Io.Reader, buf: []u8) !Frame {
    var head: [2]u8 = undefined;
    try r.readSliceAll(&head);
    if (head[0] & 0x80 == 0) return error.BadFrame;
    if (head[1] & 0x80 != 0) return error.BadFrame;
    var len: u64 = head[1] & 0x7f;
    if (len == 126) {
        var ext: [2]u8 = undefined;
        try r.readSliceAll(&ext);
        len = std.mem.readInt(u16, &ext, .big);
    } else if (len == 127) {
        var ext: [8]u8 = undefined;
        try r.readSliceAll(&ext);
        len = std.mem.readInt(u64, &ext, .big);
    }
    if (len > buf.len) return error.TooLarge;
    const payload = buf[0..@intCast(len)];
    try r.readSliceAll(payload);
    return .{ .opcode = @truncate(head[0]), .payload = payload };
}

test "the WebSocket accept key matches RFC 6455's example" {
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
}

test "a client frame is masked, and a server frame too large, split or masked is refused" {
    var out: [300]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try writeFrame(&w, 0x1, "Hello", .{ 0x37, 0xfa, 0x21, 0x3d });
    // RFC 6455, section 5.7.
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, w.buffered());
    var buf: [200]u8 = undefined;
    var long: [4 + 130]u8 = @splat('a');
    long[0..4].* = .{ 0x82, 126, 0, 130 };
    var r: std.Io.Reader = .fixed(&long);
    const f = try readFrame(&r, &buf);
    try std.testing.expectEqual(@as(u4, 2), f.opcode);
    try std.testing.expectEqual(@as(usize, 130), f.payload.len);
    r = .fixed(&long);
    try std.testing.expectError(error.TooLarge, readFrame(&r, buf[0..100]));
    r = .fixed(&.{ 0x01, 0x00 });
    try std.testing.expectError(error.BadFrame, readFrame(&r, &buf));
    r = .fixed(&.{ 0x81, 0x80, 0, 0, 0, 0 });
    try std.testing.expectError(error.BadFrame, readFrame(&r, &buf));
}

const WebSocketPeer = struct {
    fn run(s: *std.Io.net.Server, ponged: *bool) void {
        const stream = s.accept(std.testing.io) catch return;
        defer stream.close(std.testing.io);
        var in_buf: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &in_buf);
        var key_buf: [24]u8 = undefined;
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            if (line.len == 2) break;
            if (std.ascii.startsWithIgnoreCase(line, "sec-websocket-key: ") and line.len == 19 + 24 + 2) key_buf = line[19..][0..24].*;
        }
        var out_buf: [256]u8 = undefined;
        var writer = stream.writer(std.testing.io, &out_buf);
        const w = &writer.interface;
        w.print("HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\nsec-websocket-accept: {s}\r\n\r\n", .{&acceptKey(&key_buf)}) catch return;
        w.flush() catch return;
        var text: [8]u8 = undefined;
        const n = readMasked(&reader.interface, 0x81, &text) orelse return;
        w.writeAll(&.{ 0x89, 1, 'p', 0x81, @intCast(n) }) catch return;
        w.writeAll(text[0..n]) catch return;
        w.flush() catch return;
        var pong: [1]u8 = undefined;
        ponged.* = readMasked(&reader.interface, 0x8A, &pong) == 1 and pong[0] == 'p';
    }

    fn readMasked(r: *std.Io.Reader, want: u8, out: []u8) ?usize {
        var head: [6]u8 = undefined;
        r.readSliceAll(&head) catch return null;
        const n = head[1] & 0x7f;
        if (head[0] != want or head[1] & 0x80 == 0 or n > out.len) return null;
        r.readSliceAll(out[0..n]) catch return null;
        for (out[0..n], 0..) |*b, i| b.* ^= head[2 + i % 4];
        return n;
    }
};

test "a WebSocket opens over the HTTP client, sends, receives and answers a ping" {
    const a = std.testing.allocator;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/play", .{server.socket.address.getPort()});
    var ponged = false;
    const thread = try std.Thread.spawn(.{}, WebSocketPeer.run, .{ &server, &ponged });
    var c = client(a, std.testing.io);
    defer c.deinit();
    var ws: WebSocket = undefined;
    try ws.open(&c, url, &.{});
    try ws.send("hello");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try ws.receive(&buf));
    thread.join();
    ws.close();
    try std.testing.expect(ponged);
}
