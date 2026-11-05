//! Never touches the data directory, and installs only on the player's choice.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const build_options = @import("build_options");
const download = @import("download.zig");
const http = @import("../platform/http.zig");
const fs = @import("../platform/fs.zig");
const release_sig = @import("release_sig.zig");
const Ed25519 = release_sig.Ed25519;

pub const current_version = build_options.version;
/// Null without -Dupdate-key: such a build never installs anything, since only the key stops a hijacked repository; it opens the releases page.
const release_key: ?[32]u8 = if (build_options.update_key.len == 0) null else blk: {
    var key: [32]u8 = undefined;
    if (build_options.update_key.len != 64) @compileError("update-key must be 64 hex digits");
    _ = std.fmt.hexToBytes(&key, build_options.update_key) catch @compileError("update-key must be 64 hex digits");
    break :blk key;
};
pub const releases_page = "https://github.com/square3ang/actuon/releases/latest";

const latest_api = "https://api.github.com/repos/square3ang/actuon/releases/latest";
const download_base = "https://github.com/square3ang/actuon/releases/download/";
const appimage_asset = "actuon-x86_64.AppImage";
const windows_asset = "actuon-windows.zip";
/// The folder inside windows_asset, as packaging/windows/package.sh names it.
const windows_folder = "actuon-windows";
const windows_exe = "actuon.exe";
const macos_asset = "actuon-macos.zip";
/// The bundle inside macos_asset, as packaging/macos/package.sh names it.
const macos_bundle = "actuon.app";
const macos_exe = "Contents/MacOS/actuon";
const staged_name = ".actuon-update";
const old_suffix = ".actuon-old";
const journal_name = ".actuon-swap";
const lock_name = ".actuon-lock";

pub const Release = struct {
    version: []const u8,
    /// Null when this release has nothing this install can apply; the player gets the releases page.
    url: ?[]const u8 = null,
};

