//! Never touches the data directory, and installs only on the player's choice.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const build_options = @import("build_options");
const download = @import("download.zig");
const http = @import("../platform/http.zig");
const fs = @import("../platform/fs.zig");

pub const current_version = build_options.version;
pub const releases_page = "https://github.com/square3ang/actuon/releases/latest";

const latest_api = "https://api.github.com/repos/square3ang/actuon/releases/latest";
const download_base = "https://github.com/square3ang/actuon/releases/download/";
const appimage_asset = "actuon-x86_64.AppImage";
const windows_asset = "actuon-windows.zip";
/// The folder inside windows_asset, as packaging/windows/package.sh names it.
const windows_folder = "actuon-windows";
const windows_exe = "actuon.exe";
const staged_name = ".actuon-update";
const old_suffix = ".actuon-old";

pub const Release = struct {
    version: []const u8,
    /// Null when this release has nothing this install can apply; the player gets the releases page.
    url: ?[]const u8 = null,
    sha256: [32]u8 = undefined,
};

/// shortcut: the digest comes from GitHub beside the file, so this catches damage and a foreign host but not a hijacked repository; sign releases offline if that becomes a concern.
pub fn parseRelease(a: std.mem.Allocator, json: []const u8, current: []const u8, asset: ?[]const u8) !?Release {
    const Answer = struct {
        tag_name: []const u8,
        assets: []const struct { name: []const u8, browser_download_url: []const u8, digest: ?[]const u8 = null },
    };
    const answer = std.json.parseFromSliceLeaky(Answer, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.BadRelease;
    const version = if (std.mem.startsWith(u8, answer.tag_name, "v")) answer.tag_name[1..] else answer.tag_name;
    const theirs = std.SemanticVersion.parse(version) catch return error.BadRelease;
    if (theirs.order(try std.SemanticVersion.parse(current)) != .gt) return null;
    var release: Release = .{ .version = version };
    const wanted = asset orelse return release;
    for (answer.assets) |f| {
        if (!std.mem.eql(u8, f.name, wanted)) continue;
        const expected_url = try std.fmt.allocPrint(a, download_base ++ "{s}/{s}", .{ answer.tag_name, wanted });
        if (!std.mem.eql(u8, f.browser_download_url, expected_url)) return error.BadRelease;
        const digest = f.digest orelse return error.BadRelease;
        if (!std.mem.startsWith(u8, digest, "sha256:") or digest.len != "sha256:".len + 64) return error.BadRelease;
        _ = std.fmt.hexToBytes(&release.sha256, digest["sha256:".len..]) catch return error.BadRelease;
        release.url = expected_url;
        return release;
    }
    return release;
}

fn fetchVerified(gpa: std.mem.Allocator, io: std.Io, url: []const u8, sha256: [32]u8, path: []const u8, progress: *http.Progress) !void {
    errdefer fs.remove(io, path);
    try http.download(gpa, io, url, url, path, progress);
    if (!std.mem.eql(u8, &(try fs.sha256(io, path)), &sha256)) return error.ChecksumMismatch;
}

/// The rename is atomic, so a failure at any point leaves the old AppImage whole.
fn replaceFile(gpa: std.mem.Allocator, io: std.Io, url: []const u8, sha256: [32]u8, target: []const u8, progress: *http.Progress) !void {
    const tmp = try std.fmt.allocPrint(gpa, "{s}.update", .{target});
    defer gpa.free(tmp);
    errdefer fs.remove(io, tmp);
    try fetchVerified(gpa, io, url, sha256, tmp, progress);
    try fs.setExecutable(io, tmp);
    try fs.rename(tmp, target);
}

fn replaceFolder(a: std.mem.Allocator, io: std.Io, url: []const u8, sha256: [32]u8, dir: []const u8, progress: *http.Progress) !void {
    const archive = try std.fs.path.join(a, &.{ dir, staged_name ++ ".zip" });
    const staged = try std.fs.path.join(a, &.{ dir, staged_name });
    defer fs.remove(io, archive);
    defer fs.removeTree(io, staged);
    fs.removeTree(io, staged);
    try fetchVerified(a, io, url, sha256, archive, progress);
    _ = try download.extract(a, io, archive, staged);
    try swapFiles(a, io, try std.fs.path.join(a, &.{ staged, windows_folder }), dir);
}

/// Windows can rename a running exe but not overwrite it. shortcut: a power cut mid-swap leaves old and new files mixed, reinstall by hand; add a journal if that is ever reported.
fn swapFiles(a: std.mem.Allocator, io: std.Io, from: []const u8, to: []const u8) !void {
    const entries = try fs.list(a, io, from);
    var has_exe = false;
    for (entries) |e| {
        if (e.is_dir) return error.BadPackage;
        if (std.mem.eql(u8, e.name, windows_exe)) has_exe = true;
    }
    if (!has_exe) return error.BadPackage;
    for (entries, 0..) |e, i| {
        swapIn(a, io, from, to, e.name) catch |err| {
            var intact = true;
            for (entries[0..i]) |back| swapBack(a, io, from, to, back.name) catch {
                intact = false;
            };
            return if (intact) err else error.UpdateLeftBroken;
        };
    }
}

fn swapIn(a: std.mem.Allocator, io: std.Io, from: []const u8, to: []const u8, name: []const u8) !void {
    const source = try std.fs.path.join(a, &.{ from, name });
    const dest = try std.fs.path.join(a, &.{ to, name });
    const old = try std.fmt.allocPrint(a, "{s}" ++ old_suffix, .{dest});
    const had_old = fs.exists(io, dest);
    if (had_old) try fs.rename(dest, old);
    fs.rename(source, dest) catch |err| {
        if (had_old) fs.rename(old, dest) catch return error.UpdateLeftBroken;
        return err;
    };
}

fn swapBack(a: std.mem.Allocator, io: std.Io, from: []const u8, to: []const u8, name: []const u8) !void {
    const dest = try std.fs.path.join(a, &.{ to, name });
    const old = try std.fmt.allocPrint(a, "{s}" ++ old_suffix, .{dest});
    try fs.rename(dest, try std.fs.path.join(a, &.{ from, name }));
    if (fs.exists(io, old)) try fs.rename(old, dest);
}

/// The files in use by the last update have been released by now.
fn removeLeftovers(a: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    for (try fs.list(a, io, dir)) |e| {
        if (std.mem.endsWith(u8, e.name, old_suffix)) fs.remove(io, try std.fs.path.join(a, &.{ dir, e.name }));
    }
    fs.removeTree(io, try std.fs.path.join(a, &.{ dir, staged_name }));
}

const Target = union(enum) { appimage: []const u8, folder: []const u8 };

/// shortcut: dev builds, Flatpak and macOS (signed bundle untested) get the releases page; add macOS once a signed build exists.
fn findTarget(a: std.mem.Allocator, io: std.Io) !?Target {
    switch (builtin.os.tag) {
        .linux => {
            if (builtin.cpu.arch != .x86_64) return null;
            const path = c.SDL_getenv("APPIMAGE") orelse return null;
            return .{ .appimage = try a.dupe(u8, std.mem.span(path)) };
        },
        .windows => {
            const base = c.SDL_GetBasePath() orelse return null;
            const dir = try a.dupe(u8, std.mem.span(base));
            // Only a package has LICENSE beside the exe, which spares zig-out/bin.
            if (!fs.exists(io, try std.fs.path.join(a, &.{ dir, "LICENSE" }))) return null;
            return .{ .folder = dir };
        },
        else => return null,
    }
}

pub const Phase = enum(u8) { checking, current, available, installing, installed, failed };

/// Owned by the UI. The thread writes the fields, then publishes them through `phase`.
pub const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    phase: std.atomic.Value(Phase) = .init(.checking),
    err: anyerror = error.Unknown,
    release: ?Release = null,
    target: ?Target = null,
    progress: http.Progress = .{},
    thread: ?*c.SDL_Thread = null,

    fn begin(j: *Job, phase: Phase, entry: *const fn (?*anyopaque) callconv(.c) c_int, name: [*:0]const u8) void {
        if (j.thread) |t| c.SDL_WaitThread(t, null);
        j.phase.store(phase, .release);
        j.thread = c.SDL_CreateThread(entry, name, j);
        if (j.thread == null) j.fail(error.ThreadFailed);
    }

    /// Only from a finished phase.
    pub fn check(j: *Job) void {
        j.begin(.checking, checkThread, "update check");
    }

    /// Only from `available`, with a release this install can apply.
    pub fn install(j: *Job) void {
        j.progress = .{};
        j.begin(.installing, installThread, "update install");
    }

    pub fn canInstall(j: *const Job) bool {
        return j.target != null and j.release.?.url != null;
    }

    fn fail(j: *Job, err: anyerror) void {
        std.log.err("update: {t}", .{err});
        j.err = err;
        j.phase.store(.failed, .release);
    }

    /// At exit. A read blocked on a dead connection cannot be interrupted, so the thread may stay behind with its job.
    pub fn abandon(j: *Job) bool {
        j.progress.cancel.store(true, .release);
        for (0..60) |_| {
            const phase = j.phase.load(.acquire);
            if (phase != .checking and phase != .installing) {
                if (j.thread) |t| c.SDL_WaitThread(t, null);
                j.arena.deinit();
                j.gpa.destroy(j);
                return true;
            }
            c.SDL_Delay(50);
        }
        if (j.thread) |t| c.SDL_DetachThread(t);
        return false;
    }
};

