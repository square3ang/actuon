//! Reads only session snapshots.
const std = @import("std");
const bga = @import("bga.zig");
const core = @import("actuon_core");
const gfx = @import("gfx.zig");
const i18n = @import("i18n.zig");
const tr = i18n.tr;
const session_mod = @import("../game/session.zig");
const config = @import("../game/config.zig");
const Session = session_mod.Session;
const Note = core.types.Note;

pub const judge_names = [_][]const u8{ "PGREAT", "GREAT", "GOOD", "BAD", "POOR", "POOR" };
pub const judge_colors = [_]gfx.Color{
    gfx.sky,
    .{ .r = 96, .g = 150, .b = 250 },
    .{ .r = 120, .g = 138, .b = 176 },
    gfx.amber,
    gfx.danger,
    .{ .r = 150, .g = 60, .b = 56 },
};

/// Fractions of the max EX, 0 for the player's own best.
pub const pace_targets = [_]struct { label: []const u8, ninths: u32 }{
    .{ .label = "MY BEST", .ninths = 0 },
    .{ .label = "MAX", .ninths = 9 },
    .{ .label = "AAA", .ninths = 8 },
    .{ .label = "AA", .ninths = 7 },
    .{ .label = "A", .ninths = 6 },
};

pub fn paceTargetName(target: u8) []const u8 {
    return switch (target) {
        1 => tr("Target: MAX"),
        2 => tr("Target: AAA"),
        3 => tr("Target: AA"),
        4 => tr("Target: A"),
        else => tr("Target: my best"),
    };
}

/// Rounded up, as ranks are.
pub fn targetEx(target: u8, best_ex: u32, total_notes: u32) u32 {
    const ninths = pace_targets[@min(target, pace_targets.len - 1)].ninths;
    if (ninths == 0) return best_ex;
    return (total_notes * 2 * ninths + 8) / 9;
}

/// A chart's best says nothing about a section of it, so practice paces against the MAX instead.
pub fn paceTarget(target: u8, practice: bool) u8 {
    return if (practice and pace_targets[@min(target, pace_targets.len - 1)].ninths == 0) 1 else target;
}

pub fn paceDiff(ex: u32, target_ex: u32, judged: u32, total_notes: u32) i64 {
    if (total_notes == 0) return ex;
    return @as(i64, ex) - @divTrunc(@as(i64, target_ex) * @min(judged, total_notes), total_notes);
}

pub fn referenceBpm(chart: *const core.types.Chart, hs_fix: u8) f64 {
    return switch (hs_fix) {
        0 => chart.bpm,
        1 => chart.max_bpm,
        2 => mainBpm(chart),
        4 => chart.min_bpm,
        else => 150,
    };
}

pub const Scroll = struct {
    t: i64,
    now_y: f64,
    /// Lane shares per y unit.
    per_y: f64,
    /// Under the CONSTANT assist, lane shares per microsecond instead: time alone moves the notes.
    per_us: ?f64,
    /// beatoraja's CONSTANT option: nothing shows earlier than this before its time.
    appear_us: ?i64,

    /// A share of the open lane above the judge line.
    pub fn share(sc: Scroll, at_us: i64, at_y: f64) f32 {
        if (sc.per_us) |k| return @floatCast(@as(f64, @floatFromInt(at_us - sc.t)) * k);
        return @floatCast((at_y - sc.now_y) * sc.per_y);
    }

    pub fn hidden(sc: Scroll, at_us: i64) bool {
        return if (sc.appear_us) |ahead| at_us - sc.t > ahead else false;
    }
};

/// `aids` are the play's own: a versus round or a course plays without them whatever the settings say.
pub fn scrollAt(v: *View, chart: *const core.types.Chart, cfg: *const config.Config, aids: config.Assists, t: i64) Scroll {
    const green_us: f64 = @as(f64, @floatFromInt(cfg.green_ms)) * 1000;
    return .{
        .t = t,
        .now_y = chart.yAt(t),
        .per_y = chart.speedAt(t) / visibleY(cfg.green_ms, v.refBpm(chart, cfg.hs_fix)),
        .per_us = if (aids.constant) 1 / green_us else null,
        .appear_us = if (cfg.constant) @as(i64, cfg.green_ms) * 1000 else null,
    };
}

/// beatoraja's JUDGE AREA assist: how far either side of the line a press still scores GOOD, as a share of the open lane.
pub fn judgeAreaShare(chart: *const core.types.Chart, sc: Scroll) [2]f32 {
    const w = core.windows.create(5, core.windows.note_base, chart.judgerank)[2];
    const lo = sc.t + w[0];
    const hi = sc.t + w[1];
    return .{ sc.share(lo, chart.yAt(lo)), sc.share(hi, chart.yAt(hi)) };
}

pub fn bpmChanges(chart: *const core.types.Chart, i: usize) bool {
    return i > 0 and chart.timelines[i].bpm != chart.timelines[i - 1].bpm;
}

pub fn mainBpm(chart: *const core.types.Chart) f64 {
    const gpa = std.heap.smp_allocator;
    // Keyed by bit pattern, as floats do not hash; insertion order keeps the first tempo heard on a tie.
    var totals: std.array_hash_map.Auto(u64, i64) = .empty;
    defer totals.deinit(gpa);
    const tl = chart.timelines;
    for (tl, 0..) |t, j| {
        const slot = totals.getOrPut(gpa, @bitCast(t.bpm)) catch |e| {
            std.log.err("main BPM: {t}, using the chart's", .{e});
            return chart.bpm;
        };
        if (!slot.found_existing) slot.value_ptr.* = 0;
        const end = if (j + 1 < tl.len) tl[j + 1].time_us else chart.last_time_us;
        slot.value_ptr.* += @max(end - t.time_us - t.stop_us, 0);
    }
    if (totals.count() == 0) return chart.bpm;
    return @bitCast(totals.keys()[std.mem.indexOfMax(i64, totals.values())]);
}

