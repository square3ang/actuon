//! User settings, persisted as JSON in the data directory.
const std = @import("std");
const fs = @import("../platform/fs.zig");
const input = @import("../input/input.zig");
const core = @import("actuon_core");

const default_download_url = "https://gingerrush.com/download/package/{md5}";

pub const Config = struct {
    /// The most of the lane that lift and the lane cover may take between them.
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

    /// The share of the lane notes fall through, top cover to judge line.
    pub fn openLane(cfg: *const Config) f32 {
        return 1 - cfg.lift - cfg.lane_cover;
    }

    roots: []const []const u8 = &.{},
    tables: []const []const u8 = &.{"https://stellabms.xyz/st/table.html"},
    width: u32 = 1280,
    height: u32 = 720,
    fullscreen: bool = false,
    vsync: i32 = 1,
    /// Frames per second at most; 0 leaves it to VSync.
    fps_limit: u32 = 0,
    /// 0 off, 1 on, 2 on with Boost.
    reflex: i32 = 0,
    /// Deblocks BGA movies and upscales them with FSRCNNX instead of plain filtering.
    bga_upscale: bool = true,
    /// Off skips loading BGA images and movies.
    bga: bool = true,
    audio_rate: u32 = 48000,
    audio_frames: u32 = 128,
    /// PortAudio name of an output. Empty picks the output automatically.
    audio_device: []const u8 = "",
    /// Key sampling rate during play in Hz. 0 uses OS key events instead.
    input_poll_hz: u32 = 1000,
    volume: f32 = 0.8,
    bgm_volume: f32 = 0.5,
    sfx_volume: f32 = 0.8,
    /// Added to input timestamps: positive means "the player hits late, forgive it".
    judge_offset_ms: i32 = 0,
    visual_offset_ms: i32 = 0,
    /// Index into the gauge types up to hazard; `gas` means auto shift from EX HARD.
    gauge: u8 = gas,
    random: u8 = 0,
    /// What LNs the chart leaves open become: 0 LN, 1 CN, 2 HCN.
    ln_mode: u8 = 0,
    /// What a play is measured against, an index into play.pace_targets.
    pace_target: u8 = 0,
    /// The versus score board sits on the left instead of the right.
    versus_panel_left: bool = false,
    /// 0 start BPM, 1 max BPM, 2 main BPM (mode of the chart), 3 off (classic HS).
    hs_fix: u8 = 2,
    /// Green number: milliseconds a note is visible at the reference BPM.
    green_ms: u32 = 600,
    lane_cover: f32 = 0,
    /// Fractions of the lane: raises the judge line, and hides notes just above it.
    lift: f32 = 0,
    hidden: f32 = 0,
    /// The default skin; a slot in `skins` overrides it.
    skin: []const u8 = "",
    skins: SkinSlots = .{},
    /// A folder holding select and decide music, ahead of the skin's. Empty for the skin's own.
    bgm_path: []const u8 = "",
    /// The folder picked to search for music sets, any player's.
    bgm_root: []const u8 = "",
    /// A folder of system sounds, ahead of the skin's. Empty for the skin's own.
    sound_path: []const u8 = "",
    sound_root: []const u8 = "",
    /// An i18n language code. Empty follows the OS language.
    language: []const u8 = "",
    ir_url: []const u8 = "https://ir.actuon.app",
    ir_token: []const u8 = "",
    /// Off keeps failed plays off the IR, as beatoraja's "Complete song". Versus rounds always send.
    ir_send_failed: bool = true,
    /// Either a direct archive or a JSON answer naming one (see download.packageUrl).
    download_url: []const u8 = default_download_url,
    /// scancode (or joystick code) per physical button: 7 keys, scratch A, scratch B for each side.
    /// `p1` is the 7 key layout; the rest of the double layouts start from these two.
    p1: [9]u16 = .{ 29, 22, 27, 7, 6, 9, 25, 225, 224 },
    p2: [9]u16 = .{ 16, 14, 54, 15, 55, 51, 56, 229, 228 },
    /// PMS: 9 buttons
    pms: [9]u16 = .{ 4, 22, 7, 9, 44, 13, 14, 15, 51 },
    /// Per side: keys, scratch A, scratch B. Null until set, which keeps an older config's keys.
    keys5: ?[7]u16 = null,
    keys10: ?[14]u16 = null,
    keys14: ?[18]u16 = null,
    keys4: [4]u16 = .{ 7, 9, 13, 14 },
    keys6: [6]u16 = .{ 22, 7, 9, 13, 14, 15 },
    /// Song select takes the 7 key inputs as beatoraja does, with option panels on Start and Select.
    beatoraja_select: bool = false,
    /// beatoraja's defaults, Q and W.
    start_select: [2]u16 = .{ 20, 26 },

    /// What a slot shows, empty for the built-in look.
    pub fn skinFor(cfg: *const Config, slot: SkinSlot) []const u8 {
        const v = cfg.skins.get(slot);
        if (std.mem.eql(u8, v, builtin_skin)) return "";
        return if (v.len > 0) v else cfg.skin;
    }
};

