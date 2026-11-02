//! Versus play: the room screen over song select, the start of a round, and the scores during and after it.
//! Against one player their score fills the skin's target slot, so existing skins show it unchanged.
const std = @import("std");
const c = @import("c");
const gfx = @import("gfx.zig");
const i18n = @import("i18n.zig");
const tr = i18n.tr;
const db_mod = @import("../db/db.zig");
const room_mod = @import("../net/room.zig");
const select = @import("select.zig");
const skin_model = @import("../skin/model.zig");
const skin_scene = @import("../skin/scene.zig");
const testing = @import("testing.zig");
const App = @import("app.zig").App;

/// A room's thread can outlive the game's allocator, when the game quits with a request still hanging.
const room_gpa = std.heap.smp_allocator;
/// How long the result waits for scores that may never come, from a player who quit or was refused.
const winner_wait_ms = 30_000;

pub const State = struct {
    room: ?*room_mod.Room = null,
    view: room_mod.View = .{},
    open: bool = false,
    /// Typing a room's code.
    joining: bool = false,
    /// The round already started here.
    played_round: u32 = 0,
    /// The chart the room asks for is in the library.
    has_chart: bool = false,
    chart_checked: [64]u8 = @splat(0),
    /// In a round started here, from loading to the result screen.
    in_round: bool = false,
    /// When this round's song starts. The view's clock moves as soon as the host starts another.
    start_tick: u64 = 0,
    /// When this round's result screen opened, 0 before it.
    result_at: u64 = 0,
    message: []const u8 = "",
    report: room_mod.Report = .{},
};

fn signedIn(a: *const App) bool {
    return a.cfg.ir_url.len > 0 and a.cfg.ir_token.len > 0;
}

pub fn leave(a: *App) void {
    const v = &a.versus;
    if (v.room) |r| r.leave();
    v.* = .{};
    a.skin_state.versus = null;
}

fn createRoom(a: *App) void {
    const v = &a.versus;
    const song = select.selectedSong(&a.sel) orelse {
        v.message = tr("Select a chart first");
        return;
    };
    v.room = room_mod.Room.create(room_gpa, a.cfg.ir_url, a.cfg.ir_token, song.sha256, song.title) catch |e| blk: {
        std.log.err("versus room: {t}", .{e});
        v.message = tr("Could not reach the room");
        break :blk null;
    };
}

fn joinRoom(a: *App) void {
    const v = &a.versus;
    a.stopText();
    v.joining = false;
    v.room = room_mod.Room.join(room_gpa, a.cfg.ir_url, a.cfg.ir_token, a.text.items) catch |e| blk: {
        std.log.err("versus room: {t}", .{e});
        v.message = if (e == error.BadCode) tr("No room has that code") else tr("Could not reach the room");
        break :blk null;
    };
}

/// The versus key on song select: opens the room screen, and a host's selected chart becomes the room's.
pub fn openScreen(a: *App) void {
    const v = &a.versus;
    if (!signedIn(a)) {
        a.sel.status = tr("Sign in to IR first");
        return;
    }
    v.open = true;
    const r = v.room orelse return;
    if (!v.view.host) return;
    const song = select.selectedSong(&a.sel) orelse return;
    if (!std.mem.eql(u8, song.sha256, &v.view.sha256)) r.setChart(song.sha256, song.title);
}

