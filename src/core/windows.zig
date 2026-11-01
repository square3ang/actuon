//! LR2 judge windows. Port of JudgeProperty.LR2 / JudgeWindowRule.createLR2 from lr2oraja-endlessdream (GPLv3).
//! Values are {late bound, early bound} in microseconds, with dmtime = note time - input time.

pub const Window = [2]i64;

pub const note_base = [5]Window{
    .{ -21000, 21000 },
    .{ -60000, 60000 },
    .{ -120000, 120000 },
    .{ -200000, 200000 },
    .{ 0, 1000000 },
};
pub const ln_end_base = [4]Window{
    .{ -120000, 120000 },
    .{ -120000, 120000 },
    .{ -120000, 120000 },
    .{ -200000, 200000 },
};

const scaling = [4][5]i64{
    .{ 0, 0, 0, 0, 0 },
    .{ 0, 8000, 15000, 18000, 21000 },
    .{ 0, 24000, 30000, 40000, 60000 },
    .{ 0, 40000, 60000, 100000, 120000 },
};

fn scale(base_in: i64, judgerank: i64) i64 {
    var base = base_in;
    var sign: i64 = 1;
    if (base < 0) {
        base = -base;
        sign = -1;
    }
    if (judgerank >= 100) return @divTrunc(sign * base * judgerank, 100);
    const last = 4;
    const ji: usize = @intCast(@divTrunc(judgerank, 25));
    var s: usize = 0;
    while (s < scaling.len and base >= scaling[s][last]) s += 1;
    var n: i64 = undefined;
    var d: i64 = undefined;
    var x1: i64 = undefined;
    var x2: i64 = undefined;
    if (s < scaling.len) {
        n = base - scaling[s - 1][last];
        d = scaling[s][last] - scaling[s - 1][last];
        x1 = d * scaling[s - 1][ji] + n * (scaling[s][ji] - scaling[s - 1][ji]);
        x2 = d * scaling[s - 1][ji + 1] + n * (scaling[s][ji + 1] - scaling[s - 1][ji + 1]);
    } else {
        n = base;
        d = scaling[s - 1][last];
        x1 = n * scaling[s - 1][ji];
        x2 = n * scaling[s - 1][ji + 1];
    }
    return @divTrunc(sign * (x1 + @divTrunc((judgerank - @as(i64, @intCast(ji)) * 25) * (x2 - x1), 25)), d);
}

pub fn create(comptime N: usize, org: [N]Window, judgerank: i32) [N]Window {
    var judge = org;
    const rank: i64 = @max(judgerank, 0);
    for (0..3) |i| {
        for (0..2) |j| judge[i][j] = scale(org[i][j], rank);
    }
    var i: usize = 3;
    while (i > 0) {
        i -= 1;
        for (0..2) |j| {
            if (@abs(judge[i][j]) > @abs(judge[i + 1][j])) judge[i][j] = judge[i + 1][j];
        }
    }
    return judge;
}

test "published LR2 rank table" {
    const t = @import("std").testing;
    const cases = [_]struct { r: i32, pg: i64, gr: i64, gd: i64 }{
        .{ .r = 25, .pg = 8000, .gr = 24000, .gd = 40000 },
        .{ .r = 50, .pg = 15000, .gr = 30000, .gd = 60000 },
        .{ .r = 75, .pg = 18000, .gr = 40000, .gd = 100000 },
        .{ .r = 100, .pg = 21000, .gr = 60000, .gd = 120000 },
    };
    for (cases) |c| {
        const w = create(5, note_base, c.r);
        try t.expectEqual(c.pg, w[0][1]);
        try t.expectEqual(-c.pg, w[0][0]);
        try t.expectEqual(c.gr, w[1][1]);
        try t.expectEqual(c.gd, w[2][1]);
        try t.expectEqual(@as(i64, 200000), w[3][1]);
    }
    // LN release windows scale through the same curve and never exceed BAD.
    const e = create(4, ln_end_base, 25);
    try t.expectEqual(@as(i64, 40000), e[0][1]);
}
