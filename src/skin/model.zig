//! Ids are LR2's numeric ones, as in beatoraja's SkinProperty.
const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const gfx = @import("../ui/gfx.zig");
const bitfont = @import("bitfont.zig");
const bga = @import("../ui/bga.zig");

pub const Key = struct {
    time: i32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    acc: u8 = 0,
    a: f32 = 255,
    r: f32 = 255,
    g: f32 = 255,
    b: f32 = 255,
    angle: f32 = 0,
};

pub const Src = struct {
    tex: i32 = -1,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    divx: i32 = 1,
    divy: i32 = 1,
    cycle: i32 = 0,
    timer: i32 = 0,
    /// The frames split into this many runs, of which the number `ref` picks the one that plays.
    len: i32 = 1,
    ref: i32 = 0,
    set: []const Src = &.{},
    set_ref: i32 = 0,
    /// For beatoraja's negative system image ids, which have no texture.
    solid: ?[3]u8 = null,
};

pub const Kind = enum { songlist, image, number, text, graph, slider, gauge, notes, judge, bga, notes_graph, bpm_graph, timing, stagefile, backbmp, banner, hidden_cover, lift_cover };

/// beatoraja's song bars: `on`/`off` hold one bar per place; other lists sit relative to a bar, by row state.
pub const SongList = struct {
    center: usize = 0,
    on: []const Object = &.{},
    off: []const Object = &.{},
    level: []const Object = &.{},
    label: []const Object = &.{},
    text: []const Object = &.{},
    lamp: []const Object = &.{},
};

pub const Object = struct {
    kind: Kind = .image,
    songlist: ?*const SongList = null,
    src: Src = .{},
    ref: i32 = 0,
    digits: i32 = 0,
    align_: i32 = 0,
    zero_pad: bool = false,
    /// 24-glyph layout, with separate glyphs for negative values.
    signed: bool = false,
    /// graph: 0 horizontal, 1 vertical. slider: 0 up, 1 right, 2 down, 3 left.
    dir: i32 = 0,
    range: f32 = 0,
    changeable: bool = false,
    font_size: u16 = 24,
    /// beatoraja's stretch type, -1 when the skin gives none.
    stretch: i32 = -1,
    /// Half the width in ms; colors are PG, GR, GD, BD, PR.
    timing_ms: i32 = 150,
    timing_colors: [5]gfx.Color = @splat(gfx.white),
    /// timing: bare = no bands, window = lines kept, decay = fade; clear line/ema color = judge's / no average.
    timing_bare: bool = false,
    line_color: gfx.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    ema_color: gfx.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    window: u32 = 64,
    decay: bool = false,
    digit_srcs: []const Src = &.{},
    /// Overlap of each digit on the last, in skin pixels.
    digit_gap: f32 = 0,
    gauge_tint: bool = false,
    /// beatoraja's offset 3: moves up with the judge line.
    lifted: bool = false,
    /// Skin y, bottom-up; negative never cuts.
    disappear_line: f32 = -1,
    /// Null for the built-in font.
    font: ?[:0]const u8 = null,
    bitmap: ?*const bitfont.BitmapFont = null,
    constant: []const u8 = "",
    /// Front red, front green, back red, back green.
    nodes: []const Src = &.{},
    parts: i32 = 50,
    /// Index 0..5 = PG..MS.
    judge_images: []const Object = &.{},
    judge_numbers: []const Object = &.{},
    shift: bool = false,
    keys: []const Key = &.{},
    timer: i32 = 0,
    loop: i32 = 0,
    blend: u8 = 1,
    center: u8 = 0,
    ops: []const i32 = &.{},
    /// Lua registry refs.
    lua_draw: i32 = 0,
    lua_value: i32 = 0,
    lua_timer: i32 = 0,
    /// x, y, w, h from the object's bottom-left, bottom-up.
    mouse_rect: ?[4]f32 = null,
};

