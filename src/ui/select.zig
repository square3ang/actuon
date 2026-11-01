//! Song select: a browsable tree of library folders, plus search.
const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const gfx = @import("gfx.zig");
const app_mod = @import("app.zig");
const result = @import("result.zig");
const course_mod = @import("course.zig");
const table = @import("../table/table.zig");
const ir = @import("../net/ir.zig");
const download = @import("../net/download.zig");
const fs = @import("../platform/fs.zig");
const config = @import("../game/config.zig");
const db_mod = @import("../db/db.zig");
const skin_scene = @import("../skin/scene.zig");
const session_mod = @import("../game/session.zig");
const preview_mod = @import("../audio/preview.zig");
const App = app_mod.App;

pub const Row = struct {
    label: []const u8,
    kind: enum { group, folder, song, table, level, course, missing } = .song,
    song: ?db_mod.Song = null,
    /// Folder, table and level rows: what to open. Missing rows: the chart's MD5.
    target: []const u8 = "",
    extra: []const u8 = "",
    id: i64 = 0,
};

pub const State = struct {
    arena: ?std.heap.ArenaAllocator = null,
    rows: []Row = &.{},
    cursor: usize = 0,
    view: enum { root, library, folder, table, level, courses } = .root,
    table_url: []const u8 = "",
    table_buf: [1024]u8 = undefined,
    level: []const u8 = "",
    level_buf: [64]u8 = undefined,
    /// Empty means the root. Lives in folder_buf, because rows are rebuilt under it.
    folder: []const u8 = "",
    folder_buf: [4096]u8 = undefined,
    search: []const u8 = "",
    searching: bool = false,
    status: []const u8 = "",
    status_buf: [64]u8 = undefined,
    autoplay: bool = false,
    sort: u8 = 0,
    scan_thread: ?*c.SDL_Thread = null,
    scan_progress: std.atomic.Value(u32) = .init(0),
    scan_done: std.atomic.Value(bool) = .init(false),
    last_scan_ms: u64 = 0,
    download: ?*download.Job = null,
    download_buf: [64]u8 = undefined,
    download_seen: u64 = 0,
    download_shown: u64 = 0,
    download_moved_ms: u64 = 0,
    scroll: f32 = 0,
    /// The selected chart, since when, and the preview it was found to have once the cursor rested.
    preview_key: u64 = 0,
    preview_since: u64 = 0,
    preview_checked: bool = true,
    preview_buf: [4096]u8 = undefined,
    preview_len: usize = 0,
    jacket: ?*gfx.Texture = null,
    jacket_key: u64 = 0,
    jacket_since: u64 = 0,
    jacket_tried: bool = false,
    /// The image being faded out, drawn under `jacket` until the fade ends.
    jacket_old: ?*gfx.Texture = null,
    jacket_fade_at: u64 = 0,
    scroll_at_ns: u64 = 0,
    jacket_job: ?*JacketJob = null,
    /// Small copies of the images behind the wheel's cards, most recently drawn kept.
    card_art: std.ArrayList(CardArt) = .empty,
    card_job: ?*JacketJob = null,
    query: ?*ir.Query = null,
    query_title: []const u8 = "",
    table_thread: ?*c.SDL_Thread = null,
    table_done: std.atomic.Value(bool) = .init(false),
    table_failed: std.atomic.Value(u32) = .init(0),
    /// Set to fetch one table instead of every configured one.
    table_only: ?[]const u8 = null,
    stats: db_mod.ScanStats = .{},
};

const random_names = [_][]const u8{ "OFF", "MIRROR", "RANDOM", "R-RANDOM", "S-RANDOM" };
const gauge_names = [_][]const u8{ "ASSIST EASY", "EASY", "NORMAL", "HARD", "EX HARD", "HAZARD", "GAS" };
const hs_names = [_][]const u8{ "START", "MAX", "MAIN", "OFF" };
const sort_names = [_][]const u8{ "TITLE", "LEVEL", "CLEAR", "EX" };
const scan_interval_ms = 30_000;

pub fn init(a: *App) void {
    reload(a);
    startScan(a);
}

pub fn deinit(a: *App) void {
    const s = &a.sel;
    if (s.scan_thread) |t| c.SDL_WaitThread(t, null);
    if (s.table_thread) |t| c.SDL_WaitThread(t, null);
    if (s.jacket_job) |j| j.destroy();
    if (s.jacket) |t| a.g.destroyTexture(t);
    if (s.jacket_old) |t| a.g.destroyTexture(t);
    if (s.card_job) |j| j.destroy();
    for (s.card_art.items) |art| if (art.tex) |t| a.g.destroyTexture(t);
    s.card_art.deinit(a.gpa);
    closeQuery(a);
    if (s.download) |j| j.abandon();
    if (s.search.len > 0) a.gpa.free(s.search);
    if (s.arena) |*ar| ar.deinit();
}

fn scanThread(ud: ?*anyopaque) callconv(.c) c_int {
    const a: *App = @ptrCast(@alignCast(ud));
    defer a.sel.scan_done.store(true, .release);
    const d = db_mod.openMain(a.gpa) catch return 1;
    defer d.close();
    a.sel.stats = db_mod.scan(a.gpa, d, a.cfg.roots, &a.sel.scan_progress) catch |e| {
        std.log.err("scan failed: {t}", .{e});
        return 1;
    };
    return 0;
}

pub fn startScan(a: *App) void {
    const s = &a.sel;
    if (s.scan_thread != null or a.cfg.roots.len == 0) return;
    s.scan_done.store(false, .release);
    s.scan_progress.store(0, .release);
    s.scan_thread = c.SDL_CreateThread(scanThread, "scan", a);
    s.last_scan_ms = c.SDL_GetTicks();
}

/// Poll-based watcher: rescans periodically while the player is browsing, never during play.
fn tickScan(a: *App) void {
    const s = &a.sel;
    if (s.scan_thread) |t| {
        if (s.scan_done.load(.acquire)) {
            c.SDL_WaitThread(t, null);
            s.scan_thread = null;
            s.last_scan_ms = c.SDL_GetTicks();
            if (s.stats.parsed > 0 or s.stats.removed > 0) reload(a);
        }
    } else if (c.SDL_GetTicks() - s.last_scan_ms > scan_interval_ms) startScan(a);
    _ = tickTables(a);
}

/// Collects a finished fetch and returns true once when it does; `status` then holds the outcome.
pub fn tickTables(a: *App) bool {
    const s = &a.sel;
    const t = s.table_thread orelse return false;
    if (!s.table_done.load(.acquire)) return false;
    c.SDL_WaitThread(t, null);
    s.table_thread = null;
    const failed = s.table_failed.load(.acquire);
    const total = if (s.table_only != null) 1 else a.cfg.tables.len;
    s.status = if (failed == 0) "Tables updated" else std.fmt.bufPrint(&s.status_buf, "{d} of {d} tables failed to load", .{ failed, total }) catch "Tables failed to load";
    reload(a);
    return true;
}

/// Rebuilds the visible rows from the DB; keeps the cursor on the same index.
pub fn reload(a: *App) void {
    const s = &a.sel;
    if (s.arena) |*ar| ar.deinit();
    s.arena = std.heap.ArenaAllocator.init(a.gpa);
    const al = s.arena.?.allocator();
    s.rows = buildRows(a, al) catch |e| blk: {
        std.log.err("list failed: {t}", .{e});
        break :blk &.{};
    };
    if (s.cursor >= s.rows.len) s.cursor = if (s.rows.len == 0) 0 else s.rows.len - 1;
}

fn orderBy(sort: u8) []const u8 {
    return switch (sort) {
        1 => " ORDER BY CAST(s.level AS INTEGER), s.title",
        2 => " ORDER BY COALESCE(c.clear,0) DESC, s.title",
        3 => " ORDER BY COALESCE(c.ex,0) DESC, s.title",
        else => " ORDER BY s.title, s.difficulty",
    };
}

