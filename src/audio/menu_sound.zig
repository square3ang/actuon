//! Menu sound effects and background loop, synthesized at runtime so no audio assets ship.
//! Band-limited supersaws, FM plucks and bells, filtered noise and a stereo reverb.
const std = @import("std");

pub const Sfx = enum { move, adjust, confirm, back, start, clear, fail };

const tau = std.math.tau;

fn midi(n: f32) f32 {
    return 440 * std.math.pow(f32, 2, (n - 69) / 12);
}

fn alloc(al: std.mem.Allocator, frames: usize) ![]f32 {
    const buf = try al.alloc(f32, frames * 2);
    @memset(buf, 0);
    return buf;
}

fn normalize(buf: []f32, level: f32) void {
    var peak: f32 = 0;
    for (buf) |s| peak = @max(peak, @abs(s));
    if (peak > 0) for (buf) |*s| {
        s.* *= level / peak;
    };
}

fn floatOf(i: usize) f32 {
    return @floatFromInt(i);
}

const Rng = struct {
    state: u32 = 0x1234567,
    fn next(r: *Rng) f32 {
        r.state ^= r.state << 13;
        r.state ^= r.state >> 17;
        r.state ^= r.state << 5;
        return @as(f32, @floatFromInt(r.state >> 16)) / 32768 - 1;
    }
};

/// Zero-delay state variable filter.
const Svf = struct {
    ic1: f32 = 0,
    ic2: f32 = 0,
    g: f32 = 0,
    k: f32 = 1,

    fn set(f: *Svf, cutoff: f32, rate: f32, q: f32) void {
        f.g = std.math.tan(std.math.pi * @min(cutoff, rate * 0.45) / rate);
        f.k = 1 / q;
    }

    const Out = struct { low: f32, band: f32, high: f32 };

    fn run(f: *Svf, x: f32) Out {
        const a1 = 1 / (1 + f.g * (f.g + f.k));
        const v1 = a1 * (f.ic1 + f.g * (x - f.ic2));
        const v2 = f.ic2 + f.g * v1;
        f.ic1 = 2 * v1 - f.ic1;
        f.ic2 = 2 * v2 - f.ic2;
        return .{ .low = v2, .band = v1, .high = x - f.k * v1 - v2 };
    }
};

/// Anti-aliased saw: the step is rounded off with a two-sample polynomial.
fn sawBlep(p: f32, dt: f32) f32 {
    var s = 2 * p - 1;
    if (p < dt) {
        const t = p / dt;
        s -= t + t - t * t - 1;
    } else if (p > 1 - dt) {
        const t = (p - 1) / dt;
        s -= t * t + t + t + 1;
    }
    return s;
}

/// Several detuned saws per note, spread across the stereo field and swept through a low pass.
fn superChord(buf: []f32, rate: f32, at: f32, dur: f32, notes: []const f32, amp: f32, cut0: f32, cut1: f32, attack: f32, release: f32, rng: *Rng) void {
    const frames = buf.len / 2;
    const start: usize = @intFromFloat(at * rate);
    const n: usize = @min(@as(usize, @intFromFloat(dur * rate)), frames);
    const detune = [_]f32{ -0.08, -0.03, 0, 0.03, 0.08 };
    const pans = [_]f32{ -0.9, -0.4, 0, 0.4, 0.9 };
    var phase: [8][detune.len]f32 = undefined;
    var dt: [8][detune.len]f32 = undefined;
    for (notes, 0..) |note, a| for (detune, 0..) |d, b| {
        phase[a][b] = (rng.next() + 1) / 2;
        dt[a][b] = midi(note + d) / rate;
    };
    var left: Svf = .{};
    var right: Svf = .{};
    for (0..n) |i| {
        const k = floatOf(i) / floatOf(n);
        if (i % 32 == 0) {
            const cut = cut0 * std.math.pow(f32, cut1 / cut0, k);
            left.set(cut, rate, 1.1);
            right.set(cut, rate, 1.1);
        }
        var l: f32 = 0;
        var r: f32 = 0;
        for (0..notes.len) |a| for (0..detune.len) |b| {
            const p = phase[a][b] + dt[a][b];
            phase[a][b] = if (p >= 1) p - 1 else p;
            const s = sawBlep(phase[a][b], dt[a][b]);
            l += s * (1 - pans[b]);
            r += s * (1 + pans[b]);
        };
        const t = floatOf(i) / rate;
        const env = @min(t / attack, 1) * @min((dur - t) / release, 1);
        const at_frame = (start + i) % frames;
        buf[at_frame * 2] += left.run(l).low * env * amp;
        buf[at_frame * 2 + 1] += right.run(r).low * env * amp;
    }
}

