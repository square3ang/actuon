const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");
const gfx = @import("../ui/gfx.zig");
const bga = @import("../ui/bga.zig");
pub const model = @import("model.zig");
const lr2 = @import("lr2csv.zig");
const jsonskin = @import("jsonskin.zig");
const osuskin = @import("osuskin.zig");
const lua = @import("lua.zig");
const config = @import("../game/config.zig");
const Skin = model.Skin;

/// Skin type ids shared by LR2 #INFORMATION and beatoraja "type".
pub fn playType(mode: core.types.Mode) i32 {
    return switch (mode) {
        .beat7 => 0,
        .beat5 => 1,
        .beat14 => 2,
        .beat10 => 3,
        .popn9 => 4,
        .beat4 => type_beat4,
        .beat6 => type_beat6,
    };
}
pub const type_select = 5;
pub const type_decide = 6;
pub const type_result = 7;
/// Not beatoraja types: no LR2 or beatoraja skin claims them.
pub const type_beat4 = 100;
pub const type_beat6 = 101;

pub fn slotType(slot: config.SkinSlot) i32 {
    return switch (slot) {
        .select => type_select,
        .decide => type_decide,
        .result => type_result,
        .beat7 => playType(.beat7),
        .beat5 => playType(.beat5),
        .beat14 => playType(.beat14),
        .beat10 => playType(.beat10),
        .popn9 => playType(.popn9),
        .beat4 => type_beat4,
        .beat6 => type_beat6,
    };
}

pub fn playSlot(mode: core.types.Mode) config.SkinSlot {
    return switch (mode) {
        .beat7 => .beat7,
        .beat5 => .beat5,
        .beat14 => .beat14,
        .beat10 => .beat10,
        .popn9 => .popn9,
        .beat4 => .beat4,
        .beat6 => .beat6,
    };
}

/// Other types are never drawn, so their options would do nothing.
fn offersOptions(t: i64) bool {
    return t <= 4 or t == type_select or t == type_decide or t == type_result;
}

fn typeOfFile(a: std.mem.Allocator, io: std.Io, path: []const u8) ?i32 {
    const bytes = fs.readAlloc(a, io, path, 1 << 25) catch return null;
    if (std.ascii.endsWithIgnoreCase(path, ".lr2skin")) {
        const at = std.ascii.findIgnoreCase(bytes, "#INFORMATION,") orelse return null;
        const rest = bytes[at + "#INFORMATION,".len ..];
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
        return std.fmt.parseInt(i32, std.mem.trim(u8, rest[0..end], " "), 10) catch null;
    }
    // Lua skins compute their header, so the script has to run; it runs sandboxed.
    if (std.ascii.endsWithIgnoreCase(path, ".luaskin")) {
        const h = lua.header(a, io, path) catch return null;
        if (h != .object) return null;
        const t = h.object.get("type") orelse return null;
        return if (t == .integer) std.math.cast(i32, t.integer) else null;
    }
    // A lexical peek at the JSON's `type` field avoids parsing every file.
    const at = std.mem.indexOf(u8, bytes, "type") orelse return null;
    var i = at + 4;
    while (i < bytes.len and (bytes[i] == '"' or bytes[i] == ':' or bytes[i] == '=' or bytes[i] == ' ')) i += 1;
    var end = i;
    while (end < bytes.len and bytes[end] >= '0' and bytes[end] <= '9') end += 1;
    return std.fmt.parseInt(i32, bytes[i..end], 10) catch null;
}

fn isSkinFile(name: []const u8) bool {
    if (osuskin.isIni(name)) return true;
    for ([_][]const u8{ ".lr2skin", ".json", ".luaskin" }) |e| if (std.ascii.endsWithIgnoreCase(name, e)) return true;
    return false;
}

/// One osu! skin.ini serves these key modes; shortcut: not the 14, 10 and 9 key slots until asked for.
const osu_types = [_]i32{ 0, 1, type_beat4, type_beat6 };

fn hasType(a: std.mem.Allocator, io: std.Io, path: []const u8, want: i32) bool {
    if (osuskin.isIni(path)) return std.mem.indexOfScalar(i32, &osu_types, want) != null and osuskin.hasMania(a, io, path);
    return typeOfFile(a, io, path) == want;
}

