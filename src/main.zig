const std = @import("std");
const fs = @import("platform/fs.zig");
const app = @import("ui/app.zig");
const latency = @import("audio/latency.zig");
const editor = @import("ui/editor.zig");
const download = @import("net/download.zig");
const table = @import("table/table.zig");
const db = @import("db/db.zig");
const http = @import("platform/http.zig");
const ir = @import("net/ir.zig");
const config = @import("game/config.zig");
const c = @import("c");
const crash = @import("platform/crash.zig");

pub const panic = std.debug.FullPanic(crash.onPanic);
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

const usage =
    \\usage: actuon [chart] [--auto] [--replay FILE] [--from-ms N]
    \\              [--null-audio] [--shot FILE.bmp] [--shot-after-ms N] [--shot-keys F10,Down] [--decide]
    \\       actuon -P [-N<measure>] FILE    preview from an editor (-S stops)
    \\       actuon fetch-chart MD5
    \\       actuon latency [--keys SECONDS]
    \\       actuon fetch-table URL
    \\       actuon ir-register URL NAME    (password on stdin, saves the token)
    \\       actuon ir-login URL NAME       (password on stdin, saves the token)
    \\       actuon ir-rival NAME
    \\
;

pub fn main(init: std.process.Init) !void {
    fs.io = init.io;
    readEnvironNow(init.io);
    crash.install();
    download.initLocale();
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "crash-test")) {
        if (std.mem.eql(u8, args[2], "panic")) @panic("crash test");
        if (std.mem.eql(u8, args[2], "signal")) _ = std.c.raise(.SEGV);
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "latency")) {
        const keys: u32 = if (args.len >= 4) try std.fmt.parseInt(u32, args[3], 10) else 0;
        return latency.run(keys);
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "fetch-chart")) {
        const al = init.arena.allocator();
        const cfg = config.load(al);
        if (cfg.roots.len == 0) return error.NoLibraryFolder;
        const url = try download.expand(al, cfg.download_url, args[2]);
        const j = download.start(gpa, url, cfg.roots[0], args[2]) orelse return error.BadHash;
        defer j.destroy();
        while (j.state.load(.acquire) == 0) c.SDL_Delay(50);
        if (j.state.load(.acquire) != 1) return error.DownloadFailed;
        return;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "fetch-table")) return fetchTable(gpa, args[2]);
    if (args.len >= 4 and (std.mem.eql(u8, args[1], "ir-register") or std.mem.eql(u8, args[1], "ir-login"))) {
        return irAccount(gpa, init.io, args[1], args[2], args[3]);
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "ir-rival")) return irRival(gpa, args[2]);
    var opts: app.Options = .{};
    if (editor.parseArgs(args)) |cmd| {
        if (!c.SDL_Init(c.SDL_INIT_EVENTS)) return error.SdlInit;
        const running = editor.otherInstanceRunning(init.arena.allocator());
        if (running) {
            defer c.SDL_Quit();
            return editor.send(init.arena.allocator(), cmd);
        }
        c.SDL_Quit();
        if (cmd.stop) return;
        opts.preview = cmd;
        return app.main(gpa, opts);
    }
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        const next = struct {
            fn f(list: []const [:0]const u8, idx: *usize) ?[:0]const u8 {
                idx.* += 1;
                return if (idx.* < list.len) list[idx.*] else null;
            }
        }.f;
        if (std.mem.eql(u8, a, "--auto")) {
            opts.autoplay = true;
        } else if (std.mem.eql(u8, a, "--null-audio")) {
            opts.null_audio = true;
        } else if (std.mem.eql(u8, a, "--replay")) {
            opts.replay = next(args, &i) orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--shot")) {
            opts.shot = next(args, &i) orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--decide")) {
            opts.decide = true;
        } else if (std.mem.eql(u8, a, "--shot-after-ms")) {
            opts.shot_after_ms = try std.fmt.parseInt(u64, next(args, &i) orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, a, "--shot-keys")) {
            opts.shot_keys = next(args, &i) orelse return error.MissingValue;
        } else if (std.mem.eql(u8, a, "--from-ms")) {
            opts.start_us = 1000 * try std.fmt.parseInt(i64, next(args, &i) orelse return error.MissingValue, 10);
        } else if (std.mem.startsWith(u8, a, "-")) {
            std.debug.print("{s}", .{usage});
            return;
        } else opts.play_path = a;
    }
    try app.main(gpa, opts);
}