pub fn parseRelease(a: std.mem.Allocator, json: []const u8, current: []const u8, asset: ?[]const u8) !?Release {
    const Answer = struct {
        tag_name: []const u8,
        assets: []const struct { name: []const u8, browser_download_url: []const u8 },
    };
    const answer = std.json.parseFromSliceLeaky(Answer, a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.BadRelease;
    const version = if (std.mem.startsWith(u8, answer.tag_name, "v")) answer.tag_name[1..] else answer.tag_name;
    const theirs = std.SemanticVersion.parse(version) catch return error.BadRelease;
    if (theirs.order(try std.SemanticVersion.parse(current)) != .gt) return null;
    var release: Release = .{ .version = version };
    const wanted = asset orelse return release;
    const url = try std.fmt.allocPrint(a, download_base ++ "{s}/{s}", .{ answer.tag_name, wanted });
    const sig_url = try std.fmt.allocPrint(a, "{s}.sig", .{url});
    var listed = false;
    var signed = false;
    for (answer.assets) |f| {
        if (std.mem.eql(u8, f.browser_download_url, url)) listed = true;
        if (std.mem.eql(u8, f.browser_download_url, sig_url)) signed = true;
    }
    if (listed and signed) release.url = url;
    return release;
}

const Proof = struct { key: [32]u8, signature: [64]u8, name: []const u8 };

fn fetchVerified(gpa: std.mem.Allocator, io: std.Io, url: []const u8, proof: Proof, path: []const u8, progress: *http.Progress) !void {
    errdefer fs.remove(io, path);
    try http.download(gpa, io, url, url, path, progress);
    const message = try release_sig.message(gpa, proof.name, try fs.sha256(io, path));
    defer gpa.free(message);
    const key = Ed25519.PublicKey.fromBytes(proof.key) catch return error.BadSignature;
    Ed25519.Signature.fromBytes(proof.signature).verify(message, key) catch return error.BadSignature;
}

/// The rename is atomic, so a failure at any point leaves the old AppImage whole.
fn replaceFile(gpa: std.mem.Allocator, io: std.Io, url: []const u8, proof: Proof, target: []const u8, progress: *http.Progress) !void {
    const tmp = try std.fmt.allocPrint(gpa, "{s}.update", .{target});
    defer gpa.free(tmp);
    errdefer fs.remove(io, tmp);
    try fetchVerified(gpa, io, url, proof, tmp, progress);
    try fs.setExecutable(io, tmp);
    try fs.rename(tmp, target);
}

/// The .sig sits beside the asset at `url`, which starts with `base`; the rest names the asset.
fn fetchProof(gpa: std.mem.Allocator, io: std.Io, base: []const u8, url: []const u8, key: [32]u8) !Proof {
    const sig_url = try std.fmt.allocPrint(gpa, "{s}.sig", .{url});
    defer gpa.free(sig_url);
    const signature = try http.get(gpa, io, sig_url);
    defer gpa.free(signature);
    if (signature.len != 64) return error.BadSignature;
    return .{ .key = key, .signature = signature[0..64].*, .name = url[base.len..] };
}

/// Stages in `dir`, beside the game, so the final renames stay on one volume; `swap` moves `inner` of the package onto `to`.
fn replacePackage(a: std.mem.Allocator, io: std.Io, url: []const u8, proof: Proof, dir: []const u8, inner: []const u8, comptime swap: anytype, to: []const u8, progress: *http.Progress) !void {
    const held = try fs.lock(io, try std.fs.path.join(a, &.{ dir, lock_name })) orelse return error.UpdateBusy;
    defer held.close(io);
    const archive = try std.fs.path.join(a, &.{ dir, staged_name ++ ".zip" });
    const staged = try std.fs.path.join(a, &.{ dir, staged_name });
    const journal = try std.fs.path.join(a, &.{ dir, journal_name });
    defer fs.remove(io, archive);
    // A journal left behind needs the staged files at the next start.
    defer if (!fs.exists(io, journal)) fs.removeTree(io, staged);
    fs.removeTree(io, staged);
    try fetchVerified(a, io, url, proof, archive, progress);
    _ = try download.extract(a, io, archive, staged);
    try swap(a, io, try std.fs.path.join(a, &.{ staged, inner }), to);
}

/// The swap is atomic, so the old bundle stays whole until it lands in the staging folder, which the caller removes.
fn swapBundle(a: std.mem.Allocator, io: std.Io, from: []const u8, to: []const u8) !void {
    const exe = try std.fs.path.join(a, &.{ from, macos_exe });
    if (!fs.exists(io, exe)) return error.BadPackage;
    // The archive reader keeps no permissions.
    try fs.setExecutable(io, exe);
    try fs.swap(from, to);
}

/// Windows can rename a running exe but not overwrite it. The journal lets the next start finish a swap that a power cut stopped, if the game still starts.
/// shortcut: a power cut between the two renames of actuon.exe or a DLL it loads leaves a game that cannot start to replay the journal, reinstall by hand; add a separate launcher if that is ever reported.
fn swapFiles(a: std.mem.Allocator, io: std.Io, from: []const u8, to: []const u8) !void {
    const entries = try fs.list(a, io, from);
    var exe_at: ?usize = null;
    for (entries, 0..) |e, i| {
        if (e.is_dir or !plainName(e.name)) return error.BadPackage;
        if (std.mem.eql(u8, e.name, windows_exe)) exe_at = i;
        // finishSwap rolls forward, so every staged file must be on disk before the journal is.
        try fs.sync(io, try std.fs.path.join(a, &.{ from, e.name }));
    }
    // Last, so the old exe still starts and replays the journal after a cut anywhere else.
    std.mem.swap(fs.Entry, &entries[exe_at orelse return error.BadPackage], &entries[entries.len - 1]);
    var plan: std.ArrayList(u8) = .empty;
    for (entries) |e| try plan.print(a, "{s}\n", .{e.name});
    const journal = try std.fs.path.join(a, &.{ to, journal_name });
    try fs.writeAtomic(a, io, journal, plan.items);
    for (entries, 0..) |e, i| {
        swapIn(a, io, from, to, e.name) catch |err| {
            var intact = true;
            for (entries[0..i]) |back| swapBack(a, io, from, to, back.name) catch {
                intact = false;
            };
            // A file swapIn could not put back lives only as its old copy; the journal and staged tree restore it.
            if (!intact or err == error.UpdateLeftBroken) return error.UpdateLeftBroken;
            fs.remove(io, journal);
            return err;
        };
    }
    fs.remove(io, journal);
}

/// A journal line names one file in the game folder, never a path.
fn plainName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\\n") == null;
}

