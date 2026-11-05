//! BMS decoder matching jbms-parser, as built into lr2oraja-endlessdream (GPLv3); docs/spec.md lists differences.
const std = @import("std");
const types = @import("../core/types.zig");
const encoding = @import("encoding.zig");
const hash = @import("hash.zig");
const options = @import("../core/options.zig");
const Chart = types.Chart;
const Mode = types.Mode;
const Note = types.Note;

pub const Options = struct {
    is_pms: bool = false,
    /// Fixed #RANDOM results (replay/seek). Missing entries fall back to `seed`.
    selected_random: ?[]const i32 = null,
    seed: u64 = 0,
};

pub const Error = error{ NoBpm, BadRandom, TooBig, OutOfMemory };

const P1_KEY = 37;
const P2_KEY = 73;
const P1_INV = 109;
const P2_INV = 145;
const P1_LONG = 181;
const P2_LONG = 217;
const P1_MINE = 469;
const P2_MINE = 505;
const CH_SCROLL = 1020;
const CH_SPEED = 1033;

const assign_beat5 = [18]i8{ 0, 1, 2, 3, 4, 5, -1, -1, -1, 6, 7, 8, 9, 10, 11, -1, -1, -1 };
const assign_beat7 = [18]i8{ 0, 1, 2, 3, 4, 7, -1, 5, 6, 8, 9, 10, 11, 12, 15, -1, 13, 14 };
/// Qwilight's BMSCompiler.GetBMSInput: 4K is 11 12 14 15, 6K is 11 12 13 15 18 19, anything else is dropped.
const assign_beat4 = [18]i8{ 0, 1, -1, 2, 3, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
const assign_beat6 = [18]i8{ 0, 1, 2, -1, 3, -1, -1, 4, 5, -1, -1, -1, -1, -1, -1, -1, -1, -1 };
const assign_popn = [18]i8{ 0, 1, 2, 3, 4, -1, -1, -1, -1, -1, 5, 6, 7, 8, -1, -1, -1, -1 };

const Ln = struct {
    wav: i32,
    section: f64 = 0,
    orphan: bool = false,
    end: bool = false,
    pair: ?*Ln = null,
    ln_type: u8 = 0,
    index: i32 = -1,
};

const Slot = union(enum) {
    none,
    normal: i32,
    long: *Ln,
    mine: struct { wav: i32, damage: f32 },
};

const Tl = struct {
    section: f64,
    time: f64,
    micro: i64,
    bpm: f64,
    stop: i64 = 0,
    scroll: f64 = 1,
    speed: f64 = 1,
    bar: bool = false,
    node: Tree.Node = undefined,

    fn of(node: *Tree.Node) *Tl {
        return @fieldParentPtr("node", node);
    }

    fn prev(tl: *Tl) ?*Tl {
        return of(tl.node.prev() orelse return null);
    }
};

const Held = struct {
    node: Tree.Node = undefined,
    tl: *Tl,
    slot: Slot,

    fn of(node: *Tree.Node) *Held {
        return @fieldParentPtr("node", node);
    }
};

const Tree = std.Treap(f64, std.math.order);

// `order` must be the one the treap was built with, as std.Treap keeps its own private.
pub fn nodeBelow(comptime order: anytype, tree: anytype, key: anytype) ?*@TypeOf(tree.*).Node {
    const entry = tree.getEntryFor(key);
    if (entry.node) |node| return node.prev();
    const parent = entry.context.inserted_under orelse return null;
    return if (order(parent.key, key) == .lt) parent else parent.prev();
}

fn nodeAtOrBelow(tree: *Tree, section: f64) ?*Tree.Node {
    return tree.getEntryFor(section).node orelse nodeBelow(std.math.order, tree, section);
}

const Timelines = struct {
    arena: *std.heap.ArenaAllocator,
    // Lines of one measure may give their points in any order, so points go in a tree, not a shifted list.
    tree: Tree = .{},
    len: usize = 0,
    // Most points hold a note on one lane or none, so each lane keeps a tree of only the points that do.
    lanes: [types.max_lanes]Tree = @splat(.{}),

    /// Real charts stay under 192k points and a note or two on each, about 30 MiB; past this one is hostile.
    const max_bytes = 96 << 20;

    fn add(self: *Timelines, tl: *Tl) void {
        var entry = self.tree.getEntryFor(tl.section);
        entry.set(&tl.node);
        self.len += 1;
    }

    fn slot(self: *Timelines, tl: *Tl, lane: usize) Slot {
        const node = self.lanes[lane].getEntryFor(tl.section).node orelse return .none;
        return Held.of(node).slot;
    }

    fn heldBelow(self: *Timelines, tl: *Tl, lane: usize) ?*Held {
        return Held.of(nodeBelow(std.math.order, &self.lanes[lane], tl.section) orelse return null);
    }

    fn setSlot(self: *Timelines, tl: *Tl, lane: usize, s: Slot) !void {
        var entry = self.lanes[lane].getEntryFor(tl.section);
        if (entry.node) |node| {
            if (s == .none) entry.set(null) else Held.of(node).slot = s;
            return;
        }
        if (s == .none) return;
        const held = try self.arena.allocator().create(Held);
        held.* = .{ .tl = tl, .slot = s };
        entry.set(&held.node);
    }

    fn get(self: *Timelines, section: f64) !*Tl {
        // Every note, LN, span and sound starts by getting its point, so this one check bounds all the arena holds.
        if (self.arena.queryCapacity() >= max_bytes) return error.TooBig;
        if (self.tree.getEntryFor(section).node) |node| return Tl.of(node);
        // The point at section 0 comes first, so a new point always has one below it.
        const lower = Tl.of(nodeBelow(std.math.order, &self.tree, section).?);
        const stop_part: f64 = @floatFromInt(lower.stop);
        const time = lower.time + stop_part + (240000.0 * 1000.0 * (section - lower.section)) / lower.bpm;
        const tl = try self.arena.allocator().create(Tl);
        tl.* = .{
            .section = section,
            .time = time,
            .micro = truncMicro(time),
            .bpm = lower.bpm,
            .scroll = lower.scroll,
            .speed = lower.speed,
        };
        self.add(tl);
        return tl;
    }
};

pub fn truncMicro(t: f64) i64 {
    if (!(t < 9.0e18 and t > -9.0e18)) return 0; // hostile #STOP/#BPM values must not trap
    return @intFromFloat(t);
}

fn int36(a: u8, b: u8) i32 {
    const d = struct {
        fn f(c: u8) i32 {
            return switch (c) {
                '0'...'9' => c - '0',
                'a'...'z' => c - 'a' + 10,
                'A'...'Z' => c - 'A' + 10,
                else => -1,
            };
        }
    }.f;
    const x = d(a);
    const y = d(b);
    if (x < 0 or y < 0) return -1;
    return x * 36 + y;
}

fn int62(a: u8, b: u8) i32 {
    const d = struct {
        fn f(c: u8) i32 {
            return switch (c) {
                '0'...'9' => c - '0',
                'A'...'Z' => c - 'A' + 10,
                'a'...'z' => c - 'a' + 36,
                else => -1,
            };
        }
    }.f;
    const x = d(a);
    const y = d(b);
    if (x < 0 or y < 0) return -1;
    return x * 62 + y;
}

fn digit62(v: i32) u8 {
    return if (v < 10) @intCast('0' + v) else if (v < 36) @intCast('A' + v - 10) else @intCast('a' + v - 36);
}

/// Base-62 charts still store hex/mine data as written; re-read those digits as base 36.
fn rebase36(data: i32) i32 {
    return int36(digit62(@divTrunc(data, 62)), digit62(@rem(data, 62)));
}

fn reserve(line: []const u8, word: []const u8) bool {
    if (line.len <= word.len) return false;
    for (word, 0..) |w, i| {
        const c = line[i + 1];
        if (c != w and c != w + 32) return false;
    }
    return true;
}

fn parseF(s: []const u8) ?f64 {
    const v = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch return null;
    if (std.math.isNan(v) or std.math.isInf(v)) return null;
    return v;
}

/// Gimmick charts reach far past musical tempos, but the UI and timing turn BPM into integers.
pub fn validBpm(bpm: f64) bool {
    return bpm >= 1e-3 and bpm <= 1e9;
}

fn parseI(s: []const u8) ?i32 {
    return std.fmt.parseInt(i32, std.mem.trim(u8, s, " \t\r\n"), 10) catch null;
}

const LineIter = struct {
    data: []const u8,
    i: usize = 0,
    fn next(it: *LineIter) ?[]const u8 {
        if (it.i >= it.data.len) return null;
        const start = it.i;
        while (it.i < it.data.len and it.data[it.i] != '\n' and it.data[it.i] != '\r') it.i += 1;
        const line = it.data[start..it.i];
        if (it.i < it.data.len) {
            if (it.data[it.i] == '\r' and it.i + 1 < it.data.len and it.data[it.i + 1] == '\n') it.i += 1;
            it.i += 1;
        }
        return line;
    }
};

const Rng = struct {
    s: u64,
    fn next(r: *Rng) u64 {
        r.s +%= 0x9E3779B97F4A7C15;
        var z = r.s;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }
    /// As beatoraja's `(int)(Math.random() * n)`: a range <= 0 gives 0, so #RANDOM 0 takes branch 1.
    fn below(r: *Rng, n: i32) i32 {
        if (n <= 0) return 0;
        return @intCast(r.next() % @as(u64, @intCast(n)));
    }
};

const Decoder = struct {
    a: std.mem.Allocator,
    chart: *Chart,
    enc: encoding.Encoding,
    base: i32 = 36,
    lnobj: i32 = -1,
    lnmode: u8 = 0,
    bpm_table: std.AutoHashMapUnmanaged(i32, f64) = .empty,
    stop_table: std.AutoHashMapUnmanaged(i32, f64) = .empty,
    scroll_table: std.AutoHashMapUnmanaged(i32, f64) = .empty,
    speed_table: std.AutoHashMapUnmanaged(i32, f64) = .empty,
    wm: []i32,
    bm: []i32,
    wavlist: std.ArrayList([]const u8) = .empty,
    bgalist: std.ArrayList([]const u8) = .empty,
    bars: []std.ArrayList([]const u8),
    mode: Mode = .beat5,
    bg: std.ArrayList(struct { tl: *Tl, wav: i32 }) = .empty,
    hidden: std.ArrayList(struct { tl: *Tl, wav: i32, lane: u8 }) = .empty,
    bga: std.ArrayList(struct { tl: *Tl, id: i32, layer: types.BgaLayer }) = .empty,

    fn text(d: *Decoder, s: []const u8) ![]u8 {
        return encoding.toUtf8(d.a, std.mem.trim(u8, s, " \t\r\n"), d.enc);
    }

    fn path(d: *Decoder, s: []const u8) ![]u8 {
        const out = try d.text(s);
        std.mem.replaceScalar(u8, out, '\\', '/');
        return out;
    }

    fn idx(d: *Decoder, line: []const u8, at: usize) i32 {
        if (at + 1 >= line.len) return -1;
        return if (d.base == 62) int62(line[at], line[at + 1]) else int36(line[at], line[at + 1]);
    }
};

fn pickBranch(a: std.mem.Allocator, line: []const u8, is_set: bool, opts: Options, rng: *Rng, values: *std.ArrayList(i32)) !?i32 {
    const off: usize = if (is_set) 10 else 7;
    if (line.len <= off) return null;
    const r = parseI(line[off..]) orelse return null;
    const v: i32 = blk: {
        if (is_set) break :blk r;
        if (opts.selected_random) |sel| if (values.items.len < sel.len) {
            // Untrusted: a value no roll gives would drop every #IF's notes (a range <= 0 rolls 1; replays from before that recorded 2).
            const s = sel[values.items.len];
            if (s < 1 or s > (if (r >= 1) r else 2)) return error.BadRandom;
            break :blk s;
        };
        break :blk rng.below(r) + 1;
    };
    try values.append(a, v);
    return v;
}

pub fn parse(gpa: std.mem.Allocator, raw: []const u8, opts: Options) Error!Chart {
    var chart: Chart = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer chart.arena.deinit();
    const a = chart.arena.allocator();
    chart.is_pms = opts.is_pms;
    hash.fill(&chart, raw);
    // Lines are split on bytes, so UTF-16 becomes UTF-8 first; jbms-parser rejects such files.
    const data = switch (encoding.detect(raw)) {
        .utf16le, .utf16be => |enc| try encoding.toUtf8(a, raw, enc),
        else => raw,
    };

    const bars = try a.alloc(std.ArrayList([]const u8), 1000);
    for (bars) |*b| b.* = .empty;
    const wm = try a.alloc(i32, 62 * 62);
    const bm = try a.alloc(i32, 62 * 62);
    @memset(wm, -2);
    @memset(bm, -2);

    var d: Decoder = .{ .a = a, .chart = &chart, .enc = encoding.detect(data), .wm = wm, .bm = bm, .bars = bars };
    d.mode = if (opts.is_pms) .popn9 else .beat5;

    // #BASE must be known before any table is read.
    var it: LineIter = .{ .data = data };
    while (it.next()) |line| {
        if (line.len >= 2 and line[0] == '#' and reserve(line, "BASE") and line.len > 5 and line[5] == ' ') {
            const v = parseI(line[6..]) orelse 36;
            d.base = if (v == 62) 62 else 36;
        }
    }

    var rng: Rng = .{ .s = opts.seed };
    var random_values: std.ArrayList(i32) = .empty;
    const Frame = struct {
        value: i32,
        matched: bool,
        active: bool,
        outer: bool,
        fn live(stack: []const @This()) bool {
            if (stack.len == 0) return true;
            const top = stack[stack.len - 1];
            return top.outer and top.active;
        }
    };
    var rnd_stack: std.ArrayList(i32) = .empty;
    var if_stack: std.ArrayList(Frame) = .empty;
    var sw_stack: std.ArrayList(Frame) = .empty;
    var rank_type: enum { rank, defex } = .rank;
    var rank: i32 = 2;
    var maxsec: usize = 0;

    it = .{ .data = data };
    while (it.next()) |line| {
        if (line.len < 2) continue;
        if (line[0] != '#') continue;

        if (reserve(line, "RANDOM") or reserve(line, "SETRANDOM")) {
            const is_set = reserve(line, "SETRANDOM");
            const v = (try pickBranch(a, line, is_set, opts, &rng, &random_values)) orelse continue;
            try rnd_stack.append(a, v);
            chart.has_random = true;
            continue;
        }
        if (reserve(line, "ENDRANDOM")) {
            _ = rnd_stack.pop();
            continue;
        }
        if (reserve(line, "ENDSW")) {
            _ = sw_stack.pop();
            continue;
        }
        if (reserve(line, "ELSEIF") or reserve(line, "ELSE") or reserve(line, "IF") or reserve(line, "ENDIF") or reserve(line, "END")) {
            if (reserve(line, "ELSEIF")) {
                if (if_stack.items.len > 0) {
                    const f = &if_stack.items[if_stack.items.len - 1];
                    const cond = if (line.len > 8) parseI(line[7..]) else null;
                    f.active = !f.matched and cond != null and cond.? == f.value;
                    if (f.active) f.matched = true;
                }
                continue;
            }
            if (reserve(line, "ELSE")) {
                if (if_stack.items.len > 0) {
                    const f = &if_stack.items[if_stack.items.len - 1];
                    f.active = !f.matched;
                    f.matched = true;
                }
                continue;
            }
            if (reserve(line, "ENDIF") or reserve(line, "END")) {
                _ = if_stack.pop();
                continue;
            }
            const cur = if (rnd_stack.items.len > 0) rnd_stack.items[rnd_stack.items.len - 1] else null;
            if (cur) |value| {
                const cond = if (line.len > 4) parseI(line[3..]) else null;
                const hit = cond != null and cond.? == value;
                try if_stack.append(a, .{ .value = value, .matched = hit, .active = hit, .outer = Frame.live(if_stack.items) });
            } else {
                try if_stack.append(a, .{ .value = 0, .matched = false, .active = false, .outer = Frame.live(if_stack.items) });
            }
            continue;
        }
        if (reserve(line, "SWITCH") or reserve(line, "SETSWITCH")) {
            const is_set = reserve(line, "SETSWITCH");
            const v = (try pickBranch(a, line, is_set, opts, &rng, &random_values)) orelse continue;
            try sw_stack.append(a, .{ .value = v, .matched = false, .active = false, .outer = Frame.live(sw_stack.items) });
            chart.has_random = true;
            continue;
        }
        if (reserve(line, "CASE")) {
            if (sw_stack.items.len > 0) {
                const f = &sw_stack.items[sw_stack.items.len - 1];
                const cond = if (line.len > 6) parseI(line[5..]) else null;
                // fallthrough: an active case stays active until #SKIP
                if (!f.active and !f.matched and cond != null and cond.? == f.value) {
                    f.active = true;
                    f.matched = true;
                }
            }
            continue;
        }
        if (reserve(line, "DEF")) {
            if (std.ascii.startsWithIgnoreCase(line, "#DEFEXRANK")) {} else {
                if (sw_stack.items.len > 0) {
                    const f = &sw_stack.items[sw_stack.items.len - 1];
                    if (!f.active and !f.matched) {
                        f.active = true;
                        f.matched = true;
                    }
                }
                continue;
            }
        }
        if (reserve(line, "SKIP")) {
            if (sw_stack.items.len > 0) sw_stack.items[sw_stack.items.len - 1].active = false;
            continue;
        }

        if (!Frame.live(if_stack.items) or !Frame.live(sw_stack.items)) continue;

        const c = line[1];
        if (c >= '0' and c <= '9' and line.len > 6) {
            const c2 = line[2];
            const c3 = line[3];
            if (c2 >= '0' and c2 <= '9' and c3 >= '0' and c3 <= '9') {
                const bar: usize = @as(usize, c - '0') * 100 + @as(usize, c2 - '0') * 10 + (c3 - '0');
                try bars[bar].append(a, line);
                maxsec = @max(maxsec, bar);
            }
        } else if (reserve(line, "BPM")) {
            if (line.len > 4 and line[4] == ' ') {
                if (parseF(line[5..])) |bpm| if (validBpm(bpm)) {
                    chart.bpm = bpm;
                };
            } else if (line.len > 7) {
                const key = d.idx(line, 4);
                if (key >= 0) if (parseF(line[7..])) |bpm| if (validBpm(bpm)) try d.bpm_table.put(a, key, bpm);
            }
        } else if (reserve(line, "WAV")) {
            if (line.len >= 8) {
                const key = d.idx(line, 4);
                if (key >= 0) {
                    wm[@intCast(key)] = @intCast(d.wavlist.items.len);
                    try d.wavlist.append(a, try d.path(line[7..]));
                }
            }
        } else if (reserve(line, "BMP")) {
            if (line.len >= 8) {
                const key = d.idx(line, 4);
                if (key >= 0) {
                    bm[@intCast(key)] = @intCast(d.bgalist.items.len);
                    try d.bgalist.append(a, try d.path(line[7..]));
                }
            }
        } else if (reserve(line, "STOP")) {
            if (line.len >= 9) {
                const key = d.idx(line, 5);
                if (key >= 0) if (parseF(line[8..])) |v| try d.stop_table.put(a, key, @abs(v) / 192.0);
            }
        } else if (reserve(line, "SCROLL")) {
            if (line.len >= 11) {
                const key = d.idx(line, 7);
                if (key >= 0) if (parseF(line[10..])) |v| try d.scroll_table.put(a, key, v);
            }
        } else if (reserve(line, "SPEED")) {
            if (line.len >= 10) {
                const key = d.idx(line, 6);
                if (key >= 0) if (parseF(line[9..])) |v| try d.speed_table.put(a, key, v);
            }
        } else if (reserve(line, "SUBTITLE") and line.len > 10) {
            chart.subtitle = try d.text(line[10..]);
        } else if (reserve(line, "SUBARTIST") and line.len > 11) {
            chart.subartist = try d.text(line[11..]);
        } else if (reserve(line, "GENRE") and line.len > 7) {
            chart.genre = try d.text(line[7..]);
        } else if (reserve(line, "TITLE") and line.len > 7) {
            chart.title = try d.text(line[7..]);
        } else if (reserve(line, "ARTIST") and line.len > 8) {
            chart.artist = try d.text(line[8..]);
        } else if (reserve(line, "PLAYLEVEL") and line.len > 11) {
            chart.playlevel = try d.text(line[11..]);
        } else if (reserve(line, "RANK") and line.len > 6) {
            if (parseI(line[6..])) |r| if (r >= 0 and r < 5) {
                rank = r;
                rank_type = .rank;
            };
        } else if (reserve(line, "DEFEXRANK") and line.len > 11) {
            if (parseI(line[11..])) |r| if (r >= 1 and r <= 1_000_000) {
                rank = r;
                rank_type = .defex;
            };
        } else if (reserve(line, "TOTAL") and line.len > 7) {
            if (parseF(line[7..])) |t| if (t > 0) {
                chart.total = t;
                chart.total_defined = true;
            };
        } else if (reserve(line, "STAGEFILE") and line.len > 11) {
            chart.stagefile = try d.path(line[11..]);
        } else if (reserve(line, "BACKBMP") and line.len > 9) {
            chart.backbmp = try d.path(line[9..]);
        } else if (reserve(line, "PREVIEW") and line.len > 9) {
            chart.preview = try d.path(line[9..]);
        } else if (reserve(line, "BANNER") and line.len > 8) {
            chart.banner = try d.path(line[8..]);
        } else if (reserve(line, "LNOBJ") and line.len > 7) {
            const arg = std.mem.trim(u8, line[7..], " \t");
            if (arg.len >= 2) d.lnobj = if (d.base == 62) int62(arg[0], arg[1]) else int36(arg[0], arg[1]);
        } else if (reserve(line, "LNMODE") and line.len > 8) {
            if (parseI(line[8..])) |m| if (m >= 0 and m <= 3) {
                d.lnmode = @intCast(m);
            };
        } else if (reserve(line, "DIFFICULTY") and line.len > 12) {
            if (parseI(line[12..])) |v| chart.difficulty = v;
        } else if (!opts.is_pms and std.ascii.eqlIgnoreCase(std.mem.trim(u8, line, " \t\r"), "#4K")) {
            // Qwilight's own header. It takes no value, and 4K wins over 6K.
            d.mode = .beat4;
        } else if (!opts.is_pms and d.mode != .beat4 and std.ascii.eqlIgnoreCase(std.mem.trim(u8, line, " \t\r"), "#6K")) {
            d.mode = .beat6;
        }
    }

    chart.random = try random_values.toOwnedSlice(a);
    chart.judgerank = switch (rank_type) {
        .rank => ([5]i32{ 25, 50, 75, 100, 75 })[@intCast(rank)],
        .defex => @divTrunc(rank * 75, 100),
    };
    if (chart.judgerank <= 0) chart.judgerank = 75;

    try build(&d, maxsec);
    return chart;
}

const Section = struct { sectionnum: f64, rate: f64 };

fn each(d: *Decoder, line: []const u8, ctx: anytype, f: anytype) !void {
    const colon = std.mem.indexOfScalar(u8, line, ':');
    const start = if (colon) |p| p + 1 else 0;
    const split = (line.len - start) / 2;
    for (0..split) |i| {
        const at = start + i * 2;
        const v = if (d.base == 62) int62(line[at], line[at + 1]) else int36(line[at], line[at + 1]);
        if (v > 0) try f(ctx, @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(split)), v);
    }
}

