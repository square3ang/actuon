//! Latency measurement: audio loopback round trip and input-to-judge delay.
//! Loopback needs the output physically wired to an input (or a monitor source selected as input).
const std = @import("std");
const c = @import("c");
const input = @import("../input/input.zig");

const rate = 48000;
const frames = 64;
const period = rate / 2; // one click every 500 ms

const Loop = struct {
    t: u64 = 0,
    click_at: u64 = 0,
    waiting: bool = false,
    results: [32]f64 = undefined,
    n: std.atomic.Value(u32) = .init(0),
    peak_noise: f32 = 0,
};

fn loopCb(in: ?*const anyopaque, out: ?*anyopaque, count: c_ulong, _: [*c]const c.PaStreamCallbackTimeInfo, _: c.PaStreamCallbackFlags, ud: ?*anyopaque) callconv(.c) c_int {
    const l: *Loop = @ptrCast(@alignCast(ud));
    const o: [*]f32 = @ptrCast(@alignCast(out));
    const i: [*]const f32 = @ptrCast(@alignCast(in));
    for (0..count) |f| {
        const pos = l.t % period;
        // A short full-scale square burst is easy to detect and survives any resampling.
        const v: f32 = if (pos < 48) (if (pos % 8 < 4) @as(f32, 0.9) else -0.9) else 0;
        o[f * 2] = v;
        o[f * 2 + 1] = v;
        if (pos == 0) {
            l.click_at = l.t;
            l.waiting = true;
        }
        if (l.waiting and @abs(i[f]) > 0.1) {
            const n = l.n.load(.monotonic);
            if (n < l.results.len) {
                l.results[n] = @as(f64, @floatFromInt(l.t - l.click_at)) * 1000.0 / rate;
                l.n.store(n + 1, .release);
            }
            l.waiting = false;
        }
        l.t += 1;
    }
    return c.paContinue;
}

pub fn median(values: []f64) f64 {
    if (values.len == 0) return 0;
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    return values[values.len / 2];
}

fn loopback() void {
    if (c.Pa_Initialize() != c.paNoError) return;
    defer _ = c.Pa_Terminate();
    var l: Loop = .{};
    var stream: ?*c.PaStream = null;
    if (c.Pa_OpenDefaultStream(&stream, 1, 2, c.paFloat32, rate, frames, loopCb, &l) != c.paNoError) {
        std.debug.print("audio loopback: no duplex default device, skipped\n", .{});
        return;
    }
    defer _ = c.Pa_CloseStream(stream);
    const info = c.Pa_GetStreamInfo(stream);
    if (c.Pa_StartStream(stream) != c.paNoError) return;
    c.SDL_Delay(6000);
    _ = c.Pa_StopStream(stream);
    const n = l.n.load(.acquire);
    std.debug.print("audio: reported output latency {d:.2} ms, input {d:.2} ms\n", .{ info.*.outputLatency * 1000, info.*.inputLatency * 1000 });
    if (n == 0) {
        std.debug.print("audio loopback: no click heard. Wire the output to the input and retry.\n", .{});
    } else {
        std.debug.print("audio loopback: {d} clicks, median round trip {d:.2} ms\n", .{ n, median(l.results[0..n]) });
    }
}

fn report(name: []const u8, ns: []u64) void {
    if (ns.len == 0) {
        std.debug.print("{s}: no samples\n", .{name});
        return;
    }
    std.mem.sort(u64, ns, {}, std.sort.asc(u64));
    std.debug.print("{s}: n={d} p50={d:.3} ms p99={d:.3} ms max={d:.3} ms\n", .{
        name,
        ns.len,
        @as(f64, @floatFromInt(ns[ns.len / 2])) / 1e6,
        @as(f64, @floatFromInt(ns[ns.len * 99 / 100])) / 1e6,
        @as(f64, @floatFromInt(ns[ns.len - 1])) / 1e6,
    });
}

/// Same wait loop as Session.simThread: enqueue to pop is the delay the judge sees on top of the OS.
fn queueBench() void {
    var samples: [2000]u64 = undefined;
    var n: usize = 0;
    var next = c.SDL_GetTicksNS();
    while (n < samples.len) {
        const now = c.SDL_GetTicksNS();
        if (now >= next) {
            input.push(.{ .mono_ns = now, .code = 0, .down = true });
            next = now + 1_000_000;
        }
        c.SDL_DelayPrecise(250_000);
        while (input.pop()) |e| {
            samples[n] = c.SDL_GetTicksNS() - e.mono_ns;
            n += 1;
            if (n == samples.len) break;
        }
    }
    report("input queue to judge thread", &samples);
}

fn realKeys(seconds: u32) void {
    input.focused.store(true, .release);
    input.startDirect();
    c.SDL_Delay(200);
    if (!input.direct_keyboard.load(.acquire)) {
        std.debug.print("direct input unavailable (see docs: udev rule), real key test skipped\n", .{});
        return;
    }
    std.debug.print("Press keys for {d} s...\n", .{seconds});
    var samples: [4096]u64 = undefined;
    var n: usize = 0;
    const end = c.SDL_GetTicksNS() + @as(u64, seconds) * std.time.ns_per_s;
    while (c.SDL_GetTicksNS() < end) {
        while (input.pop()) |e| if (n < samples.len) {
            samples[n] = c.SDL_GetTicksNS() -| e.mono_ns;
            n += 1;
        };
        c.SDL_DelayPrecise(250_000);
    }
    report("kernel timestamp to judge thread", samples[0..n]);
}

pub fn run(key_seconds: u32) !void {
    if (!c.SDL_Init(c.SDL_INIT_EVENTS)) return error.SdlInit;
    defer c.SDL_Quit();
    queueBench();
    loopback();
    if (key_seconds > 0) realKeys(key_seconds);
}

test "median" {
    var v = [_]f64{ 3, 1, 2 };
    try std.testing.expectEqual(@as(f64, 2), median(&v));
}
