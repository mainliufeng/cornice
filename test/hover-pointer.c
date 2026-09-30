// Real Wayland pointer events for the private compositor's hover regression.
// Usage: hover-pointer X Y WIDTH HEIGHT [click|hover|scroll|interactive]
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
  if (argc != 5 && argc != 6) return 2;
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
  // Keep one pointer alive across popup interactions, like a physical mouse.
  // Removing and recreating the seat's device can clear a compositor focus grab.
  if (argc == 6 && !strcmp(argv[5], "interactive")) {
    char line[128], action[32];
    uint32_t stamp = 1;
    while (fgets(line, sizeof(line), stdin)) {
      if (sscanf(line, "%u %u %31s", &x, &y, action) != 3) return 2;
      zwlr_virtual_pointer_v1_motion_absolute(pointer, stamp++, x, y, width, height);
      zwlr_virtual_pointer_v1_frame(pointer);
      wl_display_roundtrip(display);
      usleep(100000);
      if (!strcmp(action, "click")) {
        zwlr_virtual_pointer_v1_button(pointer, stamp++, 0x110, WL_POINTER_BUTTON_STATE_PRESSED);
        zwlr_virtual_pointer_v1_frame(pointer);
        wl_display_roundtrip(display);
        usleep(30000);
        zwlr_virtual_pointer_v1_button(pointer, stamp++, 0x110, WL_POINTER_BUTTON_STATE_RELEASED);
      } else if (!strcmp(action, "scroll")) {
        zwlr_virtual_pointer_v1_axis(pointer, stamp++, WL_POINTER_AXIS_VERTICAL_SCROLL,
                                     wl_fixed_from_int(400));
      } else if (strcmp(action, "hover")) return 2;
      zwlr_virtual_pointer_v1_frame(pointer);
      wl_display_roundtrip(display);
      puts("done"); fflush(stdout);
    }
    zwlr_virtual_pointer_v1_destroy(pointer);
    zwlr_virtual_pointer_manager_v1_destroy(manager);
    wl_display_roundtrip(display);
    wl_display_disconnect(display);
    return 0;
  }
  zwlr_virtual_pointer_v1_motion_absolute(pointer, 1, x, y, width, height);
  zwlr_virtual_pointer_v1_frame(pointer);
  wl_display_roundtrip(display);
  puts("hovering"); fflush(stdout);
  if (argc == 6) {
    usleep(100000);
    if (!strcmp(argv[5], "click")) {
      zwlr_virtual_pointer_v1_button(pointer, 101, 0x110, WL_POINTER_BUTTON_STATE_PRESSED);
      zwlr_virtual_pointer_v1_frame(pointer);
      wl_display_roundtrip(display);
      usleep(30000);
      zwlr_virtual_pointer_v1_button(pointer, 131, 0x110, WL_POINTER_BUTTON_STATE_RELEASED);
      zwlr_virtual_pointer_v1_frame(pointer);
      wl_display_roundtrip(display);
    } else if (!strcmp(argv[5], "scroll")) {
      zwlr_virtual_pointer_v1_axis(pointer, 101, WL_POINTER_AXIS_VERTICAL_SCROLL,
                                   wl_fixed_from_int(400));
      zwlr_virtual_pointer_v1_frame(pointer);
      wl_display_roundtrip(display);
    } else if (strcmp(argv[5], "hover")) return 2;
    usleep(600000);
  } else {
    usleep(2000000);
    zwlr_virtual_pointer_v1_motion_absolute(pointer, 2001, x + 16, y, width, height);
    zwlr_virtual_pointer_v1_frame(pointer);
    wl_display_roundtrip(display);
    usleep(2000000);
  }
  zwlr_virtual_pointer_v1_destroy(pointer);
  zwlr_virtual_pointer_manager_v1_destroy(manager);
  wl_display_roundtrip(display);
  wl_display_disconnect(display);
  return 0;
}
