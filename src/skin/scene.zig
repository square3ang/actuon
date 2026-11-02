//! Skin values for the play and result scenes, and the skinned play renderer.
const std = @import("std");
const room = @import("../net/room.zig");
const c = @import("c");
const core = @import("actuon_core");
const gfx = @import("../ui/gfx.zig");
const m = @import("model.zig");
const skin_mod = @import("skin.zig");
const session_mod = @import("../game/session.zig");
const config = @import("../game/config.zig");
const play = @import("../ui/play.zig");
const bga_mod = @import("../ui/bga.zig");
const ir = @import("../net/ir.zig");
const Snapshot = session_mod.Snapshot;
const Session = session_mod.Session;

/// #DIFFICULTY, else the word in the title, else by note count, as beatoraja guesses it.
fn shownDifficulty(ch: *const core.types.Chart) i32 {
    if (ch.difficulty != 0) return ch.difficulty;
    const words = [_][]const u8{ "BEGINNER", "NORMAL", "HYPER", "ANOTHER", "INSANE" };
    for (words, 1..) |w, i| {
        if (std.ascii.findIgnoreCase(ch.title, w) != null or std.ascii.findIgnoreCase(ch.subtitle, w) != null) return @intCast(i);
    }
    const n = ch.total_notes;
    return if (n < 250) 1 else if (n < 600) 2 else if (n < 1000) 3 else if (n < 2000) 4 else 5;
}

const graph_bins = 512;

/// One row of song select as a skin's song bars show it.
pub const Bar = struct {
    label: []const u8,
    kind: enum(u8) { song, folder, table, grade, missing, command, search },
    level: i64 = 0,
    difficulty: i32 = 0,
    clear: u8 = 0,
    has_ln: bool = false,
};

pub const BarList = struct {
    ud: *anyopaque,
    len: usize,
    /// In rows; the fraction is how far the bars have moved on toward the next.
    scroll: f32,
    at: *const fn (ud: *anyopaque, row: usize) Bar,
};

/// What song select adds to the state: the selected row's score and where it is.
pub const SelectInfo = struct {
    kind: @TypeOf(@as(Bar, undefined).kind) = .song,
    clear: u8 = 0,
    ex: u32 = 0,
    miss: i64 = -1,
    played: u32 = 0,
    has_ln: bool = false,
    directory: []const u8 = "",
    search: []const u8 = "",
    /// Which option panel is open: 0 none, 1 play, 2 assist, 3 detail.
    panel: u8 = 0,
    /// In beatoraja's image order, for the skin's option buttons.
    gauge_index: i64 = 0,
    random_index: i64 = 0,
    hsfix_index: i64 = 0,
    autoshift_index: i64 = 0,
    mode_index: i64 = 0,
    sort_index: i64 = 0,
    ln_index: i64 = 0,
    /// Saved replays of the selected chart, and the slot picked among them.
    replays: u8 = 0,
    replay_slot: u8 = 0,
};

