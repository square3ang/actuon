//! Clock-free judge sim on a 1 ms grid, a port of lr2oraja-endlessdream's JudgeManager (GPLv3) under the LR2 rule.
const std = @import("std");
const types = @import("types.zig");
const windows = @import("windows.zig");
const gauge_mod = @import("gauge.zig");
const options = @import("options.zig");
const Note = types.Note;

pub const Event = struct {
    time_us: i64,
    lane: u8,
    /// 0 or 1: the two directions of a scratch lane; plain keys always use 0.
    key: u8 = 0,
    down: bool,
};

pub const OutKind = enum(u8) { judge, sound, stop_sound, press_empty, hold_start, hold_end };
pub const Out = struct {
    kind: OutKind,
    lane: u8 = 0,
    judge: u8 = 0,
    wav: i32 = -1,
    note: i32 = -1,
    fast_us: i32 = 0,
    combo: u32 = 0,
};

pub const Score = struct {
    /// [judge][0 = early, 1 = late]
    counts: [6][2]u32 = @splat(.{ 0, 0 }),
    max_combo: u32 = 0,
    combo: u32 = 0,
    passed: u32 = 0,

    pub fn count(s: *const Score, j: types.Judge) u32 {
        const c = s.counts[@backingInt(j)];
        return c[0] + c[1];
    }
    pub fn exScore(s: *const Score) u32 {
        return s.count(.pg) * 2 + s.count(.gr);
    }
    pub fn missCount(s: *const Score) u32 {
        return s.count(.bd) + s.count(.pr) + s.count(.ms);
    }
    /// A failed play stops judging, so the notes it never reached count as BP too, as beatoraja does.
    pub fn bp(s: *const Score, total_notes: u32) u32 {
        return s.missCount() + (total_notes -| s.passed);
    }
};

const LaneState = struct {
    processing: i32 = -1,
    passing: i32 = -1,
    increase: bool = false,
    passing_count: i64 = 0,
    release_time: i64 = no_time,
    ln_end_judge: i32 = -1,
    ln_start_judge: u8 = 0,
    ln_start_dur: i64 = 0,
    down: [2]bool = .{ false, false },
    pass_cursor: u32 = 0,
    mark: u32 = 0,
    last_sound_wav: i32 = -1,
    scratch: i8 = -1,
};

const no_time = std.math.minInt(i64);
const hcn_duration: i64 = 200_000;
const ring_size = 1024;

pub const Config = struct {
    gauge: gauge_mod.Type = .normal,
    autoplay: bool = false,
    /// Under select to under, `gauge` is the top gauge.
    gas: options.Gas = .none,
    gas_floor: gauge_mod.Type = .assist_easy,
    algorithm: options.Algorithm = .combo,
    /// beatoraja's EXPAND JUDGE assist: GREAT reaches as far as GOOD did, PGREAT as far as GREAT.
    expand_judge: bool = false,
    auto_scratch: bool = false,
};

fn gasTop(cfg: Config) gauge_mod.Type {
    if (cfg.gas != .best_clear) return cfg.gauge;
    return @fromBackingInt(@max(@backingInt(cfg.gauge), @backingInt(gauge_mod.Type.exhard)));
}

