const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");
const decode = @import("decode.zig");
const session = @import("../game/session.zig");

const clip_us = 12_000_000;
const fade_in_us = 300_000;
const fade_out_us = 1_500_000;
/// Real charts are well under a megabyte; past this one is broken or hostile.
const max_chart_bytes = 8 << 20;
const max_sound_bytes = 64 << 20;

const Hit = struct { time_us: i64, wav: i32, start_us: i64, dur_us: i64 };

/// Owned by `out_gpa`.
pub fn render(gpa: std.mem.Allocator, out_gpa: std.mem.Allocator, io: std.Io, path: []const u8, rate: u32, cancel: *const std.atomic.Value(bool)) ![]f32 {
    const bytes = try fs.readAlloc(gpa, io, path, max_chart_bytes);
    defer gpa.free(bytes);
    var chart = try session.Session.parseBytes(gpa, path, bytes, null, 0);
    defer chart.deinit();
    const start_us = @divTrunc(@max(chart.last_note_us, 0), 3);
    const hits = try collectHits(gpa, &chart, start_us +| clip_us);
    defer gpa.free(hits);
    const out = try out_gpa.alloc(f32, @as(usize, @intCast(toFrames(clip_us, rate))) * 2);
    errdefer out_gpa.free(out);
    @memset(out, 0);
    var groups: std.ArrayList(usize) = .empty;
    defer groups.deinit(gpa);
    for (hits, 0..) |h, i| if (i == 0 or h.wav != hits[i - 1].wav) try groups.append(gpa, i);
    try groups.append(gpa, hits.len);
    var mix: Mix = .{
        .gpa = gpa,
        .io = io,
        .dir = std.fs.path.dirname(path) orelse ".",
        .wavs = chart.wavs,
        .hits = hits,
        .groups = groups.items,
        .start_us = start_us,
        .rate = rate,
        .out = out,
        .cancel = cancel,
        .lock = c.SDL_CreateMutex() orelse return error.NoMutex,
    };
    defer c.SDL_DestroyMutex(mix.lock);
    var threads: [15]?*c.SDL_Thread = @splat(null);
    const extra: usize = @intCast(std.math.clamp(c.SDL_GetNumLogicalCPUCores() - 1, 0, threads.len));
    for (threads[0..extra]) |*t| t.* = c.SDL_CreateThread(Mix.run, "clip", &mix);
    _ = Mix.run(&mix);
    for (threads) |t| if (t != null) c.SDL_WaitThread(t, null);
    if (cancel.load(.acquire)) return error.Canceled;
    if (!mix.heard.load(.acquire)) return error.Silent;
    fade(out, rate);
    return out;
}

const Mix = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    wavs: []const []const u8,
    hits: []const Hit,
    groups: []const usize,
    start_us: i64,
    rate: u32,
    out: []f32,
    cancel: *const std.atomic.Value(bool),
    /// Guards `out`.
    lock: *c.SDL_Mutex,
    next: std.atomic.Value(usize) = .init(0),
    heard: std.atomic.Value(bool) = .init(false),

    fn run(ud: ?*anyopaque) callconv(.c) c_int {
        const m: *Mix = @ptrCast(@alignCast(ud));
        while (!m.cancel.load(.acquire)) {
            const g = m.next.fetchAdd(1, .monotonic);
            if (g + 1 >= m.groups.len) return 0;
            const hits = heardHits(m.hits[m.groups[g]..m.groups[g + 1]], m.start_us);
            const span = soundSpan(hits, m.start_us, m.start_us +| clip_us);
            const s = loadSound(m.gpa, m.io, m.dir, m.wavs[@intCast(hits[0].wav)], m.rate, span) orelse continue;
            defer m.gpa.free(s.data);
            c.SDL_LockMutex(m.lock);
            mixHits(m.out, s.data, hits, m.start_us, m.rate, span.from_us);
            c.SDL_UnlockMutex(m.lock);
            m.heard.store(true, .release);
        }
        return 0;
    }
};

