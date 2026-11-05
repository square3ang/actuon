//! Usage: fuzz_parser <list-file> <iterations> [seed]. Run in ReleaseSafe: any safety panic or leak is a bug.
const std = @import("std");
const core = @import("actuon_core");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const list = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1 << 26));
    defer gpa.free(list);
    const iters = try std.fmt.parseInt(usize, args[2], 10);
    const Seed = struct { bytes: []u8, bmson: bool };
    var seeds: std.ArrayList(Seed) = .empty;
    var it = std.mem.tokenizeScalar(u8, list, '\n');
    while (it.next()) |p| try seeds.append(gpa, .{
        .bytes = try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 24)),
        .bmson = std.ascii.endsWithIgnoreCase(p, ".bmson"),
    });
    defer {
        for (seeds.items) |x| gpa.free(x.bytes);
        seeds.deinit(gpa);
    }
    var prng = std.Random.DefaultPrng.init(if (args.len > 3) try std.fmt.parseInt(u64, args[3], 10) else 1);
    const r = prng.random();
    var ok: usize = 0;
    for (0..iters) |_| {
        const seed = seeds.items[r.uintLessThan(usize, seeds.items.len)];
        const buf = try gpa.dupe(u8, seed.bytes);
        defer gpa.free(buf);
        // JSON breaks at the first stray byte, so a BMSON seed mostly gets digits: they reach the timing code.
        for (0..r.intRangeAtMost(usize, 1, if (seed.bmson) 4 else 64)) |_| buf[r.uintLessThan(usize, buf.len)] = if (seed.bmson and r.uintLessThan(u8, 8) != 0) '0' + r.uintLessThan(u8, 10) else r.int(u8);
        const cut = if (seed.bmson) buf.len else r.intRangeAtMost(usize, buf.len / 2, buf.len);
        var chart = (if (seed.bmson) core.bmson.parse(gpa, buf[0..cut]) else core.bms.parse(gpa, buf[0..cut], .{ .seed = r.int(u64) })) catch continue;
        defer chart.deinit();
        ok += 1;
        const s = try core.sim.Sim.create(gpa, &chart, .{});
        defer s.destroy();
        var events: [200]core.sim.Event = undefined;
        var t: i64 = -1_000_000;
        for (&events) |*e| {
            t += r.intRangeAtMost(i64, 0, 50_000);
            e.* = .{ .time_us = t, .lane = r.uintLessThan(u8, 18), .key = r.uintLessThan(u8, 2), .down = r.boolean() };
            s.input(e.*);
        }
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // A valid replay with a few bytes changed gets past the header, so the server's re-simulation sees hostile fields.
        const bytes = try core.replay.encode(a, .{
            .sha256 = chart.sha256,
            .gauge = r.enumValue(core.gauge.Type),
            .gas = r.enumValue(core.options.Gas),
            .random = r.enumValue(core.options.Random),
            .flip = r.boolean(),
            .seed = r.int(u64),
            .events = &events,
        });
        for (0..r.uintLessThan(usize, 4)) |_| bytes[r.uintLessThan(usize, bytes.len)] = r.int(u8);
        const replay = core.replay.decode(a, bytes) catch continue;
        // The judge steps every ms, so only charts the server would accept (an hour) are re-simulated.
        if (chart.last_time_us > 3600 * std.time.us_per_s) continue;
        _ = try core.replay.resimulate(gpa, &chart, replay);
    }
    std.debug.print("{d} iterations, {d} parsed, no crash\n", .{ iters, ok });
}
