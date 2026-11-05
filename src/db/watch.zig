const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");

/// Which folders changed between scans. Without notifications, or after one was lost, a scan stats every chart.
pub const Watch = struct {
    gpa: std.mem.Allocator,
    /// Walked path to real path, and back: a link must not walk a watched folder again.
    dirs: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    reals: std.StringHashMapUnmanaged([]const u8) = .empty,
    roots: std.ArrayList([]u8) = .empty,
    lost: bool = true,
    /// Set once the system runs out of watches: retrying would cost a full pass every time.
    off: bool = false,
    os: Os = .{},

    pub fn init(gpa: std.mem.Allocator) Watch {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *Watch) void {
        w.clear();
        w.os.deinit(w.gpa);
        for (w.roots.items) |r| w.gpa.free(r);
        w.roots.deinit(w.gpa);
        w.dirs.deinit(w.gpa);
        w.reals.deinit(w.gpa);
    }

    /// Folders changed since the last call, or null when this scan must stat every chart.
    pub fn changed(w: *Watch, a: std.mem.Allocator, roots: []const []const u8) !?[]const []const u8 {
        if (!w.lost and sameRoots(w.roots.items, roots)) {
            var dirty: std.StringArrayHashMapUnmanaged(void) = .empty;
            if (try w.os.drain(w, a, &dirty)) return dirty.keys();
        }
        w.clear();
        for (w.roots.items) |r| w.gpa.free(r);
        w.roots.clearRetainingCapacity();
        for (roots) |r| {
            const own = try w.gpa.dupe(u8, r);
            errdefer w.gpa.free(own);
            try w.roots.append(w.gpa, own);
        }
        w.lost = w.off or !w.os.start();
        return null;
    }

    /// Before the folder is listed, so a change made during the listing still shows next time.
    pub fn add(w: *Watch, path: []const u8, real: []const u8) !void {
        if (w.lost) return;
        const own = try w.gpa.dupe(u8, path);
        errdefer w.gpa.free(own);
        const own_real = try w.gpa.dupe(u8, real);
        errdefer w.gpa.free(own_real);
        try w.dirs.ensureUnusedCapacity(w.gpa, 1);
        try w.reals.ensureUnusedCapacity(w.gpa, 1);
        const added = try w.os.watch(w.gpa, own, own_real);
        if (added != .watched) {
            w.gpa.free(own);
            w.gpa.free(own_real);
        }
        switch (added) {
            .watched => {},
            .exhausted => {
                std.log.warn("out of folder watches; each rescan now reads every chart's time", .{});
                w.off = true;
                w.lost = true;
                return;
            },
            // A root nobody watches could come back unnoticed, as an unplugged drive does.
            .skipped => {
                if (w.isRoot(path)) w.lost = true;
                return;
            },
        }
        w.dirs.putAssumeCapacity(own, own_real);
        w.reals.putAssumeCapacity(own_real, own);
    }

    pub fn has(w: *const Watch, real: []const u8) bool {
        return w.reals.contains(real);
    }

    pub fn watched(w: *const Watch, path: []const u8) bool {
        return w.dirs.contains(path);
    }

    fn isRoot(w: *const Watch, path: []const u8) bool {
        for (w.roots.items) |r| if (std.mem.eql(u8, r, path)) return true;
        return false;
    }

    /// Watched folders directly inside `dir`.
    pub fn children(w: *const Watch, a: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (w.dirs.keys()) |p| {
            if (db.isDirectlyIn(p, dir)) try out.append(a, try a.dupe(u8, p));
        }
        return out.items;
    }

    /// Stops watching `path` and every folder under it.
    pub fn drop(w: *Watch, path: []const u8) void {
        var i: usize = 0;
        while (i < w.dirs.count()) {
            const p = w.dirs.keys()[i];
            if (!db.holds(path, p)) {
                i += 1;
                continue;
            }
            const real = w.dirs.values()[i];
            w.os.unwatch(w.gpa, p);
            _ = w.reals.remove(real);
            w.dirs.swapRemoveAt(i);
            w.gpa.free(p);
            w.gpa.free(real);
        }
    }

    fn clear(w: *Watch) void {
        w.os.clear(w.gpa);
        for (w.dirs.keys(), w.dirs.values()) |p, r| {
            w.gpa.free(p);
            w.gpa.free(r);
        }
        w.dirs.clearRetainingCapacity();
        w.reals.clearRetainingCapacity();
    }
};