pub fn start(gpa: std.mem.Allocator, io: std.Io) ?*Job {
    const j = gpa.create(Job) catch return null;
    j.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    j.check();
    return j;
}

fn checkThread(ud: ?*anyopaque) callconv(.c) c_int {
    const j: *Job = @ptrCast(@alignCast(ud));
    runCheck(j) catch |e| j.fail(e);
    return 0;
}

fn runCheck(j: *Job) !void {
    _ = j.arena.reset(.retain_capacity);
    const a = j.arena.allocator();
    j.release = null;
    j.target = try findTarget(a, j.io);
    const asset: ?[]const u8 = if (j.target) |t| switch (t) {
        .appimage => appimage_asset,
        .folder => windows_asset,
    } else null;
    if (j.target) |t| if (t == .folder) try removeLeftovers(a, j.io, t.folder);
    const json = try http.get(j.gpa, j.io, latest_api);
    defer j.gpa.free(json);
    j.release = try parseRelease(a, json, current_version, asset);
    j.phase.store(if (j.release != null) .available else .current, .release);
}

fn installThread(ud: ?*anyopaque) callconv(.c) c_int {
    const j: *Job = @ptrCast(@alignCast(ud));
    runInstall(j) catch |e| {
        j.fail(e);
        return 0;
    };
    j.phase.store(.installed, .release);
    return 0;
}

