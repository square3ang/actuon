//! Settings: a flat list of editable items.
const std = @import("std");
const c = @import("c");
const config = @import("../game/config.zig");
const fs = @import("../platform/fs.zig");
const skin_mod = @import("../skin/skin.zig");
const skinslots = @import("skinslots.zig");
const Drop = @import("dropdown.zig").Drop;
const skin_sound = @import("../audio/skin_sound.zig");
const gfx = @import("gfx.zig");
const i18n = @import("i18n.zig");
const tr = i18n.tr;
const app_mod = @import("app.zig");
const select = @import("select.zig");
const db_mod = @import("../db/db.zig");
const input = @import("../input/input.zig");
const ir = @import("../net/ir.zig");
const update = @import("../net/update.zig");
const testing = @import("testing.zig");
const App = app_mod.App;

const Section = enum {
    library,
    tables,
    audio,
    display,
    timing,
    scores,
    online,
    controls,

    fn title(sec: Section) []const u8 {
        return switch (sec) {
            .library => tr("Library"),
            .tables => tr("Tables"),
            .audio => tr("Audio"),
            .display => tr("Display"),
            .timing => tr("Timing"),
            .scores => tr("Scores"),
            .online => tr("Online"),
            .controls => tr("Controls"),
        };
    }
};

// Declared in section order: the cursor walks this list.
const Item = enum {
    add_root,
    clear_roots,
    add_table,
    update_tables,
    table_list,
    volume,
    bgm_volume,
    bgm_set,
    sfx_volume,
    sound_set,
    audio_rate,
    audio_frames,
    audio_device,
    fullscreen,
    vsync,
    reflex,
    bga_upscale,
    skin,
    skin_slots,
    language,
    green,
    lift,
    hidden,
    judge_offset,
    visual_offset,
    import_beatoraja,
    import_lr2,
    ir_url,
    ir_signup,
    ir_signin,
    ir_rename,
    ir_upload,
    ir_download,
    download_url,
    update,
    input_poll,
    bind_4k,
    bind_5k,
    bind_6k,
    bind_7k,
    bind_10k,
    bind_14k,
    bind_9k,
    beatoraja_select,
    bind_start,

    fn section(it: Item) Section {
        return switch (it) {
            .add_root, .clear_roots => .library,
            .add_table, .update_tables, .table_list => .tables,
            .volume, .bgm_volume, .bgm_set, .sfx_volume, .sound_set, .audio_rate, .audio_frames, .audio_device => .audio,
            .fullscreen, .vsync, .reflex, .bga_upscale, .skin, .skin_slots, .language => .display,
            .green, .lift, .hidden, .judge_offset, .visual_offset => .timing,
            .import_beatoraja, .import_lr2 => .scores,
            .ir_url, .ir_signup, .ir_signin, .ir_rename, .ir_upload, .ir_download, .download_url, .update => .online,
            .input_poll, .bind_4k, .bind_5k, .bind_6k, .bind_7k, .bind_10k, .bind_14k, .bind_9k, .beatoraja_select, .bind_start => .controls,
        };
    }

    fn name(it: Item) []const u8 {
        return switch (it) {
            .add_root => tr("Add folder"),
            .clear_roots => tr("Remove all folders"),
            .add_table => tr("Add by address"),
            .update_tables => tr("Update all"),
            .table_list => tr("Tables"),
            .volume => tr("Master volume"),
            .bgm_volume => tr("Menu music"),
            .bgm_set => tr("Music set"),
            .sound_set => tr("Sound set"),
            .sfx_volume => tr("Menu sounds"),
            .audio_rate => tr("Sample rate"),
            .audio_frames => tr("Buffer size"),
            .audio_device => tr("Output device"),
            .fullscreen => tr("Fullscreen"),
            .vsync => tr("VSync"),
            .reflex => tr("NVIDIA Reflex"),
            .bga_upscale => tr("BGA movie upscaling (FSRCNNX)"),
            .skin => tr("Skin"),
            .skin_slots => tr("Skins per screen"),
            .language => tr("Language"),
            .green => tr("Green number"),
            .lift => tr("Lift"),
            .hidden => tr("Hidden"),
            .judge_offset => tr("Judge offset"),
            .visual_offset => tr("Visual offset"),
            .import_beatoraja => tr("Import beatoraja scores"),
            .import_lr2 => tr("Import LR2 scores"),
            .ir_url => tr("IR server"),
            .ir_signup => tr("Create IR account"),
            .ir_signin => tr("Sign in to IR"),
            .ir_rename => tr("Change IR name"),
            .ir_upload => tr("Upload my scores to IR"),
            .ir_download => tr("Download my scores from IR"),
            .download_url => tr("Download URL"),
            .update => tr("Game version"),
            .input_poll => tr("Key polling"),
            .bind_4k => tr("4 key"),
            .bind_5k => tr("5 key"),
            .bind_6k => tr("6 key"),
            .bind_7k => tr("7 key"),
            .bind_10k => tr("10 key"),
            .bind_14k => tr("14 key"),
            .bind_9k => tr("9 key (PMS)"),
            .beatoraja_select => tr("beatoraja controls"),
            .bind_start => tr("Start, Select"),
        };
    }

    fn help(it: Item) []const u8 {
        return switch (it) {
            .add_root => tr("Choose a folder. It is scanned for charts right away."),
            .clear_roots => tr("Forgets the folder list. Scores and chart files stay."),
            .add_table => tr("Paste a table's web address with Ctrl+V. It loads right away."),
            .update_tables => tr("Downloads every added table again. F8 in song select does the same."),
            .table_list => tr("Enter adds or removes the selected table. Removing keeps chart scores."),
            .volume => tr("Everything the game plays."),
            .sound_set => tr("Enter or click lists the sound sets, or picks a folder holding them. Left/Right steps through them."),
            .bgm_set => tr("Enter or click lists select and decide music, or picks a folder holding it. Left/Right steps through them."),
            .bgm_volume => tr("The loop behind song select and settings: the skin's own music if it has any."),
            .sfx_volume => tr("Cursor, confirm and result sounds."),
            .audio_rate => tr("Takes effect after a restart."),
            .audio_frames => tr("Smaller is lower latency, too small crackles. Takes effect after a restart."),
            .audio_device => tr("Falls back to Default if it will not open. Applies when you leave settings."),
            .fullscreen => tr("Applies at once."),
            .vsync => tr("Applies at once. Off lowers input latency and may tear."),
            .bga_upscale => tr("Cleaner, sharper movies when they are enlarged, for a little CPU and GPU time per movie frame. Applies to the next chart for deblocking."),
            .reflex => tr("NVIDIA GPUs only. Boost holds GPU clocks high and uses more power."),
            .skin_slots => tr("Enter picks a skin and its settings for each screen and key mode. The rest use the skin above."),
            .language => tr("The game's language. Applies at once."),
            .skin => tr("Enter or click lists the skins folder, or picks a skin elsewhere. Left/Right steps through them."),
            .green => tr("How long notes stay visible: higher is slower. Enter to type a number, 30 to 2000."),
            .lift => tr("Raises the judge line. Home and End change it during play."),
            .hidden => tr("Hides notes just above the judge line. Insert and Delete change it during play."),
            .judge_offset => tr("Positive forgives a player who hits late."),
            .visual_offset => tr("Moves the notes without moving the judgement."),
            .import_beatoraja => tr("Choose score.db. Note: judging differs from beatoraja, so lr2oraja scores are recommended."),
            .import_lr2 => tr("Choose the LR2 score database."),
            .ir_url => tr("Base address of the internet ranking server."),
            .ir_signup => tr("Makes an account on that server and signs in. Asks for a name, then a password."),
            .ir_signin => tr("Signs in to an account you already have on that server."),
            .ir_rename => tr("Changes the name shown in rankings. You then sign in with the new name. Scores stay."),
            .ir_upload => tr("Sends saved replays the server does not have yet. Scores without a replay, like imported ones, rank as unverified."),
            .ir_download => tr("Merges your scores on the server into this library. Better local scores stay."),
            .download_url => tr("Where missing charts come from: an archive or a lookup service. {md5} becomes the chart's hash."),
            .update => tr("Checks GitHub at launch. Enter installs a new version for the next launch, or opens its page where the game cannot replace itself. Settings and scores stay."),
            .input_poll => tr("Key checks per second during play. Higher takes more CPU. Event uses OS key events. macOS always does."),
            .bind_5k, .bind_10k => tr("Enter, then press each input in turn: 5 keys, scratch A, scratch B, per side."),
            .bind_7k, .bind_14k => tr("Enter, then press each input in turn: 7 keys, scratch A, scratch B, per side."),
            .bind_4k => tr("Enter, then press each of the 4 keys in turn."),
            .bind_6k => tr("Enter, then press each of the 6 keys in turn."),
            .bind_9k => tr("Enter, then press each of the 9 buttons in turn."),
            .beatoraja_select => tr("Song select, result and play take the 7 key inputs and Start, Select as in beatoraja, on keyboard or controller."),
            .bind_start => tr("Enter, then press Start, then Select. They open option panels in song select and change speed in play."),
        };
    }
};