fn buildRows(a: *App, al: std.mem.Allocator) ![]Row {
    const s = &a.sel;
    var rows: std.ArrayList(Row) = .empty;
    if (s.search.len > 0) {
        const sql = try std.fmt.allocPrint(al, "{s} WHERE s.title LIKE ?1 ESCAPE '\\' OR s.artist LIKE ?1 ESCAPE '\\' OR s.genre LIKE ?1 ESCAPE '\\'{s} LIMIT 2000", .{ db_mod.song_select, orderBy(s.sort) });
        const st = try a.db.prepare(sql);
        defer st.deinit();
        var pat: std.ArrayList(u8) = .empty;
        try pat.append(al, '%');
        for (s.search) |ch| {
            if (ch == '%' or ch == '_' or ch == '\\') try pat.append(al, '\\');
            try pat.append(al, ch);
        }
        try pat.append(al, '%');
        st.bindText(1, pat.items);
        while (try st.step()) {
            const song = try db_mod.readSong(al, st);
            try rows.append(al, .{ .label = song.title, .song = song });
        }
        return rows.toOwnedSlice(al);
    }
    switch (s.view) {
        .root => {
            try rows.append(al, .{ .label = "Library", .kind = .group });
            const st = try a.db.prepare("SELECT url,name,symbol FROM bms_table ORDER BY name");
            defer st.deinit();
            while (try st.step()) {
                try rows.append(al, .{ .label = try al.dupe(u8, st.text(1)), .kind = .table, .target = try al.dupe(u8, st.text(0)) });
            }
            try rows.append(al, .{ .label = "Courses", .kind = .group, .id = 1 });
        },
        .library => {
            const st = try a.db.prepare("SELECT folder, MIN(title), COUNT(*) FROM song GROUP BY folder ORDER BY MIN(title)");
            defer st.deinit();
            while (try st.step()) {
                try rows.append(al, .{
                    .label = try std.fmt.allocPrint(al, "{s}  ({d})", .{ st.text(1), st.int(2) }),
                    .kind = .folder,
                    .target = try al.dupe(u8, st.text(0)),
                });
            }
        },
        .folder => {
            const sql = try std.fmt.allocPrint(al, "{s} WHERE s.folder=?1{s}", .{ db_mod.song_select, orderBy(s.sort) });
            const st = try a.db.prepare(sql);
            defer st.deinit();
            st.bindText(1, s.folder);
            while (try st.step()) {
                const song = try db_mod.readSong(al, st);
                try rows.append(al, .{ .label = song.title, .song = song });
            }
        },
        .table => {
            const st = try a.db.prepare("SELECT level, COUNT(*) FROM table_song WHERE url=?1 GROUP BY level ORDER BY MIN(ord)");
            defer st.deinit();
            st.bindText(1, s.table_url);
            while (try st.step()) {
                try rows.append(al, .{
                    .label = try std.fmt.allocPrint(al, "Level {s}  ({d})", .{ st.text(0), st.int(1) }),
                    .kind = .level,
                    .target = try al.dupe(u8, st.text(0)),
                });
            }
        },
        .level => {
            const st = try a.db.prepare("SELECT md5,sha256,title,artist,zip_url FROM table_song WHERE url=?1 AND level=?2 ORDER BY ord");
            defer st.deinit();
            st.bindText(1, s.table_url);
            st.bindText(2, s.level);
            const sym = try a.db.prepare("SELECT COALESCE(symbol,'') FROM bms_table WHERE url=?1");
            defer sym.deinit();
            sym.bindText(1, s.table_url);
            // Inside a table, show that table's level even when another table lists the chart too.
            const level_label = try std.fmt.allocPrint(al, "{s}{s}", .{ if (try sym.step()) sym.text(0) else "", s.level });
            const look = try a.db.prepare(db_mod.song_select ++ " WHERE (s.md5=?1 AND ?1<>'') OR (s.sha256=?2 AND ?2<>'') LIMIT 1");
            defer look.deinit();
            while (try st.step()) {
                look.bindText(1, st.text(0));
                look.bindText(2, st.text(1));
                defer look.reset();
                if (try look.step()) {
                    var song = try db_mod.readSong(al, look);
                    song.table_level = level_label;
                    try rows.append(al, .{ .label = song.title, .song = song });
                } else {
                    try rows.append(al, .{
                        .label = try std.fmt.allocPrint(al, "{s}", .{st.text(2)}),
                        .kind = .missing,
                        .target = try al.dupe(u8, st.text(0)),
                        .extra = try al.dupe(u8, st.text(4)),
                    });
                }
            }
        },
        .courses => {
            const st = try a.db.prepare("SELECT c.id,c.name,t.name,COALESCE(s.clear,0) FROM course c LEFT JOIN bms_table t ON t.url=c.table_url LEFT JOIN course_score s ON s.course_id=c.id ORDER BY t.name,c.id");
            defer st.deinit();
            while (try st.step()) {
                try rows.append(al, .{
                    .label = try std.fmt.allocPrint(al, "{s}: {s}", .{ st.text(2), st.text(1) }),
                    .kind = .course,
                    .id = st.int(0),
                });
            }
        },
    }
    return rows.toOwnedSlice(al);
}

fn clearColor(clear: u8) gfx.Color {
    return switch (clear) {
        0 => .{ .r = 64, .g = 69, .b = 82 },
        1 => .{ .r = 150, .g = 52, .b = 66 },
        2, 3 => .{ .r = 178, .g = 128, .b = 255 },
        4 => .{ .r = 124, .g = 226, .b = 148 },
        5 => .{ .r = 94, .g = 196, .b = 255 },
        6 => .{ .r = 255, .g = 84, .b = 104 },
        7 => .{ .r = 255, .g = 214, .b = 92 },
        else => .{ .r = 150, .g = 245, .b = 245 },
    };
}

fn diffColor(d: i32) gfx.Color {
    return switch (d) {
        1 => .{ .r = 130, .g = 235, .b = 165 },
        2 => .{ .r = 140, .g = 195, .b = 255 },
        3 => .{ .r = 255, .g = 195, .b = 95 },
        4 => .{ .r = 255, .g = 125, .b = 115 },
        5 => .{ .r = 215, .g = 155, .b = 255 },
        else => gfx.white,
    };
}

const jacket_fade_ms = 250;
const card_fill: gfx.Color = .{ .r = 36, .g = 46, .b = 72 };
const card_hover: gfx.Color = .{ .r = 52, .g = 66, .b = 100 };

/// Where text of this size starts so it sits in the middle of a row, by the font's line height.
fn centeredY(y: f32, h: f32, size: u16) f32 {
    return y + (h - @as(f32, @floatFromInt(size)) * 1.3) / 2;
}

/// Eases toward the target by elapsed time, so the wheel moves alike at any frame rate.
/// Closes a quarter of the distance every 1/60 s.
fn scrollStep(cur: f32, target: f32, dt_s: f32) f32 {
    const next = target + (cur - target) * std.math.pow(f32, 0.75, dt_s * 60);
    return if (@abs(target - next) < 0.001) target else next;
}