fn collectHits(gpa: std.mem.Allocator, chart: *const core.types.Chart, end_us: i64) ![]Hit {
    var hits: std.ArrayList(Hit) = .empty;
    errdefer hits.deinit(gpa);
    for (chart.bg) |b| if (b.time_us < end_us and b.wav >= 0 and b.wav < chart.wavs.len)
        try hits.append(gpa, .{ .time_us = b.time_us, .wav = b.wav, .start_us = b.wav_start_us, .dur_us = b.wav_dur_us });
    for (chart.notes) |n| if (n.time_us < end_us and n.wav >= 0 and n.wav < chart.wavs.len and n.kind != .mine and n.kind != .ln_end)
        try hits.append(gpa, .{ .time_us = n.time_us, .wav = n.wav, .start_us = n.wav_start_us, .dur_us = n.wav_dur_us });
    std.mem.sort(Hit, hits.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            return if (a.wav != b.wav) a.wav < b.wav else a.time_us < b.time_us;
        }
    }.lt);
    return hits.toOwnedSlice(gpa);
}

fn loadSound(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, rate: u32, span: Span) ?decode.Sample {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const p = (fs.resolveAsset(arena.allocator(), io, dir, name, session.audio_exts) catch null) orelse return null;
    const bytes = fs.readAlloc(gpa, io, p, max_sound_bytes) catch return null;
    defer gpa.free(bytes);
    if (decode.lengthUs(bytes)) |len| if (len <= span.from_us) return null;
    return decode.decodeSpan(gpa, bytes, p, rate, span.from_us, span.len_us) catch null;
}

fn heardHits(hits: []const Hit, start_us: i64) []const Hit {
    var i = hits.len;
    while (i > 0 and hits[i - 1].time_us >= start_us) i -= 1;
    return hits[i -| 1..];
}

const Span = struct { from_us: i64, len_us: i64 };

fn soundSpan(hits: []const Hit, start_us: i64, end_us: i64) Span {
    var lo: i64 = std.math.maxInt(i64);
    var hi: i64 = 0;
    for (hits, 0..) |h, k| {
        const off = @max(h.start_us, 0);
        const stop = if (k + 1 < hits.len) @min(hits[k + 1].time_us, end_us) else end_us;
        lo = @min(lo, off +| (@max(h.time_us, start_us) -| h.time_us));
        hi = @max(hi, off +| (stop -| h.time_us));
    }
    return .{ .from_us = lo, .len_us = @max(hi -| lo, 0) };
}

/// Saturates, since chart times are untrusted.
fn toFrames(us: i64, rate: u32) i64 {
    const f = @divTrunc(@as(i128, us) * rate, 1_000_000);
    return @intCast(std.math.clamp(f, std.math.minInt(i64), std.math.maxInt(i64)));
}

fn mixHits(out: []f32, data: []const f32, hits: []const Hit, start_us: i64, rate: u32, skip_us: i64) void {
    const total: i64 = @intCast(data.len / 2);
    const out_frames: i64 = @intCast(out.len / 2);
    for (hits, 0..) |h, k| {
        const at = toFrames(h.time_us -| start_us, rate);
        const src = toFrames(@max(h.start_us, 0) -| skip_us, rate);
        var to = @min(out_frames, at -| src +| total);
        if (h.dur_us > 0) to = @min(to, at +| toFrames(h.dur_us, rate));
        if (k + 1 < hits.len) to = @min(to, at +| toFrames(hits[k + 1].time_us -| h.time_us, rate));
        const from = @max(at, 0, at -| src);
        var f = from;
        while (f < to) : (f += 1) {
            const s: usize = @intCast(src + f - at);
            const o: usize = @intCast(f);
            out[o * 2] += data[s * 2];
            out[o * 2 + 1] += data[s * 2 + 1];
        }
    }
}

fn fade(out: []f32, rate: u32) void {
    const frames = out.len / 2;
    const in_n: usize = @intCast(toFrames(fade_in_us, rate));
    const out_n: usize = @intCast(toFrames(fade_out_us, rate));
    for (0..frames) |f| {
        const g_in = @as(f32, @floatFromInt(@min(f, in_n))) / @as(f32, @floatFromInt(in_n));
        const g_out = @as(f32, @floatFromInt(@min(frames - 1 - f, out_n))) / @as(f32, @floatFromInt(out_n));
        const g = @min(g_in, g_out);
        out[f * 2] *= g;
        out[f * 2 + 1] *= g;
    }
}

