"""Private D-Bus logind test double with real inhibitor FD lifetimes.

The address is required to be a test-owned bus. No system sleep is performed.
"""
import json
import os
import pathlib
import socket
import sys
import gi
from gi.repository import Gio, GLib

bus_address, destination = sys.argv[1:]
assert bus_address == os.environ['DBUS_SYSTEM_BUS_ADDRESS']
assert os.getenv('CORNICE_TEST_SANDBOX') == '1'
assert pathlib.Path(os.environ['XDG_RUNTIME_DIR']).resolve().is_relative_to(pathlib.Path(os.environ['TMPDIR']).resolve())
assert not pathlib.Path('/run/dbus/system_bus_socket').exists()
path = pathlib.Path(destination)
properties = {'LidClosed': False, 'Docked': False, 'OnExternalPower': False,
              'HandleLidSwitch': 'suspend', 'HandleLidSwitchDocked': 'ignore', 'HandleLidSwitchExternalPower': ''}
xml = '''<node><interface name="org.freedesktop.login1.Manager">
<method name="Inhibit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="h" direction="out"/></method>
<method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>
<method name="Suspend"><arg type="b" direction="in"/></method>
<signal name="PrepareForSleep"><arg type="b"/></signal>
''' + ''.join(f'<property name="{name}" type="{"b" if isinstance(value, bool) else "s"}" access="read"/>' for name, value in properties.items()) + '''</interface>
<interface name="org.freedesktop.login1.Session"><method name="SetLockedHint"><arg type="b" direction="in"/></method></interface></node>'''
bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName', GLib.Variant('(su)', ('org.freedesktop.login1', 0)), None, Gio.DBusCallFlags.NONE, 2000, None)

def record(event, **values):
    with path.open('a') as out: out.write(json.dumps({'event': event, **values}) + '\n')

def lock_state():
    address = pathlib.Path(os.environ['XDG_RUNTIME_DIR']) / 'hypr' / os.environ['HYPRLAND_INSTANCE_SIGNATURE'] / '.socket.sock'
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(2); client.connect(str(address)); client.sendall(b'j/seat lock-state')
        data = b''
        while part := client.recv(65536): data += part
    return json.loads(data)

def method(connection, sender, object_path, interface, name, args, invocation):
    values = args.unpack()
    if name == 'Inhibit':
        what, who, why, mode = values
        read_fd, write_fd = os.pipe()
        fd_list = Gio.UnixFDList.new(); index = fd_list.append(write_fd); os.close(write_fd)
        record('inhibit', what=what, mode=mode)
        def released(fd, condition):
            os.close(fd); record('released', what=what, mode=mode); return False
        GLib.io_add_watch(read_fd, GLib.IO_HUP, released)
        invocation.return_value_with_unix_fd_list(GLib.Variant('(h)', (index,)), fd_list)
    elif name == 'GetSessionByPID': invocation.return_value(GLib.Variant('(o)', ('/org/freedesktop/login1/session/test',)))
    elif name == 'SetLockedHint':
        record('hint', locked=values[0]); invocation.return_value(None)
    elif name == 'Suspend':
        state = lock_state(); record('suspend', state=state)
        invocation.return_value(None)
        bus.emit_signal(None, '/org/freedesktop/login1', interface, 'PrepareForSleep', GLib.Variant('(b)', (True,)))
    else: invocation.return_dbus_error('org.freedesktop.DBus.Error.UnknownMethod', name)

node = Gio.DBusNodeInfo.new_for_xml(xml)
manager = '/org/freedesktop/login1'
bus.register_object(manager, node.interfaces[0], method, lambda c,s,p,i,n: GLib.Variant('b' if isinstance(properties[n], bool) else 's', properties[n]), None)
bus.register_object(manager + '/session/test', node.interfaces[1], method, None, None)

def control(fd, condition):
    line = sys.stdin.readline()
    if not line: loop.quit(); return False
    request = json.loads(line)
    if request.get('event') == 'resume':
        bus.emit_signal(None, manager, 'org.freedesktop.login1.Manager', 'PrepareForSleep', GLib.Variant('(b)', (False,)))
    elif 'LidClosed' in request:
        properties['LidClosed'] = request['LidClosed']
    return True
GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN | GLib.IO_HUP, control)
record('ready')
loop = GLib.MainLoop(); loop.run()
