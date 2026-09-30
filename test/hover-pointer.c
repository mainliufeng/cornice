// Real Wayland pointer events for the private compositor's hover regression.
// Usage: hover-pointer X Y WIDTH HEIGHT
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>
#include "virtual-pointer.h"

static struct zwlr_virtual_pointer_manager_v1 *manager;

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
  (void)data;
  (void)version;
  if (!strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name))
    manager = wl_registry_bind(registry, name,
                               &zwlr_virtual_pointer_manager_v1_interface, 1);
}

static void removed(void *data, struct wl_registry *registry, uint32_t name) {
  (void)data; (void)registry; (void)name;
}

int main(int argc, char **argv) {
  if (argc != 5) return 2;
  struct wl_display *display = wl_display_connect(NULL);
  if (!display) return 1;
  struct wl_registry *registry = wl_display_get_registry(display);
  const struct wl_registry_listener listener = {global, removed};
  wl_registry_add_listener(registry, &listener, NULL);
  wl_display_roundtrip(display);
  if (!manager) { fprintf(stderr, "virtual pointer protocol unavailable\n"); return 1; }
  struct zwlr_virtual_pointer_v1 *pointer =
    zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, NULL);
  wl_display_roundtrip(display);
  uint32_t x = atoi(argv[1]), y = atoi(argv[2]);
  uint32_t width = atoi(argv[3]), height = atoi(argv[4]);
  zwlr_virtual_pointer_v1_motion_absolute(pointer, 1, x, y, width, height);
  zwlr_virtual_pointer_v1_frame(pointer);
  wl_display_roundtrip(display);
  puts("hovering"); fflush(stdout);
  usleep(2000000);
  zwlr_virtual_pointer_v1_motion_absolute(pointer, 2001, x + 16, y, width, height);
  zwlr_virtual_pointer_v1_frame(pointer);
  wl_display_roundtrip(display);
  usleep(2000000);
  zwlr_virtual_pointer_v1_destroy(pointer);
  zwlr_virtual_pointer_manager_v1_destroy(manager);
  wl_display_roundtrip(display);
  wl_display_disconnect(display);
  return 0;
}
