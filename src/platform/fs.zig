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
    try write(tmp, data);
    try Dir.cwd().rename(tmp, Dir.cwd(), path, io);
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
    try Dir.cwd().rename(from, Dir.cwd(), to, io);
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

pub const Entry = struct { name: []const u8, is_dir: bool };

/// Lists one directory; names live in `a`. Missing or unreadable directories list as empty.
pub fn list(a: std.mem.Allocator, path: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var dir = Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return out.toOwnedSlice(a);
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
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

test "only a whole .. segment climbs" {
    try std.testing.expect(climbs("../x.png"));
    try std.testing.expect(climbs("a\\..\\x.png"));
    try std.testing.expect(!climbs("bomb/ring SCUROed..png"));
}
