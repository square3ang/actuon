//! Input capture. Each OS path timestamps events as close to the hardware as it can and hands them
//! to the sim thread through a queue, so judgment never depends on the render loop:
//! Linux evdev when the player turns it on (kernel timestamps), Windows RawInput thread, macOS IOKit HID
//! callback; SDL events (their own timestamps) are the fallback and carry joystick input everywhere.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const fs = @import("../platform/fs.zig");

pub const Raw = struct { mono_ns: u64, code: u16, down: bool };

/// Input codes: SDL scancodes as-is; joystick buttons and axes above them.
pub const joy_base: u16 = 512;
pub const joy_axis_base: u16 = joy_base + 128; // pairs: +axis*2 (positive), +axis*2+1 (negative)
pub const code_count = joy_axis_base + 32;

var q_buf: [4096]Raw = undefined;
var q_head: std.atomic.Value(u32) = .init(0);
var q_tail: std.atomic.Value(u32) = .init(0);
/// Producers: the OS input thread and the SDL main loop, hence the lock on the write side.
var q_lock: std.atomic.Value(bool) = .init(false);

pub fn push(ev: Raw) void {
    {
        while (q_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer q_lock.store(false, .release);
        const h = q_head.load(.monotonic);
        if (h -% q_tail.load(.acquire) >= q_buf.len) return;
        q_buf[h % q_buf.len] = ev;
        q_head.store(h +% 1, .release);
    }
    _ = pushes.fetchAdd(1, .release);
    if (builtin.os.tag == .windows) actuon_input_wake() else fs.io.futexWake(u32, &pushes.raw, 1);
}

/// Counts pushes, for the futex the sim thread sleeps on.
var pushes: std.atomic.Value(u32) = .init(0);

/// Sleeps up to `ns`, less once an event is queued, so a press is judged without waiting out the sim's tick.
pub fn wait(ns: u64) void {
    // Windows futex timeouts round to the system timer, too coarse for the tick.
    if (builtin.os.tag == .windows) return actuon_input_wait(ns);
    const seen = pushes.load(.acquire);
    if (q_tail.load(.monotonic) != q_head.load(.acquire)) return;
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(ns), .clock = .awake } };
    fs.io.futexWaitTimeout(u32, &pushes.raw, seen, timeout) catch {};
}

pub fn pop() ?Raw {
    const t = q_tail.load(.monotonic);
    if (t == q_head.load(.acquire)) return null;
    const ev = q_buf[t % q_buf.len];
    q_tail.store(t +% 1, .release);
    return ev;
}

pub fn clear() void {
    while (pop()) |_| {}
}

/// Sampling rate during play. 0 leaves the OS event paths in charge.
var poll_hz: std.atomic.Value(u32) = .init(0);

pub fn setPollRate(hz: u32) void {
    poll_hz.store(@min(hz, 8000), .release);
}

/// True once a direct keyboard path runs; the SDL keyboard events are then ignored during play.
pub var direct_keyboard: std.atomic.Value(bool) = .init(false);
/// Direct paths see input system-wide, so they only deliver while our window has focus.
pub var focused: std.atomic.Value(bool) = .init(false);

// PS/2 set 1 make codes (equal to Linux KEY_* below 84) to SDL scancodes.
const set1_to_sdl = blk: {
    var t: [128]u16 = @splat(0);
    const row = struct {
        fn f(table: *[128]u16, start: usize, codes: []const u16) void {
            for (codes, 0..) |code, i| table[start + i] = code;
        }
    }.f;
    row(&t, 1, &.{ 41, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 45, 46, 42, 43 }); // esc,1-0,-,=,bs,tab
    row(&t, 16, &.{ 20, 26, 8, 21, 23, 28, 24, 12, 18, 19, 47, 48, 40, 224 }); // qwertyuiop[] enter lctrl
    row(&t, 30, &.{ 4, 22, 7, 9, 10, 11, 13, 14, 15, 51, 52, 53, 225, 49 }); // asdfghjkl;'` lshift \
    row(&t, 44, &.{ 29, 27, 6, 25, 5, 17, 16, 54, 55, 56, 229, 85, 226, 44, 57 }); // zxcvbnm,./ rshift kp* lalt space caps
    row(&t, 59, &.{ 58, 59, 60, 61, 62, 63, 64, 65, 66, 67 }); // f1-f10
    row(&t, 71, &.{ 95, 96, 97, 86, 92, 93, 94, 87, 89, 90, 91, 98, 99 }); // keypad
    t[97] = 228; // Linux KEY_RIGHTCTRL
    t[100] = 230; // Linux KEY_RIGHTALT
    t[103] = 82; // up
    t[105] = 80; // left
    t[106] = 79; // right
    t[108] = 81; // down
    t[110] = 73; // insert
    t[111] = 76; // delete
    t[102] = 74; // home
    t[107] = 77; // end
    t[104] = 75; // page up
    t[109] = 78; // page down
    t[96] = 88; // kp enter
    t[98] = 84; // kp /
    break :blk t;
};

