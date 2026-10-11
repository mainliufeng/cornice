#!/usr/bin/env python3
"""UPower and read-only logind test doubles on the harness's private bus.

Only the bus socket inside XDG_RUNTIME_DIR is accepted. All properties and
signals use the standard service interfaces; no host power/sleep action exists.
stdin JSON control emits logind signals to exercise the shell's real monitor.
"""
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time

from gi.repository import Gio, GLib

address, events_file = sys.argv[1:]
match = re.fullmatch(r"unix:path=([^,]+)(?:,guid=[0-9a-f]+)?", address)
if (os.getenv("CORNICE_TEST_SANDBOX") != "1" or not match or
        address != os.getenv("DBUS_SESSION_BUS_ADDRESS") or
        address != os.getenv("DBUS_SYSTEM_BUS_ADDRESS")):
    raise SystemExit("Explicit sandbox-owned session/system bus required")
runtime = Path(os.environ["XDG_RUNTIME_DIR"]).resolve()
socket_path = Path(match[1]).resolve()
if (socket_path.parent != runtime or
        not runtime.is_relative_to(Path(os.environ["TMPDIR"]).resolve()) or
        not stat.S_ISSOCK(socket_path.stat().st_mode)):
    raise SystemExit("Bus socket must belong to the private test runtime")
events = Path(events_file).resolve()
if events.parent != runtime:
    raise SystemExit("Events must remain inside the private test runtime")


def record(event, **details):
    with events.open("a") as output:
        output.write(json.dumps({"event": event, **details}) + "\n")


bus = Gio.DBusConnection.new_for_address_sync(
    address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
    Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)

UP_ROOT = "/org/freedesktop/UPower"
UP_DEVICE = UP_ROOT + "/devices/DisplayDevice"
LOGIN_ROOT = "/org/freedesktop/login1"
LOGIN_SESSION = LOGIN_ROOT + "/session/test"
up_props = {
    "DaemonVersion": ("s", "1.90.0"), "OnBattery": ("b", False),
    "LidIsClosed": ("b", False), "LidIsPresent": ("b", True),
}
# Percentage is the standard 0..100 D-Bus value; Quickshell exposes a fraction.
device_props = {
    "NativePath": ("s", "test-battery"), "Vendor": ("s", "Cornice test"),
    "Model": ("s", "Private battery fixture"), "Serial": ("s", "test"),
    "UpdateTime": ("t", int(time.time())), "Type": ("u", 2),
    "PowerSupply": ("b", True), "HasHistory": ("b", False),
    "HasStatistics": ("b", False), "Online": ("b", False),
    "Energy": ("d", 36.0), "EnergyEmpty": ("d", 0.0),
    "EnergyFull": ("d", 50.0), "EnergyFullDesign": ("d", 50.0),
    "EnergyRate": ("d", 10.0), "Voltage": ("d", 12.0),
    "ChargeCycles": ("i", 5), "Luminosity": ("d", 0.0),
    "TimeToEmpty": ("x", 12960), "TimeToFull": ("x", 0),
    "Percentage": ("d", 72.0), "Temperature": ("d", 25.0),
    "IsPresent": ("b", True), "State": ("u", 2),
    "IsRechargeable": ("b", True), "Capacity": ("d", 100.0),
    "Technology": ("u", 1), "WarningLevel": ("u", 1),
    "BatteryLevel": ("u", 1), "IconName": ("s", "battery-good-symbolic"),
}
login_props = {
    "LidClosed": ("b", False), "Docked": ("b", False),
    "OnExternalPower": ("b", True), "PreparingForSleep": ("b", False),
    "HandleLidSwitch": ("s", "ignore"),
    "HandleLidSwitchDocked": ("s", "ignore"),
    "HandleLidSwitchExternalPower": ("s", "ignore"),
}
session_props = {"Id": ("s", "test"), "Active": ("b", True), "State": ("s", "active")}


def properties_xml(properties):
    return "".join(f'<property name="{name}" type="{kind}" access="read"/>'
                   for name, (kind, _value) in properties.items())


