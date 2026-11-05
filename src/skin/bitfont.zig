const std = @import("std");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");
const lr2csv = @import("lr2csv.zig");
const dxa = @import("dxa.zig");

const max_file = 1 << 24;
const max_pages = 256;
/// A skin file can name the same big font over and over.
pub const max_fonts = 64;
const max_fields = 7;

pub const Glyph = struct {
    page: u16 = 0,
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    x_offset: f32 = 0,
    y_offset: f32 = 0,
    advance: f32 = 0,
};

pub const BitmapFont = struct {
    size: f32 = 0,
    /// .lr2font only, in skin pixels.
    margin: f32 = 0,
    /// LR2 stretches each glyph to the text's height and squeezes the line into its width.
    lr2: bool = false,
    pages: []const ?[]const u8 = &.{},
    first_tex: i32 = 0,
    glyphs: std.AutoHashMapUnmanaged(u32, Glyph) = .empty,
    /// BMFont only: first code point << 32 | second.
    kerning: std.AutoHashMapUnmanaged(u64, f32) = .empty,

    pub fn kern(font: *const BitmapFont, prev: ?u32, cp: u32) f32 {
        return font.kerning.get((@as(u64, prev orelse return 0) << 32) | cp) orelse 0;
    }
};

fn pagePath(a: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ?[]const u8 {
    const norm = a.dupe(u8, name) catch return null;
    std.mem.replaceScalar(u8, norm, '\\', '/');
    if (fs.climbs(norm) or std.fs.path.isAbsolute(norm)) return null;
    return lr2csv.walk(a, io, dir, norm);
}

fn setPage(a: std.mem.Allocator, io: std.Io, pages: *std.ArrayList(?[]const u8), dir: []const u8, id: i64, name: []const u8) !void {
    if (id < 0 or id >= max_pages) return;
    const i: usize = @intCast(id);
    while (pages.items.len <= i) try pages.append(a, null);
    pages.items[i] = pagePath(a, io, dir, name);
}

/// LR2 numbers a glyph by its Shift-JIS code with the gaps closed.
fn lr2Code(code: i64) ?u32 {
    if (code < 0 or code > 0xffff) return null;
    var buf: [2]u8 = undefined;
    const sjis: []const u8 = if (code >= 256) blk: {
        const v: u16 = @truncate(@as(u64, @intCast(code + (if (code >= 8127) @as(i64, 49281) else 32832))));
        buf = .{ @intCast(v >> 8), @intCast(v & 0xff) };
        break :blk &buf;
    } else blk: {
        buf[0] = @intCast(code);
        break :blk buf[0..1];
    };
    var out: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&out);
    const text = core.encoding.toUtf8(fba.allocator(), sjis, .sjis) catch return null;
    if (text.len == 0) return null;
    const n = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (n > text.len) return null;
    return std.unicode.utf8Decode(text[0..n]) catch null;
}

fn fieldInt(fields: []const []const u8, i: usize) i64 {
    if (i >= fields.len) return 0;
    return std.fmt.parseInt(i64, std.mem.trim(u8, fields[i], " "), 10) catch 0;
}

