//! Stable's 480-high space; an image counts 1.6 px per unit, as on lazer's 768-high stage.
const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");
const m = @import("model.zig");
const lr2 = @import("lr2csv.zig");
const jsonskin = @import("jsonskin.zig");
const play = @import("../ui/play.zig");

const stage_h: f32 = 480;
const unit: f32 = 1.6;
/// shortcut: a 16:9 canvas, other window shapes stretch it; a ColumnStart per aspect if that matters.
const stage_w: f32 = 854;

pub fn isIni(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.basename(path), "skin.ini");
}

pub fn hasMania(a: std.mem.Allocator, path: []const u8) bool {
    const text = fs.readAlloc(a, path, 1 << 22) catch return false;
    if (std.ascii.findIgnoreCase(text, "[Mania]") != null) return true;
    return findImage(a, std.fs.path.dirname(path) orelse ".", "mania-note1", true) != null;
}

const Pair = struct { key: []const u8, value: []const u8 };

fn pairOf(raw: []const u8) ?Pair {
    var line = raw;
    if (std.mem.indexOf(u8, line, "//")) |at| line = line[0..at];
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return .{ .key = std.mem.trim(u8, line[0..colon], " \t\r"), .value = std.mem.trim(u8, line[colon + 1 ..], " \t\r") };
}

fn get(sec: []const u8, key: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, sec, '\n');
    while (it.next()) |l| if (pairOf(l)) |p| {
        if (std.mem.eql(u8, p.key, key)) found = p.value;
    };
    return found;
}

/// Mania repeats its section per key count, and `Keys` may come anywhere in one.
fn section(text: []const u8, name: []const u8, keys: ?u8) []const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    // As osu!, what comes before any header counts as [General].
    var start: ?usize = if (std.mem.eql(u8, name, "General")) 0 else null;
    var at: usize = 0;
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len > 1 and t[0] == '[' and t[t.len - 1] == ']') {
            const same = std.mem.eql(u8, t[1 .. t.len - 1], name);
            if (start) |s| {
                // Only mania repeats a section as a new one.
                if (same and keys == null) {
                    at += l.len + 1;
                    continue;
                }
                if (matches(text[s..at], keys)) return text[s..at];
            }
            start = if (same) at + l.len else null;
        }
        at += l.len + 1;
    }
    if (start) |s| {
        const body = text[@min(s, text.len)..];
        if (matches(body, keys)) return body;
    }
    return "";
}

fn matches(body: []const u8, keys: ?u8) bool {
    const want = keys orelse return true;
    const v = get(body, "Keys") orelse return false;
    return (std.fmt.parseInt(u8, v, 10) catch return false) == want;
}

fn number(sec: []const u8, key: []const u8, def: f32) f32 {
    const v = get(sec, key) orelse return def;
    return std.fmt.parseFloat(f32, v) catch def;
}

fn listAt(sec: []const u8, key: []const u8, i: usize, def: f32) f32 {
    var it = std.mem.splitScalar(u8, get(sec, key) orelse return def, ',');
    var n: usize = 0;
    while (it.next()) |v| : (n += 1) {
        if (n == i) return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch 0;
    }
    return def;
}

fn colour(sec: []const u8, key: []const u8, def: [4]f32) [4]f32 {
    var out = def;
    out[3] = 255;
    var it = std.mem.splitScalar(u8, get(sec, key) orelse return def, ',');
    for (&out) |*v| {
        const s = it.next() orelse break;
        v.* = std.fmt.parseFloat(f32, std.mem.trim(u8, s, " ")) catch return def;
    }
    return out;
}

/// Version 2.5 onward; the wiki gives 1.0 for a skin without one.
fn modern(general: []const u8) bool {
    const v = get(general, "Version") orelse return false;
    if (std.ascii.eqlIgnoreCase(v, "latest")) return true;
    return (std.fmt.parseFloat(f32, v) catch return false) >= 2.5;
}

const Found = struct { path: []const u8, scale: f32 };

