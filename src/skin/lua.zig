//! Lua skins, untrusted: no io or dangerous os, and modules load only from inside the skin folder.
const std = @import("std");
const c = @import("c");
const fs = @import("../platform/fs.zig");
const m = @import("model.zig");
const skin_sound = @import("../audio/skin_sound.zig");
const jsonskin = @import("jsonskin.zig");
const db = @import("../db/db.zig");
const scene = @import("scene.zig");
const J = std.json.Value;

/// How many values one returned table may expand to: `t = {t, t}` doubles at every level.
const max_json_nodes = 1 << 20;
/// Copied strings spend the node budget too, so `{s, s, ...}` of one big string stops at 64 MiB.
const json_bytes_per_node = 64;

const JsonError = error{ BadSkin, OutOfMemory };

fn toJson(l: *c.lua_State, a: std.mem.Allocator, idx: c_int, depth: u32, nodes: *u32) JsonError!J {
    if (depth > 64) return .null;
    nodes.* += 1;
    if (nodes.* > max_json_nodes or c.lua_checkstack(l, 4) == 0) return error.BadSkin;
    const abs = c.lua_absindex(l, idx);
    switch (c.lua_type(l, abs)) {
        c.LUA_TNUMBER => {
            if (c.lua_isinteger(l, abs) != 0) return .{ .integer = c.lua_tointegerx(l, abs, null) };
            return .{ .float = c.lua_tonumberx(l, abs, null) };
        },
        c.LUA_TSTRING => {
            var n: usize = 0;
            const p = c.lua_tolstring(l, abs, &n);
            nodes.* += @intCast(n / json_bytes_per_node); // fits: Lua memory is capped at 256 MiB
            if (nodes.* > max_json_nodes) return error.BadSkin;
            return .{ .string = try a.dupe(u8, p[0..n]) };
        },
        c.LUA_TBOOLEAN => return .{ .bool = c.lua_toboolean(l, abs) != 0 },
        c.LUA_TFUNCTION => {
            c.lua_pushvalue(l, abs);
            const ref = c.luaL_ref(l, c.LUA_REGISTRYINDEX);
            var o: std.json.ObjectMap = .empty;
            try o.put(a, "__fn", .{ .integer = ref });
            return .{ .object = o };
        },
        c.LUA_TTABLE => {
            if (c.lua_rawlen(l, abs) > 0) {
                var out = std.json.Array.init(a);
                const n = c.lua_rawlen(l, abs);
                for (1..n + 1) |i| {
                    _ = c.lua_rawgeti(l, abs, @intCast(i));
                    try out.append(try toJson(l, a, -1, depth + 1, nodes));
                    c.lua_settop(l, -2);
                }
                return .{ .array = out };
            }
            var o: std.json.ObjectMap = .empty;
            c.lua_pushnil(l);
            while (c.lua_next(l, abs) != 0) {
                if (c.lua_type(l, -2) == c.LUA_TSTRING) {
                    var n: usize = 0;
                    const p = c.lua_tolstring(l, -2, &n);
                    try o.put(a, try a.dupe(u8, p[0..n]), try toJson(l, a, -1, depth + 1, nodes));
                }
                c.lua_settop(l, -2);
            }
            return .{ .object = o };
        },
        else => return .null,
    }
}

/// An out-of-range id names nothing, like any other unknown id.
fn checkId(l: ?*c.lua_State) i32 {
    return @intCast(std.math.clamp(c.luaL_checkinteger(l, 1), std.math.minInt(i32), std.math.maxInt(i32)));
}

fn msNumber(l: ?*c.lua_State) callconv(.c) c_int {
    const cx = hostOf(l).env.ctx orelse {
        c.lua_pushinteger(l, 0);
        return 1;
    };
    c.lua_pushinteger(l, cx.st.num(checkId(l)) orelse 0);
    return 1;
}

fn msFloat(l: ?*c.lua_State) callconv(.c) c_int {
    const cx = hostOf(l).env.ctx orelse {
        c.lua_pushnumber(l, 0);
        return 1;
    };
    c.lua_pushnumber(l, cx.st.float(checkId(l)));
    return 1;
}

fn msOption(l: ?*c.lua_State) callconv(.c) c_int {
    const cx = hostOf(l).env.ctx orelse {
        c.lua_pushboolean(l, 0);
        return 1;
    };
    c.lua_pushboolean(l, @intFromBool(cx.st.opt(checkId(l))));
    return 1;
}

fn msText(l: ?*c.lua_State) callconv(.c) c_int {
    const cx = hostOf(l).env.ctx orelse {
        _ = c.lua_pushstring(l, "");
        return 1;
    };
    const s = cx.st.str(checkId(l));
    _ = c.lua_pushlstring(l, s.ptr, s.len);
    return 1;
}

const timer_off: i64 = std.math.minInt(i64);

/// Microseconds like beatoraja's main_state.timer; Long.MIN_VALUE when off.
fn msTimer(l: ?*c.lua_State) callconv(.c) c_int {
    const cx = hostOf(l).env.ctx orelse {
        c.lua_pushinteger(l, timer_off);
        return 1;
    };
    const id = c.luaL_checkinteger(l, 1);
    const on = id >= 0 and id < cx.st.timers.len and cx.st.timers[@intCast(id)] >= 0;
    c.lua_pushinteger(l, if (on) cx.st.timers[@intCast(id)] * 1000 else timer_off);
    return 1;
}

fn msNow(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(l, if (hostOf(l).env.ctx) |cx| cx.now_ms * 1000 else 0);
    return 1;
}

fn msOffValue(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(l, timer_off);
    return 1;
}

fn msGaugeType(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(l, if (hostOf(l).env.ctx) |cx| cx.st.num(m.gauge_type) orelse 0 else 0);
    return 1;
}

fn msGauge(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushnumber(l, if (hostOf(l).env.ctx) |cx| cx.st.float(m.gauge_value) * 100 else 0);
    return 1;
}

fn msExScore(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(l, if (hostOf(l).env.ctx) |cx| cx.st.num(71) orelse 0 else 0);
    return 1;
}

fn msRate(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushnumber(l, if (hostOf(l).env.ctx) |cx| cx.st.float(110) else 0);
    return 1;
}

/// Judge i counts from PG = 0.
fn msJudge(l: ?*c.lua_State) callconv(.c) c_int {
    const i = checkId(l);
    c.lua_pushinteger(l, if (hostOf(l).env.ctx) |cx| cx.st.num(if (i == 5) 420 else 110 +| i) orelse 0 else 0);
    return 1;
}