pub fn listSkins(a: std.mem.Allocator, io: std.Io, dir: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try fs.list(a, io, dir)) |e| {
        if (!e.is_dir) continue;
        const sub = try std.fs.path.join(a, &.{ dir, e.name });
        if (holdsSkin(a, io, sub)) try out.append(a, e.name);
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(x, y);
        }
    }.lt);
    return out.items;
}

fn holdsSkin(a: std.mem.Allocator, io: std.Io, dir: []const u8) bool {
    const entries = fs.list(a, io, dir) catch return false;
    for (entries) |e| if (!e.is_dir and isSkinFile(e.name)) return true;
    for (entries) |e| if (e.is_dir) {
        const sub = std.fs.path.join(a, &.{ dir, e.name }) catch return false;
        for (fs.list(a, io, sub) catch continue) |f| if (!f.is_dir and isSkinFile(f.name)) return true;
    };
    return false;
}

pub const SkinFile = struct { path: []const u8, type: i32 };

fn addFile(a: std.mem.Allocator, io: std.Io, out: *std.ArrayList(SkinFile), path: []const u8) !void {
    if (osuskin.isIni(path)) {
        if (osuskin.hasMania(a, io, path)) for (osu_types) |t| try out.append(a, .{ .path = path, .type = t });
    } else if (typeOfFile(a, io, path)) |t| try out.append(a, .{ .path = path, .type = t });
}

pub fn allFiles(a: std.mem.Allocator, io: std.Io) ![]const SkinFile {
    const root = try skinsDir(a);
    var out: std.ArrayList(SkinFile) = .empty;
    for (try listSkins(a, io, root)) |name| {
        const dir = try std.fs.path.join(a, &.{ root, name });
        for (try fs.list(a, io, dir)) |e| {
            const p = try std.fs.path.join(a, &.{ dir, e.name });
            if (!e.is_dir) {
                if (isSkinFile(e.name)) try addFile(a, io, &out, p);
                continue;
            }
            for (fs.list(a, io, p) catch continue) |f| if (!f.is_dir and isSkinFile(f.name)) {
                try addFile(a, io, &out, try std.fs.path.join(a, &.{ p, f.name }));
            };
        }
    }
    return out.items;
}

pub fn skinsDir(a: std.mem.Allocator) ![]const u8 {
    const data = try fs.dataDir(a);
    return std.fmt.allocPrint(a, "{s}skins", .{data});
}

/// A file of another type stands for its folder: its siblings cover the other key modes.
pub fn find(a: std.mem.Allocator, io: std.Io, root: []const u8, want: i32) ?[]const u8 {
    const st = fs.stat(io, root) orelse return null;
    if (!st.is_dir) {
        if (hasType(a, io, root, want)) return root;
        return find(a, io, std.fs.path.dirname(root) orelse return null, want);
    }
    const entries = fs.list(a, io, root) catch return null;
    for (entries) |e| if (!e.is_dir and isSkinFile(e.name)) {
        const p = std.fs.path.join(a, &.{ root, e.name }) catch return null;
        if (hasType(a, io, p, want)) return p;
    };
    for (entries) |e| if (e.is_dir) {
        const sub = std.fs.path.join(a, &.{ root, e.name }) catch return null;
        for (fs.list(a, io, sub) catch continue) |f| if (!f.is_dir and isSkinFile(f.name)) {
            const p = std.fs.path.join(a, &.{ sub, f.name }) catch return null;
            if (hasType(a, io, p, want)) return p;
        };
    };
    return null;
}

pub const Conf = jsonskin.Conf;

pub const Option = struct {
    kind: enum { property, file, offset },
    name: []const u8,
    choices: []const []const u8 = &.{},
    def: []const u8 = "",
    /// offset: which field of jsonskin.Offset.
    field: u3 = 0,
};

fn confRoot(io: std.Io, root: []const u8) []const u8 {
    const st = fs.stat(io, root) orelse return root;
    return if (st.is_dir) root else std.fs.path.dirname(root) orelse root;
}

