//! Song select: a browsable tree of library folders, plus search.
const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const gfx = @import("gfx.zig");
const i18n = @import("i18n.zig");
const tr = i18n.tr;
const app_mod = @import("app.zig");
const result = @import("result.zig");
const play = @import("play.zig");
const practice = @import("practice.zig");
const versus = @import("versus.zig");
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
const testing = @import("testing.zig");
const settings = @import("settings.zig");
const input = @import("../input/input.zig");
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
    view: enum { root, library, folder, table, level, courses, favorites } = .root,
    table_url: []const u8 = "",
    table_buf: [1024]u8 = undefined,
    level: []const u8 = "",
    level_buf: [64]u8 = undefined,
    /// Empty means the root. Lives in folder_buf, because rows are rebuilt under it.
    folder: []const u8 = "",
    folder_buf: [4096]u8 = undefined,
    /// The library folder open in the library view; empty lists every folder.
    library_root: []const u8 = "",
    library_root_buf: [4096]u8 = undefined,
    search: []const u8 = "",
    searching: bool = false,
    status: []const u8 = "",
    status_buf: [128]u8 = undefined,
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
    logo: ?*gfx.Texture = null,
    jacket_fade_at: u64 = 0,
    scroll_at_ns: u64 = 0,
    jacket_job: ?*JacketJob = null,
    /// Small copies of the images behind the wheel's cards, most recently drawn kept.
    card_art: std.ArrayList(CardArt) = .empty,
    card_job: ?*JacketJob = null,
    query: ?*ir.Query = null,
    query_title: []const u8 = "",
    /// The selected chart's ranking, asked for once the cursor rests on it.
    board: ?*ir.Board = null,
    board_sha: [64]u8 = undefined,
    board_sha_len: usize = 0,
    board_since_ms: u64 = 0,
    board_asked: bool = false,
    table_thread: ?*c.SDL_Thread = null,
    table_done: std.atomic.Value(bool) = .init(false),
    table_failed: std.atomic.Value(u32) = .init(0),
    /// Set to fetch one table instead of every configured one.
    table_only: ?[]const u8 = null,
    stats: db_mod.ScanStats = .{},
    start_held: bool = false,
    select_held: bool = false,
    /// The 5 key: beatoraja's way to the detail panel from a keyboard.
    detail_held: bool = false,
    exit_since_ms: u64 = 0,
    /// Index into `mode_filters`.
    mode_filter: u8 = 0,
    /// Up to `max_replays` newest are offered per chart, as beatoraja's slots.
    replay_slot: u8 = 0,
    replay_count_for: [64]u8 = undefined,
    replay_count: ?u8 = null,
    /// Holds the replay being played back.
    replay_arena: ?std.heap.ArenaAllocator = null,
    /// The panel the skin's timers last saw.
    panel_seen: u8 = 0,
    /// A scratch held in beatoraja song select: its direction, and when it next moves the cursor.
    pad_scroll: i8 = 0,
    pad_scroll_at_ms: u64 = 0,
};

const random_names = [_][]const u8{ "OFF", "MIRROR", "RANDOM", "R-RANDOM", "S-RANDOM" };
pub const gauge_names = [_][]const u8{ "ASSIST EASY", "EASY", "NORMAL", "HARD", "EX HARD", "HAZARD", "GAS" };
const hs_names = [_][]const u8{ "START", "MAX", "MAIN", "OFF" };
// In beatoraja's order: its skins show the sort by this index.
const sort_count = 8;
const scan_interval_ms = 30_000;

pub fn init(a: *App) void {
    reload(a);
    startScan(a);
}

pub fn deinit(a: *App) void {
    const s = &a.sel;
    dropBoard(a);
    if (s.replay_arena) |*r| r.deinit();
    if (s.scan_thread) |t| c.SDL_WaitThread(t, null);
    if (s.table_thread) |t| c.SDL_WaitThread(t, null);
    if (s.jacket_job) |j| j.destroy();
    if (s.jacket) |t| a.g.destroyTexture(t);
    if (s.jacket_old) |t| a.g.destroyTexture(t);
    if (s.logo) |t| a.g.destroyTexture(t);
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
    s.status = if (failed == 0) tr("Tables updated") else i18n.bufPrint(&s.status_buf, "{d} of {d} tables failed to load", .{ failed, total }) catch tr("Tables failed to load");
    reload(a);
    return true;
}

/// Rebuilds the visible rows from the DB; keeps the cursor on the same index.
pub fn reload(a: *App) void {
    const s = &a.sel;
    // A rescan may have added or removed the room's chart.
    a.versus.chart_checked = @splat(0);
    if (s.arena) |*ar| ar.deinit();
    s.arena = std.heap.ArenaAllocator.init(a.gpa);
    const al = s.arena.?.allocator();
    s.rows = buildRows(a, al) catch |e| blk: {
        std.log.err("list failed: {t}", .{e});
        break :blk &.{};
    };
    keepFilteredMode(s);
    s.replay_count = null;
    if (s.cursor >= s.rows.len) s.cursor = if (s.rows.len == 0) 0 else s.rows.len - 1;
}

/// beatoraja's play mode filter, in its order. Its skins number them differently.
/// shortcut: folder and level counts still include hidden charts, count per mode if it misleads.
const mode_filters = [_]struct { mode: ?core.types.Mode, skin_index: i64, name: []const u8 }{
    .{ .mode = null, .skin_index = 0, .name = "ALL" },
    .{ .mode = .beat7, .skin_index = 2, .name = "7K" },
    .{ .mode = .beat14, .skin_index = 4, .name = "14K" },
    .{ .mode = .popn9, .skin_index = 5, .name = "9K" },
    .{ .mode = .beat5, .skin_index = 1, .name = "5K" },
    .{ .mode = .beat10, .skin_index = 3, .name = "10K" },
};

fn keepFilteredMode(s: *State) void {
    const want = mode_filters[s.mode_filter].mode orelse return;
    var kept: usize = 0;
    for (s.rows) |row| {
        if (row.song) |song| if (song.mode != @backingInt(want)) continue;
        s.rows[kept] = row;
        kept += 1;
    }
    s.rows = s.rows[0..kept];
}

fn orderBy(sort: u8) []const u8 {
    return switch (sort) {
        1 => " ORDER BY s.artist, s.title",
        2 => " ORDER BY s.max_bpm, s.title",
        3 => " ORDER BY s.length_ms, s.title",
        4 => " ORDER BY CAST(s.level AS INTEGER), s.title",
        5 => " ORDER BY COALESCE(c.clear,0) DESC, s.title",
        6 => " ORDER BY COALESCE(c.ex,0) DESC, s.title",
        // Charts never played have no miss count: they go last.
        7 => " ORDER BY COALESCE(c.min_bp,-1)<0, c.min_bp, s.title",
        else => " ORDER BY s.title, s.difficulty",
    };
}

/// shortcut: SQLite's LIKE folds ASCII case only, so accented Latin and Cyrillic stay case-sensitive; ICU if it matters.
fn searchSql(al: std.mem.Allocator, words: usize, sort: u8) ![]const u8 {
    var sql: std.ArrayList(u8) = .empty;
    try sql.appendSlice(al, db_mod.song_select);
    for (1..words + 1) |i| {
        try sql.print(al, "{s} (", .{if (i == 1) " WHERE" else " AND"});
        for ([_][]const u8{ "title", "subtitle", "artist", "subartist", "genre" }, 0..) |col, j| {
            try sql.print(al, "{s}s.{s} LIKE ?{d} ESCAPE '\\'", .{ if (j > 0) " OR " else "", col, i });
        }
        try sql.append(al, ')');
    }
    if (sort == 0) {
        try sql.print(al, " ORDER BY s.title LIKE ?{d} ESCAPE '\\' DESC, s.title, s.difficulty", .{words + 1});
    } else try sql.appendSlice(al, orderBy(sort));
    try sql.appendSlice(al, " LIMIT 2000");
    return sql.items;
}

fn likePattern(al: std.mem.Allocator, word: []const u8, anywhere: bool) ![]const u8 {
    var pat: std.ArrayList(u8) = .empty;
    if (anywhere) try pat.append(al, '%');
    for (word) |ch| {
        if (ch == '%' or ch == '_' or ch == '\\') try pat.append(al, '\\');
        try pat.append(al, ch);
    }
    try pat.append(al, '%');
    return pat.items;
}

test "a click does not reach the list under an overlay" {
    const t = @import("testing.zig");
    const a = try t.open();
    defer t.close(a);
    a.g.clicked = true;
    blockClickUnderOverlay(a);
    try std.testing.expect(a.g.clicked);
    a.versus.open = true;
    blockClickUnderOverlay(a);
    try std.testing.expect(!a.g.clicked);
}

test "a pad can leave the practice screen, and a section is refused on another chart" {
    const t = @import("testing.zig");
    const a = try t.open();
    defer t.close(a);
    a.sel.view = .folder;
    a.sel.folder = "/a";
    reload(a);
    a.cfg.beatoraja_select = true;
    a.practice.open = true;
    a.practice.sha256 = @splat('x');
    startPractice(a, .{ .start_us = 0, .end_us = 1 });
    try std.testing.expect(a.scene == .select);
    try std.testing.expect(pad(a, a.cfg.p1[1], true, false));
    try std.testing.expect(!a.practice.open);
}

test "keys mark a favorite and the favorites folder lists it" {
    const t = @import("testing.zig");
    const a = try t.open();
    defer t.close(a);
    a.sel.view = .folder;
    a.sel.folder = "/a";
    reload(a);
    key(a, c.SDL_SCANCODE_F);
    var sha: [4]u8 = undefined;
    @memcpy(&sha, a.sel.rows[a.sel.cursor].song.?.sha256);
    try std.testing.expect(a.sel.rows[a.sel.cursor].song.?.favorite);
    a.sel.view = .favorites;
    reload(a);
    try std.testing.expectEqual(@as(usize, 1), a.sel.rows.len);
    try std.testing.expectEqualStrings(&sha, a.sel.rows[0].song.?.sha256);
    key(a, c.SDL_SCANCODE_F);
    try std.testing.expectEqual(@as(usize, 0), a.sel.rows.len);
    const was = a.cfg.pace_target;
    key(a, c.SDL_SCANCODE_9);
    try std.testing.expect(a.cfg.pace_target != was);
    a.cfg.pace_target = was;
}