pub const State = struct {
    select: ?SelectInfo = null,
    timers: [2048]i64 = @splat(-1),
    snap: Snapshot = .{},
    title: []const u8 = "",
    subtitle: []const u8 = "",
    artist: []const u8 = "",
    subartist: []const u8 = "",
    genre: []const u8 = "",
    table_name: []const u8 = "",
    table_level: []const u8 = "",
    table_full_buf: [200]u8 = undefined,
    table_full: []const u8 = "",
    playlevel: i64 = 0,
    mode: core.types.Mode = .beat7,
    total_notes: u32 = 0,
    length_us: i64 = 0,
    bpm: f64 = 0,
    min_bpm: f64 = 0,
    max_bpm: f64 = 0,
    judgerank: i32 = 75,
    autoplay: bool = false,
    replay: bool = false,
    green_ms: u32 = 600,
    cover: f32 = 0,
    lift: f32 = 0,
    hidden: f32 = 0,
    clear: core.types.Clear = .no_play,
    show_clear: bool = false,
    /// The lamp held before this play, on the result screen.
    best_clear: u8 = 0,
    best_ex: u32 = 0,
    /// What the play is measured against: a pace target, or the live score of a versus opponent.
    target_ex: u32 = 0,
    target_label: []const u8 = "MAX",
    /// The opponent's EX is already where they stand now, so it is not scaled to the song's progress.
    target_live: bool = false,
    /// The room of a versus round, for skins that show every player.
    versus: ?*const room.View = null,
    last_judge_at: i64 = -1,
    last_seen_judge_at: i64 = std.math.minInt(i64),
    flash_seen: [core.types.max_lanes]i64 = @splat(-10_000_000),
    bomb_seen: [core.types.max_lanes]i64 = @splat(-10_000_000),
    start_us: i64 = 0,
    difficulty: i32 = 0,
    has_bga: bool = false,
    judge_offset_ms: i32 = 0,
    /// False while the chart's sounds load.
    loaded: bool = true,
    load_frac: f32 = 1,
    /// How long the loading screen ran; the scene clock carries on from it.
    load_ms: i64 = 0,
    /// #STAGEFILE, owned by the app.
    stagefile: ?*gfx.Texture = null,
    /// #BACKBMP and #BANNER, owned by the app.
    backbmp: ?*gfx.Texture = null,
    banner: ?*gfx.Texture = null,
    notes: []const core.types.Note = &.{},
    timelines: []const core.types.Timeline = &.{},
    graph_end_us: i64 = 0,
    note_counts: [4]i64 = @splat(0),
    /// Judged notes per graph bin and judge, folded from the snapshot's hits.
    graph_judged: [graph_bins][6]u16 = @splat(@splat(0)),
    hits_seen: u32 = 0,
    /// This play's upload and ranking, owned by the result screen.
    ir_board: ?*ir.Board = null,

    pub fn fromSession(st: *State, s: *const Session, cfg: *const config.Config) void {
        st.fromChart(&s.chart, s.params, cfg);
        st.loaded = true;
        st.load_frac = 1;
        st.start_us = s.params.start_us - 2_000_000 - st.load_ms * 1000;
        st.timers[40] = st.load_ms;
    }

    /// What can be shown from the parsed chart alone. Called on the loading screen too.
    /// Copies what points into the chart, so a skin can still read it once the session is gone.
    pub fn keepChart(st: *State, al: std.mem.Allocator) void {
        for ([_]*[]const u8{ &st.title, &st.subtitle, &st.artist, &st.subartist, &st.genre }) |f| {
            f.* = al.dupe(u8, f.*) catch "";
        }
        st.notes = al.dupe(core.types.Note, st.notes) catch &.{};
        st.timelines = al.dupe(core.types.Timeline, st.timelines) catch &.{};
    }

    pub fn fromChart(st: *State, ch: *const core.types.Chart, params: session_mod.Params, cfg: *const config.Config) void {
        st.title = ch.title;
        st.subtitle = ch.subtitle;
        st.artist = ch.artist;
        st.subartist = ch.subartist;
        st.genre = ch.genre;
        st.table_name = params.table_name;
        st.table_level = params.table_level;
        st.table_full = std.fmt.bufPrint(&st.table_full_buf, "{s} {s}", .{ params.table_name, params.table_level }) catch "";
        st.playlevel = std.fmt.parseInt(i64, ch.playlevel, 10) catch 0;
        st.mode = ch.mode;
        st.total_notes = ch.total_notes;
        st.length_us = ch.last_time_us;
        st.min_bpm = ch.min_bpm;
        st.max_bpm = ch.max_bpm;
        st.judgerank = ch.judgerank;
        st.difficulty = shownDifficulty(ch);
        st.has_bga = ch.bga.len > 0;
        st.judge_offset_ms = cfg.judge_offset_ms;
        st.autoplay = params.autoplay;
        st.replay = params.replay != null;
        st.green_ms = cfg.green_ms;
        st.cover = cfg.lane_cover;
        st.lift = cfg.lift;
        st.hidden = cfg.hidden;
        st.notes = ch.notes;
        st.timelines = ch.timelines;
        st.graph_end_us = if (ch.last_note_us > 0) ch.last_note_us else ch.last_time_us;
        st.note_counts = @splat(0);
        for (ch.notes) |note| {
            if (note.kind == .ln_end or note.kind == .mine) continue;
            const scratch = ch.mode.scratchOf(note.lane) >= 0;
            const long = note.kind == .ln_start;
            st.note_counts[@as(usize, @intFromBool(scratch)) * 2 + @intFromBool(long)] += 1;
        }
    }

    fn graphBins(st: *const State) usize {
        if (st.graph_end_us <= 0) return 1;
        return @intCast(std.math.clamp(@divTrunc(st.graph_end_us, 1_000_000) + 1, 1, graph_bins));
    }

    fn binOf(st: *const State, time_us: i64) usize {
        const n: i64 = @intCast(st.graphBins());
        return @intCast(std.math.clamp(@divTrunc(time_us * n, @max(st.graph_end_us, 1)), 0, n - 1));
    }

    fn foldHits(st: *State, snap: *const Snapshot) void {
        if (snap.hit_seq -% st.hits_seen > session_mod.hit_ring) st.hits_seen = snap.hit_seq -% session_mod.hit_ring;
        while (st.hits_seen != snap.hit_seq) : (st.hits_seen +%= 1) {
            const hit = snap.hits[st.hits_seen % session_mod.hit_ring];
            if (hit.note < 0 or hit.note >= st.notes.len) continue;
            const note = st.notes[@intCast(hit.note)];
            if (note.kind == .ln_end or note.kind == .mine or hit.judge >= 6) continue;
            st.graph_judged[st.binOf(note.time_us)][hit.judge] +|= 1;
        }
    }

    fn laneTimer(st: *const State, lane: u8) ?i32 {
        // beatoraja numbering: scratch is 0, keys 1..9, 2P adds 10.
        const per: u8 = st.mode.keys() / st.mode.players();
        const side = lane / per;
        const idx = lane % per;
        const sc = st.mode.scratchOf(lane) >= 0;
        return @as(i32, side) * 10 + (if (sc) @as(i32, 0) else idx + 1);
    }

    /// Advances timers from a fresh snapshot. All timer times are scene ms.
    pub fn update(st: *State, snap: Snapshot) void {
        st.snap = snap;
        const now = st.sceneMs(snap.time_us);
        st.timers[1] = 0;
        if (st.timers[40] < 0) st.timers[40] = 0;
        st.foldHits(&snap);
        if (snap.time_us >= 0 and st.timers[41] < 0) st.timers[41] = st.sceneMs(0);
        if (snap.judge_at_us != st.last_seen_judge_at and snap.last_judge != 255) {
            st.last_seen_judge_at = snap.judge_at_us;
            st.timers[46] = now;
            if (snap.score.combo > 0) st.timers[446] = now;
        }
        if (snap.failed and st.timers[3] < 0) st.timers[3] = now;
        if (snap.finished and st.timers[2] < 0) st.timers[2] = now;
        if (snap.time_us >= st.length_us) {
            if (st.timers[143] < 0) st.timers[143] = now;
            if (st.timers[48] < 0 and snap.score.max_combo >= st.total_notes and st.total_notes > 0) st.timers[48] = now;
        }
        for (0..st.mode.keys()) |l| {
            const lane: u8 = @intCast(l);
            const code = st.laneTimer(lane) orelse continue;
            if (code >= 20) continue;
            if (snap.flash_at_us[l] != st.flash_seen[l]) {
                st.flash_seen[l] = snap.flash_at_us[l];
                st.timers[@intCast(100 + code)] = now;
            }
            // Key-on runs while pressed. Autoplay has no releases, so its presses last 80 ms.
            const auto_on = st.autoplay and snap.time_us - snap.flash_at_us[l] < 80_000;
            if (snap.held[l] or auto_on) {
                st.timers[@intCast(120 + code)] = -1;
            } else if (st.timers[@intCast(100 + code)] >= 0) {
                // Key-off answers a release, so nothing plays before the first press.
                st.timers[@intCast(100 + code)] = -1;
                st.timers[@intCast(120 + code)] = now;
            }
            if (snap.bomb_at_us[l] != st.bomb_seen[l]) {
                st.bomb_seen[l] = snap.bomb_at_us[l];
                st.timers[@intCast(50 + code)] = now;
            }
            const hold = 70 + code;
            if (snap.processing[l]) {
                if (st.timers[@intCast(hold)] < 0) st.timers[@intCast(hold)] = now;
            } else st.timers[@intCast(hold)] = -1;
        }
        if (st.bpm > 0 or st.max_bpm > 0) {
            const bpm = if (st.bpm > 0) st.bpm else st.max_bpm;
            const beat: i64 = @intFromFloat(60_000.0 / bpm);
            // This timer runs 0 to 1000 over each beat, whatever the tempo.
            st.timers[140] = @max(now - @divTrunc(@mod(now, @max(beat, 1)) * 1000, @max(beat, 1)), 0);
        }
    }

    pub fn sceneMs(st: *const State, us: i64) i64 {
        return @divTrunc(us - st.start_us, 1000);
    }

    fn fromUd(ud: *anyopaque) *State {
        return @ptrCast(@alignCast(ud));
    }

    fn opt(ud: *anyopaque, id: i32) bool {
        const st = fromUd(ud);
        const sn = &st.snap;
        const sc = &sn.score;
        const rate = st.scoreRate();
        if (st.versusPlayer(id, m.versus_present)) |_| return true;
        if (id >= m.versus_present and id < m.versus_present + room.max_players) return false;
        if (st.select) |se| switch (id) {
            1 => return se.kind == .folder or se.kind == .table or se.kind == .command,
            2 => return se.kind == .song or se.kind == .missing,
            3 => return se.kind == .grade,
            5 => return se.kind == .song or se.kind == .grade,
            20...23 => return se.panel == id - 20,
            196 => return se.replays < 1,
            197 => return se.replays >= 1,
            1196 => return se.replays < 2,
            1197 => return se.replays >= 2,
            1199 => return se.replays < 3,
            1200 => return se.replays >= 3,
            1202 => return se.replays < 4,
            1203 => return se.replays >= 4,
            1205...1208 => return se.replay_slot == id - 1205,
            100 => return se.clear == 0,
            101 => return se.clear == 1,
            1100 => return se.clear == 2,
            1101 => return se.clear == 3,
            102, 103, 104 => return se.clear == id - 98,
            1102 => return se.clear == 7,
            105 => return se.clear == 8,
            1103 => return se.clear == 9,
            1104 => return se.clear == 10,
            173 => return se.has_ln,
            200...207 => return se.clear > 0 and rankIndex(st.bestRate()) == id - 200,
            else => {},
        };
        return switch (id) {
            5 => true,
            50 => st.ir_board == null,
            51 => st.ir_board != null,
            601, 606, 607 => if (st.ir_board) |b| !b.ready() else false,
            602 => if (st.ir_board) |b| b.ready() else false,
            603 => if (st.ir_board) |b| b.ready() and b.total == 0 else false,
            604 => if (st.ir_board) |b| b.state.load(.acquire) == ir.Board.failed else false,
            m.combo_on => sc.combo > 0,
            m.key_held...m.key_held + 19 => st.timers[@intCast(100 + id - m.key_held)] >= 0,
            32 => !st.autoplay,
            33 => st.autoplay,
            42 => @backingInt(sn.gauge_type) < 3,
            43 => @backingInt(sn.gauge_type) >= 3,
            80 => !st.loaded,
            81 => st.loaded,
            190 => st.stagefile == null,
            191 => st.stagefile != null,
            82 => !st.replay,
            84 => st.replay,
            150...155 => st.difficulty == id - 150,
            170 => !st.has_bga,
            171 => st.has_bga,
            176 => st.min_bpm == st.max_bpm,
            177 => st.min_bpm != st.max_bpm,
            271 => st.cover > 0,
            272 => st.lift > 0,
            273 => st.hidden > 0,
            90 => st.show_clear and @backingInt(st.clear) >= @backingInt(core.types.Clear.easy),
            91 => st.show_clear and @backingInt(st.clear) < @backingInt(core.types.Clear.easy),
            160 => st.mode == .beat7,
            161 => st.mode == .beat5,
            162 => st.mode == .beat14,
            163 => st.mode == .beat10,
            164 => st.mode == .popn9,
            200...207 => rankIndex(rate) == id - 200,
            230...239 => @as(i32, @intFromFloat(sn.gauge / 10)) == id - 230,
            240 => sn.gauge >= 100,
            1240 => sn.gauge >= sn.gauge_border,
            241...246 => sn.last_judge == id - 241,
            340...347 => rankIndex(rate) == id - 340,
            1242 => sn.last_fast_us > 0 and sn.last_judge > 0,
            1243 => sn.last_fast_us < 0 and sn.last_judge > 0,
            2241 => sc.count(.pg) > 0,
            2242 => sc.count(.gr) > 0,
            2243 => sc.count(.gd) > 0,
            2244 => sc.count(.bd) > 0,
            2245 => sc.count(.pr) > 0,
            2246 => sc.count(.ms) > 0,
            else => false,
        };
    }

    fn rankIndex(rate: f32) i32 {
        var i: i32 = 0;
        var step: f32 = 8.0 / 9.0;
        while (i < 7) : (i += 1) {
            if (rate >= step) return i;
            step -= 1.0 / 9.0;
        }
        return 7;
    }

    fn judgedNotes(st: *const State) u32 {
        var seen: u32 = 0;
        for (st.snap.score.counts) |v| seen += v[0] + v[1];
        return seen;
    }

    fn judgedShare(st: *const State) f32 {
        if (st.total_notes == 0) return 0;
        return @min(@as(f32, @floatFromInt(st.judgedNotes())) / @as(f32, @floatFromInt(st.total_notes)), 1);
    }

    fn bestRate(st: *const State) f32 {
        if (st.total_notes == 0) return 0;
        return @as(f32, @floatFromInt(st.best_ex)) / @as(f32, @floatFromInt(st.total_notes * 2));
    }

    fn scoreRate(st: *const State) f32 {
        // Song select has no play running: the rate shown is the best score's.
        if (st.select != null) return st.bestRate();
        if (st.total_notes == 0) return 0;
        return @as(f32, @floatFromInt(st.snap.score.exScore())) / @as(f32, @floatFromInt(st.total_notes * 2));
    }

    fn versusPlayer(st: *const State, id: i32, base: i32) ?*const room.Player {
        const v = st.versus orelse return null;
        if (id < base or id >= base + v.count) return null;
        return &v.players[@intCast(id - base)];
    }

    fn num(ud: *anyopaque, id: i32) ?i64 {
        const st = fromUd(ud);
        if (st.versusPlayer(id, m.versus_ex)) |p| return p.final_ex orelse p.ex;
        if (st.versusPlayer(id, m.versus_judged)) |p| return p.judged;
        const sn = &st.snap;
        const sc = &sn.score;
        const n: i64 = st.total_notes;
        const rate10k: i64 = @intFromFloat(st.scoreRate() * 10000);
        const judged = struct {
            fn f(s: *const core.sim.Score, j: usize) i64 {
                return s.counts[j][0] + s.counts[j][1];
            }
        }.f;
        if (st.select) |se| {
            const secs = @divTrunc(st.length_us, 1_000_000);
            switch (id) {
                m.button_index + 11 => return se.mode_index,
                m.button_index + 308 => return se.ln_index,
                m.button_index + 12 => return se.sort_index,
                m.button_index + 40 => return se.gauge_index,
                m.button_index + 42 => return se.random_index,
                m.button_index + 55 => return se.hsfix_index,
                m.button_index + 78 => return se.autoshift_index,
                71 => return se.ex,
                76 => return if (se.miss >= 0) se.miss else null,
                77 => return se.played,
                1163 => return @divTrunc(secs, 60),
                1164 => return @mod(secs, 60),
                75, 78, 79, 110, 111, 112, 113, 114 => return null,
                else => {},
            }
        }
        const left: i64 = @divTrunc(@max(st.length_us - sn.time_us, 0), 1_000_000);
        const elapsed: i64 = @divTrunc(@max(sn.time_us, 0), 1_000_000);
        return switch (id) {
            71, 101, 171 => sc.exScore(),
            72 => n * 2,
            74, 106 => n,
            75, 105, 174 => sc.max_combo,
            76, 177 => sc.missCount(),
            104 => sc.combo,
            80, 110 => judged(sc, 0),
            81, 111 => judged(sc, 1),
            82, 112 => judged(sc, 2),
            83, 113 => judged(sc, 3),
            84, 114 => judged(sc, 4),
            410...421 => sc.counts[@intCast(@divTrunc(id - 410, 2))][@intCast(@mod(id - 410, 2))],
            m.gauge_type => @backingInt(sn.gauge_type),
            m.acc_whole, m.acc_frac => blk: {
                // osu! starts at 100%.
                const seen: i64 = st.judgedNotes();
                const acc: i64 = if (seen > 0) @divTrunc(@as(i64, sc.exScore()) * 10000, seen * 2) else 10000;
                break :blk if (id == m.acc_whole) @divTrunc(acc, 100) else @mod(acc, 100);
            },
            165 => @intFromFloat(st.load_frac * 100),
            350...353 => st.note_counts[@intCast(id - 350)],
            12 => st.judge_offset_ms,
            121, 151 => st.target_ex,
            153 => if (st.target_live) @as(i64, sc.exScore()) - st.target_ex else play.paceDiff(sc.exScore(), st.target_ex, st.judgedNotes(), st.total_notes),
            423 => blk: {
                var t: i64 = 0;
                for (sc.counts[0..5]) |v| t += v[0];
                break :blk t;
            },
            424 => blk: {
                var t: i64 = 0;
                for (sc.counts[0..5]) |v| t += v[1];
                break :blk t;
            },
            425 => sc.missCount(),
            426 => judged(sc, 4) + judged(sc, 5),
            427 => judged(sc, 3) + judged(sc, 4) + judged(sc, 5),
            90 => @intFromFloat(st.max_bpm),
            91 => @intFromFloat(st.min_bpm),
            160 => @intFromFloat(st.bpm),
            96 => st.playlevel,
            100 => if (n > 0) @divTrunc(sc.exScore() * 200000 + n, n * 2) else 0,
            102, 155 => @divTrunc(rate10k, 100),
            103, 156 => @mod(rate10k, 100),
            107 => @intFromFloat(sn.gauge),
            407 => @intFromFloat(@mod(sn.gauge * 10, 10)),
            150, 170 => st.best_ex,
            108, 128, 172 => @as(i64, sc.exScore()) - st.best_ex,
            // Against the pace so far, not the whole song.
            152 => @as(i64, sc.exScore()) - @as(i64, @intFromFloat(@as(f32, @floatFromInt(st.best_ex)) * st.judgedShare())),
            161 => @divTrunc(elapsed, 60),
            162 => @mod(elapsed, 60),
            163 => @divTrunc(left, 60),
            164 => @mod(left, 60),
            312 => st.green_ms,
            313 => st.green_ms * 3 / 5,
            14 => @intFromFloat(st.cover * 1000),
            314 => @intFromFloat(st.lift * 1000),
            315 => @intFromFloat(st.hidden * 1000),
            370 => @backingInt(st.clear),
            371 => st.best_clear,
            400 => st.judgerank,
            else => if (st.ir_board) |b| b.number(id) else null,
        };
    }

    fn float(ud: *anyopaque, id: i32) f32 {
        const st = fromUd(ud);
        const sn = &st.snap;
        return switch (id) {
            m.gauge_value => sn.gauge / 100,
            m.gauge_border => if (@backingInt(sn.gauge_type) >= 3) 0 else sn.gauge_border / 100,
            4 => st.cover,
            8 => if (st.ir_board) |b| b.position() else 0,
            6, 101 => if (st.length_us > 0) @as(f32, @floatFromInt(@max(sn.time_us, 0))) / @as(f32, @floatFromInt(st.length_us)) else 0,
            102 => st.load_frac,
            110, 147 => st.scoreRate(),
            111 => blk: {
                const seen = st.judgedNotes();
                break :blk if (seen > 0) @as(f32, @floatFromInt(sn.score.exScore())) / @as(f32, @floatFromInt(seen * 2)) else 0;
            },
            112 => st.bestRate() * st.judgedShare(),
            113 => st.bestRate(),
            114 => st.judgedShare(),
            115 => if (st.total_notes > 0) @min(@as(f32, @floatFromInt(st.target_ex)) / @as(f32, @floatFromInt(st.total_notes * 2)), 1) else 0,
            140...144 => if (st.total_notes > 0) @as(f32, @floatFromInt(sn.score.count(@fromBackingInt(@intCast(id - 140))))) / @as(f32, @floatFromInt(st.total_notes)) else 0,
            145 => if (st.total_notes > 0) @as(f32, @floatFromInt(sn.score.max_combo)) / @as(f32, @floatFromInt(st.total_notes)) else 0,
            else => 0,
        };
    }

    /// True when the slider took the value, so the mouse press is used up.
    fn setFloat(ud: *anyopaque, id: i32, value: f32) bool {
        const b = fromUd(ud).ir_board orelse return false;
        if (id != 8) return false;
        b.setPosition(value);
        return true;
    }

    fn str(ud: *anyopaque, id: i32) []const u8 {
        const st = fromUd(ud);
        if (st.versusPlayer(id, m.versus_name)) |p| return p.name();
        if (st.select) |se| switch (id) {
            30 => return se.search,
            1000 => return se.directory,
            else => {},
        };
        return switch (id) {
            1 => st.target_label,
            10, 12 => st.title,
            11 => st.subtitle,
            13 => st.genre,
            14, 16 => st.artist,
            15 => st.subartist,
            1001 => st.table_name,
            1002 => st.table_level,
            1003 => st.table_full,
            120...129 => if (st.ir_board) |b| b.name(id) else "",
            1020 => if (st.ir_board != null) "Actuon IR" else "",
            else => "",
        };
    }

    /// For a skin's script as it loads: it may pick colors and parts from the song.
    pub fn loadCtx(st: *State) m.Ctx {
        return .{ .ud = st, .now_ms = 0, .timers = &st.timers, .opt = opt, .num = num, .float = float, .str = str, .lua_call_bool = null, .lua_call_num = null };
    }

    pub fn ctx(st: *State, skin: *const m.Skin, now_ms: i64) m.Ctx {
        for (skin.videos) |v| v.tickLoop(now_ms);
        var lane_h: f32 = 0;
        for (skin.notes.lane) |lane| if (lane) |rect| {
            lane_h = rect[1];
            break;
        };
        return .{
            .lift_px = lane_h * st.lift,
            .hidden_px = lane_h * st.hidden,
            .ud = st,
            .now_ms = now_ms,
            .timers = &st.timers,
            .opt = opt,
            .num = num,
            .float = float,
            .str = str,
            .set_float = setFloat,
            .lua_call_bool = if (skin.lua != null) skin_mod.lua_call_bool else null,
            .lua_call_num = if (skin.lua != null) skin_mod.lua_call_num else null,
            .lua_call_str = if (skin.lua != null) skin_mod.lua_call_str else null,
        };
    }
};