/// Lazer's lookup order: frame 0 of an animation first, the @2x file before the plain one.
fn findImage(a: std.mem.Allocator, dir: []const u8, name_in: []const u8, animated: bool) ?Found {
    const name = a.dupe(u8, name_in) catch return null;
    std.mem.replaceScalar(u8, name, '\\', '/');
    if (fs.climbs(name) or std.fs.path.isAbsolute(name)) return null;
    const frames: []const []const u8 = if (animated) &.{ "-0", "" } else &.{""};
    for (frames) |frame| {
        for ([_]f32{ 2, 1 }) |scale| {
            for ([_][]const u8{ ".png", ".jpg" }) |ext| {
                const rel = std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ name, frame, if (scale == 2) "@2x" else "", ext }) catch return null;
                if (lr2.walk(a, dir, rel)) |path| return .{ .path = path, .scale = scale };
            }
        }
    }
    return null;
}

fn pixelSize(path: []const u8) ?[2]f32 {
    const gpa = std.heap.page_allocator;
    const bytes = fs.readAlloc(gpa, path, 1 << 28) catch return null;
    defer gpa.free(bytes);
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    if (c.stbi_info_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &n) == 0 or w <= 0 or h <= 0) return null;
    return .{ @floatFromInt(w), @floatFromInt(h) };
}

/// Size as osu! counts it: @2x halved.
const Image = struct {
    tex: i32,
    w: f32,
    h: f32,

    fn src(i: Image) m.Src {
        return .{ .tex = i.tex, .w = -1, .h = -1 };
    }
};

const white: [4]f32 = @splat(255);

const Build = struct {
    a: std.mem.Allocator,
    dir: []const u8,
    mania: []const u8,
    paths: std.ArrayList(?[]const u8) = .empty,
    objects: std.ArrayList(m.Object) = .empty,

    fn file(b: *Build, name: []const u8, animated: bool) !?Image {
        const f = findImage(b.a, b.dir, name, animated) orelse return null;
        const size = pixelSize(f.path) orelse return null;
        try b.paths.append(b.a, f.path);
        return .{ .tex = @intCast(b.paths.items.len - 1), .w = size[0] / f.scale, .h = size[1] / f.scale };
    }

    fn image(b: *Build, key: []const u8, def: []const u8, animated: bool) !?Image {
        return b.file(get(b.mania, key) orelse def, animated);
    }

    fn noteImage(b: *Build, col: usize, comptime suffix: []const u8, kind: u8) !?Image {
        const key = try std.fmt.allocPrint(b.a, "NoteImage{d}" ++ suffix, .{col});
        const def = try std.fmt.allocPrint(b.a, "mania-note{c}" ++ suffix, .{kind});
        return b.image(key, def, true);
    }

    fn keyImage(b: *Build, col: usize, comptime suffix: []const u8, kind: u8) !?Image {
        const key = try std.fmt.allocPrint(b.a, "KeyImage{d}" ++ suffix, .{col});
        const def = try std.fmt.allocPrint(b.a, "mania-key{c}" ++ suffix, .{kind});
        return b.image(key, def, false);
    }

    fn fixed(b: *Build, x: f32, y: f32, w: f32, h: f32, col: [4]f32) ![]const m.Key {
        return b.a.dupe(m.Key, &.{.{ .x = x, .y = y, .w = w, .h = h, .r = col[0], .g = col[1], .b = col[2], .a = col[3] }});
    }

    fn rect(b: *Build, x: f32, y: f32, w: f32, h: f32, col: [4]f32) !void {
        const rgb: [3]u8 = .{ @intFromFloat(std.math.clamp(col[0], 0, 255)), @intFromFloat(std.math.clamp(col[1], 0, 255)), @intFromFloat(std.math.clamp(col[2], 0, 255)) };
        try b.objects.append(b.a, .{ .src = .{ .solid = rgb }, .keys = try b.fixed(x, y, w, h, col) });
    }

    fn sprite(b: *Build, img: Image, x: f32, y: f32, w: f32, h: f32) !void {
        try b.objects.append(b.a, .{ .src = img.src(), .keys = try b.fixed(x, y, w, h, white) });
    }
};

/// LegacyManiaColumnElement: the middle of an odd count is special, the rest alternate from the edges.
fn columnKind(col: usize, n: usize) u8 {
    if (n % 2 == 1 and col == n / 2) return 'S';
    return if (@min(col, n - 1 - col) % 2 == 0) '1' else '2';
}

