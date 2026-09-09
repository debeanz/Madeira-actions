#import <TargetConditionals.h>

#if TARGET_OS_SIMULATOR

#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import "JITAllocator.h"
#import "FEXBridge.h"

#include <stdint.h>
#include <stdlib.h>

struct JITRegion { size_t size; };

volatile int ws_log_quiet = 0;

static void (*ui_log_callback)(const char *) = NULL;
static void (*jit_log_callback)(const char *) = NULL;
static void (*fex_log_callback)(const char *) = NULL;

static void simulator_log(const char *message) {
    if (ui_log_callback) ui_log_callback(message);
}

#ifdef MADEIRA_SIMULATOR_REAL_RUNTIME
/*
 * Wine's firmware probe uses IOKit on physical iOS. IOKit is not part of the
 * iOS Simulator SDK, and none of this information is needed by the Windows
 * ARM64 test application. Keep the symbols local to the simulator build and
 * report that no matching registry service/property exists.
 */
typedef uint32_t madeira_io_object_t;
typedef uint32_t madeira_io_service_t;
typedef uint32_t madeira_mach_port_t;
typedef uint32_t madeira_io_option_bits_t;
typedef int madeira_kern_return_t;

madeira_kern_return_t IOObjectRelease(madeira_io_object_t object) {
    (void)object;
    return 0;
}

CFTypeRef IORegistryEntryCreateCFProperty(madeira_io_object_t entry,
                                          CFStringRef key,
                                          CFAllocatorRef allocator,
                                          madeira_io_option_bits_t options) {
    (void)entry;
    (void)key;
    (void)allocator;
    (void)options;
    return NULL;
}

madeira_io_service_t IOServiceGetMatchingService(madeira_mach_port_t main_port,
                                                  CFDictionaryRef matching) {
    (void)main_port;
    if (matching) CFRelease(matching);
    return 0;
}

CFMutableDictionaryRef IOServiceMatching(const char *name) {
    (void)name;
    return NULL;
}
#endif

bool fex_initialize(void) { simulator_log("[simulator] FEX runtime is device-only"); return false; }
void fex_shutdown(void) {}
int64_t fex_test_execute(void) { simulator_log("[simulator] FEX execution is unavailable"); return -2; }
void fex_set_log_callback(void (*callback)(const char *)) { fex_log_callback = callback; (void)fex_log_callback; }
int64_t fex_get_jit_write_offset(void) { return 0; }

#ifndef MADEIRA_SIMULATOR_REAL_RUNTIME
int wineserver_start(const char *prefix_path) { (void)prefix_path; simulator_log("[simulator] Wine runtime is unavailable"); return -1; }
int wineserver_is_running(void) { return 0; }
void wineserver_stop(void) {}
void wineserver_inject_client_fd(int fd) { (void)fd; }
int wine_process_start(const char *prefix_path) { (void)prefix_path; return -1; }
int wine_process_is_running(void) { return 0; }
int madeira_write_continue_flag(void) { return -1; }

void wine_log_set_file(const char *path) { (void)path; }
void wine_set_ui_log_callback(void (*callback)(const char *)) {
    ui_log_callback = callback;
}
uint64_t madeira_get_present_count(void) { return 0; }
void madeira_set_vsync_locked(int locked) { (void)locked; }
int madeira_get_vsync_locked(void) { return 1; }
void winios_phase(const char *name) { (void)name; }
#endif

JITRegion *jit_region_create(size_t size) { (void)size; return NULL; }
void jit_region_destroy(JITRegion *region) { (void)region; }
bool jit_make_region_no_footprint(void *addr, size_t size, const char *label) { (void)addr; (void)size; (void)label; return false; }
void *jit_region_rw_ptr(JITRegion *region) { (void)region; return NULL; }
void *jit_region_rx_ptr(JITRegion *region) { (void)region; return NULL; }
size_t jit_region_size(JITRegion *region) { (void)region; return 0; }
void *jit_region_write(JITRegion *region, size_t offset, const void *code, size_t code_size) { (void)region; (void)offset; (void)code; (void)code_size; return NULL; }
void jit_region_invalidate(JITRegion *region, size_t offset, size_t size) { (void)region; (void)offset; (void)size; }
bool jit_check_debugged(void) { return false; }
void jit_install_trap_handler(void) {}
void *jit26_prepare_region(void *addr, size_t len) { (void)len; return addr; }
void jit26_detach(void) {}
bool jit_test_mapping(void) { return false; }
int64_t jit_test_execute(void) { return -2; }
int64_t jit_test_execute_strategy2(void) { return -2; }
void jit_wx_probe(void) {}
void jit_set_log_callback(void (*callback)(const char *)) { jit_log_callback = callback; (void)jit_log_callback; }

#ifndef MADEIRA_SIMULATOR_REAL_RUNTIME
void madeira_display_set_layer(CAMetalLayer *layer) { (void)layer; }
void winios_drv_register(void) {}
void winios_post_touch_down(int x, int y) { (void)x; (void)y; }
void winios_post_touch_move(int x, int y) { (void)x; (void)y; }
void winios_post_touch_up(int x, int y) { (void)x; (void)y; }
void winios_post_key(int vk, int down) { (void)vk; (void)down; }
void winios_set_compositor_frame(double x, double y, double w, double h) { (void)x; (void)y; (void)w; (void)h; }
void winios_pointer(int x, int y, unsigned int flags, unsigned int data) { (void)x; (void)y; (void)flags; (void)data; }
void winios_cursor_move(int x, int y) { (void)x; (void)y; }
void madeira_set_diag_enabled(int on) { (void)on; }
int madeira_get_diag_enabled(void) { return 0; }
#endif

#endif
