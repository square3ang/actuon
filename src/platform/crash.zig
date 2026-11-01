//! Local crash reports. Nothing leaves the machine: the player attaches crash.txt to a bug report by hand.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const fs = @import("fs.zig");

var path_buf: [4096:0]u8 = undefined;
var path_len: usize = 0;

/// Call once at startup. The path is prepared here because a crashing process must not allocate.
pub fn install() void {
    var fba_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
    const dir = fs.dataDir(fba.allocator()) catch return;
    const p = std.fmt.bufPrintSentinel(&path_buf, "{s}crash.txt", .{dir}, 0) catch return;
    path_len = p.len;
    // shortcut: on Windows only Zig panics are reported, native exceptions need SetUnhandledExceptionFilter.
    if (builtin.os.tag == .windows) return;
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = std.posix.SA.RESETHAND };
    for ([_]std.posix.SIG{ .SEGV, .BUS, .ILL, .ABRT, .FPE }) |sig| std.posix.sigaction(sig, &act, null);
}

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    // Only async-signal-safe calls here. The default action then runs, because of SA_RESETHAND.
    if (path_len > 0) {
        const fd = std.c.open(&path_buf, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd >= 0) {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "actuon crashed: signal {d}\n", .{@intFromEnum(sig)}) catch "actuon crashed\n";
            _ = std.c.write(fd, msg.ptr, msg.len);
            _ = std.c.close(fd);
        }
    }
    _ = std.c.raise(sig);
}

/// Panic handler: report file first, then the normal trace on stderr.
pub fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (path_len > 0) writePanic(msg, first_trace_addr) catch {};
    path_len = 0; // the abort that follows must not overwrite this report
    std.debug.defaultPanic(msg, first_trace_addr);
}

fn writePanic(msg: []const u8, first: ?usize) !void {
    const io = std.Options.debug_io;
    const file = try std.Io.Dir.cwd().createFile(io, path_buf[0..path_len], .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.print("actuon crashed: {s}\n\n", .{msg});
    std.debug.writeCurrentStackTrace(.{ .first_address = first orelse @returnAddress() }, .{ .writer = &w.interface, .mode = .no_color }) catch {};
    try w.interface.flush();
}

/// Moves a report left by the previous run aside, and tells the caller there was one.
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
