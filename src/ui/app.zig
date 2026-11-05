const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");
const gfx = @import("gfx.zig");
const i18n = @import("i18n.zig");
const tr = i18n.tr;
const input = @import("../input/input.zig");
const config = @import("../game/config.zig");
const session_mod = @import("../game/session.zig");
const engine_mod = @import("../audio/engine.zig");
const menu_sound = @import("../audio/menu_sound.zig");
const skin_sound = @import("../audio/skin_sound.zig");
const preview_mod = @import("../audio/preview.zig");
const db_mod = @import("../db/db.zig");
const play = @import("play.zig");
const practice = @import("practice.zig");
const versus = @import("versus.zig");
const select = @import("select.zig");
const result = @import("result.zig");
const settings = @import("settings.zig");
const update = @import("../net/update.zig");
const ir = @import("../net/ir.zig");
const skinconf = @import("skinconf.zig");
const skinslots = @import("skinslots.zig");
const course_mod = @import("course.zig");
const pause = @import("pause.zig");
const editor = @import("editor.zig");
const crash = @import("../platform/crash.zig");
const bga = @import("bga.zig");
const skin_mod = @import("../skin/skin.zig");
const skin_scene = @import("../skin/scene.zig");
const Session = session_mod.Session;

pub const Scene = enum { select, loading, play, result, settings, skinconf, skinslots, versus };

pub const Pending = struct {
    params: session_mod.Params,
    record: bool,
};