pub fn visibleY(green_ms: u32, ref_bpm: f64) f64 {
    return @as(f64, @floatFromInt(green_ms)) / 1000.0 * ref_bpm / 240.0;
}

/// A long note stays until its end has passed, which on a slow section can outlast the margin.
pub fn skipPastNotes(chart: *const core.types.Chart, first: usize, t: i64) usize {
    var i = first;
    while (i < chart.notes.len) : (i += 1) {
        const n = chart.notes[i];
        const end = if (n.kind == .ln_start and n.pair >= 0) chart.notes[@intCast(n.pair)].time_us else n.time_us;
        if (end >= t - 2_000_000) break;
    }
    return i;
}

pub fn laneOrder(mode: core.types.Mode, scratch_right: bool, out: *[core.types.max_lanes]u8) u8 {
    const n = mode.keys();
    switch (mode) {
        .beat5 => out[0..6].* = .{ 5, 0, 1, 2, 3, 4 },
        .beat7 => out[0..8].* = .{ 7, 0, 1, 2, 3, 4, 5, 6 },
        .beat10 => out[0..12].* = .{ 5, 0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11 },
        .beat14 => out[0..16].* = .{ 7, 0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15 },
        .popn9 => out[0..9].* = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8 },
        .beat4 => out[0..4].* = .{ 0, 1, 2, 3 },
        .beat6 => out[0..6].* = .{ 0, 1, 2, 3, 4, 5 },
    }
    // Double play keeps each side's scratch on its outer edge.
    if (scratch_right and (mode == .beat5 or mode == .beat7)) std.mem.rotate(u8, out[0..n], 1);
    return n;
}

pub const View = struct {
    render_state: []u8,
    first_note: usize = 0,
    last_t: i64 = std.math.minInt(i64),
    bga: ?*bga.Bga = null,
    scratch_right: bool = false,
    best_ex: u32 = 0,
    target_ex: u32 = 0,
    /// The target is another player's score right now, not a final one to pace against.
    target_live: bool = false,
    target_label: []const u8 = "",
    /// referenceBpm is too slow to run per frame on a chart with many tempo changes.
    ref_bpm: f64 = 0,
    ref_hs_fix: u8 = 255,
    density: [64]u16 = @splat(0),
    density_max: u16 = 0,
    timing: [24]i32 = @splat(0),
    timing_n: u32 = 0,
    timing_at: i64 = -1,

    pub fn refBpm(v: *View, chart: *const core.types.Chart, hs_fix: u8) f64 {
        if (v.ref_hs_fix != hs_fix) {
            v.ref_hs_fix = hs_fix;
            v.ref_bpm = referenceBpm(chart, hs_fix);
        }
        return v.ref_bpm;
    }

    pub fn draw(v: *View, g: *gfx.Gfx, s: *Session, cfg: *const config.Config) session_mod.Snapshot {
        const snap = s.snapshotInto(v.render_state);
        const chart = &s.chart;
        const mode = chart.mode;
        const t = snap.time_us - @as(i64, cfg.visual_offset_ms) * 1000;
        if (t < v.last_t) v.first_note = 0;
        v.last_t = t;
        const u = g.h / 720;
        if (v.density_max == 0) fillDensity(v, chart);
        if (snap.last_judge < 4 and snap.judge_at_us != v.timing_at) {
            v.timing_at = snap.judge_at_us;
            v.timing[v.timing_n % v.timing.len] = snap.last_fast_us;
            v.timing_n += 1;
        }

        const l = layoutLanes(g, mode, cfg, v.scratch_right);
        drawGear(g, &l, s, &snap);
        const aids = s.params.assist.picked;
        const sc = scrollAt(v, chart, cfg, aids, t);
        if (aids.judge_area) {
            const area = judgeAreaShare(chart, sc);
            const y0 = l.judge_y - area[1] * l.lane_h;
            g.rect(l.left, y0, l.w, l.judge_y - area[0] * l.lane_h - y0, gfx.cyan.alpha(40));
        }
        drawBarLines(g, &l, chart, sc, aids.bpm_guide);
        drawNotes(g, v, &l, chart, &snap, sc, aids.mark_note);
        drawCovers(g, &l, cfg);
        drawJudgeLine(g, &l);
        drawController(g, &l, &snap, t);
        drawGaugeInfo(g, &l, &snap, cfg, t);
        drawJudgePop(g, &l, &snap, t);

        const panel_x = l.right + l.rail + 14 * u;
        drawDeck(g, v, s, &snap, t, panel_x, g.w - 12 * u - panel_x);
        return snap;
    }
};

const Lanes = struct {
    mode: core.types.Mode,
    order: [core.types.max_lanes]u8 = undefined,
    n: usize,
    xs: [core.types.max_lanes]f32 = undefined,
    ws: [core.types.max_lanes]f32 = undefined,
    two_sides: bool,
    gap_w: f32,
    rail: f32,
    left: f32,
    right: f32 = 0,
    w: f32 = 0,
    base_y: f32,
    lift_px: f32,
    judge_y: f32,
    cover_px: f32,
    lane_h: f32,
    pad_y: f32,
    pad_h: f32,
};

const top_y: f32 = 0;

/// Fewer lanes get wider ones, so a 4 key gear is not a sliver beside the deck.
fn keyWidth(mode: core.types.Mode) f32 {
    return if (mode == .beat4) 92 else 42;
}

/// With no turntable, 4 keys sit flat under the fingers, not staggered like a beat controller.
fn flatKeys(mode: core.types.Mode) bool {
    return mode == .beat4;
}

