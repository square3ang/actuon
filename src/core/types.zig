//! Shared chart model. Pure data: no I/O, usable from client, replay verifier and tools.
const std = @import("std");

pub const max_lanes = 18;

pub const Mode = enum(u8) {
    beat5 = 0,
    beat7 = 1,
    beat10 = 2,
    beat14 = 3,
    popn9 = 4,
    /// Qwilight's modes, set by a #4K or #6K header. beatoraja has neither.
    beat4 = 5,
    beat6 = 6,

    pub fn keys(m: Mode) u8 {
        return switch (m) {
            .beat5 => 6,
            .beat7 => 8,
            .beat10 => 12,
            .beat14 => 16,
            .popn9 => 9,
            .beat4 => 4,
            .beat6 => 6,
        };
    }
    pub fn players(m: Mode) u8 {
        return if (m == .beat10 or m == .beat14) 2 else 1;
    }
    /// Scratch index of a lane, or -1 when the lane is a plain key.
    pub fn scratchOf(m: Mode, lane: u8) i8 {
        return switch (m) {
            .beat5 => if (lane == 5) 0 else -1,
            .beat7 => if (lane == 7) 0 else -1,
            .beat10 => if (lane == 5) 0 else if (lane == 11) 1 else -1,
            .beat14 => if (lane == 7) 0 else if (lane == 15) 1 else -1,
            .popn9, .beat4, .beat6 => -1,
        };
    }
};

pub const NoteKind = enum(u8) { normal, ln_start, ln_end, mine };
pub const LnType = enum(u8) { ln = 1, cn = 2, hcn = 3 };

pub const Note = struct {
    time_us: i64,
    /// Scroll position: measures, weighted by #SCROLL.
    y: f64,
    wav: i32,
    /// Index of the paired LN end/start in `Chart.notes`, or -1.
    pair: i32 = -1,
    lane: u8,
    kind: NoteKind,
    ln_type: LnType = .ln,
    /// The chart leaves this LN's type open, so the player's LN mode decides it.
    ln_open: bool = false,
    damage: f32 = 0,
    wav_start_us: i64 = 0,
    wav_dur_us: i64 = 0,
};

pub const Hidden = struct { time_us: i64, wav: i32, lane: u8 };
pub const BgSound = struct { time_us: i64, wav: i32, wav_start_us: i64 = 0, wav_dur_us: i64 = 0 };
pub const BgaLayer = enum(u8) { base, layer, poor };
pub const BgaEvent = struct { time_us: i64, id: i32, layer: BgaLayer };

/// One point on the tempo map; between points y and time advance linearly (after `stop_us`).
pub const Timeline = struct {
    time_us: i64,
    y: f64,
    section: f64,
    bpm: f64,
    stop_us: i64,
    scroll: f64,
    speed: f64,
    bar: bool,
};

pub const Chart = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8 = "",
    subtitle: []const u8 = "",
    artist: []const u8 = "",
    subartist: []const u8 = "",
    genre: []const u8 = "",
    stagefile: []const u8 = "",
    backbmp: []const u8 = "",
    banner: []const u8 = "",
    preview: []const u8 = "",
    playlevel: []const u8 = "",
    difficulty: i32 = 0,
    /// Percent scale after BMSPlayerRule.validate (LR2 rule: RANK 0..3 = 25,50,75,100).
    judgerank: i32 = 75,
    total: f64 = 0,
    total_defined: bool = false,
    bpm: f64 = 0,
    min_bpm: f64 = 0,
    max_bpm: f64 = 0,
    mode: Mode = .beat5,
    is_pms: bool = false,
    wavs: []const []const u8 = &.{},
    bmps: []const []const u8 = &.{},
    notes: []Note = &.{},
    hidden: []Hidden = &.{},
    bg: []BgSound = &.{},
    bga: []BgaEvent = &.{},
    timelines: []Timeline = &.{},
    random: []const i32 = &.{},
    total_notes: u32 = 0,
    last_time_us: i64 = 0,
    last_note_us: i64 = 0,
    has_ln: bool = false,
    has_mine: bool = false,
    has_random: bool = false,
    has_stop: bool = false,
    md5: [32]u8 = @splat('0'),
    sha256: [64]u8 = @splat('0'),

    pub fn deinit(c: *Chart) void {
        c.arena.deinit();
    }

    /// The last timeline at or before `t`, else the first. There must be at least one.
    fn timelineAt(c: *const Chart, t: i64) usize {
        const tl = c.timelines;
        var lo: usize = 0;
        var hi: usize = tl.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (tl[mid].time_us <= t) lo = mid else hi = mid;
        }
        return lo;
    }

    /// Scroll position for a chart time (render only).
    pub fn yAt(c: *const Chart, t: i64) f64 {
        const tl = c.timelines;
        if (tl.len == 0) return 0;
        const lo = c.timelineAt(t);
        const a = tl[lo];
        if (t < a.time_us) return a.y;
        const moving = t - a.time_us - a.stop_us;
        if (moving <= 0) return a.y;
        const measures = @as(f64, @floatFromInt(moving)) * a.bpm / 240_000_000.0;
        return a.y + measures * a.scroll;
    }

    /// #SPEED lane scale (render only): eases towards the next point, holding through a stop.
    pub fn speedAt(c: *const Chart, t: i64) f64 {
        const tl = c.timelines;
        if (tl.len == 0) return 1;
        const lo = c.timelineAt(t);
        const a = tl[lo];
        const start = a.time_us + a.stop_us;
        if (lo + 1 >= tl.len or t <= start) return a.speed;
        const b = tl[lo + 1];
        if (b.time_us <= start) return a.speed;
        const k = @as(f64, @floatFromInt(t - start)) / @as(f64, @floatFromInt(b.time_us - start));
        return a.speed + (b.speed - a.speed) * k;
    }

    pub fn bpmAt(c: *const Chart, t: i64) f64 {
        const tl = c.timelines;
        if (tl.len == 0 or tl[0].time_us > t) return c.bpm;
        const lo = c.timelineAt(t);
        return tl[lo].bpm;
    }
};

/// Same rule as BMSPlayerRule.calculateDefaultTotal.
pub fn defaultTotal(notes: u32) f64 {
    const n: f64 = @floatFromInt(notes);
    return 160.0 + (n + @min(@max(n - 400.0, 0.0), 200.0)) * 0.16;
}

pub const Judge = enum(u8) { pg = 0, gr = 1, gd = 2, bd = 3, pr = 4, ms = 5 };

pub const Clear = enum(u8) {
    no_play = 0,
    failed = 1,
    assist_easy = 2,
    light_assist_easy = 3,
    easy = 4,
    normal = 5,
    hard = 6,
    exhard = 7,
    full_combo = 8,
    perfect = 9,
    max = 10,
};

test "speed eases between points and holds through a stop" {
    const base: Timeline = .{ .time_us = 0, .y = 0, .section = 0, .bpm = 120, .stop_us = 0, .scroll = 1, .speed = 1, .bar = false };
    var tl = [_]Timeline{ base, base, base };
    tl[0].stop_us = 1000;
    tl[1].time_us = 3000;
    tl[1].speed = 3;
    tl[2].time_us = 4000;
    tl[2].speed = 3;
    const c: Chart = .{ .arena = undefined, .timelines = &tl };
    try std.testing.expectEqual(@as(f64, 1), c.speedAt(500));
    try std.testing.expectEqual(@as(f64, 2), c.speedAt(2000));
    try std.testing.expectEqual(@as(f64, 3), c.speedAt(9000));
}
