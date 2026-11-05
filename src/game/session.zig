const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");
const engine_mod = @import("../audio/engine.zig");
const decode = @import("../audio/decode.zig");
const input = @import("../input/input.zig");
const config = @import("config.zig");
const Chart = core.types.Chart;
const Sim = core.sim.Sim;
const Note = core.types.Note;

pub const audio_exts: []const []const u8 = &.{ "wav", "ogg", "flac", "mp3" };

pub const Hit = struct {
    at_us: i64 = 0,
    fast_us: i32 = 0,
    note: i32 = -1,
    judge: u8 = 0,
};
pub const hit_ring = 64;

pub const TimedHit = struct { fast_us: i32, judge: u8 };

/// The chart's slices live as long as the session; only a failed load frees them.
pub const Parsed = struct {
    chart: Chart = undefined,
    ready: std.atomic.Value(bool) = .init(false),
    /// Set by whoever stopped waiting; the loader then frees what it made and fails.
    cancel: std.atomic.Value(bool) = .init(false),
};

pub const Snapshot = struct {
    time_us: i64 = 0,
    score: core.sim.Score = .{},
    gauge: f32 = 0,
    gauges: [core.gauge.count]f32 = @splat(0),
    gauge_border: f32 = 0,
    gauge_type: core.gauge.Type = .normal,
    last_judge: u8 = 255,
    last_fast_us: i32 = 0,
    judge_at_us: i64 = 0,
    hits: [hit_ring]Hit = @splat(.{}),
    /// Hits so far; the newest is at (hit_seq - 1) % hit_ring.
    hit_seq: u32 = 0,
    failed: bool = false,
    finished: bool = false,
    held: [core.types.max_lanes]bool = @splat(false),
    processing: [core.types.max_lanes]bool = @splat(false),
    /// End note of the LN each lane holds, -1 for none: a held plain LN leaves its head untouched, so renderers look here.
    holding: [core.types.max_lanes]i32 = @splat(-1),
    flash_at_us: [core.types.max_lanes]i64 = @splat(-10_000_000),
    bomb_at_us: [core.types.max_lanes]i64 = @splat(-10_000_000),
    bomb_judge: [core.types.max_lanes]u8 = @splat(0),
};

/// Times are the chart's own.
pub const Practice = struct {
    pub const min_freq = 50;
    pub const max_freq = 200;

    start_us: i64,
    end_us: i64,
    /// Percent; the pitch moves with it, as beatoraja's FREQ does.
    freq: u32 = 100,
    /// Percent, 0 for the chart's own.
    judgerank: i32 = 0,
};

fn scaled(t: i64, freq: u32) i64 {
    // Saturating: a chart's times are untrusted, and a parser allows far more than a song lasts.
    return @divTrunc(t *| 100, @as(i64, freq));
}

pub fn applyPractice(chart: *Chart, p: Practice) !void {
    const al = chart.arena.allocator();
    const inSection = struct {
        fn f(n: Note, sec: Practice) bool {
            return n.time_us >= sec.start_us and n.time_us <= sec.end_us;
        }
    }.f;
    var bg: std.ArrayList(core.types.BgSound) = .empty;
    try bg.appendSlice(al, chart.bg);
    const new_index = try al.alloc(i32, chart.notes.len);
    var notes: std.ArrayList(Note) = .empty;
    var last_note: i64 = 0;
    chart.total_notes = 0;
    for (chart.notes, new_index) |n, *ni| {
        const whole = inSection(n, p) and (n.pair < 0 or inSection(chart.notes[@intCast(n.pair)], p));
        if (!whole) {
            ni.* = -1;
            if (n.wav >= 0 and n.kind != .mine and n.kind != .ln_end) try bg.append(al, .{ .time_us = n.time_us, .wav = n.wav, .wav_start_us = n.wav_start_us, .wav_dur_us = n.wav_dur_us });
            continue;
        }
        ni.* = @intCast(notes.items.len);
        try notes.append(al, n);
        last_note = n.time_us;
        const scores = switch (n.kind) {
            .normal, .ln_start => true,
            .ln_end => n.ln_type != .ln,
            .mine => false,
        };
        if (scores) chart.total_notes += 1;
    }
    for (notes.items) |*n| {
        if (n.pair >= 0) n.pair = new_index[@intCast(n.pair)];
        n.time_us = scaled(n.time_us, p.freq);
        n.wav_start_us = scaled(n.wav_start_us, p.freq);
        n.wav_dur_us = scaled(n.wav_dur_us, p.freq);
    }
    for (bg.items) |*b| {
        b.time_us = scaled(b.time_us, p.freq);
        b.wav_start_us = scaled(b.wav_start_us, p.freq);
        b.wav_dur_us = scaled(b.wav_dur_us, p.freq);
    }
    std.mem.sort(core.types.BgSound, bg.items, {}, struct {
        fn f(_: void, l: core.types.BgSound, r: core.types.BgSound) bool {
            return l.time_us < r.time_us;
        }
    }.f);
    for (chart.hidden) |*h| h.time_us = scaled(h.time_us, p.freq);
    for (chart.bga) |*e| e.time_us = scaled(e.time_us, p.freq);
    const bpm_scale = @as(f64, @floatFromInt(p.freq)) / 100;
    for (chart.timelines) |*t| {
        t.time_us = scaled(t.time_us, p.freq);
        t.stop_us = scaled(t.stop_us, p.freq);
        t.bpm *= bpm_scale;
    }
    chart.bpm *= bpm_scale;
    chart.min_bpm *= bpm_scale;
    chart.max_bpm *= bpm_scale;
    chart.notes = notes.items;
    chart.bg = bg.items;
    chart.last_note_us = scaled(last_note, p.freq);
    chart.last_time_us = scaled(p.end_us, p.freq);
    if (p.judgerank > 0) chart.judgerank = p.judgerank;
}

