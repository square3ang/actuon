const std = @import("std");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");
const m = @import("model.zig");
const jsonskin = @import("jsonskin.zig");
const bitfont = @import("bitfont.zig");

const Parser = struct {
    a: std.mem.Allocator,
    io: std.Io,
    skin: *m.Skin,
    mode: core.types.Mode,
    root: []const u8,
    images: std.ArrayList(?[]const u8) = .empty,
    /// Null where a font failed to load, as SRC_TEXT counts #LR2FONT lines in file order.
    fonts: std.ArrayList(?*bitfont.BitmapFont) = .empty,
    fonts_loaded: u32 = 0,
    objects: std.ArrayList(m.Object) = .empty,
    keys: std.ArrayList(std.ArrayList(m.Key)) = .empty,
    current: ?usize = null,
    judge_obj: ?usize = null,
    judge_cur: [6]?usize = @splat(null),
    skip: bool = false,
    taken: bool = false,
    depth: u32 = 0,
    includes: u32 = 0,
    resolver: *const fn (i32) bool,
    conf: jsonskin.Conf = .{},
    /// #CUSTOMFILE entries in the shape jsonskin.resolveWild reads, "def" already the player's pick.
    files: std.ArrayList(std.json.Value) = .empty,
    offsets: std.AutoHashMapUnmanaged(i32, jsonskin.Offset) = .empty,
    judge_imgs: [6]m.Object = @splat(.{}),
    judge_nums: [6]m.Object = @splat(.{}),
    judge_keys: [12]std.ArrayList(m.Key) = @splat(.empty),
    has_judge: bool = false,
    has_notes: bool = false,
    judge_shift: bool = true,
};

fn int(s: []const u8) i32 {
    var buf: [16]u8 = undefined;
    var n: usize = 0;
    for (s) |ch| {
        if ((ch >= '0' and ch <= '9') or (ch == '-' and n == 0)) {
            if (n < buf.len) {
                buf[n] = ch;
                n += 1;
            }
        }
    }
    return m.skinValue(std.fmt.parseInt(i64, buf[0..n], 10) catch 0);
}

/// Depth alone lets each file include many: the count stops the fan-out.
pub const max_includes = 256;

fn vals(str: []const []const u8) [24]i32 {
    var v: [24]i32 = @splat(0);
    for (str, 0..) |s, i| {
        if (i >= v.len) break;
        v[i] = int(s);
    }
    return v;
}

fn resolve(p: *Parser, raw: []const u8) ?[]const u8 {
    return resolvePath(p.a, p.io, p.root, p.files.items, raw);
}

/// Null when the path leaves the skin folder.
fn skinRel(a: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    const norm = a.dupe(u8, raw) catch return null;
    std.mem.replaceScalar(u8, norm, '\\', '/');
    var rel: []const u8 = norm;
    if (std.ascii.findIgnoreCase(rel, "theme/")) |i| {
        rel = rel[i + "theme/".len ..];
        // drop the theme's own folder name: `root` already is that folder
        if (std.mem.indexOfScalar(u8, rel, '/')) |sl| rel = rel[sl + 1 ..];
    }
    if (fs.climbs(rel) or std.fs.path.isAbsolute(rel)) return null;
    return rel;
}

/// A wildcard no #CUSTOMFILE names takes the first match.
fn resolvePath(a: std.mem.Allocator, io: std.Io, root: []const u8, files: []const std.json.Value, raw: []const u8) ?[]const u8 {
    const rel = skinRel(a, raw) orelse return null;
    return walk(a, io, root, jsonskin.resolveWild(a, io, root, files, rel) catch return null);
}