fn runInstall(j: *Job) !void {
    const release = j.release.?;
    switch (j.target.?) {
        .appimage => |path| try replaceFile(j.gpa, j.io, release.url.?, release.sha256, path, &j.progress),
        .folder => |dir| try replaceFolder(j.arena.allocator(), j.io, release.url.?, release.sha256, dir, &j.progress),
    }
}

const test_sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn fakeAnswer(a: std.mem.Allocator, tag: []const u8, url: []const u8, digest: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\{{"tag_name":"{s}","html_url":"x","assets":[
        \\{{"name":"other.zip","browser_download_url":"https://evil.example/o","digest":"sha256:{s}"}},
        \\{{"name":"a.zip","browser_download_url":"{s}","digest":"{s}"}}]}}
    , .{ tag, test_sha, url, digest });
}

test "only a newer release is offered, and its numbers compare as numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try fakeAnswer(a, "v0.10.0", download_base ++ "v0.10.0/a.zip", "sha256:" ++ test_sha);
    const newer = (try parseRelease(a, json, "0.9.0", "a.zip")).?;
    try std.testing.expectEqualStrings("0.10.0", newer.version);
    try std.testing.expectEqualStrings(download_base ++ "v0.10.0/a.zip", newer.url.?);
    try std.testing.expectEqual(@as(u8, 0x01), newer.sha256[0]);
    try std.testing.expectEqual(@as(?Release, null), try parseRelease(a, json, "0.10.0", "a.zip"));
    try std.testing.expectEqual(@as(?Release, null), try parseRelease(a, json, "0.11.0", "a.zip"));
}

test "a parsed release outlives the answer it came from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try fakeAnswer(a, "v1.2.3", download_base ++ "v1.2.3/a.zip", "sha256:" ++ test_sha);
    const release = (try parseRelease(a, json, "0.1.0", "a.zip")).?;
    @memset(json, 'x');
    try std.testing.expectEqualStrings("1.2.3", release.version);
}

test "a release with nothing for this install still reaches the player" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try fakeAnswer(a, "v1.0.0", "https://evil.example/a.zip", "bad");
    try std.testing.expectEqual(@as(?[]const u8, null), (try parseRelease(a, json, "0.1.0", null)).?.url);
    try std.testing.expectEqual(@as(?[]const u8, null), (try parseRelease(a, json, "0.1.0", "missing.zip")).?.url);
}

