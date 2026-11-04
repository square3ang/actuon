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

pub fn parse(gpa: std.mem.Allocator, format: Format, data: []const u8, opts: bms.Options) !types.Chart {
    if (format == .bmson) return bmson.parse(gpa, data);
    var o = opts;
    o.is_pms = format == .pms;
    return bms.parse(gpa, data, o);
}

test "a chart's name picks its format" {
    try std.testing.expectEqual(Format.bmson, Format.of("a/B.BMSON"));
    try std.testing.expectEqual(Format.pms, Format.of("x.pms"));
    try std.testing.expectEqual(Format.bms, Format.of("x.bme"));
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