test "search patterns escape LIKE's wildcards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    try std.testing.expectEqualStrings("%100\\%\\_a%", try likePattern(al, "100%_a", true));
    try std.testing.expectEqualStrings("abc%", try likePattern(al, "abc", false));
}

test "search matches every word, in any order, title openings first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const d = try db_mod.Db.open(":memory:", std.testing.allocator, false);
    defer d.close();
    try d.exec(db_mod.schema);
    try d.exec("INSERT INTO song(path,folder,sha256,md5,title,artist,subtitle,subartist,genre) VALUES" ++
        "('1','f','a','a','Blue Sky','Rin','','','Pop')," ++
        "('2','f','b','b','A Sky','Rin','','','Pop')," ++
        "('3','f','c','c','Sky Tower','Mio','','','Pop')");
    const st = try d.prepare(try searchSql(al, 2, 0));
    defer st.deinit();
    st.bindText(1, try likePattern(al, "rin", true));
    st.bindText(2, try likePattern(al, "sky", true));
    st.bindText(3, try likePattern(al, "rin sky", false));
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("A Sky", (try db_mod.readSong(al, st)).title);
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("Blue Sky", (try db_mod.readSong(al, st)).title);
    try std.testing.expect(!try st.step());

    const one = try d.prepare(try searchSql(al, 1, 0));
    defer one.deinit();
    one.bindText(1, try likePattern(al, "sky", true));
    one.bindText(2, try likePattern(al, "sky", false));
    try std.testing.expect(try one.step());
    try std.testing.expectEqualStrings("Sky Tower", (try db_mod.readSong(al, one)).title);
}

fn searchRows(a: *App, al: std.mem.Allocator, rows: *std.ArrayList(Row), words: *std.mem.TokenIterator(u8, .any)) !void {
    const s = &a.sel;
    var count: usize = 0;
    while (words.next() != null) count += 1;
    words.reset();
    const st = try a.db.prepare(try searchSql(al, count, s.sort));
    defer st.deinit();
    var at: c_int = 1;
    while (words.next()) |word| : (at += 1) st.bindText(at, try likePattern(al, word, true));
    // ?N: the whole query opening a title ranks first.
    if (s.sort == 0) st.bindText(at, try likePattern(al, std.mem.trim(u8, s.search, " \t"), false));
    while (try st.step()) {
        const song = try db_mod.readSong(al, st);
        try rows.append(al, .{ .label = song.title, .song = song });
    }
}

fn rootRows(a: *App, al: std.mem.Allocator, rows: *std.ArrayList(Row)) !void {
    const roots = try db_mod.outerRoots(al, a.cfg.roots);
    // Without folders, scores imported or left from removed folders still have a place.
    if (roots.len == 0) try rows.append(al, .{ .label = tr("Library"), .kind = .group });
    for (roots) |r| try rows.append(al, .{ .label = rootName(r), .kind = .group, .target = r });
    try rows.append(al, .{ .label = tr("Favorites"), .kind = .group, .id = 2 });
    const st = try a.db.prepare("SELECT url,name,symbol FROM bms_table ORDER BY name");
    defer st.deinit();
    while (try st.step()) {
        try rows.append(al, .{ .label = try al.dupe(u8, st.text(1)), .kind = .table, .target = try al.dupe(u8, st.text(0)) });
    }
    try rows.append(al, .{ .label = tr("Courses"), .kind = .group, .id = 1 });
}

fn rootName(root: []const u8) []const u8 {
    const name = std.fs.path.basename(root);
    return if (name.len > 0) name else root;
}

fn libraryRows(a: *App, al: std.mem.Allocator, rows: *std.ArrayList(Row)) !void {
    const root = a.sel.library_root;
    const st = try a.db.prepare("SELECT folder, MIN(title), COUNT(*) FROM song WHERE ?1='' OR folder=?1 OR folder LIKE ?2 ESCAPE '\\' GROUP BY folder ORDER BY MIN(title)");
    defer st.deinit();
    st.bindText(1, root);
    // The separator keeps /mnt/bms from also listing /mnt/bms2.
    const under = if (root.len > 0 and std.fs.path.isSep(root[root.len - 1])) root else try std.fmt.allocPrint(al, "{s}{c}", .{ root, std.fs.path.sep });
    st.bindText(2, try db_mod.likePrefix(al, under));
    while (try st.step()) {
        try rows.append(al, .{
            .label = try std.fmt.allocPrint(al, "{s}  ({d})", .{ st.text(1), st.int(2) }),
            .kind = .folder,
            .target = try al.dupe(u8, st.text(0)),
        });
    }
}

fn folderRows(a: *App, al: std.mem.Allocator, rows: *std.ArrayList(Row)) !void {
    const s = &a.sel;
    const sql = try std.fmt.allocPrint(al, "{s} WHERE s.folder=?1{s}", .{ db_mod.song_select, orderBy(s.sort) });
    const st = try a.db.prepare(sql);
    defer st.deinit();
    st.bindText(1, s.folder);
    while (try st.step()) {
        const song = try db_mod.readSong(al, st);
        try rows.append(al, .{ .label = song.title, .song = song });
    }
}

fn favoriteRows(a: *App, al: std.mem.Allocator, rows: *std.ArrayList(Row)) !void {
    const s = &a.sel;
    const sql = try std.fmt.allocPrint(al, "{s} WHERE s.sha256 IN (SELECT sha256 FROM favorite) GROUP BY s.sha256{s}", .{ db_mod.song_select, orderBy(s.sort) });
    const st = try a.db.prepare(sql);
    defer st.deinit();
    while (try st.step()) {
        const song = try db_mod.readSong(al, st);
        try rows.append(al, .{ .label = song.title, .song = song });
    }
}

fn tableRows(a: *App, al: std.mem.Allocator, rows: *std.ArrayList(Row)) !void {
    const s = &a.sel;
    const st = try a.db.prepare("SELECT level, COUNT(*) FROM table_song WHERE url=?1 GROUP BY level ORDER BY MIN(ord)");
    defer st.deinit();
    st.bindText(1, s.table_url);
    var level_buf: [256]u8 = undefined;
    while (try st.step()) {
        try rows.append(al, .{
            .label = try al.dupe(u8, try i18n.bufPrint(&level_buf, "Level {s}  ({d})", .{ st.text(0), st.int(1) })),
            .kind = .level,
            .target = try al.dupe(u8, st.text(0)),
        });
    }
}

fn levelRows(a: *App, al: std.mem.Allocator, rows: *std.ArrayList(Row)) !void {
    const s = &a.sel;
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
}

fn courseRows(a: *App, al: std.mem.Allocator, rows: *std.ArrayList(Row)) !void {
    const st = try a.db.prepare("SELECT c.id,c.name,t.name FROM course c LEFT JOIN bms_table t ON t.url=c.table_url ORDER BY t.name,c.id");
    defer st.deinit();
    while (try st.step()) {
        try rows.append(al, .{
            .label = try std.fmt.allocPrint(al, "{s}: {s}", .{ st.text(2), st.text(1) }),
            .kind = .course,
            .id = st.int(0),
        });
    }
}

fn buildRows(a: *App, al: std.mem.Allocator) ![]Row {
    const s = &a.sel;
    var rows: std.ArrayList(Row) = .empty;
    var words = std.mem.tokenizeAny(u8, s.search, " \t\u{3000}");
    if (words.peek() != null) {
        try searchRows(a, al, &rows, &words);
    } else switch (s.view) {
        .root => try rootRows(a, al, &rows),
        .library => try libraryRows(a, al, &rows),
        .folder => try folderRows(a, al, &rows),
        .table => try tableRows(a, al, &rows),
        .level => try levelRows(a, al, &rows),
        .courses => try courseRows(a, al, &rows),
        .favorites => try favoriteRows(a, al, &rows),
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

fn drawHeader(a: *App) void {
    const g = &a.g;
    const s = &a.sel;
    const u = g.h / 720;
    if (s.logo == null) s.logo = gfx.loadTexture(g, "logo", @embedFile("logo"));
    if (s.logo) |t| g.sprite(t, null, .{ .x = 26 * u, .y = 12 * u, .w = 32 * u * t.w / t.h, .h = 32 * u }, .{});
    if (s.searching) {
        g.fmtTr(290 * u, 18 * u, g.scaled(16), gfx.cyan, "SEARCH: {s}_", .{a.text.items});
    } else if (s.scan_thread != null) {
        g.fmtTr(290 * u, 19 * u, g.scaled(14), gfx.dim, "Scanning... {d}", .{s.scan_progress.load(.monotonic)});
    } else if (s.status.len > 0) g.textClip(s.status, 290 * u, 19 * u, g.w - 310 * u, g.scaled(14), gfx.sky);

    if (s.download) |j| {
        const total = j.progress.total.load(.acquire);
        if (total > 0 and !j.extracting.load(.acquire)) {
            const frac = @as(f32, @floatFromInt(@min(j.progress.done.load(.acquire), total))) / @as(f32, @floatFromInt(total));
            g.rect(10 * u, 46 * u, (g.w - 20 * u) * frac, 2 * u, gfx.accent);
        }
    }
}

/// Rows lean away from the selected one.
fn drawWheel(a: *App, wheel_x: f32, dock_y: f32) void {
    const g = &a.g;
    const s = &a.sel;
    const u = g.h / 720;
    const top = 54 * u;
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
            if (song.favorite) g.disc(x + 60 * u, y + h / 2, 3 * u, gfx.amber);
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
        g.textCentered(if (a.cfg.roots.len == 0) (if (a.cfg.beatoraja_select) tr("No library folders yet. Press 6 to add one.") else tr("No library folders yet. Press F10 to add one.")) else if (s.search.len > 0) tr("No charts match.") else tr("Nothing here."), g.w * 0.72, mid - 10 * u, g.scaled(16), gfx.dim);
    }
}

/// The jacket and data of the selected row.
/// Scrolling past charts asks the server nothing.
const board_delay_ms = 400;

fn drawChartInfo(a: *App, wheel_x: f32, dock_y: f32) void {
    const g = &a.g;
    const s = &a.sel;
    const u = g.h / 720;
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
                if (s.board) |b| {
                    var place: [64]u8 = undefined;
                    _ = g.text(b.placeText(&place), lx + 18 * u, iy + sh - 20 * u, g.scaled(12), gfx.sky);
                }
            }
        } else {
            g.textClip(s.rows[s.cursor].label, lx, iy, lw, g.scaled(32), gfx.white);
            iy += 44 * u;
            var hint_key: [32]u8 = undefined;
            const open_key = guideKey(a, a.cfg.p1[0], "Enter", &hint_key);
            g.fmt(lx, iy, g.scaled(14), gfx.sky, "{s}: {s}", .{ open_key, if (s.rows[s.cursor].kind == .missing) tr("download this chart") else tr("open") });
        }
    }
}