fn layoutLanes(g: *gfx.Gfx, mode: core.types.Mode, cfg: *const config.Config, scratch_right: bool) Lanes {
    const u = g.h / 720;
    const key_w = keyWidth(mode) * u;
    const sc_w: f32 = 72 * u;
    const base_y = g.h * 0.765;
    const lift_px = base_y * cfg.liftShown();
    var l: Lanes = .{
        .mode = mode,
        .n = 0,
        .two_sides = mode.players() == 2,
        .gap_w = 14 * u,
        .rail = 7 * u,
        .left = 14 * u + 7 * u,
        .base_y = base_y,
        .lift_px = lift_px,
        .judge_y = base_y - lift_px,
        .cover_px = (base_y - top_y) * cfg.coverShown(),
        .lane_h = (base_y - top_y) * cfg.openLane(),
        .pad_y = base_y + 4 * u,
        .pad_h = 92 * u,
    };
    l.n = laneOrder(mode, scratch_right, &l.order);
    var x = l.left;
    for (l.order[0..l.n], 0..) |lane, i| {
        const sc = mode.scratchOf(lane) >= 0;
        l.ws[lane] = if (sc) sc_w else key_w;
        if (l.two_sides and i == l.n / 2) x += l.gap_w;
        l.xs[lane] = x;
        x += l.ws[lane];
    }
    l.right = x;
    l.w = x - l.left;
    return l;
}

fn drawGear(g: *gfx.Gfx, l: *const Lanes, s: *Session, snap: *const session_mod.Snapshot) void {
    g.hgrad(l.left - l.rail, 0, l.rail, g.h, gfx.steel, gfx.rule);
    g.hgrad(l.right, 0, l.rail, g.h, gfx.rule, gfx.steel);
    g.vgrad(l.left, 0, l.w, l.base_y, gfx.well, .{ .r = 12, .g = 26, .b = 62 });
    for (l.order[0..l.n]) |lane| {
        if (noteColor(l.mode, lane).r < 200) g.vgrad(l.xs[lane], 0, l.ws[lane], l.base_y, gfx.white.alpha(3), gfx.white.alpha(16));
        g.rect(l.xs[lane], 0, 1, l.base_y, gfx.white.alpha(26));
    }
    g.additive(true);
    for (l.order[0..l.n]) |lane| {
        const since = snap.time_us - snap.flash_at_us[lane];
        // Lit exactly while pressed. Autoplay has no held state, only the moment of each hit.
        const auto_hit = s.params.autoplay and since >= 0 and since < 60_000;
        if (snap.held[lane] or auto_hit) {
            const col = noteColor(l.mode, lane);
            g.vgrad(l.xs[lane], l.judge_y * 0.25, l.ws[lane], l.judge_y * 0.75, col.alpha(0), col.alpha(200));
        }
    }
    g.additive(false);
}

fn drawBarLines(g: *gfx.Gfx, l: *const Lanes, chart: *const core.types.Chart, sc: Scroll, bpm_guide: bool) void {
    const u = g.h / 720;
    for (chart.timelines, 0..) |tl, i| {
        const guide = bpm_guide and bpmChanges(chart, i);
        if (!tl.bar and !guide) continue;
        if (tl.time_us < sc.t or sc.hidden(tl.time_us)) continue;
        const yy = l.judge_y - sc.share(tl.time_us, tl.y) * l.lane_h;
        if (yy < top_y) break;
        if (guide) {
            g.rect(l.left, yy, l.w, 2, gfx.amber);
            g.fmt(l.left + 4 * u, yy - 16 * u, g.scaled(12), gfx.amber, "{d:.0}", .{tl.bpm});
        } else g.rect(l.left, yy, l.w, 2, gfx.white.alpha(70));
    }
}

fn drawNotes(g: *gfx.Gfx, v: *View, l: *const Lanes, chart: *const core.types.Chart, snap: *const session_mod.Snapshot, sc: Scroll, mark: bool) void {
    const u = g.h / 720;
    const t = sc.t;
    v.first_note = skipPastNotes(chart, v.first_note, t);
    const nh: f32 = 11 * u;
    for (chart.notes[v.first_note..], v.first_note..) |note, i| {
        const yy = l.judge_y - sc.share(note.time_us, note.y) * l.lane_h;
        if (yy < top_y - nh and note.kind != .ln_start) {
            // Notes are time ordered and y grows with time except under negative #SCROLL.
            if (note.time_us > t + 60_000_000) break;
            continue;
        }
        if (sc.hidden(note.time_us)) continue;
        const lane = note.lane;
        const col = noteColor(l.mode, lane);
        switch (note.kind) {
            .normal => if (v.render_state[i] == 0) {
                drawNote(g, l.xs[lane], yy - nh, l.ws[lane], nh, col);
            } else if (mark and yy < l.judge_y) g.rect(l.xs[lane] + 1, yy - nh, l.ws[lane] - 1, nh, col.alpha(70)),
            .mine => if (v.render_state[i] == 0) {
                g.rect(l.xs[lane] + 1, yy - nh * 0.7, l.ws[lane] - 1, nh * 0.5, gfx.danger);
            },
            .ln_start => {
                if (note.pair < 0) continue;
                const pair: usize = @intCast(note.pair);
                if (v.render_state[pair] != 0) continue;
                const started = v.render_state[i] != 0;
                const held = snap.holding[lane] == note.pair;
                if (started and !held and note.ln_type == .ln) continue;
                const end = chart.notes[pair];
                const end_y = l.judge_y - sc.share(end.time_us, end.y) * l.lane_h;
                const y0 = if (held) l.judge_y else yy;
                if (end_y < g.h and y0 > top_y) {
                    const glow: u8 = if (held) 150 + @as(u8, @intFromFloat(@abs(@sin(@as(f32, @floatFromInt(t)) / 60_000)) * 90)) else 110;
                    g.rect(l.xs[lane] + 5 * u, end_y, l.ws[lane] - 10 * u, y0 - end_y, col.alpha(glow));
                }
                if (!started and !held) drawNote(g, l.xs[lane], yy - nh, l.ws[lane], nh, col);
                // Only CN and HCN judge the release, so only they get a note to aim the release at.
                if (note.ln_type != .ln) drawNote(g, l.xs[lane], end_y - nh, l.ws[lane], nh, col);
            },
            .ln_end => {},
        }
    }
}