pub const Params = struct {
    /// Never recorded.
    practice: ?Practice = null,
    path: []const u8,
    /// Chart and events are filled in when the replay is made.
    rec: core.replay.Replay = .{},
    /// A play with any of it is not saved.
    assist: config.Assist = .{},
    table_level: []const u8 = "",
    table_name: []const u8 = "",
    autoplay: bool = false,
    replay: ?core.replay.Replay = null,
    start_us: i64 = 0,
    selected_random: ?[]const i32 = null,
    judge_offset_us: i64 = 0,
    allow_input: bool = true,
    initial_gauge: ?f32 = null,
};

fn simConfig(p: Params, autoplay: bool) core.sim.Config {
    var cfg = core.replay.simConfig(p.rec);
    cfg.autoplay = autoplay;
    cfg.expand_judge = p.assist.picked.expand_judge;
    cfg.auto_scratch = p.assist.auto_scratch;
    return cfg;
}

const preroll_us: i64 = 2_000_000;
const post_us: i64 = 3_000_000;
const practice_rest_us: i64 = 1_000_000;

pub const Session = struct {
    gpa: std.mem.Allocator,
    chart: Chart,
    dir: []u8,
    engine: *engine_mod.Engine,
    sim: *Sim,
    samples: []decode.Sample,
    schedule: []engine_mod.Sched,
    params: Params,
    bind: [input.code_count]?config.Binding,
    thread: ?*c.SDL_Thread = null,
    quit: std.atomic.Value(bool) = .init(false),
    seek_to: std.atomic.Value(i64) = .init(no_seek),
    done: std.atomic.Value(bool) = .init(false),
    paused: std.atomic.Value(bool) = .init(false),
    pause_t: std.atomic.Value(i64) = .init(0),
    /// A paused play is not comparable with one in a single sitting, so it is never recorded.
    was_paused: bool = false,
    lock: *c.SDL_Mutex,
    snap: Snapshot = .{},
    events: std.ArrayList(core.sim.Event) = .empty,
    /// Filled by the sim thread, and read only once it has stopped. Its capacity never grows there.
    timed_hits: std.ArrayList(TimedHit) = .empty,
    last_event_t: i64 = std.math.minInt(i64),
    end_us: i64,
    load_warnings: u32 = 0,
    /// Guarded by `lock`.
    vis: []u8,

    const no_seek = std.math.minInt(i64);
    /// Covers the OS handing over an event stamped a moment before.
    const input_grace_us = 5_000;
    /// The evdev thread hands over kernel-stamped events only once it is scheduled, which load can delay.
    const direct_grace_us = 20_000;
    /// A main loop stalled longer than this, as by a dragged window, stops holding judging back.
    const max_input_lag_us = 250_000;

    /// Judging stops short of input still on its way; a null `sdl_read_us` means no play input comes through SDL.
    fn judgedUntil(now: i64, sdl_read_us: ?i64, direct: bool, judge_offset_us: i64) i64 {
        var t = now - @as(i64, if (direct) direct_grace_us else input_grace_us);
        if (sdl_read_us) |r| t = @min(t, @max(@min(now, r), now - max_input_lag_us) - input_grace_us);
        return t - @max(judge_offset_us, 0);
    }

    /// An auto-scratch lane's keysounds ride the engine schedule, so a lagged judge step cannot delay them.
    fn autoScratchLane(chart: *const Chart, auto_scratch: bool, lane: u8) bool {
        return auto_scratch and chart.mode.scratchOf(lane) >= 0;
    }

    pub fn parseFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, selected: ?[]const i32, seed: u64) !Chart {
        const data = try fs.readAlloc(gpa, io, path, 1 << 28);
        defer gpa.free(data);
        return parseBytes(gpa, path, data, selected, seed);
    }

    /// `path` only picks the format.
    pub fn parseBytes(gpa: std.mem.Allocator, path: []const u8, data: []const u8, selected: ?[]const i32, seed: u64) !Chart {
        return core.parse(gpa, .of(path), data, .{ .selected_random = selected, .seed = seed });
    }

    const LoadJob = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        dir: []const u8,
        chart: *const Chart,
        samples: []decode.Sample,
        rate: u32,
        next: *std.atomic.Value(usize),
        progress: *std.atomic.Value(usize),
        failed: *std.atomic.Value(u32),
        cancel: *const std.atomic.Value(bool),
    };

    fn loadWorker(ud: ?*anyopaque) callconv(.c) c_int {
        const job: *LoadJob = @ptrCast(@alignCast(ud));
        // Heap, not a fixed buffer: resolving a differently cased name lists the whole folder.
        var arena = std.heap.ArenaAllocator.init(job.gpa);
        defer arena.deinit();
        while (true) {
            _ = arena.reset(.retain_capacity);
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.chart.wavs.len or job.cancel.load(.monotonic)) return 0;
            defer _ = job.progress.fetchAdd(1, .monotonic);
            const p = fs.resolveAsset(arena.allocator(), job.io, job.dir, job.chart.wavs[i], audio_exts) catch null;
            if (p) |path| {
                const bytes = fs.readAlloc(job.gpa, job.io, path, 1 << 29) catch {
                    _ = job.failed.fetchAdd(1, .monotonic);
                    continue;
                };
                defer job.gpa.free(bytes);
                job.samples[i] = decode.decode(job.gpa, bytes, path, job.rate, job.cancel) catch blk: {
                    _ = job.failed.fetchAdd(1, .monotonic);
                    break :blk .{};
                };
            } else _ = job.failed.fetchAdd(1, .monotonic);
        }
    }

    /// A sound decoded for a lower rate than it plays at comes out faster and higher.
    fn decodeRate(rate: u32, params: Params) u32 {
        const p = params.practice orelse return rate;
        return @max(rate * 100 / p.freq, 1);
    }

    /// Blocking: runs on a loader thread.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, engine: *engine_mod.Engine, cfg: *const config.Config, params: Params, progress: *std.atomic.Value(usize), total: *std.atomic.Value(usize), parsed: *Parsed) !*Session {
        var chart = try parseFile(gpa, io, params.path, params.selected_random orelse if (params.replay) |r| r.bms_random else null, params.rec.seed);
        errdefer chart.deinit();
        var played = params;
        if (!core.options.applyLnMode(&chart, params.rec.ln_mode)) played.rec.ln_mode = .ln;
        // As in beatoraja, these assist only a chart they change.
        if (params.assist.picked.no_mine and chart.has_mine) core.options.dropMines(&chart) else played.assist.picked.no_mine = false;
        if (params.assist.picked.legacy and chart.has_ln) core.options.legacyNotes(&chart) else played.assist.picked.legacy = false;
        if (params.assist.battle and !try core.options.battle(&chart)) {
            played.assist.battle = false;
            played.assist.auto_scratch = false;
        }
        core.replay.applyLanes(&chart, params.rec);
        if (params.practice) |p| {
            try applyPractice(&chart, p);
            played.start_us = @max(scaled(p.start_us, p.freq) - preroll_us, 0);
        }
        total.store(chart.wavs.len, .release);
        parsed.chart = chart;
        parsed.ready.store(true, .release);

        const samples = try gpa.alloc(decode.Sample, chart.wavs.len);
        @memset(samples, .{});
        errdefer {
            for (samples) |sm| if (sm.data.len > 0) gpa.free(sm.data);
            gpa.free(samples);
        }
        const dir = try gpa.dupe(u8, std.fs.path.dirname(params.path) orelse ".");
        errdefer gpa.free(dir);

        var next: std.atomic.Value(usize) = .init(0);
        var failed: std.atomic.Value(u32) = .init(0);
        var job: LoadJob = .{ .gpa = gpa, .io = io, .dir = dir, .chart = &chart, .samples = samples, .rate = decodeRate(engine.rate, params), .next = &next, .progress = progress, .failed = &failed, .cancel = &parsed.cancel };
        var threads: [31]?*c.SDL_Thread = @splat(null);
        const extra: usize = @intCast(std.math.clamp(c.SDL_GetNumLogicalCPUCores() - 1, 0, threads.len));
        for (threads[0..extra]) |*t| t.* = c.SDL_CreateThread(loadWorker, "load", &job);
        _ = loadWorker(&job);
        for (threads) |t| if (t != null) c.SDL_WaitThread(t, null);
        if (parsed.cancel.load(.acquire)) return error.Canceled;

        chart.last_time_us = playEnd(&chart, samples, engine.rate, params.practice != null);
        const sched = try buildSchedule(gpa, &chart, engine, played.assist.auto_scratch);
        errdefer gpa.free(sched);
        const sim = try Sim.create(gpa, &chart, simConfig(played, params.autoplay));
        errdefer sim.destroy();
        if (params.initial_gauge) |v| sim.gauges[@backingInt(params.rec.gauge)].set(v);
        const vis = try gpa.alloc(u8, sim.state.len);
        errdefer gpa.free(vis);
        @memset(vis, 0);
        const s = try gpa.create(Session);
        s.* = .{
            .gpa = gpa,
            .chart = chart,
            .dir = dir,
            .engine = engine,
            .sim = sim,
            .samples = samples,
            .schedule = sched,
            .vis = vis,
            .params = played,
            .bind = config.bindings(cfg, chart.mode),
            .lock = c.SDL_CreateMutex() orelse return error.NoMutex,
            .end_us = if (params.practice != null) std.math.maxInt(i64) else chart.last_time_us + post_us,
            .load_warnings = failed.load(.monotonic),
        };
        s.sim.notes = s.chart.notes;
        try s.events.ensureTotalCapacity(gpa, chart.total_notes * 4 + 4096);
        try s.timed_hits.ensureTotalCapacity(gpa, chart.total_notes);
        return s;
    }

    fn buildSchedule(gpa: std.mem.Allocator, chart: *const Chart, e: *const engine_mod.Engine, auto_scratch: bool) ![]engine_mod.Sched {
        var out: std.ArrayList(engine_mod.Sched) = try .initCapacity(gpa, chart.bg.len);
        errdefer out.deinit(gpa);
        for (chart.bg) |b| out.appendAssumeCapacity(.{
            .frame = e.usToFrame(b.time_us),
            .wav = b.wav,
            .start = @intCast(e.usToFrame(b.wav_start_us)),
            .len = @intCast(e.usToFrame(b.wav_dur_us)),
        });
        // The sim sounds an auto lane's normal and LN start notes, and never a mine there.
        for (chart.notes) |n| if (autoScratchLane(chart, auto_scratch, n.lane) and n.wav >= 0 and (n.kind == .normal or n.kind == .ln_start)) try out.append(gpa, .{
            .frame = e.usToFrame(n.time_us),
            .wav = n.wav,
            .start = @intCast(e.usToFrame(n.wav_start_us)),
            .len = @intCast(e.usToFrame(n.wav_dur_us)),
        });
        std.mem.sort(engine_mod.Sched, out.items, {}, struct {
            fn lt(_: void, a: engine_mod.Sched, b: engine_mod.Sched) bool {
                return a.frame < b.frame;
            }
        }.lt);
        return out.toOwnedSlice(gpa);
    }

    /// `late_us` is how long ago a shared versus start was, so a slow loader joins where the others are.
    pub fn start(s: *Session, late_us: i64) void {
        input.clear();
        const first = firstUs(s.params.start_us, late_us);
        // Starting mid-chart is a preview or a late versus player: the sim catches up silently, the same way a seek does.
        if (first > 0) {
            s.sim.advance(first);
            var sink: [256]core.sim.Out = undefined;
            while (s.sim.drain(&sink) > 0) {}
        }
        s.engine.load(s.samples, s.schedule, s.engine.usToFrame(first));
        s.engine.seek(s.engine.usToFrame(first));
        s.engine.start();
        s.thread = c.SDL_CreateThread(simThread, "sim", s);
        if (s.thread != null) _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_HIGH);
    }

    /// Seeks by rebuilding the sim from zero: deterministic replay of autoplay reaches the same state.
    pub fn setPaused(s: *Session, p: bool) void {
        if (p) {
            s.pause_t.store(s.songNow(), .release);
            s.paused.store(true, .release);
            s.engine.pause(true);
        } else {
            // Resuming is what spoils the record: a pause that ends in quitting still counts.
            s.was_paused = true;
            s.engine.pause(false);
            s.paused.store(false, .release);
        }
    }

    pub fn seek(s: *Session, us: i64) void {
        s.seek_to.store(us, .release);
    }

    fn songNow(s: *Session) i64 {
        if (s.engine.clockReady()) return s.engine.toSongUs(c.SDL_GetTicksNS());
        const f = s.engine.frame.load(.acquire);
        return @divTrunc(f * 1_000_000, s.engine.rate);
    }

    fn applyInput(s: *Session, t_in: i64, lane: u8, key: u8, down: bool) void {
        // Replays and the sim need events ordered and never behind judged time, which a replay steps past.
        const t = @max(t_in, s.last_event_t, s.sim.grid_t);
        s.last_event_t = t;
        const ev: core.sim.Event = .{ .time_us = t, .lane = lane, .key = key, .down = down };
        s.events.appendAssumeCapacity(ev);
        s.sim.input(ev);
        if (s.events.items.len == s.events.capacity) s.params.allow_input = false;
    }

    fn simThread(ud: ?*anyopaque) callconv(.c) c_int {
        const s: *Session = @ptrCast(@alignCast(ud));
        _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_TIME_CRITICAL);
        var out: [256]core.sim.Out = undefined;
        var snap: Snapshot = .{};
        var rp_i: usize = 0;
        const joy_bound = for (s.bind[input.joy_base..]) |b| {
            if (b != null) break true;
        } else false;
        while (!s.quit.load(.acquire)) {
            const target = s.seek_to.swap(no_seek, .acq_rel);
            if (target != no_seek) s.doSeek(target, &snap);

            const paused = s.paused.load(.acquire);
            const now = if (paused) s.pause_t.load(.acquire) else s.songNow();
            const direct = input.direct_keyboard.load(.acquire);
            // Read before the queue: the main loop publishes it after pushing what it read.
            const sdl_read_us: ?i64 = if (direct and !joy_bound) null else if (s.engine.clockReady()) s.engine.toSongUs(input.sdl_read_ns.load(.acquire)) else now;
            while (input.pop()) |ev| {
                if (!s.params.allow_input or s.params.replay != null or s.params.autoplay) continue;
                const b = s.bind[ev.code] orelse continue;
                // Paused time cannot hit notes, but letting go of a long note still counts.
                if (paused and ev.down) continue;
                const t = if (paused or !s.engine.clockReady()) now else s.engine.toSongUs(ev.mono_ns) - s.params.judge_offset_us;
                s.applyInput(t, b.lane, b.key, ev.down);
                if (ev.down) snap.flash_at_us[b.lane] = t;
                snap.held[b.lane] = s.sim.lanes[b.lane].down[0] or s.sim.lanes[b.lane].down[1];
            }
            if (s.params.replay) |r| {
                while (rp_i < r.events.len and r.events[rp_i].time_us <= now) : (rp_i += 1) {
                    const e = r.events[rp_i];
                    s.sim.input(e);
                    if (e.down) snap.flash_at_us[e.lane] = e.time_us;
                    snap.held[e.lane] = s.sim.lanes[e.lane].down[0] or s.sim.lanes[e.lane].down[1];
                }
            }
            // Replays and autoplay have no late events, and their keysounds must not lag.
            s.sim.advance(if (s.params.replay != null or s.params.autoplay) now else judgedUntil(now, sdl_read_us, direct, s.params.judge_offset_us));

            const n = s.sim.drain(&out);
            for (out[0..n]) |o| switch (o.kind) {
                .sound => if (!autoScratchLane(&s.chart, s.sim.auto_scratch, o.lane)) {
                    const note = s.chart.notes[@intCast(o.note)];
                    const startf: u32 = @intCast(s.engine.usToFrame(note.wav_start_us));
                    const lenf: u32 = @intCast(s.engine.usToFrame(note.wav_dur_us));
                    s.engine.play(o.wav, startf, lenf);
                },
                .stop_sound => s.engine.stopWav(o.wav),
                .judge => {
                    snap.hits[snap.hit_seq % hit_ring] = .{ .at_us = now, .fast_us = o.fast_us, .note = o.note, .judge = o.judge };
                    snap.hit_seq +%= 1;
                    if (isTimedHit(o.judge) and s.timed_hits.items.len < s.timed_hits.capacity) s.timed_hits.appendAssumeCapacity(.{ .fast_us = o.fast_us, .judge = o.judge });
                    snap.last_judge = o.judge;
                    snap.last_fast_us = o.fast_us;
                    snap.judge_at_us = now;
                    if (o.judge < 3) {
                        snap.bomb_at_us[o.lane] = now;
                        snap.bomb_judge[o.lane] = o.judge;
                    }
                    if (s.params.autoplay) snap.flash_at_us[o.lane] = now;
                },
                .press_empty, .hold_start, .hold_end => {},
            };

            snap.time_us = now;
            snap.score = s.sim.score;
            snap.gauge = s.sim.gauge().value;
            snap.gauge_border = s.sim.gauge().el.border;
            snap.gauge_type = s.sim.gauge_type;
            for (&snap.gauges, s.sim.gauges) |*d, g| d.* = g.value;
            snap.failed = s.sim.failed;
            for (0..s.chart.mode.keys()) |l| {
                snap.processing[l] = s.sim.lanes[l].processing >= 0;
                snap.holding[l] = s.sim.lanes[l].processing;
            }
            if (s.params.practice != null and (s.sim.failed or now >= s.chart.last_time_us + practice_rest_us)) {
                s.restartSection(&snap);
                continue;
            }
            if (s.sim.failed or now >= s.end_us) snap.finished = true;
            _ = c.SDL_LockMutex(s.lock);
            s.snap = snap;
            @memcpy(s.vis, s.sim.state);
            _ = c.SDL_UnlockMutex(s.lock);
            if (snap.finished) {
                s.done.store(true, .release);
                if (s.sim.failed) s.engine.stopAll();
                break;
            }
            input.wait(250_000);
        }
        return 0;
    }

    fn restartSection(s: *Session, snap: *Snapshot) void {
        const fresh = Sim.create(s.gpa, &s.chart, simConfig(s.params, false)) catch return;
        s.engine.stopAll();
        s.sim.destroy();
        s.sim = fresh;
        s.sim.notes = s.chart.notes;
        if (s.params.start_us > 0) s.sim.advance(s.params.start_us);
        var sink: [256]core.sim.Out = undefined;
        while (s.sim.drain(&sink) > 0) {}
        s.events.clearRetainingCapacity();
        s.timed_hits.clearRetainingCapacity();
        s.last_event_t = std.math.minInt(i64);
        const first = firstUs(s.params.start_us, 0);
        s.engine.seek(s.engine.usToFrame(first));
        // Paused, the clock stays here: at the old time the new sim would miss every note up to it.
        s.pause_t.store(first, .release);
        snap.* = .{};
    }

    fn doSeek(s: *Session, target: i64, snap: *Snapshot) void {
        s.engine.seek(s.engine.usToFrame(target));
        @memset(s.sim.state, 0);
        const fresh = Sim.create(s.gpa, &s.chart, simConfig(s.params, true)) catch return;
        s.sim.destroy();
        s.sim = fresh;
        s.sim.advance(target);
        var sink: [256]core.sim.Out = undefined;
        while (s.sim.drain(&sink) > 0) {}
        snap.* = .{};
    }

    /// Copied atomically into `dst`.
    pub fn snapshotInto(s: *Session, dst: []u8) Snapshot {
        _ = c.SDL_LockMutex(s.lock);
        defer _ = c.SDL_UnlockMutex(s.lock);
        @memcpy(dst, s.vis);
        return s.snap;
    }

    pub fn snapshot(s: *Session) Snapshot {
        _ = c.SDL_LockMutex(s.lock);
        defer _ = c.SDL_UnlockMutex(s.lock);
        return s.snap;
    }

    pub fn stop(s: *Session) void {
        s.quit.store(true, .release);
        if (s.thread) |t| c.SDL_WaitThread(t, null);
        s.thread = null;
        s.engine.stopAll();
        s.engine.pause(true);
    }

    pub fn canSkip(s: *const Session, snap: Snapshot) bool {
        return s.params.practice == null and snap.time_us > s.chart.last_note_us + 1_000_000;
    }

    pub fn replayBytes(s: *Session) ![]u8 {
        var r = s.params.rec;
        r.sha256 = s.chart.sha256;
        r.bms_random = s.chart.random;
        r.events = s.events.items;
        return core.replay.encode(s.gpa, r);
    }

    pub fn destroy(s: *Session) void {
        s.stop();
        // the engine holds pointers into samples until replaced
        s.engine.load(&.{}, &.{}, 0);
        for (s.samples) |sm| if (sm.data.len > 0) s.gpa.free(sm.data);
        s.gpa.free(s.samples);
        s.gpa.free(s.schedule);
        s.gpa.free(s.vis);
        s.gpa.free(s.dir);
        s.sim.destroy();
        s.events.deinit(s.gpa);
        s.timed_hits.deinit(s.gpa);
        s.chart.deinit();
        c.SDL_DestroyMutex(s.lock);
        s.gpa.destroy(s);
    }
};