/// Each file is still staged, or swapIn already moved it, so redoing swapIn for the staged ones finishes the update.
fn finishSwap(a: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    const journal = try std.fs.path.join(a, &.{ dir, journal_name });
    const plan = fs.readAlloc(a, io, journal, 1 << 16) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    var names = std.mem.tokenizeScalar(u8, plan, '\n');
    while (names.next()) |name| if (!plainName(name)) return error.BadJournal;
    const from = try std.fs.path.join(a, &.{ dir, staged_name, windows_folder });
    names.reset();
    while (names.next()) |name| {
        if (fs.exists(io, try std.fs.path.join(a, &.{ from, name }))) try swapIn(a, io, from, dir, name);
    }
    fs.remove(io, journal);
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
    // Another instance mid-update still needs every file here.
    const held = try fs.lock(io, try std.fs.path.join(a, &.{ dir, lock_name })) orelse return;
    defer held.close(io);
    try finishSwap(a, io, dir);
    for (try fs.list(a, io, dir)) |e| {
        if (std.mem.endsWith(u8, e.name, old_suffix)) fs.remove(io, try std.fs.path.join(a, &.{ dir, e.name }));
    }
    fs.removeTree(io, try std.fs.path.join(a, &.{ dir, staged_name }));
    fs.remove(io, try std.fs.path.join(a, &.{ dir, staged_name ++ ".zip" }));
    // As a power cut inside fs.writeAtomic leaves it.
    fs.remove(io, try std.fs.path.join(a, &.{ dir, journal_name ++ ".tmp" }));
}

/// Only a package has LICENSE beside the exe, which spares zig-out/bin. A swap cut short may have moved LICENSE aside, but then the journal is there.
fn isPackage(a: std.mem.Allocator, io: std.Io, dir: []const u8) !bool {
    return fs.exists(io, try std.fs.path.join(a, &.{ dir, "LICENSE" })) or fs.exists(io, try std.fs.path.join(a, &.{ dir, journal_name }));
}

const Bundle = struct { app: []const u8, dir: []const u8 };
const Target = union(enum) { appimage: []const u8, folder: []const u8, bundle: Bundle };

/// A bundle's base path is its Contents/Resources/; zig-out/bin is not inside a .app.
fn bundleOf(io: std.Io, base: []const u8) ?Bundle {
    const contents = std.fs.path.dirname(base) orelse return null;
    const app = std.fs.path.dirname(contents) orelse return null;
    if (!std.mem.endsWith(u8, app, ".app")) return null;
    const dir = std.fs.path.dirname(app) orelse return null;
    // A translocated copy sits on a read-only mount, and a standard user cannot replace an admin's bundle; both get the releases page.
    if (!fs.writable(io, app) or !fs.writable(io, dir)) return null;
    return .{ .app = app, .dir = dir };
}

/// Dev builds and Flatpak find nothing and get the releases page.
fn findTarget(a: std.mem.Allocator, io: std.Io) !?Target {
    if (release_key == null) return null;
    switch (builtin.os.tag) {
        .linux => {
            if (builtin.cpu.arch != .x86_64) return null;
            const path = c.SDL_getenv("APPIMAGE") orelse return null;
            return .{ .appimage = try a.dupe(u8, std.mem.span(path)) };
        },
        .windows => {
            const base = c.SDL_GetBasePath() orelse return null;
            const dir = try a.dupe(u8, std.mem.span(base));
            if (!try isPackage(a, io, dir)) return null;
            return .{ .folder = dir };
        },
        .macos => {
            const base = c.SDL_GetBasePath() orelse return null;
            return .{ .bundle = bundleOf(io, try a.dupe(u8, std.mem.span(base))) orelse return null };
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
        .bundle => macos_asset,
    } else null;
    if (j.target) |t| switch (t) {
        .appimage => {},
        .folder => |dir| try removeLeftovers(a, j.io, dir),
        .bundle => |b| try removeLeftovers(a, j.io, b.dir),
    };
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
    const a = j.arena.allocator();
    const url = j.release.?.url.?;
    const proof = try fetchProof(a, j.io, download_base, url, release_key.?);
    switch (j.target.?) {
        .appimage => |path| try replaceFile(j.gpa, j.io, url, proof, path, &j.progress),
        .folder => |dir| try replacePackage(a, j.io, url, proof, dir, windows_folder, swapFiles, dir, &j.progress),
        .bundle => |b| try replacePackage(a, j.io, url, proof, b.dir, macos_bundle, swapBundle, b.app, &j.progress),
    }
}

fn fakeAnswer(a: std.mem.Allocator, tag: []const u8, url: []const u8, sig_url: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\{{"tag_name":"{s}","html_url":"x","assets":[
        \\{{"name":"other.zip","browser_download_url":"https://evil.example/o"}},
        \\{{"name":"a.zip","browser_download_url":"{s}"}},
        \\{{"name":"a.zip.sig","browser_download_url":"{s}"}}]}}
    , .{ tag, url, sig_url });
}

