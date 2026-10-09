#define _GNU_SOURCE
#include "fifo.h"
#include "presentation.h"
#include "xdg.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
static struct wl_display *display;
static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wp_presentation *presentation;
static struct wp_fifo_manager_v1 *fifo_manager;
static struct wp_fifo_v1 *fifo;
static struct wl_surface *surface;
static void submit(void);
static int frame_ready, presentation_ready;
static void next_frame(void);
struct feedback {
  uint64_t started, input;
  const char *kind;
  char output[128];
};
static struct wl_seat *seat;
static uint64_t pending_input;
static const char *pending_kind = "";
static int width = 320, height = 240, started = 0, submitted = 0, finished = 0,
           limit = 100;
static uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static void sync_output(void *d, struct wp_presentation_feedback *f,
                        struct wl_output *o) {
  struct feedback *data = d;
  const char *name = wl_output_get_user_data(o);
  if (name)
    snprintf(data->output, sizeof(data->output), "%s", name);
}
static void presented(void *d, struct wp_presentation_feedback *f, uint32_t hi,
                      uint32_t lo, uint32_t ns, uint32_t refresh, uint32_t shi,
                      uint32_t slo, uint32_t flags) {
  struct feedback *data = d;
  printf("{\"output\":\"%s\",\"refreshNs\":%u,\"feedbackMs\":%.3f,\"timeNs\":%"
         "llu,\"inputKind\":\"%s\",\"inputMs\":%.3f}\n",
         data->output, refresh, (now_ns() - data->started) / 1e6,
         (unsigned long long)now_ns(), data->kind,
         data->input ? (now_ns() - data->input) / 1e6 : 0);
  wp_presentation_feedback_destroy(f);
  free(data);
  finished++;
  presentation_ready = 1;
  next_frame();
}
static void discarded(void *d, struct wp_presentation_feedback *f) {
  wp_presentation_feedback_destroy(f);
  free(d);
  finished++;
  presentation_ready = 1;
  next_frame();
}
static const struct wp_presentation_feedback_listener feedback_events = {
    sync_output, presented, discarded};
static void release(void *d, struct wl_buffer *b) { wl_buffer_destroy(b); }
static const struct wl_buffer_listener buffer_events = {release};
static void submit(void);
static void frame_done(void *d, struct wl_callback *cb, uint32_t t) {
  wl_callback_destroy(cb);
  frame_ready = 1;
  next_frame();
}
static const struct wl_callback_listener frame_events = {frame_done};
static void next_frame(void) {
  if (frame_ready && presentation_ready && submitted < limit) {
    frame_ready = presentation_ready = 0;
    submit();
  }
}
static void submit(void) {
  int fd = memfd_create("presentation-probe", MFD_CLOEXEC);
  size_t bytes = (size_t)width * height * 4;
  if (fd < 0 || ftruncate(fd, bytes))
    exit(3);
  uint32_t *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  for (size_t i = 0; i < bytes / 4; i++)
    p[i] = submitted % 2 ? 0xff0066cc : 0xffcc6600;
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, bytes);
  struct wl_buffer *buffer = wl_shm_pool_create_buffer(
      pool, 0, width, height, width * 4, WL_SHM_FORMAT_XRGB8888);
  wl_buffer_add_listener(buffer, &buffer_events, NULL);
  wl_shm_pool_destroy(pool);
  munmap(p, bytes);
  close(fd);
  wl_callback_add_listener(wl_surface_frame(surface), &frame_events, NULL);
  struct feedback *feedback = calloc(1, sizeof(*feedback));
  feedback->started = now_ns();
  feedback->input = pending_input;
  feedback->kind = pending_kind;
  pending_input = 0;
  pending_kind = "";
  wp_presentation_feedback_add_listener(
      wp_presentation_feedback(presentation, surface), &feedback_events,
      feedback);
  if (fifo) {
    if (submitted)
      wp_fifo_v1_wait_barrier(fifo);
    wp_fifo_v1_set_barrier(fifo);
  }
  wl_surface_attach(surface, buffer, 0, 0);
  wl_surface_damage_buffer(surface, 0, 0, width, height);
  wl_surface_commit(surface);
  submitted++;
}
static void ping(void *d, struct xdg_wm_base *w, uint32_t serial) {
  xdg_wm_base_pong(w, serial);
}
static const struct xdg_wm_base_listener wm_events = {ping};
static void configured(void *d, struct xdg_surface *s, uint32_t serial) {
  xdg_surface_ack_configure(s, serial);
  if (!started) {
    started = 1;
    submit();
  }
}
static const struct xdg_surface_listener surface_events = {configured};
static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h,
                          struct wl_array *a) {
  if (w > 0)
    width = w;
  if (h > 0)
    height = h;
}
static void top_close(void *d, struct xdg_toplevel *t) { exit(4); }
static void bounds(void *d, struct xdg_toplevel *t, int32_t w, int32_t h) {}
static void capabilities(void *d, struct xdg_toplevel *t, struct wl_array *a) {}
static const struct xdg_toplevel_listener top_events = {
    top_configure, top_close, bounds, capabilities};