/// A POOR has no timing, and pressing at nothing could otherwise use up the room kept for real hits.
fn isTimedHit(judge: u8) bool {
    return judge < 4;
}

fn firstUs(start_us: i64, late_us: i64) i64 {
    return start_us - (if (start_us > 0) @as(i64, 0) else preroll_us) + late_us;
}

/// Notes can end long before the music, so play on until the sound ends; a practice section ends where set.
fn playEnd(chart: *const Chart, samples: []const decode.Sample, rate: u32, practice: bool) i64 {
    if (practice) return chart.last_time_us;
    return @max(chart.last_time_us, chartAudioEnd(chart, samples, rate));
}

fn soundEnd(time_us: i64, wav: i32, start_us: i64, dur_us: i64, samples: []const decode.Sample, rate: u32) i64 {
    if (wav < 0 or wav >= samples.len) return time_us;
    const frames: i64 = @intCast(samples[@intCast(wav)].frames());
    const rest = @max(@divTrunc(frames * 1_000_000, rate) - start_us, 0);
    return time_us + if (dur_us > 0) @min(dur_us, rest) else rest;
}

fn chartAudioEnd(chart: *const Chart, samples: []const decode.Sample, rate: u32) i64 {
    var end: i64 = 0;
    for (chart.bg) |b| end = @max(end, soundEnd(b.time_us, b.wav, b.wav_start_us, b.wav_dur_us, samples, rate));
    for (chart.notes) |n| end = @max(end, soundEnd(n.time_us, n.wav, n.wav_start_us, n.wav_dur_us, samples, rate));
    return end;
}