fn sameRoots(a: []const []u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn markDirty(a: std.mem.Allocator, dirty: *std.StringArrayHashMapUnmanaged(void), path: []const u8) !void {
    // The scan may stop watching this folder, which frees the watch's copy.
    const got = try dirty.getOrPut(a, path);
    if (!got.found_existing) got.key_ptr.* = try a.dupe(u8, path);
}

const Added = enum { watched, skipped, exhausted };

const Os = switch (builtin.os.tag) {
    .linux => Linux,
    .windows => Windows,
    // shortcut: macOS has no watcher, so each rescan stats every chart; add FSEvents once a Mac can build and test it.
    else => struct {
        fn start(_: *@This()) bool {
            return false;
        }
        fn watch(_: *@This(), _: std.mem.Allocator, _: []const u8, _: []const u8) !Added {
            return .skipped;
        }
        fn unwatch(_: *@This(), _: std.mem.Allocator, _: []const u8) void {}
        fn clear(_: *@This(), _: std.mem.Allocator) void {}
        fn deinit(_: *@This(), _: std.mem.Allocator) void {}
        fn drain(_: *@This(), _: *Watch, _: std.mem.Allocator, _: *std.StringArrayHashMapUnmanaged(void)) !bool {
            return false;
        }
    },
};

const Linux = struct {
    const linux = std.os.linux;
    const IN = linux.IN;
    const mask = IN.CREATE | IN.DELETE | IN.MOVED_FROM | IN.MOVED_TO | IN.CLOSE_WRITE | IN.ATTRIB | IN.DELETE_SELF | IN.MOVE_SELF | IN.ONLYDIR;

    fd: i32 = -1,
    /// Keys and values borrow the Watch's paths.
    wds: std.StringHashMapUnmanaged(i32) = .empty,
    paths: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,

    fn start(o: *Linux) bool {
        if (o.fd >= 0) return true;
        const rc = linux.inotify_init1(IN.NONBLOCK | IN.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return false;
        o.fd = @intCast(rc);
        return true;
    }

    fn watch(o: *Linux, gpa: std.mem.Allocator, path: []const u8, _: []const u8) !Added {
        const z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(z);
        const rc = linux.inotify_add_watch(o.fd, z, mask);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOSPC, .NOMEM => return .exhausted,
            else => return .skipped,
        }
        const wd: i32 = @intCast(rc);
        errdefer _ = linux.inotify_rm_watch(o.fd, wd);
        try o.wds.ensureUnusedCapacity(gpa, 1);
        try o.paths.put(gpa, wd, path);
        o.wds.putAssumeCapacity(path, wd);
        return .watched;
    }

    fn unwatch(o: *Linux, _: std.mem.Allocator, path: []const u8) void {
        const kv = o.wds.fetchRemove(path) orelse return;
        _ = o.paths.remove(kv.value);
        _ = linux.inotify_rm_watch(o.fd, kv.value);
    }

    fn clear(o: *Linux, _: std.mem.Allocator) void {
        var it = o.wds.valueIterator();
        while (it.next()) |wd| _ = linux.inotify_rm_watch(o.fd, wd.*);
        o.wds.clearRetainingCapacity();
        o.paths.clearRetainingCapacity();
    }

    fn deinit(o: *Linux, gpa: std.mem.Allocator) void {
        o.wds.deinit(gpa);
        o.paths.deinit(gpa);
        if (o.fd >= 0) _ = linux.close(o.fd);
    }

    fn drain(o: *Linux, w: *Watch, a: std.mem.Allocator, dirty: *std.StringArrayHashMapUnmanaged(void)) !bool {
        var buf: [16384]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const rc = linux.read(o.fd, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return true,
                .INTR => continue,
                else => return false,
            }
            var i: usize = 0;
            while (i < rc) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[i]));
                i += @sizeOf(linux.inotify_event) + ev.len;
                if (ev.mask & (IN.Q_OVERFLOW | IN.UNMOUNT) != 0) return false;
                const path = o.paths.get(ev.wd) orelse continue;
                if (ev.mask & (IN.DELETE_SELF | IN.MOVE_SELF | IN.IGNORED) != 0) {
                    // The parent reports a folder that went, but a root has no watched parent.
                    if (w.isRoot(path)) return false;
                    if (ev.mask & IN.IGNORED != 0) {
                        _ = o.paths.remove(ev.wd);
                        _ = o.wds.remove(path);
                    }
                    continue;
                }
                try markDirty(a, dirty, path);
            }
        }
    }
};

