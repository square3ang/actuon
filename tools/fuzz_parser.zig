//! Mutation fuzzer for everything that reads untrusted bytes. Run in ReleaseSafe: a safety panic
//! or a leak is a bug. Usage: fuzz_parser <list-file> <iterations> [seed]
const std = @import("std");
const core = @import("actuon_core");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const list = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1 << 26));
    defer gpa.free(list);
    const iters = try std.fmt.parseInt(usize, args[2], 10);
    var seeds: std.ArrayList([]u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, list, '\n');
    while (it.next()) |p| try seeds.append(gpa, try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 24)));
    defer {
        for (seeds.items) |x| gpa.free(x);
        seeds.deinit(gpa);
    }
    var prng = std.Random.DefaultPrng.init(if (args.len > 3) try std.fmt.parseInt(u64, args[3], 10) else 1);
    const r = prng.random();
    var ok: usize = 0;
    for (0..iters) |_| {
        const seed = seeds.items[r.uintLessThan(usize, seeds.items.len)];
        const buf = try gpa.dupe(u8, seed);
        defer gpa.free(buf);
        for (0..r.intRangeAtMost(usize, 1, 64)) |_| buf[r.uintLessThan(usize, buf.len)] = r.int(u8);
        const cut = r.intRangeAtMost(usize, buf.len / 2, buf.len);
        var chart = core.bms.parse(gpa, buf[0..cut], .{ .seed = r.int(u64) }) catch continue;
        defer chart.deinit();
        ok += 1;
        // Feed the result through the sim too: hostile timing must not panic it either.
        const s = try core.sim.Sim.create(gpa, &chart, .{});
        defer s.destroy();
        var t: i64 = 0;
        for (0..200) |_| {
            t += r.intRangeAtMost(i64, 0, 50_000);
            s.input(.{ .time_us = t, .lane = r.uintLessThan(u8, 18), .key = r.uintLessThan(u8, 2), .down = r.boolean() });
        }
        var bytes: [512]u8 = undefined;
        r.bytes(&bytes);
        @memcpy(bytes[0..4], core.replay.magic);
        bytes[4] = core.replay.version;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        _ = core.replay.decode(arena.allocator(), &bytes) catch {};
    }
    std.debug.print("{d} iterations, {d} parsed, no crash\n", .{ iters, ok });
}
