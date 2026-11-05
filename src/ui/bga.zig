//! One decode thread per video, so a slow codec never holds up rendering.
const std = @import("std");
const c = @import("c");
const core = @import("actuon_core");
const fs = @import("../platform/fs.zig");
const gfx = @import("gfx.zig");
const Session = @import("../game/session.zig").Session;

const exts: []const []const u8 = &.{ "png", "bmp", "jpg", "jpeg", "gif", "tga", "mpg", "mpeg", "avi", "wmv", "mp4", "m4v", "webm", "mkv", "ogv", "flv" };
const video_exts: []const []const u8 = &.{ ".mpg", ".mpeg", ".avi", ".wmv", ".mp4", ".m4v", ".webm", ".mkv", ".ogv", ".flv" };
const poor_show_us: i64 = 1_000_000;

pub fn isVideo(path: []const u8) bool {
    const e = std.fs.path.extension(path);
    for (video_exts) |v| if (std.ascii.eqlIgnoreCase(e, v)) return true;
    return false;
}

/// Pure so seeking can be tested without media.
pub const Cursor = struct {
    next: usize = 0,
    last_t: i64 = std.math.minInt(i64),
    id: [3]i32 = @splat(-1),
    since: [3]i64 = @splat(0),

    pub fn advance(cur: *Cursor, events: []const core.types.BgaEvent, t: i64) void {
        if (t < cur.last_t) cur.* = .{};
        cur.last_t = t;
        while (cur.next < events.len and events[cur.next].time_us <= t) : (cur.next += 1) {
            const e = events[cur.next];
            const l = @backingInt(e.layer);
            cur.id[l] = e.id;
            cur.since[l] = e.time_us;
        }
    }
};

const Filters = struct { graph: *c.AVFilterGraph, src: *c.AVFilterContext, sink: *c.AVFilterContext };