pub fn walk(a: std.mem.Allocator, io: std.Io, root: []const u8, rel: []const u8) ?[]const u8 {
    var cur: []const u8 = root;
    var it = std.mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |seg| {
        const entries = fs.list(a, io, cur) catch return null;
        var found: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, seg, '*')) |star| {
            const pre = seg[0..star];
            const suf = seg[star + 1 ..];
            var best: ?[]const u8 = null;
            for (entries) |e| {
                if (e.name.len < pre.len + suf.len) continue;
                if (!std.ascii.startsWithIgnoreCase(e.name, pre) or !std.ascii.endsWithIgnoreCase(e.name, suf)) continue;
                if (best == null or std.mem.lessThan(u8, e.name, best.?)) best = e.name;
            }
            found = best;
        } else {
            for (entries) |e| if (std.ascii.eqlIgnoreCase(e.name, seg)) {
                found = e.name;
                break;
            };
        }
        cur = std.fs.path.join(a, &.{ cur, found orelse return null }) catch return null;
    }
    return cur;
}

fn laneOf(mode: core.types.Mode, code: i32) ?u8 {
    if (code < 0) return null;
    const side = @divTrunc(code, 10);
    const n = @mod(code, 10);
    const per: u8 = mode.keys() / mode.players();
    if (side >= mode.players()) return null;
    const base: u8 = @as(u8, @intCast(side)) * per;
    if (n == 0) {
        if (mode == .popn9) return null;
        return base + per - 1;
    }
    const key_count: u8 = if (mode == .popn9) 9 else per - 1;
    if (n > key_count) return null;
    return base + @as(u8, @intCast(n - 1));
}

fn srcOf(v: [24]i32) m.Src {
    return .{ .tex = v[2], .x = v[3], .y = v[4], .w = v[5], .h = v[6], .divx = std.math.clamp(v[7], 1, m.max_div), .divy = std.math.clamp(v[8], 1, m.max_div), .cycle = v[9], .timer = v[10] };
}

/// The images LR2 numbers from 100: the chart's own, and plain colors.
fn runtimeImage(gr: i32) ?m.Object {
    return switch (gr) {
        100 => .{ .kind = .stagefile },
        101 => .{ .kind = .backbmp },
        102 => .{ .kind = .banner },
        110 => .{ .kind = .image, .src = .{ .solid = .{ 0, 0, 0 } } },
        111 => .{ .kind = .image, .src = .{ .solid = .{ 255, 255, 255 } } },
        else => if (gr >= 100) .{ .kind = .image, .src = .{ .tex = -1 } } else null,
    };
}

fn begin(p: *Parser, o: m.Object) !void {
    try p.objects.append(p.a, o);
    try p.keys.append(p.a, .empty);
    p.current = p.objects.items.len - 1;
}

fn keyOf(v: [24]i32) m.Key {
    var x = v[3];
    var y = v[4];
    var w = v[5];
    var h = v[6];
    if (w < 0) {
        x += w;
        w = -w;
    }
    if (h < 0) {
        y += h;
        h = -h;
    }
    return .{
        .time = v[2],
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .w = @floatFromInt(w),
        .h = @floatFromInt(h),
        .acc = @intCast(std.math.clamp(v[7], 0, 3)),
        .a = @floatFromInt(v[8]),
        .r = @floatFromInt(v[9]),
        .g = @floatFromInt(v[10]),
        .b = @floatFromInt(v[11]),
        .angle = @floatFromInt(v[14]),
    };
}

fn applyDst(p: *Parser, o: *m.Object, list: *std.ArrayList(m.Key), v: [24]i32) !void {
    if (list.items.len == 0) {
        o.blend = @intCast(std.math.clamp(v[12], 0, 255));
        o.center = @intCast(std.math.clamp(v[15], 0, 9));
        o.loop = v[16];
        o.timer = v[17];
        const ops = try p.a.alloc(i32, 3);
        ops[0] = v[18];
        ops[1] = v[19];
        ops[2] = v[20];
        o.ops = ops;
    }
    var k = keyOf(v);
    // As beatoraja's LR2 loader: fields from 21 name offsets, which move the rect bottom-up.
    for (v[21..]) |id| {
        const off = p.offsets.get(id) orelse continue;
        k.x += @floatFromInt(off.x);
        k.w += @floatFromInt(off.w);
        k.h += @floatFromInt(off.h);
        k.y -= @as(f32, @floatFromInt(off.y)) + @as(f32, @floatFromInt(off.h));
        k.angle += @floatFromInt(off.r);
        k.a += @floatFromInt(off.a);
    }
    try list.append(p.a, k);
}