/// Two-operator FM: the modulation dies faster than the tone, so it starts bright and settles glassy.
fn fm(buf: []f32, rate: f32, at: f32, dur: f32, f: f32, ratio: f32, index: f32, amp: f32, pan: f32) void {
    const frames = buf.len / 2;
    const start: usize = @intFromFloat(at * rate);
    const n: usize = @min(@as(usize, @intFromFloat(dur * rate)), frames);
    const left = amp * (1 - pan);
    const right = amp * (1 + pan);
    for (0..n) |i| {
        const t = floatOf(i) / rate;
        const k = floatOf(i) / floatOf(n);
        const mod = @sin(tau * f * ratio * t) * index * @exp(-k * 9);
        const attack = @min(t / 0.001, 1);
        const s = @sin(tau * f * t + mod) * attack * @exp(-k * 4.5) * (1 - k);
        const at_frame = (start + i) % frames;
        buf[at_frame * 2] += s * left;
        buf[at_frame * 2 + 1] += s * right;
    }
}

/// Noise through a band pass swept between two cutoffs.
fn noise(buf: []f32, rate: f32, at: f32, dur: f32, cut0: f32, cut1: f32, q: f32, amp: f32, rise: bool, rng: *Rng) void {
    const frames = buf.len / 2;
    const start: usize = @intFromFloat(at * rate);
    const n: usize = @min(@as(usize, @intFromFloat(dur * rate)), frames);
    var filter: Svf = .{};
    for (0..n) |i| {
        const k = floatOf(i) / floatOf(n);
        if (i % 32 == 0) filter.set(cut0 * std.math.pow(f32, cut1 / cut0, k), rate, q);
        const env = if (rise) k * k * (1 - std.math.pow(f32, k, 24)) else @exp(-k * 6) * (1 - k);
        const s = filter.run(rng.next()).band * env * amp;
        const at_frame = (start + i) % frames;
        buf[at_frame * 2] += s;
        buf[at_frame * 2 + 1] += s;
    }
}

fn kick(buf: []f32, rate: f32, at: f32, amp: f32) void {
    const frames = buf.len / 2;
    const start: usize = @intFromFloat(at * rate);
    const n: usize = @intFromFloat(0.26 * rate);
    var phase: f32 = 0;
    for (0..n) |i| {
        const t = floatOf(i) / rate;
        phase += (48 + 170 * @exp(-t * 38)) / rate;
        const k = floatOf(i) / floatOf(n);
        const s = std.math.tanh(@sin(phase * tau) * 2.2) * @exp(-t * 11) * (1 - k) * amp;
        const at_frame = (start + i) % frames;
        buf[at_frame * 2] += s;
        buf[at_frame * 2 + 1] += s;
    }
}

/// Sine sub with a touch of drive, so it also reads on small speakers.
fn sub(buf: []f32, rate: f32, at: f32, dur: f32, f: f32, amp: f32) void {
    const frames = buf.len / 2;
    const start: usize = @intFromFloat(at * rate);
    const n: usize = @min(@as(usize, @intFromFloat(dur * rate)), frames);
    for (0..n) |i| {
        const t = floatOf(i) / rate;
        const env = @min(t / 0.004, 1) * @min((dur - t) / 0.02, 1);
        const s = std.math.tanh(@sin(tau * f * t) * 1.6) * env * amp;
        const at_frame = (start + i) % frames;
        buf[at_frame * 2] += s;
        buf[at_frame * 2 + 1] += s;
    }
}

/// Ping-pong delay. Two laps let the tails wrap into a loop's start.
fn echo(buf: []f32, delay: usize, feedback: f32) void {
    const frames = buf.len / 2;
    for (0..2) |_| {
        for (0..frames) |i| {
            const from = (i + frames - delay) % frames;
            buf[i * 2] += buf[from * 2 + 1] * feedback;
            buf[i * 2 + 1] += buf[from * 2] * feedback;
        }
    }
}

