//! Replay file: chart identity, options, and the raw input stream. Results are never stored as
//! truth: anything that needs the score re-simulates, which is what makes IR verification possible.
const std = @import("std");
const types = @import("types.zig");
const sim_mod = @import("sim.zig");
const gauge = @import("gauge.zig");
const options = @import("options.zig");

pub const magic = "ACTR";
pub const version: u8 = 1;
pub const max_events = 4_000_000;
/// Set on the gauge byte: old replays stay valid, and a verifier without GAS rejects the file.
const gas_bit: u8 = 0x80;
/// The LN mode sits above the random option: old replays read as plain LN.
const ln_mode_shift = 6;

pub const Replay = struct {
    sha256: [64]u8 = @splat('0'),
    gauge: gauge.Type = .normal,
    gas: bool = false,
    random: options.Random = .off,
    ln_mode: options.LnMode = .ln,
    seed: u64 = 0,
    /// Resolved #RANDOM/#SWITCH values the chart was played with.
    bms_random: []const i32 = &.{},
    events: []const sim_mod.Event = &.{},
};

fn putVar(w: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u64) !void {
    var x = v;
    while (x >= 0x80) : (x >>= 7) try w.append(gpa, @as(u8, @truncate(x)) | 0x80);
    try w.append(gpa, @truncate(x));
}

pub fn encode(gpa: std.mem.Allocator, r: Replay) ![]u8 {
    var w: std.ArrayList(u8) = .empty;
    errdefer w.deinit(gpa);
    try w.appendSlice(gpa, magic);
    try w.append(gpa, version);
    try w.appendSlice(gpa, &r.sha256);
    try w.append(gpa, @backingInt(r.gauge) | gas_bit * @as(u8, @intFromBool(r.gas)));
    try w.append(gpa, @backingInt(r.random) | @backingInt(r.ln_mode) << ln_mode_shift);
    try putVar(&w, gpa, r.seed);
    try putVar(&w, gpa, r.bms_random.len);
    for (r.bms_random) |v| try putVar(&w, gpa, @as(u32, @bitCast(v)));
    try putVar(&w, gpa, r.events.len);
    var prev: i64 = 0;
    for (r.events) |e| {
        const delta = e.time_us - prev;
        prev = e.time_us;
        try putVar(&w, gpa, @as(u64, @bitCast((delta << 1) ^ (delta >> 63))));
        try w.append(gpa, e.lane | (@as(u8, e.key & 1) << 6) | (@as(u8, @intFromBool(e.down)) << 7));
    }
    return w.toOwnedSlice(gpa);
}

const Reader = struct {
    b: []const u8,
    i: usize = 0,
    fn byte(r: *Reader) !u8 {
        if (r.i >= r.b.len) return error.Truncated;
        r.i += 1;
        return r.b[r.i - 1];
    }
    fn vari(r: *Reader) !u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (shift < 64) : (shift += 7) {
            const c = try r.byte();
            v |= @as(u64, c & 0x7F) << @intCast(shift);
            if (c & 0x80 == 0) return v;
        }
        return error.BadVarint;
    }
};

