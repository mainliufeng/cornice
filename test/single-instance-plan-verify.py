#!/usr/bin/env python3
"""Real process identity, hidden app, symlink and desktop checks in a private HOME."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ['CORNICE_TEST_RUNTIME'])
with tempfile.TemporaryDirectory(prefix='cornice-singleton-') as directory:
    home = Path(directory)
    config = home / 'config/cornice'; config.mkdir(parents=True)
    binary = home / 'singleton'; shutil.copy('/usr/bin/sleep', binary)
    alias = home / 'singleton-alias'; alias.symlink_to(binary)
    settings = {'desktopApplications': {'rules': {'test': {
        'executables': ['singleton', 'singleton-alias'], 'singleInstance': 'Singleton test'}}}}
    (config / 'config.json').write_text(json.dumps(settings))
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home/'config'),
               XDG_DATA_HOME=str(home/'data'), CORNICE_PATH=str(ROOT),
               HYPRLAND_INSTANCE_SIGNATURE='singleton-test', WAYLAND_DISPLAY='wayland-test')
    env.pop('CORNICE_DESKTOP_NAME', None)
    def check(desktop, argv, success=True):
        result = subprocess.run([str(BINARY), 'check-singleton', desktop,
                                 str(desktop == 'main').lower(), json.dumps(argv)],
                                env=env, text=True, capture_output=True, timeout=8)
        assert (result.returncode == 0) == success, result.stderr
        return result.stderr
    check('desktop2', [str(binary), '100'])
    process = subprocess.Popen([str(binary), '100'], env=env)
    try:
        check('main', [str(binary), '100'])
        error = check('desktop2', ['env', 'sh', '-c', str(alias)+' 100'], False)
        assert 'Singleton test' in error and '桌面 1' in error and '只能打开一个实例' in error
        applications = home / 'data/applications'; applications.mkdir(parents=True, exist_ok=True)
        (applications/'singleton-test.desktop').write_text('[Desktop Entry]\nType=Application\nName=Singleton test\nExec='+str(binary)+' %u\nMimeType=x-scheme-handler/cornice-singleton;\n')
        (home/'config/mimeapps.list').write_text('[Default Applications]\nx-scheme-handler/cornice-singleton=singleton-test.desktop\n')
        assert 'Singleton test' in check('desktop2', ['xdg-open', 'cornice-singleton:open'], False)
        planned = subprocess.run([str(BINARY), 'plan-launch', 'desktop2', 'false', json.dumps([str(binary), '100'])], env=env, text=True, capture_output=True, timeout=8)
        assert planned.returncode != 0 and '桌面 1' in planned.stderr
        # Unconfigured applications remain ordinary multi-window launches.
        check('desktop2', ['sleep', '100'])
        print('PASS exact real executable identity detects hidden primary singleton through env/shell/symlink aliases; same-desktop and ordinary apps stay allowed')
    finally:
        process.terminate(); process.wait()
    secondary = subprocess.Popen([str(binary), '100'], env=env | {'CORNICE_DESKTOP_NAME':'desktop2'})
    try:
        check('desktop2', [str(binary), '100'])
        assert '桌面 2' in check('main', [str(binary), '100'], False)
    finally:
        secondary.terminate(); secondary.wait()
    check('desktop2', [str(binary), '100'])
    other = subprocess.Popen([str(binary), '100'], env=env | {'HYPRLAND_INSTANCE_SIGNATURE':'another-login'})
    try:
        message = check('desktop2', [str(binary), '100'], False)
        assert '无法确认所在桌面' in message and '桌面 1' not in message
    finally:
        other.terminate(); other.wait()
    settings['desktopApplications']['rules']['test']['singleInstance'] = True
    (config/'config.json').write_text(json.dumps(settings))
    assert 'singleInstance' in check('desktop2', [str(binary), '100'], False)
    print('PASS reverse desktop direction, exited process and malformed singleton policy are handled truthfully')