/// Parallel damped combs into series all-passes, per channel, added onto `out`. The buffers are treated
/// as circular and run for two laps, so a looped sound's tail lands on its own start.
fn reverb(al: std.mem.Allocator, send: []const f32, out: []f32, rate: f32, feedback: f32, level: f32) !void {
    const frames = send.len / 2;
    const scale = rate / 44100;
    const combs = [_]f32{ 1557, 1617, 1491, 1422, 1277, 1356 };
    const passes = [_]f32{ 556, 441, 225 };
    const wet = try al.alloc(f32, frames);
    defer al.free(wet);
    for (0..2) |ch| {
        const stereo: f32 = if (ch == 0) 0 else 23;
        @memset(wet, 0);
        for (combs) |length| {
            const size: usize = @intFromFloat((length + stereo) * scale);
            const line = try al.alloc(f32, size);
            defer al.free(line);
            @memset(line, 0);
            var low: f32 = 0;
            var pos: usize = 0;
            for (0..2) |lap| {
                for (0..frames) |i| {
                    const y = line[pos];
                    low += 0.3 * (y - low);
                    line[pos] = send[i * 2 + ch] * 0.2 + low * feedback;
                    pos = (pos + 1) % size;
                    if (lap == 1) wet[i] += y;
                }
            }
        }
        for (passes) |length| {
            const size: usize = @intFromFloat((length + stereo) * scale);
            const line = try al.alloc(f32, size);
            defer al.free(line);
            @memset(line, 0);
            var pos: usize = 0;
            for (wet) |*w| {
                const y = line[pos];
                line[pos] = w.* + y * 0.5;
                w.* = y - w.* * 0.5;
                pos = (pos + 1) % size;
            }
        }
        for (0..frames) |i| out[i * 2 + ch] += wet[i] * level;
    }
}

fn mixIn(out: []f32, stem: []const f32, level: f32) void {
    for (out, stem) |*o, s| o.* += s * level;
}

fn saturate(buf: []f32, drive: f32) void {
    for (buf) |*s| s.* = std.math.tanh(s.* * drive);
}

pub fn renderSfx(al: std.mem.Allocator, which: Sfx, rate_hz: u32) ![]f32 {
    const rate: f32 = @floatFromInt(rate_hz);
    const seconds: f32 = switch (which) {
        .move, .adjust => 0.14,
        .confirm, .back => 0.6,
        .start, .clear => 2.0,
        .fail => 1.6,
    };
    const frames: usize = @intFromFloat(seconds * rate);
    const buf = try alloc(al, frames);
    errdefer al.free(buf);
    var rng: Rng = .{};
    switch (which) {
        // A short glassy tick with an air transient on top.
        .move => {
            fm(buf, rate, 0, 0.05, 2093, 3, 1.6, 0.3, 0);
            noise(buf, rate, 0, 0.012, 7000, 5000, 1.2, 0.5, false, &rng);
        },
        .adjust => {
            fm(buf, rate, 0, 0.05, 1046.5, 2, 1.2, 0.34, 0);
            noise(buf, rate, 0, 0.01, 3500, 2500, 1.2, 0.4, false, &rng);
        },
        .confirm => {
            fm(buf, rate, 0, 0.22, 1318.5, 3, 2.2, 0.26, -0.25);
            fm(buf, rate, 0.075, 0.34, 1975.5, 3, 2.2, 0.26, 0.25);
            noise(buf, rate, 0, 0.02, 8000, 5000, 1.2, 0.3, false, &rng);
        },
        .back => {
            fm(buf, rate, 0, 0.16, 1318.5, 2, 1.6, 0.24, 0.25);
            fm(buf, rate, 0.07, 0.26, 880, 2, 1.6, 0.24, -0.25);
        },
        // Riser into a wide chord with a sub and a kick under the hit.
        .start => {
            noise(buf, rate, 0, 0.42, 600, 9000, 1.6, 0.9, true, &rng);
            const hit = 0.4;
            superChord(buf, rate, hit, 1.2, &.{ 57, 64, 69, 72, 76 }, 0.035, 9000, 900, 0.004, 0.5, &rng);
            fm(buf, rate, hit, 1.0, 1760, 3, 3, 0.2, 0);
            kick(buf, rate, hit, 0.5);
            sub(buf, rate, hit, 0.5, 55, 0.3);
        },
        .clear => {
            for ([_]f32{ 76, 79, 84, 88, 91 }, 0..) |note, i| {
                fm(buf, rate, floatOf(i) * 0.085, 0.7, midi(note), 3, 2.4, 0.2, (floatOf(i) - 2) * 0.2);
            }
            superChord(buf, rate, 0.34, 1.2, &.{ 60, 67, 72, 76, 79 }, 0.03, 700, 6000, 0.05, 0.7, &rng);
            sub(buf, rate, 0.34, 0.6, 65.4, 0.25);
        },
        // Falling filter over a detuned minor chord.
        .fail => {
            superChord(buf, rate, 0, 1.1, &.{ 45, 48, 52, 57 }, 0.05, 3500, 180, 0.005, 0.5, &rng);
            sub(buf, rate, 0, 0.5, 55, 0.3);
            noise(buf, rate, 0, 0.7, 4000, 200, 1.4, 0.5, false, &rng);
        },
    }
    const dry = try al.dupe(f32, buf);
    defer al.free(dry);
    const space: f32 = switch (which) {
        .move, .adjust => 0.05,
        .confirm, .back => 0.18,
        else => 0.3,
    };
    try reverb(al, dry, buf, rate, 0.8, space);
    saturate(buf, 1.2);
    normalize(buf, 0.8);
    return buf;
}