/// Called from src/input/rawinput_win.c with a Linux-style key code (extended keys already folded).
export fn actuon_input_push_set1(code: u32, down: c_int) callconv(.c) void {
    if (!focused.load(.acquire) or code >= set1_to_sdl.len or poll_hz.load(.acquire) != 0) return;
    const sc = set1_to_sdl[code];
    if (sc != 0) push(.{ .mono_ns = c.SDL_GetTicksNS(), .code = sc, .down = down != 0 });
}

/// Called from src/input/hid_macos.c: HID usage IDs are exactly SDL scancodes.
export fn actuon_input_push_hid(usage: u32, down: c_int) callconv(.c) void {
    if (!focused.load(.acquire) or usage == 0 or usage >= joy_base) return;
    push(.{ .mono_ns = c.SDL_GetTicksNS(), .code = @intCast(usage), .down = down != 0 });
}

extern fn actuon_rawinput_start() c_int;
extern fn actuon_rawinput_sample(bits: *KeyBits) void;
extern fn actuon_hid_start() c_int;
extern fn actuon_input_wait_start() void;
extern fn actuon_input_wait(ns: u64) void;
extern fn actuon_input_wake() void;

/// `evdev` opts Linux into /dev/input; without it Linux keeps SDL's key events and their compositor timestamps.
pub fn startDirect(evdev_on: bool) void {
    switch (builtin.os.tag) {
        .linux => evdev.set(evdev_on),
        .windows => {
            actuon_input_wait_start();
            if (actuon_rawinput_start() != 0) direct_keyboard.store(true, .release);
        },
        .macos => if (actuon_hid_start() != 0) direct_keyboard.store(true, .release),
        else => {},
    }
    // shortcut: macOS has no key state sampler and stays on HID events, add CGEventSourceKeyState with a keycode table when it can be tested there.
    // Linux starts it with evdev, which settings can turn on later.
    if (builtin.os.tag == .windows and direct_keyboard.load(.acquire)) startSampler();
}

fn startSampler() void {
    const t = c.SDL_CreateThread(pollThread, "input-poll", null);
    if (t != null) c.SDL_DetachThread(t);
}

/// Turns Linux evdev input on or off while the game runs.
pub fn setEvdev(on: bool) void {
    evdev.set(on);
}

/// One bit per Linux-style key code, the layout EVIOCGKEY returns.
const KeyBits = [set1_to_sdl.len / 8]u8;

fn sample(bits: *KeyBits) void {
    switch (builtin.os.tag) {
        .linux => evdev.sample(bits),
        .windows => actuon_rawinput_sample(bits),
        else => {},
    }
}

/// Pushes every key that differs between two samples, stamped with the sample time.
fn pushEdges(prev: *const KeyBits, cur: *const KeyBits, ns: u64) void {
    for (prev, cur, 0..) |p, n, byte| {
        var changed = p ^ n;
        while (changed != 0) : (changed &= changed - 1) {
            const bit: u3 = @intCast(@ctz(changed));
            const sc = set1_to_sdl[byte * 8 + bit];
            if (sc != 0) push(.{ .mono_ns = ns, .code = sc, .down = n >> bit & 1 != 0 });
        }
    }
}

