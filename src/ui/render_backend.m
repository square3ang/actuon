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

// shortcut: --shot only reads back under OpenGL; add a blit to a shared texture if it is needed here.
bool rb_read_pixels(int w, int h, void *rgba) { (void)w; (void)h; (void)rgba; return false; }
