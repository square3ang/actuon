//! Deterministic for a seed, so a replay stores just the seed and the option.
const std = @import("std");
const types = @import("types.zig");

/// beatoraja's order. The EX kinds move the scratch too.
pub const Random = enum(u8) { off, mirror, random, r_random, s_random, spiral, h_random, all_scratch, random_ex, s_random_ex };

pub const Double = enum(u8) { off, flip, battle, battle_auto_scratch };

/// Which note a press takes when several are in reach, as beatoraja's JudgeAlgorithm.
pub const Algorithm = enum(u8) { combo, duration, lowest };

/// Gauge auto shift, in beatoraja's order.
pub const Gas = enum(u8) { none, continue_play, survival_to_groove, best_clear, select_to_under };

fn sideLanes(mode: types.Mode, side: u8, with_scratch: bool, buf: *[9]u8) []u8 {
    const per: u8 = mode.keys() / mode.players();
    const offset = side * per;
    var n: usize = 0;
    var scratch: ?u8 = null;
    for (0..per) |i| {
        const lane: u8 = offset + @as(u8, @intCast(i));
        if (mode.scratchOf(lane) >= 0) {
            scratch = lane;
            continue;
        }
        buf[n] = lane;
        n += 1;
    }
    if (with_scratch) if (scratch) |s| {
        buf[n] = s;
        n += 1;
    };
    return buf[0..n];
}

fn keyLanes(mode: types.Mode, side: u8, buf: *[9]u8) []u8 {
    return sideLanes(mode, side, false, buf);
}

fn scratchOfSide(mode: types.Mode, side: u8) ?u8 {
    const per: u8 = mode.keys() / mode.players();
    for (0..per) |i| {
        const lane: u8 = side * per + @as(u8, @intCast(i));
        if (mode.scratchOf(lane) >= 0) return lane;
    }
    return null;
}

fn recount(chart: *types.Chart) void {
    var n: u32 = 0;
    for (chart.notes) |note| switch (note.kind) {
        .normal, .ln_start => n += 1,
        .ln_end => if (note.ln_type != .ln) {
            n += 1;
        },
        .mine => {},
    };
    chart.total_notes = n;
    if (!chart.total_defined) chart.total = types.defaultTotal(n);
}

fn dropNotes(chart: *types.Chart, comptime gone: fn (types.Note) bool) void {
    var map: std.ArrayList(i32) = .empty;
    const a = chart.arena.allocator();
    map.resize(a, chart.notes.len) catch return;
    var n: usize = 0;
    for (chart.notes, 0..) |note, i| {
        if (gone(note)) {
            map.items[i] = -1;
            continue;
        }
        map.items[i] = @intCast(n);
        chart.notes[n] = note;
        n += 1;
    }
    chart.notes = chart.notes[0..n];
    for (chart.notes) |*note| {
        if (note.pair >= 0) note.pair = map.items[@intCast(note.pair)];
    }
}

/// beatoraja's NO MINE assist.
pub fn dropMines(chart: *types.Chart) void {
    dropNotes(chart, struct {
        fn f(n: types.Note) bool {
            return n.kind == .mine;
        }
    }.f);
}

/// beatoraja's LEGACY NOTE assist.
pub fn legacyNotes(chart: *types.Chart) void {
    dropNotes(chart, struct {
        fn f(n: types.Note) bool {
            return n.kind == .ln_end;
        }
    }.f);
    for (chart.notes) |*n| if (n.kind == .ln_start) {
        n.kind = .normal;
        n.pair = -1;
    };
    recount(chart);
}

pub fn battle(chart: *types.Chart) !bool {
    const to: types.Mode = switch (chart.mode) {
        .beat7 => .beat14,
        .beat5 => .beat10,
        else => return false,
    };
    const offset = chart.mode.keys();
    const both = try chart.arena.allocator().alloc(types.Note, chart.notes.len * 2);
    for (chart.notes, 0..) |n, i| {
        var left = n;
        var right = n;
        if (n.pair >= 0) {
            left.pair = n.pair * 2;
            right.pair = n.pair * 2 + 1;
        }
        right.lane += offset;
        both[i * 2] = left;
        both[i * 2 + 1] = right;
    }
    chart.notes = both;
    chart.mode = to;
    recount(chart);
    return true;
}