test "a sound stops where the same sound starts again, and the clip starts at its window" {
    const data: [20]f32 = @splat(1); // 10 frames
    var out: [16]f32 = @splat(0); // 8 frames
    const hits = [_]Hit{
        .{ .time_us = 8, .wav = 0, .start_us = 0, .dur_us = 0 },
        .{ .time_us = 11, .wav = 0, .start_us = 0, .dur_us = 2 },
    };
    mixHits(&out, &data, &hits, 10, 1_000_000, 0);
    try std.testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &out);
}

test "only the part of a sound the clip hears is decoded, and it mixes where it belongs" {
    const hits = [_]Hit{
        .{ .time_us = 0, .wav = 0, .start_us = 0, .dur_us = 0 },
        .{ .time_us = 5, .wav = 0, .start_us = 2, .dur_us = 0 },
        .{ .time_us = 12, .wav = 0, .start_us = 0, .dur_us = 0 },
    };
    const heard = heardHits(&hits, 10);
    try std.testing.expectEqual(@as(usize, 2), heard.len);
    try std.testing.expectEqual(Span{ .from_us = 0, .len_us = 9 }, soundSpan(heard, 10, 18));
    try std.testing.expectEqual(Span{ .from_us = 7, .len_us = 8 }, soundSpan(heard[0..1], 10, 18));
    var data: [16]f32 = undefined;
    for (0..8) |i| data[i * 2] = @floatFromInt(7 + i);
    for (0..8) |i| data[i * 2 + 1] = data[i * 2];
    var out: [16]f32 = @splat(0);
    mixHits(&out, &data, heard[0..1], 10, 1_000_000, 7);
    try std.testing.expectEqualSlices(f32, &data, &out);
}

test "a chart's sounds become a faded clip, and a huge or soundless chart is refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const chart = try std.fs.path.join(gpa, &.{ dir, "a.bms" });
    defer gpa.free(chart);
    const wav = try std.fs.path.join(gpa, &.{ dir, "a.wav" });
    defer gpa.free(wav);
    var cancel: std.atomic.Value(bool) = .init(false);

    try fs.write(io, chart, "#BPM 120\n#WAV01 a.wav\n#00101:01\n");
    try std.testing.expectError(error.Silent, render(gpa, gpa, io, chart, 1000, &cancel));

    // 100 frames of 1000 Hz mono 8-bit: a tenth of a second, from 2 s.
    var buf: [44 + 100]u8 = @splat(200);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + 100, .little);
    @memcpy(buf[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little);
    std.mem.writeInt(u16, buf[22..24], 1, .little);
    std.mem.writeInt(u32, buf[24..28], 1000, .little);
    std.mem.writeInt(u32, buf[28..32], 1000, .little);
    std.mem.writeInt(u16, buf[32..34], 1, .little);
    std.mem.writeInt(u16, buf[34..36], 8, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], 100, .little);
    try fs.write(io, wav, &buf);
    const clip = try render(gpa, gpa, io, chart, 1000, &cancel);
    defer gpa.free(clip);
    try std.testing.expectEqual(@as(usize, 12_000 * 2), clip.len);
    try std.testing.expectEqual(@as(f32, 0), clip[0]);
    try std.testing.expect(clip[2050 * 2] > 0);
    try std.testing.expectEqual(@as(f32, 0), clip[2150 * 2]);

    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, render(gpa, gpa, io, chart, 1000, &cancel));

    const huge = try gpa.alloc(u8, max_chart_bytes + 1);
    defer gpa.free(huge);
    @memset(huge, '#');
    try fs.write(io, chart, huge);
    try std.testing.expectError(error.StreamTooLong, render(gpa, gpa, io, chart, 1000, &cancel));
    try fs.write(io, chart, "\x00\xff#WAVZZ\n#99999:ZZ\n#BPM -0\n");
    if (render(gpa, gpa, io, chart, 1000, &cancel)) |x| {
        gpa.free(x);
        return error.TestUnexpectedResult;
    } else |_| {}
}
