const std = @import("std");
const fs = @import("../platform/fs.zig");
const input = @import("../input/input.zig");
const core = @import("actuon_core");
const table = @import("../table/table.zig");

const default_download_url = "https://gingerrush.com/download/package/{md5}";

pub const Config = struct {
    const max_covered = 0.9;

    pub fn setLift(cfg: *Config, v: f32) void {
        cfg.lift = std.math.clamp(v, 0, max_covered - cfg.lane_cover);
    }

    pub fn setCover(cfg: *Config, v: f32) void {
        cfg.lane_cover = std.math.clamp(v, 0, max_covered - cfg.lift);
    }

    pub fn setHidden(cfg: *Config, v: f32) void {
        cfg.hidden = std.math.clamp(v, 0, max_covered);
    }

    fn clampCovers(cfg: *Config) void {
        cfg.lane_cover = std.math.clamp(cfg.lane_cover, 0, max_covered);
        cfg.setLift(cfg.lift);
        cfg.setHidden(cfg.hidden);
    }

    pub fn openLane(cfg: *const Config) f32 {
        return 1 - cfg.liftShown() - cfg.coverShown();
    }

    pub fn coverShown(cfg: *const Config) f32 {
        return if (cfg.lane_cover_on) cfg.lane_cover else 0;
    }

    pub fn liftShown(cfg: *const Config) f32 {
        return if (cfg.lift_on) cfg.lift else 0;
    }

    pub fn hiddenShown(cfg: *const Config) f32 {
        return if (cfg.hidden_on) cfg.hidden else 0;
    }

    roots: []const []const u8 = &.{},
    tables: []const []const u8 = &.{"https://stellabms.xyz/st/table.html"},
    width: u32 = 1280,
    height: u32 = 720,
    fullscreen: bool = false,
    vsync: i32 = 1,
    /// 0 leaves it to VSync.
    fps_limit: u32 = 0,
    /// 0 off, 1 on, 2 on with Boost.
    reflex: i32 = 0,
    bga_upscale: bool = true,
    bga: bool = true,
    bga_auto: bool = false,
    audio_rate: u32 = 48000,
    audio_frames: u32 = 128,
    /// Empty picks the output automatically.
    audio_device: []const u8 = "",
    /// Hz. 0 uses OS key events instead, which on Linux carry evdev's kernel timestamps.
    input_poll_hz: u32 = if (@import("builtin").os.tag == .linux) 0 else 1000,
    volume: f32 = 0.8,
    bgm_volume: f32 = 0.5,
    sfx_volume: f32 = 0.8,
    /// Added to input timestamps: positive means "the player hits late, forgive it".
    judge_offset_ms: i32 = 0,
    visual_offset_ms: i32 = 0,
    /// Index into the gauge types up to hazard.
    gauge_type: u8 = 4,
    /// An options.Gas: beatoraja's gauge auto shift.
    gauge_auto_shift: u8 = @backingInt(core.options.Gas.select_to_under),
    /// The lowest gauge a shift may fall to: A-EASY, EASY or NORMAL.
    gas_floor: u8 = 0,
    /// An older save's gauge, where 6 meant auto shift from EX HARD. Moved to the fields above on load.
    gauge: ?u8 = null,
    /// options.Random for each side; the second is for double play.
    random: u8 = 0,
    random2: u8 = 0,
    /// An options.Double: off, flip, battle, battle with auto scratch.
    double_option: u8 = 0,
    /// An options.Algorithm.
    judge_algorithm: u8 = 0,
    /// What LNs the chart leaves open become: 0 LN, 1 CN, 2 HCN.
    ln_mode: u8 = 0,
    /// What a play is measured against, an index into play.pace_targets.
    pace_target: u8 = 0,
    versus_panel_left: bool = false,
    /// 0 start BPM, 1 max BPM, 2 main BPM (mode of the chart), 3 off (classic HS), 4 min BPM.
    hs_fix: u8 = 2,
    hs_auto_adjust: bool = false,
    /// ms a note is visible at the reference BPM.
    green_ms: u32 = 600,
    lane_cover: f32 = 0,
    /// Fractions of the lane.
    lift: f32 = 0,
    hidden: f32 = 0,
    lane_cover_on: bool = true,
    lift_on: bool = true,
    hidden_on: bool = true,
    constant: bool = false,
    judge_auto_adjust: bool = false,
    assist: Assists = .{},
    skin: []const u8 = "",
    skins: SkinSlots = .{},
    /// Wins over the skin's music; empty for the skin's own.
    bgm_path: []const u8 = "",
    bgm_root: []const u8 = "",
    /// Wins over the skin's sounds; empty for the skin's own.
    sound_path: []const u8 = "",
    sound_root: []const u8 = "",
    /// Empty follows the OS language.
    language: []const u8 = "",
    ir_url: []const u8 = "https://ir.actuon.app",
    ir_token: []const u8 = "",
    ir_send_failed: bool = true,
    /// Either a direct archive or a JSON answer naming one (see download.packageUrl).
    download_url: []const u8 = default_download_url,
    /// Scancode or joystick code per button: 7 keys, scratch A, B. `p1` is 7 key; double layouts start from these.
    p1: [9]u16 = .{ 29, 22, 27, 7, 6, 9, 25, 225, 224 },
    p2: [9]u16 = .{ 16, 14, 54, 15, 55, 51, 56, 229, 228 },
    pms: [9]u16 = .{ 4, 22, 7, 9, 44, 13, 14, 15, 51 },
    /// Null until set, which keeps an older config's keys.
    keys5: ?[7]u16 = null,
    keys10: ?[14]u16 = null,
    keys14: ?[18]u16 = null,
    keys4: [4]u16 = .{ 7, 9, 13, 14 },
    keys6: [6]u16 = .{ 22, 7, 9, 13, 14, 15 },
    beatoraja_select: bool = false,
    /// Q and W, as beatoraja.
    start_select: [2]u16 = .{ 20, 26 },

    pub fn skinFor(cfg: *const Config, slot: SkinSlot) []const u8 {
        const v = cfg.skins.get(slot);
        if (std.mem.eql(u8, v, builtin_skin)) return "";
        return if (v.len > 0) v else cfg.skin;
    }
};

