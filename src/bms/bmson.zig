//! Follows jbms-parser's BMSONDecoder.
const std = @import("std");
const types = @import("../core/types.zig");
const hash = @import("hash.zig");
const validBpm = @import("parser.zig").validBpm;
const nodeBelow = @import("parser.zig").nodeBelow;
const Chart = types.Chart;
const Mode = types.Mode;

const JNote = struct { x: i64 = 0, y: i64 = 0, l: i64 = 0, c: bool = false, t: i64 = 0, up: bool = false };
const JMine = struct { x: i64 = 0, y: i64 = 0, damage: f64 = 0 };
const JSound = struct { name: []const u8 = "", notes: []JNote = &.{} };
const JMineCh = struct { name: []const u8 = "", notes: []JMine = &.{} };
const JBpm = struct { y: i64 = 0, bpm: f64 = 0 };
const JStop = struct { y: i64 = 0, duration: i64 = 0 };
const JScroll = struct { y: i64 = 0, rate: f64 = 1 };
const JLine = struct { y: i64 = 0 };
const JBgaHeader = struct { id: i64 = 0, name: []const u8 = "" };
const JBgaEvent = struct { y: i64 = 0, id: i64 = 0 };
const JBga = struct {
    bga_header: []JBgaHeader = &.{},
    bga_events: []JBgaEvent = &.{},
    layer_events: []JBgaEvent = &.{},
    poor_events: []JBgaEvent = &.{},
};
const JInfo = struct {
    title: []const u8 = "",
    subtitle: []const u8 = "",
    artist: []const u8 = "",
    subartists: []const []const u8 = &.{},
    genre: []const u8 = "",
    mode_hint: []const u8 = "beat-7k",
    chart_name: []const u8 = "",
    level: i64 = 0,
    init_bpm: f64 = 0,
    judge_rank: f64 = 100,
    total: f64 = 100,
    back_image: []const u8 = "",
    eyecatch_image: []const u8 = "",
    banner_image: []const u8 = "",
    preview_music: []const u8 = "",
    resolution: i64 = 240,
    ln_type: i64 = 0,
};
const JRoot = struct {
    info: JInfo = .{},
    lines: []JLine = &.{},
    bpm_events: []JBpm = &.{},
    stop_events: []JStop = &.{},
    scroll_events: []JScroll = &.{},
    sound_channels: []JSound = &.{},
    key_channels: []JMineCh = &.{},
    mine_channels: []JMineCh = &.{},
    bga: JBga = .{},
};

const Tl = struct { y: i64, time: f64, micro: i64, bpm: f64, stop: i64 = 0, scroll: f64 = 1, bar: bool = false };