pub const Video = struct {
    fmt: *c.AVFormatContext,
    dec: *c.AVCodecContext,
    sws: *c.SwsContext,
    filters: ?Filters,
    stream: c_int,
    tb: f64,
    w: c_int,
    h: c_int,
    pix_fmt: c_int,
    front: []u8,
    back: []u8,
    lock: *c.SDL_Mutex,
    fresh: std.atomic.Value(bool) = .init(false),
    /// Microseconds since this clip started; negative while it is not showing.
    clock: std.atomic.Value(i64) = .init(-1),
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?*c.SDL_Thread = null,
    tex: *gfx.Texture,
    uploaded_frame: u64 = std.math.maxInt(u64),
    stale: bool = false,
    scaled: ?gfx.Scaled = null,
    g: *gfx.Gfx,

    pub fn open(gpa: std.mem.Allocator, g: *gfx.Gfx, path: []const u8) !*Video {
        var buf: [4096]u8 = undefined;
        const pz = try std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0);
        // Chart folders are untrusted: a playlist-style file must not make ffmpeg open a URL.
        var opts: ?*c.AVDictionary = null;
        _ = c.av_dict_set(&opts, "protocol_whitelist", "file", 0);
        defer c.av_dict_free(&opts);
        var fmt: ?*c.AVFormatContext = null;
        if (c.avformat_open_input(&fmt, pz.ptr, null, &opts) < 0) return error.Open;
        errdefer c.avformat_close_input(&fmt);
        if (c.avformat_find_stream_info(fmt, null) < 0) return error.Open;
        var codec: ?*const c.AVCodec = null;
        const si = c.av_find_best_stream(fmt, c.AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
        if (si < 0 or codec == null) return error.NoVideo;
        const st = fmt.?.streams[@intCast(si)];
        var dec: ?*c.AVCodecContext = c.avcodec_alloc_context3(codec) orelse return error.Open;
        errdefer c.avcodec_free_context(&dec);
        if (c.avcodec_parameters_to_context(dec, st.*.codecpar) < 0) return error.Open;
        if (c.avcodec_open2(dec, codec, null) < 0) return error.Open;
        const w = dec.?.width;
        const h = dec.?.height;
        if (w <= 0 or h <= 0 or w > 4096 or h > 4096) return error.BadSize;
        const filters = if (g.upscale_on) makeDeblock(w, h, dec.?.pix_fmt) else null;
        errdefer if (filters) |f| {
            var graph: ?*c.AVFilterGraph = f.graph;
            c.avfilter_graph_free(&graph);
        };
        const sws = c.sws_getContext(w, h, if (filters != null) c.AV_PIX_FMT_YUV420P else dec.?.pix_fmt, w, h, c.AV_PIX_FMT_RGBA, c.SWS_FAST_BILINEAR, null, null, null) orelse return error.Open;
        // sws's SIMD writes past the last row (seen: 32 bytes at 1080x1080), so leave it a spare row.
        const size: usize = @intCast(w * (h + 1) * 4);
        const v = try gpa.create(Video);
        v.* = .{
            .fmt = fmt.?,
            .dec = dec.?,
            .sws = sws,
            .filters = filters,
            .stream = si,
            .tb = c.av_q2d(st.*.time_base),
            .w = w,
            .h = h,
            .pix_fmt = dec.?.pix_fmt,
            .front = try gpa.alloc(u8, size),
            .back = try gpa.alloc(u8, size),
            .lock = c.SDL_CreateMutex() orelse return error.Open,
            .tex = g.createTexture(w, h) orelse return error.Open,
            .g = g,
        };
        v.thread = c.SDL_CreateThread(decodeThread, "bga", v);
        return v;
    }

    pub fn destroy(v: *Video, gpa: std.mem.Allocator) void {
        v.stop.store(true, .release);
        if (v.thread) |t| c.SDL_WaitThread(t, null);
        var fmt: ?*c.AVFormatContext = v.fmt;
        c.avformat_close_input(&fmt);
        var dec: ?*c.AVCodecContext = v.dec;
        c.avcodec_free_context(&dec);
        c.sws_freeContext(v.sws);
        if (v.filters) |f| {
            var graph: ?*c.AVFilterGraph = f.graph;
            c.avfilter_graph_free(&graph);
        }
        c.SDL_DestroyMutex(v.lock);
        if (v.scaled) |*s| v.g.dropScaled(s);
        v.g.destroyTexture(v.tex);
        gpa.free(v.front);
        gpa.free(v.back);
        gpa.destroy(v);
    }

    fn makeDeblock(w: c_int, h: c_int, fmt: c.AVPixelFormat) ?Filters {
        const name = c.av_get_pix_fmt_name(fmt) orelse return null;
        var buf: [256]u8 = undefined;
        const desc = std.fmt.bufPrintSentinel(&buf, "buffer=video_size={d}x{d}:pix_fmt={s}:time_base=1/1000:pixel_aspect=1/1,deblock,format=yuv420p,buffersink", .{ w, h, name }, 0) catch return null;
        var graph: ?*c.AVFilterGraph = c.avfilter_graph_alloc() orelse return null;
        var inputs: ?*c.AVFilterInOut = null;
        var outputs: ?*c.AVFilterInOut = null;
        const built = c.avfilter_graph_parse2(graph, desc.ptr, &inputs, &outputs) >= 0 and c.avfilter_graph_config(graph, null) >= 0;
        c.avfilter_inout_free(&inputs);
        c.avfilter_inout_free(&outputs);
        const src = c.avfilter_graph_get_filter(graph, "Parsed_buffer_0");
        const sink = c.avfilter_graph_get_filter(graph, "Parsed_buffersink_3");
        if (!built or src == null or sink == null) {
            c.avfilter_graph_free(&graph);
            return null;
        }
        return .{ .graph = graph.?, .src = src.?, .sink = sink.? };
    }

    /// Clamped to a day either way so the sums in `decodeLoop` cannot overflow.
    fn frameUs(ts: i64, tb: f64) i64 {
        const day: f64 = 86_400e6;
        return std.math.lossyCast(i64, std.math.clamp(@as(f64, @floatFromInt(ts)) * tb * 1e6, -day, day));
    }

    fn seekTo(v: *Video, us: i64) void {
        const ts: i64 = std.math.lossyCast(i64, @as(f64, @floatFromInt(us)) / 1e6 / v.tb);
        _ = c.av_seek_frame(v.fmt, v.stream, ts, c.AVSEEK_FLAG_BACKWARD);
        c.avcodec_flush_buffers(v.dec);
    }

    fn nextFrame(v: *Video, pkt: *c.AVPacket, frame: *c.AVFrame) bool {
        while (true) {
            if (c.avcodec_receive_frame(v.dec, frame) == 0) return true;
            if (c.av_read_frame(v.fmt, pkt) < 0) return false;
            defer c.av_packet_unref(pkt);
            if (pkt.stream_index == v.stream) _ = c.avcodec_send_packet(v.dec, pkt);
        }
    }

    fn decodeLoop(v: *Video, pkt: *c.AVPacket, frame: *c.AVFrame, filtered: *c.AVFrame) void {
        var pts: i64 = 0;
        var at_end = false;
        const far_us = 2_000_000;
        while (!v.stop.load(.acquire)) {
            const clock = v.clock.load(.acquire);
            if (clock < 0) {
                c.SDL_Delay(5);
                continue;
            }
            if (clock + 200_000 < pts or clock > pts + far_us) {
                v.seekTo(clock);
                pts = clock;
                at_end = false;
            }
            if (at_end) {
                c.SDL_Delay(5);
                continue;
            }
            if (!v.nextFrame(pkt, frame)) {
                at_end = true;
                continue;
            }
            defer c.av_frame_unref(frame);
            if (frame.best_effort_timestamp != c.AV_NOPTS_VALUE) pts = frameUs(frame.best_effort_timestamp, v.tb);
            if (pts + 50_000 < clock) continue;
            // sws and the deblock graph are built for the opening size; a file that changes it mid-stream would overread.
            if (frame.width != v.w or frame.height != v.h or frame.format != v.pix_fmt) continue;
            var dst = [4]?[*]u8{ v.back.ptr, null, null, null };
            var stride = [4]c_int{ v.w * 4, 0, 0, 0 };
            if (v.filters) |f| {
                if (c.av_buffersrc_add_frame_flags(f.src, frame, c.AV_BUFFERSRC_FLAG_KEEP_REF) < 0) continue;
                if (c.av_buffersink_get_frame(f.sink, filtered) < 0) continue;
                defer c.av_frame_unref(filtered);
                _ = c.sws_scale(v.sws, @ptrCast(&filtered.data), &filtered.linesize, 0, v.h, @ptrCast(&dst), &stride);
            } else {
                _ = c.sws_scale(v.sws, @ptrCast(&frame.data), &frame.linesize, 0, v.h, @ptrCast(&dst), &stride);
            }
            while (!v.stop.load(.acquire)) {
                const now = v.clock.load(.acquire);
                if (now >= pts or now < 0 or now + 200_000 < pts) break;
                c.SDL_Delay(1);
            }
            c.SDL_LockMutex(v.lock);
            std.mem.swap([]u8, &v.front, &v.back);
            c.SDL_UnlockMutex(v.lock);
            v.fresh.store(true, .release);
        }
    }

    pub fn tickLoop(v: *Video, now_ms: i64) void {
        const dur = v.fmt.duration;
        const us = @max(now_ms, 0) * 1000;
        v.clock.store(if (dur > 0) @mod(us, dur) else us, .release);
        v.stale = v.upload() or v.stale;
    }

    fn upload(v: *Video) bool {
        // The clock tick and the draw both land here, and a texture streams once a frame.
        if (v.uploaded_frame == v.g.frame) return false;
        if (!v.fresh.swap(false, .acq_rel)) return false;
        v.uploaded_frame = v.g.frame;
        c.SDL_LockMutex(v.lock);
        v.g.streamTexture(v.tex, v.front.ptr);
        c.SDL_UnlockMutex(v.lock);
        return true;
    }
};

