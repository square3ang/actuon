// Windows RawInput on a dedicated high-priority thread, so key timing does not wait for the
// render loop. Keys arrive with Linux-style codes; the mapping table lives in input.zig.
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

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_INPUT) {
        RAWINPUT ri;
        UINT size = sizeof(ri);
        if (GetRawInputData((HRAWINPUT)lp, RID_INPUT, &ri, &size, sizeof(RAWINPUTHEADER)) != (UINT)-1 &&
            ri.header.dwType == RIM_TYPEKEYBOARD) {
            const RAWKEYBOARD *k = &ri.data.keyboard;
            unsigned int code = fold_extended(k->MakeCode, (k->Flags & RI_KEY_E0) != 0);
            if (code != 0) actuon_input_push_set1(code, (k->Flags & RI_KEY_BREAK) == 0);
        }
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

// Virtual keys by Linux-style code, the inverse of fold_extended.
// shortcut: keypad keys share virtual keys with the navigation cluster, split them when a binding needs both.
static int code_vk[128];

static void build_code_vk(void) {
    for (unsigned int i = 1; i < 84; i++) code_vk[i] = (int)MapVirtualKeyW(i, MAPVK_VSC_TO_VK_EX);
    code_vk[96] = VK_RETURN;
    code_vk[97] = VK_RCONTROL;
    code_vk[98] = VK_DIVIDE;
    code_vk[100] = VK_RMENU;
    code_vk[102] = VK_HOME;
    code_vk[103] = VK_UP;
    code_vk[104] = VK_PRIOR;
    code_vk[105] = VK_LEFT;
    code_vk[106] = VK_RIGHT;
    code_vk[107] = VK_END;
    code_vk[108] = VK_DOWN;
    code_vk[109] = VK_NEXT;
    code_vk[110] = VK_INSERT;
    code_vk[111] = VK_DELETE;
}

void actuon_rawinput_sample(unsigned char *bits) {
    for (int i = 0; i < 128; i++) {
        if (code_vk[i] != 0 && (GetAsyncKeyState(code_vk[i]) & 0x8000)) bits[i / 8] |= (unsigned char)(1 << (i % 8));
    }
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