/// One image being read and decoded off the main thread, so changing songs never stalls a frame.
const JacketJob = struct {
    gpa: std.mem.Allocator,
    key: u64,
    dir: []u8,
    stagefile: []u8,
    thread: ?*c.SDL_Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    px: ?*anyopaque = null,
    w: c_int = 0,
    h: c_int = 0,
    /// Shrinks the decoded image to at most this wide; 0 keeps it whole.
    max_w: c_int = 0,

    fn run(ud: ?*anyopaque) callconv(.c) c_int {
        const j: *JacketJob = @ptrCast(@alignCast(ud));
        defer j.done.store(true, .release);
        var arena = std.heap.ArenaAllocator.init(j.gpa);
        defer arena.deinit();
        const al = arena.allocator();
        const path = (fs.resolveAsset(al, j.dir, j.stagefile, &.{ "png", "jpg", "jpeg", "bmp", "gif", "tga" }) catch null) orelse return 0;
        const bytes = fs.readAlloc(al, path, 32 << 20) catch return 0;
        var n: c_int = 0;
        j.px = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &j.w, &j.h, &n, 4);
        if (j.px != null and j.max_w > 0) {
            const px: [*]u8 = @ptrCast(j.px.?);
            const size = shrink(px[0..@intCast(j.w * j.h * 4)], j.w, j.h, j.max_w);
            j.w = size[0];
            j.h = size[1];
        }
        return 0;
    }

    /// Waits for the thread if it is still running.
    fn destroy(j: *JacketJob) void {
        c.SDL_WaitThread(j.thread, null);
        if (j.px) |px| c.stbi_image_free(px);
        j.gpa.free(j.dir);
        j.gpa.free(j.stagefile);
        j.gpa.destroy(j);
    }
};

fn startImageJob(a: *App, sg: db_mod.Song, name: []const u8, image: u64, max_w: c_int) ?*JacketJob {
    const dir = std.fs.path.dirname(sg.path) orelse return null;
    const j = a.gpa.create(JacketJob) catch return null;
    const d = a.gpa.dupe(u8, dir) catch {
        a.gpa.destroy(j);
        return null;
    };
    const st = a.gpa.dupe(u8, name) catch {
        a.gpa.free(d);
        a.gpa.destroy(j);
        return null;
    };
    j.* = .{ .gpa = a.gpa, .key = image, .dir = d, .stagefile = st, .max_w = max_w };
    j.thread = c.SDL_CreateThread(JacketJob.run, "jacket", j);
    if (j.thread == null) {
        j.destroy();
        return null;
    }
    return j;
}

/// Keeps every nth pixel in place until the image fits `max_w`, and returns its new size.
/// shortcut: point sampling, fine under a dim fade; a box filter if card art looks noisy.
fn shrink(px: []u8, w: c_int, h: c_int, max_w: c_int) [2]c_int {
    if (w <= max_w) return .{ w, h };
    const step: usize = @intCast(@divTrunc(w + max_w - 1, max_w));
    const uw: usize = @intCast(w);
    const nw = uw / step;
    const nh = @as(usize, @intCast(h)) / step;
    for (0..nh) |y| for (0..nw) |x| {
        const from = (y * step * uw + x * step) * 4;
        const to = (y * nw + x) * 4;
        std.mem.copyForwards(u8, px[to .. to + 4], px[from .. from + 4]);
    };
    return .{ @intCast(nw), @intCast(nh) };
}

const CardArt = struct { key: u64, tex: ?*gfx.Texture, used: u64, at: u64 };
const card_art_w = 480;
const card_art_keep = 40;

fn imageKey(sg: db_mod.Song, name: []const u8) u64 {
    return std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, std.fs.path.dirname(sg.path) orelse ""), name);
}

/// A card shows the chart's stage image, or its banner if it only has that.
fn cardImage(sg: db_mod.Song) []const u8 {
    return if (sg.stagefile.len > 0) sg.stagefile else sg.banner;
}

fn findCardArt(s: *State, image: u64) ?*CardArt {
    for (s.card_art.items) |*art| if (art.key == image) return art;
    return null;
}

/// Takes in a finished image, drops the longest unseen, and starts the row nearest the cursor that
/// still has none. Waits while the wheel moves, so rows only passed over are never read.
fn tickCardArt(a: *App, reach: usize) void {
    const s = &a.sel;
    if (s.card_job) |j| {
        if (!j.done.load(.acquire)) return;
        const tex = if (j.px) |px| a.g.textureFromPixels(@ptrCast(px), j.w, j.h, @intCast(j.w * 4)) else null;
        s.card_art.append(a.gpa, .{ .key = j.key, .tex = tex, .used = a.g.frame, .at = c.SDL_GetTicks() }) catch {
            if (tex) |t| a.g.destroyTexture(t);
        };
        j.destroy();
        s.card_job = null;
    }
    while (s.card_art.items.len > card_art_keep) {
        var oldest: usize = 0;
        for (s.card_art.items, 0..) |art, i| {
            if (art.used < s.card_art.items[oldest].used) oldest = i;
        }
        if (s.card_art.items[oldest].tex) |t| a.g.destroyTexture(t);
        _ = s.card_art.swapRemove(oldest);
    }
    if (@abs(s.scroll - @as(f32, @floatFromInt(s.cursor))) > 0.5) return;
    for (0..reach + 1) |off| {
        for ([_]usize{ s.cursor + off, s.cursor -| off }) |i| {
            if (i >= s.rows.len) continue;
            const song = s.rows[i].song orelse continue;
            const name = cardImage(song);
            if (name.len == 0) continue;
            const image = imageKey(song, name);
            if (findCardArt(s, image) != null) continue;
            s.card_job = startImageJob(a, song, name, image, card_art_w);
            return;
        }
    }
}

/// The song's image behind its card, cropped to fill it and fading out toward the card's text.
fn drawCardArt(a: *App, song: db_mod.Song, x: f32, y: f32, w: f32, h: f32, on: bool) void {
    const name = cardImage(song);
    if (name.len == 0) return;
    const art = findCardArt(&a.sel, imageKey(song, name)) orelse return;
    art.used = a.g.frame;
    const tex = art.tex orelse return;
    const k = @min(tex.w / w, tex.h / h);
    const src: c.SDL_FRect = .{ .x = (tex.w - w * k) / 2, .y = (tex.h - h * k) / 2, .w = w * k, .h = h * k };
    const t = std.math.clamp(@as(f32, @floatFromInt(c.SDL_GetTicks() - art.at)) / jacket_fade_ms, 0, 1);
    const peak: f32 = if (on) 210 else 130;
    a.g.spriteHFade(tex, src, .{ .x = x, .y = y, .w = w, .h = h }, 0, @intFromFloat(peak * t));
}

fn swapJacket(s: *State, next: ?*gfx.Texture) void {
    if (next == null and s.jacket == null) return;
    s.jacket_old = s.jacket;
    s.jacket = next;
    s.jacket_fade_at = c.SDL_GetTicks();
}

/// Shows #STAGEFILE once the cursor has rested a moment, so scrolling never stalls on image loads.
fn updateJacket(a: *App) void {
    const s = &a.sel;
    const song = if (s.rows.len > 0 and s.cursor < s.rows.len) s.rows[s.cursor].song else null;
    // Keyed by the image, so charts of one song sharing it keep showing it untouched.
    const image: u64 = if (song) |sg| (if (sg.stagefile.len == 0) 0 else imageKey(sg, sg.stagefile)) else 0;
    const now = c.SDL_GetTicks();
    if (image != s.jacket_key) {
        s.jacket_key = image;
        s.jacket_since = now;
        s.jacket_tried = false;
    }
    if (s.jacket_old != null and now - s.jacket_fade_at >= jacket_fade_ms) {
        a.g.destroyTexture(s.jacket_old.?);
        s.jacket_old = null;
    }
    if (s.jacket_job) |j| {
        if (!j.done.load(.acquire)) return;
        // A result the cursor has moved away from is dropped; the current image starts next.
        if (j.key == s.jacket_key) swapJacket(s, if (j.px) |px| a.g.textureFromPixels(@ptrCast(px), j.w, j.h, @intCast(j.w * 4)) else null);
        j.destroy();
        s.jacket_job = null;
    }
    // Waits out a running fade too, so stepping through songs never cuts one short.
    if (s.jacket_tried or s.jacket_old != null or now - s.jacket_since < 150) return;
    s.jacket_tried = true;
    if (image == 0) swapJacket(s, null) else s.jacket_job = startImageJob(a, song.?, song.?.stagefile, image, 0);
}