fn timerCode(mode: core.types.Mode, lane: u8) i32 {
    return if (mode.scratchOf(lane) >= 0) 0 else lane + @as(i32, 1);
}

const Layout = struct {
    xs: [core.types.max_lanes]f32 = @splat(0),
    ws: [core.types.max_lanes]f32 = @splat(0),
    x: f32,
    w: f32,
    min_w: f32,
};

fn layoutOf(mania: []const u8, n: usize) Layout {
    const start = number(mania, "ColumnStart", 136);
    var l: Layout = .{ .x = start, .w = 0, .min_w = std.math.inf(f32) };
    var x = start;
    for (0..n) |i| {
        l.xs[i] = x;
        l.ws[i] = listAt(mania, "ColumnWidth", i, 30);
        l.min_w = @min(l.min_w, l.ws[i]);
        x += l.ws[i];
        if (i + 1 < n) x += listAt(mania, "ColumnSpacing", i, 0);
    }
    l.w = x - start;
    return l;
}

fn hitPosition(mania: []const u8) f32 {
    return std.math.clamp(number(mania, "HitPosition", 402), 240, 480);
}

fn addKeys(b: *Build, mode: core.types.Mode, order: []const u8, l: *const Layout) !void {
    for (order, 0..) |lane, i| {
        const kind = columnKind(i, order.len);
        const held = m.key_held + timerCode(mode, lane);
        if (try b.keyImage(i, "", kind)) |img| {
            try b.objects.append(b.a, .{
                .src = img.src(),
                .ops = try b.a.dupe(i32, &.{-held}),
                .keys = try b.fixed(l.xs[i], stage_h - img.h / unit, l.ws[i], img.h / unit, white),
            });
        }
        if (try b.keyImage(i, "D", kind)) |img| {
            try b.objects.append(b.a, .{
                .src = img.src(),
                .ops = try b.a.dupe(i32, &.{held}),
                .keys = try b.fixed(l.xs[i], stage_h - img.h / unit, l.ws[i], img.h / unit, white),
            });
        }
    }
}

fn addNotes(b: *Build, skin: *m.Skin, general: []const u8, order: []const u8, l: *const Layout) !void {
    const n = &skin.notes;
    const hit = hitPosition(b.mania);
    const given = number(b.mania, "WidthForNoteHeightScale", 0);
    const scale_w = if (given > 0) given else l.min_w;
    n.ln_end_flip = modern(general);
    n.ln_osu = true;
    // LegacyManiaSkinDecoder takes any number; only 0 stretches, and it is what a skin before 2.5 gets by default.
    const stretches = if (get(b.mania, "NoteBodyStyle")) |v| std.mem.eql(u8, v, "0") else !modern(general);
    n.ln_body_span = if (stretches) 0 else 32800 / unit;
    for (order, 0..) |lane, i| {
        const kind = columnKind(i, order.len);
        const note = try b.noteImage(i, "", kind);
        const head = try b.noteImage(i, "H", kind) orelse note;
        const tail = try b.noteImage(i, "T", kind) orelse head;
        const body = try b.noteImage(i, "L", kind);
        // shortcut: a missing image is a white bar, as there is no osu! default skin to fall back on.
        const blank: m.Src = .{ .solid = .{ 255, 255, 255 } };
        n.note[lane] = if (note) |x| x.src() else blank;
        n.ln_start[lane] = if (head) |x| x.src() else blank;
        n.ln_end[lane] = if (tail) |x| x.src() else blank;
        n.ln_body[lane] = if (body) |x| x.src() else blank;
        // osu! has no mines; these must still show.
        n.mine[lane] = .{ .solid = .{ 255, 0, 0 } };
        const h = if (note orelse head) |x| x.h * scale_w / x.w else l.ws[i] / 3;
        n.lane[lane] = .{ l.xs[i], hit, l.ws[i], h };
    }
}