test "only a newer release is offered, and its numbers compare as numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try fakeAnswer(a, "v0.10.0", download_base ++ "v0.10.0/a.zip", download_base ++ "v0.10.0/a.zip.sig");
    const newer = (try parseRelease(a, json, "0.9.0", "a.zip")).?;
    try std.testing.expectEqualStrings("0.10.0", newer.version);
    try std.testing.expectEqualStrings(download_base ++ "v0.10.0/a.zip", newer.url.?);
    try std.testing.expectEqual(@as(?Release, null), try parseRelease(a, json, "0.10.0", "a.zip"));
    try std.testing.expectEqual(@as(?Release, null), try parseRelease(a, json, "0.11.0", "a.zip"));
}

test "a parsed release outlives the answer it came from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try fakeAnswer(a, "v1.2.3", download_base ++ "v1.2.3/a.zip", download_base ++ "v1.2.3/a.zip.sig");
    const release = (try parseRelease(a, json, "0.1.0", "a.zip")).?;
    @memset(json, 'x');
    try std.testing.expectEqualStrings("1.2.3", release.version);
    try std.testing.expectEqualStrings(download_base ++ "v1.2.3/a.zip", release.url.?);
}

test "an unsigned or foreign asset gets the releases page, never an install" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good_url = download_base ++ "v1.0.0/a.zip";
    const good_sig = good_url ++ ".sig";
    try std.testing.expectEqual(@as(?[]const u8, null), (try parseRelease(a, try fakeAnswer(a, "v1.0.0", good_url, good_sig), "0.1.0", null)).?.url);
    const cases = [_][]const u8{
        try fakeAnswer(a, "v1.0.0", good_url, "https://evil.example/a.zip.sig"),
        try fakeAnswer(a, "v1.0.0", good_url, download_base ++ "v0.9.0/a.zip.sig"),
        try fakeAnswer(a, "v1.0.0", "https://evil.example/a.zip", good_sig),
        try fakeAnswer(a, "v1.0.0", "http://github.com/square3ang/actuon/releases/download/v1.0.0/a.zip", good_sig),
    };
    for (cases) |json| try std.testing.expectEqual(@as(?[]const u8, null), (try parseRelease(a, json, "0.1.0", "a.zip")).?.url);
    try std.testing.expectEqual(@as(?[]const u8, null), (try parseRelease(a, try fakeAnswer(a, "v1.0.0", good_url, good_sig), "0.1.0", "missing.zip")).?.url);
}

test "a build without an update key never installs, even as an AppImage" {
    if (release_key != null) return error.SkipZigTest;
    const env = c.SDL_GetEnvironment();
    try std.testing.expect(c.SDL_SetEnvironmentVariable(env, "APPIMAGE", "/tmp/actuon.AppImage", true));
    defer _ = c.SDL_UnsetEnvironmentVariable(env, "APPIMAGE");
    try std.testing.expectEqual(@as(?Target, null), try findTarget(std.testing.allocator, std.testing.io));
}

test "a bad release answer is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good_url = download_base ++ "v1.0.0/a.zip";
    const cases = [_][]const u8{ "not json", try fakeAnswer(a, "nightly", good_url, good_url ++ ".sig") };
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

/// Signs `data` as asset `name` with the key a seed of `seed_byte` makes; the proof checks against seed 1.
fn proofFor(data: []const u8, name: []const u8, seed_byte: u8) !Proof {
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &sum, .{});
    const message = try release_sig.message(std.testing.allocator, name, sum);
    defer std.testing.allocator.free(message);
    const signer = try Ed25519.KeyPair.generateDeterministic(@splat(seed_byte));
    const trusted = try Ed25519.KeyPair.generateDeterministic(@splat(1));
    return .{ .key = trusted.public_key.toBytes(), .signature = (try signer.sign(message, null)).toBytes(), .name = "v1.0.0/a.zip" };
}

