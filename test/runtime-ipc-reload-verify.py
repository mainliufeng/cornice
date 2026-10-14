#!/usr/bin/env python3
"""Real Quickshell IPC across QML generations on the private offscreen backend."""
import ctypes
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
# Preserve the real pre-migration transport independent of the current HEAD.
legacy_server = (ROOT / 'test/fixtures/legacy-shell-ipc.qml').read_text()
modern_server = (ROOT / 'shell/services/IpcServer.qml').read_text()
registry = (ROOT / 'shell/Commons/IpcRegistry.qml').read_text()
controller = (ROOT / 'shell/plugins/runtime-control/Controller.qml').read_text()


def exchange(left, right):
    rename = ctypes.CDLL(None, use_errno=True).renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    assert rename(-100, os.fsencode(left), -100, os.fsencode(right), 2) == 0


def tree(directory, modern):
    for name in ('Commons', 'services', 'runtime'):
        (directory / name).mkdir(parents=True, exist_ok=True)
    (directory / 'Commons/qmldir').write_text('module qs.Commons\nsingleton IpcRegistry 1.0 IpcRegistry.qml\n')
    (directory / 'Commons/IpcRegistry.qml').write_text(registry)
    (directory / 'services/IpcServer.qml').write_text(modern_server if modern else legacy_server)
    (directory / 'runtime/Controller.qml').write_text(controller)
    qml = '''import QtQuick
import Quickshell
import qs.Commons
import "services"
import "runtime" as Runtime
ShellRoot {
  id: shell
  readonly property string generation: __GENERATION__
  IpcServer { id: ipcServer; socketPath: Quickshell.env("TEST_IPC_PATH") }
  __PREPARE__
  Runtime.Controller { id: controller; host: shell }
  Item {
    id: handler
    property string target: "shell"
    function ping() { return "pong " + shell.generation }
    __IDENTITY__
    function reload() {
      controller.open('{"action":"prepare"}')
      return controller.reload('{}')
    }
    Component.onCompleted: IpcRegistry.register(handler)
    Component.onDestruction: IpcRegistry.unregister(handler)
  }
}
'''
    qml = qml.replace('__GENERATION__', json.dumps('modern' if modern else 'legacy'))
    qml = qml.replace('__PREPARE__', 'function prepareUiReload() { ipcServer.prepareReload() }' if modern else '')
    qml = qml.replace('__IDENTITY__', 'function runtimeIdentity() { return "modern" }' if modern else '')
    (directory / 'shell.qml').write_text(qml)


with tempfile.TemporaryDirectory(prefix='cornice-ipc-reload-', dir='/tmp') as temporary:
    base = Path(temporary)
    for name in ('runtime-dir', 'cache', 'config', 'data', 'state', 'home'):
        (base / name).mkdir(mode=0o700)
    active, modern = base / 'active', base / 'modern'
    tree(active, False)
    tree(modern, True)
    slot = base / '.slot'
    slot.symlink_to(modern, target_is_directory=True)
    endpoint = base / 'runtime-dir/ipc.sock'
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('CORNICE_', 'HYPRLAND_', 'QS_')) or key in ('DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS'):
            del env[key]
    env.update(QML_IMPORT_PATH=os.environ.get('CORNICE_TEST_PLATFORM_QML', str(ROOT / 'native/qml')), QT_QPA_PLATFORM='offscreen', QSG_RHI_BACKEND='software', TEST_IPC_PATH=str(endpoint),
               HOME=str(base / 'home'), XDG_RUNTIME_DIR=str(base / 'runtime-dir'),
               XDG_CACHE_HOME=str(base / 'cache'), XDG_CONFIG_HOME=str(base / 'config'),
               XDG_DATA_HOME=str(base / 'data'), XDG_STATE_HOME=str(base / 'state'),
               QS_DISABLE_FILE_WATCHER='1', QS_NO_RELOAD_POPUP='1')
    log_path = base / 'quickshell.log'
    with log_path.open('w') as log:
        process = subprocess.Popen(['quickshell', '--no-color', '-p', str(active)], env=env,
                                   stdout=log, stderr=subprocess.STDOUT)

        def request(method, success=True):
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(1)
                client.connect(str(endpoint))
                assert struct.unpack('3i', client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0] == process.pid
                client.sendall((json.dumps({'target': 'shell', 'method': method, 'args': []}) + '\n').encode())
                data = bytearray()
                while b'\n' not in data:
                    chunk = client.recv(4096)
                    assert chunk, 'IPC closed without reply'
                    data.extend(chunk)
            value = json.loads(data.split(b'\n', 1)[0])
            assert value['ok'] is success, value
            return value.get('result') if success else value['error']

        def wait_generation(expected):
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                assert process.poll() is None, log_path.read_text()
                try:
                    if request('ping') == 'pong ' + expected:
                        if expected == 'legacy':
                            assert 'unknown method: shell.runtimeIdentity' in request('runtimeIdentity', success=False)
                        else:
                            assert request('runtimeIdentity') == 'modern'
                        return
                except (OSError, AssertionError):
                    pass
                time.sleep(.01)
            raise AssertionError('IPC generation did not become reachable: ' + expected + '\n' + log_path.read_text())

        try:
            wait_generation('legacy')
            exchange(active, slot)
            assert request('reload') == 'requested'
            wait_generation('modern')
            print('PASS private fresh legacy/new transport generations retain the socket pathname after the publicly documented reload callback')
            bad = base / 'bad'
            shutil.copytree(modern, bad)
            (bad / 'shell.qml').write_text((bad / 'shell.qml').read_text() + '\ninvalid qml {\n')
            bad_slot = base / '.bad-slot'
            bad_slot.symlink_to(bad, target_is_directory=True)
            exchange(active, bad_slot)
            assert request('reload') == 'requested'
            wait_generation('modern')
            # Confirm the failed reload was really processed before restoring.
            deadline = time.monotonic() + 5
            while 'Failed to load configuration' not in log_path.read_text():
                assert time.monotonic() < deadline
                time.sleep(.01)
            assert request('ping') == 'pong modern'
            exchange(active, bad_slot)
            assert request('reload') == 'requested'
            wait_generation('modern')
            print('PASS a real QML parser failure restores the old listener and a later explicit reload succeeds on the same process')
            for _ in range(10):
                exchange(active, slot)
                assert request('reload') == 'requested'
                wait_generation('legacy')
                exchange(active, slot)
                assert request('reload') == 'requested'
                wait_generation('modern')
            print('PASS 10 private transport generation exchanges preserve real IPC replies and the same socket peer PID')
        finally:
            process.terminate()
            process.wait(timeout=5)