/// LegacyManiaJudgementPiece: fades over 220 ms, centred on ScorePosition; a miss shrinks, others pulse.
fn judgeKeys(b: *Build, img: Image, cx: f32, cy: f32, miss: bool) ![]const m.Key {
    const Step = struct { t: i32, s: f32, a: f32 };
    const steps: []const Step = if (miss)
        &.{ .{ .t = 0, .s = 1.2, .a = 0 }, .{ .t = 20, .s = 1.16, .a = 255 }, .{ .t = 100, .s = 1, .a = 255 }, .{ .t = 180, .s = 1, .a = 255 }, .{ .t = 220, .s = 1, .a = 0 } }
    else
        &.{ .{ .t = 0, .s = 0.8, .a = 0 }, .{ .t = 20, .s = 0.9, .a = 255 }, .{ .t = 40, .s = 1, .a = 255 }, .{ .t = 41, .s = 0.85, .a = 255 }, .{ .t = 80, .s = 0.7, .a = 255 }, .{ .t = 180, .s = 0.7, .a = 255 }, .{ .t = 220, .s = 0.4, .a = 0 } };
    const keys = try b.a.alloc(m.Key, steps.len);
    for (keys, steps) |*k, s| {
        const w = img.w / unit * s.s;
        const h = img.h / unit * s.s;
        k.* = .{ .time = s.t, .x = cx - w / 2, .y = cy - h / 2, .w = w, .h = h, .a = s.a };
    }
    return keys;
}

fn addJudge(b: *Build, l: *const Layout) !void {
    // PG, GR, GD, BD, then PR and empty POOR, which osu! has no word for, both as its miss.
    const names = [6][2][]const u8{
        .{ "Hit300g", "mania-hit300g" }, .{ "Hit300", "mania-hit300" }, .{ "Hit200", "mania-hit200" },
        .{ "Hit100", "mania-hit100" },   .{ "Hit0", "mania-hit0" },     .{ "Hit0", "mania-hit0" },
    };
    const cx = l.x + l.w / 2;
    const cy = number(b.mania, "ScorePosition", 300);
    const images = try b.a.alloc(m.Object, names.len);
    for (images, names, 0..) |*o, name, i| {
        o.* = .{ .timer = 46, .loop = -1 };
        const img = try b.image(name[0], name[1], true) orelse continue;
        o.src = img.src();
        o.keys = try judgeKeys(b, img, cx, cy, i >= 4);
    }
    try b.objects.append(b.a, .{ .kind = .judge, .judge_images = images });
}

const Font = struct {
    digits: []const m.Src,
    w: f32,
    h: f32,
};

/// A skin font is one file per digit. shortcut: every digit takes the 0's width, as a fixed width font does.
fn fontOf(b: *Build, prefix: []const u8) !?Font {
    const digits = try b.a.alloc(m.Src, 10);
    var first: ?Image = null;
    for (digits, 0..) |*d, i| {
        const img = try b.file(try std.fmt.allocPrint(b.a, "{s}-{d}", .{ prefix, i }), false) orelse return null;
        if (first == null) first = img;
        d.* = img.src();
    }
    return .{ .digits = digits, .w = first.?.w, .h = first.?.h };
}

fn addCombo(b: *Build, fonts: []const u8, l: *const Layout) !void {
    const font = try fontOf(b, get(fonts, "ComboPrefix") orelse "score") orelse return;
    const w = font.w / unit;
    const h = font.h / unit;
    const gap = number(fonts, "ComboOverlap", 0) / unit;
    const places = 6;
    const x = l.x + l.w / 2 - (w - gap) * places / 2;
    try b.objects.append(b.a, .{
        .kind = .number,
        .ref = 104,
        .digit_srcs = font.digits,
        .digit_gap = gap,
        .digits = places,
        .align_ = 2,
        .ops = try b.a.dupe(i32, &.{m.combo_on}),
        .keys = try b.fixed(x, number(b.mania, "ComboPosition", 111) - h / 2, w, h, white),
    });
}