fn parseLr2(a: std.mem.Allocator, io: std.Io, text: []const u8, dir: []const u8) !?*BitmapFont {
    const font = try a.create(BitmapFont);
    font.* = .{ .lr2 = true };
    var pages: std.ArrayList(?[]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r\t");
        if (line.len < 2 or line[0] != '#') continue;
        var fields: [max_fields][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.splitScalar(u8, line, ',');
        while (count < max_fields) : (count += 1) fields[count] = it.next() orelse break;
        const f = fields[0..count];
        if (std.mem.eql(u8, f[0], "#S")) {
            font.size = @floatFromInt(fieldInt(f, 1));
        } else if (std.mem.eql(u8, f[0], "#M")) {
            font.margin = @floatFromInt(fieldInt(f, 1));
        } else if (std.mem.eql(u8, f[0], "#T") and f.len > 2) {
            try setPage(a, io, &pages, dir, fieldInt(f, 1), f[2]);
        } else if (std.mem.eql(u8, f[0], "#R") and f.len > 6) {
            const page = fieldInt(f, 2);
            if (page < 0 or page >= pages.items.len or pages.items[@intCast(page)] == null) continue;
            const w: f32 = @floatFromInt(fieldInt(f, 5));
            const glyph: Glyph = .{ .page = @intCast(page), .x = @floatFromInt(fieldInt(f, 3)), .y = @floatFromInt(fieldInt(f, 4)), .w = w, .h = @floatFromInt(fieldInt(f, 6)), .advance = w };
            const code = fieldInt(f, 1);
            // LR2's wave dash stands for both of the characters it is confused with.
            if (code == 288) {
                try font.glyphs.put(a, 0x301c, glyph);
                try font.glyphs.put(a, 0xff5e, glyph);
            } else if (lr2Code(code)) |cp| try font.glyphs.put(a, cp, glyph);
        }
    }
    if (font.size <= 0 or font.glyphs.count() == 0) return null;
    font.pages = pages.items;
    return font;
}

fn bmValue(line: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and line[i] == ' ') i += 1;
        const name_start = i;
        while (i < line.len and line[i] != ' ' and line[i] != '=') i += 1;
        const name = line[name_start..i];
        if (i >= line.len or line[i] != '=') continue;
        i += 1;
        const value_start = i;
        const quoted = i < line.len and line[i] == '"';
        if (quoted) i += 1;
        while (i < line.len and line[i] != (if (quoted) @as(u8, '"') else ' ')) i += 1;
        if (std.mem.eql(u8, name, key)) return if (quoted) line[value_start + 1 .. i] else line[value_start..i];
        if (quoted and i < line.len) i += 1;
    }
    return null;
}

fn bmInt(line: []const u8, key: []const u8) i64 {
    return std.fmt.parseInt(i64, bmValue(line, key) orelse return 0, 10) catch 0;
}

fn parseBm(a: std.mem.Allocator, io: std.Io, text: []const u8, dir: []const u8) !?*BitmapFont {
    const font = try a.create(BitmapFont);
    font.* = .{};
    var pages: std.ArrayList(?[]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "info ")) {
            font.size = @floatFromInt(@abs(bmInt(line, "size")));
        } else if (std.mem.startsWith(u8, line, "page ")) {
            try setPage(a, io, &pages, dir, bmInt(line, "id"), bmValue(line, "file") orelse continue);
        } else if (std.mem.startsWith(u8, line, "char ")) {
            const page = bmInt(line, "page");
            const id = bmInt(line, "id");
            if (page < 0 or page >= pages.items.len or pages.items[@intCast(page)] == null or id < 0 or id > 0x10ffff) continue;
            try font.glyphs.put(a, @intCast(id), .{
                .page = @intCast(page),
                .x = @floatFromInt(bmInt(line, "x")),
                .y = @floatFromInt(bmInt(line, "y")),
                .w = @floatFromInt(bmInt(line, "width")),
                .h = @floatFromInt(bmInt(line, "height")),
                .x_offset = @floatFromInt(bmInt(line, "xoffset")),
                .y_offset = @floatFromInt(bmInt(line, "yoffset")),
                .advance = @floatFromInt(bmInt(line, "xadvance")),
            });
        } else if (std.mem.startsWith(u8, line, "kerning ")) {
            const first = bmInt(line, "first");
            const second = bmInt(line, "second");
            if (first < 0 or first > 0x10ffff or second < 0 or second > 0x10ffff) continue;
            try font.kerning.put(a, (@as(u64, @intCast(first)) << 32) | @as(u64, @intCast(second)), @floatFromInt(bmInt(line, "amount")));
        }
    }
    if (font.size <= 0 or font.glyphs.count() == 0) return null;
    font.pages = pages.items;
    return font;
}

