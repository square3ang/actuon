//! Lua skins: runs the script, converts the returned table for the JSON loader, and keeps the state
//! alive so functions (draw conditions, values, timers) stay callable. Skins are untrusted: io and
//! the dangerous parts of os are absent, and module loading stays inside the skin folder.
const std = @import("std");
const c = @import("c");
const fs = @import("../platform/fs.zig");
const m = @import("model.zig");
const skin_sound = @import("../audio/skin_sound.zig");
const jsonskin = @import("jsonskin.zig");
const J = std.json.Value;

/// Set while a scene draws, read by the main_state bindings.
pub var ctx: ?*const m.Ctx = null;

/// How many values one returned table may expand to: `t = {t, t}` doubles at every level.
const max_json_nodes = 1 << 20;

fn toJson(l: *c.lua_State, a: std.mem.Allocator, idx: c_int, depth: u32, nodes: *u32) anyerror!J {
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

/// A number id from a skin; out of range it names nothing, like any other unknown id.
fn checkId(l: ?*c.lua_State) i32 {
    return @intCast(std.math.clamp(c.luaL_checkinteger(l, 1), std.math.minInt(i32), std.math.maxInt(i32)));
}

fn msNumber(l: ?*c.lua_State) callconv(.c) c_int {
    const cx = ctx orelse {
        c.lua_pushinteger(l, 0);
        return 1;
    };
    c.lua_pushinteger(l, cx.num(cx.ud, checkId(l)) orelse 0);
    return 1;
}

fn msFloat(l: ?*c.lua_State) callconv(.c) c_int {
    const cx = ctx orelse {
        c.lua_pushnumber(l, 0);
        return 1;
    };
    c.lua_pushnumber(l, cx.float(cx.ud, checkId(l)));
    return 1;
}

fn msOption(l: ?*c.lua_State) callconv(.c) c_int {
    const cx = ctx orelse {
        c.lua_pushboolean(l, 0);
        return 1;
    };
    c.lua_pushboolean(l, @intFromBool(cx.opt(cx.ud, checkId(l))));
    return 1;
}

fn msText(l: ?*c.lua_State) callconv(.c) c_int {
    const cx = ctx orelse {
        _ = c.lua_pushstring(l, "");
        return 1;
    };
    const s = cx.str(cx.ud, checkId(l));
    _ = c.lua_pushlstring(l, s.ptr, s.len);
    return 1;
}

const timer_off: i64 = std.math.minInt(i64);

/// Micro-seconds like beatoraja's main_state.timer; Long.MIN_VALUE when off.
fn msTimer(l: ?*c.lua_State) callconv(.c) c_int {
    const cx = ctx orelse {
        c.lua_pushinteger(l, timer_off);
        return 1;
    };
    const id = c.luaL_checkinteger(l, 1);
    const on = id >= 0 and id < cx.timers.len and cx.timers[@intCast(id)] >= 0;
    c.lua_pushinteger(l, if (on) cx.timers[@intCast(id)] * 1000 else timer_off);
    return 1;
}

fn msNow(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(l, if (ctx) |cx| cx.now_ms * 1000 else 0);
    return 1;
}

fn msOffValue(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(l, timer_off);
    return 1;
}

fn msGaugeType(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(l, if (ctx) |cx| cx.num(cx.ud, m.gauge_type) orelse 0 else 0);
    return 1;
}

fn msGauge(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushnumber(l, if (ctx) |cx| cx.float(cx.ud, m.gauge_value) * 100 else 0);
    return 1;
}

fn msExScore(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushinteger(l, if (ctx) |cx| cx.num(cx.ud, 71) orelse 0 else 0);
    return 1;
}

fn msRate(l: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushnumber(l, if (ctx) |cx| cx.float(cx.ud, 110) else 0);
    return 1;
}

/// main_state.judge(i): the count of judge i, PG first.
fn msJudge(l: ?*c.lua_State) callconv(.c) c_int {
    const i = checkId(l);
    c.lua_pushinteger(l, if (ctx) |cx| cx.num(cx.ud, if (i == 5) 420 else 110 +| i) orelse 0 else 0);
    return 1;
}

/// Where audio_play goes. While `audio_quiet`, as during a load ahead of the scene, it only decodes.
pub const AudioHook = struct { ud: *anyopaque, f: *const fn (*anyopaque, []const u8, skin_sound.Op, f32) void };
pub var audio_hook: ?AudioHook = null;
pub var audio_quiet: bool = false;

fn audioCall(l: ?*c.lua_State, op: skin_sound.Op) c_int {
    const hook = audio_hook orelse return 0;
    var n: usize = 0;
    const p = c.lua_tolstring(l, 1, &n) orelse return 0;
    const vol = c.lua_tonumberx(l, 2, null);
    const gain: f32 = if (c.lua_type(l, 2) == c.LUA_TNUMBER) @floatCast(std.math.clamp(vol, 0, 2)) else 1;
    hook.f(hook.ud, p[0..n], if (audio_quiet and op != .stop) .cache else op, gain);
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

/// The running skin's `filepath` list, for get_path. Skins load on one thread at a time.
var path_files: []const J = &.{};
var path_arena: ?std.mem.Allocator = null;

/// skin_config.get_path(rel): an absolute, real path, since skins pass it to dofile.
fn getPath(l: ?*c.lua_State) callconv(.c) c_int {
    var n: usize = 0;
    const p = c.luaL_checklstring(l, 1, &n);
    const dir = std.mem.span(c.lua_tolstring(l, c.LUA_REGISTRYINDEX - 1, null));
    const a = path_arena orelse {
        // shortcut: past the load, wildcards stay as written; keep the arena if a skin plays one.
        c.lua_pushvalue(l, c.LUA_REGISTRYINDEX - 1);
        _ = c.lua_pushstring(l, "/");
        c.lua_pushvalue(l, 1);
        c.lua_concat(l, 3);
        return 1;
    };
    const rel = jsonskin.resolveWild(a, dir, path_files, p[0..n]) catch p[0..n];
    const out = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, rel }) catch return 0;
    _ = c.lua_pushlstring(l, out.ptr, out.len);
    return 1;
}