/// The chart's own images decode beside loading and decide, which don't wait for them; the upload stays on the main thread.
const ChartImages = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Only the decode thread allocates from it until it is done.
    arena: std.heap.ArenaAllocator,
    dir: []const u8 = "",
    /// Stagefile, backbmp, banner.
    names: [3][]const u8 = @splat(""),
    px: [3]?[*]u8 = @splat(null),
    w: [3]c_int = @splat(0),
    h: [3]c_int = @splat(0),
    thread: ?*c.SDL_Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),

    fn run(ud: ?*anyopaque) callconv(.c) c_int {
        const j: *ChartImages = @ptrCast(@alignCast(ud));
        defer j.done.store(true, .release);
        for (j.names, &j.px, &j.w, &j.h) |name, *px, *w, *h| {
            if (name.len == 0 or j.cancel.load(.acquire)) continue;
            const path = (fs.resolveAsset(j.arena.allocator(), j.io, j.dir, name, &.{ "png", "jpg", "jpeg", "bmp", "gif", "tga" }) catch null) orelse continue;
            const bytes = fs.readAlloc(j.gpa, j.io, path, 1 << 26) catch continue;
            defer j.gpa.free(bytes);
            if (!gfx.imageFits(bytes, gfx.max_chart_image_px)) continue;
            var n: c_int = 0;
            px.* = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), w, h, &n, 4);
        }
        return 0;
    }
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Shared with main, so what menus allocate here is freed with what main allocated.
    arena: *std.heap.ArenaAllocator,
    cfg: config.Config,
    g: gfx.Gfx,
    engine: *engine_mod.Engine,
    sfx_data: [std.enums.values(menu_sound.Sfx).len][]const f32 = @splat(&.{}),
    sfx_slot: u8 = engine_mod.first_oneshot_slot,
    sfx_thread: ?*c.SDL_Thread = null,
    sfx_ready: std.atomic.Value(bool) = .init(false),
    sounds: skin_sound.Player = undefined,
    preview: preview_mod.Preview = undefined,
    sfx_skin: [std.enums.values(menu_sound.Sfx).len]?*skin_sound.Entry = @splat(null),
    bgm_thread: ?*c.SDL_Thread = null,
    bgm_data: []const f32 = &.{},
    bgm_ready: std.atomic.Value(bool) = .init(false),
    bgm_on: bool = false,
    bgm_slot: u8 = 0,
    /// What slot 0 is looping, so a different skin's music can take over.
    bgm_playing: []const f32 = &.{},
    bgm_skin: ?*skin_sound.Entry = null,
    sfx_option_open: ?*skin_sound.Entry = null,
    sfx_option_close: ?*skin_sound.Entry = null,
    sfx_play_stop: ?*skin_sound.Entry = null,
    sfx_play_ready: ?*skin_sound.Entry = null,
    decide_bgm: ?*skin_sound.Entry = null,
    decide_bgm_on: bool = false,
    /// Applied after drawing, because keys can replace what is being drawn.
    click_key: ?u32 = null,
    last_pump_ns: u64 = 0,
    next_frame_ns: u64 = 0,
    db: db_mod.Db,
    scene: Scene = .select,
    running: bool = true,
    sel: select.State,
    res: result.State = .{},
    pause: pause.State = .{},
    set: settings.State = .{},
    skinconf: skinconf.State = .{},
    skinslots: skinslots.State = .{},
    session: ?*Session = null,
    cursor_hidden: bool = false,
    view: play.View = .{ .render_state = &.{} },
    record: bool = true,
    load_progress: std.atomic.Value(usize) = .init(0),
    load_total: std.atomic.Value(usize) = .init(0),
    load_done: std.atomic.Value(bool) = .init(false),
    load_parsed: session_mod.Parsed = .{},
    /// 0 until the chart is parsed.
    load_skin_at: u64 = 0,
    load_at: u64 = 0,
    load_err: bool = false,
    load_thread: ?*c.SDL_Thread = null,
    load_params: session_mod.Params = .{ .path = "" },
    load_result: ?*Session = null,
    text: std.ArrayList(u8) = .empty,
    text_active: bool = false,
    joy_axis: [32]i16 = @splat(0),
    joy_axis_at: [32]u64 = @splat(0),
    practice: practice.State = .{},
    versus: versus.State = .{},
    shot_wanted: bool = false,
    notice: []const u8 = "",
    notice_until: u64 = 0,
    shot_path: ?[:0]const u8 = null,
    shot_after_ms: u64 = 0,
    shot_keys: std.mem.TokenIterator(u8, .scalar) = std.mem.tokenizeScalar(u8, "", ','),
    shot_key_at: u64 = shot_keys_start_ms,
    start_ms: u64 = 0,
    exit_after_play: bool = false,
    course: ?course_mod.Run = null,
    play_skin: ?*skin_mod.model.Skin = null,
    result_skin: ?*skin_mod.model.Skin = null,
    decide_skin: ?*skin_mod.model.Skin = null,
    skin_mode: core.types.Mode = .beat7,
    select_skin: ?*skin_mod.model.Skin = null,
    select_skin_root: []const u8 = "",
    select_skin_loaded: bool = false,
    select_state: skin_scene.State = .{},
    select_at: u64 = 0,
    select_seen: u64 = 0,
    select_row: usize = 0,
    kept: std.heap.ArenaAllocator = undefined,
    chart_images: ?*ChartImages = null,
    want_decide: bool = false,
    decide_at: u64 = 0,
    decide_fade_at: u64 = 0,
    last_scene: ?Scene = null,
    select_shown_at: u64 = 0,
    decide_cancel: bool = false,
    skin_state: skin_scene.State = .{},
    skin_poll_ms: u64 = 0,
    editor_poll_ms: u64 = 0,
    preview_buf: [4096]u8 = undefined,
    /// `load_params.path` and the session point here.
    play_path_buf: [4096]u8 = undefined,
    play_level_buf: [64]u8 = undefined,
    play_table_buf: [128]u8 = undefined,
    preview_path: []const u8 = "",
    preview_measure: i32 = 0,
    preview_mtime: i64 = 0,
    /// Deferred to the next frame, so any running session ends first.
    preview_pending: bool = false,

    pub fn startText(a: *App, initial: []const u8) void {
        a.text.clearRetainingCapacity();
        a.typeText(initial);
        a.text_active = true;
        _ = c.SDL_StartTextInput(a.g.win);
    }

    fn typeText(a: *App, s: []const u8) void {
        a.text.appendSlice(a.gpa, s) catch |e| std.log.warn("typed text dropped: {t}", .{e});
    }

    pub fn stopText(a: *App) void {
        a.text_active = false;
        _ = c.SDL_StopTextInput(a.g.win);
    }

    pub fn sfxOr(a: *App, entry: ?*skin_sound.Entry, fallback: menu_sound.Sfx) void {
        if (entry) |e| if (e.ready.load(.acquire) and e.data.len > 0) {
            a.engine.uiPlay(skin_sound.nextSlot(&a.sfx_slot), e.data, false, a.cfg.sfx_volume);
            return;
        };
        a.sfx(fallback);
    }

    pub fn sfx(a: *App, which: menu_sound.Sfx) void {
        if (a.sfx_skin[@backingInt(which)]) |e| if (e.ready.load(.acquire) and e.data.len > 0) {
            a.engine.uiPlay(skin_sound.nextSlot(&a.sfx_slot), e.data, false, a.cfg.sfx_volume);
            return;
        };
        if (!a.sfx_ready.load(.acquire)) return;
        a.engine.uiPlay(skin_sound.nextSlot(&a.sfx_slot), a.sfx_data[@backingInt(which)], false, a.cfg.sfx_volume);
    }

    /// Skin Lua is untrusted: it may only play files inside a skin folder.
    fn skinAudio(ud: *anyopaque, path: []const u8, op: skin_sound.Op, gain: f32) void {
        const a: *App = @ptrCast(@alignCast(ud));
        if (fs.climbs(path)) return;
        const inside = for (std.enums.values(config.SkinSlot)) |slot| {
            if (db_mod.isUnder(path, a.skinDir(slot))) break true;
        } else false;
        if (!inside) return;
        a.sounds.request(path, op, gain * a.cfg.sfx_volume);
    }

    fn skinDir(a: *App, slot: config.SkinSlot) []const u8 {
        const root = a.cfg.skinFor(slot);
        const st = fs.stat(a.io, root) orelse return root;
        return if (st.is_dir) root else std.fs.path.dirname(root) orelse root;
    }

    /// beatoraja's sound set names, in `Sfx` order, from the skin's Sound folder.
    fn loadSkinSfx(a: *App, al: std.mem.Allocator) void {
        const names = [std.enums.values(menu_sound.Sfx).len][]const u8{ "scratch", "o-change", "f-open", "f-close", "", "clear", "fail" };
        for (names, &a.sfx_skin) |name, *slot| {
            slot.* = a.systemSound(al, name);
        }
        a.sfx_option_open = a.systemSound(al, "o-open");
        a.sfx_option_close = a.systemSound(al, "o-close");
        a.sfx_play_stop = a.systemSound(al, "playstop");
        a.sfx_play_ready = a.systemSound(al, "playready");
        a.bgm_skin = a.musicSound(al, .select, "select");
        a.decide_bgm = a.musicSound(al, .decide, "decide");
    }

    fn systemSound(a: *App, al: std.mem.Allocator, name: []const u8) ?*skin_sound.Entry {
        if (a.cfg.sound_path.len > 0) if (skin_sound.findIn(al, a.io, a.cfg.sound_path, name)) |p| return a.sounds.entry(p);
        // A built-in song select borrows a full skin's sounds; a skin picked for one other screen keeps its own.
        for (std.enums.values(config.SkinSlot)) |slot| {
            if (slot != .select and a.cfg.skins.get(slot).len > 0) continue;
            if (name.len > 0) if (a.skinSound(al, slot, name)) |e| return e;
        }
        return null;
    }

    fn musicSound(a: *App, al: std.mem.Allocator, slot: config.SkinSlot, name: []const u8) ?*skin_sound.Entry {
        if (a.cfg.bgm_path.len > 0) if (skin_sound.findIn(al, a.io, a.cfg.bgm_path, name)) |p| return a.sounds.entry(p);
        return a.skinSound(al, slot, name);
    }

    /// What plays changes only once the new file has decoded.
    pub fn refreshBgm(a: *App) void {
        var tmp = std.heap.ArenaAllocator.init(a.gpa);
        defer tmp.deinit();
        a.loadSkinSfx(tmp.allocator());
    }

    fn skinSound(a: *App, al: std.mem.Allocator, slot: config.SkinSlot, name: []const u8) ?*skin_sound.Entry {
        const dir = a.skinDir(slot);
        if (dir.len == 0) return null;
        for ([_][]const u8{ "Sound", "Sound/bgm", "bgm" }) |sub| {
            const folder = std.fs.path.join(al, &.{ dir, sub }) catch return null;
            if (skin_sound.findIn(al, a.io, folder, name)) |p| return a.sounds.entry(p);
        }
        return null;
    }

    fn menuBgm(a: *App) ?[]const f32 {
        if (a.scene == .select and a.preview.current.len > 0) return a.preview.current;
        if (a.bgm_skin) |e| {
            if (!e.ready.load(.acquire)) return null;
            if (e.data.len > 0) return e.data;
        }
        if (a.bgm_thread == null) a.bgm_thread = c.SDL_CreateThread(bgmThread, "bgm", a);
        return if (a.bgm_ready.load(.acquire)) a.bgm_data else null;
    }

    fn startDecideBgm(a: *App) void {
        const e = a.decide_bgm orelse return;
        if (!e.ready.load(.acquire) or e.data.len == 0) return;
        a.engine.uiPlay(engine_mod.decide_slot, e.data, false, a.cfg.bgm_volume);
        a.decide_bgm_on = true;
    }

    /// Rendered off the main thread so startup doesn't wait on the reverb.
    fn sfxThread(ud: ?*anyopaque) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(ud));
        for (std.enums.values(menu_sound.Sfx), 0..) |which, i| {
            a.sfx_data[i] = menu_sound.renderSfx(a.gpa, which, a.engine.rate) catch &.{};
        }
        a.sfx_ready.store(true, .release);
        return 0;
    }

    fn bgmThread(ud: ?*anyopaque) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(ud));
        a.bgm_data = menu_sound.renderBgm(a.gpa, a.engine.rate) catch return 0;
        a.bgm_ready.store(true, .release);
        return 0;
    }

    /// Only once the engine has stopped and run has joined the threads that render these.
    fn freeMenuSounds(a: *App) void {
        for (a.sfx_data) |d| a.gpa.free(d);
        a.gpa.free(a.bgm_data);
    }

    /// The loop renders when a menu first shows, so a chart launched from the command line never pays for it.
    fn tickBgm(a: *App) void {
        a.sounds.tick();
        if (a.scene != .result) if (a.res.music_slot) |s| {
            a.engine.uiGain(s, 0);
            a.res.music_slot = null;
        };
        const want = a.scene == .select or a.scene == .settings or a.scene == .skinconf or a.scene == .skinslots or a.scene == .versus;
        if (a.decide_bgm_on and a.decide_at == 0) {
            a.engine.uiGain(engine_mod.decide_slot, 0);
            a.decide_bgm_on = false;
        }
        if (want) {
            if (a.menuBgm()) |data| if (!a.bgm_on or data.ptr != a.bgm_playing.ptr) {
                if (a.bgm_on) a.engine.uiGain(a.bgm_slot, 0);
                a.bgm_slot = (a.bgm_slot + 1) % engine_mod.menu_slots;
                a.engine.uiPlay(a.bgm_slot, data, true, a.cfg.bgm_volume);
                a.bgm_playing = data;
                a.bgm_on = true;
            };
        } else if (a.bgm_on) {
            a.engine.uiGain(a.bgm_slot, 0);
            a.bgm_on = false;
        }
    }

    /// Under HS auto adjust the green number then refers to the BPM playing now.
    pub fn moveCover(a: *App, by: f32) void {
        a.cfg.setCover(a.cfg.lane_cover + by);
        const s = a.session orelse return;
        if (a.cfg.hs_auto_adjust and a.cfg.hs_fix != 3) a.view.ref_bpm = s.chart.bpmAt(s.snapshot().time_us);
    }

    pub fn startPlay(a: *App, params: session_mod.Params, record: bool) void {
        if (a.load_thread != null) return;
        if ((a.scene == .select or a.scene == .versus) and a.sfx_play_ready == null and a.decide_bgm == null) a.sfx(.start);
        a.load_params = params;
        a.record = record and !params.autoplay and params.replay == null;
        a.load_progress.store(0, .release);
        a.load_total.store(0, .release);
        a.load_done.store(false, .release);
        a.load_err = false;
        a.load_parsed.ready.store(false, .release);
        a.load_parsed.cancel.store(false, .release);
        a.load_skin_at = 0;
        a.load_at = c.SDL_GetTicks();
        a.want_decide = false;
        a.decide_at = 0;
        a.decide_fade_at = 0;
        a.decide_cancel = false;
        // Held until now: the skin draws the chart's images through play and the result.
        a.dropChartImages();
        a.skin_state = .{};
        a.scene = .loading;
        a.load_thread = c.SDL_CreateThread(loadThread, "loader", a);
    }

    pub fn decidePlay(a: *App, params: session_mod.Params, record: bool) void {
        a.startPlay(params, record);
        a.want_decide = true;
    }

    fn loadThread(ud: ?*anyopaque) callconv(.c) c_int {
        const a: *App = @ptrCast(@alignCast(ud));
        a.load_result = Session.create(a.gpa, a.io, a.engine, &a.cfg, a.load_params, &a.load_progress, &a.load_total, &a.load_parsed) catch |e| blk: {
            std.log.err("load failed: {t}", .{e});
            break :blk null;
        };
        a.load_done.store(true, .release);
        return 0;
    }

    /// A load backed out of runs on until its decode sees the cancel, so it is collected once done.
    fn reapCanceledLoad(a: *App) void {
        const t = a.load_thread orelse return;
        if (!a.load_parsed.cancel.load(.acquire) or !a.load_done.load(.acquire)) return;
        c.SDL_WaitThread(t, null);
        a.load_thread = null;
        if (a.load_result) |s| s.destroy();
        a.load_result = null;
    }

    pub fn startPreview(a: *App, file: []const u8, measure: i32) void {
        if (file.len == 0 or file.len > a.preview_buf.len) return;
        @memcpy(a.preview_buf[0..file.len], file);
        a.preview_path = a.preview_buf[0..file.len];
        a.preview_measure = measure;
        a.preview_mtime = if (fs.stat(a.io, a.preview_path)) |st| st.mtime else 0;
        a.preview_pending = true;
    }

    fn launchPreview(a: *App) void {
        a.preview_pending = false;
        var tmp = std.heap.ArenaAllocator.init(a.gpa);
        defer tmp.deinit();
        var start_us: i64 = 0;
        if (a.preview_measure > 0) {
            if (Session.parseFile(a.gpa, a.io, a.preview_path, null, 0)) |parsed| {
                var ch = parsed;
                defer ch.deinit();
                start_us = editor.measureStart(&ch, a.preview_measure);
            } else |_| {}
        }
        a.startPlay(.{ .path = a.preview_path, .autoplay = true, .start_us = start_us }, false);
    }

    fn pollEditor(a: *App) void {
        const now = c.SDL_GetTicks();
        if (now - a.editor_poll_ms < 250) return;
        a.editor_poll_ms = now;
        var tmp = std.heap.ArenaAllocator.init(a.gpa);
        defer tmp.deinit();
        const al = tmp.allocator();
        editor.heartbeat(al, a.io);
        if (editor.receive(al, a.io)) |cmd| {
            if (a.session != null and a.scene == .play) {
                const s = a.session.?;
                a.finishPlay(s.snapshot(), false);
            }
            if (cmd.stop) {
                a.preview_path = "";
                a.scene = .select;
            } else a.startPreview(cmd.file, cmd.measure);
        }
        if (a.preview_path.len > 0 and a.load_thread == null) {
            if (fs.stat(a.io, a.preview_path)) |st| if (st.mtime != a.preview_mtime) {
                a.preview_mtime = st.mtime;
                if (a.session != null and a.scene == .play) {
                    const s = a.session.?;
                    a.finishPlay(s.snapshot(), false);
                }
                a.preview_pending = true;
            };
        }
        if (a.preview_pending and a.load_thread == null and a.session == null) a.launchPreview();
    }

    fn bestEx(a: *App, sha: []const u8, asked: core.options.LnMode, played: core.options.LnMode) u32 {
        const mode = db_mod.scoreMode(a.db, sha, @backingInt(asked), @backingInt(played)) catch return 0;
        const st = a.db.prepare("SELECT ex FROM score WHERE sha256=?1 AND mode=?2") catch return 0;
        defer st.deinit();
        st.bindText(1, sha);
        st.bindInt(2, mode);
        return if (st.step() catch false) @intCast(st.int(0)) else 0;
    }

    /// Brings the skin up as soon as the chart is parsed, so sounds decode behind its loading screen.
    fn startLoadingSkin(a: *App) void {
        const ch = &a.load_parsed.chart;
        a.load_skin_at = c.SDL_GetTicks();
        a.skin_state.fromChart(ch, a.load_params, &a.cfg);
        a.skin_state.loaded = false;
        a.skin_state.load_frac = 0;
        a.reloadSkins(ch.mode);
        // Decide's clock starts once it can be drawn, so its opening is seen whole.
        const show_decide = a.want_decide and a.decide_skin != null;
        if (show_decide) {
            a.decide_at = c.SDL_GetTicks();
            a.startDecideBgm();
        }
        if (a.play_skin == null and !show_decide) return;
        a.startChartImages(ch) catch |e| std.log.warn("chart images not shown: {t}", .{e});
    }

    fn startChartImages(a: *App, ch: *const core.types.Chart) !void {
        const j = try a.gpa.create(ChartImages);
        errdefer a.gpa.destroy(j);
        j.* = .{ .gpa = a.gpa, .io = a.io, .arena = .init(a.gpa) };
        errdefer j.arena.deinit();
        const al = j.arena.allocator();
        j.dir = try al.dupe(u8, std.fs.path.dirname(a.load_params.path) orelse ".");
        for ([_][]const u8{ ch.stagefile, ch.backbmp, ch.banner }, &j.names) |name, *out| out.* = try al.dupe(u8, name);
        j.thread = c.SDL_CreateThread(ChartImages.run, "chart images", j);
        if (j.thread == null) _ = ChartImages.run(j);
        a.chart_images = j;
    }

    /// In `ChartImages.names` order.
    fn chartImageSlots(a: *App) [3]*?*gfx.Texture {
        return .{ &a.skin_state.stagefile, &a.skin_state.backbmp, &a.skin_state.banner };
    }

    fn finishChartImages(a: *App, show: bool) void {
        const j = a.chart_images orelse return;
        a.chart_images = null;
        // Images nobody will see are skipped, so backing out waits on one decode at most.
        if (!show) j.cancel.store(true, .release);
        c.SDL_WaitThread(j.thread, null);
        for (j.px, j.w, j.h, a.chartImageSlots()) |px, w, h, slot| if (px) |p| {
            if (show) slot.* = gfx.textureFitted(&a.g, p, w, h);
            c.stbi_image_free(p);
        };
        j.arena.deinit();
        a.gpa.destroy(j);
    }

    fn decideLeave(a: *App, cancel: bool) void {
        if (a.decide_fade_at != 0) return;
        a.decide_fade_at = c.SDL_GetTicks();
        a.decide_cancel = cancel;
        a.skin_state.timers[2] = @intCast(a.decide_fade_at - a.decide_at);
    }

    pub fn decideKey(a: *App, sc: c.SDL_Scancode) void {
        if (a.decide_at == 0) return;
        const sk = a.decide_skin orelse return;
        if (sc == c.SDL_SCANCODE_ESCAPE) return a.decideLeave(true);
        if (c.SDL_GetTicks() - a.decide_at >= @as(u64, @intCast(@max(sk.input_ms, 0)))) a.decideLeave(false);
    }

    fn tickDecide(a: *App) bool {
        const sk = a.decide_skin.?;
        const now = c.SDL_GetTicks();
        const shown: i64 = @intCast(now - a.decide_at);
        if (shown >= std.math.clamp(sk.scene_ms, 0, 20_000)) a.decideLeave(false);
        const over = a.decide_fade_at != 0 and now - a.decide_fade_at >= @as(u64, @intCast(std.math.clamp(sk.fadeout_ms, 0, 5000)));
        if (!over) {
            skin_scene.drawLoading(&a.g, sk, &a.skin_state, shown);
            return true;
        }
        if (a.decide_cancel) {
            a.load_parsed.cancel.store(true, .release);
            a.dropChartImages();
            a.decide_at = 0;
            a.scene = .select;
            return true;
        }
        a.decide_at = 0;
        a.load_at = now;
        a.skin_state.timers = @splat(-1);
        return false;
    }

    fn tickLoading(a: *App) void {
        const g = &a.g;
        const t = a.load_total.load(.acquire);
        const frac: f32 = if (t > 0) @min(@as(f32, @floatFromInt(a.load_progress.load(.acquire))) / @as(f32, @floatFromInt(t)), 1) else 0;
        const finished = a.load_done.load(.acquire);
        if (a.load_skin_at == 0 and a.load_parsed.ready.load(.acquire) and (!finished or a.load_result != null)) a.startLoadingSkin();
        if (a.chart_images) |j| if (j.done.load(.acquire)) a.finishChartImages(true);
        if (a.decide_at != 0 and a.tickDecide()) return;
        const elapsed: i64 = @intCast(c.SDL_GetTicks() - a.load_at);
        if (a.load_skin_at != 0 and a.play_skin != null and !a.play_skin.?.plain_loading) {
            a.skin_state.load_frac = frac;
            skin_scene.drawLoading(g, a.play_skin.?, &a.skin_state, elapsed);
        } else {
            if (a.want_decide and a.load_skin_at == 0 and a.cfg.skinFor(.decide).len > 0) return;
            g.textCentered(tr("LOADING"), g.w / 2, g.h * 0.42, 32, gfx.white);
            if (t > 0) {
                g.rect(g.w * 0.3, g.h * 0.72, g.w * 0.4, 8, gfx.rule);
                g.rect(g.w * 0.3, g.h * 0.72, g.w * 0.4 * frac, 8, gfx.white);
            }
        }
        if (!a.load_done.load(.acquire)) return;
        // The skin's own minimum, so its opening plays out; a preview jumps straight in.
        if (a.play_skin) |sk| {
            const least: i64 = std.math.clamp(sk.loadend_ms, 0, 5000);
            if (a.load_skin_at != 0 and a.load_params.start_us == 0 and elapsed < least) return;
        }
        if (a.versus.in_round and c.SDL_GetTicks() < a.versus.start_tick) return;
        c.SDL_WaitThread(a.load_thread, null);
        a.load_thread = null;
        const s = a.load_result orelse {
            a.scene = if (a.exit_after_play) blk: {
                a.running = false;
                break :blk .select;
            } else .select;
            a.sel.status = tr("Could not load that chart");
            // A course without this stage is over, or the next play would count as its next stage.
            if (a.course) |*r| {
                r.arena.deinit();
                a.course = null;
            }
            a.dropChartImages();
            return;
        };
        a.load_result = null;
        a.session = s;
        a.view = .{ .render_state = a.gpa.alloc(u8, s.vis.len) catch {
            s.destroy();
            a.session = null;
            a.scene = .select;
            return;
        } };
        const bga_shown = a.cfg.bga and (!a.cfg.bga_auto or s.params.autoplay or s.params.replay != null);
        a.view.bga = if (bga_shown) bga.Bga.create(a.gpa, a.io, &a.g, s) else null;
        {
            var arena = std.heap.ArenaAllocator.init(a.gpa);
            defer arena.deinit();
            a.view.scratch_right = skin_mod.scratchRight(skin_mod.loadConf(arena.allocator(), a.io, "", skin_mod.playType(s.chart.mode)));
        }
        a.view.best_ex = a.bestEx(&s.chart.sha256, a.load_params.rec.ln_mode, s.params.rec.ln_mode);
        const pace_target = play.paceTarget(a.cfg.pace_target, s.params.practice != null);
        a.view.target_ex = play.targetEx(pace_target, a.view.best_ex, s.chart.total_notes);
        a.view.target_label = play.pace_targets[@min(pace_target, play.pace_targets.len - 1)].label;
        a.skin_state.best_ex = a.view.best_ex;
        a.skin_state.target_ex = a.view.target_ex;
        a.skin_state.target_label = a.view.target_label;
        // The clock carries on from the loading screen, so what it opened is not replayed.
        if (a.load_skin_at != 0 and a.play_skin != null) a.skin_state.load_ms = elapsed;
        a.skin_state.fromSession(s, &a.cfg);
        if (a.load_skin_at == 0) a.reloadSkins(s.chart.mode);
        // Play and the result draw these too, and nothing polls the job after this.
        a.finishChartImages(true);
        a.scene = .play;
        // As beatoraja, the load's end is heard; a preview jumping in partway stays quiet.
        if (a.load_params.start_us == 0) if (a.sfx_play_ready) |e| if (e.ready.load(.acquire) and e.data.len > 0) {
            a.engine.uiPlay(skin_sound.nextSlot(&a.sfx_slot), e.data, false, a.cfg.sfx_volume);
        };
        input.setPollRate(if (s.params.autoplay or s.params.replay != null) 0 else a.cfg.input_poll_hz);
        s.start(versus.lateUs(&a.versus, c.SDL_GetTicks()));
    }

    fn dropChartImages(a: *App) void {
        a.finishChartImages(false);
        for (a.chartImageSlots()) |img| {
            if (img.*) |tex| a.g.destroyTexture(tex);
            img.* = null;
        }
    }

    fn reloadSkins(a: *App, mode: core.types.Mode) void {
        a.dropSkins();
        a.skin_mode = mode;
        var tmp = std.heap.ArenaAllocator.init(a.gpa);
        defer tmp.deinit();
        const al = tmp.allocator();
        a.loadSkinSfx(al);
        const load_ctx = a.skin_state.loadCtx();
        const env = a.luaEnv(&load_ctx, true);
        a.play_skin = a.loadSlot(al, skin_mod.playSlot(mode), mode, env);
        a.decide_skin = a.loadSlot(al, .decide, mode, env);
        a.result_skin = a.loadSlot(al, .result, mode, env);
    }

    fn luaEnv(a: *App, load_ctx: *const skin_mod.model.Ctx, audio_quiet: bool) skin_mod.LuaEnv {
        return .{ .ctx = load_ctx, .audio = .{ .ud = a, .f = App.skinAudio }, .audio_quiet = audio_quiet };
    }

    fn loadSlot(a: *App, al: std.mem.Allocator, slot: config.SkinSlot, mode: core.types.Mode, env: skin_mod.LuaEnv) ?*skin_mod.model.Skin {
        const root = a.cfg.skinFor(slot);
        if (root.len == 0) return null;
        const p = skin_mod.find(al, a.io, root, skin_mod.slotType(slot)) orelse {
            std.log.warn("no skin of the needed type under {s}", .{root});
            return null;
        };
        return skin_mod.load(a.gpa, a.io, &a.g, p, mode, noOption, skin_mod.loadConf(al, a.io, root, skin_mod.slotType(slot)), env) catch |e| {
            std.log.err("skin {s}: {t}", .{ p, e });
            return null;
        };
    }

    pub fn syncSelectSkin(a: *App) void {
        const root = a.cfg.skinFor(.select);
        if (a.select_skin_loaded and std.mem.eql(u8, root, a.select_skin_root)) return;
        a.dropSelectSkin();
        a.select_skin_loaded = true;
        a.select_skin_root = a.gpa.dupe(u8, root) catch "";
        var tmp = std.heap.ArenaAllocator.init(a.gpa);
        defer tmp.deinit();
        const al = tmp.allocator();
        a.loadSkinSfx(al);
        a.select_state = .{};
        const load_ctx = a.select_state.loadCtx();
        a.select_skin = a.loadSlot(al, .select, .beat7, a.luaEnv(&load_ctx, true));
    }

    fn dropSelectSkin(a: *App) void {
        if (a.select_skin) |sk| skin_mod.destroy(a.gpa, sk);
        a.select_skin = null;
        if (a.select_skin_root.len > 0) a.gpa.free(a.select_skin_root);
        a.select_skin_root = "";
    }

    /// Beatoraja builds the result skin on entry, and skins read the score while loading.
    pub fn reloadResultSkin(a: *App) void {
        const root = a.cfg.skinFor(.result);
        if (root.len == 0) return;
        var tmp = std.heap.ArenaAllocator.init(a.gpa);
        defer tmp.deinit();
        const al = tmp.allocator();
        const p = skin_mod.find(al, a.io, root, skin_mod.type_result) orelse return;
        const load_ctx = a.skin_state.loadCtx();
        const fresh = skin_mod.load(a.gpa, a.io, &a.g, p, a.skin_mode, noOption, skin_mod.loadConf(al, a.io, root, skin_mod.type_result), a.luaEnv(&load_ctx, false)) catch return;
        if (a.result_skin) |old| skin_mod.destroy(a.gpa, old);
        a.result_skin = fresh;
    }

    fn dropSkins(a: *App) void {
        if (a.play_skin) |sk| skin_mod.destroy(a.gpa, sk);
        if (a.result_skin) |sk| skin_mod.destroy(a.gpa, sk);
        if (a.decide_skin) |sk| skin_mod.destroy(a.gpa, sk);
        a.decide_skin = null;
        a.play_skin = null;
        a.result_skin = null;
    }

    fn pollSkin(a: *App, mode: core.types.Mode) void {
        const now = c.SDL_GetTicks();
        if (now - a.skin_poll_ms < 1000) return;
        a.skin_poll_ms = now;
        const sk = a.play_skin orelse return;
        if (skin_mod.changed(sk, a.io, a.g.w / a.g.h)) a.reloadSkins(mode);
    }

    fn tickPlay(a: *App) void {
        const s = a.session.?;
        a.pollSkin(s.chart.mode);
        const snap = if (a.play_skin) |sk|
            skin_scene.drawPlay(&a.g, sk, &a.skin_state, s, &a.view, &a.cfg)
        else
            a.view.draw(&a.g, s, &a.cfg);
        if (a.pause.open) return pause.tick(a);
        if (s.params.practice) |p| {
            var buf: [48]u8 = undefined;
            a.g.textRight(i18n.bufPrint(&buf, "PRACTICE {d}%", .{p.freq}) catch "", a.g.w - 22 * a.g.h / 720, 52 * a.g.h / 720, a.g.scaled(16), gfx.amber);
        }
        if (s.was_paused and a.record) a.g.textRight(tr("NOT RECORDED: PAUSED"), a.g.w - 22 * a.g.h / 720, 52 * a.g.h / 720, a.g.scaled(16), gfx.amber);
        if (s.canSkip(snap)) {
            var key_buf: [32]u8 = undefined;
            var hint_buf: [48]u8 = undefined;
            a.g.textCentered(i18n.bufPrint(&hint_buf, "{s}: SKIP", .{select.guideKey(a, a.cfg.start_select[0], "ENTER", &key_buf)}) catch "", a.g.w / 2, a.g.h * 0.5, a.g.scaled(28), gfx.white);
        }
        // The drawn snapshot can be a tick older than the end, and would lose the last judgements.
        if (s.done.load(.acquire)) a.finishPlay(s.snapshot(), true);
    }

    pub fn retryPlay(a: *App) void {
        const s = a.session.?;
        s.stop();
        input.setPollRate(0);
        a.pause = .{};
        a.gpa.free(a.view.render_state);
        if (a.view.bga) |b| b.destroy();
        a.view = .{ .render_state = &.{} };
        s.destroy();
        a.session = null;
        a.startPlay(a.load_params, a.record);
    }

    /// `natural` is false when the player quit: quitting never counts as a clear, but the play still counts.
    pub fn finishPlay(a: *App, snap: session_mod.Snapshot, natural: bool) void {
        const s = a.session.?;
        a.pause = .{};
        s.stop();
        input.setPollRate(0);
        if (!natural or snap.failed) a.sfxOr(a.sfx_play_stop, .back);
        const practised = s.params.practice != null;
        const continues = a.course != null and course_mod.stageDone(a, s, snap, natural);
        if (!continues and !practised) {
            result.capture(a, s, snap, natural);
            _ = a.kept.reset(.retain_capacity);
            a.skin_state.keepChart(a.kept.allocator());
        }
        a.gpa.free(a.view.render_state);
        if (a.view.bga) |b| b.destroy();
        a.view = .{ .render_state = &.{} };
        s.destroy();
        a.session = null;
        if (a.exit_after_play) {
            a.running = false;
            return;
        }
        if (continues) {
            course_mod.next(a);
            return;
        }
        if (practised) {
            a.practice.open = true;
            a.scene = .select;
            return;
        }
        if (a.course != null) course_mod.finish(a);
        a.scene = .result;
        select.reload(a);
    }

    fn sdlKey(a: *App, sc: u32, ts: u64, down: bool, repeat: bool) void {
        if (sc == c.SDL_SCANCODE_F12) {
            if (down and !repeat) a.shot_wanted = true;
            return;
        }
        if (select.pad(a, @intCast(sc), down, repeat)) return;
        if (a.scene == .play) {
            if (!repeat and !input.direct_keyboard.load(.acquire) and sc < input.joy_base) {
                input.push(.{ .mono_ns = ts, .code = @intCast(sc), .down = down });
            }
            if (down and !repeat and a.pause.open) return pause.key(a, sc);
            if (down and !repeat) {
                switch (sc) {
                    c.SDL_SCANCODE_ESCAPE => {
                        const s = a.session.?;
                        const snap = s.snapshot();
                        // Past the last note there is nothing left to pause for, and leaving keeps the clear.
                        if (s.canSkip(snap)) a.finishPlay(snap, true) else pause.open(a);
                    },
                    c.SDL_SCANCODE_RETURN => {
                        const s = a.session.?;
                        const snap = s.snapshot();
                        if (s.canSkip(snap)) a.finishPlay(snap, true);
                    },
                    c.SDL_SCANCODE_LEFT, c.SDL_SCANCODE_RIGHT => {
                        // Section search: autoplay only, because a seek rebuilds the sim from zero.
                        const s = a.session.?;
                        if (s.params.autoplay) {
                            const step: i64 = if (sc == c.SDL_SCANCODE_LEFT) -5_000_000 else 5_000_000;
                            s.seek(@max(s.snapshot().time_us + step, 0));
                        }
                    },
                    c.SDL_SCANCODE_UP => a.cfg.green_ms += 25,
                    c.SDL_SCANCODE_DOWN => a.cfg.green_ms = @max(a.cfg.green_ms, 75) - 25,
                    c.SDL_SCANCODE_PAGEUP => a.moveCover(0.02),
                    c.SDL_SCANCODE_PAGEDOWN => a.moveCover(-0.02),
                    c.SDL_SCANCODE_HOME => a.cfg.setLift(a.cfg.lift + 0.02),
                    c.SDL_SCANCODE_END => a.cfg.setLift(a.cfg.lift - 0.02),
                    c.SDL_SCANCODE_INSERT => a.cfg.setHidden(a.cfg.hidden + 0.02),
                    c.SDL_SCANCODE_DELETE => a.cfg.setHidden(a.cfg.hidden - 0.02),
                    else => {},
                }
            }
            return;
        }
        if (!down) return;
        switch (a.scene) {
            .select => select.key(a, sc),
            .result => result.key(a, sc),
            .settings => settings.key(a, sc),
            .skinconf => skinconf.key(a, sc),
            .skinslots => skinslots.key(a, sc),
            .versus => versus.key(a, sc),
            .loading => if (!repeat) a.decideKey(sc),
            else => {},
        }
    }

    /// Hidden while playing; the pause menu and autoplay's click-to-seek still need it.
    fn applyCursor(a: *App) void {
        const autoplay = if (a.session) |s| s.params.autoplay else false;
        const hide = a.scene == .play and !a.pause.open and !autoplay;
        if (hide == a.cursor_hidden) return;
        a.cursor_hidden = hide;
        _ = if (hide) c.SDL_HideCursor() else c.SDL_ShowCursor();
    }

    fn applyMouse(a: *App) void {
        const g = &a.g;
        defer {
            g.clicked = false;
            g.right_clicked = false;
            g.wheel = 0;
            a.click_key = null;
        }
        if (a.scene == .play or a.scene == .loading) return;
        if (a.scene == .result and g.clicked) a.click_key = c.SDL_SCANCODE_RETURN;
        if (g.right_clicked) {
            if (a.scene == .settings and a.set.capture_slot != null) {
                settings.captured(a, c.SDL_SCANCODE_ESCAPE);
            } else a.sdlKey(c.SDL_SCANCODE_ESCAPE, 0, true, false);
        }
        if (a.click_key) |k| a.sdlKey(k, 0, true, false);
        if (a.set.capture_slot != null and a.scene == .settings) return;
        var steps: i32 = @intFromFloat(@round(g.wheel));
        while (steps != 0) : (steps -= std.math.sign(steps)) {
            a.sdlKey(if (steps > 0) c.SDL_SCANCODE_UP else c.SDL_SCANCODE_DOWN, 0, true, false);
        }
    }

    fn clickSeek(a: *App, x: f32) void {
        const s = a.session orelse return;
        if (!s.params.autoplay or a.g.w <= 0) return;
        s.seek(@intFromFloat(@as(f64, x / a.g.w) * @as(f64, @floatFromInt(s.chart.last_time_us))));
    }

    fn pump(a: *App) void {
        var ev: c.SDL_Event = undefined;
        const read_ns = c.SDL_GetTicksNS();
        defer input.sdl_read_ns.store(read_ns, .release);
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => a.running = false,
                c.SDL_EVENT_WINDOW_FOCUS_GAINED => input.focused.store(true, .release),
                c.SDL_EVENT_WINDOW_FOCUS_LOST => input.focused.store(false, .release),
                c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                    const down = ev.type == c.SDL_EVENT_KEY_DOWN;
                    if (a.set.capture_slot != null and down and a.scene == .settings) {
                        settings.captured(a, @intCast(ev.key.scancode));
                    } else a.sdlKey(ev.key.scancode, ev.key.timestamp, down, ev.key.repeat);
                },
                c.SDL_EVENT_TEXT_INPUT => if (a.text_active) a.typeText(std.mem.span(ev.text.text)),
                c.SDL_EVENT_MOUSE_MOTION => {
                    a.g.mx = ev.motion.x * a.g.pixelDensity();
                    a.g.my = ev.motion.y * a.g.pixelDensity();
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    a.g.mx = ev.button.x * a.g.pixelDensity();
                    a.g.my = ev.button.y * a.g.pixelDensity();
                    const pressed = ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN;
                    if (ev.button.button == c.SDL_BUTTON_LEFT) {
                        a.g.down = pressed;
                        if (pressed) {
                            a.g.clicked = true;
                            if (a.scene == .play and !a.pause.open) a.clickSeek(ev.button.x);
                        }
                    } else if (ev.button.button == c.SDL_BUTTON_RIGHT and pressed) a.g.right_clicked = true;
                },
                c.SDL_EVENT_MOUSE_WHEEL => a.g.wheel += ev.wheel.y,
                c.SDL_EVENT_JOYSTICK_ADDED => _ = c.SDL_OpenJoystick(ev.jdevice.which),
                c.SDL_EVENT_JOYSTICK_BUTTON_DOWN, c.SDL_EVENT_JOYSTICK_BUTTON_UP => {
                    if (ev.jbutton.button >= input.joy_axis_base - input.joy_base) continue;
                    const code = input.joy_base + @as(u16, ev.jbutton.button);
                    const down = ev.type == c.SDL_EVENT_JOYSTICK_BUTTON_DOWN;
                    if (a.set.capture_slot != null and down and a.scene == .settings) {
                        settings.captured(a, code);
                    } else a.joyInput(code, ev.jbutton.timestamp, down);
                },
                c.SDL_EVENT_JOYSTICK_AXIS_MOTION => a.joyAxis(ev.jaxis.axis, ev.jaxis.value, ev.jaxis.timestamp),
                else => {},
            }
        }
        a.joyAxisRelease();
        select.tickPad(a, c.SDL_GetTicks());
    }

    // Turntables report an ever-moving axis: any movement is a press, a short pause in it the release.
    const axis_release_ns = 60 * std.time.ns_per_ms;

    fn joyInput(a: *App, code: u16, ts: u64, down: bool) void {
        input.push(.{ .mono_ns = ts, .code = code, .down = down });
        _ = select.pad(a, code, down, false);
    }

    fn joyAxis(a: *App, axis: u8, value: i16, ts: u64) void {
        if (axis >= 16) return;
        const prev = a.joy_axis[axis];
        const delta = @as(i32, value) - prev;
        if (@abs(delta) < 8) return;
        a.joy_axis[axis] = value;
        const wrapped = if (delta > 32768) delta - 65536 else if (delta < -32768) delta + 65536 else delta;
        const pos = wrapped > 0;
        const code = input.joy_axis_base + @as(u16, axis) * 2 + @intFromBool(!pos);
        if (a.set.capture_slot != null and a.scene == .settings) {
            settings.captured(a, code);
            return;
        }
        const idx: usize = @as(usize, axis) * 2 + @intFromBool(!pos);
        const other = idx ^ 1;
        if (a.joy_axis_at[other] != 0) {
            a.joyInput(input.joy_axis_base + @as(u16, @intCast(other)), ts, false);
            a.joy_axis_at[other] = 0;
        }
        if (a.joy_axis_at[idx] == 0) a.joyInput(code, ts, true);
        a.joy_axis_at[idx] = ts;
    }

    fn joyAxisRelease(a: *App) void {
        const now = c.SDL_GetTicksNS();
        for (&a.joy_axis_at, 0..) |*at, i| {
            if (at.* != 0 and now -| at.* > axis_release_ns) {
                a.joyInput(input.joy_axis_base + @as(u16, @intCast(i)), now, false);
                at.* = 0;
            }
        }
    }

    pub fn saveConfig(a: *App) void {
        config.save(a.gpa, a.io, a.cfg) catch |e| std.log.err("config save failed: {t}", .{e});
    }

    fn pressShotKey(a: *App) void {
        const age = c.SDL_GetTicks() - a.start_ms;
        if (age < a.shot_key_at) return;
        const name = a.shot_keys.next() orelse return;
        var buf: [32]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return;
        a.click_key = c.SDL_GetScancodeFromName(z.ptr);
        a.shot_key_at = age + shot_key_gap_ms;
    }

    fn shot(a: *App) void {
        if (!a.g.saveShot(a.shot_path.?.ptr)) std.log.warn("--shot saved nothing", .{});
        a.running = false;
    }

    fn saveScreenshot(a: *App) void {
        var ok = false;
        defer a.showNotice(if (ok) tr("Screenshot saved") else tr("Screenshot failed"));
        const path = screenshotPath(a.gpa, a.io) catch |e| {
            std.log.err("screenshot failed: {t}", .{e});
            a.g.present();
            return;
        };
        defer a.gpa.free(path);
        ok = a.g.saveShot(path.ptr);
        if (!ok) std.log.err("screenshot failed: {s}", .{c.SDL_GetError()});
    }

    fn showNotice(a: *App, text: []const u8) void {
        a.notice = text;
        a.notice_until = c.SDL_GetTicks() + 2000;
    }

    fn drawNotice(a: *App) void {
        if (c.SDL_GetTicks() >= a.notice_until) return;
        const u = a.g.h / 720;
        const size = a.g.scaled(14);
        const w = a.g.measure(a.notice, size) + 24 * u;
        a.g.panel(a.g.w - w - 12 * u, 12 * u, w, 32 * u, "");
        a.g.textRight(a.notice, a.g.w - 24 * u, 19 * u, size, gfx.sky);
    }

    pub fn run(a: *App) void {
        a.start_ms = c.SDL_GetTicks();
        a.sfx_thread = c.SDL_CreateThread(sfxThread, "sfx", a);
        while (a.running) {
            if (a.cfg.fps_limit > 0) {
                const now = c.SDL_GetTicksNS();
                if (a.next_frame_ns > now) c.SDL_DelayPrecise(a.next_frame_ns - now);
                a.next_frame_ns = @max(a.next_frame_ns, now) + 1_000_000_000 / @as(u64, a.cfg.fps_limit);
            }
            a.g.waitFrame();
            // Key events carry their own timestamps, so a finer poll wouldn't change judgement.
            const pump_now = c.SDL_GetTicksNS();
            if (pump_now - a.last_pump_ns >= 500_000) {
                a.last_pump_ns = pump_now;
                a.pump();
            }
            a.tickBgm();
            a.reapCanceledLoad();
            a.pollEditor();
            settings.pollUpdate(a);
            a.g.beginFrame();
            versus.tick(a);
            const scene_now = a.scene;
            switch (scene_now) {
                .select => {
                    if (a.last_scene != .select) a.select_shown_at = c.SDL_GetTicks();
                    select.draw(a);
                    practice.draw(a);
                    if (a.select_skin == null) {
                        const alpha = fadeInAlpha(c.SDL_GetTicks() - a.select_shown_at);
                        if (alpha > 0) a.g.rect(0, 0, a.g.w, a.g.h, .{ .r = 0, .g = 0, .b = 0, .a = alpha });
                    }
                },
                .loading => {
                    a.tickLoading();
                    versus.drawCountdown(a);
                },
                .play => {
                    versus.fillTarget(a);
                    a.tickPlay();
                    versus.drawPlayBoard(a);
                },
                .result => {
                    result.draw(a);
                    versus.drawResult(a);
                },
                .settings => {
                    a.g.backdrop();
                    settings.draw(a);
                },
                .skinconf => {
                    a.g.backdrop();
                    skinconf.draw(a);
                },
                .skinslots => {
                    a.g.backdrop();
                    skinslots.draw(a);
                },
                .versus => {
                    a.g.backdrop();
                    versus.draw(a);
                },
            }
            a.last_scene = scene_now;
            a.pressShotKey();
            a.applyMouse();
            a.applyCursor();
            if (a.shot_path != null and c.SDL_GetTicks() - a.start_ms >= a.shot_after_ms) a.shot();
            if (a.shot_wanted) {
                a.shot_wanted = false;
                a.saveScreenshot();
            } else {
                a.drawNotice();
                a.g.present();
            }
        }
        // Closing the window past the last note keeps the clear, like leaving with Esc there.
        if (a.scene == .play) if (a.session) |s| {
            a.exit_after_play = true;
            const snap = s.snapshot();
            a.finishPlay(snap, s.canSkip(snap));
        };
        if (a.view.bga) |b| b.destroy();
        a.view.bga = null;
        if (a.session) |s| s.destroy();
        a.session = null;
        if (a.view.render_state.len > 0) a.gpa.free(a.view.render_state);
        a.dropSkins();
        a.saveConfig();
        if (a.bgm_thread) |t| c.SDL_WaitThread(t, null);
        if (a.sfx_thread) |t| c.SDL_WaitThread(t, null);
    }
};