fn condition(p: *Parser, str: []const []const u8) bool {
    for (str[1..]) |tok| {
        if (tok.len == 0) continue;
        const neg = tok[0] == '!';
        const op = int(tok);
        const id = if (op < 0) -op else op;
        const on = p.skin.enabled.contains(id) or p.resolver(id);
        if ((op < 0 or neg) == on) return false;
    }
    return true;
}

/// #CUSTOMOPTION,title,first op,item...: an item's op is first op + position; no valid saved pick means the first.
fn pickedItem(p: *Parser, str: []const []const u8) i32 {
    const pick = p.conf.property.map.get(str[1]) orelse return 0;
    for (str[3..], 0..) |item, i| {
        if (std.mem.eql(u8, std.mem.trim(u8, item, " "), pick)) return @intCast(i);
    }
    return 0;
}

const Error = std.Io.Dir.ReadFileAllocError || error{BadInclude};

fn line(p: *Parser, raw: []const u8) Error!void {
    const text = std.mem.trimEnd(u8, raw, " \r\t");
    if (text.len == 0 or text[0] != '#') return;
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |s| try parts.append(p.a, s);
    const str = parts.items;
    const cmd = str[0][1..];
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(cmd, "IF")) {
        p.taken = condition(p, str);
        p.skip = !p.taken;
        return;
    }
    if (eq(cmd, "ELSEIF")) {
        if (p.taken) {
            p.skip = true;
        } else {
            p.taken = condition(p, str);
            p.skip = !p.taken;
        }
        return;
    }
    if (eq(cmd, "ELSE")) {
        p.skip = p.taken;
        return;
    }
    if (eq(cmd, "ENDIF")) {
        p.skip = false;
        return;
    }
    if (p.skip) return;
    const v = vals(str);
    if (eq(cmd, "CUSTOMOPTION")) {
        if (str.len > 2) try p.skin.enabled.put(p.a, int(str[2]) + pickedItem(p, str), {});
    } else if (eq(cmd, "CUSTOMFILE")) {
        if (str.len < 3) return;
        var o: std.json.ObjectMap = .empty;
        try o.put(p.a, "path", .{ .string = skinRel(p.a, str[2]) orelse return });
        try o.put(p.a, "def", .{ .string = p.conf.file.map.get(str[1]) orelse if (str.len > 3) str[3] else "" });
        try p.files.append(p.a, .{ .object = o });
    } else if (eq(cmd, "CUSTOMOFFSET")) {
        // 0 fills the DST fields a line leaves empty, so it can never name an offset.
        if (str.len > 2 and int(str[2]) != 0) if (p.conf.offset.map.get(str[1])) |o| try p.offsets.put(p.a, int(str[2]), o);
    } else if (eq(cmd, "SETOPTION")) {
        if (str.len > 2 and int(str[2]) != 0) try p.skin.enabled.put(p.a, int(str[1]), {});
    } else if (eq(cmd, "RESOLUTION")) {
        const res = [_][2]f32{ .{ 640, 480 }, .{ 1280, 720 }, .{ 1920, 1080 }, .{ 3840, 2160 } };
        const i = if (str.len > 1) int(str[1]) else -1;
        if (i >= 0 and i < res.len) {
            p.skin.w = res[@intCast(i)][0];
            p.skin.h = res[@intCast(i)][1];
        }
    } else if (eq(cmd, "INCLUDE")) {
        if (str.len < 2 or p.depth > 8) return;
        const path = resolve(p, str[1]) orelse return;
        p.includes += 1;
        if (p.includes > max_includes) return error.BadInclude;
        p.depth += 1;
        defer p.depth -= 1;
        try runFile(p, path);
    } else if (eq(cmd, "IMAGE")) {
        try p.images.append(p.a, if (str.len > 1) resolve(p, str[1]) else null);
    } else if (eq(cmd, "LR2FONT")) {
        try p.fonts.append(p.a, if (str.len > 1) if (resolve(p, str[1])) |path| bitfont.loadCapped(p.a, p.io, path, &p.fonts_loaded) else null else null);
    } else if (eq(cmd, "SRC_IMAGE")) {
        p.current = null;
        try begin(p, runtimeImage(v[2]) orelse .{ .kind = .image, .src = srcOf(v) });
    } else if (eq(cmd, "SRC_NUMBER")) {
        p.current = null;
        const src = srcOf(v);
        const n = src.divx * src.divy;
        if (n < 10) return;
        var o: m.Object = .{ .kind = .number, .src = src, .ref = v[11], .align_ = v[12], .digits = m.clampDigits(v[13]) };
        if (@mod(n, 24) == 0) {
            o.signed = true;
            o.digits += 1;
        } else if (@mod(n, 10) != 0) o.zero_pad = true;
        try begin(p, o);
    } else if (eq(cmd, "SRC_TEXT")) {
        try begin(p, .{ .kind = .text, .ref = v[3], .align_ = v[4], .bitmap = if (v[2] >= 0 and v[2] < p.fonts.items.len) p.fonts.items[@intCast(v[2])] else null });
    } else if (eq(cmd, "SRC_BARGRAPH")) {
        try begin(p, .{ .kind = .graph, .src = srcOf(v), .ref = v[11] + 100, .dir = v[12] });
    } else if (eq(cmd, "SRC_SLIDER")) {
        try begin(p, .{ .kind = .slider, .src = srcOf(v), .dir = v[11], .range = @floatFromInt(v[12]), .ref = v[13] });
    } else if (eq(cmd, "SRC_GROOVEGAUGE") or eq(cmd, "SRC_GROOVEGAUGE_EX")) {
        const src = srcOf(v);
        const nodes = try p.a.alloc(m.Src, 4);
        const cols: i32 = @max(src.divx, 1);
        const rows: i32 = @max(src.divy, 1);
        const fw = @divTrunc(src.w, cols);
        const fh = @divTrunc(src.h, rows);
        for (nodes, 0..) |*nd, i| {
            const idx: i32 = @intCast(i);
            nd.* = .{ .tex = src.tex, .x = src.x + fw * @mod(idx, cols), .y = src.y + fh * @divTrunc(idx, cols), .w = fw, .h = fh };
        }
        const parts_n = if (v[13] <= 0) 50 else @min(v[13], m.max_parts);
        try begin(p, .{ .kind = .gauge, .nodes = nodes, .parts = parts_n, .dir = v[11] });
    } else if (eq(cmd, "SRC_BGA")) {
        try begin(p, .{ .kind = .bga });
    } else if (std.mem.startsWith(u8, cmd, "SRC_NOWJUDGE_1P")) {
        const idx: usize = @intCast(std.math.clamp(5 - v[1], 0, 5));
        p.judge_imgs[idx] = .{ .kind = .image, .src = srcOf(v) };
        p.has_judge = true;
        p.judge_shift = v[11] != 1;
    } else if (std.mem.startsWith(u8, cmd, "DST_NOWJUDGE_1P")) {
        const idx: usize = @intCast(std.math.clamp(5 - v[1], 0, 5));
        try applyDst(p, &p.judge_imgs[idx], &p.judge_keys[idx], v);
    } else if (std.mem.startsWith(u8, cmd, "SRC_NOWCOMBO_1P")) {
        const idx: usize = @intCast(std.math.clamp(5 - v[1], 0, 5));
        const src = srcOf(v);
        const n = src.divx * src.divy;
        // LR2PlaySkinLoader.setSrcNowCombo: align 1 means centred here.
        p.judge_nums[idx] = .{ .kind = .number, .src = src, .ref = 104, .digits = m.clampDigits(v[13]), .align_ = if (v[12] == 1) 2 else v[12], .signed = @mod(n, 24) == 0 };
    } else if (std.mem.startsWith(u8, cmd, "DST_NOWCOMBO_1P")) {
        const idx: usize = @intCast(std.math.clamp(5 - v[1], 0, 5));
        var kv = v;
        kv[4] = -v[4]; // LR2 measures combo y from the judge image upward
        if (p.judge_nums[idx].align_ == 2) kv[3] -= @divTrunc(p.judge_nums[idx].digits * v[5], 2);
        try applyDst(p, &p.judge_nums[idx], &p.judge_keys[idx + 6], kv);
    } else if (eq(cmd, "SRC_NOTE") or eq(cmd, "SRC_MINE") or eq(cmd, "SRC_LN_START") or eq(cmd, "SRC_LN_END") or eq(cmd, "SRC_LN_BODY") or eq(cmd, "SRC_LN_BODY_ACTIVE") or eq(cmd, "SRC_LN_BODY_INACTIVE")) {
        const lane = laneOf(p.mode, v[1]) orelse return;
        const n = &p.skin.notes;
        const target = if (eq(cmd, "SRC_NOTE")) &n.note else if (eq(cmd, "SRC_MINE")) &n.mine else if (eq(cmd, "SRC_LN_START")) &n.ln_start else if (eq(cmd, "SRC_LN_END")) &n.ln_end else if (eq(cmd, "SRC_LN_BODY_ACTIVE")) &n.ln_active else &n.ln_body;
        target[lane] = srcOf(v);
    } else if (eq(cmd, "DST_NOTE")) {
        const lane = laneOf(p.mode, v[1]) orelse return;
        if (!p.has_notes) {
            p.has_notes = true;
            const prev = p.current;
            try begin(p, .{ .kind = .notes });
            p.current = prev;
        }
        if (p.skin.notes.lane[lane] == null) {
            p.skin.notes.lane[lane] = .{ @floatFromInt(v[3]), @floatFromInt(v[4] + v[6]), @floatFromInt(v[5]), @floatFromInt(v[6]) };
        }
    } else if (std.mem.startsWith(u8, cmd, "DST_")) {
        const idx = p.current orelse return;
        const known = eq(cmd, "DST_IMAGE") or eq(cmd, "DST_NUMBER") or eq(cmd, "DST_TEXT") or eq(cmd, "DST_BARGRAPH") or eq(cmd, "DST_SLIDER") or eq(cmd, "DST_GROOVEGAUGE") or eq(cmd, "DST_BGA");
        if (!known) return;
        var kv = v;
        const o = &p.objects.items[idx];
        // With add_x set, the DST rect is one part wide; beatoraja widens it to all 50.
        if (eq(cmd, "DST_GROOVEGAUGE") and @abs(o.dir) >= 1) kv[5] = o.dir * 50;
        try applyDst(p, o, &p.keys.items[idx], kv);
    } else if (std.mem.startsWith(u8, cmd, "SRC_")) {
        // Unsupported part: later DST lines must not land on the previous object.
        p.current = null;
    }
}

