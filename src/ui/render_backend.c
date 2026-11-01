// sokol_gfx's implementation and its platform half: Vulkan on Linux, Direct3D 11 on Windows.
#if defined(_WIN32)
#define COBJMACROS
#define SOKOL_D3D11
#else
#define SOKOL_VULKAN
#include <vulkan/vulkan.h>
// Reflex wants each frame's submit tagged with its present id, and sokol makes that call.
static VkResult rb_queue_submit(VkQueue queue, uint32_t count, const VkSubmitInfo *infos, VkFence fence);
#define vkQueueSubmit rb_queue_submit
#endif
#include <SDL3/SDL.h>
#define SOKOL_IMPL
#include "sokol_gfx.h"
#include "render_backend.h"

static void rb_log(const char *tag, uint32_t level, uint32_t item, const char *msg, uint32_t line, const char *file, void *ud) {
    (void)tag; (void)ud;
    SDL_Log("sokol_gfx level %u item %u: %s (%s:%u)", level, item, msg ? msg : "", file ? file : "", line);
}

static void rb_sg_setup(sg_environment env) {
    sg_setup(&(sg_desc){
        // Every cached text and skin image is one image and one view.
        .image_pool_size = 1 << 14,
        .view_pool_size = 1 << 14,
        .logger.func = rb_log,
        .environment = env,
    });
}

#if defined(_WIN32)
#include <dxgi1_5.h>

static SDL_Window *rb_win;
static ID3D11Device *rb_dev;
static ID3D11DeviceContext *rb_ctx;
static IDXGISwapChain *rb_chain;
static ID3D11RenderTargetView *rb_view;
static int rb_w, rb_h;
static UINT rb_interval = 1, rb_flags;
static bool rb_tearing;

SDL_WindowFlags rb_window_flags(void) { return 0; }

// Reflex through NVAPI. nvapi64.dll ships with NVIDIA's driver, so elsewhere this stays off.
// The ids and layouts are from NVIDIA's nvapi.h and nvapi_interface.h.
typedef struct {
    UINT32 version;
    UINT8 low_latency, boost;
    UINT32 min_interval_us;
    UINT8 use_markers, min_queue, reserved[30];
} rb_nv_sleep_mode;
typedef struct {
    UINT32 version;
    UINT64 frame;
    int marker;
    UINT64 reserved0;
    UINT8 reserved[56];
} rb_nv_marker;
enum { RB_SIM_START, RB_SIM_END, RB_SUBMIT_START, RB_SUBMIT_END, RB_PRESENT_START, RB_PRESENT_END };
static int (*rb_nv_set_sleep_mode)(IUnknown *, rb_nv_sleep_mode *);
static int (*rb_nv_sleep)(IUnknown *);
static int (*rb_nv_set_marker)(IUnknown *, rb_nv_marker *);
static int rb_reflex_mode;
static UINT64 rb_frame_id = 1;

static void rb_nv_load(void) {
    HMODULE dll = LoadLibraryA("nvapi64.dll");
    if (!dll) return;
    void *(*query)(UINT32) = (void *(*)(UINT32))(void *)GetProcAddress(dll, "nvapi_QueryInterface");
    if (!query) return;
    int (*init)(void) = (int (*)(void))query(0x0150e828);
    if (!init || init() != 0) return;
    rb_nv_set_sleep_mode = (int (*)(IUnknown *, rb_nv_sleep_mode *))query(0xac1ca9e0);
    rb_nv_sleep = (int (*)(IUnknown *))query(0x852cd1d2);
    rb_nv_set_marker = (int (*)(IUnknown *, rb_nv_marker *))query(0xd9984c05);
    if (!rb_nv_sleep || !rb_nv_set_marker) rb_nv_set_sleep_mode = NULL;
}

static void rb_nv_mark(int marker) {
    if (!rb_nv_set_sleep_mode || !rb_reflex_mode) return;
    rb_nv_marker m = { .version = sizeof m | 1u << 16, .frame = rb_frame_id, .marker = marker };
    rb_nv_set_marker((IUnknown *)rb_dev, &m);
}

static bool rb_can_tear(void) {
    IDXGIFactory5 *f = NULL;
    BOOL ok = FALSE;
    if (SUCCEEDED(CreateDXGIFactory1(&IID_IDXGIFactory5, (void **)&f))) {
        if (FAILED(IDXGIFactory5_CheckFeatureSupport(f, DXGI_FEATURE_PRESENT_ALLOW_TEARING, &ok, sizeof ok))) ok = FALSE;
        IDXGIFactory5_Release(f);
    }
    return ok;
}

