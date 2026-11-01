//! Sounds a skin asks for by path: decoded off the main thread, kept until exit.
const std = @import("std");
const c = @import("c");
const fs = @import("../platform/fs.zig");
const decode = @import("decode.zig");
const engine_mod = @import("engine.zig");

pub const Op = enum { cache, play, loop, stop };

pub const extensions = [_][]const u8{ "ogg", "wav", "flac", "mp3" };

/// The file for `name` directly in `dir`, if there is one.
pub fn findIn(al: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]const u8 {
    for (extensions) |ext| {
        const p = std.fmt.allocPrint(al, "{s}/{s}.{s}", .{ dir, name, ext }) catch return null;
        if (fs.stat(p) != null) return p;
    }
    return null;
}

fn collectSets(al: std.mem.Allocator, dir: []const u8, markers: []const []const u8, depth: u8, out: *std.ArrayList([]const u8)) void {
    for (markers) |name| if (findIn(al, dir, name) != null) {
        out.append(al, dir) catch return;
        break;
    };
    if (depth == 0) return;
    for (fs.list(al, dir) catch return) |e| {
        if (!e.is_dir) continue;
        collectSets(al, std.fs.path.join(al, &.{ dir, e.name }) catch return, markers, depth - 1, out);
    }
}

/// Folders up to three levels down in actuon's own `folder` and in the one the player picked.
fn sets(al: std.mem.Allocator, folder: []const u8, root: []const u8, markers: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (fs.dataDir(al)) |data| {
        collectSets(al, std.fmt.allocPrint(al, "{s}{s}", .{ data, folder }) catch return out.items, markers, 3, &out);
    } else |_| {}
    if (root.len > 0) collectSets(al, root, markers, 3, &out);
    return out.items;
}

pub fn musicSets(al: std.mem.Allocator, root: []const u8) []const []const u8 {
    return sets(al, "bgm", root, &.{ "select", "decide" });
}

pub fn soundSets(al: std.mem.Allocator, root: []const u8) []const []const u8 {
    return sets(al, "sound", root, &.{ "f-open", "scratch", "o-open" });
}

/// Steps along the skin's own ("") and the sets, stopping at either end so a second press or a
/// held key doesn't turn the pick off. A value no longer on offer counts as "".
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
    rate: u32,
    path: []const u8,
    data: []const f32 = &.{},
    ready: std.atomic.Value(bool) = .init(false),
    thread: ?*c.SDL_Thread = null,
    /// A request made before the decode finished. Main thread only.
    pending: ?struct { loop: bool, gain: f32 } = null,
    loop_slot: ?u8 = null,

    fn run(ud: ?*anyopaque) callconv(.c) c_int {
        const e: *Entry = @ptrCast(@alignCast(ud));
        defer e.ready.store(true, .release);
        const bytes = fs.readAlloc(e.gpa, e.path, 1 << 28) catch return 0;
        defer e.gpa.free(bytes);
        // Voices read this until exit, past the engine, like the menu sounds.
        const s = decode.decode(std.heap.page_allocator, bytes, e.path, e.rate) catch return 0;
        e.data = s.data;
        return 0;
    }
};

/// Rotates through the one-shot slots, past the music's.
pub fn nextSlot(slot: *u8) u8 {
    const now = slot.*;
    slot.* = if (now + 1 < engine_mod.ui_slots) now + 1 else engine_mod.first_oneshot_slot;
    return now;
}

pub const Player = struct {
    gpa: std.mem.Allocator,
    engine: *engine_mod.Engine,
    slot: *u8,
    entries: std.ArrayList(*Entry) = .empty,

    /// shortcut: one thread per new file, fine for a skin's few dozen; a worker queue if a skin floods this.
    pub fn entry(p: *Player, path: []const u8) ?*Entry {
        for (p.entries.items) |e| if (std.mem.eql(u8, e.path, path)) return e;
        const owned = p.gpa.dupe(u8, path) catch return null;
        const e = p.gpa.create(Entry) catch {
            p.gpa.free(owned);
            return null;
        };
        e.* = .{ .gpa = p.gpa, .rate = p.engine.rate, .path = owned };
        p.entries.append(p.gpa, e) catch {
            p.gpa.free(owned);
            p.gpa.destroy(e);
            return null;
        };
        e.thread = c.SDL_CreateThread(Entry.run, "skin sound", e);
        if (e.thread == null) e.ready.store(true, .release);
        return e;
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

    /// Starts what finished decoding. The engine's command queue takes one producer, this thread.
    pub fn tick(p: *Player) void {
        for (p.entries.items) |e| {
            const want = e.pending orelse continue;
            if (!e.ready.load(.acquire)) continue;
            e.pending = null;
            if (e.data.len == 0) continue;
            const s = nextSlot(p.slot);
            p.engine.uiPlay(s, e.data, want.loop, want.gain);
            if (want.loop) e.loop_slot = s;
        }
    }

    pub fn deinit(p: *Player) void {
        for (p.entries.items) |e| {
            if (e.thread) |t| c.SDL_WaitThread(t, null);
            p.gpa.free(e.path);
            p.gpa.destroy(e);
        }
        p.entries.deinit(p.gpa);
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
