//! Drawing layer over sokol_gfx: rectangles, cached text, textures, all batched per frame.
const std = @import("std");
const i18n = @import("i18n.zig");
const c = @import("c");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn alpha(col: Color, a: u8) Color {
        return .{ .r = col.r, .g = col.g, .b = col.b, .a = a };
    }
};

pub const white: Color = .{ .r = 236, .g = 240, .b = 248 };
pub const dim: Color = .{ .r = 168, .g = 180, .b = 206 };
pub const bg: Color = .{ .r = 10, .g = 15, .b = 28 };
pub const well: Color = .{ .r = 5, .g = 8, .b = 16 };
pub const rule: Color = .{ .r = 52, .g = 68, .b = 104 };
pub const accent: Color = .{ .r = 38, .g = 92, .b = 240 };
pub const slab: Color = .{ .r = 22, .g = 40, .b = 88 };
pub const cyan: Color = .{ .r = 176, .g = 212, .b = 255 };
pub const steel: Color = .{ .r = 92, .g = 106, .b = 134 };
pub const plate: Color = .{ .r = 26, .g = 36, .b = 64 };
pub const sky: Color = .{ .r = 130, .g = 190, .b = 255 };
pub const danger: Color = .{ .r = 214, .g = 62, .b = 54 };
pub const amber: Color = .{ .r = 240, .g = 170, .b = 70 };

// SUITE is built in. It has no kana or hanzi, so system CJK fonts stay as fallbacks for those.
const font_medium = @embedFile("font_medium");
const backdrop_jpg = @embedFile("backdrop");
const font_heavy = @embedFile("font_heavy");
const heavy_from_size = 24;

// The closest weights to SUITE's medium and heavy faces; regular only where a system has nothing nearer.
const cjk_medium = [_][:0]const u8{
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Medium.ttc",
    "/usr/share/fonts/noto/NotoSansCJK-Medium.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Medium.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
    "/System/Library/Fonts/ヒラギノ角ゴシック W5.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "C:/Windows/Fonts/YuGothM.ttc",
    "C:/Windows/Fonts/msyh.ttc",
    "C:/Windows/Fonts/meiryo.ttc",
};
const cjk_heavy = [_][:0]const u8{
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Bold.ttc",
    "/usr/share/fonts/noto/NotoSansCJK-Bold.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Bold.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
    "/System/Library/Fonts/ヒラギノ角ゴシック W7.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "C:/Windows/Fonts/YuGothB.ttc",
    "C:/Windows/Fonts/msyhbd.ttc",
    "C:/Windows/Fonts/meiryob.ttc",
};
const max_cjk_fonts = 3;

const TextKey = struct { hash: u64, size: u16 };
const TextEntry = struct { tex: *Texture, w: f32, h: f32, frame: u64 };

pub fn mix(a: Color, b: Color, t: f32) Color {
    const f = struct {
        fn f(x: u8, y: u8, k: f32) u8 {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            return @intFromFloat(fx + (fy - fx) * k);
        }
    }.f;
    const k = std.math.clamp(t, 0, 1);
    return .{ .r = f(a.r, b.r, k), .g = f(a.g, b.g, k), .b = f(a.b, b.b, k), .a = f(a.a, b.a, k) };
}

pub const Texture = struct {
    /// Zero until it has pixels; drawn as white until then.
    image: c.sg_image = .{ .id = 0 },
    view: c.sg_view = .{ .id = 0 },
    /// `streamTexture` writes here, then copies into `image`.
    staging: c.sg_image = .{ .id = 0 },
    w: f32,
    h: f32,
};

/// A movie frame after FSRCNNX. `tex` is what gets drawn, with the source's size so source rects still fit.
pub const Scaled = struct {
    tex: *Texture,
    images: [up_passes.len]c.sg_image,
    reads: [up_passes.len]c.sg_view,
    targets: [up_passes.len]c.sg_view,
    target: c.sg_view,
};

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    col: [4]u8,
};

fn vert(x: f32, y: f32, col: Color) Vertex {
    return .{ .x = x, .y = y, .u = -1, .v = -1, .col = .{ col.r, col.g, col.b, col.a } };
}

const State = struct {
    add: bool = false,
    nearest: bool = false,
    clip: ?c.SDL_Rect = null,

    fn same(a: State, b: State, textured: bool) bool {
        if (a.add != b.add) return false;
        if (textured and a.nearest != b.nearest) return false;
        const ac = a.clip orelse return b.clip == null;
        const bc = b.clip orelse return false;
        return ac.x == bc.x and ac.y == bc.y and ac.w == bc.w and ac.h == bc.h;
    }
};

const Cmd = struct {
    tex: ?*Texture,
    state: State,
    first: u32,
    count: u32,
};

/// A frame's geometry. Draw order is kept; a new draw call starts only when state must change.
const Batch = struct {
    verts: std.ArrayList(Vertex) = .empty,
    idx: std.ArrayList(u32) = .empty,
    cmds: std.ArrayList(Cmd) = .empty,

    fn reset(b: *Batch) void {
        b.verts.clearRetainingCapacity();
        b.idx.clearRetainingCapacity();
        b.cmds.clearRetainingCapacity();
    }

    fn deinit(b: *Batch, gpa: std.mem.Allocator) void {
        b.verts.deinit(gpa);
        b.idx.deinit(gpa);
        b.cmds.deinit(gpa);
    }

    fn push(b: *Batch, gpa: std.mem.Allocator, tex: ?*Texture, state: State, v: []const Vertex, idx: []const u32) void {
        b.verts.ensureUnusedCapacity(gpa, v.len) catch return;
        b.idx.ensureUnusedCapacity(gpa, idx.len) catch return;
        b.cmds.ensureUnusedCapacity(gpa, 1) catch return;
        const base: u32 = @intCast(b.verts.items.len);
        const first: u32 = @intCast(b.idx.items.len);
        b.verts.appendSliceAssumeCapacity(v);
        for (idx) |i| b.idx.appendAssumeCapacity(base + i);
        if (b.cmds.items.len > 0) {
            const last = &b.cmds.items[b.cmds.items.len - 1];
            const fits_tex = tex == null or last.tex == null or last.tex == tex;
            // A shape ignores the sampler, so it never decides one: the first texture after it does.
            const textured = tex != null and last.tex != null;
            if (fits_tex and last.state.same(state, textured)) {
                if (last.tex == null and tex != null) {
                    last.tex = tex;
                    last.state.nearest = state.nearest;
                }
                last.count += @intCast(idx.len);
                return;
            }
        }
        b.cmds.appendAssumeCapacity(.{ .tex = tex, .state = state, .first = first, .count = @intCast(idx.len) });
    }
};

pub const SpriteOptions = struct {
    col: Color = .{ .r = 255, .g = 255, .b = 255 },
    add: bool = false,
    nearest: bool = false,
    /// Degrees clockwise about `pivot`, which is relative to the destination's corner.
    angle: f32 = 0,
    pivot: [2]f32 = .{ 0, 0 },
    flip_x: bool = false,
    flip_y: bool = false,
};