/// Lua side of beatoraja's helper modules; timers are µs, off is TIMER_OFF.
const prelude =
    \\local skin_dir = string.gsub((...), "\\", "/")
    \\-- Locals, since a skin can replace anything in `string`.
    \\local sub, find, gsub, tostring, type, rawget = string.sub, string.find, string.gsub, tostring, type, rawget
    \\local module_path, raw_searchpath = package.path, package.searchpath
    \\package.searchpath = nil
    \\-- skin_config.get_path hands out paths under skin_dir; anything else is relative to it.
    \\-- shortcut: a symlink inside the skin folder is still followed, resolve real paths if archives can carry them.
    \\local function checked(path)
    \\  path = gsub(tostring(path), "\\", "/")
    \\  if sub(path, 1, #skin_dir + 1) == skin_dir .. "/" then path = sub(path, #skin_dir + 2) end
    \\  if sub(path, 1, 1) == "/" or find(path, "^%a:") or find("/" .. path .. "/", "/../", 1, true) then
    \\    return nil, "skins read only their own folder"
    \\  end
    \\  return skin_dir .. "/" .. path
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
const Limits = struct {
    bytes: usize = 0,
    /// Off between calls, where a failed allocation would have no pcall to land in.
    capped: bool = false,
    /// Hook firings left in this call; 0 means the script ran out and stays out.
    steps: u32 = load_steps,
};

const max_bytes = 256 << 20;
const hook_every = 1 << 16;
// About 1e9 instructions for a load, 8e6 for one draw callback.
const load_steps = 1 << 14;
const call_steps = 1 << 7;

fn limitsOf(l: ?*c.lua_State) *Limits {
    var ud: ?*anyopaque = null;
    _ = c.lua_getallocf(l, &ud);
    return @ptrCast(@alignCast(ud.?));
}

fn cappedAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, old_or_tag: usize, new: usize) callconv(.c) ?*anyopaque {
    const lim: *Limits = @ptrCast(@alignCast(ud.?));
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
    const lim = limitsOf(l);
    if (lim.steps > 0) {
        lim.steps -= 1;
        return;
    }
    // Raising at every instruction from here on: a pcall in a loop cannot keep the script alive.
    _ = c.lua_sethook(l, onCount, c.LUA_MASKCOUNT, 1);
    _ = c.luaL_error(l, "skin script ran too long");
}

/// Every entry into skin code goes through here, with its budgets set.
fn protectedCall(l: *c.lua_State, args: c_int, results: c_int, steps: u32) c_int {
    const lim = limitsOf(l);
    if (lim.steps == 0) return c.LUA_ERRRUN;
    lim.steps = steps;
    lim.capped = true;
    defer lim.capped = false;
    return c.lua_pcallk(l, args, results, 0, 0, null);
}

fn newState(a: std.mem.Allocator, dir: []const u8) !*c.lua_State {
    const limits = try a.create(Limits);
    limits.* = .{};
    const l = c.lua_newstate(cappedAlloc, limits) orelse return error.Lua;
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
    if (protectedCall(l, 1, 0, load_steps) != c.LUA_OK) return error.Lua;
    return l;
}

