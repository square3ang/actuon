//! One play of one chart: loads assets, runs the sim thread, records the replay.
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

pub const audio_exts: []const []const u8 = &.{ "wav", "ogg", "flac", "mp3" };

/// One judged note, for skins that chart recent timing.
pub const Hit = struct {
    at_us: i64 = 0,
    fast_us: i32 = 0,
    note: i32 = -1,
    judge: u8 = 0,
};
pub const hit_ring = 64;

/// What the loader knows once the chart is parsed, before its sounds decode.
/// The chart's slices live until the session does; only a load that then fails frees them.
pub const Parsed = struct {
    chart: Chart = undefined,
    ready: std.atomic.Value(bool) = .init(false),
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
    /// The end note of the long note each lane is holding, -1 when none. A plain long note leaves
    /// its head note's state untouched while held, so this is how a renderer knows it was hit.
    holding: [core.types.max_lanes]i32 = @splat(-1),
    flash_at_us: [core.types.max_lanes]i64 = @splat(-10_000_000),
    bomb_at_us: [core.types.max_lanes]i64 = @splat(-10_000_000),
    bomb_judge: [core.types.max_lanes]u8 = @splat(0),
};

pub const Params = struct {
    path: []const u8,
    gauge: core.gauge.Type = .normal,
    gas: bool = false,
    /// Difficulty table level to show instead of the chart's own, when it has one.
    table_level: []const u8 = "",
    table_name: []const u8 = "",
    random: core.options.Random = .off,
    seed: u64 = 0,
    autoplay: bool = false,
    /// Replay to play back instead of live input.
    replay: ?core.replay.Replay = null,
    start_us: i64 = 0,
    selected_random: ?[]const i32 = null,
    judge_offset_us: i64 = 0,
    allow_input: bool = true,
    /// Course play carries the gauge over from the previous stage.
    initial_gauge: ?f32 = null,
};

