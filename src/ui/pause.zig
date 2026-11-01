//! Pause overlay: "PAUSED" slides in from the left, the menu from the right. Resuming plays it
//! backwards and counts down, so the chart does not restart under the player's hands.
const std = @import("std");
const c = @import("c");
const gfx = @import("gfx.zig");
const i18n = @import("i18n.zig");
const tr = i18n.tr;
const testing = @import("testing.zig");
const App = @import("app.zig").App;

const slide_ms: f32 = 280;
const stagger_ms: f32 = 45;
const count_ms: u64 = 3000;

const Action = enum { resume_play, retry, quit };

pub const State = struct {
    open: bool = false,
    opened_at: u64 = 0,
    closing_at: ?u64 = null,
    sel: u8 = 0,
    last_mx: f32 = -1,
    last_my: f32 = -1,
};

/// Fast start, soft landing.
fn easeOut(x: f32) f32 {
    const k = 1 - std.math.clamp(x, 0, 1);
    return 1 - k * k * k;
}

pub fn open(a: *App) void {
    a.pause = .{ .open = true, .opened_at = c.SDL_GetTicks(), .last_mx = a.g.mx, .last_my = a.g.my };
    a.session.?.setPaused(true);
    a.sfx(.back);
}

fn startClosing(a: *App) void {
    a.pause.closing_at = c.SDL_GetTicks();
}

/// Items a course cannot do are left out: a retry would lose the stages before this one.
fn itemCount(a: *const App) u8 {
    return if (a.course != null) 2 else 3;
}

fn actionOf(a: *const App, i: u8) Action {
    return if (a.course != null and i == 1) .quit else @fromBackingInt(@intCast(i));
}

fn activate(a: *App, act: Action) void {
    a.sfx(if (act == .quit) .back else .confirm);
    switch (act) {
        .resume_play => startClosing(a),
        .retry => a.retryPlay(),
        .quit => {
            const s = a.session.?;
            a.finishPlay(s.snapshot(), false);
        },
    }
}

pub fn key(a: *App, sc: u32) void {
    const p = &a.pause;
    if (p.closing_at != null) {
        // Change of mind during the countdown: straight back to the menu.
        if (sc == c.SDL_SCANCODE_ESCAPE) {
            p.closing_at = null;
            p.opened_at = c.SDL_GetTicks();
            a.sfx(.back);
        }
        return;
    }
    const n = itemCount(a);
    switch (sc) {
        c.SDL_SCANCODE_ESCAPE => {
            a.sfx(.back);
            startClosing(a);
        },
        c.SDL_SCANCODE_UP => {
            p.sel = (p.sel + n - 1) % n;
            a.sfx(.move);
        },
        c.SDL_SCANCODE_DOWN => {
            p.sel = (p.sel + 1) % n;
            a.sfx(.move);
        },
        c.SDL_SCANCODE_RETURN, c.SDL_SCANCODE_SPACE => activate(a, actionOf(a, p.sel)),
        else => {},
    }
}