pub const Sim = struct {
    notes: []const Note,
    /// 0 = unjudged, else judge + 1. Only the sim's thread touches it; render draws from a copy taken under a lock.
    state: []u8,
    lane_notes: [types.max_lanes][]u32,
    lanes: [types.max_lanes]LaneState = @splat(.{}),
    lane_count: u8,
    sckey: [2]u8 = .{ 0, 0 },
    judge_w: [5]windows.Window,
    end_w: [4]windows.Window,
    judge_start: i64,
    judge_end: i64,
    prev_t: i64 = -1,
    grid_t: i64 = 0,
    gauges: [gauge_mod.count]gauge_mod.Gauge,
    gauge_type: gauge_mod.Type,
    gas: options.Gas,
    gas_top: gauge_mod.Type,
    gas_floor: gauge_mod.Type,
    algorithm: options.Algorithm,
    score: Score = .{},
    autoplay: bool,
    auto_scratch: bool,
    failed: bool = false,
    total_notes: u32,
    ring: [ring_size]Out = undefined,
    ring_head: std.atomic.Value(u32) = .init(0),
    ring_tail: std.atomic.Value(u32) = .init(0),
    gpa: std.mem.Allocator,

    pub fn create(gpa: std.mem.Allocator, chart: *const types.Chart, cfg: Config) !*Sim {
        const s = try gpa.create(Sim);
        errdefer gpa.destroy(s);
        const state = try gpa.alloc(u8, chart.notes.len);
        errdefer gpa.free(state);
        @memset(state, 0);
        const keys = chart.mode.keys();
        s.* = .{
            .notes = chart.notes,
            .state = state,
            .lane_notes = @splat(&.{}),
            .lane_count = keys,
            .judge_w = windows.create(5, windows.note_base, chart.judgerank),
            .end_w = windows.create(4, windows.ln_end_base, chart.judgerank),
            .judge_start = 0,
            .judge_end = 0,
            .gauges = undefined,
            .gauge_type = if (cfg.gas == .best_clear) gasTop(cfg) else cfg.gauge,
            .gas = cfg.gas,
            .gas_top = gasTop(cfg),
            .gas_floor = cfg.gas_floor,
            .algorithm = cfg.algorithm,
            .autoplay = cfg.autoplay,
            .auto_scratch = cfg.auto_scratch,
            .total_notes = chart.total_notes,
            .gpa = gpa,
        };
        if (cfg.expand_judge) {
            s.judge_w[0] = s.judge_w[1];
            s.judge_w[1] = s.judge_w[2];
        }
        for (s.judge_w) |w| {
            s.judge_start = @min(s.judge_start, w[0]);
            s.judge_end = @max(s.judge_end, w[1]);
        }
        for (0..gauge_mod.count) |i| s.gauges[i] = gauge_mod.init(@fromBackingInt(@intCast(i)), chart.total, chart.total_notes);
        var counts: [types.max_lanes]u32 = @splat(0);
        for (chart.notes) |n| counts[n.lane] += 1;
        errdefer for (s.lane_notes) |l| gpa.free(l);
        for (0..keys) |l| s.lane_notes[l] = try gpa.alloc(u32, counts[l]);
        @memset(&counts, 0);
        for (chart.notes, 0..) |n, i| {
            s.lane_notes[n.lane][counts[n.lane]] = @intCast(i);
            counts[n.lane] += 1;
        }
        for (0..keys) |l| s.lanes[l].scratch = chart.mode.scratchOf(@intCast(l));
        return s;
    }

    pub fn destroy(s: *Sim) void {
        for (s.lane_notes) |l| if (l.len > 0) s.gpa.free(l);
        s.gpa.free(s.state);
        s.gpa.destroy(s);
    }

    pub fn gauge(s: *const Sim) *const gauge_mod.Gauge {
        return &s.gauges[@backingInt(s.gauge_type)];
    }

    pub fn drain(s: *Sim, out: []Out) usize {
        var n: usize = 0;
        var t = s.ring_tail.load(.monotonic);
        const h = s.ring_head.load(.acquire);
        while (t != h and n < out.len) : (t +%= 1) {
            out[n] = s.ring[t % ring_size];
            n += 1;
        }
        s.ring_tail.store(t, .release);
        return n;
    }

    fn emit(s: *Sim, o: Out) void {
        const h = s.ring_head.load(.monotonic);
        if (h -% s.ring_tail.load(.acquire) >= ring_size) return; // replay verify never drains
        s.ring[h % ring_size] = o;
        s.ring_head.store(h +% 1, .release);
    }

    fn sound(s: *Sim, idx: i32) void {
        const n = s.notes[@intCast(idx)];
        if (n.wav >= 0) s.emit(.{ .kind = .sound, .lane = n.lane, .wav = n.wav, .note = idx });
    }

    fn pressed(ls: *const LaneState) bool {
        return ls.down[0] or ls.down[1];
    }

    fn shiftGauge(s: *Sim) void {
        var alive: ?usize = null;
        var i: usize = @backingInt(s.gas_top) + 1;
        const floor: usize = @min(@backingInt(s.gas_floor), @backingInt(s.gas_top));
        while (i > floor) {
            i -= 1;
            if (s.gauges[i].qualified()) {
                s.gauge_type = @fromBackingInt(@intCast(i));
                return;
            }
            if (alive == null and s.gauges[i].value > 0) alive = i;
        }
        if (alive) |a| s.gauge_type = @fromBackingInt(@intCast(a));
    }

    fn checkFailed(s: *Sim) void {
        switch (s.gas) {
            .none, .continue_play => {},
            .select_to_under, .best_clear => s.shiftGauge(),
            // A survival gauge that empties hands over to the groove gauge, which has run alongside it.
            .survival_to_groove => if (s.gauge().value == 0 and @backingInt(s.gauge_type) >= @backingInt(gauge_mod.Type.hard)) {
                s.gauge_type = .normal;
            },
        }
        // Under continue the chart plays on; the empty gauge still fails the clear.
        if (s.gauge().value == 0 and s.gas != .continue_play) s.failed = true;
    }

    /// Steps the absolute 1 ms grid, so call cadence cannot change the outcome.
    pub fn advance(s: *Sim, t: i64) void {
        while (s.grid_t + 1000 <= t and !s.failed) {
            s.grid_t += 1000;
            s.step(s.grid_t);
        }
    }

    /// Events must come in time order; late ones are clamped forward so a replay sees the same sequence.
    pub fn input(s: *Sim, ev: Event) void {
        s.advance(ev.time_us);
        if (s.failed or ev.lane >= s.lane_count) return;
        const key: u1 = @intCast(ev.key & 1);
        const ls = &s.lanes[ev.lane];
        if (ls.down[key] == ev.down or (s.auto_scratch and ls.scratch >= 0)) return;
        ls.down[key] = ev.down;
        // The lead-in is beatoraja's READY, which judges nothing: a key there only lights its lane.
        if (ev.time_us < 0) {
            if (ev.down) s.emit(.{ .kind = .press_empty, .lane = ev.lane });
            return;
        }
        if (ev.down) s.onPress(ev.lane, key, ev.time_us) else s.onRelease(ev.lane, key, ev.time_us);
        s.endPhase(ev.time_us);
        s.checkFailed();
    }

    fn step(s: *Sim, t: i64) void {
        for (0..s.lane_count) |l| s.passPhase(@intCast(l), t);
        s.hcnPhase(t);
        s.prev_t = t;
        s.endPhase(t);
        s.checkFailed();
    }

    fn passPhase(s: *Sim, lane: u8, t: i64) void {
        const ls = &s.lanes[lane];
        const list = s.lane_notes[lane];
        const down = pressed(ls);
        while (ls.pass_cursor < list.len) : (ls.pass_cursor += 1) {
            const idx = list[ls.pass_cursor];
            const n = s.notes[idx];
            if (n.time_us > t) break;
            switch (n.kind) {
                .ln_start, .ln_end => {
                    if (n.ln_type == .hcn) {
                        if (n.kind == .ln_end) {
                            ls.passing = -1;
                            ls.passing_count = 0;
                        } else ls.passing = @intCast(idx);
                    }
                },
                .mine => if (down) {
                    for (&s.gauges) |*g| g.set(g.value - n.damage);
                    s.sound(@intCast(idx));
                },
                .normal => {},
            }
            if (s.autoLane(ls)) s.autoNote(lane, idx);
        }
        ls.increase = ls.passing >= 0 and (down or s.autoLane(ls) or endHeld(s, ls));
    }

    fn autoLane(s: *const Sim, ls: *const LaneState) bool {
        return s.autoplay or (s.auto_scratch and ls.scratch >= 0);
    }

    fn endHeld(s: *const Sim, ls: *const LaneState) bool {
        const pair = s.notes[@intCast(ls.passing)].pair;
        if (pair < 0) return false;
        const st = s.state[@intCast(pair)];
        return st > 0 and st <= 3;
    }

    fn autoNote(s: *Sim, lane: u8, idx: u32) void {
        const n = s.notes[idx];
        const ls = &s.lanes[lane];
        switch (n.kind) {
            .normal => if (s.state[idx] == 0) {
                s.sound(@intCast(idx));
                s.judgeNote(lane, @intCast(idx), 0, 0, true);
                s.emit(.{ .kind = .press_empty, .lane = lane });
            },
            .ln_start => if (s.state[idx] == 0 and ls.processing < 0) {
                s.sound(@intCast(idx));
                if (n.ln_type == .ln) {
                    ls.ln_start_judge = 0;
                    ls.ln_start_dur = 0;
                } else s.judgeNote(lane, @intCast(idx), 0, 0, true);
                ls.processing = n.pair;
                s.emit(.{ .kind = .hold_start, .lane = lane });
            },
            .ln_end => if (s.state[idx] == 0 and n.ln_type != .ln) {
                s.judgeNote(lane, @intCast(idx), 0, 0, true);
                ls.processing = -1;
                s.emit(.{ .kind = .hold_end, .lane = lane });
            },
            .mine => {},
        }
    }

    fn hcnPhase(s: *Sim, t: i64) void {
        const dt = t - s.prev_t;
        for (0..s.lane_count) |l| {
            const ls = &s.lanes[l];
            if (ls.passing < 0 or s.state[@intCast(ls.passing)] == 0) continue;
            if (ls.increase) {
                ls.passing_count += dt;
                if (ls.passing_count > hcn_duration) {
                    for (&s.gauges) |*g| g.update(1, 0.5);
                    ls.passing_count -= hcn_duration;
                }
            } else {
                ls.passing_count -= dt;
                if (ls.passing_count < -hcn_duration) {
                    for (&s.gauges) |*g| g.update(3, 0.5);
                    ls.passing_count += hcn_duration;
                }
            }
        }
    }

    fn windowJudge(w: []const windows.Window, dm: i64) u8 {
        var j: u8 = 0;
        while (j < w.len and !(dm >= w[j][0] and dm <= w[j][1])) j += 1;
        return j;
    }

    fn onPress(s: *Sim, lane: u8, key: u1, pt: i64) void {
        const ls = &s.lanes[lane];
        const sc = ls.scratch;
        if (ls.processing >= 0) {
            const proc = s.notes[@intCast(ls.processing)];
            if (proc.ln_type != .ln and sc >= 0 and s.sckey[@intCast(sc)] != @as(u8, key) + 1) {
                // BSS: the other direction ends a charge note
                const dm = proc.time_us - pt;
                const j = windowJudge(&s.end_w, dm);
                s.sound(ls.processing);
                s.judgeNote(lane, ls.processing, j, dm, true);
                ls.processing = -1;
                ls.release_time = no_time;
                ls.ln_end_judge = -1;
                s.sckey[@intCast(sc)] = 0;
            } else {
                ls.release_time = no_time;
            }
            return;
        }

        const w = &s.judge_w;
        var tnote: i32 = -1;
        var judge: u8 = 0;
        var bad_notes: [64]i32 = undefined;
        var bad_times: [64]i64 = undefined;
        var bad_len: usize = 0;

        s.moveMark(lane);
        const list = s.lane_notes[lane];
        var i: usize = ls.mark;
        while (i < list.len) : (i += 1) {
            const idx: i32 = @intCast(list[i]);
            const n = s.notes[@intCast(idx)];
            const dm = n.time_us - pt;
            if (dm >= s.judge_end) break;
            if (dm < s.judge_start) continue;
            if (n.kind == .mine or n.kind == .ln_end) continue;
            const st = s.state[@intCast(idx)];
            if (st == 0 and bad_len < bad_notes.len) {
                bad_notes[bad_len] = idx;
                bad_times[bad_len] = dm;
                bad_len += 1;
            }
            const better = tnote < 0 or s.state[@intCast(tnote)] != 0 or (st == 0 and switch (s.algorithm) {
                .combo => s.notes[@intCast(tnote)].time_us < pt + w[2][0] and n.time_us <= pt + w[2][1],
                .duration => @abs(s.notes[@intCast(tnote)].time_us - pt) > @abs(n.time_us - pt),
                .lowest => false,
            });
            if (!better) continue;
            if (st != 0) {
                judge = if (dm >= w[4][0] and dm <= w[4][1]) 5 else 6;
            } else if (n.kind == .ln_start and dm < w[2][0]) {
                judge = 6; // lr2oraja-endlessdream: no late BAD on LN heads
            } else {
                const j = windowJudge(w, dm);
                judge = if (j >= 4) j + 1 else j;
            }
            if (judge < 6) {
                if (judge < 4 or tnote < 0 or
                    @abs(s.notes[@intCast(tnote)].time_us - pt) > @abs(n.time_us - pt))
                {
                    tnote = idx;
                }
            } else {
                tnote = -1;
            }
        }

        if (tnote >= 0) {
            const tn = s.notes[@intCast(tnote)];
            const tdm = tn.time_us - pt;
            s.multiBad(lane, tnote, tdm, bad_notes[0..bad_len], bad_times[0..bad_len]);
            const vanish = judge != 5;
            if (tn.kind == .ln_start) {
                s.sound(tnote);
                if (tn.ln_type == .ln) {
                    if (vanish) {
                        ls.ln_start_judge = judge;
                        ls.ln_start_dur = tdm;
                        ls.processing = tn.pair;
                        ls.release_time = no_time;
                        ls.ln_end_judge = -1;
                        if (sc >= 0) s.sckey[@intCast(sc)] = @as(u8, key) + 1;
                        s.emit(.{ .kind = .hold_start, .lane = lane });
                    } else s.judgeNote(lane, tnote, judge, tdm, false);
                } else {
                    if (vanish) {
                        ls.processing = tn.pair;
                        ls.release_time = no_time;
                        ls.ln_end_judge = -1;
                        if (sc >= 0) s.sckey[@intCast(sc)] = @as(u8, key) + 1;
                        s.emit(.{ .kind = .hold_start, .lane = lane });
                    }
                    s.judgeNote(lane, tnote, judge, tdm, vanish);
                }
            } else {
                s.sound(tnote);
                s.judgeNote(lane, tnote, judge, tdm, vanish);
            }
        } else {
            var n_idx: i32 = if (list.len > 0) @intCast(list[0]) else -1;
            for (list) |li| {
                const n = s.notes[li];
                if (n.time_us >= pt) break;
                if (!(n.kind == .ln_start and s.state[li] != 0) and n.kind != .ln_end) n_idx = @intCast(li);
            }
            if (n_idx >= 0 and ls.passing < 0 and s.notes[@intCast(n_idx)].kind != .mine) s.sound(n_idx);
            s.emit(.{ .kind = .press_empty, .lane = lane });
        }
    }

    /// Port of JudgeManager.MultiBadCollector.filter.
    fn multiBad(s: *Sim, lane: u8, tnote: i32, tdm: i64, notes: []i32, times: []i64) void {
        const w = &s.judge_w;
        var size: usize = 0;
        for (notes, times) |n, t| {
            if (t < w[3][0] or t > w[3][1]) continue;
            if (t >= w[2][0] and t <= w[2][1]) continue;
            if (n == tnote) continue;
            notes[size] = n;
            times[size] = t;
            size += 1;
        }
        var i: usize = 1;
        while (i < size) : (i += 1) {
            var j = i;
            while (j > 0 and times[j - 1] > times[j]) : (j -= 1) {
                std.mem.swap(i32, &notes[j], &notes[j - 1]);
                std.mem.swap(i64, &times[j], &times[j - 1]);
            }
        }
        const t_is_ln = s.notes[@intCast(tnote)].kind == .ln_start;
        const t_bad = (w[3][0] <= tdm and tdm < w[2][0]) or (w[2][1] < tdm and tdm <= w[3][1]);
        if (!t_bad or t_is_ln) {
            for (0..size) |k| {
                if (times[k] >= tdm) {
                    size = k;
                    break;
                }
            }
        }
        var start = size;
        for (0..size) |k| {
            if (times[k] >= tdm or s.notes[@intCast(notes[k])].kind != .ln_start) {
                start = k;
                break;
            }
        }
        for (start..size) |k| s.judgeNote(lane, notes[k], 3, times[k], true);
    }

    fn onRelease(s: *Sim, lane: u8, key: u1, pt: i64) void {
        const ls = &s.lanes[lane];
        if (ls.processing < 0) return;
        const sc = ls.scratch;
        const proc = s.notes[@intCast(ls.processing)];
        var dm = proc.time_us - pt;
        var j = windowJudge(&s.end_w, dm);
        if (proc.ln_type != .ln) {
            var release = true;
            if (sc >= 0) {
                if (j != 4 or s.sckey[@intCast(sc)] != @as(u8, key) + 1) release = false else s.sckey[@intCast(sc)] = 0;
            }
            if (!release) return;
            if (j >= 3 and dm > 0) {
                ls.release_time = pt;
                ls.ln_end_judge = j;
            } else {
                s.judgeNote(lane, ls.processing, j, dm, true);
                s.endHold(lane);
            }
        } else {
            if (sc >= 0) {
                if (s.sckey[@intCast(sc)] != @as(u8, key) + 1) return;
                s.sckey[@intCast(sc)] = 0;
            }
            j = @max(j, ls.ln_start_judge);
            if (@abs(ls.ln_start_dur) > @abs(dm)) dm = ls.ln_start_dur;
            if (j >= 3 and dm > 0) {
                ls.release_time = pt;
                ls.ln_end_judge = 3;
            } else {
                s.judgeNote(lane, proc.pair, @min(j, 3), dm, true);
                s.endHold(lane);
            }
        }
    }

    fn endHold(s: *Sim, lane: u8) void {
        const ls = &s.lanes[lane];
        s.sound(ls.processing);
        ls.processing = -1;
        ls.release_time = no_time;
        ls.ln_end_judge = -1;
        s.emit(.{ .kind = .hold_end, .lane = lane });
    }

    fn moveMark(s: *Sim, lane: u8) void {
        const ls = &s.lanes[lane];
        const list = s.lane_notes[lane];
        const from = @max(s.prev_t, 0) + s.judge_start - 100_000;
        while (ls.mark < list.len and s.notes[list[ls.mark]].time_us < from) ls.mark += 1;
    }

    fn endPhase(s: *Sim, t: i64) void {
        const w = &s.judge_w;
        for (0..s.lane_count) |l| {
            const lane: u8 = @intCast(l);
            const ls = &s.lanes[l];
            if (ls.processing >= 0) {
                const proc = s.notes[@intCast(ls.processing)];
                if (proc.ln_type == .ln) {
                    if (ls.release_time != no_time and ls.release_time <= t) {
                        s.emit(.{ .kind = .stop_sound, .lane = lane, .wav = s.notes[@intCast(proc.pair)].wav });
                        s.judgeNote(lane, proc.pair, @intCast(ls.ln_end_judge), proc.time_us - ls.release_time, true);
                        s.endHold(lane);
                    } else if (proc.time_us < t) {
                        s.judgeNote(lane, proc.pair, ls.ln_start_judge, ls.ln_start_dur, true);
                        s.endHold(lane);
                    }
                } else if (ls.release_time != no_time and ls.release_time <= t) {
                    if (ls.ln_end_judge >= 3) s.emit(.{ .kind = .stop_sound, .lane = lane, .wav = s.notes[@intCast(proc.pair)].wav });
                    s.judgeNote(lane, ls.processing, @intCast(ls.ln_end_judge), proc.time_us - ls.release_time, true);
                    s.endHold(lane);
                }
            }

            s.moveMark(lane);
            const list = s.lane_notes[l];
            var i: usize = ls.mark;
            while (i < list.len) : (i += 1) {
                const idx: i32 = @intCast(list[i]);
                const n = s.notes[@intCast(idx)];
                if (!(n.time_us < t + w[3][0])) break;
                const mj = n.time_us - t;
                const st = s.state[@intCast(idx)];
                switch (n.kind) {
                    .normal => if (st == 0) s.judgeNote(lane, idx, 4, mj, true),
                    .ln_start => if (st == 0) {
                        if (n.ln_type != .ln) {
                            s.judgeNote(lane, idx, 4, mj, true);
                            // A head whose end was dropped has no pair.
                            if (n.pair >= 0) s.judgeNote(lane, n.pair, 4, mj, true);
                        } else if (ls.processing != n.pair) {
                            s.judgeNote(lane, idx, 4, mj, true);
                        }
                    },
                    .ln_end => if (st == 0 and n.ln_type != .ln) {
                        s.judgeNote(lane, idx, 4, mj, true);
                        ls.processing = -1;
                        ls.release_time = no_time;
                        ls.ln_end_judge = -1;
                        if (ls.scratch >= 0) s.sckey[@intCast(ls.scratch)] = 0;
                    },
                    .mine => {},
                }
            }
        }
    }

    /// JudgeManager.updateMicro with the LR2 rule's combo table {PG,GR,GD,MS keep; BD,PR break}.
    fn judgeNote(s: *Sim, lane: u8, idx: i32, judge: u8, fast: i64, vanish: bool) void {
        if (vanish) {
            s.state[@intCast(idx)] = judge + 1;
            s.score.passed += 1;
        }
        s.score.counts[judge][if (fast >= 0) 0 else 1] += 1;
        if (judge < 3) {
            s.score.combo += 1;
            s.score.max_combo = @max(s.score.max_combo, s.score.combo);
        } else if (judge == 3 or judge == 4) {
            s.score.combo = 0;
        }
        for (&s.gauges) |*g| g.update(judge, 1);
        s.emit(.{
            .kind = .judge,
            .lane = lane,
            .judge = judge,
            .note = idx,
            .fast_us = @intCast(std.math.clamp(fast, -2_000_000_000, 2_000_000_000)),
            .combo = s.score.combo,
        });
    }

    /// BMSPlayer.saveConfig clear logic.
    pub fn clear(s: *const Sim, finished: bool) types.Clear {
        if (s.score.passed == 0 and !finished) return .no_play;
        if (s.failed or !s.gauge().qualified() or !finished) return .failed;
        if (s.score.passed == s.score.combo) {
            if (s.score.count(.gd) == 0) {
                return if (s.score.count(.gr) == 0) .max else .perfect;
            }
            return .full_combo;
        }
        return gauge_mod.clearOf(s.gauge_type);
    }
};

