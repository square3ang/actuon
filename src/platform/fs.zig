//! All file system calls live here so the next std.Io change has one place to break.
const std = @import("std");
const c = @import("c");

pub var io: std.Io = undefined;

const Dir = std.Io.Dir;

pub fn readAlloc(gpa: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit));
}

pub fn write(path: []const u8, data: []const u8) !void {
    return Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Write-then-rename, so a crash cannot leave a half-written config or database copy.
pub fn writeAtomic(gpa: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(tmp);
    errdefer remove(tmp);
    const f = try Dir.cwd().createFile(io, tmp, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, data);
    // Rename can reach the disk before the data does, and a power cut would then leave an empty file.
    try f.sync(io);
    try rename(tmp, path);
}

pub fn exists(path: []const u8) bool {
    Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn mkdirs(path: []const u8) !void {
    try Dir.cwd().createDirPath(io, path);
}

pub fn remove(path: []const u8) void {
    Dir.cwd().deleteFile(io, path) catch {};
}

pub fn removeTree(path: []const u8) void {
    Dir.cwd().deleteTree(io, path) catch {};
}

pub fn rename(from: []const u8, to: []const u8) !void {
    // Not std: on Windows it opens the source for writing, which a running exe or loaded DLL refuses. SDL uses MoveFileExW there.
    var from_buf: [std.fs.max_path_bytes]u8 = undefined;
    var to_buf: [std.fs.max_path_bytes]u8 = undefined;
    const from_z = try std.fmt.bufPrintSentinel(&from_buf, "{s}", .{from}, 0);
    const to_z = try std.fmt.bufPrintSentinel(&to_buf, "{s}", .{to}, 0);
    if (!c.SDL_RenamePath(from_z, to_z)) {
        std.log.warn("rename {s}: {s}", .{ from, std.mem.span(c.SDL_GetError()) });
        return error.RenameFailed;
    }
}

pub fn setExecutable(path: []const u8) !void {
    if (@import("builtin").os.tag == .windows) return;
    try Dir.cwd().setFilePermissions(io, path, .fromMode(0o755), .{});
}

pub fn sha256(path: []const u8) ![32]u8 {
    const file = try Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [1 << 16]u8 = undefined;
    var r = file.reader(io, &buf);
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    var chunk: [1 << 16]u8 = undefined;
    while (true) {
        const n = try r.interface.readSliceShort(&chunk);
        if (n == 0) return hash.finalResult();
        hash.update(chunk[0..n]);
    }
}

pub const Stat = struct { mtime: i64, size: u64, is_dir: bool };

pub fn stat(path: []const u8) ?Stat {
    const s = Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{
        .mtime = @intCast(@divTrunc(s.mtime.nanoseconds, std.time.ns_per_s)),
        .size = s.size,
        .is_dir = s.kind == .directory,
    };
}

/// The path with every symlink resolved, so two names for one directory compare equal.
pub fn realPath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return Dir.cwd().realPathFileAlloc(io, path, a);
}

pub const Entry = struct { name: []const u8, is_dir: bool };

/// Lists one directory; names live in `a`. Missing or unreadable directories list as empty.
pub fn list(a: std.mem.Allocator, path: []const u8) ![]Entry {
    return listChecked(a, path) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => &.{},
    };
}

/// `list` for callers that must tell an empty directory from one they could not read.
pub fn listChecked(a: std.mem.Allocator, path: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        var is_dir = e.kind == .directory;
        if (e.kind == .sym_link) {
            const full = try std.fs.path.join(a, &.{ path, e.name });
            if (stat(full)) |s| is_dir = s.is_dir;
        }
        try out.append(a, .{ .name = try a.dupe(u8, e.name), .is_dir = is_dir });
    }
    return out.toOwnedSlice(a);
}

pub const test_data_dir = ".zig-cache/tmp/actuon-test-data";

/// Per-user data directory with a trailing separator.
pub fn dataDir(gpa: std.mem.Allocator) ![]u8 {
    // Tests must never touch the player's settings and scores.
    if (@import("builtin").is_test) return gpa.dupe(u8, test_data_dir ++ "/");
    const p = c.SDL_GetPrefPath("actuon", "actuon") orelse return error.NoPrefPath;
    defer c.SDL_free(p);
    return gpa.dupe(u8, std.mem.span(p));
}

/// Shows a folder in the system file manager, making it first so a new player sees where things go.
pub fn openFolder(gpa: std.mem.Allocator, path: []const u8) !void {
    try mkdirs(path);
    const url = try folderUrl(gpa, path, @import("builtin").os.tag == .windows);
    defer gpa.free(url);
    if (!c.SDL_OpenURL(url)) return error.OpenFailed;
}

