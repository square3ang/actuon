const std = @import("std");
const tables = @import("enc_tables.zig");

pub const Encoding = enum { utf8, utf16le, utf16be, euckr, sjis };

fn cp932At(lead: u8, trail: u8) u16 {
    if (lead < 0x81 or lead > 0xFC or trail < 0x40 or trail > 0xFC) return 0;
    return tables.cp932[@as(usize, lead - 0x81) * (0xFC - 0x40 + 1) + (trail - 0x40)];
}

fn cp949At(lead: u8, trail: u8) u16 {
    if (lead < 0x81 or lead > 0xFE or trail < 0x41 or trail > 0xFE) return 0;
    return tables.cp949[@as(usize, lead - 0x81) * (0xFE - 0x41 + 1) + (trail - 0x41)];
}

fn isStrictEucKr(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c < 0x80) {
            i += 1;
            continue;
        }
        if (i + 1 >= bytes.len) return true; // a sample may cut a character in half
        const t = bytes[i + 1];
        if (c < 0xA1 or c > 0xFE or t < 0xA1 or t > 0xFE or cp949At(c, t) == 0) return false;
        i += 2;
    }
    return true;
}

/// beatoraja's order (EUC-KR before MS932), after UTF-8, which legacy text almost never passes as.
pub fn detect(bytes: []const u8) Encoding {
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) return .utf8;
    if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) return .utf16le;
    if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) return .utf16be;
    const sample = bytes[0..@min(bytes.len, 64 * 1024)];
    var end = sample.len;
    // a truncated sample may split a UTF-8 sequence
    if (sample.len < bytes.len) {
        var back: usize = 0;
        while (back < 3 and end > 0 and sample[end - 1] & 0xC0 == 0x80) : (back += 1) end -= 1;
        if (end > 0 and sample[end - 1] >= 0xC0) end -= 1;
    }
    if (std.unicode.utf8ValidateSlice(sample[0..end])) return .utf8;
    if (isStrictEucKr(sample)) return .euckr;
    return .sjis;
}

pub fn toUtf8(gpa: std.mem.Allocator, bytes: []const u8, enc: Encoding) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, bytes.len);
    var i: usize = 0;
    switch (enc) {
        .utf8 => {
            if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) i = 3;
            while (i < bytes.len) {
                const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
                if (n > 0 and i + n <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + n])) {
                    try out.appendSlice(gpa, bytes[i .. i + n]);
                    i += n;
                } else {
                    try appendCp(&out, gpa, 0xFFFD);
                    i += 1;
                }
            }
        },
        .utf16le, .utf16be => {
            i = 2;
            while (i + 1 < bytes.len) : (i += 2) {
                const u: u21 = if (enc == .utf16le)
                    @as(u21, bytes[i]) | (@as(u21, bytes[i + 1]) << 8)
                else
                    (@as(u21, bytes[i]) << 8) | bytes[i + 1];
                if (u >= 0xD800 and u < 0xDC00 and i + 3 < bytes.len) {
                    const v: u21 = if (enc == .utf16le)
                        @as(u21, bytes[i + 2]) | (@as(u21, bytes[i + 3]) << 8)
                    else
                        (@as(u21, bytes[i + 2]) << 8) | bytes[i + 3];
                    if (v >= 0xDC00 and v < 0xE000) {
                        try appendCp(&out, gpa, 0x10000 + ((u - 0xD800) << 10) + (v - 0xDC00));
                        i += 2;
                        continue;
                    }
                }
                try appendCp(&out, gpa, if (u >= 0xD800 and u < 0xE000) 0xFFFD else u);
            }
        },
        .euckr, .sjis => while (i < bytes.len) {
            const c = bytes[i];
            if (c < 0x80) {
                try out.append(gpa, c);
                i += 1;
            } else if (enc == .sjis and c >= 0xA1 and c <= 0xDF) {
                try appendCp(&out, gpa, 0xFF61 + @as(u21, c - 0xA1)); // half-width katakana
                i += 1;
            } else if (i + 1 < bytes.len) {
                const u = if (enc == .sjis) cp932At(c, bytes[i + 1]) else cp949At(c, bytes[i + 1]);
                if (u != 0) {
                    try appendCp(&out, gpa, u);
                    i += 2;
                } else {
                    try appendCp(&out, gpa, 0xFFFD);
                    i += 1;
                }
            } else {
                try appendCp(&out, gpa, 0xFFFD);
                i += 1;
            }
        },
    }
    return out.toOwnedSlice(gpa);
}

fn appendCp(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try out.appendSlice(gpa, buf[0..n]);
}

test "detect and decode" {
    const gpa = std.testing.allocator;
    // "テスト" in Shift-JIS
    const sjis = "\x83\x65\x83\x58\x83\x67";
    try std.testing.expectEqual(Encoding.sjis, detect(sjis));
    const a = try toUtf8(gpa, sjis, .sjis);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("テスト", a);
    // "한글" in EUC-KR
    const euc = "\xC7\xD1\xB1\xDB";
    try std.testing.expectEqual(Encoding.euckr, detect(euc));
    const b = try toUtf8(gpa, euc, .euckr);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("한글", b);
    try std.testing.expectEqual(Encoding.utf8, detect("한글 テスト"));
}