pub fn keysOf(cfg: *Config, mode: core.types.Mode) []u16 {
    switch (mode) {
        .popn9 => return &cfg.pms,
        .beat4 => return &cfg.keys4,
        .beat6 => return &cfg.keys6,
        .beat7 => return &cfg.p1,
        .beat5 => {
            if (cfg.keys5 == null) cfg.keys5 = sideOf5(cfg.p1);
            return &cfg.keys5.?;
        },
        .beat10 => {
            if (cfg.keys10 == null) cfg.keys10 = sideOf5(cfg.p1) ++ sideOf5(cfg.p2);
            return &cfg.keys10.?;
        },
        .beat14 => {
            if (cfg.keys14 == null) cfg.keys14 = cfg.p1 ++ cfg.p2;
            return &cfg.keys14.?;
        },
    }
}

fn sideOf5(side: [9]u16) [7]u16 {
    return side[0..5].* ++ side[7..9].*;
}

pub fn playOptions(cfg: *const Config, seed: u64) core.replay.Replay {
    return .{
        .gauge = @fromBackingInt(cfg.gauge_type),
        .gas = @fromBackingInt(cfg.gauge_auto_shift),
        .gas_floor = @fromBackingInt(cfg.gas_floor),
        .random = @fromBackingInt(cfg.random),
        .random2 = @fromBackingInt(cfg.random2),
        .flip = cfg.double_option == @backingInt(core.options.Double.flip),
        .ln_mode = @fromBackingInt(cfg.ln_mode),
        .algorithm = @fromBackingInt(cfg.judge_algorithm),
        .seed = seed,
    };
}

/// In beatoraja's order. Any of them keeps the play from being saved.
pub const Assists = struct {
    expand_judge: bool = false,
    constant: bool = false,
    judge_area: bool = false,
    legacy: bool = false,
    mark_note: bool = false,
    bpm_guide: bool = false,
    no_mine: bool = false,

    pub const names = [_][]const u8{ "EXPAND JUDGE", "CONSTANT", "JUDGE AREA", "LEGACY NOTE", "MARK NOTE", "BPM GUIDE", "NO MINE" };

    /// `i` below `names.len`; `a` is a pointer, const or not.
    pub fn flag(a: anytype, i: usize) @TypeOf(&a.expand_judge) {
        inline for (@typeInfo(Assists).@"struct".field_names, 0..) |name, k| if (k == i) return &@field(a, name);
        unreachable;
    }
};

