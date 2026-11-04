//! Audio output and mixer. The writer thread owns all voices: game threads talk to it through a
//! wait-free queue, and scheduled background notes are started sample-accurately inside the buffer.
//! The writer thread never allocates, locks or touches the disk.
const std = @import("std");
const c = @import("c");
const builtin = @import("builtin");
const decode = @import("decode.zig");
const alsa = @import("alsa.zig");

pub const max_voices = 256;
/// Largest buffer the settings allow.
const feed_max = 4096;
const device_key_max = 512;
/// Song frames one output buffer can consume: `feed_max` plus the largest slew.
const song_max = feed_max + feed_max / 256 + 1;
/// Slew at most one frame per this many: 0.4%, about 7 cents.
const slew_period = 256;
/// Audio this close to the tick clock is left alone, so jitter cannot wobble the pitch.
const sync_deadband_us = 2_000;
/// Audio further behind than this, such as after an underrun, skips instead of slewing.
const sync_skip_us = 50_000;
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
    paused: bool = false,
    cmd_buf: [4096]Cmd = undefined,
    cmd_head: std.atomic.Value(u32) = .init(0),
    cmd_tail: std.atomic.Value(u32) = .init(0),
    /// The sim and UI threads both send commands, and the ring takes one producer at a time.
    cmd_lock: std.atomic.Value(bool) = .init(false),
    gain: f32 = 1,
    /// Tick clock (song µs - monotonic µs), fixed once settled; the writer thread is the only writer.
    clock_offset_us: std.atomic.Value(i64) = .init(0),
    clock_valid: std.atomic.Value(bool) = .init(false),
    // Audio sync state, writer thread only.
    settle_frames: i64 = 0,
    audio_err_us: i64 = 0,
    slew: i64 = 0,
    slew_carry: u32 = 0,
    skip_frames: i64 = 0,
    song_buf: [song_max * 2]f32 = undefined,
    host: HostInfo = .{},
    /// Drives the mixer, writing to `stream` or, on the null output, only keeping time.
    feed_thread: ?*c.SDL_Thread = null,
    feed_frames: u32 = 0,
    feed_quit: std.atomic.Value(bool) = .init(false),
    pa_ready: bool = false,
    alsa_out: if (builtin.os.tag == .linux) ?alsa.Out else void = if (builtin.os.tag == .linux) null else {},
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
    /// shared as the mandatory fallback; Linux is in `openLinux`.
    /// A named `device` comes first; if it is gone or refuses, the usual order still gives sound.
    pub fn open(e: *Engine, want_rate: u32, frames: u32, prefer_null: bool, device: []const u8) !void {
        e.rate = want_rate;
        e.device = device;
        if (prefer_null) return e.openNull();
        if (!e.pa_ready) {
            if (c.Pa_Initialize() != c.paNoError) return e.openNull();
            e.pa_ready = true;
        }
        if (builtin.os.tag == .linux) return e.openLinux(frames, device);
        if (device.len > 0) {
            if (namedDevice(device)) |dev| {
                if (e.openOn(c.Pa_GetHostApiInfo(c.Pa_GetDeviceInfo(dev).*.hostApi).*.type, dev, want_rate, frames)) return;
            }
            std.log.warn("audio device \"{s}\" did not open, using the default", .{device});
        }
        const order: []const c.PaHostApiTypeId = switch (builtin.os.tag) {
            .windows => &.{ c.paASIO, c.paWASAPI },
            else => &.{c.paCoreAudio},
        };
        for (order) |ty| if (e.openDefaultOf(ty, frames)) return;
        const dev = c.Pa_GetDefaultOutputDevice();
        if (dev >= 0 and e.tryOpen(c.paInDevelopment, dev, want_rate, frames, false)) return;
        return e.openNull();
    }

    /// ALSA through libasound, with JACK from PortAudio. A named device is always ALSA.
    fn openLinux(e: *Engine, frames: u32, device: []const u8) !void {
        if (device.len > 0) {
            if (e.openAlsa(alsa.fromPortAudioName(device), frames)) return;
            std.log.warn("audio device \"{s}\" did not open, using the default", .{device});
        }
        // PortAudio's JACK backend only links to physical ports, so through PipeWire's JACK layer
        // it stays silent whenever the default sink is virtual. ALSA follows the default sink.
        const jack_first = !pipewireRunning();
        if (jack_first and e.openDefaultOf(c.paJACK, frames)) return;
        if (e.openAlsa("default", frames)) return;
        if (!jack_first and e.openDefaultOf(c.paJACK, frames)) return;
        return e.openNull();
    }

    fn openDefaultOf(e: *Engine, ty: c.PaHostApiTypeId, frames: u32) bool {
        const index = c.Pa_HostApiTypeIdToHostApiIndex(ty);
        if (index < 0) return false;
        const info = c.Pa_GetHostApiInfo(index);
        if (info == null or info.*.defaultOutputDevice < 0) return false;
        return e.openOn(ty, info.*.defaultOutputDevice, e.rate, frames);
    }

    fn openAlsa(e: *Engine, name: []const u8, frames: u32) bool {
        const out = alsa.Out.open(name, e.rate, frames, feed_max) orelse return false;
        e.alsa_out = out;
        e.feed_frames = out.period;
        e.host = .{ .latency_ms = out.lead_s * 1000, .exclusive = std.mem.startsWith(u8, name, "hw:") };
        @memcpy(e.host.name[0.."ALSA".len], "ALSA");
        e.feed_quit.store(false, .release);
        e.feed_thread = c.SDL_CreateThread(alsaThread, "audio-write", e);
        return true;
    }

    /// Mixes each period only once the device has room for it: a block mixed early sits a period in the write.
    fn alsaThread(ud: ?*anyopaque) callconv(.c) c_int {
        const e: *Engine = @ptrCast(@alignCast(ud));
        raiseAudioPriority();
        const out = &e.alsa_out.?;
        var buf: [feed_max * 2]f32 = undefined;
        var scratch: [feed_max * alsa.max_channels * 4]u8 = undefined;
        while (!e.feed_quit.load(.acquire)) {
            if (!out.waitRoom()) continue;
            e.mix(&buf, out.period);
            if (!e.paused) e.updateClock(out.lead_s, out.period);
            out.write(buf[0 .. out.period * 2], &scratch);
        }
        return 0;
    }

    /// Reopens on another output or buffer size, keeping the rate that loaded sounds were decoded at.
    /// Not during play: the song clock would jump. Does nothing under --null-audio or when nothing changed.
    pub fn reopen(e: *Engine, frames: u32, device: []const u8) void {
        if (!e.pa_ready or (std.mem.eql(u8, e.device, device) and @min(frames, feed_max) == e.feed_frames)) return;
        e.close();
        e.open(e.rate, frames, false, device) catch |err| std.log.err("audio reopen failed: {t}", .{err});
    }

    /// Exclusive first where the platform has it, then shared.
    fn openOn(e: *Engine, ty: c.PaHostApiTypeId, dev: c.PaDeviceIndex, rate: u32, frames: u32) bool {
        return e.tryOpen(ty, dev, rate, frames, true) or e.tryOpen(ty, dev, rate, frames, false);
    }

    /// The name a config stores. Windows lists one card under each API, so there the API is part of it.
    fn deviceKey(buf: []u8, os: std.Target.Os.Tag, ty: c.PaHostApiTypeId, name: []const u8) ?[]const u8 {
        if (os == .windows) return std.fmt.bufPrint(buf, "{s}: {s}", .{ nameOf(ty), name }) catch null;
        return if (name.len <= buf.len) name else null;
    }

    fn outputKey(buf: []u8, dev: c.PaDeviceIndex) ?[]const u8 {
        const info = c.Pa_GetDeviceInfo(dev);
        if (info == null or info.*.maxOutputChannels < 2) return null;
        const api = c.Pa_GetHostApiInfo(info.*.hostApi);
        if (api == null) return null;
        const offered: []const c.PaHostApiTypeId = switch (builtin.os.tag) {
            .windows => &.{ c.paASIO, c.paWASAPI },
            else => &.{c.paCoreAudio},
        };
        if (std.mem.indexOfScalar(c.PaHostApiTypeId, offered, api.*.type) == null) return null;
        return deviceKey(buf, builtin.os.tag, api.*.type, std.mem.span(info.*.name));
    }

    fn namedDevice(name: []const u8) ?c.PaDeviceIndex {
        var buf: [device_key_max]u8 = undefined;
        var dev: c.PaDeviceIndex = 0;
        while (dev < c.Pa_GetDeviceCount()) : (dev += 1) {
            if (std.mem.eql(u8, outputKey(&buf, dev) orelse continue, name)) return dev;
        }
        return null;
    }

    /// Names of the stereo outputs. Empty when PortAudio never started.
    pub fn outputDevices(e: *const Engine, a: std.mem.Allocator) []const []const u8 {
        if (!e.pa_ready) return &.{};
        if (builtin.os.tag == .linux) return alsa.outputNames(a);
        var names: std.ArrayList([]const u8) = .empty;
        var buf: [device_key_max]u8 = undefined;
        var dev: c.PaDeviceIndex = 0;
        while (dev < c.Pa_GetDeviceCount()) : (dev += 1) {
            const key = a.dupe(u8, outputKey(&buf, dev) orelse continue) catch return &.{};
            names.append(a, key) catch return &.{};
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
            // PortAudio's ASIO sizes the driver buffer from the suggested latency, so the default
            // one kept the driver's preferred size whatever Buffer size said.
            if (ty == c.paASIO) out.suggestedLatency = @as(f64, @floatFromInt(frames)) / @as(f64, @floatFromInt(rate));
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

    /// A callback, not blocking writes: at 32 or 64 frames a period is under 1.5 ms, less than a
    /// polling thread can count on waking in. Linux ALSA, whose ioplug PCMs may never run a
    /// callback, has its own writer in `alsaThread`.
    fn startStream(e: *Engine, ty: c.PaHostApiTypeId, out: *c.PaStreamParameters, rate: u32, frames: u32, exclusive: bool) bool {
        var stream: ?*c.PaStream = null;
        const err = c.Pa_OpenStream(&stream, null, out, @floatFromInt(rate), @min(frames, feed_max), c.paClipOff | c.paDitherOff, paCallback, e);
        if (err != c.paNoError) return false;
        // Set before the start: the callback reads the latency from its first buffer.
        e.feed_frames = @min(frames, feed_max);
        const info = c.Pa_GetStreamInfo(stream);
        e.host = .{ .latency_ms = if (info != null) info.*.outputLatency * 1000 else 0, .exclusive = exclusive };
        const n = nameOf(ty);
        @memcpy(e.host.name[0..n.len], n);
        if (c.Pa_StartStream(stream) != c.paNoError) {
            _ = c.Pa_CloseStream(stream);
            e.host = .{};
            return false;
        }
        e.stream = stream;
        return true;
    }

    /// Runs on the host API's audio thread, which already outranks the game's own.
    fn paCallback(_: ?*const anyopaque, out: ?*anyopaque, count: c_ulong, _: [*c]const c.PaStreamCallbackTimeInfo, _: c.PaStreamCallbackFlags, ud: ?*anyopaque) callconv(.c) c_int {
        const e: *Engine = @ptrCast(@alignCast(ud));
        const frames: u32 = @intCast(count);
        e.mix(@ptrCast(@alignCast(out.?)), frames);
        if (!e.paused) e.updateClock(e.host.latency_ms / 1000, frames);
        return c.paContinue;
    }

    /// Every block must be ready within one period, so this thread outranks everything else the game runs.
    /// SDL's time-critical is only a nice level here; realtime comes through rtkit when the system allows it.
    fn raiseAudioPriority() void {
        const rr: c_int = @backingInt(std.os.linux.SCHED.Mode.RR);
        if (c.SDL_SetLinuxThreadPriorityAndPolicy(std.os.linux.gettid(), c.SDL_THREAD_PRIORITY_TIME_CRITICAL, rr)) return;
        std.log.warn("audio thread stays non-realtime: {s}", .{std.mem.span(c.SDL_GetError())});
        _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_TIME_CRITICAL);
    }

    fn openNull(e: *Engine) !void {
        const n = "none";
        @memcpy(e.host.name[0..n.len], n);
        e.feed_quit.store(false, .release);
        e.feed_thread = c.SDL_CreateThread(nullThread, "audio-null", e);
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
            if (!e.paused) e.updateClock(0, 512);
            next += @as(u64, 512) * 1_000_000_000 / e.rate;
        }
        return 0;
    }

    pub fn close(e: *Engine) void {
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
        if (builtin.os.tag == .linux) if (e.alsa_out) |*o| {
            o.close();
            e.alsa_out = null;
        };
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
        while (e.cmd_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer e.cmd_lock.store(false, .release);
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
        // Skipping through the mixer keeps scheduled notes and voice positions right.
        while (e.skip_frames > 0) {
            const n: usize = @intCast(@min(e.skip_frames, feed_max));
            e.mixSong(n);
            e.skip_frames -= @intCast(n);
        }
        const n: usize = @intCast(@as(i64, @intCast(frames)) + e.slew);
        e.mixSong(n);
        e.addSong(out, frames, n);
        // Soft clip only when needed: a dense chart routinely sums past full scale.
        for (out[0 .. frames * 2]) |*s| {
            const x = s.*;
            if (x > 1 or x < -1) s.* = std.math.clamp(x, -1.5, 1.5) * (1 - std.math.clamp(x, -1.5, 1.5) * std.math.clamp(x, -1.5, 1.5) / 6.75);
        }
    }

    /// Renders the next `frames` of the song into `song_buf` and advances the song position.
    fn mixSong(e: *Engine, frames: usize) void {
        @memset(e.song_buf[0 .. frames * 2], 0);
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
            const dst = e.song_buf[skip * 2 ..][0 .. n * 2];
            const g = v.gain * e.gain;
            for (dst, src) |*d, s| d.* += s * g;
            v.pos += n * 2;
            if (v.pos >= v.data.len) v.data = &.{};
        }
        e.frame.store(f1, .release);
    }

    /// Adds `n` rendered frames to `out`, stretched to `frames`. The ends line up with the
    /// rendered ends, so consecutive buffers join without keeping resampler state.
    fn addSong(e: *const Engine, out: [*]f32, frames: usize, n: usize) void {
        if (n == frames) {
            for (out[0 .. frames * 2], e.song_buf[0 .. frames * 2]) |*d, s| d.* += s;
            return;
        }
        const step = @as(f64, @floatFromInt(n - 1)) / @as(f64, @floatFromInt(frames - 1));
        for (0..frames) |i| {
            const pos = @as(f64, @floatFromInt(i)) * step;
            const j: usize = @intFromFloat(pos);
            const k = @min(j + 1, n - 1);
            const frac: f32 = @floatCast(pos - @as(f64, @floatFromInt(j)));
            out[i * 2] += std.math.lerp(e.song_buf[j * 2], e.song_buf[k * 2], frac);
            out[i * 2 + 1] += std.math.lerp(e.song_buf[j * 2 + 1], e.song_buf[k * 2 + 1], frac);
        }
    }

    fn updateClock(e: *Engine, dac_delay_s: f64, frames: u32) void {
        // Song time of what the listener hears right now, relative to the shared monotonic clock.
        const now_us: i64 = @intCast(c.SDL_GetTicksNS() / 1000);
        const f = e.frame.load(.monotonic);
        const song_us = @divTrunc(f * 1_000_000, e.rate);
        const raw = song_us - @as(i64, @intFromFloat(dac_delay_s * 1e6)) - now_us;
        if (!e.clock_valid.load(.monotonic)) {
            e.clock_offset_us.store(raw, .release);
            e.settle_frames = e.rate;
            e.audio_err_us = 0;
            e.slew = 0;
            e.skip_frames = 0;
            e.clock_valid.store(true, .release);
            return;
        }
        const prev = e.clock_offset_us.load(.monotonic);
        // A fresh stream fills its queue faster than real time, so the first readings run early.
        if (e.settle_frames > 0) {
            e.settle_frames -= frames;
            e.clock_offset_us.store(prev + @divTrunc(raw - prev, 8), .release);
            return;
        }
        e.steerAudio(raw - prev, frames);
    }

    /// Moves the audio toward the tick clock. `err_us` is how far the audio is ahead of it.
    /// shortcut: audio far ahead only slews, as a stalled device stalls our writes too; add a hold if that proves wrong.
    fn steerAudio(e: *Engine, err_us: i64, frames: u32) void {
        // Writer wake-up jitter is the noise here; the mean is what's true.
        e.audio_err_us += @divTrunc(err_us - e.audio_err_us, 32);
        if (e.audio_err_us < -sync_skip_us) {
            e.skip_frames = @max(e.usToFrame(-err_us), 0);
            e.audio_err_us = 0;
            e.slew = 0;
            return;
        }
        if (@abs(e.audio_err_us) <= sync_deadband_us) {
            e.slew = 0;
            return;
        }
        e.slew_carry += frames;
        const budget: i64 = e.slew_carry / slew_period;
        e.slew_carry %= slew_period;
        e.slew = std.math.clamp(-e.usToFrame(e.audio_err_us), -budget, budget);
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

test "a device's name tells one API from another only on Windows" {
    var buf: [device_key_max]u8 = undefined;
    try std.testing.expectEqualStrings("WASAPI: Speakers", Engine.deviceKey(&buf, .windows, c.paWASAPI, "Speakers").?);
    try std.testing.expectEqualStrings("hw:0,0", Engine.deviceKey(&buf, .linux, c.paALSA, "hw:0,0").?);
    try std.testing.expectEqualStrings("Speakers", Engine.deviceKey(&buf, .macos, c.paCoreAudio, "Speakers").?);
    try std.testing.expect(Engine.deviceKey(buf[0..3], .windows, c.paASIO, "long name") == null);
}

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

test "the PortAudio callback mixes each buffer it is asked for and keeps the clock" {
    const e = try Engine.create(std.testing.allocator);
    defer e.destroy();
    const data = [_]f32{ 1, 1, 0.5, 0.5 };
    const samples = [_]decode.Sample{.{ .data = @constCast(&data) }};
    const sched = [_]Sched{.{ .frame = 1, .wav = 0 }};
    e.samples = &samples;
    e.schedule = &sched;
    var out: [64]f32 = undefined;
    try std.testing.expectEqual(@as(c_int, c.paContinue), Engine.paCallback(null, &out, 32, null, 0, e));
    try std.testing.expectEqual(@as(f32, 1), out[2]);
    try std.testing.expectEqual(@as(i64, 32), e.frame.load(.acquire));
    try std.testing.expect(e.clock_valid.load(.acquire));
}

test "tick clock stays fixed after settling and audio follows it" {
    const e = try Engine.create(std.testing.allocator);
    defer e.destroy();
    e.clock_valid.store(true, .release);
    e.clock_offset_us.store(123, .release);
    e.updateClock(0, 128);
    try std.testing.expectEqual(@as(i64, 123), e.clock_offset_us.load(.acquire));

    // Jitter inside the deadband leaves the pitch alone.
    e.audio_err_us = 0;
    e.steerAudio(sync_deadband_us, 128);
    try std.testing.expectEqual(@as(i64, 0), e.slew);

    // Ahead consumes fewer frames, behind consumes more, each within the slew limit.
    e.audio_err_us = 10_000;
    e.steerAudio(10_000, 512);
    try std.testing.expectEqual(@as(i64, -2), e.slew);
    e.audio_err_us = -10_000;
    e.steerAudio(-10_000, 512);
    try std.testing.expectEqual(@as(i64, 2), e.slew);
    var out: [1024]f32 = undefined;
    const f0 = e.frame.load(.monotonic);
    e.mix(&out, 512);
    try std.testing.expectEqual(f0 + 514, e.frame.load(.monotonic));

    // Far behind skips, and voices move with the song position.
    const data: [96000]f32 = @splat(0.25);
    const samples = [_]decode.Sample{.{ .data = @constCast(&data) }};
    e.samples = &samples;
    e.startVoice(0, 0, 0, 0);
    e.slew = 0;
    e.audio_err_us = -sync_skip_us - 1;
    e.steerAudio(-100_000, 128);
    try std.testing.expectEqual(@as(i64, 4800), e.skip_frames);
    const f1 = e.frame.load(.monotonic);
    e.mix(&out, 128);
    try std.testing.expectEqual(f1 + 4928, e.frame.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 4928 * 2), e.voices[0].pos);
}

test "slew stretches without clicks at the buffer ends" {
    const e = try Engine.create(std.testing.allocator);
    defer e.destroy();
    for (0..9) |i| {
        e.song_buf[i * 2] = @floatFromInt(i);
        e.song_buf[i * 2 + 1] = @floatFromInt(i);
    }
    var out: [16]f32 = @splat(0);
    e.addSong(&out, 8, 9);
    try std.testing.expectEqual(@as(f32, 0), out[0]);
    try std.testing.expectEqual(@as(f32, 8), out[14]);
    try std.testing.expect(out[2] > 1 and out[2] < 1.2);
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
