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
    /// The lounge's cursor is on joining, not creating.
    join_row: bool = false,
    joining: bool = false,
    picking: bool = false,
    played_round: u32 = 0,
    chart: ?db_mod.Song = null,
    chart_arena: ?std.heap.ArenaAllocator = null,
    chart_checked: [64]u8 = @splat(0),
    /// From loading to the result screen.
    in_round: bool = false,
    /// Kept here because the view's clock moves as soon as the host starts another round.
    start_tick: u64 = 0,
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
    if (v.chart_arena) |*ar| ar.deinit();
    v.* = .{};
    a.skin_state.versus = null;
}

fn createRoom(a: *App) void {
    const v = &a.versus;
    v.message = "";
    // With nothing selected the room opens without a chart, and the host picks one inside it.
    const song = select.selectedSong(&a.sel);
    v.room = room_mod.Room.create(room_gpa, a.cfg.ir_url, a.cfg.ir_token, if (song) |s| s.sha256 else "", if (song) |s| s.title else "") catch |e| blk: {
        std.log.err("versus room: {t}", .{e});
        v.message = tr("Could not reach the room");
        break :blk null;
    };
}

fn joinRoom(a: *App) void {
    const v = &a.versus;
    a.stopText();
    v.joining = false;
    v.message = "";
    v.room = room_mod.Room.join(room_gpa, a.cfg.ir_url, a.cfg.ir_token, a.text.items) catch |e| blk: {
        std.log.err("versus room: {t}", .{e});
        v.message = if (e == error.BadCode) tr("No room has that code") else tr("Could not reach the room");
        break :blk null;
    };
}

/// A host's selected chart becomes the room's.
pub fn openScreen(a: *App) void {
    const v = &a.versus;
    if (!signedIn(a)) {
        a.sel.status = tr("Sign in to IR first");
        return;
    }
    a.sfx(.confirm);
    a.scene = .versus;
    v.picking = false;
    const r = v.room orelse return;
    if (!v.view.host) return;
    const song = select.selectedSong(&a.sel) orelse return;
    if (!std.mem.eql(u8, song.sha256, &v.view.sha256)) r.setChart(song.sha256, song.title);
}

fn startPicking(a: *App) void {
    a.versus.picking = true;
    a.sel.status = tr("Open a chart to play it in the room. Esc goes back to the room.");
    a.scene = .select;
}

pub fn pickChart(a: *App, song: db_mod.Song) void {
    const v = &a.versus;
    if (v.room) |r| if (v.view.host and !std.mem.eql(u8, song.sha256, &v.view.sha256)) r.setChart(song.sha256, song.title);
    a.sfx(.confirm);
    stopPicking(a);
}

pub fn stopPicking(a: *App) void {
    a.versus.picking = false;
    a.sel.status = "";
    a.scene = .versus;
}

pub fn key(a: *App, sc: u32) void {
    const v = &a.versus;
    const in_room = v.room != null and v.view.status == .joined;
    switch (sc) {
        c.SDL_SCANCODE_ESCAPE => a.sfx(.back),
        c.SDL_SCANCODE_RETURN => if (v.room == null or (in_room and v.view.host)) a.sfx(.confirm),
        c.SDL_SCANCODE_TAB => if (in_room and v.view.host) a.sfx(.confirm),
        c.SDL_SCANCODE_L => if (in_room) a.sfx(.adjust),
        else => {},
    }
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
    const r = v.room orelse {
        switch (sc) {
            c.SDL_SCANCODE_ESCAPE => a.scene = .select,
            c.SDL_SCANCODE_UP, c.SDL_SCANCODE_DOWN => {
                a.sfx(.move);
                v.join_row = !v.join_row;
            },
            // Not a letter key: its own press would land in the code.
            c.SDL_SCANCODE_RETURN => if (v.join_row) {
                v.joining = true;
                a.startText("");
            } else createRoom(a),
            else => {},
        }
        return;
    };
    // A refused or lost room leaves the same way, back to the lounge.
    if (sc == c.SDL_SCANCODE_ESCAPE) return leave(a);
    if (v.view.status != .joined) return;
    switch (sc) {
        c.SDL_SCANCODE_TAB => if (v.view.host) startPicking(a),
        c.SDL_SCANCODE_RETURN => if (v.view.host) r.start(),
        c.SDL_SCANCODE_L => a.cfg.versus_panel_left = !a.cfg.versus_panel_left,
        else => {},
    }
}

