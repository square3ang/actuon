//! beatoraja JSON skins and, through a table-to-JSON bridge, Lua skins; the native format is the same schema.
const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");
const m = @import("model.zig");
const gfx = @import("../ui/gfx.zig");
const lr2 = @import("lr2csv.zig");
const J = std.json.Value;

/// beatoraja's JSON reader accepts trailing commas and comments; std.json does not.
pub fn sanitize(a: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_str = false;
    while (i < src.len) : (i += 1) {
        const ch = src[i];
        if (in_str) {
            try out.append(a, ch);
            if (ch == '\\' and i + 1 < src.len) {
                i += 1;
                try out.append(a, src[i]);
            } else if (ch == '"') in_str = false;
            continue;
        }
        if (ch == '"') {
            in_str = true;
        } else if (ch == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        } else if (ch == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse return error.BadJson;
            i = end + 1;
            continue;
        } else if (ch == '}' or ch == ']') {
            var n = out.items.len;
            while (n > 0 and std.ascii.isWhitespace(out.items[n - 1])) n -= 1;
            if (n > 0 and out.items[n - 1] == ',') out.items.len = n - 1;
        }
        try out.append(a, ch);
    }
    return out.toOwnedSlice(a);
}

pub fn parseFile(a: std.mem.Allocator, path: []const u8) !J {
    const raw = try fs.readAlloc(a, path, 1 << 25);
    const text = if (std.unicode.utf8ValidateSlice(raw)) raw else try core.encoding.toUtf8(a, raw, .sjis);
    const clean = try sanitize(a, if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text);
    return std.json.parseFromSliceLeaky(J, a, clean, .{ .allocate = .alloc_always });
}

fn int(v: ?J, d: i32) i32 {
    const x = v orelse return d;
    return switch (x) {
        .integer => |i| @intCast(std.math.clamp(i, std.math.minInt(i32), std.math.maxInt(i32))),
        .float => |f| @intFromFloat(std.math.clamp(f, -2e9, 2e9)),
        else => d,
    };
}

fn str(v: ?J) []const u8 {
    const x = v orelse return "";
    return if (x == .string) x.string else "";
}

fn arr(v: ?J) []const J {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn fnRef(v: ?J) i32 {
    const x = v orelse return 0;
    if (x != .object) return 0;
    return int(x.object.get("__fn"), 0);
}

fn idOf(a: std.mem.Allocator, v: ?J) ![]const u8 {
    const x = v orelse return "";
    return switch (x) {
        .string => |s| s,
        .integer => |i| std.fmt.allocPrint(a, "{d}", .{i}),
        else => "",
    };
}

/// The option a property starts on: the one its `def` names, else its first.
pub fn defaultItem(pv: J) ?std.json.ObjectMap {
    if (pv != .object) return null;
    const items = arr(pv.object.get("item"));
    const def = str(pv.object.get("def"));
    var chosen: ?std.json.ObjectMap = null;
    for (items) |it| {
        if (it != .object) continue;
        if (chosen == null) chosen = it.object;
        if (def.len > 0 and std.mem.eql(u8, str(it.object.get("name")), def)) return it.object;
    }
    return chosen;
}

/// A player's choices for one skin folder, by the skin's own names. Names it no longer has do nothing.
pub const Conf = struct {
    property: std.json.ArrayHashMap([]const u8) = .{},
    file: std.json.ArrayHashMap([]const u8) = .{},
    offset: std.json.ArrayHashMap(Offset) = .{},
};

pub const Offset = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    r: i32 = 0,
    a: i32 = 0,

    pub const axes = [_][:0]const u8{ "x", "y", "w", "h", "r", "a" };

    pub fn axis(o: *Offset, i: u3) *i32 {
        return switch (i) {
            0 => &o.x,
            1 => &o.y,
            2 => &o.w,
            3 => &o.h,
            4 => &o.r,
            else => &o.a,
        };
    }
};