pub const AudioHook = struct { ud: *anyopaque, f: *const fn (*anyopaque, []const u8, skin_sound.Op, f32) void };

/// What main_state reaches while a skin loads; the audio hook stays for the skin's life.
pub const Env = struct {
    ctx: ?*const m.Ctx = null,
    audio: ?AudioHook = null,
    /// As during a load ahead of the scene: audio_play only decodes.
    audio_quiet: bool = false,
};

fn audioCall(l: ?*c.lua_State, op: skin_sound.Op) c_int {
    const env = hostOf(l).env;
    const hook = env.audio orelse return 0;
    var n: usize = 0;
    const p = c.lua_tolstring(l, 1, &n) orelse return 0;
    const vol = c.lua_tonumberx(l, 2, null);
    const gain: f32 = if (c.lua_type(l, 2) == c.LUA_TNUMBER) @floatCast(std.math.clamp(vol, 0, 2)) else 1;
    hook.f(hook.ud, p[0..n], if (env.audio_quiet and op != .stop) .cache else op, gain);
    return 0;
}
fn msAudioPlay(l: ?*c.lua_State) callconv(.c) c_int {
    return audioCall(l, .play);
}
fn msAudioLoop(l: ?*c.lua_State) callconv(.c) c_int {
    return audioCall(l, .loop);
}
fn msAudioStop(l: ?*c.lua_State) callconv(.c) c_int {
    return audioCall(l, .stop);
}

/// Buttons and volumes have no effect here; scripts only need them to exist.
fn msZero(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(l, 0);
    return 1;
}

fn setFn(l: *c.lua_State, name: [*:0]const u8, f: c.lua_CFunction) void {
    c.lua_pushcclosure(l, f, 0);
    c.lua_setfield(l, -2, name);
}

fn registerMainState(l: *c.lua_State) void {
    c.lua_createtable(l, 0, 12);
    setFn(l, "number", msNumber);
    setFn(l, "float_number", msFloat);
    setFn(l, "option", msOption);
    setFn(l, "text", msText);
    setFn(l, "timer", msTimer);
    setFn(l, "time", msNow);
    setFn(l, "timer_off_value", msOffValue);
    setFn(l, "gauge_type", msGaugeType);
    setFn(l, "gauge", msGauge);
    setFn(l, "exscore", msExScore);
    setFn(l, "rate", msRate);
    setFn(l, "judge", msJudge);
    setFn(l, "audio_play", msAudioPlay);
    setFn(l, "audio_loop", msAudioLoop);
    setFn(l, "audio_stop", msAudioStop);
    for ([_][*:0]const u8{ "event_index", "volume_sys", "volume_key", "volume_bg" }) |name| setFn(l, name, msZero);
    c.lua_pushinteger(l, timer_off);
    c.lua_setfield(l, -2, "TIMER_OFF");
    c.lua_setglobal(l, "main_state");
}

/// Absolute, since skins pass the path to dofile.
fn getPath(l: ?*c.lua_State) callconv(.c) c_int {
    var n: usize = 0;
    const p = c.luaL_checklstring(l, 1, &n);
    const dir = std.mem.span(c.lua_tolstring(l, c.LUA_REGISTRYINDEX - 1, null));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = wildPath(hostOf(l), dir, p[0..n], &buf) orelse return 0;
    _ = c.lua_pushlstring(l, out.ptr, out.len);
    return 1;
}

/// Its arena is freed before the push, since a Lua error past that point skips Zig's defers.
fn wildPath(host: *const Host, dir: []const u8, rel: []const u8, buf: []u8) ?[]const u8 {
    // malloc like the state's own memory: the skin arena would grow at every call, and pages cost a mmap each.
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const picked = jsonskin.resolveWild(arena.allocator(), host.io, dir, host.path_files, rel) catch rel;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, picked }) catch null;
}

/// The real path of a file a skin opens, refused outside the real skin folder so a symlink cannot lead out.
fn realInside(l: ?*c.lua_State) callconv(.c) c_int {
    var n: usize = 0;
    const p = c.luaL_checklstring(l, 1, &n);
    const host = hostOf(l);
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const real = fs.realPath(fba.allocator(), host.io, p[0..n]) catch {
        c.lua_pushnil(l);
        _ = c.lua_pushstring(l, "cannot open ");
        c.lua_pushvalue(l, 1);
        c.lua_concat(l, 2);
        return 2;
    };
    if (!db.isUnder(real, host.root)) {
        c.lua_pushnil(l);
        _ = c.lua_pushstring(l, "skins read only their own folder");
        return 2;
    }
    _ = c.lua_pushlstring(l, real.ptr, real.len);
    return 1;
}

/// Steps one string.find, match, gmatch or gsub may take, so a skin cannot stall a frame.
const max_pattern_steps = 1 << 22;
/// lstrlib's MAXCCALLS and LUA_MAXCAPTURES.
const max_match_depth = 200;
const max_captures = 32;
const cap_unfinished = -1;
const cap_position = -2;