fn jacketEased(s: *const State) f32 {
    const elapsed: f32 = @floatFromInt(c.SDL_GetTicks() - s.jacket_fade_at);
    const t = std.math.clamp(elapsed / jacket_fade_ms, 0, 1);
    return t * t * (3 - 2 * t);
}

/// How much image there is, 0 to 1: what it covers fades along with it.
fn jacketPresence(has_new: bool, has_old: bool, eased: f32) f32 {
    if (has_new and has_old) return 1;
    if (has_new) return eased;
    return if (has_old) 1 - eased else 0;
}

test "an image fades in from nothing and out to nothing" {
    try std.testing.expectEqual(@as(f32, 0.25), jacketPresence(true, false, 0.25));
    try std.testing.expectEqual(@as(f32, 0.75), jacketPresence(false, true, 0.25));
    try std.testing.expectEqual(@as(f32, 1), jacketPresence(true, true, 0.25));
    try std.testing.expectEqual(@as(f32, 0), jacketPresence(false, false, 0.25));
}

/// The new image fades in over the old one or over nothing; with no new image the old one fades out.
fn drawJacketLayers(a: *App, cover: bool, dst: ?*const c.SDL_FRect) void {
    const s = &a.sel;
    const eased = jacketEased(s);
    if (s.jacket_old) |old| drawJacketTexture(a, old, cover, dst, if (s.jacket == null) 1 - eased else 1);
    if (s.jacket) |tex| drawJacketTexture(a, tex, cover, dst, eased);
}

fn drawJacketTexture(a: *App, tex: *gfx.Texture, cover: bool, dst: ?*const c.SDL_FRect, alpha: f32) void {
    const g = &a.g;
    const box = if (dst) |d| d.* else c.SDL_FRect{ .x = 0, .y = 0, .w = g.w, .h = g.h };
    // Behind the page it is dimmed in its own color, so text stays readable and a fade only ever
    // moves between this and what lies behind; a dim layer over it would lag the image.
    const shade: u8 = if (cover) 80 else 255;
    const o: gfx.SpriteOptions = .{ .col = .{ .r = shade, .g = shade, .b = shade, .a = @intFromFloat(std.math.clamp(alpha, 0, 1) * 255) } };
    if (!cover) return g.sprite(tex, null, box, o);
    // Full-bleed crop: the image fills the window without stretching.
    const k = @min(tex.w / g.w, tex.h / g.h);
    g.sprite(tex, .{ .x = (tex.w - g.w * k) / 2, .y = (tex.h - g.h * k) / 2, .w = g.w * k, .h = g.h * k }, box, o);
}

/// The chart's #PREVIEW, or else a file in its folder named for one.
fn findPreview(al: std.mem.Allocator, song: db_mod.Song) ?[]const u8 {
    const dir = std.fs.path.dirname(song.path) orelse return null;
    const exts = session_mod.audio_exts;
    if (song.preview.len > 0) {
        if (fs.resolveAsset(al, dir, song.preview, exts) catch null) |p| return p;
    }
    for (fs.list(al, dir) catch return null) |e| {
        if (!e.is_dir and preview_mod.isPreviewFile(e.name, exts)) return std.fs.path.join(al, &.{ dir, e.name }) catch null;
    }
    return null;
}

/// Looks for a preview once the cursor has rested, so scrolling never touches the disk.
fn updatePreview(a: *App) void {
    const s = &a.sel;
    const now = c.SDL_GetTicks();
    const song = if (s.cursor < s.rows.len) s.rows[s.cursor].song else null;
    const chart: u64 = if (song) |sg| std.hash.Wyhash.hash(0, sg.path) else 0;
    if (chart != s.preview_key) {
        s.preview_key = chart;
        s.preview_since = now;
        s.preview_checked = false;
    }
    if (!s.preview_checked and now - s.preview_since >= 300) {
        s.preview_checked = true;
        s.preview_len = 0;
        var tmp = std.heap.ArenaAllocator.init(a.gpa);
        defer tmp.deinit();
        if (song) |sg| if (findPreview(tmp.allocator(), sg)) |p| if (p.len <= s.preview_buf.len) {
            @memcpy(s.preview_buf[0..p.len], p);
            s.preview_len = p.len;
        };
    }
    a.preview.tick(if (s.preview_len > 0) s.preview_buf[0..s.preview_len] else null, now);
}