/// Makes the player's choices the skin's defaults, which is all the loaders read.
pub fn applyConf(a: std.mem.Allocator, head: J, conf: Conf) !void {
    if (head != .object) return;
    for ([_]struct { []const u8, std.StringArrayHashMapUnmanaged([]const u8) }{
        .{ "property", conf.property.map },
        .{ "filepath", conf.file.map },
    }) |group| {
        const list = head.object.get(group[0]) orelse continue;
        if (list != .array) continue;
        for (list.array.items) |*e| {
            if (e.* != .object) continue;
            const pick = group[1].get(str(e.object.get("name"))) orelse continue;
            try e.object.put(a, "def", .{ .string = try a.dupe(u8, pick) });
        }
    }
}

/// What a filepath entry's "dir/*.png|1|/foot" can stand for: names in `dir`, sorted.
pub fn wildChoices(a: std.mem.Allocator, dir: []const u8, rel: []const u8) ![]const []const u8 {
    const star = std.mem.indexOfScalar(u8, rel, '*') orelse return &.{};
    const base_end = if (std.mem.lastIndexOfScalar(u8, rel[0..star], '/')) |i| i + 1 else 0;
    const seg_end = std.mem.indexOfScalarPos(u8, rel, star, '/') orelse rel.len;
    const tail = rel[star + 1..seg_end];
    const ext = tail[0 .. std.mem.indexOfScalar(u8, tail, '|') orelse tail.len];
    const pre = rel[base_end..star];
    var out: std.ArrayList([]const u8) = .empty;
    for (try fs.list(a, try std.fs.path.join(a, &.{ dir, rel[0..base_end] }))) |e| {
        if (e.name.len < pre.len + ext.len) continue;
        if (!std.ascii.startsWithIgnoreCase(e.name, pre) or !std.ascii.endsWithIgnoreCase(e.name, ext)) continue;
        if (seg_end < rel.len and !e.is_dir) continue;
        if (ext.len > 0 and e.is_dir) continue;
        try out.append(a, e.name);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.items;
}

/// Turns a skin's "dir/*.png|1|/foot" into a real path relative to `dir`: the file its `filepath`
/// entry names by `def`, else the name closest to `def`. The |n| marks only tell entries apart.
pub fn resolveWild(a: std.mem.Allocator, dir: []const u8, files: []const J, rel: []const u8) ![]const u8 {
    const star = std.mem.indexOfScalar(u8, rel, '*') orelse return rel;
    const base_end = if (std.mem.lastIndexOfScalar(u8, rel[0..star], '/')) |i| i + 1 else 0;
    const seg_end = std.mem.indexOfScalarPos(u8, rel, star, '/') orelse rel.len;
    const foot = rel[seg_end..];
    var def: []const u8 = "";
    for (files) |f| if (f == .object and std.mem.eql(u8, str(f.object.get("path")), rel[0..seg_end])) {
        def = str(f.object.get("def"));
    };
    const names = wildChoices(a, dir, rel) catch return rel;
    var best: ?[]const u8 = null;
    var best_score: usize = 0;
    for (names) |name| {
        const score = if (std.mem.eql(u8, name, def)) std.math.maxInt(usize) else std.mem.indexOfDiff(u8, name, def) orelse name.len;
        if (best == null or score > best_score) {
            best = name;
            best_score = score;
        }
    }
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ rel[0..base_end], best orelse return rel, foot });
}

/// "RRGGBBAA"; anything else is clear.
fn hexColor(s: []const u8) gfx.Color {
    const v = std.fmt.parseInt(u32, s, 16) catch return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    if (s.len != 8) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    return .{ .r = @truncate(v >> 24), .g = @truncate(v >> 16), .b = @truncate(v >> 8), .a = @truncate(v) };
}