pub fn key(a: *App, sc: u32) void {
    const v = &a.versus;
    if (v.joining) {
        switch (sc) {
            c.SDL_SCANCODE_RETURN => joinRoom(a),
            c.SDL_SCANCODE_ESCAPE => {
                a.stopText();
                v.joining = false;
            },
            c.SDL_SCANCODE_BACKSPACE => if (a.text.items.len > 0) {
                a.text.items.len -= 1;
            },
            else => {},
        }
        return;
    }
    const usable = if (v.room != null) v.view.status == .joined or v.view.status == .connecting else false;
    if (!usable) {
        switch (sc) {
            c.SDL_SCANCODE_ESCAPE => {
                if (v.room != null) leave(a) else v.open = false;
            },
            c.SDL_SCANCODE_C => if (v.room == null) createRoom(a),
            // Not a letter key: its own press would land in the code.
            c.SDL_SCANCODE_RETURN => if (v.room == null) {
                v.joining = true;
                a.startText("");
            },
            else => {},
        }
        return;
    }
    switch (sc) {
        c.SDL_SCANCODE_ESCAPE => leave(a),
        // Back to the list, so a host can pick another chart with the versus key.
        c.SDL_SCANCODE_TAB => v.open = false,
        c.SDL_SCANCODE_RETURN => if (v.view.host) v.room.?.start(),
        c.SDL_SCANCODE_L => a.cfg.versus_panel_left = !a.cfg.versus_panel_left,
        else => {},
    }
}

fn checkChart(a: *App) void {
    const v = &a.versus;
    if (std.mem.eql(u8, &v.chart_checked, &v.view.sha256)) return;
    v.chart_checked = v.view.sha256;
    v.has_chart = false;
    const st = a.db.prepare("SELECT 1 FROM song WHERE sha256=?1 LIMIT 1") catch return;
    defer st.deinit();
    st.bindText(1, &v.view.sha256);
    v.has_chart = st.step() catch false;
}

/// Runs every frame on every screen.
pub fn tick(a: *App) void {
    const v = &a.versus;
    const r = v.room orelse return;
    v.view = r.snapshot();
    checkChart(a);
    // Not the room's round: one skipped here must not take the last round's score, or a song played alone.
    v.report.round = v.played_round;
    v.report.has_chart = v.has_chart;
    if (v.in_round and a.scene == .play) if (a.session) |s| {
        const snap = s.snapshot();
        v.report.ex = snap.score.exScore();
        v.report.judged = snap.score.passed;
        v.report.gauge = snap.gauge;
    };
    if (v.in_round) v.report.done = a.scene == .result;
    if (v.in_round and a.scene == .result and v.result_at == 0) v.result_at = c.SDL_GetTicks();
    r.setReport(v.report);
    if (a.scene == .select) {
        if (v.in_round) {
            v.in_round = false;
            v.open = true;
        }
        if (v.view.start_round != v.played_round and v.view.start_round != 0) startRound(a);
    }
}

/// The song takes the keyboard from whatever was open over song select.
fn closeOverSelect(a: *App) void {
    a.practice.open = false;
    a.sel.searching = false;
    a.stopText();
}

fn startRound(a: *App) void {
    const v = &a.versus;
    v.played_round = v.view.start_round;
    v.report = .{};
    v.message = "";
    if (c.SDL_GetTicks() >= v.view.start_tick) {
        v.message = tr("That round has already started");
        return;
    }
    if (!v.has_chart) {
        v.message = tr("You do not have this chart");
        return;
    }
    const st = a.db.prepare(db_mod.song_select ++ " WHERE s.sha256=?1 LIMIT 1") catch return;
    defer st.deinit();
    st.bindText(1, &v.view.sha256);
    var tmp = std.heap.ArenaAllocator.init(a.gpa);
    defer tmp.deinit();
    if (!(st.step() catch false)) return;
    const song = db_mod.readSong(tmp.allocator(), st) catch return;
    v.open = false;
    v.in_round = true;
    v.start_tick = v.view.start_tick;
    v.result_at = 0;
    closeOverSelect(a);
    select.startVersus(a, song, v.view.seed);
    a.skin_state.versus = &v.view;
}

/// The other player highest on the board, for the target slot. Null with nobody else there.
pub fn opponent(v: *const room_mod.View) ?*const room_mod.Player {
    var best: ?*const room_mod.Player = null;
    for (v.players[0..v.count]) |*p| {
        if (p.you) continue;
        if (best == null or p.ex > best.?.ex) best = p;
    }
    return best;
}

