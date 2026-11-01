//! Audio output and mixer. The writer thread owns all voices: game threads talk to it through a
//! wait-free queue, and scheduled background notes are started sample-accurately inside the buffer.
//! The writer thread never allocates, locks or touches the disk.
const std = @import("std");
const c = @import("c");
const builtin = @import("builtin");
const decode = @import("decode.zig");

pub const max_voices = 256;
/// Largest buffer the settings allow.
const feed_max = 4096;
pub const ui_slots = 11;
/// Menu music takes turns on these, so the old track can fade under the new one. Three because a
/// new track can start before the last fade ended.
pub const menu_slots = 3;
pub const decide_slot = menu_slots;
pub const first_oneshot_slot = decide_slot + 1;

pub const Sched = struct { frame: i64, wav: i32, start: u32 = 0, len: u32 = 0 };

const Voice = struct {
    data: []const f32 = &.{}, // stereo interleaved
    pos: usize = 0,
    delay: u32 = 0, // frames into the next buffer
    gain: f32 = 1,
    wav: i32 = -1,
};

/// Menu layer: keeps playing while the song side is paused, and never touches the song clock.
const UiVoice = struct {
    data: []const f32 = &.{},
    pos: usize = 0,
    loop: bool = false,
    gain: f32 = 0,
    target: f32 = 0,
};

const Cmd = union(enum) {
    ui_play: struct { slot: u8, data: []const f32, loop: bool, gain: f32 },
    ui_gain: struct { slot: u8, gain: f32 },
    play: struct { wav: i32, start: u32, len: u32 },
    stop_wav: i32,
    stop_all,
    seek: i64,
    set_paused: bool,
};

pub const HostInfo = struct { name: [64]u8 = @splat(0), latency_ms: f64 = 0, exclusive: bool = false };

