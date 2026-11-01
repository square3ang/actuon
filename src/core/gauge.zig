//! LR2 gauges. Port of GaugeProperty.LR2 / GrooveGauge from lr2oraja (GPLv3). f32 on purpose:
//! the accumulated rounding is part of the behaviour being matched.
const std = @import("std");
const types = @import("types.zig");

pub const Type = enum(u8) { assist_easy, easy, normal, hard, exhard, hazard, class, exclass, exhardclass };
pub const count = 9;

const Modifier = enum { none, total, modify_damage };

const Element = struct {
    modifier: Modifier,
    min: f32,
    max: f32,
    init: f32,
    border: f32,
    death: f32,
    value: [6]f32,
    guts: ?[2]f32 = null,
    clear: types.Clear,
};

const elements = [count]Element{
    .{ .modifier = .total, .min = 2, .max = 100, .init = 20, .border = 60, .death = 0, .value = .{ 1.2, 1.2, 0.6, -3.2, -4.8, -1.6 }, .clear = .light_assist_easy },
    .{ .modifier = .total, .min = 2, .max = 100, .init = 20, .border = 80, .death = 0, .value = .{ 1.2, 1.2, 0.6, -3.2, -4.8, -1.6 }, .clear = .easy },
    .{ .modifier = .total, .min = 2, .max = 100, .init = 20, .border = 80, .death = 0, .value = .{ 1.0, 1.0, 0.5, -4.0, -6.0, -2.0 }, .clear = .normal },
    .{ .modifier = .modify_damage, .min = 0, .max = 100, .init = 100, .border = 0, .death = 2, .value = .{ 0.1, 0.1, 0.05, -6.0, -10.0, -2.0 }, .guts = .{ 32, 0.6 }, .clear = .hard },
    .{ .modifier = .modify_damage, .min = 0, .max = 100, .init = 100, .border = 0, .death = 2, .value = .{ 0.1, 0.1, 0.05, -12.0, -20.0, -2.0 }, .clear = .exhard },
    .{ .modifier = .none, .min = 0, .max = 100, .init = 100, .border = 0, .death = 2, .value = .{ 0.15, 0.06, 0, -100.0, -100.0, -10.0 }, .clear = .full_combo },
    .{ .modifier = .none, .min = 0, .max = 100, .init = 100, .border = 0, .death = 2, .value = .{ 0.10, 0.10, 0.05, -2, -3, -2 }, .guts = .{ 32, 0.6 }, .clear = .normal },
    .{ .modifier = .none, .min = 0, .max = 100, .init = 100, .border = 0, .death = 2, .value = .{ 0.10, 0.10, 0.05, -6.0, -10.0, -2.0 }, .guts = .{ 32, 0.6 }, .clear = .hard },
    .{ .modifier = .none, .min = 0, .max = 100, .init = 100, .border = 0, .death = 2, .value = .{ 0.10, 0.10, 0.05, -12.0, -20.0, -2.0 }, .clear = .exhard },
};

fn modify(f: f32, m: Modifier, total: f64, notes: u32) f32 {
    switch (m) {
        .none => return f,
        .total => {
            if (f <= 0) return f;
            const n: f64 = @floatFromInt(@max(notes, 1));
            return @floatCast(@as(f64, f) * total / n);
        },
        .modify_damage => {
            if (f >= 0) return f;
            const fix1: f32 = @floatCast(10.0 / @min(10.0, @max(1.0, @floor(total / 16.0) - 5.0)));
            const n = notes;
            const nf: f32 = @floatFromInt(n);
            const fix2: f32 = if (n <= 20)
                10.0
            else if (n < 30)
                8.0 + 0.2 * (30 - nf)
            else if (n < 60)
                5.0 + 0.2 * (60 - nf) / 3.0
            else if (n < 125)
                4.0 + (125 - nf) / 65.0
            else if (n < 250)
                3.0 + 0.008 * (250 - nf)
            else if (n < 500)
                2.0 + 0.004 * (500 - nf)
            else if (n < 1000)
                1.0 + 0.002 * (1000 - nf)
            else
                1.0;
            return f * @max(fix1, fix2);
        },
    }
}

pub const Gauge = struct {
    value: f32,
    el: *const Element,
    inc: [6]f32,

    pub fn set(g: *Gauge, v: f32) void {
        if (g.value > 0) {
            g.value = std.math.clamp(v, g.el.min, g.el.max);
            if (g.value < g.el.death) g.value = 0;
        }
    }

    pub fn update(g: *Gauge, judge: u8, rate: f32) void {
        var inc = g.inc[judge] * rate;
        if (inc < 0) {
            if (g.el.guts) |gut| {
                if (g.value < gut[0]) inc *= gut[1];
            }
        }
        g.set(g.value + inc);
    }

    pub fn qualified(g: *const Gauge) bool {
        return g.value > 0 and g.value >= g.el.border;
    }
};

pub fn init(ty: Type, total: f64, notes: u32) Gauge {
    const el = &elements[@backingInt(ty)];
    var g: Gauge = .{ .value = el.init, .el = el, .inc = el.value };
    for (&g.inc) |*v| v.* = modify(v.*, el.modifier, total, notes);
    return g;
}

pub fn clearOf(ty: Type) types.Clear {
    return elements[@backingInt(ty)].clear;
}

test "groove recovers by total/notes and floors at 2" {
    var g = init(.normal, 200, 100);
    g.update(0, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 22), g.value, 0.001);
    for (0..20) |_| g.update(4, 1);
    try std.testing.expectEqual(@as(f32, 2), g.value);
    try std.testing.expect(!g.qualified());
}

test "hard dies under 2 and applies note count damage" {
    var g = init(.hard, 300, 2000);
    g.update(4, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 90), g.value, 0.001);
    var few = init(.hard, 300, 20);
    few.update(4, 1); // fix2 = 10 at <=20 notes
    try std.testing.expectEqual(@as(f32, 0), few.value);
    var low = init(.hard, 300, 2000);
    low.value = 30;
    low.update(4, 1); // guts below 32%
    try std.testing.expectApproxEqAbs(@as(f32, 24), low.value, 0.001);
}