const testing = std.testing;
const parser = @import("../bms/parser.zig");

fn chartFrom(src: []const u8) !types.Chart {
    return parser.parse(testing.allocator, src, .{});
}

test "gauge auto shift falls through dead gauges and picks the best clearing one" {
    var chart = try chartFrom("#BPM 120\n#TOTAL 300\n#WAV01 a.wav\n#00111:01\n");
    defer chart.deinit();
    const s = try Sim.create(testing.allocator, &chart, .{ .gauge = .exhard, .gas = .select_to_under });
    defer s.destroy();
    s.checkFailed();
    try testing.expectEqual(gauge_mod.Type.exhard, s.gauge_type);
    s.gauges[@backingInt(gauge_mod.Type.exhard)].value = 0;
    s.checkFailed();
    try testing.expectEqual(gauge_mod.Type.hard, s.gauge_type);
    s.gauges[@backingInt(gauge_mod.Type.hard)].value = 0;
    s.checkFailed();
    try testing.expectEqual(gauge_mod.Type.normal, s.gauge_type); // nothing clears yet: best alive
    s.gauges[@backingInt(gauge_mod.Type.assist_easy)].value = 70;
    s.checkFailed();
    try testing.expectEqual(gauge_mod.Type.assist_easy, s.gauge_type);
    s.gauges[@backingInt(gauge_mod.Type.normal)].value = 85;
    s.checkFailed();
    try testing.expectEqual(gauge_mod.Type.normal, s.gauge_type); // recovers upward
    try testing.expect(!s.failed);
}