/// The score shown is the EX score.
fn addScore(b: *Build, fonts: []const u8) !void {
    const prefix = get(fonts, "ScorePrefix") orelse "score";
    const overlap = number(fonts, "ScoreOverlap", 0);
    const font = try fontOf(b, prefix) orelse return;

    const score_scale = 0.96 / unit;
    const w = font.w * score_scale;
    const h = font.h * score_scale;
    const gap = overlap * score_scale;
    const places = 8;
    try b.objects.append(b.a, .{
        .kind = .number,
        .ref = 71,
        .digit_srcs = font.digits,
        .digit_gap = gap,
        .digits = places,
        .zero_pad = true,
        .keys = try b.fixed(stage_w - 10 / unit - w - (w - gap) * (places - 1), 0, w, h, white),
    });

    const acc_scale = 0.6 * 0.96 / unit;
    const aw = font.w * acc_scale;
    const ah = font.h * acc_scale;
    const agap = overlap * acc_scale;
    const y = h + 9 / unit;
    var right = stage_w - 17 / unit;
    if (try b.file(try std.fmt.allocPrint(b.a, "{s}-percent", .{prefix}), false)) |img| {
        right -= img.w * acc_scale;
        try b.sprite(img, right, y, img.w * acc_scale, img.h * acc_scale);
        right += agap;
    }
    right -= aw * 2 - agap;
    try b.objects.append(b.a, .{ .kind = .number, .ref = m.acc_frac, .digit_srcs = font.digits, .digit_gap = agap, .digits = 2, .zero_pad = true, .keys = try b.fixed(right, y, aw, ah, white) });
    if (try b.file(try std.fmt.allocPrint(b.a, "{s}-dot", .{prefix}), false)) |img| {
        right -= img.w * acc_scale - agap;
        try b.sprite(img, right, y, img.w * acc_scale, img.h * acc_scale);
    }
    right -= (aw - agap) * 3;
    try b.objects.append(b.a, .{ .kind = .number, .ref = m.acc_whole, .digit_srcs = font.digits, .digit_gap = agap, .digits = 3, .keys = try b.fixed(right, y, aw, ah, white) });
}

/// A marker image makes it LegacyHealthDisplay's new style, placed a little differently.
fn addGauge(b: *Build, conf: jsonskin.Conf) !void {
    const bg = try b.file("scorebar-bg", false) orelse return;
    try b.sprite(bg, 0, 0, bg.w / unit, bg.h / unit);
    const marker_new = try b.file("scorebar-marker", false);
    const fx: f32 = if (marker_new != null) 7.5 else 3;
    const fy: f32 = if (marker_new != null) 7.8 else 10;
    const fill = try b.file("scorebar-colour", true) orelse return;
    const fw = fill.w / unit;
    const fh = fill.h / unit;
    try b.objects.append(b.a, .{ .kind = .graph, .ref = m.gauge_value, .gauge_tint = gaugeColorOn(conf), .src = fill.src(), .keys = try b.fixed(fx, fy, fw, fh, white) });
    const marker = marker_new orelse try b.file("scorebar-ki", false) orelse return;
    const mw = marker.w / unit;
    const mh = marker.h / unit;
    const my = if (marker_new != null) fy + fh / 2 else fy;
    try b.objects.append(b.a, .{ .kind = .slider, .ref = m.gauge_value, .dir = 1, .range = fw, .src = marker.src(), .keys = try b.fixed(fx - mw / 2, my - mh / 2, mw, mh, white) });
}

fn addLighting(b: *Build, general: []const u8, mode: core.types.Mode, order: []const u8, l: *const Layout) !void {
    const hit = hitPosition(b.mania);
    const normal = try b.image("LightingN", "lightingN", true);
    const long = try b.image("LightingL", "lightingL", true);
    for (order, 0..) |lane, i| {
        const code = timerCode(mode, lane);
        const cx = l.xs[i] + l.ws[i] / 2;
        const scaleOf = struct {
            fn f(mania: []const u8, gen: []const u8, key: []const u8, col: usize, col_w: f32) f32 {
                if (!modern(gen)) return 1;
                const given = listAt(mania, key, col, 0);
                return (if (given != 0) given else col_w) / 30;
            }
        }.f;
        if (normal) |img| {
            const s = scaleOf(b.mania, general, "LightingNWidth", i, l.ws[i]);
            const w = img.w * s / unit;
            const h = img.h * s / unit;
            const at: m.Key = .{ .x = cx - w / 2, .y = hit - h / 2, .w = w, .h = h };
            var fade = [_]m.Key{ at, at, at };
            fade[0].a = 0;
            fade[1].time = 80;
            fade[2].time = 200;
            fade[2].a = 0;
            try b.objects.append(b.a, .{ .src = img.src(), .blend = 2, .timer = 50 + code, .loop = -1, .keys = try b.a.dupe(m.Key, &fade) });
        }
        if (long) |img| {
            const s = scaleOf(b.mania, general, "LightingLWidth", i, l.ws[i]);
            const w = img.w * s / unit;
            const h = img.h * s / unit;
            try b.objects.append(b.a, .{ .src = img.src(), .blend = 2, .timer = 70 + code, .keys = try b.fixed(cx - w / 2, hit - h / 2, w, h, white) });
        }
    }
}