fn drawNotes(r: *const m.Renderer, s: *Session, view: *play.View, snap: *const Snapshot, cfg: *const config.Config) void {
    const chart = &s.chart;
    const notes = &r.s.notes;
    const t = snap.time_us - @as(i64, cfg.visual_offset_ms) * 1000;
    if (t < view.last_t) view.first_note = 0; // seeked backwards
    view.last_t = t;
    const vis_y = play.visibleY(cfg.green_ms, view.refBpm(chart, cfg.hs_fix)) / chart.speedAt(t);
    const now_y = chart.yAt(t);
    view.first_note = play.skipPastNotes(chart, view.first_note, t);
    const base: m.Key = .{};
    for (chart.notes[view.first_note..], view.first_note..) |note, i| {
        const lane_rect = notes.lane[note.lane] orelse continue;
        const judge_y = lane_rect[1] - r.ctx.lift_px;
        const lane_h = lane_rect[1] * cfg.openLane();
        // A skin without a hidden cover still hides.
        const hidden_y = if (r.ctx.hidden_px > 0) judge_y - r.ctx.hidden_px else std.math.inf(f32);
        const px_per_y = lane_h / @as(f32, @floatCast(vis_y));
        const dy: f32 = @floatCast(note.y - now_y);
        // As beatoraja, nothing falls past the judge line; an LN's head waits on it until the end passes.
        if (note.time_us < t and note.kind != .ln_start) continue;
        const yy = @min(judge_y - dy * px_per_y, judge_y);
        if (yy < -lane_rect[3] and note.kind != .ln_start) {
            if (note.time_us > t + 60_000_000) break;
            continue;
        }
        var k = base;
        k.x = lane_rect[0];
        k.w = lane_rect[2];
        k.h = lane_rect[3];
        k.y = yy - k.h;
        switch (note.kind) {
            .normal => if (view.render_state[i] == 0 and yy <= hidden_y) r.blit(&notes.note[note.lane], r.frameOf(&notes.note[note.lane]), k, 1, 0, null),
            .mine => if (view.render_state[i] == 0 and yy <= hidden_y) r.blit(&notes.mine[note.lane], r.frameOf(&notes.mine[note.lane]), k, 1, 0, null),
            .ln_start => {
                if (note.pair < 0) continue;
                const pair: usize = @intCast(note.pair);
                // As beatoraja, it stays until its end passes, whatever was judged: the head waits on the
                // line under the body, held or not.
                if (chart.notes[pair].time_us < t) continue;
                const active = snap.holding[note.lane] == note.pair;
                const end_dy: f32 = @floatCast(chart.notes[pair].y - now_y);
                const end_y = judge_y - end_dy * px_per_y;
                const body_bot = @min(if (notes.ln_osu) yy - k.h / 2 else yy - k.h, hidden_y);
                var b = k;
                b.y = if (notes.ln_osu) end_y - k.h / 2 else end_y;
                b.h = body_bot - b.y;
                if (b.h > 0) {
                    const body = if (active and notes.ln_active[note.lane].tex >= 0) &notes.ln_active[note.lane] else &notes.ln_body[note.lane];
                    const cut: ?[4]f32 = if (notes.ln_body_span > 0) .{ 0, 0, 1, @min(b.h / notes.ln_body_span, 1) } else null;
                    r.blit(body, r.frameOf(body), b, 1, 0, cut);
                }
                if (yy <= hidden_y) r.blit(&notes.ln_start[note.lane], r.frameOf(&notes.ln_start[note.lane]), k, 1, 0, null);
                // Only an LN judged on release ends in a note of its own.
                if ((note.ln_type != .ln or notes.ln_osu) and end_y <= hidden_y) {
                    var e = k;
                    e.y = end_y - e.h;
                    if (notes.ln_end_flip) {
                        e.y += e.h;
                        e.h = -e.h;
                    }
                    r.blit(&notes.ln_end[note.lane], r.frameOf(&notes.ln_end[note.lane]), e, 1, 0, null);
                }
            },
            .ln_end => {},
        }
    }
}

