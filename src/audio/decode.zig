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

/// How long a sound lasts, from its header alone. Null when only decoding can tell, as for mp3 and flac.
pub fn lengthUs(bytes: []const u8) ?i64 {
    var w: c.drwav = undefined;
    if (c.drwav_init_memory(&w, bytes.ptr, bytes.len, null) != 0) {
        defer _ = c.drwav_uninit(&w);
        return usOf(w.totalPCMFrameCount, w.sampleRate);
    }
    return oggLengthUs(bytes);
}

/// The last page's granule position over the rate in the first packet. Opening the stream with
/// stb_vorbis would also build its codebooks, which costs more than a short sound's decode.
fn oggLengthUs(bytes: []const u8) ?i64 {
    if (bytes.len < 28 or !std.mem.eql(u8, bytes[0..4], "OggS")) return null;
    const id = 27 + @as(usize, bytes[26]);
    if (bytes.len < id + 16 or !std.mem.eql(u8, bytes[id .. id + 7], "\x01vorbis")) return null;
    const rate = std.mem.readInt(u32, bytes[id + 12 ..][0..4], .little);
    const last = std.mem.lastIndexOf(u8, bytes, "OggS") orelse return null;
    if (bytes.len < last + 14) return null;
    return usOf(std.mem.readInt(u64, bytes[last + 6 ..][0..8], .little), rate);
}

fn usOf(frames: u64, rate: u32) ?i64 {
    if (frames == 0 or rate == 0) return null;
    return @intCast(@min(@as(u128, frames) * 1_000_000 / rate, std.math.maxInt(i64)));
}

/// Cubic Hermite interpolation: much cheaper than a windowed sinc at load, and keysounds are short.
fn hermite(x0: f32, x1: f32, x2: f32, x3: f32, t: f32) f32 {
    const a = -0.5 * x0 + 1.5 * x1 - 1.5 * x2 + 0.5 * x3;
    const b = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3;
    const cc = -0.5 * x0 + 0.5 * x2;
    return ((a * t + b) * t + cc) * t + x1;
}

fn freeRaw(gpa: std.mem.Allocator, raw: Raw) void {
    switch (raw.owner) {
        .dr => c.drwav_free(raw.samples.ptr, null),
        .gpa => gpa.free(raw.samples),
    }
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, name: []const u8, out_rate: u32) !Sample {
    const raw = try decodeRaw(gpa, bytes, name);
    defer freeRaw(gpa, raw);
    return resample(gpa, raw.samples, raw.channels, raw.rate, out_rate);
}

/// `len_us` of the sound from `from_us`, so the unheard rest of a long track is never resampled,
/// nor for Ogg decoded. Empty when the span lies past the end.
pub fn decodeSpan(gpa: std.mem.Allocator, bytes: []const u8, name: []const u8, out_rate: u32, from_us: i64, len_us: i64) !Sample {
    if (oggSpan(gpa, bytes, from_us, len_us)) |span| {
        defer freeRaw(gpa, span);
        return resample(gpa, span.samples, span.channels, span.rate, out_rate);
    } else |e| if (e != error.NotOgg) return e;
    const raw = try decodeRaw(gpa, bytes, name);
    defer freeRaw(gpa, raw);
    const ch = raw.channels;
    const frames = raw.samples.len / ch;
    const a = @min(framesAt(from_us, raw.rate), frames);
    const b = @min(a + framesAt(len_us, raw.rate), frames);
    return resample(gpa, raw.samples[a * ch .. b * ch], ch, raw.rate, out_rate);
}

fn framesAt(us: i64, rate: u32) usize {
    return @intCast(@min(@as(u128, @intCast(@max(us, 0))) * rate / 1_000_000, max_seconds * @as(u128, rate)));
}

