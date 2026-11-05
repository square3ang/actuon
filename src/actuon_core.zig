pub const types = @import("core/types.zig");
pub const windows = @import("core/windows.zig");
pub const gauge = @import("core/gauge.zig");
pub const sim = @import("core/sim.zig");
pub const options = @import("core/options.zig");
pub const replay = @import("core/replay.zig");
pub const bms = @import("bms/parser.zig");
pub const bmson = @import("bms/bmson.zig");
pub const encoding = @import("bms/encoding.zig");

const std = @import("std");

/// The numbers are what the IR's upload and libactuon_core take.
pub const Format = enum(u8) {
    bms = 1,
    pms = 2,
    bmson = 3,

    /// As beatoraja: .bme and .bml are BMS.
    pub fn of(path: []const u8) Format {
        if (std.ascii.endsWithIgnoreCase(path, ".bmson")) return .bmson;
        if (std.ascii.endsWithIgnoreCase(path, ".pms")) return .pms;
        return .bms;
    }
};

/// Times past this overflow the audio frame and graph maths, which multiply microseconds.
const max_chart_us: i64 = 12 * 3600 * std.time.us_per_s;

pub fn parse(gpa: std.mem.Allocator, format: Format, data: []const u8, opts: bms.Options) !types.Chart {
    var o = opts;
    o.is_pms = format == .pms;
    var chart = if (format == .bmson) try bmson.parse(gpa, data) else try bms.parse(gpa, data, o);
    if (chart.last_time_us > max_chart_us) {
        chart.deinit();
        return error.TooLong;
    }
    return chart;
}

test "a chart's name picks its format" {
    try std.testing.expectEqual(Format.bmson, Format.of("a/B.BMSON"));
    try std.testing.expectEqual(Format.pms, Format.of("x.pms"));
    try std.testing.expectEqual(Format.bms, Format.of("x.bme"));
}

test "a chart longer than the cap is refused" {
    try std.testing.expectError(error.TooLong, parse(std.testing.allocator, .bms, "#BPM 120\n#WAV01 a.wav\n#00002:10000000000\n#00111:01\n", .{}));
    try std.testing.expectError(error.TooLong, parse(std.testing.allocator, .bms, "#BPM 0.001\n#WAV01 a.wav\n#99901:01\n", .{}));
}

test {
    _ = types;
    _ = windows;
    _ = gauge;
    _ = sim;
    _ = options;
    _ = replay;
    _ = bms;
    _ = bmson;
    _ = encoding;
}