fn spriteVerts(tw: f32, th: f32, src: c.SDL_FRect, dst: c.SDL_FRect, o: SpriteOptions) [4]Vertex {
    var left = src.x / tw;
    var right = (src.x + src.w) / tw;
    var top = src.y / th;
    var bottom = (src.y + src.h) / th;
    if (o.flip_x) std.mem.swap(f32, &left, &right);
    if (o.flip_y) std.mem.swap(f32, &top, &bottom);
    const rad = std.math.degreesToRadians(o.angle);
    const cs = @cos(rad);
    const sn = @sin(rad);
    const col = [4]u8{ o.col.r, o.col.g, o.col.b, o.col.a };
    var out: [4]Vertex = undefined;
    const corners = [4][4]f32{ .{ 0, 0, left, top }, .{ dst.w, 0, right, top }, .{ dst.w, dst.h, right, bottom }, .{ 0, dst.h, left, bottom } };
    for (corners, &out) |q, *v| {
        const px = q[0] - o.pivot[0];
        const py = q[1] - o.pivot[1];
        v.* = .{
            .x = dst.x + o.pivot[0] + (if (o.angle != 0) px * cs - py * sn else px),
            .y = dst.y + o.pivot[1] + (if (o.angle != 0) px * sn + py * cs else py),
            .u = q[2],
            .v = q[3],
            .col = col,
        };
    }
    return out;
}

const os = @import("builtin").os.tag;
// Built from the WGSL in shaders/ by build.zig.
const vert_src = if (os == .windows) @embedFile("sprite.vert") else if (os == .macos) @embedFile("sprite.vert") else {};
const frag_src = if (os == .windows) @embedFile("sprite.frag") else if (os == .macos) @embedFile("sprite.frag") else {};
// Vulkan reads SPIR-V as 32-bit words.
const vert_spv align(4) = if (os == .linux) @embedFile("sprite.vert").* else {};
const frag_spv align(4) = if (os == .linux) @embedFile("sprite.frag").* else {};
const shader_entry: [*c]const u8 = if (os == .macos) "main0" else "main";

/// FSRCNNX's layers, each writing the image with its own index. `inputs` are earlier images, the movie being -1.
/// All work at the movie's size but the last, which is twice it.
const up_passes = [_][]const i8{
    &.{-1},
    &.{-1},
    &.{ 0, 1 },
    &.{ 0, 1 },
    &.{ 2, 3 },
    &.{ 2, 3 },
    &.{ 4, 5 },
    &.{ 4, 5 },
    &.{ 6, 7 },
    &.{ 6, 7 },
    &.{ 8, 9, 0 },
    &.{ 8, 9, 1 },
    &.{ 10, 11 },
    &.{12},
};

fn SpirV(comptime name: []const u8) type {
    return struct {
        const bytes align(4) = @embedFile(name).*;
    };
}

fn shaderFunc(comptime name: []const u8, comptime target: [*:0]const u8) c.sg_shader_function {
    var f = std.mem.zeroes(c.sg_shader_function);
    f.entry = shader_entry;
    f.d3d11_target = target;
    switch (os) {
        .windows, .macos => f.source = @embedFile(name),
        else => f.bytecode = .{ .ptr = &SpirV(name).bytes, .size = SpirV(name).bytes.len },
    }
    return f;
}