fn build(d: *Decoder, maxsec: usize) !void {
    const a = d.a;
    const chart = d.chart;

    // Any note can change the mode, so it is settled before lanes are assigned.
    const sections = try a.alloc(Section, maxsec + 1);
    var prev_end: f64 = 0;
    for (sections, 0..) |*s, i| {
        s.* = .{ .sectionnum = prev_end, .rate = 1 };
        for (d.bars[i].items) |line| {
            const channel = int36(line[4], line[5]);
            if (channel == 2) {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                if (parseF(line[colon + 1 ..])) |rate| {
                    const next = s.sectionnum + rate;
                    if (rate > 0 and next > s.sectionnum and !std.math.isInf(next)) s.rate = rate;
                }
            } else if (channel >= 0) {
                detectMode(d, line, channel);
            }
        }
        prev_end = s.sectionnum + s.rate;
    }
    chart.mode = d.mode;

    const base_tl = try a.create(Tl);
    base_tl.* = .{ .section = 0, .time = 0, .micro = 0, .bpm = chart.bpm };
    var tls: Timelines = .{ .arena = &chart.arena };
    tls.add(base_tl);

    const cassign: *const [18]i8 = switch (d.mode) {
        .popn9 => &assign_popn,
        .beat4 => &assign_beat4,
        .beat6 => &assign_beat6,
        .beat7, .beat14 => &assign_beat7,
        else => &assign_beat5,
    };

    var state: LaneState = .{};
    for (sections, 0..) |*s, i| {
        try tempoEvents(d, &tls, s, d.bars[i].items);
        (try tls.get(s.sectionnum)).bar = true;
        for (d.bars[i].items) |line| try channelLine(d, &tls, s, line, cassign, &state);
    }

    if (base_tl.bpm == 0) return error.NoBpm;

    // An LN that never ends disappears, as in jbms-parser.
    for (state.start, 0..) |maybe, lane| {
        if (maybe) |ln| if (!ln.orphan) try tls.setSlot(try tls.get(ln.section), lane, .none);
    }
    try flatten(d, &tls);
}

