#!/usr/bin/env python3
"""Private-bus DBusMenu fixture for native cascading-menu regressions.

Consecutive first-child submenus reproduce unwanted event reuse. Repeated leaf
labels across branches, disabled/separator/checked items and a tall sixth level
verify actual activation, navigation and scrolling through Quickshell.
"""
from gi.repository import Gio, GLib

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
sni_xml = """<node><interface name="org.kde.StatusNotifierItem">
<property name="Id" type="s" access="read"/>
<property name="Title" type="s" access="read"/>
<property name="Category" type="s" access="read"/>
<property name="Status" type="s" access="read"/>
<property name="IconName" type="s" access="read"/>
<property name="Menu" type="o" access="read"/>
<property name="ItemIsMenu" type="b" access="read"/>
</interface></node>"""
menu_xml = """<node><interface name="com.canonical.dbusmenu">
<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/>
<arg type="as" direction="in"/><arg type="u" direction="out"/>
<arg type="(ia{sv}av)" direction="out"/></method>
<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/>
<arg type="v" direction="in"/><arg type="u" direction="in"/></method>
<property name="Version" type="u" access="read"/>
<property name="TextDirection" type="s" access="read"/>
<property name="Status" type="s" access="read"/>
<property name="IconThemePath" type="as" access="read"/>
</interface></node>"""
properties = {
    "Id": GLib.Variant("s", "cornice-menu-test"),
    "Title": GLib.Variant("s", "Menu test"),
    "Category": GLib.Variant("s", "ApplicationStatus"),
    "Status": GLib.Variant("s", "Active"),
    "IconName": GLib.Variant("s", "network-wireless"),
    "Menu": GLib.Variant("o", "/Menu"),
    "ItemIsMenu": GLib.Variant("b", True),
}
nodes = {0: ("", [1, 2, 6, 12, 13]), 1: ("Leaf", []), 2: ("First submenu", [3, 4]),
         3: ("Nested submenu", [7]), 4: ("Other leaf", []), 5: ("Deep leaf", []),
         6: ("Second submenu", [9]), 7: ("Third submenu", [8]),
         8: ("Fourth submenu", [5, 10]), 9: ("Other leaf", []),
         10: ("Tall submenu", list(range(20, 55))),
         12: ("Disabled", []), 13: ("Separator", [])}
for ident in range(20, 55):
    nodes[ident] = (f"Tall leaf {ident}", [])



def layout(ident, depth):
    label, children = nodes[ident]
    props = {"label": GLib.Variant("s", label), "enabled": GLib.Variant("b", True)}
    if ident == 12:
        props["enabled"] = GLib.Variant("b", False)
    if ident == 13:
        props["type"] = GLib.Variant("s", "separator")
    if ident == 5:
        props["toggle-type"] = GLib.Variant("s", "checkmark")
        props["toggle-state"] = GLib.Variant("i", 1)
    if children:
        props["children-display"] = GLib.Variant("s", "submenu")
    return (ident, props, [GLib.Variant("(ia{sv}av)", layout(child, depth - 1))
                           for child in children] if depth != 0 else [])


def method(_bus, _sender, _path, _iface, name, params, invocation):
    if name == "GetLayout":
        ident, depth, _props = params.unpack()
        invocation.return_value(GLib.Variant("(u(ia{sv}av))", (1, layout(ident, depth))))
    elif name == "AboutToShow":
        invocation.return_value(GLib.Variant("(b)", (False,)))
    elif name == "Event":
        print("event " + str(params.unpack()[0]) + " " + params.unpack()[1], flush=True)
        invocation.return_value(GLib.Variant("()", ()))


bus.register_object("/StatusNotifierItem", Gio.DBusNodeInfo.new_for_xml(sni_xml).interfaces[0],
                    None, lambda *_args: properties[_args[-1]], None)
menu_props = {"Version": GLib.Variant("u", 3), "TextDirection": GLib.Variant("s", "ltr"),
              "Status": GLib.Variant("s", "normal"), "IconThemePath": GLib.Variant("as", [])}
bus.register_object("/Menu", Gio.DBusNodeInfo.new_for_xml(menu_xml).interfaces[0], method,
                    lambda *_args: menu_props[_args[-1]], None)
bus.call_sync("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
              "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
              GLib.Variant("(s)", (bus.get_unique_name(),)), None,
              Gio.DBusCallFlags.NONE, 5000, None)
print("ready", flush=True)
GLib.MainLoop().run()