test "an input older than judged time scores the same when resimulated" {
    const gpa = std.testing.allocator;
    var chart = try core.bms.parse(gpa, "#BPM 120\n#TOTAL 300\n#WAV01 a.wav\n#00111:01\n", .{});
    defer chart.deinit();
    var s: Session = undefined;
    s.params = .{ .path = "" };
    s.last_event_t = 0;
    s.sim = try Sim.create(gpa, &chart, .{});
    defer s.sim.destroy();
    s.events = try .initCapacity(gpa, 4);
    defer s.events.deinit(gpa);
    const note_t = chart.notes[0].time_us;
    s.sim.advance(note_t + 1_000_000);
    s.applyInput(note_t, chart.notes[0].lane, 0, true);
    try std.testing.expectEqual(note_t + 1_000_000, s.events.items[0].time_us);
    const again = try Sim.create(gpa, &chart, .{});
    defer again.destroy();
    for (s.events.items) |e| again.input(e);
    try std.testing.expectEqual(s.sim.score.exScore(), again.score.exScore());
    try std.testing.expectEqual(s.sim.score.count(.pr), again.score.count(.pr));
    try std.testing.expectEqual(s.sim.score.count(.ms), again.score.count(.ms));
}

test "judging waits for input a slow frame has not read yet" {
    const now: i64 = 10_000_000;
    const read = now - 50_000;
    try std.testing.expect(Session.judgedUntil(now, read, false, 0) <= read);
    try std.testing.expect(Session.judgedUntil(now, now, false, 30_000) <= now - 30_000);
    try std.testing.expectEqual(now - Session.max_input_lag_us - Session.input_grace_us, Session.judgedUntil(now, 0, false, 0));
    // Direct keys alone: a stalled main loop holds nothing back, but a late evdev thread stays covered.
    try std.testing.expectEqual(now - Session.direct_grace_us, Session.judgedUntil(now, null, true, 0));
    try std.testing.expect(Session.judgedUntil(now, now, true, 0) <= now - Session.direct_grace_us);
    try std.testing.expect(Session.judgedUntil(now, read, true, 0) <= read);

    const gpa = std.testing.allocator;
    var chart = try core.bms.parse(gpa, "#BPM 120\n#TOTAL 300\n#WAV01 a.wav\n#00111:01\n", .{});
    defer chart.deinit();
    var s: Session = undefined;
    s.params = .{ .path = "" };
    s.last_event_t = 0;
    s.sim = try Sim.create(gpa, &chart, .{});
    defer s.sim.destroy();
    s.events = try .initCapacity(gpa, 4);
    defer s.events.deinit(gpa);
    const note_t = chart.notes[0].time_us;
    s.sim.advance(Session.judgedUntil(note_t + 50_000, note_t, false, 0));
    s.applyInput(note_t, chart.notes[0].lane, 0, true);
    try std.testing.expectEqual(note_t, s.events.items[0].time_us);
    try std.testing.expectEqual(@as(u32, 1), s.sim.score.count(.pg));
}