fn loadChart(a: *App) void {
    const v = &a.versus;
    if (std.mem.eql(u8, &v.chart_checked, &v.view.sha256)) return;
    v.chart_checked = v.view.sha256;
    v.chart = null;
    if (v.chart_arena) |*ar| {
        _ = ar.reset(.free_all);
    } else v.chart_arena = .init(a.gpa);
    const st = a.db.prepare(db_mod.song_select ++ " WHERE s.sha256=?1 LIMIT 1") catch return;
    defer st.deinit();
    st.bindText(1, &v.view.sha256);
    if (!(st.step() catch false)) return;
    v.chart = db_mod.readSong(v.chart_arena.?.allocator(), st) catch null;
}

/// Runs every frame on every screen.
pub fn tick(a: *App) void {
    const v = &a.versus;
    const r = v.room orelse return;
    v.view = r.snapshot();
    loadChart(a);
    // Not the room's round: one skipped here must not take the last round's score, or a song played alone.
    v.report.round = v.played_round;
    v.report.has_chart = v.chart != null;
    if (v.in_round and a.scene == .play) if (a.session) |s| {
        const snap = s.snapshot();
        v.report.ex = snap.score.exScore();
        v.report.judged = snap.score.passed;
        v.report.gauge = snap.gauge;
    };
    if (v.in_round) v.report.done = a.scene == .result;
    if (v.in_round and a.scene == .result and v.result_at == 0) v.result_at = c.SDL_GetTicks();
    r.setReport(v.report);
    if (a.scene == .select or a.scene == .versus) {
        // The result screen leaves for song select, and a round ends back in its room.
        if (v.in_round) {
            v.in_round = false;
            a.scene = .versus;
        }
        if (v.view.start_round != v.played_round and v.view.start_round != 0) startRound(a);
    }
}

/// The song takes the keyboard from whatever was open over song select.
fn closeOverSelect(a: *App) void {
    a.practice.open = false;
    a.sel.searching = false;
    a.versus.picking = false;
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
    const song = v.chart orelse {
        v.message = tr("You do not have this chart");
        return;
    };
    v.in_round = true;
    v.start_tick = v.view.start_tick;
    v.result_at = 0;
    closeOverSelect(a);
    select.startVersus(a, song, v.view.seed);
    a.skin_state.versus = &v.view;
}

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