const Timelines = struct {
    gpa: std.mem.Allocator,
    res: f64,
    items: std.ArrayList(*Tl) = .empty,

    fn lower(self: *const Timelines, y: i64) usize {
        var lo: usize = 0;
        var hi: usize = self.items.items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (self.items.items[mid].y < y) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn get(self: *Timelines, y: i64) !*Tl {
        const i = self.lower(y);
        if (i < self.items.items.len and self.items.items[i].y == y) return self.items.items[i];
        if (i == 0) return self.items.items[0]; // negative y in hostile input
        const lo = self.items.items[i - 1];
        const stop_part: f64 = @floatFromInt(lo.stop);
        const dy: f64 = @floatFromInt(y - lo.y);
        const time = lo.time + stop_part + (240000.0 * 1000.0 * (dy / self.res)) / lo.bpm;
        const tl = try self.gpa.create(Tl);
        tl.* = .{ .y = y, .time = time, .micro = micro(time), .bpm = lo.bpm, .scroll = lo.scroll };
        try self.items.insert(self.gpa, i, tl);
        return tl;
    }

    /// One `get` per y would take minutes on a hostile file of reversed positions.
    fn addAll(self: *Timelines, ys: []i64) !void {
        std.mem.sort(i64, ys, {}, std.sort.asc(i64));
        const old = self.items.items;
        var merged: std.ArrayList(*Tl) = try .initCapacity(self.gpa, old.len + ys.len);
        // The first point is y 0, below every point `get` makes.
        merged.appendAssumeCapacity(old[0]);
        var i: usize = 1;
        for (ys) |y| {
            while (i < old.len and old[i].y <= y) : (i += 1) merged.appendAssumeCapacity(old[i]);
            const lo = merged.items[merged.items.len - 1];
            // Negative y has no point of its own, as in `get`; duplicates land on the point already there.
            if (lo.y >= y) continue;
            const stop_part: f64 = @floatFromInt(lo.stop);
            const dy: f64 = @floatFromInt(y - lo.y);
            const time = lo.time + stop_part + (240000.0 * 1000.0 * (dy / self.res)) / lo.bpm;
            const tl = try self.gpa.create(Tl);
            tl.* = .{ .y = y, .time = time, .micro = micro(time), .bpm = lo.bpm, .scroll = lo.scroll };
            merged.appendAssumeCapacity(tl);
        }
        merged.appendSliceAssumeCapacity(old[i..]);
        self.items = merged;
    }
};

fn micro(t: f64) i64 {
    if (!(t < 9.0e18 and t > -9.0e18)) return 0;
    return @intFromFloat(t);
}

const Placed = struct { y: i64, lane: u8, note: types.Note };

/// Real charts, keysounds included, hold a few ten thousand.
const max_notes = 1 << 18;

// Every placed y on a lane, an LN start carrying its end; nothing else lands inside an LN, so only the y just below can hold another.
const Taken = struct {
    tree: Tree = .{},

    const Mark = struct { y: i64, end: i64 };
    const Tree = std.Treap(Mark, byY);

    fn byY(l: Mark, r: Mark) std.math.Order {
        return std.math.order(l.y, r.y);
    }

    fn below(t: *Taken, y: i64) ?*Tree.Node {
        return nodeBelow(byY, &t.tree, Mark{ .y = y, .end = y });
    }

    fn holds(t: *Taken, y: i64) bool {
        const node = t.below(y) orelse return false;
        return y <= node.key.end;
    }

    fn add(t: *Taken, a: std.mem.Allocator, y: i64, end: i64) !void {
        var e = t.tree.getEntryFor(.{ .y = y, .end = end });
        e.set(try a.create(Tree.Node));
    }
};

pub fn parse(gpa: std.mem.Allocator, data: []const u8) !Chart {
    var chart: Chart = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer chart.arena.deinit();
    const a = chart.arena.allocator();
    hash.fill(&chart, data);
    const root = try std.json.parseFromSliceLeaky(JRoot, a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    const info = root.info;
    var note_count: usize = 0;
    for (root.sound_channels) |sc| note_count += sc.notes.len;
    for ([_][]const JMineCh{ root.key_channels, root.mine_channels }) |chs| for (chs) |ch| {
        note_count += ch.notes.len;
    };
    if (note_count > max_notes) return error.TooBig;

    chart.title = info.title;
    chart.subtitle = if (info.chart_name.len > 0)
        (if (info.subtitle.len > 0) try std.fmt.allocPrint(a, "{s} [{s}]", .{ info.subtitle, info.chart_name }) else try std.fmt.allocPrint(a, "[{s}]", .{info.chart_name}))
    else
        info.subtitle;
    chart.artist = info.artist;
    chart.subartist = try std.mem.join(a, ",", info.subartists);
    chart.genre = info.genre;
    chart.playlevel = try std.fmt.allocPrint(a, "{d}", .{info.level});
    chart.banner = info.banner_image;
    chart.backbmp = info.back_image;
    chart.stagefile = info.eyecatch_image;
    chart.preview = info.preview_music;
    chart.bpm = info.init_bpm;
    if (!validBpm(info.init_bpm)) return error.NoBpm;

    const rank = info.judge_rank;
    if (rank >= 0 and rank < 5) {
        chart.judgerank = ([5]i32{ 25, 50, 75, 100, 75 })[@intFromFloat(rank)];
    } else if (rank >= 5 and rank < 100000) {
        chart.judgerank = @intFromFloat(rank);
    } else chart.judgerank = 100;

    chart.mode = if (std.mem.eql(u8, info.mode_hint, "beat-5k"))
        .beat5
    else if (std.mem.eql(u8, info.mode_hint, "beat-10k"))
        .beat10
    else if (std.mem.eql(u8, info.mode_hint, "beat-14k"))
        .beat14
    else if (std.mem.eql(u8, info.mode_hint, "popn-9k"))
        .popn9
    else
        .beat7;
    chart.is_pms = chart.mode == .popn9;
    const keys = chart.mode.keys();
    const lnmode: types.LnType = switch (info.ln_type) {
        2 => .cn,
        3 => .hcn,
        else => .ln,
    };

    const res: f64 = if (info.resolution > 0) @as(f64, @floatFromInt(info.resolution)) * 4 else 960;
    const base = try a.create(Tl);
    base.* = .{ .y = 0, .time = 0, .micro = 0, .bpm = chart.bpm };
    var tls: Timelines = .{ .gpa = a, .res = res };
    try tls.items.append(a, base);

    const ByY = struct {
        fn bpm(_: void, l: JBpm, r: JBpm) bool {
            return l.y < r.y;
        }
        fn stop(_: void, l: JStop, r: JStop) bool {
            return l.y < r.y;
        }
        fn scroll(_: void, l: JScroll, r: JScroll) bool {
            return l.y < r.y;
        }
        fn note(_: void, l: JNote, r: JNote) bool {
            return l.y < r.y;
        }
    };
    std.mem.sort(JBpm, root.bpm_events, {}, ByY.bpm);
    std.mem.sort(JStop, root.stop_events, {}, ByY.stop);
    std.mem.sort(JScroll, root.scroll_events, {}, ByY.scroll);
    var ib: usize = 0;
    var ist: usize = 0;
    var isc: usize = 0;
    const max = std.math.maxInt(i64);
    while (ib < root.bpm_events.len or ist < root.stop_events.len or isc < root.scroll_events.len) {
        const by = if (ib < root.bpm_events.len) root.bpm_events[ib].y else max;
        const sty = if (ist < root.stop_events.len) root.stop_events[ist].y else max;
        const scy = if (isc < root.scroll_events.len) root.scroll_events[isc].y else max;
        if (scy <= sty and scy <= by) {
            (try tls.get(scy)).scroll = root.scroll_events[isc].rate;
            isc += 1;
        } else if (by <= sty) {
            if (validBpm(root.bpm_events[ib].bpm)) (try tls.get(by)).bpm = root.bpm_events[ib].bpm;
            ib += 1;
        } else {
            const dur = root.stop_events[ist].duration;
            if (dur >= 0) {
                const tl = try tls.get(sty);
                tl.stop = micro((1000.0 * 1000.0 * 60.0 * 4.0 * @as(f64, @floatFromInt(dur))) / (tl.bpm * res));
                chart.has_stop = true;
            }
            ist += 1;
        }
    }
    {
        var ys: std.ArrayList(i64) = .empty;
        for (root.lines) |l| try ys.append(a, l.y);
        for (root.sound_channels) |sc| for (sc.notes) |n| {
            const end = std.math.add(i64, n.y, n.l) catch continue;
            try ys.appendSlice(a, &.{ n.y, end });
        };
        for ([_][]const JMineCh{ root.key_channels, root.mine_channels }) |chs| for (chs) |ch| for (ch.notes) |n| try ys.append(a, n.y);
        for ([_][]const JBgaEvent{ root.bga.bga_events, root.bga.layer_events, root.bga.poor_events }) |evs| for (evs) |ev| try ys.append(a, ev.y);
        try tls.addAll(ys.items);
    }
    for (root.lines) |l| (try tls.get(l.y)).bar = true;

    const assign: []const i8 = switch (chart.mode) {
        .beat5 => &[_]i8{ 0, 1, 2, 3, 4, -1, -1, 5 },
        .beat10 => &[_]i8{ 0, 1, 2, 3, 4, -1, -1, 5, 6, 7, 8, 9, 10, -1, -1, 11 },
        else => &[_]i8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    };
    const laneOf = struct {
        fn f(x: i64, table: []const i8, k: u8) i8 {
            if (x <= 0 or x > table.len) return -1;
            const v = table[@intCast(x - 1)];
            return if (v >= k) -1 else v;
        }
    }.f;

    var wavs: std.ArrayList([]const u8) = .empty;
    var bg: std.ArrayList(types.BgSound) = .empty;
    var hidden: std.ArrayList(types.Hidden) = .empty;
    var taken: [types.max_lanes]Taken = @splat(.{});
    var placed: std.ArrayList(Placed) = .empty;
    // first note at (lane, y) wins, as with TimeLine.setNote guards
    var occupied: std.AutoHashMapUnmanaged(u128, void) = .empty;
    const occKey = struct {
        fn f(lane: u8, y: i64) u128 {
            return (@as(u128, lane) << 64) | @as(u64, @bitCast(y));
        }
    }.f;
    var ups: std.AutoHashMapUnmanaged(u128, struct { wav: i32, start: i64, dur: i64 }) = .empty;

    var id: i32 = 0;
    for (root.sound_channels) |*sc| {
        try wavs.append(a, sc.name);
        std.mem.sort(JNote, sc.notes, {}, ByY.note);
        var start_time: i64 = 0;
        var later: usize = 0;
        for (sc.notes) |n| {
            _ = std.math.add(i64, n.y, n.l) catch continue;
            while (later < sc.notes.len and sc.notes[later].y <= n.y) later += 1;
            const next: ?JNote = if (later < sc.notes.len) sc.notes[later] else null;
            if (!n.c) start_time = 0;
            const tl = try tls.get(n.y);
            var dur: i64 = 0;
            if (next) |m| if (m.c) {
                // saturate: hostile y/bpm push micro near i64 limits, and offsets add up per note
                dur = (try tls.get(m.y)).micro -| tl.micro;
            };
            const key = laneOf(n.x, assign, keys);
            if (key < 0) {
                try bg.append(a, .{ .time_us = tl.micro, .wav = id, .wav_start_us = start_time, .wav_dur_us = dur });
            } else {
                const lane: u8 = @intCast(key);
                if (n.up) {
                    try ups.put(a, occKey(lane, n.y), .{ .wav = id, .start = start_time, .dur = dur });
                } else {
                    if (taken[lane].holds(n.y)) {
                        try bg.append(a, .{ .time_us = tl.micro, .wav = id, .wav_start_us = start_time, .wav_dur_us = dur });
                    } else if (n.l > 0) {
                        const end = try tls.get(n.y + n.l);
                        if (!occupied.contains(occKey(lane, n.y))) {
                            // Nothing sits at n.y itself, as every y in taken is also in occupied.
                            const above = if (taken[lane].below(n.y)) |b| b.next() else taken[lane].tree.getMin();
                            if (above != null and above.?.key.y <= n.y + n.l) {
                                try bg.append(a, .{ .time_us = tl.micro, .wav = id, .wav_start_us = start_time, .wav_dur_us = dur });
                            } else {
                                const ty: types.LnType = switch (n.t) {
                                    1 => .ln,
                                    2 => .cn,
                                    3 => .hcn,
                                    else => lnmode,
                                };
                                const ln_open = n.t == 0 and info.ln_type == 0;
                                try occupied.put(a, occKey(lane, n.y), {});
                                try occupied.put(a, occKey(lane, n.y + n.l), {});
                                try placed.append(a, .{ .y = n.y, .lane = lane, .note = .{ .time_us = tl.micro, .y = 0, .wav = id, .lane = lane, .kind = .ln_start, .ln_type = ty, .ln_open = ln_open, .wav_start_us = start_time, .wav_dur_us = dur } });
                                try placed.append(a, .{ .y = n.y + n.l, .lane = lane, .note = .{ .time_us = end.micro, .y = 0, .wav = -2, .lane = lane, .kind = .ln_end, .ln_type = ty, .ln_open = ln_open } });
                                try taken[lane].add(a, n.y, n.y + n.l);
                                try taken[lane].add(a, n.y + n.l, n.y + n.l);
                                chart.has_ln = true;
                            }
                        }
                    } else if (occupied.contains(occKey(lane, n.y))) {
                        try bg.append(a, .{ .time_us = tl.micro, .wav = id, .wav_start_us = start_time, .wav_dur_us = dur });
                    } else {
                        try occupied.put(a, occKey(lane, n.y), {});
                        try taken[lane].add(a, n.y, n.y);
                        try placed.append(a, .{ .y = n.y, .lane = lane, .note = .{ .time_us = tl.micro, .y = 0, .wav = id, .lane = lane, .kind = .normal, .wav_start_us = start_time, .wav_dur_us = dur } });
                    }
                }
            }
            start_time +|= dur;
        }
        id += 1;
    }
    for (root.key_channels) |*sc| {
        try wavs.append(a, sc.name);
        for (sc.notes) |n| {
            const key = laneOf(n.x, assign, keys);
            if (key >= 0) try hidden.append(a, .{ .time_us = (try tls.get(n.y)).micro, .wav = id, .lane = @intCast(key) });
        }
        id += 1;
    }
    for (root.mine_channels) |*sc| {
        try wavs.append(a, sc.name);
        for (sc.notes) |n| {
            const key = laneOf(n.x, assign, keys);
            if (key < 0) continue;
            const lane: u8 = @intCast(key);
            const tl = try tls.get(n.y);
            if (!taken[lane].holds(n.y) and !occupied.contains(occKey(lane, n.y))) {
                try occupied.put(a, occKey(lane, n.y), {});
                try placed.append(a, .{ .y = n.y, .lane = lane, .note = .{ .time_us = tl.micro, .y = 0, .wav = id, .lane = lane, .kind = .mine, .damage = @floatCast(n.damage) } });
                chart.has_mine = true;
            }
        }
        id += 1;
    }
    chart.wavs = try wavs.toOwnedSlice(a);

    var bmps: std.ArrayList([]const u8) = .empty;
    var bga_ids: std.AutoHashMapUnmanaged(i64, i32) = .empty;
    for (root.bga.bga_header, 0..) |h, i| {
        try bmps.append(a, h.name);
        try bga_ids.put(a, h.id, @intCast(i));
    }
    chart.bmps = try bmps.toOwnedSlice(a);
    var bga: std.ArrayList(types.BgaEvent) = .empty;
    for ([_]struct { e: []JBgaEvent, l: types.BgaLayer }{
        .{ .e = root.bga.bga_events, .l = .base },
        .{ .e = root.bga.layer_events, .l = .layer },
        .{ .e = root.bga.poor_events, .l = .poor },
    }) |group| {
        for (group.e) |ev| {
            try bga.append(a, .{ .time_us = (try tls.get(ev.y)).micro, .id = bga_ids.get(ev.id) orelse -1, .layer = group.l });
        }
    }

    const items = tls.items.items;
    const timelines = try a.alloc(types.Timeline, items.len);
    var ypos: f64 = 0;
    var min_bpm = chart.bpm;
    var max_bpm = chart.bpm;
    var ymap: std.AutoHashMapUnmanaged(i64, f64) = .empty;
    for (items, 0..) |tl, i| {
        if (i > 0) ypos += @as(f64, @floatFromInt(tl.y - items[i - 1].y)) / res * items[i - 1].scroll;
        timelines[i] = .{ .time_us = tl.micro, .y = ypos, .section = @as(f64, @floatFromInt(tl.y)) / res, .bpm = tl.bpm, .stop_us = tl.stop, .scroll = tl.scroll, .speed = 1, .bar = tl.bar };
        min_bpm = @min(min_bpm, tl.bpm);
        max_bpm = @max(max_bpm, tl.bpm);
        try ymap.put(a, tl.y, ypos);
    }
    chart.timelines = timelines;
    chart.min_bpm = min_bpm;
    chart.max_bpm = max_bpm;

    const items_placed = placed.items;
    std.mem.sort(Placed, items_placed, {}, struct {
        fn lt(_: void, l: Placed, r: Placed) bool {
            return if (l.y != r.y) l.y < r.y else l.lane < r.lane;
        }
    }.lt);
    const notes = try a.alloc(types.Note, items_placed.len);
    var open: [types.max_lanes]i32 = @splat(-1);
    var total: u32 = 0;
    for (items_placed, 0..) |p, i| {
        notes[i] = p.note;
        notes[i].y = ymap.get(p.y) orelse 0;
        switch (p.note.kind) {
            .ln_start => {
                open[p.lane] = @intCast(i);
                total += 1;
            },
            .ln_end => {
                if (open[p.lane] >= 0) {
                    notes[i].pair = open[p.lane];
                    notes[@intCast(open[p.lane])].pair = @intCast(i);
                    open[p.lane] = -1;
                }
                if (p.note.ln_type != .ln) total += 1;
                if (ups.get(occKey(p.lane, p.y))) |u| {
                    notes[i].wav = u.wav;
                    notes[i].wav_start_us = u.start;
                    notes[i].wav_dur_us = u.dur;
                }
            },
            .normal => total += 1,
            .mine => {},
        }
    }
    chart.notes = notes;
    chart.total_notes = total;
    // BMSON total is a percentage of the default gauge rate.
    const def = types.defaultTotal(total);
    chart.total = if (info.total > 0) info.total / 100.0 * def else def;
    chart.total_defined = true;

    std.mem.sort(types.BgSound, bg.items, {}, struct {
        fn lt(_: void, l: types.BgSound, r: types.BgSound) bool {
            return l.time_us < r.time_us;
        }
    }.lt);
    std.mem.sort(types.Hidden, hidden.items, {}, struct {
        fn lt(_: void, l: types.Hidden, r: types.Hidden) bool {
            return l.time_us < r.time_us;
        }
    }.lt);
    std.mem.sort(types.BgaEvent, bga.items, {}, struct {
        fn lt(_: void, l: types.BgaEvent, r: types.BgaEvent) bool {
            return l.time_us < r.time_us;
        }
    }.lt);
    chart.bg = bg.items;
    chart.hidden = hidden.items;
    chart.bga = bga.items;
    var last: i64 = 0;
    if (notes.len > 0) {
        chart.last_note_us = notes[notes.len - 1].time_us;
        last = chart.last_note_us;
    }
    if (bg.items.len > 0) last = @max(last, bg.items[bg.items.len - 1].time_us);
    if (hidden.items.len > 0) last = @max(last, hidden.items[hidden.items.len - 1].time_us);
    if (bga.items.len > 0) last = @max(last, bga.items[bga.items.len - 1].time_us);
    chart.last_time_us = last;
    return chart;
}

test "numbers past what timing can hold are refused or skipped" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NoBpm, parse(a,
        \\{"info":{"init_bpm":1e300,"resolution":240,"mode_hint":"beat-7k"}}
    ));
    var c = try parse(a,
        \\{"info":{"init_bpm":120,"resolution":240,"mode_hint":"beat-7k"},
        \\ "bpm_events":[{"y":240,"bpm":1e300}],
        \\ "sound_channels":[{"name":"a.wav","notes":[{"x":1,"y":9223372036854775807,"l":1},{"x":2,"y":0,"l":0}]}]}
    );
    defer c.deinit();
    try std.testing.expectEqual(@as(u32, 1), c.total_notes);
    try std.testing.expectEqual(@as(f64, 120), c.max_bpm);
}

