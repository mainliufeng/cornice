#!/usr/bin/env python3
"""Run the real native planning worker in a private home, without a compositor."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BINARY = Path(os.environ.get('CORNICE_TEST_RUNTIME', '/tmp/cornice-product-fixes-native-build/cornice-desktop-runtime'))

with tempfile.TemporaryDirectory(prefix='cornice-launch-plan-') as directory:
    home = Path(directory)
    config, data = home / 'config', home / 'data'
    (config / 'cornice').mkdir(parents=True)
    (data / 'applications').mkdir(parents=True)
    settings = {'desktopApplications': {'rules': {'handler': {
        'executables': ['true'], 'scope': 'secondary', 'profile': 'handler',
        'arguments': ['{desktop}', '{profile}']}}}}
    (config / 'cornice/config.json').write_text(json.dumps(settings))
    env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(config),
               XDG_DATA_HOME=str(data), XDG_STATE_HOME=str(home / 'state'),
               CORNICE_PATH=str(ROOT))
    # This command executes only policy preparation, never the requested app.
    def plan(argv, success=True):
        result = subprocess.run([str(BINARY), 'plan-launch', 'desktop2', 'false', json.dumps(argv)],
                                env=env, capture_output=True, text=True, timeout=8)
        assert (result.returncode == 0) == success, result.stderr
        return json.loads(result.stdout) if success else result.stderr

    wrapped = plan(['env', 'HTTP_PROXY=http://127.0.0.1:8080', 'sh', '-c',
                    "exec google-chrome-stable 'https://example.invalid/with space'"])
    assert wrapped['environment']['HTTP_PROXY'] == 'http://127.0.0.1:8080'
    assert wrapped['requestedEnvironment'] == {'HTTP_PROXY': 'http://127.0.0.1:8080'}
    assert wrapped['requestedArguments'] == ['https://example.invalid/with space']
    assert '--user-data-dir=' + str(data / 'cornice/desktops/desktop2/chrome') in wrapped['arguments']
    print('PASS literal env and shell wrappers preserve browser policy, profile and quoted URL')
    ordinary = plan(['google-chrome-stable', 'https://example.invalid/next'])
    absolute = plan([ordinary['program'], 'https://example.invalid/absolute'])
    assert Path(ordinary['program']).is_absolute() and ordinary['program'] == absolute['program'] == wrapped['program']
    search = str(Path(ordinary['program']).parent) + ':/usr/bin'
    explicit_path = plan(['env', 'PATH=' + search, 'google-chrome-stable'])
    assert explicit_path['program'] == ordinary['program'] and explicit_path['environment']['PATH'] == search
    print('PASS launcher and absolute browser commands share executable identity and retain explicit PATH')
    changed = plan(['env', 'HTTP_PROXY=http://127.0.0.1:8081', 'google-chrome-stable'])
    assert wrapped['basePolicy'] == ordinary['basePolicy'] == changed['basePolicy']
    assert len({wrapped['policy'], ordinary['policy'], changed['policy']}) == 3
    print('PASS configured policy and explicit per-launch environment have separate reconnect identities')
    (config / 'mimeapps.list').write_text('[Default Applications]\nx-scheme-handler/cornice-test=cornice-test.desktop\n')
    (data / 'applications/cornice-test.desktop').write_text(
        '[Desktop Entry]\nType=Application\nName=Cornice test handler\nExec=true %u\nMimeType=x-scheme-handler/cornice-test;\n')
    handled = plan(['xdg-open', 'cornice-test://actual-handler/path'])
    assert handled['program'] == 'true' and handled['arguments'][-1] == 'cornice-test://actual-handler/path'
    assert handled['rule'] == 'handler' and handled['arguments'][0] == 'desktop2'
    print('PASS real XDG MIME association resolves through the configured desktop application rule')
    compound = plan(['sh', '-c', 'touch ' + str(home / 'must-not-launch') + '; true'])
    assert compound['program'] == 'sh' and compound['warnings'] and not (home / 'must-not-launch').exists()
    print('PASS compound scripts retain native argv and report limits without executing during preparation')
    assert 'identity' in plan(['env', 'WAYLAND_DISPLAY=wrong', 'true'], False)
    assert 'disabled' in plan(['google-chrome-stable', '--remote-debugging-port=9222'], False)
    print('PASS native worker rejects compositor identity and browser transport overrides')