/// Draws over the play scene. The session may be gone afterwards, when a menu click ended it.
pub fn tick(a: *App) void {
    const p = &a.pause;
    const g = &a.g;
    const now = c.SDL_GetTicks();
    const u = g.h / 720;
    const since: f32 = @floatFromInt(now - p.opened_at);
    const closed: f32 = if (p.closing_at) |at| @floatFromInt(now - at) else 0;
    const k = if (p.closing_at != null) 1 - easeOut(closed / slide_ms) else easeOut(since / slide_ms);

    g.rect(0, 0, g.w, g.h, gfx.well.alpha(@intFromFloat(190 * k)));

    // Left: the word, entering from off screen.
    const word_w = 520 * u;
    _ = g.text(tr("PAUSED"), 72 * u - word_w * (1 - k), g.h * 0.5 - 62 * u, g.scaled(96), gfx.white);
    if (a.record) _ = g.text(tr("Resuming will leave this play unrecorded"), 76 * u - word_w * (1 - k), g.h * 0.5 + 56 * u, g.scaled(20), gfx.amber);

    // Right: the menu on a band of its own, each row landing just after the one above.
    const band_w = 380 * u;
    const row_h = 64 * u;
    const n = itemCount(a);
    const top = g.h * 0.5 - row_h * @as(f32, @floatFromInt(n)) / 2;
    g.rect(g.w - band_w * k, 0, band_w, g.h, gfx.plate.alpha(235));
    var clicked: ?u8 = null;
    // Measured from where the mouse last counted, so sensor jitter never adds up to a move.
    const moved = @abs(g.mx - p.last_mx) + @abs(g.my - p.last_my) > 8 * u;
    if (moved) {
        p.last_mx = g.mx;
        p.last_my = g.my;
    }
    for (0..n) |i| {
        const idx: u8 = @intCast(i);
        const delay = stagger_ms * @as(f32, @floatFromInt(i));
        const row_k = if (p.closing_at != null) k else easeOut((since - delay) / slide_ms);
        const x = g.w - band_w * row_k;
        const y = top + row_h * @as(f32, @floatFromInt(i));
        if (p.closing_at == null and g.hit(x, y, band_w, row_h)) {
            // Only a moving mouse takes the selection, so a resting one cannot fight the keyboard.
            if (moved and p.sel != idx) {
                p.sel = idx;
                a.sfx(.move);
            }
            if (g.clickIn(x, y, band_w, row_h)) clicked = idx;
        }
        const on = p.sel == idx;
        if (on) {
            g.rect(x, y, band_w, row_h, gfx.slab);
            g.rect(x, y, 5 * u, row_h, gfx.cyan);
        }
        const labels = [_][]const u8{ tr("RESUME"), tr("RETRY"), tr("QUIT") };
        _ = g.text(labels[@backingInt(actionOf(a, idx))], x + 36 * u, y + 16 * u, g.scaled(28), if (on) gfx.white else gfx.dim);
    }

    if (p.closing_at) |at| {
        const left = count_ms -| (now - at);
        if (left == 0) {
            a.session.?.setPaused(false);
            p.open = false;
            return;
        }
        var buf: [4]u8 = undefined;
        const digit = std.fmt.bufPrint(&buf, "{d}", .{left * 3 / count_ms + 1}) catch "";
        // Each number lands big and settles early in its second.
        const slot = count_ms / 3;
        const age: f32 = @floatFromInt(slot - @min(left % slot, slot));
        const scale = 1 + 0.7 * (1 - easeOut(age / 350));
        g.textPop(digit, g.w / 2, g.h * 0.5 - 48 * u, g.scaled(96), gfx.white, scale);
    }
    if (clicked) |i| activate(a, actionOf(a, i));
}

test "the menu eases to rest" {
    try std.testing.expectEqual(@as(f32, 0), easeOut(0));
    try std.testing.expectEqual(@as(f32, 1), easeOut(2));
    try std.testing.expect(easeOut(0.5) > 0.5);
}

test "the menu wraps, and a course has no retry" {
    const a = try testing.open();
    defer testing.close(a);
    key(a, c.SDL_SCANCODE_UP);
    try std.testing.expectEqual(@as(u8, 2), a.pause.sel);
    key(a, c.SDL_SCANCODE_DOWN);
    try std.testing.expectEqual(@as(u8, 0), a.pause.sel);
    try std.testing.expectEqual(Action.retry, actionOf(a, 1));
    // An undefined payload, not an undefined optional: that one reads as null on arm64.
    a.course = @as(@typeInfo(@TypeOf(a.course)).optional.child, undefined);
    defer a.course = null;
    key(a, c.SDL_SCANCODE_UP);
    try std.testing.expectEqual(@as(u8, 1), a.pause.sel);
    try std.testing.expectEqual(Action.quit, actionOf(a, 1));
}

test "escape counts down to resume, and again goes back to the menu" {
    const a = try testing.open();
    defer testing.close(a);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(a.pause.closing_at != null);
    key(a, c.SDL_SCANCODE_DOWN);
    try std.testing.expectEqual(@as(u8, 0), a.pause.sel);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(a.pause.closing_at == null);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expect(a.pause.closing_at != null);
}