test "a crowded lane parses, and more notes than a chart could play are refused" {
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "{\"info\":{\"init_bpm\":120,\"resolution\":240},\"sound_channels\":[");
    // One channel per note with y descending: each lands below every note already on the lane.
    const lane_notes = 40_000;
    for (0..lane_notes) |i| try src.print(gpa, "{{\"name\":\"a\",\"notes\":[{{\"x\":1,\"y\":{d}}}]}},", .{(lane_notes - i) * 10});
    try src.appendSlice(gpa, "{\"name\":\"a\",\"notes\":[{\"x\":1,\"y\":5,\"l\":10},{\"x\":1,\"y\":12}]}]}");
    var c = try parse(gpa, src.items);
    defer c.deinit();
    // The LN at 5 would cover the note at 10, so it sounds as background; the note at 12 is free.
    try std.testing.expectEqual(@as(u32, lane_notes + 1), c.total_notes);
    try std.testing.expect(!c.has_ln);

    src.clearRetainingCapacity();
    try src.appendSlice(gpa, "{\"info\":{\"init_bpm\":120,\"resolution\":240},\"sound_channels\":[{\"name\":\"a\",\"notes\":[");
    for (0..max_notes) |_| try src.appendSlice(gpa, "{},");
    try src.appendSlice(gpa, "{}]}]}");
    try std.testing.expectError(error.TooBig, parse(gpa, src.items));
}