test "a bad release answer is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good_url = download_base ++ "v1.0.0/a.zip";
    const good_digest = "sha256:" ++ test_sha;
    const cases = [_][]const u8{
        "not json",
        try fakeAnswer(a, "nightly", good_url, good_digest),
        try fakeAnswer(a, "v1.0.0", "https://evil.example/a.zip", good_digest),
        try fakeAnswer(a, "v1.0.0", "http://github.com/square3ang/actuon/releases/download/v1.0.0/a.zip", good_digest),
        try fakeAnswer(a, "v1.0.0", good_url, "md5:" ++ test_sha),
        try fakeAnswer(a, "v1.0.0", good_url, "sha256:abc"),
        try fakeAnswer(a, "v1.0.0", good_url, "sha256:zz" ++ test_sha[2..]),
    };
    for (cases) |json| try std.testing.expectError(error.BadRelease, parseRelease(a, json, "0.1.0", "a.zip"));
}

const TestServer = struct {
    server: std.Io.net.Server,
    thread: std.Thread,
    url_buf: [64]u8 = undefined,

    fn serve(s: *std.Io.net.Server, body: []const u8) void {
        const stream = s.accept(std.testing.io) catch return;
        defer stream.close(std.testing.io);
        var in_buf: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &in_buf);
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            if (line.len == 2) break;
        }
        var out_buf: [1 << 12]u8 = undefined;
        var writer = stream.writer(std.testing.io, &out_buf);
        writer.interface.print("HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{body.len}) catch return;
        writer.interface.writeAll(body) catch return;
        writer.interface.flush() catch return;
    }

    fn start(t: *TestServer, body: []const u8) ![]const u8 {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        t.server = try address.listen(std.testing.io, .{ .reuse_address = true });
        t.thread = try std.Thread.spawn(.{}, serve, .{ &t.server, body });
        return std.fmt.bufPrint(&t.url_buf, "http://127.0.0.1:{d}/", .{t.server.socket.address.getPort()});
    }

    fn stop(t: *TestServer) void {
        t.thread.join();
        t.server.deinit(std.testing.io);
    }
};

fn sumOf(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

fn tmpPath(a: std.mem.Allocator, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "a download that fails its checksum never replaces the game" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpPath(a, &tmp, "actuon.AppImage");
    try fs.write(std.testing.io, target, "old");

    var bad: TestServer = .{ .server = undefined, .thread = undefined };
    const bad_url = try bad.start("tampered");
    var progress: http.Progress = .{};
    const refused = replaceFile(a, std.testing.io, bad_url, sumOf("new"), target, &progress);
    bad.stop();
    try std.testing.expectError(error.ChecksumMismatch, refused);
    try std.testing.expectEqualStrings("old", try fs.readAlloc(a, std.testing.io, target, 16));
    try std.testing.expect(!fs.exists(std.testing.io, try tmpPath(a, &tmp, "actuon.AppImage.update")));

    var good: TestServer = .{ .server = undefined, .thread = undefined };
    const good_url = try good.start("new");
    const applied = replaceFile(a, std.testing.io, good_url, sumOf("new"), target, &progress);
    good.stop();
    try applied;
    try std.testing.expectEqualStrings("new", try fs.readAlloc(a, std.testing.io, target, 16));
    if (builtin.os.tag != .windows) {
        const file = try tmp.dir.openFile(std.testing.io, "actuon.AppImage", .{});
        defer file.close(std.testing.io);
        try std.testing.expect((try file.stat(std.testing.io)).permissions.toMode() & 0o111 != 0);
    }
}

fn writeZip(a: std.mem.Allocator, path: []const u8, names: []const []const u8) !void {
    const w = c.archive_write_new().?;
    defer _ = c.archive_write_free(w);
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_set_format_zip(w));
    try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_open_filename(w, (try a.dupeSentinel(u8, path, 0)).ptr));
    for (names) |name| {
        const e = c.archive_entry_new().?;
        defer c.archive_entry_free(e);
        c.archive_entry_set_pathname(e, (try a.dupeSentinel(u8, name, 0)).ptr);
        c.archive_entry_set_size(e, 3);
        c.archive_entry_set_filetype(e, 0o100000);
        c.archive_entry_set_perm(e, 0o644);
        try std.testing.expectEqual(c.ARCHIVE_OK, c.archive_write_header(w, e));
        try std.testing.expectEqual(@as(isize, 3), c.archive_write_data(w, "new", 3));
    }
    _ = c.archive_write_close(w);
}