fn drawCovers(g: *gfx.Gfx, l: *const Lanes, cfg: *const config.Config) void {
    const u = g.h / 720;
    const hidden_px = l.base_y * cfg.hiddenShown();
    if (hidden_px > 0) g.rect(l.left, @max(l.judge_y - hidden_px, l.cover_px), l.w, @min(hidden_px, l.judge_y - l.cover_px), gfx.plate);
    if (l.lift_px > 0) g.rect(l.left, l.judge_y, l.w, l.lift_px, gfx.plate);
    if (l.cover_px > 0) {
        g.vgrad(l.left, 0, l.w, l.cover_px, gfx.plate, .{ .r = 26, .g = 38, .b = 66 });
        g.rect(l.left, l.cover_px - 2 * u, l.w, 2 * u, gfx.cyan);
    }
}

fn drawJudgeLine(g: *gfx.Gfx, l: *const Lanes) void {
    const u = g.h / 720;
    g.additive(true);
    g.vgrad(l.left, l.judge_y - 30 * u, l.w, 30 * u, gfx.cyan.alpha(0), gfx.cyan.alpha(90));
    g.additive(false);
    g.rect(l.left, l.judge_y - 2 * u, l.w, 4 * u, gfx.white);
}

fn drawController(g: *gfx.Gfx, l: *const Lanes, snap: *const session_mod.Snapshot, t: i64) void {
    const u = g.h / 720;
    g.rect(l.left, l.pad_y, l.w, l.pad_h, gfx.plate);
    for (l.order[0..l.n]) |lane| {
        if (l.mode.scratchOf(lane) >= 0) {
            drawTurntable(g, l.xs[lane] + l.ws[lane] / 2, l.pad_y + l.pad_h / 2, @min(l.ws[lane], l.pad_h) / 2 - 3 * u, t, snap.held[lane]);
        } else if (flatKeys(l.mode)) {
            drawKey(g, l.xs[lane] + 3 * u, l.pad_y + 8 * u, l.ws[lane] - 6 * u, 76 * u, noteColor(l.mode, lane), snap.held[lane]);
        } else drawKey(g, l.xs[lane] + 3 * u, l.pad_y + (if (noteColor(l.mode, lane).r >= 200) 44 * u else 8 * u), l.ws[lane] - 6 * u, 40 * u, noteColor(l.mode, lane), snap.held[lane]);
    }
    if (l.two_sides) g.rect(l.xs[l.order[l.n / 2]] - l.gap_w, 0, l.gap_w, l.pad_y + l.pad_h, gfx.bg);
    g.additive(true);
    for (l.order[0..l.n]) |lane| drawBomb(g, snap, lane, l.xs[lane] + l.ws[lane] / 2, l.judge_y, l.ws[lane]);
    g.additive(false);
}

fn drawGaugeInfo(g: *gfx.Gfx, l: *const Lanes, snap: *const session_mod.Snapshot, cfg: *const config.Config, t: i64) void {
    const u = g.h / 720;
    const info_y = l.pad_y + l.pad_h + 4 * u;
    drawGauge(g, l.left, info_y, l.w, 16 * u, snap.gauge, snap.gauge_border, @backingInt(snap.gauge_type) >= 3, t);
    var buf: [48]u8 = undefined;
    const info2 = info_y + 20 * u;
    _ = g.text(gauge_labels[@backingInt(snap.gauge_type)], l.left, info2, g.scaled(14), gfx.sky);
    g.textRight(std.fmt.bufPrint(&buf, "{d:.1}%", .{snap.gauge}) catch "", l.right, info2 - 2 * u, g.scaled(20), gfx.white);
    g.fmt(l.left + l.w * 0.36, info2 + 2 * u, g.scaled(12), gfx.dim, "GREEN {d}  C{d} L{d} H{d}", .{ cfg.green_ms * 3 / 5, @as(u32, @intFromFloat(cfg.lane_cover * 100)), @as(u32, @intFromFloat(@round(cfg.lift * 100))), @as(u32, @intFromFloat(@round(cfg.hidden * 100))) });
}

fn drawJudgePop(g: *gfx.Gfx, l: *const Lanes, snap: *const session_mod.Snapshot, t: i64) void {
    const u = g.h / 720;
    const cx = l.left + l.w / 2;
    if (snap.last_judge != 255 and snap.time_us - snap.judge_at_us < 600_000) {
        const age = snap.time_us - snap.judge_at_us;
        const pop: f32 = if (age < 80_000) 1.3 - 0.3 * @as(f32, @floatFromInt(age)) / 80_000 else 1;
        const j = snap.last_judge;
        const jy = l.judge_y * 0.62;
        const col = if (j == 0) (if (@mod(@divTrunc(t, 50_000), 2) == 0) gfx.white else gfx.cyan) else judge_colors[j];
        if (snap.score.combo > 0) {
            var cb: [16]u8 = undefined;
            g.textPop(std.fmt.bufPrint(&cb, "{d}", .{snap.score.combo}) catch "", cx, jy - 60 * u, g.scaled(48), gfx.white, pop);
        }
        g.textPop(judge_names[j], cx, jy, g.scaled(32), col, pop);
        if (j > 0 and j < 4) g.textPop(if (snap.last_fast_us > 0) "FAST" else "SLOW", cx, jy + 40 * u, g.scaled(14), if (snap.last_fast_us > 0) gfx.cyan else gfx.amber, 1);
    }
}