fn detectMode(d: *Decoder, line: []const u8, channel: i32) void {
    const bases = [_]i32{ P1_KEY, P2_KEY, P1_INV, P2_INV, P1_LONG, P2_LONG, P1_MINE, P2_MINE };
    for (bases) |b| {
        if (channel < b or channel > b + 8) continue;
        const ch2 = channel - b;
        var any = false;
        const Ctx = struct { any: *bool };
        each(d, line, Ctx{ .any = &any }, struct {
            fn f(c: Ctx, _: f64, _: i32) error{}!void {
                c.any.* = true;
            }
        }.f) catch unreachable;
        if (!any) return;
        if (ch2 == 7 or ch2 == 8) {
            if (d.mode == .beat5) d.mode = .beat7 else if (d.mode == .beat10) d.mode = .beat14;
        }
        if (b == P2_KEY or b == P2_INV or b == P2_LONG or b == P2_MINE) {
            if (d.mode == .beat5) d.mode = .beat10 else if (d.mode == .beat7) d.mode = .beat14;
        }
        return;
    }
}

const Pending = struct { pos: f64, value: f64 };

fn collectTable(d: *Decoder, out: *std.ArrayList(Pending), line: []const u8, table: *const std.AutoHashMapUnmanaged(i32, f64)) !void {
    const Ctx = struct { d: *Decoder, out: *std.ArrayList(Pending), table: *const std.AutoHashMapUnmanaged(i32, f64) };
    try each(d, line, Ctx{ .d = d, .out = out, .table = table }, struct {
        fn f(c: Ctx, pos: f64, v: i32) !void {
            if (c.table.get(v)) |x| try c.out.append(c.d.a, .{ .pos = pos, .value = x });
        }
    }.f);
}