fn tmpPath(a: std.mem.Allocator, tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "a download without a good signature never replaces the game" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = try tmpPath(a, &tmp, "actuon.AppImage");
    try fs.write(std.testing.io, target, "old");
    var progress: http.Progress = .{};

    const refusals = [_]struct { body: []const u8, proof: Proof }{
        .{ .body = "tampered", .proof = try proofFor("new", "v1.0.0/a.zip", 1) },
        .{ .body = "new", .proof = try proofFor("new", "v1.0.0/a.zip", 2) },
        .{ .body = "new", .proof = try proofFor("new", "v0.9.0/a.zip", 1) },
    };
    for (refusals) |k| {
        var bad: TestServer = .{ .server = undefined, .thread = undefined };
        const bad_url = try bad.start(k.body);
        const refused = replaceFile(a, std.testing.io, bad_url, k.proof, target, &progress);
        bad.stop();
        try std.testing.expectError(error.BadSignature, refused);
        try std.testing.expectEqualStrings("old", try fs.readAlloc(a, std.testing.io, target, 16));
        try std.testing.expect(!fs.exists(std.testing.io, try tmpPath(a, &tmp, "actuon.AppImage.update")));
    }

    var good: TestServer = .{ .server = undefined, .thread = undefined };
    const good_url = try good.start("new");
    const applied = replaceFile(a, std.testing.io, good_url, try proofFor("new", "v1.0.0/a.zip", 1), target, &progress);
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
    const applied = replacePackage(a, std.testing.io, url, try proofFor(zip, "v1.0.0/a.zip", 1), dir, windows_folder, swapFiles, dir, &progress);
    server.stop();
    try applied;
    try std.testing.expectEqualStrings("new", try fs.readAlloc(a, std.testing.io, exe, 16));
    try std.testing.expectEqualStrings("new", try fs.readAlloc(a, std.testing.io, try std.fs.path.join(a, &.{ dir, "new.dll" }), 16));
    const old = try std.fmt.allocPrint(a, "{s}" ++ old_suffix, .{exe});
    try std.testing.expectEqualStrings("old", try fs.readAlloc(a, std.testing.io, old, 16));
    try std.testing.expect(!fs.exists(std.testing.io, try std.fs.path.join(a, &.{ dir, staged_name })));
    try std.testing.expect(!fs.exists(std.testing.io, try std.fs.path.join(a, &.{ dir, journal_name })));

    // As a download cut short leaves it.
    const archive = try std.fs.path.join(a, &.{ dir, staged_name ++ ".zip" });
    try fs.write(std.testing.io, archive, "part");
    try removeLeftovers(a, std.testing.io, dir);
    try std.testing.expect(!fs.exists(std.testing.io, old));
    try std.testing.expect(!fs.exists(std.testing.io, archive));
    try std.testing.expectEqualStrings("mine", try fs.readAlloc(a, std.testing.io, save, 16));
}