/// Windows opens a plain path, which keeps non-ASCII user names intact. macOS needs a file URL,
/// and the space in "Application Support" must be escaped there.
fn folderUrl(gpa: std.mem.Allocator, path: []const u8, windows: bool) ![:0]u8 {
    if (windows) return gpa.dupeSentinel(u8, path, 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    for (path) |b| switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => try out.append(gpa, b),
        else => try out.print(gpa, "%{X:0>2}", .{b}),
    };
    return out.toOwnedSliceSentinel(gpa, 0);
}

test "a folder opens as an escaped file URL, and as a plain path on Windows" {
    const url = try folderUrl(std.testing.allocator, "/Users/a b/Library/Application Support/\xec\x95\x84/", false);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("file:///Users/a%20b/Library/Application%20Support/%EC%95%84/", url);
    const win = try folderUrl(std.testing.allocator, "C:\\Users\\\xec\x95\x84\\", true);
    defer std.testing.allocator.free(win);
    try std.testing.expectEqualStrings("C:\\Users\\\xec\x95\x84\\", win);
}

/// Finds a referenced asset beside the chart: exact, then case-insensitive, then other extensions
/// (charts often say .wav where the package ships .ogg).
pub fn resolveAsset(a: std.mem.Allocator, dir: []const u8, rel: []const u8, exts: []const []const u8) !?[]u8 {
    // Reject escapes: chart files are untrusted and must not read outside their folder.
    if (std.fs.path.isAbsolute(rel) or climbs(rel)) return null;
    const exact = try std.fs.path.join(a, &.{ dir, rel });
    if (exists(exact)) return exact;
    const sub = std.fs.path.dirname(rel) orelse "";
    const base = std.fs.path.basename(rel);
    const stem = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
    const search = if (sub.len > 0) try std.fs.path.join(a, &.{ dir, sub }) else dir;
    // The usual case, .wav in the chart and .ogg on disk, needs no listing of a folder that may hold thousands.
    for (exts) |x| {
        const name = try std.fmt.allocPrint(a, "{s}.{s}", .{ stem, x });
        const direct = try std.fs.path.join(a, &.{ search, name });
        if (exists(direct)) return direct;
    }
    const entries = try list(a, search);
    for (entries) |e| {
        if (!e.is_dir and std.ascii.eqlIgnoreCase(e.name, base)) return try std.fs.path.join(a, &.{ search, e.name });
    }
    for (entries) |e| {
        if (e.is_dir) continue;
        const dot = std.mem.lastIndexOfScalar(u8, e.name, '.') orelse continue;
        if (!std.ascii.eqlIgnoreCase(e.name[0..dot], stem)) continue;
        for (exts) |x| {
            if (std.ascii.eqlIgnoreCase(e.name[dot + 1 ..], x)) return try std.fs.path.join(a, &.{ search, e.name });
        }
    }
    return null;
}

test "assets in a huge folder resolve with little memory, and without an exact name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(dir);
    var name_buf: [128]u8 = undefined;
    for (0..3000) |i| try write(try std.fmt.bufPrint(&name_buf, "{s}/some_long_sound_name_{d}.ogg", .{ dir, i }), "");
    var buf: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const found = try resolveAsset(fba.allocator(), dir, "some_long_sound_name_7.wav", &.{ "wav", "ogg" });
    try std.testing.expect(std.mem.endsWith(u8, found.?, "some_long_sound_name_7.ogg"));
}

/// True if a path climbs out of its folder. A file named "a..png" does not.
pub fn climbs(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return true;
    return false;
}

test "an asset path cannot leave the chart folder" {
    io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // These all exist, so only the escape check can turn them down.
    try std.testing.expect(try resolveAsset(a, "tests/charts", "stop.bms", &.{}) != null);
    try std.testing.expectEqual(null, try resolveAsset(a, "tests/charts", "../charts/stop.bms", &.{}));
    try std.testing.expectEqual(null, try resolveAsset(a, "tests/charts", "sub/../../charts/stop.bms", &.{}));
    const absolute = try Dir.cwd().realPathFileAlloc(io, "tests/charts/stop.bms", a);
    try std.testing.expectEqual(null, try resolveAsset(a, "tests/charts", absolute, &.{}));
}

test "writeAtomic replaces the file and leaves no temporary" {
    io = std.testing.io;
    const gpa = std.testing.allocator;
    const p = "actuon_test_atomic.txt";
    defer remove(p);
    try writeAtomic(gpa, p, "one");
    try writeAtomic(gpa, p, "two");
    const back = try readAlloc(gpa, p, 16);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("two", back);
    try std.testing.expect(!exists(p ++ ".tmp"));
}

test "only a whole .. segment climbs" {
    try std.testing.expect(climbs("../x.png"));
    try std.testing.expect(climbs("a\\..\\x.png"));
    try std.testing.expect(!climbs("bomb/ring SCUROed..png"));
}