/// As beatoraja, each screen and key mode keeps its own choices.
fn confPath(a: std.mem.Allocator, io: std.Io, root: []const u8, want: i32) ![]const u8 {
    const data = try fs.dataDir(a);
    return std.fmt.allocPrint(a, "{s}skinconf/{x}-{d}.json", .{ data, std.hash.Wyhash.hash(0, confRoot(io, root)), want });
}

/// Before choices were per screen, one file covered the whole folder.
fn sharedConfPath(a: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    const data = try fs.dataDir(a);
    return std.fmt.allocPrint(a, "{s}skinconf/{x}.json", .{ data, std.hash.Wyhash.hash(0, confRoot(io, root)) });
}

pub fn loadConf(a: std.mem.Allocator, io: std.Io, root: []const u8, want: i32) Conf {
    const p = confPath(a, io, root, want) catch return .{};
    const bytes = fs.readAlloc(a, io, p, 1 << 22) catch blk: {
        const old = sharedConfPath(a, io, root) catch return .{};
        break :blk fs.readAlloc(a, io, old, 1 << 22) catch return .{};
    };
    return std.json.parseFromSliceLeaky(Conf, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch .{};
}

pub fn saveConf(a: std.mem.Allocator, io: std.Io, root: []const u8, want: i32, conf: Conf) void {
    const p = confPath(a, io, root, want) catch return;
    fs.mkdirs(io, std.fs.path.dirname(p).?) catch {};
    const text = std.json.Stringify.valueAlloc(a, conf, .{ .whitespace = .indent_2 }) catch return;
    fs.writeAtomic(a, io, p, text) catch |e| std.log.err("skin settings save failed: {t}", .{e});
}

fn headerOf(a: std.mem.Allocator, io: std.Io, path: []const u8) ?std.json.Value {
    if (std.ascii.endsWithIgnoreCase(path, ".luaskin")) return lua.header(a, io, path) catch null;
    if (std.ascii.endsWithIgnoreCase(path, ".json")) return jsonskin.parseFile(a, io, path) catch null;
    return null;
}

fn addOptions(a: std.mem.Allocator, io: std.Io, out: *std.ArrayList(Option), dir: []const u8, head: std.json.Value) !void {
    if (head != .object) return;
    const list = struct {
        fn f(v: ?std.json.Value) []const std.json.Value {
            return if (v) |x| (if (x == .array) x.array.items else &.{}) else &.{};
        }
        fn s(v: ?std.json.Value) []const u8 {
            return if (v) |x| (if (x == .string) x.string else "") else "";
        }
    };
    const t = head.object.get("type") orelse return;
    if (t != .integer or !offersOptions(t.integer)) return;
    for (list.f(head.object.get("property"))) |p| {
        if (p != .object) continue;
        var names: std.ArrayList([]const u8) = .empty;
        for (list.f(p.object.get("item"))) |it| if (it == .object) try names.append(a, list.s(it.object.get("name")));
        const def = if (jsonskin.defaultItem(p)) |d| list.s(d.get("name")) else "";
        if (names.items.len > 1) try addOption(a, out, .{ .kind = .property, .name = list.s(p.object.get("name")), .choices = names.items, .def = def });
    }
    for (list.f(head.object.get("filepath"))) |f| {
        if (f != .object) continue;
        const names = jsonskin.wildChoices(a, io, dir, list.s(f.object.get("path"))) catch continue;
        if (names.len > 1) try addOption(a, out, .{ .kind = .file, .name = list.s(f.object.get("name")), .choices = names, .def = list.s(f.object.get("def")) });
    }
    for (list.f(head.object.get("offset"))) |o| {
        if (o != .object) continue;
        for (jsonskin.Offset.axes, 0..) |axis, i| {
            const on = o.object.get(axis) orelse continue;
            if (on == .bool and on.bool) try addOption(a, out, .{ .kind = .offset, .name = list.s(o.object.get("name")), .field = @intCast(i) });
        }
    }
}

fn addOption(a: std.mem.Allocator, out: *std.ArrayList(Option), o: Option) !void {
    for (out.items) |*e| if (e.kind == o.kind and e.field == o.field and std.mem.eql(u8, e.name, o.name)) {
        var merged: std.ArrayList([]const u8) = .empty;
        try merged.appendSlice(a, e.choices);
        for (o.choices) |ch| {
            for (e.choices) |have| {
                if (std.mem.eql(u8, have, ch)) break;
            } else try merged.append(a, ch);
        }
        e.choices = merged.items;
        return;
    };
    try out.append(a, o);
}

fn addFileOptions(a: std.mem.Allocator, io: std.Io, out: *std.ArrayList(Option), dir: []const u8, path: []const u8) !void {
    if (osuskin.isIni(path)) {
        try addOption(a, out, .{ .kind = .property, .name = osuskin.bga_stretch_name, .choices = &osuskin.bga_stretch_choices, .def = "Fit" });
        try addOption(a, out, .{ .kind = .property, .name = osuskin.bga_dim_name, .choices = &osuskin.bga_dim_choices, .def = "0%" });
        try addOption(a, out, .{ .kind = .property, .name = osuskin.gauge_color_name, .choices = &osuskin.gauge_color_choices, .def = "On" });
        try addOption(a, out, .{ .kind = .property, .name = osuskin.scratch_side_name, .choices = &osuskin.scratch_side_choices, .def = "Left" });
        return;
    }
    if (std.ascii.endsWithIgnoreCase(path, ".lr2skin")) {
        const t = typeOfFile(a, io, path) orelse return;
        if (!offersOptions(t)) return;
        for (lr2.customOptions(a, io, path) catch return) |o| {
            if (o.items.len > 1) try addOption(a, out, .{ .kind = .property, .name = o.title, .choices = o.items, .def = o.items[0] });
        }
    } else if (headerOf(a, io, path)) |h| try addOptions(a, io, out, dir, h);
}

pub const scratchRight = osuskin.scratchRight;

const builtin_options = [_]Option{.{ .kind = .property, .name = osuskin.scratch_side_name, .choices = &osuskin.scratch_side_choices, .def = "Left" }};

/// shortcut: LR2 #CUSTOMFILE and #CUSTOMOFFSET are not offered, their wildcards take the first match.
pub fn options(a: std.mem.Allocator, io: std.Io, root: []const u8, want: i32) ![]const Option {
    if (root.len == 0) return if (want == playType(.beat7) or want == playType(.beat5)) &builtin_options else &.{};
    const path = find(a, io, root, want) orelse return &.{};
    var out: std.ArrayList(Option) = .empty;
    try addFileOptions(a, io, &out, std.fs.path.dirname(path) orelse ".", path);
    return out.items;
}

const CachedTexture = struct { tex: *gfx.Texture, size: [2]f32, mtime: i128 };
/// By path: skins are rebuilt per song, as their scripts read it, but their images need not be.
var texture_cache: std.StringHashMapUnmanaged(CachedTexture) = .empty;

fn cachedTexture(gpa: std.mem.Allocator, io: std.Io, g: *gfx.Gfx, file: []const u8) ?CachedTexture {
    const mtime: i128 = if (fs.stat(io, file)) |st| st.mtime else 0;
    const old = texture_cache.getEntry(file);
    if (old) |e| if (e.value_ptr.mtime == mtime) return e.value_ptr.*;
    const bytes = fs.readAlloc(gpa, io, file, 1 << 28) catch return null;
    defer gpa.free(bytes);
    const tex = gfx.loadTexture(g, file, bytes) orelse return null;
    const fresh: CachedTexture = .{ .tex = tex, .size = .{ tex.w, tex.h }, .mtime = mtime };
    if (old) |e| {
        // An edited file: no skin holds the old texture across a reload that gets here.
        g.destroyTexture(e.value_ptr.tex);
        e.value_ptr.* = fresh;
        return fresh;
    }
    const key = gpa.dupe(u8, file) catch return fresh;
    texture_cache.put(gpa, key, fresh) catch gpa.free(key);
    return fresh;
}

pub fn clearTextures(gpa: std.mem.Allocator, g: *gfx.Gfx) void {
    var it = texture_cache.iterator();
    while (it.next()) |e| {
        g.destroyTexture(e.value_ptr.tex);
        gpa.free(e.key_ptr.*);
    }
    texture_cache.deinit(gpa);
    texture_cache = .empty;
}

pub fn load(gpa: std.mem.Allocator, io: std.Io, g: *gfx.Gfx, path: []const u8, mode: core.types.Mode, resolver: *const fn (i32) bool, conf: Conf, lua_env: lua.Env) !*Skin {
    const skin = try gpa.create(Skin);
    errdefer gpa.destroy(skin);
    skin.* = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer skin.deinit();
    const a = skin.arena.allocator();
    skin.path = try a.dupe(u8, path);
    skin.mtime = if (fs.stat(io, path)) |st| st.mtime else 0;
    const paths = if (osuskin.isIni(path))
        try osuskin.load(skin, io, path, mode, conf)
    else if (std.ascii.endsWithIgnoreCase(path, ".lr2skin") or std.ascii.endsWithIgnoreCase(path, ".csv"))
        try lr2.load(skin, io, path, mode, resolver, conf)
    else if (std.ascii.endsWithIgnoreCase(path, ".json"))
        try jsonskin.load(skin, io, path, resolver, conf)
    else
        try lua.load(skin, io, path, resolver, conf, lua_env);
    skin.textures = try a.alloc(?*gfx.Texture, paths.len);
    skin.tex_sizes = try a.alloc([2]f32, paths.len);
    var videos: std.ArrayList(*bga.Video) = .empty;
    for (paths, skin.textures, skin.tex_sizes) |p, *t, *sz| {
        t.* = null;
        sz.* = .{ 0, 0 };
        const file = p orelse continue;
        if (bga.isVideo(file)) {
            const v = bga.Video.open(gpa, g, file) catch continue;
            try videos.append(a, v);
            t.* = v.tex;
            sz.* = .{ @floatFromInt(v.w), @floatFromInt(v.h) };
            continue;
        }
        const cached = cachedTexture(gpa, io, g, file) orelse continue;
        t.* = cached.tex;
        sz.* = cached.size;
    }
    skin.videos = videos.items;
    return skin;
}

pub fn destroy(gpa: std.mem.Allocator, s: *Skin) void {
    for (s.videos) |v| v.destroy(gpa);
    s.deinit();
    gpa.destroy(s);
}

pub fn changed(s: *const Skin, io: std.Io) bool {
    const st = fs.stat(io, s.path) orelse return false;
    return st.mtime != s.mtime;
}

/// Bound as Ctx callbacks.
pub const lua_call_bool = lua.callBool;
pub const lua_call_num = lua.callNum;
pub const lua_call_str = lua.callStr;
pub const LuaEnv = lua.Env;

test "a saved pick reaches the wildcard, the option and the offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    for ([_][]const u8{ "f/a.ttf", "f/b.ttf" }) |f| {
        const full = try std.fs.path.join(a, &.{ dir, f });
        try fs.mkdirs(std.testing.io, std.fs.path.dirname(full).?);
        try fs.write(std.testing.io, full, "");
    }
    const skin_json =
        \\{"type":0,"property":[{"name":"P","def":"on","item":[{"name":"on","op":901},{"name":"off","op":902}]}],
        \\"filepath":[{"name":"Font","path":"f/*.ttf","def":"a.ttf"}],
        \\"offset":[{"name":"O","id":40,"y":true}]}
    ;
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ dir, "play.json" }), skin_json);
    const got = try options(a, std.testing.io, dir, 0);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("on", got[0].def);
    try std.testing.expectEqual(@as(usize, 2), got[1].choices.len);
    try std.testing.expectEqual(@as(u3, 1), got[2].field);

    var conf: Conf = .{};
    try conf.property.map.put(a, "P", "off");
    try conf.file.map.put(a, "Font", "b.ttf");
    const again = try std.json.parseFromSliceLeaky(Conf, a, try std.json.Stringify.valueAlloc(a, conf, .{}), .{ .allocate = .alloc_always });
    const head = try jsonskin.parseFile(a, std.testing.io, try std.fs.path.join(a, &.{ dir, "play.json" }));
    try jsonskin.applyConf(a, head, again);
    try std.testing.expectEqualStrings("off", jsonskin.defaultItem(head.object.get("property").?.array.items[0]).?.get("name").?.string);
    const files = head.object.get("filepath").?.array.items;
    try std.testing.expectEqualStrings("f/b.ttf", try jsonskin.resolveWild(a, std.testing.io, dir, files, "f/*.ttf"));
}