/// Stable, so at equal positions the last definition in the file wins, as jbms-parser's TreeMap.
fn sortPending(items: []Pending) void {
    std.mem.sort(Pending, items, {}, struct {
        fn lt(_: void, x: Pending, y: Pending) bool {
            return x.pos < y.pos;
        }
    }.lt);
}

fn tempoEvents(d: *Decoder, tls: *Timelines, s: *Section, lines: []const []const u8) !void {
    var bpm: std.ArrayList(Pending) = .empty;
    var stop: std.ArrayList(Pending) = .empty;
    var scroll: std.ArrayList(Pending) = .empty;
    var speed: std.ArrayList(Pending) = .empty;
    for (lines) |line| {
        switch (int36(line[4], line[5])) {
            3 => {
                const Ctx = struct { d: *Decoder, out: *std.ArrayList(Pending) };
                try each(d, line, Ctx{ .d = d, .out = &bpm }, struct {
                    fn f(c: Ctx, pos: f64, v0: i32) !void {
                        const v = if (c.d.base == 62) rebase36(v0) else v0;
                        const hex = @divTrunc(v, 36) * 16 + @rem(v, 36);
                        try c.out.append(c.d.a, .{ .pos = pos, .value = @floatFromInt(hex) });
                    }
                }.f);
            },
            8 => try collectTable(d, &bpm, line, &d.bpm_table),
            9 => try collectTable(d, &stop, line, &d.stop_table),
            CH_SCROLL => try collectTable(d, &scroll, line, &d.scroll_table),
            CH_SPEED => try collectTable(d, &speed, line, &d.speed_table),
            else => {},
        }
    }
    sortPending(bpm.items);
    sortPending(stop.items);
    sortPending(scroll.items);
    sortPending(speed.items);
    var ib: usize = 0;
    var ist: usize = 0;
    var isc: usize = 0;
    var isp: usize = 0;
    while (ib < bpm.items.len or ist < stop.items.len or isc < scroll.items.len or isp < speed.items.len) {
        const bc = if (ib < bpm.items.len) bpm.items[ib].pos else 2;
        const st = if (ist < stop.items.len) stop.items[ist].pos else 2;
        const sc = if (isc < scroll.items.len) scroll.items[isc].pos else 2;
        const sp = if (isp < speed.items.len) speed.items[isp].pos else 2;
        if (sp <= sc and sp <= st and sp <= bc) {
            (try tls.get(s.sectionnum + sp * s.rate)).speed = speed.items[isp].value;
            isp += 1;
        } else if (sc <= st and sc <= bc) {
            (try tls.get(s.sectionnum + sc * s.rate)).scroll = scroll.items[isc].value;
            isc += 1;
        } else if (bc <= st) {
            (try tls.get(s.sectionnum + bc * s.rate)).bpm = bpm.items[ib].value;
            ib += 1;
        } else {
            const tl = try tls.get(s.sectionnum + st * s.rate);
            tl.stop = truncMicro(1000.0 * 1000.0 * 60.0 * 4.0 * stop.items[ist].value / tl.bpm);
            d.chart.has_stop = true;
            ist += 1;
        }
    }
}