test "a note inside a placed LN sounds as background, one just past it is placed" {
    var c = try parse(std.testing.allocator,
        \\{"info":{"init_bpm":120,"resolution":240},"sound_channels":[
        \\ {"name":"a","notes":[{"x":1,"y":0,"l":100}]},
        \\ {"name":"b","notes":[{"x":1,"y":50},{"x":1,"y":100},{"x":1,"y":101,"l":20}]},
        \\ {"name":"c","notes":[{"x":1,"y":110}]}],
        \\ "mine_channels":[{"name":"m","notes":[{"x":1,"y":60},{"x":1,"y":130}]}]}
    );
    defer c.deinit();
    // LN 0-100 and LN 101-121 hold 50, 100 (its end) and 110; the mine at 130 is past both.
    try std.testing.expectEqual(@as(usize, 5), c.notes.len);
    try std.testing.expectEqual(@as(usize, 3), c.bg.len);
    try std.testing.expectEqual(types.NoteKind.mine, c.notes[4].kind);
}

test "keysound offsets past i64 saturate instead of overflowing" {
    var c = try parse(std.testing.allocator,
        \\{"info":{"init_bpm":0.001,"resolution":240},"sound_channels":[{"name":"a","notes":[{"x":0,"y":0},{"x":0,"y":0,"c":true},{"x":0,"y":32000000000,"c":true}]}]}
    );
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 3), c.bg.len);
}