test "a package with a bad signature or without the game changes nothing" {
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
    const cases = [_]struct { zip: []const u8, proof: Proof, want: anyerror }{
        .{ .zip = "tampered", .proof = try proofFor("something else", "v1.0.0/a.zip", 1), .want = error.BadSignature },
        .{ .zip = no_game, .proof = try proofFor(no_game, "v1.0.0/a.zip", 1), .want = error.BadPackage },
    };
    for (cases) |k| {
        var server: TestServer = .{ .server = undefined, .thread = undefined };
        const url = try server.start(k.zip);
        const r = replacePackage(a, std.testing.io, url, k.proof, dir, windows_folder, swapFiles, dir, &progress);
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
    try std.testing.expect(!fs.exists(std.testing.io, try std.fs.path.join(a, &.{ to, journal_name })));
}

test "the next start finishes a swap that stopped at any step" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const staged = staged_name ++ "/" ++ windows_folder ++ "/";
    const kept = [_][]const u8{ "LICENSE", "a.dll", windows_exe };
    // swapIn's renames in swapFiles' order, the exe last; new.dll has no old copy to keep.
    const renames = [_][2][]const u8{
        .{ "LICENSE", "LICENSE" ++ old_suffix },
        .{ staged ++ "LICENSE", "LICENSE" },
        .{ "a.dll", "a.dll" ++ old_suffix },
        .{ staged ++ "a.dll", "a.dll" },
        .{ staged ++ "new.dll", "new.dll" },
        .{ windows_exe, windows_exe ++ old_suffix },
        .{ staged ++ windows_exe, windows_exe },
    };
    // Step 0 stops inside fs.writeAtomic, before the journal is renamed in; step k after k-1 renames.
    for (0..renames.len + 2) |step| {
        const dir = try tmpPath(a, &tmp, try std.fmt.allocPrint(a, "game{d}", .{step}));
        try fs.mkdirs(io, try std.fs.path.join(a, &.{ dir, staged }));
        for (kept ++ [_][]const u8{"new.dll"}) |n| try fs.write(io, try std.fs.path.join(a, &.{ dir, staged, n }), "new");
        for (kept) |n| try fs.write(io, try std.fs.path.join(a, &.{ dir, n }), "old");
        const plan = "LICENSE\na.dll\nnew.dll\n" ++ windows_exe ++ "\n";
        try fs.write(io, try std.fs.path.join(a, &.{ dir, if (step == 0) journal_name ++ ".tmp" else journal_name }), plan);
        for (renames[0..step -| 1]) |r| try fs.rename(try std.fs.path.join(a, &.{ dir, r[0] }), try std.fs.path.join(a, &.{ dir, r[1] }));

        // Even with LICENSE moved aside, findTarget must still see a package.
        try std.testing.expect(try isPackage(a, io, dir));
        try removeLeftovers(a, io, dir);
        const want = if (step == 0) "old" else "new";
        for (kept) |n| try std.testing.expectEqualStrings(want, try fs.readAlloc(a, io, try std.fs.path.join(a, &.{ dir, n }), 16));
        try std.testing.expectEqual(step > 0, fs.exists(io, try std.fs.path.join(a, &.{ dir, "new.dll" })));
        for ([_][]const u8{ journal_name, journal_name ++ ".tmp", staged_name, "LICENSE" ++ old_suffix, windows_exe ++ old_suffix, "a.dll" ++ old_suffix }) |n| try std.testing.expect(!fs.exists(io, try std.fs.path.join(a, &.{ dir, n })));
    }
    try std.testing.expect(!try isPackage(a, io, try tmpPath(a, &tmp, "")));
}

test "a second instance leaves an update in progress alone" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(a, &tmp, "game");
    const staged = try std.fs.path.join(a, &.{ dir, staged_name, windows_folder });
    try fs.mkdirs(io, staged);
    try fs.write(io, try std.fs.path.join(a, &.{ staged, windows_exe }), "new");
    try fs.write(io, try std.fs.path.join(a, &.{ dir, windows_exe }), "old");
    const journal = try std.fs.path.join(a, &.{ dir, journal_name });
    try fs.write(io, journal, windows_exe ++ "\n");
    const held = (try fs.lock(io, try std.fs.path.join(a, &.{ dir, lock_name }))).?;
    defer held.close(io);

    try removeLeftovers(a, io, dir);
    try std.testing.expect(fs.exists(io, journal));
    try std.testing.expectEqualStrings("old", try fs.readAlloc(a, io, try std.fs.path.join(a, &.{ dir, windows_exe }), 16));
    var progress: http.Progress = .{};
    try std.testing.expectError(error.UpdateBusy, replacePackage(a, io, "http://127.0.0.1:1/", try proofFor("x", "v1.0.0/a.zip", 1), dir, windows_folder, swapFiles, dir, &progress));
    try std.testing.expect(fs.exists(io, try std.fs.path.join(a, &.{ staged, windows_exe })));
}

test "a journal naming a path outside the game folder moves nothing" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(a, &tmp, "game");
    const staged = try std.fs.path.join(a, &.{ dir, staged_name, windows_folder });
    try fs.mkdirs(io, staged);
    try fs.write(io, try std.fs.path.join(a, &.{ staged, windows_exe }), "new");
    try fs.write(io, try std.fs.path.join(a, &.{ dir, windows_exe }), "old");
    for ([_][]const u8{ windows_exe ++ "\n../" ++ windows_exe ++ "\n", windows_exe ++ "\n..\n", "sub\\" ++ windows_exe ++ "\n" }) |plan| {
        try fs.write(io, try std.fs.path.join(a, &.{ dir, journal_name }), plan);
        try std.testing.expectError(error.BadJournal, removeLeftovers(a, io, dir));
        try std.testing.expectEqualStrings("old", try fs.readAlloc(a, io, try std.fs.path.join(a, &.{ dir, windows_exe }), 16));
        try std.testing.expect(fs.exists(io, try std.fs.path.join(a, &.{ staged, windows_exe })));
    }
}

