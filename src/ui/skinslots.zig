const std = @import("std");
const c = @import("c");
const gfx = @import("gfx.zig");
const i18n = @import("i18n.zig");
const tr = i18n.tr;
const app_mod = @import("app.zig");
const config = @import("../game/config.zig");
const skinconf = @import("skinconf.zig");
const skin_mod = @import("../skin/skin.zig");
const Drop = @import("dropdown.zig").Drop;
const App = app_mod.App;
const Slot = config.SkinSlot;

const slots = std.enums.values(Slot);

pub const State = struct {
    arena: ?std.heap.ArenaAllocator = null,
    /// `""` (the default) and "builtin" come ahead of these.
    choices: [slots.len][]const []const u8 = @splat(&.{}),
    cursor: usize = 0,
    drop: Drop = .{},
};

fn slotName(slot: Slot) []const u8 {
    return switch (slot) {
        .select => tr("Song select"),
        .decide => tr("Decide"),
        .result => tr("Result"),
        .beat7 => tr("Play 7 keys"),
        .beat5 => tr("Play 5 keys"),
        .beat14 => tr("Play 14 keys"),
        .beat10 => tr("Play 10 keys"),
        .popn9 => tr("Play 9 buttons"),
        .beat4 => tr("Play 4 keys"),
        .beat6 => tr("Play 6 keys"),
    };
}

/// shortcut: Lua headers run on the main thread as this opens; a thread if skin folders grow large.
pub fn open(a: *App) void {
    close(a);
    var arena = std.heap.ArenaAllocator.init(a.gpa);
    const al = arena.allocator();
    const files = skin_mod.allFiles(al) catch &.{};
    a.skinslots = .{};
    for (slots, &a.skinslots.choices) |slot, *out| {
        var list: std.ArrayList([]const u8) = .empty;
        for (files) |f| if (f.type == skin_mod.slotType(slot)) list.append(al, f.path) catch {};
        out.* = list.items;
    }
    a.skinslots.arena = arena;
    a.scene = .skinslots;
}

pub fn close(a: *App) void {
    if (a.skinslots.arena) |*arena| arena.deinit();
    a.skinslots = .{};
}

pub fn cycled(now: []const u8, files: []const []const u8, dir: i32) []const u8 {
    var at: i64 = 0;
    if (std.mem.eql(u8, now, config.builtin_skin)) at = 1;
    for (files, 2..) |f, i| {
        if (std.mem.eql(u8, f, now)) at = @intCast(i);
    }
    const next = @mod(at + dir, @as(i64, @intCast(files.len + 2)));
    return switch (next) {
        0 => "",
        1 => config.builtin_skin,
        else => files[@intCast(next - 2)],
    };
}

/// Same order as `cycled`.
fn openDrop(a: *App) void {
    const s = &a.skinslots;
    const al = (s.arena orelse return).allocator();
    const files = s.choices[s.cursor];
    const now = a.cfg.skins.get(slots[s.cursor]);
    const labels = al.alloc([]const u8, files.len + 2) catch return;
    var buf: [1024]u8 = undefined;
    labels[0] = al.dupe(u8, i18n.bufPrint(&buf, "Default ({s})", .{defaultName(a)}) catch return) catch return;
    labels[1] = tr("Built-in");
    var cursor: usize = if (std.mem.eql(u8, now, config.builtin_skin)) 1 else 0;
    for (files, 2..) |f, i| {
        labels[i] = al.dupe(u8, shown(&buf, f)) catch return;
        if (std.mem.eql(u8, f, now)) cursor = i;
    }
    s.drop.show(&a.g, labels, cursor);
}

fn choose(a: *App, i: usize) void {
    const s = &a.skinslots;
    const files = s.choices[s.cursor];
    const next = switch (i) {
        0 => "",
        1 => config.builtin_skin,
        else => files[i - 2],
    };
    a.cfg.skins.set(slots[s.cursor], a.arena.allocator().dupe(u8, next) catch return);
    a.saveConfig();
}

fn openOptions(a: *App) void {
    const slot = slots[a.skinslots.cursor];
    a.sfx(.confirm);
    skinconf.open(a, a.cfg.skinFor(slot), skin_mod.slotType(slot), .skinslots);
}

fn change(a: *App, dir: i32) void {
    const s = &a.skinslots;
    const slot = slots[s.cursor];
    const next = cycled(a.cfg.skins.get(slot), s.choices[s.cursor], dir);
    a.cfg.skins.set(slot, a.arena.allocator().dupe(u8, next) catch return);
    a.sfx(.adjust);
    a.saveConfig();
}