/// AngelCode's binary layout, version 3: blocks of a type byte and a little-endian length.
fn parseBmBinary(a: std.mem.Allocator, io: std.Io, bytes: []const u8, dir: []const u8) !?*BitmapFont {
    if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "BMF\x03")) return null;
    const font = try a.create(BitmapFont);
    font.* = .{};
    var pages: std.ArrayList(?[]const u8) = .empty;
    var chars: []const u8 = "";
    var at: usize = 4;
    while (bytes.len - at >= 5) {
        const kind = bytes[at];
        const len = std.mem.readInt(u32, bytes[at + 1 ..][0..4], .little);
        at += 5;
        if (len > bytes.len - at) return null;
        const block = bytes[at..][0..len];
        at += len;
        switch (kind) {
            1 => if (block.len >= 2) {
                font.size = @floatFromInt(@abs(std.mem.readInt(i16, block[0..2], .little)));
            },
            3 => {
                var names = std.mem.splitScalar(u8, block, 0);
                var id: i64 = 0;
                while (names.next()) |name| : (id += 1) {
                    if (name.len > 0) try setPage(a, io, &pages, dir, id, name);
                }
            },
            // Pages may come later, so glyphs are read after the loop.
            4 => chars = block,
            5 => {
                var k: usize = 0;
                while (block.len - k >= 10) : (k += 10) {
                    const first = std.mem.readInt(u32, block[k..][0..4], .little);
                    const second = std.mem.readInt(u32, block[k + 4 ..][0..4], .little);
                    if (first > 0x10ffff or second > 0x10ffff) continue;
                    try font.kerning.put(a, (@as(u64, first) << 32) | second, @floatFromInt(std.mem.readInt(i16, block[k + 8 ..][0..2], .little)));
                }
            },
            else => {},
        }
    }
    var k: usize = 0;
    while (chars.len - k >= 20) : (k += 20) {
        const ch = chars[k..][0..20];
        const id = std.mem.readInt(u32, ch[0..4], .little);
        const page = ch[18];
        if (page >= pages.items.len or pages.items[page] == null or id > 0x10ffff) continue;
        try font.glyphs.put(a, id, .{
            .page = page,
            .x = @floatFromInt(std.mem.readInt(u16, ch[4..6], .little)),
            .y = @floatFromInt(std.mem.readInt(u16, ch[6..8], .little)),
            .w = @floatFromInt(std.mem.readInt(u16, ch[8..10], .little)),
            .h = @floatFromInt(std.mem.readInt(u16, ch[10..12], .little)),
            .x_offset = @floatFromInt(std.mem.readInt(i16, ch[12..14], .little)),
            .y_offset = @floatFromInt(std.mem.readInt(i16, ch[14..16], .little)),
            .advance = @floatFromInt(std.mem.readInt(i16, ch[16..18], .little)),
        });
    }
    if (font.size <= 0 or font.glyphs.count() == 0) return null;
    font.pages = pages.items;
    return font;
}

pub fn load(a: std.mem.Allocator, io: std.Io, path: []const u8) ?*BitmapFont {
    // Apart from `a`: the skin keeps what it parses, and a font's text would stay as long as the skin.
    var tmp = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer tmp.deinit();
    const bytes = fs.readAlloc(tmp.allocator(), io, path, max_file) catch return null;
    if (std.ascii.endsWithIgnoreCase(path, ".dxa")) return loadDxa(a, io, tmp.allocator(), bytes);
    const dir = std.fs.path.dirname(path) orelse ".";
    if (std.ascii.endsWithIgnoreCase(path, ".lr2font")) {
        const text = if (std.unicode.utf8ValidateSlice(bytes)) bytes else core.encoding.toUtf8(tmp.allocator(), bytes, .sjis) catch return null;
        return parseLr2(a, io, text, dir) catch null;
    }
    if (std.mem.startsWith(u8, bytes, "BMF")) return parseBmBinary(a, io, bytes, dir) catch null;
    return parseBm(a, io, bytes, dir) catch null;
}