test "a signature must be 64 bytes, and it vouches for the tag and asset in the url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key: [32]u8 = @splat(7);
    for ([_][]const u8{ &@as([63]u8, @splat(1)), &@as([65]u8, @splat(1)) }) |body| {
        var server: TestServer = .{ .server = undefined, .thread = undefined };
        const base = try a.dupe(u8, try server.start(body));
        const r = fetchProof(std.testing.allocator, std.testing.io, base, try std.fmt.allocPrint(a, "{s}v1.0.0/a.zip", .{base}), key);
        server.stop();
        try std.testing.expectError(error.BadSignature, r);
    }
    var server: TestServer = .{ .server = undefined, .thread = undefined };
    const base = try a.dupe(u8, try server.start(&@as([64]u8, @splat(2))));
    const r = fetchProof(std.testing.allocator, std.testing.io, base, try std.fmt.allocPrint(a, "{s}v1.0.0/a.zip", .{base}), key);
    server.stop();
    const proof = try r;
    try std.testing.expectEqualStrings("v1.0.0/a.zip", proof.name);
    try std.testing.expectEqual(@as([64]u8, @splat(2)), proof.signature);
    try std.testing.expectEqual(key, proof.key);
}

test "only a writable bundle is a target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try fs.mkdirs(std.testing.io, try tmpPath(a, &tmp, "apps/x.app/Contents/Resources"));
    try fs.mkdirs(std.testing.io, try tmpPath(a, &tmp, "bin/Contents/Resources"));
    const bundle = bundleOf(std.testing.io, try tmpPath(a, &tmp, "apps/x.app/Contents/Resources/")).?;
    try std.testing.expectEqualStrings(try tmpPath(a, &tmp, "apps/x.app"), bundle.app);
    try std.testing.expectEqualStrings(try tmpPath(a, &tmp, "apps"), bundle.dir);
    try std.testing.expectEqual(@as(?Bundle, null), bundleOf(std.testing.io, try tmpPath(a, &tmp, "bin/Contents/Resources/")));
    // Root writes anywhere, and Windows ignores the mode.
    if (builtin.os.tag == .windows or std.c.geteuid() == 0) return;
    try tmp.dir.setFilePermissions(std.testing.io, "apps", .fromMode(0o555), .{});
    defer tmp.dir.setFilePermissions(std.testing.io, "apps", .fromMode(0o755), .{}) catch {};
    try std.testing.expectEqual(@as(?Bundle, null), bundleOf(std.testing.io, try tmpPath(a, &tmp, "apps/x.app/Contents/Resources/")));
}

test "a verified bundle swaps in whole, and the old one leaves with the staging folder" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(a, &tmp, "apps");
    const app = try std.fs.path.join(a, &.{ dir, "renamed.app" });
    try fs.mkdirs(std.testing.io, app);
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ app, "old.txt" }), "old");
    const zip = try zipBytes(a, &tmp, &.{ macos_bundle ++ "/" ++ macos_exe, macos_bundle ++ "/Contents/Info.plist" });

    var server: TestServer = .{ .server = undefined, .thread = undefined };
    const url = try server.start(zip);
    var progress: http.Progress = .{};
    const applied = replacePackage(a, std.testing.io, url, try proofFor(zip, "v1.0.0/a.zip", 1), dir, macos_bundle, swapBundle, app, &progress);
    server.stop();
    try applied;
    const exe = try std.fs.path.join(a, &.{ app, macos_exe });
    try std.testing.expectEqualStrings("new", try fs.readAlloc(a, std.testing.io, exe, 16));
    try std.testing.expect(!fs.exists(std.testing.io, try std.fs.path.join(a, &.{ app, "old.txt" })));
    try std.testing.expect(!fs.exists(std.testing.io, try std.fs.path.join(a, &.{ dir, staged_name })));
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, exe, .{});
    defer file.close(std.testing.io);
    try std.testing.expect((try file.stat(std.testing.io)).permissions.toMode() & 0o111 != 0);
}
