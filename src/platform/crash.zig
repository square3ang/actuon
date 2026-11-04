//! Nothing leaves the machine: the player attaches crash.txt to a bug report by hand.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const fs = @import("fs.zig");

var path_buf: [4096:0]u8 = undefined;
var path_len: usize = 0;

/// The path is prepared at startup because a crashing process must not allocate.
pub fn install() void {
    var fba_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const dir = fs.dataDir(fba.allocator()) catch return;
    const p = std.fmt.bufPrintSentinel(&path_buf, "{s}crash.txt", .{dir}, 0) catch return;
    path_len = p.len;
    if (builtin.os.tag == .windows) {
        _ = SetUnhandledExceptionFilter(onException);
        return;
    }
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = std.posix.SA.RESETHAND };
    for ([_]std.posix.SIG{ .SEGV, .BUS, .ILL, .ABRT, .FPE }) |sig| std.posix.sigaction(sig, &act, null);
}

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    // Only async-signal-safe calls here. The default action then runs, because of SA_RESETHAND.
    if (path_len > 0) {
        const fd = std.c.open(&path_buf, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd >= 0) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "actuon crashed: signal {d}\n", .{@backingInt(sig)}) catch "actuon crashed\n";
            _ = std.c.write(fd, msg.ptr, msg.len);
            _ = std.c.close(fd);
        }
    }
    _ = std.c.raise(sig);
}

const windows = std.os.windows;
extern "kernel32" fn SetUnhandledExceptionFilter(filter: ?*const fn (*windows.EXCEPTION_POINTERS) callconv(.winapi) c_long) callconv(.winapi) ?*anyopaque;

/// Runs after every library handler; else Windows leaves threads waiting forever on the crashed one's locks.
fn onException(info: *windows.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const rec = info.ExceptionRecord;
    const at = @intFromPtr(rec.ExceptionAddress);
    if (path_len > 0) {
        const ctx = std.debug.cpu_context.fromWindowsContext(info.ContextRecord);
        var buf: [96]u8 = undefined;
        const msg = describeException(&buf, rec.ExceptionCode, at, @intFromPtr(windows.peb().ImageBaseAddress));
        writeReport(msg, .{ .context = &ctx, .allow_unsafe_unwind = true }) catch {};
    }
    // Not ExitProcess: detaching DLLs takes the loader lock, which the crashed thread may hold.
    _ = windows.ntdll.NtTerminateProcess(windows.current_process, @fromBackingInt(@intCast(rec.ExceptionCode)));
    unreachable;
}

/// The offset into actuon.exe finds the code with the release's actuon.pdb, wherever Windows loaded it.
fn describeException(buf: []u8, code: u32, at: usize, image: usize) []const u8 {
    return std.fmt.bufPrint(buf, "exception 0x{x:0>8} at actuon.exe+0x{x}", .{ code, at -% image }) catch "exception";
}

pub fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (path_len > 0) writeReport(msg, .{ .first_address = first_trace_addr orelse @returnAddress() }) catch {};
    path_len = 0; // the abort that follows must not overwrite this report
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn writeReport(msg: []const u8, unwind: std.debug.StackUnwindOptions) !void {
    const io = std.Options.debug_io;
    const file = try std.Io.Dir.cwd().createFile(io, path_buf[0..path_len], .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.print("actuon crashed: {s}\n\n", .{msg});
    std.debug.writeCurrentStackTrace(unwind, .{ .writer = &w.interface, .mode = .no_color }) catch {};
    try w.interface.flush();
}

test "a native exception names its code and its offset into the game" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("exception 0xc0000005 at actuon.exe+0xbe46a", describeException(&buf, 0xc0000005, 0x1400be46a, 0x140000000));
}

pub fn takePrevious(a: std.mem.Allocator) bool {
    if (path_len == 0) return false;
    const p = path_buf[0..path_len];
    const bytes = fs.readAlloc(a, p, 1 << 20) catch return false;
    const dir = std.fs.path.dirname(p) orelse return false;
    const last = std.fmt.allocPrint(a, "{s}/crash-last.txt", .{dir}) catch return false;
    fs.write(last, bytes) catch return false;
    fs.remove(p);
    return true;
}