pub const State = struct {
    cursor: usize = 0,
    editing: ?Item = null,
    message: []const u8 = "",
    message_buf: [512]u8 = undefined,
    /// Which button of which bind group is being captured.
    capture_slot: ?u8 = null,
    capture_group: Item = .bind_7k,
    capture_buf: [128]u8 = undefined,
    /// False while choosing a tab; true once inside one.
    inside: bool = false,
    table_row: usize = 0,
    table_first: usize = 0,
    /// A native dialog is open. Its callback may run on another thread and only fills these.
    picker_for: ?Item = null,
    picker_state: std.atomic.Value(u8) = .init(picker_idle),
    picker_buf: [4096]u8 = undefined,
    picker_len: usize = 0,
    drop: Drop = .{},
    drop_for: Item = .skin,
    drop_values: []const []const u8 = &.{},
    sync: ?*ir.Sync = null,
    account: ?*ir.Account = null,
    /// Set once the name is typed: the row then takes the password.
    account_name: ?[]const u8 = null,
    update: ?*update.Job = null,
    update_seen: update.Phase = .checking,
};

const items = std.enums.values(Item);
const poll_rates = [_]u32{ 0, 1000, 2000, 4000, 8000 };

/// A rate typed into config.json shows as the nearest choice at or below it.
fn pollIndex(hz: u32) usize {
    var best: usize = 0;
    for (poll_rates, 0..) |r, i| {
        if (r <= hz) best = i;
    }
    return best;
}

const picker_idle = 0;
const picker_open = 1;
const picker_chosen = 2;
const picker_cancelled = 3;
const picker_failed = 4;

fn pickerDone(ud: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    const s: *State = @ptrCast(@alignCast(ud));
    if (files == null) return s.picker_state.store(picker_failed, .release);
    if (files[0] == null) return s.picker_state.store(picker_cancelled, .release);
    const path = std.mem.span(files[0]);
    if (path.len > s.picker_buf.len) return s.picker_state.store(picker_failed, .release);
    @memcpy(s.picker_buf[0..path.len], path);
    s.picker_len = path.len;
    s.picker_state.store(picker_chosen, .release);
}

// SDL reads the names until the dialog closes, so they live here, filled as it opens.
var db_filter = [_]c.SDL_DialogFileFilter{
    .{ .name = null, .pattern = "db;sqlite;sqlite3" },
    .{ .name = null, .pattern = "*" },
};

fn usesPicker(it: Item) bool {
    return it == .add_root or it == .import_beatoraja or it == .import_lr2 or it == .skin or it == .bgm_set or it == .sound_set;
}

fn openPicker(a: *App, it: Item) void {
    const s = &a.set;
    if (s.picker_for != null) return;
    s.picker_for = it;
    s.picker_state.store(picker_open, .release);
    switch (it) {
        .add_root, .bgm_set, .sound_set => c.SDL_ShowOpenFolderDialog(pickerDone, s, a.g.win, null, false),
        .import_beatoraja, .import_lr2 => {
            db_filter[0].name = tr("Score database").ptr;
            db_filter[1].name = tr("All files").ptr;
            c.SDL_ShowOpenFileDialog(pickerDone, s, a.g.win, &db_filter, db_filter.len, null, false);
        },
        else => c.SDL_ShowOpenFileDialog(pickerDone, s, a.g.win, null, 0, null, false),
    }
}

/// Without a dialog service (no portal or zenity) the path can still be typed.
fn pollPicker(a: *App) void {
    const s = &a.set;
    const it = s.picker_for orelse return;
    const state = s.picker_state.load(.acquire);
    if (state == picker_open) return;
    s.picker_for = null;
    s.picker_state.store(picker_idle, .release);
    switch (state) {
        picker_chosen => {
            a.text.clearRetainingCapacity();
            a.text.appendSlice(a.gpa, s.picker_buf[0..s.picker_len]) catch return;
            commit(a, it);
            a.text.clearRetainingCapacity();
        },
        picker_failed => {
            say(a, "No file dialog available: type the path", .{});
            startEditing(a, it);
        },
        else => {},
    }
}

fn startSync(a: *App, upload: bool) void {
    if (a.set.sync != null) return;
    if (a.cfg.ir_url.len == 0 or a.cfg.ir_token.len == 0) return say(a, "Sign in to an IR server first", .{});
    a.set.sync = ir.startSync(a.gpa, a.cfg.ir_url, a.cfg.ir_token, upload);
    if (a.set.sync == null) say(a, "Could not start IR sync", .{});
}

fn pollSync(a: *App) void {
    const s = a.set.sync orelse return;
    if (!s.done.load(.acquire)) {
        const total = s.total.load(.acquire);
        if (total > 0) return say(a, "Uploading {d} of {d}...", .{ s.progress.load(.acquire), total });
        return say(a, "Talking to the IR server...", .{});
    }
    if (s.err) |e| {
        say(a, "IR sync failed: {t}", .{e});
    } else if (s.upload) {
        say(a, "Uploaded {d} replays, {d} unverified scores, {d} failed", .{ s.accepted, s.claimed, s.failed });
    } else {
        say(a, "Downloaded {d} scores", .{s.accepted});
        select.reload(a);
    }
    s.destroy();
    a.set.sync = null;
}

/// Runs in every scene, so song select can announce a release.
pub fn pollUpdate(a: *App) void {
    const j = a.set.update orelse return;
    const phase = j.phase.load(.acquire);
    if (phase == a.set.update_seen) return;
    a.set.update_seen = phase;
    switch (phase) {
        .available => a.sel.status = i18n.bufPrint(&a.sel.status_buf, "actuon {s} is out: see Settings, Online", .{j.release.?.version}) catch "",
        .installed => say(a, "Updated to {s}. Restart to use it.", .{j.release.?.version}),
        .failed => say(a, "Update failed: {t}", .{j.err}),
        .checking, .current, .installing => {},
    }
}

fn updateLabel(a: *App, buf: []u8) []const u8 {
    const j = a.set.update orelse return update.current_version;
    return switch (j.phase.load(.acquire)) {
        .checking => tr("Checking..."),
        .current => i18n.bufPrint(buf, "{s} (latest)", .{update.current_version}) catch "",
        .available => i18n.bufPrint(buf, "{s}, {s} available", .{ update.current_version, j.release.?.version }) catch "",
        .installing => blk: {
            const total = j.progress.total.load(.acquire);
            if (total == 0) break :blk tr("Downloading...");
            break :blk i18n.bufPrint(buf, "Downloading {d}%", .{j.progress.done.load(.acquire) * 100 / total}) catch "";
        },
        .installed => tr("Restart to use the new version"),
        .failed => i18n.bufPrint(buf, "{s}, update failed", .{update.current_version}) catch "",
    };
}

fn activateUpdate(a: *App) void {
    const j = a.set.update orelse {
        a.set.update = update.start(a.gpa);
        return;
    };
    switch (j.phase.load(.acquire)) {
        .checking, .installing, .installed => {},
        .current, .failed => j.check(),
        .available => {
            if (j.canInstall()) return j.install();
            if (!c.SDL_OpenURL(update.releases_page)) say(a, "Could not open the browser", .{});
        },
    }
}

fn startAccount(a: *App, it: Item) void {
    if (a.set.account != null) return;
    if (!isWebUrl(a.cfg.ir_url)) return say(a, "Set an IR server first, like https://ir.actuon.app", .{});
    if (it == .ir_rename and a.cfg.ir_token.len == 0) return say(a, "Sign in to an IR server first", .{});
    startEditing(a, it);
}

fn sendAccount(a: *App, name: []const u8, register: bool) void {
    a.set.account = ir.startAccount(a.gpa, a.cfg.ir_url, name, a.text.items, if (register) .register else .login);
    a.text.clearRetainingCapacity();
    if (a.set.account == null) say(a, "Could not reach the IR server", .{});
}

fn pollAccount(a: *App) void {
    const s = a.set.account orelse return;
    if (!s.done.load(.acquire)) return say(a, "Talking to the IR server...", .{});
    if (s.err) |e| {
        say(a, "Could not reach the IR server: {t}", .{e});
    } else if (s.token) |token| {
        if (a.arena.allocator().dupe(u8, token)) |kept| {
            a.cfg.ir_token = kept;
            a.saveConfig();
            select.dropBoard(a);
            say(a, "Signed in as {s}", .{s.name});
        } else |_| say(a, "Out of memory, not signed in", .{});
    } else if (s.action == .rename and s.status == 200) {
        say(a, "Your IR name is now {s}", .{s.name});
    } else {
        say(a, "{s}", .{ir.accountRefusal(s.status, s.action)});
    }
    s.destroy();
    a.set.account = null;
}

fn startEditing(a: *App, it: Item) void {
    a.set.editing = it;
    var green_buf: [16]u8 = undefined;
    a.startText(switch (it) {
        .ir_url => a.cfg.ir_url,
        .download_url => a.cfg.download_url,
        .skin => a.cfg.skin,
        .bgm_set => a.cfg.bgm_root,
        .sound_set => a.cfg.sound_root,
        .green => std.fmt.bufPrint(&green_buf, "{d}", .{greenShown(a.cfg.green_ms)}) catch "",
        else => "",
    });
}

/// beatoraja's key config key lands here.
pub fn openControls(a: *App) void {
    a.set.cursor = firstOf(.controls);
    a.set.inside = true;
    a.scene = .settings;
}

