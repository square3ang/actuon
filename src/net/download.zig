//! Built-in chart downloader: fetches a package, extracts it safely, and lets the scanner pick it up.
const std = @import("std");
const c = @import("c");
const http = @import("../platform/http.zig");
const fs = @import("../platform/fs.zig");

const Limits = struct { bytes: u64 = 8 << 30, entries: u32 = 200_000 };

/// libarchive converts archive names through the C locale, which drops anything non-ASCII by default.
pub fn initLocale() void {
    for ([_][*:0]const u8{ "C.UTF-8", ".UTF8", "UTF-8" }) |name| {
        if (c.setlocale(c.LC_CTYPE, name) != null) return;
    }
}

/// Fills the "{md5}" placeholder of a download URL template.
pub fn expand(a: std.mem.Allocator, template: []const u8, md5: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, a, template, "{md5}", md5);
}

/// Rejects anything that could land outside the extraction folder. Archives are untrusted.
pub fn safeEntry(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/' or name[0] == '\\') return false;
    if (name.len >= 2 and name[1] == ':') return false;
    var it = std.mem.tokenizeAny(u8, name, "/\\");
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return false;
    return true;
}

/// Extracts regular files and folders only: links and devices are skipped, never followed.
pub fn extract(a: std.mem.Allocator, archive_path: []const u8, dest: []const u8) !u32 {
    return extractWithin(a, archive_path, dest, .{});
}

fn extractWithin(a: std.mem.Allocator, archive_path: []const u8, dest: []const u8, limits: Limits) !u32 {
    const ar = c.archive_read_new() orelse return error.Archive;
    defer _ = c.archive_read_free(ar);
    _ = c.archive_read_support_filter_all(ar);
    _ = c.archive_read_support_format_all(ar);
    const pz = try a.dupeSentinel(u8, archive_path, 0);
    if (c.archive_read_open_filename(ar, pz.ptr, 1 << 16) != c.ARCHIVE_OK) return error.Archive;
    var entry: ?*c.archive_entry = null;
    var written: u64 = 0;
    var files: u32 = 0;
    var seen: u32 = 0;
    var buf: [1 << 16]u8 = undefined;
    while (true) {
        const rc = c.archive_read_next_header(ar, &entry);
        if (rc == c.ARCHIVE_EOF) break;
        // A name the locale cannot convert only warns; stopping there would truncate the package silently.
        if (rc != c.ARCHIVE_OK and rc != c.ARCHIVE_WARN) return error.Archive;
        seen += 1;
        if (seen > limits.entries) return error.TooManyEntries;
        const raw = c.archive_entry_pathname_utf8(entry) orelse c.archive_entry_pathname(entry);
        if (raw == null) continue;
        const name = std.mem.span(raw);
        if (!safeEntry(name)) continue;
        const ty = c.archive_entry_filetype(entry);
        if (ty != 0o100000) continue; // AE_IFREG: its macro does not translate
        const clean = try a.dupe(u8, name);
        std.mem.replaceScalar(u8, clean, '\\', '/');
        const out_path = try std.fs.path.join(a, &.{ dest, clean });
        if (std.fs.path.dirname(out_path)) |d| try fs.mkdirs(d);
        const file = try std.Io.Dir.cwd().createFile(fs.io, out_path, .{});
        defer file.close(fs.io);
        var out_buf: [1 << 16]u8 = undefined;
        var w = file.writer(fs.io, &out_buf);
        while (true) {
            const n = c.archive_read_data(ar, &buf, buf.len);
            if (n < 0) return error.Archive;
            if (n == 0) break;
            written += @intCast(n);
            if (written > limits.bytes) return error.TooLarge;
            try w.interface.writeAll(buf[0..@intCast(n)]);
        }
        try w.interface.flush();
        files += 1;
    }
    return files;
}

pub const Job = struct {
    gpa: std.mem.Allocator,
    url: []u8,
    root: []u8,
    id: []u8,
    state: std.atomic.Value(u8) = .init(0), // 0 running, 1 done, 2 failed
    progress: http.Progress = .{},
    extracting: std.atomic.Value(bool) = .init(false),
    thread: ?*c.SDL_Thread = null,

    /// For giving up on a stalled download or at exit. A read blocked on a dead connection cannot
    /// be interrupted, so if the thread does not finish in time it is left behind with its job.
    pub fn abandon(j: *Job) void {
        j.progress.cancel.store(true, .release);
        for (0..60) |_| {
            if (j.state.load(.acquire) != 0) return j.destroy();
            c.SDL_Delay(50);
        }
        if (j.thread) |t| c.SDL_DetachThread(t);
    }

    pub fn destroy(j: *Job) void {
        if (j.thread) |t| c.SDL_WaitThread(t, null);
        j.gpa.free(j.url);
        j.gpa.free(j.root);
        j.gpa.free(j.id);
        j.gpa.destroy(j);
    }
};