const bpm = 126;
const beats = 64;

// Plain open triads: anything richer rubs once it is detuned and sustained under a reverb.
const chords = [4][4]f32{ .{ 57, 64, 69, 72 }, .{ 53, 60, 65, 69 }, .{ 55, 60, 64, 67 }, .{ 55, 62, 67, 71 } };
const chord_beats = 8;

// Lead over the second half, in beats; zero is a rest. Every note is a tone of the chord under it.
const lead = [_]f32{
    76, 0, 72, 0, 0, 69, 0, 72,
    72, 0, 0,  69, 0, 65, 0, 0,
    79, 0, 76, 0, 0, 72, 0, 76,
    74, 0, 0,  71, 0, 67, 0, 0,
};

/// Sixteen bars of melodic house in A minor (Am F C G). The frame count is a whole number of
/// beats and every voice wraps, so the buffer loops without a seam. The first half keeps the filter
/// closed and the drums thin; the second half opens up.
pub fn renderBgm(al: std.mem.Allocator, rate_hz: u32) ![]f32 {
    const rate: f32 = @floatFromInt(rate_hz);
    const spb: usize = rate_hz * 60 / bpm;
    const beat_s = floatOf(spb) / rate;
    const step_s = beat_s / 4;
    const frames = spb * beats;
    const out = try alloc(al, frames);
    errdefer al.free(out);
    const duck_bus = try alloc(al, frames);
    defer al.free(duck_bus);
    const send = try alloc(al, frames);
    defer al.free(send);
    var rng: Rng = .{};

    const roots = [4]f32{ 33, 29, 36, 31 };
    // Syncopated stabs, in sixteenths across each two-bar chord: start and length.
    const stabs = [_][2]u8{ .{ 0, 3 }, .{ 3, 3 }, .{ 6, 4 }, .{ 10, 3 }, .{ 13, 3 }, .{ 16, 3 }, .{ 19, 3 }, .{ 22, 4 }, .{ 26, 2 }, .{ 28, 4 } };
    const arp = [_]u8{ 0, 2, 3, 1, 2, 3, 0, 2, 1, 3, 2, 0, 3, 1, 2, 3 };
    const slots = beats / chord_beats;
    for (0..slots) |slot| {
        const chord = chords[slot % 4];
        const root = roots[slot % 4];
        const at = floatOf(slot * chord_beats) * beat_s;
        const open = slot >= slots / 2;
        const progress = floatOf(slot) / floatOf(slots / 2);

        // A quiet held layer under everything.
        superChord(duck_bus, rate, at, chord_beats * beat_s, &chord, 0.012, 700, 900, 0.3, 0.3, &rng);
        for (stabs) |st| {
            const t = at + floatOf(st[0]) * step_s;
            const len = floatOf(st[1]) * step_s * 0.92;
            const cut: f32 = if (open) 5200 else 700 + progress * 1800;
            superChord(duck_bus, rate, t, len, &chord, 0.018, cut, cut * 0.45, 0.003, 0.03, &rng);
            sub(out, rate, t, len, midi(root), 0.26);
        }
        for (0..chord_beats * 4) |step| {
            const p = arp[step % arp.len];
            const note = chord[p] + 24;
            const pan: f32 = if (step % 2 == 0) -0.4 else 0.4;
            fm(send, rate, at + floatOf(step) * step_s, 0.2, midi(note), 2, 1.2, if (open) 0.06 else 0.045, pan);
        }
    }

    for (lead, 0..) |note, i| {
        if (note == 0) continue;
        const t = floatOf(beats / 2 + i) * beat_s;
        fm(send, rate, t, beat_s * 1.6, midi(note + 12), 3, 2.6, 0.14, 0);
    }
    echo(send, spb * 3 / 4, 0.22);

    // Drums.
    for (0..beats) |b| {
        const t = floatOf(b) * beat_s;
        const full = b >= beats / 2;
        // The kick drops out for the first bars of the quiet half.
        if (b >= 16) kick(out, rate, t, 0.62);
        noise(out, rate, t + beat_s / 2, 0.09, 9000, 7500, 1.5, if (full) 0.2 else 0.12, false, &rng);
        if (full) {
            noise(out, rate, t + beat_s / 4, 0.03, 10000, 9000, 1.5, 0.09, false, &rng);
            noise(out, rate, t + beat_s * 3 / 4, 0.03, 10000, 9000, 1.5, 0.09, false, &rng);
        }
        if (b % 2 == 1) {
            const level: f32 = if (full) 0.5 else 0.2;
            noise(out, rate, t, 0.16, 2200, 1500, 1.1, level, false, &rng);
            noise(send, rate, t, 0.16, 2200, 1500, 1.1, level * 0.3, false, &rng);
        }
    }

    // Harmony pumps under the kick.
    for (0..frames) |i| {
        const in_beat = floatOf(i % spb) / floatOf(spb);
        const pump = 1 - 0.5 * @exp(-in_beat * 10);
        for (0..2) |ch| duck_bus[i * 2 + ch] *= pump;
    }
    mixIn(out, duck_bus, 1);
    mixIn(out, send, 1);
    mixIn(send, duck_bus, 0.5);
    try reverb(al, send, out, rate, 0.84, 0.35);
    // Well under the effects, which must stay audible over it.
    normalize(out, 0.5);
    return out;
}

