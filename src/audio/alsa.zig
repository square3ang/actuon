//! Linux output straight through libasound. PortAudio's ALSA backend insists on two periods and
//! fixed formats; this takes whatever buffer the device allows down to one period, as SideALSA's PRO mode does.
const std = @import("std");
const c = @import("c");

/// Wider devices are refused, so the conversion buffer stays a fixed size.
pub const max_channels = 8;

pub const Format = enum { f32, s32, s16 };

pub const Out = struct {
    pcm: *c.snd_pcm_t,
    format: Format,
    channels: u32,
    /// Frames per write; the device picks it, near the requested size.
    period: u32,
    /// Seconds from a write to when its first frame plays, with the device kept one period short of full.
    lead_s: f64,

    /// `period_max` caps the period to what the caller's buffers hold.
    pub fn open(name: []const u8, rate: u32, frames: u32, period_max: u32) ?Out {
        var name_buf: [512]u8 = undefined;
        const name_z = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{name}, 0) catch return null;
        var pcm: ?*c.snd_pcm_t = null;
        if (c.snd_pcm_open(&pcm, name_z, c.SND_PCM_STREAM_PLAYBACK, 0) < 0) return null;
        const out = configure(pcm.?, rate, @min(frames, period_max), period_max) catch |err| {
            std.log.warn("ALSA {s}: {t}", .{ name, err });
            _ = c.snd_pcm_close(pcm);
            return null;
        };
        return out;
    }

    fn configure(pcm: *c.snd_pcm_t, rate: u32, frames: u32, period_max: u32) !Out {
        var hw: ?*c.snd_pcm_hw_params_t = null;
        if (c.snd_pcm_hw_params_malloc(&hw) < 0) return error.OutOfMemory;
        defer c.snd_pcm_hw_params_free(hw);
        try check(c.snd_pcm_hw_params_any(pcm, hw));
        try check(c.snd_pcm_hw_params_set_access(pcm, hw, c.SND_PCM_ACCESS_RW_INTERLEAVED));
        const formats = [_]struct { Format, c.snd_pcm_format_t }{
            .{ .f32, c.SND_PCM_FORMAT_FLOAT_LE },
            .{ .s32, c.SND_PCM_FORMAT_S32_LE },
            .{ .s16, c.SND_PCM_FORMAT_S16_LE },
        };
        const format = for (formats) |f| {
            if (c.snd_pcm_hw_params_set_format(pcm, hw, f[1]) == 0) break f[0];
        } else return error.NoFormat;
        var channels: c_uint = 2;
        try check(c.snd_pcm_hw_params_set_channels_near(pcm, hw, &channels));
        if (channels < 2 or channels > max_channels) return error.NoChannels;
        // Exact: the sounds were decoded at this rate, and a plugin resampler would add its own delay.
        try check(c.snd_pcm_hw_params_set_rate(pcm, hw, rate, 0));
        var period: c.snd_pcm_uframes_t = frames;
        var dir: c_int = 0;
        try check(c.snd_pcm_hw_params_set_period_size_near(pcm, hw, &period, &dir));
        if (period > period_max) return error.PeriodTooLarge;
        // As small as the device goes: one period where it allows that, else two.
        var buffer: c.snd_pcm_uframes_t = period;
        try check(c.snd_pcm_hw_params_set_buffer_size_near(pcm, hw, &buffer));
        try check(c.snd_pcm_hw_params(pcm, hw));

        var sw: ?*c.snd_pcm_sw_params_t = null;
        if (c.snd_pcm_sw_params_malloc(&sw) < 0) return error.OutOfMemory;
        defer c.snd_pcm_sw_params_free(sw);
        try check(c.snd_pcm_sw_params_current(pcm, sw));
        // Starts on the first period written: no silence queued ahead of the game's sound.
        try check(c.snd_pcm_sw_params_set_start_threshold(pcm, sw, period));
        try check(c.snd_pcm_sw_params_set_avail_min(pcm, sw, period));
        try check(c.snd_pcm_sw_params(pcm, sw));
        return .{
            .pcm = pcm,
            .format = format,
            .channels = channels,
            .period = @intCast(period),
            .lead_s = @as(f64, @floatFromInt(buffer - period)) / @as(f64, @floatFromInt(rate)),
        };
    }

    /// Waits until a whole period fits, so the caller mixes only then. False on a timeout or a
    /// recovered underrun; the caller loops, which lets it notice when to stop.
    pub fn waitRoom(o: *Out) bool {
        const r = c.snd_pcm_wait(o.pcm, 100);
        if (r < 0) _ = c.snd_pcm_recover(o.pcm, r, 1);
        return r > 0;
    }

    /// Writes one period of stereo float, converted to what the device takes.
    pub fn write(o: *Out, stereo: []const f32, scratch: []u8) void {
        const bytes = interleave(scratch, stereo, o.channels, o.format);
        const n = c.snd_pcm_writei(o.pcm, bytes.ptr, o.period);
        if (n < 0) _ = c.snd_pcm_recover(o.pcm, @intCast(n), 1);
    }

    pub fn close(o: *Out) void {
        _ = c.snd_pcm_drop(o.pcm);
        _ = c.snd_pcm_close(o.pcm);
    }
};

fn check(r: c_int) !void {
    if (r < 0) return error.Refused;
}