/// Option tabs with their keys, then the remaining commands.
fn drawDock(a: *App, dock_y: f32) void {
    const g = &a.g;
    const s = &a.sel;
    const u = g.h / 720;
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
    const on = a.cfg.beatoraja_select;
    const tabs: f32 = 8;
    const tw = (g.w - 28 * u - 6 * u * (tabs - 1)) / tabs;
    const tab_x = struct {
        fn f(uu: f32, width: f32, i: f32) f32 {
            return 14 * uu + (width + 6 * uu) * i;
        }
    }.f;
    var dock_buf: [32]u8 = undefined;
    tab(a, tab_x(u, tw, 0), dock_y, tw, c.SDL_SCANCODE_F1, "F1", "RANDOM", random_names[@min(a.cfg.random, 4)]);
    tab(a, tab_x(u, tw, 1), dock_y, tw, c.SDL_SCANCODE_F2, "F2", "GAUGE", gauge_names[@min(a.cfg.gauge, config.gas)]);
    tab(a, tab_x(u, tw, 2), dock_y, tw, c.SDL_SCANCODE_F3, "F3", "HS FIX / GREEN", std.fmt.bufPrint(&dock_buf, "{s}  {d}", .{ hs_names[@min(a.cfg.hs_fix, 3)], a.cfg.green_ms * 3 / 5 }) catch "");
    tab(a, tab_x(u, tw, 3), dock_y, tw, c.SDL_SCANCODE_F4, if (on) "2" else "F4", tr("SORT"), ([sort_count][]const u8{ tr("TITLE"), tr("ARTIST"), "BPM", tr("LENGTH"), tr("LEVEL"), "CLEAR", "EX", "MISS" })[s.sort]);
    tab(a, tab_x(u, tw, 4), dock_y, tw, c.SDL_SCANCODE_1, "1", tr("KEY MODE"), mode_filters[s.mode_filter].name);
    tab(a, tab_x(u, tw, 5), dock_y, tw, c.SDL_SCANCODE_3, "3", "LN MODE", ([_][]const u8{ "LN", "CN", "HCN" })[@min(a.cfg.ln_mode, 2)]);
    var replay_buf: [16]u8 = undefined;
    const replays = if (selectedSong(s)) |song| replaysOf(a, song.sha256) else 0;
    tab(a, tab_x(u, tw, 6), dock_y, tw, c.SDL_SCANCODE_4, "4", tr("REPLAY"), if (replays == 0) tr("NONE") else std.fmt.bufPrint(&replay_buf, "{d} / {d}", .{ s.replay_slot + 1, replays }) catch "");
    tab(a, tab_x(u, tw, tabs - 1), dock_y, tw, c.SDL_SCANCODE_F5, "F5", tr("AUTOPLAY"), if (s.autoplay) "ON" else "OFF");

    // The remaining commands, as a row of text buttons.
    const Cmd = struct { sc: u32, label: []const u8 };
    const keyboard_cmds = [_]Cmd{
        .{ .sc = c.SDL_SCANCODE_F6, .label = tr("F6 Search") },
        .{ .sc = c.SDL_SCANCODE_F7, .label = tr("F7 Rescan") },
        .{ .sc = c.SDL_SCANCODE_F8, .label = tr("F8 Tables") },
        .{ .sc = c.SDL_SCANCODE_F9, .label = "F9 IR" },
        .{ .sc = c.SDL_SCANCODE_F10, .label = tr("F10 Settings") },
        .{ .sc = c.SDL_SCANCODE_R, .label = tr("R Replay") },
        .{ .sc = c.SDL_SCANCODE_V, .label = tr("V Versus") },
        .{ .sc = c.SDL_SCANCODE_8, .label = tr("8 Folder") },
        .{ .sc = c.SDL_SCANCODE_ESCAPE, .label = tr("Esc Back") },
    };
    var name_buf: [4][32]u8 = undefined;
    const cfg = &a.cfg;
    const start = settings.keyName(cfg.start_select[0], &name_buf[0]);
    const scratch_a = settings.keyName(cfg.p1[7], &name_buf[1]);
    const scratch_b = settings.keyName(cfg.p1[8], &name_buf[2]);
    const select_key = settings.keyName(cfg.start_select[1], &name_buf[3]);
    var key_buf: [4][32]u8 = undefined;
    var label_buf: [7][80]u8 = undefined;
    // Without a key of its own to click, sc 0 does nothing.
    const beatoraja_cmds = [_]Cmd{
        .{ .sc = c.SDL_SCANCODE_RETURN, .label = i18n.bufPrint(&label_buf[0], "{s} Open", .{settings.keyName(cfg.p1[0], &key_buf[0])}) catch "" },
        .{ .sc = 0, .label = i18n.bufPrint(&label_buf[1], "{s} Auto", .{settings.keyName(cfg.p1[4], &key_buf[1])}) catch "" },
        .{ .sc = 0, .label = i18n.bufPrint(&label_buf[6], "{s} Replay", .{settings.keyName(cfg.p1[6], &key_buf[3])}) catch "" },
        .{ .sc = c.SDL_SCANCODE_ESCAPE, .label = i18n.bufPrint(&label_buf[2], "{s} Back", .{settings.keyName(cfg.p1[1], &key_buf[2])}) catch "" },
        .{ .sc = 0, .label = i18n.bufPrint(&label_buf[3], "{s}, {s} Scroll", .{ scratch_a, scratch_b }) catch "" },
        .{ .sc = 0, .label = i18n.bufPrint(&label_buf[4], "Hold {s} Options", .{start}) catch "" },
        .{ .sc = 0, .label = i18n.bufPrint(&label_buf[5], "Hold {s}+{s} or 5 Detail", .{ start, select_key }) catch "" },
        .{ .sc = c.SDL_SCANCODE_0, .label = tr("0 Search") },
        .{ .sc = c.SDL_SCANCODE_7, .label = tr("7 IR page") },
        .{ .sc = c.SDL_SCANCODE_V, .label = tr("V Versus") },
        .{ .sc = c.SDL_SCANCODE_8, .label = tr("8 Folder") },
        .{ .sc = c.SDL_SCANCODE_6, .label = tr("6 Key config") },
    };
    const cmds: []const Cmd = if (cfg.beatoraja_select) &beatoraja_cmds else &keyboard_cmds;
    const cmd_size = g.scaled(12);
    var cmd_w: f32 = 0;
    for (cmds) |cmd| cmd_w += g.measure(cmd.label, cmd_size) + 24 * u;
    var cmd_x = (g.w - cmd_w) / 2;
    const cmd_y = g.h - 28 * u;
    for (cmds) |cmd| {
        const bw = g.measure(cmd.label, cmd_size) + 24 * u;
        const hover = g.hit(cmd_x, cmd_y, bw, 24 * u);
        if (g.clickIn(cmd_x, cmd_y, bw, 24 * u) and cmd.sc != 0) a.click_key = cmd.sc;
        if (hover) g.round(cmd_x, cmd_y, bw, 24 * u, 6 * u, gfx.rule);
        g.textCentered(cmd.label, cmd_x + bw / 2, cmd_y + 4 * u, cmd_size, if (hover) gfx.white else gfx.dim);
        cmd_x += bw;
    }
}

/// Forgets the ranking, so it is asked for again: a play or a sign-in changes it.
pub fn dropBoard(a: *App) void {
    const s = &a.sel;
    if (s.board) |b| b.release();
    s.board = null;
    a.select_state.ir_board = null;
    s.board_sha_len = 0;
    s.board_asked = false;
}

/// Only when signed in, so browsing tells no server what is in the library before that.
fn tickBoard(a: *App, now_ms: u64) void {
    const s = &a.sel;
    const signed_in = a.cfg.ir_url.len > 0 and a.cfg.ir_token.len > 0;
    const sha = if (signed_in) if (selectedSong(s)) |song| song.sha256 else "" else "";
    if (!std.mem.eql(u8, sha, s.board_sha[0..s.board_sha_len])) {
        dropBoard(a);
        s.board_sha_len = @min(sha.len, s.board_sha.len);
        @memcpy(s.board_sha[0..s.board_sha_len], sha[0..s.board_sha_len]);
        s.board_since_ms = now_ms;
        return;
    }
    if (sha.len == 0 or s.board_asked or now_ms - s.board_since_ms < board_delay_ms) return;
    s.board_asked = true;
    s.board = ir.startRanking(a.gpa, a.cfg.ir_url, a.cfg.ir_token, sha);
    a.select_state.ir_board = s.board;
}

/// The list is drawn under these, and they take no clicks of their own.
fn blockClickUnderOverlay(a: *App) void {
    if (a.practice.open or a.versus.open) a.g.clicked = false;
}

pub fn draw(a: *App) void {
    blockClickUnderOverlay(a);
    tickBoard(a, c.SDL_GetTicks());
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

    drawHeader(a);
    const wheel_x = g.w * 0.46;
    const dock_y = g.h - 74 * u;
    drawWheel(a, wheel_x, dock_y);
    drawChartInfo(a, wheel_x, dock_y);
    drawDock(a, dock_y);
    drawPanel(a);
    drawQuery(a);
}