test "auto-scratch keysounds play from the schedule, not from the lagged judge step" {
    const gpa = std.testing.allocator;
    // BGM at 2 s, a key note at 2.5 s and a scratch note at 3 s.
    var chart = try core.bms.parse(gpa, "#BPM 120\n#WAV01 a.wav\n#WAV02 b.wav\n#WAV03 c.wav\n#00101:01\n#00111:0002\n#00116:0003\n", .{});
    defer chart.deinit();
    const e: engine_mod.Engine = .{ .gpa = gpa, .rate = 1000 };
    const plain = try Session.buildSchedule(gpa, &chart, &e, false);
    defer gpa.free(plain);
    try std.testing.expectEqual(@as(usize, 1), plain.len);
    const auto = try Session.buildSchedule(gpa, &chart, &e, true);
    defer gpa.free(auto);
    try std.testing.expectEqual(@as(usize, 2), auto.len);
    try std.testing.expectEqual(@as(i64, 2000), auto[0].frame);
    try std.testing.expectEqual(@as(i64, 3000), auto[1].frame);
    try std.testing.expectEqual(@as(i32, 2), auto[1].wav);

    var sim = try Sim.create(gpa, &chart, .{ .auto_scratch = true });
    defer sim.destroy();
    sim.advance(4_000_000);
    var out: [16]core.sim.Out = undefined;
    var sounds: u32 = 0;
    for (out[0..sim.drain(&out)]) |o| if (o.kind == .sound) {
        try std.testing.expect(Session.autoScratchLane(&chart, true, o.lane));
        sounds += 1;
    };
    try std.testing.expectEqual(@as(u32, 1), sounds);
}

