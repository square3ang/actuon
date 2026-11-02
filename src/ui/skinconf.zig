//! The options a skin offers: choices, files and offsets. Saved per screen and key mode as they change;
//! play skins load at play start, so a change shows from the next play, and song select's on return.
const std = @import("std");
const c = @import("c");
const gfx = @import("gfx.zig");
const i18n = @import("i18n.zig");
const tr = i18n.tr;
const app_mod = @import("app.zig");
const settings = @import("settings.zig");
const skin_mod = @import("../skin/skin.zig");
const jsonskin = @import("../skin/jsonskin.zig");
const testing = @import("testing.zig");
const App = app_mod.App;
const Option = skin_mod.Option;

pub const State = struct {
    arena: ?std.heap.ArenaAllocator = null,
    rows: []const Option = &.{},
    conf: skin_mod.Conf = .{},
    cursor: usize = 0,
    first: usize = 0,
    /// The skin these options belong to, and where Esc goes.
    root: []const u8 = "",
    want: i32 = 0,
    back: app_mod.Scene = .settings,
};

pub fn open(a: *App, root_in: []const u8, want: i32, back: app_mod.Scene) void {
    close(a);
    var arena = std.heap.ArenaAllocator.init(a.gpa);
    const al = arena.allocator();
    const root = al.dupe(u8, root_in) catch return;
    const rows = skin_mod.options(al, root, want) catch &.{};
    if (rows.len == 0) {
        arena.deinit();
        return settings.say(a, "This skin has no settings.", .{});
    }
    a.skinconf = .{ .arena = arena, .rows = rows, .conf = skin_mod.loadConf(al, root, want), .root = root, .want = want, .back = back };
    a.scene = .skinconf;
}

pub fn close(a: *App) void {
    if (a.skinconf.arena) |*arena| arena.deinit();
    a.skinconf = .{};
}

fn pickMap(s: *State, kind: @TypeOf(@as(Option, undefined).kind)) *std.StringArrayHashMapUnmanaged([]const u8) {
    return if (kind == .property) &s.conf.property.map else &s.conf.file.map;
}

/// The picked name, or the skin's default. A pick the skin no longer offers counts as unset.
fn picked(s: *State, o: Option) []const u8 {
    const name = pickMap(s, o.kind).get(o.name) orelse o.def;
    for (o.choices) |ch| if (std.mem.eql(u8, ch, name)) return ch;
    return if (o.choices.len > 0) o.choices[0] else "";
}

fn change(a: *App, row: usize, dir: i32) void {
    const s = &a.skinconf;
    const o = s.rows[row];
    const al = s.arena.?.allocator();
    if (o.kind == .offset) {
        const gop = s.conf.offset.map.getOrPutValue(al, o.name, .{}) catch return;
        gop.value_ptr.axis(o.field).* += dir;
    } else {
        const now = picked(s, o);
        var at: i64 = 0;
        for (o.choices, 0..) |ch, i| {
            if (std.mem.eql(u8, ch, now)) at = @intCast(i);
        }
        const next: usize = @intCast(@mod(at + dir, @as(i64, @intCast(o.choices.len))));
        pickMap(s, o.kind).put(al, o.name, o.choices[next]) catch return;
    }
    a.sfx(.adjust);
    skin_mod.saveConf(al, s.root, s.want, s.conf);
    a.select_skin_loaded = false;
}

pub fn key(a: *App, sc: c.SDL_Scancode) void {
    const s = &a.skinconf;
    switch (sc) {
        c.SDL_SCANCODE_UP => {
            a.sfx(.move);
            s.cursor = if (s.cursor == 0) s.rows.len - 1 else s.cursor - 1;
        },
        c.SDL_SCANCODE_DOWN => {
            a.sfx(.move);
            s.cursor = (s.cursor + 1) % s.rows.len;
        },
        c.SDL_SCANCODE_LEFT => change(a, s.cursor, -1),
        c.SDL_SCANCODE_RIGHT, c.SDL_SCANCODE_RETURN => change(a, s.cursor, 1),
        c.SDL_SCANCODE_ESCAPE => {
            a.sfx(.back);
            const back = s.back;
            close(a);
            a.scene = back;
        },
        else => {},
    }
}