/// Skins draw their own panels; this is the built-in look's.
fn drawPanel(a: *App) void {
    const panel = panelOf(&a.sel);
    if (panel == 0) return;
    const g = &a.g;
    const u = g.h / 720;
    var buf: [3][96]u8 = undefined;
    var names: [3][32]u8 = undefined;
    const cfg = &a.cfg;
    const lines: [3][]const u8 = switch (panel) {
        1 => .{
            std.fmt.bufPrint(&buf[0], "{s}, {s}  RANDOM  {s}", .{ settings.keyName(cfg.p1[0], &names[0]), settings.keyName(cfg.p1[1], &names[1]), random_names[@min(cfg.random, 4)] }) catch "",
            std.fmt.bufPrint(&buf[1], "{s}  GAUGE  {s}", .{ settings.keyName(cfg.p1[2], &names[2]), gauge_names[@min(cfg.gauge, config.gas)] }) catch "",
            std.fmt.bufPrint(&buf[2], "{s}  HS FIX  {s}", .{ settings.keyName(cfg.p1[4], &names[2]), hs_names[@min(cfg.hs_fix, 3)] }) catch "",
        },
        2 => .{ tr("Nothing to set here yet"), "", "" },
        else => .{
            std.fmt.bufPrint(&buf[0], "{s}  GAS  {s}", .{ settings.keyName(cfg.p1[1], &names[0]), if (cfg.gauge == config.gas) "ON" else "OFF" }) catch "",
            i18n.bufPrint(&buf[1], "{s}, {s}  DURATION  {d} ms", .{ settings.keyName(cfg.p1[3], &names[0]), settings.keyName(cfg.p1[5], &names[1]), cfg.green_ms }) catch "",
            i18n.bufPrint(&buf[2], "{s}, {s}  JUDGE OFFSET  {d} ms", .{ settings.keyName(cfg.p1[4], &names[0]), settings.keyName(cfg.p1[6], &names[1]), cfg.judge_offset_ms }) catch "",
        },
    };
    const w = 420 * u;
    const x = (g.w - w) / 2;
    const y = g.h * 0.32;
    g.panel(x, y, w, 118 * u, "");
    for (lines, 0..) |line, i| _ = g.text(line, x + 20 * u, y + 16 * u + 30 * u * @as(f32, @floatFromInt(i)), g.scaled(16), gfx.white);
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
            .library => if (s.library_root.len > 0) rootName(s.library_root) else tr("LIBRARY"),
            .folder => std.fs.path.basename(s.folder),
            .table => tr("TABLE"),
            .level => s.level,
            .courses => tr("COURSES"),
            .favorites => tr("Favorites"),
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
    const cfg = &a.cfg;
    st.select.?.panel = panelOf(s);
    st.select.?.gauge_index = @min(cfg.gauge, 4);
    st.select.?.random_index = cfg.random;
    // beatoraja lists off first and adds min BPM last.
    st.select.?.hsfix_index = if (cfg.hs_fix >= 3) 0 else cfg.hs_fix + 1;
    // GAS starts from the gauge picked and falls: beatoraja's "select to under".
    st.select.?.autoshift_index = if (cfg.gauge == config.gas) 4 else 0;
    st.select.?.mode_index = mode_filters[s.mode_filter].skin_index;
    st.select.?.sort_index = s.sort;
    st.select.?.ln_index = @min(cfg.ln_mode, 2);
    st.select.?.replays = if (song) |sg| replaysOf(a, sg.sha256) else 0;
    st.select.?.replay_slot = s.replay_slot;
    st.green_ms = cfg.green_ms;
    st.cover = cfg.lane_cover;
    st.lift = cfg.lift;
    st.hidden = cfg.hidden;
    st.judge_offset_ms = cfg.judge_offset_ms;
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
        s.panel_seen = 0;
    }
    a.select_seen = now;
    const shown: i64 = @intCast(now - a.select_at);
    if (s.cursor != a.select_row) {
        a.select_row = s.cursor;
        a.select_state.timers[11] = shown;
    }
    const panel = panelOf(s);
    if (panel != s.panel_seen) {
        if (s.panel_seen != 0) {
            a.select_state.timers[@as(usize, 20) + s.panel_seen] = -1;
            a.select_state.timers[@as(usize, 30) + s.panel_seen] = shown;
        }
        if (panel != 0) {
            a.select_state.timers[@as(usize, 20) + panel] = shown;
            a.select_state.timers[@as(usize, 30) + panel] = -1;
        }
        s.panel_seen = panel;
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
        g.fmtTr(26 * u, 18 * u, g.scaled(16), gfx.cyan, "SEARCH: {s}_", .{a.text.items});
    } else if (s.scan_thread != null) {
        g.fmtTr(26 * u, 8 * u, g.scaled(14), gfx.dim, "Scanning... {d}", .{s.scan_progress.load(.monotonic)});
    } else if (s.status.len > 0) {
        g.panel(10 * u, 8 * u, g.w - 20 * u, 40 * u, "");
        g.textClip(s.status, 26 * u, 19 * u, g.w - 52 * u, g.scaled(14), gfx.sky);
    }
    if (s.rows.len == 0) g.textCentered(if (a.cfg.roots.len == 0) (if (a.cfg.beatoraja_select) tr("No library folders yet. Press 6 to add one.") else tr("No library folders yet. Press F10 to add one.")) else if (s.search.len > 0) tr("No charts match.") else tr("Nothing here."), g.w * 0.72, g.h * 0.48, g.scaled(16), gfx.white);
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
            _ = g.text(tr("Loading..."), qx + 24, qy + 56, 16, gfx.dim);
        } else if (q.failed) {
            _ = g.text(tr("Could not reach the IR server"), qx + 24, qy + 56, 16, gfx.dim);
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

fn setLibraryRoot(a: *App, root: []const u8) void {
    const s = &a.sel;
    const n = @min(root.len, s.library_root_buf.len);
    std.mem.copyForwards(u8, s.library_root_buf[0..n], root[0..n]);
    s.library_root = s.library_root_buf[0..n];
}

fn setFolder(a: *App, f: []const u8) void {
    const s = &a.sel;
    // A folder opened from a chart: going back must land in the library folder that holds it.
    const root = s.library_root;
    if (root.len > 0 and !std.mem.eql(u8, f, root) and !db_mod.isUnder(f, root)) {
        setLibraryRoot(a, for (a.cfg.roots) |r| {
            if (std.mem.eql(u8, f, r) or db_mod.isUnder(f, r)) break r;
        } else "");
    }
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
            .favorites => row.kind == .group and row.id == 2,
            .root => false,
            .library => row.kind == .group and row.id == 0 and std.mem.eql(u8, row.target, s.library_root),
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
        s.status = tr("No tables yet. Add one in Settings, Tables.");
        return;
    }
    s.table_only = only;
    s.table_done.store(false, .release);
    s.table_failed.store(0, .release);
    s.status = tr("Updating tables...");
    s.table_thread = c.SDL_CreateThread(tableThread, "tables", a);
}

