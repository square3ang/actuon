//! C ABI of libactuon_core: the IR server re-simulates replays with the same code the client plays with.
const std = @import("std");
const core = @import("actuon_core.zig");
const replay = core.replay;

pub const VerifyInput = extern struct {
    chart: [*]const u8,
    chart_len: usize,
    replay: [*]const u8,
    replay_len: usize,
    /// 0 = decide by content, 1 = BMS, 2 = PMS, 3 = BMSON
    format: u8,
};

/// Returns 0 on success; negative codes: -1 malformed replay, -2 malformed chart, -3 hash mismatch.
export fn actuon_verify(input: *const VerifyInput, out: *replay.Result) callconv(.c) i32 {
    const gpa = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const chart_bytes = input.chart[0..input.chart_len];
    const r = replay.decode(a, input.replay[0..input.replay_len]) catch return -1;
    // A CN or HCN play changes the note count, so it cannot rank against the chart's own board.
    if (r.ln_mode != .ln) return -1;
    var chart = (if (input.format == 3)
        core.bmson.parse(gpa, chart_bytes)
    else
        core.bms.parse(gpa, chart_bytes, .{ .is_pms = input.format == 2, .selected_random = r.bms_random })) catch return -2;
    defer chart.deinit();
    if (!std.mem.eql(u8, &chart.sha256, &r.sha256)) return -3;
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

/// Returns 0 when the bytes parse as a chart with notes to play, and names it in `info`. Otherwise -2.
export fn actuon_check_chart(data: [*]const u8, len: usize, format: u8, info: *ChartInfo) callconv(.c) i32 {
    const gpa = std.heap.c_allocator;
    const bytes = data[0..len];
    var chart = (if (format == 3) core.bmson.parse(gpa, bytes) else core.bms.parse(gpa, bytes, .{ .is_pms = format == 2 })) catch return -2;
    defer chart.deinit();
    if (chart.total_notes == 0) return -2;
    copyText(&info.title, chart.title);
    copyText(&info.artist, chart.artist);
    return 0;
}

/// Lowercase hex SHA-256 and MD5 of a chart file, without decoding it.
export fn actuon_chart_hash(data: [*]const u8, len: usize, sha256_hex: *[64]u8, md5_hex: *[32]u8) callconv(.c) void {
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data[0..len], &sha, .{});
    sha256_hex.* = std.fmt.bytesToHex(sha, .lower);
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data[0..len], &md5, .{});
    md5_hex.* = std.fmt.bytesToHex(md5, .lower);
}