fn screenRect(r: *const m.Renderer, k: m.Key) c.SDL_FRect {
    return .{ .x = k.x * r.sx, .y = k.y * r.sy, .w = k.w * r.sx, .h = k.h * r.sy };
}

const graph_colors = [6]gfx.Color{
    .{ .r = 153, .g = 204, .b = 255 },
    .{ .r = 242, .g = 203, .b = 48 },
    .{ .r = 20, .g = 204, .b = 143 },
    .{ .r = 255, .g = 26, .b = 179 },
    .{ .r = 204, .g = 41, .b = 41 },
    .{ .r = 110, .g = 30, .b = 30 },
};

/// Notes per second as bars: gray until judged, then the judge's color. A line marks where the song is.
fn drawNotesGraph(g: *gfx.Gfx, st: *const State, d: c.SDL_FRect, now_us: i64) void {
    if (st.graph_end_us <= 0 or d.w <= 0) return;
    var totals: [graph_bins]u16 = @splat(0);
    var most: u16 = 1;
    const n = st.graphBins();
    for (st.notes) |note| {
        if (note.kind == .ln_end or note.kind == .mine) continue;
        const at = st.binOf(note.time_us);
        totals[at] += 1;
        most = @max(most, totals[at]);
    }
    const bw = d.w / @as(f32, @floatFromInt(n));
    const unit = d.h / @as(f32, @floatFromInt(most));
    for (totals[0..n], st.graph_judged[0..n], 0..) |count, judged, i| {
        const x = d.x + bw * @as(f32, @floatFromInt(i));
        const w = @max(bw - 1, 1);
        var y = d.y + d.h;
        var left = count;
        for (judged, graph_colors) |amount, col| {
            const shown = @min(amount, left);
            left -= shown;
            const h = @as(f32, @floatFromInt(shown)) * unit;
            y -= h;
            g.rect(x, y, w, h, col);
        }
        const h = @as(f32, @floatFromInt(left)) * unit;
        g.rect(x, y - h, w, h, .{ .r = 128, .g = 128, .b = 128 });
    }
    const f = std.math.clamp(@as(f32, @floatFromInt(now_us)) / @as(f32, @floatFromInt(st.graph_end_us)), 0, 1);
    g.rect(d.x + d.w * f, d.y, 2, d.h, gfx.white);
}