static void keymap(void *d, struct wl_keyboard *k, uint32_t fmt, int32_t fd,
                   uint32_t size) {
  close(fd);
}
static void keyboard_enter(void *d, struct wl_keyboard *k, uint32_t serial,
                           struct wl_surface *s, struct wl_array *keys) {}
static void keyboard_leave(void *d, struct wl_keyboard *k, uint32_t serial,
                           struct wl_surface *s) {}
static void key(void *d, struct wl_keyboard *k, uint32_t serial, uint32_t time,
                uint32_t code, uint32_t state) {
  if (state) {
    pending_input = now_ns();
    pending_kind = "key";
  }
}
static void modifiers(void *d, struct wl_keyboard *k, uint32_t serial,
                      uint32_t depressed, uint32_t latched, uint32_t locked,
                      uint32_t group) {}
static void repeat(void *d, struct wl_keyboard *k, int32_t rate,
                   int32_t delay) {}
static const struct wl_keyboard_listener keyboard_events = {
    keymap, keyboard_enter, keyboard_leave, key, modifiers, repeat};
static void pointer_enter(void *d, struct wl_pointer *p, uint32_t serial,
                          struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {}
static void pointer_leave(void *d, struct wl_pointer *p, uint32_t serial,
                          struct wl_surface *s) {}
static void motion(void *d, struct wl_pointer *p, uint32_t time, wl_fixed_t x,
                   wl_fixed_t y) {
  pending_input = now_ns();
  pending_kind = "pointer";
}
static void button(void *d, struct wl_pointer *p, uint32_t serial,
                   uint32_t time, uint32_t button, uint32_t state) {}
static void axis(void *d, struct wl_pointer *p, uint32_t time, uint32_t axis,
                 wl_fixed_t value) {}
static void pointer_frame(void *d, struct wl_pointer *p) {}
static void axis_source(void *d, struct wl_pointer *p, uint32_t source) {}
static void axis_stop(void *d, struct wl_pointer *p, uint32_t time,
                      uint32_t axis) {}
static void axis_discrete(void *d, struct wl_pointer *p, uint32_t axis,
                          int32_t steps) {}
static const struct wl_pointer_listener pointer_events = {
    pointer_enter, pointer_leave, motion,    button,       axis,
    pointer_frame, axis_source,   axis_stop, axis_discrete};
static void seat_caps(void *d, struct wl_seat *s, uint32_t caps) {
  if (caps & WL_SEAT_CAPABILITY_KEYBOARD)
    wl_keyboard_add_listener(wl_seat_get_keyboard(s), &keyboard_events, NULL);
  if (caps & WL_SEAT_CAPABILITY_POINTER)
    wl_pointer_add_listener(wl_seat_get_pointer(s), &pointer_events, NULL);
}
static void seat_name(void *d, struct wl_seat *s, const char *name) {}
static const struct wl_seat_listener seat_events = {seat_caps, seat_name};
static void output_geometry(void *d, struct wl_output *o, int32_t x, int32_t y,
                            int32_t w, int32_t h, int32_t s, const char *a,
                            const char *b, int32_t t) {}
static void output_mode(void *d, struct wl_output *o, uint32_t f, int32_t w,
                        int32_t h, int32_t r) {}
static void output_done(void *d, struct wl_output *o) {}
static void output_scale(void *d, struct wl_output *o, int32_t s) {}
static void output_name(void *d, struct wl_output *o, const char *name) {
  snprintf(d, 128, "%s", name);
}
static void output_description(void *d, struct wl_output *o, const char *name) {
}
static const struct wl_output_listener output_events = {
    output_geometry, output_mode, output_done,
    output_scale,    output_name, output_description};
static void global(void *d, struct wl_registry *r, uint32_t id,
                   const char *name, uint32_t ver) {
  if (!strcmp(name, "wl_seat") && !seat) {
    seat = wl_registry_bind(r, id, &wl_seat_interface, 5);
    wl_seat_add_listener(seat, &seat_events, NULL);
  }
  if (!strcmp(name, "wl_compositor"))
    compositor = wl_registry_bind(r, id, &wl_compositor_interface, 4);
  if (!strcmp(name, "wl_output")) {
    struct wl_output *o =
        wl_registry_bind(r, id, &wl_output_interface, ver < 4 ? ver : 4);
    wl_output_add_listener(o, &output_events, calloc(1, 128));
  }
  if (!strcmp(name, "wl_shm"))
    shm = wl_registry_bind(r, id, &wl_shm_interface, 1);
  if (!strcmp(name, "xdg_wm_base")) {
    wm = wl_registry_bind(r, id, &xdg_wm_base_interface, 1);
    xdg_wm_base_add_listener(wm, &wm_events, NULL);
  }
  if (!strcmp(name, "wp_presentation"))
    presentation = wl_registry_bind(r, id, &wp_presentation_interface, 1);
  if (!strcmp(name, "wp_fifo_manager_v1"))
    fifo_manager = wl_registry_bind(r, id, &wp_fifo_manager_v1_interface, 1);
}
static void removed(void *d, struct wl_registry *r, uint32_t id) {}
static const struct wl_registry_listener registry_events = {global, removed};
int main(int argc, char **argv) {
  if (argc > 1 && !strcmp(argv[1], "input"))
    limit = 600;
  setbuf(stdout, NULL);
  if (!getenv("CORNICE_TEST_SANDBOX"))
    return 9;
  display = wl_display_connect(NULL);
  if (!display)
    return 1;
  wl_registry_add_listener(wl_display_get_registry(display), &registry_events,
                           NULL);
  wl_display_roundtrip(display);
  wl_display_roundtrip(display);
  if (!wm || !shm || !compositor || !presentation)
    return 2;
  surface = wl_compositor_create_surface(compositor);
  if (argc > 1 && (!strcmp(argv[1], "fifo") || !strcmp(argv[1], "input"))) {
    if (!fifo_manager)
      return 5;
    fifo = wp_fifo_manager_v1_get_fifo(fifo_manager, surface);
  }
  struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
  xdg_surface_add_listener(xdg, &surface_events, NULL);
  struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
  xdg_toplevel_add_listener(top, &top_events, NULL);
  xdg_toplevel_set_title(top, "presentation-probe");
  xdg_toplevel_set_app_id(top, "presentation-probe");
  wl_surface_commit(surface);
  while (finished < limit && wl_display_dispatch(display) >= 0) {
  }
  wl_display_disconnect(display);
  return finished < limit ? 6 : 0;
}
