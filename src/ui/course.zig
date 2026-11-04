const std = @import("std");
const tr = @import("i18n.zig").tr;
const c = @import("c");
const core = @import("actuon_core");
const app_mod = @import("app.zig");
const result = @import("result.zig");
const table = @import("../table/table.zig");
const session_mod = @import("../game/session.zig");
const App = app_mod.App;

pub const Run = struct {
    id: i64,
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    paths: [][]const u8,
    stage: usize = 0,
    limits: table.CourseLimits,
    gauge: core.gauge.Type,
    gauge_value: ?f32 = null,
    total: core.sim.Score = .{},
    notes: u32 = 0,
    random: core.options.Random,
    paused: bool = false,
};

pub fn addScore(total: *core.sim.Score, s: *const core.sim.Score) void {
    for (&total.counts, s.counts) |*d, v| {
        d[0] += v[0];
        d[1] += v[1];
    }
    total.max_combo = @max(total.max_combo, s.max_combo);
    total.passed += s.passed;
}

fn lookup(a: *App, al: std.mem.Allocator, hash: []const u8) !?[]const u8 {
    const st = try a.db.prepare(if (hash[0] == 'm') "SELECT path FROM song WHERE md5=?1 LIMIT 1" else "SELECT path FROM song WHERE sha256=?1 LIMIT 1");
    defer st.deinit();
    st.bindText(1, hash[2..]);
    return if (try st.step()) try al.dupe(u8, st.text(0)) else null;
}

pub fn start(a: *App, id: i64) void {
    startImpl(a, id) catch |e| {
        std.log.err("course: {t}", .{e});
        a.sel.status = tr("Could not start course");
    };
}

fn startImpl(a: *App, id: i64) !void {
    var arena = std.heap.ArenaAllocator.init(a.gpa);
    errdefer arena.deinit();
    const al = arena.allocator();
    const st = try a.db.prepare("SELECT name,hashes,constraints FROM course WHERE id=?1");
    defer st.deinit();
    st.bindInt(1, id);
    if (!try st.step()) return error.NoCourse;
    const name = try al.dupe(u8, st.text(0));
    const limits = table.parseConstraints(st.text(2));
    var paths: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, st.text(1), ',');
    while (it.next()) |h| {
        if (h.len < 3) continue;
        const p = (try lookup(a, al, h)) orelse {
            a.sel.status = tr("Course has charts missing from the library");
            arena.deinit();
            return;
        };
        try paths.append(al, p);
    }
    const chosen: core.options.Random = @fromBackingInt(a.cfg.random);
    const allowed: core.options.Random = switch (limits.random) {
        0 => .off,
        1 => if (chosen == .mirror) .mirror else .off,
        else => chosen,
    };
    a.course = .{
        .id = id,
        .arena = arena,
        .name = name,
        .paths = paths.items,
        .limits = limits,
        // Dan gauges follow the class gauge rule regardless of the selected one.
        .gauge = .class,
        .random = allowed,
    };
    launch(a);
}

fn launch(a: *App) void {
    const r = &a.course.?;
    a.startPlay(.{
        .path = r.paths[r.stage],
        .rec = .{ .gauge = r.gauge, .random = r.random, .seed = c.SDL_GetTicksNS() },
        .initial_gauge = r.gauge_value,
        .judge_offset_us = @as(i64, a.cfg.judge_offset_ms) * 1000,
    }, false);
}

pub fn stageDone(a: *App, s: *session_mod.Session, snap: session_mod.Snapshot, natural: bool) bool {
    const r = &a.course.?;
    addScore(&r.total, &snap.score);
    r.paused = r.paused or s.was_paused;
    r.notes += s.chart.total_notes;
    r.gauge_value = snap.gauge;
    const alive = natural and !snap.failed;
    const violated = (r.limits.no_good and snap.score.count(.gd) > 0) or (r.limits.no_great and snap.score.count(.gr) > 0);
    r.stage += 1;
    if (alive and !violated and r.stage < r.paths.len) return true;
    if (r.stage == r.paths.len and alive and !violated) r.stage = std.math.maxInt(usize);
    return false;
}

pub fn next(a: *App) void {
    launch(a);
}

/// Must run after capture(), whose single-stage result it overwrites.
pub fn finish(a: *App) void {
    var r = a.course.?;
    a.course = null;
    defer r.arena.deinit();
    const passed = r.stage == std.math.maxInt(usize);
    const res = &a.res;
    res.clear = if (passed) .normal else .failed;
    res.snap.score = r.total;
    res.notes = r.notes;
    res.recorded = false;
    res.save_failed = false;
    res.prev_ex = 0;
    res.prev_clear = 0;
    const n = @min(r.name.len, res.title_buf.len);
    @memcpy(res.title_buf[0..n], r.name[0..n]);
    res.title = res.title_buf[0..n];
    res.paused = r.paused;
    if (r.paused) return;
    save(a, r.id, r.total.exScore()) catch |e| {
        std.log.err("course save failed: {t}", .{e});
        res.save_failed = true;
        return;
    };
    res.recorded = true;
}

fn save(a: *App, id: i64, ex: u32) !void {
    const res = &a.res;
    {
        const look = try a.db.prepare("SELECT ex, clear FROM course_score WHERE course_id=?1");
        defer look.deinit();
        look.bindInt(1, id);
        if (try look.step()) {
            res.prev_ex = @intCast(look.int(0));
            res.prev_clear = @intCast(look.int(1));
        }
    }
    const st = try a.db.prepare(
        \\INSERT INTO course_score(course_id,clear,ex) VALUES(?1,?2,?3)
        \\ON CONFLICT(course_id) DO UPDATE SET clear=MAX(clear,excluded.clear), ex=MAX(ex,excluded.ex)
    );
    defer st.deinit();
    st.bindInt(1, id);
    st.bindInt(2, @backingInt(res.clear));
    st.bindInt(3, ex);
    _ = try st.step();
}

test "stage scores add up" {
    var total: core.sim.Score = .{};
    var one: core.sim.Score = .{};
    one.counts[0] = .{ 3, 2 };
    one.max_combo = 5;
    one.passed = 5;
    addScore(&total, &one);
    addScore(&total, &one);
    try std.testing.expectEqual(@as(u32, 10), total.count(.pg));
    try std.testing.expectEqual(@as(u32, 5), total.max_combo);
    try std.testing.expectEqual(@as(u32, 10), total.passed);
}