pub fn key(a: *App, sc: c.SDL_Scancode) void {
    const s = &a.skinslots;
    if (s.drop.open) {
        if (s.drop.key(a, sc)) |i| choose(a, i);
        return;
    }
    switch (sc) {
        c.SDL_SCANCODE_UP => {
            a.sfx(.move);
            s.cursor = if (s.cursor == 0) slots.len - 1 else s.cursor - 1;
        },
        c.SDL_SCANCODE_DOWN => {
            a.sfx(.move);
            s.cursor = (s.cursor + 1) % slots.len;
        },
        c.SDL_SCANCODE_LEFT => change(a, -1),
        c.SDL_SCANCODE_RIGHT => change(a, 1),
        c.SDL_SCANCODE_RETURN => {
            a.sfx(.confirm);
            openDrop(a);
        },
        c.SDL_SCANCODE_O => openOptions(a),
        c.SDL_SCANCODE_ESCAPE => {
            a.sfx(.back);
            close(a);
            a.scene = .settings;
        },
        else => {},
    }
}

fn shown(buf: []u8, path: []const u8) []const u8 {
    const dir = std.fs.path.basename(std.fs.path.dirname(path) orelse "");
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, std.fs.path.basename(path) }) catch std.fs.path.basename(path);
}

fn defaultName(a: *const App) []const u8 {
    return if (a.cfg.skin.len > 0) std.fs.path.basename(a.cfg.skin) else tr("Built-in");
}

pub fn draw(a: *App) void {
    const g = &a.g;
    const s = &a.skinslots;
    const u = g.h / 720;
    if (s.arena == null) {
        a.scene = .settings;
        return;
    }
    const drop_click = s.drop.open and g.clicked;
    if (drop_click) g.clicked = false;
    _ = g.text(tr("Skins per screen"), 22 * u, 18 * u, g.scaled(32), gfx.white);
    const top = 76 * u;
    const row_h = 44 * u;
    const rx = 14 * u;
    const rw = g.w - 28 * u;
    const options_w = 84 * u;
    const right = rx + rw - 14 * u - options_w - 12 * u;
    var buf: [1024]u8 = undefined;
    for (slots, 0..) |slot, i| {
        const y = top + @as(f32, @floatFromInt(i)) * row_h;
        const rh = row_h - 4 * u;
        const on = i == s.cursor;
        if (on) {
            g.round(rx, y, rw, rh, 8 * u, gfx.accent);
        } else if (g.hit(rx, y, rw, rh)) g.round(rx, y, rw, rh, 8 * u, gfx.rule);
        const ox = rx + rw - 8 * u - options_w;
        g.round(ox, y + 6 * u, options_w, rh - 12 * u, 6 * u, if (g.hit(ox, y, options_w, rh)) gfx.rule else gfx.well);
        g.textCentered(tr("Options"), ox + options_w / 2, y + (rh - 18 * u) / 2, g.scaled(13), gfx.white);
        if (g.clickIn(ox, y, options_w, rh)) {
            s.cursor = i;
            openOptions(a);
        }
        if (g.clickIn(rx, y, rw, rh)) {
            if (on) a.click_key = c.SDL_SCANCODE_RETURN else s.cursor = i;
        }
        const ty = y + (rh - 22 * u) / 2;
        _ = g.text(slotName(slot), rx + 12 * u, ty, g.scaled(16), gfx.white);
        const v = a.cfg.skins.get(slot);
        const value = if (v.len == 0)
            i18n.bufPrint(&buf, "Default ({s})", .{defaultName(a)}) catch tr("Default")
        else if (std.mem.eql(u8, v, config.builtin_skin)) tr("Built-in") else shown(&buf, v);
        g.textRight(value, right - 24 * u, ty, g.scaled(16), if (on) gfx.white else gfx.dim);
        g.textRight("v", right, ty, g.scaled(16), if (on) gfx.white else gfx.dim);
        if (s.drop.open and on) s.drop.anchor(y, rh, right);
    }
    const help_y = g.h - 44 * u;
    _ = g.text(tr("Enter or click: pick a skin   Left/Right: step   O: its options   Esc: back"), 22 * u, help_y, g.scaled(14), gfx.dim);
    if (s.drop.open) {
        if (s.drop.draw(a, drop_click)) |i| choose(a, i);
    }
}

test "cycling passes default, built-in and each file, and wraps" {
    const files = [_][]const u8{ "a", "b" };
    try std.testing.expectEqualStrings(config.builtin_skin, cycled("", &files, 1));
    try std.testing.expectEqualStrings("a", cycled(config.builtin_skin, &files, 1));
    try std.testing.expectEqualStrings("", cycled("b", &files, 1));
    try std.testing.expectEqualStrings("b", cycled("", &files, -1));
}
