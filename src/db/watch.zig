const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");

/// Changed folders, each true when the folder itself went: its name may come back as another folder.
pub const Changes = std.StringArrayHashMapUnmanaged(bool);

/// Must stay put once a scan has used it: macOS streams hold the address.
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
    pub fn changed(w: *Watch, a: std.mem.Allocator, roots: []const []const u8) !?Changes {
        if (!w.lost and sameRoots(w.roots.items, roots)) {
            var dirty: Changes = .empty;
            if (try w.os.drain(w, a, &dirty)) return dirty;
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
                // Other programs need the watches this one can no longer use.
                w.clear();
                return;
            },
            // A folder nobody watches could change unnoticed, as on a network drive or an unplugged one.
            .skipped => {
                w.lost = true;
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

    pub fn children(w: *const Watch, a: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (w.dirs.keys()) |p| {
            if (db.isDirectlyIn(p, dir)) try out.append(a, try a.dupe(u8, p));
        }
        return out.items;
    }

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

fn markDirty(a: std.mem.Allocator, dirty: *Changes, path: []const u8, gone: bool) !void {
    // The scan may stop watching this folder, which frees the watch's copy.
    const got = try dirty.getOrPut(a, path);
    if (!got.found_existing) {
        got.key_ptr.* = try a.dupe(u8, path);
        got.value_ptr.* = false;
    }
    got.value_ptr.* = got.value_ptr.* or gone;
}

const Added = enum { watched, skipped, exhausted };

const Os = switch (builtin.os.tag) {
    .linux => Linux,
    .windows => Windows,
    .macos => Mac,
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
        fn drain(_: *@This(), _: *Watch, _: std.mem.Allocator, _: *Changes) !bool {
            return false;
        }
    },
};

/// Network and FUSE mounts accept a watch but never report another machine's changes.
fn remoteFs(magic: u32) bool {
    return switch (magic) {
        0x6969, 0x517B, 0xFF534D42, 0xFE534D42, 0x65735546, 0x01021997, 0x00C36400 => true, // NFS, SMB, CIFS, SMB2, FUSE, 9P, Ceph
        else => false,
    };
}

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

    extern "c" fn statfs(path: [*:0]const u8, buf: *anyopaque) c_int;

    fn watch(o: *Linux, gpa: std.mem.Allocator, path: []const u8, _: []const u8) !Added {
        const z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(z);
        // f_type is the first word in glibc's and musl's struct statfs.
        var fs: extern struct { f_type: c_ulong, rest: [256]u8 } = undefined;
        if (statfs(z, &fs) == 0 and remoteFs(@truncate(fs.f_type))) return .skipped;
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

    fn drain(o: *Linux, w: *Watch, a: std.mem.Allocator, dirty: *Changes) !bool {
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
                    try markDirty(a, dirty, path, true);
                    if (ev.mask & IN.IGNORED != 0) {
                        _ = o.paths.remove(ev.wd);
                        _ = o.wds.remove(path);
                    }
                    continue;
                }
                try markDirty(a, dirty, path, false);
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

    fn drain(o: *Windows, w: *Watch, a: std.mem.Allocator, dirty: *Changes) !bool {
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
                if (w.reals.get(dir)) |path| try markDirty(a, dirty, path, false);
                if (next == 0) break;
                off += next;
            }
            if (!read(r)) return false;
        }
        return true;
    }
};