const select_fade_ms = 300;
fn screenshotPath(gpa: std.mem.Allocator, io: std.Io) ![:0]u8 {
    const dir = try fs.dataDir(gpa);
    defer gpa.free(dir);
    const folder = try std.fmt.allocPrint(gpa, "{s}screenshots", .{dir});
    defer gpa.free(folder);
    try fs.mkdirs(io, folder);
    var ns: c.SDL_Time = 0;
    var t: c.SDL_DateTime = undefined;
    if (!c.SDL_GetCurrentTime(&ns) or !c.SDL_TimeToDateTime(ns, &t, true)) return error.NoClock;
    return std.fmt.allocPrintSentinel(gpa, "{s}/actuon-{d}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d:0>3}.bmp", .{ folder, @as(u32, @intCast(t.year)), @as(u32, @intCast(t.month)), @as(u32, @intCast(t.day)), @as(u32, @intCast(t.hour)), @as(u32, @intCast(t.minute)), @as(u32, @intCast(t.second)), @as(u32, @intCast(@divTrunc(t.nanosecond, 1_000_000))) }, 0);
}

const shot_keys_start_ms = 2000;
const shot_key_gap_ms = 300;

fn fadeInAlpha(age_ms: u64) u8 {
    if (age_ms >= select_fade_ms) return 0;
    return @intCast(255 - age_ms * 255 / select_fade_ms);
}