pub fn draw(a: *App) void {
    tickScan(a);
    updatePreview(a);
    tickDownload(a);
    const g = &a.g;
    const s = &a.sel;
    if (s.searching) {
        if (!std.mem.eql(u8, s.search, a.text.items)) {
            const al = a.gpa;
            if (s.search.len > 0) al.free(s.search);
            s.search = if (a.text.items.len == 0) "" else al.dupe(u8, a.text.items) catch "";
            s.cursor = 0;
            reload(a);
        }
    }
    a.syncSelectSkin();
    if (a.select_skin != null) return drawSkinned(a);
    const u = g.h / 720;
    updateJacket(a);
    g.backdrop();
    if (s.jacket != null or s.jacket_old != null) {
        drawJacketLayers(a, true, null);
    }

    // Header.
    g.panel(10 * u, 8 * u, g.w - 20 * u, 40 * u, "");
    _ = g.text("actuon", 26 * u, 12 * u, g.scaled(24), gfx.white);
    g.textClip(switch (s.view) {
        .root => "",
        .library => "LIBRARY",
        .folder => std.fs.path.basename(s.folder),
        .table => "TABLE",
        .level => s.level,
        .courses => "COURSES",
    }, 120 * u, 19 * u, 160 * u, g.scaled(14), gfx.dim);
    if (s.searching) {
        g.fmt(290 * u, 18 * u, g.scaled(16), gfx.cyan, "SEARCH: {s}_", .{a.text.items});
    } else if (s.scan_thread != null) {
        g.fmt(290 * u, 19 * u, g.scaled(14), gfx.dim, "Scanning... {d}", .{s.scan_progress.load(.monotonic)});
    } else if (s.status.len > 0) g.textClip(s.status, 290 * u, 19 * u, g.w - 310 * u, g.scaled(14), gfx.sky);

    if (s.download) |j| {
        const total = j.progress.total.load(.acquire);
        if (total > 0 and !j.extracting.load(.acquire)) {
            const frac = @as(f32, @floatFromInt(@min(j.progress.done.load(.acquire), total))) / @as(f32, @floatFromInt(total));
            g.rect(10 * u, 46 * u, (g.w - 20 * u) * frac, 2 * u, gfx.accent);
        }
    }

    // Wheel: rows lean away from the selected one.
    const wheel_x = g.w * 0.46;
    const top = 54 * u;
    const dock_y = g.h - 74 * u;
    const mid = (top + dock_y) / 2;
    const row_h = 54 * u;
    const scroll_now = c.SDL_GetTicksNS();
    s.scroll = scrollStep(s.scroll, @floatFromInt(s.cursor), @as(f32, @floatFromInt(scroll_now -| s.scroll_at_ns)) / std.time.ns_per_s);
    s.scroll_at_ns = scroll_now;
    const reach: usize = @intFromFloat((dock_y - top) / row_h / 2 + 2);
    const first = if (s.cursor > reach) s.cursor - reach else 0;
    tickCardArt(a, reach);
    g.clip(0, top, g.w, dock_y - top);
    var ex_buf: [16]u8 = undefined;
    for (s.rows[@min(first, s.rows.len)..@min(s.cursor + reach + 1, s.rows.len)], first..) |row, i| {
        const d = @as(f32, @floatFromInt(i)) - s.scroll;
        const on = i == s.cursor;
        const h = row_h - 5 * u;
        const y = mid + d * row_h - h / 2;
        const x = wheel_x + d * d * 4 * u + 24 * u;
        const rw = g.w - x + 40 * u;
        // Over the wheel only: rows pass under the header and dock.
        const hover = g.my >= top and g.my < dock_y and g.hit(x, y, rw, h);
        if (hover and g.clickIn(x, y, rw, h)) {
            if (on) {
                a.click_key = c.SDL_SCANCODE_RETURN;
            } else {
                s.cursor = i;
                a.sfx(.move);
            }
        }
        // A solid fill, so the card holds up on any background.
        g.round(x, y, rw, h, 10 * u, if (on) gfx.accent else if (hover) card_hover else card_fill);
        if (row.song) |song| drawCardArt(a, song, x, y, rw, h, on);
        const tsize = g.scaled(15);
        const ty = centeredY(y, h, tsize);
        if (row.song) |song| {
            // The number carries the difficulty colour; on the accent row only white holds up.
            g.textCentered(song.shownLevel(), x + 34 * u, centeredY(y, h, g.scaled(18)), g.scaled(18), if (on) gfx.white else diffColor(song.difficulty));
            g.textClip(row.label, x + 70 * u, ty, @max(g.w - x - 210 * u, 0), tsize, gfx.white);
            if (song.clear > 0) {
                g.textRight(std.fmt.bufPrint(&ex_buf, "{d}", .{song.ex}) catch "", g.w - 92 * u, centeredY(y, h, g.scaled(12)), g.scaled(12), gfx.white);
                g.textRight(result.rankOf(song.ex, song.notes), g.w - 42 * u, centeredY(y, h, g.scaled(14)), g.scaled(14), gfx.white);
            }
            const lamp = clearColor(song.clear);
            if (song.clear > 0) g.round(g.w - 22 * u, y + 8 * u, 6 * u, h - 16 * u, 3 * u, lamp);
        } else {
            g.textClip(row.label, x + 20 * u, ty, @max(g.w - x - 60 * u, 0), tsize, if (row.kind == .missing) gfx.dim else gfx.white);
        }
    }
    g.unclip();
    if (s.rows.len == 0) {
        g.textCentered(if (a.cfg.roots.len == 0) "No library folders yet. Press F10 to add one." else "Nothing here.", g.w * 0.72, mid - 10 * u, g.scaled(16), gfx.dim);
    }

    // Left: jacket and chart data.
    const lx = 14 * u;
    const lw = wheel_x - 22 * u;
    const jack_w = @min(lw, 370 * u);
    const jack_h = jack_w * 0.75;
    const jy = 56 * u;
    g.round(lx, jy, jack_w, jack_h, 8 * u, gfx.plate);
    const jcx = lx + jack_w / 2;
    const jcy = jy + jack_h / 2;
    const cur_song = if (s.rows.len > 0 and s.cursor < s.rows.len) s.rows[s.cursor].song else null;
    const jack_rect: c.SDL_FRect = .{ .x = lx, .y = jy, .w = jack_w, .h = jack_h };
    const level_alpha = 1 - jacketPresence(s.jacket != null, s.jacket_old != null, jacketEased(s));
    if (level_alpha > 0) {
        const big = if (cur_song) |song| song.shownLevel() else "";
        g.textCentered(big, jcx, jcy - 44 * u, g.scaled(72), gfx.white.alpha(@intFromFloat(255 * level_alpha)));
    }
    drawJacketLayers(a, false, &jack_rect);
    var iy = jy + jack_h + 8 * u;
    if (s.rows.len > 0 and s.cursor < s.rows.len) {
        if (cur_song) |song| {
            g.textClip(song.title, lx, iy, lw, g.scaled(24), gfx.white);
            iy += 34 * u;
            g.textClip(song.artist, lx, iy, lw, g.scaled(14), gfx.sky);
            g.textClip(song.genre, lx + lw * 0.55, iy, lw * 0.45, g.scaled(14), gfx.dim);
            iy += 24 * u;
            const cw = (lw - 12 * u) / 3;
            const ph = 50 * u;
            g.panel(lx, iy, cw, ph, "NOTES");
            g.digits(lx + cw - 8 * u, iy + 12 * u, g.scaled(24), 4, song.notes, gfx.white);
            g.panel(lx + cw + 6 * u, iy, cw, ph, "BPM");
            g.digits(lx + cw * 2 - 2 * u, iy + 12 * u, g.scaled(24), 3, @intFromFloat(@max(song.max_bpm, 0)), gfx.cyan);
            if (song.min_bpm != song.max_bpm) g.fmt(lx + cw + 14 * u, iy + 28 * u, g.scaled(12), gfx.dim, "{d:.0}~", .{song.min_bpm});
            const len_s: u64 = @intCast(@divTrunc(@max(song.length_ms, 0), 1000));
            g.panel(lx + (cw + 6 * u) * 2, iy, cw, ph, "TIME");
            var tb: [16]u8 = undefined;
            g.textRight(std.fmt.bufPrint(&tb, "{d}:{d:0>2}", .{ len_s / 60, len_s % 60 }) catch "", lx + lw - 8 * u, iy + 12 * u, g.scaled(24), gfx.white);
            iy += ph + 6 * u;
            const sh = @min(dock_y - iy - 6 * u, 92 * u);
            if (sh > 60 * u) {
                const lamp = clearColor(song.clear);
                g.panel(lx, iy, lw, sh, "BEST");
                if (song.clear > 0) g.round(lx + 6 * u, iy + 18 * u, 5 * u, sh - 26 * u, 3 * u, lamp);
                _ = g.text(result.clear_names[song.clear], lx + 18 * u, iy + 18 * u, g.scaled(16), if (song.clear == 0) gfx.dim else lamp);
                if (song.miss >= 0 and song.played > 0) g.fmt(lx + 18 * u, iy + 40 * u, g.scaled(12), gfx.dim, "BP {d}   PLAYS {d}", .{ song.miss, song.played });
                g.digits(lx + lw * 0.74, iy + 14 * u, g.scaled(48), 5, song.ex, gfx.white);
                if (song.clear > 0) g.textRight(result.rankOf(song.ex, song.notes), lx + lw - 10 * u, iy + 14 * u, g.scaled(48), gfx.cyan);
            }
        } else {
            g.textClip(s.rows[s.cursor].label, lx, iy, lw, g.scaled(32), gfx.white);
            iy += 44 * u;
            _ = g.text(if (s.rows[s.cursor].kind == .missing) "Enter: download this chart" else "Enter: open", lx, iy, g.scaled(14), gfx.sky);
        }
    }

    // Dock: tabs with their keys.
    const tab = struct {
        fn f(aa: *App, ox: f32, oy: f32, w: f32, sc: u32, key_name: []const u8, label: []const u8, value: []const u8) void {
            const gg = &aa.g;
            const uu = gg.h / 720;
            const hover = gg.hit(ox, oy, w, 44 * uu);
            if (gg.clickIn(ox, oy, w, 44 * uu)) aa.click_key = sc;
            gg.round(ox, oy, w, 44 * uu, 8 * uu, if (hover) gfx.rule else gfx.plate.alpha(225));
            gg.round(ox + 8 * uu, oy + 6 * uu, 30 * uu, 18 * uu, 4 * uu, gfx.accent);
            _ = gg.text(key_name, ox + 14 * uu, oy + 6 * uu, gg.scaled(12), gfx.white);
            _ = gg.text(label, ox + 46 * uu, oy + 5 * uu, gg.scaled(12), gfx.dim);
            gg.textClip(value, ox + 46 * uu, oy + 20 * uu, w - 56 * uu, gg.scaled(16), gfx.white);
        }
    }.f;
    const tw = (g.w - 28 * u - 24 * u) / 5;
    const tab_x = struct {
        fn f(uu: f32, width: f32, i: f32) f32 {
            return 14 * uu + (width + 6 * uu) * i;
        }
    }.f;
    var dock_buf: [32]u8 = undefined;
    tab(a, tab_x(u, tw, 0), dock_y, tw, c.SDL_SCANCODE_F1, "F1", "RANDOM", random_names[@min(a.cfg.random, 4)]);
    tab(a, tab_x(u, tw, 1), dock_y, tw, c.SDL_SCANCODE_F2, "F2", "GAUGE", gauge_names[@min(a.cfg.gauge, config.gas)]);
    tab(a, tab_x(u, tw, 2), dock_y, tw, c.SDL_SCANCODE_F3, "F3", "HS FIX / GREEN", std.fmt.bufPrint(&dock_buf, "{s}  {d}", .{ hs_names[@min(a.cfg.hs_fix, 3)], a.cfg.green_ms * 3 / 5 }) catch "");
    tab(a, tab_x(u, tw, 3), dock_y, tw, c.SDL_SCANCODE_F4, "F4", "SORT", sort_names[s.sort]);
    tab(a, tab_x(u, tw, 4), dock_y, tw, c.SDL_SCANCODE_F5, "F5", "AUTOPLAY", if (s.autoplay) "ON" else "OFF");

    // The remaining commands, as a row of text buttons.
    const cmds = [_]struct { sc: u32, label: []const u8 }{
        .{ .sc = c.SDL_SCANCODE_F6, .label = "F6 Search" },
        .{ .sc = c.SDL_SCANCODE_F7, .label = "F7 Rescan" },
        .{ .sc = c.SDL_SCANCODE_F8, .label = "F8 Tables" },
        .{ .sc = c.SDL_SCANCODE_F9, .label = "F9 IR" },
        .{ .sc = c.SDL_SCANCODE_F10, .label = "F10 Settings" },
        .{ .sc = c.SDL_SCANCODE_ESCAPE, .label = "Esc Back" },
    };
    const cmd_size = g.scaled(12);
    var cmd_w: f32 = 0;
    for (cmds) |cmd| cmd_w += g.measure(cmd.label, cmd_size) + 24 * u;
    var cmd_x = (g.w - cmd_w) / 2;
    const cmd_y = g.h - 28 * u;
    for (cmds) |cmd| {
        const bw = g.measure(cmd.label, cmd_size) + 24 * u;
        const hover = g.hit(cmd_x, cmd_y, bw, 24 * u);
        if (g.clickIn(cmd_x, cmd_y, bw, 24 * u)) a.click_key = cmd.sc;
        if (hover) g.round(cmd_x, cmd_y, bw, 24 * u, 6 * u, gfx.rule);
        g.textCentered(cmd.label, cmd_x + bw / 2, cmd_y + 4 * u, cmd_size, if (hover) gfx.white else gfx.dim);
        cmd_x += bw;
    }

    drawQuery(a);
}