pub const Gfx = struct {
    gpa: std.mem.Allocator,
    win: *c.SDL_Window,
    /// Upscale movies with FSRCNNX.
    upscale_on: bool = false,
    upscale_tried: bool = false,
    /// Zero ids when the GPU can't run it.
    up_pipes: [up_passes.len]c.sg_pipeline = @splat(.{ .id = 0 }),
    up_merge: c.sg_pipeline = .{ .id = 0 },
    vsync_wanted: ?i32 = null,
    reflex_wanted: ?i32 = null,
    pipelines: [2]c.sg_pipeline = undefined, // blend, add
    samplers: [2]c.sg_sampler = undefined, // linear, nearest
    /// Bound for draws of nothing but shapes.
    white: *Texture = undefined,
    batch: Batch = .{},
    state: State = .{},
    /// Textures released once the frame that may draw them is sent.
    dead: std.ArrayList(*Texture) = .empty,
    vbuf: c.sg_buffer = .{ .id = 0 },
    ibuf: c.sg_buffer = .{ .id = 0 },
    vbuf_size: usize = 0,
    ibuf_size: usize = 0,
    fonts: [font_sizes.len]?*c.TTF_Font = @splat(null),
    cjk_fonts: [font_sizes.len][max_cjk_fonts]?*c.TTF_Font = @splat(@splat(null)),
    /// Font file for the next text calls, null for the built-in one.
    text_font: ?[:0]const u8 = null,
    /// Opened skin fonts by file and exact size; null remembers a file that would not open.
    /// shortcut: kept until exit and only TTF/OTF, bitmap .fnt files show in the built-in font.
    file_fonts: std.AutoHashMapUnmanaged(u64, ?*c.TTF_Font) = .empty,
    text_cache: std.AutoHashMapUnmanaged(TextKey, TextEntry) = .empty,
    frame: u64 = 0,
    backdrop_tex: ?*Texture = null,
    backdrop_tried: bool = false,
    w: f32 = 1280,
    h: f32 = 720,

    /// Mouse for this frame, in render pixels. Widgets read it while they draw.
    mx: f32 = -1,
    my: f32 = -1,
    down: bool = false,
    clicked: bool = false,
    right_clicked: bool = false,
    wheel: f32 = 0,

    const font_sizes = [_]u16{ 12, 14, 16, 20, 24, 32, 48, 72, 96, 144 };

    pub fn init(gpa: std.mem.Allocator, win: *c.SDL_Window) !Gfx {
        if (!c.TTF_Init()) return error.Ttf;
        if (!c.rb_setup(win)) {
            std.log.err("no graphics device: {s}", .{c.SDL_GetError()});
            return error.GpuDevice;
        }
        var g: Gfx = .{ .gpa = gpa, .win = win };
        const sh = c.sg_make_shader(&shaderDesc());
        g.pipelines = .{ pipeline(sh, false), pipeline(sh, true) };
        for ([_]c_uint{ c.SG_FILTER_LINEAR, c.SG_FILTER_NEAREST }, &g.samplers) |filter, *out| {
            var d = std.mem.zeroes(c.sg_sampler_desc);
            d.min_filter = filter;
            d.mag_filter = filter;
            d.wrap_u = c.SG_WRAP_CLAMP_TO_EDGE;
            d.wrap_v = c.SG_WRAP_CLAMP_TO_EDGE;
            out.* = c.sg_make_sampler(&d);
        }
        const pixel = [4]u8{ 255, 255, 255, 255 };
        g.white = g.textureFromPixels(&pixel, 1, 1, 4) orelse return error.GpuTexture;
        for (font_sizes, 0..) |sz, i| {
            const data: []const u8 = if (sz >= heavy_from_size) font_heavy else font_medium;
            const io = c.SDL_IOFromConstMem(data.ptr, data.len);
            g.fonts[i] = c.TTF_OpenFontIO(io, true, @floatFromInt(sz));
            // Hinting bends SUITE's outlines at small sizes.
            if (g.fonts[i] != null) c.TTF_SetFontHinting(g.fonts[i], c.TTF_HINTING_NONE);
            var found: usize = 0;
            const cjk_paths: []const [:0]const u8 = if (sz >= heavy_from_size) &cjk_heavy else &cjk_medium;
            for (cjk_paths) |path| {
                if (found == max_cjk_fonts) break;
                const f = c.TTF_OpenFont(path.ptr, @floatFromInt(sz)) orelse continue;
                c.TTF_SetFontHinting(f, c.TTF_HINTING_NONE);
                g.cjk_fonts[i][found] = f;
                found += 1;
            }
        }
        return g;
    }

    fn shaderDesc() c.sg_shader_desc {
        var d = std.mem.zeroes(c.sg_shader_desc);
        if (os == .linux) {
            d.vertex_func.bytecode = .{ .ptr = &vert_spv, .size = vert_spv.len };
            d.fragment_func.bytecode = .{ .ptr = &frag_spv, .size = frag_spv.len };
        } else {
            d.vertex_func.source = vert_src;
            d.fragment_func.source = frag_src;
        }
        d.vertex_func.entry = shader_entry;
        d.fragment_func.entry = shader_entry;
        for (0..3) |i| {
            d.attrs[i].base_type = c.SG_SHADERATTRBASETYPE_FLOAT;
            d.attrs[i].hlsl_sem_name = "TEXCOORD";
            d.attrs[i].hlsl_sem_index = @intCast(i);
        }
        d.uniform_blocks[0].stage = c.SG_SHADERSTAGE_VERTEX;
        d.uniform_blocks[0].size = @sizeOf([4]f32);
        d.views[0].texture.stage = c.SG_SHADERSTAGE_FRAGMENT;
        d.views[0].texture.image_type = c.SG_IMAGETYPE_2D;
        d.views[0].texture.sample_type = c.SG_IMAGESAMPLETYPE_FLOAT;
        d.samplers[0].stage = c.SG_SHADERSTAGE_FRAGMENT;
        d.samplers[0].sampler_type = c.SG_SAMPLERTYPE_FILTERING;
        d.texture_sampler_pairs[0].stage = c.SG_SHADERSTAGE_FRAGMENT;
        // spirv-cross keeps the WGSL's binding as the register number.
        d.samplers[0].spirv_set1_binding_n = 1;
        d.samplers[0].hlsl_register_s_n = 1;
        d.samplers[0].msl_sampler_n = 1;
        return d;
    }

    fn fragmentTextures(s: *c.sg_shader_desc, count: usize) void {
        for (0..count) |b| {
            s.views[b].texture.stage = c.SG_SHADERSTAGE_FRAGMENT;
            s.views[b].texture.image_type = c.SG_IMAGETYPE_2D;
            s.views[b].texture.sample_type = c.SG_IMAGESAMPLETYPE_FLOAT;
            s.views[b].texture.spirv_set1_binding_n = @intCast(b);
            s.views[b].texture.hlsl_register_t_n = @intCast(b);
            s.views[b].texture.msl_texture_n = @intCast(b);
        }
    }

    fn upPipeline(comptime i: usize) c.sg_pipeline {
        const name = if (i == up_passes.len - 1) "fsrcnnx_unpack.frag" else std.fmt.comptimePrint("fsrcnnx_{d}.frag", .{i});
        var s = std.mem.zeroes(c.sg_shader_desc);
        s.vertex_func = shaderFunc("upscale.vert", "vs_5_0");
        s.fragment_func = shaderFunc(name, "ps_5_0");
        fragmentTextures(&s, up_passes[i].len);
        var d = std.mem.zeroes(c.sg_pipeline_desc);
        d.shader = c.sg_make_shader(&s);
        d.colors[0].pixel_format = c.SG_PIXELFORMAT_RGBA16F;
        d.depth.pixel_format = c.SG_PIXELFORMAT_NONE;
        d.sample_count = 1;
        return c.sg_make_pipeline(&d);
    }

    fn mergePipeline() c.sg_pipeline {
        var s = std.mem.zeroes(c.sg_shader_desc);
        s.vertex_func = shaderFunc("upscale.vert", "vs_5_0");
        s.fragment_func = shaderFunc("upscale.frag", "ps_5_0");
        fragmentTextures(&s, 2);
        s.samplers[0].stage = c.SG_SHADERSTAGE_FRAGMENT;
        s.samplers[0].sampler_type = c.SG_SAMPLERTYPE_FILTERING;
        s.samplers[0].spirv_set1_binding_n = 2;
        s.samplers[0].hlsl_register_s_n = 2;
        s.samplers[0].msl_sampler_n = 2;
        s.texture_sampler_pairs[0].stage = c.SG_SHADERSTAGE_FRAGMENT;
        s.texture_sampler_pairs[0].view_slot = 1;
        s.texture_sampler_pairs[0].sampler_slot = 0;
        var d = std.mem.zeroes(c.sg_pipeline_desc);
        d.shader = c.sg_make_shader(&s);
        d.colors[0].pixel_format = c.SG_PIXELFORMAT_RGBA8;
        d.depth.pixel_format = c.SG_PIXELFORMAT_NONE;
        d.sample_count = 1;
        return c.sg_make_pipeline(&d);
    }

    /// Builds the model's shaders, slow on Windows, so call it while loading rather than mid-song.
    pub fn prepareUpscaler(g: *Gfx) void {
        if (g.upscale_tried) return;
        g.upscale_tried = true;
        inline for (0..up_passes.len) |i| {
            const pipe = upPipeline(i);
            if (c.sg_query_pipeline_state(pipe) != c.SG_RESOURCESTATE_VALID) return;
            g.up_pipes[i] = pipe;
        }
        const merge = mergePipeline();
        if (c.sg_query_pipeline_state(merge) == c.SG_RESOURCESTATE_VALID) g.up_merge = merge;
    }

    fn pipeline(sh: c.sg_shader, add: bool) c.sg_pipeline {
        var d = std.mem.zeroes(c.sg_pipeline_desc);
        d.shader = sh;
        d.layout.buffers[0].stride = @sizeOf(Vertex);
        d.layout.attrs[0].format = c.SG_VERTEXFORMAT_FLOAT2;
        d.layout.attrs[0].offset = @offsetOf(Vertex, "x");
        d.layout.attrs[1].format = c.SG_VERTEXFORMAT_FLOAT2;
        d.layout.attrs[1].offset = @offsetOf(Vertex, "u");
        d.layout.attrs[2].format = c.SG_VERTEXFORMAT_UBYTE4N;
        d.layout.attrs[2].offset = @offsetOf(Vertex, "col");
        d.index_type = c.SG_INDEXTYPE_UINT32;
        d.colors[0].blend = .{
            .enabled = true,
            .src_factor_rgb = c.SG_BLENDFACTOR_SRC_ALPHA,
            .dst_factor_rgb = if (add) c.SG_BLENDFACTOR_ONE else c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .op_rgb = c.SG_BLENDOP_ADD,
            .src_factor_alpha = if (add) c.SG_BLENDFACTOR_ZERO else c.SG_BLENDFACTOR_ONE,
            .dst_factor_alpha = if (add) c.SG_BLENDFACTOR_ONE else c.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .op_alpha = c.SG_BLENDOP_ADD,
        };
        return c.sg_make_pipeline(&d);
    }

    pub fn deinit(g: *Gfx) void {
        var it = g.text_cache.valueIterator();
        while (it.next()) |e| g.destroyTexture(e.tex);
        g.text_cache.deinit(g.gpa);
        var opened = g.file_fonts.valueIterator();
        while (opened.next()) |f| if (f.*) |font| c.TTF_CloseFont(font);
        g.file_fonts.deinit(g.gpa);
        for (g.fonts) |f| if (f != null) c.TTF_CloseFont(f);
        for (g.cjk_fonts) |set| for (set) |f| if (f != null) c.TTF_CloseFont(f);
        c.TTF_Quit();
        if (g.backdrop_tex) |t| g.destroyTexture(t);
        g.destroyTexture(g.white);
        g.reapTextures();
        g.dead.deinit(g.gpa);
        g.batch.deinit(g.gpa);
        c.rb_shutdown();
    }

    /// 0 off, 1 on, anything else adaptive.
    pub fn setVsync(g: *Gfx, mode: i32) void {
        g.vsync_wanted = mode;
    }

    /// 0 off, 1 on, 2 on with Boost.
    pub fn setReflex(g: *Gfx, mode: i32) void {
        g.reflex_wanted = mode;
    }

    /// Call before anything the frame samples. Under vsync the loop blocks in `present`, just before this,
    /// so input and the song clock are read just after the wait, at a steady phase of the refresh.
    pub fn waitFrame(g: *Gfx) void {
        if (g.vsync_wanted) |mode| c.rb_set_vsync(mode);
        g.vsync_wanted = null;
        if (g.reflex_wanted) |mode| c.rb_set_reflex(mode);
        g.reflex_wanted = null;
        c.rb_wait_frame();
    }

    pub fn beginFrame(g: *Gfx) void {
        g.frame += 1;
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(g.win, &w, &h);
        g.w = @floatFromInt(@max(w, 1));
        g.h = @floatFromInt(@max(h, 1));
        g.batch.reset();
        g.state = .{};
        if (g.text_cache.count() > 2048) g.evict();
    }

    /// Window coordinates of an event to the pixels everything draws in.
    pub fn pixelDensity(g: *const Gfx) f32 {
        return c.SDL_GetWindowPixelDensity(g.win);
    }

    fn evict(g: *Gfx) void {
        var it = g.text_cache.iterator();
        var drop: std.ArrayList(TextKey) = .empty;
        defer drop.deinit(g.gpa);
        while (it.next()) |e| {
            if (e.value_ptr.frame + 120 < g.frame) drop.append(g.gpa, e.key_ptr.*) catch return;
        }
        for (drop.items) |k| {
            g.destroyTexture(g.text_cache.get(k).?.tex);
            _ = g.text_cache.remove(k);
        }
    }

    fn push(g: *Gfx, v: []const Vertex, idx: []const u32) void {
        g.batch.push(g.gpa, null, g.state, v, idx);
    }

    /// Draws part of a texture, all of it when `src` is null.
    pub fn sprite(g: *Gfx, t: *Texture, src: ?c.SDL_FRect, dst: c.SDL_FRect, o: SpriteOptions) void {
        const v = spriteVerts(t.w, t.h, src orelse .{ .x = 0, .y = 0, .w = t.w, .h = t.h }, dst, o);
        var state = g.state;
        state.add = o.add;
        state.nearest = o.nearest;
        g.batch.push(g.gpa, t, state, &v, &.{ 0, 1, 2, 0, 2, 3 });
    }

    /// A sprite whose opacity runs from `left_a` to `right_a`, so it can melt into what is under it.
    pub fn spriteHFade(g: *Gfx, t: *Texture, src: c.SDL_FRect, dst: c.SDL_FRect, left_a: u8, right_a: u8) void {
        var v = spriteVerts(t.w, t.h, src, dst, .{});
        v[0].col[3] = left_a;
        v[3].col[3] = left_a;
        v[1].col[3] = right_a;
        v[2].col[3] = right_a;
        var state = g.state;
        state.add = false;
        state.nearest = false;
        g.batch.push(g.gpa, t, state, &v, &.{ 0, 1, 2, 0, 2, 3 });
    }

    /// A texture to fill with `updateTexture`.
    pub fn createTexture(g: *Gfx, w: c_int, h: c_int) ?*Texture {
        if (w <= 0 or h <= 0) return null;
        const t = g.gpa.create(Texture) catch return null;
        t.* = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
        return t;
    }

    /// Replaces a texture's pixels (RGBA, `pitch` bytes a row). Takes effect for this frame's draws,
    /// which are only recorded at `present`.
    /// Waits for the GPU to go idle under Vulkan, so per-frame pixels belong in `streamTexture`.
    pub fn updateTexture(g: *Gfx, t: *Texture, px: [*]const u8, pitch: usize) void {
        const w: usize = @intFromFloat(t.w);
        const h: usize = @intFromFloat(t.h);
        const tight = w * 4;
        var packed_px: []u8 = &.{};
        defer if (packed_px.len > 0) g.gpa.free(packed_px);
        if (pitch != tight) {
            packed_px = g.gpa.alloc(u8, tight * h) catch return;
            for (0..h) |row| @memcpy(packed_px[row * tight ..][0..tight], px[row * pitch ..][0..tight]);
        }
        var d = std.mem.zeroes(c.sg_image_desc);
        d.width = @intCast(w);
        d.height = @intCast(h);
        d.pixel_format = c.SG_PIXELFORMAT_RGBA8;
        d.data = .{ .ptr = if (pitch != tight) packed_px.ptr else px, .size = tight * h };
        const image = c.sg_make_image(&d);
        var v = std.mem.zeroes(c.sg_view_desc);
        v.texture.image = image;
        const view = c.sg_make_view(&v);
        if (c.sg_query_view_state(view) != c.SG_RESOURCESTATE_VALID) {
            c.sg_destroy_view(view);
            c.sg_destroy_image(image);
            return;
        }
        releaseGpu(t);
        t.image = image;
        t.view = view;
    }

    /// Replaces a whole texture's pixels (RGBA, tightly packed) without waiting for the GPU.
    /// At most once a frame, outside a pass; a texture must only ever take one of this and `updateTexture`.
    pub fn streamTexture(g: *Gfx, t: *Texture, px: [*]const u8) void {
        const w: c_int = @intFromFloat(t.w);
        const h: c_int = @intFromFloat(t.h);
        const size: usize = @intCast(w * h * 4);
        // Sokol's per-frame upload space is 16 MB, shared with the vertices.
        if (size > 12 * 1024 * 1024) return g.updateTexture(t, px, @intCast(w * 4));
        if (t.image.id == 0) {
            var d = std.mem.zeroes(c.sg_image_desc);
            d.width = w;
            d.height = h;
            d.pixel_format = c.SG_PIXELFORMAT_RGBA8;
            d.usage.copy_dst = true;
            const image = c.sg_make_image(&d);
            d.usage.copy_dst = false;
            d.usage.write_transient = true;
            d.usage.copy_src = true;
            const staging = c.sg_make_image(&d);
            var v = std.mem.zeroes(c.sg_view_desc);
            v.texture.image = image;
            const view = c.sg_make_view(&v);
            if (c.sg_query_view_state(view) != c.SG_RESOURCESTATE_VALID or c.sg_query_image_state(staging) != c.SG_RESOURCESTATE_VALID) {
                c.sg_destroy_view(view);
                c.sg_destroy_image(image);
                c.sg_destroy_image(staging);
                return;
            }
            t.image = image;
            t.view = view;
            t.staging = staging;
        }
        var write = std.mem.zeroes(c.sg_write_image_desc);
        write.src.data = .{ .ptr = px, .size = size };
        write.src.bytes_per_row = w * 4;
        write.src.bytes_per_slice = @intCast(size);
        write.dst.image = t.staging;
        write.size = .{ .width = w, .height = h, .num_slices = 1 };
        c.sg_write_image_transient(&write);
        var copy = std.mem.zeroes(c.sg_copy_image_to_image_desc);
        copy.src.image = t.staging;
        copy.dst.image = t.image;
        copy.size = write.size;
        c.sg_copy_image_to_image(&copy);
    }

    /// What to draw for a movie this frame: FSRCNNX's output when the movie is being enlarged,
    /// else the movie itself. Only reruns the model when `stale`.
    pub fn upscaled(g: *Gfx, src: *Texture, out: *?Scaled, stale: *bool, from: c.SDL_FRect, to: c.SDL_FRect) *Texture {
        if (!g.upscale_on or g.up_merge.id == 0 or src.view.id == 0 or from.w <= 0 or from.h <= 0) return src;
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(g.win, &pw, &ph);
        // Below this the model's doubled frame would mostly be thrown away again.
        const min_enlargement = 1.3;
        if (to.w / from.w * @as(f32, @floatFromInt(pw)) / g.w < min_enlargement or to.h / from.h * @as(f32, @floatFromInt(ph)) / g.h < min_enlargement) return src;
        if (out.* == null) {
            out.* = g.makeScaled(src) orelse return src;
            stale.* = true;
        }
        const s = &out.*.?;
        if (stale.*) {
            stale.* = false;
            g.runUpscaler(src, s);
        }
        return s.tex;
    }

    fn runUpscaler(g: *Gfx, src: *Texture, s: *Scaled) void {
        for (up_passes, 0..) |inputs, i| {
            var pass = std.mem.zeroes(c.sg_pass);
            pass.action.colors[0].load_action = c.SG_LOADACTION_DONTCARE;
            pass.attachments.colors[0] = s.targets[i];
            c.sg_begin_pass(&pass);
            c.sg_apply_pipeline(g.up_pipes[i]);
            var bind = std.mem.zeroes(c.sg_bindings);
            for (inputs, 0..) |input, b| bind.views[b] = if (input < 0) src.view else s.reads[@intCast(input)];
            c.sg_apply_bindings(&bind);
            c.sg_draw(0, 3, 1);
            c.sg_end_pass();
        }
        var pass = std.mem.zeroes(c.sg_pass);
        pass.action.colors[0].load_action = c.SG_LOADACTION_DONTCARE;
        pass.attachments.colors[0] = s.target;
        c.sg_begin_pass(&pass);
        c.sg_apply_pipeline(g.up_merge);
        var bind = std.mem.zeroes(c.sg_bindings);
        bind.views[0] = s.reads[up_passes.len - 1];
        bind.views[1] = src.view;
        bind.samplers[0] = g.samplers[0];
        c.sg_apply_bindings(&bind);
        c.sg_draw(0, 3, 1);
        c.sg_end_pass();
    }

    fn makeScaled(g: *Gfx, src: *Texture) ?Scaled {
        const w: c_int = @intFromFloat(src.w);
        const h: c_int = @intFromFloat(src.h);
        const t = g.createTexture(w, h) orelse return null;
        var s: Scaled = undefined;
        s.tex = t;
        var ok = true;
        for (0..up_passes.len) |i| {
            var d = std.mem.zeroes(c.sg_image_desc);
            const scale: c_int = if (i == up_passes.len - 1) 2 else 1;
            d.width = w * scale;
            d.height = h * scale;
            d.pixel_format = c.SG_PIXELFORMAT_RGBA16F;
            d.sample_count = 1;
            d.usage.color_attachment = true;
            s.images[i] = c.sg_make_image(&d);
            var v = std.mem.zeroes(c.sg_view_desc);
            v.texture.image = s.images[i];
            s.reads[i] = c.sg_make_view(&v);
            v = std.mem.zeroes(c.sg_view_desc);
            v.color_attachment.image = s.images[i];
            s.targets[i] = c.sg_make_view(&v);
            ok = ok and c.sg_query_view_state(s.reads[i]) == c.SG_RESOURCESTATE_VALID and c.sg_query_view_state(s.targets[i]) == c.SG_RESOURCESTATE_VALID;
        }
        var d = std.mem.zeroes(c.sg_image_desc);
        d.width = w * 2;
        d.height = h * 2;
        d.pixel_format = c.SG_PIXELFORMAT_RGBA8;
        d.sample_count = 1;
        d.usage.color_attachment = true;
        t.image = c.sg_make_image(&d);
        var v = std.mem.zeroes(c.sg_view_desc);
        v.texture.image = t.image;
        t.view = c.sg_make_view(&v);
        v = std.mem.zeroes(c.sg_view_desc);
        v.color_attachment.image = t.image;
        s.target = c.sg_make_view(&v);
        ok = ok and c.sg_query_view_state(t.view) == c.SG_RESOURCESTATE_VALID and c.sg_query_view_state(s.target) == c.SG_RESOURCESTATE_VALID;
        if (!ok) {
            g.dropScaled(&s);
            return null;
        }
        return s;
    }

    pub fn dropScaled(g: *Gfx, s: *Scaled) void {
        for (s.reads, s.targets, s.images) |read, target, image| {
            c.sg_destroy_view(read);
            c.sg_destroy_view(target);
            c.sg_destroy_image(image);
        }
        c.sg_destroy_view(s.target);
        g.destroyTexture(s.tex);
    }

    fn releaseGpu(t: *Texture) void {
        if (t.staging.id != 0) c.sg_destroy_image(t.staging);
        if (t.view.id != 0) c.sg_destroy_view(t.view);
        if (t.image.id != 0) c.sg_destroy_image(t.image);
    }

    pub fn textureFromPixels(g: *Gfx, px: [*]const u8, w: c_int, h: c_int, pitch: usize) ?*Texture {
        const t = g.createTexture(w, h) orelse return null;
        g.updateTexture(t, px, pitch);
        if (t.view.id != 0) return t;
        g.gpa.destroy(t);
        return null;
    }

    pub fn destroyTexture(g: *Gfx, t: *Texture) void {
        g.dead.append(g.gpa, t) catch {};
    }

    fn reapTextures(g: *Gfx) void {
        for (g.dead.items) |t| {
            releaseGpu(t);
            g.gpa.destroy(t);
        }
        g.dead.clearRetainingCapacity();
    }

    fn growBuffer(buf: *c.sg_buffer, have: *usize, need: usize, index: bool) void {
        if (buf.id != 0 and have.* >= need) return;
        if (buf.id != 0) c.sg_destroy_buffer(buf.*);
        have.* = @max(need * 2, 1 << 16);
        var d = std.mem.zeroes(c.sg_buffer_desc);
        d.size = have.*;
        d.usage.vertex_buffer = !index;
        d.usage.index_buffer = index;
        d.usage.write_transient = true;
        buf.* = c.sg_make_buffer(&d);
    }

    fn writeBuffer(buf: c.sg_buffer, bytes: []const u8) void {
        var d = std.mem.zeroes(c.sg_write_buffer_desc);
        d.src.data = .{ .ptr = bytes.ptr, .size = bytes.len };
        d.dst.buffer = buf;
        d.size = bytes.len;
        c.sg_write_buffer_transient(&d);
    }

    /// Sends the frame's draws to the backbuffer.
    fn record(g: *Gfx) void {
        defer g.batch.reset();
        const ready = g.batch.cmds.items.len > 0;
        if (ready) {
            const verts = std.mem.sliceAsBytes(g.batch.verts.items);
            const idx = std.mem.sliceAsBytes(g.batch.idx.items);
            growBuffer(&g.vbuf, &g.vbuf_size, verts.len, false);
            growBuffer(&g.ibuf, &g.ibuf_size, idx.len, true);
            writeBuffer(g.vbuf, verts);
            writeBuffer(g.ibuf, idx);
        }
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(g.win, &w, &h);
        w = @max(w, 1);
        h = @max(h, 1);
        var pass = std.mem.zeroes(c.sg_pass);
        pass.action.colors[0].load_action = c.SG_LOADACTION_CLEAR;
        pass.action.colors[0].clear_value = .{ .r = @as(f32, bg.r) / 255, .g = @as(f32, bg.g) / 255, .b = @as(f32, bg.b) / 255, .a = 1 };
        pass.swapchain = c.rb_swapchain(w, h);
        c.sg_begin_pass(&pass);
        if (ready) {
            const size = [4]f32{ g.w, g.h, 0, 0 };
            const uniforms: c.sg_range = .{ .ptr = &size, .size = @sizeOf(@TypeOf(size)) };
            var bind = std.mem.zeroes(c.sg_bindings);
            bind.vertex_buffers[0] = g.vbuf;
            bind.index_buffer = g.ibuf;
            const whole: c.SDL_Rect = .{ .x = 0, .y = 0, .w = w, .h = h };
            var add: ?bool = null;
            for (g.batch.cmds.items) |d| {
                if (add != d.state.add) {
                    add = d.state.add;
                    c.sg_apply_pipeline(g.pipelines[@intFromBool(d.state.add)]);
                    c.sg_apply_uniforms(0, &uniforms);
                }
                const tex = d.tex orelse g.white;
                bind.views[0] = if (tex.view.id != 0) tex.view else g.white.view;
                bind.samplers[0] = g.samplers[@intFromBool(d.state.nearest)];
                c.sg_apply_bindings(&bind);
                var box = whole;
                if (d.state.clip) |r| _ = c.SDL_GetRectIntersection(&whole, &r, &box);
                c.sg_apply_scissor_rect(box.x, box.y, box.w, box.h, true);
                c.sg_draw(@intCast(d.first), @intCast(d.count), 1);
            }
        }
        c.sg_end_pass();
        c.sg_commit();
    }

    pub fn rect(g: *Gfx, x: f32, y: f32, w: f32, h: f32, col: Color) void {
        g.quad(.{ vert(x, y, col), vert(x + w, y, col), vert(x + w, y + h, col), vert(x, y + h, col) });
    }

    fn quad(g: *Gfx, v: [4]Vertex) void {
        const idx = [6]u32{ 0, 1, 2, 0, 2, 3 };
        g.push(&v, &idx);
    }

    /// The menus' backdrop: a night sky under a dim, so text stays readable.
    pub fn backdrop(g: *Gfx) void {
        if (!g.backdrop_tried) {
            g.backdrop_tried = true;
            var w: c_int = 0;
            var h: c_int = 0;
            var n: c_int = 0;
            // shortcut: decodes on the main thread at first use, one short hitch; a thread if it shows.
            if (c.stbi_load_from_memory(backdrop_jpg.ptr, @intCast(backdrop_jpg.len), &w, &h, &n, 4)) |px| {
                defer c.stbi_image_free(px);
                g.backdrop_tex = g.textureFromPixels(px, w, h, @intCast(w * 4));
            }
        }
        const tex = g.backdrop_tex orelse return g.vgrad(0, 0, g.w, g.h, .{ .r = 22, .g = 36, .b = 78 }, well);
        const k = @min(tex.w / g.w, tex.h / g.h);
        g.sprite(tex, .{ .x = (tex.w - g.w * k) / 2, .y = (tex.h - g.h * k) / 2, .w = g.w * k, .h = g.h * k }, .{ .x = 0, .y = 0, .w = g.w, .h = g.h }, .{});
        g.rect(0, 0, g.w, g.h, .{ .r = 0, .g = 0, .b = 0, .a = 215 });
    }

    pub fn vgrad(g: *Gfx, x: f32, y: f32, w: f32, h: f32, top: Color, bottom: Color) void {
        g.quad(.{ vert(x, y, top), vert(x + w, y, top), vert(x + w, y + h, bottom), vert(x, y + h, bottom) });
    }

    pub fn hgrad(g: *Gfx, x: f32, y: f32, w: f32, h: f32, left: Color, right: Color) void {
        g.quad(.{ vert(x, y, left), vert(x + w, y, right), vert(x + w, y + h, right), vert(x, y + h, left) });
    }

    /// Arc as a strip. `from`, `to` in radians; a full circle when they differ by tau.
    pub fn ring(g: *Gfx, cx: f32, cy: f32, r: f32, thick: f32, from: f32, to: f32, col: Color) void {
        const segs = 48;
        var v: [2 * (segs + 1)]Vertex = undefined;
        var idx: [6 * segs]u32 = undefined;
        for (0..segs + 1) |i| {
            const a = from + (to - from) * @as(f32, @floatFromInt(i)) / segs;
            v[i * 2] = vert(cx + @cos(a) * r, cy + @sin(a) * r, col);
            v[i * 2 + 1] = vert(cx + @cos(a) * (r - thick), cy + @sin(a) * (r - thick), col);
        }
        for (0..segs) |i| {
            const b: u32 = @intCast(i * 2);
            idx[i * 6 ..][0..6].* = .{ b, b + 1, b + 3, b, b + 3, b + 2 };
        }
        g.push(&v, &idx);
    }

    pub fn disc(g: *Gfx, cx: f32, cy: f32, r: f32, col: Color) void {
        g.ring(cx, cy, r, r, 0, std.math.tau, col);
    }

    pub fn line(g: *Gfx, x0: f32, y0: f32, x1: f32, y1: f32, col: Color) void {
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len = @max(@sqrt(dx * dx + dy * dy), 0.001);
        const nx = -dy / len / 2;
        const ny = dx / len / 2;
        g.quad(.{ vert(x0 + nx, y0 + ny, col), vert(x1 + nx, y1 + ny, col), vert(x1 - nx, y1 - ny, col), vert(x0 - nx, y0 - ny, col) });
    }

    /// Light adds up while this is on: bombs, beams, glows. Sprites choose their own blending.
    pub fn additive(g: *Gfx, on: bool) void {
        g.state.add = on;
    }

    pub fn hit(g: *const Gfx, x: f32, y: f32, w: f32, h: f32) bool {
        return g.mx >= x and g.mx < x + w and g.my >= y and g.my < y + h;
    }

    /// True once for a click inside the box; the click is then used up.
    pub fn clickIn(g: *Gfx, x: f32, y: f32, w: f32, h: f32) bool {
        if (!g.clicked or !g.hit(x, y, w, h)) return false;
        g.clicked = false;
        return true;
    }

    pub fn round(g: *Gfx, x: f32, y: f32, w: f32, h: f32, radius: f32, col: Color) void {
        const r = @min(radius, @min(w, h) / 2);
        const per = 6;
        var v: [1 + 4 * per]Vertex = undefined;
        var idx: [3 * 4 * per]u32 = undefined;
        v[0] = vert(x + w / 2, y + h / 2, col);
        const cx = [4]f32{ x + w - r, x + r, x + r, x + w - r };
        const cy = [4]f32{ y + h - r, y + h - r, y + r, y + r };
        for (0..4) |q| for (0..per) |i| {
            const a = (@as(f32, @floatFromInt(q)) + @as(f32, @floatFromInt(i)) / (per - 1)) * std.math.pi / 2;
            v[1 + q * per + i] = vert(cx[q] + @cos(a) * r, cy[q] + @sin(a) * r, col);
        };
        for (0..4 * per) |i| {
            const b: u32 = @intCast(i + 1);
            const n: u32 = @intCast((i + 1) % (4 * per) + 1);
            idx[i * 3 ..][0..3].* = .{ 0, b, n };
        }
        g.push(&v, &idx);
    }

    /// Plain rounded plate with a small label.
    pub fn panel(g: *Gfx, x: f32, y: f32, w: f32, h: f32, label: []const u8) void {
        const u = g.h / 720;
        g.round(x, y, w, h, 8 * u, plate.alpha(225));
        if (label.len > 0) _ = g.text(label, x + 10 * u, y + 4 * u, g.scaled(12), dim);
    }

    /// Fixed-width number with dim leading zeros, like a scoreboard.
    pub fn digits(g: *Gfx, right: f32, y: f32, size: u16, cells: u8, value: u64, col: Color) void {
        const cell = g.measure("0", size);
        var v = value;
        var i: u8 = 0;
        while (i < cells) : (i += 1) {
            const lit = v > 0 or (i == 0);
            const ch = [1]u8{'0' + @as(u8, @intCast(v % 10))};
            g.textCentered(&ch, right - cell * (@as(f32, @floatFromInt(i)) + 0.5), y, size, if (lit) col else col.alpha(34));
            v /= 10;
        }
    }

    /// Text with a dark edge so it reads over notes, scaled about its middle for pops.
    pub fn textPop(g: *Gfx, s: []const u8, cx: f32, y: f32, size: u16, col: Color, scale: f32) void {
        const edge = g.textEntry(s, size, .{ .r = 4, .g = 8, .b = 20 }) orelse return;
        const o = @as(f32, @floatFromInt(size)) * 0.05 + 1;
        const w = edge.w * scale;
        const h = edge.h * scale;
        const top = y + (edge.h - h) / 2;
        for ([_][2]f32{ .{ -o, 0 }, .{ o, 0 }, .{ 0, -o }, .{ 0, o } }) |d| {
            g.sprite(edge.tex, null, .{ .x = cx - w / 2 + d[0], .y = top + d[1], .w = w, .h = h }, .{});
        }
        const e = g.textEntry(s, size, col) orelse return;
        g.sprite(e.tex, null, .{ .x = cx - w / 2, .y = top, .w = w, .h = h }, .{ .col = opaque_white.alpha(col.a) });
    }

    /// Limits drawing to a box until `unclip`.
    pub fn clip(g: *Gfx, x: f32, y: f32, w: f32, h: f32) void {
        g.state.clip = .{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = @intFromFloat(w), .h = @intFromFloat(h) };
    }

    pub fn unclip(g: *Gfx) void {
        g.state.clip = null;
    }

    /// A size from the 720p design, scaled to the window.
    pub fn scaled(g: *const Gfx, n: f32) u16 {
        return @intFromFloat(@round(n * g.h / 720));
    }

    fn fontIndex(size: u16) usize {
        for (font_sizes, 0..) |s, i| if (s >= size) return i;
        return font_sizes.len - 1;
    }

    fn fontFor(g: *Gfx, size: u16) ?*c.TTF_Font {
        const builtin = g.fonts[fontIndex(size)];
        const path = g.text_font orelse return builtin;
        const gop = g.file_fonts.getOrPut(g.gpa, std.hash.Wyhash.hash(size, path)) catch return builtin;
        if (!gop.found_existing) {
            gop.value_ptr.* = c.TTF_OpenFont(path.ptr, @floatFromInt(size));
            // Skin fonts are usually Japanese only: song titles fall through to the built-in chain.
            if (gop.value_ptr.*) |f| if (builtin != null) {
                _ = c.TTF_AddFallbackFont(f, builtin);
            };
        }
        return gop.value_ptr.* orelse builtin;
    }

    pub const Size = struct { w: f32, h: f32 };
    const opaque_white: Color = .{ .r = 255, .g = 255, .b = 255 };

    /// SDL_ttf hangs a fallback glyph from its own font's ascent, which sits it below the main baseline,
    /// so each CJK run is rendered with its own font and placed on the main font's baseline by hand.
    fn renderRuns(g: *Gfx, main: *c.TTF_Font, size: u16, s: []const u8, col: c.SDL_Color) ?*c.SDL_Surface {
        const picker: GlyphFont = .{ .main = main, .cjk = &g.cjk_fonts[fontIndex(size)] };
        if (runEnd(s, 0, picker) == s.len and picker.of(decodeAt(s, 0).cp) == main) {
            return c.TTF_RenderText_Blended(main, s.ptr, s.len, col);
        }
        var total: c_int = 0;
        var at: usize = 0;
        while (at < s.len) {
            const end = runEnd(s, at, picker);
            var w: c_int = 0;
            if (!c.TTF_GetStringSize(picker.of(decodeAt(s, at).cp), s[at..].ptr, end - at, &w, null)) return null;
            total += w;
            at = end;
        }
        const canvas = c.SDL_CreateSurface(total, c.TTF_GetFontHeight(main), c.SDL_PIXELFORMAT_RGBA32) orelse return null;
        var x: c_int = 0;
        at = 0;
        while (at < s.len) {
            const end = runEnd(s, at, picker);
            const font = picker.of(decodeAt(s, at).cp);
            if (c.TTF_RenderText_Blended(font, s[at..].ptr, end - at, col)) |run| {
                defer c.SDL_DestroySurface(run);
                _ = c.SDL_SetSurfaceBlendMode(run, c.SDL_BLENDMODE_NONE);
                var dst: c.SDL_Rect = .{ .x = x, .y = c.TTF_GetFontAscent(main) - c.TTF_GetFontAscent(font), .w = run.*.w, .h = run.*.h };
                _ = c.SDL_BlitSurface(run, null, canvas, &dst);
                x += run.*.w;
            }
            at = end;
        }
        return canvas;
    }

    /// Rendered opaque and faded per draw, so a fading text is not a new texture every frame.
    fn textEntry(g: *Gfx, s: []const u8, size: u16, col_in: Color) ?*TextEntry {
        if (s.len == 0) return null;
        const col = col_in.alpha(255);
        var hasher = std.hash.Wyhash.init(@as(u64, col.r) << 24 | @as(u64, col.g) << 16 | @as(u64, col.b) << 8 | col.a);
        hasher.update(s);
        if (g.text_font) |f| hasher.update(f);
        const key: TextKey = .{ .hash = hasher.final(), .size = size };
        const gop = g.text_cache.getOrPut(g.gpa, key) catch return null;
        if (gop.found_existing) {
            gop.value_ptr.frame = g.frame;
            return gop.value_ptr;
        }
        const font = g.fontFor(size) orelse {
            _ = g.text_cache.remove(key);
            return null;
        };
        const blended = g.renderRuns(font, size, s, .{ .r = col.r, .g = col.g, .b = col.b, .a = col.a });
        defer c.SDL_DestroySurface(blended);
        const surf = if (blended != null) c.SDL_ConvertSurface(blended, c.SDL_PIXELFORMAT_RGBA32) else null;
        defer c.SDL_DestroySurface(surf);
        const tex = if (surf != null) g.textureFromPixels(@ptrCast(surf.*.pixels), surf.*.w, surf.*.h, @intCast(surf.*.pitch)) else null;
        if (tex == null) {
            _ = g.text_cache.remove(key);
            return null;
        }
        gop.value_ptr.* = .{ .tex = tex.?, .w = @floatFromInt(surf.*.w), .h = @floatFromInt(surf.*.h), .frame = g.frame };
        return gop.value_ptr;
    }

    fn drawEntry(g: *Gfx, e: *const TextEntry, src: ?c.SDL_FRect, dst: c.SDL_FRect, a: u8) void {
        g.sprite(e.tex, src, dst, .{ .col = opaque_white.alpha(a) });
    }

    pub fn text(g: *Gfx, s: []const u8, x: f32, y: f32, size: u16, col: Color) Size {
        const e = g.textEntry(s, size, col) orelse return .{ .w = 0, .h = 0 };
        g.drawEntry(e, null, .{ .x = @round(x), .y = @round(y), .w = e.w, .h = e.h }, col.a);
        return .{ .w = e.w, .h = e.h };
    }

    pub fn textCentered(g: *Gfx, s: []const u8, cx: f32, y: f32, size: u16, col: Color) void {
        const e = g.textEntry(s, size, col) orelse return;
        g.drawEntry(e, null, .{ .x = @round(cx - e.w / 2), .y = @round(y), .w = e.w, .h = e.h }, col.a);
    }

    pub fn textRight(g: *Gfx, s: []const u8, right: f32, y: f32, size: u16, col: Color) void {
        const e = g.textEntry(s, size, col) orelse return;
        g.drawEntry(e, null, .{ .x = @round(right - e.w), .y = @round(y), .w = e.w, .h = e.h }, col.a);
    }

    pub fn measure(g: *Gfx, s: []const u8, size: u16) f32 {
        const e = g.textEntry(s, size, white) orelse return 0;
        return e.w;
    }

    /// Text clipped to `max_w`.
    pub fn textClip(g: *Gfx, s: []const u8, x: f32, y: f32, max_w: f32, size: u16, col: Color) void {
        const e = g.textEntry(s, size, col) orelse return;
        const w = @min(e.w, max_w);
        g.drawEntry(e, .{ .x = 0, .y = 0, .w = w, .h = e.h }, .{ .x = @round(x), .y = @round(y), .w = w, .h = e.h }, col.a);
    }

    pub fn fmt(g: *Gfx, x: f32, y: f32, size: u16, col: Color, comptime f: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, f, args) catch return;
        _ = g.text(s, x, y, size, col);
    }

    /// `fmt` for text with a row in i18n.
    pub fn fmtTr(g: *Gfx, x: f32, y: f32, size: u16, col: Color, comptime f: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const s = i18n.bufPrint(&buf, f, args) catch return;
        _ = g.text(s, x, y, size, col);
    }

    pub fn present(g: *Gfx) void {
        defer g.reapTextures();
        g.record();
        c.rb_present();
    }

    /// Writes this frame to a BMP. Used once, at the end of a run.
    pub fn saveShot(g: *Gfx, path: [*:0]const u8) void {
        g.record();
        const w: c_int = @intFromFloat(g.w);
        const h: c_int = @intFromFloat(g.h);
        const px = g.gpa.alloc(u8, @intCast(w * h * 4)) catch return;
        defer g.gpa.free(px);
        if (!c.rb_read_pixels(w, h, px.ptr)) {
            std.log.warn("--shot needs the Vulkan backend", .{});
            return;
        }
        const surf = c.SDL_CreateSurfaceFrom(w, h, c.SDL_PIXELFORMAT_RGBA32, px.ptr, w * 4);
        if (surf != null) {
            _ = c.SDL_SaveBMP(surf, path);
            c.SDL_DestroySurface(surf);
        }
    }
};

