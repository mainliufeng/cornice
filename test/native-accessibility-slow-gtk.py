"""Real GTK accessibility client with an opt-in slow application main loop."""
import json
import pathlib
import sys
import time
import gi

gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib

flag, destination = map(pathlib.Path, sys.argv[1:])
window = Gtk.Window(title='slow-native-window')
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
entry = Gtk.Entry()
entry.connect('changed', lambda widget: destination.write_text(widget.get_text()))
box.pack_start(entry, False, False, 0)
clicks = 0

def record_click(widget):
    global clicks
    clicks += 1
    destination.with_suffix('.click').write_text(str(clicks))

button = Gtk.Button(label='Record slow click')
button.connect('clicked', record_click)
box.pack_start(button, False, False, 0)
for i in range(280):
    box.pack_start(Gtk.Button(label='Real native button ' + str(i)), False, False, 0)
scroll = Gtk.ScrolledWindow()
scroll.add(box)
window.add(scroll)
window.set_default_size(600, 400)
window.connect('destroy', Gtk.main_quit)
window.show_all()

def delay():
    if flag.exists():
        time.sleep(.065)
    return True

GLib.timeout_add(1, delay)
Gtk.main()