fn decodeThread(ud: ?*anyopaque) callconv(.c) c_int {
    const v: *Video = @ptrCast(@alignCast(ud));
    var pkt: ?*c.AVPacket = c.av_packet_alloc();
    var frame: ?*c.AVFrame = c.av_frame_alloc();
    var filtered: ?*c.AVFrame = c.av_frame_alloc();
    defer c.av_packet_free(&pkt);
    defer c.av_frame_free(&frame);
    defer c.av_frame_free(&filtered);
    if (pkt != null and frame != null and filtered != null) v.decodeLoop(pkt.?, frame.?, filtered.?);
    return 0;
}

const Media = union(enum) { none, image: *gfx.Texture, video: *Video };

fn clipUs(shown_us: i64, freq: u32) i64 {
    return @divTrunc(shown_us *| freq, 100);
}

test "a clip keeps pace with the practice speed" {
    try std.testing.expectEqual(@as(i64, 2_000_000), clipUs(1_000_000, 200));
    try std.testing.expectEqual(@as(i64, 500_000), clipUs(1_000_000, 50));
    try std.testing.expectEqual(@as(i64, 1_000_000), clipUs(1_000_000, 100));

    const gpa = std.testing.allocator;
    var s: Session = undefined;
    s.chart = try core.bms.parse(gpa, "#BPM 120\n#BMP01 missing.png\n#00104:01\n", .{});
    defer s.chart.deinit();
    s.params = .{ .path = "/nonexistent-actuon/x.bms", .practice = .{ .start_us = 0, .end_us = 1, .freq = 150 } };
    // A missing file never reaches the GPU.
    var g: gfx.Gfx = undefined;
    const b = Bga.create(gpa, std.testing.io, &g, &s).?;
    defer b.destroy();
    try std.testing.expectEqual(@as(u32, 150), b.freq);
}