pub const NoteSet = struct {
    note: [core.types.max_lanes]Src = @splat(.{}),
    ln_start: [core.types.max_lanes]Src = @splat(.{}),
    ln_end: [core.types.max_lanes]Src = @splat(.{}),
    ln_body: [core.types.max_lanes]Src = @splat(.{}),
    ln_active: [core.types.max_lanes]Src = @splat(.{}),
    mine: [core.types.max_lanes]Src = @splat(.{}),
    /// osu! draws the tail upside down.
    ln_end_flip: bool = false,
    /// osu!: the body runs from the tail's middle to the head's, and every LN has a tail.
    ln_osu: bool = false,
    /// osu!: skin pixels the whole body image spans from the tail down, cut by the LN's length; 0 stretches it.
    ln_body_span: f32 = 0,
    /// Top-left coordinates: x, judge line y, width, note height.
    lane: [core.types.max_lanes]?[4]f32 = @splat(null),
};

pub const Skin = struct {
    arena: std.heap.ArenaAllocator,
    w: f32 = 640,
    h: f32 = 480,
    objects: []Object = &.{},
    /// Owned by the texture cache in skin.zig.
    textures: []?*gfx.Texture = &.{},
    tex_sizes: [][2]f32 = &.{},
    /// Movies among `textures`; these the skin owns.
    videos: []*bga.Video = &.{},
    notes: NoteSet = .{},
    enabled: std.AutoHashMapUnmanaged(i32, void) = .empty,
    path: []const u8 = "",
    mtime: i64 = 0,
    fadeout_ms: i32 = 0,
    loadend_ms: i32 = 0,
    /// The format has no loading screen, so the built-in one stands in.
    plain_loading: bool = false,
    scene_ms: i32 = 0,
    input_ms: i32 = 0,
    /// Kept alive so dynamic values stay callable.
    lua: ?*c.lua_State = null,

    pub fn deinit(s: *Skin) void {
        if (s.lua) |l| c.lua_close(l);
        s.arena.deinit();
    }
};

fn fontSize(px: f32) u16 {
    return @intFromFloat(std.math.clamp(px, 8, 1024));
}

/// Skin numbers are untrusted; this range leaves room for the arithmetic drawing does on them.
pub fn skinValue(v: i64) i32 {
    return @intCast(std.math.clamp(v, -10_000_000, 10_000_000));
}
pub const max_div = 4096;
pub const max_parts = 4096;
pub fn clampDigits(d: i32) i32 {
    return std.math.clamp(d, 0, 32);
}

pub const Ctx = struct {
    ud: *anyopaque,
    now_ms: i64,
    /// Start time per timer id in ms, -1 when off.
    timers: []const i64,
    opt: *const fn (ud: *anyopaque, id: i32) bool,
    num: *const fn (ud: *anyopaque, id: i32) ?i64,
    float: *const fn (ud: *anyopaque, id: i32) f32,
    str: *const fn (ud: *anyopaque, id: i32) []const u8,
    set_float: ?*const fn (ud: *anyopaque, id: i32, value: f32) bool = null,
    /// Lift and hidden in skin pixels.
    lift_px: f32 = 0,
    hidden_px: f32 = 0,
    lua_call_bool: ?*const fn (skin: *Skin, r: i32) bool = null,
    lua_call_num: ?*const fn (skin: *Skin, r: i32) f64 = null,
    lua_call_str: ?*const fn (skin: *Skin, r: i32, buf: []u8) []const u8 = null,
};

/// Slider position 0..1 from its resting place for a point, null off the track, as beatoraja's SkinSlider.
fn sliderValue(dir: i32, range: f32, k: Key, x: f32, y: f32) ?f32 {
    if (range <= 0) return null;
    const across = if (dir == 0 or dir == 2) x >= k.x and x <= k.x + k.w else y >= k.y and y <= k.y + k.h;
    if (!across) return null;
    const along = switch (dir) {
        0 => k.y - y,
        1 => x - k.x,
        2 => y - k.y,
        else => k.x - x,
    };
    return if (along >= 0 and along <= range) along / range else null;
}

test "slider tracks run from the resting place" {
    const k: Key = .{ .x = 100, .y = 200, .w = 28, .h = 70 };
    try std.testing.expectEqual(@as(?f32, 0.5), sliderValue(2, 600, k, 110, 500));
    try std.testing.expectEqual(@as(?f32, 0), sliderValue(2, 600, k, 110, 200));
    try std.testing.expectEqual(@as(?f32, null), sliderValue(2, 600, k, 90, 500));
    try std.testing.expectEqual(@as(?f32, null), sliderValue(2, 600, k, 110, 801));
    try std.testing.expectEqual(@as(?f32, 0.5), sliderValue(0, 100, k, 110, 150));
    try std.testing.expectEqual(@as(?f32, 0.25), sliderValue(1, 100, k, 125, 210));
    try std.testing.expectEqual(@as(?f32, 0.5), sliderValue(3, 100, k, 50, 210));
}