/// BPM over the song, the middle height when it never changes.
fn drawBpmGraph(g: *gfx.Gfx, st: *const State, d: c.SDL_FRect) void {
    if (st.graph_end_us <= 0 or st.timelines.len == 0) return;
    const col: gfx.Color = .{ .r = 0, .g = 255, .b = 0 };
    const span = st.max_bpm - st.min_bpm;
    const yOf = struct {
        fn f(box: c.SDL_FRect, bpm: f64, low: f64, range: f64) f32 {
            const v: f32 = if (range > 0) @floatCast((bpm - low) / range) else 0.5;
            return box.y + box.h * (1 - std.math.clamp(v, 0, 1));
        }
    }.f;
    var bpm = st.timelines[0].bpm;
    var from: f32 = d.x;
    for (st.timelines) |tl| {
        if (tl.bpm == bpm) continue;
        const x = d.x + d.w * std.math.clamp(@as(f32, @floatFromInt(tl.time_us)) / @as(f32, @floatFromInt(st.graph_end_us)), 0, 1);
        const y0 = yOf(d, bpm, st.min_bpm, span);
        const y1 = yOf(d, tl.bpm, st.min_bpm, span);
        g.rect(from, y0, x - from, 2, col);
        g.rect(x, @min(y0, y1), 2, @abs(y1 - y0), col);
        from = x;
        bpm = tl.bpm;
    }
    g.rect(from, yOf(d, bpm, st.min_bpm, span), d.x + d.w - from, 2, col);
}