/// Downloads into the first library folder; the scanner then finds the charts.
fn startDownload(a: *App, row: Row) void {
    const s = &a.sel;
    if (s.download != null) {
        s.status = tr("A download is already running");
        return;
    }
    if (a.cfg.roots.len == 0) {
        s.status = tr("Add a library folder first");
        return;
    }
    var buf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const url: []const u8 = if (a.cfg.download_url.len > 0 and row.target.len > 0)
        download.expand(fba.allocator(), a.cfg.download_url, row.target) catch return
    else
        row.extra;
    if (url.len == 0) {
        s.status = tr("No download source for this chart");
        return;
    }
    s.download = download.start(a.gpa, url, a.cfg.roots[0], row.target);
    s.status = if (s.download != null) tr("Downloading...") else tr("Could not start download");
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
            s.status = tr("Extracting...");
            return;
        }
        const done = j.progress.done.load(.acquire);
        if (done != s.download_seen) {
            s.download_seen = done;
            s.download_moved_ms = now;
        } else if (now - s.download_moved_ms > download_stall_ms) {
            s.status = tr("Download stalled: the server stopped sending");
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
    s.status = if (st == 1) tr("Download finished") else tr("Download failed");
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

const max_replays = db_mod.max_replays;

pub fn selectedSong(s: *const State) ?db_mod.Song {
    return if (s.cursor < s.rows.len) s.rows[s.cursor].song else null;
}

/// Cached: this runs every frame, and replays only arrive through a play, after which rows reload.
fn replaysOf(a: *App, sha256: []const u8) u8 {
    const s = &a.sel;
    if (s.replay_count) |n| if (std.mem.eql(u8, &s.replay_count_for, sha256)) return n;
    const n = countReplays(a, sha256) catch |e| blk: {
        std.log.err("replay count failed: {t}", .{e});
        break :blk 0;
    };
    if (sha256.len == s.replay_count_for.len) {
        @memcpy(&s.replay_count_for, sha256);
        s.replay_count = n;
    }
    return n;
}

/// The replays of the LN mode selected, on a chart that leaves it open.
const replay_mode = "ln_mode=CASE WHEN EXISTS(SELECT 1 FROM song WHERE sha256=?1 AND has_open_ln) THEN (SELECT ln_mode FROM temp.play_setting) ELSE 0 END";

fn countReplays(a: *App, sha256: []const u8) !u8 {
    const st = try a.db.prepare("SELECT COUNT(*) FROM (SELECT 1 FROM replay WHERE sha256=?1 AND " ++ replay_mode ++ " LIMIT " ++ std.fmt.comptimePrint("{d}", .{max_replays}) ++ ")");
    defer st.deinit();
    st.bindText(1, sha256);
    return if (try st.step()) @intCast(st.int(0)) else 0;
}

/// Decodes a stored replay, newest first. Its slices live until the next one is loaded.
fn loadReplay(a: *App, sha256: []const u8, slot: u8) !core.replay.Replay {
    const s = &a.sel;
    if (s.replay_arena) |*old| old.deinit();
    s.replay_arena = .init(a.gpa);
    const st = try a.db.prepare("SELECT data FROM replay WHERE sha256=?1 AND " ++ replay_mode ++ " ORDER BY date DESC, id DESC LIMIT 1 OFFSET ?2");
    defer st.deinit();
    st.bindText(1, sha256);
    st.bindInt(2, slot);
    if (!try st.step()) return error.NoReplay;
    return core.replay.decode(s.replay_arena.?.allocator(), st.blob(0));
}

fn nextReplay(a: *App) void {
    const s = &a.sel;
    const song = selectedSong(s) orelse return;
    s.replay_slot = @intCast((@min(s.replay_slot, max_replays - 1) + 1) % @max(replaysOf(a, song.sha256), 1));
    a.sfx(.adjust);
}

fn playReplay(a: *App, song: db_mod.Song) void {
    const s = &a.sel;
    if (a.load_thread != null) return;
    if (s.replay_slot >= replaysOf(a, song.sha256)) {
        s.status = tr("No replay in this slot");
        return;
    }
    const r = loadReplay(a, song.sha256, s.replay_slot) catch |e| {
        std.log.err("replay load failed: {t}", .{e});
        s.status = tr("Could not read this replay");
        return;
    };
    startSongWith(a, song, r, null);
}

fn startSong(a: *App, song: db_mod.Song) void {
    startSongWith(a, song, null, null);
}

/// A round of a versus room: everyone's seed is the same, only LN mode ranks, and no decide screen holds up the clock.
pub fn startVersus(a: *App, song: db_mod.Song, seed: u64) void {
    var params = songParams(a, song) orelse return;
    params.seed = seed;
    params.autoplay = false;
    params.ln_mode = .ln;
    a.startPlay(params, true);
}

pub fn startPractice(a: *App, section: session_mod.Practice) void {
    const song = selectedSong(&a.sel) orelse return;
    // A section's times only mean something on the chart they were set for.
    if (!std.mem.eql(u8, song.sha256, &a.practice.sha256)) return;
    startSongWith(a, song, null, section);
}

fn songParams(a: *App, song: db_mod.Song) ?session_mod.Params {
    // The loader thread may still be reading the buffer, and a path this long can't be opened anyway.
    if (a.load_thread != null or song.path.len > a.play_path_buf.len) return null;
    @memcpy(a.play_path_buf[0..song.path.len], song.path);
    const level_n = @min(song.table_level.len, a.play_level_buf.len);
    @memcpy(a.play_level_buf[0..level_n], song.table_level[0..level_n]);
    const table_n = tableName(a, song);
    return .{
        .path = a.play_path_buf[0..song.path.len],
        .table_level = a.play_level_buf[0..level_n],
        .table_name = a.play_table_buf[0..table_n],
        .gauge = config.gaugeType(a.cfg.gauge),
        .gas = a.cfg.gauge == config.gas,
        .random = @fromBackingInt(@intCast(@min(a.cfg.random, 4))),
        .seed = c.SDL_GetTicksNS(),
        .autoplay = a.sel.autoplay,
        .judge_offset_us = @as(i64, a.cfg.judge_offset_ms) * 1000,
        .ln_mode = std.enums.fromInt(core.options.LnMode, a.cfg.ln_mode) orelse .ln,
    };
}

fn startSongWith(a: *App, song: db_mod.Song, replay: ?core.replay.Replay, section: ?session_mod.Practice) void {
    var params = songParams(a, song) orelse return;
    if (replay) |r| {
        params.replay = r;
        params.gauge = r.gauge;
        params.gas = r.gas;
        params.random = r.random;
        params.seed = r.seed;
        params.ln_mode = r.ln_mode;
        params.autoplay = false;
        params.judge_offset_us = 0;
    }
    if (section) |sec| {
        params.practice = sec;
        params.autoplay = false;
        return a.startPlay(params, false);
    }
    a.decidePlay(params, true);
}

fn toggleFavorite(a: *App, song: db_mod.Song) void {
    var ms: c.SDL_Time = 0;
    _ = c.SDL_GetCurrentTime(&ms);
    a.sel.status = if (db_mod.toggleFavorite(a.db, song.sha256, @divTrunc(ms, std.time.ns_per_s))) |on|
        (if (on) tr("Added to favorites") else tr("Removed from favorites"))
    else |e| blk: {
        std.log.err("favorite not saved: {t}", .{e});
        break :blk tr("Could not save the favorite");
    };
    reload(a);
}

fn closeQuery(a: *App) void {
    if (a.sel.query) |q| q.destroy();
    a.sel.query = null;
}

fn chartPageUrl(gpa: std.mem.Allocator, ir_url: []const u8, sha256: []const u8) ![:0]u8 {
    return std.fmt.allocPrintSentinel(gpa, "{s}/charts/{s}", .{ ir_url, sha256 }, 0);
}

/// The chart's page in the browser. A row without a chart has no page, so it gets the ranking overlay.
fn openChartPage(a: *App) void {
    const song = selectedSong(&a.sel) orelse return openRanking(a);
    if (a.cfg.ir_url.len == 0) return openRanking(a);
    const url = chartPageUrl(a.gpa, a.cfg.ir_url, song.sha256) catch return;
    defer a.gpa.free(url);
    if (!c.SDL_OpenURL(url)) {
        std.log.warn("open {s}: {s}", .{ url, c.SDL_GetError() });
        a.sel.status = tr("Could not open the browser");
    }
}

/// A chart row shows its ranking; a table or level row shows standings over its charts.
fn openRanking(a: *App) void {
    const s = &a.sel;
    if (a.cfg.ir_url.len == 0 or s.cursor >= s.rows.len) {
        s.status = tr("Set an IR server in settings first");
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
        s.query_title = tr("Ranking");
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
    s.query_title = tr("Table standings");
}

fn keyQuery(a: *App, sc: u32) void {
    const s = &a.sel;
    if (sc == c.SDL_SCANCODE_F9) {
        closeQuery(a);
        const url_ok = s.cursor < s.rows.len and s.rows[s.cursor].song != null and a.cfg.ir_token.len > 0;
        if (url_ok and !std.mem.eql(u8, s.query_title, tr("Rivals"))) {
            var buf: [1024]u8 = undefined;
            const url = std.fmt.bufPrint(&buf, "{s}/scores/{s}/rivals", .{ a.cfg.ir_url, s.rows[s.cursor].song.?.sha256 }) catch return;
            s.query = ir.startQuery(a.gpa, url, a.cfg.ir_token, null);
            s.query_title = tr("Rivals");
        }
    } else if (sc == c.SDL_SCANCODE_ESCAPE) closeQuery(a);
}

/// True when the search box took the key.
fn keySearching(a: *App, sc: u32) bool {
    const s = &a.sel;
    switch (sc) {
        c.SDL_SCANCODE_ESCAPE => {
            s.searching = false;
            a.stopText();
            a.text.clearRetainingCapacity();
            if (s.search.len > 0) a.gpa.free(s.search);
            s.search = "";
            reload(a);
            return true;
        },
        c.SDL_SCANCODE_BACKSPACE => {
            while (a.text.items.len > 0) {
                const ch = a.text.pop().?;
                if (ch & 0xC0 != 0x80) break;
            }
            return true;
        },
        c.SDL_SCANCODE_RETURN => {
            s.searching = false;
            a.stopText();
            return true;
        },
        c.SDL_SCANCODE_UP, c.SDL_SCANCODE_DOWN => return false,
        else => return true,
    }
}

fn keySound(a: *App, sc: u32) void {
    const s = &a.sel;
    switch (sc) {
        c.SDL_SCANCODE_UP, c.SDL_SCANCODE_DOWN, c.SDL_SCANCODE_PAGEUP, c.SDL_SCANCODE_PAGEDOWN => a.sfx(.move),
        c.SDL_SCANCODE_F1, c.SDL_SCANCODE_F2, c.SDL_SCANCODE_F3, c.SDL_SCANCODE_F4, c.SDL_SCANCODE_F5 => a.sfx(.adjust),
        c.SDL_SCANCODE_F6, c.SDL_SCANCODE_F7, c.SDL_SCANCODE_F8, c.SDL_SCANCODE_F9, c.SDL_SCANCODE_7 => a.sfx(.confirm),
        c.SDL_SCANCODE_F10, c.SDL_SCANCODE_6 => a.sfxOr(a.sfx_option_open, .confirm),
        c.SDL_SCANCODE_1, c.SDL_SCANCODE_3 => a.sfx(.adjust),
        c.SDL_SCANCODE_8 => if (selectedSong(s) != null) a.sfx(.confirm),
        c.SDL_SCANCODE_ESCAPE => a.sfx(.back),
        c.SDL_SCANCODE_RETURN => if (s.cursor < s.rows.len and s.rows[s.cursor].song == null and s.rows[s.cursor].kind != .course) a.sfx(.confirm),
        else => {},
    }
}

fn openRow(a: *App) void {
    const s = &a.sel;
    if (s.cursor >= s.rows.len) return;
    const row = s.rows[s.cursor];
    if (row.song) |song| return startSong(a, song);
    switch (row.kind) {
        .folder => setFolder(a, row.target),
        .group => {
            if (row.id == 0) setLibraryRoot(a, row.target);
            go(a, switch (row.id) {
                1 => .courses,
                2 => .favorites,
                else => .library,
            });
        },
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
}

fn goBack(a: *App) void {
    const s = &a.sel;
    if (s.search.len > 0) {
        a.gpa.free(s.search);
        s.search = "";
        reload(a);
    } else switch (s.view) {
        .root => a.running = false,
        .library, .courses, .table, .favorites => back(a, .root),
        .folder => back(a, .library),
        .level => back(a, .table),
    }
}

/// The key an on-screen guide names: the bound one under beatoraja controls.
pub fn guideKey(a: *const App, code: u16, keyboard: []const u8, buf: []u8) []const u8 {
    return if (a.cfg.beatoraja_select) settings.keyName(code, buf) else keyboard;
}

fn panelOf(s: *const State) u8 {
    if (s.detail_held or (s.start_held and s.select_held)) return 3;
    if (s.select_held) return 2;
    return @intFromBool(s.start_held);
}

/// Index in `p1`: 7 keys, scratch A, scratch B. Layout from beatoraja's MusicSelectKeyProperty.BEAT_7K.
fn padBrowse(a: *App, at: usize) void {
    const s = &a.sel;
    const on_song = s.cursor < s.rows.len and s.rows[s.cursor].song != null;
    switch (at) {
        0, 2, 4, 6 => {
            if (on_song and at == 2) return practice.open(a, s.rows[s.cursor].song.?);
            if (on_song and at == 6) return playReplay(a, s.rows[s.cursor].song.?);
            const was_auto = s.autoplay;
            if (on_song and at == 4) s.autoplay = true;
            key(a, c.SDL_SCANCODE_RETURN);
            s.autoplay = was_auto;
        },
        5 => nextReplay(a),
        // Unlike Esc, closing never leaves the game.
        1, 3 => if (s.view != .root or s.search.len > 0) key(a, c.SDL_SCANCODE_ESCAPE),
        7, 8 => {
            s.pad_scroll = if (at == 7) -1 else 1;
            s.pad_scroll_at_ms = c.SDL_GetTicks() + pad_scroll_first_ms;
            key(a, if (at == 7) c.SDL_SCANCODE_UP else c.SDL_SCANCODE_DOWN);
        },
        else => {},
    }
}

fn padOption(a: *App, panel: u8, at: usize) void {
    const cfg = &a.cfg;
    const gauges = config.gas + 1;
    switch (panel) {
        1 => switch (at) {
            0 => cfg.random = (cfg.random + 1) % 5,
            1 => cfg.random = (cfg.random + 4) % 5,
            2 => cfg.gauge = (cfg.gauge + 1) % gauges,
            4 => cfg.hs_fix = (cfg.hs_fix + 1) % 4,
            else => return,
        },
        3 => switch (at) {
            1 => cfg.gauge = if (cfg.gauge == config.gas) 4 else config.gas,
            3 => cfg.green_ms = @max(cfg.green_ms, 75) - 25,
            5 => cfg.green_ms += 25,
            4 => cfg.judge_offset_ms -= 1,
            6 => cfg.judge_offset_ms += 1,
            else => return,
        },
        else => return,
    }
    a.sfx(.adjust);
}

fn padSelect(a: *App, at: usize, panel: u8, down: bool, repeat: bool) void {
    if (!down) {
        if (at >= 7) a.sel.pad_scroll = 0;
    } else if (!repeat) {
        if (panel == 0) padBrowse(a, at) else padOption(a, panel, at);
    }
}

/// Start + keys change hi-speed, Select + keys the green number by one, as in beatoraja's
/// ControlInputProcessor. Never uses the input up: the same key still plays its note.
/// shortcut: double-pressing Start does not toggle the lane cover, add it with a cover on/off setting.
fn padPlay(a: *App, at: ?usize, down: bool, repeat: bool) void {
    const s = &a.sel;
    if (at) |i| if (i >= 7 and !down) {
        s.pad_scroll = 0;
    };
    if (!down or repeat or a.pause.open or s.start_held == s.select_held) return;
    const i = at orelse return;
    const cfg = &a.cfg;
    if (i >= 7) {
        s.pad_scroll = if (i == 7) 1 else -1;
        s.pad_scroll_at_ms = 0;
    } else if (s.start_held) {
        if (i % 2 == 0) cfg.green_ms += 25 else cfg.green_ms = @max(cfg.green_ms, 75) - 25;
    } else {
        if (i % 2 == 0) cfg.green_ms = @max(cfg.green_ms, 2) - 1 else cfg.green_ms += 1;
    }
}

/// Index in `p1`, on the practice and room screens, so that a pad alone can use and leave them.
fn overlayKey(at: usize) ?u32 {
    return switch (at) {
        0, 6 => c.SDL_SCANCODE_RETURN,
        1 => c.SDL_SCANCODE_ESCAPE,
        2, 7 => c.SDL_SCANCODE_UP,
        3, 8 => c.SDL_SCANCODE_DOWN,
        4 => c.SDL_SCANCODE_LEFT,
        5 => c.SDL_SCANCODE_RIGHT,
        else => null,
    };
}

/// beatoraja controls. True when the input was used, so it is not also a menu key.
/// Start and Select are tracked on every screen: their release may come after a screen has gone.
/// shortcut: reads only the 1P 7 key layout, add the others if a controller needs them here.
pub fn pad(a: *App, code: u16, down: bool, repeat: bool) bool {
    if (!a.cfg.beatoraja_select) return false;
    if (a.practice.open or a.versus.open) {
        if (down) if (std.mem.indexOfScalar(u16, &a.cfg.p1, code)) |i| if (overlayKey(i)) |sc| {
            if (a.practice.open) practice.key(a, sc) else versus.key(a, sc);
        };
        return true;
    }
    const s = &a.sel;
    const was = panelOf(s);
    const is_start = code == a.cfg.start_select[0];
    const is_select = code == a.cfg.start_select[1];
    const at = std.mem.indexOfScalar(u16, &a.cfg.p1, code);
    // Typing a search uses the same keys.
    if (is_start) s.start_held = down and !s.searching;
    if (is_select) s.select_held = down and !s.searching;
    if (code == c.SDL_SCANCODE_5 and at == null and !is_start and !is_select) s.detail_held = down and a.scene == .select and !s.searching;
    const panel = panelOf(s);
    if (panel != was) s.pad_scroll = 0;
    if (s.query != null or s.searching) {
        s.pad_scroll = 0;
        return false;
    }
    const bound = at != null or is_start or is_select;
    switch (a.scene) {
        .select => {
            if (panel != was) {
                if (was == 0) a.sfxOr(a.sfx_option_open, .confirm) else if (panel == 0) a.sfxOr(a.sfx_option_close, .back);
            }
            if (is_start or is_select) return true;
            padSelect(a, at orelse return false, panel, down, repeat);
            return true;
        },
        .result => {
            // Keys still being mashed from the end of the chart do not skip the result.
            if (bound and down and !repeat and c.SDL_GetTicks() -| a.res.shown_at >= result_input_ms) result.key(a, c.SDL_SCANCODE_RETURN);
            return bound;
        },
        .loading => {
            if (bound and down and !repeat) a.decideKey(c.SDL_SCANCODE_RETURN);
            return bound;
        },
        .play => {
            if (a.session) |session| {
                const snap = session.snapshot();
                if ((is_start or is_select) and down and !repeat and !a.pause.open and session.canSkip(snap)) {
                    a.finishPlay(snap, true);
                    return false;
                }
            }
            padPlay(a, at, down, repeat);
            return false;
        },
        else => return false,
    }
}

const result_input_ms = 500;
// beatoraja's default exitPressDuration.
const play_exit_hold_ms = 1000;

/// What a held input keeps doing: scrolling in song select; in play, moving the cover or the green
/// number with a scratch, and quitting on Start + Select.
pub fn tickPad(a: *App, now_ms: u64) void {
    if (!a.cfg.beatoraja_select) return;
    const s = &a.sel;
    switch (a.scene) {
        .select => tickPadScroll(a, now_ms),
        .play => {
            if (a.pause.open) return;
            if (s.start_held and s.select_held) {
                if (s.exit_since_ms == 0) s.exit_since_ms = now_ms;
                if (now_ms - s.exit_since_ms >= play_exit_hold_ms) {
                    s.exit_since_ms = 0;
                    s.pad_scroll = 0;
                    if (a.session) |session| a.finishPlay(session.snapshot(), false);
                }
                return;
            }
            s.exit_since_ms = 0;
            if (s.pad_scroll == 0 or now_ms < s.pad_scroll_at_ms) return;
            s.pad_scroll_at_ms = now_ms + pad_scroll_next_ms;
            if (s.start_held) {
                a.cfg.setCover(a.cfg.lane_cover + 0.005 * @as(f32, @floatFromInt(s.pad_scroll)));
            } else if (s.pad_scroll > 0) {
                a.cfg.green_ms += 1;
            } else a.cfg.green_ms = @max(a.cfg.green_ms, 2) - 1;
        },
        else => {},
    }
}

// beatoraja's default scroll durations.
const pad_scroll_first_ms = 300;
const pad_scroll_next_ms = 50;

fn tickPadScroll(a: *App, now_ms: u64) void {
    const s = &a.sel;
    if (s.pad_scroll == 0 or now_ms < s.pad_scroll_at_ms) return;
    s.pad_scroll_at_ms = now_ms + pad_scroll_next_ms;
    key(a, if (s.pad_scroll < 0) c.SDL_SCANCODE_UP else c.SDL_SCANCODE_DOWN);
}

pub fn key(a: *App, sc: u32) void {
    const s = &a.sel;
    if (a.practice.open) return practice.key(a, sc);
    if (a.versus.open) return versus.key(a, sc);
    if (s.query != null) return keyQuery(a, sc);
    if (s.searching and keySearching(a, sc)) return;
    keySound(a, sc);
    switch (sc) {
        c.SDL_SCANCODE_UP => if (s.cursor > 0) {
            s.cursor -= 1;
        } else if (s.rows.len > 0) {
            s.cursor = s.rows.len - 1;
        },
        c.SDL_SCANCODE_DOWN => s.cursor = if (s.cursor + 1 < s.rows.len) s.cursor + 1 else 0,
        c.SDL_SCANCODE_PAGEUP => s.cursor -|= 15,
        c.SDL_SCANCODE_PAGEDOWN => s.cursor = @min(s.cursor + 15, s.rows.len -| 1),
        c.SDL_SCANCODE_RETURN => openRow(a),
        c.SDL_SCANCODE_ESCAPE => goBack(a),
        c.SDL_SCANCODE_F1 => a.cfg.random = (a.cfg.random + 1) % 5,
        c.SDL_SCANCODE_F2 => a.cfg.gauge = (a.cfg.gauge + 1) % (config.gas + 1),
        c.SDL_SCANCODE_F3 => a.cfg.hs_fix = (a.cfg.hs_fix + 1) % 4,
        c.SDL_SCANCODE_F4 => {
            s.sort = @intCast((s.sort + 1) % sort_count);
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
        // beatoraja's keyboard controls, which need no setting: nothing else uses these keys here.
        c.SDL_SCANCODE_LEFT => if (s.view != .root or s.search.len > 0) key(a, c.SDL_SCANCODE_ESCAPE),
        c.SDL_SCANCODE_RIGHT => key(a, c.SDL_SCANCODE_RETURN),
        c.SDL_SCANCODE_1 => {
            s.mode_filter = @intCast((s.mode_filter + 1) % mode_filters.len);
            s.cursor = 0;
            reload(a);
        },
        c.SDL_SCANCODE_2 => key(a, c.SDL_SCANCODE_F4),
        c.SDL_SCANCODE_3 => {
            a.cfg.ln_mode = (@min(a.cfg.ln_mode, 2) + 1) % 3;
            db_mod.setLnMode(a.db, a.cfg.ln_mode) catch |e| std.log.err("LN mode not applied to scores: {t}", .{e});
            s.replay_slot = 0;
            reload(a);
        },
        c.SDL_SCANCODE_4 => nextReplay(a),
        c.SDL_SCANCODE_F => if (selectedSong(s)) |song| toggleFavorite(a, song),
        c.SDL_SCANCODE_P => if (selectedSong(s)) |song| practice.open(a, song),
        c.SDL_SCANCODE_V => versus.openScreen(a),
        c.SDL_SCANCODE_9 => {
            a.cfg.pace_target = (@min(a.cfg.pace_target, play.pace_targets.len - 1) + 1) % @as(u8, play.pace_targets.len);
            s.status = play.paceTargetName(a.cfg.pace_target);
        },
        c.SDL_SCANCODE_6 => settings.openControls(a),
        c.SDL_SCANCODE_7 => openChartPage(a),
        c.SDL_SCANCODE_8 => if (selectedSong(s)) |song| setFolder(a, song.folder),
        c.SDL_SCANCODE_0 => key(a, c.SDL_SCANCODE_F6),
        c.SDL_SCANCODE_R => if (selectedSong(s)) |song| playReplay(a, song),
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

fn expectRows(a: *App, want: []const []const u8) !void {
    try std.testing.expectEqual(want.len, a.sel.rows.len);
    for (want, a.sel.rows) |label, row| try std.testing.expectEqualStrings(label, row.label);
}

test "the cursor wraps at the ends and pages stop at them" {
    const a = try testing.open();
    defer testing.close(a);
    key(a, c.SDL_SCANCODE_UP);
    try std.testing.expectEqual(a.sel.rows.len - 1, a.sel.cursor);
    key(a, c.SDL_SCANCODE_DOWN);
    try std.testing.expectEqual(@as(usize, 0), a.sel.cursor);
    key(a, c.SDL_SCANCODE_PAGEDOWN);
    try std.testing.expectEqual(a.sel.rows.len - 1, a.sel.cursor);
    key(a, c.SDL_SCANCODE_PAGEUP);
    try std.testing.expectEqual(@as(usize, 0), a.sel.cursor);
}

test "each library folder is its own row and lists only what it holds" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.roots = &.{ "/a", "/b", "/a/inner" };
    reload(a);
    try expectRows(a, &.{ "a", "b", "Favorites", "Table", "Courses" });
    key(a, c.SDL_SCANCODE_DOWN);
    key(a, c.SDL_SCANCODE_RETURN);
    try expectRows(a, &.{"Delta  (1)"});
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expectEqual(@as(usize, 1), a.sel.cursor);
}

test "enter walks into folders and escape comes back to the row it opened" {
    const a = try testing.open();
    defer testing.close(a);
    try expectRows(a, &.{ "Library", "Favorites", "Table", "Courses" });
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(.library, a.sel.view);
    try expectRows(a, &.{ "Alpha  (3)", "Delta  (1)" });
    key(a, c.SDL_SCANCODE_DOWN);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(.folder, a.sel.view);
    try expectRows(a, &.{"Delta"});
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expectEqual(.library, a.sel.view);
    try std.testing.expectEqual(@as(usize, 1), a.sel.cursor);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expectEqual(.root, a.sel.view);
    try std.testing.expectEqual(@as(usize, 0), a.sel.cursor);
    try std.testing.expect(a.running);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(!a.running);
}

test "a table opens by level and lists charts the library lacks" {
    const a = try testing.open();
    defer testing.close(a);
    key(a, c.SDL_SCANCODE_DOWN);
    key(a, c.SDL_SCANCODE_DOWN);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(.table, a.sel.view);
    try expectRows(a, &.{"Level 3  (2)"});
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(.level, a.sel.view);
    try expectRows(a, &.{ "Alpha", "Lost" });
    try std.testing.expectEqualStrings("*3", a.sel.rows[0].song.?.shownLevel());
    try std.testing.expectEqual(.missing, a.sel.rows[1].kind);
    key(a, c.SDL_SCANCODE_DOWN);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqualStrings("Add a library folder first", a.sel.status);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expectEqual(.table, a.sel.view);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expectEqual(.root, a.sel.view);
    try std.testing.expectEqual(@as(usize, 2), a.sel.cursor);
}

test "the courses row lists courses by table" {
    const a = try testing.open();
    defer testing.close(a);
    key(a, c.SDL_SCANCODE_UP);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expectEqual(.courses, a.sel.view);
    try expectRows(a, &.{"Table: Dan"});
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expectEqual(@as(usize, 3), a.sel.cursor);
}

test "function keys cycle the options and wrap" {
    const a = try testing.open();
    defer testing.close(a);
    for (0..5) |_| key(a, c.SDL_SCANCODE_F1);
    try std.testing.expectEqual(@as(u8, 0), a.cfg.random);
    key(a, c.SDL_SCANCODE_F1);
    try std.testing.expectEqual(@as(u8, 1), a.cfg.random);
    a.cfg.gauge = config.gas;
    key(a, c.SDL_SCANCODE_F2);
    try std.testing.expectEqual(@as(u8, 0), a.cfg.gauge);
    a.cfg.hs_fix = 3;
    key(a, c.SDL_SCANCODE_F3);
    try std.testing.expectEqual(@as(u8, 0), a.cfg.hs_fix);
    key(a, c.SDL_SCANCODE_F5);
    try std.testing.expect(a.sel.autoplay);
    key(a, c.SDL_SCANCODE_F10);
    try std.testing.expectEqual(.settings, a.scene);
}

test "beatoraja select does nothing until it is turned on" {
    const a = try testing.open();
    defer testing.close(a);
    try std.testing.expect(!pad(a, a.cfg.p1[2], true, false));
    try std.testing.expect(!pad(a, a.cfg.start_select[0], true, false));
    try std.testing.expectEqual(.root, a.sel.view);
    try std.testing.expect(!a.sel.start_held);
}

test "beatoraja select opens with odd keys, closes with even ones, and stays in the game" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.beatoraja_select = true;
    a.scene = .select;
    try std.testing.expect(pad(a, a.cfg.p1[1], true, false));
    try std.testing.expect(a.running);
    try std.testing.expect(pad(a, a.cfg.p1[2], true, false));
    try std.testing.expectEqual(.library, a.sel.view);
    _ = pad(a, a.cfg.p1[2], true, true);
    try std.testing.expectEqual(.library, a.sel.view);
    _ = pad(a, a.cfg.p1[1], true, false);
    try std.testing.expectEqual(.root, a.sel.view);
    try std.testing.expect(!pad(a, c.SDL_SCANCODE_RIGHT, true, false));
    try std.testing.expect(!pad(a, c.SDL_SCANCODE_3, true, false));
}

test "a held scratch scrolls until it is let go" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.beatoraja_select = true;
    a.scene = .select;
    _ = pad(a, a.cfg.p1[8], true, false);
    try std.testing.expectEqual(@as(usize, 1), a.sel.cursor);
    a.sel.pad_scroll_at_ms = 100;
    tickPadScroll(a, 99);
    try std.testing.expectEqual(@as(usize, 1), a.sel.cursor);
    tickPadScroll(a, 100);
    try std.testing.expectEqual(@as(usize, 2), a.sel.cursor);
    _ = pad(a, a.cfg.p1[8], false, false);
    tickPadScroll(a, 1000);
    try std.testing.expectEqual(@as(usize, 2), a.sel.cursor);
}

test "start and select pick the panel, whose keys change options instead of moving" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.beatoraja_select = true;
    a.scene = .select;
    const start = a.cfg.start_select[0];
    const sel = a.cfg.start_select[1];
    _ = pad(a, start, true, false);
    try std.testing.expectEqual(@as(u8, 1), panelOf(&a.sel));
    _ = pad(a, a.cfg.p1[1], true, false);
    try std.testing.expectEqual(@as(u8, 4), a.cfg.random);
    _ = pad(a, a.cfg.p1[0], true, false);
    try std.testing.expectEqual(@as(u8, 0), a.cfg.random);
    try std.testing.expectEqual(.root, a.sel.view);
    _ = pad(a, sel, true, false);
    try std.testing.expectEqual(@as(u8, 3), panelOf(&a.sel));
    _ = pad(a, a.cfg.p1[1], true, false);
    try std.testing.expectEqual(@as(u8, 4), a.cfg.gauge);
    _ = pad(a, a.cfg.p1[6], true, false);
    try std.testing.expectEqual(@as(i32, 1), a.cfg.judge_offset_ms);
    _ = pad(a, start, false, false);
    try std.testing.expectEqual(@as(u8, 2), panelOf(&a.sel));
    a.scene = .result;
    _ = pad(a, sel, false, false);
    try std.testing.expectEqual(@as(u8, 0), panelOf(&a.sel));
}

test "the number keys and arrows work without beatoraja controls" {
    const a = try testing.open();
    defer testing.close(a);
    a.scene = .select;
    key(a, c.SDL_SCANCODE_R);
    try std.testing.expectEqualStrings("", a.sel.status);
    key(a, c.SDL_SCANCODE_RIGHT);
    key(a, c.SDL_SCANCODE_RIGHT);
    key(a, c.SDL_SCANCODE_R);
    try std.testing.expectEqualStrings("No replay in this slot", a.sel.status);
    key(a, c.SDL_SCANCODE_LEFT);
    key(a, c.SDL_SCANCODE_LEFT);
    try std.testing.expectEqual(.root, a.sel.view);
    key(a, c.SDL_SCANCODE_LEFT);
    try std.testing.expect(a.running);
    key(a, c.SDL_SCANCODE_3);
    try std.testing.expectEqual(@as(u8, 1), a.cfg.ln_mode);
    a.cfg.ln_mode = 0;
    key(a, c.SDL_SCANCODE_RIGHT);
    try std.testing.expectEqual(.library, a.sel.view);
    key(a, c.SDL_SCANCODE_LEFT);
    try std.testing.expectEqual(.root, a.sel.view);
    try std.testing.expect(a.running);
    key(a, c.SDL_SCANCODE_2);
    try std.testing.expectEqual(@as(u8, 1), a.sel.sort);
    key(a, c.SDL_SCANCODE_6);
    try std.testing.expectEqual(.settings, a.scene);
    try std.testing.expect(a.set.inside);
}

test "any bound input leaves the result, but not one held from the chart's end" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.beatoraja_select = true;
    a.scene = .result;
    a.res.shown_at = c.SDL_GetTicks() + result_input_ms;
    try std.testing.expect(pad(a, a.cfg.p1[3], true, false));
    try std.testing.expectEqual(.result, a.scene);
    a.res.shown_at = c.SDL_GetTicks() -| result_input_ms;
    if (c.SDL_GetTicks() >= result_input_ms) {
        try std.testing.expect(pad(a, a.cfg.p1[3], true, false));
        try std.testing.expectEqual(.select, a.scene);
    }
}

test "start and select with a key change the green number during play, without using up the key" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.beatoraja_select = true;
    a.scene = .play;
    const green = a.cfg.green_ms;
    try std.testing.expect(!pad(a, a.cfg.p1[0], true, false));
    try std.testing.expectEqual(green, a.cfg.green_ms);
    _ = pad(a, a.cfg.start_select[0], true, false);
    try std.testing.expect(!pad(a, a.cfg.p1[0], true, false));
    try std.testing.expectEqual(green + 25, a.cfg.green_ms);
    _ = pad(a, a.cfg.p1[1], true, false);
    try std.testing.expectEqual(green, a.cfg.green_ms);
    _ = pad(a, a.cfg.p1[7], true, false);
    tickPad(a, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.005), a.cfg.lane_cover, 0.0001);
    _ = pad(a, a.cfg.p1[7], false, false);
    tickPad(a, 1000);
    try std.testing.expectApproxEqAbs(@as(f32, 0.005), a.cfg.lane_cover, 0.0001);
    _ = pad(a, a.cfg.start_select[0], false, false);
    _ = pad(a, a.cfg.start_select[1], true, false);
    _ = pad(a, a.cfg.p1[1], true, false);
    try std.testing.expectEqual(green + 1, a.cfg.green_ms);
}