up_xml = '''<node><interface name="org.freedesktop.UPower">
<method name="EnumerateDevices"><arg type="ao" direction="out"/></method>
<method name="GetDisplayDevice"><arg type="o" direction="out"/></method>
<method name="GetCriticalAction"><arg type="s" direction="out"/></method>
<signal name="DeviceAdded"><arg type="o"/></signal>
<signal name="DeviceRemoved"><arg type="o"/></signal>
''' + properties_xml(up_props) + "</interface></node>"
device_xml = '''<node><interface name="org.freedesktop.UPower.Device">
<method name="Refresh"/>
''' + properties_xml(device_props) + "</interface></node>"
login_xml = '''<node><interface name="org.freedesktop.login1.Manager">
<method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
<signal name="PrepareForSleep"><arg type="b"/></signal>
''' + properties_xml(login_props) + "</interface></node>"
session_xml = '''<node><interface name="org.freedesktop.login1.Session">
<signal name="Lock"/><signal name="Unlock"/>
''' + properties_xml(session_props) + "</interface></node>"


def method(_bus, sender, path, interface, name, _args, invocation):
    record("method", sender=sender, path=path, interface=interface, method=name)
    if interface == "org.freedesktop.UPower" and name == "GetDisplayDevice":
        invocation.return_value(GLib.Variant("(o)", (UP_DEVICE,)))
    elif interface == "org.freedesktop.UPower" and name == "EnumerateDevices":
        invocation.return_value(GLib.Variant("(ao)", ([UP_DEVICE],)))
    elif interface == "org.freedesktop.UPower" and name == "GetCriticalAction":
        invocation.return_value(GLib.Variant("(s)", ("Ignore",)))
    elif interface == "org.freedesktop.UPower.Device" and name == "Refresh":
        invocation.return_value(GLib.Variant("()", ()))
    elif interface == "org.freedesktop.login1.Manager" and name == "GetSessionByPID":
        invocation.return_value(GLib.Variant("(o)", (LOGIN_SESSION,)))
    else:
        invocation.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", name)


def export(path, xml, properties):
    def get_property(_bus, sender, _path, interface, name):
        record("property", sender=sender, path=path, interface=interface, property=name)
        kind, value = properties[name]
        return GLib.Variant(kind, value)
    identifier = bus.register_object(path, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0],
                                     method, get_property, None)
    if not identifier:
        raise RuntimeError("Could not export " + path)


export(UP_ROOT, up_xml, up_props)
export(UP_DEVICE, device_xml, device_props)
export(LOGIN_ROOT, login_xml, login_props)
export(LOGIN_SESSION, session_xml, session_props)
for name in ("org.freedesktop.UPower", "org.freedesktop.login1"):
    reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                          "org.freedesktop.DBus", "RequestName",
                          GLib.Variant("(su)", (name, 4)), None,
                          Gio.DBusCallFlags.NONE, 2000, None)
    if reply.unpack() != (1,):
        raise RuntimeError("Private service name was already owned: " + name)

loop = GLib.MainLoop()


def control(_fd, condition):
    if condition & GLib.IO_HUP:
        loop.quit()
        return False
    line = sys.stdin.readline()
    if not line:
        loop.quit()
        return False
    request = json.loads(line)
    event = request.get("event")
    if event not in ("sleep", "resume"):
        raise ValueError("Only private sleep/resume signals are supported")
    sleeping = event == "sleep"
    login_props["PreparingForSleep"] = ("b", sleeping)
    bus.emit_signal(None, LOGIN_ROOT, "org.freedesktop.login1.Manager",
                    "PrepareForSleep", GLib.Variant("(b)", (sleeping,)))
    bus.flush_sync(None)
    record("signal", interface="org.freedesktop.login1.Manager", signal="PrepareForSleep", sleeping=sleeping)
    return True


GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN | GLib.IO_HUP, control)
GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, lambda: (loop.quit(), False)[1])
record("ready", address=address, owner=bus.get_unique_name(), services=["org.freedesktop.UPower", "org.freedesktop.login1"])
loop.run()
bus.close_sync(None)
