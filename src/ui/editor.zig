//! A running instance owns the window, so later launches pass their command through a polled file.
const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");

pub const Command = struct {
    stop: bool = false,
    file: []const u8 = "",
    measure: i32 = 0,
};

/// BMSE, iBMSC, uBMSC and BmsONE run `<exe> -P -N<measure> <file>` to preview and `-S` to stop.
pub fn parseArgs(args: []const [:0]const u8) ?Command {
    var cmd: Command = .{};
    var found = false;
    for (args[1..]) |raw| {
        const a: []const u8 = raw;
        if (std.mem.eql(u8, a, "-P")) {
            found = true;
        } else if (std.mem.eql(u8, a, "-S")) {
            found = true;
            cmd.stop = true;
        } else if (std.mem.startsWith(u8, a, "-N")) {
            cmd.measure = std.fmt.parseInt(i32, a[2..], 10) catch 0;
        } else if (!std.mem.startsWith(u8, a, "-")) cmd.file = a;
    }
    return if (found) cmd else null;
}

fn path(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const dir = try fs.dataDir(a);
    return std.fmt.allocPrint(a, "{s}{s}", .{ dir, name });
}

const alive_window_s = 3;

fn wallSeconds() i64 {
    var t: c.SDL_Time = 0;
    _ = c.SDL_GetCurrentTime(&t);
    return @divTrunc(t, std.time.ns_per_s);
}

pub fn otherInstanceRunning(a: std.mem.Allocator) bool {
    const p = path(a, "instance") catch return false;
    const st = fs.stat(p) orelse return false;
    return wallSeconds() - st.mtime <= alive_window_s;
}

pub fn heartbeat(a: std.mem.Allocator) void {
    const p = path(a, "instance") catch return;
    fs.write(p, "") catch {};
}

pub fn clearHeartbeat(a: std.mem.Allocator) void {
    const p = path(a, "instance") catch return;
    fs.remove(p);
}

pub fn send(a: std.mem.Allocator, cmd: Command) !void {
    const p = try path(a, "command.json");
    const text = try std.json.Stringify.valueAlloc(a, cmd, .{});
    try fs.writeAtomic(a, p, text);
}

/// Strings live in `a`.
pub fn receive(a: std.mem.Allocator) ?Command {
    const p = path(a, "command.json") catch return null;
    const bytes = fs.readAlloc(a, p, 1 << 16) catch return null;
    fs.remove(p);
    return std.json.parseFromSliceLeaky(Command, a, bytes, .{ .allocate = .alloc_always }) catch null;
}

pub fn measureStart(chart: *const core.types.Chart, measure: i32) i64 {
    const target: f64 = @floatFromInt(measure);
    var best: i64 = 0;
    for (chart.timelines) |tl| {
        if (tl.section > target) break;
        best = tl.time_us;
    }
    return best;
}

test "editor command lines" {
    const args = [_][:0]const u8{ "actuon", "-P", "-N12", "a b.bms" };
    const cmd = parseArgs(&args).?;
    try std.testing.expectEqual(@as(i32, 12), cmd.measure);
    try std.testing.expectEqualStrings("a b.bms", cmd.file);
    const stop = [_][:0]const u8{ "actuon", "-S" };
    try std.testing.expect(parseArgs(&stop).?.stop);
    const plain = [_][:0]const u8{ "actuon", "a.bms" };
    try std.testing.expect(parseArgs(&plain) == null);
}