test "the GAS floor, survival to groove and continue" {
    var chart = try chartFrom("#BPM 120\n#TOTAL 300\n#WAV01 a.wav\n#00111:01\n");
    defer chart.deinit();
    const floored = try Sim.create(testing.allocator, &chart, .{ .gauge = .hard, .gas = .select_to_under, .gas_floor = .normal });
    defer floored.destroy();
    floored.gauges[@backingInt(gauge_mod.Type.hard)].value = 0;
    floored.gauges[@backingInt(gauge_mod.Type.assist_easy)].value = 70;
    floored.checkFailed();
    try testing.expectEqual(gauge_mod.Type.normal, floored.gauge_type);

    const groove = try Sim.create(testing.allocator, &chart, .{ .gauge = .exhard, .gas = .survival_to_groove });
    defer groove.destroy();
    groove.checkFailed();
    try testing.expectEqual(gauge_mod.Type.exhard, groove.gauge_type);
    groove.gauges[@backingInt(gauge_mod.Type.exhard)].value = 0;
    groove.checkFailed();
    try testing.expectEqual(gauge_mod.Type.normal, groove.gauge_type);
    try testing.expect(!groove.failed);

    const on = try Sim.create(testing.allocator, &chart, .{ .gauge = .hard, .gas = .continue_play });
    defer on.destroy();
    on.gauges[@backingInt(gauge_mod.Type.hard)].value = 0;
    on.checkFailed();
    try testing.expect(!on.failed);
    try testing.expectEqual(types.Clear.failed, on.clear(true));
}

