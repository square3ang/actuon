const std = @import("std");

pub const Ed25519 = std.crypto.sign.Ed25519;

/// `name` is "<tag>/<asset>", the end of the download URL, so a signature cannot vouch for an older release or another asset.
pub fn message(a: std.mem.Allocator, name: []const u8, sha256: [32]u8) ![]u8 {
    return std.fmt.allocPrint(a, "actuon-release {s} {s}", .{ name, &std.fmt.bytesToHex(sha256, .lower) });
}