/// One watch per root over its whole tree: a handle on every folder would stop the player renaming any folder above it.
const Windows = struct {
    const win = std.os.windows;
    const Overlapped = extern struct { internal: usize = 0, internal_high: usize = 0, offset: u32 = 0, offset_high: u32 = 0, event: ?win.HANDLE = null };
    const Root = struct { handle: win.HANDLE, ov: Overlapped = .{}, buf: [16384]u32 = undefined, path: []const u8, real: []const u8 };
    const filter = 0x1f; // file and folder names, attributes, size, last write
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?win.HANDLE) callconv(.winapi) win.HANDLE;
    extern "kernel32" fn ReadDirectoryChangesW(dir: win.HANDLE, buf: *anyopaque, len: u32, subtree: win.BOOL, filter: u32, returned: ?*u32, ov: *Overlapped, routine: ?*anyopaque) callconv(.winapi) win.BOOL;
    extern "kernel32" fn GetOverlappedResult(h: win.HANDLE, ov: *Overlapped, n: *u32, wait: win.BOOL) callconv(.winapi) win.BOOL;
    extern "kernel32" fn CancelIoEx(h: win.HANDLE, ov: ?*Overlapped) callconv(.winapi) win.BOOL;

    /// Paths borrow the Watch's, which unwatches a folder before freeing them.
    roots: std.ArrayList(*Root) = .empty,

    fn start(_: *Windows) bool {
        return true;
    }

    fn read(r: *Root) bool {
        r.ov = .{};
        return ReadDirectoryChangesW(r.handle, &r.buf, @sizeOf(@TypeOf(r.buf)), .TRUE, filter, null, &r.ov, null).toBool();
    }

    fn watch(o: *Windows, gpa: std.mem.Allocator, path: []const u8, real: []const u8) !Added {
        for (o.roots.items) |r| if (db.holds(r.real, real)) return .watched;
        const name = std.unicode.wtf8ToWtf16LeAllocZ(gpa, real) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.InvalidWtf8 => return .skipped,
        };
        defer gpa.free(name);
        const list_directory = 1;
        const share_all = 7;
        const open_existing = 3;
        const backup_semantics = 0x02000000;
        const overlapped = 0x40000000;
        const h = CreateFileW(name, list_directory, share_all, null, open_existing, backup_semantics | overlapped, null);
        if (h == win.INVALID_HANDLE_VALUE) return .skipped;
        const r = gpa.create(Root) catch |e| {
            win.CloseHandle(h);
            return e;
        };
        r.* = .{ .handle = h, .path = path, .real = real };
        errdefer close(gpa, r);
        if (!read(r)) {
            close(gpa, r);
            return .skipped;
        }
        try o.roots.append(gpa, r);
        return .watched;
    }

    fn close(gpa: std.mem.Allocator, r: *Root) void {
        // The kernel writes into the buffer until the cancelled read has finished.
        var n: u32 = 0;
        if (CancelIoEx(r.handle, &r.ov).toBool()) _ = GetOverlappedResult(r.handle, &r.ov, &n, .TRUE);
        win.CloseHandle(r.handle);
        gpa.destroy(r);
    }

    fn unwatch(o: *Windows, gpa: std.mem.Allocator, path: []const u8) void {
        for (o.roots.items, 0..) |r, i| if (std.mem.eql(u8, r.path, path)) {
            close(gpa, r);
            _ = o.roots.swapRemove(i);
            return;
        };
    }

    fn clear(o: *Windows, gpa: std.mem.Allocator) void {
        for (o.roots.items) |r| close(gpa, r);
        o.roots.clearRetainingCapacity();
    }

    fn deinit(o: *Windows, gpa: std.mem.Allocator) void {
        o.roots.deinit(gpa);
    }

    fn drain(o: *Windows, w: *Watch, a: std.mem.Allocator, dirty: *std.StringArrayHashMapUnmanaged(void)) !bool {
        for (o.roots.items) |r| {
            var n: u32 = 0;
            if (!GetOverlappedResult(r.handle, &r.ov, &n, .FALSE).toBool()) {
                if (win.GetLastError() == .IO_INCOMPLETE) continue;
                return false;
            }
            // Zero bytes: the changes did not fit the buffer.
            if (n == 0) return false;
            const bytes: []const u8 = std.mem.sliceAsBytes(&r.buf)[0..n];
            var off: usize = 0;
            while (true) {
                const next = std.mem.readInt(u32, bytes[off..][0..4], .little);
                const len = std.mem.readInt(u32, bytes[off + 8 ..][0..4], .little);
                // Records start on a DWORD, so the name is u16 aligned.
                const name16: []const u16 = @alignCast(std.mem.bytesAsSlice(u16, bytes[off + 12 ..][0..len]));
                const name = try std.unicode.wtf16LeToWtf8Alloc(a, name16);
                const dir = if (std.fs.path.dirname(name)) |sub| try std.fs.path.join(a, &.{ r.real, sub }) else r.real;
                if (w.reals.get(dir)) |path| try markDirty(a, dirty, path);
                if (next == 0) break;
                off += next;
            }
            if (!read(r)) return false;
        }
        return true;
    }
};