fn fillDensity(v: *View, chart: *const core.types.Chart) void {
    v.density_max = 1;
    if (chart.last_time_us <= 0) return;
    for (chart.notes) |note| {
        if (note.kind == .ln_end or note.kind == .mine) continue;
        const i: usize = @intCast(@min(@divTrunc(@max(note.time_us, 0) * @as(i64, v.density.len), chart.last_time_us), v.density.len - 1));
        v.density[i] += 1;
        v.density_max = @max(v.density_max, v.density[i]);
    }
}

fn drawNote(g: *gfx.Gfx, x: f32, y: f32, w: f32, h: f32, col: gfx.Color) void {
    g.rect(x + 1, y, w - 1, h, col);
}

fn drawBomb(g: *gfx.Gfx, snap: *const session_mod.Snapshot, lane: u8, cx: f32, y: f32, w: f32) void {
    const since = snap.time_us - snap.bomb_at_us[lane];
    const life = 240_000;
    if (since < 0 or since >= life) return;
    const p = @as(f32, @floatFromInt(since)) / life;
    const col = judge_colors[snap.bomb_judge[lane]];
    const a: u8 = @intFromFloat((1 - p) * 255);
    g.disc(cx, y, w * 0.45 * (1 - p), gfx.white.alpha(a));
    g.vgrad(cx - w / 2, y - w * 2.4 * (1 - p * 0.5), w, w * 2.4 * (1 - p * 0.5), col.alpha(0), col.alpha(a / 2));
    for (0..6) |i| {
        const ang = @as(f32, @floatFromInt(i)) * std.math.pi / 5 + std.math.pi;
        const r0 = w * (0.3 + p * 1.3);
        const r1 = r0 + w * 0.35 * (1 - p);
        g.line(cx + @cos(ang) * r0, y + @sin(ang) * r0, cx + @cos(ang) * r1, y + @sin(ang) * r1, gfx.white.alpha(a));
    }
}

fn drawTurntable(g: *gfx.Gfx, cx: f32, cy: f32, r: f32, t: i64, held: bool) void {
    const ang = @as(f32, @floatFromInt(@mod(t, 1_800_000))) / 1_800_000 * std.math.tau;
    g.disc(cx, cy, r, .{ .r = 8, .g = 10, .b = 18 });
    g.ring(cx, cy, r, 2, 0, std.math.tau, if (held) scratch_lit else scratch_red);
    g.ring(cx, cy, r * 0.82, 1, 0, std.math.tau, gfx.white.alpha(40));
    g.ring(cx, cy, r * 0.66, 1, 0, std.math.tau, gfx.white.alpha(30));
    for (0..3) |i| {
        const a = ang + @as(f32, @floatFromInt(i)) * std.math.tau / 3;
        g.ring(cx, cy, r * 0.92, 3, a, a + 0.5, if (held) scratch_lit else scratch_red);
    }
    g.disc(cx, cy, r * 0.3, if (held) scratch_lit else scratch_red);
    g.disc(cx, cy, r * 0.08, gfx.white);
}

fn drawKey(g: *gfx.Gfx, x: f32, y: f32, w: f32, h: f32, col: gfx.Color, held: bool) void {
    g.round(x, y, w, h, 4 * g.h / 720, if (held) col else gfx.mix(col, gfx.well, 0.72));
}

const scratch_red: gfx.Color = .{ .r = 235, .g = 48, .b = 62 };
const scratch_lit: gfx.Color = .{ .r = 255, .g = 112, .b = 118 };

fn noteColor(mode: core.types.Mode, lane: u8) gfx.Color {
    const blue: gfx.Color = .{ .r = 72, .g = 156, .b = 255 };
    const white: gfx.Color = .{ .r = 240, .g = 244, .b = 250 };
    if (mode.scratchOf(lane) >= 0) return scratch_red;
    // Mirrored, so both hands read the same colors.
    if (flatKeys(mode)) {
        const mid = mode.keys() / 2;
        const from_edge = if (lane < mid) lane else mode.keys() - 1 - lane;
        return if (from_edge % 2 == 0) white else blue;
    }
    if (mode == .popn9) return switch (lane) {
        0, 8 => white,
        1, 7 => gfx.amber,
        2, 6 => .{ .r = 110, .g = 220, .b = 170 },
        3, 5 => blue,
        else => gfx.danger,
    };
    const idx = if (lane >= 8) lane - 8 else if (mode == .beat10 and lane >= 6) lane - 6 else lane;
    return if (idx % 2 == 0) white else blue;
}

const gauge_labels = [_][]const u8{ "ASSIST EASY", "EASY", "NORMAL", "HARD", "EX HARD", "HAZARD", "CLASS", "EX CLASS", "EX HARD CLASS" };

fn drawGauge(g: *gfx.Gfx, x: f32, y: f32, w: f32, h: f32, value: f32, border: f32, hard: bool, t: i64) void {
    const segs = 50;
    const gap: f32 = 1;
    const seg_w = (w - gap * (segs - 1)) / segs;
    const filled: usize = @intFromFloat(@max(value, 0) / 2);
    g.rect(x, y, w, h, gfx.well);
    const flick = @mod(@divTrunc(t, 40_000), 3) == 0;
    for (0..segs) |i| {
        const pct: f32 = @floatFromInt(i * 2);
        const col = if (hard) gfx.danger else if (pct >= border) gfx.cyan else gfx.accent;
        const fx = x + @as(f32, @floatFromInt(i)) * (seg_w + gap);
        if (i < filled) {
            const dimmed = flick and i + 3 >= filled;
            g.vgrad(fx, y, seg_w, h, gfx.mix(col, gfx.white, if (dimmed) 0.1 else 0.45), col.alpha(if (dimmed) 120 else 255));
        } else g.rect(fx, y, seg_w, h, col.alpha(30));
    }
}