pub const Assist = struct {
    battle: bool = false,
    auto_scratch: bool = false,
    picked: Assists = .{},

    /// Changes the notes or their judging: beatoraja's ASSIST rather than LIGHT ASSIST.
    pub fn judging(a: Assist) bool {
        return a.battle or a.picked.legacy or a.picked.no_mine or a.picked.expand_judge;
    }

    /// The rest only draw aids: they judge nothing differently, but beatoraja counts them as assists too.
    pub fn any(a: Assist) bool {
        const p = a.picked;
        return a.judging() or p.constant or p.judge_area or p.mark_note or p.bpm_guide;
    }
};

pub fn assistOf(cfg: *const Config) Assist {
    return .{
        .battle = cfg.double_option >= @backingInt(core.options.Double.battle),
        .auto_scratch = cfg.double_option == @backingInt(core.options.Double.battle_auto_scratch),
        .picked = cfg.assist,
    };
}

/// A hand-edited value would crash an enum cast, or show one option and play another.
fn clampOptions(cfg: *Config) void {
    if (cfg.gauge) |g| {
        const shifted = g >= 6;
        cfg.gauge_type = if (shifted) @backingInt(core.gauge.Type.exhard) else g;
        cfg.gauge_auto_shift = @backingInt(if (shifted) core.options.Gas.select_to_under else core.options.Gas.none);
        cfg.gauge = null;
    }
    const top = struct {
        fn of(comptime E: type) u8 {
            return @intCast(std.enums.values(E).len - 1);
        }
    }.of;
    cfg.gauge_type = @min(cfg.gauge_type, @backingInt(core.gauge.Type.hazard));
    cfg.gauge_auto_shift = @min(cfg.gauge_auto_shift, top(core.options.Gas));
    cfg.gas_floor = @min(cfg.gas_floor, @backingInt(core.gauge.Type.normal));
    cfg.random = @min(cfg.random, top(core.options.Random));
    cfg.random2 = @min(cfg.random2, top(core.options.Random));
    cfg.double_option = @min(cfg.double_option, top(core.options.Double));
    cfg.judge_algorithm = @min(cfg.judge_algorithm, top(core.options.Algorithm));
    cfg.ln_mode = @min(cfg.ln_mode, top(core.options.LnMode));
    cfg.hs_fix = @min(cfg.hs_fix, 4);
}

test "an older gauge setting moves to the gauge and its auto shift" {
    var shifted: Config = .{ .gauge = 6 };
    clampOptions(&shifted);
    try std.testing.expectEqual(@as(u8, 4), shifted.gauge_type);
    try std.testing.expectEqual(core.options.Gas.select_to_under, playOptions(&shifted, 0).gas);
    var hard: Config = .{ .gauge = 3, .random = 200, .double_option = 9 };
    clampOptions(&hard);
    try std.testing.expectEqual(core.gauge.Type.hard, playOptions(&hard, 0).gauge);
    try std.testing.expectEqual(core.options.Gas.none, playOptions(&hard, 0).gas);
    try std.testing.expectEqual(core.options.Random.s_random_ex, playOptions(&hard, 0).random);
    try std.testing.expect(assistOf(&hard).auto_scratch);
}

test "each assist name has its flag, in beatoraja's order" {
    var a: Assists = .{};
    try std.testing.expectEqual(@typeInfo(Assists).@"struct".field_names.len, Assists.names.len);
    try std.testing.expectEqual(&a.expand_judge, Assists.flag(&a, 0));
    try std.testing.expectEqual(&a.no_mine, Assists.flag(&a, Assists.names.len - 1));
}

pub fn path(gpa: std.mem.Allocator) ![]u8 {
    const dir = try fs.dataDir(gpa);
    defer gpa.free(dir);
    return std.fmt.allocPrint(gpa, "{s}config.json", .{dir});
}

/// Tags match the fields of SkinSlots.
pub const SkinSlot = enum { select, decide, result, beat7, beat5, beat14, beat10, popn9, beat4, beat6 };

pub const builtin_skin = "builtin";

/// Empty means the default skin. Otherwise a skin file, or a folder searched for the right type.
pub const SkinSlots = struct {
    select: []const u8 = "",
    decide: []const u8 = "",
    result: []const u8 = "",
    beat7: []const u8 = "",
    beat5: []const u8 = "",
    beat14: []const u8 = "",
    beat10: []const u8 = "",
    popn9: []const u8 = "",
    beat4: []const u8 = "",
    beat6: []const u8 = "",

    pub fn get(s: SkinSlots, slot: SkinSlot) []const u8 {
        return switch (slot) {
            inline else => |t| @field(s, @tagName(t)),
        };
    }

    pub fn set(s: *SkinSlots, slot: SkinSlot, v: []const u8) void {
        switch (slot) {
            inline else => |t| @field(s, @tagName(t)) = v,
        }
    }
};