pub const bga_stretch_name = "BGA stretch";
pub const bga_stretch_choices = [_][]const u8{ "Fit", "Fill", "Stretch" };
pub const gauge_color_name = "Gauge color";
pub const gauge_color_choices = [_][]const u8{ "On", "Off" };
pub const bga_dim_name = "BGA dim";
pub const bga_dim_choices = [_][]const u8{ "0%", "10%", "20%", "30%", "40%", "50%", "60%", "70%", "80%", "90%", "100%" };
pub const scratch_side_name = "Scratch side";
pub const scratch_side_choices = [_][]const u8{ "Left", "Right" };

pub fn scratchRight(conf: jsonskin.Conf) bool {
    const pick = conf.property.map.get(scratch_side_name) orelse return false;
    return std.mem.eql(u8, pick, "Right");
}

fn gaugeColorOn(conf: jsonskin.Conf) bool {
    const pick = conf.property.map.get(gauge_color_name) orelse return true;
    return !std.mem.eql(u8, pick, "Off");
}

/// bga.fit's types: keep the shape and fit inside, keep it and crop, or fill the screen out of shape.
fn stretchOf(conf: jsonskin.Conf) i32 {
    const pick = conf.property.map.get(bga_stretch_name) orelse return 1;
    if (std.mem.eql(u8, pick, "Fill")) return 3;
    if (std.mem.eql(u8, pick, "Stretch")) return 0;
    return 1;
}

fn dimAlpha(conf: jsonskin.Conf) f32 {
    const pick = conf.property.map.get(bga_dim_name) orelse return 0;
    for (bga_dim_choices) |ch| {
        if (!std.mem.eql(u8, ch, pick)) continue;
        const pct = std.fmt.parseFloat(f32, pick[0 .. pick.len - 1]) catch return 0;
        return pct * 255 / 100;
    }
    return 0;
}