fn mouseIn(mr: [4]f32, k: Key, x: f32, y: f32) bool {
    const left = k.x + mr[0];
    const top = k.y + k.h - mr[1] - mr[3];
    return x >= left and x < left + mr[2] and y >= top and y < top + mr[3];
}

test "a mouseRect counts up from the object's bottom-left" {
    const k: Key = .{ .x = 100, .y = 200, .w = 50, .h = 40 };
    try std.testing.expect(mouseIn(.{ 0, 0, 50, 40 }, k, 120, 220));
    try std.testing.expect(!mouseIn(.{ 0, 0, 50, 40 }, k, 160, 220));
    try std.testing.expect(mouseIn(.{ 0, 0, 50, 10 }, k, 120, 235));
    try std.testing.expect(!mouseIn(.{ 0, 0, 50, 10 }, k, 120, 205));
}

fn timerStart(ctx: *const Ctx, id: i32) i64 {
    if (id == 0) return 0;
    if (id < 0 or id >= ctx.timers.len) return -1;
    return ctx.timers[@intCast(id)];
}

fn opOk(s: *const Skin, ctx: *const Ctx, op: i32) bool {
    if (op == 0) return true;
    const abs = @abs(op);
    const on = s.enabled.contains(@intCast(abs)) or ctx.opt(ctx.ud, @intCast(abs));
    return if (op > 0) on else !on;
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Keyframe interpolation following SkinObject.getRegion: acc 0 linear, 1 accelerate, 2 decelerate, 3 hold.
pub fn sample(keys: []const Key, t_in: i64, loop: i32) ?Key {
    if (keys.len == 0) return null;
    const first = keys[0].time;
    const last = keys[keys.len - 1].time;
    var t = t_in;
    if (t < first) return null;
    if (t > last) {
        if (loop < 0) return null;
        if (loop >= last) {
            t = last;
        } else {
            const span = last - loop;
            t = loop + @mod(t - loop, @as(i64, @max(span, 1)));
        }
    }
    var i: usize = 0;
    while (i + 1 < keys.len and keys[i + 1].time <= t) i += 1;
    const a = keys[i];
    if (i + 1 >= keys.len) return a;
    const b = keys[i + 1];
    var f: f32 = @as(f32, @floatFromInt(t - a.time)) / @as(f32, @floatFromInt(@max(b.time - a.time, 1)));
    switch (a.acc) {
        1 => f = f * f,
        2 => f = 1 - (1 - f) * (1 - f),
        3 => f = 0,
        else => {},
    }
    return .{
        .time = @intCast(t),
        .x = lerp(a.x, b.x, f),
        .y = lerp(a.y, b.y, f),
        .w = lerp(a.w, b.w, f),
        .h = lerp(a.h, b.h, f),
        .a = lerp(a.a, b.a, f),
        .r = lerp(a.r, b.r, f),
        .g = lerp(a.g, b.g, f),
        .b = lerp(a.b, b.b, f),
        .angle = lerp(a.angle, b.angle, f),
    };
}

/// Added to an option button's ref, as `imageRef` does.
pub const button_index: i32 = 91000;

/// beatoraja keeps image values apart from numbers: image 390 is a ranking row's clear, number 390 its place.
fn imageRef(ref: i32) i32 {
    return switch (ref) {
        390...399 => ref + 10000,
        11, 12, 40, 42, 55, 72, 78, 308 => ref + button_index,
        else => ref,
    };
}
/// Private float ids for the gauge object, outside LR2's id range.
pub const gauge_value: i32 = 90107;
pub const gauge_border: i32 = 90108;
/// Private number id: the gauge type, as main_state.gauge_type returns it.
pub const gauge_type: i32 = 90109;
/// Private option ids: a combo is running; a key is down, by its timer code (scratch 0, keys from 1).
pub const combo_on: i32 = 90110;
/// Private number ids: accuracy over the notes judged so far, split at the point.
pub const acc_whole: i32 = 90111;
pub const acc_frac: i32 = 90112;
pub const key_held: i32 = 90120;
/// Private ids, one per versus player in room order: EX (the checked score once there is one), notes judged, name, seat taken.
pub const versus_ex: i32 = 90200;
pub const versus_judged: i32 = 90210;
pub const versus_name: i32 = 90220;
pub const versus_present: i32 = 90230;

const center_x = [_]f32{ 0.5, 0, 0.5, 1, 0, 0.5, 1, 0, 0.5, 1 };
const center_y = [_]f32{ 0.5, 1, 1, 1, 0.5, 0.5, 0.5, 0, 0, 0 };

fn runFrame(n: i32, len: i32, row: i64, t: i64, cycle: i32) i32 {
    const runs = std.math.clamp(len, 1, n);
    const per = @divTrunc(n, runs);
    const first: i64 = std.math.clamp(row, 0, runs - 1) * per;
    if (cycle <= 0 or per <= 1) return @intCast(first);
    return @intCast(first + @mod(@divTrunc(t * per, cycle), per));
}

pub const Renderer = struct {
    g: *gfx.Gfx,
    s: *Skin,
    ctx: *const Ctx,
    sx: f32,
    sy: f32,

    pub fn frameOf(r: *const Renderer, src: *const Src) i32 {
        const n = @max(src.divx, 1) * @max(src.divy, 1);
        const st = timerStart(r.ctx, src.timer);
        const t = if (st < 0) 0 else r.ctx.now_ms - st;
        const row = if (src.len > 1) r.ctx.num(r.ctx.ud, imageRef(src.ref)) orelse 0 else 0;
        return runFrame(n, src.len, row, t, src.cycle);
    }

    pub fn blit(r: *const Renderer, src_in: *const Src, frame: i32, k: Key, blend: u8, center: u8, crop: ?[4]f32) void {
        var src = src_in;
        if (src.set.len > 0) {
            const v = r.ctx.num(r.ctx.ud, imageRef(src.set_ref)) orelse 0;
            src = &src.set[@intCast(std.math.clamp(v, 0, @as(i64, @intCast(src.set.len)) - 1))];
        }
        const dst: c.SDL_FRect = .{ .x = k.x * r.sx, .y = k.y * r.sy, .w = k.w * r.sx, .h = k.h * r.sy };
        if (src.solid) |col| {
            r.g.rect(dst.x, dst.y, dst.w, dst.h, .{ .r = col[0], .g = col[1], .b = col[2], .a = @intFromFloat(std.math.clamp(k.a, 0, 255)) });
            return;
        }
        if (src.tex < 0 or src.tex >= r.s.textures.len) return;
        const tex = r.s.textures[@intCast(src.tex)] orelse return;
        const size = r.s.tex_sizes[@intCast(src.tex)];
        const dx = @max(src.divx, 1);
        const dy = @max(src.divy, 1);
        const full_w: f32 = if (src.w < 0) size[0] else @floatFromInt(src.w);
        const full_h: f32 = if (src.h < 0) size[1] else @floatFromInt(src.h);
        const fw = full_w / @as(f32, @floatFromInt(dx));
        const fh = full_h / @as(f32, @floatFromInt(dy));
        var sr: c.SDL_FRect = .{
            .x = @as(f32, @floatFromInt(src.x)) + fw * @as(f32, @floatFromInt(@mod(frame, dx))),
            .y = @as(f32, @floatFromInt(src.y)) + fh * @as(f32, @floatFromInt(@divTrunc(frame, dx))),
            .w = fw,
            .h = fh,
        };
        if (crop) |cr| {
            sr.x += cr[0] * fw;
            sr.y += cr[1] * fh;
            sr.w *= cr[2];
            sr.h *= cr[3];
        }
        // Smoothing a sliver of an atlas, such as a gauge cell, or a piece blown up, blends in the neighbouring art.
        const sliver = sr.w <= 8 or sr.h <= 8 or @abs(dst.w) >= sr.w * 8 or @abs(dst.h) >= sr.h * 8;
        var d = dst;
        const flip_x = d.w < 0;
        const flip_y = d.h < 0;
        if (flip_x) {
            d.x += d.w;
            d.w = -d.w;
        }
        if (flip_y) {
            d.y += d.h;
            d.h = -d.h;
        }
        const ci = @min(center, 9);
        r.g.sprite(tex, sr, d, .{
            .col = .{ .r = byte(k.r), .g = byte(k.g), .b = byte(k.b), .a = byte(k.a) },
            .add = blend == 2,
            .nearest = sliver,
            .angle = k.angle,
            .pivot = .{ d.w * center_x[ci], d.h * center_y[ci] },
            .flip_x = flip_x,
            .flip_y = flip_y,
        });
    }

    fn drawNumber(r: *const Renderer, o: *const Object, k: Key) void {
        const v = if (o.lua_value != 0 and r.ctx.lua_call_num != null) @as(?i64, @intFromFloat(r.ctx.lua_call_num.?(r.s, o.lua_value))) else r.ctx.num(r.ctx.ud, o.ref);
        // beatoraja's value for "nothing to show", such as an empty ranking row.
        if (v == std.math.minInt(i32)) return;
        r.drawValue(o, k, v orelse return);
    }

    pub fn drawValue(r: *const Renderer, o: *const Object, k: Key, value: i64) void {
        var digits: [20]u8 = undefined;
        var n: usize = 0;
        var mag: u64 = @abs(value);
        while (true) {
            digits[n] = @intCast(mag % 10);
            n += 1;
            mag /= 10;
            if (mag == 0 or n == digits.len) break;
        }
        const width: usize = if (o.digits > 0) @intCast(o.digits) else n;
        if (n > width) n = width;
        const base = r.frameOf(&o.src);
        const per_row = glyphsPerRow(o.signed, @max(o.src.divx, 1) * @max(o.src.divy, 1));
        const row = @divTrunc(base, @max(per_row, 1));
        const sign_rows: i32 = if (o.signed and value < 0) 12 else 0;
        if (o.signed and n >= width and width > 1) n = width - 1;
        const used = n + @intFromBool(o.signed);
        const pad = width -| used;
        const advance = k.w - o.digit_gap;
        const shift: f32 = switch (o.align_) {
            1 => 0, // left aligned digits start at x
            2 => @as(f32, @floatFromInt(pad)) * advance / 2,
            else => @as(f32, @floatFromInt(pad)) * advance, // right aligned
        };
        // Eleven glyphs: the last is what empty places show, whatever `zeropadding` says.
        const pad_glyph: ?i32 = if (!o.signed and per_row == 11) 10 else if (o.zero_pad and !o.signed) 0 else null;
        var x = k.x + (if (pad_glyph != null and o.align_ != 1) 0 else shift);
        var kk = k;
        if (pad_glyph) |glyph| if (o.align_ != 1) {
            for (0..pad) |_| {
                kk.x = x;
                if (o.digit_srcs.len == 10) {
                    r.blit(&o.digit_srcs[@intCast(glyph)], 0, kk, o.blend, o.center, null);
                } else r.blit(&o.src, row * per_row + glyph, kk, o.blend, o.center, null);
                x += advance;
            }
        };
        if (o.signed) {
            kk.x = x;
            r.blit(&o.src, row * per_row + sign_rows + 11, kk, o.blend, o.center, null);
            x += k.w;
        }
        var i = n;
        while (i > 0) {
            i -= 1;
            kk.x = x;
            if (o.digit_srcs.len == 10) {
                r.blit(&o.digit_srcs[digits[i]], 0, kk, o.blend, o.center, null);
            } else r.blit(&o.src, row * per_row + sign_rows + digits[i], kk, o.blend, o.center, null);
            x += advance;
        }
    }

    fn drawText(r: *const Renderer, o: *const Object, k: Key) void {
        var buf: [512]u8 = undefined;
        const s = if (o.lua_value != 0 and r.ctx.lua_call_str != null)
            r.ctx.lua_call_str.?(r.s, o.lua_value, &buf)
        else if (o.constant.len > 0) o.constant else r.ctx.str(r.ctx.ud, o.ref);
        if (s.len == 0 or k.a <= 0) return;
        const col: gfx.Color = .{ .r = @intFromFloat(std.math.clamp(k.r, 0, 255)), .g = @intFromFloat(std.math.clamp(k.g, 0, 255)), .b = @intFromFloat(std.math.clamp(k.b, 0, 255)), .a = @intFromFloat(std.math.clamp(k.a, 0, 255)) };
        if (o.bitmap) |font| return r.drawBitmapText(font, o, k, s, col, o.align_, font.lr2);
        const size = fontSize(k.h * r.sy);
        r.g.text_font = o.font;
        defer r.g.text_font = null;
        switch (o.align_) {
            1 => r.g.textCentered(s, k.x * r.sx, k.y * r.sy, size, col),
            2 => {
                const w = r.g.measure(s, size);
                _ = r.g.text(s, k.x * r.sx - w, k.y * r.sy, size, col);
            },
            else => _ = r.g.text(s, k.x * r.sx, k.y * r.sy, size, col),
        }
    }

    /// `fit` squeezes the line into the text's width, as SkinTextImage does.
    fn drawBitmapText(r: *const Renderer, font: *const bitfont.BitmapFont, o: *const Object, k: Key, s: []const u8, col: gfx.Color, align_: i32, fit: bool) void {
        if (!std.unicode.utf8ValidateSlice(s)) return;
        // LR2 sizes by the text's height, a BMFont by the size the skin asks for.
        const height = if (font.lr2) k.h else @as(f32, @floatFromInt(o.font_size));
        var scale = height / font.size;
        const width = bitfont.measure(font, s, scale);
        const squeeze: f32 = if (fit and k.w > 0 and width > k.w) k.w / width else 1;
        const shown = width * squeeze;
        const left = switch (align_) {
            1 => k.x - shown / 2,
            2 => k.x - shown,
            else => k.x,
        };
        scale *= squeeze;
        var x = left;
        var it = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (it.nextCodepoint()) |cp| {
            const glyph = font.glyphs.get(cp) orelse continue;
            defer x += glyph.advance * scale + font.margin * squeeze;
            if (glyph.w <= 0 or glyph.h <= 0) continue;
            const page = font.first_tex + @as(i32, glyph.page);
            if (page >= r.s.textures.len) continue;
            const tex = r.s.textures[@intCast(page)] orelse continue;
            const h = if (font.lr2) k.h else glyph.h * scale;
            const y = if (font.lr2) k.y else k.y + glyph.y_offset * scale;
            r.g.sprite(tex, .{ .x = glyph.x, .y = glyph.y, .w = glyph.w, .h = glyph.h }, .{ .x = (x + glyph.x_offset * scale) * r.sx, .y = y * r.sy, .w = glyph.w * scale * r.sx, .h = h * r.sy }, .{ .col = col });
        }
    }

    pub fn drawBarText(r: *const Renderer, o: *const Object, k: Key, s: []const u8) void {
        if (s.len == 0 or k.a <= 0) return;
        const col: gfx.Color = .{ .r = byte(k.r), .g = byte(k.g), .b = byte(k.b), .a = byte(k.a) };
        if (o.bitmap) |font| return r.drawBitmapText(font, o, k, s, col, 0, true);
        r.g.text_font = o.font;
        defer r.g.text_font = null;
        r.g.textClip(s, k.x * r.sx, k.y * r.sy, k.w * r.sx, fontSize(k.h * r.sy), col);
    }

    fn drawTintedFill(r: *const Renderer, o: *const Object, k: Key, v: f32) void {
        const border = std.math.clamp(r.ctx.float(r.ctx.ud, gauge_border), 0, 1); // 0 when all red
        const split = @min(v, border);
        var kk = k;
        if (split > 0) {
            kk.w = k.w * split;
            kk.r = 40;
            kk.g = 220;
            kk.b = 70;
            r.blit(&o.src, r.frameOf(&o.src), kk, o.blend, o.center, .{ 0, 0, split, 1 });
        }
        if (v > split) {
            kk.x = k.x + k.w * split;
            kk.w = k.w * (v - split);
            kk.r = 235;
            kk.g = 40;
            kk.b = 40;
            r.blit(&o.src, r.frameOf(&o.src), kk, o.blend, o.center, .{ split, 0, v - split, 1 });
        }
    }

    fn drawGauge(r: *const Renderer, o: *const Object, k: Key) void {
        if (o.nodes.len < 4) return;
        const pct = r.ctx.float(r.ctx.ud, gauge_value); // 0..1
        const border = r.ctx.float(r.ctx.ud, gauge_border); // 0..1, 0 when all parts are red
        const parts = @max(o.parts, 1);
        // Six nodes per gauge type when the skin draws each type its own way, the last two for the tip.
        const per_type: usize = if (o.nodes.len >= 6) 6 else 4;
        const types = o.nodes.len / per_type;
        const ty: usize = @intCast(std.math.clamp(r.ctx.num(r.ctx.ud, gauge_type) orelse 0, 0, @as(i64, @intCast(types)) - 1));
        const nodes = o.nodes[ty * per_type ..][0..per_type];
        const pw = k.w / @as(f32, @floatFromInt(parts));
        const lit: i32 = @intFromFloat(@ceil(pct * @as(f32, @floatFromInt(parts))));
        var kk = k;
        kk.w = pw;
        for (0..@intCast(parts)) |i| {
            const idx: i32 = @intCast(i);
            const red = @as(f32, @floatFromInt(idx + 1)) / @as(f32, @floatFromInt(parts)) > border;
            const tip = per_type == 6 and idx == lit - 1;
            const node: usize = if (tip) (if (red) 4 else 5) else if (idx < lit) (if (red) 0 else 1) else (if (red) 2 else 3);
            kk.x = k.x + pw * @as(f32, @floatFromInt(idx));
            r.blit(&nodes[node], r.frameOf(&nodes[node]), kk, o.blend, o.center, null);
        }
    }

    pub fn visible(r: *const Renderer, o: *const Object) ?Key {
        for (o.ops) |op| if (!opOk(r.s, r.ctx, op)) return null;
        if (o.lua_draw != 0 and r.ctx.lua_call_bool != null and !r.ctx.lua_call_bool.?(r.s, o.lua_draw)) return null;
        const st = if (o.lua_timer != 0 and r.ctx.lua_call_num != null) blk: {
            const v = r.ctx.lua_call_num.?(r.s, o.lua_timer);
            break :blk if (v < 0) @as(i64, -1) else @as(i64, @intFromFloat(v / 1000));
        } else timerStart(r.ctx, o.timer);
        if (st < 0) return null;
        var k = sample(o.keys, r.ctx.now_ms - st, o.loop) orelse return null;
        if (o.lifted) k.y -= r.ctx.lift_px;
        if (o.mouse_rect) |mr| if (!mouseIn(mr, k, r.g.mx / r.sx, r.g.my / r.sy)) return null;
        return k;
    }

    /// As SkinHidden: only what is above the disappear line shows.
    fn drawCover(r: *const Renderer, o: *const Object, k: Key) void {
        var kk = k;
        var line = r.s.h - o.disappear_line;
        if (o.kind == .hidden_cover) {
            kk.y -= r.ctx.hidden_px;
            line -= r.ctx.lift_px;
        }
        if (o.disappear_line < 0) return r.blit(&o.src, r.frameOf(&o.src), kk, o.blend, o.center, null);
        const h = @min(k.h, line - kk.y);
        if (h <= 0 or k.h <= 0) return;
        kk.h = h;
        r.blit(&o.src, r.frameOf(&o.src), kk, o.blend, o.center, .{ 0, 0, 1, h / k.h });
    }

    pub fn drawObject(r: *const Renderer, o: *const Object) void {
        const k = r.visible(o) orelse return;
        switch (o.kind) {
            .image => r.blit(&o.src, r.frameOf(&o.src), k, o.blend, o.center, null),
            .number => r.drawNumber(o, k),
            .text => r.drawText(o, k),
            .gauge => r.drawGauge(o, k),
            .graph => {
                const v = std.math.clamp(r.ctx.float(r.ctx.ud, o.ref), 0, 1);
                if (o.gauge_tint) return r.drawTintedFill(o, k, v);
                var kk = k;
                if (o.dir == 1) {
                    kk.h = k.h * v;
                    kk.y = k.y + k.h - kk.h;
                    r.blit(&o.src, r.frameOf(&o.src), kk, o.blend, o.center, .{ 0, 1 - v, 1, v });
                } else {
                    kk.w = k.w * v;
                    r.blit(&o.src, r.frameOf(&o.src), kk, o.blend, o.center, .{ 0, 0, v, 1 });
                }
            },
            .slider => {
                if (o.changeable and r.g.down) if (r.ctx.set_float) |set| {
                    if (sliderValue(o.dir, o.range, k, r.g.mx / r.sx, r.g.my / r.sy)) |value| {
                        if (set(r.ctx.ud, o.ref, value)) r.g.clicked = false;
                    }
                };
                const v = std.math.clamp(r.ctx.float(r.ctx.ud, o.ref), 0, 1);
                var kk = k;
                switch (o.dir) {
                    0 => kk.y -= v * o.range,
                    1 => kk.x += v * o.range,
                    2 => kk.y += v * o.range,
                    else => kk.x -= v * o.range,
                }
                r.blit(&o.src, r.frameOf(&o.src), kk, o.blend, o.center, null);
            },
            .songlist, .judge, .notes, .bga, .notes_graph, .bpm_graph, .timing, .stagefile, .backbmp, .banner => {},
            .hidden_cover, .lift_cover => r.drawCover(o, k),
        }
    }

    pub fn drawJudge(r: *const Renderer, o: *const Object, judge: u8, combo: u32) void {
        if (judge >= o.judge_images.len) return;
        const img = &o.judge_images[judge];
        const k = r.visible(img) orelse return;
        var ik = k;
        const num: ?*const Object = if (judge < o.judge_numbers.len and judge < 3 and combo > 0) &o.judge_numbers[judge] else null;
        // Number keys are offsets from the judge image's bottom-left, bottom-up, as in SkinJudge.
        if (num) |n| if (r.visible(n)) |base| {
            var digits: f32 = 1;
            var v = combo;
            while (v >= 10) : (v /= 10) digits += 1;
            if (o.shift) ik.x -= base.w * digits / 2;
            var b = base;
            b.x = k.x + base.x;
            b.y = k.y + k.h - base.y - base.h;
            // Whatever the skin refers to, SkinJudge shows the running combo.
            r.drawValue(n, b, combo);
        };
        r.blit(&img.src, r.frameOf(&img.src), ik, img.blend, img.center, null);
    }
};

fn byte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 255));
}