test "a slot overrides the default skin, and can ask for the built-in look" {
    var cfg: Config = .{ .skin = "dir" };
    try std.testing.expectEqualStrings("dir", cfg.skinFor(.result));
    cfg.skins.set(.result, "file");
    try std.testing.expectEqualStrings("file", cfg.skinFor(.result));
    cfg.skins.set(.result, builtin_skin);
    try std.testing.expectEqualStrings("", cfg.skinFor(.result));
}

pub var set_aside = false;

/// The defaults are saved on exit: keep the player's settings out of their way.
fn setAside(a: std.mem.Allocator, p: []const u8, why: anyerror) void {
    std.log.warn("config unreadable: {t}", .{why});
    // Until it has moved, saving defaults would write over the only copy of the player's settings.
    stuck = true;
    const bad = std.fmt.allocPrint(a, "{s}.bad", .{p}) catch return;
    fs.rename(p, bad) catch |e| return std.log.warn("could not move {s}: {t}", .{ p, e });
    stuck = false;
    set_aside = true;
}

/// Set when the unreadable file could not be moved: `save` then leaves it alone.
pub var stuck = false;

/// The result's strings live in `a`. A broken file falls back to defaults rather than blocking startup.
pub fn load(a: std.mem.Allocator) Config {
    const p = path(a) catch return .{};
    const bytes = fs.readAlloc(a, p, 1 << 20) catch |e| {
        if (e != error.FileNotFound) setAside(a, p, e);
        return .{};
    };
    var cfg = std.json.parseFromSliceLeaky(Config, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| {
        setAside(a, p, e);
        return .{};
    };
    cfg.clampCovers();
    clampOptions(&cfg);
    cfg.download_url = migrateDownloadUrl(cfg.download_url);
    dropPlainIr(&cfg);
    return cfg;
}

/// An older save may hold plain HTTP to the internet, which would send its token and next password readable.
fn dropPlainIr(cfg: *Config) void {
    if (!table.sendsInClear(cfg.ir_url)) return;
    std.log.warn("IR address {s} is plain HTTP on the internet: signed out, back to the default", .{cfg.ir_url});
    cfg.ir_url = (Config{}).ir_url;
    cfg.ir_token = "";
}

/// Saved copies of old defaults: one domain expired, the other caps out near 1 MB/s.
fn migrateDownloadUrl(url: []const u8) []const u8 {
    const old = [_][]const u8{ "https://bms.wrigglebug.xyz/download/package/{md5}", "https://bms.alvorna.com/api/hash?md5={md5}" };
    for (old) |o| {
        if (std.mem.eql(u8, url, o)) return default_download_url;
    }
    return url;
}

pub fn save(gpa: std.mem.Allocator, cfg: Config) !void {
    if (stuck) return error.ConfigUnreadable;
    const p = try path(gpa);
    defer gpa.free(p);
    const text = try std.json.Stringify.valueAlloc(gpa, cfg, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer gpa.free(text);
    try fs.writeAtomic(gpa, p, text);
}

pub const Binding = struct { lane: u8, key: u8 };

pub fn bindings(cfg: *const Config, mode: core.types.Mode) [input.code_count]?Binding {
    var t: [input.code_count]?Binding = @splat(null);
    const put = struct {
        fn f(tb: *[input.code_count]?Binding, code: u16, lane: u8, key: u8) void {
            if (code < tb.len) tb[code] = .{ .lane = lane, .key = key };
        }
    }.f;
    var copy = cfg.*;
    const keys = keysOf(&copy, mode);
    if (mode == .popn9 or mode == .beat4 or mode == .beat6) {
        for (keys, 0..) |code, i| put(&t, code, @intCast(i), 0);
        return t;
    }
    const per_side: usize = if (mode == .beat5 or mode == .beat10) 5 else 7;
    for (0..mode.players()) |side| {
        const inputs = keys[side * (per_side + 2) ..];
        const first = side * (per_side + 1);
        for (0..per_side) |i| put(&t, inputs[i], @intCast(first + i), 0);
        put(&t, inputs[per_side], @intCast(first + per_side), 0);
        put(&t, inputs[per_side + 1], @intCast(first + per_side), 1);
    }
    return t;
}

test "4 and 6 keys bind straight to their lanes" {
    var cfg: Config = .{};
    try std.testing.expectEqual(@as(u8, 3), bindings(&cfg, .beat4)[cfg.keys4[3]].?.lane);
    try std.testing.expectEqual(@as(u8, 5), bindings(&cfg, .beat6)[cfg.keys6[5]].?.lane);
}

test "each mode keeps its own keys, and old configs carry over" {
    var cfg: Config = .{};
    cfg.p1[0] = 100;
    cfg.p1[7] = 101;
    cfg.p2[0] = 102;
    const k5 = bindings(&cfg, .beat5);
    try std.testing.expectEqual(@as(u8, 0), k5[100].?.lane);
    try std.testing.expectEqual(@as(u8, 5), k5[101].?.lane);
    try std.testing.expectEqual(@as(u8, 6), bindings(&cfg, .beat10)[102].?.lane);
    try std.testing.expectEqual(@as(u8, 8), bindings(&cfg, .beat14)[102].?.lane);

    keysOf(&cfg, .beat5)[0] = 200;
    try std.testing.expectEqual(@as(u8, 0), bindings(&cfg, .beat5)[200].?.lane);
    try std.testing.expect(bindings(&cfg, .beat7)[200] == null);
    try std.testing.expectEqual(@as(u8, 0), bindings(&cfg, .beat7)[100].?.lane);
    try std.testing.expect(bindings(&cfg, .beat5)[100] == null);
}

test "a broken config is kept aside instead of being overwritten" {
    fs.io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fs.mkdirs(fs.test_data_dir);
    const p = try path(a);
    const bad = try std.fmt.allocPrint(a, "{s}.bad", .{p});
    defer fs.remove(bad);
    defer fs.remove(p);
    defer set_aside = false;
    try fs.write(p, "{ not json");
    const cfg = load(a);
    try std.testing.expectEqual(@as(Config, .{}).green_ms, cfg.green_ms);
    try std.testing.expect(set_aside);
    try std.testing.expect(!fs.exists(p));
    try std.testing.expectEqualStrings("{ not json", try fs.readAlloc(a, bad, 64));
}

test "an unreadable config that cannot be moved is never written over" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fs.mkdirs(fs.test_data_dir);
    const p = try path(a);
    const bad = try std.fmt.allocPrint(a, "{s}.bad", .{p});
    // A folder in the way makes the move fail.
    try fs.mkdirs(try std.fmt.allocPrint(a, "{s}/x", .{bad}));
    defer fs.removeTree(bad);
    defer fs.remove(p);
    defer stuck = false;
    try fs.write(p, "{ not json");
    _ = load(a);
    try std.testing.expect(stuck and !set_aside);
    try std.testing.expectError(error.ConfigUnreadable, save(a, .{}));
    try std.testing.expectEqualStrings("{ not json", try fs.readAlloc(a, p, 64));
}

test "the dead download default is replaced, custom ones stay" {
    try std.testing.expectEqualStrings(default_download_url, migrateDownloadUrl("https://bms.wrigglebug.xyz/download/package/{md5}"));
    try std.testing.expectEqualStrings(default_download_url, migrateDownloadUrl("https://bms.alvorna.com/api/hash?md5={md5}"));
    try std.testing.expectEqualStrings("https://example.com/{md5}", migrateDownloadUrl("https://example.com/{md5}"));
}

test "a saved plain-HTTP IR on the internet signs out, one at home stays" {
    var public: Config = .{ .ir_url = "http://ir.example.com", .ir_token = "t" };
    dropPlainIr(&public);
    try std.testing.expectEqualStrings((Config{}).ir_url, public.ir_url);
    try std.testing.expectEqualStrings("", public.ir_token);
    var home: Config = .{ .ir_url = "http://192.168.0.5:8730", .ir_token = "t" };
    dropPlainIr(&home);
    try std.testing.expectEqualStrings("http://192.168.0.5:8730", home.ir_url);
    try std.testing.expectEqualStrings("t", home.ir_token);
}

test "lift and the lane cover leave part of the lane open" {
    var cfg: Config = .{ .lane_cover = 0.6 };
    cfg.setLift(0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), cfg.lift, 0.001);
    cfg.setCover(0.9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), cfg.openLane(), 0.001);
    cfg.setHidden(-1);
    try std.testing.expectEqual(@as(f32, 0), cfg.hidden);
}
