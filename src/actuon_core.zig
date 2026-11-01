//! Deterministic game core plus chart decoding; shared by the client, tools and libactuon_core.
pub const types = @import("core/types.zig");
pub const windows = @import("core/windows.zig");
pub const gauge = @import("core/gauge.zig");
pub const sim = @import("core/sim.zig");
pub const options = @import("core/options.zig");
pub const replay = @import("core/replay.zig");
pub const bms = @import("bms/parser.zig");
pub const bmson = @import("bms/bmson.zig");
pub const encoding = @import("bms/encoding.zig");

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
