//! Prints the same fingerprint as tools/golden/DumpChart.java, for parity checks.
const std = @import("std");
const core = @import("actuon_core");

fn mix(h: u64, v: i64) u64 {
    return (h ^ @as(u64, @bitCast(v))) *% 0x100000001b3;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const list = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1 << 26));
    defer gpa.free(list);
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;
    var ones: [256]i32 = @splat(1);
    var it = std.mem.tokenizeScalar(u8, list, '\n');
    while (it.next()) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 28));
        defer gpa.free(data);
        const low = std.ascii.endsWithIgnoreCase(path, ".pms");
        var chart = (if (std.ascii.endsWithIgnoreCase(path, ".bmson"))
            core.bmson.parse(gpa, data)
        else
            core.bms.parse(gpa, data, .{ .is_pms = low, .selected_random = &ones })) catch |e| {
            try w.print("{s}\tFAILED {t}\n", .{ path, e });
            continue;
        };
        defer chart.deinit();
        var h: u64 = 0xcbf29ce484222325;
        for (chart.notes) |n| {
            if (args.len > 2) try w.print("{d} {d} {d} {d}\n", .{ n.time_us, n.lane, @intFromEnum(n.kind), if (n.wav < 0) -1 else n.wav });
            h = mix(h, n.time_us);
            h = mix(h, n.lane);
            h = mix(h, @intFromEnum(n.kind));
            h = mix(h, if (n.wav < 0) -1 else n.wav);
        }
        const is_bmson = std.ascii.endsWithIgnoreCase(path, ".bmson");
        try w.print("{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{x}\n", .{
            path,                                    if (is_bmson) "" else chart.md5[0..],  chart.sha256[0..],
            chart.mode.keys(),                       chart.total_notes,                     @divTrunc(chart.last_time_us, 1000),
            @divTrunc(chart.last_note_us, 1000),     h,
        });
    }
    try w.flush();
}