fn drawScoreGraph(g: *gfx.Gfx, ex: u32, passed: u32, best: u32, notes: u32, x: f32, y: f32, w: f32, h: f32) void {
    const u = g.h / 720;
    g.panel(x, y, w, h, "SCORE GRAPH");
    const top = y + 22 * u;
    const bot = y + h - 8 * u;
    const gh = bot - top;
    const lx = x + 34 * u;
    const gw = w - 44 * u;
    const max: f32 = @floatFromInt(@max(notes * 2, 1));
    const marks = [_]struct { f32, []const u8 }{ .{ 8.0 / 9.0, "AAA" }, .{ 7.0 / 9.0, "" }, .{ 6.0 / 9.0, "A" } };
    for (marks) |m| {
        const my = bot - gh * m[0];
        g.rect(lx, my, gw, 1, gfx.white.alpha(50));
        if (m[1].len > 0) g.textRight(m[1], lx - 4 * u, my - 8 * u, g.scaled(12), gfx.dim);
    }
    const bw = gw / 2 - 6 * u;
    const vals = [_]struct { f32, gfx.Color }{ .{ @as(f32, @floatFromInt(ex)) / max, gfx.cyan }, .{ @as(f32, @floatFromInt(best)) / max, gfx.steel } };
    for (vals, 0..) |val, i| {
        const bh = gh * @min(val[0], 1);
        const bx = lx + 3 * u + @as(f32, @floatFromInt(i)) * (bw + 6 * u);
        g.rect(bx, top, bw, gh, gfx.white.alpha(6));
        g.vgrad(bx, bot - bh, bw, bh, gfx.mix(val[1], gfx.white, 0.3), gfx.mix(val[1], gfx.well, 0.5));
    }
    // Pace: where a max score would stand by now.
    const pace = bot - gh * @min(@as(f32, @floatFromInt(passed * 2)) / max, 1);
    g.rect(lx, pace, gw, 2, gfx.amber);
}

fn drawTitleBar(g: *gfx.Gfx, s: *Session, snap: *const session_mod.Snapshot, x: f32, w: f32, bar_h: f32, frac: f32) void {
    const chart = &s.chart;
    const u = g.h / 720;
    var buf: [64]u8 = undefined;
    g.panel(x, 8 * u, w, bar_h, "");
    const now_s: u64 = @intCast(@divTrunc(@max(snap.time_us, 0), 1_000_000));
    const total_s: u64 = @intCast(@divTrunc(@max(chart.last_time_us, 0), 1_000_000));
    const time_txt = std.fmt.bufPrint(&buf, "{d}:{d:0>2} / {d}:{d:0>2}", .{ now_s / 60, now_s % 60, total_s / 60, total_s % 60 }) catch "";
    _ = g.text(time_txt, x + 14 * u, 16 * u, g.scaled(16), gfx.cyan);
    const lead = 130 * u;
    const lvl_w = 70 * u;
    g.textClip(chart.title, x + lead, 13 * u, w - lead - lvl_w - 10 * u, g.scaled(20), gfx.white);
    var lv: [80]u8 = undefined;
    g.textRight(std.fmt.bufPrint(&lv, "LV {s}", .{if (s.params.table_level.len > 0) s.params.table_level else chart.playlevel}) catch "", x + w - 14 * u, 16 * u, g.scaled(16), gfx.sky);
    g.rect(x + 8 * u, 8 * u + bar_h - 3 * u, w - 16 * u, 2 * u, gfx.white.alpha(30));
    g.hgrad(x + 8 * u, 8 * u + bar_h - 3 * u, (w - 16 * u) * frac, 2 * u, gfx.accent, gfx.cyan);
}

fn drawStage(g: *gfx.Gfx, v: *View, s: *Session, snap: *const session_mod.Snapshot, t: i64, x: f32, w: f32, stage_y: f32, stage_h: f32) void {
    const chart = &s.chart;
    const u = g.h / 720;
    g.panel(x, stage_y, w, stage_h, "");
    const inner = stage_h - 8 * u;
    const by = stage_y + 4 * u;
    if (v.bga) |b| {
        const size = @min(inner, w - 8 * u);
        b.draw(chart, t, snap.last_judge, snap.judge_at_us, .{ .x = x + (w - size) / 2, .y = by + (inner - size) / 2, .w = size, .h = size }, .{});
    } else {
        g.textCentered(chart.title, x + w / 2, by + inner / 2 - 40 * u, g.scaled(48), gfx.white);
        g.textCentered(chart.artist, x + w / 2, by + inner / 2 + 26 * u, g.scaled(16), gfx.dim);
    }
}

