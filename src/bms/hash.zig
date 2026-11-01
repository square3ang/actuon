//! Chart identity: lowercase hex MD5 and SHA-256 of the raw file bytes (as beatoraja).
const std = @import("std");
const Chart = @import("../core/types.zig").Chart;

pub fn fill(chart: *Chart, data: []const u8) void {
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(data, &md5, .{});
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &sha, .{});
    chart.md5 = std.fmt.bytesToHex(md5, .lower);
    chart.sha256 = std.fmt.bytesToHex(sha, .lower);
}
