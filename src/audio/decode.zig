//! Decodes keysounds fully into memory as interleaved stereo f32 at the device rate, so playback
//! does no disk I/O and no allocation.
const std = @import("std");
const c = @import("c");

pub const Sample = struct {
    data: []f32 = &.{}, // stereo frames
    pub fn frames(s: Sample) usize {
        return s.data.len / 2;
    }
};

/// Longer than any song a chart plays.
const max_seconds = 30 * 60;

const Raw = struct { samples: []f32, channels: u32, rate: u32, owner: enum { dr, gpa } };

fn lower(path: []const u8, buf: []u8) []const u8 {
    return std.ascii.lowerString(buf, path[path.len -| @min(path.len, buf.len)..]);
}

fn decodeRaw(gpa: std.mem.Allocator, bytes: []const u8, name: []const u8) !Raw {
    var ext_buf: [8]u8 = undefined;
    const ext = lower(std.fs.path.extension(name), &ext_buf);
    var channels: c_uint = 0;
    var rate: c_uint = 0;
    var frames: u64 = 0;
    // Trust content over extension order only as far as trying each decoder: charts mislabel files.
    const try_order: [4]u8 = if (std.mem.eql(u8, ext, ".ogg"))
        .{ 'o', 'w', 'f', 'm' }
    else if (std.mem.eql(u8, ext, ".flac"))
        .{ 'f', 'w', 'o', 'm' }
    else if (std.mem.eql(u8, ext, ".mp3"))
        .{ 'm', 'w', 'o', 'f' }
    else
        .{ 'w', 'o', 'f', 'm' };
    for (try_order) |t| switch (t) {
        'w' => {
            const p = c.drwav_open_memory_and_read_pcm_frames_f32(bytes.ptr, bytes.len, &channels, &rate, &frames, null);
            if (p != null and frames > 0) return .{ .samples = p[0..@intCast(frames * channels)], .channels = channels, .rate = rate, .owner = .dr };
        },
        'f' => {
            const p = c.drflac_open_memory_and_read_pcm_frames_f32(bytes.ptr, bytes.len, &channels, &rate, &frames, null);
            if (p != null and frames > 0) return .{ .samples = p[0..@intCast(frames * channels)], .channels = channels, .rate = rate, .owner = .dr };
        },
        'm' => {
            var cfg: c.drmp3_config = undefined;
            const p = c.drmp3_open_memory_and_read_pcm_frames_f32(bytes.ptr, bytes.len, &cfg, &frames, null);
            if (p != null and frames > 0) return .{ .samples = p[0..@intCast(frames * cfg.channels)], .channels = cfg.channels, .rate = cfg.sampleRate, .owner = .dr };
        },
        'o' => {
            var ch: c_int = 0;
            var r: c_int = 0;
            var output: [*c]c_short = null;
            const n = c.stb_vorbis_decode_memory(bytes.ptr, @intCast(bytes.len), &ch, &r, &output);
            // stb_vorbis hands an unsigned header rate back as an int, so a huge one reads negative.
            if (n > 0 and ch > 0 and r > 0) {
                defer c.free(output);
                const total: usize = @intCast(@as(i64, n) * ch);
                const out = try gpa.alloc(f32, total);
                for (out, output[0..total]) |*d, s| d.* = @as(f32, @floatFromInt(s)) / 32768.0;
                return .{ .samples = out, .channels = @intCast(ch), .rate = @intCast(r), .owner = .gpa };
            }
        },
        else => unreachable,
    };
    return error.UndecodableAudio;
}

/// Cubic Hermite interpolation: much cheaper than a windowed sinc at load, and keysounds are short.
fn hermite(x0: f32, x1: f32, x2: f32, x3: f32, t: f32) f32 {
    const a = -0.5 * x0 + 1.5 * x1 - 1.5 * x2 + 0.5 * x3;
    const b = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3;
    const cc = -0.5 * x0 + 0.5 * x2;
    return ((a * t + b) * t + cc) * t + x1;
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, name: []const u8, out_rate: u32) !Sample {
    const raw = try decodeRaw(gpa, bytes, name);
    defer switch (raw.owner) {
        .dr => c.drwav_free(raw.samples.ptr, null),
        .gpa => gpa.free(raw.samples),
    };
    const ch = raw.channels;
    const in_frames = raw.samples.len / ch;
    if (raw.rate == 0) return error.UndecodableAudio;
    const ratio = @as(f64, @floatFromInt(raw.rate)) / @as(f64, @floatFromInt(out_rate));
    const out_len = @ceil(@as(f64, @floatFromInt(in_frames)) / ratio);
    // A tiny header rate would make a small file resample into gigabytes.
    if (out_len > @as(f64, @floatFromInt(max_seconds * out_rate))) return error.UndecodableAudio;
    const out_frames: usize = @intFromFloat(out_len);
    const out = try gpa.alloc(f32, out_frames * 2);
    const at = struct {
        fn f(s: []const f32, chn: u32, i: i64, side: u32, n: usize) f32 {
            const idx: usize = @intCast(std.math.clamp(i, 0, @as(i64, @intCast(n)) - 1));
            return s[idx * chn + @min(side, chn - 1)];
        }
    }.f;
    if (raw.rate == out_rate) {
        for (0..out_frames) |i| {
            out[i * 2] = at(raw.samples, ch, @intCast(i), 0, in_frames);
            out[i * 2 + 1] = at(raw.samples, ch, @intCast(i), 1, in_frames);
        }
    } else {
        for (0..out_frames) |i| {
            const pos = @as(f64, @floatFromInt(i)) * ratio;
            const fl = @floor(pos);
            const p: i64 = @intFromFloat(fl);
            const t: f32 = @floatCast(pos - fl);
            for (0..2) |side| {
                const s: u32 = @intCast(side);
                out[i * 2 + side] = hermite(at(raw.samples, ch, p - 1, s, in_frames), at(raw.samples, ch, p, s, in_frames), at(raw.samples, ch, p + 1, s, in_frames), at(raw.samples, ch, p + 2, s, in_frames), t);
            }
        }
    }
    return .{ .data = out };
}

test "wav decode through resampler keeps duration" {
    // 2000 frames, 8 kHz, mono, 16-bit PCM
    var buf: [44 + 4000]u8 = @splat(0);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + 4000, .little);
    @memcpy(buf[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little);
    std.mem.writeInt(u16, buf[22..24], 1, .little);
    std.mem.writeInt(u32, buf[24..28], 8000, .little);
    std.mem.writeInt(u32, buf[28..32], 16000, .little);
    std.mem.writeInt(u16, buf[32..34], 2, .little);
    std.mem.writeInt(u16, buf[34..36], 16, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], 4000, .little);
    const s = try decode(std.testing.allocator, &buf, "x.wav", 48000);
    defer std.testing.allocator.free(s.data);
    try std.testing.expectEqual(@as(usize, 12000), s.frames());
    // At 1 Hz the same 4 KB would last 33 minutes and resample into 96 million frames.
    std.mem.writeInt(u32, buf[24..28], 1, .little);
    std.mem.writeInt(u32, buf[28..32], 2, .little);
    try std.testing.expectError(error.UndecodableAudio, decode(std.testing.allocator, &buf, "x.wav", 48000));
}
