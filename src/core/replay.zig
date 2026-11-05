//! Never stores results, so the IR re-simulates every score.
const std = @import("std");
const types = @import("types.zig");
const sim_mod = @import("sim.zig");
const gauge = @import("gauge.zig");
const options = @import("options.zig");

pub const magic = "ACTR";
/// 2 adds a byte each for the gauge shift, the 2P random and DP flip, and the judge algorithm.
pub const version: u8 = 2;
pub const max_events = 4_000_000;
/// Version 1 set this on the gauge byte for select-to-under GAS.
const gas_bit: u8 = 0x80;
/// The LN mode sits above the random option: old replays read as plain LN.
const ln_mode_shift = 6;
const floor_shift = 4;
const flip_bit: u8 = 0x80;

/// Only options a verifier can rank: assists and battle are never recorded.
pub const Replay = struct {
    sha256: [64]u8 = @splat('0'),
    gauge: gauge.Type = .normal,
    gas: options.Gas = .none,
    gas_floor: gauge.Type = .assist_easy,
    random: options.Random = .off,
    random2: options.Random = .off,
    flip: bool = false,
    ln_mode: options.LnMode = .ln,
    algorithm: options.Algorithm = .combo,
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
    try w.append(gpa, @backingInt(r.gauge));
    try w.append(gpa, @backingInt(r.random) | @backingInt(r.ln_mode) << ln_mode_shift);
    try w.append(gpa, @backingInt(r.gas) | @backingInt(r.gas_floor) << floor_shift);
    try w.append(gpa, @backingInt(r.random2) | flip_bit * @as(u8, @intFromBool(r.flip)));
    try w.append(gpa, @backingInt(r.algorithm));
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

/// The bytes are untrusted. Returned slices live in `a`.
pub fn decode(a: std.mem.Allocator, bytes: []const u8) !Replay {
    var r: Reader = .{ .b = bytes };
    if (bytes.len < 4 + 1 + 64 + 2 or !std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    r.i = 4;
    const ver = try r.byte();
    if (ver != 1 and ver != version) return error.BadVersion;
    var out: Replay = .{};
    @memcpy(&out.sha256, bytes[5..69]);
    r.i = 69;
    const gauge_byte = try r.byte();
    if (ver == 1 and gauge_byte & gas_bit != 0) out.gas = .select_to_under;
    out.gauge = std.enums.fromInt(gauge.Type, if (ver == 1) gauge_byte & ~gas_bit else gauge_byte) orelse return error.BadField;
    const random_byte = try r.byte();
    out.random = std.enums.fromInt(options.Random, random_byte & (1 << ln_mode_shift) - 1) orelse return error.BadField;
    out.ln_mode = std.enums.fromInt(options.LnMode, random_byte >> ln_mode_shift) orelse return error.BadField;
    if (ver == version) {
        const gas_byte = try r.byte();
        out.gas = std.enums.fromInt(options.Gas, gas_byte & (1 << floor_shift) - 1) orelse return error.BadField;
        out.gas_floor = std.enums.fromInt(gauge.Type, gas_byte >> floor_shift) orelse return error.BadField;
        // beatoraja offers A-EASY, EASY and NORMAL.
        if (@backingInt(out.gas_floor) > @backingInt(gauge.Type.normal)) return error.BadField;
        const side_byte = try r.byte();
        out.random2 = std.enums.fromInt(options.Random, side_byte & ~flip_bit) orelse return error.BadField;
        out.flip = side_byte & flip_bit != 0;
        out.algorithm = std.enums.fromInt(options.Algorithm, try r.byte()) orelse return error.BadField;
    }
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
        // Ordered, against time travel; only the first may be negative, a key pressed in the lead-in.
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
    /// The replay's own, for a versus round to tell its play from an older one.
    seed: u64 = 0,
};

/// `chart` must have been parsed with `r.bms_random`; options modify it.
pub fn resimulate(gpa: std.mem.Allocator, chart: *types.Chart, r: Replay) !Result {
    _ = options.applyLnMode(chart, r.ln_mode);
    applyLanes(chart, r);
    const s = try sim_mod.Sim.create(gpa, chart, simConfig(r));
    defer s.destroy();
    for (r.events) |e| s.input(e);
    s.advance(chart.last_time_us + 2_000_000);
    var res = summarize(s, chart.total_notes);
    res.seed = r.seed;
    return res;
}

/// The order the client plays them in.
pub fn applyLanes(chart: *types.Chart, r: Replay) void {
    options.apply(chart, .{ r.random, r.random2 }, r.seed);
    if (r.flip) options.flip(chart);
}

pub fn simConfig(r: Replay) sim_mod.Config {
    return .{ .gauge = r.gauge, .gas = r.gas, .gas_floor = r.gas_floor, .algorithm = r.algorithm };
}

pub fn summarize(s: *const sim_mod.Sim, total: u32) Result {
    var res: Result = .{
        .ok = true,
        .clear = @backingInt(s.clear(true)),
        .gauge_type = @backingInt(s.gauge_type),
        .ex_score = s.score.exScore(),
        .max_combo = s.score.max_combo,
        .miss = s.score.bp(total),
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
    try std.testing.expectEqual(options.Gas.none, r.gas);
    const gas_bytes = try encode(gpa, .{ .sha256 = c.sha256, .gauge = .exhard, .gas = .best_clear, .gas_floor = .normal, .random2 = .spiral, .flip = true, .algorithm = .lowest });
    defer gpa.free(gas_bytes);
    const g = try decode(arena.allocator(), gas_bytes);
    try std.testing.expectEqual(options.Gas.best_clear, g.gas);
    try std.testing.expectEqual(gauge.Type.normal, g.gas_floor);
    try std.testing.expectEqual(options.Random.spiral, g.random2);
    try std.testing.expect(g.flip);
    try std.testing.expectEqual(options.Algorithm.lowest, g.algorithm);
    try std.testing.expectEqual(gauge.Type.exhard, g.gauge);
    // A version 1 file keeps its GAS bit and its layout.
    var old = try arena.allocator().dupe(u8, gas_bytes);
    old[4] = 1;
    old[69] = @backingInt(gauge.Type.exhard) | gas_bit;
    const v1 = try std.mem.concat(arena.allocator(), u8, &.{ old[0..71], old[74..] });
    const back = try decode(arena.allocator(), v1);
    try std.testing.expectEqual(options.Gas.select_to_under, back.gas);
    try std.testing.expectEqual(options.Random.off, back.random2);
    // A floor above NORMAL is not one beatoraja offers.
    old[4] = version;
    old[71] = @backingInt(options.Gas.best_clear) | @as(u8, @backingInt(gauge.Type.hard)) << floor_shift;
    try std.testing.expectError(error.BadField, decode(arena.allocator(), old));
    const res = try resimulate(gpa, &c, r);
    try std.testing.expect(res.ok);
    try std.testing.expectEqual(@as(u32, 3 * 2 + 1), res.ex_score); // 0,7,14 ms PG; 21 ms at NORMAL=GR
    try std.testing.expectError(error.Truncated, decode(arena.allocator(), bytes[0 .. bytes.len - 1]));
}

test "a failed replay counts the notes it never reached as BP" {
    const parser = @import("../bms/parser.zig");
    const gpa = std.testing.allocator;
    const bar = "0101010101010101010101010101010101010101010101010101010101010101\n";
    var c = try parser.parse(gpa, "#BPM 120\n#WAV01 a.wav\n#00111:" ++ bar ++ "#00211:" ++ bar ++ "#00311:" ++ bar, .{});
    defer c.deinit();
    const res = try resimulate(gpa, &c, .{ .gauge = .hard });
    var judged: u32 = 0;
    for (res.counts) |n| judged += n;
    try std.testing.expect(judged < c.total_notes);
    try std.testing.expectEqual(c.total_notes, res.miss);
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

test "the size limits reject a replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try encode(a, .{});
    _ = try decode(a, good);
    // magic, version, hash, gauge, random, gauge shift, 2P random, algorithm, then a one-byte seed
    const counts = 4 + 1 + 64 + 5 + 1;
    const with = struct {
        fn make(al: std.mem.Allocator, head: []const u8, tail: []const u8) ![]u8 {
            return std.mem.concat(al, u8, &.{ head[0..counts], tail });
        }
    }.make;
    // 4097 random values
    try std.testing.expectError(error.BadField, decode(a, try with(a, good, &.{ 0x81, 0x20 })));
    // no random values, then more events than bytes
    try std.testing.expectError(error.BadField, decode(a, try with(a, good, &.{ 0, 0xFF, 0x7F })));
    // a varint that never ends
    try std.testing.expectError(error.BadVarint, decode(a, try with(a, good, &@as([12]u8, @splat(0xFF)))));
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
    const back = [_]sim_mod.Event{ .{ .time_us = 5, .lane = 0, .down = true }, .{ .time_us = 4, .lane = 0, .down = false } };
    const bad = try encode(gpa, .{ .events = &back });
    defer gpa.free(bad);
    try std.testing.expectError(error.BadField, decode(arena.allocator(), bad));
}