pub const Look = struct {
    /// beatoraja's stretch types: 0 fills, 1 fits inside keeping the shape, 3 covers and crops.
    stretch: i32 = 0,
    alpha: u8 = 255,
    backdrop: bool = true,
};

const Fitted = struct { src: c.SDL_FRect, dst: c.SDL_FRect };

pub fn fit(stretch: i32, w: f32, h: f32, box: c.SDL_FRect) Fitted {
    var out: Fitted = .{ .src = .{ .x = 0, .y = 0, .w = w, .h = h }, .dst = box };
    if (w <= 0 or h <= 0 or box.w <= 0 or box.h <= 0) return out;
    if (stretch == 1) {
        const scale = @min(box.w / w, box.h / h);
        out.dst.w = w * scale;
        out.dst.h = h * scale;
        out.dst.x = box.x + (box.w - out.dst.w) / 2;
        out.dst.y = box.y + (box.h - out.dst.h) / 2;
    } else if (stretch == 3) {
        const scale = @max(box.w / w, box.h / h);
        out.src.w = box.w / scale;
        out.src.h = box.h / scale;
        out.src.x = (w - out.src.w) / 2;
        out.src.y = (h - out.src.h) / 2;
    }
    return out;
}

test "wild frame times stay within a day" {
    try std.testing.expectEqual(@as(i64, 1_000_000), Video.frameUs(90_000, 1.0 / 90_000.0));
    try std.testing.expectEqual(@as(i64, 86_400_000_000), Video.frameUs(std.math.maxInt(i64), 1.0));
    try std.testing.expectEqual(@as(i64, -86_400_000_000), Video.frameUs(c.AV_NOPTS_VALUE, 1.0 / 90_000.0));
}

test "fitting keeps the shape or crops to it" {
    const box: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 1280, .h = 720 };
    const inner = fit(1, 256, 256, box);
    try std.testing.expectEqual(@as(f32, 720), inner.dst.w);
    try std.testing.expectEqual(@as(f32, 280), inner.dst.x);
    const outer = fit(3, 256, 256, box);
    try std.testing.expectEqual(@as(f32, 1280), outer.dst.w);
    try std.testing.expectEqual(@as(f32, 144), outer.src.h);
    try std.testing.expectEqual(@as(f32, 56), outer.src.y);
}