/// A walk of lstrlib's matcher that only counts its steps, as the count hook does not fire inside C.
const Matcher = struct {
    src: []const u8,
    pat: []const u8,
    steps: u32 = 0,
    depth: u32 = 0,
    level: usize = 0,
    capture: [max_captures]struct { init: usize, len: isize } = undefined,

    /// Malformed covers whatever lstrlib raises on, so the real call reports it.
    const Stop = error{ TooSlow, Malformed };

    fn step(mt: *Matcher, n: usize) Stop!void {
        mt.steps +|= @intCast(@min(n, max_pattern_steps));
        if (mt.steps > max_pattern_steps) return error.TooSlow;
    }

    /// Lua strings end in a NUL that lstrlib reads past either end.
    fn byteAt(s: []const u8, i: usize) u8 {
        return if (i < s.len) s[i] else 0;
    }

    fn classEnd(mt: *const Matcher, p: usize) Stop!usize {
        var q = p + 1;
        switch (mt.pat[p]) {
            '%' => return if (q < mt.pat.len) q + 1 else error.Malformed,
            '[' => {
                if (byteAt(mt.pat, q) == '^') q += 1;
                while (true) {
                    if (q >= mt.pat.len) return error.Malformed;
                    q += 1;
                    if (mt.pat[q - 1] == '%' and q < mt.pat.len) q += 1;
                    if (byteAt(mt.pat, q) == ']') return q + 1;
                }
            },
            else => return q,
        }
    }

    fn classMatches(ch: u8, cl: u8) bool {
        const a = std.ascii;
        const hit = switch (a.toLower(cl)) {
            'a' => a.isAlphabetic(ch),
            'c' => a.isControl(ch),
            'd' => a.isDigit(ch),
            'g' => ch > ' ' and ch < 0x7f,
            'l' => a.isLower(ch),
            'p' => ch > ' ' and ch < 0x7f and !a.isAlphanumeric(ch),
            's' => a.isWhitespace(ch),
            'u' => a.isUpper(ch),
            'w' => a.isAlphanumeric(ch),
            'x' => a.isHex(ch),
            else => return cl == ch,
        };
        return hit != a.isUpper(cl);
    }

    fn bracketMatches(mt: *const Matcher, ch: u8, p: usize, ec: usize) bool {
        var q = p;
        const sig = mt.pat[q + 1] != '^';
        if (!sig) q += 1;
        while (true) {
            q += 1;
            if (q >= ec) return !sig;
            if (mt.pat[q] == '%') {
                q += 1;
                if (classMatches(ch, mt.pat[q])) return sig;
            } else if (mt.pat[q + 1] == '-' and q + 2 < ec) {
                q += 2;
                if (mt.pat[q - 2] <= ch and ch <= mt.pat[q]) return sig;
            } else if (mt.pat[q] == ch) return sig;
        }
    }

    fn singleMatch(mt: *Matcher, s: usize, p: usize, ep: usize) Stop!bool {
        try mt.step(if (mt.pat[p] == '[') ep - p else 1);
        if (s >= mt.src.len) return false;
        const ch = mt.src[s];
        return switch (mt.pat[p]) {
            '.' => true,
            '%' => classMatches(ch, mt.pat[p + 1]),
            '[' => mt.bracketMatches(ch, p, ep - 1),
            else => mt.pat[p] == ch,
        };
    }

    fn match(mt: *Matcher, s_start: usize, p_start: usize) Stop!?usize {
        if (mt.depth == max_match_depth) return error.Malformed;
        mt.depth += 1;
        defer mt.depth -= 1;
        var s = s_start;
        var p = p_start;
        while (true) {
            try mt.step(1);
            if (p == mt.pat.len) return s;
            switch (mt.pat[p]) {
                '(' => return if (byteAt(mt.pat, p + 1) == ')') mt.startCapture(s, p + 2, cap_position) else mt.startCapture(s, p + 1, cap_unfinished),
                ')' => return mt.endCapture(s, p + 1),
                '$' => if (p + 1 == mt.pat.len) return if (s == mt.src.len) s else null,
                '%' => switch (byteAt(mt.pat, p + 1)) {
                    'b' => {
                        s = try mt.matchBalance(s, p + 2) orelse return null;
                        p += 4;
                        continue;
                    },
                    'f' => {
                        p += 2;
                        if (byteAt(mt.pat, p) != '[') return error.Malformed;
                        const ep = try mt.classEnd(p);
                        try mt.step(ep - p);
                        const prev = if (s == 0) 0 else mt.src[s - 1];
                        if (mt.bracketMatches(prev, p, ep - 1) or !mt.bracketMatches(byteAt(mt.src, s), p, ep - 1)) return null;
                        p = ep;
                        continue;
                    },
                    '0'...'9' => {
                        s = try mt.matchCapture(s, mt.pat[p + 1]) orelse return null;
                        p += 2;
                        continue;
                    },
                    else => {},
                },
                else => {},
            }
            const ep = try mt.classEnd(p);
            const suffix = byteAt(mt.pat, ep);
            if (!try mt.singleMatch(s, p, ep)) {
                if (suffix != '*' and suffix != '?' and suffix != '-') return null;
                p = ep + 1;
                continue;
            }
            switch (suffix) {
                '?' => {
                    if (try mt.match(s + 1, ep + 1)) |r| return r;
                    p = ep + 1;
                },
                '+' => return mt.maxExpand(s + 1, p, ep),
                '*' => return mt.maxExpand(s, p, ep),
                '-' => return mt.minExpand(s, p, ep),
                else => {
                    s += 1;
                    p = ep;
                },
            }
        }
    }

    fn maxExpand(mt: *Matcher, s: usize, p: usize, ep: usize) Stop!?usize {
        var i: usize = 0;
        while (try mt.singleMatch(s + i, p, ep)) i += 1;
        while (true) : (i -= 1) {
            if (try mt.match(s + i, ep + 1)) |r| return r;
            if (i == 0) return null;
        }
    }

    fn minExpand(mt: *Matcher, s_start: usize, p: usize, ep: usize) Stop!?usize {
        var s = s_start;
        while (true) : (s += 1) {
            if (try mt.match(s, ep + 1)) |r| return r;
            if (!try mt.singleMatch(s, p, ep)) return null;
        }
    }

    fn startCapture(mt: *Matcher, s: usize, p: usize, what: isize) Stop!?usize {
        if (mt.level >= max_captures) return error.Malformed;
        mt.capture[mt.level] = .{ .init = s, .len = what };
        mt.level += 1;
        const r = try mt.match(s, p);
        if (r == null) mt.level -= 1;
        return r;
    }

    fn endCapture(mt: *Matcher, s: usize, p: usize) Stop!?usize {
        var i = mt.level;
        const open = while (i > 0) {
            i -= 1;
            if (mt.capture[i].len == cap_unfinished) break i;
        } else return error.Malformed;
        mt.capture[open].len = @intCast(s - mt.capture[open].init);
        const r = try mt.match(s, p);
        if (r == null) mt.capture[open].len = cap_unfinished;
        return r;
    }

    fn matchCapture(mt: *Matcher, s: usize, digit: u8) Stop!?usize {
        const i = @as(isize, digit) - '1';
        if (i < 0 or i >= mt.level or mt.capture[@intCast(i)].len == cap_unfinished) return error.Malformed;
        const cap = mt.capture[@intCast(i)];
        if (cap.len < 0) return null;
        const len: usize = @intCast(cap.len);
        try mt.step(len);
        if (mt.src.len - s < len or !std.mem.eql(u8, mt.src[s..][0..len], mt.src[cap.init..][0..len])) return null;
        return s + len;
    }

    fn matchBalance(mt: *Matcher, s: usize, p: usize) Stop!?usize {
        if (p + 1 >= mt.pat.len) return error.Malformed;
        if (byteAt(mt.src, s) != mt.pat[p]) return null;
        var depth: usize = 1;
        for (mt.src[@min(s + 1, mt.src.len)..], s + 1..) |ch, i| {
            try mt.step(1);
            if (ch == mt.pat[p + 1]) {
                depth -= 1;
                if (depth == 0) return i + 1;
            } else if (ch == mt.pat[p]) depth += 1;
        }
        return null;
    }

    /// One attempt from each start, as lstrlib's search loops make them.
    fn attempt(mt: *Matcher, s: usize, p: usize) Stop!?usize {
        mt.level = 0;
        return mt.match(s, p);
    }

    /// lstrlib's lmemfind: memchr for the first byte, then a compare of the whole needle at each hit.
    fn plainFind(mt: *Matcher, init: usize) Stop!void {
        if (mt.pat.len == 0 or mt.pat.len > mt.src.len - init) return;
        const starts = mt.src[0 .. mt.src.len - mt.pat.len + 1];
        var s = init;
        // memchr covers about 32 bytes in the time of one step.
        while (std.mem.indexOfScalarPos(u8, starts, s, mt.pat[0])) |hit| : (s = hit + 1) {
            try mt.step((hit - s) / 32 + mt.pat.len);
            if (std.mem.eql(u8, mt.src[hit..][0..mt.pat.len], mt.pat)) return;
        }
        try mt.step((starts.len - s) / 32);
    }
};