fn firstOf(sec: Section) usize {
    for (items, 0..) |it, i| if (it.section() == sec) return i;
    return 0;
}

fn bindsOf(a: *App, it: Item) []u16 {
    if (it == .bind_start) return &a.cfg.start_select;
    return config.keysOf(&a.cfg, switch (it) {
        .bind_4k => .beat4,
        .bind_5k => .beat5,
        .bind_6k => .beat6,
        .bind_10k => .beat10,
        .bind_14k => .beat14,
        .bind_9k => .popn9,
        else => .beat7,
    });
}

pub fn keyName(code: u16, buf: []u8) []const u8 {
    if (code >= input.joy_base) return std.fmt.bufPrint(buf, "Pad {d}", .{code - input.joy_base}) catch "";
    const name = std.mem.span(c.SDL_GetScancodeName(code));
    return if (name.len > 0) name else "-";
}

/// Returns the value the mouse is dragging it to.
fn drawSlider(g: *gfx.Gfx, right: f32, y: f32, h: f32, v: f32, on: bool) ?f32 {
    const u = g.h / 720;
    const w = 220 * u;
    const x = right - w - 56 * u;
    const th = 6 * u;
    const ty = y + (h - th) / 2;
    g.round(x, ty, w, th, 3 * u, if (on) gfx.white.alpha(70) else gfx.rule);
    g.round(x, ty, @max(w * v, th), th, 3 * u, if (on) gfx.white else gfx.accent);
    g.disc(x + w * v, y + h / 2, 8 * u, gfx.white);
    var buf: [8]u8 = undefined;
    g.textRight(std.fmt.bufPrint(&buf, "{d:.0}%", .{v * 100}) catch "", right, y + (h - 22 * u) / 2, g.scaled(16), gfx.white);
    if (!g.down or !g.hit(x - 10 * u, y, w + 20 * u, h)) return null;
    g.clicked = false;
    return @round(std.math.clamp((g.mx - x) / w, 0, 1) * 20) / 20;
}

fn drawToggle(g: *gfx.Gfx, right: f32, y: f32, h: f32, v: bool, on: bool) void {
    const u = g.h / 720;
    const w = 48 * u;
    const th = 26 * u;
    const ty = y + (h - th) / 2;
    const fill = if (v) (if (on) gfx.white else gfx.accent) else (if (on) gfx.white.alpha(70) else gfx.rule);
    g.round(right - w, ty, w, th, th / 2, fill);
    const knob = if (v and on) gfx.accent else gfx.white;
    g.disc(if (v) right - th / 2 else right - w + th / 2, ty + th / 2, 9 * u, knob);
}

fn drawChoices(g: *gfx.Gfx, right: f32, y: f32, h: f32, names: []const []const u8, picked: usize, on: bool) ?usize {
    var chosen: ?usize = null;
    const u = g.h / 720;
    const cell = 92 * u;
    const ch = 30 * u;
    const x0 = right - cell * @as(f32, @floatFromInt(names.len));
    const cy = y + (h - ch) / 2;
    g.round(x0, cy, right - x0, ch, 8 * u, if (on) gfx.white.alpha(50) else gfx.well);
    for (names, 0..) |n, i| {
        const x = x0 + cell * @as(f32, @floatFromInt(i));
        if (g.clickIn(x, cy, cell, ch)) chosen = i;
        if (i == picked) g.round(x, cy, cell, ch, 8 * u, if (on) gfx.white else gfx.accent);
        g.textCentered(n, x + cell / 2, cy + 5 * u, g.scaled(14), if (i != picked) gfx.dim else if (on) gfx.accent else gfx.white);
    }
    return chosen;
}

/// The current value of a row that lists its choices; clicking it opens the list.
fn drawDropValue(a: *App, it: Item, x: f32, right: f32, y: f32, h: f32, value: []const u8, on: bool) void {
    const g = &a.g;
    const u = g.h / 720;
    const ty = y + (h - 22 * u) / 2;
    const w = @min(g.measure(value, g.scaled(16)), right - x - 330 * u);
    g.textRight("v", right, ty, g.scaled(16), if (on) gfx.white else gfx.dim);
    g.textClip(value, right - 30 * u - w, ty, w, g.scaled(16), gfx.white);
    if (a.set.drop.open and a.set.drop_for == it) a.set.drop.anchor(y, h, right);
    if (g.clickIn(right - 38 * u - w, y, w + 46 * u, h)) openDrop(a, it);
}

fn hasDrop(it: Item) bool {
    return it == .audio_frames or it == .audio_device or it == .skin or it == .bgm_set or it == .sound_set;
}

fn openDrop(a: *App, it: Item) void {
    const s = &a.set;
    if (s.picker_for != null) return;
    // shortcut: lists stay in the app arena until exit, free them if settings ever stays open for long.
    const al = a.arena.allocator();
    var labels: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const u8) = .empty;
    var now: []const u8 = "";
    var last: ?[]const u8 = null;
    fill: switch (it) {
        .audio_frames => {
            now = std.fmt.allocPrint(al, "{d}", .{a.cfg.audio_frames}) catch return;
            var frames_buf: [32]u8 = undefined;
            for ([_]u32{ 32, 64, 128, 256, 512, 1024, 2048, 4096 }) |n| {
                labels.append(al, al.dupe(u8, i18n.bufPrint(&frames_buf, "{d} frames", .{n}) catch return) catch return) catch return;
                values.append(al, std.fmt.allocPrint(al, "{d}", .{n}) catch return) catch return;
            }
        },
        .audio_device => {
            now = a.cfg.audio_device;
            labels.append(al, tr("Default")) catch return;
            values.append(al, "") catch return;
            for (a.engine.outputDevices(al)) |n| {
                labels.append(al, n) catch return;
                values.append(al, n) catch return;
            }
        },
        .skin => {
            now = a.cfg.skin;
            last = tr("Pick a skin elsewhere...");
            labels.append(al, tr("Built-in")) catch return;
            values.append(al, "") catch return;
            const root = skin_mod.skinsDir(al) catch break :fill;
            fs.mkdirs(root) catch {};
            for (skin_mod.listSkins(al, root) catch break :fill) |n| {
                labels.append(al, n) catch return;
                values.append(al, std.fs.path.join(al, &.{ root, n }) catch return) catch return;
            }
        },
        .bgm_set, .sound_set => {
            now = if (it == .bgm_set) a.cfg.bgm_path else a.cfg.sound_path;
            last = tr("Pick a folder...");
            labels.append(al, tr("From the skin")) catch return;
            values.append(al, "") catch return;
            const sets = if (it == .bgm_set) skin_sound.musicSets(al, a.cfg.bgm_root) else skin_sound.soundSets(al, a.cfg.sound_root);
            for (sets) |set| {
                labels.append(al, std.fmt.allocPrint(al, "{s}/{s}", .{ std.fs.path.basename(std.fs.path.dirname(set) orelse ""), std.fs.path.basename(set) }) catch return) catch return;
                values.append(al, set) catch return;
            }
        },
        else => return,
    }
    var cursor: usize = 0;
    for (values.items, 0..) |v, i| {
        if (std.mem.eql(u8, v, now)) cursor = i;
    }
    if (last) |l| labels.append(al, l) catch return;
    s.drop_values = values.items;
    s.drop_for = it;
    s.drop.show(&a.g, labels.items, cursor);
}

/// Takes the row's value; the entry past the values is the dialog.
fn chooseDrop(a: *App, i: usize) void {
    const s = &a.set;
    const it = s.drop_for;
    if (i >= s.drop_values.len) return openPicker(a, it);
    const v = s.drop_values[i];
    switch (it) {
        .audio_frames => a.cfg.audio_frames = std.fmt.parseInt(u32, v, 10) catch return,
        .audio_device => {
            a.cfg.audio_device = v;
            say(a, "{s}", .{if (v.len > 0) v else tr("Default")});
        },
        .skin => a.cfg.skin = v,
        .bgm_set, .sound_set => {
            if (it == .bgm_set) a.cfg.bgm_path = v else a.cfg.sound_path = v;
            a.refreshBgm();
            if (v.len > 0) say(a, "Set picked. A long song takes a moment to load before it plays.", .{});
        },
        else => {},
    }
    a.saveConfig();
}

fn drawStepper(g: *gfx.Gfx, right: f32, y: f32, h: f32, value: []const u8, on: bool) i32 {
    const u = g.h / 720;
    const ty = y + (h - 22 * u) / 2;
    const col = if (on) gfx.white else gfx.dim;
    g.textRight(">", right, ty, g.scaled(16), col);
    g.textCentered(value, right - 80 * u, ty, g.scaled(16), gfx.white);
    g.textRight("<", right - 150 * u, ty, g.scaled(16), col);
    const box = 36 * u;
    if (g.clickIn(right - 150 * u - box + 8 * u, y, box, h)) return -1;
    if (g.clickIn(right - box + 8 * u, y, box, h)) return 1;
    return 0;
}

