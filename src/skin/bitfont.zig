//! Bitmap fonts: LR2's .lr2font, following beatoraja's LR2FontLoader, and AngelCode BMFont text .fnt files.
const std = @import("std");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");
const lr2csv = @import("lr2csv.zig");

const max_file = 1 << 24;
const max_pages = 256;

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
    /// The pixel height glyphs were drawn at.
    size: f32 = 0,
    /// .lr2font: added between glyphs, in skin pixels.
    margin: f32 = 0,
    /// LR2 stretches each glyph to the text's height and squeezes the line into its width.
    lr2: bool = false,
    pages: []const ?[]const u8 = &.{},
    /// Where `pages` start in the skin's textures.
    first_tex: i32 = 0,
    glyphs: std.AutoHashMapUnmanaged(u32, Glyph) = .empty,
};

fn pagePath(a: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]const u8 {
    const norm = a.dupe(u8, name) catch return null;
    std.mem.replaceScalar(u8, norm, '\\', '/');
    if (fs.climbs(norm) or std.fs.path.isAbsolute(norm)) return null;
    return lr2csv.walk(a, dir, norm);
}

fn setPage(a: std.mem.Allocator, pages: *std.ArrayList(?[]const u8), dir: []const u8, id: i64, name: []const u8) !void {
    if (id < 0 or id >= max_pages) return;
    const i: usize = @intCast(id);
    while (pages.items.len <= i) try pages.append(a, null);
    pages.items[i] = pagePath(a, dir, name);
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

fn parseLr2(a: std.mem.Allocator, text: []const u8, dir: []const u8) !?*BitmapFont {
    const font = try a.create(BitmapFont);
    font.* = .{ .lr2 = true };
    var pages: std.ArrayList(?[]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r\t");
        if (line.len < 2 or line[0] != '#') continue;
        var fields: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, line, ',');
        while (it.next()) |f| try fields.append(a, f);
        const f = fields.items;
        if (std.mem.eql(u8, f[0], "#S")) {
            font.size = @floatFromInt(fieldInt(f, 1));
        } else if (std.mem.eql(u8, f[0], "#M")) {
            font.margin = @floatFromInt(fieldInt(f, 1));
        } else if (std.mem.eql(u8, f[0], "#T") and f.len > 2) {
            try setPage(a, &pages, dir, fieldInt(f, 1), f[2]);
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

/// `key=value` from a BMFont line; a quoted value keeps its spaces, and is not searched.
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

// shortcut: kerning pairs are ignored, read them if a skin's text looks uneven.
fn parseBm(a: std.mem.Allocator, text: []const u8, dir: []const u8) !?*BitmapFont {
    const font = try a.create(BitmapFont);
    font.* = .{};
    var pages: std.ArrayList(?[]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "info ")) {
            font.size = @floatFromInt(@abs(bmInt(line, "size")));
        } else if (std.mem.startsWith(u8, line, "page ")) {
            try setPage(a, &pages, dir, bmInt(line, "id"), bmValue(line, "file") orelse continue);
        } else if (std.mem.startsWith(u8, line, "char ")) {
            const page = bmInt(line, "page");
            const id = bmInt(line, "id");
            if (page < 0 or page >= pages.items.len or id < 0 or id > 0x10ffff) continue;
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
        }
    }
    if (font.size <= 0 or font.glyphs.count() == 0) return null;
    font.pages = pages.items;
    return font;
}

/// Null for a missing or unreadable file, such as a binary .fnt: the skin then falls back to a built-in font.
pub fn load(a: std.mem.Allocator, path: []const u8) ?*BitmapFont {
    const bytes = fs.readAlloc(a, path, max_file) catch return null;
    const dir = std.fs.path.dirname(path) orelse ".";
    if (std.ascii.endsWithIgnoreCase(path, ".lr2font")) {
        const text = if (std.unicode.utf8ValidateSlice(bytes)) bytes else core.encoding.toUtf8(a, bytes, .sjis) catch return null;
        return parseLr2(a, text, dir) catch null;
    }
    return parseBm(a, bytes, dir) catch null;
}

/// Pixel width of `s` at `scale`, margins included.
pub fn measure(font: *const BitmapFont, s: []const u8, scale: f32) f32 {
    var w: f32 = 0;
    var view = std.unicode.Utf8View.initUnchecked(s).iterator();
    if (!std.unicode.utf8ValidateSlice(s)) return 0;
    while (view.nextCodepoint()) |cp| {
        const g = font.glyphs.get(cp) orelse continue;
        w += g.advance * scale + font.margin;
    }
    return w;
}

test "an lr2font maps LR2 codes to characters and refuses pages outside its folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    fs.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try fs.write(try std.fs.path.join(a, &.{ dir, "a.png" }), "");
    const font = (try parseLr2(a, "#S,24\r\n#M,2\r\n#T,0,a.png\r\n#T,1,../b.png\r\n#R,65,0,1,2,3,4\r\n#R,66,1,0,0,9,9\r\n#R,288,0,0,0,1,1\r\n", dir)).?;
    try std.testing.expectEqual(@as(f32, 24), font.size);
    const g = font.glyphs.get('A').?;
    try std.testing.expectEqual(@as(f32, 3), g.w);
    try std.testing.expect(font.glyphs.get('B') == null);
    try std.testing.expect(font.glyphs.get(0xff5e) != null);
    try std.testing.expectEqual(@as(f32, 5), measure(font, "A", 1));
    try std.testing.expectEqual(@as(?u32, 'あ'), lr2Code(0x82a0 - 32832));
}

test "a font without a size is refused, and a BMFont reads its fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    fs.io = std.testing.io;
    try std.testing.expect((try parseLr2(a, "#T,0,a.png\n#R,65,0,1,2,3,4\n", ".")) == null);
    try std.testing.expect((try parseBm(a, "not a font", ".")) == null);
    const font = (try parseBm(a, "info face=\"a size=9\" size=-40 bold=0\r\npage id=0 file=\"none.png\"\r\nchar id=65 x=1 y=2 width=3 height=4 xoffset=-1 yoffset=5 xadvance=6 page=0\r\nchar id=66 page=9\r\n", ".")).?;
    try std.testing.expectEqual(@as(f32, 40), font.size);
    const g = font.glyphs.get('A').?;
    try std.testing.expectEqual(@as(f32, -1), g.x_offset);
    try std.testing.expectEqual(@as(f32, 6), g.advance);
    try std.testing.expect(font.glyphs.get('B') == null);
}