test "sounds are audible and do not clip" {
    const al = std.testing.allocator;
    for (std.enums.values(Sfx)) |which| {
        const buf = try renderSfx(al, which, 8000);
        defer al.free(buf);
        var peak: f32 = 0;
        for (buf) |s| peak = @max(peak, @abs(s));
        try std.testing.expect(peak > 0.7 and peak < 0.9);
    }
    const bgm = try renderBgm(al, 8000);
    defer al.free(bgm);
    try std.testing.expectEqual(@as(usize, 8000 * 60 / bpm * beats * 2), bgm.len);
    var peak: f32 = 0;
    for (bgm) |s| peak = @max(peak, @abs(s));
    try std.testing.expect(peak > 0.45 and peak <= 0.51);
}

test "every lead note is a tone of the chord under it" {
    for (lead, 0..) |note, i| {
        if (note == 0) continue;
        const chord = chords[i / chord_beats % chords.len];
        var found = false;
        for (chord) |tone| found = found or @mod(tone - note, 12) == 0;
        try std.testing.expect(found);
    }
}

test "band-limited saw stays bounded at high pitch" {
    var p: f32 = 0;
    const dt = 0.2;
    for (0..100) |_| {
        p += dt;
        if (p >= 1) p -= 1;
        try std.testing.expect(@abs(sawBlep(p, dt)) < 2.1);
    }
}