bool rb_setup(SDL_Window *win) {
    HWND hwnd = (HWND)SDL_GetPointerProperty(SDL_GetWindowProperties(win), SDL_PROP_WINDOW_WIN32_HWND_POINTER, NULL);
    if (!hwnd) return false;
    rb_win = win;
    rb_tearing = rb_can_tear();
    SDL_GetWindowSizeInPixels(win, &rb_w, &rb_h);
    DXGI_SWAP_CHAIN_DESC sd = {
        .BufferDesc = { .Width = rb_w, .Height = rb_h, .Format = DXGI_FORMAT_R8G8B8A8_UNORM },
        .SampleDesc = { .Count = 1 },
        .BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 2,
        .OutputWindow = hwnd,
        .Windowed = TRUE,
        .SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD,
        .Flags = rb_tearing ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0,
    };
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    if (FAILED(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &level, 1, D3D11_SDK_VERSION, &sd, &rb_chain, &rb_dev, NULL, &rb_ctx))) return false;
    rb_sg_setup((sg_environment){
        .defaults = { .color_format = SG_PIXELFORMAT_RGBA8, .depth_format = SG_PIXELFORMAT_NONE, .sample_count = 1 },
        .d3d11 = { .device = rb_dev, .device_context = rb_ctx },
    });
    rb_nv_load();
    return sg_isvalid();
}

void rb_shutdown(void) {
    sg_shutdown();
    if (rb_view) ID3D11RenderTargetView_Release(rb_view);
    if (rb_chain) IDXGISwapChain_Release(rb_chain);
    if (rb_ctx) ID3D11DeviceContext_Release(rb_ctx);
    if (rb_dev) ID3D11Device_Release(rb_dev);
}

void rb_set_vsync(int mode) {
    rb_interval = mode == 1 ? 1 : 0;
    // Adaptive replaces a waiting frame without tearing; off shows a frame at once.
    rb_flags = mode == 0 && rb_tearing ? DXGI_PRESENT_ALLOW_TEARING : 0;
}

void rb_set_reflex(int mode) {
    rb_reflex_mode = mode;
    if (!rb_nv_set_sleep_mode) return;
    rb_nv_sleep_mode m = { .version = sizeof m | 1u << 16, .low_latency = mode != 0, .boost = mode != 0 && mode != 1 };
    rb_nv_set_sleep_mode((IUnknown *)rb_dev, &m);
}

sg_swapchain rb_swapchain(int w, int h) {
    rb_nv_mark(RB_SIM_END);
    rb_nv_mark(RB_SUBMIT_START);
    if (rb_view && (w != rb_w || h != rb_h)) {
        ID3D11RenderTargetView_Release(rb_view);
        rb_view = NULL;
        IDXGISwapChain_ResizeBuffers(rb_chain, 2, w, h, DXGI_FORMAT_R8G8B8A8_UNORM, rb_tearing ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0);
    }
    rb_w = w;
    rb_h = h;
    if (!rb_view) {
        ID3D11Texture2D *back = NULL;
        IDXGISwapChain_GetBuffer(rb_chain, 0, &IID_ID3D11Texture2D, (void **)&back);
        ID3D11Device_CreateRenderTargetView(rb_dev, (ID3D11Resource *)back, NULL, &rb_view);
        ID3D11Texture2D_Release(back);
    }
    return (sg_swapchain){ .width = w, .height = h, .sample_count = 1, .color_format = SG_PIXELFORMAT_RGBA8, .depth_format = SG_PIXELFORMAT_NONE, .d3d11.render_view = rb_view };
}

void rb_wait_frame(void) {
    if (!rb_nv_set_sleep_mode || !rb_reflex_mode) return;
    rb_nv_sleep((IUnknown *)rb_dev);
    rb_nv_mark(RB_SIM_START);
}

void rb_present(void) {
    rb_nv_mark(RB_SUBMIT_END);
    rb_nv_mark(RB_PRESENT_START);
    IDXGISwapChain_Present(rb_chain, rb_interval, rb_flags);
    rb_nv_mark(RB_PRESENT_END);
    rb_frame_id++;
}