const Loader = struct {
    a: std.mem.Allocator,
    skin: *m.Skin,
    dir: []const u8,
    resolver: *const fn (i32) bool,
    /// The header's filepath entries; a Lua body does not repeat them.
    head_files: []const J = &.{},
    /// Offset id -> the player's values.
    offsets: std.AutoHashMapUnmanaged(i32, Offset) = .empty,
    /// Font id -> file.
    fonts: std.StringHashMapUnmanaged([:0]const u8) = .empty,
    /// source id -> texture index
    sources: std.StringHashMapUnmanaged(i32) = .empty,
    paths: std.ArrayList(?[]const u8) = .empty,
    srcs: std.StringHashMapUnmanaged(m.Src) = .empty,
    protos: std.StringHashMapUnmanaged(m.Object) = .empty,
    note_id: []const u8 = "notes",
    files: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn testOp(l: *Loader, v: J) bool {
        switch (v) {
            .integer, .float => {
                const op = int(v, 0);
                const id = if (op < 0) -op else op;
                const on = l.skin.enabled.contains(id) or l.resolver(id);
                return if (op < 0) !on else on;
            },
            .array => |list| {
                for (list.items) |x| if (!l.testOp(x)) return false;
                return true;
            },
            else => return false,
        }
    }

    /// Expands {"if":..,"value":..} items and {"include":..} in arrays and values, like JsonSkinSerializer.
    fn expand(l: *Loader, v: J, depth: u32) anyerror!J {
        if (depth > 32) return v;
        switch (v) {
            .array => |list| {
                var out = std.json.Array.init(l.a);
                for (list.items) |item| {
                    if (item == .object) {
                        const o = item.object;
                        if (o.get("if")) |cond| {
                            if (o.get("value") != null or o.get("values") != null) {
                                if (!l.testOp(cond)) continue;
                                if (o.get("value")) |x| try out.append(try l.expand(x, depth + 1));
                                for (arr(o.get("values"))) |x| try out.append(try l.expand(x, depth + 1));
                                continue;
                            }
                        }
                        if (o.get("include")) |inc| {
                            const e = try l.loadInclude(str(inc), depth);
                            if (e == .array) try out.appendSlice(e.array.items) else try out.append(e);
                            continue;
                        }
                    }
                    try out.append(try l.expand(item, depth + 1));
                }
                return .{ .array = out };
            },
            .object => |o| {
                if (o.get("include")) |inc| return l.loadInclude(str(inc), depth);
                var out: std.json.ObjectMap = .empty;
                var it = o.iterator();
                while (it.next()) |e| try out.put(l.a, e.key_ptr.*, try l.expand(e.value_ptr.*, depth + 1));
                return .{ .object = out };
            },
            else => return v,
        }
    }

    fn loadInclude(l: *Loader, rel: []const u8, depth: u32) anyerror!J {
        if (std.mem.indexOf(u8, rel, "..") != null or std.fs.path.isAbsolute(rel)) return error.BadInclude;
        const p = lr2.walk(l.a, l.dir, rel) orelse return error.BadInclude;
        return l.expand(try parseFile(l.a, p), depth + 1);
    }

    fn src(l: *Loader, o: std.json.ObjectMap) !m.Src {
        const id = try idOf(l.a, o.get("src"));
        const w = int(o.get("w"), 0);
        const h = int(o.get("h"), 0);
        return .{
            .tex = l.sources.get(id) orelse -1,
            .x = int(o.get("x"), 0),
            .y = int(o.get("y"), 0),
            .w = if (w == 0) -1 else w,
            .h = if (h == 0) -1 else h,
            .divx = @max(int(o.get("divx"), 1), 1),
            .divy = @max(int(o.get("divy"), 1), 1),
            .cycle = int(o.get("cycle"), 0),
            .timer = int(o.get("timer"), 0),
            .len = @max(int(o.get("len"), 1), 1),
            .ref = @max(int(o.get("ref"), 0), int(o.get("value"), 0)),
        };
    }

    fn lookupSrc(l: *Loader, v: J) !m.Src {
        const id = try idOf(l.a, v);
        return l.srcs.get(id) orelse .{};
    }

    fn fill(l: *Loader, out: *m.Object, d: std.json.ObjectMap) !void {
        out.timer = int(d.get("timer"), 0);
        out.lua_timer = fnRef(d.get("timer"));
        out.lua_draw = fnRef(d.get("draw"));
        out.loop = int(d.get("loop"), 0);
        out.blend = @intCast(std.math.clamp(int(d.get("blend"), 1), 0, 255));
        out.center = @intCast(std.math.clamp(int(d.get("center"), 0), 0, 9));
        out.stretch = int(d.get("stretch"), -1);
        var ops: std.ArrayList(i32) = .empty;
        for (arr(d.get("op"))) |x| try ops.append(l.a, int(x, 0));
        out.ops = ops.items;
        var keys: std.ArrayList(m.Key) = .empty;
        var prev: m.Key = .{};
        for (arr(d.get("dst"))) |kv| {
            if (kv != .object) continue;
            const ko = kv.object;
            var k = prev;
            k.time = int(ko.get("time"), if (keys.items.len == 0) 0 else prev.time);
            k.x = @floatFromInt(int(ko.get("x"), @intFromFloat(prev.x)));
            k.w = @floatFromInt(int(ko.get("w"), @intFromFloat(prev.w)));
            k.h = @floatFromInt(int(ko.get("h"), @intFromFloat(prev.h)));
            // prev.y holds the raw bottom-up value until the flip below
            k.y = @floatFromInt(int(ko.get("y"), @intFromFloat(prev.y)));
            k.acc = @intCast(std.math.clamp(int(ko.get("acc"), prev.acc), 0, 3));
            k.a = @floatFromInt(int(ko.get("a"), @intFromFloat(prev.a)));
            k.r = @floatFromInt(int(ko.get("r"), @intFromFloat(prev.r)));
            k.g = @floatFromInt(int(ko.get("g"), @intFromFloat(prev.g)));
            k.b = @floatFromInt(int(ko.get("b"), @intFromFloat(prev.b)));
            k.angle = @floatFromInt(int(ko.get("angle"), @intFromFloat(prev.angle)));
            prev = k;
            try keys.append(l.a, k);
        }
        // JSON coordinates are bottom-up.
        var ids: std.ArrayList(J) = .empty;
        if (d.get("offset")) |one| try ids.append(l.a, one);
        try ids.appendSlice(l.a, arr(d.get("offsets")));
        for (ids.items) |id| {
            if (int(id, 0) == 3) out.lifted = true;
            const o = l.offsets.get(int(id, 0)) orelse continue;
            for (keys.items) |*k| {
                k.x += @floatFromInt(o.x);
                k.y += @floatFromInt(o.y);
                k.w += @floatFromInt(o.w);
                k.h += @floatFromInt(o.h);
                k.angle += @floatFromInt(o.r);
                k.a += @floatFromInt(o.a);
            }
        }
        for (keys.items) |*k| k.y = l.skin.h - (k.y + k.h);
        out.keys = keys.items;
    }

    /// A path the skin names, as a real file inside the skin folder or null.
    fn assetPath(l: *Loader, raw: []const u8) !?[]const u8 {
        const rel = try l.a.dupe(u8, raw);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        // skin_config.get_path hands out absolute paths inside the skin; nothing else may be absolute.
        const abs_inside = if (std.mem.startsWith(u8, rel, l.dir)) std.mem.trimStart(u8, rel[l.dir.len..], "/") else rel;
        const inside = try resolveWild(l.a, l.dir, l.head_files, abs_inside);
        const safe = !fs.climbs(inside) and !std.fs.path.isAbsolute(inside);
        return if (safe) lr2.walk(l.a, l.dir, inside) else null;
    }

    fn build(l: *Loader, root: J) !void {
        const a = l.a;
        const r = root.object;
        l.skin.w = @floatFromInt(int(r.get("w"), 1280));
        l.skin.h = @floatFromInt(int(r.get("h"), 720));
        l.skin.loadend_ms = int(r.get("loadend"), 0);
        l.skin.scene_ms = int(r.get("scene"), 3000);
        l.skin.input_ms = int(r.get("input"), 0);
        l.skin.fadeout_ms = int(r.get("fadeout"), 0);
        for (arr(r.get("property"))) |pv| {
            if (pv != .object) continue;
            if (defaultItem(pv)) |ch| {
                const op = int(ch.get("op"), 0);
                if (op != 0) try l.skin.enabled.put(a, op, {});
            }
        }
        for (arr(r.get("source"))) |v| {
            if (v != .object) continue;
            const id = try idOf(a, v.object.get("id"));
            try l.paths.append(a, try l.assetPath(str(v.object.get("path"))));
            try l.sources.put(a, id, @intCast(l.paths.items.len - 1));
        }
        for (arr(r.get("font"))) |v| {
            if (v != .object) continue;
            const file = try l.assetPath(str(v.object.get("path"))) orelse continue;
            try l.fonts.put(a, try idOf(a, v.object.get("id")), try a.dupeSentinel(u8, file, 0));
        }
        for (arr(r.get("image"))) |v| {
            if (v != .object) continue;
            const id = try idOf(a, v.object.get("id"));
            try l.srcs.put(a, id, try l.src(v.object));
        }
        try l.srcs.put(a, "-110", .{ .solid = .{ 0, 0, 0 } });
        try l.srcs.put(a, "-111", .{ .solid = .{ 255, 255, 255 } });
        for (arr(r.get("imageset"))) |v| {
            if (v != .object) continue;
            var set: std.ArrayList(m.Src) = .empty;
            for (arr(v.object.get("images"))) |x| try set.append(a, try l.lookupSrc(x));
            try l.srcs.put(a, try idOf(a, v.object.get("id")), .{ .set = set.items, .set_ref = @max(int(v.object.get("ref"), 0), int(v.object.get("value"), 0)) });
        }
        for (arr(r.get("value"))) |v| {
            if (v != .object) continue;
            const o = v.object;
            const s = try l.src(o);
            const n = s.divx * s.divy;
            try l.protos.put(a, try idOf(a, o.get("id")), .{
                .kind = .number,
                .src = s,
                .ref = int(o.get("ref"), 0),
                .lua_value = fnRef(o.get("value")),
                .digits = int(o.get("digit"), 0),
                .align_ = int(o.get("align"), 0),
                .zero_pad = int(o.get("zeropadding"), 0) != 0 or int(o.get("padding"), 0) != 0,
                .signed = @mod(n, 24) == 0,
            });
        }
        for (arr(r.get("text"))) |v| {
            if (v != .object) continue;
            const o = v.object;
            try l.protos.put(a, try idOf(a, o.get("id")), .{ .kind = .text, .ref = int(o.get("ref"), 0), .lua_value = fnRef(o.get("value")), .align_ = int(o.get("align"), 0), .constant = str(o.get("constantText")), .font = l.fonts.get(try idOf(a, o.get("font"))) });
        }
        for (arr(r.get("graph"))) |v| {
            if (v != .object) continue;
            const o = v.object;
            try l.protos.put(a, try idOf(a, o.get("id")), .{ .kind = .graph, .src = try l.src(o), .ref = int(o.get("type"), 0), .dir = int(o.get("angle"), 1) });
        }
        for (arr(r.get("slider"))) |v| {
            if (v != .object) continue;
            const o = v.object;
            try l.protos.put(a, try idOf(a, o.get("id")), .{ .kind = .slider, .src = try l.src(o), .ref = int(o.get("type"), 0), .dir = int(o.get("angle"), 0), .range = @floatFromInt(int(o.get("range"), 0)) });
        }
        if (r.get("gauge")) |gv| if (gv == .object) {
            var nodes: std.ArrayList(m.Src) = .empty;
            for (arr(gv.object.get("nodes"))) |x| try nodes.append(a, try l.lookupSrc(x));
            try l.protos.put(a, try idOf(a, gv.object.get("id")), .{ .kind = .gauge, .nodes = nodes.items, .parts = int(gv.object.get("parts"), 50) });
        };
        for (arr(r.get("judgegraph"))) |v| {
            if (v == .object) try l.protos.put(a, try idOf(a, v.object.get("id")), .{ .kind = .notes_graph });
        }
        for (arr(r.get("bpmgraph"))) |v| {
            if (v == .object) try l.protos.put(a, try idOf(a, v.object.get("id")), .{ .kind = .bpm_graph });
        }
        for ([_][]const u8{ "timingvisualizer", "hiterrorvisualizer" }, [_]bool{ false, true }) |key, errors| {
            for (arr(r.get(key))) |v| {
                if (v != .object) continue;
                const o = v.object;
                try l.protos.put(a, try idOf(a, o.get("id")), .{
                    .kind = .timing,
                    .timing_ms = @max(int(o.get("judgeWidthMillis"), 150), 1),
                    .timing_colors = .{ hexColor(str(o.get("PGColor"))), hexColor(str(o.get("GRColor"))), hexColor(str(o.get("GDColor"))), hexColor(str(o.get("BDColor"))), hexColor(str(o.get("PRColor"))) },
                    .timing_bare = errors or int(o.get("transparent"), 0) != 0,
                    .line_color = if (errors and int(o.get("colorMode"), 0) != 0) .{ .r = 0, .g = 0, .b = 0, .a = 0 } else hexColor(str(o.get("lineColor"))),
                    .ema_color = if (errors and int(o.get("emaMode"), 0) != 0) hexColor(str(o.get("emaColor"))) else .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    .window = @intCast(std.math.clamp(int(o.get("windowLength"), 64), 1, 64)),
                    .decay = int(o.get("drawDecay"), 0) != 0,
                });
            }
        }
        try l.protos.put(a, "-100", .{ .kind = .stagefile });
        for ([_][]const u8{ "hiddenCover", "liftCover" }, [_]m.Kind{ .hidden_cover, .lift_cover }) |key, kind| {
            for (arr(r.get(key))) |v| {
                if (v != .object) continue;
                const o = v.object;
                try l.protos.put(a, try idOf(a, o.get("id")), .{ .kind = kind, .src = try l.src(o), .lifted = true, .disappear_line = @floatFromInt(int(o.get("disapearLine"), -1)) });
            }
        }
        if (r.get("bga")) |bv| if (bv == .object) try l.protos.put(a, try idOf(a, bv.object.get("id")), .{ .kind = .bga });
        if (r.get("note")) |nv| if (nv == .object) try l.notes(nv.object);
        for (arr(r.get("judge"))) |v| {
            if (v != .object) continue;
            const o = v.object;
            if (int(o.get("index"), 0) != 0) continue; // 1P only
            var imgs: std.ArrayList(m.Object) = .empty;
            for (arr(o.get("images"))) |d| {
                if (d != .object) continue;
                var x: m.Object = .{ .kind = .image, .src = try l.lookupSrc(d.object.get("id") orelse .null) };
                try l.fill(&x, d.object);
                try imgs.append(a, x);
            }
            var nums: std.ArrayList(m.Object) = .empty;
            for (arr(o.get("numbers"))) |d| {
                if (d != .object) continue;
                var x = l.protos.get(try idOf(a, d.object.get("id"))) orelse m.Object{ .kind = .number };
                try l.fill(&x, d.object);
                // Offsets from the judge image stay bottom-up: undo fill's flip.
                const ks = try a.dupe(m.Key, x.keys);
                // JsonPlaySkinObjectLoader: judge numbers are centred on their x.
                x.align_ = 2;
                for (ks) |*k| {
                    k.y = l.skin.h - k.y - k.h;
                    k.x -= k.w * @as(f32, @floatFromInt(x.digits)) / 2;
                }
                x.keys = ks;
                try nums.append(a, x);
            }
            try l.protos.put(a, try idOf(a, o.get("id")), .{ .kind = .judge, .judge_images = imgs.items, .judge_numbers = nums.items, .shift = if (o.get("shift")) |sh| sh == .bool and sh.bool else false });
        }
        if (r.get("songlist")) |sv| if (sv == .object) try l.songlist(sv.object);
        var objs: std.ArrayList(m.Object) = .empty;
        for (arr(r.get("destination"))) |d| {
            if (d != .object) continue;
            const id = try idOf(a, d.object.get("id"));
            var o: m.Object = undefined;
            if (std.mem.eql(u8, id, l.note_id)) {
                o = .{ .kind = .notes };
            } else if (l.protos.get(id)) |p| {
                o = p;
            } else if (l.srcs.get(id)) |s| {
                o = .{ .kind = .image, .src = s };
            } else continue;
            try l.fill(&o, d.object);
            try objs.append(a, o);
        }
        l.skin.objects = objs.items;
    }

    /// A part with an unknown id stays as a blank, since position in the list is what means something.
    fn barParts(l: *Loader, list: ?J) ![]const m.Object {
        var out: std.ArrayList(m.Object) = .empty;
        for (arr(list)) |d| {
            var x: m.Object = .{};
            if (d == .object) {
                const id = try idOf(l.a, d.object.get("id"));
                if (l.protos.get(id)) |p| {
                    x = p;
                } else if (l.srcs.get(id)) |s| x.src = s;
                try l.fill(&x, d.object);
            }
            try out.append(l.a, x);
        }
        return out.items;
    }

    fn songlist(l: *Loader, o: std.json.ObjectMap) !void {
        const list = try l.a.create(m.SongList);
        list.* = .{
            .center = @intCast(@max(int(o.get("center"), 0), 0)),
            .on = try l.barParts(o.get("liston")),
            .off = try l.barParts(o.get("listoff")),
            .level = try l.barParts(o.get("level")),
            .label = try l.barParts(o.get("label")),
            .text = try l.barParts(o.get("text")),
            .lamp = try l.barParts(o.get("lamp")),
        };
        try l.protos.put(l.a, try idOf(l.a, o.get("id")), .{ .kind = .songlist, .songlist = list });
    }

    fn notes(l: *Loader, o: std.json.ObjectMap) !void {
        l.note_id = try idOf(l.a, o.get("id"));
        const set = &l.skin.notes;
        const fields = [_]struct { []const u8, *[core.types.max_lanes]m.Src }{
            .{ "note", &set.note },
            .{ "lnstart", &set.ln_start },
            .{ "lnend", &set.ln_end },
            .{ "mine", &set.mine },
        };
        for (fields) |f| for (arr(o.get(f[0])), 0..) |id, i| {
            if (i < f[1].len) f[1][i] = try l.lookupSrc(id);
        };
        // As beatoraja: without lnbodyActive, "lnbody" is what shows held and "lnactive" what shows released.
        const has_active = arr(o.get("lnbodyActive")).len > 0;
        const held = arr(o.get(if (has_active) "lnbodyActive" else "lnbody"));
        const released = arr(o.get(if (has_active) "lnbody" else "lnactive"));
        for (held, 0..) |id, i| if (i < set.ln_active.len) {
            set.ln_active[i] = try l.lookupSrc(id);
        };
        for (if (released.len > 0) released else held, 0..) |id, i| if (i < set.ln_body.len) {
            set.ln_body[i] = try l.lookupSrc(id);
        };
        for (arr(o.get("dst")), 0..) |kv, i| {
            if (kv != .object or i >= set.lane.len) continue;
            // dst.h is the lane's height; the note's own comes from "size" or the note image.
            const sizes = arr(o.get("size"));
            const img_h = @divTrunc(set.note[i].h, @max(set.note[i].divy, 1));
            const h: f32 = if (i < sizes.len) @floatFromInt(int(sizes[i], 12)) else if (img_h > 0) @floatFromInt(img_h) else 12;
            const y: f32 = @floatFromInt(int(kv.object.get("y"), 0));
            set.lane[i] = .{ @floatFromInt(int(kv.object.get("x"), 0)), l.skin.h - y, @floatFromInt(int(kv.object.get("w"), 0)), h };
        }
    }
};