test "the song select fade starts black and clears" {
    try std.testing.expectEqual(@as(u8, 255), fadeInAlpha(0));
    try std.testing.expectEqual(@as(u8, 128), fadeInAlpha(150));
    try std.testing.expectEqual(@as(u8, 0), fadeInAlpha(select_fade_ms));
}

/// Load-time #IF conditions on runtime state are treated as off: state options re-evaluate per draw.
fn noOption(_: i32) bool {
    return false;
}

pub const Options = struct {
    play_path: ?[]const u8 = null,
    autoplay: bool = false,
    replay: ?[]const u8 = null,
    shot: ?[:0]const u8 = null,
    shot_after_ms: u64 = 3000,
    shot_keys: []const u8 = "",
    decide: bool = false,
    null_audio: bool = false,
    start_us: i64 = 0,
    preview: ?editor.Command = null,
};

fn setWindowIcon(win: *c.SDL_Window) void {
    const png = @embedFile("app_icon");
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const px = c.stbi_load_from_memory(png.ptr, png.len, &w, &h, &n, 4) orelse return;
    defer c.stbi_image_free(px);
    const surf = c.SDL_CreateSurfaceFrom(w, h, c.SDL_PIXELFORMAT_RGBA32, px, w * 4) orelse return;
    defer c.SDL_DestroySurface(surf);
    _ = c.SDL_SetWindowIcon(win, surf);
}