fn zipBytes(a: std.mem.Allocator, tmp: *const std.testing.TmpDir, names: []const []const u8) ![]u8 {
    const path = try tmpPath(a, tmp, "fixture.zip");
    defer fs.remove(std.testing.io, path);
    try writeZip(a, path, names);
    return fs.readAlloc(a, std.testing.io, path, 1 << 20);
}

test "a verified package replaces the folder, and the next launch clears what it kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(a, &tmp, "game");
    try fs.mkdirs(std.testing.io, dir);
    const exe = try std.fs.path.join(a, &.{ dir, windows_exe });
    const save = try std.fs.path.join(a, &.{ dir, "mine.txt" });
    try fs.write(std.testing.io, exe, "old");
    try fs.write(std.testing.io, save, "mine");
    const zip = try zipBytes(a, &tmp, &.{ windows_folder ++ "/" ++ windows_exe, windows_folder ++ "/new.dll" });

    var server: TestServer = .{ .server = undefined, .thread = undefined };
    const url = try server.start(zip);
    var progress: http.Progress = .{};
    const applied = replaceFolder(a, std.testing.io, url, sumOf(zip), dir, &progress);
    server.stop();
    try applied;
    try std.testing.expectEqualStrings("new", try fs.readAlloc(a, std.testing.io, exe, 16));
    try std.testing.expectEqualStrings("new", try fs.readAlloc(a, std.testing.io, try std.fs.path.join(a, &.{ dir, "new.dll" }), 16));
    const old = try std.fmt.allocPrint(a, "{s}" ++ old_suffix, .{exe});
    try std.testing.expectEqualStrings("old", try fs.readAlloc(a, std.testing.io, old, 16));
    try std.testing.expect(!fs.exists(std.testing.io, try std.fs.path.join(a, &.{ dir, staged_name })));

    try removeLeftovers(a, std.testing.io, dir);
    try std.testing.expect(!fs.exists(std.testing.io, old));
    try std.testing.expectEqualStrings("mine", try fs.readAlloc(a, std.testing.io, save, 16));
}

test "a package with the wrong checksum or without the game changes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(a, &tmp, "game");
    try fs.mkdirs(std.testing.io, dir);
    const exe = try std.fs.path.join(a, &.{ dir, windows_exe });
    try fs.write(std.testing.io, exe, "old");
    var progress: http.Progress = .{};
    const no_game = try zipBytes(a, &tmp, &.{windows_folder ++ "/evil.dll"});
    const cases = [_]struct { zip: []const u8, sum: [32]u8, want: anyerror }{
        .{ .zip = "tampered", .sum = sumOf("something else"), .want = error.ChecksumMismatch },
        .{ .zip = no_game, .sum = sumOf(no_game), .want = error.BadPackage },
    };
    for (cases) |k| {
        var server: TestServer = .{ .server = undefined, .thread = undefined };
        const url = try server.start(k.zip);
        const r = replaceFolder(a, std.testing.io, url, k.sum, dir, &progress);
        server.stop();
        try std.testing.expectError(k.want, r);
        try std.testing.expectEqualStrings("old", try fs.readAlloc(a, std.testing.io, exe, 16));
        try std.testing.expect(!fs.exists(std.testing.io, try std.fs.path.join(a, &.{ dir, "evil.dll" })));
    }
}

test "a swap that fails partway puts every file back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const from = try tmpPath(a, &tmp, "from");
    const to = try tmpPath(a, &tmp, "to");
    try fs.mkdirs(std.testing.io, from);
    try fs.mkdirs(std.testing.io, to);
    const names = [_][]const u8{ windows_exe, "a.dll", "b.dll" };
    for (names) |n| {
        try fs.write(std.testing.io, try std.fs.path.join(a, &.{ from, n }), "new");
        try fs.write(std.testing.io, try std.fs.path.join(a, &.{ to, n }), "old");
    }
    // A full folder cannot be renamed over, so keeping b.dll's old copy fails wherever the listing puts it.
    const blocker = try std.fs.path.join(a, &.{ to, "b.dll" ++ old_suffix });
    try fs.mkdirs(std.testing.io, blocker);
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ blocker, "x" }), "");

    try std.testing.expect(std.meta.isError(swapFiles(a, std.testing.io, from, to)));
    for (names) |n| try std.testing.expectEqualStrings("old", try fs.readAlloc(a, std.testing.io, try std.fs.path.join(a, &.{ to, n }), 16));
}