test "points given in any order land at their own times" {
    var c = try parse(std.testing.allocator,
        \\{"info":{"init_bpm":120,"resolution":240},"lines":[{"y":1920},{"y":960},{"y":-5},{"y":960}],
        \\ "bpm_events":[{"y":960,"bpm":240}],
        \\ "sound_channels":[{"name":"a","notes":[{"x":1,"y":1920},{"x":2,"y":480,"l":960}]}]}
    );
    defer c.deinit();
    var bars: usize = 0;
    for (c.timelines, 1..) |tl, i| {
        if (tl.bar) bars += 1;
        if (i < c.timelines.len) try std.testing.expect(tl.y <= c.timelines[i].y);
    }
    try std.testing.expectEqual(@as(usize, 3), bars);
    // 120 BPM for a measure (2 s), then 240 BPM for the next (1 s).
    try std.testing.expectEqual(@as(i64, 3_000_000), c.notes[c.notes.len - 1].time_us);
}

test "bmson basic" {
    const src =
        \\{"version":"1.0.0","info":{"title":"t","init_bpm":120,"resolution":240,"mode_hint":"beat-7k","judge_rank":100,"total":100},
        \\ "sound_channels":[{"name":"a.wav","notes":[{"x":1,"y":0,"l":0,"c":false},{"x":2,"y":240,"l":240,"c":false},{"x":0,"y":0,"l":0,"c":false}]}]}
    ;
    var c = try parse(std.testing.allocator, src);
    defer c.deinit();
    try std.testing.expectEqual(@as(u32, 2), c.total_notes);
    try std.testing.expectEqual(@as(usize, 1), c.bg.len);
    try std.testing.expectEqual(@as(i64, 500_000), c.notes[1].time_us);
    try std.testing.expect(c.has_ln);
}