test "a practice section keeps its notes, hands the rest to the music and moves to the new speed" {
    const gpa = std.testing.allocator;
    // 120 BPM: a measure is 2 s, with notes at 2 s, 3 s and 4 s, and an LN crossing the section's end.
    var chart = try core.bms.parse(gpa, "#BPM 120\n#TOTAL 300\n#WAV01 a.wav\n#00111:01010100\n#00212:01000000\n#LNOBJ 02\n#00113:01000000\n#00313:02000000\n", .{});
    defer chart.deinit();
    const bg_before = chart.bg.len;
    const notes_before = chart.notes.len;
    try applyPractice(&chart, .{ .start_us = 2_500_000, .end_us = 4_500_000, .freq = 200, .judgerank = 50 });
    try std.testing.expect(chart.notes.len < notes_before);
    try std.testing.expect(chart.bg.len > bg_before);
    for (chart.notes) |n| {
        try std.testing.expect(n.time_us >= 1_250_000 and n.time_us <= 2_250_000);
        try std.testing.expect(n.pair < chart.notes.len);
    }
    try std.testing.expectEqual(@as(u32, @intCast(chart.notes.len)), chart.total_notes);
    try std.testing.expectEqual(@as(i64, 2_250_000), chart.last_time_us);
    try std.testing.expectEqual(@as(f64, 240), chart.bpm);
    try std.testing.expectEqual(@as(i32, 50), chart.judgerank);
    for (chart.bg[1..], chart.bg[0 .. chart.bg.len - 1]) |b, prev| try std.testing.expect(b.time_us >= prev.time_us);
}