/// The layout for a mode, filled in from the older shared one the first time it is needed.
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

pub const gas: u8 = 6;

pub fn gaugeType(setting: u8) core.gauge.Type {
    return if (setting == gas) .exhard else @fromBackingInt(@intCast(@min(setting, 5)));
}

pub fn path(gpa: std.mem.Allocator) ![]u8 {
    const dir = try fs.dataDir(gpa);
    defer gpa.free(dir);
    return std.fmt.allocPrint(gpa, "{s}config.json", .{dir});
}

/// The result's strings live in `a`. A broken file falls back to defaults rather than blocking startup.
/// A screen or key mode with a skin of its own. Tags match the fields of SkinSlots.
pub const SkinSlot = enum { select, decide, result, beat7, beat5, beat14, beat10, popn9, beat4, beat6 };

/// In a slot: the built-in look, whatever the default skin is.
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

/// Set when `load` could not read the file, so the game can tell the player.
pub var set_aside = false;

/// The defaults are saved on exit: keep the player's settings out of their way.
fn setAside(a: std.mem.Allocator, p: []const u8, why: anyerror) void {
    std.log.warn("config unreadable: {t}", .{why});
    set_aside = true;
    const bad = std.fmt.allocPrint(a, "{s}.bad", .{p}) catch return;
    fs.rename(p, bad) catch |e| std.log.warn("could not move {s}: {t}", .{ p, e });
}

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
    // A hand-edited value would show one mode, play another and read scores under a third.
    cfg.ln_mode = @min(cfg.ln_mode, 2);
    cfg.download_url = migrateDownloadUrl(cfg.download_url);
    return cfg;
}

/// Saved copies of old defaults: one domain expired, the other caps out near 1 MB/s.
fn migrateDownloadUrl(url: []const u8) []const u8 {
    const old = [_][]const u8{ "https://bms.wrigglebug.xyz/download/package/{md5}", "https://bms.alvorna.com/api/hash?md5={md5}" };
    for (old) |o| {
        if (std.mem.eql(u8, url, o)) return default_download_url;
    }
    return url;
}

pub fn save(gpa: std.mem.Allocator, cfg: Config) void {
    const p = path(gpa) catch return;
    defer gpa.free(p);
    const text = std.json.Stringify.valueAlloc(gpa, cfg, .{ .whitespace = .indent_2 }) catch return;
    defer gpa.free(text);
    fs.writeAtomic(gpa, p, text) catch |e| std.log.err("config save failed: {t}", .{e});
}

pub const Binding = struct { lane: u8, key: u8 };

/// Input code to lane table for a mode.
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

    // Changing 5 key leaves 7 key alone.
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

test "the dead download default is replaced, custom ones stay" {
    try std.testing.expectEqualStrings(default_download_url, migrateDownloadUrl("https://bms.wrigglebug.xyz/download/package/{md5}"));
    try std.testing.expectEqualStrings(default_download_url, migrateDownloadUrl("https://bms.alvorna.com/api/hash?md5={md5}"));
    try std.testing.expectEqualStrings("https://example.com/{md5}", migrateDownloadUrl("https://example.com/{md5}"));
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