pub fn flip(chart: *types.Chart) void {
    if (chart.mode.players() < 2) return;
    const per = chart.mode.keys() / 2;
    for (chart.notes) |*n| n.lane = if (n.lane < per) n.lane + per else n.lane - per;
    for (chart.hidden) |*h| h.lane = if (h.lane < per) h.lane + per else h.lane - per;
}

pub const LnMode = enum(u8) { ln, cn, hcn };

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

fn perNote(opt: Random) bool {
    return switch (opt) {
        .s_random, .spiral, .h_random, .all_scratch, .s_random_ex => true,
        .off, .mirror, .random, .r_random, .random_ex => false,
    };
}

/// beatoraja's H-RANDOM jack threshold (a 16th at 120 BPM); ALL-SCR keeps scratch notes this far apart too.
const jack_gap_us: i64 = 125_000;

const Spiral = struct { head: u8 = 0, step: u8 = 1 };

/// Scratch stays on scratch, as in LR2, except under the EX options and ALL-SCR.
pub fn apply(chart: *types.Chart, opts: [2]Random, seed: u64) void {
    const sides = chart.mode.players();
    if (opts[0] == .off and (sides < 2 or opts[1] == .off)) return;
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var map: [types.max_lanes]u8 = undefined;
    for (&map, 0..) |*m, i| m.* = @intCast(i);
    var spirals: [2]Spiral = @splat(.{});

    for (0..sides) |side| {
        const opt = opts[side];
        var buf: [9]u8 = undefined;
        const lanes = sideLanes(chart.mode, @intCast(side), opt == .random_ex, &buf);
        var shuffled: [9]u8 = undefined;
        @memcpy(shuffled[0..lanes.len], lanes);
        const dst = shuffled[0..lanes.len];
        switch (opt) {
            .mirror => std.mem.reverse(u8, dst),
            .random, .random_ex => rnd.shuffle(u8, dst),
            .r_random => {
                std.mem.rotate(u8, dst, rnd.intRangeLessThan(usize, 1, @max(dst.len, 2)));
                if (rnd.boolean()) std.mem.reverse(u8, dst);
            },
            .spiral => spirals[side] = .{
                .head = rnd.intRangeLessThan(u8, 0, @intCast(lanes.len)),
                .step = rnd.intRangeLessThan(u8, 1, @intCast(@max(lanes.len, 2))),
            },
            else => {},
        }
        for (lanes, dst) |from, to| map[from] = to;
    }
    for (chart.notes) |*n| n.lane = map[n.lane];
    for (chart.hidden) |*h| h.lane = map[h.lane];
    if (!perNote(opts[0]) and !(sides == 2 and perNote(opts[1]))) return;
    reroll(chart, opts, &spirals, rnd);
}

