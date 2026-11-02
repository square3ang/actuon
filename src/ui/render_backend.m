// sokol_gfx's implementation and its platform half on macOS: Metal.
#include <SDL3/SDL.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#define SOKOL_METAL
#define SOKOL_IMPL
#include "sokol_gfx.h"
#include "render_backend.h"

static SDL_MetalView rb_view;
static CAMetalLayer *rb_layer;
static id<CAMetalDrawable> rb_drawable;

static void rb_log(const char *tag, uint32_t level, uint32_t item, const char *msg, uint32_t line, const char *file, void *ud) {
    (void)tag; (void)ud;
    SDL_Log("sokol_gfx level %u item %u: %s (%s:%u)", level, item, msg ? msg : "", file ? file : "", line);
}

SDL_WindowFlags rb_window_flags(void) { return SDL_WINDOW_METAL; }

bool rb_setup(SDL_Window *win) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    rb_view = SDL_Metal_CreateView(win);
    if (!dev || !rb_view) return false;
    rb_layer = (__bridge CAMetalLayer *)SDL_Metal_GetLayer(rb_view);
    rb_layer.device = dev;
    rb_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // The screenshot key blits from the drawable.
    rb_layer.framebufferOnly = NO;
    sg_setup(&(sg_desc){
        // Every cached text and skin image is one image and one view.
        .image_pool_size = 1 << 14,
        .view_pool_size = 1 << 14,
        .logger.func = rb_log,
        .environment = {
            .defaults = { .color_format = SG_PIXELFORMAT_BGRA8, .depth_format = SG_PIXELFORMAT_NONE, .sample_count = 1 },
            .metal.device = (__bridge const void *)dev,
        },
    });
    return sg_isvalid();
}

void rb_shutdown(void) {
    sg_shutdown();
    rb_drawable = nil;
    SDL_Metal_DestroyView(rb_view);
}

void rb_set_vsync(int mode) { rb_layer.displaySyncEnabled = mode == 1; }

sg_swapchain rb_swapchain(int w, int h) {
    rb_layer.drawableSize = CGSizeMake(w, h);
    @autoreleasepool { rb_drawable = [rb_layer nextDrawable]; }
    return (sg_swapchain){ .invalid = rb_drawable == nil, .width = w, .height = h, .sample_count = 1, .color_format = SG_PIXELFORMAT_BGRA8, .depth_format = SG_PIXELFORMAT_NONE, .metal.current_drawable = (__bridge const void *)rb_drawable };
}

void rb_set_reflex(int mode) { (void)mode; }
void rb_wait_frame(void) {}

void rb_present(void) { rb_drawable = nil; }

void rb_frame_size(int *w, int *h) {
    if (!rb_drawable) return;
    *w = (int)rb_drawable.texture.width;
    *h = (int)rb_drawable.texture.height;
}

// Sokol presents in sg_end_pass, and a presented drawable's pixels are no longer ours: the shot presents it itself.
void rb_hold_present(void) { _sg.mtl.cur_drawable = nil; }

// Presents as well, as on the other backends.
bool rb_read_pixels(int w, int h, void *rgba) {
    @autoreleasepool {
        id<MTLTexture> tex = rb_drawable.texture;
        NSUInteger pitch = (NSUInteger)w * 4;
        id<MTLBuffer> buf = [rb_layer.device newBufferWithLength:pitch * h options:MTLResourceStorageModeShared];
        // Sokol's own queue, so this runs after the frame it reads.
        id<MTLCommandBuffer> cmd = [_sg.mtl.cmd_queue commandBuffer];
        bool fits = tex && buf && (int)tex.width == w && (int)tex.height == h;
        if (fits) {
            id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
            [blit copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:buf destinationOffset:0 destinationBytesPerRow:pitch destinationBytesPerImage:pitch * h];
            [blit endEncoding];
        }
        if (rb_drawable) [cmd presentDrawable:rb_drawable];
        [cmd commit];
        [cmd waitUntilCompleted];
        rb_present();
        if (!fits || cmd.status != MTLCommandBufferStatusCompleted) return false;
        const uint8_t *src = buf.contents;
        uint8_t *out = rgba;
        for (NSUInteger i = 0; i < pitch * h; i += 4) {
            out[i] = src[i + 2];
            out[i + 1] = src[i + 1];
            out[i + 2] = src[i];
            out[i + 3] = src[i + 3];
        }
        return true;
    }
}
