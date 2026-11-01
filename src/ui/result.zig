//! Result screen; also records the score and the replay.
const std = @import("std");
const select = @import("select.zig");
const c = @import("c");
const core = @import("actuon_core");
const gfx = @import("gfx.zig");
const app_mod = @import("app.zig");
const play = @import("play.zig");
const db_mod = @import("../db/db.zig");
const skin_scene = @import("../skin/scene.zig");
const ir = @import("../net/ir.zig");
const session_mod = @import("../game/session.zig");
const testing = @import("testing.zig");
const App = app_mod.App;

pub const clear_names = [_][]const u8{ "NO PLAY", "FAILED", "ASSIST EASY", "LIGHT ASSIST", "EASY", "NORMAL", "HARD", "EX HARD", "FULL COMBO", "PERFECT", "MAX" };

pub const State = struct {
    title_buf: [256]u8 = undefined,
    title: []const u8 = "",
    snap: session_mod.Snapshot = .{},
    clear: core.types.Clear = .failed,
    notes: u32 = 0,
    prev_ex: u32 = 0,
    prev_clear: u8 = 0,
    saved: bool = false,
    /// The skin reloads over the real result once, since its load picks and plays the voice.
    skin_fresh: bool = false,
    /// The clear or fail sound, cut when the screen is left; it can be a whole song.
    music_slot: ?u8 = null,
    recorded: bool = false,
    ln_unranked: bool = false,
    shown_at: u64 = 0,
    /// When a key started the skin's fade out; the screen ends with it.
    leave_at: u64 = 0,
    ir_used: bool = false,
    paused: bool = false,
    board: ?*ir.Board = null,
};

pub fn dropBoard(a: *App) void {
    if (a.res.board) |b| b.release();
    a.res.board = null;
    a.skin_state.ir_board = null;
}

pub fn capture(a: *App, s: *session_mod.Session, snap: session_mod.Snapshot, natural: bool) void {
    const r = &a.res;
    const n = @min(s.chart.title.len, r.title_buf.len);
    @memcpy(r.title_buf[0..n], s.chart.title[0..n]);
    r.title = r.title_buf[0..n];
    r.snap = snap;
    r.notes = s.chart.total_notes;
    const finished = natural and !snap.failed;
    r.clear = s.sim.clear(finished);
    r.recorded = false;
    r.ln_unranked = false;
    r.saved = false;
    r.ir_used = false;
    dropBoard(a);
    select.dropBoard(a);
    r.paused = s.was_paused;
    r.shown_at = c.SDL_GetTicks();
    r.leave_at = 0;
    r.skin_fresh = false;
    r.music_slot = a.sfx_slot;
    a.sfx(if (r.clear == .failed) .fail else .clear);
    if (!a.record or s.was_paused) return;

    const look = a.db.prepare("SELECT ex, clear FROM score WHERE sha256=?1") catch return;
    defer look.deinit();
    look.bindText(1, &s.chart.sha256);
    r.prev_ex = 0;
    r.prev_clear = 0;
    if (look.step() catch false) {
        r.prev_ex = @intCast(look.int(0));
        r.prev_clear = @intCast(look.int(1));
    }
    const sc = &snap.score;
    const cleared = @backingInt(r.clear) >= @backingInt(core.types.Clear.easy) or r.clear == .assist_easy or r.clear == .light_assist_easy;
    var counts: [6]u32 = undefined;
    for (&counts, sc.counts) |*d, v| d.* = v[0] + v[1];
    const date = wallClock();
    // shortcut: scores keep one row per chart, so CN and HCN plays are not saved, add a mode column to rank them.
    r.ln_unranked = s.params.ln_mode != .ln;
    if (r.ln_unranked) {} else if (db_mod.recordScore(a.db, .{
        .sha256 = &s.chart.sha256,
        .clear = @backingInt(r.clear),
        .ex = sc.exScore(),
        .counts = counts,
        .max_combo = sc.max_combo,
        .miss = sc.missCount() + (s.chart.total_notes -| sc.passed),
        .cleared = @intFromBool(cleared),
        .date = date,
    })) |_| {
        r.recorded = true;
    } else |e| std.log.err("score save failed: {t}", .{e});

    const bytes = s.replayBytes() catch return;
    defer s.gpa.free(bytes);
    const ins = a.db.prepare("INSERT INTO replay(sha256,date,ex,clear,data) VALUES(?1,?2,?3,?4,?5)") catch return;
    defer ins.deinit();
    ins.bindText(1, &s.chart.sha256);
    ins.bindInt(2, date);
    ins.bindInt(3, sc.exScore());
    ins.bindInt(4, @backingInt(r.clear));
    ins.bindBlob(5, bytes);
    _ = ins.step() catch return;
    r.saved = true;
    if (!r.ln_unranked and a.cfg.ir_url.len > 0 and a.cfg.ir_token.len > 0) r.board = ir.startUpload(a.gpa, a.cfg.ir_url, a.cfg.ir_token, &s.chart.sha256, s.params.path, bytes);
    r.ir_used = r.board != null;
}

