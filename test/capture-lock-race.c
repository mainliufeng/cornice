#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include "screencopy.h"
#include "session-lock.h"

static struct wl_shm *shm;
static struct wl_compositor *compositor;
static struct wl_surface *lock_surface;
static struct wl_output *human;
static struct zwlr_screencopy_manager_v1 *screenshots;
static struct ext_session_lock_manager_v1 *locks;
static uint32_t format, width, height, stride;
static unsigned char *pixels;
static size_t bytes;
static int result = -1;

static void output_name(void *data, struct wl_output *output, const char *name) {
    if (!strcmp(name, "human")) human = output;
}
static void geometry(void *d, struct wl_output *o, int32_t x, int32_t y, int32_t pw,
                     int32_t ph, int32_t subpixel, const char *make, const char *model, int32_t transform) {}
static void mode(void *d, struct wl_output *o, uint32_t f, int32_t w, int32_t h, int32_t rate) {}
static void output_done(void *d, struct wl_output *o) {}
static void scale(void *d, struct wl_output *o, int32_t factor) {}
static void description(void *d, struct wl_output *o, const char *text) {}
static const struct wl_output_listener output_events = {geometry, mode, output_done, scale, output_name, description};
static void global(void *d, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    if (!strcmp(interface, "wl_shm")) shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    if (!strcmp(interface, "wl_compositor")) compositor = wl_registry_bind(registry, name, &wl_compositor_interface, 4);
    if (!strcmp(interface, "zwlr_screencopy_manager_v1"))
        screenshots = wl_registry_bind(registry, name, &zwlr_screencopy_manager_v1_interface, 3);
    if (!strcmp(interface, "ext_session_lock_manager_v1"))
        locks = wl_registry_bind(registry, name, &ext_session_lock_manager_v1_interface, 1);
    if (!strcmp(interface, "wl_output")) {
        struct wl_output *output = wl_registry_bind(registry, name, &wl_output_interface, version < 4 ? version : 4);
        wl_output_add_listener(output, &output_events, NULL);
    }
}
static void removed(void *d, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_events = {global, removed};
static void locked(void *d, struct ext_session_lock_v1 *lock) {}
static void finished(void *d, struct ext_session_lock_v1 *lock) {
    fputs("test lock was rejected\n", stderr);
    result = 3;
}
static const struct ext_session_lock_v1_listener lock_events = {locked, finished};
static void configure(void *d, struct ext_session_lock_surface_v1 *surface, uint32_t serial, uint32_t w, uint32_t h) {
    int fd = memfd_create("real-black-lock", MFD_CLOEXEC);
    size_t size = (size_t)w * h * 4;
    if (fd < 0 || ftruncate(fd, size) < 0) exit(4);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, WL_SHM_FORMAT_XRGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    ext_session_lock_surface_v1_ack_configure(surface, serial);
    wl_surface_attach(lock_surface, buffer, 0, 0);
    wl_surface_damage_buffer(lock_surface, 0, 0, w, h);
    wl_surface_commit(lock_surface);
}
static const struct ext_session_lock_surface_v1_listener surface_events = {configure};
static void buffer(void *d, struct zwlr_screencopy_frame_v1 *frame, uint32_t f, uint32_t w, uint32_t h, uint32_t s) {
    format = f; width = w; height = h; stride = s;
}
static void buffer_done(void *d, struct zwlr_screencopy_frame_v1 *frame) {
    bytes = (size_t)stride * height;
    int fd = memfd_create("pending-capture", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, bytes) < 0) exit(4);
    pixels = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) exit(4);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, bytes);
    struct wl_buffer *target = wl_shm_pool_create_buffer(pool, 0, width, height, stride, format);
    wl_shm_pool_destroy(pool);
    close(fd);
    // These requests are queued on the SAME connection in this order. The
    // server handles copy then lock before the next output commit can run.
    zwlr_screencopy_frame_v1_copy(frame, target);
    struct ext_session_lock_v1 *lock = ext_session_lock_manager_v1_lock(locks);
    ext_session_lock_v1_add_listener(lock, &lock_events, NULL);
    lock_surface = wl_compositor_create_surface(compositor);
    struct ext_session_lock_surface_v1 *surface = ext_session_lock_v1_get_lock_surface(lock, lock_surface, human);
    ext_session_lock_surface_v1_add_listener(surface, &surface_events, NULL);
    puts("copy and lock queued");
}
static void flags(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t flags) {}
static void ready(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t hi, uint32_t lo, uint32_t ns) {
    fputs("invalidated capture unexpectedly returned pixels\n", stderr);
    result = 5;
}
static void failed(void *d, struct zwlr_screencopy_frame_v1 *f) {
    if (!pixels) { result = 6; return; }
    for (size_t i = 0; i < bytes; ++i) {
        if (pixels[i]) { result = 7; return; }
    }
    puts("failed received; destination untouched");
    result = 0;
}
static void damage(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {}
static void dmabuf(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t format, uint32_t w, uint32_t h) {}
static const struct zwlr_screencopy_frame_v1_listener frame_events = {buffer, flags, ready, failed, damage, dmabuf, buffer_done};

int main(void) {
    setbuf(stdout, NULL);
    const char *sandbox = getenv("CORNICE_TEST_SANDBOX");
    if (!sandbox || strcmp(sandbox, "1")) return 9;
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_events, NULL);
    if (wl_display_roundtrip(display) < 0 || wl_display_roundtrip(display) < 0) return 1;
    if (!shm || !compositor || !human || !screenshots || !locks) return 2;
    struct zwlr_screencopy_frame_v1 *frame = zwlr_screencopy_manager_v1_capture_output(screenshots, 0, human);
    zwlr_screencopy_frame_v1_add_listener(frame, &frame_events, NULL);
    while (result < 0 && wl_display_dispatch(display) >= 0) {}
    wl_display_disconnect(display);
    if (pixels) munmap(pixels, bytes);
    return result < 0 ? 8 : result;
}