const preroll_us: i64 = 2_000_000;
const post_us: i64 = 3_000_000;

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
    last_event_t: i64 = std.math.minInt(i64),
    end_us: i64,
    load_warnings: u32 = 0,
    /// Copy of sim.state for the render thread, guarded by `lock`.
    vis: []u8,

    const no_seek = std.math.minInt(i64);

    pub fn parseFile(gpa: std.mem.Allocator, path: []const u8, selected: ?[]const i32, seed: u64) !Chart {
        const data = try fs.readAlloc(gpa, path, 1 << 28);
        defer gpa.free(data);
        if (std.ascii.endsWithIgnoreCase(path, ".bmson")) return core.bmson.parse(gpa, data);
        return core.bms.parse(gpa, data, .{
            .is_pms = std.ascii.endsWithIgnoreCase(path, ".pms"),
            .selected_random = selected,
            .seed = seed,
        });
    }

    const LoadJob = struct {
        gpa: std.mem.Allocator,
        dir: []const u8,
        chart: *const Chart,
        samples: []decode.Sample,
        rate: u32,
        next: *std.atomic.Value(usize),
        progress: *std.atomic.Value(usize),
        failed: *std.atomic.Value(u32),
    };

    fn loadWorker(ud: ?*anyopaque) callconv(.c) c_int {
        const job: *LoadJob = @ptrCast(@alignCast(ud));
        // Heap, not a fixed buffer: resolving a differently cased name lists the whole folder.
        var arena = std.heap.ArenaAllocator.init(job.gpa);
        defer arena.deinit();
        while (true) {
            _ = arena.reset(.retain_capacity);
            const i = job.next.fetchAdd(1, .monotonic);
            if (i >= job.chart.wavs.len) return 0;
            defer _ = job.progress.fetchAdd(1, .monotonic);
            const p = fs.resolveAsset(arena.allocator(), job.dir, job.chart.wavs[i], audio_exts) catch null;
            if (p) |path| {
                const bytes = fs.readAlloc(job.gpa, path, 1 << 29) catch {
                    _ = job.failed.fetchAdd(1, .monotonic);
                    continue;
                };
                defer job.gpa.free(bytes);
                job.samples[i] = decode.decode(job.gpa, bytes, path, job.rate) catch blk: {
                    _ = job.failed.fetchAdd(1, .monotonic);
                    break :blk .{};
                };
            } else _ = job.failed.fetchAdd(1, .monotonic);
        }
    }

    /// Blocking: runs on a loader thread. `progress` counts decoded sounds.
    pub fn create(gpa: std.mem.Allocator, engine: *engine_mod.Engine, cfg: *const config.Config, params: Params, progress: *std.atomic.Value(usize), total: *std.atomic.Value(usize), parsed: *Parsed) !*Session {
        var chart = try parseFile(gpa, params.path, params.selected_random orelse if (params.replay) |r| r.bms_random else null, params.seed);
        errdefer chart.deinit();
        core.options.apply(&chart, params.random, params.seed);
        total.store(chart.wavs.len, .release);
        parsed.chart = chart;
        parsed.ready.store(true, .release);

        const samples = try gpa.alloc(decode.Sample, chart.wavs.len);
        errdefer gpa.free(samples);
        @memset(samples, .{});
        const dir = try gpa.dupe(u8, std.fs.path.dirname(params.path) orelse ".");
        errdefer gpa.free(dir);

        var next: std.atomic.Value(usize) = .init(0);
        var failed: std.atomic.Value(u32) = .init(0);
        var job: LoadJob = .{ .gpa = gpa, .dir = dir, .chart = &chart, .samples = samples, .rate = engine.rate, .next = &next, .progress = progress, .failed = &failed };
        var threads: [31]?*c.SDL_Thread = @splat(null);
        const extra: usize = @intCast(std.math.clamp(c.SDL_GetNumLogicalCPUCores() - 1, 0, threads.len));
        for (threads[0..extra]) |*t| t.* = c.SDL_CreateThread(loadWorker, "load", &job);
        _ = loadWorker(&job);
        for (threads) |t| if (t != null) c.SDL_WaitThread(t, null);

        // A chart can stop placing notes long before its music does: play on until the sound ends.
        chart.last_time_us = @max(chart.last_time_us, chartAudioEnd(&chart, samples, engine.rate));
        const sched = try buildSchedule(gpa, &chart, engine);
        errdefer gpa.free(sched);
        const sim = try Sim.create(gpa, &chart, .{ .gauge = params.gauge, .autoplay = params.autoplay, .gas = params.gas });
        errdefer sim.destroy();
        if (params.initial_gauge) |v| sim.gauges[@intFromEnum(params.gauge)].set(v);
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
            .params = params,
            .bind = config.bindings(cfg, chart.mode),
            .lock = c.SDL_CreateMutex() orelse return error.NoMutex,
            .end_us = chart.last_time_us + post_us,
            .load_warnings = failed.load(.monotonic),
        };
        s.sim.notes = s.chart.notes;
        try s.events.ensureTotalCapacity(gpa, chart.total_notes * 4 + 4096);
        return s;
    }

    fn buildSchedule(gpa: std.mem.Allocator, chart: *const Chart, e: *engine_mod.Engine) ![]engine_mod.Sched {
        const out = try gpa.alloc(engine_mod.Sched, chart.bg.len);
        for (chart.bg, out) |b, *o| o.* = .{
            .frame = e.usToFrame(b.time_us),
            .wav = b.wav,
            .start = @intCast(e.usToFrame(b.wav_start_us)),
            .len = @intCast(e.usToFrame(b.wav_dur_us)),
        };
        return out;
    }

    pub fn start(s: *Session) void {
        input.clear();
        const first = s.params.start_us - (if (s.params.start_us > 0) @as(i64, 0) else preroll_us);
        // Starting mid-chart is a preview: the sim catches up silently, the same way a seek does.
        if (s.params.start_us > 0) {
            s.sim.advance(s.params.start_us);
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
        // keep the stream ordered: replays and the sim both depend on it
        const t = @max(t_in, s.last_event_t);
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
        while (!s.quit.load(.acquire)) {
            const target = s.seek_to.swap(no_seek, .acq_rel);
            if (target != no_seek) s.doSeek(target, &snap);

            const paused = s.paused.load(.acquire);
            const now = if (paused) s.pause_t.load(.acquire) else s.songNow();
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
            s.sim.advance(now);

            const n = s.sim.drain(&out);
            for (out[0..n]) |o| switch (o.kind) {
                .sound => {
                    const note = s.chart.notes[@intCast(o.note)];
                    const startf: u32 = @intCast(s.engine.usToFrame(note.wav_start_us));
                    const lenf: u32 = @intCast(s.engine.usToFrame(note.wav_dur_us));
                    s.engine.play(o.wav, startf, lenf);
                },
                .stop_sound => s.engine.stopWav(o.wav),
                .judge => {
                    snap.hits[snap.hit_seq % hit_ring] = .{ .at_us = now, .fast_us = o.fast_us, .note = o.note, .judge = o.judge };
                    snap.hit_seq +%= 1;
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
            c.SDL_DelayPrecise(250_000);
        }
        return 0;
    }

    fn doSeek(s: *Session, target: i64, snap: *Snapshot) void {
        s.engine.seek(s.engine.usToFrame(target));
        @memset(s.sim.state, 0);
        const cfg: core.sim.Config = .{ .gauge = s.params.gauge, .autoplay = true, .gas = s.params.gas };
        const fresh = Sim.create(s.gpa, &s.chart, cfg) catch return;
        s.sim.destroy();
        s.sim = fresh;
        s.sim.advance(target);
        var sink: [256]core.sim.Out = undefined;
        while (s.sim.drain(&sink) > 0) {}
        snap.* = .{};
    }

    /// Snapshot plus per-note state, copied atomically into `dst`.
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

    /// Every note is judged by now, so only the rest of the music is left.
    pub fn canSkip(s: *const Session, snap: Snapshot) bool {
        return snap.time_us > s.chart.last_note_us + 1_000_000;
    }

    pub fn clear(s: *Session) core.types.Clear {
        return s.sim.clear(s.snapshot().finished and !s.sim.failed);
    }

    pub fn replayBytes(s: *Session) ![]u8 {
        return core.replay.encode(s.gpa, .{
            .sha256 = s.chart.sha256,
            .gauge = s.params.gauge,
            .gas = s.params.gas,
            .random = s.params.random,
            .seed = s.params.seed,
            .bms_random = s.chart.random,
            .events = s.events.items,
        });
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
        s.chart.deinit();
        c.SDL_DestroyMutex(s.lock);
        s.gpa.destroy(s);
    }
};

/// Song time at which a sound started at `time_us` stops playing.
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

test "sound end honours slices and missing samples" {
    var data: [8000]f32 = @splat(0); // 4000 stereo frames: 1 s at 4 kHz
    const samples = [_]decode.Sample{.{ .data = &data }};
    try std.testing.expectEqual(@as(i64, 6_000_000), soundEnd(5_000_000, 0, 0, 0, &samples, 4000));
    try std.testing.expectEqual(@as(i64, 5_250_000), soundEnd(5_000_000, 0, 500_000, 250_000, &samples, 4000));
    try std.testing.expectEqual(@as(i64, 5_500_000), soundEnd(5_000_000, 0, 500_000, 9_000_000, &samples, 4000));
    try std.testing.expectEqual(@as(i64, 5_000_000), soundEnd(5_000_000, -1, 0, 0, &samples, 4000));
}
