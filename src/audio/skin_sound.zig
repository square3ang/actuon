const std = @import("std");
const c = @import("c");
const fs = @import("../platform/fs.zig");
const decode = @import("decode.zig");
const engine_mod = @import("engine.zig");

pub const Op = enum { cache, play, loop, stop };

pub const extensions = [_][]const u8{ "ogg", "wav", "flac", "mp3" };

pub fn findIn(al: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ?[]const u8 {
    for (extensions) |ext| {
        const p = std.fmt.allocPrint(al, "{s}/{s}.{s}", .{ dir, name, ext }) catch return null;
        if (fs.stat(io, p) != null) return p;
    }
    return null;
}

fn collectSets(al: std.mem.Allocator, io: std.Io, dir: []const u8, markers: []const []const u8, depth: u8, out: *std.ArrayList([]const u8)) void {
    for (markers) |name| if (findIn(al, io, dir, name) != null) {
        out.append(al, dir) catch return;
        break;
    };
    if (depth == 0) return;
    for (fs.list(al, io, dir) catch return) |e| {
        if (!e.is_dir) continue;
        collectSets(al, io, std.fs.path.join(al, &.{ dir, e.name }) catch return, markers, depth - 1, out);
    }
}

fn sets(al: std.mem.Allocator, io: std.Io, folder: []const u8, root: []const u8, markers: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (fs.dataDir(al)) |data| {
        collectSets(al, io, std.fmt.allocPrint(al, "{s}{s}", .{ data, folder }) catch return out.items, markers, 3, &out);
    } else |_| {}
    if (root.len > 0) collectSets(al, io, root, markers, 3, &out);
    return out.items;
}

pub fn musicSets(al: std.mem.Allocator, io: std.Io, root: []const u8) []const []const u8 {
    return sets(al, io, "bgm", root, &.{ "select", "decide" });
}

pub fn soundSets(al: std.mem.Allocator, io: std.Io, root: []const u8) []const []const u8 {
    return sets(al, io, "sound", root, &.{ "f-open", "scratch", "o-open" });
}

pub fn nextSet(now: []const u8, list: []const []const u8, dir: i32) []const u8 {
    var at: i64 = 0;
    for (list, 1..) |set, i| {
        if (std.mem.eql(u8, set, now)) at = @intCast(i);
    }
    const next = std.math.clamp(at + dir, 0, @as(i64, @intCast(list.len)));
    return if (next == 0) "" else list[@intCast(next - 1)];
}

pub const Entry = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    rate: u32,
    path: []const u8,
    data: []const f32 = &.{},
    ready: std.atomic.Value(bool) = .init(false),
    /// Main thread only.
    pending: ?struct { loop: bool, gain: f32 } = null,
    loop_slot: ?u8 = null,

    fn load(e: *Entry) void {
        defer e.ready.store(true, .release);
        const bytes = fs.readAlloc(e.gpa, e.io, e.path, 1 << 28) catch return;
        defer e.gpa.free(bytes);
        e.data = (decode.decode(e.gpa, bytes, e.path, e.rate) catch return).data;
    }
};

pub fn nextSlot(slot: *u8) u8 {
    const now = slot.*;
    slot.* = if (now + 1 < engine_mod.ui_slots) now + 1 else engine_mod.first_oneshot_slot;
    return now;
}

const max_entries = 256;
const workers = 2;