/// The usual rhythm game loop: read the whole key state on a fixed clock.
fn pollThread(_: ?*anyopaque) callconv(.c) c_int {
    _ = c.SDL_SetCurrentThreadPriority(c.SDL_THREAD_PRIORITY_TIME_CRITICAL);
    var prev: KeyBits = @splat(0);
    var was_on = false;
    var next: u64 = 0;
    while (true) {
        // Without a direct path (Linux evdev off) there is nothing to sample.
        const hz = if (direct_keyboard.load(.acquire)) poll_hz.load(.acquire) else 0;
        if (hz == 0) {
            was_on = false;
            c.SDL_Delay(20);
            continue;
        }
        var cur: KeyBits = @splat(0);
        sample(&cur);
        const now = c.SDL_GetTicksNS();
        // A key already held when sampling starts is not a press.
        if (was_on and focused.load(.acquire)) pushEdges(&prev, &cur, now);
        prev = cur;
        was_on = true;
        // After a stall, carry on from now instead of sampling in a burst to catch up.
        next = @max(next + 1_000_000_000 / @as(u64, hz), now);
        c.SDL_DelayPrecise(next -| c.SDL_GetTicksNS());
    }
}

const evdev = if (builtin.os.tag == .linux) struct {
    const linux = std.os.linux;
    const EV_KEY = 1;
    const InputEvent = extern struct { sec: isize, usec: isize, type: u16, code: u16, value: i32 };
    // EVIOCSCLOCKID = _IOW('E', 0xa0, int): kernel event timestamps in CLOCK_MONOTONIC.
    const EVIOCSCLOCKID: u32 = 0x400445a0;
    // EVIOCGBIT(EV_KEY, 64 bytes): which keys a device has, to skip mice and power buttons.
    const EVIOCGBIT_KEY: u32 = 0x80404521;
    // EVIOCGKEY(16 bytes): the keys held right now, for codes below 128.
    const EVIOCGKEY: u32 = 0x80104518;

    const max_events = 64;
    /// udev opens a new node to the player a moment after it appears.
    const rescan_ns = 5 * std.time.ns_per_s;

    var fds: [32]linux.pollfd = undefined;
    /// The /dev/input number behind each slot of fds.
    var event_nums: [fds.len]u8 = undefined;
    /// Keys each slot has pushed as down, for when its device goes with them still held.
    var held: [fds.len]std.StaticBitSet(set1_to_sdl.len) = @splat(.empty);
    /// The sampler reads this while the evdev thread adds devices.
    var n: std.atomic.Value(usize) = .init(0);

    fn sample(bits: *KeyBits) void {
        for (fds[0..n.load(.acquire)]) |f| {
            var one: KeyBits = @splat(0);
            if (linux.errno(linux.ioctl(f.fd, EVIOCGKEY, @intFromPtr(&one))) != .SUCCESS) continue;
            for (bits, one) |*b, o| b.* |= o;
        }
    }

    fn monoNs() u64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }

    /// The first slot an unplugged device left, else the next unused one.
    fn freeSlot(used: []const linux.pollfd) ?usize {
        for (used, 0..) |f, i| if (f.fd < 0) return i;
        return if (used.len < fds.len) used.len else null;
    }

    fn releaseHeld(slot: usize, ns: u64) void {
        var it = held[slot].iterator(.{});
        while (it.next()) |code| {
            push(.{ .mono_ns = ns, .code = set1_to_sdl[code], .down = false });
            held[slot].unset(code);
        }
    }

    /// When a node last came or went, or null if that cannot be read.
    fn nodesChangedAt() ?i64 {
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, "/dev/input", 0, .{ .MTIME = true }, &st)) != .SUCCESS) return null;
        return st.mtime.sec;
    }

    /// /dev/input/event`i` opened, if it is a keyboard this user may read.
    fn openKeyboard(i: usize) ?i32 {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "/dev/input/event{d}", .{i}, 0) catch return null;
        const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        const fd: i32 = @intCast(rc);
        var bits: [64]u8 = @splat(0);
        if (linux.errno(linux.ioctl(fd, EVIOCGBIT_KEY, @intFromPtr(&bits))) != .SUCCESS or bits[3] & 0x40 == 0) { // KEY_A (30)
            _ = linux.close(fd);
            return null;
        }
        return fd;
    }

    fn readable() bool {
        for (0..max_events) |i| if (openKeyboard(i)) |fd| {
            _ = linux.close(fd);
            return true;
        };
        return false;
    }

    /// Opens every keyboard not open yet, so one plugged in during play works at once.
    fn openKeyboards() void {
        var open: std.StaticBitSet(max_events) = .empty;
        for (fds[0..n.load(.monotonic)], event_nums[0..n.load(.monotonic)]) |f, num| if (f.fd >= 0) open.set(num);
        for (0..max_events) |i| {
            if (open.isSet(i)) continue;
            const slot = freeSlot(fds[0..n.load(.monotonic)]) orelse return;
            const fd = openKeyboard(i) orelse continue;
            var clock: i32 = @backingInt(linux.clockid_t.MONOTONIC);
            _ = linux.ioctl(fd, EVIOCSCLOCKID, @intFromPtr(&clock));
            event_nums[slot] = @intCast(i);
            fds[slot] = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
            if (slot == n.load(.monotonic)) n.store(slot + 1, .release);
        }
    }

    /// The player's setting; the evdev thread alone opens and closes devices to follow it.
    var wanted: std.atomic.Value(bool) = .init(false);
    /// Touched only from the main thread.
    var started = false;

    fn set(on: bool) void {
        wanted.store(on, .release);
        // SDL's key events take over at once; the thread lets go of the devices within a second.
        if (!on) direct_keyboard.store(false, .release);
        if (!on or started) return;
        const t = c.SDL_CreateThread(run, "input-evdev", null) orelse return;
        c.SDL_DetachThread(t);
        started = true;
        startSampler();
    }

    /// Settings never opens over play, so the sampler is not reading these when they close.
    fn closeAll() void {
        for (fds[0..n.load(.monotonic)], 0..) |*f, slot| {
            if (f.fd < 0) continue;
            _ = linux.close(f.fd);
            f.fd = -1;
            releaseHeld(slot, c.SDL_GetTicksNS());
        }
        n.store(0, .release);
    }

    fn run(_: ?*anyopaque) callconv(.c) c_int {
        var evs: [64]InputEvent = undefined;
        // CLOCK_MONOTONIC, not SDL ticks: SDL_Quit resets those while this detached thread still runs.
        var opened_at = monoNs();
        var nodes_at = nodesChangedAt();
        var rescan_until: u64 = 0;
        while (true) {
            if (!wanted.load(.acquire)) {
                closeAll();
                c.SDL_Delay(100);
                continue;
            }
            if (!direct_keyboard.load(.monotonic)) {
                openKeyboards();
                if (n.load(.monotonic) > 0) direct_keyboard.store(true, .release);
            }
            const count = n.load(.monotonic);
            _ = linux.poll(&fds, count, 1000);
            // Events carry kernel timestamps, so the time this takes cannot move a judgement.
            if (monoNs() - opened_at >= std.time.ns_per_s) {
                opened_at = monoNs();
                // Opening a device can wake it, so idle mice and pads are left alone until a node changes.
                const changed = nodesChangedAt();
                if (changed == null or changed != nodes_at) rescan_until = opened_at + rescan_ns;
                nodes_at = changed;
                if (opened_at < rescan_until) openKeyboards();
            }
            // SDL's tick clock and CLOCK_MONOTONIC share a rate, so a fresh delta per wake is exact enough.
            const delta = @as(i128, c.SDL_GetTicksNS()) - monoNs();
            for (fds[0..count], 0..) |*f, slot| {
                // An unplugged device reports HUP forever: without dropping it this loop would spin.
                if (f.revents & (linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL) != 0) {
                    _ = linux.close(f.fd);
                    f.fd = -1;
                    releaseHeld(slot, @intCast(@max(@as(i128, monoNs()) + delta, 0)));
                    continue;
                }
                if (f.revents & linux.POLL.IN == 0) continue;
                const rc = linux.read(f.fd, @ptrCast(&evs), @sizeOf(@TypeOf(evs)));
                if (linux.errno(rc) != .SUCCESS) continue;
                for (evs[0 .. rc / @sizeOf(InputEvent)]) |e| {
                    if (e.type != EV_KEY or e.value == 2 or e.code >= set1_to_sdl.len) continue;
                    if (e.value == 0) held[slot].unset(e.code);
                    // Reading keeps the kernel queue empty; the sampler owns the keys while it runs.
                    if (!focused.load(.acquire) or poll_hz.load(.acquire) != 0) continue;
                    const sc = set1_to_sdl[e.code];
                    if (sc == 0) continue;
                    if (e.value == 1) held[slot].set(e.code);
                    const ns = @as(i128, e.sec) * 1_000_000_000 + @as(i128, e.usec) * 1000 + delta;
                    push(.{ .mono_ns = @intCast(@max(ns, 0)), .code = sc, .down = e.value == 1 });
                }
            }
        }
    }
} else struct {
    fn set(_: bool) void {}
    fn sample(_: *KeyBits) void {}
    fn readable() bool {
        return false;
    }
};