test "guides name the bound key only under beatoraja controls" {
    const a = try testing.open();
    defer testing.close(a);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Enter", guideKey(a, a.cfg.p1[0], "Enter", &buf));
    a.cfg.beatoraja_select = true;
    a.cfg.p1[0] = input.joy_base + 3;
    try std.testing.expectEqualStrings("Pad 3", guideKey(a, a.cfg.p1[0], "Enter", &buf));
}

test "the 1 key filters by play mode and 8 lists the chart's folder" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.beatoraja_select = true;
    a.scene = .select;
    try a.db.exec("UPDATE song SET mode=" ++ std.fmt.comptimePrint("{d}", .{@backingInt(core.types.Mode.beat14)}) ++ " WHERE title='Beta'");
    try a.db.exec("UPDATE song SET mode=" ++ std.fmt.comptimePrint("{d}", .{@backingInt(core.types.Mode.beat7)}) ++ " WHERE title<>'Beta'");
    _ = pad(a, a.cfg.p1[0], true, false);
    _ = pad(a, a.cfg.p1[0], true, false);
    try expectRows(a, &.{ "Alpha", "Beta", "Gamma" });
    key(a, c.SDL_SCANCODE_1);
    try expectRows(a, &.{ "Alpha", "Gamma" });
    key(a, c.SDL_SCANCODE_1);
    try expectRows(a, &.{"Beta"});
    for (2..mode_filters.len) |_| key(a, c.SDL_SCANCODE_1);
    try expectRows(a, &.{ "Alpha", "Beta", "Gamma" });
    a.sel.folder = "";
    a.sel.view = .root;
    reload(a);
    key(a, c.SDL_SCANCODE_F6);
    try a.text.appendSlice(a.gpa, "Delta");
    a.sel.search = try a.gpa.dupe(u8, "Delta");
    reload(a);
    key(a, c.SDL_SCANCODE_RETURN);
    key(a, c.SDL_SCANCODE_8);
    try std.testing.expectEqual(.folder, a.sel.view);
    try std.testing.expectEqualStrings("/b", a.sel.folder);
}