fn readText(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const bytes = try fs.readAlloc(a, io, path, 1 << 24);
    return if (std.unicode.utf8ValidateSlice(bytes)) bytes else core.encoding.toUtf8(a, bytes, .sjis);
}

/// #IF is ignored: a chooser shows every #CUSTOMOPTION, #CUSTOMFILE and #CUSTOMOFFSET.
pub fn customOptions(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const jsonskin.Option {
    var out: std.ArrayList(jsonskin.Option) = .empty;
    var includes: u32 = 0;
    try scanOptions(a, io, skinRoot(path), path, &out, 0, &includes);
    return out.items;
}

fn scanOptions(a: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8, out: *std.ArrayList(jsonskin.Option), depth: u32, includes: *u32) Error!void {
    var lines = std.mem.splitScalar(u8, try readText(a, io, path), '\n');
    while (lines.next()) |raw| {
        var parts: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, raw, " \r\t"), ',');
        while (it.next()) |s| try parts.append(a, s);
        const f = parts.items;
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(f[0], "#INCLUDE")) {
            if (depth > 8 or f.len < 2) continue;
            const inc = resolvePath(a, io, root, &.{}, f[1]) orelse continue;
            includes.* += 1;
            if (includes.* > max_includes) return error.BadInclude;
            try scanOptions(a, io, root, inc, out, depth + 1, includes);
        } else if (eq(f[0], "#CUSTOMOPTION")) {
            if (f.len < 3) continue;
            var items: std.ArrayList([]const u8) = .empty;
            for (f[3..]) |item| {
                const name = std.mem.trim(u8, item, " ");
                if (name.len > 0) try items.append(a, name);
            }
            try out.append(a, .{ .kind = .property, .name = f[1], .choices = items.items, .def = if (items.items.len > 0) items.items[0] else "" });
        } else if (eq(f[0], "#CUSTOMFILE")) {
            if (f.len < 3) continue;
            // A folder that cannot be listed has nothing to choose from.
            const names = jsonskin.wildChoices(a, io, root, skinRel(a, f[2]) orelse continue) catch continue;
            try out.append(a, .{ .kind = .file, .name = f[1], .choices = names, .def = jsonskin.closest(names, if (f.len > 3) f[3] else "") orelse "" });
        } else if (eq(f[0], "#CUSTOMOFFSET")) {
            if (f.len < 3) continue;
            // #CUSTOMOFFSET,name,id,x,y,w,h,r,a: an axis left out is on.
            for (0..jsonskin.Offset.axes.len) |i| {
                if (f.len > i + 3 and int(f[i + 3]) <= 0) continue;
                try out.append(a, .{ .kind = .offset, .name = f[1], .field = @intCast(i) });
            }
        }
    }
}