/// Stereo float into the device's layout: integers clip instead of wrapping, extra channels stay silent.
fn interleave(dst: []u8, stereo: []const f32, channels: u32, format: Format) []u8 {
    const frames = stereo.len / 2;
    const size: usize = if (format == .s16) 2 else 4;
    const out = dst[0 .. frames * channels * size];
    @memset(out, 0);
    for (0..frames) |i| for (0..2) |ch| {
        const v = stereo[i * 2 + ch];
        const at = out[(i * channels + ch) * size ..][0..size];
        switch (format) {
            .f32 => std.mem.writeInt(u32, at[0..4], @bitCast(v), .little),
            .s32 => std.mem.writeInt(i32, at[0..4], @intFromFloat(std.math.clamp(v, -1, 1) * 2147483520.0), .little),
            .s16 => std.mem.writeInt(i16, at[0..2], @intFromFloat(std.math.clamp(v, -1, 1) * 32767.0), .little),
        }
    };
    return out;
}

/// ALSA's output PCMs by the names `open` takes.
pub fn outputNames(a: std.mem.Allocator) []const []const u8 {
    var hints: [*c]?*anyopaque = null;
    if (c.snd_device_name_hint(-1, "pcm", &hints) < 0) return &.{};
    defer _ = c.snd_device_name_free_hint(hints);
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (hints[i]) |h| : (i += 1) {
        const name = c.snd_device_name_get_hint(h, "NAME") orelse continue;
        defer std.c.free(name);
        const io = c.snd_device_name_get_hint(h, "IOID");
        defer if (io != null) std.c.free(io);
        if (io != null and !std.mem.eql(u8, std.mem.span(io), "Output")) continue;
        if (std.mem.eql(u8, std.mem.span(name), "null")) continue;
        names.append(a, a.dupe(u8, std.mem.span(name)) catch return names.items) catch return names.items;
    }
    hardwareNames(a, &names);
    return names.items;
}

/// The hints leave out raw hardware, the lowest-latency path where no sound server holds the card.
fn hardwareNames(a: std.mem.Allocator, names: *std.ArrayList([]const u8)) void {
    var info: ?*c.snd_pcm_info_t = null;
    if (c.snd_pcm_info_malloc(&info) < 0) return;
    defer c.snd_pcm_info_free(info);
    var card: c_int = -1;
    while (c.snd_card_next(&card) == 0 and card >= 0) {
        var ctl_buf: [16]u8 = undefined;
        const ctl_name = std.fmt.bufPrintSentinel(&ctl_buf, "hw:{d}", .{card}, 0) catch continue;
        var ctl: ?*c.snd_ctl_t = null;
        if (c.snd_ctl_open(&ctl, ctl_name, 0) < 0) continue;
        defer _ = c.snd_ctl_close(ctl);
        var dev: c_int = -1;
        while (c.snd_ctl_pcm_next_device(ctl, &dev) == 0 and dev >= 0) {
            c.snd_pcm_info_set_device(info, @intCast(dev));
            c.snd_pcm_info_set_subdevice(info, 0);
            c.snd_pcm_info_set_stream(info, c.SND_PCM_STREAM_PLAYBACK);
            if (c.snd_ctl_pcm_info(ctl, info) < 0) continue;
            const name = std.fmt.allocPrint(a, "hw:{d},{d}", .{ card, dev }) catch return;
            names.append(a, name) catch return;
        }
    }
}

/// PortAudio named hardware "Card: Device (hw:0,0)"; a config saved then still opens the same device.
pub fn fromPortAudioName(name: []const u8) []const u8 {
    if (!std.mem.endsWith(u8, name, ")")) return name;
    const at = std.mem.lastIndexOf(u8, name, "(hw:") orelse return name;
    return name[at + 1 .. name.len - 1];
}

test "interleaving clips integers and silences extra channels" {
    var buf: [64]u8 = undefined;
    const s16 = interleave(&buf, &.{ 1.5, -1.5 }, 4, .s16);
    try std.testing.expectEqual(@as(usize, 8), s16.len);
    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, s16[0..2], .little));
    try std.testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, s16[2..4], .little));
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, s16[4..6], .little));
    try std.testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, s16[6..8], .little));
    const s32 = interleave(&buf, &.{ 0.5, -2, 0, 1 }, 2, .s32);
    try std.testing.expectEqual(@as(usize, 16), s32.len);
    try std.testing.expect(std.mem.readInt(i32, s32[0..4], .little) > 1 << 29);
    try std.testing.expect(std.mem.readInt(i32, s32[4..8], .little) < -(1 << 30));
    try std.testing.expect(std.mem.readInt(i32, s32[12..16], .little) > 0);
    const f = interleave(&buf, &.{ 1.5, 0.25 }, 2, .f32);
    try std.testing.expectEqual(@as(f32, 1.5), @as(f32, @bitCast(std.mem.readInt(u32, f[0..4], .little))));
}

test "a PortAudio hardware name maps to the ALSA one" {
    try std.testing.expectEqualStrings("hw:0,0", fromPortAudioName("HDA Intel PCH: ALC897 Analog (hw:0,0)"));
    try std.testing.expectEqualStrings("sidealsa_pro_lowlat", fromPortAudioName("sidealsa_pro_lowlat"));
    try std.testing.expectEqualStrings("Odd (name)", fromPortAudioName("Odd (name)"));
}