/// A skin that reads the versus numbers draws the board itself.
pub fn skinDrawsBoard(skin: *const skin_model.Skin) bool {
    for (skin.objects) |*o| if (o.kind == .number and o.ref >= skin_model.versus_ex and o.ref < skin_model.versus_ex + room_mod.max_players) return true;
    return false;
}

pub fn fillTarget(a: *App) void {
    const v = &a.versus;
    if (!v.in_round) return;
    const o = opponent(&v.view) orelse return;
    a.view.target_ex = o.ex;
    a.view.target_label = o.name();
    a.view.target_live = true;
    a.skin_state.target_ex = o.ex;
    a.skin_state.target_label = o.name();
    a.skin_state.target_live = true;
}

fn sorted(v: *const room_mod.View, out: *[room_mod.max_players]*const room_mod.Player) []*const room_mod.Player {
    for (v.players[0..v.count], 0..) |*p, i| out[i] = p;
    const list = out[0..v.count];
    std.mem.sort(*const room_mod.Player, list, {}, struct {
        fn f(_: void, l: *const room_mod.Player, r: *const room_mod.Player) bool {
            return shownEx(l) > shownEx(r);
        }
    }.f);
    return list;
}

fn shownEx(p: *const room_mod.Player) u32 {
    return p.final_ex orelse p.ex;
}

/// A small board for what skins have no place for: more than one opponent, or a lost connection.
pub fn drawPlayBoard(a: *App) void {
    const v = &a.versus;
    if (!v.in_round) return;
    if (v.view.status == .lost) {
        a.g.textCentered(tr("Connection to the room was lost"), a.g.w / 2, 12 * a.g.h / 720, a.g.scaled(14), gfx.amber);
    }
    if (v.view.count < 3) return;
    if (a.play_skin) |sk| if (skinDrawsBoard(sk)) return;
    drawBoard(a, if (a.cfg.versus_panel_left) 12 * a.g.h / 720 else a.g.w - 232 * a.g.h / 720, 84 * a.g.h / 720);
}

fn drawBoard(a: *App, x: f32, y: f32) void {
    const g = &a.g;
    const v = &a.versus;
    const u = g.h / 720;
    const row_h = 20 * u;
    var order: [room_mod.max_players]*const room_mod.Player = undefined;
    const list = sorted(&v.view, &order);
    g.panel(x, y, 220 * u, 8 * u + row_h * @as(f32, @floatFromInt(list.len)), "");
    for (list, 0..) |p, i| {
        const ry = y + 4 * u + row_h * @as(f32, @floatFromInt(i));
        const col = if (p.you) gfx.cyan else gfx.white;
        g.textClip(p.name(), x + 10 * u, ry, 130 * u, g.scaled(14), col);
        var buf: [16]u8 = undefined;
        g.textRight(std.fmt.bufPrint(&buf, "{d}", .{shownEx(p)}) catch "", x + 210 * u, ry, g.scaled(14), col);
    }
}

/// Who won, once the replays are checked. A score not checked yet is shown, and cannot win.
pub fn drawResult(a: *App) void {
    const v = &a.versus;
    if (!v.in_round) return;
    const g = &a.g;
    const u = g.h / 720;
    const x = 30 * u;
    // shortcut: a full room reaches the grade behind it, move this if the result screen gets a free column.
    const y = 124 * u;
    const row_h = 22 * u;
    var order: [room_mod.max_players]*const room_mod.Player = undefined;
    const list = sorted(&v.view, &order);
    g.panel(x, y, 330 * u, 34 * u + row_h * @as(f32, @floatFromInt(list.len)), "VERSUS");
    const top = winner(list, v.result_at != 0 and c.SDL_GetTicks() - v.result_at >= winner_wait_ms);
    for (list, 0..) |p, i| {
        const ry = y + 26 * u + row_h * @as(f32, @floatFromInt(i));
        const col = if (top == p) gfx.amber else if (p.you) gfx.cyan else gfx.white;
        g.textClip(p.name(), x + 12 * u, ry, 160 * u, g.scaled(14), col);
        var buf: [32]u8 = undefined;
        const label = if (p.final_ex) |ex| std.fmt.bufPrint(&buf, "{d}", .{ex}) catch "" else std.fmt.bufPrint(&buf, "{d} ...", .{p.ex}) catch "";
        g.textRight(label, x + 318 * u, ry, g.scaled(14), col);
    }
}