const PatternCall = enum { find, match, gmatch, gsub };

/// lstrlib's posrelatI: 1-based, negative from the end.
fn startOf(l: ?*c.lua_State, idx: c_int, len: usize) ?usize {
    if (c.lua_type(l, idx) <= c.LUA_TNIL) return 1;
    var ok: c_int = 0;
    const pos = c.lua_tointegerx(l, idx, &ok);
    if (ok == 0) return null;
    if (pos > 0) return @intCast(pos);
    const back = @abs(pos);
    if (back == 0 or back > len) return 1;
    return len - back + 1;
}

/// Walks the search the real call would make, counting its steps in mt.
fn walkPattern(call: PatternCall, l: ?*c.lua_State, mt: *Matcher) Matcher.Stop!void {
    const src = mt.src;
    const plain = c.lua_toboolean(l, 5) != 0 or std.mem.indexOfAny(u8, mt.pat, "^$*+?.([%-") == null;
    const anchor = call != .gmatch and mt.pat.len > 0 and mt.pat[0] == '^';
    if (anchor and !(call == .find and plain)) mt.pat = mt.pat[1..];
    switch (call) {
        .find, .match => {
            const init = startOf(l, 4, src.len) orelse return;
            if (init > src.len + 1) return;
            if (call == .find and plain) return mt.plainFind(init - 1);
            var s = init - 1;
            while (true) : (s += 1) {
                if (try mt.attempt(s, 0) != null or anchor or s == src.len) return;
            }
        },
        .gmatch, .gsub => {
            var s: usize = if (call == .gsub) 0 else @min(startOf(l, 4, src.len) orelse return, src.len + 1) - 1;
            var max_n: usize = src.len + 1;
            if (call == .gsub and c.lua_type(l, 5) > c.LUA_TNIL) {
                var ok: c_int = 0;
                max_n = std.math.cast(usize, c.lua_tointegerx(l, 5, &ok)) orelse 0;
                if (ok == 0) return;
            }
            var last: ?usize = null;
            var n: usize = 0;
            while (n < max_n and s <= src.len) {
                if (try mt.attempt(s, 0)) |e| if (e != last) {
                    n += 1;
                    s = e;
                    last = e;
                    if (anchor) return;
                    continue;
                };
                if (anchor) return;
                s += 1;
            }
        },
    }
}

/// Pattern steps spend the call's hook firings, so a loop of slow matches runs out like any loop.
fn chargeSteps(l: ?*c.lua_State, steps: u32) bool {
    const host = hostOf(l);
    host.pattern_steps += steps;
    const firings = host.pattern_steps / hook_every;
    host.pattern_steps %= hook_every;
    if (firings <= host.steps) {
        host.steps -= firings;
        return true;
    }
    host.steps = 0;
    _ = c.lua_sethook(l, onCount, c.LUA_MASKCOUNT, 1);
    return false;
}

/// fits(call, s, p, ...): false refuses the call; anything lstrlib raises on is left for it to raise.
fn fitsPattern(l: ?*c.lua_State) callconv(.c) c_int {
    const call = std.meta.stringToEnum(PatternCall, std.mem.span(c.lua_tolstring(l, 1, null))).?;
    var fits = true;
    if (c.lua_type(l, 2) == c.LUA_TSTRING and c.lua_type(l, 3) == c.LUA_TSTRING) {
        var sn: usize = 0;
        var pn: usize = 0;
        const s = c.lua_tolstring(l, 2, &sn);
        const p = c.lua_tolstring(l, 3, &pn);
        var mt: Matcher = .{ .src = s[0..sn], .pat = p[0..pn] };
        walkPattern(call, l, &mt) catch |e| {
            fits = e != error.TooSlow;
        };
        fits = chargeSteps(l, mt.steps) and fits;
    }
    c.lua_pushboolean(l, @intFromBool(fits));
    return 1;
}

