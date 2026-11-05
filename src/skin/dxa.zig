const std = @import("std");
const core = @import("actuon_core");

pub const Error = error{BadArchive} || std.mem.Allocator.Error;
pub const Member = struct { name: []const u8, data: []const u8 };

/// From 0x0005 DxLib keys file data by its size, not its offset, which this reader does not do.
const max_version = 4;
const max_member = 1 << 24;
const dir_attribute = 0x10;
/// DxLib's MIN_COMPRESS: the encoder subtracts it from every copy length.
const min_copy = 4;

/// DXArchive::KeyCreate without a key string, which is how LR2 packs its fonts.
const default_key = blk: {
    var k: [12]u8 = @splat(0xaa);
    k[0] = ~k[0];
    k[1] = std.math.rotl(u8, k[1], 4);
    k[2] ^= 0x8a;
    k[3] = ~std.math.rotl(u8, k[3], 4);
    k[4] = ~k[4];
    k[5] ^= 0xac;
    k[6] = ~k[6];
    k[7] = ~std.math.rotr(u8, k[7], 3);
    k[8] = std.math.rotr(u8, k[8], 5);
    k[9] ^= 0x7f;
    k[10] = std.math.rotl(u8, k[10], 4) ^ 0xd6;
    k[11] ^= 0xcc;
    break :blk k;
};
/// Archives before version 2 are keyed with plain 0xff bytes.
const old_key: [12]u8 = @splat(0xff);

fn slice(b: []const u8, off: u64, len: u64) Error![]const u8 {
    if (off > b.len or len > b.len - off) return error.BadArchive;
    return b[@intCast(off)..][0..@intCast(len)];
}

fn word(b: []const u8, off: u64) Error!u32 {
    return std.mem.readInt(u32, (try slice(b, off, 4))[0..4], .little);
}

/// The files in the archive's root folder. `bytes` is decrypted in place.
pub fn members(a: std.mem.Allocator, bytes: []u8) Error![]const Member {
    if (bytes.len < 24) return error.BadArchive;
    const key = for ([_][12]u8{ default_key, old_key }) |k| {
        if (bytes[0] ^ k[0] == 'D' and bytes[1] ^ k[1] == 'X') break k;
    } else return error.BadArchive;
    for (bytes, 0..) |*b, i| b.* ^= key[i % key.len];

    const version = std.mem.readInt(u16, bytes[2..4], .little);
    if (version == 0 or version > max_version) return error.BadArchive;
    const table = try slice(bytes, try word(bytes, 12), try word(bytes, 4));
    const data_start = try word(bytes, 8);
    const file_table = try word(bytes, 16);
    const root = try word(bytes, 20);
    const head_len: u64 = if (version >= 2) 44 else 40;
    const count = try word(table, @as(u64, root) + 8);
    const first = @as(u64, file_table) + try word(table, @as(u64, root) + 12);

    var out: std.ArrayList(Member) = .empty;
    for (0..count) |i| {
        const head = try slice(table, first + i * head_len, head_len);
        if (try word(head, 4) & dir_attribute != 0) continue;
        const size = try word(head, 36);
        if (size > max_member) return error.BadArchive;
        const at = @as(u64, data_start) + try word(head, 32);
        const press: u32 = if (version >= 2) try word(head, 40) else 0xffff_ffff;
        const data = if (press == 0xffff_ffff) try slice(bytes, at, size) else try decode(a, try slice(bytes, at, press), size);
        try out.append(a, .{ .name = try nameAt(a, table, try word(head, 0)), .data = data });
    }
    return out.items;
}

/// A name is a u16 count of 4-byte units, a u16 checksum, the name in upper case, then as written.
fn nameAt(a: std.mem.Allocator, table: []const u8, at: u64) Error![]const u8 {
    const units: u64 = std.mem.readInt(u16, (try slice(table, at, 2))[0..2], .little);
    const raw = std.mem.sliceTo(try slice(table, at + 4 + units * 4, units * 4), 0);
    const name = if (std.unicode.utf8ValidateSlice(raw)) raw else try core.encoding.toUtf8(a, raw, .sjis);
    // Checked after decoding: a Shift-JIS second byte can be a backslash.
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.mem.indexOfAny(u8, name, "/\\:\x00") != null) return error.BadArchive;
    return name;
}

/// DXArchive::Decode, with every read and copy bounded.
fn decode(a: std.mem.Allocator, src: []const u8, size: u32) Error![]u8 {
    if (src.len < 9 or std.mem.readInt(u32, src[0..4], .little) != size) return error.BadArchive;
    const s = try slice(src, 9, @as(u64, std.mem.readInt(u32, src[4..8], .little)) -| 9);
    const keycode = src[8];
    const out = try a.alloc(u8, size);
    var dp: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != keycode or (i + 1 < s.len and s[i + 1] == keycode)) {
            if (dp >= out.len) return error.BadArchive;
            out[dp] = s[i];
            dp += 1;
            i += if (s[i] == keycode) 2 else 1;
            continue;
        }
        if (i + 1 >= s.len) return error.BadArchive;
        var code: u32 = s[i + 1];
        // The encoder adds one to codes at or above the keycode so they never read as it.
        if (code > keycode) code -= 1;
        i += 2;
        var len: usize = code >> 3;
        if (code & 4 != 0) {
            if (i >= s.len) return error.BadArchive;
            len |= @as(usize, s[i]) << 5;
            i += 1;
        }
        len += min_copy;
        const index_len: usize = (code & 3) + 1;
        if (index_len > 3 or index_len > s.len - i) return error.BadArchive;
        var back: usize = 0;
        for (s[i..][0..index_len], 0..) |b, n| back |= @as(usize, b) << @intCast(8 * n);
        back += 1;
        i += index_len;
        if (back > dp or len > out.len - dp) return error.BadArchive;
        for (0..len) |_| {
            out[dp] = out[dp - back];
            dp += 1;
        }
    }
    if (dp != out.len) return error.BadArchive;
    return out;
}

