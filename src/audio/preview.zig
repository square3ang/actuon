const std = @import("std");
const c = @import("c");
const fs = @import("../platform/fs.zig");
const decode = @import("decode.zig");
const clip = @import("clip.zig");

/// Longer than the engine's one second fade, the last it reads of anything replaced.
const retire_ms = 3000;

const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    rate: u32,
    path: []const u8,
    from_chart: bool,
    data: []f32 = &.{},
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    thread: ?*c.SDL_Thread = null,

    fn run(ud: ?*anyopaque) callconv(.c) c_int {
        const j: *Job = @ptrCast(@alignCast(ud));
        defer j.done.store(true, .release);
        j.data = (if (j.from_chart) clip.render(j.gpa, std.heap.page_allocator, j.io, j.path, j.rate, &j.cancel) else j.decodeFile()) catch return 0;
        return 0;
    }

    fn decodeFile(j: *Job) ![]f32 {
        const bytes = try fs.readAlloc(j.gpa, j.io, j.path, 1 << 28);
        defer j.gpa.free(bytes);
        return (try decode.decode(std.heap.page_allocator, bytes, j.path, j.rate, null)).data;
    }

    /// Hands over `path`, which the caller keeps or frees.
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
    io: std.Io,
    rate: u32,
    current: []const f32 = &.{},
    current_path: []const u8 = "",
    job: ?*Job = null,
    retired: std.ArrayList(Retired) = .empty,

    fn retire(p: *Preview, data: []const f32, now: u64) void {
        if (data.len == 0) return;
        p.retired.append(p.gpa, .{ .data = data, .at = now }) catch {};
    }

    pub fn tick(p: *Preview, path: ?[]const u8, from_chart: bool, now: u64) void {
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
                if (data.len > 0) std.heap.page_allocator.free(data);
                p.gpa.free(job_path);
            }
        };
        if (p.job) |j| if (path == null or !std.mem.eql(u8, path.?, j.path)) j.cancel.store(true, .release);
        const want = path orelse {
            p.retire(p.current, now);
            p.current = &.{};
            p.gpa.free(p.current_path);
            p.current_path = "";
            return;
        };
        if (p.job != null or std.mem.eql(u8, want, p.current_path)) return;
        const j = p.gpa.create(Job) catch return;
        j.* = .{ .gpa = p.gpa, .io = p.io, .rate = p.rate, .from_chart = from_chart, .path = p.gpa.dupe(u8, want) catch {
            p.gpa.destroy(j);
            return;
        } };
        j.thread = c.SDL_CreateThread(Job.run, "preview", j);
        if (j.thread == null) j.done.store(true, .release);
        p.job = j;
    }

    /// Decoded audio stays mapped until exit, past the engine.
    pub fn deinit(p: *Preview) void {
        if (p.job) |j| {
            j.cancel.store(true, .release);
            p.gpa.free(j.finish());
        }
        p.gpa.free(p.current_path);
        p.retired.deinit(p.gpa);
    }
};

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
    var p: Preview = .{ .gpa = std.testing.allocator, .io = std.testing.io, .rate = 48000 };
    defer p.deinit();
    const data = try std.heap.page_allocator.alloc(f32, 2);
    p.current = data;
    p.current_path = try std.testing.allocator.dupe(u8, "x");
    p.tick(null, false, 1000);
    try std.testing.expectEqual(@as(usize, 0), p.current.len);
    try std.testing.expectEqual(@as(usize, 1), p.retired.items.len);
    p.tick(null, false, 1000 + retire_ms);
    try std.testing.expectEqual(@as(usize, 0), p.retired.items.len);
}

test "a preview still mixing for a chart the cursor left is told to stop, then dropped" {
    const gpa = std.testing.allocator;
    var p: Preview = .{ .gpa = gpa, .io = std.testing.io, .rate = 48000 };
    defer p.deinit();
    const j = try gpa.create(Job);
    j.* = .{ .gpa = gpa, .io = std.testing.io, .rate = 48000, .from_chart = true, .path = try gpa.dupe(u8, "a.bms") };
    p.job = j;
    p.tick("a.bms", true, 0);
    try std.testing.expect(!j.cancel.load(.acquire));
    p.tick("b.bms", true, 0);
    try std.testing.expect(j.cancel.load(.acquire));
    j.data = try std.heap.page_allocator.alloc(f32, 2);
    j.done.store(true, .release);
    p.tick("b.bms", true, 0);
    try std.testing.expectEqual(@as(usize, 0), p.current.len);
    try std.testing.expect(p.job != null);
    try std.testing.expectEqualStrings("b.bms", p.job.?.path);
}