const LaneState = struct {
    start: [types.max_lanes]?*Ln = @splat(null),
    // Only whether some LN covers a point matters, so overlapping LNs merge into disjoint spans keyed by their start.
    covered: [types.max_lanes]Tree = @splat(.{}),

    const Span = struct {
        node: Tree.Node = undefined,
        to: f64,

        fn of(node: *Tree.Node) *Span {
            return @fieldParentPtr("node", node);
        }
    };

    fn addLn(st: *LaneState, a: std.mem.Allocator, key: usize, ln: *Ln) !void {
        var from = ln.section;
        var to = ln.pair.?.section;
        // An end placed before its start covers nothing.
        if (to < from) return;
        const tree = &st.covered[key];
        var next = nodeAtOrBelow(tree, from) orelse tree.getMin();
        while (next) |node| {
            if (node.key > to) break;
            next = node.next();
            const span = Span.of(node);
            if (span.to < from) continue;
            from = @min(from, node.key);
            to = @max(to, span.to);
            var gone = tree.getEntryForExisting(node);
            gone.set(null);
        }
        const span = try a.create(Span);
        span.* = .{ .to = to };
        var entry = tree.getEntryFor(from);
        entry.set(&span.node);
    }

    fn inside(st: *LaneState, key: usize, section: f64) bool {
        const node = nodeAtOrBelow(&st.covered[key], section) orelse return false;
        return section <= Span.of(node).to;
    }
};

fn setPair(a: *Ln, b: *Ln) void {
    a.pair = b;
    b.pair = a;
    a.end = false;
    b.end = true;
    b.ln_type = a.ln_type;
}