/// The archive address in a lookup answer: Konmai's `data.song_url` or Ginger's `downloadURL`.
pub fn packageUrl(a: std.mem.Allocator, json: []const u8) !?[]const u8 {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    if (root != .object) return null;
    const direct = root.object.get("downloadURL");
    const inner = root.object.get("data");
    const found = direct orelse if (inner != null and inner.? == .object) inner.?.object.get("song_url") else null;
    const v = found orelse return null;
    if (v != .string) return null;
    if (!std.mem.startsWith(u8, v.string, "https://") and !std.mem.startsWith(u8, v.string, "http://")) return null;
    return v.string;
}

fn run(j: *Job) !void {
    var arena = std.heap.ArenaAllocator.init(j.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const downloads = try std.fs.path.join(a, &.{ j.root, "downloads" });
    try fs.mkdirs(downloads);
    const dest = try std.fs.path.join(a, &.{ downloads, j.id });
    // Per job: an abandoned job's thread can wake later and remove its file while a retry downloads.
    const archive = try std.fmt.allocPrint(a, "{s}.{x}.part", .{ dest, @intFromPtr(j) });
    defer fs.remove(archive);
    try http.download(j.gpa, j.url, archive, &j.progress);
    // Lookup services answer with JSON naming the archive. Anything too big to read here is the archive.
    if (fs.readAlloc(a, archive, 1 << 20)) |head| {
        if (head.len > 0 and head[0] == '{') {
            const real = (try packageUrl(a, head)) orelse return error.NoPackage;
            try http.download(j.gpa, real, archive, &j.progress);
        }
    } else |_| {}
    j.extracting.store(true, .release);
    try unpack(a, archive, dest, .{});
}

/// A package that fails halfway leaves nothing, but a folder from an earlier download stays.
fn unpack(a: std.mem.Allocator, archive: []const u8, dest: []const u8, limits: Limits) !void {
    const fresh = !fs.exists(dest);
    errdefer if (fresh) fs.removeTree(dest);
    if ((try extractWithin(a, archive, dest, limits)) == 0) return error.EmptyArchive;
}

fn thread(ud: ?*anyopaque) callconv(.c) c_int {
    const j: *Job = @ptrCast(@alignCast(ud));
    run(j) catch |e| {
        std.log.err("download {s}: {t}", .{ j.url, e });
        j.state.store(2, .release);
        return 1;
    };
    j.state.store(1, .release);
    return 0;
}

/// `id` names the folder, so it must be a chart hash, not free text.
pub fn start(gpa: std.mem.Allocator, url: []const u8, root: []const u8, id: []const u8) ?*Job {
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch)) return null;
    if (id.len == 0) return null;
    const j = gpa.create(Job) catch return null;
    j.* = .{ .gpa = gpa, .url = gpa.dupe(u8, url) catch return null, .root = gpa.dupe(u8, root) catch return null, .id = gpa.dupe(u8, id) catch return null };
    j.thread = c.SDL_CreateThread(thread, "download", j) orelse {
        j.destroy();
        return null;
    };
    return j;
}

test "extraction keeps non-ASCII names and everything after them" {
    initLocale();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const archive = try std.fmt.allocPrintSentinel(a, "{s}/t.7z", .{root}, 0);

    const w = c.archive_write_new().?;
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_set_format_7zip(w));
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_set_format_option(w, "7zip", "compression", "store"));
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_open_filename(w, archive.ptr));
    const names = [_][:0]const u8{ "s/a.bms", "s/\u{5DEE}\u{5206}.bme", "s/z.bms" };
    for (names) |name| {
        const e = c.archive_entry_new().?;
        defer c.archive_entry_free(e);
        c.archive_entry_set_pathname_utf8(e, name.ptr);
        c.archive_entry_set_filetype(e, 0o100000);
        c.archive_entry_set_perm(e, 0o644);
        c.archive_entry_set_size(e, 1);
        try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_header(w, e));
        try std.testing.expectEqual(@as(isize, 1), c.archive_write_data(w, "x", 1));
    }
    _ = c.archive_write_close(w);
    _ = c.archive_write_free(w);

    const dest = try std.fmt.allocPrint(a, "{s}/out", .{root});
    try std.testing.expectEqual(@as(u32, 3), try extract(a, archive, dest));
    for (names) |name| try std.testing.expect(fs.exists(try std.fs.path.join(a, &.{ dest, name })));
}