/// Timers are µs; off is TIMER_OFF.
const prelude =
    \\local root, real_inside, fits = ...
    \\local skin_dir = string.gsub(root, "\\", "/")
    \\-- Locals, since a skin can replace anything in `string`.
    \\local sub, gsub, tostring, type, rawget = string.sub, string.gsub, tostring, type, rawget
    \\-- The count hook does not fire inside C, so a backtracking pattern on a long string would hang the game.
    \\local function bounded(f, call)
    \\  return function(...)
    \\    if not fits(call, ...) then error("pattern too slow for a string this long", 2) end
    \\    return f(...)
    \\  end
    \\end
    \\-- Strings index `string`, so this covers s:find too.
    \\string.find, string.match = bounded(string.find, "find"), bounded(string.match, "match")
    \\string.gmatch, string.gsub = bounded(string.gmatch, "gmatch"), bounded(gsub, "gsub")
    \\-- Both loop in C once per count, and an empty string or table costs no memory to repeat.
    \\local rep, move, tonumber = string.rep, table.move, tonumber
    \\local function counted(n) if (tonumber(n) or 0) > 1e7 then error("count too large for a skin", 3) end end
    \\function string.rep(s, n, ...) counted(n) return rep(s, n, ...) end
    \\function table.move(a, f, e, ...) counted((tonumber(e) or 0) - (tonumber(f) or 0)) return move(a, f, e, ...) end
    \\local module_path, raw_searchpath = package.path, package.searchpath
    \\package.searchpath = nil
    \\-- skin_config.get_path hands out paths under skin_dir; anything else is relative to it.
    \\local function checked(path)
    \\  path = gsub(tostring(path), "\\", "/")
    \\  if sub(path, 1, #skin_dir + 1) == skin_dir .. "/" then path = sub(path, #skin_dir + 2) end
    \\  return real_inside(skin_dir .. "/" .. path)
    \\end
    \\-- The hook does not run inside finalizers, so one could spin forever.
    \\local raw_setmetatable = setmetatable
    \\function setmetatable(t, mt)
    \\  if type(mt) == "table" and rawget(mt, "__gc") ~= nil then error("no finalizers in skins", 2) end
    \\  return raw_setmetatable(t, mt)
    \\end
    \\package.loaded.main_state = main_state
    \\-- Java and file access do not exist here: skins that keep history files see an empty, write-discarding world.
    \\local stub = setmetatable({}, {})
    \\getmetatable(stub).__index = function() return stub end
    \\getmetatable(stub).__call = function() return stub end
    \\package.loaded.luajava = { bindClass = function() return stub end, newInstance = function() return stub end }
    \\luajava = package.loaded.luajava
    \\io = { open = function(_, mode)
    \\  if mode and mode:find("[wa]") then return { write = function(f) return f end, close = function() end, flush = function() end } end
    \\  return nil, "no file access in skins"
    \\end }
    \\package.loaded.io = io
    \\for _, k in ipairs({ "execute", "exit", "getenv", "remove", "rename", "setlocale", "tmpname" }) do os[k] = nil end
    \\-- No native code and no bytecode, which can corrupt memory: skins load Lua text only.
    \\package.loadlib, string.dump = nil, nil
    \\local raw_load, raw_loadfile = load, loadfile
    \\function load(chunk, name, _, ...) return raw_load(chunk, name, "t", ...) end
    \\function loadfile(path, _, ...)
    \\  local safe, e = checked(path)
    \\  if not safe then return nil, e end
    \\  return raw_loadfile(safe, "t", ...)
    \\end
    \\function dofile(path)
    \\  local f, e = loadfile(path)
    \\  if not f then error(e, 0) end
    \\  return f()
    \\end
    \\package.searchers[4], package.searchers[3] = nil, nil
    \\package.searchers[2] = function(name)
    \\  local path, e = raw_searchpath(name, module_path)
    \\  if not path then return e end
    \\  local f, le = loadfile(path)
    \\  if not f then error(le, 0) end
    \\  return f, path
    \\end
    \\local T = {}
    \\function T.now_timer(id) local t = main_state.timer(id); if t == main_state.TIMER_OFF then return 0 end return main_state.time() - t end
    \\function T.is_timer_on(id) return main_state.timer(id) ~= main_state.TIMER_OFF end
    \\function T.is_timer_off(id) return main_state.timer(id) == main_state.TIMER_OFF end
    \\function T.new_passive_timer() return function() return main_state.TIMER_OFF end end
    \\function T.timer_observe_boolean(f)
    \\  local on = main_state.TIMER_OFF
    \\  return function() if f() then if on == main_state.TIMER_OFF then on = main_state.time() end else on = main_state.TIMER_OFF end return on end
    \\end
    \\function T.timer_observe_number(f)
    \\  local v, on = nil, main_state.TIMER_OFF
    \\  return function() local x = f(); if x ~= v then v = x; on = main_state.time() end return on end
    \\end
    \\package.loaded.timer_util = T
    \\package.loaded.event_util = setmetatable({}, { __index = function() return function() return function() end end end })
;

/// Lives as long as its state, reached through the allocator's user data.
const Host = struct {
    bytes: usize = 0,
    /// Off between calls, where a failed allocation would have no pcall to land in.
    capped: bool = false,
    /// Hook firings left in this call; 0 means the script ran out and stays out.
    steps: u32 = load_steps,
    /// Pattern steps short of one hook firing, kept so many small matches still add up.
    pattern_steps: u32 = 0,
    /// SDL ticks past which the call is out, as C work inside one instruction does not count steps.
    deadline_ns: u64 = std.math.maxInt(u64),
    io: std.Io,
    /// The skin folder with symlinks resolved.
    root: []const u8,
    env: Env = .{},
    /// The header's filepath entries, so get_path picks wildcards as a load does.
    path_files: []const J = &.{},
};

const max_bytes = 256 << 20;
// Small, so a loop of cheap instructions that each do long C work (string.rep) still meets the clock check soon.
const hook_every = 1 << 8;
// About 1e9 instructions for a load, 8e6 for one draw callback.
const load_steps = 1 << 22;
const call_steps = 1 << 15;
/// Wall time per hook firing: 250 ms for a draw callback, about 30 s for a load.
const ns_per_firing = 250 * std.time.ns_per_ms / call_steps;

fn hostOf(l: ?*c.lua_State) *Host {
    var ud: ?*anyopaque = null;
    _ = c.lua_getallocf(l, &ud);
    return @ptrCast(@alignCast(ud.?));
}

fn cappedAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, old_or_tag: usize, new: usize) callconv(.c) ?*anyopaque {
    const lim: *Host = @ptrCast(@alignCast(ud.?));
    const old = if (ptr == null) 0 else old_or_tag; // without a block Lua passes a type tag here
    if (new == 0) {
        std.c.free(ptr);
        lim.bytes -= old;
        return null;
    }
    if (lim.capped and new > old and lim.bytes - old + new > max_bytes) return null;
    const out = std.c.realloc(ptr, new) orelse return null;
    lim.bytes = lim.bytes - old + new;
    return out;
}

fn onCount(l: ?*c.lua_State, _: ?*c.lua_Debug) callconv(.c) void {
    const lim = hostOf(l);
    if (lim.steps > 0 and c.SDL_GetTicksNS() < lim.deadline_ns) {
        lim.steps -= 1;
        return;
    }
    lim.steps = 0;
    // Raising at every instruction from here on: a pcall in a loop cannot keep the script alive.
    _ = c.lua_sethook(l, onCount, c.LUA_MASKCOUNT, 1);
    _ = c.luaL_error(l, "skin script ran too long");
}

/// Every entry into skin code goes through here, with its budgets set.
fn protectedCall(l: *c.lua_State, args: c_int, results: c_int, steps: u32) c_int {
    const lim = hostOf(l);
    if (lim.steps == 0) return c.LUA_ERRRUN;
    lim.steps = steps;
    lim.deadline_ns = c.SDL_GetTicksNS() + @as(u64, steps) * ns_per_firing;
    lim.capped = true;
    defer lim.capped = false;
    return c.lua_pcallk(l, args, results, 0, 0, null);
}

