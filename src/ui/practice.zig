//! Practice setup over song select: a section of the chart, its speed and judge, looped until left. Never recorded.
const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const gfx = @import("gfx.zig");
const i18n = @import("i18n.zig");
const tr = i18n.tr;
const config = @import("../game/config.zig");
const session_mod = @import("../game/session.zig");
const db_mod = @import("../db/db.zig");
const select = @import("select.zig");
const testing = @import("testing.zig");
const App = @import("app.zig").App;

const step_ms = 1000;
const row_count = 5;

pub const State = struct {
    open: bool = false,
    row: u8 = 0,
    sha256: [64]u8 = @splat(0),
    length_ms: i64 = 0,
    start_ms: i64 = 0,
    end_ms: i64 = 0,
    freq: u32 = 100,
    /// Percent; 0 keeps the chart's own.
    judgerank: i32 = 0,
};

/// Settings stay while the same chart is practised again.
pub fn open(a: *App, song: db_mod.Song) void {
    const p = &a.practice;
    const same = std.mem.eql(u8, &p.sha256, song.sha256);
    p.open = true;
    p.row = 0;
    if (same) return;
    p.* = .{ .open = true, .length_ms = @max(song.length_ms, 0), .end_ms = @max(song.length_ms, 0) };
    if (song.sha256.len == p.sha256.len) @memcpy(&p.sha256, song.sha256);
}

fn adjust(a: *App, dir: i32) void {
    const p = &a.practice;
    const d: i64 = dir;
    switch (p.row) {
        0 => p.start_ms = std.math.clamp(p.start_ms + d * step_ms, 0, @max(p.end_ms - step_ms, 0)),
        1 => p.end_ms = std.math.clamp(p.end_ms + d * step_ms, @min(p.start_ms + step_ms, p.length_ms), p.length_ms),
        2 => p.freq = @intCast(std.math.clamp(@as(i32, @intCast(p.freq)) + dir * 5, session_mod.Practice.min_freq, session_mod.Practice.max_freq)),
        3 => a.cfg.gauge = @intCast(@mod(@as(i32, a.cfg.gauge) + dir, config.gas + 1)),
        else => p.judgerank = std.math.clamp(p.judgerank + dir * 5, 0, 200),
    }
    a.sfx(.adjust);
}

pub fn params(p: *const State) session_mod.Practice {
    return .{ .start_us = p.start_ms * 1000, .end_us = p.end_ms * 1000, .freq = p.freq, .judgerank = p.judgerank };
}

pub fn key(a: *App, sc: u32) void {
    const p = &a.practice;
    switch (sc) {
        c.SDL_SCANCODE_ESCAPE => {
            p.open = false;
            a.sfx(.back);
        },
        c.SDL_SCANCODE_UP => p.row = (p.row + row_count - 1) % row_count,
        c.SDL_SCANCODE_DOWN => p.row = (p.row + 1) % row_count,
        c.SDL_SCANCODE_LEFT => adjust(a, -1),
        c.SDL_SCANCODE_RIGHT => adjust(a, 1),
        c.SDL_SCANCODE_RETURN => {
            p.open = false;
            select.startPractice(a, params(p));
        },
        else => {},
    }
}

fn clock(buf: []u8, ms: i64) []const u8 {
    const s = @divTrunc(ms, 1000);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ @divTrunc(s, 60), @mod(s, 60) }) catch "";
}

pub fn draw(a: *App) void {
    const p = &a.practice;
    if (!p.open) return;
    const g = &a.g;
    const u = g.h / 720;
    const w = 460 * u;
    const row_h = 40 * u;
    const h = 96 * u + row_h * row_count;
    const x = (g.w - w) / 2;
    const y = (g.h - h) / 2;
    g.rect(0, 0, g.w, g.h, gfx.bg.alpha(170));
    g.panel(x, y, w, h, "");
    _ = g.text(tr("PRACTICE"), x + 20 * u, y + 12 * u, g.scaled(24), gfx.white);
    var bufs: [row_count][32]u8 = undefined;
    const labels = [row_count][]const u8{ tr("START"), tr("END"), "FREQ", "GAUGE", "JUDGE" };
    const judge: []const u8 = if (p.judgerank == 0) tr("CHART") else std.fmt.bufPrint(&bufs[4], "{d}%", .{p.judgerank}) catch "";
    const values = [row_count][]const u8{
        clock(&bufs[0], p.start_ms),
        clock(&bufs[1], p.end_ms),
        std.fmt.bufPrint(&bufs[2], "{d}%", .{p.freq}) catch "",
        select.gauge_names[@min(a.cfg.gauge, config.gas)],
        judge,
    };
    for (labels, values, 0..) |label, value, i| {
        const ry = y + 56 * u + @as(f32, @floatFromInt(i)) * row_h;
        if (i == p.row) g.round(x + 10 * u, ry, w - 20 * u, row_h - 4 * u, 6 * u, gfx.accent);
        _ = g.text(label, x + 24 * u, ry + 8 * u, g.scaled(16), gfx.white);
        g.textRight(value, x + w - 24 * u, ry + 8 * u, g.scaled(16), gfx.white);
    }
    g.textCentered(tr("Left and right change a value. Enter starts."), x + w / 2, y + h - 30 * u, g.scaled(12), gfx.dim);
}

test "a section stays at least a second long and inside the chart" {
    const a = try testing.open();
    defer testing.close(a);
    a.practice = .{ .open = true, .length_ms = 10_000, .end_ms = 10_000 };
    for (0..30) |_| key(a, c.SDL_SCANCODE_RIGHT);
    try std.testing.expectEqual(@as(i64, 9000), a.practice.start_ms);
    a.practice.row = 1;
    for (0..30) |_| key(a, c.SDL_SCANCODE_LEFT);
    try std.testing.expectEqual(@as(i64, 10_000), a.practice.end_ms);
    a.practice.row = 2;
    for (0..100) |_| key(a, c.SDL_SCANCODE_LEFT);
    try std.testing.expectEqual(session_mod.Practice.min_freq, @as(i32, @intCast(a.practice.freq)));
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(!a.practice.open);
}