// shortcut: --shot only reads back under Vulkan; add a staging copy if it is needed on Windows.
bool rb_read_pixels(int w, int h, void *rgba) { (void)w; (void)h; (void)rgba; return false; }

#else
#undef vkQueueSubmit
#include <SDL3/SDL_vulkan.h>

#define RB_MAX_IMAGES 8

static SDL_Window *rb_win;
static VkInstance rb_inst;
static VkPhysicalDevice rb_phys;
static VkDevice rb_dev;
static VkQueue rb_queue;
static uint32_t rb_family;
static VkSurfaceKHR rb_surface;
static VkSwapchainKHR rb_chain;
static VkExtent2D rb_extent;
static uint32_t rb_image_count, rb_image, rb_acquire_next;
static VkImage rb_images[RB_MAX_IMAGES];
static VkImageView rb_views[RB_MAX_IMAGES];
static VkSemaphore rb_rendered[RB_MAX_IMAGES];
static VkSemaphore rb_acquired[RB_MAX_IMAGES + 1];
static VkPresentModeKHR rb_mode = VK_PRESENT_MODE_FIFO_KHR;
static bool rb_stale;

// Reflex and Reflex Boost, on drivers that have them.
static bool rb_reflex;
static VkSemaphore rb_sleep_sem;
static int rb_reflex_mode;
static uint64_t rb_sleep_value, rb_present_id = 1;
static PFN_vkSetLatencySleepModeNV rb_set_sleep_mode;
static PFN_vkLatencySleepNV rb_latency_sleep;
static PFN_vkSetLatencyMarkerNV rb_set_marker;

static VkResult rb_queue_submit(VkQueue queue, uint32_t count, const VkSubmitInfo *infos, VkFence fence) {
    // Two infos is sokol's frame submit, the one that draws; its uploads go one at a time.
    if (!rb_reflex || !rb_reflex_mode || count != 2) return vkQueueSubmit(queue, count, infos, fence);
    VkLatencySubmissionPresentIdNV id = { .sType = VK_STRUCTURE_TYPE_LATENCY_SUBMISSION_PRESENT_ID_NV, .presentID = rb_present_id };
    VkSubmitInfo tagged[2] = { infos[0], infos[1] };
    tagged[1].pNext = &id;
    return vkQueueSubmit(queue, 2, tagged, fence);
}

static void rb_marker(VkLatencyMarkerNV marker) {
    if (!rb_reflex || !rb_reflex_mode) return;
    rb_set_marker(rb_dev, rb_chain, &(VkSetLatencyMarkerInfoNV){ .sType = VK_STRUCTURE_TYPE_SET_LATENCY_MARKER_INFO_NV, .presentID = rb_present_id, .marker = marker });
}

SDL_WindowFlags rb_window_flags(void) { return SDL_WINDOW_VULKAN; }

static bool rb_has_ext(const VkExtensionProperties *exts, uint32_t n, const char *name) {
    for (uint32_t i = 0; i < n; i++)
        if (SDL_strcmp(exts[i].extensionName, name) == 0) return true;
    return false;
}

static bool rb_device_exts(VkPhysicalDevice dev, bool *reflex) {
    uint32_t n = 0;
    vkEnumerateDeviceExtensionProperties(dev, NULL, &n, NULL);
    VkExtensionProperties *exts = SDL_malloc(n * sizeof *exts);
    if (!exts) return false;
    vkEnumerateDeviceExtensionProperties(dev, NULL, &n, exts);
    bool ok = rb_has_ext(exts, n, VK_KHR_SWAPCHAIN_EXTENSION_NAME) && rb_has_ext(exts, n, VK_EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME);
    *reflex = rb_has_ext(exts, n, VK_NV_LOW_LATENCY_2_EXTENSION_NAME) && rb_has_ext(exts, n, VK_KHR_PRESENT_ID_EXTENSION_NAME);
    SDL_free(exts);
    return ok;
}