fn newState(a: std.mem.Allocator, io: std.Io, dir: []const u8) !*c.lua_State {
    const host = try a.create(Host);
    host.* = .{ .io = io, .root = try fs.realPath(a, io, dir) };
    const l = c.lua_newstate(cappedAlloc, host) orelse return error.Lua;
    errdefer c.lua_close(l);
    _ = c.lua_sethook(l, onCount, c.LUA_MASKCOUNT, hook_every);
    const libs = [_]struct { [*:0]const u8, c.lua_CFunction }{
        .{ "_G", c.luaopen_base },
        .{ "package", c.luaopen_package },
        .{ "string", c.luaopen_string },
        .{ "table", c.luaopen_table },
        .{ "math", c.luaopen_math },
        .{ "utf8", c.luaopen_utf8 },
        .{ "os", c.luaopen_os }, // reduced to time and date by the prelude
    };
    for (libs) |lib| {
        c.luaL_requiref(l, lib[0], lib[1], 1);
        c.lua_settop(l, -2);
    }
    // package: only skin-relative Lua modules; native modules are never loadable.
    _ = c.lua_getglobal(l, "package");
    const lp = try std.fmt.allocPrintSentinel(a, "{s}/?.lua;{s}/?.luaskin", .{ dir, dir }, 0);
    _ = c.lua_pushstring(l, lp.ptr);
    c.lua_setfield(l, -2, "path");
    _ = c.lua_pushstring(l, "");
    c.lua_setfield(l, -2, "cpath");
    c.lua_settop(l, -2);
    registerMainState(l);
    if (c.luaL_loadstring(l, prelude) != c.LUA_OK) return error.Lua;
    _ = c.lua_pushlstring(l, dir.ptr, dir.len);
    c.lua_pushcclosure(l, realInside, 0);
    c.lua_pushcclosure(l, fitsPattern, 0);
    if (protectedCall(l, 3, 0, load_steps) != c.LUA_OK) return error.Lua;
    return l;
}

fn runFile(l: *c.lua_State, a: std.mem.Allocator, path: []const u8) !J {
    const pz = try a.dupeSentinel(u8, path, 0);
    hostOf(l).capped = true; // lua_load protects itself, and a script file can be any size
    const loaded = c.luaL_loadfilex(l, pz.ptr, "t");
    hostOf(l).capped = false;
    if (loaded != c.LUA_OK or protectedCall(l, 0, 1, load_steps) != c.LUA_OK) {
        // A script can raise a table, which has no text.
        const text: ?[*:0]const u8 = c.lua_tolstring(l, -1, null);
        std.log.err("skin lua: {s}", .{text orelse "error without a message"});
        return error.Lua;
    }
    if (c.lua_type(l, -1) != c.LUA_TTABLE) return error.BadSkin;
    var nodes: u32 = 0;
    const root = try toJson(l, a, -1, 0, &nodes);
    c.lua_settop(l, 0);
    return root;
}

/// Without skin_config, beatoraja Lua skins return just their header.
pub fn header(a: std.mem.Allocator, io: std.Io, path: []const u8) !J {
    const l = try newState(a, io, std.fs.path.dirname(path) orelse ".");
    defer c.lua_close(l);
    return runFile(l, a, path);
}

/// Options default to each property's first item, like a fresh beatoraja config.
fn pushConfig(l: *c.lua_State, head: J, dir: []const u8, conf: jsonskin.Conf) void {
    c.lua_createtable(l, 0, 4);
    c.lua_createtable(l, 0, 0); // option: name -> op
    c.lua_createtable(l, 0, 0); // enabled_options: list of op
    var n: c.lua_Integer = 0;
    const props = if (head == .object) head.object.get("property") else null;
    if (props) |ps| if (ps == .array) for (ps.array.items) |p| {
        const item = jsonskin.defaultItem(p) orelse continue;
        const first = item.get("op") orelse continue;
        if (first != .integer) continue;
        const name = p.object.get("name") orelse continue;
        if (name != .string) continue;
        _ = c.lua_pushlstring(l, name.string.ptr, name.string.len);
        c.lua_pushinteger(l, first.integer);
        c.lua_settable(l, -4);
        n += 1;
        c.lua_pushinteger(l, first.integer);
        c.lua_rawseti(l, -2, n);
    };
    c.lua_setfield(l, -3, "enabled_options");
    c.lua_setfield(l, -2, "option");
    c.lua_createtable(l, 0, 0);
    var offs = conf.offset.map.iterator();
    while (offs.next()) |e| {
        c.lua_createtable(l, 0, 6);
        for (jsonskin.Offset.axes, 0..) |name, i| {
            c.lua_pushinteger(l, e.value_ptr.axis(@intCast(i)).*);
            c.lua_setfield(l, -2, name.ptr);
        }
        _ = c.lua_pushlstring(l, e.key_ptr.ptr, e.key_ptr.len);
        c.lua_insert(l, -2);
        c.lua_settable(l, -3);
    }
    c.lua_setfield(l, -2, "offset");
    const files = if (head == .object) head.object.get("filepath") else null;
    hostOf(l).path_files = if (files) |f| (if (f == .array) f.array.items else &.{}) else &.{};
    _ = c.lua_pushlstring(l, dir.ptr, dir.len);
    c.lua_pushcclosure(l, getPath, 1);
    c.lua_setfield(l, -2, "get_path");
    c.lua_setglobal(l, "skin_config");
    const zero_offsets = "setmetatable(skin_config.offset, { __index = function() return { x = 0, y = 0, w = 0, h = 0, r = 0, a = 0 } end })";
    if (c.luaL_loadstring(l, zero_offsets) == c.LUA_OK) _ = protectedCall(l, 0, 0, load_steps);
}

pub fn load(skin: *m.Skin, io: std.Io, path: []const u8, resolver: *const fn (i32) bool, conf: jsonskin.Conf, env: Env) ![]const ?[]const u8 {
    const a = skin.arena.allocator();
    const dir = std.fs.path.dirname(path) orelse ".";
    const head = try header(a, io, path);
    const l = try newState(a, io, dir);
    skin.lua = l;
    const host = hostOf(l);
    host.env = env;
    defer host.env = .{ .audio = env.audio };
    try jsonskin.applyConf(a, head, conf);
    pushConfig(l, head, dir, conf);
    return jsonskin.fromJson(skin, io, try runFile(l, a, path), head, dir, resolver, conf);
}

/// Leaves the callback's result on top, with main_state reading `ctx` while it runs.
fn callRef(ctx: *const m.Ctx, l: *c.lua_State, r: i32) bool {
    const host = hostOf(l);
    host.env.ctx = ctx;
    defer host.env.ctx = null;
    _ = c.lua_rawgeti(l, c.LUA_REGISTRYINDEX, r);
    return protectedCall(l, 0, 1, call_steps) == c.LUA_OK;
}