/// Seeks instead of decoding the start. NotOgg sends any other file to the full decoders.
fn oggSpan(gpa: std.mem.Allocator, bytes: []const u8, from_us: i64, len_us: i64) !Raw {
    if (!std.mem.startsWith(u8, bytes, "OggS") or bytes.len > std.math.maxInt(c_int)) return error.NotOgg;
    var err: c_int = 0;
    const v = c.stb_vorbis_open_memory(bytes.ptr, @intCast(bytes.len), &err, null) orelse return error.UndecodableAudio;
    defer c.stb_vorbis_close(v);
    const info = c.stb_vorbis_get_info(v);
    if (info.channels <= 0 or info.sample_rate == 0) return error.UndecodableAudio;
    const ch: usize = @intCast(info.channels);
    const total: usize = c.stb_vorbis_stream_length_in_samples(v);
    const from = @min(framesAt(from_us, info.sample_rate), total);
    const n = @min(framesAt(len_us, info.sample_rate), total - from);
    if (n == 0) return .{ .samples = &.{}, .channels = @intCast(ch), .rate = info.sample_rate, .owner = .gpa };
    if (from > 0 and c.stb_vorbis_seek(v, @intCast(from)) == 0) return error.UndecodableAudio;
    const out = try gpa.alloc(f32, n * ch);
    errdefer gpa.free(out);
    const got: usize = @intCast(@max(c.stb_vorbis_get_samples_float_interleaved(v, info.channels, out.ptr, @intCast(out.len)), 0));
    return .{ .samples = try gpa.realloc(out, got * ch), .channels = @intCast(ch), .rate = info.sample_rate, .owner = .gpa };
}

fn resample(gpa: std.mem.Allocator, samples: []const f32, ch: u32, rate: u32, out_rate: u32) !Sample {
    const in_frames = samples.len / ch;
    if (rate == 0) return error.UndecodableAudio;
    const ratio = @as(f64, @floatFromInt(rate)) / @as(f64, @floatFromInt(out_rate));
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
    if (rate == out_rate) {
        for (0..out_frames) |i| {
            out[i * 2] = at(samples, ch, @intCast(i), 0, in_frames);
            out[i * 2 + 1] = at(samples, ch, @intCast(i), 1, in_frames);
        }
    } else {
        for (0..out_frames) |i| {
            const pos = @as(f64, @floatFromInt(i)) * ratio;
            const fl = @floor(pos);
            const p: i64 = @intFromFloat(fl);
            const t: f32 = @floatCast(pos - fl);
            for (0..2) |side| {
                const s: u32 = @intCast(side);
                out[i * 2 + side] = hermite(at(samples, ch, p - 1, s, in_frames), at(samples, ch, p, s, in_frames), at(samples, ch, p + 1, s, in_frames), at(samples, ch, p + 2, s, in_frames), t);
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
    try std.testing.expectEqual(@as(?i64, 250_000), lengthUs(&buf));
    try std.testing.expectEqual(@as(?i64, null), lengthUs("not audio"));
    // An Ogg stream's length is its last page's granule over the rate, read without decoding.
    var ogg: [28 + 16 + 14]u8 = @splat(0);
    @memcpy(ogg[0..4], "OggS");
    ogg[26] = 1;
    @memcpy(ogg[28..35], "\x01vorbis");
    std.mem.writeInt(u32, ogg[40..44], 44100, .little);
    @memcpy(ogg[44..48], "OggS");
    std.mem.writeInt(u64, ogg[50..58], 88200, .little);
    try std.testing.expectEqual(@as(?i64, 2_000_000), lengthUs(&ogg));
    try std.testing.expectEqual(@as(?i64, null), lengthUs(ogg[0..40]));
    // At 1 Hz the same 4 KB would last 33 minutes and resample into 96 million frames.
    std.mem.writeInt(u32, buf[24..28], 1, .little);
    std.mem.writeInt(u32, buf[28..32], 2, .little);
    try std.testing.expectError(error.UndecodableAudio, decode(std.testing.allocator, &buf, "x.wav", 48000));
}