/// Decodes untrusted bytes. Returned slices live in `a`.
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Replay {
    var r: Reader = .{ .b = bytes };
    if (bytes.len < 4 + 1 + 64 + 2 or !std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    r.i = 4;
    if (try r.byte() != version) return error.BadVersion;
    var out: Replay = .{};
    @memcpy(&out.sha256, bytes[5..69]);
    r.i = 69;
    const gauge_byte = try r.byte();
    out.gas = gauge_byte & gas_bit != 0;
    out.gauge = std.enums.fromInt(gauge.Type, gauge_byte & ~gas_bit) orelse return error.BadField;
    const random_byte = try r.byte();
    out.random = std.enums.fromInt(options.Random, random_byte & (1 << ln_mode_shift) - 1) orelse return error.BadField;
    out.ln_mode = std.enums.fromInt(options.LnMode, random_byte >> ln_mode_shift) orelse return error.BadField;
    out.seed = try r.vari();
    const nr = try r.vari();
    if (nr > 4096) return error.BadField;
    const rnd = try a.alloc(i32, @intCast(nr));
    for (rnd) |*v| v.* = @bitCast(@as(u32, @truncate(try r.vari())));
    out.bms_random = rnd;
    const ne = try r.vari();
    if (ne > max_events or ne > bytes.len) return error.BadField;
    const ev = try a.alloc(sim_mod.Event, @intCast(ne));
    var t: i64 = 0;
    for (ev, 0..) |*e, i| {
        const z = try r.vari();
        const delta: i64 = @bitCast((z >> 1) ^ (0 -% (z & 1)));
        // events must be ordered: the sim's contract, and the verifier's defence against time travel
        // Only the first may start below zero: a key pressed during the lead-in has a negative song time.
        if ((delta < 0 and i > 0) or delta < -3_600_000_000 or delta > 3_600_000_000) return error.BadField;
        t += delta;
        const f = try r.byte();
        e.* = .{ .time_us = t, .lane = f & 0x3F, .key = (f >> 6) & 1, .down = f & 0x80 != 0 };
    }
    out.events = ev;
    return out;
}

pub const Result = extern struct {
    ok: bool = false,
    clear: u8 = 0,
    gauge_type: u8 = 0,
    ex_score: u32 = 0,
    max_combo: u32 = 0,
    miss: u32 = 0,
    total_notes: u32 = 0,
    counts: [6]u32 = @splat(0),
    gauge_value: f32 = 0,
};

/// Re-runs a play. `chart` must have been parsed with `r.bms_random`; it is modified by options.
pub fn resimulate(gpa: std.mem.Allocator, chart: *types.Chart, r: Replay) !Result {
    _ = options.applyLnMode(chart, r.ln_mode);
    options.apply(chart, r.random, r.seed);
    const s = try sim_mod.Sim.create(gpa, chart, .{ .gauge = r.gauge, .gas = r.gas });
    defer s.destroy();
    for (r.events) |e| s.input(e);
    s.advance(chart.last_time_us + 2_000_000);
    return summarize(s, chart.total_notes);
}

pub fn summarize(s: *const sim_mod.Sim, total: u32) Result {
    var res: Result = .{
        .ok = true,
        .clear = @backingInt(s.clear(true)),
        .gauge_type = @backingInt(s.gauge_type),
        .ex_score = s.score.exScore(),
        .max_combo = s.score.max_combo,
        .miss = s.score.missCount(),
        .total_notes = total,
        .gauge_value = s.gauge().value,
    };
    for (0..6) |i| res.counts[i] = s.score.counts[i][0] + s.score.counts[i][1];
    return res;
}

test "round trip and resimulate" {
    const parser = @import("../bms/parser.zig");
    const gpa = std.testing.allocator;
    const src =
        \\#BPM 120
        \\#TOTAL 300
        \\#WAV01 a.wav
        \\#00111:01010101
    ;
    var c = try parser.parse(gpa, src, .{});
    defer c.deinit();
    var evs: std.ArrayList(sim_mod.Event) = .empty;
    defer evs.deinit(gpa);
    for (c.notes, 0..) |n, i| {
        const off: i64 = @as(i64, @intCast(i)) * 7000;
        try evs.append(gpa, .{ .time_us = n.time_us + off, .lane = n.lane, .down = true });
        try evs.append(gpa, .{ .time_us = n.time_us + off + 50_000, .lane = n.lane, .down = false });
    }
    const bytes = try encode(gpa, .{ .sha256 = c.sha256, .events = evs.items });
    defer gpa.free(bytes);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try decode(arena.allocator(), bytes);
    try std.testing.expectEqual(evs.items.len, r.events.len);
    try std.testing.expect(!r.gas);
    const gas_bytes = try encode(gpa, .{ .sha256 = c.sha256, .gauge = .exhard, .gas = true });
    defer gpa.free(gas_bytes);
    const g = try decode(arena.allocator(), gas_bytes);
    try std.testing.expect(g.gas);
    try std.testing.expectEqual(gauge.Type.exhard, g.gauge);
    const res = try resimulate(gpa, &c, r);
    try std.testing.expect(res.ok);
    try std.testing.expectEqual(@as(u32, 3 * 2 + 1), res.ex_score); // 0,7,14 ms PG; 21 ms at NORMAL=GR
    // truncated and hostile inputs are rejected, not crashed on
    try std.testing.expectError(error.Truncated, decode(arena.allocator(), bytes[0 .. bytes.len - 1]));
}

test "the LN mode survives the round trip and a bad one is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try encode(a, .{ .random = .mirror, .ln_mode = .hcn });
    const back = try decode(a, bytes);
    try std.testing.expectEqual(options.LnMode.hcn, back.ln_mode);
    try std.testing.expectEqual(options.Random.mirror, back.random);
    // version, hash and gauge come before the random byte
    bytes[4 + 1 + 64 + 1] |= 3 << ln_mode_shift;
    try std.testing.expectError(error.BadField, decode(a, bytes));
}

test "a key pressed before the song starts survives the round trip" {
    const parser = @import("../bms/parser.zig");
    const gpa = std.testing.allocator;
    var c = try parser.parse(gpa, "#BPM 120\n#TOTAL 300\n#WAV01 a.wav\n#00111:01\n", .{});
    defer c.deinit();
    const evs = [_]sim_mod.Event{
        .{ .time_us = -1_500_000, .lane = 0, .down = true },
        .{ .time_us = -1_400_000, .lane = 0, .down = false },
        .{ .time_us = c.notes[0].time_us, .lane = c.notes[0].lane, .down = true },
    };
    const bytes = try encode(gpa, .{ .sha256 = c.sha256, .events = &evs });
    defer gpa.free(bytes);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try decode(arena.allocator(), bytes);
    try std.testing.expectEqual(@as(i64, -1_500_000), r.events[0].time_us);
    try std.testing.expectEqual(c.notes[0].time_us, r.events[2].time_us);
    try std.testing.expectEqual(@as(u32, 2), (try resimulate(gpa, &c, r)).ex_score);
    // Later events still cannot go back in time.
    const back = [_]sim_mod.Event{ .{ .time_us = 5, .lane = 0, .down = true }, .{ .time_us = 4, .lane = 0, .down = false } };
    const bad = try encode(gpa, .{ .events = &back });
    defer gpa.free(bad);
    try std.testing.expectError(error.BadField, decode(arena.allocator(), bad));
}
