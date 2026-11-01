//! The selected song's preview: one decoded at a time off the main thread, and only the playing
//! one kept. What the audio thread may still read is freed a while after it stops being wanted.
const std = @import("std");
const c = @import("c");
const fs = @import("../platform/fs.zig");
const decode = @import("decode.zig");

/// Longer than the engine's one second fade, the last it reads of anything replaced.
const retire_ms = 3000;

const Job = struct {
    gpa: std.mem.Allocator,
    rate: u32,
    path: []const u8,
    data: []f32 = &.{},
    done: std.atomic.Value(bool) = .init(false),
    thread: ?*c.SDL_Thread = null,

    fn run(ud: ?*anyopaque) callconv(.c) c_int {
        const j: *Job = @ptrCast(@alignCast(ud));
        defer j.done.store(true, .release);
        const bytes = fs.readAlloc(j.gpa, j.path, 1 << 28) catch return 0;
        defer j.gpa.free(bytes);
        const s = decode.decode(std.heap.page_allocator, bytes, j.path, j.rate) catch return 0;
        j.data = s.data;
        return 0;
    }

    /// Joins, and hands over `path`, which the caller keeps or frees.
    fn finish(j: *Job) []const u8 {
        if (j.thread) |t| c.SDL_WaitThread(t, null);
        const path = j.path;
        j.gpa.destroy(j);
        return path;
    }
};

const Retired = struct { data: []const f32, at: u64 };

pub const Preview = struct {
    gpa: std.mem.Allocator,
    rate: u32,
    /// What should play; empty for the menu music.
    current: []const f32 = &.{},
    current_path: []const u8 = "",
    job: ?*Job = null,
    retired: std.ArrayList(Retired) = .empty,

    fn retire(p: *Preview, data: []const f32, now: u64) void {
        if (data.len == 0) return;
        p.retired.append(p.gpa, .{ .data = data, .at = now }) catch {};
    }

    /// Call each frame of song select. `path` is the preview wanted, null for none. An old preview
    /// keeps playing until the new one has decoded.
    pub fn tick(p: *Preview, path: ?[]const u8, now: u64) void {
        var i: usize = 0;
        while (i < p.retired.items.len) {
            const r = p.retired.items[i];
            if (now - r.at < retire_ms) {
                i += 1;
                continue;
            }
            std.heap.page_allocator.free(r.data);
            _ = p.retired.swapRemove(i);
        }
        if (p.job) |j| if (j.done.load(.acquire)) {
            const data = j.data;
            const job_path = j.finish();
            p.job = null;
            if (path != null and std.mem.eql(u8, path.?, job_path)) {
                p.retire(p.current, now);
                p.gpa.free(p.current_path);
                p.current = data;
                p.current_path = job_path;
            } else {
                // Never played: the cursor moved on while it decoded.
                if (data.len > 0) std.heap.page_allocator.free(data);
                p.gpa.free(job_path);
            }
        };
        const want = path orelse {
            p.retire(p.current, now);
            p.current = &.{};
            p.gpa.free(p.current_path);
            p.current_path = "";
            return;
        };
        if (p.job != null or std.mem.eql(u8, want, p.current_path)) return;
        const j = p.gpa.create(Job) catch return;
        j.* = .{ .gpa = p.gpa, .rate = p.rate, .path = p.gpa.dupe(u8, want) catch {
            p.gpa.destroy(j);
            return;
        } };
        j.thread = c.SDL_CreateThread(Job.run, "preview", j);
        if (j.thread == null) j.done.store(true, .release);
        p.job = j;
    }

    /// Decoded audio stays mapped until exit, past the engine.
    pub fn deinit(p: *Preview) void {
        if (p.job) |j| p.gpa.free(j.finish());
        p.gpa.free(p.current_path);
        p.retired.deinit(p.gpa);
    }
};

/// The file a folder offers as its preview when the chart names none, such as preview_music.ogg.
pub fn isPreviewFile(name: []const u8, exts: []const []const u8) bool {
    const bare = if (std.mem.startsWith(u8, name, "_")) name[1..] else name;
    if (!std.ascii.startsWithIgnoreCase(bare, "preview")) return false;
    const ext = std.fs.path.extension(name);
    if (ext.len < 2) return false;
    for (exts) |e| if (std.ascii.eqlIgnoreCase(ext[1..], e)) return true;
    return false;
}

test "a folder's preview is known by its name and type" {
    const exts = [_][]const u8{ "ogg", "wav" };
    try std.testing.expect(isPreviewFile("preview_music.ogg", &exts));
    try std.testing.expect(isPreviewFile("_Preview.WAV", &exts));
    try std.testing.expect(!isPreviewFile("preview.png", &exts));
    try std.testing.expect(!isPreviewFile("kick.ogg", &exts));
    try std.testing.expect(!isPreviewFile("preview", &exts));
}

test "with nothing wanted, a preview goes silent and its audio waits out the fade" {
    var p: Preview = .{ .gpa = std.testing.allocator, .rate = 48000 };
    defer p.deinit();
    const data = try std.heap.page_allocator.alloc(f32, 2);
    p.current = data;
    p.current_path = try std.testing.allocator.dupe(u8, "x");
    p.tick(null, 1000);
    try std.testing.expectEqual(@as(usize, 0), p.current.len);
    try std.testing.expectEqual(@as(usize, 1), p.retired.items.len);
    p.tick(null, 1000 + retire_ms);
    try std.testing.expectEqual(@as(usize, 0), p.retired.items.len);
}