fn runFile(p: *Parser, path: []const u8) !void {
    const text = try readText(p.a, p.io, path);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try line(p, l);
}

/// What "LR2files\Theme\<name>\" stands for: <name>/Play/7key.lr2skin gives <name>.
pub fn skinRoot(path: []const u8) []const u8 {
    const d = std.fs.path.dirname(path) orelse ".";
    return std.fs.path.dirname(d) orelse d;
}

pub fn load(skin: *m.Skin, io: std.Io, path: []const u8, mode: core.types.Mode, resolver: *const fn (i32) bool, conf: jsonskin.Conf) ![]const ?[]const u8 {
    const a = skin.arena.allocator();
    var p: Parser = .{ .a = a, .io = io, .skin = skin, .mode = mode, .root = skinRoot(path), .resolver = resolver, .conf = conf };
    try runFile(&p, path);
    for (p.objects.items, p.keys.items) |*o, k| o.keys = k.items;
    if (p.has_judge) {
        for (&p.judge_imgs, 0..) |*o, i| o.keys = p.judge_keys[i].items;
        for (&p.judge_nums, 0..) |*o, i| o.keys = p.judge_keys[i + 6].items;
        try p.objects.append(a, .{ .kind = .judge, .judge_images = &p.judge_imgs, .judge_numbers = &p.judge_nums, .shift = p.judge_shift });
        // the arrays above live on this stack frame
        const last = &p.objects.items[p.objects.items.len - 1];
        last.judge_images = try a.dupe(m.Object, &p.judge_imgs);
        last.judge_numbers = try a.dupe(m.Object, &p.judge_nums);
    }
    skin.objects = p.objects.items;
    // Last, as #IMAGE lines count their own position.
    for (p.fonts.items) |font| {
        const f = font orelse continue;
        f.first_tex = @intCast(p.images.items.len);
        try p.images.appendSlice(a, f.pages);
    }
    return p.images.items;
}