pub fn callBool(ctx: *const m.Ctx, skin: *m.Skin, r: i32) bool {
    const l = skin.lua orelse return true;
    defer c.lua_settop(l, 0);
    if (!callRef(ctx, l, r)) return false;
    return c.lua_toboolean(l, -1) != 0;
}

pub fn callStr(ctx: *const m.Ctx, skin: *m.Skin, r: i32, buf: []u8) []const u8 {
    const l = skin.lua orelse return "";
    defer c.lua_settop(l, 0);
    if (!callRef(ctx, l, r)) return "";
    var len: usize = 0;
    const s = c.lua_tolstring(l, -1, &len) orelse return "";
    const n = @min(len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

pub fn callNum(ctx: *const m.Ctx, skin: *m.Skin, r: i32) f64 {
    const l = skin.lua orelse return 0;
    defer c.lua_settop(l, 0);
    if (!callRef(ctx, l, r)) return 0;
    const v = c.lua_tonumberx(l, -1, null);
    // Callers cast this to integers, so it is clamped, keeping its sign: TIMER_OFF must stay negative.
    return if (std.math.isNan(v)) 0 else std.math.clamp(v, -9e15, 9e15);
}

test "skins cannot reach native code or bytecode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try newState(arena.allocator(), std.testing.io, ".");
    defer c.lua_close(l);
    const script =
        \\assert(package.loadlib == nil and string.dump == nil)
        \\assert(package.searchers[3] == nil and package.searchers[4] == nil)
        \\assert(load("\27Lua") == nil)
        \\assert(load("return 7")() == 7)
        \\assert(load("return x", "c", "t", { x = 8 })() == 8)
        \\package.cpath = "./?.so"
        \\assert(not pcall(require, "no_such_module"))
    ;
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, script));
    try std.testing.expectEqual(c.LUA_OK, c.lua_pcallk(l, 0, 0, 0, 0, null));
}

fn expectRuns(l: *c.lua_State, script: [*:0]const u8) !void {
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, script));
    try std.testing.expectEqual(c.LUA_OK, c.lua_pcallk(l, 0, 0, 0, 0, null));
}

test "file access stops at the skin folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = try std.fs.path.join(a, &.{ root, "s" });
    try fs.mkdirs(std.testing.io, dir);
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ dir, "inside.lua" }), "return 7");
    try fs.write(std.testing.io, try std.fs.path.join(a, &.{ root, "outside.lua" }), "return 8");
    const l = try newState(a, std.testing.io, dir);
    defer c.lua_close(l);
    _ = c.lua_pushlstring(l, dir.ptr, dir.len);
    c.lua_setglobal(l, "SKIN");
    try expectRuns(l,
        \\assert(package.searchpath == nil)
        \\assert(dofile("inside.lua") == 7)
        \\assert(dofile(SKIN .. "/inside.lua") == 7)
        \\assert(loadfile("inside.lua")() == 7)
        \\assert(require("inside") == 7)
        \\assert(loadfile("../outside.lua") == nil)
        \\assert(loadfile(SKIN .. "/../outside.lua") == nil)
        \\assert(loadfile("..\\outside.lua") == nil)
        \\assert(loadfile("/etc/hostname") == nil)
        \\assert(loadfile("C:/Windows/win.ini") == nil)
        \\assert(not pcall(dofile, "../outside.lua"))
        \\package.path = "../?.lua;" .. SKIN .. "/../?.lua"
        \\assert(not pcall(require, "outside"))
        \\string.sub = function() return SKIN .. "/" end
        \\string.find = function() return nil end
        \\assert(loadfile("../outside.lua") == nil)
    );
}

test "a symlink cannot lead a skin out of its folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const dir = try std.fs.path.join(a, &.{ root, "s" });
    try fs.mkdirs(io, try std.fs.path.join(a, &.{ dir, "sub" }));
    try fs.mkdirs(io, try std.fs.path.join(a, &.{ root, "secret" }));
    try fs.write(io, try std.fs.path.join(a, &.{ dir, "sub", "inside.lua" }), "return 7");
    try fs.write(io, try std.fs.path.join(a, &.{ root, "secret", "key.lua" }), "return 9");
    const links = [_]struct { []const u8, []const u8, bool }{
        .{ "../secret/key.lua", "s/file.lua", false },
        .{ "../secret", "s/away", true },
        .{ "sub/inside.lua", "s/near.lua", false },
    };
    // Windows makes symlinks only with a privilege the test may lack.
    for (links) |ln| tmp.dir.symLink(io, ln[0], ln[1], .{ .is_directory = ln[2] }) catch |e| {
        return if (@import("builtin").os.tag == .windows) error.SkipZigTest else e;
    };
    const l = try newState(a, io, dir);
    defer c.lua_close(l);
    try expectRuns(l,
        \\assert(loadfile("near.lua")() == 7)
        \\local f, e = loadfile("file.lua")
        \\assert(f == nil and e == "skins read only their own folder")
        \\assert(loadfile("away/key.lua") == nil)
        \\assert(not pcall(dofile, "file.lua"))
        \\assert(not pcall(require, "file"))
        \\assert(not pcall(require, "away.key"))
    );
}

test "a script that never ends is stopped, and stays stopped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try newState(arena.allocator(), std.testing.io, ".");
    var skin: m.Skin = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .lua = l };
    defer skin.deinit();
    var st: scene.State = .{};
    const ctx = st.loadCtx();
    try expectRuns(l,
        \\assert(not pcall(setmetatable, {}, { __gc = function() while true do end end }))
    );
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "return 12.5"));
    const fine = c.luaL_ref(l, c.LUA_REGISTRYINDEX);
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "return 12.5"));
    const after = c.luaL_ref(l, c.LUA_REGISTRYINDEX);
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "while true do pcall(function() while true do end end) end"));
    const spin = c.luaL_ref(l, c.LUA_REGISTRYINDEX);
    try std.testing.expectEqual(@as(f64, 12.5), callNum(&ctx, &skin, fine));
    try std.testing.expect(!callBool(&ctx, &skin, spin));
    try std.testing.expectEqual(@as(f64, 0), callNum(&ctx, &skin, after));
}

test "a script cannot allocate past the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try newState(arena.allocator(), std.testing.io, ".");
    defer c.lua_close(l);
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l,
        \\assert(not pcall(string.rep, "x", 1 << 34))
        \\assert(#string.rep("x", 1 << 20) == 1 << 20)
        \\assert(not pcall(string.rep, "", 1e15))
        \\assert(not pcall(table.move, {}, 1, 1e15, 1))
        \\assert(table.move({ 1, 2 }, 1, 2, 2)[3] == 2)
    ));
    try std.testing.expectEqual(c.LUA_OK, protectedCall(l, 0, 0, call_steps));
}

