//! Lane options. Deterministic for a seed, so a replay stores just the seed and the option.
const std = @import("std");
const types = @import("types.zig");

pub const Random = enum(u8) { off, mirror, random, r_random, s_random };

fn keyLanes(mode: types.Mode, side: u8, buf: *[9]u8) []u8 {
    const per: u8 = mode.keys() / mode.players();
    const offset = side * per;
    var n: usize = 0;
    for (0..per) |i| {
        const lane: u8 = offset + @as(u8, @intCast(i));
        if (mode.scratchOf(lane) >= 0) continue;
        buf[n] = lane;
        n += 1;
    }
    return buf[0..n];
}

pub const LnMode = enum(u8) { ln, cn, hcn };

/// Decides the LNs the chart leaves open. False when nothing changed, so the play is an ordinary one.
pub fn applyLnMode(chart: *types.Chart, mode: LnMode) bool {
    if (mode == .ln) return false;
    var changed = false;
    for (chart.notes) |*n| {
        if (!n.ln_open) continue;
        changed = true;
        n.ln_type = if (mode == .cn) .cn else .hcn;
        // LN scores once, CN and HCN at both ends.
        if (n.kind == .ln_end) chart.total_notes += 1;
    }
    if (changed and !chart.total_defined) chart.total = types.defaultTotal(chart.total_notes);
    return changed;
}

/// Rewrites lanes in place. Scratch stays on scratch, as in LR2.
pub fn apply(chart: *types.Chart, opt: Random, seed: u64) void {
    if (opt == .off) return;
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var map: [types.max_lanes]u8 = undefined;
    for (&map, 0..) |*m, i| m.* = @intCast(i);

    for (0..chart.mode.players()) |side| {
        var buf: [9]u8 = undefined;
        const lanes = keyLanes(chart.mode, @intCast(side), &buf);
        var shuffled: [9]u8 = undefined;
        @memcpy(shuffled[0..lanes.len], lanes);
        const dst = shuffled[0..lanes.len];
        switch (opt) {
            .off, .s_random => {},
            .mirror => std.mem.reverse(u8, dst),
            .random => rnd.shuffle(u8, dst),
            .r_random => {
                std.mem.rotate(u8, dst, rnd.intRangeLessThan(usize, 1, @max(dst.len, 2)));
                if (rnd.boolean()) std.mem.reverse(u8, dst);
            },
        }
        for (lanes, dst) |from, to| map[from] = to;
    }

    if (opt != .s_random) {
        for (chart.notes) |*n| n.lane = map[n.lane];
        for (chart.hidden) |*h| h.lane = map[h.lane];
        return;
    }

    // S-RANDOM: re-roll every note, but an LN keeps its lane until it ends and two notes at the
    // same instant never share a lane.
    var busy_until: [types.max_lanes]i64 = @splat(-1);
    var i: usize = 0;
    while (i < chart.notes.len) {
        var j = i;
        const t = chart.notes[i].time_us;
        var used: [types.max_lanes]bool = @splat(false);
        // ends keep the lane their start already chose, and that lane stays taken at this instant
        for (chart.notes[i..]) |n| {
            if (n.time_us != t) break;
            j += 1;
        }
        for (chart.notes[i..j]) |*n| {
            if (n.kind == .ln_end and n.pair >= 0) {
                n.lane = chart.notes[@intCast(n.pair)].lane;
                used[n.lane] = true;
            }
        }
        for (chart.notes[i..j]) |*n| {
            if (n.kind == .ln_end and n.pair >= 0) continue;
            if (chart.mode.scratchOf(n.lane) >= 0) {
                used[n.lane] = true;
                continue;
            }
            const per: u8 = chart.mode.keys() / chart.mode.players();
            var buf: [9]u8 = undefined;
            const lanes = keyLanes(chart.mode, n.lane / per, &buf);
            var candidates: [9]u8 = undefined;
            var c: usize = 0;
            for (lanes) |l| if (!used[l] and busy_until[l] < t) {
                candidates[c] = l;
                c += 1;
            };
            if (c > 0) n.lane = candidates[rnd.intRangeLessThan(usize, 0, c)];
            used[n.lane] = true;
            if (n.kind == .ln_start and n.pair >= 0) busy_until[n.lane] = chart.notes[@intCast(n.pair)].time_us;
        }
        i = j;
    }
}

test "mirror and s-random keep lanes valid" {
    const parser = @import("../bms/parser.zig");
    const src =
        \\#BPM 120
        \\#WAV01 a.wav
        \\#00111:01010101
        \\#00112:01010101
        \\#00116:01010101
        \\#00151:01000100
    ;
    var c = try parser.parse(std.testing.allocator, src, .{});
    defer c.deinit();
    apply(&c, .mirror, 1);
    try std.testing.expect(c.notes[0].lane == 4 or c.notes[1].lane == 4);
    var d = try parser.parse(std.testing.allocator, src, .{});
    defer d.deinit();
    apply(&d, .s_random, 7);
    for (d.notes) |n| try std.testing.expect(n.lane < d.mode.keys());
    for (d.notes) |n| {
        if (n.kind == .ln_start) try std.testing.expectEqual(n.lane, d.notes[@intCast(n.pair)].lane);
    }
}