/// Recent hits as lines around zero: over the judge windows' bands, or bare for a hit error meter.
/// A negative width mirrors it, as the skin's destination asks.
fn drawTiming(g: *gfx.Gfx, o: *const m.Object, st: *const State, snap: *const Snapshot, box: c.SDL_FRect) void {
    const dir: f32 = if (box.w < 0) -1 else 1;
    const half = @abs(box.w) / 2;
    const mid = box.x + box.w / 2;
    const left = mid - half;
    const span: f32 = @floatFromInt(@as(i64, o.timing_ms) * 1000);
    if (!o.timing_bare) {
        g.rect(left, box.y, half * 2, box.h, o.timing_colors[4]);
        const w = core.windows.create(5, core.windows.note_base, st.judgerank);
        var i: usize = 4;
        while (i > 0) {
            i -= 1;
            const reach = @min(@as(f32, @floatFromInt(w[i][1])) / span, 1) * half;
            g.rect(mid - reach, box.y, reach * 2, box.h, o.timing_colors[i]);
        }
    }
    const kept = @min(snap.hit_seq, o.window);
    var ema: f32 = 0;
    var i: u32 = kept;
    while (i > 0) {
        i -= 1;
        const hit = snap.hits[(snap.hit_seq -% 1 -% i) % session_mod.hit_ring];
        const f = std.math.clamp(@as(f32, @floatFromInt(hit.fast_us)) / span, -1, 1);
        ema += (f - ema) * 0.2;
        if (hit.judge >= 5) continue; // an empty miss has no timing
        var col = if (o.line_color.a > 0) o.line_color else o.timing_colors[hit.judge];
        if (o.decay) col = col.alpha(@intCast(@as(u32, col.a) * (kept - i) / kept));
        g.rect(mid - f * half * dir, box.y, 2, box.h, col);
    }
    if (kept > 0 and o.ema_color.a > 0) g.rect(mid - ema * half * dir - 1, box.y, 3, box.h, o.ema_color);
    if (!o.timing_bare) g.rect(mid - 1, box.y, 2, box.h, gfx.white);
}

fn drawStagefile(g: *gfx.Gfx, image: ?*gfx.Texture, d: c.SDL_FRect, alpha: f32) void {
    const tex = image orelse return;
    const fitted = bga_mod.fit(1, tex.w, tex.h, d);
    g.sprite(tex, fitted.src, fitted.dst, .{ .col = gfx.Color{ .r = 255, .g = 255, .b = 255, .a = @intFromFloat(std.math.clamp(alpha, 0, 255)) } });
}