test "deep and self-repeating tables convert without a crash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try newState(a, std.testing.io, ".");
    defer c.lua_close(l);
    var nodes: u32 = 0;

    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "local t = {} for i = 1, 500 do t = i % 2 == 0 and { t } or { k = t } end return t"));
    try std.testing.expectEqual(c.LUA_OK, c.lua_pcallk(l, 0, 1, 0, 0, null));
    _ = try toJson(l, a, -1, 0, &nodes);
    c.lua_settop(l, 0);

    nodes = 0;
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "local t = { 1 } for i = 1, 60 do t = { t, t } end return t"));
    try std.testing.expectEqual(c.LUA_OK, c.lua_pcallk(l, 0, 1, 0, 0, null));
    try std.testing.expectError(error.BadSkin, toJson(l, a, -1, 0, &nodes));
    c.lua_settop(l, 0);

    nodes = 0;
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "local s = string.rep('x', 1 << 22) local t = {} for i = 1, 100 do t[i] = s end return t"));
    try std.testing.expectEqual(c.LUA_OK, c.lua_pcallk(l, 0, 1, 0, 0, null));
    try std.testing.expectError(error.BadSkin, toJson(l, a, -1, 0, &nodes));
}

test "a backtracking pattern on a long string is refused, not run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try newState(arena.allocator(), std.testing.io, ".");
    defer c.lua_close(l);
    try expectRuns(l,
        \\local long, slow = string.rep("a", 1e5), string.rep("a-", 12) .. "b"
        \\assert(not pcall(string.find, long, slow))
        \\assert(not pcall(function() return long:find(slow) end))
        \\assert(not pcall(string.gsub, long, slow, ""))
        \\assert(not pcall(string.match, long, slow))
        \\assert(not pcall(string.gmatch, long, slow))
        \\assert(long:find("b", 1, true) == nil)
        \\assert(long:find("aab") == nil)
        \\local needle = string.rep("a", 5e4) .. "b"
        \\assert(not pcall(string.find, long, needle))
        \\assert(not pcall(string.find, long, needle, 1, true))
        \\assert(not pcall(string.find, long, "^[" .. string.rep("b", 1e5) .. "a]*x"))
        \\assert(not pcall(string.gsub, string.rep("a ", 5e3), string.rep("%f[%a]", 2e5) .. "x", ""))
        \\assert(("bg_01.png"):match("^(.-)%.(%a+)$") == "bg_01")
        \\assert(select(2, ("a,b,c"):gsub(",", ";")) == 2)
        \\-- Fast on a long string though a worst-case bound on their quantifiers would refuse them.
        \\assert((long .. ".png"):match("^(.-)%.(%a+)$") == long)
        \\assert(long:find("^a*b?c?d?$") == 1)
        \\assert(select(2, long:gsub("(a)(a?)", "%2")) == 5e4)
        \\local n = 0 for w in (long .. " x"):gmatch("%S+") do n = n + 1 end assert(n == 2)
        \\assert(not pcall(string.gsub, ("("):rep(1e5), "%b()", ""))
    );
}

test "a loop of slow matches runs out of the callback's steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try newState(arena.allocator(), std.testing.io, ".");
    defer c.lua_close(l);
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "s = string.rep('a', 15e5) function f(n) for i = 1, n do s:find('%d') end end"));
    try std.testing.expectEqual(c.LUA_OK, protectedCall(l, 0, 0, load_steps));
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "f(1)"));
    try std.testing.expectEqual(c.LUA_OK, protectedCall(l, 0, 0, call_steps));
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "f(10)"));
    try std.testing.expect(protectedCall(l, 0, 0, call_steps) != c.LUA_OK);
}

test "a loop of long C calls runs out of the callback's time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try newState(arena.allocator(), std.testing.io, ".");
    defer c.lua_close(l);
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "for i = 1, 1e9 do local s = string.rep('x', 1e6) end"));
    const start = c.SDL_GetTicksNS();
    try std.testing.expect(protectedCall(l, 0, 0, call_steps) != c.LUA_OK);
    try std.testing.expect(c.SDL_GetTicksNS() - start < 2 * std.time.ns_per_s);
}

test "get_path picks a wildcard file after the load too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    for ([_][]const u8{ "f/a.ttf", "f/b.ttf" }) |f| {
        const full = try std.fs.path.join(a, &.{ dir, f });
        try fs.mkdirs(std.testing.io, std.fs.path.dirname(full).?);
        try fs.write(std.testing.io, full, "");
    }
    const head = try std.json.parseFromSliceLeaky(J, a,
        \\{"filepath":[{"name":"Font","path":"f/*.ttf","def":"b.ttf"}]}
    , .{});
    const l = try newState(a, std.testing.io, dir);
    var skin: m.Skin = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .lua = l };
    defer skin.deinit();
    pushConfig(l, head, dir, .{});
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "return skin_config.get_path('f/*.ttf')"));
    var st: scene.State = .{};
    var buf: [256]u8 = undefined;
    const got = callStr(&st.loadCtx(), &skin, c.luaL_ref(l, c.LUA_REGISTRYINDEX), &buf);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/f/b.ttf", .{dir}), got);
}

test "numbers from Lua do not trap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try newState(arena.allocator(), std.testing.io, ".");
    var skin: m.Skin = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .lua = l };
    defer skin.deinit();
    var st: scene.State = .{};
    st.timers[5] = 2;
    const ctx = st.loadCtx();
    // Outside a call the state reads no ctx, so a skin cannot keep one past its frame.
    try expectRuns(l,
        \\assert(main_state.judge(1 << 40) == 0)
        \\assert(main_state.judge(-(1 << 40)) == 0)
        \\assert(main_state.timer(5) == main_state.TIMER_OFF)
    );
    const cases = [_]struct { [*:0]const u8, f64 }{
        .{ "return main_state.timer(5)", 2000 },
        .{ "return 0/0", 0 },
        .{ "return 1e300", 9e15 },
        .{ "return -1/0", -9e15 },
        // An off timer stays off, or a skin's closed panel would show for good.
        .{ "return require('timer_util').timer_observe_boolean(function() return false end)()", -9e15 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, case[0]));
        try std.testing.expectEqual(case[1], callNum(&ctx, &skin, c.luaL_ref(l, c.LUA_REGISTRYINDEX)));
    }
}