test "replays load newest first, and a broken one is refused" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.beatoraja_select = true;
    a.scene = .select;
    const gpa = a.gpa;
    for ([_]u64{ 11, 22 }, [_]i64{ 1, 2 }) |seed, date| {
        const bytes = try core.replay.encode(gpa, .{ .seed = seed });
        defer gpa.free(bytes);
        const ins = try a.db.prepare("INSERT INTO replay(sha256,date,data) VALUES('sha1',?1,?2)");
        defer ins.deinit();
        ins.bindInt(1, date);
        ins.bindBlob(2, bytes);
        _ = try ins.step();
    }
    try std.testing.expectEqual(@as(u8, 2), replaysOf(a, "sha1"));
    try std.testing.expectEqual(@as(u64, 22), (try loadReplay(a, "sha1", 0)).seed);
    try std.testing.expectEqual(@as(u64, 11), (try loadReplay(a, "sha1", 1)).seed);
    try std.testing.expectError(error.NoReplay, loadReplay(a, "sha1", 2));
    try a.db.exec("INSERT INTO replay(sha256,date,data) VALUES('sha2',1,x'00')");
    try std.testing.expectError(error.BadMagic, loadReplay(a, "sha2", 0));
}

test "the 3 and 4 keys step the LN mode and the replay slot" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.beatoraja_select = true;
    a.scene = .select;
    for ([_]u8{ 1, 2, 0 }) |want| {
        key(a, c.SDL_SCANCODE_3);
        try std.testing.expectEqual(want, a.cfg.ln_mode);
    }
    try a.db.exec("INSERT INTO replay(sha256,date,data) VALUES('sha1',1,x'00'),('sha1',2,x'00')");
    _ = pad(a, a.cfg.p1[0], true, false);
    _ = pad(a, a.cfg.p1[0], true, false);
    for ([_]u8{ 1, 0 }) |want| {
        key(a, c.SDL_SCANCODE_4);
        try std.testing.expectEqual(want, a.sel.replay_slot);
    }
}