pub const Bga = struct {
    gpa: std.mem.Allocator,
    media: []Media,
    cur: Cursor = .{},
    shown: [3]i32 = @splat(-1),
    /// Practice FREQ percent: chart time runs that much faster, and a clip with it.
    freq: u32 = 100,
    g: *gfx.Gfx,

    /// Black is transparent on layer images, as in LR2, and the base draws over black anyway.
    fn loadImage(g: *gfx.Gfx, bytes: []const u8) ?*gfx.Texture {
        if (!gfx.imageFits(bytes, gfx.max_chart_image_px)) return null;
        var w: c_int = 0;
        var h: c_int = 0;
        var n: c_int = 0;
        const px = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &n, 4) orelse return null;
        defer c.stbi_image_free(px);
        const size: usize = @intCast(w * h * 4);
        var i: usize = 0;
        while (i < size) : (i += 4) {
            if (px[i] == 0 and px[i + 1] == 0 and px[i + 2] == 0) px[i + 3] = 0;
        }
        return g.textureFromPixels(px, w, h, @intCast(w * 4));
    }

    pub fn create(gpa: std.mem.Allocator, io: std.Io, g: *gfx.Gfx, s: *Session) ?*Bga {
        if (s.chart.bga.len == 0 or s.chart.bmps.len == 0) return null;
        const b = gpa.create(Bga) catch return null;
        const media = gpa.alloc(Media, s.chart.bmps.len) catch {
            gpa.destroy(b);
            return null;
        };
        b.* = .{ .gpa = gpa, .g = g, .media = media, .freq = if (s.params.practice) |p| p.freq else 100 };
        @memset(media, .none);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const dir = std.fs.path.dirname(s.params.path) orelse ".";
        var used = gpa.alloc(bool, media.len) catch return b;
        defer gpa.free(used);
        @memset(used, false);
        for (s.chart.bga) |e| if (e.id >= 0 and e.id < media.len) {
            used[@intCast(e.id)] = true;
        };
        for (s.chart.bmps, 0..) |rel, i| {
            if (!used[i]) continue;
            _ = arena.reset(.retain_capacity);
            const path = (fs.resolveAsset(a, io, dir, rel, exts) catch null) orelse continue;
            if (isVideo(path)) {
                g.prepareUpscaler();
                const v = Video.open(gpa, g, path) catch |e| {
                    std.log.warn("bga {s}: {t}", .{ path, e });
                    continue;
                };
                media[i] = .{ .video = v };
            } else {
                const bytes = fs.readAlloc(a, io, path, 64 << 20) catch continue;
                if (loadImage(g, bytes)) |t| media[i] = .{ .image = t };
            }
        }
        return b;
    }

    pub fn destroy(b: *Bga) void {
        for (b.media) |m| switch (m) {
            .none => {},
            .image => |t| b.g.destroyTexture(t),
            .video => |v| v.destroy(b.gpa),
        };
        b.gpa.free(b.media);
        b.gpa.destroy(b);
    }

    fn drawSlot(b: *Bga, id: i32, since: i64, t: i64, dst: *const c.SDL_FRect, look: Look) void {
        if (id < 0 or id >= b.media.len) return;
        var video: ?*Video = null;
        const tex = switch (b.media[@intCast(id)]) {
            .none => return,
            .image => |tex| tex,
            .video => |v| blk: {
                v.clock.store(clipUs(t - since, b.freq), .release);
                v.stale = v.upload() or v.stale;
                video = v;
                break :blk v.tex;
            },
        };
        const fitted = fit(look.stretch, tex.w, tex.h, dst.*);
        const shown = if (video) |v| b.g.upscaled(v.tex, &v.scaled, &v.stale, fitted.src, fitted.dst) else tex;
        b.g.sprite(shown, fitted.src, fitted.dst, .{ .col = .{ .r = 255, .g = 255, .b = 255, .a = look.alpha } });
    }

    pub fn draw(b: *Bga, chart: *const core.types.Chart, t: i64, last_judge: u8, judge_at: i64, dst: c.SDL_FRect, look: Look) void {
        b.cur.advance(chart.bga, t);
        // A clip that left the screen must stop consuming the decoder.
        for (b.shown, 0..) |id, l| if (id != b.cur.id[l] and id >= 0 and id < b.media.len) switch (b.media[@intCast(id)]) {
            .video => |v| v.clock.store(-1, .release),
            else => {},
        };
        b.shown = b.cur.id;
        const poor = last_judge >= 3 and last_judge != 255 and t - judge_at < poor_show_us and b.cur.id[2] >= 0;
        if (look.backdrop) {
            b.g.rect(dst.x, dst.y, dst.w, dst.h, .{ .r = 0, .g = 0, .b = 0 });
        }
        if (poor) {
            b.drawSlot(b.cur.id[2], b.cur.since[2], t, &dst, look);
        } else {
            b.drawSlot(b.cur.id[0], b.cur.since[0], t, &dst, look);
            b.drawSlot(b.cur.id[1], b.cur.since[1], t, &dst, look);
        }
    }
};

test "cursor follows time and survives a backward seek" {
    const ev = [_]core.types.BgaEvent{
        .{ .time_us = 0, .id = 1, .layer = .base },
        .{ .time_us = 100, .id = 2, .layer = .base },
        .{ .time_us = 150, .id = 7, .layer = .layer },
    };
    var cur: Cursor = .{};
    cur.advance(&ev, 120);
    try std.testing.expectEqual(@as(i32, 2), cur.id[0]);
    try std.testing.expectEqual(@as(i32, -1), cur.id[1]);
    cur.advance(&ev, 200);
    try std.testing.expectEqual(@as(i32, 7), cur.id[1]);
    cur.advance(&ev, 50);
    try std.testing.expectEqual(@as(i32, 1), cur.id[0]);
    try std.testing.expectEqual(@as(i32, -1), cur.id[1]);
    try std.testing.expectEqual(@as(i64, 0), cur.since[0]);
}
