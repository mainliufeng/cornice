#!/usr/bin/env python3
"""A fake MPRIS player, for verifying cornice's media widget without a real one.

It owns org.mpris.MediaPlayer2.cornice-test on the session bus, exposes the
properties a player would, and records every method call to a log file so a test
can prove that clicking the widget actually reached a player.

    test/fake-mpris-player.py --title "Some Song" --artist "Someone" &
    cat /tmp/fake-mpris-calls.log
"""
import argparse
import os
import sys
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

MPRIS_PATH = "/org/mpris/MediaPlayer2"
IFACE_ROOT = "org.mpris.MediaPlayer2"
IFACE_PLAYER = "org.mpris.MediaPlayer2.Player"

ROOT_XML = """
<node>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/>
    <method name="Quit"/>
    <property name="CanQuit" type="b" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
    <property name="HasTrackList" type="b" access="read"/>
    <property name="Identity" type="s" access="read"/>
    <property name="DesktopEntry" type="s" access="read"/>
    <property name="SupportedUriSchemes" type="as" access="read"/>
    <property name="SupportedMimeTypes" type="as" access="read"/>
  </interface>
</node>
"""

PLAYER_XML = """
<node>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="Next"/>
    <method name="Previous"/>
    <method name="Pause"/>
    <method name="PlayPause"/>
    <method name="Stop"/>
    <method name="Play"/>
    <method name="Seek"><arg direction="in" type="x" name="Offset"/></method>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="LoopStatus" type="s" access="readwrite"/>
    <property name="Rate" type="d" access="readwrite"/>
    <property name="Shuffle" type="b" access="readwrite"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="Volume" type="d" access="readwrite"/>
    <property name="Position" type="x" access="read"/>
    <property name="MinimumRate" type="d" access="read"/>
    <property name="MaximumRate" type="d" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanSeek" type="b" access="read"/>
    <property name="CanControl" type="b" access="read"/>
  </interface>
</node>
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--title", default="Fake Song")
    parser.add_argument("--artist", default="Fake Artist")
    parser.add_argument("--playing", action="store_true", default=True)
    parser.add_argument("--log", default="/tmp/fake-mpris-calls.log")
    parser.add_argument("--seconds", type=int, default=0, help="exit after N seconds (0 = run forever)")
    args = parser.parse_args()

    log = open(args.log, "a", encoding="utf-8")

    def record(what):
        log.write(f"{int(time.time())} {what}\n")
        log.flush()

    state = {"playing": args.playing}

    def metadata():
        return {
            "mpris:trackid": GLib.Variant("o", "/org/mpris/MediaPlayer2/Track/1"),
            "xesam:title": GLib.Variant("s", args.title),
            "xesam:artist": GLib.Variant("as", [args.artist]),
            "xesam:album": GLib.Variant("s", "Fake Album"),
            "mpris:length": GLib.Variant("x", 210 * 1000000),
        }

    def properties(iface):
        if iface == IFACE_ROOT:
            return {
                "CanQuit": GLib.Variant("b", True),
                "CanRaise": GLib.Variant("b", False),
                "HasTrackList": GLib.Variant("b", False),
                "Identity": GLib.Variant("s", "Fake Player"),
                "DesktopEntry": GLib.Variant("s", "fake-player"),
                "SupportedUriSchemes": GLib.Variant("as", []),
                "SupportedMimeTypes": GLib.Variant("as", []),
            }
        return {
            "PlaybackStatus": GLib.Variant("s", "Playing" if state["playing"] else "Paused"),
            "LoopStatus": GLib.Variant("s", "None"),
            "Rate": GLib.Variant("d", 1.0),
            "Shuffle": GLib.Variant("b", False),
            "Metadata": GLib.Variant("a{sv}", metadata()),
            "Volume": GLib.Variant("d", 0.8),
            "Position": GLib.Variant("x", 0),
            "MinimumRate": GLib.Variant("d", 1.0),
            "MaximumRate": GLib.Variant("d", 1.0),
            "CanGoNext": GLib.Variant("b", True),
            "CanGoPrevious": GLib.Variant("b", True),
            "CanPlay": GLib.Variant("b", True),
            "CanPause": GLib.Variant("b", True),
            "CanSeek": GLib.Variant("b", False),
            "CanControl": GLib.Variant("b", True),
        }

    def on_call(connection, sender, path, iface, method, params, invocation):
        record(f"{iface.split('.')[-1]}.{method}")
        if method == "PlayPause":
            state["playing"] = not state["playing"]
            emit_properties()
        elif method == "Play":
            state["playing"] = True
            emit_properties()
        elif method == "Pause":
            state["playing"] = False
            emit_properties()
        elif method == "Quit":
            loop.quit()
        invocation.return_value(None)

    def emit_properties():
        changed = {
            IFACE_PLAYER: {
                "PlaybackStatus": GLib.Variant("s", "Playing" if state["playing"] else "Paused"),
                "Metadata": GLib.Variant("a{sv}", metadata()),
            }
        }
        connection.emit_signal(None, MPRIS_PATH, "org.freedesktop.DBus.Properties",
                               "PropertiesChanged",
                               GLib.Variant("(sa{sv}as)", (IFACE_PLAYER, changed[IFACE_PLAYER], [])))

    # Gio's vtable returns values here (no invocation object).
    def on_get(connection, sender, path, iface, prop):
        return properties(iface).get(prop, GLib.Variant("s", ""))

    def on_get_all(connection, sender, path, iface):
        return properties(iface)

    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    for xml in (ROOT_XML, PLAYER_XML):
        node = Gio.DBusNodeInfo.new_for_xml(xml)
        connection.register_object(MPRIS_PATH, node.interfaces[0], on_call, on_get, on_get_all)

    Gio.bus_own_name_on_connection(connection, "org.mpris.MediaPlayer2.cornice-test",
                                  Gio.BusNameOwnerFlags.NONE, None, None)
    record("started")

    loop = GLib.MainLoop()
    if args.seconds:
        GLib.timeout_add_seconds(args.seconds, lambda: loop.quit())
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    # export a property or two
    return 0


if __name__ == "__main__":
    sys.exit(main())
