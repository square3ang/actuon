// Without Input Monitoring permission this returns 0 and SDL keys stay in charge.
#include <IOKit/hid/IOHIDManager.h>
#include <pthread.h>

void actuon_input_push_hid(unsigned int usage, int down);

static void on_value(void *ctx, IOReturn res, void *sender, IOHIDValueRef value) {
    (void)ctx; (void)res; (void)sender;
    IOHIDElementRef el = IOHIDValueGetElement(value);
    if (IOHIDElementGetUsagePage(el) != kHIDPage_KeyboardOrKeypad) return;
    uint32_t usage = IOHIDElementGetUsage(el);
    if (usage < 4 || usage > 231) return;
    actuon_input_push_hid(usage, IOHIDValueGetIntegerValue(value) != 0);
}

static volatile int status = 0;

static void *thread_main(void *arg) {
    (void)arg;
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int page = kHIDPage_GenericDesktop, usage = kHIDUsage_GD_Keyboard;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR(kIOHIDDeviceUsagePageKey), CFSTR(kIOHIDDeviceUsageKey)};
    const void *vals[] = {p, u};
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(mgr, match);
    IOHIDManagerRegisterInputValueCallback(mgr, on_value, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    status = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone) == kIOReturnSuccess ? 1 : -1;
    if (status == 1) CFRunLoopRun();
    return NULL;
}

int actuon_hid_start(void) {
    pthread_t t;
    if (pthread_create(&t, NULL, thread_main, NULL) != 0) return 0;
    pthread_detach(t);
    while (status == 0) {
        struct timespec ts = {0, 1000000};
        nanosleep(&ts, NULL);
    }
    return status == 1;
}