pub const Engine = struct {
    gpa: std.mem.Allocator,
    rate: u32 = 48000,
    stream: ?*c.PaStream = null,
    samples: []const decode.Sample = &.{},
    schedule: []const Sched = &.{},
    sched_pos: usize = 0,
    voices: [max_voices]Voice = @splat(.{}),
    ui_voices: [ui_slots]UiVoice = @splat(.{}),
    /// Song position of the first sample of the next buffer.
    frame: std.atomic.Value(i64) = .init(0),
    running: std.atomic.Value(bool) = .init(false),
    paused: bool = false,
    cmd_buf: [4096]Cmd = undefined,
    cmd_head: std.atomic.Value(u32) = .init(0),
    cmd_tail: std.atomic.Value(u32) = .init(0),
    gain: f32 = 1,
    /// Clock offset (song µs - monotonic µs), smoothed; the writer thread is the only writer.
    clock_offset_us: std.atomic.Value(i64) = .init(0),
    clock_valid: std.atomic.Value(bool) = .init(false),
    host: HostInfo = .{},
    /// Drives the mixer, writing to `stream` or, on the null output, only keeping time.
    feed_thread: ?*c.SDL_Thread = null,
    feed_frames: u32 = 0,
    feed_quit: std.atomic.Value(bool) = .init(false),
    pa_ready: bool = false,
    /// What `open` was asked for, not necessarily what opened. Must outlive the engine.
    device: []const u8 = "",

    pub fn create(gpa: std.mem.Allocator) !*Engine {
        const e = try gpa.create(Engine);
        e.* = .{ .gpa = gpa };
        return e;
    }

    pub fn destroy(e: *Engine) void {
        e.close();
        if (e.pa_ready) _ = c.Pa_Terminate();
        e.gpa.destroy(e);
    }

    fn nameOf(ty: c.PaHostApiTypeId) [:0]const u8 {
        return switch (ty) {
            c.paASIO => "ASIO",
            c.paWASAPI => "WASAPI",
            c.paCoreAudio => "CoreAudio",
            c.paJACK => "JACK",
            c.paALSA => "ALSA",
            else => "other",
        };
    }

    /// Opens the lowest-latency path available. Windows order is ASIO, WASAPI exclusive, then WASAPI
    /// shared as the mandatory fallback; Linux prefers JACK (including PipeWire's) then ALSA.
    /// A named ALSA `device` comes first; if it is gone or refuses, the usual order still gives sound.
    pub fn open(e: *Engine, want_rate: u32, frames: u32, prefer_null: bool, device: []const u8) !void {
        e.rate = want_rate;
        e.device = device;
        if (prefer_null) return e.openNull();
        if (!e.pa_ready) {
            if (c.Pa_Initialize() != c.paNoError) return e.openNull();
            e.pa_ready = true;
        }
        if (device.len > 0) {
            if (alsaDevice(device)) |dev| {
                if (e.tryOpen(c.paALSA, dev, want_rate, frames, false)) return;
            }
            std.log.warn("audio device \"{s}\" did not open, using the default", .{device});
        }
        const order: []const c.PaHostApiTypeId = switch (builtin.os.tag) {
            .windows => &.{ c.paASIO, c.paWASAPI },
            .macos => &.{c.paCoreAudio},
            // PortAudio's JACK backend only links to physical ports, so through PipeWire's JACK layer
            // it stays silent whenever the default sink is virtual. ALSA follows the default sink.
            else => if (pipewireRunning()) &.{ c.paALSA, c.paJACK } else &.{ c.paJACK, c.paALSA },
        };
        for (order) |ty| {
            const index = c.Pa_HostApiTypeIdToHostApiIndex(ty);
            if (index < 0) continue;
            const info = c.Pa_GetHostApiInfo(index);
            if (info == null or info.*.defaultOutputDevice < 0) continue;
            if (e.tryOpen(ty, info.*.defaultOutputDevice, want_rate, frames, true)) return;
            if (ty == c.paWASAPI and e.tryOpen(ty, info.*.defaultOutputDevice, want_rate, frames, false)) return;
            if (ty != c.paWASAPI and e.tryOpen(ty, info.*.defaultOutputDevice, want_rate, frames, false)) return;
        }
        const dev = c.Pa_GetDefaultOutputDevice();
        if (dev >= 0 and e.tryOpen(c.paInDevelopment, dev, want_rate, frames, false)) return;
        return e.openNull();
    }

    /// Moves to another output, keeping the rate that loaded sounds were decoded at. Not during play:
    /// the song clock would jump. Does nothing under --null-audio or when `device` is already asked for.
    pub fn switchDevice(e: *Engine, frames: u32, device: []const u8) void {
        if (!e.pa_ready or std.mem.eql(u8, e.device, device)) return;
        e.close();
        e.open(e.rate, frames, false, device) catch |err| std.log.err("audio reopen failed: {t}", .{err});
    }

    fn alsaOutput(dev: c.PaDeviceIndex) ?[]const u8 {
        const info = c.Pa_GetDeviceInfo(dev);
        if (info == null or info.*.maxOutputChannels < 2) return null;
        if (info.*.hostApi != c.Pa_HostApiTypeIdToHostApiIndex(c.paALSA)) return null;
        return std.mem.span(info.*.name);
    }

    fn alsaDevice(name: []const u8) ?c.PaDeviceIndex {
        var dev: c.PaDeviceIndex = 0;
        while (dev < c.Pa_GetDeviceCount()) : (dev += 1) {
            if (std.mem.eql(u8, alsaOutput(dev) orelse continue, name)) return dev;
        }
        return null;
    }

    /// Names of the stereo ALSA outputs, owned by PortAudio. Empty when it never started.
    pub fn alsaDevices(e: *const Engine, a: std.mem.Allocator) []const []const u8 {
        if (!e.pa_ready) return &.{};
        var names: std.ArrayList([]const u8) = .empty;
        var dev: c.PaDeviceIndex = 0;
        while (dev < c.Pa_GetDeviceCount()) : (dev += 1) {
            names.append(a, alsaOutput(dev) orelse continue) catch return &.{};
        }
        return names.items;
    }

    fn pipewireRunning() bool {
        const dir = std.c.getenv("XDG_RUNTIME_DIR") orelse return false;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&buf, "{s}/pipewire-0", .{std.mem.span(dir)}, 0) catch return false;
        return std.c.access(path, 0) == 0;
    }

    fn tryOpen(e: *Engine, ty: c.PaHostApiTypeId, dev: c.PaDeviceIndex, rate: u32, frames: u32, exclusive: bool) bool {
        const dinfo = c.Pa_GetDeviceInfo(dev);
        if (dinfo == null) return false;
        var out: c.PaStreamParameters = .{
            .device = dev,
            .channelCount = 2,
            .sampleFormat = c.paFloat32,
            .suggestedLatency = dinfo.*.defaultLowOutputLatency,
            .hostApiSpecificStreamInfo = null,
        };
        if (builtin.os.tag == .windows) {
            if (ty == c.paWASAPI and exclusive) {
                var wasapi: c.PaWasapiStreamInfo = std.mem.zeroes(c.PaWasapiStreamInfo);
                wasapi.size = @sizeOf(c.PaWasapiStreamInfo);
                wasapi.hostApiType = c.paWASAPI;
                wasapi.version = 1;
                wasapi.flags = c.paWinWasapiExclusive | c.paWinWasapiThreadPriority;
                wasapi.threadPriority = c.eThreadPriorityProAudio;
                out.hostApiSpecificStreamInfo = &wasapi;
                return e.startStream(ty, &out, rate, frames, true);
            }
        } else if (exclusive) return false;
        return e.startStream(ty, &out, rate, frames, false);
    }

    /// Blocking writes, not a callback: some ioplug PCMs, such as sidealsa_pro, accept a callback
    /// stream and then never run the callback, while writes to them keep real time.
    fn startStream(e: *Engine, ty: c.PaHostApiTypeId, out: *c.PaStreamParameters, rate: u32, frames: u32, exclusive: bool) bool {
        var stream: ?*c.PaStream = null;
        const err = c.Pa_OpenStream(&stream, null, out, @floatFromInt(rate), @min(frames, feed_max), c.paClipOff | c.paDitherOff, null, null);
        if (err != c.paNoError) return false;
        if (c.Pa_StartStream(stream) != c.paNoError) {
            _ = c.Pa_CloseStream(stream);
            return false;
        }
        e.stream = stream;
        e.feed_frames = @min(frames, feed_max);
        const info = c.Pa_GetStreamInfo(stream);
        e.host = .{ .latency_ms = if (info != null) info.*.outputLatency * 1000 else 0, .exclusive = exclusive };
        const n = nameOf(ty);
        @memcpy(e.host.name[0..n.len], n);
        e.feed_quit.store(false, .release);
        e.running.store(true, .release);
        e.feed_thread = c.SDL_CreateThread(writeThread, "audio-write", e);
        return true;
    }

    fn writeThread(ud: ?*anyopaque) callconv(.c) c_int {
        const e: *Engine = @ptrCast(@alignCast(ud));
        _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_TIME_CRITICAL);
        var buf: [feed_max * 2]f32 = undefined;
        const frames = e.feed_frames;
        const buffer_s = @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(e.rate));
        const latency_s = e.host.latency_ms / 1000;
        while (!e.feed_quit.load(.acquire)) {
            e.mix(&buf, frames);
            if (!e.paused) e.updateClock(latency_s + buffer_s);
            const err = c.Pa_WriteStream(e.stream, &buf, frames);
            if (err != c.paNoError and err != c.paOutputUnderflowed) c.SDL_Delay(1);
        }
        return 0;
    }

    fn openNull(e: *Engine) !void {
        const n = "none";
        @memcpy(e.host.name[0..n.len], n);
        e.feed_quit.store(false, .release);
        e.feed_thread = c.SDL_CreateThread(nullThread, "audio-null", e);
        e.running.store(true, .release);
    }

    fn nullThread(ud: ?*anyopaque) callconv(.c) c_int {
        const e: *Engine = @ptrCast(@alignCast(ud));
        var buf: [512 * 2]f32 = undefined;
        var next = c.SDL_GetTicksNS();
        while (!e.feed_quit.load(.acquire)) {
            const now = c.SDL_GetTicksNS();
            if (now < next) {
                c.SDL_DelayNS(next - now);
                continue;
            }
            e.mix(&buf, 512);
            e.updateClock(0);
            next += @as(u64, 512) * 1_000_000_000 / e.rate;
        }
        return 0;
    }

    pub fn close(e: *Engine) void {
        e.running.store(false, .release);
        // The writer uses the stream, so it stops first.
        if (e.feed_thread) |t| {
            e.feed_quit.store(true, .release);
            c.SDL_WaitThread(t, null);
            e.feed_thread = null;
        }
        if (e.stream) |s| {
            _ = c.Pa_StopStream(s);
            _ = c.Pa_CloseStream(s);
            e.stream = null;
        }
    }

    /// Installs sounds and schedule for a song. Must not race the writer thread, so it pauses first.
    pub fn load(e: *Engine, samples: []const decode.Sample, schedule: []const Sched, start_frame: i64) void {
        e.push(.{ .set_paused = true });
        // The writer thread only reads these while unpaused; give it a chance to observe the pause.
        var waited: u32 = 0;
        while (e.cmd_tail.load(.acquire) != e.cmd_head.load(.acquire) and waited < 200) : (waited += 1) c.SDL_Delay(1);
        c.SDL_Delay(2 + @as(u32, 2048) * 1000 / e.rate);
        e.samples = samples;
        e.schedule = schedule;
        e.sched_pos = 0;
        for (&e.voices) |*v| v.* = .{};
        e.frame.store(start_frame, .release);
        e.clock_valid.store(false, .release);
    }

    pub fn start(e: *Engine) void {
        e.push(.{ .set_paused = false });
    }

    pub fn pause(e: *Engine, p: bool) void {
        // The offset ties song time to the wall clock, which kept running: anchor it again.
        if (!p) e.clock_valid.store(false, .release);
        e.push(.{ .set_paused = p });
    }

    fn push(e: *Engine, cmd: Cmd) void {
        const h = e.cmd_head.load(.monotonic);
        if (h -% e.cmd_tail.load(.acquire) >= e.cmd_buf.len) return;
        e.cmd_buf[h % e.cmd_buf.len] = cmd;
        e.cmd_head.store(h +% 1, .release);
    }

    pub fn play(e: *Engine, wav: i32, start_frame: u32, len: u32) void {
        e.push(.{ .play = .{ .wav = wav, .start = start_frame, .len = len } });
    }
    pub fn stopWav(e: *Engine, wav: i32) void {
        e.push(.{ .stop_wav = wav });
    }
    pub fn stopAll(e: *Engine) void {
        e.push(.stop_all);
    }
    pub fn seek(e: *Engine, frame: i64) void {
        e.push(.{ .seek = frame });
    }

    /// `data` must outlive the engine. A looping sound fades in; a one-shot starts at full gain.
    pub fn uiPlay(e: *Engine, slot: u8, data: []const f32, loop: bool, gain: f32) void {
        e.push(.{ .ui_play = .{ .slot = slot, .data = data, .loop = loop, .gain = gain } });
    }
    /// Fades the slot to `gain`; a slot that reaches zero stops.
    pub fn uiGain(e: *Engine, slot: u8, gain: f32) void {
        e.push(.{ .ui_gain = .{ .slot = slot, .gain = gain } });
    }

    fn mixUi(e: *Engine, out: [*]f32, frames: usize) void {
        // A full fade takes one second.
        const step = 1 / @as(f32, @floatFromInt(e.rate));
        for (&e.ui_voices) |*v| {
            for (0..frames) |i| {
                if (v.data.len == 0) break;
                if (v.pos >= v.data.len) {
                    if (!v.loop) {
                        v.data = &.{};
                        break;
                    }
                    v.pos = 0;
                }
                v.gain += std.math.clamp(v.target - v.gain, -step, step);
                if (v.gain <= 0 and v.target <= 0) {
                    v.data = &.{};
                    break;
                }
                out[i * 2] += v.data[v.pos] * v.gain * e.gain;
                out[i * 2 + 1] += v.data[v.pos + 1] * v.gain * e.gain;
                v.pos += 2;
            }
        }
    }

    fn startVoice(e: *Engine, wav: i32, start_frame: u32, len: u32, delay: u32) void {
        if (wav < 0 or wav >= e.samples.len) return;
        const data = e.samples[@intCast(wav)].data;
        const begin: usize = @min(@as(usize, start_frame) * 2, data.len);
        const end: usize = if (len > 0) @min(begin + @as(usize, len) * 2, data.len) else data.len;
        if (begin >= end) return;
        // Retrigger of the same keysound replaces its voice, as in LR2/beatoraja.
        var slot: ?*Voice = null;
        var oldest: ?*Voice = null;
        for (&e.voices) |*v| {
            if (v.data.len == 0) {
                if (slot == null) slot = v;
            } else if (v.wav == wav) {
                slot = v;
                break;
            } else if (oldest == null or v.pos > oldest.?.pos) oldest = v;
        }
        const v = slot orelse oldest orelse return;
        v.* = .{ .data = data[begin..end], .wav = wav, .delay = delay };
    }

    fn processCmds(e: *Engine) void {
        var t = e.cmd_tail.load(.monotonic);
        const h = e.cmd_head.load(.acquire);
        while (t != h) : (t +%= 1) {
            switch (e.cmd_buf[t % e.cmd_buf.len]) {
                .play => |p| if (!e.paused) e.startVoice(p.wav, p.start, p.len, 0),
                .stop_wav => |w| for (&e.voices) |*v| {
                    if (v.wav == w) v.data = &.{};
                },
                .stop_all => for (&e.voices) |*v| {
                    v.data = &.{};
                },
                .seek => |f| {
                    for (&e.voices) |*v| v.data = &.{};
                    e.frame.store(f, .release);
                    var lo: usize = 0;
                    var hi: usize = e.schedule.len;
                    while (lo < hi) {
                        const mid = (lo + hi) / 2;
                        if (e.schedule[mid].frame < f) lo = mid + 1 else hi = mid;
                    }
                    e.sched_pos = lo;
                    e.clock_valid.store(false, .release);
                },
                .set_paused => |p| e.paused = p,
                .ui_play => |p| e.ui_voices[p.slot] = .{ .data = p.data, .loop = p.loop, .gain = if (p.loop) 0 else p.gain, .target = p.gain },
                .ui_gain => |p| e.ui_voices[p.slot].target = p.gain,
            }
        }
        e.cmd_tail.store(t, .release);
    }

    fn mix(e: *Engine, out: [*]f32, frames: usize) void {
        @memset(out[0 .. frames * 2], 0);
        e.processCmds();
        e.mixUi(out, frames);
        if (e.paused) return;
        const f0 = e.frame.load(.monotonic);
        const f1 = f0 + @as(i64, @intCast(frames));
        while (e.sched_pos < e.schedule.len and e.schedule[e.sched_pos].frame < f1) : (e.sched_pos += 1) {
            const s = e.schedule[e.sched_pos];
            const delay: u32 = if (s.frame > f0) @intCast(s.frame - f0) else 0;
            e.startVoice(s.wav, s.start, s.len, delay);
        }
        for (&e.voices) |*v| {
            if (v.data.len == 0) continue;
            const skip: usize = @min(v.delay, frames);
            v.delay -= @intCast(skip);
            const avail = (v.data.len - v.pos) / 2;
            const n = @min(frames - skip, avail);
            const src = v.data[v.pos..][0 .. n * 2];
            const dst = out[skip * 2 ..][0 .. n * 2];
            const g = v.gain * e.gain;
            for (dst, src) |*d, s| d.* += s * g;
            v.pos += n * 2;
            if (v.pos >= v.data.len) v.data = &.{};
        }
        // Soft clip only when needed: a dense chart routinely sums past full scale.
        for (out[0 .. frames * 2]) |*s| {
            const x = s.*;
            if (x > 1 or x < -1) s.* = std.math.clamp(x, -1.5, 1.5) * (1 - std.math.clamp(x, -1.5, 1.5) * std.math.clamp(x, -1.5, 1.5) / 6.75);
        }
        e.frame.store(f1, .release);
    }

    fn updateClock(e: *Engine, dac_delay_s: f64) void {
        // Song time of what the listener hears right now, relative to the shared monotonic clock.
        const now_us: i64 = @intCast(c.SDL_GetTicksNS() / 1000);
        const f = e.frame.load(.monotonic);
        const song_us = @divTrunc(f * 1_000_000, e.rate);
        const raw = song_us - @as(i64, @intFromFloat(dac_delay_s * 1e6)) - now_us;
        if (!e.clock_valid.load(.monotonic)) {
            e.clock_offset_us.store(raw, .release);
            e.clock_valid.store(true, .release);
            return;
        }
        // Writer wake-up jitter is the noise here; the mean is what's true.
        const prev = e.clock_offset_us.load(.monotonic);
        e.clock_offset_us.store(prev + @divTrunc(raw - prev, 32), .release);
    }

    /// Converts a monotonic timestamp to song time.
    pub fn toSongUs(e: *const Engine, mono_ns: u64) i64 {
        return @as(i64, @intCast(mono_ns / 1000)) + e.clock_offset_us.load(.acquire);
    }

    pub fn clockReady(e: *const Engine) bool {
        return e.clock_valid.load(.acquire);
    }

    pub fn usToFrame(e: *const Engine, us: i64) i64 {
        return @divFloor(us * e.rate, 1_000_000);
    }
};