pub const Player = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    engine: *engine_mod.Engine,
    slot: *u8,
    /// Fixed, as workers read it while the main thread adds.
    entries: [max_entries]*Entry = undefined,
    len: usize = 0,
    queued: ?*c.SDL_Semaphore = null,
    next: std.atomic.Value(usize) = .init(0),
    quit: std.atomic.Value(bool) = .init(false),
    threads: [workers]?*c.SDL_Thread = @splat(null),

    pub fn entry(p: *Player, path: []const u8) ?*Entry {
        for (p.entries[0..p.len]) |e| if (std.mem.eql(u8, e.path, path)) return e;
        // A script naming a new file each frame would grow this list every time.
        if (p.len >= max_entries) return null;
        const owned = p.gpa.dupe(u8, path) catch return null;
        const e = p.gpa.create(Entry) catch {
            p.gpa.free(owned);
            return null;
        };
        e.* = .{ .gpa = p.gpa, .io = p.io, .rate = p.engine.rate, .path = owned };
        p.entries[p.len] = e;
        p.len += 1;
        if (p.startWorkers()) c.SDL_SignalSemaphore(p.queued) else e.ready.store(true, .release);
        return e;
    }

    fn startWorkers(p: *Player) bool {
        if (p.queued != null) return true;
        const sem = c.SDL_CreateSemaphore(0) orelse return false;
        p.queued = sem;
        var started = false;
        for (&p.threads) |*t| {
            t.* = c.SDL_CreateThread(work, "skin sound", p);
            started = started or t.* != null;
        }
        if (started) return true;
        c.SDL_DestroySemaphore(sem);
        p.queued = null;
        return false;
    }

    fn work(ud: ?*anyopaque) callconv(.c) c_int {
        const p: *Player = @ptrCast(@alignCast(ud));
        while (true) {
            c.SDL_WaitSemaphore(p.queued);
            if (p.quit.load(.acquire)) return 0;
            p.entries[p.next.fetchAdd(1, .monotonic)].load();
        }
    }

    pub fn request(p: *Player, path: []const u8, op: Op, gain: f32) void {
        const e = p.entry(path) orelse return;
        switch (op) {
            .cache => {},
            .play, .loop => e.pending = .{ .loop = op == .loop, .gain = gain },
            .stop => {
                e.pending = null;
                if (e.loop_slot) |s| p.engine.uiGain(s, 0);
                e.loop_slot = null;
            },
        }
    }

    /// The engine's command queue takes one producer, this thread.
    pub fn tick(p: *Player) void {
        for (p.entries[0..p.len]) |e| {
            const want = e.pending orelse continue;
            if (!e.ready.load(.acquire)) continue;
            e.pending = null;
            if (e.data.len == 0) continue;
            const s = nextSlot(p.slot);
            p.engine.uiPlay(s, e.data, want.loop, want.gain);
            if (want.loop) e.loop_slot = s;
        }
    }

    /// Only once the engine has stopped, as its voices may still read this audio.
    pub fn deinit(p: *Player) void {
        p.quit.store(true, .release);
        // Each worker leaves on its first wake after quit, so one count per worker frees them all.
        for (p.threads) |t| if (t != null) c.SDL_SignalSemaphore(p.queued);
        for (p.threads) |t| if (t) |th| c.SDL_WaitThread(th, null);
        if (p.queued) |s| c.SDL_DestroySemaphore(s);
        for (p.entries[0..p.len]) |e| {
            p.gpa.free(e.data);
            p.gpa.free(e.path);
            p.gpa.destroy(e);
        }
    }
};

test "stepping through sets stops at both ends" {
    const list = [_][]const u8{ "a", "b" };
    try std.testing.expectEqualStrings("a", nextSet("", &list, 1));
    try std.testing.expectEqualStrings("b", nextSet("b", &list, 1));
    try std.testing.expectEqualStrings("", nextSet("a", &list, -1));
    try std.testing.expectEqualStrings("", nextSet("gone", &list, -1));
}

test "one-shot slots skip the music's slots" {
    var slot: u8 = engine_mod.ui_slots - 1;
    try std.testing.expectEqual(engine_mod.ui_slots - 1, nextSlot(&slot));
    try std.testing.expectEqual(@as(u8, engine_mod.first_oneshot_slot), nextSlot(&slot));
}

test "a script naming a new sound every frame stops adding them" {
    var eng: engine_mod.Engine = undefined;
    eng.rate = 48000;
    var slot: u8 = engine_mod.first_oneshot_slot;
    var p: Player = .{ .gpa = std.testing.allocator, .io = std.testing.io, .engine = &eng, .slot = &slot };
    defer p.deinit();
    var buf: [32]u8 = undefined;
    for (0..max_entries + 10) |i| p.request(try std.fmt.bufPrint(&buf, "missing/{d}.ogg", .{i}), .cache, 1);
    try std.testing.expectEqual(@as(usize, max_entries), p.len);
    try std.testing.expect(p.entry("missing/0.ogg") != null);
}

test "a burst of new sounds is loaded by the few workers, each one once" {
    var eng: engine_mod.Engine = undefined;
    eng.rate = 48000;
    var slot: u8 = engine_mod.first_oneshot_slot;
    var p: Player = .{ .gpa = std.testing.allocator, .io = std.testing.io, .engine = &eng, .slot = &slot };
    defer p.deinit();
    var buf: [32]u8 = undefined;
    for (0..40) |i| _ = p.entry(try std.fmt.bufPrint(&buf, "missing/{d}.ogg", .{i}));
    for (p.entries[0..p.len]) |e| {
        var waited: u32 = 0;
        while (!e.ready.load(.acquire) and waited < 5000) : (waited += 1) c.SDL_Delay(1);
        try std.testing.expect(e.ready.load(.acquire));
    }
    try std.testing.expectEqual(@as(usize, 40), p.next.load(.monotonic));
    for (p.threads) |t| try std.testing.expect(t != null);
}