fn build(b: *Build, skin: *m.Skin, general: []const u8, fonts: []const u8, mode: core.types.Mode, conf: jsonskin.Conf) !void {
    var order_buf: [core.types.max_lanes]u8 = undefined;
    const order = order_buf[0..play.laneOrder(mode, scratchRight(conf), &order_buf)];
    const l = layoutOf(b.mania, order.len);
    const hit = hitPosition(b.mania);

    try b.objects.append(b.a, .{ .kind = .bga, .stretch = stretchOf(conf), .keys = try b.fixed(0, 0, stage_w, stage_h, white) });
    const dim = dimAlpha(conf);
    if (dim > 0) try b.rect(0, 0, stage_w, stage_h, .{ 0, 0, 0, dim });
    if (try b.image("StageLeft", "mania-stage-left", true)) |img|
        try b.sprite(img, l.x - img.w / unit, 0, img.w / unit, stage_h);
    if (try b.image("StageRight", "mania-stage-right", true)) |img|
        try b.sprite(img, l.x + l.w, 0, img.w / unit, stage_h);
    const light = try b.image("StageLight", "mania-stage-light", true);
    const light_y = number(b.mania, "LightPosition", 413);
    for (order, 0..) |lane, i| {
        const back = colour(b.mania, try std.fmt.allocPrint(b.a, "Colour{d}", .{i + 1}), .{ 0, 0, 0, 255 });
        try b.rect(l.xs[i], 0, l.ws[i], stage_h, back);
        if (light) |img| {
            const tint = colour(b.mania, try std.fmt.allocPrint(b.a, "ColourLight{d}", .{i + 1}), white);
            const h = img.h / unit;
            try b.objects.append(b.a, .{ .src = img.src(), .timer = 100 + timerCode(mode, lane), .keys = try b.fixed(l.xs[i], light_y - h, l.ws[i], h, tint) });
        }
    }
    const line = colour(b.mania, "ColourColumnLine", white);
    for (0..order.len + 1) |i| {
        const w = listAt(b.mania, "ColumnLineWidth", i, 2) * 0.74 / unit;
        if (w <= 0) continue;
        const x = if (i < order.len) l.xs[i] else l.x + l.w;
        try b.rect(x - w / 2, 0, w, hit, line);
    }
    if (try b.image("StageHint", "mania-stage-hint", false)) |img| {
        // LegacyHitTarget's height scale, centred on the hit line.
        const h = img.h * 0.9 * 1.6025 / unit;
        try b.sprite(img, l.x, hit - h / 2, l.w, h);
    }
    const shows_line = if (get(b.mania, "JudgementLine")) |v| std.mem.eql(u8, v, "1") else true;
    if (shows_line) try b.rect(l.x, hit, l.w, 1 / unit, colour(b.mania, "ColourJudgementLine", white));
    if (try b.image("StageBottom", "mania-stage-bottom", true)) |img|
        try b.sprite(img, l.x + l.w / 2 - img.w / 2, stage_h - img.h, img.w, img.h);

    const keys_under = if (get(b.mania, "KeysUnderNotes")) |v| std.mem.eql(u8, v, "1") else false;
    if (keys_under) try addKeys(b, mode, order, &l);
    try addNotes(b, skin, general, order, &l);
    try b.objects.append(b.a, .{ .kind = .notes });
    if (!keys_under) try addKeys(b, mode, order, &l);
    try addLighting(b, general, mode, order, &l);
    try addJudge(b, &l);
    try addCombo(b, fonts, &l);
    try addScore(b, fonts);
    try addGauge(b, conf);
}

/// A key count the ini has no section for takes every default, as in lazer.
pub fn load(skin: *m.Skin, path: []const u8, mode: core.types.Mode, conf: jsonskin.Conf) ![]const ?[]const u8 {
    const a = skin.arena.allocator();
    const text = try fs.readAlloc(a, path, 1 << 22);
    const body = if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text;
    skin.w = stage_w;
    skin.h = stage_h;
    skin.plain_loading = true;
    var b: Build = .{ .a = a, .dir = std.fs.path.dirname(path) orelse ".", .mania = section(body, "Mania", mode.keys()) };
    try build(&b, skin, section(body, "General", null), section(body, "Fonts", null), mode, conf);
    skin.objects = b.objects.items;
    return b.paths.items;
}

/// A PNG's signature, header and the start of its data, as far as stb reads for the size.
fn testPng(w: u8, h: u8) [41]u8 {
    return "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00".* ++ [_]u8{w} ++ "\x00\x00\x00".* ++ [_]u8{h} ++ "\x08\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00IDAT".*;
}

test "the section for the key count is found, with keys set before its Keys line" {
    const text = "[General]\nVersion: 2.5\n[Mania]\nKeys: 4\nHitPosition: 300\n[Mania]\nHitPosition: 410 // note\nKeys: 8\n[Mania]\nKeys: 8\nHitPosition: 1\n";
    const sec = section(text, "Mania", 8);
    try std.testing.expectEqual(@as(f32, 410), number(sec, "HitPosition", 0));
    try std.testing.expectEqual(@as(usize, 0), section(text, "Mania", 7).len);
    try std.testing.expect(modern(section(text, "General", null)));
    try std.testing.expect(!modern(""));
    try std.testing.expect(modern(section("sss[General]\nVersion: 2.7\n[Mania]\nKeys: 4\n", "General", null)));
}

test "column lists fall back past their end" {
    try std.testing.expectEqual(@as(f32, 40), listAt("ColumnWidth: 50,40", "ColumnWidth", 1, 30));
    try std.testing.expectEqual(@as(f32, 30), listAt("ColumnWidth: 50,40", "ColumnWidth", 2, 30));
}

