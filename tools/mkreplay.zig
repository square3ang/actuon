//! Writes a perfect-play replay for a chart: used by the IR end-to-end test and parity checks.
const std = @import("std");
const core = @import("actuon_core");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1 << 28));
    defer gpa.free(bytes);
    var chart = try core.bms.parse(gpa, bytes, .{});
    defer chart.deinit();
    var events: std.ArrayList(core.sim.Event) = .empty;
    defer events.deinit(gpa);
    for (chart.notes) |n| {
        if (n.kind == .mine) continue;
        if (n.kind == .ln_end) {
            try events.append(gpa, .{ .time_us = n.time_us, .lane = n.lane, .key = 0, .down = false });
        } else {
            try events.append(gpa, .{ .time_us = n.time_us, .lane = n.lane, .key = 0, .down = true });
            if (n.kind == .normal) try events.append(gpa, .{ .time_us = n.time_us + 1000, .lane = n.lane, .key = 0, .down = false });
        }
    }
    std.mem.sort(core.sim.Event, events.items, {}, struct {
        fn f(_: void, l: core.sim.Event, r: core.sim.Event) bool {
            return l.time_us < r.time_us;
        }
    }.f);
    const out = try core.replay.encode(gpa, .{ .sha256 = chart.sha256, .bms_random = chart.random, .events = events.items });
    defer gpa.free(out);
    const f = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer f.close(io);
    try f.writeStreamingAll(io, out);
    std.debug.print("{s} {d} notes\n", .{ chart.sha256, chart.total_notes });
}