test "the judge algorithm picks which of two close notes a press takes" {
    // Two notes on one lane 100 ms apart, pressed 70 ms after the first: 30 ms before the second.
    var c = try chartFrom("#BPM 150\n#WAV01 a.wav\n#00111:01010000000000000000000000000000\n");
    defer c.deinit();
    const second = c.notes[1].time_us;
    try testing.expectEqual(@as(i64, 100_000), second - c.notes[0].time_us);
    const press = c.notes[0].time_us + 70_000;
    for ([_]struct { options.Algorithm, u32 }{ .{ .duration, 1 }, .{ .lowest, 0 } }) |case| {
        const s = try Sim.create(testing.allocator, &c, .{ .algorithm = case[0] });
        defer s.destroy();
        s.input(.{ .time_us = press, .lane = 0, .down = true });
        try testing.expect(s.state[case[1]] != 0);
    }
}

test "expand judge widens PGREAT to the GREAT window" {
    var c = try chartFrom("#BPM 120\n#RANK 3\n#WAV01 a.wav\n#00111:01\n");
    defer c.deinit();
    const s = try Sim.create(testing.allocator, &c, .{ .expand_judge = true });
    defer s.destroy();
    s.input(.{ .time_us = c.notes[0].time_us + 50_000, .lane = 0, .down = true });
    try testing.expectEqual(@as(u32, 1), s.score.count(.pg));
}

