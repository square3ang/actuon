const std = @import("std");
const c = @import("c");
const gfx = @import("gfx.zig");
const App = @import("app.zig").App;

pub const Drop = struct {
    open: bool = false,
    labels: []const []const u8 = &.{},
    cursor: usize = 0,
    first: usize = 0,
    w: f32 = 0,
    /// The row sets this through `anchor` each time it draws.
    y: f32 = 0,
    h: f32 = 0,
    right: f32 = 0,

    pub fn show(d: *Drop, g: *gfx.Gfx, labels: []const []const u8, cursor: usize) void {
        const u = g.h / 720;
        d.w = 160 * u;
        for (labels) |l| d.w = @max(d.w, g.measure(l, g.scaled(16)) + 24 * u);
        d.labels = labels;
        d.cursor = cursor;
        d.first = 0;
        d.open = true;
    }

    pub fn anchor(d: *Drop, y: f32, h: f32, right: f32) void {
        d.y = y;
        d.h = h;
        d.right = right;
    }

    pub fn key(d: *Drop, a: *App, sc: u32) ?usize {
        switch (sc) {
            c.SDL_SCANCODE_UP => if (d.cursor > 0) {
                a.sfx(.move);
                d.cursor -= 1;
            },
            c.SDL_SCANCODE_DOWN => if (d.cursor + 1 < d.labels.len) {
                a.sfx(.move);
                d.cursor += 1;
            },
            c.SDL_SCANCODE_RETURN => {
                a.sfx(.adjust);
                d.open = false;
                return d.cursor;
            },
            c.SDL_SCANCODE_ESCAPE => {
                a.sfx(.back);
                d.open = false;
            },
            else => {},
        }
        return null;
    }

    /// Draw last, over the rest. `click` was held back from the rows beneath.
    pub fn draw(d: *Drop, a: *App, click: bool) ?usize {
        const g = &a.g;
        const u = g.h / 720;
        const row = 30 * u;
        const shown = @min(d.labels.len, 10);
        if (d.cursor < d.first) d.first = d.cursor;
        if (d.cursor >= d.first + shown) d.first = d.cursor + 1 - shown;
        const w = @min(d.w, d.right - 8 * u);
        const h = row * @as(f32, @floatFromInt(shown)) + 8 * u;
        const x = d.right - w;
        const below = d.y + d.h;
        const top = if (below + h <= g.h - 8 * u) below else @max(8 * u, d.y - h);
        g.round(x - 1, top - 1, w + 2, h + 2, 8 * u, gfx.rule);
        g.round(x, top, w, h, 8 * u, gfx.well);
        var chosen: ?usize = null;
        for (d.first..d.first + shown) |i| {
            const ry = top + 4 * u + row * @as(f32, @floatFromInt(i - d.first));
            const hover = g.hit(x, ry, w, row);
            if (i == d.cursor) g.round(x + 4 * u, ry, w - 8 * u, row, 6 * u, gfx.accent) else if (hover) g.round(x + 4 * u, ry, w - 8 * u, row, 6 * u, gfx.rule);
            g.textClip(d.labels[i], x + 12 * u, ry + 4 * u, w - 24 * u, g.scaled(16), gfx.white);
            if (click and hover) chosen = i;
        }
        if (click) d.open = false;
        if (chosen != null) a.sfx(.adjust);
        return chosen;
    }
};