/// Pages load by path, so the archive is unpacked to disk, once per content.
fn loadDxa(a: std.mem.Allocator, io: std.Io, tmp: std.mem.Allocator, bytes: []u8) ?*BitmapFont {
    const data = fs.dataDir(tmp) catch return null;
    const dir = std.fmt.allocPrint(tmp, "{s}cache/dxa/{x}", .{ data, std.hash.Wyhash.hash(0, bytes) }) catch return null;
    if (!fs.exists(io, dir)) unpack(tmp, io, bytes, dir) catch |e| {
        std.log.warn("font archive unreadable: {t}", .{e});
        return null;
    };
    for (fs.list(tmp, io, dir) catch return null) |e| {
        if (std.ascii.endsWithIgnoreCase(e.name, ".lr2font")) return load(a, io, std.fs.path.join(tmp, &.{ dir, e.name }) catch return null);
    }
    return null;
}

fn unpack(a: std.mem.Allocator, io: std.Io, bytes: []u8, dir: []const u8) !void {
    const files = try dxa.members(a, bytes);
    // Written aside and renamed, so a half unpacked archive never passes for a whole one.
    const part = try std.fmt.allocPrint(a, "{s}.part", .{dir});
    fs.removeTree(io, part);
    errdefer fs.removeTree(io, part);
    try fs.mkdirs(io, part);
    for (files) |f| try fs.write(io, try std.fs.path.join(a, &.{ part, f.name }), f.data);
    try fs.rename(part, dir);
}

/// `loaded` counts every try: a failing one reads its file too.
pub fn loadCapped(a: std.mem.Allocator, io: std.Io, path: []const u8, loaded: *u32) ?*BitmapFont {
    if (loaded.* >= max_fonts) return null;
    loaded.* += 1;
    return load(a, io, path);
}

pub fn measure(font: *const BitmapFont, s: []const u8, scale: f32) f32 {
    var w: f32 = 0;
    var view = std.unicode.Utf8View.initUnchecked(s).iterator();
    if (!std.unicode.utf8ValidateSlice(s)) return 0;
    var prev: ?u32 = null;
    while (view.nextCodepoint()) |cp| {
        const g = font.glyphs.get(cp) orelse continue;
        w += (font.kern(prev, cp) + g.advance) * scale + font.margin;
        prev = cp;
    }
    return w;
}

test "an lr2font maps LR2 codes to characters and refuses pages outside its folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ dir, "a.png" }), "");
    const font = (try parseLr2(a, std.testing.io, "#S,24\r\n#M,2\r\n#T,0,a.png\r\n#T,1,../b.png\r\n#R,65,0,1,2,3,4\r\n#R,66,1,0,0,9,9\r\n#R,288,0,0,0,1,1\r\n", dir)).?;
    try std.testing.expectEqual(@as(f32, 24), font.size);
    const g = font.glyphs.get('A').?;
    try std.testing.expectEqual(@as(f32, 3), g.w);
    try std.testing.expect(font.glyphs.get('B') == null);
    try std.testing.expect(font.glyphs.get(0xff5e) != null);
    try std.testing.expectEqual(@as(f32, 5), measure(font, "A", 1));
    try std.testing.expectEqual(@as(?u32, 'あ'), lr2Code(0x82a0 - 32832));
}

test "an lr2font packed in a .dxa loads with its page, and a broken one gives none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fs.path.join(a, &.{ dir, "font.dxa" });
    try fs.write(io, path, try dxa.testArchive(a, &.{ .{ .name = "f.lr2font", .data = "#S,24\n#T,0,page.png\n#R,65,0,1,2,3,4\n" }, .{ .name = "page.png", .data = "" } }, &.{"\x00\x00\x00\x00\x09\x00\x00\x00\xff"}));
    const font = load(a, io, path).?;
    try std.testing.expect(std.mem.endsWith(u8, font.pages[0].?, "page.png"));
    try std.testing.expect(font.glyphs.get('A') != null);
    try fs.write(io, path, "DX but not really an archive");
    try std.testing.expect(load(a, io, path) == null);
}