/// One FSEvents stream per root over its whole tree, as on Windows. Events land on `queue`, and drain takes them there.
const Mac = struct {
    const Ref = *opaque {};
    const Context = extern struct { version: isize = 0, info: *Mac, retain: ?*const anyopaque = null, release: ?*const anyopaque = null, describe: ?*const anyopaque = null };
    const Callback = fn (Ref, *Mac, usize, [*]const [*:0]const u8, [*]const u32, [*]const u64) callconv(.c) void;
    extern "c" fn CFStringCreateWithBytes(alloc: ?Ref, bytes: [*]const u8, len: isize, encoding: u32, external: u8) ?Ref;
    extern "c" fn CFArrayCreate(alloc: ?Ref, values: [*]const Ref, n: isize, callbacks: ?*const anyopaque) ?Ref;
    extern "c" fn CFRelease(r: Ref) void;
    extern "c" fn FSEventStreamCreate(alloc: ?Ref, cb: *const Callback, ctx: *const Context, paths: Ref, since: u64, latency: f64, flags: u32) ?Ref;
    extern "c" fn FSEventStreamSetDispatchQueue(s: Ref, q: Ref) void;
    extern "c" fn FSEventStreamStart(s: Ref) u8;
    extern "c" fn FSEventStreamStop(s: Ref) void;
    extern "c" fn FSEventStreamInvalidate(s: Ref) void;
    extern "c" fn FSEventStreamRelease(s: Ref) void;
    extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?Ref;
    extern "c" fn dispatch_sync_f(q: Ref, ctx: *anyopaque, f: *const fn (*anyopaque) callconv(.c) void) void;
    extern "c" fn dispatch_release(q: Ref) void;
    const statfs = @extern(*const fn ([*:0]const u8, *anyopaque) callconv(.c) c_int, .{ .name = if (builtin.cpu.arch == .x86_64) "statfs$INODE64" else "statfs" });
    const Root = struct { stream: Ref, path: []const u8, real: []const u8 };
    const since_now = std.math.maxInt(u64);
    const watch_root_flag = 0x4;
    const utf8 = 0x08000100;
    const mnt_local = 0x1000;
    // Must scan subfolders, user or kernel dropped, root changed, mount, unmount.
    const lost_flags = 0x1 | 0x2 | 0x4 | 0x20 | 0x40 | 0x80;
    const Taken = struct { o: *Mac, paths: std.ArrayList([]u8) = .empty, dropped: bool = false };

    queue: ?Ref = null,
    /// Paths borrow the Watch's, which unwatches a folder before freeing them.
    roots: std.ArrayList(Root) = .empty,
    /// Only touched on `queue`; the callback cannot reach the scan's allocator, so these use libc's.
    pending: std.ArrayList([]u8) = .empty,
    dropped: bool = false,

    fn start(o: *Mac) bool {
        if (o.queue == null) o.queue = dispatch_queue_create("actuon.watch", null);
        return o.queue != null;
    }

    fn onEvents(_: Ref, o: *Mac, n: usize, paths: [*]const [*:0]const u8, flags: [*]const u32, _: [*]const u64) callconv(.c) void {
        const ca = std.heap.c_allocator;
        for (paths[0..n], flags[0..n]) |p, f| {
            if (f & lost_flags != 0) o.dropped = true;
            const own = ca.dupe(u8, std.mem.trimEnd(u8, std.mem.span(p), "/")) catch {
                o.dropped = true;
                continue;
            };
            o.pending.append(ca, own) catch {
                ca.free(own);
                o.dropped = true;
            };
        }
    }

    fn take(ctx: *anyopaque) callconv(.c) void {
        const t: *Taken = @ptrCast(@alignCast(ctx));
        t.paths = t.o.pending;
        t.dropped = t.o.dropped;
        t.o.pending = .empty;
        t.o.dropped = false;
    }

    fn takeAll(o: *Mac) Taken {
        var t: Taken = .{ .o = o };
        if (o.queue) |q| dispatch_sync_f(q, &t, take);
        return t;
    }

    fn free(t: *Taken) void {
        for (t.paths.items) |p| std.heap.c_allocator.free(p);
        t.paths.deinit(std.heap.c_allocator);
    }

    fn watch(o: *Mac, gpa: std.mem.Allocator, path: []const u8, real: []const u8) !Added {
        const z = try gpa.dupeSentinel(u8, real, 0);
        defer gpa.free(z);
        // f_flags is at byte 64 of the 64-bit-inode struct statfs.
        var fs: extern struct { head: [64]u8, f_flags: u32, rest: [2200]u8 } = undefined;
        if (statfs(z, &fs) == 0 and fs.f_flags & mnt_local == 0) return .skipped;
        for (o.roots.items) |r| if (db.holds(r.real, real)) return .watched;
        const str = CFStringCreateWithBytes(null, real.ptr, @intCast(real.len), utf8, 0) orelse return .skipped;
        defer CFRelease(str);
        const list = CFArrayCreate(null, @ptrCast(&str), 1, null) orelse return .skipped;
        defer CFRelease(list);
        const s = FSEventStreamCreate(null, &onEvents, &.{ .info = o }, list, since_now, 0.5, watch_root_flag) orelse return .skipped;
        FSEventStreamSetDispatchQueue(s, o.queue.?);
        if (FSEventStreamStart(s) == 0) {
            close(s);
            return .skipped;
        }
        o.roots.append(gpa, .{ .stream = s, .path = path, .real = real }) catch |e| {
            close(s);
            return e;
        };
        return .watched;
    }

    fn close(s: Ref) void {
        FSEventStreamStop(s);
        FSEventStreamInvalidate(s);
        FSEventStreamRelease(s);
    }

    fn unwatch(o: *Mac, _: std.mem.Allocator, path: []const u8) void {
        for (o.roots.items, 0..) |r, i| if (std.mem.eql(u8, r.path, path)) {
            close(r.stream);
            _ = o.roots.swapRemove(i);
            return;
        };
    }

    fn clear(o: *Mac, _: std.mem.Allocator) void {
        for (o.roots.items) |r| close(r.stream);
        o.roots.clearRetainingCapacity();
        // Also waits out a callback still running on the queue.
        var t = o.takeAll();
        free(&t);
    }

    fn deinit(o: *Mac, gpa: std.mem.Allocator) void {
        o.clear(gpa);
        o.roots.deinit(gpa);
        if (o.queue) |q| dispatch_release(q);
    }

    fn drain(o: *Mac, w: *Watch, a: std.mem.Allocator, dirty: *Changes) !bool {
        var t = o.takeAll();
        defer free(&t);
        if (t.dropped) return false;
        for (t.paths.items) |real| {
            // A folder new since the last scan is walked from the nearest watched one above it.
            var dir: ?[]const u8 = real;
            while (dir) |d| : (dir = std.fs.path.dirname(d)) {
                if (w.reals.get(d)) |path| {
                    try markDirty(a, dirty, path, false);
                    break;
                }
            } else return false; // the system spells the path in another case than the walk did
        }
        return true;
    }
};

test "network and FUSE mounts go unwatched, local file systems do not" {
    try std.testing.expect(remoteFs(0x6969) and remoteFs(0xFF534D42) and remoteFs(0x65735546));
    try std.testing.expect(!remoteFs(0xEF53) and !remoteFs(0x9123683E) and !remoteFs(0x01021994));
}