// A discrete GPU if there is one: an integrated one can't keep this game's frame rate.
static bool rb_pick_device(void) {
    uint32_t n = 0;
    vkEnumeratePhysicalDevices(rb_inst, &n, NULL);
    VkPhysicalDevice devs[16];
    if (n > 16) n = 16;
    vkEnumeratePhysicalDevices(rb_inst, &n, devs);
    int best = -1;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(devs[i], &props);
        bool reflex;
        if (props.apiVersion < VK_API_VERSION_1_3 || !rb_device_exts(devs[i], &reflex)) continue;
        uint32_t qn = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devs[i], &qn, NULL);
        VkQueueFamilyProperties qs[32];
        if (qn > 32) qn = 32;
        vkGetPhysicalDeviceQueueFamilyProperties(devs[i], &qn, qs);
        for (uint32_t q = 0; q < qn; q++) {
            if (!(qs[q].queueFlags & VK_QUEUE_GRAPHICS_BIT) || !SDL_Vulkan_GetPresentationSupport(rb_inst, devs[i], q)) continue;
            int score = props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU ? 2 : 1;
            if (score > best) {
                best = score;
                rb_phys = devs[i];
                rb_family = q;
                rb_reflex = reflex;
            }
            break;
        }
    }
    return best > 0;
}

static bool rb_make_device(void) {
    VkPhysicalDevicePresentIdFeaturesKHR present_id = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR, .presentId = VK_TRUE };
    VkPhysicalDeviceDescriptorBufferFeaturesEXT descriptors = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_BUFFER_FEATURES_EXT, .pNext = rb_reflex ? &present_id : NULL, .descriptorBuffer = VK_TRUE };
    VkPhysicalDeviceVulkan13Features v13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .pNext = &descriptors, .dynamicRendering = VK_TRUE, .synchronization2 = VK_TRUE };
    VkPhysicalDeviceVulkan12Features v12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &v13, .bufferDeviceAddress = VK_TRUE, .timelineSemaphore = VK_TRUE };
    VkPhysicalDeviceFeatures2 features = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &v12 };
    const char *exts[4] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME, VK_EXT_DESCRIPTOR_BUFFER_EXTENSION_NAME, VK_NV_LOW_LATENCY_2_EXTENSION_NAME, VK_KHR_PRESENT_ID_EXTENSION_NAME };
    float priority = 1;
    VkDeviceQueueCreateInfo queue = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = rb_family, .queueCount = 1, .pQueuePriorities = &priority };
    VkDeviceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &features,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue,
        .enabledExtensionCount = rb_reflex ? 4 : 2,
        .ppEnabledExtensionNames = exts,
    };
    if (vkCreateDevice(rb_phys, &info, NULL, &rb_dev) != VK_SUCCESS) return false;
    vkGetDeviceQueue(rb_dev, rb_family, 0, &rb_queue);
    if (rb_reflex) {
        rb_set_sleep_mode = (PFN_vkSetLatencySleepModeNV)vkGetDeviceProcAddr(rb_dev, "vkSetLatencySleepModeNV");
        rb_latency_sleep = (PFN_vkLatencySleepNV)vkGetDeviceProcAddr(rb_dev, "vkLatencySleepNV");
        rb_set_marker = (PFN_vkSetLatencyMarkerNV)vkGetDeviceProcAddr(rb_dev, "vkSetLatencyMarkerNV");
        VkSemaphoreTypeCreateInfo timeline = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO, .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE };
        vkCreateSemaphore(rb_dev, &(VkSemaphoreCreateInfo){ .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = &timeline }, NULL, &rb_sleep_sem);
    }
    return true;
}

void rb_set_reflex(int mode) {
    rb_reflex_mode = mode;
    if (!rb_reflex || !rb_chain) return;
    // Boost holds the GPU's clocks up; no minimum interval, so it never caps the frame rate.
    VkLatencySleepModeInfoNV info = { .sType = VK_STRUCTURE_TYPE_LATENCY_SLEEP_MODE_INFO_NV, .lowLatencyMode = mode != 0, .lowLatencyBoost = mode != 0 && mode != 1 };
    rb_set_sleep_mode(rb_dev, rb_chain, &info);
}

static void rb_drop_chain_objects(void) {
    for (uint32_t i = 0; i < rb_image_count; i++) {
        vkDestroyImageView(rb_dev, rb_views[i], NULL);
        vkDestroySemaphore(rb_dev, rb_rendered[i], NULL);
    }
    for (uint32_t i = 0; rb_image_count && i <= rb_image_count; i++) vkDestroySemaphore(rb_dev, rb_acquired[i], NULL);
    rb_image_count = 0;
}

