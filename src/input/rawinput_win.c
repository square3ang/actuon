#define WIN32_LEAN_AND_MEAN
#include <windows.h>

void actuon_input_push_set1(unsigned int code, int down);

static unsigned int fold_extended(unsigned int make, int extended) {
    if (!extended) return make;
    switch (make) {
    case 0x1D: return 97;  // right ctrl
    case 0x38: return 100; // right alt
    case 0x48: return 103; // up
    case 0x4B: return 105; // left
    case 0x4D: return 106; // right
    case 0x50: return 108; // down
    case 0x52: return 110; // insert
    case 0x53: return 111; // delete
    case 0x47: return 102; // home
    case 0x4F: return 107; // end
    case 0x49: return 104; // page up
    case 0x51: return 109; // page down
    case 0x1C: return 96;  // keypad enter
    case 0x35: return 98;  // keypad /
    default: return 0;
    }
}

// Only raw input sees the E0 prefix, so keys whose virtual key is shared with a twin are sampled from here.
static volatile LONG held[4];

void actuon_rawinput_key(unsigned int make, unsigned int flags) {
    unsigned int code = fold_extended(make, (flags & RI_KEY_E0) != 0);
    if (code == 0 || code >= 128) return;
    int down = (flags & RI_KEY_BREAK) == 0;
    LONG bit = (LONG)(1u << (code % 32));
    if (down) InterlockedOr(&held[code / 32], bit);
    else InterlockedAnd(&held[code / 32], ~bit);
    actuon_input_push_set1(code, down);
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_INPUT) {
        RAWINPUT ri;
        UINT size = sizeof(ri);
        if (GetRawInputData((HRAWINPUT)lp, RID_INPUT, &ri, &size, sizeof(RAWINPUTHEADER)) != (UINT)-1 &&
            ri.header.dwType == RIM_TYPEKEYBOARD)
            actuon_rawinput_key(ri.data.keyboard.MakeCode, ri.data.keyboard.Flags);
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static DWORD WINAPI thread_main(LPVOID ready) {
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"actuon-rawinput";
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, wc.hInstance, NULL);
    RAWINPUTDEVICE rid = {0x01, 0x06, RIDEV_INPUTSINK, hwnd};
    *(volatile LONG *)ready = (hwnd != NULL && RegisterRawInputDevices(&rid, 1, sizeof(rid))) ? 1 : -1;
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) DispatchMessageW(&msg);
    return 0;
}

// 0 reads held: the keypad digits, Enter and the navigation cluster share virtual keys, and NumLock changes the keypad's.
static int code_vk[128];

static void build_code_vk(void) {
    for (unsigned int i = 1; i < 84; i++) code_vk[i] = (int)MapVirtualKeyW(i, MAPVK_VSC_TO_VK_EX);
    static const unsigned char twins[] = {28, 71, 72, 73, 75, 76, 77, 79, 80, 81, 82, 83};
    for (unsigned int i = 0; i < sizeof(twins); i++) code_vk[twins[i]] = 0;
    code_vk[97] = VK_RCONTROL;
    code_vk[98] = VK_DIVIDE;
    code_vk[100] = VK_RMENU;
}

void actuon_rawinput_sample(unsigned char *bits) {
    for (int i = 0; i < 128; i++) {
        int down = code_vk[i] != 0 ? (GetAsyncKeyState(code_vk[i]) & 0x8000) != 0 : (held[i / 32] >> (i % 32)) & 1;
        if (down) bits[i / 8] |= (unsigned char)(1 << (i % 8));
    }
}

// The sim thread sleeps on a high-resolution timer and wakes early when input.zig queues an event.
static HANDLE wake_event, wake_timer;
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

void actuon_input_wait_start(void) {
    wake_event = CreateEventW(NULL, FALSE, FALSE, NULL);
    wake_timer = CreateWaitableTimerExW(NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    // Before Windows 10 1803 there is no high-resolution timer; the ordinary one rounds to the system tick.
    if (wake_timer == NULL) wake_timer = CreateWaitableTimerExW(NULL, NULL, 0, TIMER_ALL_ACCESS);
}

void actuon_input_wake(void) {
    if (wake_event != NULL) SetEvent(wake_event);
}

void actuon_input_wait(unsigned long long ns) {
    LARGE_INTEGER due;
    due.QuadPart = -(LONGLONG)(ns / 100); // negative: relative, in 100 ns units
    if (wake_event == NULL || wake_timer == NULL || !SetWaitableTimer(wake_timer, &due, 0, NULL, NULL, FALSE)) {
        Sleep(0);
        return;
    }
    HANDLE both[2] = {wake_event, wake_timer};
    WaitForMultipleObjects(2, both, FALSE, INFINITE);
}

int actuon_rawinput_start(void) {
    static volatile LONG ready = 0;
    build_code_vk();
    HANDLE t = CreateThread(NULL, 0, thread_main, (LPVOID)&ready, 0, NULL);
    if (t == NULL) return 0;
    CloseHandle(t);
    while (ready == 0) Sleep(1);
    return ready == 1;
}