fn barOf(row: Row) skin_scene.Bar {
    var b: skin_scene.Bar = .{ .label = row.label, .kind = switch (row.kind) {
        .song => .song,
        .folder => .folder,
        .table, .level => .table,
        .course => .grade,
        .missing => .missing,
        .group => .command,
    } };
    if (row.song) |song| {
        b.level = std.fmt.parseInt(i64, song.level, 10) catch 0;
        b.difficulty = song.difficulty;
        b.clear = song.clear;
        b.has_ln = song.has_ln;
    }
    return b;
}

fn barAt(ud: *anyopaque, i: usize) skin_scene.Bar {
    const s: *State = @ptrCast(@alignCast(ud));
    return barOf(s.rows[i]);
}

/// Points the skin's state at the selected row.
fn fillSkinState(a: *App) void {
    const s = &a.sel;
    const st = &a.select_state;
    const row: ?Row = if (s.cursor < s.rows.len) s.rows[s.cursor] else null;
    const song = if (row) |r| r.song else null;
    const bar: skin_scene.Bar = if (row) |r| barOf(r) else .{ .label = "", .kind = .command };
    st.select = .{
        .kind = if (s.searching) .search else bar.kind,
        .directory = switch (s.view) {
            .root => "",
            .library => "LIBRARY",
            .folder => std.fs.path.basename(s.folder),
            .table => "TABLE",
            .level => s.level,
            .courses => "COURSES",
        },
        .search = a.text.items,
        .clear = bar.clear,
        .has_ln = bar.has_ln,
    };
    st.title = bar.label;
    st.subtitle = "";
    st.artist = "";
    st.genre = "";
    st.playlevel = bar.level;
    st.difficulty = bar.difficulty;
    st.total_notes = 0;
    st.min_bpm = 0;
    st.max_bpm = 0;
    st.length_us = 0;
    st.best_ex = 0;
    if (song) |sg| {
        st.title = sg.title;
        st.subtitle = sg.subtitle;
        st.artist = sg.artist;
        st.genre = sg.genre;
        st.total_notes = sg.notes;
        st.min_bpm = sg.min_bpm;
        st.max_bpm = sg.max_bpm;
        st.length_us = sg.length_ms * 1000;
        st.best_ex = sg.ex;
        st.mode = std.enums.fromInt(core.types.Mode, sg.mode) orelse .beat7;
        st.select.?.ex = sg.ex;
        st.select.?.miss = sg.miss;
        st.select.?.played = sg.played;
    }
    st.stagefile = s.jacket;
}

/// The skin draws everything but what it has no place for: search, status and the IR ranking.
fn drawSkinned(a: *App) void {
    const g = &a.g;
    const s = &a.sel;
    updateJacket(a);
    const now = c.SDL_GetTicks();
    // Back from another screen: the skin's opening runs again.
    if (now - a.select_seen > 500) {
        a.select_at = now;
        a.select_state.timers = @splat(-1);
        a.select_state.timers[1] = 0;
        a.select_state.timers[11] = 0;
        a.select_row = s.cursor;
    }
    a.select_seen = now;
    const shown: i64 = @intCast(now - a.select_at);
    if (s.cursor != a.select_row) {
        a.select_row = s.cursor;
        a.select_state.timers[11] = shown;
    }
    const scroll_now = c.SDL_GetTicksNS();
    s.scroll = scrollStep(s.scroll, @floatFromInt(s.cursor), @as(f32, @floatFromInt(scroll_now -| s.scroll_at_ns)) / std.time.ns_per_s);
    s.scroll_at_ns = scroll_now;
    fillSkinState(a);
    const clicked = skin_scene.drawSelect(g, a.select_skin.?, &a.select_state, shown, .{ .ud = s, .len = s.rows.len, .scroll = s.scroll, .at = barAt });
    if (clicked) |row| {
        if (row == s.cursor) {
            a.click_key = c.SDL_SCANCODE_RETURN;
        } else {
            s.cursor = row;
            a.sfx(.move);
        }
    }
    const u = g.h / 720;
    if (s.searching) {
        g.panel(10 * u, 8 * u, g.w - 20 * u, 40 * u, "");
        g.fmt(26 * u, 18 * u, g.scaled(16), gfx.cyan, "SEARCH: {s}_", .{a.text.items});
    } else if (s.scan_thread != null) {
        g.fmt(26 * u, 8 * u, g.scaled(14), gfx.dim, "Scanning... {d}", .{s.scan_progress.load(.monotonic)});
    } else if (s.status.len > 0) {
        g.panel(10 * u, 8 * u, g.w - 20 * u, 40 * u, "");
        g.textClip(s.status, 26 * u, 19 * u, g.w - 52 * u, g.scaled(14), gfx.sky);
    }
    if (s.rows.len == 0) g.textCentered(if (a.cfg.roots.len == 0) "No library folders yet. Press F10 to add one." else "Nothing here.", g.w * 0.72, g.h * 0.48, g.scaled(16), gfx.white);
    drawQuery(a);
}