test "entry names cannot escape" {
    try std.testing.expect(safeEntry("song/a.bms"));
    try std.testing.expect(safeEntry("..hidden/a.bms"));
    try std.testing.expect(!safeEntry("../a.bms"));
    try std.testing.expect(!safeEntry("x/../../a.bms"));
    try std.testing.expect(!safeEntry("x\\..\\a.bms"));
    try std.testing.expect(!safeEntry("/etc/passwd"));
    try std.testing.expect(!safeEntry("C:\\a.bms"));
    try std.testing.expect(!safeEntry(""));
}

test "lookup answers name the archive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("https://x/a.7z", (try packageUrl(a, "{\"result\":\"success\",\"data\":{\"song_url\":\"https://x/a.7z\"}}")).?);
    try std.testing.expectEqualStrings("https://y/b.7z", (try packageUrl(a, "{\"id\":1,\"downloadURL\":\"https://y/b.7z\"}")).?);
    try std.testing.expect((try packageUrl(a, "{\"result\":\"fail\",\"data\":null}")) == null);
    try std.testing.expect((try packageUrl(a, "{\"downloadURL\":\"file:///etc/passwd\"}")) == null);
}

/// "12.3 / 148.0 MB", or "12.3 MB" when the server names no size.
pub fn formatProgress(buf: []u8, done: u64, total: u64) []const u8 {
    const mb = 1024.0 * 1024.0;
    const d = @as(f64, @floatFromInt(done)) / mb;
    const t = @as(f64, @floatFromInt(total)) / mb;
    return (if (total > 0) std.fmt.bufPrint(buf, "Downloading {d:.1} / {d:.1} MB", .{ d, t }) else std.fmt.bufPrint(buf, "Downloading {d:.1} MB", .{d})) catch "Downloading...";
}

test "progress text" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Downloading 1.5 / 3.0 MB", formatProgress(&buf, 1572864, 3145728));
    try std.testing.expectEqualStrings("Downloading 1.5 MB", formatProgress(&buf, 1572864, 0));
}

test "url template" {
    const a = std.testing.allocator;
    const u = try expand(a, "https://x/{md5}", "abc");
    defer a.free(u);
    try std.testing.expectEqualStrings("https://x/abc", u);
}

test "extract keeps files and drops escapes and links" {
    const a = std.testing.allocator;
    fs.io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    // A tar built by hand: one good file, one traversal, one symlink.
    const tar_path = "actuon_test.tar";
    const dest = "actuon_test_out";
    defer fs.remove(tar_path);
    var tar: std.ArrayList(u8) = .empty;
    const add = struct {
        fn f(out: *std.ArrayList(u8), all: std.mem.Allocator, name: []const u8, kind: u8, body: []const u8) !void {
            var h: [512]u8 = @splat(0);
            @memcpy(h[0..name.len], name);
            _ = try std.fmt.bufPrint(h[100..], "0000644\x000000000\x000000000\x00{o:0>11}\x0000000000000\x00", .{body.len});
            h[156] = kind;
            @memcpy(h[257..263], "ustar\x00");
            @memcpy(h[263..265], "00");
            @memset(h[148..156], ' ');
            var sum: u32 = 0;
            for (h) |b| sum += b;
            _ = try std.fmt.bufPrint(h[148..], "{o:0>6}\x00 ", .{sum});
            try out.appendSlice(all, &h);
            try out.appendSlice(all, body);
            const pad = (512 - body.len % 512) % 512;
            try out.appendNTimes(all, 0, pad);
        }
    }.f;
    try add(&tar, al, "song/good.bms", '0', "#TITLE ok\n");
    try add(&tar, al, "../evil.bms", '0', "bad");
    try add(&tar, al, "link", '2', "");
    try tar.appendNTimes(al, 0, 1024);
    try fs.write(tar_path, tar.items);
    const limited = dest ++ "_limits";
    defer fs.removeTree(limited);
    try std.testing.expectError(error.TooLarge, unpack(al, tar_path, limited, .{ .bytes = 4 }));
    try std.testing.expect(!fs.exists(limited));
    try std.testing.expectError(error.TooManyEntries, unpack(al, tar_path, limited, .{ .entries = 2 }));
    try std.testing.expect(!fs.exists(limited));
    try fs.mkdirs(limited ++ "/kept");
    try std.testing.expectError(error.TooLarge, unpack(al, tar_path, limited, .{ .bytes = 4 }));
    try std.testing.expect(fs.exists(limited ++ "/kept"));
    const n = try extract(al, tar_path, dest);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expect(fs.exists(dest ++ "/song/good.bms"));
    try std.testing.expect(!fs.exists("evil.bms"));
    try std.testing.expect(!fs.exists(dest ++ "/link"));
    try std.Io.Dir.cwd().deleteTree(fs.io, dest);
}