fn wallClock() i64 {
    var ms: c.SDL_Time = 0;
    if (!c.SDL_GetCurrentTime(&ms)) return 0;
    return @divTrunc(ms, std.time.ns_per_s);
}

pub fn rankOf(ex: u32, notes: u32) []const u8 {
    if (notes == 0) return "F";
    const rate = @as(f64, @floatFromInt(ex)) / @as(f64, @floatFromInt(notes * 2));
    const steps = [_]struct { f64, []const u8 }{ .{ 8.0 / 9.0, "AAA" }, .{ 7.0 / 9.0, "AA" }, .{ 6.0 / 9.0, "A" }, .{ 5.0 / 9.0, "B" }, .{ 4.0 / 9.0, "C" }, .{ 3.0 / 9.0, "D" }, .{ 2.0 / 9.0, "E" } };
    for (steps) |st| if (rate >= st[0]) return st[1];
    return "F";
}

fn irLabel(r: *const State, buf: []u8) []const u8 {
    const b = r.board orelse return "";
    return switch (b.state.load(.acquire)) {
        ir.Board.pending => "IR: uploading...",
        ir.Board.accepted => b.placeText(buf),
        else => "IR: upload failed",
    };
}

fn drawSkinned(a: *App, sk: *@import("../skin/model.zig").Skin) void {
    const g = &a.g;
    const r = &a.res;
    const st = &a.skin_state;
    st.snap = r.snap;
    st.clear = r.clear;
    st.show_clear = true;
    st.best_ex = r.prev_ex;
    st.best_clear = r.prev_clear;
    st.ir_board = r.board;
    if (!r.skin_fresh) {
        r.skin_fresh = true;
        // What play left in the timers would fire here, its fade out above all.
        st.timers = @splat(-1);
        a.reloadResultSkin();
        // The skin's clock starts now, so a slow load doesn't eat its opening.
        r.shown_at = c.SDL_GetTicks();
    }
    const skin = a.result_skin orelse sk;
    const now = c.SDL_GetTicks();
    const shown: i64 = @intCast(now - r.shown_at);
    st.timers[1] = if (shown >= skin.input_ms) skin.input_ms else -1;
    if (r.board) |b| {
        if (st.timers[172] < 0) st.timers[172] = shown;
        const done: usize = switch (b.state.load(.acquire)) {
            ir.Board.pending => 0,
            ir.Board.accepted => 173,
            else => 174,
        };
        if (done != 0 and st.timers[done] < 0) st.timers[done] = shown;
    }
    skin_scene.drawStatic(g, skin, st, shown);
    // Skins have nowhere to put this, so it goes on top, in a corner they rarely fill.
    if (r.ir_used) {
        const u = g.h / 720;
        const size = g.scaled(14);
        var place: [64]u8 = undefined;
        const label = irLabel(r, &place);
        const w = g.measure(label, size) + 24 * u;
        g.panel(g.w - w - 12 * u, g.h - 44 * u, w, 32 * u, "");
        g.textRight(label, g.w - 24 * u, g.h - 37 * u, size, gfx.sky);
    }
    if (r.leave_at != 0 and now - r.leave_at >= @as(u64, @intCast(std.math.clamp(skin.fadeout_ms, 0, 5000)))) a.scene = .select;
}

/// The title, the clear banner, which slides in, and the rank.
fn drawHeadline(a: *App, ease: f32, ex: u32) void {
    const g = &a.g;
    const r = &a.res;
    const u = g.h / 720;
    const failed = r.clear == .failed;
    const rcx = g.w * 0.24;
    const rcy = 300 * u;
    g.textClip(r.title, 34 * u, 18 * u, g.w * 0.8, g.scaled(24), gfx.white);
    const banner_w = 360 * u;
    const bx = -banner_w + (banner_w + 30 * u) * ease;
    g.round(bx, 66 * u, banner_w, 52 * u, 10 * u, if (failed) gfx.danger else gfx.accent);
    _ = g.text(clear_names[@backingInt(r.clear)], bx + 44 * u, 72 * u, g.scaled(32), gfx.white);

    const pop = 1.6 - 0.6 * ease;
    g.textPop(rankOf(ex, r.notes), rcx, rcy - 86 * u, g.scaled(144), gfx.white, pop);
}