test "mixer schedules sample accurately" {
    const gpa = std.testing.allocator;
    const e = try Engine.create(gpa);
    defer e.destroy();
    const data = [_]f32{ 1, 1, 0.5, 0.5 };
    const samples = [_]decode.Sample{.{ .data = @constCast(&data) }};
    const sched = [_]Sched{.{ .frame = 10, .wav = 0 }};
    e.samples = &samples;
    e.schedule = &sched;
    var out: [40]f32 = undefined;
    e.mix(&out, 8);
    for (out[0..16]) |s| try std.testing.expectEqual(@as(f32, 0), s);
    e.mix(&out, 8); // frames 8..15: the note starts 2 frames in
    try std.testing.expectEqual(@as(f32, 0), out[2]);
    try std.testing.expectEqual(@as(f32, 1), out[4]);
    try std.testing.expectEqual(@as(f32, 0.5), out[6]);
    try std.testing.expectEqual(@as(f32, 0), out[8]);
}

test "menu layer plays while paused and leaves the song clock alone" {
    const e = try Engine.create(std.testing.allocator);
    defer e.destroy();
    const data = [_]f32{ 1, 1, 0.5, 0.5 };
    e.paused = true;
    e.uiPlay(1, &data, false, 1);
    var out: [8]f32 = undefined;
    e.mix(&out, 4);
    try std.testing.expectEqual(@as(f32, 1), out[0]);
    try std.testing.expectEqual(@as(f32, 0.5), out[2]);
    try std.testing.expectEqual(@as(f32, 0), out[4]);
    try std.testing.expectEqual(@as(i64, 0), e.frame.load(.monotonic));
    // The fade-out of a loop ends by stopping it.
    e.rate = 2;
    e.uiPlay(0, &data, true, 1);
    e.mix(&out, 4);
    try std.testing.expect(out[0] > 0);
    e.uiGain(0, 0);
    e.mix(&out, 4);
    try std.testing.expectEqual(@as(usize, 0), e.ui_voices[0].data.len);
    // Two slots crossfade: the old one still sounds as the new one comes in.
    e.rate = 4;
    e.uiPlay(0, &data, true, 1);
    e.mix(&out, 4);
    e.uiGain(0, 0);
    e.uiPlay(1, &data, true, 1);
    e.mix(&out, 1);
    try std.testing.expect(e.ui_voices[0].gain > 0 and e.ui_voices[1].gain > 0);
}