fn drawKeys(a: *App, it: Item, right: f32, y: f32, h: f32, on: bool) void {
    const g = &a.g;
    const u = g.h / 720;
    const size = g.scaled(12);
    const bh = 26 * u;
    const by = y + (h - bh) / 2;
    const capturing = a.set.capture_slot != null and a.set.capture_group == it;
    const binds = bindsOf(a, it);
    var x = right;
    var i: usize = binds.len;
    while (i > 0) {
        i -= 1;
        var buf: [16]u8 = undefined;
        const name = keyName(binds[i], &buf);
        const bw = @max(g.measure(name, size) + 14 * u, 30 * u);
        x -= bw;
        const hot = capturing and a.set.capture_slot.? == i;
        g.round(x, by, bw, bh, 5 * u, if (hot) gfx.white else if (on) gfx.white.alpha(50) else gfx.well);
        g.textCentered(name, x + bw / 2, by + 6 * u, size, if (hot) gfx.accent else gfx.white);
        x -= 4 * u;
    }
}

fn drawValue(a: *App, it: Item, x: f32, right: f32, y: f32, h: f32, on: bool) void {
    const g = &a.g;
    const cfg = &a.cfg;
    const u = g.h / 720;
    var buf: [64]u8 = undefined;
    const text_y = y + (h - 22 * u) / 2;
    if (a.set.editing == it) {
        const fx = x + 260 * u;
        const fh = 30 * u;
        g.round(fx, y + (h - fh) / 2, right - fx, fh, 6 * u, gfx.well);
        switch (it) {
            .ir_rename => g.fmtTr(fx + 10 * u, text_y, g.scaled(16), gfx.white, "New name: {s}_", .{a.text.items}),
            .ir_signup, .ir_signin => if (a.set.account_name == null) {
                g.fmtTr(fx + 10 * u, text_y, g.scaled(16), gfx.white, "Name: {s}_", .{a.text.items});
            } else {
                const stars: [64]u8 = @splat('*');
                g.fmtTr(fx + 10 * u, text_y, g.scaled(16), gfx.white, "Password: {s}_", .{stars[0..@min(a.text.items.len, stars.len)]});
            },
            else => g.fmt(fx + 10 * u, text_y, g.scaled(16), gfx.white, "{s}_", .{a.text.items}),
        }
        if (it == .green) {
            if (std.fmt.parseInt(u32, a.text.items, 10)) |shown| {
                g.textRight(std.fmt.bufPrint(&buf, "{d} ms", .{greenMs(shown)}) catch "", right - 10 * u, text_y + 2 * u, g.scaled(12), gfx.dim);
            } else |_| {}
        }
        return;
    }
    const step = struct {
        fn f(aa: *App, target: Item, dir: i32) void {
            if (dir == 0) return;
            aa.sfx(.adjust);
            adjust(aa, target, dir);
        }
    }.f;
    switch (it) {
        .volume => if (drawSlider(g, right, y, h, cfg.volume, on)) |v| {
            cfg.volume = v;
            a.engine.gain = v;
        },
        .bgm_volume => if (drawSlider(g, right, y, h, cfg.bgm_volume, on)) |v| {
            cfg.bgm_volume = v;
            if (a.bgm_on) a.engine.uiGain(a.bgm_slot, v);
        },
        .sfx_volume => if (drawSlider(g, right, y, h, cfg.sfx_volume, on)) |v| {
            cfg.sfx_volume = v;
        },
        .fullscreen => drawToggle(g, right, y, h, cfg.fullscreen, on),
        .bga_upscale => drawToggle(g, right, y, h, cfg.bga_upscale, on),
        .beatoraja_select => drawToggle(g, right, y, h, cfg.beatoraja_select, on),
        .vsync => if (drawChoices(g, right, y, h, &.{ tr("Off"), tr("On"), tr("Adaptive") }, if (cfg.vsync == 0) 0 else if (cfg.vsync == 1) 1 else 2, on)) |i| {
            a.sfx(.adjust);
            cfg.vsync = switch (i) {
                0 => 0,
                1 => 1,
                else => -1,
            };
            g.setVsync(cfg.vsync);
        },
        .reflex => if (drawChoices(g, right, y, h, &.{ tr("Off"), tr("On"), tr("On + Boost") }, @intCast(std.math.clamp(cfg.reflex, 0, 2)), on)) |i| {
            a.sfx(.adjust);
            cfg.reflex = @intCast(i);
            g.setReflex(cfg.reflex);
        },
        .language => if (drawChoices(g, right, y, h, &i18n.names, @backingInt(i18n.current), on)) |i| {
            a.sfx(.adjust);
            setLanguage(a, @fromBackingInt(@intCast(i)));
        },
        .input_poll => if (drawChoices(g, right, y, h, &.{ tr("Event"), "1000", "2000", "4000", "8000" }, pollIndex(cfg.input_poll_hz), on)) |i| {
            a.sfx(.adjust);
            cfg.input_poll_hz = poll_rates[i];
        },
        .audio_rate => if (drawChoices(g, right, y, h, &.{ "44100", "48000" }, if (cfg.audio_rate == 44100) 0 else 1, on)) |i| {
            a.sfx(.adjust);
            cfg.audio_rate = if (i == 0) 44100 else 48000;
        },
        .audio_frames => drawDropValue(a, it, x, right, y, h, i18n.bufPrint(&buf, "{d} frames", .{cfg.audio_frames}) catch "", on),
        .green => {
            step(a, it, drawStepper(g, right, y, h, std.fmt.bufPrint(&buf, "{d}", .{greenShown(cfg.green_ms)}) catch "", on));
            g.textCentered(std.fmt.bufPrint(&buf, "{d} ms", .{cfg.green_ms}) catch "", right - 80 * u, y + h - 17 * u, g.scaled(12), if (on) gfx.white else gfx.dim);
        },
        .bgm_set, .sound_set => {
            const path = if (it == .bgm_set) cfg.bgm_path else cfg.sound_path;
            var name_buf: [512]u8 = undefined;
            const name = if (path.len > 0) std.fmt.bufPrint(&name_buf, "{s}/{s}", .{ std.fs.path.basename(std.fs.path.dirname(path) orelse ""), std.fs.path.basename(path) }) catch std.fs.path.basename(path) else tr("From the skin");
            drawDropValue(a, it, x, right, y, h, name, on);
        },
        .skin, .audio_device => {
            const name = if (it == .audio_device) deviceLabel(cfg.audio_device) else if (cfg.skin.len > 0) std.fs.path.basename(cfg.skin) else tr("Built-in");
            drawDropValue(a, it, x, right, y, h, name, on);
        },
        .lift => step(a, it, drawStepper(g, right, y, h, std.fmt.bufPrint(&buf, "{d}%", .{@as(u32, @intFromFloat(@round(cfg.lift * 100)))}) catch "", on)),
        .hidden => step(a, it, drawStepper(g, right, y, h, std.fmt.bufPrint(&buf, "{d}%", .{@as(u32, @intFromFloat(@round(cfg.hidden * 100)))}) catch "", on)),
        .judge_offset => step(a, it, drawStepper(g, right, y, h, std.fmt.bufPrint(&buf, "{d} ms", .{cfg.judge_offset_ms}) catch "", on)),
        .visual_offset => step(a, it, drawStepper(g, right, y, h, std.fmt.bufPrint(&buf, "{d} ms", .{cfg.visual_offset_ms}) catch "", on)),
        .bind_4k, .bind_5k, .bind_6k, .bind_7k, .bind_10k, .bind_14k, .bind_9k, .bind_start => drawKeys(a, it, right, y, h, on),
        else => {
            const value = switch (it) {
                .add_root => i18n.bufPrint(&buf, "{d} configured", .{cfg.roots.len}) catch "",
                .add_table => i18n.bufPrint(&buf, "{d} added", .{cfg.tables.len}) catch "",
                .ir_url => if (cfg.ir_url.len > 0) cfg.ir_url else tr("Not set"),
                .ir_signin => if (cfg.ir_token.len > 0) tr("Signed in") else tr("Not signed in"),
                .download_url => cfg.download_url,
                .update => updateLabel(a, &buf),
                else => "",
            };
            const col = if (on) gfx.white else gfx.dim;
            const fx = x + 260 * u;
            const size = g.scaled(14);
            if (g.measure(value, size) > right - fx) {
                g.textClip(value, fx, text_y + 1 * u, right - fx, size, col);
            } else g.textRight(value, right, text_y + 1 * u, size, col);
        },
    }
}

/// Tabs down the left. A tab is picked first, then entered to reach its items.
fn drawNav(a: *App, current: Section, nav_w: f32) void {
    const g = &a.g;
    const s = &a.set;
    const u = g.h / 720;
    _ = g.text(tr("Settings"), 22 * u, 18 * u, g.scaled(32), gfx.white);
    var sy = 76 * u;
    for (std.enums.values(Section)) |sec| {
        const here = sec == current;
        const hover = g.hit(14 * u, sy, nav_w, 38 * u);
        if (g.clickIn(14 * u, sy, nav_w, 38 * u)) {
            a.sfx(.confirm);
            s.cursor = firstOf(sec);
            s.inside = true;
        }
        if (here and !s.inside) {
            g.round(14 * u, sy, nav_w, 38 * u, 8 * u, gfx.accent);
        } else if (here or hover) g.round(14 * u, sy, nav_w, 38 * u, 8 * u, gfx.plate);
        _ = g.text(sec.title(), 30 * u, sy + 8 * u, g.scaled(16), if (here or hover) gfx.white else gfx.dim);
        sy += 42 * u;
    }
}