fn drawReadouts(g: *gfx.Gfx, chart: *const core.types.Chart, snap: *const session_mod.Snapshot, x: f32, w: f32, read_y: f32, read_h: f32, gap: f32) void {
    const u = g.h / 720;
    const sc = &snap.score;
    const cw = (w - gap * 2) / 3;
    // Double play leaves a narrow deck.
    const wide = cw >= 220 * u;
    const num = g.scaled(if (wide) 48 else 32);
    const num_y = read_y + (if (wide) 8 * u else 22 * u);
    g.panel(x, read_y, cw, read_h, "EX SCORE");
    const ex = sc.exScore();
    g.digits(x + cw - 12 * u, num_y, num, 5, ex, gfx.white);
    const bx2 = x + cw + gap;
    g.panel(bx2, read_y, cw, read_h, "BPM");
    if (wide) {
        g.fmt(bx2 + 10 * u, read_y + 22 * u, g.scaled(12), gfx.dim, "MIN {d:.0}", .{chart.min_bpm});
        g.fmt(bx2 + 10 * u, read_y + 44 * u, g.scaled(12), gfx.dim, "MAX {d:.0}", .{chart.max_bpm});
    }
    g.digits(bx2 + cw - 12 * u, num_y, num, 3, @intFromFloat(@max(chart.bpmAt(snap.time_us), 0)), gfx.cyan);
    const bx3 = bx2 + cw + gap;
    g.panel(bx3, read_y, cw, read_h, "MAX COMBO");
    g.digits(bx3 + cw - 12 * u, num_y, num, 4, sc.max_combo, gfx.white);
}

fn drawNotesGraph(g: *gfx.Gfx, v: *View, nx: f32, graph_y: f32, b_w: f32, graph_h: f32, frac: f32) void {
    const u = g.h / 720;
    g.panel(nx, graph_y, b_w, graph_h, "NOTES GRAPH");
    const gx = nx + 8 * u;
    const gw = b_w - 16 * u;
    const gtop = graph_y + 20 * u;
    const gbot = graph_y + graph_h - 30 * u;
    const bw = gw / @as(f32, @floatFromInt(v.density.len));
    for (v.density, 0..) |d, i| {
        const ratio = @as(f32, @floatFromInt(d)) / @as(f32, @floatFromInt(@max(v.density_max, 1)));
        const px = gx + @as(f32, @floatFromInt(i)) * bw;
        const bh = (gbot - gtop) * ratio;
        const done = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(v.density.len)) <= frac;
        g.vgrad(px, gbot - bh, @max(bw - 1, 1), bh, if (done) gfx.cyan else gfx.steel, if (done) gfx.accent else gfx.rule);
    }
    g.rect(gx + gw * frac, gtop, 2, gbot - gtop, gfx.white);
    const my = gbot + 6 * u;
    const mh = 18 * u;
    const mcx = gx + gw / 2;
    g.rect(gx, my, gw, mh, gfx.well);
    g.rect(mcx - 1, my, 2, mh, gfx.white);
    const shown = @min(v.timing_n, v.timing.len);
    for (0..shown) |i| {
        const idx = (v.timing_n - 1 - i) % v.timing.len;
        const off = std.math.clamp(@as(f32, @floatFromInt(v.timing[idx])) / 120_000, -1, 1);
        const a: u8 = @intCast(240 - i * 9);
        g.rect(mcx - off * gw / 2 - 1, my + 2, 2, mh - 4, (if (off > 0) gfx.cyan else gfx.amber).alpha(a));
    }
}

fn drawJudgeCounts(g: *gfx.Gfx, snap: *const session_mod.Snapshot, jx: f32, graph_y: f32, c_w: f32, graph_h: f32) void {
    const u = g.h / 720;
    const sc = &snap.score;
    var buf: [64]u8 = undefined;
    g.panel(jx, graph_y, c_w, graph_h, "JUDGE");
    var early: u32 = 0;
    var late: u32 = 0;
    const rows = [_][]const u8{ "PG", "GR", "GD", "BD", "PR" };
    for (rows, 0..) |name, i| {
        const cnt = sc.counts[i];
        const extra: u32 = if (i == 4) sc.counts[5][0] + sc.counts[5][1] else 0;
        if (i > 0 and i < 4) {
            early += cnt[0];
            late += cnt[1];
        }
        const ry = graph_y + 18 * u + @as(f32, @floatFromInt(i)) * 15 * u;
        _ = g.text(name, jx + 10 * u, ry, g.scaled(12), judge_colors[i]);
        g.textRight(std.fmt.bufPrint(&buf, "{d}", .{cnt[0] + cnt[1] + extra}) catch "", jx + c_w - 10 * u, ry, g.scaled(12), gfx.white);
    }
    g.fmt(jx + 10 * u, graph_y + graph_h - 16 * u, g.scaled(12), gfx.cyan, "F {d}", .{early});
    g.textRight(std.fmt.bufPrint(&buf, "S {d}", .{late}) catch "", jx + c_w - 10 * u, graph_y + graph_h - 16 * u, g.scaled(12), gfx.amber);
}

fn drawTag(g: *gfx.Gfx, s: *Session, x: f32, w: f32, stage_y: f32) void {
    const u = g.h / 720;
    var buf: [64]u8 = undefined;
    if (s.params.autoplay or s.params.replay != null or s.load_warnings > 0) {
        const tag = if (s.load_warnings > 0)
            i18n.bufPrint(&buf, "{d} SOUNDS MISSING", .{s.load_warnings}) catch ""
        else if (s.params.autoplay) tr("AUTOPLAY") else tr("REPLAY");
        const tw = g.measure(tag, g.scaled(12)) + 18 * u;
        g.round(x + w - tw - 8 * u, stage_y + 8 * u, tw, 18 * u, 4 * u, gfx.accent);
        _ = g.text(tag, x + w - tw + 2 * u, stage_y + 9 * u, g.scaled(12), gfx.white);
    }
}

