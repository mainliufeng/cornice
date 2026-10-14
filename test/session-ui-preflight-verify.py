#!/usr/bin/env python3
"""Real Qt parser/native transport compilation; all processes stay offscreen."""
import importlib.machinery,tempfile,shutil,subprocess,os
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
PRODUCT=Path(os.environ.get('CORNICE_TEST_PREFLIGHT_PRODUCT', str(ROOT)))
m=importlib.machinery.SourceFileLoader('ui_preflight_probe',str(ROOT/'bin/cornice-session-trial')).load_module()
with tempfile.TemporaryDirectory(prefix='cornice-preflight-real-') as temporary:
    base=Path(temporary)
    candidate=base/'release'; product=candidate/'cornice'
    shutil.copytree(ROOT/'shell',product/'shell')
    shutil.copytree(PRODUCT/'native',product/'native')
    for name in ('runtime','home','config','cache','data','state'):(base/name).mkdir(mode=0o700)
    (base/'shell.qml').write_text('import QtQuick\nimport Quickshell\nShellRoot {}\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('CORNICE_','HYPRLAND_','QS_','QT_','XDG_')) and k not in ('DISPLAY','WAYLAND_DISPLAY','DBUS_SESSION_BUS_ADDRESS')}
    env.update(QT_QPA_PLATFORM='offscreen',QSG_RHI_BACKEND='software',HOME=str(base/'home'),XDG_RUNTIME_DIR=str(base/'runtime'),XDG_CONFIG_HOME=str(base/'config'),XDG_CACHE_HOME=str(base/'cache'),XDG_DATA_HOME=str(base/'data'),XDG_STATE_HOME=str(base/'state'),DBUS_SESSION_BUS_ADDRESS='unix:path='+str(base/'no-bus'))
    q=subprocess.Popen(['quickshell','--no-color','-p',str(base/'shell.qml')],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        m.ui_preflight(candidate,{'info':{'shellPid':q.pid}})
        print('PASS real full candidate QML syntax and actual new native IPC compile in a separate private Quickshell engine')
        (product/'shell/shell.qml').write_text((product/'shell/shell.qml').read_text()+'\ninvalid qml {\n')
        try:
            m.ui_preflight(candidate,{'info':{'shellPid':q.pid}})
            raise AssertionError('bad QML accepted')
        except RuntimeError as e:
            assert 'QML preflight rejected' in str(e),str(e)
            print('PASS real bad QML payload rejected before any live pointer or owner-process action')
    finally:
        q.terminate();q.wait(timeout=3)