/// A skin with a target number shows the one opponent there; osu! skins have none.
fn skinShowsTarget(skin: *const skin_model.Skin) bool {
    for (skin.objects) |*o| if (o.kind == .number and (o.ref == 121 or o.ref == 151 or o.ref == 153)) return true;
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

/// For what skins have no place for: more than one opponent, no target slot, or a lost connection.
pub fn drawPlayBoard(a: *App) void {
    const v = &a.versus;
    if (!v.in_round) return;
    if (v.view.status == .lost) {
        a.g.textCentered(tr("Connection to the room was lost"), a.g.w / 2, 12 * a.g.h / 720, a.g.scaled(14), gfx.amber);
    }
    if (v.view.count < 2) return;
    if (a.play_skin) |sk| {
        if (skinDrawsBoard(sk)) return;
        if (v.view.count == 2 and skinShowsTarget(sk)) return;
    } else if (v.view.count == 2) return; // the built-in deck shows the one opponent as its target

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

/// A score not checked yet is shown, and cannot win.
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
    const top = roundWinner(v, list);
    for (list, 0..) |p, i| {
        const ry = y + 26 * u + row_h * @as(f32, @floatFromInt(i));
        const col = if (top == p) gfx.amber else if (p.you) gfx.cyan else gfx.white;
        g.textClip(p.name(), x + 12 * u, ry, 160 * u, g.scaled(14), col);
        var buf: [32]u8 = undefined;
        const label = if (p.final_ex) |ex| std.fmt.bufPrint(&buf, "{d}", .{ex}) catch "" else std.fmt.bufPrint(&buf, "{d} ...", .{p.ex}) catch "";
        g.textRight(label, x + 318 * u, ry, g.scaled(14), col);
    }
}

fn roundWinner(v: *const State, list: []const *const room_mod.Player) ?*const room_mod.Player {
    return winner(list, v.result_at != 0 and c.SDL_GetTicks() - v.result_at >= winner_wait_ms);
}

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

/// A room opened with no chart sends none, so its hash stays unset.
fn hasChart(v: *const room_mod.View) bool {
    return v.sha256[0] != 0;
}

const Seat = enum { idle, no_chart, playing, results, winner };

/// Derived from what the room already sends: it keeps no ready state.
fn seatOf(p: *const room_mod.Player, v: *const room_mod.View, top: ?*const room_mod.Player) Seat {
    if (top == p) return .winner;
    if (!p.has_chart) return if (hasChart(v)) .no_chart else .idle;
    if (v.round == 0) return .idle;
    if (p.done) return .results;
    return if (p.judged > 0) .playing else .idle;
}

pub fn draw(a: *App) void {
    const g = &a.g;
    const v = &a.versus;
    const u = g.h / 720;
    _ = g.text(tr("Versus"), 22 * u, 18 * u, g.scaled(32), gfx.white);
    if (v.room == null) return drawLounge(a);
    if (v.view.status == .joined) return drawRoom(a);
    const say = switch (v.view.status) {
        .connecting, .joined => tr("Connecting..."),
        .full => tr("That room is full"),
        .not_found => tr("No room has that code"),
        .failed => tr("Could not reach the room"),
        .lost => tr("Connection to the room was lost"),
    };
    const f = frame(a);
    g.panel(f.x, f.top, f.w, f.bottom - f.top, "");
    _ = g.text(tr("Room"), f.x + 18 * u, f.top + 10 * u, g.scaled(24), gfx.white);
    drawRow(g, f.x + 8 * u, f.top + menu_row * u, f.w - 16 * u, say, if (v.view.status == .connecting) gfx.dim else gfx.amber, "", gfx.dim, null);
    drawHelp(a, "", "");
    select.drawCommands(a, &.{.{ .sc = c.SDL_SCANCODE_ESCAPE, .label = tr("Esc Leave") }});
}

const Frame = struct { x: f32, w: f32, top: f32, bottom: f32, help_y: f32 };

fn frame(a: *const App) Frame {
    const u = a.g.h / 720;
    const help_y = a.g.h - 34 * u - 56 * u;
    return .{ .x = 14 * u, .w = a.g.w - 28 * u, .top = 72 * u, .bottom = help_y - 8 * u, .help_y = help_y };
}

/// Settings' row pitch, in 720p units.
const menu_row = 54;

fn drawRow(g: *gfx.Gfx, x: f32, y: f32, w: f32, label: []const u8, label_col: gfx.Color, value: []const u8, value_col: gfx.Color, fill: ?gfx.Color) void {
    const u = g.h / 720;
    const h = (menu_row - 4) * u;
    if (fill) |col| g.round(x, y, w, h, 8 * u, col);
    const ty = y + (h - 22 * u) / 2;
    const label_w = @min(g.measure(label, g.scaled(16)), w * 0.6);
    g.textClip(label, x + 12 * u, ty, label_w, g.scaled(16), label_col);
    const right = x + w - 14 * u;
    const value_x = x + 36 * u + label_w;
    g.textClip(value, @max(value_x, right - g.measure(value, g.scaled(14))), ty + u, right - value_x, g.scaled(14), value_col);
}

fn rowFill(g: *const gfx.Gfx, on: bool, x: f32, y: f32, w: f32) ?gfx.Color {
    if (on) return gfx.accent;
    return if (g.hit(x, y, w, (menu_row - 4) * g.h / 720)) gfx.rule else null;
}

/// Rooms are private, so a code takes the place of osu!lazer's room list.
fn drawLounge(a: *App) void {
    const g = &a.g;
    const v = &a.versus;
    const u = g.h / 720;
    const f = frame(a);
    g.panel(f.x, f.top, f.w, f.bottom - f.top, "");
    _ = g.text(tr("Lounge"), f.x + 18 * u, f.top + 10 * u, g.scaled(24), gfx.white);
    const rx = f.x + 8 * u;
    const rw = f.w - 16 * u;
    const song = select.selectedSong(&a.sel);
    for ([_][]const u8{ tr("Create a room"), tr("Join a room") }, 0..) |label, i| {
        const ry = f.top + menu_row * u * @as(f32, @floatFromInt(i + 1));
        const join = i == 1;
        const on = join == v.join_row;
        const value_col = if (on) gfx.white else gfx.dim;
        const value = if (join) (if (v.joining) "" else tr("Room code")) else if (song) |s| s.title else tr("No chart yet");
        drawRow(g, rx, ry, rw, label, gfx.white, value, value_col, rowFill(g, on, rx, ry, rw));
        if (join and v.joining) {
            const rh = (menu_row - 4) * u;
            const fx = rx + 260 * u;
            g.round(fx, ry + (rh - 30 * u) / 2, rx + rw - 14 * u - fx, 30 * u, 6 * u, gfx.well);
            var up: [32]u8 = undefined;
            const n = @min(a.text.items.len, up.len);
            g.fmt(fx + 10 * u, ry + (rh - 22 * u) / 2, g.scaled(16), gfx.white, "{s}_", .{std.ascii.upperString(up[0..n], a.text.items[0..n])});
        }
        if (!v.joining and g.clickIn(rx, ry, rw, (menu_row - 4) * u)) {
            v.join_row = join;
            a.click_key = c.SDL_SCANCODE_RETURN;
        }
    }
    drawHelp(a, if (v.join_row) tr("Type the code the host shares, then press Enter.") else tr("Opens a room for the selected chart, or with none for now. Others join with its code."), v.message);
    if (v.joining) {
        select.drawCommands(a, &.{
            .{ .sc = c.SDL_SCANCODE_RETURN, .label = tr("Enter Join") },
            .{ .sc = c.SDL_SCANCODE_ESCAPE, .label = tr("Esc Back") },
        });
    } else select.drawCommands(a, &.{
        .{ .sc = c.SDL_SCANCODE_DOWN, .label = tr("Up/Down Choose") },
        .{ .sc = c.SDL_SCANCODE_RETURN, .label = tr("Enter Open") },
        .{ .sc = c.SDL_SCANCODE_ESCAPE, .label = tr("Esc Back") },
    });
}

fn drawHelp(a: *App, help: []const u8, message: []const u8) void {
    const g = &a.g;
    const u = g.h / 720;
    const f = frame(a);
    g.panel(f.x, f.help_y, f.w, 56 * u, "");
    g.textClip(help, f.x + 18 * u, f.help_y + 8 * u, f.w - 36 * u, g.scaled(14), gfx.sky);
    g.textClip(message, f.x + 18 * u, f.help_y + 30 * u, f.w - 36 * u, g.scaled(14), gfx.white);
}

fn drawRoom(a: *App) void {
    const g = &a.g;
    const v = &a.versus;
    const u = g.h / 720;
    const code_w = g.measure(&v.view.code, g.scaled(32));
    g.textRight(&v.view.code, g.w - 22 * u, 18 * u, g.scaled(32), gfx.cyan);
    g.textRight(tr("Room code"), g.w - 34 * u - code_w, 30 * u, g.scaled(14), gfx.dim);

    const f = frame(a);
    const lw = (f.w - 14 * u) / 2;
    g.panel(f.x, f.top, lw, f.bottom - f.top, "");
    _ = g.text(tr("Players"), f.x + 18 * u, f.top + 10 * u, g.scaled(24), gfx.white);
    g.fmt(f.x + 30 * u + g.measure(tr("Players"), g.scaled(24)), f.top + 18 * u, g.scaled(16), gfx.dim, "{d} / {d}", .{ v.view.count, room_mod.max_players });
    var order: [room_mod.max_players]*const room_mod.Player = undefined;
    const list = sorted(&v.view, &order);
    const top_player = roundWinner(v, list);
    for (list, 0..) |p, i| drawPlayer(a, p, top_player, f.x + 8 * u, f.top + menu_row * u * @as(f32, @floatFromInt(i + 1)), lw - 16 * u);

    const rx = f.x + lw + 14 * u;
    const rw = f.w - lw - 14 * u;
    g.panel(rx, f.top, rw, f.bottom - f.top, "");
    _ = g.text(tr("Chart"), rx + 18 * u, f.top + 10 * u, g.scaled(24), gfx.white);
    if (v.chart) |song| {
        g.textRight(song.shownLevel(), rx + rw - 18 * u, f.top + 10 * u, g.scaled(24), gfx.cyan);
        g.textRight(tr("LEVEL"), rx + rw - 26 * u - g.measure(song.shownLevel(), g.scaled(24)), f.top + 18 * u, g.scaled(14), gfx.dim);
    }
    drawChart(a, rx + 8 * u, f.top + menu_row * u, rw - 16 * u);
    const sy = f.bottom - 8 * u - (menu_row - 4) * u;
    if (!v.view.host) {
        drawRow(g, rx + 8 * u, sy, rw - 16 * u, tr("Waiting for the host"), gfx.dim, "", gfx.dim, null);
    } else if (!hasChart(&v.view)) {
        drawRow(g, rx + 8 * u, sy, rw - 16 * u, tr("Start"), gfx.dim, "", gfx.dim, null);
    } else {
        drawRow(g, rx + 8 * u, sy, rw - 16 * u, tr("Start"), gfx.white, "Enter", gfx.white, rowFill(g, true, rx + 8 * u, sy, rw - 16 * u));
        if (g.clickIn(rx + 8 * u, sy, rw - 16 * u, (menu_row - 4) * u)) a.click_key = c.SDL_SCANCODE_RETURN;
    }
    drawHelp(a, tr("Everyone plays with the same seed, in LN mode, with no assist options."), if (v.view.order_failed) tr("The room did not take that") else v.message);

    const board = if (a.cfg.versus_panel_left) tr("L Score board: left") else tr("L Score board: right");
    if (v.view.host) {
        select.drawCommands(a, &.{
            .{ .sc = c.SDL_SCANCODE_RETURN, .label = tr("Enter Start") },
            .{ .sc = c.SDL_SCANCODE_TAB, .label = tr("Tab Change chart") },
            .{ .sc = c.SDL_SCANCODE_L, .label = board },
            .{ .sc = c.SDL_SCANCODE_ESCAPE, .label = tr("Esc Leave") },
        });
    } else select.drawCommands(a, &.{
        .{ .sc = c.SDL_SCANCODE_L, .label = board },
        .{ .sc = c.SDL_SCANCODE_ESCAPE, .label = tr("Esc Leave") },
    });
}

fn drawPlayer(a: *App, p: *const room_mod.Player, top_player: ?*const room_mod.Player, x: f32, y: f32, w: f32) void {
    const g = &a.g;
    const u = g.h / 720;
    const v = &a.versus.view;
    const seat = seatOf(p, v, top_player);
    var buf: [16]u8 = undefined;
    const score = if (v.round == 0 or (p.final_ex == null and p.judged == 0)) "" else std.fmt.bufPrint(&buf, "{d}", .{shownEx(p)}) catch "";
    const score_col = if (seat == .winner) gfx.amber else if (p.final_ex == null) gfx.sky else gfx.white;
    drawRow(g, x, y, w, p.name(), if (p.you) gfx.cyan else gfx.white, score, score_col, if (p.you) gfx.slab else null);
    var tx = x + w * 0.62;
    const ty = y + ((menu_row - 4) * u - 22 * u) / 2 + u;
    if (p.host) tx += g.text(tr("HOST"), tx, ty, g.scaled(14), gfx.sky).w + 12 * u;
    const tag: struct { []const u8, gfx.Color } = switch (seat) {
        .idle => .{ "", gfx.dim },
        .no_chart => .{ tr("NO CHART"), gfx.amber },
        .playing => .{ tr("PLAYING"), gfx.sky },
        .results => .{ tr("RESULTS"), gfx.dim },
        .winner => .{ tr("WINNER"), gfx.amber },
    };
    _ = g.text(tag[0], tx, ty, g.scaled(14), tag[1]);
}

fn drawChart(a: *App, x: f32, y: f32, w: f32) void {
    const g = &a.g;
    const v = &a.versus;
    const u = g.h / 720;
    const step = menu_row * u;
    if (!hasChart(&v.view)) {
        const hint = if (v.view.host) tr("Tab opens song select to pick one.") else "";
        return drawRow(g, x, y, w, tr("No chart yet"), gfx.dim, hint, gfx.dim, null);
    }
    const song = v.chart orelse {
        g.textClip(v.view.title(), x + 10 * u, y, w - 20 * u, g.scaled(24), gfx.white);
        return drawRow(g, x, y + step, w, tr("You do not have this chart"), gfx.amber, "", gfx.dim, null);
    };
    _ = select.drawSongData(g, song, x + 10 * u, y, w - 20 * u);
}

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

test "a player's card follows the round" {
    var p: room_mod.Player = .{};
    var v: room_mod.View = .{};
    try std.testing.expectEqual(Seat.idle, seatOf(&p, &v, null));
    v.sha256 = @splat('a');
    try std.testing.expectEqual(Seat.no_chart, seatOf(&p, &v, null));
    p.has_chart = true;
    try std.testing.expectEqual(Seat.idle, seatOf(&p, &v, null));
    v.round = 1;
    try std.testing.expectEqual(Seat.idle, seatOf(&p, &v, null));
    p.judged = 5;
    try std.testing.expectEqual(Seat.playing, seatOf(&p, &v, null));
    p.done = true;
    try std.testing.expectEqual(Seat.results, seatOf(&p, &v, null));
    try std.testing.expectEqual(Seat.winner, seatOf(&p, &v, &p));
}

test "a skin reading the versus numbers replaces the board, and they read the room" {
    var objects = [_]skin_model.Object{.{ .kind = .number, .ref = skin_model.versus_ex + 1 }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var skin: skin_model.Skin = .{ .arena = arena };
    try std.testing.expect(!skinDrawsBoard(&skin));
    skin.objects = &objects;
    try std.testing.expect(skinDrawsBoard(&skin));
    try std.testing.expect(!skinShowsTarget(&skin));
    objects[0].ref = 121;
    try std.testing.expect(skinShowsTarget(&skin));
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

test "the versus screen needs a sign-in, and its lounge goes back to song select" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.ir_token = "";
    openScreen(a);
    try std.testing.expectEqual(.select, a.scene);
    a.cfg.ir_url = "http://127.0.0.1:1";
    a.cfg.ir_token = "t";
    openScreen(a);
    try std.testing.expectEqual(.versus, a.scene);
    key(a, c.SDL_SCANCODE_DOWN);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expect(a.versus.joining and a.text_active);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(!a.versus.joining and a.versus.join_row);
    try std.testing.expectEqual(.versus, a.scene);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expectEqual(.select, a.scene);
}

test "a pad leaves the lounge, and a room code keeps the letters bound to it" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.beatoraja_select = true;
    a.scene = .versus;
    a.versus.joining = true;
    try std.testing.expect(!select.pad(a, a.cfg.p1[1], true, false));
    try std.testing.expect(a.versus.joining);
    a.versus.joining = false;
    try std.testing.expect(select.pad(a, a.cfg.p1[1], true, false));
    try std.testing.expectEqual(.select, a.scene);
}

test "the room finds its chart, leaves for the lounge, and a finished round comes back to it" {
    const a = try testing.open();
    defer testing.close(a);
    const sha: [64]u8 = @splat('a');
    try a.db.exec(std.fmt.comptimePrint("INSERT INTO song(path,folder,sha256,md5,title,level) VALUES('/c/1.bms','/c','{s}','md5','Room','2')", .{&sha}));
    // No thread: the room is only the state the game reads.
    var r: room_mod.Room = undefined;
    r.lock = c.SDL_CreateMutex() orelse return error.NoMutex;
    defer c.SDL_DestroyMutex(r.lock);
    r.quit = .init(false);
    r.view = .{ .status = .joined, .sha256 = sha };
    a.versus.room = &r;
    defer leave(a);
    a.versus.in_round = true;
    tick(a);
    try std.testing.expectEqual(.versus, a.scene);
    try std.testing.expect(!a.versus.in_round);
    try std.testing.expectEqualStrings("/c/1.bms", a.versus.chart.?.path);
    try std.testing.expect(r.report.has_chart);
    r.view.sha256 = @splat('b');
    tick(a);
    try std.testing.expect(a.versus.chart == null);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(r.quit.load(.acquire));
    try std.testing.expect(a.versus.room == null);
    try std.testing.expectEqual(.versus, a.scene);
}

test "the host picks the room's chart on song select, and Esc there goes back to the room" {
    const a = try testing.open();
    defer testing.close(a);
    const sha: [64]u8 = @splat('c');
    try a.db.exec(std.fmt.comptimePrint("INSERT INTO song(path,folder,sha256,md5,title,level) VALUES('/c/1.bms','/c','{s}','md5','Picked','2')", .{&sha}));
    var r: room_mod.Room = undefined;
    r.gpa = std.testing.allocator;
    r.lock = c.SDL_CreateMutex() orelse return error.NoMutex;
    defer c.SDL_DestroyMutex(r.lock);
    r.quit = .init(false);
    r.want_sha = null;
    r.want_title = &.{};
    defer r.gpa.free(r.want_title);
    r.view = .{ .status = .joined, .host = true };
    a.versus.room = &r;
    defer leave(a);
    a.scene = .versus;
    tick(a);
    key(a, c.SDL_SCANCODE_TAB);
    try std.testing.expect(a.versus.picking and a.scene == .select);
    select.key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(!a.versus.picking and a.scene == .versus and a.running);
    key(a, c.SDL_SCANCODE_TAB);
    a.sel.view = .folder;
    a.sel.folder = "/c";
    select.reload(a);
    select.key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(.versus, a.scene);
    try std.testing.expectEqualSlices(u8, &sha, &r.want_sha.?);
    try std.testing.expectEqualStrings("Picked", r.want_title);
}
