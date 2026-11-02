// What Gfx needs from the platform: a device for sokol_gfx, and the window's backbuffer.
#pragma once
#include <SDL3/SDL.h>

// Call before SDL_CreateWindow; returns the flags the window needs.
SDL_WindowFlags rb_window_flags(void);
bool rb_setup(SDL_Window *win);
void rb_shutdown(void);
// 0 off, 1 on, anything else adaptive.
void rb_set_vsync(int mode);
// NVIDIA Reflex: 0 off, 1 on, anything else on with Boost. Does nothing without an NVIDIA driver that has it.
void rb_set_reflex(int mode);
// Call before sampling input: Reflex holds the frame here so it finishes as late as it safely can.
void rb_wait_frame(void);
// The backbuffer to draw this frame into, sized to the window.
sg_swapchain rb_swapchain(int w, int h);
void rb_present(void);
// Copies the drawn frame out, top row first, RGBA. False where the backend has no way to.
// The size of the frame rb_read_pixels reads, which a surface can keep from matching the window's.
void rb_frame_size(int *w, int *h);
// For a frame rb_read_pixels will read, called before its pass ends. Does nothing where presenting comes later anyway.
void rb_hold_present(void);
bool rb_read_pixels(int w, int h, void *rgba);