/// For tests: a version 4 archive of root files, the first stored and the rest packed as given.
pub fn testArchive(a: std.mem.Allocator, files: []const Member, packed_data: []const []const u8) ![]u8 {
    var data: std.ArrayList(u8) = .empty;
    var names: std.ArrayList(u8) = .empty;
    var heads: std.ArrayList(u8) = .empty;
    for (files, 0..) |f, n| {
        const units: u16 = @intCast((f.name.len + 4) / 4);
        const name_at: u32 = @intCast(names.items.len);
        var unit_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &unit_buf, units, .little);
        try names.appendSlice(a, &unit_buf);
        try names.appendSlice(a, &.{ 0, 0 });
        for (0..2) |_| {
            try names.appendSlice(a, f.name);
            try names.appendNTimes(a, 0, units * 4 - f.name.len);
        }
        const stored = n == 0;
        const body = if (stored) f.data else packed_data[n - 1];
        var head: [44]u8 = @splat(0);
        std.mem.writeInt(u32, head[0..4], name_at, .little);
        std.mem.writeInt(u32, head[32..36], @intCast(data.items.len), .little);
        std.mem.writeInt(u32, head[36..40], @intCast(f.data.len), .little);
        std.mem.writeInt(u32, head[40..44], if (stored) 0xffff_ffff else @intCast(body.len), .little);
        try heads.appendSlice(a, &head);
        try data.appendSlice(a, body);
    }
    var dir: [16]u8 = @splat(0);
    std.mem.writeInt(u32, dir[8..12], @intCast(files.len), .little);
    var out: std.ArrayList(u8) = .empty;
    var head: [28]u8 = @splat(0);
    head[0] = 'D';
    head[1] = 'X';
    std.mem.writeInt(u16, head[2..4], 4, .little);
    std.mem.writeInt(u32, head[4..8], @intCast(names.items.len + heads.items.len + dir.len), .little);
    std.mem.writeInt(u32, head[8..12], head.len, .little);
    std.mem.writeInt(u32, head[12..16], @intCast(head.len + data.items.len), .little);
    std.mem.writeInt(u32, head[16..20], @intCast(names.items.len), .little);
    std.mem.writeInt(u32, head[20..24], @intCast(names.items.len + heads.items.len), .little);
    for ([_][]const u8{ &head, data.items, names.items, heads.items, &dir }) |part| try out.appendSlice(a, part);
    for (out.items, 0..) |*b, i| b.* ^= default_key[i % default_key.len];
    return out.items;
}

test "an archive's stored and packed files are read back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // "abc", a copy of 9 from 3 back, then a doubled keycode for a literal 0xff.
    const packed_abc = "\x0d\x00\x00\x00\x11\x00\x00\x00\xff" ++ "abc\xff\x28\x02\xff\xff";
    const bytes = try testArchive(a, &.{ .{ .name = "font.lr2font", .data = "#S,24\n" }, .{ .name = "page.png", .data = "abcabcabcabc\xff" } }, &.{packed_abc});
    const got = try members(a, bytes);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("font.lr2font", got[0].name);
    try std.testing.expectEqualStrings("#S,24\n", got[0].data);
    try std.testing.expectEqualStrings("page.png", got[1].name);
    try std.testing.expectEqualStrings("abcabcabcabc\xff", got[1].data);
}

test "bad headers, names, sizes and copies are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "#S,24\n";
    try std.testing.expectError(error.BadArchive, members(a, try a.dupe(u8, "not an archive at all, really")));
    try std.testing.expectError(error.BadArchive, members(a, try a.dupe(u8, "DX")));
    try std.testing.expectError(error.BadArchive, members(a, try testArchive(a, &.{.{ .name = "../x", .data = plain }}, &.{})));
    try std.testing.expectError(error.BadArchive, members(a, try testArchive(a, &.{.{ .name = "a\\b", .data = plain }}, &.{})));
    const bad_version = try testArchive(a, &.{.{ .name = "a", .data = plain }}, &.{});
    bad_version[2] ^= 4 ^ 5;
    try std.testing.expectError(error.BadArchive, members(a, bad_version));
    const cut = try testArchive(a, &.{.{ .name = "a", .data = plain }}, &.{});
    try std.testing.expectError(error.BadArchive, members(a, cut[0 .. cut.len - 4]));
    // A copy from before the start of the output.
    const reaches_back = "\x08\x00\x00\x00\x0d\x00\x00\x00\xff" ++ "a\xff\x20\x05";
    try std.testing.expectError(error.BadArchive, members(a, try testArchive(a, &.{ .{ .name = "a", .data = plain }, .{ .name = "b", .data = "aaaaaaaa" } }, &.{reaches_back})));
    // A length that would write past the size it claims.
    const too_long = "\x03\x00\x00\x00\x0d\x00\x00\x00\xff" ++ "a\xff\x20\x00";
    try std.testing.expectError(error.BadArchive, members(a, try testArchive(a, &.{ .{ .name = "a", .data = plain }, .{ .name = "b", .data = "aaa" } }, &.{too_long})));
}