static VkPresentModeKHR rb_supported_mode(VkPresentModeKHR want) {
    VkPresentModeKHR modes[16];
    uint32_t n = 16;
    vkGetPhysicalDeviceSurfacePresentModesKHR(rb_phys, rb_surface, &n, modes);
    for (uint32_t i = 0; i < n; i++)
        if (modes[i] == want) return want;
    return VK_PRESENT_MODE_FIFO_KHR; // Every driver has it.
}

static bool rb_make_chain(int w, int h) {
    vkDeviceWaitIdle(rb_dev);
    VkSurfaceCapabilitiesKHR caps;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(rb_phys, rb_surface, &caps);
    // Minimized: there is nothing to draw into until the window comes back.
    while (caps.currentExtent.width == 0 || caps.currentExtent.height == 0) {
        SDL_Delay(10);
        SDL_PumpEvents();
        vkGetPhysicalDeviceSurfaceCapabilitiesKHR(rb_phys, rb_surface, &caps);
    }
    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) {
        extent.width = SDL_clamp((uint32_t)w, caps.minImageExtent.width, caps.maxImageExtent.width);
        extent.height = SDL_clamp((uint32_t)h, caps.minImageExtent.height, caps.maxImageExtent.height);
    }
    uint32_t count = caps.minImageCount + 1;
    if (count > RB_MAX_IMAGES) count = RB_MAX_IMAGES;
    if (caps.maxImageCount && count > caps.maxImageCount) count = caps.maxImageCount;
    VkSwapchainLatencyCreateInfoNV latency = { .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_LATENCY_CREATE_INFO_NV, .latencyModeEnable = VK_TRUE };
    VkSwapchainKHR old = rb_chain;
    VkSwapchainCreateInfoKHR info = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .pNext = rb_reflex ? &latency : NULL,
        .surface = rb_surface,
        .minImageCount = count,
        .imageFormat = VK_FORMAT_B8G8R8A8_UNORM,
        .imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = rb_mode,
        .clipped = VK_TRUE,
        .oldSwapchain = old,
    };
    VkResult res = vkCreateSwapchainKHR(rb_dev, &info, NULL, &rb_chain);
    rb_drop_chain_objects();
    if (old) vkDestroySwapchainKHR(rb_dev, old, NULL);
    if (res != VK_SUCCESS) {
        rb_chain = VK_NULL_HANDLE;
        return false;
    }
    rb_extent = extent;
    rb_image_count = RB_MAX_IMAGES;
    if (vkGetSwapchainImagesKHR(rb_dev, rb_chain, &rb_image_count, rb_images) < 0) return false;
    VkSemaphoreCreateInfo sem = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    for (uint32_t i = 0; i < rb_image_count; i++) {
        VkImageViewCreateInfo view = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = rb_images[i],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        };
        vkCreateImageView(rb_dev, &view, NULL, &rb_views[i]);
        vkCreateSemaphore(rb_dev, &sem, NULL, &rb_rendered[i]);
    }
    // One spare: the next acquire needs a free semaphore while every image's may still be in use.
    for (uint32_t i = 0; i <= rb_image_count; i++) vkCreateSemaphore(rb_dev, &sem, NULL, &rb_acquired[i]);
    rb_acquire_next = 0;
    rb_stale = false;
    rb_set_reflex(rb_reflex_mode);
    return true;
}

bool rb_setup(SDL_Window *win) {
    rb_win = win;
    Uint32 ext_count = 0;
    const char *const *exts = SDL_Vulkan_GetInstanceExtensions(&ext_count);
    if (!exts) return false;
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "actuon", .apiVersion = VK_API_VERSION_1_3 };
    const char *inst_exts[16];
    if (ext_count > 15) return false;
    SDL_memcpy(inst_exts, exts, ext_count * sizeof *exts);
#ifndef NDEBUG
    // sokol names its objects in debug builds and panics without this.
    inst_exts[ext_count++] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
#endif
    VkInstanceCreateInfo inst = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app, .enabledExtensionCount = ext_count, .ppEnabledExtensionNames = inst_exts };
    if (vkCreateInstance(&inst, NULL, &rb_inst) != VK_SUCCESS) return false;
    if (!SDL_Vulkan_CreateSurface(win, rb_inst, NULL, &rb_surface)) return false;
    if (!rb_pick_device() || !rb_make_device()) return false;
    int w = 1, h = 1;
    SDL_GetWindowSizeInPixels(win, &w, &h);
    if (!rb_make_chain(w, h)) return false;
    rb_sg_setup((sg_environment){
        .defaults = { .color_format = SG_PIXELFORMAT_BGRA8, .depth_format = SG_PIXELFORMAT_NONE, .sample_count = 1 },
        .vulkan = { .instance = rb_inst, .physical_device = rb_phys, .device = rb_dev, .queue = rb_queue, .queue_family_index = rb_family },
    });
    return sg_isvalid();
}

