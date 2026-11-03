//! A preview for a chart that ships none: a few seconds of its own sounds from a third of the way in.
//! Mixed live, not cached: one window's sounds decode in well under a second, and a cache could go stale.
const std = @import("std");
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

/// Interleaved stereo at `rate`, owned by `out_gpa`. Gives up with error.Canceled once `cancel` is set.
// shortcut: decodes every sound heard before the clip on one thread, since a long one may still be playing; split across threads if a dense chart is slow to preview.
pub fn render(gpa: std.mem.Allocator, out_gpa: std.mem.Allocator, path: []const u8, rate: u32, cancel: *const std.atomic.Value(bool)) ![]f32 {
    const bytes = try fs.readAlloc(gpa, path, max_chart_bytes);
    defer gpa.free(bytes);
    var chart = try session.Session.parseBytes(gpa, path, bytes, null, 0);
    defer chart.deinit();
    const start_us = @divTrunc(@max(chart.last_note_us, 0), 3);
    const hits = try collectHits(gpa, &chart, start_us +| clip_us);
    defer gpa.free(hits);
    const out = try out_gpa.alloc(f32, @as(usize, @intCast(toFrames(clip_us, rate))) * 2);
    errdefer out_gpa.free(out);
    @memset(out, 0);
    const dir = std.fs.path.dirname(path) orelse ".";
    var heard = false;
    var i: usize = 0;
    while (i < hits.len) {
        var j = i + 1;
        while (j < hits.len and hits[j].wav == hits[i].wav) j += 1;
        defer i = j;
        if (cancel.load(.acquire)) return error.Canceled;
        const s = loadSound(gpa, dir, chart.wavs[@intCast(hits[i].wav)], rate) orelse continue;
        defer gpa.free(s.data);
        mixHits(out, s.data, hits[i..j], start_us, rate);
        heard = true;
    }
    if (!heard) return error.Silent;
    fade(out, rate);
    return out;
}

/// Every sound the chart starts before `end_us`, grouped by sound and in time order within each.
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

/// Null when the file is missing, too big or not audio: the clip plays on without it.
fn loadSound(gpa: std.mem.Allocator, dir: []const u8, name: []const u8, rate: u32) ?decode.Sample {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const p = (fs.resolveAsset(arena.allocator(), dir, name, session.audio_exts) catch null) orelse return null;
    const bytes = fs.readAlloc(gpa, p, max_sound_bytes) catch return null;
    defer gpa.free(bytes);
    return decode.decode(gpa, bytes, p, rate) catch null;
}

/// Saturates, since chart times are untrusted.
fn toFrames(us: i64, rate: u32) i64 {
    const f = @divTrunc(@as(i128, us) * rate, 1_000_000);
    return @intCast(std.math.clamp(f, std.math.minInt(i64), std.math.maxInt(i64)));
}

/// Adds one sound's hits into the clip that starts at `start_us`. A hit stops when the same sound
/// starts again, as the engine does.
fn mixHits(out: []f32, data: []const f32, hits: []const Hit, start_us: i64, rate: u32) void {
    const total: i64 = @intCast(data.len / 2);
    const out_frames: i64 = @intCast(out.len / 2);
    for (hits, 0..) |h, k| {
        const at = toFrames(h.time_us -| start_us, rate);
        const src = std.math.clamp(toFrames(h.start_us, rate), 0, total);
        var len = total - src;
        if (h.dur_us > 0) len = @min(len, toFrames(h.dur_us, rate));
        if (k + 1 < hits.len) len = @min(len, toFrames(hits[k + 1].time_us -| h.time_us, rate));
        const from = @max(at, 0);
        const to = @min(at +| len, out_frames);
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
    // At 1 MHz a frame is a microsecond. Starts before the window, cut 3 frames later.
    const hits = [_]Hit{
        .{ .time_us = 8, .wav = 0, .start_us = 0, .dur_us = 0 },
        .{ .time_us = 11, .wav = 0, .start_us = 0, .dur_us = 2 },
    };
    mixHits(&out, &data, &hits, 10, 1_000_000);
    try std.testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, &out);
}

test "a chart's sounds become a faded clip, and a huge or soundless chart is refused" {
    const gpa = std.testing.allocator;
    fs.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer gpa.free(dir);
    const chart = try std.fs.path.join(gpa, &.{ dir, "a.bms" });
    defer gpa.free(chart);
    const wav = try std.fs.path.join(gpa, &.{ dir, "a.wav" });
    defer gpa.free(wav);
    var cancel: std.atomic.Value(bool) = .init(false);

    // Names a sound that isn't there yet: nothing to hear.
    try fs.write(chart, "#BPM 120\n#WAV01 a.wav\n#00101:01\n");
    try std.testing.expectError(error.Silent, render(gpa, gpa, chart, 1000, &cancel));

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
    try fs.write(wav, &buf);
    const clip = try render(gpa, gpa, chart, 1000, &cancel);
    defer gpa.free(clip);
    try std.testing.expectEqual(@as(usize, 12_000 * 2), clip.len);
    try std.testing.expectEqual(@as(f32, 0), clip[0]);
    try std.testing.expect(clip[2050 * 2] > 0);
    try std.testing.expectEqual(@as(f32, 0), clip[2150 * 2]);

    cancel.store(true, .release);
    try std.testing.expectError(error.Canceled, render(gpa, gpa, chart, 1000, &cancel));

    const huge = try gpa.alloc(u8, max_chart_bytes + 1);
    defer gpa.free(huge);
    @memset(huge, '#');
    try fs.write(chart, huge);
    try std.testing.expectError(error.StreamTooLong, render(gpa, gpa, chart, 1000, &cancel));
    // Garbage parses to a chart with no sounds, or fails to parse; either way nothing plays.
    try fs.write(chart, "\x00\xff#WAVZZ\n#99999:ZZ\n#BPM -0\n");
    if (render(gpa, gpa, chart, 1000, &cancel)) |c| {
        gpa.free(c);
        return error.TestUnexpectedResult;
    } else |_| {}
}