test "a saved pick selects its #CUSTOMOPTION item, includes too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const play = try std.fs.path.join(a, &.{ root, "play" });
    try fs.mkdirs(std.testing.io, play);
    const path = try std.fs.path.join(a, &.{ play, "s.lr2skin" });
    try fs.write(std.testing.io, path, "#CUSTOMOPTION,T,900,A,B,C,\r\n#INCLUDE,LR2files\\Theme\\x\\play\\i.csv\r\n");
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ play, "i.csv" }), "#CUSTOMOPTION,U,910,X,Y\n");

    const got = try customOptions(a, std.testing.io, path);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("T", got[0].name);
    try std.testing.expectEqual(@as(usize, 3), got[0].choices.len);
    try std.testing.expectEqualStrings("U", got[1].name);

    var conf: jsonskin.Conf = .{};
    try conf.property.map.put(a, "T", "C");
    var skin: m.Skin = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer skin.arena.deinit();
    const none = struct {
        fn f(_: i32) bool {
            return false;
        }
    }.f;
    _ = try load(&skin, std.testing.io, path, .beat7, &none, conf);
    try std.testing.expect(skin.enabled.contains(902));
    try std.testing.expect(!skin.enabled.contains(900));
    try std.testing.expect(skin.enabled.contains(910));
}