test "the 5 key holds the detail panel under beatoraja controls" {
    const a = try testing.open();
    defer testing.close(a);
    a.scene = .select;
    _ = pad(a, c.SDL_SCANCODE_5, true, false);
    try std.testing.expectEqual(@as(u8, 0), panelOf(&a.sel));
    a.cfg.beatoraja_select = true;
    _ = pad(a, c.SDL_SCANCODE_5, true, false);
    try std.testing.expectEqual(@as(u8, 3), panelOf(&a.sel));
    _ = pad(a, c.SDL_SCANCODE_5, false, false);
    try std.testing.expectEqual(@as(u8, 0), panelOf(&a.sel));
}

test "typing a search does not open a panel" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.beatoraja_select = true;
    a.scene = .select;
    key(a, c.SDL_SCANCODE_F6);
    try std.testing.expect(!pad(a, a.cfg.start_select[0], true, false));
    try std.testing.expectEqual(@as(u8, 0), panelOf(&a.sel));
}

test "the sort key reorders the open folder" {
    const a = try testing.open();
    defer testing.close(a);
    key(a, c.SDL_SCANCODE_RETURN);
    key(a, c.SDL_SCANCODE_RETURN);
    try expectRows(a, &.{ "Alpha", "Beta", "Gamma" });
    try a.db.exec("UPDATE song SET artist='z',max_bpm=300,length_ms=1 WHERE title='Alpha'");
    try a.db.exec("UPDATE song SET artist='y',max_bpm=100,length_ms=3 WHERE title='Beta'");
    try a.db.exec("UPDATE song SET artist='x',max_bpm=200,length_ms=2 WHERE title='Gamma'");
    try a.db.exec("INSERT INTO score(sha256,min_bp) VALUES('sha2',9),('sha3',4)");
    const orders = [_][3][]const u8{
        .{ "Gamma", "Beta", "Alpha" }, // artist
        .{ "Beta", "Gamma", "Alpha" }, // BPM
        .{ "Alpha", "Gamma", "Beta" }, // length
        .{ "Alpha", "Gamma", "Beta" }, // level
    };
    for (orders) |order| {
        key(a, c.SDL_SCANCODE_F4);
        try expectRows(a, &order);
    }
    key(a, c.SDL_SCANCODE_F4); // clear
    key(a, c.SDL_SCANCODE_F4); // EX
    key(a, c.SDL_SCANCODE_F4); // miss count: unplayed last
    try expectRows(a, &.{ "Gamma", "Beta", "Alpha" });
    key(a, c.SDL_SCANCODE_F4);
    try std.testing.expectEqual(@as(u8, 0), a.sel.sort);
}

test "typing a search takes the keys until it ends" {
    const a = try testing.open();
    defer testing.close(a);
    key(a, c.SDL_SCANCODE_F6);
    try std.testing.expect(a.sel.searching);
    try a.text.appendSlice(a.gpa, "a\u{D55C}");
    key(a, c.SDL_SCANCODE_BACKSPACE);
    try std.testing.expectEqualStrings("a", a.text.items);
    key(a, c.SDL_SCANCODE_F1);
    try std.testing.expectEqual(@as(u8, 0), a.cfg.random);
    key(a, c.SDL_SCANCODE_DOWN);
    try std.testing.expectEqual(@as(usize, 1), a.sel.cursor);
    key(a, c.SDL_SCANCODE_RETURN);
    try std.testing.expect(!a.sel.searching);
    try std.testing.expect(!a.text_active);
}

test "escape drops a search before it leaves the view" {
    const a = try testing.open();
    defer testing.close(a);
    a.sel.search = try a.gpa.dupe(u8, "elt");
    reload(a);
    try expectRows(a, &.{"Delta"});
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(a.running);
    try expectRows(a, &.{ "Library", "Favorites", "Table", "Courses" });
    key(a, c.SDL_SCANCODE_F6);
    a.gpa.free(a.sel.search);
    a.sel.search = try a.gpa.dupe(u8, "elt");
    reload(a);
    key(a, c.SDL_SCANCODE_ESCAPE);
    try std.testing.expect(!a.sel.searching);
    try expectRows(a, &.{ "Library", "Favorites", "Table", "Courses" });
}

test "a chart's ranking is asked for once the cursor rests, and only when signed in" {
    const a = try testing.open();
    defer testing.close(a);
    var song: db_mod.Song = undefined;
    song.sha256 = "aaa";
    const rows = [_]Row{.{ .label = "x", .song = song }};
    const kept = a.sel.rows;
    defer a.sel.rows = kept;
    a.sel.rows = @constCast(&rows);
    a.sel.cursor = 0;

    a.cfg.ir_url = "http://127.0.0.1:1";
    a.cfg.ir_token = "";
    tickBoard(a, 1000);
    tickBoard(a, 5000);
    try std.testing.expect(a.sel.board == null);

    a.cfg.ir_token = "tok";
    tickBoard(a, 5000);
    tickBoard(a, 5000 + board_delay_ms - 1);
    try std.testing.expect(a.sel.board == null);
    tickBoard(a, 5000 + board_delay_ms);
    const first = a.sel.board.?;
    try std.testing.expectEqual(first, a.select_state.ir_board.?);
    tickBoard(a, 9000);
    try std.testing.expectEqual(first, a.sel.board.?);

    while (!first.ready()) c.SDL_Delay(5);
    dropBoard(a);
    try std.testing.expect(a.select_state.ir_board == null);
}

test "the IR page key builds the chart's address and asks for a server first" {
    const url = try chartPageUrl(std.testing.allocator, "https://ir.actuon.app", "abc");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://ir.actuon.app/charts/abc", url);
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.ir_url = "";
    key(a, c.SDL_SCANCODE_7);
    try std.testing.expectEqualStrings("Set an IR server in settings first", a.sel.status);
}

test "the IR key asks for a server first" {
    const a = try testing.open();
    defer testing.close(a);
    a.cfg.ir_url = "";
    key(a, c.SDL_SCANCODE_F9);
    try std.testing.expectEqualStrings("Set an IR server in settings first", a.sel.status);
    try std.testing.expect(a.sel.query == null);
}