void rb_shutdown(void) {
    vkDeviceWaitIdle(rb_dev);
    sg_shutdown();
    rb_drop_chain_objects();
    vkDestroySwapchainKHR(rb_dev, rb_chain, NULL);
    if (rb_sleep_sem) vkDestroySemaphore(rb_dev, rb_sleep_sem, NULL);
    vkDestroyDevice(rb_dev, NULL);
    SDL_Vulkan_DestroySurface(rb_inst, rb_surface, NULL);
    vkDestroyInstance(rb_inst, NULL);
}

void rb_set_vsync(int mode) {
    VkPresentModeKHR want = mode == 1 ? VK_PRESENT_MODE_FIFO_KHR : mode == 0 ? VK_PRESENT_MODE_IMMEDIATE_KHR : VK_PRESENT_MODE_FIFO_RELAXED_KHR;
    want = rb_supported_mode(want);
    if (want != rb_mode) rb_stale = true;
    rb_mode = want;
}

void rb_wait_frame(void) {
    if (!rb_reflex || !rb_reflex_mode) return;
    rb_sleep_value++;
    VkLatencySleepInfoNV sleep = { .sType = VK_STRUCTURE_TYPE_LATENCY_SLEEP_INFO_NV, .signalSemaphore = rb_sleep_sem, .value = rb_sleep_value };
    if (rb_latency_sleep(rb_dev, rb_chain, &sleep) == VK_SUCCESS) {
        VkSemaphoreWaitInfo wait = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO, .semaphoreCount = 1, .pSemaphores = &rb_sleep_sem, .pValues = &rb_sleep_value };
        vkWaitSemaphores(rb_dev, &wait, UINT64_MAX);
    }
    rb_marker(VK_LATENCY_MARKER_SIMULATION_START_NV);
}

sg_swapchain rb_swapchain(int w, int h) {
    rb_marker(VK_LATENCY_MARKER_SIMULATION_END_NV);
    rb_marker(VK_LATENCY_MARKER_RENDERSUBMIT_START_NV);
    for (;;) {
        if (rb_stale || !rb_chain || (uint32_t)w != rb_extent.width || (uint32_t)h != rb_extent.height) {
            if (!rb_make_chain(w, h)) SDL_Delay(10);
            // A surface can refuse the window's size: keep what it gave instead of rebuilding every frame.
            w = (int)rb_extent.width;
            h = (int)rb_extent.height;
            if (!rb_chain) continue;
        }
        VkResult res = vkAcquireNextImageKHR(rb_dev, rb_chain, UINT64_MAX, rb_acquired[rb_acquire_next], VK_NULL_HANDLE, &rb_image);
        if (res == VK_ERROR_OUT_OF_DATE_KHR) {
            rb_stale = true;
            continue;
        }
        if (res == VK_SUBOPTIMAL_KHR) rb_stale = true;
        break;
    }
    sg_swapchain out = {
        .width = (int)rb_extent.width,
        .height = (int)rb_extent.height,
        .sample_count = 1,
        .color_format = SG_PIXELFORMAT_BGRA8,
        .depth_format = SG_PIXELFORMAT_NONE,
        .vulkan = {
            .render_image = rb_images[rb_image],
            .render_view = rb_views[rb_image],
            .render_finished_semaphore = rb_rendered[rb_image],
            .present_complete_semaphore = rb_acquired[rb_acquire_next],
        },
    };
    rb_acquire_next = (rb_acquire_next + 1) % (rb_image_count + 1);
    return out;
}