fn drawRows(a: *App, current: Section, px: f32, pw: f32, help_y: f32) void {
    const g = &a.g;
    const s = &a.set;
    const u = g.h / 720;
    g.panel(px, 18 * u, pw, help_y - 26 * u, "");
    _ = g.text(current.title(), px + 18 * u, 28 * u, g.scaled(24), if (s.inside) gfx.white else gfx.dim);
    var y = 72 * u;
    const row_h = 54 * u;
    for (items, 0..) |it, i| {
        if (it.section() != current) continue;
        if (it == .table_list) {
            drawTableList(a, i, px + 8 * u, pw - 16 * u, y, help_y - 12 * u);
            continue;
        }
        const on = s.inside and i == s.cursor;
        const rx = px + 8 * u;
        const rw = pw - 16 * u;
        const rh = row_h - 4 * u;
        const hover = g.hit(rx, y, rw, rh);
        if (on) {
            g.round(rx, y, rw, rh, 8 * u, gfx.accent);
        } else if (hover) g.round(rx, y, rw, rh, 8 * u, gfx.rule);
        _ = g.text(it.name(), rx + 12 * u, y + (rh - 22 * u) / 2, g.scaled(16), if (s.inside or hover) gfx.white else gfx.dim);
        if (s.capture_slot == null and s.editing == null) {
            // Controls take their own clicks first; anywhere else on the row selects it.
            const clicked_before = g.clicked and hover;
            drawValue(a, it, rx + 12 * u, rx + rw - 14 * u, y, rh, on);
            if (clicked_before) {
                s.cursor = i;
                s.inside = true;
                if (g.clicked) {
                    g.clicked = false;
                    if (clickActs(on, it)) a.click_key = c.SDL_SCANCODE_RETURN else a.sfx(.move);
                }
            }
        } else drawValue(a, it, rx + 12 * u, rx + rw - 14 * u, y, rh, on);
        y += row_h;
    }
}

fn drawHelp(a: *App, px: f32, pw: f32, help_y: f32, help_h: f32) void {
    const g = &a.g;
    const s = &a.set;
    const u = g.h / 720;
    g.panel(px, help_y, pw, help_h, "");
    const help = if (s.picker_for != null)
        tr("Waiting for the file dialog...")
    else if (s.capture_slot) |slot|
        i18n.bufPrint(&s.capture_buf, "Press the input for button {d} of {d}. Esc cancels.", .{ slot + 1, bindsOf(a, s.capture_group).len }) catch ""
    else if (s.inside)
        items[s.cursor].help()
    else
        tr("Enter or click to open this tab.");
    g.textClip(help, px + 18 * u, help_y + 8 * u, pw - 36 * u, g.scaled(14), gfx.sky);
    if (s.message.len > 0) g.textClip(s.message, px + 18 * u, help_y + 30 * u, pw - 36 * u, g.scaled(14), gfx.white);
    const hint = if (s.inside) tr("Up/Down select    Left/Right change    Enter edit    Esc or right click back") else tr("Up/Down choose a tab    Enter open    Esc or right click leave");
    _ = g.text(hint, px, g.h - 26 * u, g.scaled(12), gfx.dim);
}

pub fn draw(a: *App) void {
    const g = &a.g;
    const s = &a.set;
    const u = g.h / 720;
    pollPicker(a);
    pollSync(a);
    pollAccount(a);
    if (select.tickTables(a)) say(a, "{s}", .{a.sel.status});
    const current = items[s.cursor].section();
    const drop_click = s.drop.open and g.clicked;
    if (drop_click) g.clicked = false;
    const nav_w = 196 * u;
    drawNav(a, current, nav_w);
    const px = 14 * u + nav_w + 14 * u;
    const pw = g.w - px - 14 * u;
    const help_h = 56 * u;
    const help_y = g.h - 34 * u - help_h;
    drawRows(a, current, px, pw, help_y);
    drawHelp(a, px, pw, help_y, help_h);
    if (s.drop.open) {
        if (s.drop.draw(a, drop_click)) |i| chooseDrop(a, i);
    }
}

/// Rows where a click on the row itself does what Enter does.
fn rowActs(it: Item) bool {
    return switch (it) {
        // Lists open from their value or with Enter, not from anywhere on the row.
        .volume, .bgm_volume, .sfx_volume, .audio_rate, .audio_frames, .audio_device, .vsync, .reflex, .language, .input_poll, .lift, .hidden, .judge_offset, .visual_offset, .skin, .bgm_set, .sound_set => false,
        else => true,
    };
}

/// A first click only selects a row; a click on the selected one acts on it.
fn clickActs(selected: bool, it: Item) bool {
    return selected and rowActs(it);
}

fn adjust(a: *App, it: Item, dir: i32) void {
    const cfg = &a.cfg;
    switch (it) {
        .audio_rate => cfg.audio_rate = if (cfg.audio_rate == 48000) 44100 else 48000,
        .audio_frames => {
            const v = @as(i64, cfg.audio_frames) + 32 * @as(i64, dir);
            cfg.audio_frames = @intCast(std.math.clamp(v, 32, 4096));
        },
        .audio_device => cycleDevice(a, dir),
        .volume => {
            cfg.volume = std.math.clamp(cfg.volume + 0.05 * @as(f32, @floatFromInt(dir)), 0, 1);
            a.engine.gain = cfg.volume;
        },
        .bgm_volume => {
            cfg.bgm_volume = std.math.clamp(cfg.bgm_volume + 0.05 * @as(f32, @floatFromInt(dir)), 0, 1);
            if (a.bgm_on) a.engine.uiGain(a.bgm_slot, cfg.bgm_volume);
        },
        .sfx_volume => cfg.sfx_volume = std.math.clamp(cfg.sfx_volume + 0.05 * @as(f32, @floatFromInt(dir)), 0, 1),
        .vsync => {
            cfg.vsync = if (cfg.vsync == 1) 0 else if (cfg.vsync == 0) -1 else 1;
            a.g.setVsync(cfg.vsync);
        },
        .reflex => {
            cfg.reflex = @mod(cfg.reflex + dir, 3);
            a.g.setReflex(cfg.reflex);
        },
        .language => setLanguage(a, @fromBackingInt(@intCast(@mod(@as(i32, @backingInt(i18n.current)) + dir, @as(i32, i18n.names.len))))),
        .beatoraja_select => cfg.beatoraja_select = !cfg.beatoraja_select,
        .bga_upscale => {
            cfg.bga_upscale = !cfg.bga_upscale;
            a.g.upscale_on = cfg.bga_upscale;
        },
        .fullscreen => {
            cfg.fullscreen = !cfg.fullscreen;
            _ = c.SDL_SetWindowFullscreen(a.g.win, cfg.fullscreen);
        },
        .input_poll => {
            const i = @as(i32, @intCast(pollIndex(cfg.input_poll_hz))) + dir;
            cfg.input_poll_hz = poll_rates[@intCast(std.math.clamp(i, 0, poll_rates.len - 1))];
        },
        .green => cfg.green_ms = greenMs(@intCast(@max(@as(i64, greenShown(cfg.green_ms)) + 5 * @as(i64, dir), 0))),
        .lift => cfg.setLift(cfg.lift + 0.01 * @as(f32, @floatFromInt(dir))),
        .hidden => cfg.setHidden(cfg.hidden + 0.01 * @as(f32, @floatFromInt(dir))),
        .judge_offset => cfg.judge_offset_ms += dir,
        .visual_offset => cfg.visual_offset_ms += dir,
        .skin => cycleSkin(a, dir),
        .bgm_set => cycleSet(a, &a.cfg.bgm_path, a.cfg.bgm_root, skin_sound.musicSets, dir),
        .sound_set => cycleSet(a, &a.cfg.sound_path, a.cfg.sound_root, skin_sound.soundSets, dir),
        else => {},
    }
}

/// Rows are labelled when they load, so the song list reloads with the new words.
fn setLanguage(a: *App, lang: i18n.Lang) void {
    i18n.current = lang;
    a.cfg.language = @tagName(lang);
    a.saveConfig();
    select.reload(a);
}

/// Device names run long; the end, with its hw:N,N, is what tells them apart.
fn deviceLabel(name: []const u8) []const u8 {
    if (name.len == 0) return tr("Default");
    return name[name.len - @min(name.len, 48) ..];
}

fn cycleDevice(a: *App, dir: i32) void {
    var tmp = std.heap.ArenaAllocator.init(a.gpa);
    defer tmp.deinit();
    const names = a.engine.outputDevices(tmp.allocator());
    if (names.len == 0) return say(a, "No audio outputs found", .{});
    a.cfg.audio_device = a.arena.allocator().dupe(u8, skin_sound.nextSet(a.cfg.audio_device, names, dir)) catch return;
    a.saveConfig();
    say(a, "{s}", .{if (a.cfg.audio_device.len > 0) a.cfg.audio_device else tr("Default")});
}

const SetList = *const fn (std.mem.Allocator, []const u8) []const []const u8;