/// `head` holds the options: the root itself for a JSON skin, the script's header for a Lua one.
pub fn fromJson(skin: *m.Skin, root_in: J, head: J, dir: []const u8, resolver: *const fn (i32) bool, conf: Conf) ![]const ?[]const u8 {
    const a = skin.arena.allocator();
    var l: Loader = .{ .a = a, .skin = skin, .dir = dir, .resolver = resolver };
    if (root_in != .object or head != .object) return error.BadSkin;
    try applyConf(a, head, conf);
    try applyConf(a, root_in, conf);
    l.head_files = arr(head.object.get("filepath"));
    for (arr(head.object.get("offset"))) |e| {
        if (e != .object or e.object.get("id") == null) continue;
        const o = conf.offset.map.get(str(e.object.get("name"))) orelse continue;
        try l.offsets.put(a, int(e.object.get("id"), 0), o);
    }
    // Options must be known before conditionals expand.
    for (arr(head.object.get("property"))) |pv| {
        if (defaultItem(pv)) |ch| {
            const op = int(ch.get("op"), 0);
            if (op != 0) try skin.enabled.put(a, op, {});
        }
    }
    const root = try l.expand(root_in, 0);
    try l.build(root);
    return l.paths.items;
}

pub fn load(skin: *m.Skin, path: []const u8, resolver: *const fn (i32) bool, conf: Conf) ![]const ?[]const u8 {
    const root = try parseFile(skin.arena.allocator(), path);
    return fromJson(skin, root, root, std.fs.path.dirname(path) orelse ".", resolver, conf);
}

