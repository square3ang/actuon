const std = @import("std");

pub const Ed25519 = std.crypto.sign.Ed25519;

/// `name` is "<tag>/<asset>", the end of the download URL, so a signature cannot vouch for an older release or another asset.
pub fn message(a: std.mem.Allocator, name: []const u8, sha256: [32]u8) ![]u8 {
    return std.fmt.allocPrint(a, "actuon-release {s} {s}", .{ name, &std.fmt.bytesToHex(sha256, .lower) });
}

/// Releases are tagged "v" plus the version; a signature made for any other tag would fail on every install.
pub fn checkTag(tag: []const u8) !void {
    if (!std.mem.startsWith(u8, tag, "v")) return error.BadTag;
    _ = std.SemanticVersion.parse(tag[1..]) catch return error.BadTag;
}

test "only a v-prefixed version is a release tag" {
    try checkTag("v1.2.3");
    for ([_][]const u8{ "1.2.3", "v1.2", "release", "v1.2.3/x" }) |tag| try std.testing.expectError(error.BadTag, checkTag(tag));
}