fn drawQuery(a: *App) void {
    const g = &a.g;
    const s = &a.sel;
    if (s.query) |q| {
        const qx = g.w * 0.2;
        const qy = g.h * 0.1;
        g.rect(0, 0, g.w, g.h, gfx.well.alpha(190));
        g.rect(qx, qy, g.w * 0.6, g.h * 0.8, gfx.bg);
        g.rect(qx, qy, g.w * 0.6, 3, gfx.accent);
        _ = g.text(s.query_title, qx + 24, qy + 18, 20, gfx.white);
        if (!q.done.load(.acquire)) {
            _ = g.text("Loading...", qx + 24, qy + 56, 16, gfx.dim);
        } else if (q.failed) {
            _ = g.text("Could not reach the IR server", qx + 24, qy + 56, 16, gfx.dim);
        } else {
            var ly = qy + 56;
            for (q.lines.items) |l| {
                if (ly > g.h * 0.85) break;
                _ = g.text(l, qx + 24, ly, 16, gfx.white);
                ly += 26;
            }
        }
    }
}

fn setFolder(a: *App, f: []const u8) void {
    const s = &a.sel;
    const n = @min(f.len, s.folder_buf.len);
    std.mem.copyForwards(u8, s.folder_buf[0..n], f[0..n]);
    s.folder = s.folder_buf[0..n];
    s.view = .folder;
    s.cursor = 0;
    reload(a);
}

fn go(a: *App, view: @TypeOf(a.sel.view)) void {
    a.sel.view = view;
    a.sel.cursor = 0;
    reload(a);
}

/// Goes up a view, with the cursor on the row that was opened.
fn back(a: *App, view: @TypeOf(a.sel.view)) void {
    const s = &a.sel;
    const from = s.view;
    go(a, view);
    for (s.rows, 0..) |row, i| {
        const opened = switch (from) {
            .root => false,
            .library => row.kind == .group and row.id != 1,
            .courses => row.kind == .group and row.id == 1,
            .folder => row.kind == .folder and std.mem.eql(u8, row.target, s.folder),
            .table => row.kind == .table and std.mem.eql(u8, row.target, s.table_url),
            .level => row.kind == .level and std.mem.eql(u8, row.target, s.level),
        };
        if (opened) {
            s.cursor = i;
            return;
        }
    }
}

fn tableThread(ud: ?*anyopaque) callconv(.c) c_int {
    const a: *App = @ptrCast(@alignCast(ud));
    defer a.sel.table_done.store(true, .release);
    const d = db_mod.openMain(a.gpa) catch return 1;
    defer d.close();
    const only = [_][]const u8{a.sel.table_only orelse ""};
    for (if (a.sel.table_only != null) &only else a.cfg.tables) |url| {
        _ = table.fetch(a.gpa, d, url) catch |e| {
            std.log.err("table {s}: {t}", .{ url, e });
            _ = a.sel.table_failed.fetchAdd(1, .monotonic);
        };
    }
    return 0;
}

pub fn startTableFetch(a: *App, only: ?[]const u8) void {
    const s = &a.sel;
    if (s.table_thread != null) return;
    if (a.cfg.tables.len == 0) {
        s.status = "No tables yet. Add one in Settings, Tables.";
        return;
    }
    s.table_only = only;
    s.table_done.store(false, .release);
    s.table_failed.store(0, .release);
    s.status = "Updating tables...";
    s.table_thread = c.SDL_CreateThread(tableThread, "tables", a);
}

/// Downloads into the first library folder; the scanner then finds the charts.
fn startDownload(a: *App, row: Row) void {
    const s = &a.sel;
    if (s.download != null) {
        s.status = "A download is already running";
        return;
    }
    if (a.cfg.roots.len == 0) {
        s.status = "Add a library folder first";
        return;
    }
    var buf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const url: []const u8 = if (a.cfg.download_url.len > 0 and row.target.len > 0)
        download.expand(fba.allocator(), a.cfg.download_url, row.target) catch return
    else
        row.extra;
    if (url.len == 0) {
        s.status = "No download source for this chart";
        return;
    }
    s.download = download.start(a.gpa, url, a.cfg.roots[0], row.target);
    s.status = if (s.download != null) "Downloading..." else "Could not start download";
    s.download_seen = 0;
    s.download_shown = 0;
    s.download_moved_ms = c.SDL_GetTicks();
}

const download_stall_ms = 30_000;

fn tickDownload(a: *App) void {
    const s = &a.sel;
    const j = s.download orelse return;
    const st = j.state.load(.acquire);
    if (st == 0) {
        const now = c.SDL_GetTicks();
        if (j.extracting.load(.acquire)) {
            s.status = "Extracting...";
            return;
        }
        const done = j.progress.done.load(.acquire);
        if (done != s.download_seen) {
            s.download_seen = done;
            s.download_moved_ms = now;
        } else if (now - s.download_moved_ms > download_stall_ms) {
            s.status = "Download stalled: the server stopped sending";
            j.abandon();
            s.download = null;
            return;
        }
        // A tenth of a megabyte at a time: each new string is a new text texture.
        const step = done / (1 << 17);
        if (step != s.download_shown or s.status.ptr != &s.download_buf) {
            s.download_shown = step;
            s.status = download.formatProgress(&s.download_buf, done, j.progress.total.load(.acquire));
        }
        return;
    }
    s.status = if (st == 1) "Download finished" else "Download failed";
    j.destroy();
    s.download = null;
    if (st == 1) startScan(a);
}

/// Fills `play_table_buf`, returning the length.
/// shortcut: the first table listing the chart, as its level is; pass the table along if one opened from another table must name that.
fn tableName(a: *App, song: db_mod.Song) usize {
    const st = a.db.prepare("SELECT b.name FROM table_song t JOIN bms_table b ON b.url=t.url WHERE (t.md5=?1 AND t.md5<>'') OR (t.sha256=?2 AND t.sha256<>'') ORDER BY b.name LIMIT 1") catch return 0;
    defer st.deinit();
    st.bindText(1, song.md5);
    st.bindText(2, song.sha256);
    if (!(st.step() catch false)) return 0;
    const name = st.text(0);
    const n = @min(name.len, a.play_table_buf.len);
    @memcpy(a.play_table_buf[0..n], name[0..n]);
    return n;
}

fn startSong(a: *App, song: db_mod.Song) void {
    const seed = c.SDL_GetTicksNS();
    // The loader thread may still be reading the buffer, and a path this long can't be opened anyway.
    if (a.load_thread != null or song.path.len > a.play_path_buf.len) return;
    @memcpy(a.play_path_buf[0..song.path.len], song.path);
    const level_n = @min(song.table_level.len, a.play_level_buf.len);
    @memcpy(a.play_level_buf[0..level_n], song.table_level[0..level_n]);
    const table_n = tableName(a, song);
    a.decidePlay(.{
        .path = a.play_path_buf[0..song.path.len],
        .table_level = a.play_level_buf[0..level_n],
        .table_name = a.play_table_buf[0..table_n],
        .gauge = config.gaugeType(a.cfg.gauge),
        .gas = a.cfg.gauge == config.gas,
        .random = @enumFromInt(@min(a.cfg.random, 4)),
        .seed = seed,
        .autoplay = a.sel.autoplay,
        .judge_offset_us = @as(i64, a.cfg.judge_offset_ms) * 1000,
    }, true);
}

fn closeQuery(a: *App) void {
    if (a.sel.query) |q| q.destroy();
    a.sel.query = null;
}