/// Loads an image file into a texture with stb_image.
pub fn loadTexture(g: *Gfx, path: []const u8, bytes: []const u8) ?*Texture {
    _ = path;
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    const px = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &n, 4);
    if (px == null) return null;
    defer c.stbi_image_free(px);
    const size = fitTexture(w, h);
    if (size[0] == w and size[1] == h) return g.textureFromPixels(px, w, h, @intCast(w * 4));
    const small = g.gpa.alloc(u8, @intCast(size[0] * size[1] * 4)) catch return null;
    defer g.gpa.free(small);
    const from: [*]const u8 = @ptrCast(px);
    for (0..@intCast(size[1])) |y| {
        const sy = y * @as(usize, @intCast(h)) / @as(usize, @intCast(size[1]));
        for (0..@intCast(size[0])) |x| {
            const sx = x * @as(usize, @intCast(w)) / @as(usize, @intCast(size[0]));
            const at = (sy * @as(usize, @intCast(w)) + sx) * 4;
            @memcpy(small[(y * @as(usize, @intCast(size[0])) + x) * 4 ..][0..4], from[at..][0..4]);
        }
    }
    return g.textureFromPixels(small.ptr, size[0], size[1], @intCast(size[0] * 4));
}

/// shortcut: 16384 is what desktop GPUs take; ask the device if a smaller one turns up.
const max_texture = 16384;