void rb_present(void) {
    rb_marker(VK_LATENCY_MARKER_RENDERSUBMIT_END_NV);
    rb_marker(VK_LATENCY_MARKER_PRESENT_START_NV);
    VkPresentIdKHR id = { .sType = VK_STRUCTURE_TYPE_PRESENT_ID_KHR, .swapchainCount = 1, .pPresentIds = &rb_present_id };
    VkPresentInfoKHR info = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext = rb_reflex ? &id : NULL,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &rb_rendered[rb_image],
        .swapchainCount = 1,
        .pSwapchains = &rb_chain,
        .pImageIndices = &rb_image,
    };
    VkResult res = vkQueuePresentKHR(rb_queue, &info);
    if (res == VK_ERROR_OUT_OF_DATE_KHR || res == VK_SUBOPTIMAL_KHR) rb_stale = true;
    rb_marker(VK_LATENCY_MARKER_PRESENT_END_NV);
    rb_present_id++;
}

static uint32_t rb_host_memory(uint32_t bits) {
    VkPhysicalDeviceMemoryProperties mem;
    vkGetPhysicalDeviceMemoryProperties(rb_phys, &mem);
    VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    for (uint32_t i = 0; i < mem.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mem.memoryTypes[i].propertyFlags & want) == want) return i;
    return UINT32_MAX;
}

static void rb_shot_barrier(VkCommandBuffer cmd, VkImageLayout from, VkImageLayout to) {
    VkImageMemoryBarrier b = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_MEMORY_READ_BIT,
        .oldLayout = from,
        .newLayout = to,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = rb_images[rb_image],
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, NULL, 0, NULL, 1, &b);
}

// Presents as well: the acquired image has to go back before the next frame takes one.
bool rb_read_pixels(int w, int h, void *rgba) {
    bool ok = false;
    VkDeviceSize size = (VkDeviceSize)w * h * 4;
    VkBuffer buf = VK_NULL_HANDLE;
    VkDeviceMemory mem = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT };
    VkCommandPoolCreateInfo pi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = rb_family };
    if ((uint32_t)w == rb_extent.width && (uint32_t)h == rb_extent.height
        && vkCreateBuffer(rb_dev, &bi, NULL, &buf) == VK_SUCCESS
        && vkCreateCommandPool(rb_dev, &pi, NULL, &pool) == VK_SUCCESS) {
        VkMemoryRequirements req;
        vkGetBufferMemoryRequirements(rb_dev, buf, &req);
        VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = rb_host_memory(req.memoryTypeBits) };
        VkCommandBuffer cmd = VK_NULL_HANDLE;
        VkCommandBufferAllocateInfo ci = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
        if (ai.memoryTypeIndex != UINT32_MAX && vkAllocateMemory(rb_dev, &ai, NULL, &mem) == VK_SUCCESS
            && vkBindBufferMemory(rb_dev, buf, mem, 0) == VK_SUCCESS
            && vkAllocateCommandBuffers(rb_dev, &ci, &cmd) == VK_SUCCESS) {
            vkBeginCommandBuffer(cmd, &(VkCommandBufferBeginInfo){ .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT });
            rb_shot_barrier(cmd, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
            VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { (uint32_t)w, (uint32_t)h, 1 } };
            vkCmdCopyImageToBuffer(cmd, rb_images[rb_image], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &region);
            rb_shot_barrier(cmd, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
            vkEndCommandBuffer(cmd);
            VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            VkSubmitInfo submit = {
                .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
                .waitSemaphoreCount = 1,
                .pWaitSemaphores = &rb_rendered[rb_image],
                .pWaitDstStageMask = &stage,
                .commandBufferCount = 1,
                .pCommandBuffers = &cmd,
                .signalSemaphoreCount = 1,
                .pSignalSemaphores = &rb_rendered[rb_image],
            };
            vkQueueSubmit(rb_queue, 1, &submit, VK_NULL_HANDLE);
            vkQueueWaitIdle(rb_queue);
            Uint8 *mapped = NULL;
            if (vkMapMemory(rb_dev, mem, 0, size, 0, (void **)&mapped) == VK_SUCCESS) {
                Uint8 *out = rgba;
                for (VkDeviceSize i = 0; i < size; i += 4) {
                    out[i] = mapped[i + 2];
                    out[i + 1] = mapped[i + 1];
                    out[i + 2] = mapped[i];
                    out[i + 3] = mapped[i + 3];
                }
                vkUnmapMemory(rb_dev, mem);
                ok = true;
            }
        }
    }
    if (pool) vkDestroyCommandPool(rb_dev, pool, NULL);
    if (mem) vkFreeMemory(rb_dev, mem, NULL);
    if (buf) vkDestroyBuffer(rb_dev, buf, NULL);
    rb_present();
    return ok;
}
#endif