/// EX counts up while the banner lands.
fn drawExPanel(a: *App, ease: f32, ex: u32) void {
    const g = &a.g;
    const r = &a.res;
    const u = g.h / 720;
    const rate = if (r.notes == 0) 0.0 else @as(f64, @floatFromInt(ex)) * 50.0 / @as(f64, @floatFromInt(r.notes));
    g.panel(30 * u, 500 * u, g.w * 0.48 - 44 * u, 110 * u, "EX SCORE");
    const shown_ex: u64 = @intFromFloat(@as(f32, @floatFromInt(ex)) * ease);
    g.digits(g.w * 0.48 - 30 * u, 527 * u, g.scaled(48), 5, shown_ex, gfx.white);
    g.fmt(44 * u, 536 * u, g.scaled(24), gfx.cyan, "{d:.2}%", .{rate});
    if (r.recorded) {
        const delta = @as(i64, ex) - @as(i64, r.prev_ex);
        const mag: u64 = @intCast(if (delta >= 0) delta else -delta);
        g.fmt(44 * u, 574 * u, g.scaled(14), if (delta >= 0) gfx.cyan else gfx.dim, "BEST {d}  {s}{d}", .{ r.prev_ex, if (delta >= 0) "+" else "-", mag });
    } else if (r.paused) {
        _ = g.text("NOT RECORDED: PAUSED", 44 * u, 574 * u, g.scaled(14), gfx.amber);
    } else if (r.ln_unranked) {
        _ = g.text("NOT RECORDED: LN MODE", 44 * u, 574 * u, g.scaled(14), gfx.amber);
    } else _ = g.text("NOT RECORDED", 44 * u, 574 * u, g.scaled(14), gfx.dim);
    const lamp_y = 622 * u;
    if (r.recorded or r.ir_used) g.panel(30 * u, lamp_y, g.w * 0.48 - 44 * u, 48 * u, "");
    if (r.recorded) g.fmt(44 * u, lamp_y + 14 * u, g.scaled(14), gfx.dim, "BEST LAMP  {s}", .{clear_names[r.prev_clear]});
    var place: [64]u8 = undefined;
    if (r.ir_used) g.textRight(irLabel(r, &place), g.w * 0.48 - 30 * u, lamp_y + 14 * u, g.scaled(14), gfx.sky);
}

/// Judges slide in from the right, one after another. Stats and the gauge follow.
fn drawJudges(a: *App, age_ms: f32) void {
    const g = &a.g;
    const r = &a.res;
    const u = g.h / 720;
    const sc = &r.snap.score;
    var buf: [64]u8 = undefined;
    const lamp = if (r.clear == .failed) gfx.danger else gfx.cyan;
    const x0 = g.w * 0.5;
    const w = g.w - x0 - 16 * u;
    var y = 66 * u;
    const notes_f: f32 = @floatFromInt(@max(r.notes, 1));
    for (play.judge_names[0..5], 0..) |n, i| {
        const delay = @as(f32, @floatFromInt(i)) * 70;
        const e = 1 - std.math.pow(f32, 1 - std.math.clamp((age_ms - delay) / 350, 0, 1), 3);
        const x = x0 + (1 - e) * 500 * u;
        const v = sc.counts[i];
        const total = v[0] + v[1];
        g.panel(x, y, w, 78 * u, "");
        g.rect(x + 2, y + 8 * u, 5 * u, 62 * u, play.judge_colors[i]);
        _ = g.text(n, x + 18 * u, y + 14 * u, g.scaled(24), play.judge_colors[i]);
        g.fmt(x + 18 * u, y + 48 * u, g.scaled(12), gfx.dim, "FAST {d}   SLOW {d}", .{ v[0], v[1] });
        g.digits(x + w - 14 * u, y + 11 * u, g.scaled(48), 4, total, gfx.white);
        g.rect(x + 8 * u, y + 74 * u, (w - 16 * u) * @min(@as(f32, @floatFromInt(total)) / notes_f, 1), 2 * u, play.judge_colors[i]);
        y += 84 * u;
    }
    const cell = (w - 12 * u) / 3;
    const stats = [_]struct { []const u8, u64 }{ .{ "MAX COMBO", sc.max_combo }, .{ "BP", sc.missCount() }, .{ "EMPTY POOR", sc.counts[5][0] + sc.counts[5][1] } };
    for (stats, 0..) |st, i| {
        const x = x0 + @as(f32, @floatFromInt(i)) * (cell + 6 * u);
        g.panel(x, y, cell, 70 * u, st[0]);
        g.digits(x + cell - 12 * u, y + 20 * u, g.scaled(32), 4, st[1], gfx.white);
    }
    y += 76 * u;
    g.panel(x0, y, w, 46 * u, "GAUGE");
    g.rect(x0 + 10 * u, y + 22 * u, w - 110 * u, 12 * u, gfx.well);
    g.rect(x0 + 10 * u, y + 22 * u, (w - 110 * u) * std.math.clamp(r.snap.gauge / 100, 0, 1), 12 * u, lamp);
    g.textRight(std.fmt.bufPrint(&buf, "{d:.1}%", .{r.snap.gauge}) catch "", x0 + w - 10 * u, y + 12 * u, g.scaled(20), gfx.white);
}

