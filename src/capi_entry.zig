//! The IR server re-simulates replays with the same code the client plays with.
const std = @import("std");
const core = @import("actuon_core.zig");
const replay = core.replay;

pub const VerifyInput = extern struct {
    chart: [*]const u8,
    chart_len: usize,
    replay: [*]const u8,
    replay_len: usize,
    /// 1 = BMS, 2 = PMS, 3 = BMSON; anything else reads as BMS
    format: u8,
};

fn formatOf(n: u8) core.Format {
    return if (n == 2) .pms else if (n == 3) .bmson else .bms;
}

/// The judge steps every ms to the end, so a longer chart could hold a check slot; one hour simulates in ~0.1 s.
const max_song_us: i64 = 3600 * std.time.us_per_s;
/// Keys still held on the result screen come after the end, but nothing that late can change a score.
const max_overrun_us: i64 = 600 * std.time.us_per_s;

fn tooLong(chart: *const core.types.Chart) bool {
    return chart.last_time_us > max_song_us;
}

/// Returns 0 on success; negative codes: -1 malformed replay, -2 malformed chart or one PMS parsing cuts notes from, -3 hash mismatch.
export fn actuon_verify(input: *const VerifyInput, out: *replay.Result) callconv(.c) i32 {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const chart_bytes = input.chart[0..input.chart_len];
    const r = replay.decode(a, input.replay[0..input.replay_len]) catch return -1;
    // A CN or HCN play changes the note count, so it cannot rank against the chart's own board.
    if (r.ln_mode != .ln) return -1;
    const format = formatOf(input.format);
    var chart = core.parse(gpa, format, chart_bytes, .{ .selected_random = r.bms_random }) catch return -2;
    defer chart.deinit();
    if (!std.mem.eql(u8, &chart.sha256, &r.sha256)) return -3;
    // HARD and EXHARD start full, so a play with nothing to hit would still clear as MAX.
    if (chart.total_notes == 0 or tooLong(&chart)) return -2;
    if (r.events.len > 0 and r.events[r.events.len - 1].time_us > chart.last_time_us + max_overrun_us) return -1;
    // PMS drops lane-less channels, so a BMS chart named PMS could MAX the rest; a real PMS chart reads the same as BMS.
    if (format == .pms) {
        var whole = core.bms.parse(gpa, chart_bytes, .{ .selected_random = r.bms_random }) catch return -2;
        defer whole.deinit();
        if (whole.total_notes != chart.total_notes) return -2;
    }
    out.* = replay.resimulate(gpa, &chart, r) catch return -2;
    return 0;
}

pub const ChartInfo = extern struct {
    /// UTF-8, NUL-terminated, cut short when longer than the field.
    title: [256]u8,
    artist: [256]u8,
};

fn copyText(out: *[256]u8, text: []const u8) void {
    const n = @min(text.len, out.len - 1);
    @memcpy(out[0..n], text[0..n]);
    out[n] = 0;
}

/// 0 when the bytes parse as a chart with notes to play, else -2.
export fn actuon_check_chart(data: [*]const u8, len: usize, format: u8, info: *ChartInfo) callconv(.c) i32 {
    const gpa = std.heap.c_allocator;
    const bytes = data[0..len];
    var chart = core.parse(gpa, formatOf(format), bytes, .{}) catch return -2;
    defer chart.deinit();
    if (chart.total_notes == 0 or tooLong(&chart)) return -2;
    copyText(&info.title, chart.title);
    copyText(&info.artist, chart.artist);
    return 0;
}

export fn actuon_chart_hash(data: [*]const u8, len: usize, sha256_hex: *[64]u8, md5_hex: *[32]u8) callconv(.c) void {
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data[0..len], &sha, .{});
    sha256_hex.* = std.fmt.bytesToHex(sha, .lower);
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data[0..len], &md5, .{});
    md5_hex.* = std.fmt.bytesToHex(md5, .lower);
}

fn verifyWith(chart_src: []const u8, r: replay.Replay) !i32 {
    const gpa = std.testing.allocator;
    var chart = try core.parse(gpa, .bms, chart_src, .{});
    defer chart.deinit();
    var with_hash = r;
    with_hash.sha256 = chart.sha256;
    const bytes = try replay.encode(gpa, with_hash);
    defer gpa.free(bytes);
    var out: replay.Result = .{};
    return actuon_verify(&.{ .chart = chart_src.ptr, .chart_len = chart_src.len, .replay = bytes.ptr, .replay_len = bytes.len, .format = 1 }, &out);
}

test "the server refuses a CN play and a chart with nothing to hit" {
    const chart = "#BPM 120\n#WAV01 a.wav\n#00111:01\n";
    try std.testing.expectEqual(@as(i32, 0), try verifyWith(chart, .{}));
    try std.testing.expectEqual(@as(i32, -1), try verifyWith(chart, .{ .ln_mode = .cn }));
    try std.testing.expectEqual(@as(i32, -2), try verifyWith("#BPM 120\n#WAV01 a.wav\n#00101:01\n", .{ .gauge = .hard }));
}