test "auto scratch plays the scratch and ignores its keys" {
    var c = try chartFrom("#BPM 120\n#WAV01 a.wav\n#00116:01\n");
    defer c.deinit();
    const s = try Sim.create(testing.allocator, &c, .{ .auto_scratch = true });
    defer s.destroy();
    s.input(.{ .time_us = 100_000, .lane = 7, .down = true });
    s.advance(c.last_note_us + 1_000_000);
    try testing.expectEqual(@as(u32, 1), s.score.count(.pg));
    try testing.expectEqual(@as(u32, 0), s.score.count(.ms));
}

// Rows are {ms from note (positive = late), judge} at the #RANK 3 window edges (EASY 21/60/120/200).
test "judge windows at rank edges" {
    const src =
        \\#BPM 120
        \\#RANK 3
        \\#TOTAL 200
        \\#WAV01 a.wav
        \\#00111:01
    ;
    const cases = [_]struct { off: i64, judge: types.Judge }{
        .{ .off = 0, .judge = .pg },
        .{ .off = -21000, .judge = .pg },
        .{ .off = 21000, .judge = .pg },
        .{ .off = -21001, .judge = .gr },
        .{ .off = 60000, .judge = .gr },
        .{ .off = 60001, .judge = .gd },
        .{ .off = 120000, .judge = .gd },
        .{ .off = -120001, .judge = .bd },
        .{ .off = 200000, .judge = .bd },
    };
    var c = try chartFrom(src);
    defer c.deinit();
    for (cases) |tc| {
        const s = try Sim.create(testing.allocator, &c, .{});
        defer s.destroy();
        s.input(.{ .time_us = c.notes[0].time_us + tc.off, .lane = 0, .down = true });
        try testing.expectEqual(@as(u32, 1), s.score.count(tc.judge));
    }
}