fn channelLine(d: *Decoder, tls: *Timelines, s: *const Section, line: []const u8, cassign: *const [18]i8, st: *LaneState) !void {
    const a = d.a;
    const raw = int36(line[4], line[5]);
    if (raw < 0) return;
    var key: i8 = 0;
    var kind: enum { key, hidden, long, mine, bg, bga, layer, poor, none } = .none;
    const ranges = [_]struct { b: i32, off: usize, k: @TypeOf(kind) }{
        .{ .b = P1_KEY, .off = 0, .k = .key },
        .{ .b = P2_KEY, .off = 9, .k = .key },
        .{ .b = P1_INV, .off = 0, .k = .hidden },
        .{ .b = P2_INV, .off = 9, .k = .hidden },
        .{ .b = P1_LONG, .off = 0, .k = .long },
        .{ .b = P2_LONG, .off = 9, .k = .long },
        .{ .b = P1_MINE, .off = 0, .k = .mine },
        .{ .b = P2_MINE, .off = 9, .k = .mine },
    };
    for (ranges) |r| {
        if (raw >= r.b and raw < r.b + 9) {
            key = cassign[@as(usize, @intCast(raw - r.b)) + r.off];
            kind = r.k;
            break;
        }
    }
    if (kind == .none) switch (raw) {
        1 => kind = .bg,
        4 => kind = .bga,
        7 => kind = .layer,
        6 => kind = .poor,
        else => return,
    };
    if (key < 0) return;
    const lane: usize = @intCast(key);

    const Ctx = struct { d: *Decoder, tls: *Timelines, s: *const Section, st: *LaneState, lane: usize, a: std.mem.Allocator };
    const ctx: Ctx = .{ .d = d, .tls = tls, .s = s, .st = st, .lane = lane, .a = a };
    switch (kind) {
        .bg => try each(d, line, ctx, struct {
            fn f(c: Ctx, pos: f64, v: i32) !void {
                const tl = try c.tls.get(c.s.sectionnum + c.s.rate * pos);
                try c.d.bg.append(c.a, .{ .tl = tl, .wav = c.d.wm[@intCast(v)] });
            }
        }.f),
        .bga, .layer, .poor => {
            const layer: types.BgaLayer = switch (kind) {
                .bga => .base,
                .layer => .layer,
                else => .poor,
            };
            const C2 = struct { c: Ctx, layer: types.BgaLayer };
            try each(d, line, C2{ .c = ctx, .layer = layer }, struct {
                fn f(c2: C2, pos: f64, v: i32) !void {
                    const c = c2.c;
                    const tl = try c.tls.get(c.s.sectionnum + c.s.rate * pos);
                    try c.d.bga.append(c.a, .{ .tl = tl, .id = c.d.bm[@intCast(v)], .layer = c2.layer });
                }
            }.f);
        },
        .hidden => try each(d, line, ctx, struct {
            fn f(c: Ctx, pos: f64, v: i32) !void {
                const tl = try c.tls.get(c.s.sectionnum + c.s.rate * pos);
                try c.d.hidden.append(c.a, .{ .tl = tl, .wav = c.d.wm[@intCast(v)], .lane = @intCast(c.lane) });
            }
        }.f),
        .key => try each(d, line, ctx, struct {
            fn f(c: Ctx, pos: f64, v: i32) !void {
                const tl = try c.tls.get(c.s.sectionnum + c.s.rate * pos);
                const k = c.lane;
                if (v == c.d.lnobj) {
                    if (c.tls.heldBelow(tl, k)) |held| {
                        const tl2 = held.tl;
                        switch (held.slot) {
                            .normal => |wav| {
                                const ln = try c.a.create(Ln);
                                ln.* = .{ .wav = wav, .section = tl2.section, .ln_type = c.d.lnmode };
                                try c.tls.setSlot(tl2, k, .{ .long = ln });
                                const end = try c.a.create(Ln);
                                end.* = .{ .wav = -2, .section = tl.section };
                                try c.tls.setSlot(tl, k, .{ .long = end });
                                setPair(ln, end);
                                try c.st.addLn(c.a, k, ln);
                            },
                            .long => |note| if (note.pair == null) {
                                const end = try c.a.create(Ln);
                                end.* = .{ .wav = -2, .section = tl.section };
                                try c.tls.setSlot(tl, k, .{ .long = end });
                                setPair(note, end);
                                try c.st.addLn(c.a, k, note);
                                c.st.start[k] = null;
                            },
                            else => {},
                        }
                    }
                } else {
                    try c.tls.setSlot(tl, k, .{ .normal = c.d.wm[@intCast(v)] });
                }
            }
        }.f),
        .long => try each(d, line, ctx, struct {
            fn f(c: Ctx, pos: f64, v: i32) !void {
                const tl = try c.tls.get(c.s.sectionnum + c.s.rate * pos);
                const k = c.lane;
                const wav = c.d.wm[@intCast(v)];
                if (!c.st.inside(k, tl.section)) {
                    if (c.st.start[k] == null) {
                        const held = c.tls.slot(tl, k);
                        if (held == .normal and held.normal != wav) {
                            try c.d.bg.append(c.a, .{ .tl = tl, .wav = held.normal });
                        }
                        const ln = try c.a.create(Ln);
                        ln.* = .{ .wav = wav, .section = tl.section };
                        try c.tls.setSlot(tl, k, .{ .long = ln });
                        c.st.start[k] = ln;
                    } else if (c.st.start[k].?.orphan) {
                        c.st.start[k] = null;
                    } else {
                        const start = c.st.start[k].?;
                        var below = tl.prev();
                        while (below) |tl2| : (below = tl2.prev()) {
                            if (!(tl2.section > start.section)) break;
                            switch (c.tls.slot(tl2, k)) {
                                .none => {},
                                .normal => |w| {
                                    try c.d.bg.append(c.a, .{ .tl = tl2, .wav = w });
                                    try c.tls.setSlot(tl2, k, .none);
                                },
                                else => try c.tls.setSlot(tl2, k, .none),
                            }
                        }
                        start.ln_type = c.d.lnmode;
                        const end = try c.a.create(Ln);
                        end.* = .{ .wav = if (start.wav != wav) wav else -2, .section = tl.section };
                        try c.tls.setSlot(tl, k, .{ .long = end });
                        setPair(start, end);
                        try c.st.addLn(c.a, k, start);
                        c.st.start[k] = null;
                    }
                } else if (c.st.start[k] == null) {
                    const ln = try c.a.create(Ln);
                    ln.* = .{ .wav = wav, .orphan = true };
                    c.st.start[k] = ln;
                } else {
                    const start = c.st.start[k].?;
                    if (!start.orphan) try c.tls.setSlot(try c.tls.get(start.section), k, .none);
                    c.st.start[k] = null;
                }
            }
        }.f),
        .mine => try each(d, line, ctx, struct {
            fn f(c: Ctx, pos: f64, v0: i32) !void {
                const tl = try c.tls.get(c.s.sectionnum + c.s.rate * pos);
                const k = c.lane;
                if (c.tls.slot(tl, k) != .none or c.st.inside(k, tl.section)) return;
                const v = if (c.d.base == 62) rebase36(v0) else v0;
                try c.tls.setSlot(tl, k, .{ .mine = .{ .wav = c.d.wm[0], .damage = @floatFromInt(v) } });
            }
        }.f),
        .none => {},
    }
}