/// Only a checked score counts, and nobody has won until everyone's is in or `waited_out`.
fn winner(list: []const *const room_mod.Player, waited_out: bool) ?*const room_mod.Player {
    var best: ?*const room_mod.Player = null;
    if (!waited_out) for (list) |p| {
        if (p.has_chart and p.final_ex == null) return null;
    };
    for (list) |p| {
        const ex = p.final_ex orelse continue;
        if (best == null or ex > best.?.final_ex.?) best = p;
    }
    return best;
}

pub fn draw(a: *App) void {
    const v = &a.versus;
    if (!v.open) return;
    const g = &a.g;
    const u = g.h / 720;
    const w = 560 * u;
    const h = 460 * u;
    const x = (g.w - w) / 2;
    const y = (g.h - h) / 2;
    g.rect(0, 0, g.w, g.h, gfx.bg.alpha(170));
    g.panel(x, y, w, h, "");
    _ = g.text(tr("VERSUS"), x + 20 * u, y + 12 * u, g.scaled(24), gfx.white);
    const body = y + 56 * u;
    if (v.joining) {
        _ = g.text(tr("Room code"), x + 24 * u, body, g.scaled(16), gfx.dim);
        _ = g.text(a.text.items, x + 24 * u, body + 30 * u, g.scaled(32), gfx.white);
    } else if (v.room == null) {
        _ = g.text(tr("C: create a room for the selected chart"), x + 24 * u, body, g.scaled(16), gfx.white);
        _ = g.text(tr("ENTER: join a room by its code"), x + 24 * u, body + 30 * u, g.scaled(16), gfx.white);
    } else switch (v.view.status) {
        .connecting => _ = g.text(tr("Connecting..."), x + 24 * u, body, g.scaled(16), gfx.dim),
        .full => _ = g.text(tr("That room is full"), x + 24 * u, body, g.scaled(16), gfx.amber),
        .not_found => _ = g.text(tr("No room has that code"), x + 24 * u, body, g.scaled(16), gfx.amber),
        .failed => _ = g.text(tr("Could not reach the room"), x + 24 * u, body, g.scaled(16), gfx.amber),
        .lost => _ = g.text(tr("Connection to the room was lost"), x + 24 * u, body, g.scaled(16), gfx.amber),
        .joined => drawRoom(a, x, body, w),
    }
    g.textCentered(if (v.view.order_failed) tr("The room did not take that") else v.message, x + w / 2, y + h - 52 * u, g.scaled(14), gfx.amber);
    g.textCentered(tr("ESC: leave"), x + w / 2, y + h - 28 * u, g.scaled(12), gfx.dim);
}

fn drawRoom(a: *App, x: f32, y: f32, w: f32) void {
    const g = &a.g;
    const v = &a.versus;
    const u = g.h / 720;
    g.textRight(&v.view.code, x + w - 24 * u, y - 44 * u, g.scaled(32), gfx.cyan);
    g.textClip(v.view.title(), x + 24 * u, y, w - 48 * u, g.scaled(20), gfx.white);
    if (!v.has_chart) _ = g.text(tr("You do not have this chart"), x + 24 * u, y + 28 * u, g.scaled(14), gfx.amber);
    for (v.view.players[0..v.view.count], 0..) |*p, i| {
        const ry = y + 56 * u + 26 * u * @as(f32, @floatFromInt(i));
        g.textClip(p.name(), x + 24 * u, ry, w * 0.5, g.scaled(16), if (p.you) gfx.cyan else gfx.white);
        if (p.host) g.textRight(tr("HOST"), x + w * 0.75, ry, g.scaled(14), gfx.sky);
        if (!p.has_chart) g.textRight(tr("NO CHART"), x + w - 24 * u, ry, g.scaled(14), gfx.amber);
    }
    const hints = y + 300 * u;
    if (v.view.host) {
        g.textCentered(tr("ENTER: start. TAB: pick a chart, then the versus key."), x + w / 2, hints, g.scaled(14), gfx.sky);
    } else g.textCentered(tr("Waiting for the host"), x + w / 2, hints, g.scaled(14), gfx.dim);
    g.textCentered(tr("L: move the score board in play"), x + w / 2, hints + 24 * u, g.scaled(12), gfx.dim);
}