test "sanitize strips comments and trailing commas" {
    const a = std.testing.allocator;
    const out = try sanitize(a, "{\"a\":[1,2,],// x,\n \"b\":\"//,]\",}");
    defer a.free(out);
    try std.testing.expectEqualStrings("{\"a\":[1,2], \"b\":\"//,]\"}", out);
}

test "wildcards resolve to the default, or the closest name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    for ([_][]const u8{ "s/FHD_center.lua", "s/FHD_default_Left.lua", "b/x/BOMB.png", "b/y/BOMB.png" }) |f| {
        const full = try std.fs.path.join(a, &.{ dir, f });
        try fs.mkdirs(std.fs.path.dirname(full).?);
        try fs.write(full, "");
    }
    const entry = struct {
        fn f(al: std.mem.Allocator, path: []const u8, def: []const u8) !J {
            var o: std.json.ObjectMap = .empty;
            try o.put(al, "path", .{ .string = path });
            try o.put(al, "def", .{ .string = def });
            return .{ .object = o };
        }
    }.f;
    const files = [_]J{ try entry(a, "s/*.lua", "FHD_default_1P.lua"), try entry(a, "b/*|2|", "y") };
    try std.testing.expectEqualStrings("s/FHD_default_Left.lua", try resolveWild(a, dir, &files, "s/*.lua"));
    try std.testing.expectEqualStrings("b/y/BOMB.png", try resolveWild(a, dir, &files, "b/*|2|/BOMB.png"));
    try std.testing.expectEqualStrings("b/x/BOMB.png", try resolveWild(a, dir, &files, "b/*|9|/BOMB.png"));
}