test "missed note becomes POOR after BAD window, frame cadence does not matter" {
    const src =
        \\#BPM 120
        \\#WAV01 a.wav
        \\#00111:01
    ;
    var c = try chartFrom(src);
    defer c.deinit();
    const a = try Sim.create(testing.allocator, &c, .{});
    defer a.destroy();
    a.advance(2_199_000);
    try testing.expectEqual(@as(u32, 0), a.score.count(.pr));
    a.advance(2_300_000);
    try testing.expectEqual(@as(u32, 1), a.score.count(.pr));
    const b = try Sim.create(testing.allocator, &c, .{});
    defer b.destroy();
    var t: i64 = 0;
    while (t < 2_300_000) : (t += 333) b.advance(t);
    b.advance(2_300_000);
    try testing.expectEqual(a.score.count(.pr), b.score.count(.pr));
    try testing.expectEqual(a.gauge().value, b.gauge().value);
}

test "empty POOR only within 1s before a note and keeps combo" {
    const src =
        \\#BPM 120
        \\#WAV01 a.wav
        \\#00111:01
    ;
    var c = try chartFrom(src);
    defer c.deinit();
    const s = try Sim.create(testing.allocator, &c, .{});
    defer s.destroy();
    s.input(.{ .time_us = 500_000, .lane = 0, .down = true }); // 1.5 s early: nothing
    s.input(.{ .time_us = 500_100, .lane = 0, .down = false });
    try testing.expectEqual(@as(u32, 0), s.score.count(.ms));
    s.input(.{ .time_us = 1_500_000, .lane = 0, .down = true }); // 0.5 s early: MS
    s.input(.{ .time_us = 1_500_100, .lane = 0, .down = false });
    try testing.expectEqual(@as(u32, 1), s.score.count(.ms));
    try testing.expectEqual(@as(u32, 0), s.score.passed);
    s.input(.{ .time_us = 2_000_000, .lane = 0, .down = true });
    try testing.expectEqual(@as(u32, 1), s.score.count(.pg));
    try testing.expectEqual(@as(u32, 1), s.score.combo);
}