pub fn draw(a: *App) void {
    const g = &a.g;
    const r = &a.res;
    if (a.result_skin) |sk| return drawSkinned(a, sk);
    const u = g.h / 720;
    const ex = r.snap.score.exScore();
    const age_ms: f32 = @floatFromInt(c.SDL_GetTicks() - r.shown_at);
    const ease = 1 - std.math.pow(f32, 1 - std.math.clamp(age_ms / 500, 0, 1), 3);
    drawHeadline(a, ease, ex);
    drawExPanel(a, ease, ex);
    drawJudges(a, age_ms);
    var key_buf: [32]u8 = undefined;
    var hint_buf: [48]u8 = undefined;
    g.textRight(std.fmt.bufPrint(&hint_buf, "{s}: BACK", .{select.guideKey(a, a.cfg.p1[0], "ENTER", &key_buf)}) catch "", g.w - 20 * u, g.h - 26 * u, g.scaled(14), gfx.dim);
}

pub fn key(a: *App, sc: u32) void {
    if (sc == c.SDL_SCANCODE_RETURN or sc == c.SDL_SCANCODE_ESCAPE or sc == c.SDL_SCANCODE_SPACE) {
        const r = &a.res;
        if (r.leave_at != 0) return;
        a.sfx(.back);
        if (a.result_skin == null) {
            a.scene = .select;
            return;
        }
        r.leave_at = c.SDL_GetTicks();
        a.skin_state.timers[2] = @intCast(r.leave_at - r.shown_at);
    }
    // The mouse wheel arrives as these too.
    if (a.res.board) |b| {
        if (sc == c.SDL_SCANCODE_UP) b.scroll(-1);
        if (sc == c.SDL_SCANCODE_DOWN) b.scroll(1);
    }
}

test "rank boundaries follow ninths of the max EX" {
    try std.testing.expectEqualStrings("AAA", rankOf(1600, 900));
    try std.testing.expectEqualStrings("AA", rankOf(1599, 900));
    try std.testing.expectEqualStrings("F", rankOf(0, 900));
}

test "leaving waits for a skin's fade and a built-in screen goes at once" {
    const a = try testing.open();
    defer testing.close(a);
    a.scene = .result;
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(.select, a.scene);
    a.scene = .result;
    a.result_skin = @ptrFromInt(8); // only compared with null on this path
    defer a.result_skin = null;
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expectEqual(.result, a.scene);
    try std.testing.expect(a.res.leave_at != 0);
    const at = a.res.leave_at;
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(at, a.res.leave_at);
}

test "up and down scroll the ranking" {
    const a = try testing.open();
    defer testing.close(a);
    var rows: [3]ir.Board.Row = @splat(.{});
    var b: ir.Board = .{ .gpa = a.gpa, .rows = &rows };
    b.state.store(ir.Board.accepted, .release);
    a.res.board = &b;
    defer a.res.board = null;
    key(a, c.SDL_SCANCODE_DOWN);
    try std.testing.expectEqual(@as(usize, 1), b.offset);
    key(a, c.SDL_SCANCODE_UP);
    key(a, c.SDL_SCANCODE_UP);
    try std.testing.expectEqual(@as(usize, 0), b.offset);
}
