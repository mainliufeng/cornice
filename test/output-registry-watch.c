#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

static void output_name(void *data, struct wl_output *output, const char *name) {
    printf("output=%s\n", name);
}
static void geometry(void *data, struct wl_output *output, int32_t x, int32_t y,
                     int32_t pw, int32_t ph, int32_t subpixel, const char *make,
                     const char *model, int32_t transform) {}
static void mode(void *data, struct wl_output *output, uint32_t flags, int32_t w, int32_t h, int32_t rate) {}
static void done(void *data, struct wl_output *output) {}
static void scale(void *data, struct wl_output *output, int32_t factor) {}
static void description(void *data, struct wl_output *output, const char *text) {}
static const struct wl_output_listener outputs = {geometry, mode, done, scale, output_name, description};
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    if (strcmp(interface, "wl_output")) return;
    struct wl_output *output = wl_registry_bind(registry, name, &wl_output_interface, version < 4 ? version : 4);
    wl_output_add_listener(output, &outputs, NULL);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener registry_events = {global, removed};
int main(void) {
    setbuf(stdout, NULL);
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 1;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_events, NULL);
    char command[32];
    do {
        if (wl_display_roundtrip(display) < 0 || wl_display_roundtrip(display) < 0) {
            fprintf(stderr, "output registry protocol failure\n");
            return 2;
        }
        puts("ready");
    } while (fgets(command, sizeof(command), stdin));
    wl_display_disconnect(display);
    return 0;
}