test "only folders holding a skin are listed, in name order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    for ([_][]const u8{ "b/play7.luaskin", "A/inner/x.lr2skin", "empty/readme.txt" }) |f| {
        const full = try std.fs.path.join(a, &.{ dir, f });
        try fs.mkdirs(std.testing.io, std.fs.path.dirname(full).?);
        try fs.write(std.testing.io, full, "");
    }
    const got = try listSkins(a, std.testing.io, dir);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("A", got[0]);
    try std.testing.expectEqualStrings("b", got[1]);
}

test "a skin.ini stands for the 7, 6, 5 and 4 key screens only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const ini = try std.fs.path.join(a, &.{ dir, "skin.ini" });
    const io = std.testing.io;
    try fs.write(io, ini, "[Mania]\nKeys: 8\n");
    try std.testing.expectEqualStrings(ini, find(a, io, dir, playType(.beat7)).?);
    try std.testing.expectEqualStrings(ini, find(a, io, ini, playType(.beat5)).?);
    try std.testing.expectEqualStrings(ini, find(a, io, dir, playType(.beat4)).?);
    try std.testing.expectEqualStrings(ini, find(a, io, dir, playType(.beat6)).?);
    try std.testing.expect(find(a, io, dir, playType(.beat14)) == null);
    try std.testing.expect(find(a, io, dir, type_select) == null);
    const rows = try options(a, io, dir, playType(.beat7));
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expectEqualStrings(osuskin.bga_dim_name, rows[1].name);
    try std.testing.expectEqualStrings(osuskin.gauge_color_name, rows[2].name);
    try std.testing.expectEqualStrings(osuskin.scratch_side_name, rows[3].name);
}