test "a practice section ends where it was set, and every loop has a lead-in from the top" {
    var data: [8000]f32 = @splat(0);
    const samples = [_]decode.Sample{.{ .data = &data }};
    var chart: Chart = undefined;
    chart.last_time_us = 1000;
    var bg = [_]core.types.BgSound{.{ .time_us = 0, .wav = 0, .wav_start_us = 0, .wav_dur_us = 0 }};
    chart.bg = &bg;
    chart.notes = &.{};
    try std.testing.expectEqual(@as(i64, 1000), playEnd(&chart, &samples, 4000, true));
    try std.testing.expectEqual(@as(i64, 1_000_000), playEnd(&chart, &samples, 4000, false));
    try std.testing.expectEqual(-preroll_us, firstUs(0, 0));
    try std.testing.expectEqual(@as(i64, 5), firstUs(5, 0));
    try std.testing.expectEqual(1_000_000 - preroll_us, firstUs(0, 1_000_000));
    try std.testing.expectEqual(@as(i64, 3_000_000), firstUs(0, 3_000_000 + preroll_us));
}

test "only a hit with a timing is kept for the graph" {
    try std.testing.expect(isTimedHit(3));
    try std.testing.expect(!isTimedHit(4));
    try std.testing.expect(!isTimedHit(5));
}