test "column kinds follow the wiki's table" {
    const table = [_][]const u8{ "1S1", "12S21", "121S121", "12122121" };
    for (table) |want| for (want, 0..) |kind, i| {
        try std.testing.expectEqual(kind, columnKind(i, want.len));
    };
}

test "a 7+1 chart takes the 8 key section, scratch first, @2x and frame 0 preferred" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fs.path.join(a, &.{ dir, "skin.ini" });
    try fs.write(path, "[Mania]\nKeys: 7\nColumnStart: 1\n[Mania]\nKeys: 8\nColumnStart: 100\nColumnWidth: 40,20\nHitPosition: 400\n");
    const png = testPng(40, 10);
    try fs.write(try std.fs.path.join(a, &.{ dir, "mania-note1.png" }), &png);
    try fs.write(try std.fs.path.join(a, &.{ dir, "mania-note1@2x.png" }), &png);
    try fs.write(try std.fs.path.join(a, &.{ dir, "mania-note2-0.png" }), &png);
    try fs.write(try std.fs.path.join(a, &.{ dir, "mania-hit0.png" }), &png);
    try std.testing.expect(hasMania(a, path));

    var skin: m.Skin = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer skin.arena.deinit();
    const paths = try load(&skin, path, .beat7, .{});
    const scratch = skin.notes.lane[7].?;
    try std.testing.expectEqual(@as(f32, 100), scratch[0]);
    try std.testing.expectEqual(@as(f32, 40), scratch[2]);
    try std.testing.expectEqual(@as(f32, 400), scratch[1]);
    // @2x counts 20 x 5, drawn at the narrowest column's width, 20.
    try std.testing.expectEqual(@as(f32, 5), scratch[3]);
    try std.testing.expectEqual(@as(f32, 140), skin.notes.lane[0].?[0]);
    const note1 = paths[@intCast(skin.notes.note[7].tex)].?;
    try std.testing.expect(std.mem.endsWith(u8, note1, "mania-note1@2x.png"));
    const note2 = paths[@intCast(skin.notes.note[0].tex)].?;
    try std.testing.expect(std.mem.endsWith(u8, note2, "mania-note2-0.png"));
    for (skin.objects) |obj| if (obj.kind == .judge) {
        for (obj.judge_images[4..]) |miss| {
            try std.testing.expect(std.mem.endsWith(u8, paths[@intCast(miss.src.tex)].?, "mania-hit0.png"));
        }
    };
    // A note image missing, the head still sizes the lane; a skin without a version stretches its bodies.
    try std.testing.expectEqual(@as(f32, 0), skin.notes.ln_body_span);
    // Mines have no art in osu!, nor does a missing column image stop a note showing.
    try std.testing.expect(skin.notes.mine[0].solid != null);
    try std.testing.expect(skin.notes.ln_body[0].solid != null);
}

test "an ini for other modes only is not a mania skin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fs.path.join(a, &.{ dir, "skin.ini" });
    try fs.write(path, "[General]\nName: x\n");
    try std.testing.expect(!hasMania(a, path));
}

test "an image name cannot climb out of the skin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(findImage(arena.allocator(), ".", "..\\secret", false) == null);
}

test "the BGA options read back from a saved pick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(i32, 1), stretchOf(.{}));
    try std.testing.expectEqual(@as(f32, 0), dimAlpha(.{}));
    var conf: jsonskin.Conf = .{};
    try conf.property.map.put(a, bga_stretch_name, "Fill");
    try conf.property.map.put(a, bga_dim_name, "100%");
    try std.testing.expectEqual(@as(i32, 3), stretchOf(conf));
    try std.testing.expectEqual(@as(f32, 255), dimAlpha(conf));
    try std.testing.expect(gaugeColorOn(conf));
    try conf.property.map.put(a, gauge_color_name, "Off");
    try std.testing.expect(!gaugeColorOn(conf));
    try std.testing.expect(!scratchRight(conf));
    try conf.property.map.put(a, scratch_side_name, "Right");
    try std.testing.expect(scratchRight(conf));
    try conf.property.map.put(a, bga_dim_name, "33%");
    try std.testing.expectEqual(@as(f32, 0), dimAlpha(conf));
}