/// The clock of a round about to start, over the loading screen.
pub fn drawCountdown(a: *App) void {
    const v = &a.versus;
    if (!v.in_round) return;
    const now = c.SDL_GetTicks();
    if (now >= v.start_tick) return;
    var buf: [16]u8 = undefined;
    a.g.textCentered(std.fmt.bufPrint(&buf, "{d}", .{(v.start_tick - now) / 1000 + 1}) catch "", a.g.w / 2, a.g.h * 0.2, a.g.scaled(72), gfx.white);
}

test "the opponent is the best other player, and only a checked score wins" {
    var v: room_mod.View = .{ .count = 3 };
    v.players[0] = .{ .you = true, .ex = 500 };
    v.players[1] = .{ .ex = 10, .final_ex = 900 };
    v.players[2] = .{ .ex = 20 };
    try std.testing.expectEqual(&v.players[2], opponent(&v).?);
    var order: [room_mod.max_players]*const room_mod.Player = undefined;
    const list = sorted(&v, &order);
    try std.testing.expectEqual(&v.players[1], list[0]);
    try std.testing.expectEqual(&v.players[1], winner(list, false).?);
    v.players[2].has_chart = true;
    try std.testing.expect(winner(list, false) == null);
    try std.testing.expectEqual(&v.players[1], winner(list, true).?);
    v.players[1].final_ex = null;
    try std.testing.expect(winner(list, true) == null);
    v.count = 1;
    try std.testing.expect(opponent(&v) == null);
}

test "a skin reading the versus numbers replaces the board, and they read the room" {
    var objects = [_]skin_model.Object{.{ .kind = .number, .ref = skin_model.versus_ex + 1 }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var skin: skin_model.Skin = .{ .arena = arena };
    try std.testing.expect(!skinDrawsBoard(&skin));
    skin.objects = &objects;
    try std.testing.expect(skinDrawsBoard(&skin));
    var v: room_mod.View = .{ .count = 1 };
    v.players[0] = .{ .ex = 7, .judged = 3, .final_ex = 8 };
    var st: skin_scene.State = .{ .versus = &v };
    const ctx = st.loadCtx();
    try std.testing.expectEqual(@as(?i64, 8), ctx.num(ctx.ud, skin_model.versus_ex));
    try std.testing.expectEqual(@as(?i64, 3), ctx.num(ctx.ud, skin_model.versus_judged));
    try std.testing.expect(ctx.opt(ctx.ud, skin_model.versus_present));
    try std.testing.expect(!ctx.opt(ctx.ud, skin_model.versus_present + 1));
}

test "a round closes what was open over song select" {
    const a = try testing.open();
    defer testing.close(a);
    a.practice.open = true;
    a.sel.searching = true;
    a.startText("x");
    closeOverSelect(a);
    try std.testing.expect(!a.practice.open and !a.sel.searching and !a.text_active);
}

test "the room screen needs a sign-in, and closes without a room" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.ir_token = "";
    openScreen(a);
    try std.testing.expect(!a.versus.open);
    a.cfg.ir_url = "http://127.0.0.1:1";
    a.cfg.ir_token = "t";
    openScreen(a);
    try std.testing.expect(a.versus.open);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(!a.versus.open);
}