/// SDL unsetting XDG_ACTIVATION_TOKEN breaks std's lazy environ read, which then hangs in the stderr lock.
fn readEnvironNow(io: std.Io) void {
    _ = std.debug.lockStderr(&.{});
    std.debug.unlockStderr();
    _ = io.lockStderr(&.{}, null) catch return;
    io.unlockStderr();
}

fn irAccount(gpa: std.mem.Allocator, io: std.Io, cmd: []const u8, url: []const u8, name: []const u8) !void {
    if (!c.SDL_Init(c.SDL_INIT_EVENTS)) return error.SdlInit;
    defer c.SDL_Quit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // As in Settings: the password would go out readable, and the next start signs out of such an IR anyway.
    if (table.sendsInClear(url)) {
        std.debug.print("an IR on the internet needs https://\n", .{});
        return error.PlainHttp;
    }
    var buf: [1024]u8 = undefined;
    var rd = std.Io.File.stdin().reader(io, &buf);
    const line = rd.interface.takeDelimiterExclusive('\n') catch return error.NoPassword;
    const password = std.mem.trimEnd(u8, line, "\r");
    const r = try ir.requestToken(a, url, name, password, std.mem.eql(u8, cmd, "ir-register"));
    const token = r.token orelse {
        std.debug.print("server said {d}: {s}\n", .{ r.status, r.body });
        return error.Refused;
    };
    var cfg = config.load(a);
    cfg.ir_url = url;
    cfg.ir_token = token;
    try config.save(gpa, cfg);
    std.debug.print("logged in as {s}; token saved\n", .{name});
}

fn irRival(gpa: std.mem.Allocator, name: []const u8) !void {
    if (!c.SDL_Init(c.SDL_INIT_EVENTS)) return error.SdlInit;
    defer c.SDL_Quit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = config.load(a);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{cfg.ir_token});
    const r = try http.request(a, .PUT, try std.fmt.allocPrint(a, "{s}/rivals/{f}", .{ cfg.ir_url, std.fmt.alt(std.Uri.Component{ .raw = name }, .formatEscaped) }), "", &.{.{ .name = "Authorization", .value = auth }});
    std.debug.print("{d}: {s}\n", .{ r.status, r.body });
}

fn fetchTable(gpa: std.mem.Allocator, url: []const u8) !void {
    if (!c.SDL_Init(c.SDL_INIT_EVENTS)) return error.SdlInit;
    defer c.SDL_Quit();
    const d = try db.openMain(gpa);
    defer d.close();
    const r = try table.fetch(gpa, d, url);
    std.debug.print("{d} songs, {d} courses\n", .{ r.songs, r.courses });
}

test {
    _ = @import("audio/decode.zig");
    _ = @import("audio/engine.zig");
    _ = @import("audio/alsa.zig");
    _ = @import("audio/menu_sound.zig");
    _ = @import("audio/skin_sound.zig");
    _ = @import("audio/preview.zig");
    _ = @import("audio/clip.zig");
    _ = @import("input/input.zig");
    _ = @import("db/db.zig");
    _ = @import("net/update.zig");
    _ = @import("ui/play.zig");
    _ = @import("ui/pause.zig");
    _ = @import("ui/skinconf.zig");
    _ = @import("ui/result.zig");
    _ = @import("ui/practice.zig");
    _ = @import("skin/bitfont.zig");
    _ = @import("ui/select.zig");
    _ = @import("ui/settings.zig");
    _ = @import("ui/skinslots.zig");
    _ = @import("game/config.zig");
    _ = @import("audio/latency.zig");
    _ = @import("platform/http.zig");
    _ = @import("platform/fs.zig");
    _ = @import("platform/crash.zig");
    _ = @import("table/table.zig");
    _ = @import("ui/course.zig");
    _ = @import("net/ir.zig");
    _ = @import("net/download.zig");
    _ = @import("game/session.zig");
    _ = @import("ui/bga.zig");
    _ = @import("ui/editor.zig");
    _ = @import("skin/model.zig");
    _ = @import("skin/lr2csv.zig");
    _ = @import("skin/osuskin.zig");
    _ = @import("skin/jsonskin.zig");
    _ = @import("skin/lua.zig");
    _ = @import("skin/skin.zig");
    _ = @import("skin/scene.zig");
}