test "a skin's fonts stop at the limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ dir, "a.png" }), "");
    const path = try std.fs.path.join(a, &.{ dir, "a.lr2font" });
    try fs.write(std.testing.io, path, "#S,24\n#T,0,a.png\n#R,65,0,1,2,3,4\n");
    var loaded: u32 = 0;
    try std.testing.expect(loadCapped(a, std.testing.io, path, &loaded) != null);
    loaded = max_fonts;
    try std.testing.expect(loadCapped(a, std.testing.io, path, &loaded) == null);
}

test "a font without a size is refused, and a BMFont reads its fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ dir, "page.png" }), "");
    try std.testing.expect((try parseBm(a, std.testing.io, "info size=9\npage id=0 file=\"gone.png\"\nchar id=65 page=0\n", dir)) == null);
    try std.testing.expect((try parseLr2(a, std.testing.io, "#T,0,a.png\n#R,65,0,1,2,3,4\n", ".")) == null);
    try std.testing.expect((try parseBm(a, std.testing.io, "not a font", ".")) == null);
    const font = (try parseBm(a, std.testing.io, "info face=\"a size=9\" size=-40 bold=0\r\npage id=0 file=\"page.png\"\r\nchar id=65 x=1 y=2 width=3 height=4 xoffset=-1 yoffset=5 xadvance=6 page=0\r\nchar id=66 page=9\r\nkernings count=2\r\nkerning first=65 second=65 amount=-2\r\nkerning first=-1 second=65 amount=9\r\n", dir)).?;
    try std.testing.expectEqual(@as(f32, 10), measure(font, "AA", 1));
    try std.testing.expectEqual(@as(usize, 1), font.kerning.count());
    try std.testing.expectEqual(@as(f32, 40), font.size);
    const g = font.glyphs.get('A').?;
    try std.testing.expectEqual(@as(f32, -1), g.x_offset);
    try std.testing.expectEqual(@as(f32, 6), g.advance);
    try std.testing.expect(font.glyphs.get('B') == null);
}

test "a binary BMFont reads its blocks, and a truncated or foreign one is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ dir, "page.png" }), "");
    const info = "\x01\x02\x00\x00\x00\xe0\xff";
    const chars = "\x04\x28\x00\x00\x00" ++ "\x41\x00\x00\x00\x01\x00\x02\x00\x03\x00\x04\x00\xff\xff\x05\x00\x06\x00\x00\x0f" ++ "\x42\x00\x00\x00\x00\x00\x00\x00\x01\x00\x01\x00\x00\x00\x00\x00\x01\x00\x01\x0f";
    const pages = "\x03\x12\x00\x00\x00page.png\x00../b.png\x00";
    const kerning = "\x05\x0a\x00\x00\x00\x41\x00\x00\x00\x41\x00\x00\x00\xfe\xff";
    const font = (try parseBmBinary(a, std.testing.io, "BMF\x03" ++ info ++ chars ++ pages ++ kerning, dir)).?;
    try std.testing.expectEqual(@as(f32, 32), font.size);
    try std.testing.expectEqual(@as(f32, 10), measure(font, "AA", 1));
    const g = font.glyphs.get('A').?;
    try std.testing.expectEqual(@as(f32, -1), g.x_offset);
    try std.testing.expectEqual(@as(f32, 4), g.h);
    try std.testing.expect(font.glyphs.get('B') == null);
    try std.testing.expect((try parseBmBinary(a, std.testing.io, "BMF\x03\x01\xff\x00\x00\x00\xe0\xff" ++ chars ++ pages, dir)) == null);
    try std.testing.expect((try parseBmBinary(a, std.testing.io, "BMF\x02" ++ info ++ chars ++ pages, dir)) == null);
}