/// A number's frames are rows of 10, 11 (with a pad glyph) or 12 (signed) glyphs, one row per animation step.
fn glyphsPerRow(signed: bool, frames: i32) i32 {
    if (signed) return 12;
    if (@mod(frames, 11) == 0) return 11;
    if (@mod(frames, 10) == 0) return 10;
    return @min(frames, 11);
}

test "number frames split into rows of glyphs" {
    try std.testing.expectEqual(@as(i32, 10), glyphsPerRow(false, 30));
    try std.testing.expectEqual(@as(i32, 11), glyphsPerRow(false, 22));
    try std.testing.expectEqual(@as(i32, 12), glyphsPerRow(true, 24));
}

test "keyframe sampling" {
    const keys = [_]Key{ .{ .time = 0, .x = 0 }, .{ .time = 100, .x = 100 } };
    try std.testing.expect(sample(&keys, -1, 0) == null);
    try std.testing.expectEqual(@as(f32, 50), sample(&keys, 50, 0).?.x);
    try std.testing.expectEqual(@as(f32, 100), sample(&keys, 500, 100).?.x);
    try std.testing.expect(sample(&keys, 101, -1) == null);
    try std.testing.expectEqual(@as(f32, 25), sample(&keys, 125, 0).?.x);
    var acc = keys;
    acc[0].acc = 1;
    try std.testing.expectEqual(@as(f32, 25), sample(&acc, 50, 0).?.x);
}

test "a number picks a run of frames, and only that run animates" {
    // 3 columns by 11 rows, as a clear lamp.
    try std.testing.expectEqual(@as(i32, 18), runFrame(33, 11, 6, 0, 192));
    try std.testing.expectEqual(@as(i32, 19), runFrame(33, 11, 6, 64, 192));
    try std.testing.expectEqual(@as(i32, 18), runFrame(33, 11, 6, 192, 192));
    try std.testing.expectEqual(@as(i32, 30), runFrame(33, 11, 99, 0, 0));
    try std.testing.expectEqual(@as(i32, 2), runFrame(4, 1, 0, 50, 100));
}

test "skin numbers are bounded" {
    try std.testing.expectEqual(@as(i32, 10_000_000), skinValue(std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(i32, -10_000_000), skinValue(std.math.minInt(i64)));
    try std.testing.expectEqual(@as(u16, 1024), fontSize(1e30));
    try std.testing.expectEqual(@as(u16, 8), fontSize(-1e30));
    try std.testing.expectEqual(@as(i32, 0), clampDigits(-5));
    try std.testing.expectEqual(@as(i32, 32), clampDigits(std.math.maxInt(i32)));
}