fn cycleSet(a: *App, path: *[]const u8, root: []const u8, list: SetList, dir: i32) void {
    var tmp = std.heap.ArenaAllocator.init(a.gpa);
    defer tmp.deinit();
    const al = tmp.allocator();
    const sets = list(al, root);
    if (sets.len == 0) return say(a, "No sets yet: press Enter to pick a folder", .{});
    path.* = a.arena.allocator().dupe(u8, skin_sound.nextSet(path.*, sets, dir)) catch return;
    a.saveConfig();
    a.refreshBgm();
    if (path.len > 0) say(a, "Set picked. A long song takes a moment to load before it plays.", .{});
}

/// A picked folder: its first set takes effect at once.
fn pickSetRoot(a: *App, path: *[]const u8, root: *[]const u8, v: []const u8, list: SetList) void {
    root.* = v;
    var tmp = std.heap.ArenaAllocator.init(a.gpa);
    defer tmp.deinit();
    const al = tmp.allocator();
    for (list(al, v)) |set| if (std.mem.startsWith(u8, set, v)) {
        path.* = a.arena.allocator().dupe(u8, set) catch return;
        a.saveConfig();
        a.refreshBgm();
        return say(a, "Set picked. A long song takes a moment to load before it plays.", .{});
    };
    a.saveConfig();
    say(a, "No sets in that folder", .{});
}

/// Steps through Built-in and the skins folder. A skin picked from elsewhere counts as Built-in's place.
fn cycleSkin(a: *App, dir: i32) void {
    var tmp = std.heap.ArenaAllocator.init(a.gpa);
    defer tmp.deinit();
    const al = tmp.allocator();
    const root = skin_mod.skinsDir(al) catch return;
    fs.mkdirs(root) catch {};
    const names = skin_mod.listSkins(al, root) catch return;
    if (names.len == 0) return say(a, "No skins yet: put skin folders in {s}", .{root});
    var at: i64 = 0;
    for (names, 1..) |n, i| {
        if (std.mem.eql(u8, a.cfg.skin, std.fs.path.join(al, &.{ root, n }) catch return)) at = @intCast(i);
    }
    const next = @mod(at + dir, @as(i64, @intCast(names.len + 1)));
    a.cfg.skin = if (next == 0) "" else std.fs.path.join(a.arena.allocator(), &.{ root, names[@intCast(next - 1)] }) catch return;
    a.saveConfig();
}

pub fn say(a: *App, comptime f: []const u8, args: anytype) void {
    a.set.message = i18n.bufPrint(&a.set.message_buf, f, args) catch "";
}

const green_min = 30;
const green_max = 2000;

/// The number on screen is 3/5 of the stored milliseconds, the scale IIDX players know.
fn greenShown(ms: u32) u32 {
    return ms * 3 / 5;
}

/// Rounds up, so the screen shows exactly what was typed.
fn greenMs(shown: u32) u32 {
    return (std.math.clamp(shown, green_min, green_max) * 5 + 2) / 3;
}

fn isWebUrl(v: []const u8) bool {
    return std.mem.startsWith(u8, v, "http://") or std.mem.startsWith(u8, v, "https://");
}

const Preset = struct { name: []const u8, url: []const u8 };

// Each one fetched and parsed with table.fetch when it was added here.
const presets = [_]Preset{
    .{ .name = "Satellite", .url = "https://stellabms.xyz/sl/table.html" },
    .{ .name = "Stella", .url = "https://stellabms.xyz/st/table.html" },
    .{ .name = "Starlight", .url = "https://djkuroakari.github.io/starlighttable.html" },
    .{ .name = "DP Satellite", .url = "https://stellabms.xyz/dp/table.html" },
    .{ .name = "Solar", .url = "https://stellabms.xyz/so/table.html" },
    .{ .name = "New Generation Normal", .url = "https://rattoto10.jounin.jp/table.html" },
    .{ .name = "New Generation Insane", .url = "https://rattoto10.jounin.jp/table_insane.html" },
    .{ .name = "Normal (archive)", .url = "https://darksabun.club/table/archive/normal1/" },
    .{ .name = "Insane (archive)", .url = "https://darksabun.club/table/archive/insane1/" },
};

fn isPreset(url: []const u8) bool {
    for (presets) |p| {
        if (std.mem.eql(u8, p.url, url)) return true;
    }
    return false;
}

fn tableAdded(a: *App, url: []const u8) bool {
    for (a.cfg.tables) |t| {
        if (std.mem.eql(u8, t, url)) return true;
    }
    return false;
}

/// Presets first, then every other added table, named by its address.
fn tableRow(a: *App, row: usize) ?Preset {
    if (row < presets.len) return presets[row];
    var left = row - presets.len;
    for (a.cfg.tables) |t| {
        if (isPreset(t)) continue;
        if (left == 0) return .{ .name = t, .url = t };
        left -= 1;
    }
    return null;
}

fn tableRowCount(a: *App) usize {
    var n: usize = presets.len;
    for (a.cfg.tables) |t| {
        if (!isPreset(t)) n += 1;
    }
    return n;
}

// The fetch thread reads the list, so it only changes while none is running.
fn tablesBusy(a: *App) bool {
    if (a.sel.table_thread == null) return false;
    say(a, "Tables are still loading: try again in a moment", .{});
    return true;
}

fn addTable(a: *App, url: []const u8) void {
    if (tablesBusy(a)) return;
    const al = a.arena.allocator();
    const tables = al.alloc([]const u8, a.cfg.tables.len + 1) catch return;
    @memcpy(tables[0..a.cfg.tables.len], a.cfg.tables);
    tables[a.cfg.tables.len] = url;
    a.cfg.tables = tables;
    a.saveConfig();
    select.startTableFetch(a, url);
    say(a, "Loading table...", .{});
}

fn removeTable(a: *App, url: []const u8) void {
    if (tablesBusy(a)) return;
    const al = a.arena.allocator();
    const tables = al.alloc([]const u8, a.cfg.tables.len) catch return;
    var n: usize = 0;
    for (a.cfg.tables) |t| {
        if (std.mem.eql(u8, t, url)) continue;
        tables[n] = t;
        n += 1;
    }
    a.cfg.tables = tables[0..n];
    a.saveConfig();
    for ([_][:0]const u8{ "DELETE FROM table_song WHERE url=?1", "DELETE FROM course WHERE table_url=?1", "DELETE FROM bms_table WHERE url=?1" }) |sql| {
        const st = a.db.prepare(sql) catch return say(a, "Could not remove that table", .{});
        defer st.deinit();
        st.bindText(1, url);
        _ = st.step() catch return say(a, "Could not remove that table", .{});
    }
    select.reload(a);
    say(a, "Table removed", .{});
}

fn toggleTableRow(a: *App) void {
    const row = tableRow(a, a.set.table_row) orelse return;
    if (tableAdded(a, row.url)) removeTable(a, row.url) else addTable(a, row.url);
}

/// The one list here that grows with the data, so it scrolls inside the panel.
fn drawTableList(a: *App, item_index: usize, x: f32, w: f32, top: f32, bottom: f32) void {
    const g = &a.g;
    const s = &a.set;
    const u = g.h / 720;
    const rh = 40 * u;
    const count = tableRowCount(a);
    s.table_row = @min(s.table_row, count - 1);
    const visible: usize = @max(@as(usize, @intFromFloat((bottom - top) / rh)), 1);
    if (s.table_row < s.table_first) s.table_first = s.table_row;
    if (s.table_row >= s.table_first + visible) s.table_first = s.table_row + 1 - visible;
    s.table_first = @min(s.table_first, count -| visible);
    const loading = a.sel.table_thread != null;
    var y = top;
    for (s.table_first..@min(s.table_first + visible, count)) |i| {
        const row = tableRow(a, i) orelse break;
        const on = s.inside and items[s.cursor] == .table_list and i == s.table_row;
        const hover = g.hit(x, y, w, rh - 4 * u);
        if (on) {
            g.round(x, y, w, rh - 4 * u, 8 * u, gfx.accent);
        } else if (hover) g.round(x, y, w, rh - 4 * u, 8 * u, gfx.rule);
        const added = tableAdded(a, row.url);
        const name_y = y + (rh - 4 * u - 22 * u) / 2;
        g.textClip(row.name, x + 12 * u, name_y, w - 140 * u, g.scaled(16), if (added or on or hover) gfx.white else gfx.dim);
        g.textRight(if (added) (if (on) tr("Remove") else tr("Added")) else tr("Add"), x + w - 14 * u, name_y + 2 * u, g.scaled(14), if (on) gfx.white else if (added) gfx.cyan else gfx.dim);
        if (hover and s.capture_slot == null and s.editing == null and g.clickIn(x, y, w, rh - 4 * u)) {
            s.cursor = item_index;
            s.table_row = i;
            s.inside = true;
            g.clicked = false;
            if (!on) {
                a.sfx(.move);
            } else if (!loading) a.click_key = c.SDL_SCANCODE_RETURN else _ = tablesBusy(a);
        }
        y += rh;
    }
}