/// An image past the GPU's limit loads squeezed along that axis, not at all otherwise. Sources are fractions, so they hold.
fn fitTexture(w: c_int, h: c_int) [2]c_int {
    return .{ @min(w, max_texture), @min(h, max_texture) };
}

const GlyphFont = struct {
    main: *c.TTF_Font,
    cjk: []const ?*c.TTF_Font,

    fn of(p: GlyphFont, cp: u32) *c.TTF_Font {
        if (c.TTF_FontHasGlyph(p.main, cp)) return p.main;
        for (p.cjk) |f| if (f != null and c.TTF_FontHasGlyph(f, cp)) return f.?;
        return p.main;
    }
};

fn decodeAt(s: []const u8, at: usize) struct { cp: u32, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(s[at]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (at + len > s.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(s[at..][0..len]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// Where the run of glyphs from one font, starting at `at`, ends.
fn runEnd(s: []const u8, at: usize, picker: anytype) usize {
    const first = picker.of(decodeAt(s, at).cp);
    var i = at + decodeAt(s, at).len;
    while (i < s.len and picker.of(decodeAt(s, i).cp) == first) i += decodeAt(s, i).len;
    return i;
}

test "runs split where the font changes and survive broken UTF-8" {
    const Stub = struct {
        fn of(_: @This(), cp: u32) bool {
            return cp >= 0x3040 and cp <= 0x9FFF;
        }
    };
    const stub: Stub = .{};
    try std.testing.expectEqual(@as(usize, 6), runEnd("オン + Boost", 0, stub));
    try std.testing.expectEqual(@as(usize, 14), runEnd("オン + Boost", 6, stub));
    try std.testing.expectEqual(@as(usize, 7), runEnd("English", 0, stub));
    try std.testing.expectEqual(@as(usize, 2), runEnd("a\xE6", 0, stub));
    try std.testing.expectEqual(@as(usize, 2), runEnd("a\xE6", 1, stub));
}

test "only an axis past the limit is squeezed" {
    try std.testing.expectEqual([2]c_int{ 128, 16384 }, fitTexture(128, 40000));
    try std.testing.expectEqual([2]c_int{ 150, 150 }, fitTexture(150, 150));
}

test "batch keeps one draw while only shapes and one texture alternate" {
    const gpa = std.testing.allocator;
    var b: Batch = .{};
    defer b.deinit(gpa);
    var tex_a: Texture = undefined;
    var tex_b: Texture = undefined;
    const v: [4]Vertex = @splat(vert(0, 0, white));
    const idx = [_]u32{ 0, 1, 2 };
    b.push(gpa, null, .{}, &v, &idx);
    b.push(gpa, &tex_a, .{ .nearest = true }, &v, &idx);
    b.push(gpa, null, .{}, &v, &idx);
    b.push(gpa, &tex_a, .{ .nearest = true }, &v, &idx);
    try std.testing.expectEqual(@as(usize, 1), b.cmds.items.len);
    try std.testing.expectEqual(&tex_a, b.cmds.items[0].tex.?);
    try std.testing.expect(b.cmds.items[0].state.nearest);
    try std.testing.expectEqual(@as(u32, 12), b.cmds.items[0].count);
    b.push(gpa, &tex_b, .{}, &v, &idx);
    b.push(gpa, null, .{ .add = true }, &v, &idx);
    try std.testing.expectEqual(@as(usize, 3), b.cmds.items.len);
}

test "sprite flips by swapping texture coordinates and turns about its pivot" {
    const src: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const dst: c.SDL_FRect = .{ .x = 100, .y = 100, .w = 10, .h = 10 };
    const flipped = spriteVerts(10, 10, src, dst, .{ .flip_x = true });
    try std.testing.expectEqual(@as(f32, 1), flipped[0].u);
    try std.testing.expectEqual(@as(f32, 0), flipped[1].u);
    const turned = spriteVerts(10, 10, src, dst, .{ .angle = 90, .pivot = .{ 0, 0 } });
    try std.testing.expectApproxEqAbs(@as(f32, 100), turned[1].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 110), turned[1].y, 0.001);
}
