#!/usr/bin/python3
"""Exact-owner menu fallback, without a watcher or application-ID lookup."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if len(sys.argv) > 1 and sys.argv[1] == "--service":
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    xml = '''<node><interface name="org.kde.StatusNotifierItem">
    <property name="Id" type="s" access="read"/><property name="Menu" type="o" access="read"/>
    </interface></node>'''
    menu_xml = '''<node><interface name="com.canonical.dbusmenu">
    <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
    <method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
    <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
    <method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
    </interface></node>'''
    events = Path(sys.argv[2])
    def prop(_bus, _sender, path, _iface, name):
        return GLib.Variant("s", "duplicate-id") if name == "Id" else GLib.Variant("o", path + "Menu")
    def method(_bus, _sender, path, _iface, name, params, invocation):
        if name == "AboutToShow": invocation.return_value(GLib.Variant("(b)", (False,)))
        elif name == "GetLayout":
            child = GLib.Variant("(ia{sv}av)", (7, {"label": GLib.Variant("s", "_Open")}, []))
            invocation.return_value(GLib.Variant("(u(ia{sv}av))", (1, (0, {}, [child]))))
        elif name == "Event":
            with events.open("a") as output: output.write(path + ":" + str(params.unpack()[0]) + "\n")
            invocation.return_value(GLib.Variant("()", ()))
    for path in ("/First", "/Second"):
        bus.register_object(path, Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], None, prop, None)
        bus.register_object(path + "Menu", Gio.DBusNodeInfo.new_for_xml(menu_xml).interfaces[0], method, None, None)
    print(bus.get_unique_name(), flush=True)
    GLib.MainLoop().run()
else:
    with tempfile.TemporaryDirectory(prefix="exact-tray-") as temporary:
        log = Path(temporary) / "events"
        service = subprocess.Popen([sys.executable, __file__, "--service", str(log)], stdout=subprocess.PIPE, text=True)
        try:
            assert select.select([service.stdout], [], [], 4)[0]
            owner = service.stdout.readline().strip(); assert owner.startswith(":")
            helper = ROOT / "bin/cornice-tray-activate"
            route = json.dumps([{"text": "Open", "index": 0}])
            def invoke(destination, path):
                return subprocess.run([str(helper), "--service", destination, "--object-path", path,
                                       "--label", "Open", "--path", route], capture_output=True, text=True, timeout=6)
            for path in ("/Second", "/First"):
                result = invoke(owner, path)
                assert result.returncode == 0, (result.stdout, result.stderr)
            assert log.read_text().splitlines() == ["/SecondMenu:7", "/FirstMenu:7"]
            print("PASS duplicate logical IDs dispatch only to the exact unique owner and SNI object path")
            print("PASS generic menu path fallback resolves mnemonic-normalized labels")
            assert invoke("org.cornice.WellKnown", "/Second").returncode == 2
            assert len(log.read_text().splitlines()) == 2
            print("PASS replaceable service names are refused by the exact-owner fallback")
            service.terminate(); service.wait(timeout=4)
            assert invoke(owner, "/First").returncode != 0
            assert len(log.read_text().splitlines()) == 2
            print("PASS vanished owner never falls back to another registration")
        finally:
            if service.poll() is None: service.terminate(); service.wait(timeout=4)