test "#CUSTOMFILE and #CUSTOMOFFSET are offered, and a saved pick moves the image and its rect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const frame = try std.fs.path.join(a, &.{ root, "frame" });
    try fs.mkdirs(io, frame);
    for ([_][]const u8{ "a.png", "b.png", "c.png" }) |f| try fs.write(io, try std.fs.path.join(a, &.{ frame, f }), "");
    const play = try std.fs.path.join(a, &.{ root, "play" });
    try fs.mkdirs(io, play);
    const path = try std.fs.path.join(a, &.{ play, "s.lr2skin" });
    try fs.write(io, path,
        \\#CUSTOMFILE,Frame,LR2files\Theme\x\frame\*.png,b
        \\#CUSTOMOFFSET,Pos,40,1,1,0,0,0,0
        \\#IMAGE,LR2files\Theme\x\frame\*.png
        \\#SRC_IMAGE,0,0,0,0,10,10,1,1,0,0
        \\#DST_IMAGE,0,0,5,6,10,10,0,255,255,255,255,0,0,0,0,0,0,0,0,0,40
    );

    const got = try customOptions(a, io, path);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqual(@as(usize, 3), got[0].choices.len);
    try std.testing.expectEqualStrings("b.png", got[0].def);
    try std.testing.expectEqual(@as(u3, 0), got[1].field);
    try std.testing.expectEqual(@as(u3, 1), got[2].field);

    var skin: m.Skin = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer skin.arena.deinit();
    const plain = try load(&skin, io, path, .beat7, &noneEnabled, .{});
    try std.testing.expect(std.mem.endsWith(u8, plain[0].?, "b.png"));
    try std.testing.expectEqual(@as(f32, 5), skin.objects[0].keys[0].x);

    var conf: jsonskin.Conf = .{};
    try conf.file.map.put(a, "Frame", "c.png");
    try conf.offset.map.put(a, "Pos", .{ .x = 2, .y = 3 });
    var picked: m.Skin = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer picked.arena.deinit();
    const images = try load(&picked, io, path, .beat7, &noneEnabled, conf);
    try std.testing.expect(std.mem.endsWith(u8, images[0].?, "c.png"));
    try std.testing.expectEqual(@as(f32, 7), picked.objects[0].keys[0].x);
    try std.testing.expectEqual(@as(f32, 3), picked.objects[0].keys[0].y);
}

test "runtime images become the chart's images and plain colors" {
    try std.testing.expectEqual(m.Kind.stagefile, runtimeImage(100).?.kind);
    try std.testing.expectEqual(m.Kind.backbmp, runtimeImage(101).?.kind);
    try std.testing.expectEqual(m.Kind.banner, runtimeImage(102).?.kind);
    try std.testing.expectEqual(@as(u8, 255), runtimeImage(111).?.src.solid.?[0]);
    try std.testing.expectEqual(@as(u8, 0), runtimeImage(110).?.src.solid.?[0]);
    try std.testing.expectEqual(@as(i32, -1), runtimeImage(150).?.src.tex);
    try std.testing.expect(runtimeImage(99) == null);
}