/// Whether evdev input can be turned on: a keyboard under /dev/input this user may read.
pub fn evdevReadable() bool {
    return evdev.readable();
}

test "sampling pushes one event per changed key" {
    fs.io = std.testing.io;
    clear();
    var prev: KeyBits = @splat(0);
    var cur: KeyBits = @splat(0);
    prev[42 / 8] |= 1 << (42 % 8); // LSHIFT held, then released
    cur[44 / 8] |= 1 << (44 % 8); // Z pressed
    cur[57 / 8] |= 1 << (57 % 8); // SPACE pressed
    pushEdges(&prev, &prev, 1);
    try std.testing.expect(pop() == null);
    pushEdges(&prev, &cur, 7);
    const up = pop().?;
    try std.testing.expectEqual(@as(u16, 225), up.code);
    try std.testing.expect(!up.down);
    const z = pop().?;
    try std.testing.expectEqual(@as(u16, 29), z.code);
    try std.testing.expect(z.down);
    try std.testing.expectEqual(@as(u64, 7), z.mono_ns);
    try std.testing.expectEqual(@as(u16, 44), pop().?.code);
    try std.testing.expect(pop() == null);
}

test "a keyboard plugged in later reuses an unplugged one's slot" {
    if (builtin.os.tag != .linux) return;
    const PollFd = std.os.linux.pollfd;
    const open: PollFd = .{ .fd = 3, .events = 0, .revents = 0 };
    const gone: PollFd = .{ .fd = -1, .events = 0, .revents = 0 };
    try std.testing.expectEqual(@as(?usize, 1), evdev.freeSlot(&.{ open, gone, open }));
    try std.testing.expectEqual(@as(?usize, 2), evdev.freeSlot(&.{ open, open }));
    try std.testing.expectEqual(@as(?usize, null), evdev.freeSlot(&(@as([evdev.fds.len]PollFd, @splat(open)))));
}

