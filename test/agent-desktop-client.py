"""Real GTK client: input effects and widget geometry are recorded for QA."""
import json
import pathlib
import sys
import time
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib

name, destination = sys.argv[1:]
path = pathlib.Path(destination)
window = Gtk.Window(title=name)
window.set_default_size(600, 400)
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24, margin=24)
entry = Gtk.Entry()
entry.connect("changed", lambda widget: path.write_text(widget.get_text()))
button = Gtk.Button(label="Record a click")
clicks = 0
def click(widget):
    global clicks
    clicks += 1
    path.with_suffix(".click").write_text(str(clicks))
button.connect("clicked", click)
box.pack_start(Gtk.Label(label=name), False, False, 0)
box.pack_start(entry, False, False, 0)
box.pack_start(button, False, False, 0)
clock = Gtk.DrawingArea()
clock.set_size_request(320, 12)
def draw_clock(widget, context):
    stamp = int(time.monotonic() * 1000) & 0xffffffff
    for bit in range(32):
        context.set_source_rgb(0, 1, 0) if stamp & (1 << bit) else context.set_source_rgb(1, 0, 0)
        context.rectangle(bit * 10, 0, 10, 12)
        context.fill()
clock.connect("draw", draw_clock)
box.pack_start(clock, False, False, 0)
GLib.timeout_add(20, lambda: (clock.queue_draw(), True)[1])
window.add(box)
window.connect("destroy", Gtk.main_quit)
window.show_all()
entry.grab_focus()

def geometry():
    bounds = {}
    for key, widget in (("entry", entry), ("button", button)):
        x, y = widget.translate_coordinates(window, 0, 0)
        bounds[key] = [x, y, widget.get_allocated_width(), widget.get_allocated_height()]
    bounds["selection"] = list(entry.get_selection_bounds())
    path.with_suffix(".geometry").write_text(json.dumps(bounds))
    return True

GLib.timeout_add(100, geometry)
Gtk.main()