test "paths that climb out of the skin are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const inner = try std.fs.path.join(a, &.{ root, "skin" });
    try fs.mkdirs(std.testing.io, inner);
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ inner, "in.png" }), "");
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ root, "out.png" }), "");
    try std.testing.expect(resolvePath(a, std.testing.io, inner, &.{}, "LR2files\\Theme\\x\\in.png") != null);
    try std.testing.expectEqual(@as(?[]const u8, null), resolvePath(a, std.testing.io, inner, &.{}, "LR2files\\Theme\\x\\..\\out.png"));
    try std.testing.expectEqual(@as(?[]const u8, null), resolvePath(a, std.testing.io, inner, &.{}, "../out.png"));
    try std.testing.expectEqual(@as(?[]const u8, null), resolvePath(a, std.testing.io, inner, &.{}, "/etc/hostname"));
}

fn noneEnabled(_: i32) bool {
    return false;
}

test "a skin that includes itself twice is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const play = try std.fs.path.join(a, &.{ root, "play" });
    try fs.mkdirs(std.testing.io, play);
    const path = try std.fs.path.join(a, &.{ play, "s.lr2skin" });
    const once = "#INCLUDE,LR2files\\Theme\\x\\play\\s.lr2skin\n";
    try fs.write(std.testing.io, path, once ++ once);
    var skin: m.Skin = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer skin.arena.deinit();
    try std.testing.expectError(error.BadInclude, load(&skin, std.testing.io, path, .beat7, &noneEnabled, .{}));
    try std.testing.expectError(error.BadInclude, customOptions(a, std.testing.io, path));
    // One self-include is only a long chain, which depth ends.
    try fs.write(std.testing.io, path, once);
    _ = try load(&skin, std.testing.io, path, .beat7, &noneEnabled, .{});
}

test "hostile numbers in a CSV skin are bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fs.path.join(a, &.{ root, "s.lr2skin" });
    try fs.write(std.testing.io, path,
        \\#RESOLUTION
        \\#IF,-2147483648
        \\#ENDIF
        \\#SRC_NUMBER,0,0,0,0,10,10,2147483647,2147483647,0,0,0,0,2147483647
        \\#DST_NUMBER,0,-2147483648,-2147483648,-2147483648,-2147483648,-2147483648
        \\#SRC_GROOVEGAUGE,0,0,0,0,40,10,1,1,0,0,0,0,2147483647
        \\#SRC_NOWCOMBO_1P,0,0,0,0,10,10,2147483647,2147483647,0,0,0,0,-2147483648
        \\#DST_NOWCOMBO_1P,0,0,-2147483648,-2147483648,2147483647,2147483647
    );
    var skin: m.Skin = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer skin.arena.deinit();
    _ = try load(&skin, std.testing.io, path, .beat7, &noneEnabled, .{});
    try std.testing.expectEqual(@as(i32, m.max_div), skin.objects[0].src.divx);
    try std.testing.expect(skin.objects[0].digits <= 33); // 32 and a sign
    try std.testing.expectEqual(@as(i32, m.max_parts), skin.objects[1].parts);
}

test "lane codes" {
    try std.testing.expectEqual(@as(?u8, 7), laneOf(.beat7, 0));
    try std.testing.expectEqual(@as(?u8, 0), laneOf(.beat7, 1));
    try std.testing.expectEqual(@as(?u8, 6), laneOf(.beat7, 7));
    try std.testing.expectEqual(@as(?u8, null), laneOf(.beat7, 11));
    try std.testing.expectEqual(@as(?u8, 15), laneOf(.beat14, 10));
    try std.testing.expectEqual(@as(?u8, 8), laneOf(.beat14, 11));
    try std.testing.expectEqual(@as(?u8, 5), laneOf(.beat5, 0));
    try std.testing.expectEqual(@as(?u8, 8), laneOf(.popn9, 9));
}