/// A screen that only knows the parsed chart: the skin's loading screen, or decide.
pub fn drawLoading(g: *gfx.Gfx, skin: *m.Skin, st: *State, now_ms: i64) void {
    st.timers[1] = 0;
    const ctx = st.ctx(skin, now_ms);
    skin_mod.setLuaCtx(&ctx);
    defer skin_mod.setLuaCtx(null);
    const r: m.Renderer = .{ .g = g, .s = skin, .ctx = &ctx, .sx = g.w / skin.w, .sy = g.h / skin.h };
    const before: Snapshot = .{};
    for (skin.objects) |*o| switch (o.kind) {
        .notes, .bga, .judge => {},
        .notes_graph => if (r.visible(o)) |k| drawNotesGraph(g, st, screenRect(&r, k), 0),
        .bpm_graph => if (r.visible(o)) |k| drawBpmGraph(g, st, screenRect(&r, k)),
        .timing => if (r.visible(o)) |k| drawTiming(g, o, st, &before, screenRect(&r, k)),
        .stagefile => if (r.visible(o)) |k| drawStagefile(g, st.stagefile, screenRect(&r, k), k.a),
        .backbmp => if (r.visible(o)) |k| drawStagefile(g, st.backbmp, screenRect(&r, k), k.a),
        .banner => if (r.visible(o)) |k| drawStagefile(g, st.banner, screenRect(&r, k), k.a),
        else => r.drawObject(o),
    };
}

/// Draws a whole play frame with a skin. Returns the snapshot used.
pub fn drawPlay(g: *gfx.Gfx, skin: *m.Skin, st: *State, s: *Session, view: *play.View, cfg: *const config.Config) Snapshot {
    const snap = s.snapshotInto(view.render_state);
    st.bpm = s.chart.bpmAt(snap.time_us);
    st.green_ms = cfg.green_ms;
    st.cover = cfg.lane_cover;
    st.update(snap);
    const ctx = st.ctx(skin, st.sceneMs(snap.time_us));
    skin_mod.setLuaCtx(&ctx);
    defer skin_mod.setLuaCtx(null);
    const r: m.Renderer = .{ .g = g, .s = skin, .ctx = &ctx, .sx = g.w / skin.w, .sy = g.h / skin.h };
    for (skin.objects) |*o| switch (o.kind) {
        .notes => drawNotes(&r, s, view, &snap, cfg),
        .bga => if (view.bga) |b| {
            if (r.visible(o)) |k| {
                b.draw(&s.chart, snap.time_us, snap.last_judge, snap.judge_at_us, .{ .x = k.x * r.sx, .y = k.y * r.sy, .w = k.w * r.sx, .h = k.h * r.sy }, .{
                    // beatoraja keeps the picture's shape unless the skin asks otherwise
                    .stretch = if (o.stretch < 0) 1 else o.stretch,
                    .alpha = @intFromFloat(std.math.clamp(k.a, 0, 255)),
                    .backdrop = false,
                });
            }
        },
        .judge => if (snap.last_judge != 255) r.drawJudge(o, snap.last_judge, snap.score.combo),
        .notes_graph => if (r.visible(o)) |k| drawNotesGraph(g, st, screenRect(&r, k), snap.time_us),
        .bpm_graph => if (r.visible(o)) |k| drawBpmGraph(g, st, screenRect(&r, k)),
        .timing => if (r.visible(o)) |k| drawTiming(g, o, st, &snap, screenRect(&r, k)),
        .stagefile => if (r.visible(o)) |k| drawStagefile(g, st.stagefile, screenRect(&r, k), k.a),
        .backbmp => if (r.visible(o)) |k| drawStagefile(g, st.backbmp, screenRect(&r, k), k.a),
        .banner => if (r.visible(o)) |k| drawStagefile(g, st.banner, screenRect(&r, k), k.a),
        else => r.drawObject(o),
    };
    return snap;
}

/// Which `text` entry a row uses, as ModernChic lists them: general, song, folder, table, grade,
/// missing, command, search. A shorter list falls back on its first entry.
fn barTextIndex(kind: @TypeOf(@as(Bar, undefined).kind), have: usize) usize {
    const at: usize = switch (kind) {
        .song => 2,
        .folder => 4,
        .table => 6,
        .grade => 7,
        .missing => 8,
        .command => 9,
        .search => 10,
    };
    return if (at < have) at else 0;
}

/// Which row a place shows, wrapping around the list like beatoraja's.
fn barRow(scroll_floor: i64, place: usize, center: usize, len: usize) usize {
    return @intCast(@mod(scroll_floor + @as(i64, @intCast(place)) - @as(i64, @intCast(center)), @as(i64, @intCast(len))));
}

/// Returns the row a click landed on.
fn drawBars(r: *const m.Renderer, list_obj: *const m.SongList, bars: BarList) ?usize {
    if (bars.len == 0) return null;
    const base = @floor(bars.scroll);
    const frac = bars.scroll - base;
    const resting = frac < 0.01;
    var clicked: ?usize = null;
    for (list_obj.off, 0..) |*off, i| {
        const row = barRow(@intFromFloat(base), i, list_obj.center, bars.len);
        const b = bars.at(bars.ud, row);
        const selected = i == list_obj.center and resting and i < list_obj.on.len;
        const place = if (selected) &list_obj.on[i] else off;
        var k = r.visible(place) orelse continue;
        // On its way to the place above.
        if (!resting and i > 0) if (r.visible(&list_obj.off[i - 1])) |to| {
            k.x += (to.x - k.x) * frac;
            k.y += (to.y - k.y) * frac;
        };
        const set = place.src.set;
        const src = if (set.len > 0) &set[@min(@backingInt(b.kind), set.len - 1)] else &place.src;
        r.blit(src, r.frameOf(src), k, place.blend, place.center, null);
        if (r.g.clickIn(k.x * r.sx, k.y * r.sy, k.w * r.sx, k.h * r.sy)) clicked = row;
        const child = struct {
            /// Parts are bottom-up from the bar's bottom; `fill` flipped them against the skin's height.
            fn f(rr: *const m.Renderer, o: *const m.Object, bar: m.Key) ?m.Key {
                var x = rr.visible(o) orelse return null;
                x.x += bar.x;
                x.y += bar.y + bar.h - rr.s.h;
                return x;
            }
        }.f;
        if (list_obj.text.len > 0) {
            const t = &list_obj.text[barTextIndex(b.kind, list_obj.text.len)];
            if (child(r, t, k)) |x| r.drawBarText(t, x, b.label);
        }
        if (b.kind == .song or b.kind == .missing) {
            // level: unknown first, then the five difficulties.
            const li: usize = @intCast(std.math.clamp(b.difficulty, 0, 5));
            if (li < list_obj.level.len) {
                const o = &list_obj.level[li];
                if (child(r, o, k)) |x| r.drawValue(o, x, b.level);
            }
            if (b.clear < list_obj.lamp.len) {
                const o = &list_obj.lamp[b.clear];
                if (child(r, o, k)) |x| r.blit(&o.src, r.frameOf(&o.src), x, o.blend, o.center, null);
            }
            if (b.has_ln and list_obj.label.len > 0) {
                const o = &list_obj.label[0];
                if (child(r, o, k)) |x| r.blit(&o.src, r.frameOf(&o.src), x, o.blend, o.center, null);
            }
        }
    }
    return clicked;
}

