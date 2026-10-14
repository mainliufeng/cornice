#!/usr/bin/env python3
"""Exercise the real PluginInstance and Controller on Qt's offscreen backend."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
qs = shutil.which('quickshell')
assert qs, 'Quickshell is required for the real Loader contract test'
metadata = Path('/usr/lib/qt6/qml/Quickshell/quickshell-core.qmltypes').read_text()
assert re.search(r'name: "reload"[\s\S]{0,140}name: "hard"; type: "bool"', metadata)
print(subprocess.check_output([qs, '--version'], text=True).strip())

with tempfile.TemporaryDirectory(prefix='cornice-runtime-loader-', dir='/tmp') as temporary:
    base = Path(temporary)
    for directory in ('runtime', 'cache', 'config', 'data', 'state', 'home'):
        (base / directory).mkdir(mode=0o700)
    (base / 'Commons').symlink_to(ROOT / 'shell/Commons', target_is_directory=True)
    (base / 'services').mkdir()
    shutil.copy2(ROOT / 'shell/services/PluginInstance.qml', base / 'services/PluginInstance.qml')
    qml = r'''
import QtQuick
import Quickshell
import "services" as Services
ShellRoot {
  id: shell
  function check(value, message) { if (!value) throw new Error(message) }
  Item {
    id: testHost
    property var instance: null
    function registerInstance(id, instance) { testHost.instance = instance }
    function unregisterInstance(id) { testHost.instance = null }
  }
  Item {
    id: testRegistry
    signal pluginsChanged()
    property bool ready: true
    property var metadata: ({id:"cn.runtime-control", dir:__PLUGIN__, entryPoints:{panel:"Controller.qml"}})
    function byId(id) { return id === "cn.runtime-control" ? metadata : null }
  }
  Services.PluginInstance {
    id: instance
    host: testHost
    registry: testRegistry
    pluginId: "cn.runtime-control"
    entry: "panel"
    autoOpen: false
  }
  Timer {
    interval: 100
    running: true
    onTriggered: {
      try {
        shell.check(instance.loaded, "actual PluginInstance Loader did not load")
        shell.check(testHost.instance === instance, "host registration contract differs")
        shell.check(instance.item.host === testHost, "host injection failed")
        shell.check(instance.item.plugin === testRegistry.metadata, "plugin injection failed")
        shell.check(instance.call("status", "{}") === "unprepared", "loading triggered preparation")
        shell.check(instance.open({action:"prepare"}) === "ok", "host open contract failed")
        shell.check(instance.call("status", "{}") === "ready", "JSON-string payload was not prepared")
        shell.check(instance.item.children.length === 0, "controller created a surface")
        shell.check(typeof Quickshell.reload === "function", "public reload API missing")
        instance.close()
        shell.check(instance.call("status", "{}") === "unprepared", "close failed")
        console.log("PASS real PluginInstance Loader, host injection, JSON open/call/close and public soft reload API")
        Qt.quit()
      } catch (error) {
        console.error("FAIL " + error)
        Qt.exit(1)
      }
    }
  }
}
'''
    qml = qml.replace('__PLUGIN__', json.dumps(str(ROOT / 'shell/plugins/runtime-control')))
    (base / 'shell.qml').write_text(qml)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('CORNICE_', 'HYPRLAND_', 'QS_')) or key in ('DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS'):
            del env[key]
    env.update(QT_QPA_PLATFORM='offscreen', QSG_RHI_BACKEND='software', HOME=str(base / 'home'),
               XDG_RUNTIME_DIR=str(base / 'runtime'), XDG_CACHE_HOME=str(base / 'cache'),
               XDG_CONFIG_HOME=str(base / 'config'), XDG_DATA_HOME=str(base / 'data'),
               XDG_STATE_HOME=str(base / 'state'), QS_DISABLE_FILE_WATCHER='1', QS_NO_RELOAD_POPUP='1')
    answer = subprocess.run([qs, '--no-color', '-p', str(base)], env=env, capture_output=True,
                            text=True, timeout=10)
    output = answer.stdout + answer.stderr
    print(output.strip())
    assert answer.returncode == 0 and 'PASS real PluginInstance' in output, output