pub fn main(gpa: std.mem.Allocator, io: std.Io, opts: Options) !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK | c.SDL_INIT_EVENTS)) return error.SdlInit;
    defer c.SDL_Quit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const cfg = config.load(arena.allocator(), io);
    i18n.current = i18n.resolve(cfg.language);
    const flags: u64 = c.rb_window_flags() | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | (if (cfg.fullscreen) @as(u64, c.SDL_WINDOW_FULLSCREEN) else 0);
    const win = c.SDL_CreateWindow("actuon", @intCast(cfg.width), @intCast(cfg.height), flags) orelse return error.SdlWindow;
    setWindowIcon(win);

    const engine = try engine_mod.Engine.create(gpa);
    defer engine.destroy();
    engine.gain = cfg.volume;
    try engine.open(cfg.audio_rate, cfg.audio_frames, opts.null_audio, cfg.audio_device);
    const direct_input = input.startDirect();

    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.* = .{
        .gpa = gpa,
        .io = io,
        .arena = &arena,
        .cfg = cfg,
        .g = try gfx.Gfx.init(gpa, win),
        .engine = engine,
        .db = try db_mod.openMain(gpa),
        .sel = .{},
    };
    defer app.db.close();
    // Once a start, as this build may read charts the last one could not.
    app.db.exec("DELETE FROM unparsed") catch |e| std.log.err("broken charts not retried: {t}", .{e});
    db_mod.setLnMode(app.db, app.cfg.ln_mode) catch |e| std.log.err("LN mode not applied to scores: {t}", .{e});
    defer app.g.deinit();
    defer app.text.deinit(gpa);
    if (opts.shot) |p| {
        app.shot_path = p;
        app.shot_after_ms = opts.shot_after_ms;
        app.shot_keys = std.mem.tokenizeScalar(u8, opts.shot_keys, ',');
    }
    app.g.setVsync(cfg.vsync);
    app.g.setReflex(cfg.reflex);
    app.g.upscale_on = cfg.bga_upscale;
    app.kept = .init(gpa);
    defer app.kept.deinit();
    app.sounds = .{ .gpa = gpa, .io = io, .engine = app.engine, .slot = &app.sfx_slot };
    defer app.sounds.deinit();
    app.preview = .{ .gpa = gpa, .io = io, .rate = app.engine.rate };
    defer app.preview.deinit();
    defer app.freeMenuSounds();
    // Voices read the buffers freed above until the writer stops; destroy closes again harmlessly.
    defer engine.close();
    // Textures stay cached, so a play's skins come up without the wait.
    app.reloadSkins(.beat7);
    app.dropSkins();
    app.syncSelectSkin();
    defer app.dropSelectSkin();
    defer skin_mod.clearTextures(gpa, &app.g);
    select.init(app);
    defer select.deinit(app);
    defer result.dropBoard(app);
    if (opts.play_path) |p| {
        app.exit_after_play = opts.shot == null;
        var params: session_mod.Params = .{ .path = p, .autoplay = opts.autoplay, .rec = config.playOptions(&app.cfg, 0), .start_us = opts.start_us };
        if (opts.replay) |rp| {
            const bytes = try fs.readAlloc(arena.allocator(), io, rp, 1 << 28);
            const r = try core.replay.decode(arena.allocator(), bytes);
            params.replay = r;
            params.rec = r;
        }
        if (opts.decide) app.decidePlay(params, true) else app.startPlay(params, true);
    }
    if (@import("builtin").os.tag == .linux and !direct_input) {
        std.log.warn("no readable keyboard under /dev/input: keys come from the compositor, a frame late", .{});
        app.sel.status = tr("Reading /dev/input needs the input group: run sudo usermod -aG input $USER, then log in again.");
    }
    if (config.set_aside) app.sel.status = tr("Settings could not be read: moved to config.json.bad");
    if (config.stuck) app.sel.status = tr("Settings could not be read or moved: changes this run are not saved");
    if (crash.takePrevious(arena.allocator(), io)) app.sel.status = tr("The last run crashed: see crash-last.txt in the data folder");
    if (opts.preview) |cmd| if (!cmd.stop) app.startPreview(cmd.file, cmd.measure);
    // Captures stay offline, so every run draws the same version row.
    if (app.shot_path == null) app.set.update = update.start(gpa, io);
    app.run();
    const update_ended = if (app.set.update) |j| j.abandon() else true;
    // A thread stuck on a dead connection still allocates, and the allocator's shutdown check would crash it.
    if (!ir.waitForThreads() or !update_ended) std.process.exit(0);
    skinconf.close(app);
    skinslots.close(app);
    // Frees the room's chart before the allocator's shutdown check.
    versus.leave(app);
    var hb = std.heap.ArenaAllocator.init(gpa);
    defer hb.deinit();
    editor.clearHeartbeat(hb.allocator(), io);
    app.load_parsed.cancel.store(true, .release);
    if (app.load_thread) |t| c.SDL_WaitThread(t, null);
    // Quit during decide or loading: nothing took what the loader made.
    if (app.load_result) |loaded| loaded.destroy();
    app.dropChartImages();
}