test "a key in the lead-in before the song judges nothing" {
    const src =
        \\#BPM 240
        \\#WAV01 a.wav
        \\#00011:0100
    ;
    var c = try chartFrom(src);
    defer c.deinit();
    const note = c.notes[0].time_us;
    const s = try Sim.create(testing.allocator, &c, .{});
    defer s.destroy();
    // Within a second of the note, so once the song plays this press would be an empty POOR.
    try testing.expect(note < 600_000);
    s.input(.{ .time_us = -400_000, .lane = 0, .down = true });
    s.input(.{ .time_us = -300_000, .lane = 0, .down = false });
    try testing.expectEqual(@as(u32, 0), s.score.count(.ms));
    s.input(.{ .time_us = note, .lane = 0, .down = true });
    try testing.expectEqual(@as(u32, 1), s.score.count(.pg));
}

test "LR2 LN: one note, judged at release; early release is BAD" {
    const src =
        \\#BPM 120
        \\#WAV01 a.wav
        \\#00151:0101
    ;
    var c = try chartFrom(src);
    defer c.deinit();
    try testing.expectEqual(@as(u32, 1), c.total_notes);
    const head = c.notes[0].time_us;
    const tail = c.notes[1].time_us;
    {
        const s = try Sim.create(testing.allocator, &c, .{});
        defer s.destroy();
        s.input(.{ .time_us = head, .lane = 0, .down = true });
        try testing.expectEqual(@as(u32, 0), s.score.passed);
        s.advance(tail + 2000);
        try testing.expectEqual(@as(u32, 1), s.score.count(.pg));
    }
    {
        const s = try Sim.create(testing.allocator, &c, .{});
        defer s.destroy();
        s.input(.{ .time_us = head, .lane = 0, .down = true });
        s.input(.{ .time_us = head + 100_000, .lane = 0, .down = false });
        try testing.expectEqual(@as(u32, 1), s.score.count(.bd));
        try testing.expectEqual(@as(u32, 0), s.score.combo);
    }
}

test "a held plain long note names its end note and leaves the head's state alone" {
    const src =
        \\#BPM 120
        \\#WAV01 a.wav
        \\#00151:0101
    ;
    var c = try chartFrom(src);
    defer c.deinit();
    const s = try Sim.create(testing.allocator, &c, .{});
    defer s.destroy();
    s.input(.{ .time_us = c.notes[0].time_us, .lane = 0, .down = true });
    s.advance(c.notes[0].time_us + 1000);
    // Renderers rely on this: the head has no state yet, so only `processing` says it was hit.
    try testing.expectEqual(@as(u8, 0), s.state[0]);
    try testing.expectEqual(c.notes[0].pair, s.lanes[0].processing);
}

test "a charge note head without an end survives a miss and a hit" {
    const src = "#BPM 120\n#LNMODE 2\n#WAV01 a.wav\n#00151:0101\n#00111:0001\n";
    var c = try chartFrom(src);
    defer c.deinit();
    try testing.expectEqual(@as(i32, -1), c.notes[0].pair);
    const missed = try Sim.create(testing.allocator, &c, .{});
    defer missed.destroy();
    missed.advance(c.notes[c.notes.len - 1].time_us + 2_000_000);
    const hit = try Sim.create(testing.allocator, &c, .{});
    defer hit.destroy();
    for (c.notes) |n| hit.input(.{ .time_us = n.time_us, .lane = n.lane, .down = true });
    hit.advance(c.notes[c.notes.len - 1].time_us + 2_000_000);
}

test "multi-bad judges skipped notes in BAD range" {
    const src =
        \\#BPM 240
        \\#WAV01 a.wav
        \\#00111:0101010101010101
    ;
    var c = try chartFrom(src);
    defer c.deinit();
    const s = try Sim.create(testing.allocator, &c, .{});
    defer s.destroy();
    // 125 ms spacing at 240 BPM; pressing on note 3 leaves note 2 in late BAD range
    s.input(.{ .time_us = c.notes[2].time_us, .lane = 0, .down = true });
    try testing.expect(s.score.count(.bd) >= 1);
}

test "autoplay reaches max" {
    const src =
        \\#BPM 120
        \\#TOTAL 300
        \\#WAV01 a.wav
        \\#00111:01010101
        \\#00112:00010001
    ;
    var c = try chartFrom(src);
    defer c.deinit();
    const s = try Sim.create(testing.allocator, &c, .{ .autoplay = true });
    defer s.destroy();
    s.advance(c.last_note_us + 1_000_000);
    try testing.expectEqual(types.Clear.max, s.clear(true));
}