fn flatten(d: *Decoder, tls: *Timelines) !void {
    const a = d.a;
    const chart = d.chart;
    const timelines = try a.alloc(types.Timeline, tls.len);
    var y: f64 = 0;
    var total: u32 = 0;
    var notes: std.ArrayList(Note) = .empty;
    var min_bpm = chart.bpm;
    var max_bpm = chart.bpm;
    const keys = chart.mode.keys();

    var it = tls.tree.inorderIterator();
    var below: ?*Tl = null;
    var next_held: [types.max_lanes]?*Tree.Node = undefined;
    for (&next_held, tls.lanes) |*n, lane| n.* = lane.getMin();
    for (timelines) |*out| {
        const tl = Tl.of(it.next().?);
        if (below) |b| y += (tl.section - b.section) * b.scroll;
        below = tl;
        out.* = .{ .time_us = tl.micro, .y = y, .section = tl.section, .bpm = tl.bpm, .stop_us = tl.stop, .scroll = tl.scroll, .speed = tl.speed, .bar = tl.bar };
        min_bpm = @min(min_bpm, tl.bpm);
        max_bpm = @max(max_bpm, tl.bpm);
        for (next_held[0..keys], 0..) |*node, lane_usize| {
            const held = Held.of(node.* orelse continue);
            if (held.tl != tl) continue;
            node.* = node.*.?.next();
            const lane: u8 = @intCast(lane_usize);
            switch (held.slot) {
                .none => {},
                .normal => |wav| {
                    try notes.append(a, .{ .time_us = tl.micro, .y = y, .wav = wav, .lane = lane, .kind = .normal });
                    total += 1;
                },
                .mine => |m| {
                    try notes.append(a, .{ .time_us = tl.micro, .y = y, .wav = m.wav, .lane = lane, .kind = .mine, .damage = m.damage });
                    chart.has_mine = true;
                },
                .long => |ln| {
                    const ty: types.LnType = switch (ln.ln_type) {
                        2 => .cn,
                        3 => .hcn,
                        else => .ln,
                    };
                    ln.index = @intCast(notes.items.len);
                    var n: Note = .{ .time_us = tl.micro, .y = y, .wav = ln.wav, .lane = lane, .kind = if (ln.end) .ln_end else .ln_start, .ln_type = ty, .ln_open = ln.ln_type == 0 };
                    if (ln.pair) |p| if (p.index >= 0) {
                        n.pair = p.index;
                        notes.items[@intCast(p.index)].pair = ln.index;
                    };
                    try notes.append(a, n);
                    if (!ln.end or ty != .ln) total += 1;
                    chart.has_ln = true;
                },
            }
        }
    }

    chart.timelines = timelines;
    chart.notes = try notes.toOwnedSlice(a);
    chart.total_notes = total;
    chart.min_bpm = min_bpm;
    chart.max_bpm = max_bpm;
    chart.wavs = try d.wavlist.toOwnedSlice(a);
    chart.bmps = try d.bgalist.toOwnedSlice(a);
    if (!chart.total_defined) chart.total = types.defaultTotal(total);

    const hidden = try a.alloc(types.Hidden, d.hidden.items.len);
    for (d.hidden.items, 0..) |h, i| hidden[i] = .{ .time_us = h.tl.micro, .wav = h.wav, .lane = h.lane };
    const bg = try a.alloc(types.BgSound, d.bg.items.len);
    for (d.bg.items, 0..) |b, i| bg[i] = .{ .time_us = b.tl.micro, .wav = b.wav };
    const bga = try a.alloc(types.BgaEvent, d.bga.items.len);
    for (d.bga.items, 0..) |b, i| bga[i] = .{ .time_us = b.tl.micro, .id = b.id, .layer = b.layer };
    const ByTime = struct {
        fn hid(_: void, x: types.Hidden, y2: types.Hidden) bool {
            return x.time_us < y2.time_us;
        }
        fn bgl(_: void, x: types.BgSound, y2: types.BgSound) bool {
            return x.time_us < y2.time_us;
        }
        fn bgal(_: void, x: types.BgaEvent, y2: types.BgaEvent) bool {
            return x.time_us < y2.time_us;
        }
    };
    std.mem.sort(types.Hidden, hidden, {}, ByTime.hid);
    std.mem.sort(types.BgSound, bg, {}, ByTime.bgl);
    std.mem.sort(types.BgaEvent, bga, {}, ByTime.bgal);
    chart.hidden = hidden;
    chart.bg = bg;
    chart.bga = bga;

    // Same "last event" rule as BMSModel.getLastMilliTime (bar lines alone do not count).
    var last: i64 = 0;
    if (chart.notes.len > 0) {
        chart.last_note_us = chart.notes[chart.notes.len - 1].time_us;
        last = chart.last_note_us;
    }
    if (hidden.len > 0) last = @max(last, hidden[hidden.len - 1].time_us);
    if (bg.len > 0) last = @max(last, bg[bg.len - 1].time_us);
    if (bga.len > 0) last = @max(last, bga[bga.len - 1].time_us);
    chart.last_time_us = last;
}

test "basic chart" {
    const src =
        \\#PLAYER 1
        \\#TITLE test
        \\#BPM 120
        \\#TOTAL 200
        \\#RANK 3
        \\#WAV01 a.wav
        \\#00111:01010101
        \\#00116:0100
    ;
    var c = try parse(std.testing.allocator, src, .{});
    defer c.deinit();
    try std.testing.expectEqual(@as(u32, 5), c.total_notes);
    try std.testing.expectEqual(Mode.beat5, c.mode);
    try std.testing.expectEqual(@as(i32, 100), c.judgerank);
    // measure 1 at 120 BPM starts at 2s; second note a quarter later
    try std.testing.expectEqual(@as(i64, 2_000_000), c.notes[0].time_us);
    try std.testing.expectEqual(@as(i64, 2_500_000), c.notes[2].time_us);
}

test "nested random with fixed selection" {
    const src =
        \\#BPM 120
        \\#WAV01 a.wav
        \\#RANDOM 2
        \\#IF 1
        \\#00111:01
        \\#RANDOM 2
        \\#IF 2
        \\#00112:01
        \\#ENDIF
        \\#ENDRANDOM
        \\#ELSE
        \\#00113:01
        \\#ENDIF
        \\#ENDRANDOM
    ;
    var a = try parse(std.testing.allocator, src, .{ .selected_random = &.{ 1, 2 } });
    defer a.deinit();
    try std.testing.expectEqual(@as(u32, 2), a.total_notes);
    var b = try parse(std.testing.allocator, src, .{ .selected_random = &.{ 2, 2 } });
    defer b.deinit();
    try std.testing.expectEqual(@as(u32, 1), b.total_notes);
    try std.testing.expectEqual(@as(u8, 2), b.notes[0].lane);
    try std.testing.expectError(error.BadRandom, parse(std.testing.allocator, src, .{ .selected_random = &.{99} }));
    try std.testing.expectError(error.BadRandom, parse(std.testing.allocator, src, .{ .selected_random = &.{0} }));
}

test "#RANDOM 0 takes branch 1, as beatoraja" {
    var c = try parse(std.testing.allocator, "#BPM 120\n#WAV01 a.wav\n#RANDOM 0\n#IF 1\n#00111:01\n#ENDIF\n#IF 2\n#00112:01\n#ENDIF\n#ENDRANDOM\n", .{});
    defer c.deinit();
    try std.testing.expectEqual(@as(u8, 0), c.notes[0].lane);
}

test "overlapping and touching LNs cover their union and nothing past it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st: LaneState = .{};
    for ([_][2]f64{ .{ 2, 3 }, .{ 6, 7 }, .{ 0, 1 }, .{ 0.5, 2.5 }, .{ 3, 4 }, .{ 9, 8 } }) |span| {
        const start = try a.create(Ln);
        const end = try a.create(Ln);
        start.* = .{ .wav = 1, .section = span[0] };
        end.* = .{ .wav = -2, .section = span[1] };
        setPair(start, end);
        try st.addLn(a, 0, start);
    }
    for ([_]f64{ 0, 1.5, 3, 4, 6.5 }) |in| try std.testing.expect(st.inside(0, in));
    for ([_]f64{ -1, 4.5, 5, 7.5, 8.5 }) |out| try std.testing.expect(!st.inside(0, out));
    try std.testing.expect(!st.inside(1, 1));
}

test "a measure crowded with LNs parses, and notes inside any LN are dropped" {
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "#BPM 120\n#WAV01 a.wav\n#00151:");
    for (0..5000) |_| try src.appendSlice(gpa, "010100");
    try src.appendSlice(gpa, "\n");
    var c = try parse(gpa, src.items, .{});
    defer c.deinit();
    try std.testing.expectEqual(@as(u32, 5000), c.total_notes);

    // LNs 0-1/8 and 1/2-5/8 on lane 1; the mines at 1/16 and 9/16 fall inside, the one at 3/4 does not.
    var mines = try parse(gpa, "#BPM 120\n#WAV01 a.wav\n#00151:0101000001010000\n#001D1:00010000000000000001000001000000\n", .{});
    defer mines.deinit();
    try std.testing.expectEqual(@as(usize, 5), mines.notes.len);
    try std.testing.expectEqual(types.NoteKind.mine, mines.notes[4].kind);
}