/// A chart row shows its ranking; a table or level row shows standings over its charts.
fn openRanking(a: *App) void {
    const s = &a.sel;
    if (a.cfg.ir_url.len == 0 or s.cursor >= s.rows.len) {
        s.status = "Set an IR server in settings first";
        return;
    }
    const row = s.rows[s.cursor];
    var arena = std.heap.ArenaAllocator.init(a.gpa);
    defer arena.deinit();
    const al = arena.allocator();
    if (row.song) |song| {
        // With a token the list narrows to rivals only when asked: full ranking is the default view.
        const url = std.fmt.allocPrint(al, "{s}/scores/{s}?limit=50", .{ a.cfg.ir_url, song.sha256 }) catch return;
        s.query = ir.startQuery(a.gpa, url, a.cfg.ir_token, null);
        s.query_title = "Ranking";
        return;
    }
    if (row.kind != .level and row.kind != .table) return;
    const sql: []const u8 = if (row.kind == .level)
        "SELECT DISTINCT s.sha256 FROM table_song t JOIN song s ON (s.md5=t.md5 AND t.md5<>'') OR (s.sha256=t.sha256 AND t.sha256<>'') WHERE t.url=?1 AND t.level=?2"
    else
        "SELECT DISTINCT s.sha256 FROM table_song t JOIN song s ON (s.md5=t.md5 AND t.md5<>'') OR (s.sha256=t.sha256 AND t.sha256<>'') WHERE t.url=?1";
    const st = a.db.prepare(sql) catch return;
    defer st.deinit();
    st.bindText(1, if (row.kind == .level) s.table_url else row.target);
    if (row.kind == .level) st.bindText(2, row.target);
    var body: std.ArrayList(u8) = .empty;
    body.appendSlice(al, "{\"sha256\":[") catch return;
    var n: usize = 0;
    while (st.step() catch false) {
        if (n > 0) body.append(al, ',') catch return;
        body.append(al, '"') catch return;
        body.appendSlice(al, st.text(0)) catch return;
        body.append(al, '"') catch return;
        n += 1;
    }
    body.appendSlice(al, "]}") catch return;
    const url = std.fmt.allocPrint(al, "{s}/table-ranking", .{a.cfg.ir_url}) catch return;
    s.query = ir.startQuery(a.gpa, url, a.cfg.ir_token, body.items);
    s.query_title = "Table standings";
}

pub fn key(a: *App, sc: u32) void {
    const s = &a.sel;
    if (s.query != null) {
        if (sc == c.SDL_SCANCODE_F9) {
            closeQuery(a);
            const url_ok = s.cursor < s.rows.len and s.rows[s.cursor].song != null and a.cfg.ir_token.len > 0;
            if (url_ok and !std.mem.eql(u8, s.query_title, "Rivals")) {
                var buf: [1024]u8 = undefined;
                const url = std.fmt.bufPrint(&buf, "{s}/scores/{s}/rivals", .{ a.cfg.ir_url, s.rows[s.cursor].song.?.sha256 }) catch return;
                s.query = ir.startQuery(a.gpa, url, a.cfg.ir_token, null);
                s.query_title = "Rivals";
            }
        } else if (sc == c.SDL_SCANCODE_ESCAPE) closeQuery(a);
        return;
    }
    if (s.searching) {
        switch (sc) {
            c.SDL_SCANCODE_ESCAPE => {
                s.searching = false;
                a.stopText();
                a.text.clearRetainingCapacity();
                if (s.search.len > 0) a.gpa.free(s.search);
                s.search = "";
                reload(a);
                return;
            },
            c.SDL_SCANCODE_BACKSPACE => {
                while (a.text.items.len > 0) {
                    const ch = a.text.pop().?;
                    if (ch & 0xC0 != 0x80) break;
                }
                return;
            },
            c.SDL_SCANCODE_RETURN => {
                s.searching = false;
                a.stopText();
                return;
            },
            c.SDL_SCANCODE_UP, c.SDL_SCANCODE_DOWN => {},
            else => return,
        }
    }
    switch (sc) {
        c.SDL_SCANCODE_UP, c.SDL_SCANCODE_DOWN, c.SDL_SCANCODE_PAGEUP, c.SDL_SCANCODE_PAGEDOWN => a.sfx(.move),
        c.SDL_SCANCODE_F1, c.SDL_SCANCODE_F2, c.SDL_SCANCODE_F3, c.SDL_SCANCODE_F4, c.SDL_SCANCODE_F5 => a.sfx(.adjust),
        c.SDL_SCANCODE_F6, c.SDL_SCANCODE_F7, c.SDL_SCANCODE_F8, c.SDL_SCANCODE_F9 => a.sfx(.confirm),
        c.SDL_SCANCODE_F10 => a.sfxOr(a.sfx_option_open, .confirm),
        c.SDL_SCANCODE_ESCAPE => a.sfx(.back),
        c.SDL_SCANCODE_RETURN => if (s.cursor < s.rows.len and s.rows[s.cursor].song == null and s.rows[s.cursor].kind != .course) a.sfx(.confirm),
        else => {},
    }
    switch (sc) {
        c.SDL_SCANCODE_UP => if (s.cursor > 0) {
            s.cursor -= 1;
        } else if (s.rows.len > 0) {
            s.cursor = s.rows.len - 1;
        },
        c.SDL_SCANCODE_DOWN => s.cursor = if (s.cursor + 1 < s.rows.len) s.cursor + 1 else 0,
        c.SDL_SCANCODE_PAGEUP => s.cursor -|= 15,
        c.SDL_SCANCODE_PAGEDOWN => s.cursor = @min(s.cursor + 15, s.rows.len -| 1),
        c.SDL_SCANCODE_RETURN => {
            if (s.cursor >= s.rows.len) return;
            const row = s.rows[s.cursor];
            if (row.song) |song| return startSong(a, song);
            switch (row.kind) {
                .folder => setFolder(a, row.target),
                .group => go(a, if (row.id == 1) .courses else .library),
                .table => {
                    const n = @min(row.target.len, s.table_buf.len);
                    @memcpy(s.table_buf[0..n], row.target[0..n]);
                    s.table_url = s.table_buf[0..n];
                    go(a, .table);
                },
                .level => {
                    const n = @min(row.target.len, s.level_buf.len);
                    @memcpy(s.level_buf[0..n], row.target[0..n]);
                    s.level = s.level_buf[0..n];
                    go(a, .level);
                },
                .course => course_mod.start(a, row.id),
                .missing => startDownload(a, row),
                .song => {},
            }
        },
        c.SDL_SCANCODE_ESCAPE => {
            if (s.search.len > 0) {
                a.gpa.free(s.search);
                s.search = "";
                reload(a);
            } else switch (s.view) {
                .root => a.running = false,
                .library, .courses, .table => back(a, .root),
                .folder => back(a, .library),
                .level => back(a, .table),
            }
        },
        c.SDL_SCANCODE_F1 => a.cfg.random = (a.cfg.random + 1) % 5,
        c.SDL_SCANCODE_F2 => a.cfg.gauge = (a.cfg.gauge + 1) % (config.gas + 1),
        c.SDL_SCANCODE_F3 => a.cfg.hs_fix = (a.cfg.hs_fix + 1) % 4,
        c.SDL_SCANCODE_F4 => {
            s.sort = (s.sort + 1) % 4;
            reload(a);
        },
        c.SDL_SCANCODE_F5 => s.autoplay = !s.autoplay,
        c.SDL_SCANCODE_F6 => {
            s.searching = true;
            a.startText(s.search);
        },
        c.SDL_SCANCODE_F7 => startScan(a),
        c.SDL_SCANCODE_F8 => startTableFetch(a, null),
        c.SDL_SCANCODE_F9 => openRanking(a),
        c.SDL_SCANCODE_F10 => a.scene = .settings,
        else => {},
    }
}

test "wheel easing does not depend on the frame rate" {
    const once = scrollStep(10, 0, 1.0 / 60.0);
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), once, 0.001);
    var many: f32 = 10;
    for (0..133) |_| many = scrollStep(many, 0, 1.0 / 8000.0);
    try std.testing.expectApproxEqAbs(once, many, 0.01);
    try std.testing.expectEqual(@as(f32, 0), scrollStep(0.0005, 0, 0));
}

test "shrinking keeps a whole number of steps and the pixels it samples" {
    var px: [4 * 4 * 2]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = @intCast(i);
    try std.testing.expectEqual([2]c_int{ 2, 1 }, shrink(&px, 4, 2, 2));
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 8, 9, 10, 11 }, px[0..8]);
    try std.testing.expectEqual([2]c_int{ 4, 2 }, shrink(&px, 4, 2, 4));
}