test "each screen offers only its own file's options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const io = std.testing.io;
    try fs.write(io, try std.fs.path.join(a, &.{ dir, "play.json" }),
        \\{"type":0,"property":[{"name":"Play","def":"on","item":[{"name":"on","op":901},{"name":"off","op":902}]}]}
    );
    try fs.write(io, try std.fs.path.join(a, &.{ dir, "result.json" }), try std.fmt.allocPrint(a,
        \\{{"type":{d},"property":[{{"name":"Result","def":"on","item":[{{"name":"on","op":901}},{{"name":"off","op":902}}]}}]}}
    , .{type_result}));
    const play = try options(a, io, dir, 0);
    try std.testing.expectEqual(@as(usize, 1), play.len);
    try std.testing.expectEqualStrings("Play", play[0].name);
    const result = try options(a, io, dir, type_result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("Result", result[0].name);
}

test "a Lua header with a huge type has no type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const path = try std.fs.path.join(a, &.{ dir, "s.luaskin" });
    const io = std.testing.io;
    try fs.write(io, path, "return { type = 1 << 40 }");
    try std.testing.expectEqual(@as(?i32, null), typeOfFile(a, io, path));
    try fs.write(io, path, "return { type = 3 }");
    try std.testing.expectEqual(@as(?i32, 3), typeOfFile(a, io, path));
}

test "the built-in skin offers the scratch side for single play only" {
    const a = std.testing.allocator;
    try std.testing.expectEqualStrings(osuskin.scratch_side_name, (try options(a, std.testing.io, "", playType(.beat7)))[0].name);
    try std.testing.expectEqual(@as(usize, 1), (try options(a, std.testing.io, "", playType(.beat5))).len);
    try std.testing.expectEqual(@as(usize, 0), (try options(a, std.testing.io, "", playType(.beat14))).len);
    try std.testing.expectEqual(@as(usize, 0), (try options(a, std.testing.io, "", type_select)).len);
}