test "deep #IF nesting keeps a live inner branch dead under a dead outer one" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    try src.appendSlice(gpa, "#BPM 120\n#WAV01 a.wav\n#SETRANDOM 1\n");
    for (0..200) |_| try src.appendSlice(gpa, "#IF 1\n");
    try src.appendSlice(gpa, "#IF 2\n#IF 1\n#00111:01\n#ENDIF\n#ELSE\n#00112:01\n#ENDIF\n");
    for (0..200) |_| try src.appendSlice(gpa, "#ENDIF\n");
    try src.appendSlice(gpa, "#00113:01\n");
    var c = try parse(gpa, src.items, .{});
    defer c.deinit();
    try std.testing.expectEqual(@as(u32, 2), c.total_notes);
    try std.testing.expectEqual(@as(u8, 1), c.notes[0].lane);
}

test "the later of two BPM changes at one position wins" {
    var c = try parse(std.testing.allocator, "#BPM 60\n#WAV01 a.wav\n#00103:3C\n#00103:78\n#00211:01", .{});
    defer c.deinit();
    // measure 0 at 60 BPM is 4s, measure 1 at 0x78 = 120 BPM is 2s
    try std.testing.expectEqual(@as(i64, 6_000_000), c.notes[0].time_us);
}

test "a chart that would fill the memory cap is refused" {
    const gpa = std.testing.allocator;
    var points: std.ArrayList(u8) = .empty;
    defer points.deinit(gpa);
    try points.appendSlice(gpa, "#BPM 120\n#WAV01 a.wav\n#00101:");
    try points.appendNTimes(gpa, '1', 2 * Timelines.max_bytes / 64);
    try std.testing.expectError(error.TooBig, parse(gpa, points.items, .{}));

    // Each line reuses the same two points and slots but still makes an LN and its span.
    var lns: std.ArrayList(u8) = .empty;
    defer lns.deinit(gpa);
    try lns.appendSlice(gpa, "#BPM 120\n#LNOBJ ZZ\n#WAV01 a.wav\n");
    for (0..Timelines.max_bytes / 64) |_| try lns.appendSlice(gpa, "#00111:01ZZ\n");
    try std.testing.expectError(error.TooBig, parse(gpa, lns.items, .{}));
}

test "lnobj and channel 5x LN" {
    const src =
        \\#BPM 120
        \\#LNOBJ ZZ
        \\#WAV01 a.wav
        \\#00111:01ZZ
        \\#00152:0101
    ;
    var c = try parse(std.testing.allocator, src, .{});
    defer c.deinit();
    try std.testing.expectEqual(@as(u32, 2), c.total_notes);
    try std.testing.expect(c.has_ln);
}

test "LN mode changes only LNs the chart leaves open, and CN ends count as notes" {
    const open =
        \\#BPM 120
        \\#WAV01 a.wav
        \\#00152:0101
    ;
    var c = try parse(std.testing.allocator, open, .{});
    defer c.deinit();
    try std.testing.expectEqual(@as(u32, 1), c.total_notes);
    try std.testing.expect(!options.applyLnMode(&c, .ln));
    try std.testing.expect(options.applyLnMode(&c, .hcn));
    try std.testing.expectEqual(@as(u32, 2), c.total_notes);
    try std.testing.expectEqual(types.LnType.hcn, c.notes[0].ln_type);
    try std.testing.expectEqual(types.defaultTotal(2), c.total);

    var fixed = try parse(std.testing.allocator, "#LNMODE 1\n" ++ open, .{});
    defer fixed.deinit();
    try std.testing.expect(!options.applyLnMode(&fixed, .cn));
    try std.testing.expectEqual(types.LnType.ln, fixed.notes[0].ln_type);
}

test "a UTF-16 chart reads like its UTF-8 copy" {
    const src = "#TITLE 고추참치\r\n#BPM 154\r\n#WAV01 a.wav\r\n#00111:01\r\n";
    const wide = std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral("\u{FEFF}" ++ src));
    var c = try parse(std.testing.allocator, wide, .{});
    defer c.deinit();
    var plain = try parse(std.testing.allocator, src, .{});
    defer plain.deinit();
    try std.testing.expectEqualStrings(plain.title, c.title);
    try std.testing.expectEqual(@as(f64, 154), c.bpm);
    try std.testing.expectEqual(plain.total_notes, c.total_notes);
    try std.testing.expect(!std.mem.eql(u8, &plain.md5, &c.md5)); // hashed as stored
}

test "no bpm is an error" {
    try std.testing.expectError(error.NoBpm, parse(std.testing.allocator, "#00111:01", .{}));
}

test "numbers past what timing can hold are ignored" {
    const notes = "#WAV01 a.wav\n#00111:01\n";
    var rank = try parse(std.testing.allocator, "#BPM 120\n#DEFEXRANK 2147483647\n" ++ notes, .{});
    defer rank.deinit();
    try std.testing.expectEqual(@as(i32, 75), rank.judgerank);
    for ([_][]const u8{ "#BPM 1e300\n", "#BPM 1e-300\n" }) |line| {
        var buf: [64]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "{s}#BPM 120\n{s}", .{ notes, line });
        var c = try parse(std.testing.allocator, src, .{});
        defer c.deinit();
        try std.testing.expectEqual(@as(f64, 120), c.bpm);
    }
    var table = try parse(std.testing.allocator, "#BPM 120\n#BPM01 1e300\n#WAV01 a.wav\n#00108:01\n#00111:01\n", .{});
    defer table.deinit();
    try std.testing.expectEqual(@as(f64, 120), table.max_bpm);
}

test "only Qwilight's #4K and #6K headers make those modes" {
    const notes =
        \\#BPM 120
        \\#WAV01 a.wav
        \\#00111:01
        \\#00113:01
        \\#00116:01
        \\#00119:01
        \\#00121:01
        \\
    ;
    var four = try parse(std.testing.allocator, "#4K\n" ++ notes, .{});
    defer four.deinit();
    try std.testing.expectEqual(Mode.beat4, four.mode);
    // 13, 16, 19 and 2P have no lane.
    try std.testing.expectEqual(@as(u32, 1), four.total_notes);

    var six = try parse(std.testing.allocator, "#6K\r\n" ++ notes, .{});
    defer six.deinit();
    try std.testing.expectEqual(Mode.beat6, six.mode);
    try std.testing.expectEqual(@as(u32, 3), six.total_notes);
    try std.testing.expectEqual(@as(u8, 5), six.notes[2].lane);

    var plain = try parse(std.testing.allocator, "#BPM 120\n#WAV01 a.wav\n#00111:01\n#00112:01\n#00114:01\n#00115:01\n", .{});
    defer plain.deinit();
    try std.testing.expectEqual(Mode.beat5, plain.mode);
}