fn drawDeck(g: *gfx.Gfx, v: *View, s: *Session, snap: *const session_mod.Snapshot, t: i64, x: f32, w: f32) void {
    if (w < 80) return;
    const chart = &s.chart;
    const u = g.h / 720;
    const sc = &snap.score;
    const gap = 6 * u;
    const frac: f32 = if (chart.last_time_us > 0) std.math.clamp(@as(f32, @floatFromInt(snap.time_us)) / @as(f32, @floatFromInt(chart.last_time_us)), 0, 1) else 0;

    const bar_h = 38 * u;
    drawTitleBar(g, s, snap, x, w, bar_h, frac);

    const graph_h = 112 * u;
    const read_h = 74 * u;
    const graph_y = g.h - 8 * u - graph_h;
    const read_y = graph_y - gap - read_h;
    const stage_y = 8 * u + bar_h + gap;
    const stage_h = read_y - gap - stage_y;
    drawStage(g, v, s, snap, t, x, w, stage_y, stage_h);
    drawReadouts(g, chart, snap, x, w, read_y, read_h, gap);
    const pace = if (v.target_live) @as(i64, sc.exScore()) - v.target_ex else paceDiff(sc.exScore(), v.target_ex, sc.passed, chart.total_notes);
    g.fmt(x + 10 * u, read_y + 22 * u, g.scaled(12), if (pace >= 0) gfx.cyan else gfx.amber, "{s} {s}{d}", .{ v.target_label, if (pace >= 0) "+" else "-", @abs(pace) });

    const a_w = w * 0.26;
    const c_w = w * 0.3;
    const b_w = w - a_w - c_w - gap * 2;
    drawScoreGraph(g, sc.exScore(), sc.passed, v.target_ex, chart.total_notes, x, graph_y, a_w, graph_h);
    const nx = x + a_w + gap;
    drawNotesGraph(g, v, nx, graph_y, b_w, graph_h, frac);
    drawJudgeCounts(g, snap, nx + b_w + gap, graph_y, c_w, graph_h);
    drawTag(g, s, x, w, stage_y);
}

test "a target's EX and the pace against it" {
    try std.testing.expectEqual(@as(u32, 77), targetEx(0, 77, 900));
    try std.testing.expectEqual(@as(u32, 1800), targetEx(1, 77, 900));
    try std.testing.expectEqual(@as(u32, 1600), targetEx(2, 77, 900));
    try std.testing.expectEqual(@as(u32, 2), targetEx(2, 0, 1));
    try std.testing.expectEqual(@as(u8, 1), paceTarget(0, true));
    try std.testing.expectEqual(@as(u8, 0), paceTarget(0, false));
    try std.testing.expectEqual(@as(u8, 3), paceTarget(3, true));
    try std.testing.expectEqual(@as(i64, 10), paceDiff(100, 1800, 50, 1000));
    try std.testing.expectEqual(@as(i64, -10), paceDiff(80, 1800, 50, 1000));
    try std.testing.expectEqual(@as(i64, -1000), paceDiff(800, 1800, 2000, 1000));
}

test "a 4 key gear has wide, mirrored lanes" {
    try std.testing.expect(keyWidth(.beat4) > keyWidth(.beat7) * 2);
    try std.testing.expectEqual(noteColor(.beat4, 0), noteColor(.beat4, 3));
    try std.testing.expectEqual(noteColor(.beat4, 1), noteColor(.beat4, 2));
    try std.testing.expect(noteColor(.beat4, 0).r != noteColor(.beat4, 1).r);
}

test "scratch on the right moves to the end in single play only" {
    var out: [core.types.max_lanes]u8 = undefined;
    const n = laneOrder(.beat7, true, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, out[0..n]);
    const d = laneOrder(.beat14, true, &out);
    try std.testing.expectEqual(@as(u8, 7), out[0]);
    try std.testing.expectEqual(@as(u8, 15), out[d - 1]);
}

test "green number maps to visible y" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.375), visibleY(600, 150), 1e-9);
}

test "scroll takes CONSTANT from the play, not from the settings" {
    const tl = [_]core.types.Timeline{.{ .time_us = 0, .y = 0, .section = 0, .bpm = 150, .stop_us = 0, .scroll = 1, .speed = 1, .bar = false }};
    const chart: core.types.Chart = .{ .arena = undefined, .bpm = 150, .timelines = @constCast(&tl) };
    var v: View = .{ .render_state = &.{} };
    const cfg: config.Config = .{ .hs_fix = 3, .assist = .{ .constant = true } };
    try std.testing.expect(scrollAt(&v, &chart, &cfg, .{}, 0).per_us == null);
    try std.testing.expect(scrollAt(&v, &chart, &cfg, .{ .constant = true }, 0).per_us != null);
}

test "main BPM finds a tempo that only starts late in the chart, past hundreds of others" {
    const base: core.types.Timeline = .{ .time_us = 0, .y = 0, .section = 0, .bpm = 100, .stop_us = 0, .scroll = 1, .speed = 1, .bar = false };
    var tl: [600]core.types.Timeline = @splat(base);
    for (&tl, 0..) |*t, i| {
        t.time_us = @intCast(i * 1000);
        t.bpm = @floatFromInt(100 + i);
    }
    const chart: core.types.Chart = .{ .arena = undefined, .bpm = 100, .timelines = &tl, .last_time_us = 60_000_000 };
    try std.testing.expectEqual(@as(f64, 699), mainBpm(&chart));
}

test "a long note outlasting the margin is not skipped" {
    const notes = [_]Note{
        .{ .time_us = 0, .y = 0, .wav = -1, .lane = 0, .kind = .ln_start, .pair = 1 },
        .{ .time_us = 9_000_000, .y = 1, .wav = -1, .lane = 0, .kind = .ln_end, .pair = 0 },
    };
    const chart: core.types.Chart = .{ .arena = undefined, .notes = @constCast(&notes) };
    try std.testing.expectEqual(@as(usize, 0), skipPastNotes(&chart, 0, 8_000_000));
    try std.testing.expectEqual(@as(usize, 2), skipPastNotes(&chart, 0, 12_000_000));
}