test "a hostile chart's time does not overflow practice scaling" {
    try std.testing.expectEqual(@divTrunc(std.math.maxInt(i64), @as(i64, 50)), scaled(std.math.maxInt(i64) / 2, 50));
}

test "sound end honours slices and missing samples" {
    var data: [8000]f32 = @splat(0); // 4000 stereo frames: 1 s at 4 kHz
    const samples = [_]decode.Sample{.{ .data = &data }};
    try std.testing.expectEqual(@as(i64, 6_000_000), soundEnd(5_000_000, 0, 0, 0, &samples, 4000));
    try std.testing.expectEqual(@as(i64, 5_250_000), soundEnd(5_000_000, 0, 500_000, 250_000, &samples, 4000));
    try std.testing.expectEqual(@as(i64, 5_500_000), soundEnd(5_000_000, 0, 500_000, 9_000_000, &samples, 4000));
    try std.testing.expectEqual(@as(i64, 5_000_000), soundEnd(5_000_000, -1, 0, 0, &samples, 4000));
}

test "a canceled load fails and frees what it made" {
    const gpa = std.testing.allocator;
    const engine = try engine_mod.Engine.create(gpa);
    defer engine.destroy();
    const cfg: config.Config = .{};
    var progress: std.atomic.Value(usize) = .init(0);
    var total: std.atomic.Value(usize) = .init(0);
    var parsed: Parsed = .{};
    parsed.cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, Session.create(gpa, std.testing.io, engine, &cfg, .{ .path = "tests/charts/stop.bms" }, &progress, &total, &parsed));
    try std.testing.expectEqual(@as(usize, 0), progress.load(.acquire));
}