fn commit(a: *App, it: Item) void {
    // Before the trim below and the arena copy: a password is sent as typed and not kept.
    if (a.set.account_name) |name| {
        a.set.account_name = null;
        return sendAccount(a, name, it == .ir_signup);
    }
    const al = a.arena.allocator();
    const v = al.dupe(u8, std.mem.trim(u8, a.text.items, " \t\"")) catch return;
    switch (it) {
        .add_root => {
            if (v.len == 0) return;
            const roots = al.alloc([]const u8, a.cfg.roots.len + 1) catch return;
            @memcpy(roots[0..a.cfg.roots.len], a.cfg.roots);
            roots[a.cfg.roots.len] = v;
            a.cfg.roots = roots;
            a.saveConfig();
            select.startScan(a);
        },
        .import_beatoraja => {
            const st = db_mod.importBeatoraja(a.gpa, a.db, v) catch |e| return say(a, "Import failed: {t}", .{e});
            say(a, "Imported {d} scores", .{st.imported});
            select.reload(a);
        },
        .import_lr2 => {
            const st = db_mod.importLr2(a.gpa, a.db, v) catch |e| return say(a, "Import failed: {t}", .{e});
            say(a, "Imported {d} scores, {d} charts not in library", .{ st.imported, st.skipped });
            select.reload(a);
        },
        .add_table => {
            if (v.len == 0) return;
            if (!isWebUrl(v)) return say(a, "A table address starts with http:// or https://", .{});
            if (tableAdded(a, v)) return say(a, "That table is already added", .{});
            addTable(a, v);
        },
        .green => {
            const shown = std.fmt.parseInt(u32, v, 10) catch return say(a, "Type a number from {d} to {d}", .{ green_min, green_max });
            a.cfg.green_ms = greenMs(shown);
            a.saveConfig();
        },
        // A bare host is what people type, and a password must not go out over plain HTTP by accident.
        .ir_url => a.cfg.ir_url = if (v.len == 0 or isWebUrl(v)) v else std.fmt.allocPrint(al, "https://{s}", .{v}) catch return,
        .ir_rename => {
            if (v.len == 0) return;
            a.set.account = ir.startAccount(a.gpa, a.cfg.ir_url, v, a.cfg.ir_token, .rename);
            if (a.set.account == null) say(a, "Could not reach the IR server", .{});
        },
        .ir_signup, .ir_signin => {
            if (v.len == 0) return;
            a.set.account_name = v;
            a.set.editing = it;
            a.startText("");
        },
        .download_url => a.cfg.download_url = v,
        .skin => a.cfg.skin = v,
        .bgm_set => pickSetRoot(a, &a.cfg.bgm_path, &a.cfg.bgm_root, v, skin_sound.musicSets),
        .sound_set => pickSetRoot(a, &a.cfg.sound_path, &a.cfg.sound_root, v, skin_sound.soundSets),
        else => {},
    }
}

pub fn captured(a: *App, code: u16) void {
    const s = &a.set;
    const slot = s.capture_slot orelse return;
    if (code == c.SDL_SCANCODE_ESCAPE) {
        s.capture_slot = null;
        return;
    }
    const binds = bindsOf(a, s.capture_group);
    binds[slot] = code;
    s.capture_slot = if (slot + 1 < binds.len) slot + 1 else null;
    if (s.capture_slot == null) a.saveConfig();
}

fn keyEditing(a: *App, it: Item, sc: u32) void {
    const s = &a.set;
    switch (sc) {
        c.SDL_SCANCODE_ESCAPE => {
            s.editing = null;
            s.account_name = null;
            a.text.clearRetainingCapacity();
            a.stopText();
        },
        c.SDL_SCANCODE_RETURN => {
            s.editing = null;
            a.stopText();
            commit(a, it);
        },
        c.SDL_SCANCODE_BACKSPACE => while (a.text.items.len > 0) {
            const ch = a.text.pop().?;
            if (ch & 0xC0 != 0x80) break;
        },
        c.SDL_SCANCODE_V => if (c.SDL_GetModState() & c.SDL_KMOD_CTRL != 0) {
            const clip = c.SDL_GetClipboardText();
            defer c.SDL_free(clip);
            if (clip != null) a.text.appendSlice(a.gpa, std.mem.span(clip)) catch {};
        },
        else => {},
    }
}

/// Picking a tab, before going into it.
fn keyTabs(a: *App, it: Item, sc: u32) void {
    const s = &a.set;
    const sections = std.enums.values(Section);
    const at: usize = @backingInt(it.section());
    switch (sc) {
        c.SDL_SCANCODE_UP => {
            a.sfx(.move);
            s.cursor = firstOf(sections[if (at == 0) sections.len - 1 else at - 1]);
        },
        c.SDL_SCANCODE_DOWN => {
            a.sfx(.move);
            s.cursor = firstOf(sections[(at + 1) % sections.len]);
        },
        c.SDL_SCANCODE_RETURN, c.SDL_SCANCODE_RIGHT => {
            a.sfx(.confirm);
            s.inside = true;
        },
        c.SDL_SCANCODE_ESCAPE => {
            a.sfxOr(a.sfx_option_close, .back);
            a.saveConfig();
            a.engine.switchDevice(a.cfg.audio_frames, a.cfg.audio_device);
            a.scene = .select;
        },
        else => {},
    }
}

/// What Enter does on a row.
fn activate(a: *App, it: Item) void {
    const s = &a.set;
    // Arrow rows step with Left/Right and their arrows only.
    switch (it) {
        .lift, .hidden, .judge_offset, .visual_offset => return,
        else => {},
    }
    a.sfx(.confirm);
    if (hasDrop(it)) return openDrop(a, it);
    if (usesPicker(it)) return openPicker(a, it);
    switch (it) {
        .clear_roots => {
            a.cfg.roots = &.{};
            a.saveConfig();
        },
        .update_tables => {
            if (tablesBusy(a)) return;
            select.startTableFetch(a, null);
            say(a, "Loading tables...", .{});
        },
        .table_list => toggleTableRow(a),
        .ir_upload => startSync(a, true),
        .ir_download => startSync(a, false),
        .update => activateUpdate(a),
        .skin_slots => skinslots.open(a),
        .bind_4k, .bind_5k, .bind_6k, .bind_7k, .bind_10k, .bind_14k, .bind_9k, .bind_start => {
            s.capture_group = it;
            s.capture_slot = 0;
        },
        .green, .add_table, .ir_url, .download_url => startEditing(a, it),
        .ir_signup, .ir_signin, .ir_rename => startAccount(a, it),
        else => adjust(a, it, 1),
    }
}

fn keyItems(a: *App, it: Item, sc: u32) void {
    const s = &a.set;
    if (it == .table_list) {
        if (sc == c.SDL_SCANCODE_UP and s.table_row > 0) {
            a.sfx(.move);
            s.table_row -= 1;
            return;
        }
        if (sc == c.SDL_SCANCODE_DOWN and s.table_row + 1 < tableRowCount(a)) {
            a.sfx(.move);
            s.table_row += 1;
            return;
        }
    }
    switch (sc) {
        c.SDL_SCANCODE_UP => {
            a.sfx(.move);
            s.cursor = if (s.cursor > 0 and items[s.cursor - 1].section() == it.section()) s.cursor - 1 else blk: {
                var last = s.cursor;
                while (last + 1 < items.len and items[last + 1].section() == it.section()) last += 1;
                break :blk last;
            };
            if (items[s.cursor] == .table_list) s.table_row = tableRowCount(a) - 1;
        },
        c.SDL_SCANCODE_DOWN => {
            a.sfx(.move);
            s.cursor = if (s.cursor + 1 < items.len and items[s.cursor + 1].section() == it.section()) s.cursor + 1 else firstOf(it.section());
            s.table_row = 0;
        },
        c.SDL_SCANCODE_LEFT => {
            a.sfx(.adjust);
            adjust(a, it, -1);
        },
        c.SDL_SCANCODE_RIGHT => {
            a.sfx(.adjust);
            adjust(a, it, 1);
        },
        c.SDL_SCANCODE_ESCAPE => {
            a.sfx(.back);
            s.inside = false;
        },
        c.SDL_SCANCODE_RETURN => activate(a, it),
        else => {},
    }
}

pub fn key(a: *App, sc: u32) void {
    const s = &a.set;
    if (s.editing) |it| return keyEditing(a, it, sc);
    if (s.picker_for != null) return;
    if (s.drop.open) {
        if (s.drop.key(a, sc)) |i| chooseDrop(a, i);
        return;
    }
    const it = items[s.cursor];
    if (s.inside) keyItems(a, it, sc) else keyTabs(a, it, sc);
}

test "a click selects first, and stepped rows never open a dialog" {
    try std.testing.expect(!clickActs(false, .add_root));
    try std.testing.expect(clickActs(true, .add_root));
    try std.testing.expect(!clickActs(true, .skin));
    try std.testing.expect(!clickActs(true, .sound_set));
}

test "table addresses must be web addresses" {
    try std.testing.expect(isWebUrl("https://stellabms.xyz/st/table.html"));
    try std.testing.expect(isWebUrl("http://example.com/t"));
    try std.testing.expect(!isWebUrl("stellabms.xyz/st/table.html"));
    try std.testing.expect(!isWebUrl("/home/me/table.json"));
}

test "presets are not listed twice and added tables follow them" {
    try std.testing.expect(isPreset("https://stellabms.xyz/st/table.html"));
    try std.testing.expect(!isPreset("https://example.com/t.html"));
}