test "unplugging a device lets go of the keys it held" {
    if (builtin.os.tag != .linux) return;
    fs.io = std.testing.io;
    clear();
    evdev.held[1].set(44);
    evdev.releaseHeld(1, 9);
    const up = pop().?;
    try std.testing.expectEqual(@as(u16, 29), up.code);
    try std.testing.expect(!up.down);
    try std.testing.expectEqual(@as(u64, 9), up.mono_ns);
    try std.testing.expect(pop() == null);
    evdev.releaseHeld(1, 10);
    try std.testing.expect(pop() == null);
}

fn pushLater(_: ?*anyopaque) callconv(.c) c_int {
    c.SDL_Delay(20);
    push(.{ .mono_ns = 0, .code = 1, .down = true });
    return 0;
}

test "a queued event cuts the sim's wait short" {
    fs.io = std.testing.io;
    if (builtin.os.tag == .windows) actuon_input_wait_start();
    clear();
    const t = c.SDL_CreateThread(pushLater, "push-later", null).?;
    const start = c.SDL_GetTicksNS();
    while (q_tail.load(.monotonic) == q_head.load(.acquire)) wait(5 * std.time.ns_per_s);
    c.SDL_WaitThread(t, null);
    try std.testing.expect(c.SDL_GetTicksNS() - start < std.time.ns_per_s);
    // Already queued: no sleep at all.
    const again = c.SDL_GetTicksNS();
    wait(5 * std.time.ns_per_s);
    try std.testing.expect(c.SDL_GetTicksNS() - again < std.time.ns_per_s);
    clear();
}

test "scancode table" {
    try std.testing.expectEqual(@as(u16, 29), set1_to_sdl[44]); // Z
    try std.testing.expectEqual(@as(u16, 225), set1_to_sdl[42]); // LSHIFT
    try std.testing.expectEqual(@as(u16, 44), set1_to_sdl[57]); // SPACE
    try std.testing.expectEqual(@as(u16, 22), set1_to_sdl[31]); // S
    try std.testing.expectEqual(@as(u16, 224), set1_to_sdl[29]); // LCTRL
}