test "a chart image claiming to be huge is refused before decoding" {
    // A TGA header: 8 bit grey, width and height at bytes 12 to 15.
    var tga: [18]u8 = @splat(0);
    tga[2] = 3;
    tga[16] = 8;
    tga[12] = 0xff;
    tga[13] = 0x3f;
    tga[14] = 0xff;
    tga[15] = 0x3f;
    try std.testing.expect(!gfx.imageFits(&tga, gfx.max_chart_image_px));
    tga[13] = 0;
    tga[15] = 0;
    try std.testing.expect(gfx.imageFits(&tga, gfx.max_chart_image_px));
    try std.testing.expect(!gfx.imageFits("not an image", gfx.max_chart_image_px));
}

test "a canceled chart image job decodes nothing more" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var tga: [19]u8 = @splat(0);
    tga[2] = 3;
    tga[12] = 1;
    tga[14] = 1;
    tga[16] = 8;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.tga", .data = &tga });
    for ([_]bool{ false, true }) |cancel| {
        var j: ChartImages = .{ .gpa = gpa, .io = std.testing.io, .arena = .init(gpa), .dir = dir };
        defer j.arena.deinit();
        j.names[0] = "a.tga";
        j.cancel.store(cancel, .release);
        _ = ChartImages.run(&j);
        try std.testing.expectEqual(cancel, j.px[0] == null);
        if (j.px[0]) |p| c.stbi_image_free(p);
    }
}