pub fn draw(a: *App) void {
    const g = &a.g;
    const s = &a.skinconf;
    const u = g.h / 720;
    if (s.arena == null) {
        a.scene = .settings;
        return;
    }
    _ = g.text(tr("Skin settings"), 22 * u, 18 * u, g.scaled(32), gfx.white);
    g.textRight(if (s.root.len == 0) tr("Built-in") else std.fs.path.basename(s.root), g.w - 22 * u, 28 * u, g.scaled(16), gfx.dim);

    const top = 76 * u;
    const help_y = g.h - 44 * u;
    const row_h = 44 * u;
    const fit: usize = @max(@as(usize, @intFromFloat((help_y - top) / row_h)), 1);
    s.first = @max(@min(s.first, s.cursor), (s.cursor + 1) -| fit);
    const rx = 14 * u;
    const rw = g.w - 28 * u;
    const value_w = 340 * u;
    const right = rx + rw - 14 * u;
    for (s.rows[s.first..@min(s.first + fit, s.rows.len)], s.first..) |o, i| {
        const y = top + @as(f32, @floatFromInt(i - s.first)) * row_h;
        const rh = row_h - 4 * u;
        const on = i == s.cursor;
        if (on) {
            g.round(rx, y, rw, rh, 8 * u, gfx.accent);
        } else if (g.hit(rx, y, rw, rh)) g.round(rx, y, rw, rh, 8 * u, gfx.rule);
        const ty = y + (rh - 22 * u) / 2;
        var buf: [32]u8 = undefined;
        var label_buf: [512]u8 = undefined;
        const label = if (o.kind == .offset)
            std.fmt.bufPrint(&label_buf, "{s}: {s}", .{ o.name, jsonskin.Offset.axes[o.field] }) catch o.name
        else
            o.name;
        g.textClip(label, rx + 12 * u, ty, rw - value_w - 40 * u, g.scaled(16), gfx.white);
        const value = if (o.kind == .offset) blk: {
            var v = s.conf.offset.map.get(o.name) orelse jsonskin.Offset{};
            break :blk std.fmt.bufPrint(&buf, "{d}", .{v.axis(o.field).*}) catch "";
        } else picked(s, o);
        const w = @min(g.measure(value, g.scaled(16)), value_w - 60 * u);
        const col = if (on) gfx.white else gfx.dim;
        g.textRight(">", right, ty, g.scaled(16), col);
        g.textClip(value, right - 30 * u - w, ty, w, g.scaled(16), gfx.white);
        const left_x = right - 44 * u - w;
        g.textRight("<", left_x, ty, g.scaled(16), col);
        const box = 36 * u;
        if (g.clickIn(left_x - box + 8 * u, y, box, rh)) {
            s.cursor = i;
            change(a, i, -1);
        } else if (g.clickIn(right - box + 8 * u, y, box, rh)) {
            s.cursor = i;
            change(a, i, 1);
        } else if (g.clickIn(rx, y, rw, rh)) {
            a.sfx(.move);
            s.cursor = i;
        }
    }
    _ = g.text(tr("Left/Right changes the value. Changes show on song select and from the next play. Esc goes back."), 22 * u, help_y + 10 * u, g.scaled(14), gfx.dim);
}

test "the cursor wraps and escape returns where it came from" {
    const a = try testing.open();
    defer testing.close(a);
    const rows = [_]Option{ undefined, undefined, undefined };
    a.skinconf = .{ .rows = &rows, .back = .skinslots };
    a.scene = .skinconf;
    key(a, c.SDL_SCANCODE_UP);
    try std.testing.expectEqual(@as(usize, 2), a.skinconf.cursor);
    key(a, c.SDL_SCANCODE_DOWN);
    try std.testing.expectEqual(@as(usize, 0), a.skinconf.cursor);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expectEqual(.skinslots, a.scene);
    try std.testing.expectEqual(@as(usize, 0), a.skinconf.rows.len);
}