fn reroll(chart: *types.Chart, opts: [2]Random, spirals: *[2]Spiral, rnd: std.Random) void {
    const mode = chart.mode;
    const per: u8 = mode.keys() / mode.players();
    var busy_until: [types.max_lanes]i64 = @splat(-1);
    var last_at: [types.max_lanes]i64 = @splat(std.math.minInt(i64) / 2);
    var i: usize = 0;
    while (i < chart.notes.len) {
        var j = i;
        const t = chart.notes[i].time_us;
        var used: [types.max_lanes]bool = @splat(false);
        for (chart.notes[i..]) |n| {
            if (n.time_us != t) break;
            j += 1;
        }
        for (chart.notes[i..j]) |*n| {
            if (n.kind == .ln_end and n.pair >= 0) {
                n.lane = chart.notes[@intCast(n.pair)].lane;
                used[n.lane] = true;
            } else if (mode.scratchOf(n.lane) >= 0 and opts[n.lane / per] != .s_random_ex) used[n.lane] = true;
        }
        for (0..mode.players()) |side| {
            if (opts[side] != .spiral) continue;
            var buf: [9]u8 = undefined;
            const keys = keyLanes(mode, @intCast(side), &buf);
            // Turning while an LN is held would move its end.
            for (keys) |l| {
                if (busy_until[l] >= t) break;
            } else spirals[side].head = @intCast((spirals[side].head + spirals[side].step) % keys.len);
        }
        for (chart.notes[i..j]) |*n| {
            if (n.kind == .ln_end and n.pair >= 0) continue;
            const side: u8 = n.lane / per;
            const opt = opts[side];
            if (!perNote(opt)) continue;
            // Scratch notes that stay put still hold their lane, so ALL-SCR adds nothing inside a scratch LN.
            defer {
                last_at[n.lane] = t;
                if (n.kind == .ln_start and n.pair >= 0) busy_until[n.lane] = chart.notes[@intCast(n.pair)].time_us;
            }
            const on_scratch = mode.scratchOf(n.lane) >= 0;
            if (on_scratch and opt != .s_random_ex) continue;
            var buf: [9]u8 = undefined;
            const lanes = sideLanes(mode, side, opt == .s_random_ex, &buf);
            var free: [9]u8 = undefined;
            var c: usize = 0;
            for (lanes) |l| if (!used[l] and busy_until[l] < t) {
                free[c] = l;
                c += 1;
            };
            switch (opt) {
                .s_random, .s_random_ex => if (c > 0) {
                    n.lane = free[rnd.intRangeLessThan(usize, 0, c)];
                },
                .h_random => if (c > 0) {
                    var rested: [9]u8 = undefined;
                    var r: usize = 0;
                    for (free[0..c]) |l| if (t - last_at[l] >= jack_gap_us) {
                        rested[r] = l;
                        r += 1;
                    };
                    n.lane = if (r > 0) rested[rnd.intRangeLessThan(usize, 0, r)] else free[rnd.intRangeLessThan(usize, 0, c)];
                },
                .spiral => {
                    const k = std.mem.indexOfScalar(u8, lanes, n.lane) orelse 0;
                    const to = lanes[(k + spirals[side].head) % lanes.len];
                    n.lane = if (!used[to] and busy_until[to] < t) to else if (c > 0) free[0] else n.lane;
                },
                .all_scratch => if (scratchOfSide(mode, side)) |s| {
                    if (n.kind == .normal and !used[s] and busy_until[s] < t and t - last_at[s] >= jack_gap_us) n.lane = s;
                },
                else => unreachable,
            }
            used[n.lane] = true;
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
    apply(&c, .{ .mirror, .off }, 1);
    try std.testing.expect(c.notes[0].lane == 4 or c.notes[1].lane == 4);
    var d = try parser.parse(std.testing.allocator, src, .{});
    defer d.deinit();
    apply(&d, .{ .s_random, .off }, 7);
    for (d.notes) |n| try std.testing.expect(n.lane < d.mode.keys());
    for (d.notes) |n| {
        if (n.kind == .ln_start) try std.testing.expectEqual(n.lane, d.notes[@intCast(n.pair)].lane);
    }
}

fn expectPlayable(c: *const types.Chart) !void {
    for (c.notes, 0..) |n, i| {
        try std.testing.expect(n.lane < c.mode.keys());
        if (n.kind == .ln_start and n.pair >= 0) try std.testing.expectEqual(n.lane, c.notes[@intCast(n.pair)].lane);
        for (c.notes[i + 1 ..]) |m| {
            if (m.time_us != n.time_us) break;
            try std.testing.expect(m.lane != n.lane);
        }
    }
}

test "every random option, on either side, keeps notes apart and LNs whole" {
    const parser = @import("../bms/parser.zig");
    const src =
        \\#BPM 120
        \\#WAV01 a.wav
        \\#00111:0101010101010101
        \\#00112:0001010100010101
        \\#00116:0101000101010001
        \\#00118:0100010001000100
        \\#00121:0101010101010101
        \\#00129:0001000100010001
        \\#00126:0100010001000100
        \\#00151:0100000001000000
        \\#00153:0001000000010000
        \\#00161:0001000000010000
    ;
    for (std.enums.values(Random)) |opt| {
        for (0..5) |seed| {
            var c = try parser.parse(std.testing.allocator, src, .{});
            defer c.deinit();
            try std.testing.expectEqual(types.Mode.beat14, c.mode);
            apply(&c, .{ opt, opt }, seed);
            try expectPlayable(&c);
        }
    }
}

test "ALL-SCR moves notes onto a free scratch, and EX options may leave it" {
    const parser = @import("../bms/parser.zig");
    var c = try parser.parse(std.testing.allocator, "#BPM 60\n#WAV01 a.wav\n#00111:01010101\n", .{});
    defer c.deinit();
    apply(&c, .{ .all_scratch, .off }, 3);
    for (c.notes) |n| try std.testing.expect(c.mode.scratchOf(n.lane) >= 0);
    // A key note while a scratch LN is held stays on its key.
    var held = try parser.parse(std.testing.allocator, "#BPM 60\n#WAV01 a.wav\n#00156:01000001\n#00111:00010000\n", .{});
    defer held.deinit();
    apply(&held, .{ .all_scratch, .off }, 3);
    for (held.notes) |n| if (n.kind == .normal) try std.testing.expect(held.mode.scratchOf(n.lane) < 0);
}

test "each random option's lanes stay as they were, so saved replays play back the same" {
    const parser = @import("../bms/parser.zig");
    const src =
        \\#BPM 150
        \\#WAV01 a.wav
        \\#00111:0101010101010101
        \\#00112:0001000100010001
        \\#00113:0100010001000100
        \\#00114:0000010000000100
        \\#00115:0100000001000000
        \\#00116:0001000000010000
        \\#00118:0000000100000001
        \\#00119:0100000000000100
        \\#00121:0101010101010101
        \\#00129:0000010000000100
    ;
    // One string per option: each note's lane, in chart order.
    const want = [_][]const u8{
        "0246801780238e01580248017802368e0158", "6420e657e643e8651e642e657e6430e8651e", "561385278560895248561852785603895248",
        "4205e437e421ed436e420e437e4215ed436e", "5163d407c163dc03490439637b5036be0459", "13509567e245cb604a3508017d4603ba1269",
        "5163d407c163dc03490439637b5036be0459", "7246f017f723fe715f724f017f7236fe715f", "6725c634c670ce631c672c634c6705ce631c",
        "6274e4059736d83418430e536937468d517d",
    };
    for (std.enums.values(Random), want) |opt, lanes| {
        var c = try parser.parse(std.testing.allocator, src, .{});
        defer c.deinit();
        apply(&c, .{ opt, opt }, 42);
        var got: [64]u8 = undefined;
        for (c.notes, 0..) |n, i| got[i] = "0123456789abcdef"[n.lane];
        try std.testing.expectEqualStrings(lanes, got[0..c.notes.len]);
    }
}

test "battle copies a single chart to the second side, flip swaps the sides" {
    const parser = @import("../bms/parser.zig");
    var c = try parser.parse(std.testing.allocator, "#BPM 120\n#WAV01 a.wav\n#00111:01\n#00119:0001\n#00151:0101\n", .{});
    defer c.deinit();
    const single = c.total_notes;
    try std.testing.expect(try battle(&c));
    try std.testing.expectEqual(types.Mode.beat14, c.mode);
    try std.testing.expectEqual(single * 2, c.total_notes);
    try expectPlayable(&c);
    for (c.notes) |n| if (n.pair >= 0) try std.testing.expectEqual(n.lane, c.notes[@intCast(n.pair)].lane);
    const before = c.notes[0].lane;
    flip(&c);
    try std.testing.expectEqual(before + 8, c.notes[0].lane);
}

test "NO MINE and LEGACY NOTE drop notes and keep the count right" {
    const parser = @import("../bms/parser.zig");
    var c = try parser.parse(std.testing.allocator, "#BPM 120\n#WAV01 a.wav\n#00111:01\n#00151:0101\n#000D2:0101\n#00112:0001\n", .{});
    defer c.deinit();
    try std.testing.expect(c.has_mine);
    dropMines(&c);
    for (c.notes) |n| try std.testing.expect(n.kind != .mine);
    try expectPlayable(&c);
    const notes = c.total_notes;
    legacyNotes(&c);
    try std.testing.expectEqual(notes, c.total_notes);
    for (c.notes) |n| try std.testing.expectEqual(types.NoteKind.normal, n.kind);
}