test "a typed green number comes back exactly" {
    for (green_min..green_max + 1) |shown| {
        try std.testing.expectEqual(@as(u32, @intCast(shown)), greenShown(greenMs(@intCast(shown))));
    }
    try std.testing.expectEqual(@as(u32, green_min), greenShown(greenMs(1)));
    try std.testing.expectEqual(@as(u32, green_max), greenShown(greenMs(99999)));
}

fn openItem(a: *App, it: Item) void {
    a.set.cursor = std.mem.indexOfScalar(Item, items, it).?;
    a.set.inside = true;
}

test "tabs wrap, enter goes in and escape comes out, then leaves" {
    const a = try testing.open();
    defer testing.close(a);
    a.scene = .settings;
    key(a, c.SDL_SCANCODE_UP);
    try std.testing.expectEqual(.controls, items[a.set.cursor].section());
    key(a, c.SDL_SCANCODE_DOWN);
    try std.testing.expectEqual(.library, items[a.set.cursor].section());
    try std.testing.expectEqual(firstOf(.library), a.set.cursor);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expect(a.set.inside);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(!a.set.inside);
    try std.testing.expectEqual(.settings, a.scene);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expectEqual(.select, a.scene);
}

test "up and down stay inside a tab" {
    const a = try testing.open();
    defer testing.close(a);
    openItem(a, .add_root);
    key(a, c.SDL_SCANCODE_UP);
    try std.testing.expectEqual(.clear_roots, items[a.set.cursor]);
    key(a, c.SDL_SCANCODE_DOWN);
    try std.testing.expectEqual(.add_root, items[a.set.cursor]);
    key(a, c.SDL_SCANCODE_DOWN);
    try std.testing.expectEqual(.clear_roots, items[a.set.cursor]);
}

test "the table list moves row by row before it leaves" {
    const a = try testing.open();
    defer testing.close(a);
    openItem(a, .table_list);
    for (1..tableRowCount(a)) |row| {
        key(a, c.SDL_SCANCODE_DOWN);
        try std.testing.expectEqual(row, a.set.table_row);
        try std.testing.expectEqual(.table_list, items[a.set.cursor]);
    }
    key(a, c.SDL_SCANCODE_DOWN);
    try std.testing.expectEqual(.add_table, items[a.set.cursor]);
    try std.testing.expectEqual(@as(usize, 0), a.set.table_row);
    key(a, c.SDL_SCANCODE_UP);
    try std.testing.expectEqual(.table_list, items[a.set.cursor]);
    try std.testing.expectEqual(tableRowCount(a) - 1, a.set.table_row);
}

test "left and right step a value, and arrow rows ignore enter" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.volume = 0.5;
    openItem(a, .volume);
    key(a, c.SDL_SCANCODE_RIGHT);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), a.cfg.volume, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), a.engine.gain, 0.001);
    key(a, c.SDL_SCANCODE_LEFT);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), a.cfg.volume, 0.001);
    openItem(a, .judge_offset);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(@as(i32, 0), a.cfg.judge_offset_ms);
    key(a, c.SDL_SCANCODE_RIGHT);
    try std.testing.expectEqual(@as(i32, 1), a.cfg.judge_offset_ms);
    a.cfg.audio_rate = 48000;
    openItem(a, .audio_rate);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(@as(u32, 44100), a.cfg.audio_rate);
}

test "signing up asks for a name, then sends the password as typed" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.ir_url = "";
    a.cfg.ir_token = "";
    openItem(a, .ir_signup);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expect(a.set.editing == null);

    a.cfg.ir_url = "http://127.0.0.1:1";
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(.ir_signup, a.set.editing.?);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expect(a.set.editing == null);
    try std.testing.expect(a.set.account_name == null);

    key(a, c.SDL_SCANCODE_RETURN);
    try a.text.appendSlice(a.gpa, "alice");
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqualStrings("alice", a.set.account_name.?);
    try std.testing.expectEqual(.ir_signup, a.set.editing.?);
    try std.testing.expectEqual(@as(usize, 0), a.text.items.len);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(a.set.account_name == null);

    key(a, c.SDL_SCANCODE_RETURN);
    try a.text.appendSlice(a.gpa, "alice");
    key(a, c.SDL_SCANCODE_RETURN);
    try a.text.appendSlice(a.gpa, " \"pass word\" ");
    key(a, c.SDL_SCANCODE_RETURN);
    const sent = a.set.account.?;
    try std.testing.expectEqualStrings(" \"pass word\" ", sent.secret);
    try std.testing.expectEqual(.register, sent.action);
    try std.testing.expectEqual(@as(usize, 0), a.text.items.len);
    while (!sent.done.load(.acquire)) c.SDL_Delay(5);
    pollAccount(a);
    try std.testing.expect(a.set.account == null);
    try std.testing.expectEqualStrings("", a.cfg.ir_token);
}

test "an IR server typed without a scheme uses https" {
    const a = try testing.open();
    defer testing.close(a);
    openItem(a, .ir_url);
    for ([_][2][]const u8{
        .{ "ir.actuon.app", "https://ir.actuon.app" },
        .{ "http://127.0.0.1:8730", "http://127.0.0.1:8730" },
        .{ "", "" },
    }) |case| {
        key(a, c.SDL_SCANCODE_RETURN);
        a.text.clearRetainingCapacity();
        try a.text.appendSlice(a.gpa, case[0]);
        key(a, c.SDL_SCANCODE_RETURN);
        try std.testing.expectEqualStrings(case[1], a.cfg.ir_url);
    }
}

test "renaming needs a sign-in and sends the token" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.ir_url = "http://127.0.0.1:1";
    a.cfg.ir_token = "";
    openItem(a, .ir_rename);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expect(a.set.editing == null);

    a.cfg.ir_token = "tok";
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(.ir_rename, a.set.editing.?);
    try a.text.appendSlice(a.gpa, "alicia");
    key(a, c.SDL_SCANCODE_RETURN);
    const sent = a.set.account.?;
    try std.testing.expectEqualStrings("alicia", sent.name);
    try std.testing.expectEqualStrings("tok", sent.secret);
    try std.testing.expectEqual(.rename, sent.action);
    while (!sent.done.load(.acquire)) c.SDL_Delay(5);
    pollAccount(a);
    try std.testing.expect(a.set.account == null);
    try std.testing.expectEqualStrings("tok", a.cfg.ir_token);
}

test "editing a value commits on enter and cancels on escape" {
    const a = try testing.open();
    defer testing.close(a);
    openItem(a, .green);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(.green, a.set.editing.?);
    a.text.clearRetainingCapacity();
    try a.text.appendSlice(a.gpa, "2500");
    key(a, c.SDL_SCANCODE_BACKSPACE);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expect(a.set.editing == null);
    try std.testing.expectEqual(greenMs(250), a.cfg.green_ms);
    const before = a.cfg.green_ms;
    key(a, c.SDL_SCANCODE_RETURN);
    a.text.clearRetainingCapacity();
    try a.text.appendSlice(a.gpa, "999");
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(a.set.editing == null);
    try std.testing.expectEqual(before, a.cfg.green_ms);
    key(a, c.SDL_SCANCODE_RETURN);
    a.text.clearRetainingCapacity();
    try a.text.appendSlice(a.gpa, "soon");
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(before, a.cfg.green_ms);
    try std.testing.expect(std.mem.startsWith(u8, a.set.message, "Type a number"));
}

test "a table address must look like one" {
    const a = try testing.open();
    defer testing.close(a);
    openItem(a, .add_table);
    key(a, c.SDL_SCANCODE_RETURN);
    try a.text.appendSlice(a.gpa, "stellabms.xyz");
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(@as(usize, 0), a.cfg.tables.len);
    try std.testing.expect(std.mem.startsWith(u8, a.set.message, "A table address"));
}

test "binding walks every button and escape stops it" {
    const a = try testing.open();
    defer testing.close(a);
    openItem(a, .bind_4k);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(@as(?u8, 0), a.set.capture_slot);
    captured(a, 100);
    try std.testing.expectEqual(@as(u16, 100), a.cfg.keys4[0]);
    captured(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(a.set.capture_slot == null);
    try std.testing.expectEqual(@as(u16, 9), a.cfg.keys4[1]);
    key(a, c.SDL_SCANCODE_RETURN);
    for (a.cfg.keys4, 0..) |_, i| captured(a, @intCast(200 + i));
    try std.testing.expect(a.set.capture_slot == null);
    try std.testing.expectEqual(@as(u16, 203), a.cfg.keys4[3]);
}

test "the language row steps through every language, wraps and is saved" {
    const a = try testing.open();
    defer testing.close(a);
    defer i18n.current = .en;
    openItem(a, .language);
    key(a, c.SDL_SCANCODE_RIGHT);
    try std.testing.expectEqual(.ko, i18n.current);
    try std.testing.expectEqualStrings("ko", a.cfg.language);
    try std.testing.expectEqualStrings("언어", Item.language.name());
    key(a, c.SDL_SCANCODE_LEFT);
    key(a, c.SDL_SCANCODE_LEFT);
    try std.testing.expectEqual(.zh, i18n.current);
    try std.testing.expectEqualStrings("zh", a.cfg.language);
}

test "clearing library folders empties the list" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.roots = &.{"/lib"};
    openItem(a, .clear_roots);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(@as(usize, 0), a.cfg.roots.len);
}