fn runFile(l: *c.lua_State, a: std.mem.Allocator, path: []const u8) !J {
    const pz = try a.dupeSentinel(u8, path, 0);
    limitsOf(l).capped = true; // lua_load protects itself, and a script file can be any size
    const loaded = c.luaL_loadfilex(l, pz.ptr, "t");
    limitsOf(l).capped = false;
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

/// Runs the script without skin_config, which makes beatoraja Lua skins return just their header.
pub fn header(a: std.mem.Allocator, path: []const u8) !J {
    const l = try newState(a, std.fs.path.dirname(path) orelse ".");
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
    _ = c.lua_pushlstring(l, dir.ptr, dir.len);
    c.lua_pushcclosure(l, getPath, 1);
    c.lua_setfield(l, -2, "get_path");
    c.lua_setglobal(l, "skin_config");
    const zero_offsets = "setmetatable(skin_config.offset, { __index = function() return { x = 0, y = 0, w = 0, h = 0, r = 0, a = 0 } end })";
    if (c.luaL_loadstring(l, zero_offsets) == c.LUA_OK) _ = protectedCall(l, 0, 0, load_steps);
}

pub fn load(skin: *m.Skin, path: []const u8, resolver: *const fn (i32) bool, conf: jsonskin.Conf) ![]const ?[]const u8 {
    const a = skin.arena.allocator();
    const dir = std.fs.path.dirname(path) orelse ".";
    const head = try header(a, path);
    const l = try newState(a, dir);
    skin.lua = l;
    path_arena = a;
    defer path_arena = null;
    path_files = if (head == .object) if (head.object.get("filepath")) |f| (if (f == .array) f.array.items else &.{}) else &.{} else &.{};
    try jsonskin.applyConf(a, head, conf);
    pushConfig(l, head, dir, conf);
    return jsonskin.fromJson(skin, try runFile(l, a, path), head, dir, resolver, conf);
}

pub fn callBool(skin: *m.Skin, r: i32) bool {
    const l = skin.lua orelse return true;
    _ = c.lua_rawgeti(l, c.LUA_REGISTRYINDEX, r);
    defer c.lua_settop(l, 0);
    if (protectedCall(l, 0, 1, call_steps) != c.LUA_OK) return false;
    return c.lua_toboolean(l, -1) != 0;
}

/// Calls a text's value function; the result is copied to `buf`, cut if too long.
pub fn callStr(skin: *m.Skin, r: i32, buf: []u8) []const u8 {
    const l = skin.lua orelse return "";
    _ = c.lua_rawgeti(l, c.LUA_REGISTRYINDEX, r);
    defer c.lua_settop(l, 0);
    if (protectedCall(l, 0, 1, call_steps) != c.LUA_OK) return "";
    var len: usize = 0;
    const s = c.lua_tolstring(l, -1, &len) orelse return "";
    const n = @min(len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

pub fn callNum(skin: *m.Skin, r: i32) f64 {
    const l = skin.lua orelse return 0;
    _ = c.lua_rawgeti(l, c.LUA_REGISTRYINDEX, r);
    defer c.lua_settop(l, 0);
    if (protectedCall(l, 0, 1, call_steps) != c.LUA_OK) return 0;
    const v = c.lua_tonumberx(l, -1, null);
    // Callers cast this to integers; beyond 2^53 it is not a number any skin means, and NaN fails too.
    return if (@abs(v) < 9e15) v else 0;
}

test "skins cannot reach native code or bytecode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try newState(arena.allocator(), ".");
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
    try fs.mkdirs(dir);
    try fs.write(try std.fs.path.join(a, &.{ dir, "inside.lua" }), "return 7");
    try fs.write(try std.fs.path.join(a, &.{ root, "outside.lua" }), "return 8");
    const l = try newState(a, dir);
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

test "a script that never ends is stopped, and stays stopped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try newState(arena.allocator(), ".");
    var skin: m.Skin = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .lua = l };
    defer skin.deinit();
    try expectRuns(l,
        \\assert(not pcall(setmetatable, {}, { __gc = function() while true do end end }))
    );
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "return 12.5"));
    const fine = c.luaL_ref(l, c.LUA_REGISTRYINDEX);
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "return 12.5"));
    const after = c.luaL_ref(l, c.LUA_REGISTRYINDEX);
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, "while true do pcall(function() while true do end end) end"));
    const spin = c.luaL_ref(l, c.LUA_REGISTRYINDEX);
    try std.testing.expectEqual(@as(f64, 12.5), callNum(&skin, fine));
    try std.testing.expect(!callBool(&skin, spin));
    try std.testing.expectEqual(@as(f64, 0), callNum(&skin, after));
}

test "a script cannot allocate past the cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try newState(arena.allocator(), ".");
    defer c.lua_close(l);
    try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l,
        \\assert(not pcall(string.rep, "x", 1 << 34))
        \\assert(#string.rep("x", 1 << 20) == 1 << 20)
    ));
    try std.testing.expectEqual(c.LUA_OK, protectedCall(l, 0, 0, call_steps));
}

test "deep and self-repeating tables convert without a crash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try newState(a, ".");
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
}

test "numbers from Lua do not trap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const l = try newState(arena.allocator(), ".");
    var skin: m.Skin = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .lua = l };
    defer skin.deinit();
    try expectRuns(l,
        \\assert(main_state.judge(1 << 40) == 0)
        \\assert(main_state.judge(-(1 << 40)) == 0)
    );
    for ([_][*:0]const u8{ "return 0/0", "return 1e300", "return -1/0" }) |script| {
        try std.testing.expectEqual(c.LUA_OK, c.luaL_loadstring(l, script));
        try std.testing.expectEqual(@as(f64, 0), callNum(&skin, c.luaL_ref(l, c.LUA_REGISTRYINDEX)));
    }
}