/// Song select: the skin's objects with the song bars. Returns the row a click landed on.
pub fn drawSelect(g: *gfx.Gfx, skin: *m.Skin, st: *State, now_ms: i64, bars: BarList) ?usize {
    const ctx = st.ctx(skin, now_ms);
    skin_mod.setLuaCtx(&ctx);
    defer skin_mod.setLuaCtx(null);
    const r: m.Renderer = .{ .g = g, .s = skin, .ctx = &ctx, .sx = g.w / skin.w, .sy = g.h / skin.h };
    var clicked: ?usize = null;
    for (skin.objects) |*o| switch (o.kind) {
        .songlist => if (o.songlist) |list| {
            clicked = drawBars(&r, list, bars) orelse clicked;
        },
        .notes, .bga, .judge => {},
        .notes_graph => if (r.visible(o)) |k| drawNotesGraph(g, st, screenRect(&r, k), 0),
        .bpm_graph => if (r.visible(o)) |k| drawBpmGraph(g, st, screenRect(&r, k)),
        .stagefile => if (r.visible(o)) |k| drawStagefile(g, st.stagefile, screenRect(&r, k), k.a),
        .backbmp => if (r.visible(o)) |k| drawStagefile(g, st.backbmp, screenRect(&r, k), k.a),
        .banner => if (r.visible(o)) |k| drawStagefile(g, st.banner, screenRect(&r, k), k.a),
        else => r.drawObject(o),
    };
    return clicked;
}

test "a bar's row wraps around the list, the center showing the cursor" {
    try std.testing.expectEqual(@as(usize, 3), barRow(3, 8, 8, 5));
    try std.testing.expectEqual(@as(usize, 4), barRow(0, 7, 8, 5));
    try std.testing.expectEqual(@as(usize, 0), barRow(4, 9, 8, 5));
}

test "a short text list falls back on its first entry" {
    try std.testing.expectEqual(@as(usize, 4), barTextIndex(.folder, 11));
    try std.testing.expectEqual(@as(usize, 0), barTextIndex(.folder, 2));
}

/// Static scene (result): draws all objects against a frozen state.
pub fn drawStatic(g: *gfx.Gfx, skin: *m.Skin, st: *State, now_ms: i64) void {
    const ctx = st.ctx(skin, now_ms);
    skin_mod.setLuaCtx(&ctx);
    defer skin_mod.setLuaCtx(null);
    const r: m.Renderer = .{ .g = g, .s = skin, .ctx = &ctx, .sx = g.w / skin.w, .sy = g.h / skin.h };
    for (skin.objects) |*o| r.drawObject(o);
}

test "hits fold into the bin of their note, once each" {
    var st: State = .{ .graph_end_us = 10_000_000 };
    const notes = [_]core.types.Note{
        .{ .time_us = 1_000_000, .y = 0, .wav = -1, .lane = 0, .kind = .normal },
        .{ .time_us = 9_000_000, .y = 0, .wav = -1, .lane = 0, .kind = .mine },
    };
    st.notes = &notes;
    var snap: Snapshot = .{};
    snap.hits[0] = .{ .note = 0, .judge = 2 };
    snap.hits[1] = .{ .note = 1, .judge = 4 };
    snap.hit_seq = 2;
    st.foldHits(&snap);
    st.foldHits(&snap);
    try std.testing.expectEqual(@as(u16, 1), st.graph_judged[st.binOf(1_000_000)][2]);
    try std.testing.expectEqual(@as(u16, 0), st.graph_judged[st.binOf(9_000_000)][4]);
}

test "song select tells the skin about the IR" {
    var st: State = .{ .select = .{} };
    try std.testing.expect(State.opt(&st, 50));
    try std.testing.expect(!State.opt(&st, 51));
    var b: ir.Board = .{ .gpa = std.testing.allocator, .total = 7 };
    b.state.store(ir.Board.accepted, .release);
    st.ir_board = &b;
    try std.testing.expect(State.opt(&st, 51));
    try std.testing.expect(!State.opt(&st, 50));
    try std.testing.expect(State.opt(&st, 602));
    try std.testing.expectEqual(@as(?i64, 7), State.num(&st, 200));
    try std.testing.expectEqualStrings("Actuon IR", State.str(&st, 1020));
}

test "song select tells the skin its panel and options" {
    var st: State = .{ .select = .{ .panel = 2, .random_index = 3, .autoshift_index = 4 } };
    try std.testing.expect(State.opt(&st, 22));
    st.select.?.replays = 2;
    st.select.?.replay_slot = 1;
    try std.testing.expect(State.opt(&st, 1197));
    try std.testing.expect(State.opt(&st, 1199));
    try std.testing.expect(State.opt(&st, 1206));
    try std.testing.expect(!State.opt(&st, 20));
    try std.testing.expect(!State.opt(&st, 21));
    try std.testing.expectEqual(@as(?i64, 3), State.num(&st, m.button_index + 42));
    try std.testing.expectEqual(@as(?i64, 4), State.num(&st, m.button_index + 78));
    st.select.?.sort_index = 5;
    st.select.?.mode_index = 2;
    try std.testing.expectEqual(@as(?i64, 5), State.num(&st, m.button_index + 12));
    try std.testing.expectEqual(@as(?i64, 2), State.num(&st, m.button_index + 11));
}

test "rank index follows ninths" {
    try std.testing.expectEqual(@as(i32, 0), State.rankIndex(0.9));
    try std.testing.expectEqual(@as(i32, 1), State.rankIndex(0.8));
    try std.testing.expectEqual(@as(i32, 7), State.rankIndex(0.0));
}
