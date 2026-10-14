"""Real QML soft updates and rollback in the isolated compositor only."""
import desktop_harness as harness
from desktop_harness import *
import importlib.machinery
import shutil

assert os.environ.get('CORNICE_TEST_SANDBOX') == '1'
CANDIDATE_PRODUCT = PRODUCT
TRIAL = ROOT / 'bin/cornice-session-trial'
TRIAL_STATE = BASE / 'ui-trial'
TRIAL_ENV = ENV | {'CORNICE_TRIAL_STATE_DIR': str(TRIAL_STATE)}
pathlib.Path(ENV['XDG_CONFIG_HOME']).mkdir(parents=True, exist_ok=True)
configuration = BASE / 'candidate.lua'
configuration.write_text('hl.monitor({output="",mode="1280x800",position="auto",scale=1})\n')


def trial(*args, succeeds=True, timeout=90):
    result = subprocess.run([str(TRIAL), *map(str, args)], env=TRIAL_ENV,
                            capture_output=True, text=True, timeout=timeout)
    (BASE / ('trial-' + str(time.monotonic_ns()) + '.json')).write_text(json.dumps({
        'command': args, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}, default=str))
    assert (result.returncode == 0) == succeeds, (args, result.stdout, result.stderr)
    return result


def prepare(source):
    return pathlib.Path(json.loads(trial('prepare', '--hyprland', os.environ['CORNICE_TEST_HYPRLAND'],
                                        '--cornice', source, '--config', configuration).stdout)['prepared'])


def invoke(*args, env=None, succeeds=True):
    result = subprocess.run([str(CANDIDATE_PRODUCT / 'bin/cornice'), *map(str, args)], env=env or ENV,
                            capture_output=True, text=True, timeout=15)
    assert (result.returncode == 0) == succeeds, (args, result.stdout, result.stderr)
    return result.stdout.strip()


def secondary_environment(name):
    digest = hashlib.sha256(ENV['HYPRLAND_INSTANCE_SIGNATURE'].encode()).hexdigest()[:8]
    return ENV | {'CORNICE_DESKTOP_NAME': name,
                  'CORNICE_SHELL_SOCKET': str(RT / ('cs-' + digest + '-' + name + '.sock'))}


def observer():
    return json.loads(invoke('ipc', 'desktopObserver', 'status'))


def identities():
    return {name: json.loads(invoke('ipc', 'shell', 'runtimeIdentity', env=environment))
            for name, environment in [('main', ENV), ('desktop2', secondary_environment('desktop2'))]}


def wait_identity(expected):
    def probe():
        assert primary_shell.poll() is None
        try:
            return identities() == expected
        except (AssertionError, ValueError, subprocess.SubprocessError):
            return False
    return wait(probe)


def assert_processes_unchanged():
    for process in (compositor, broker, primary_shell, human_client):
        assert process.poll() is None, process.args
    assert {layer['pid'] for rows in ctl('layers', True)[cli('state', 'desktop2')['output']]['levels'].values() for layer in rows if layer['namespace'] == 'cornice-bar'} == {secondary_pid}
    assert pathlib.Path(f'/proc/{secondary_pid}').exists()
    assert ((BASE / 'human.txt').read_text() if (BASE / 'human.txt').exists() else None) == baseline_text
    assert human_state() == baseline_human


try:
    # Cold migration is verified with the real supervisor in the separate suite.
    # Both soft-update snapshots use the same modern, bounded native transport.
    first = prepare(CANDIDATE_PRODUCT)
    candidate = prepare(CANDIDATE_PRODUCT)
    harness.PRODUCT = PRODUCT = first / 'cornice'
    ENV.update(CORNICE_PATH=str(PRODUCT), QML_IMPORT_PATH=str(PRODUCT / 'native/qml'),
               QS_DISABLE_FILE_WATCHER='1', QS_NO_RELOAD_POPUP='1')
    broker = initialize()
    compositor = next(process for process in PROCESSES if pathlib.Path(process.args[0]).name == 'Hyprland')
    settings = BASE / 'config/cornice/config.json'
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text(json.dumps({'agentDesktop': {'enabled': True}, 'background': {'enabled': False},
        'weather': {'intervalMinutes': 0}, 'idle': {'lock': 0, 'screenOffAc': 0, 'screenOffBattery': 0,
        'dimAc': 0, 'dimBattery': 0, 'lockOnSleep': False, 'lockOnLockSignal': False, 'lockOnLidClose': False}}))
    # Keep the same existing config path for the updater, as in a real trial.
    (first / 'config-home/cornice/config.json').write_bytes(settings.read_bytes())
    ENV['XDG_CONFIG_HOME'] = str(first / 'config-home')
    human_client = start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py',
                          'human-window', BASE / 'human.txt'], 'human')
    wait(lambda: any(window['title'] == 'human-window' for window in ctl('clients', True)))
    primary_shell = start([str(PRODUCT / 'bin/cornice-qs'), '-p', str(PRODUCT / 'shell')], 'cornice')
    wait(lambda: invoke('ipc', 'shell', 'ping'))
    wait(lambda: any(row['name'] == 'desktop2' for row in cli('list')['desktops']))
    wait(lambda: cli('state', 'desktop2')['available'])
    secondary_pid = wait(lambda: next((layer['pid'] for rows in ctl('layers', True)[cli('state', 'desktop2')['output']]['levels'].values() for layer in rows if layer['namespace'] == 'cornice-bar'), None))
    wait(lambda: invoke('ipc', 'shell', 'ping', env=secondary_environment('desktop2')))
    baseline_human = human_state()
    baseline_text = (BASE / 'human.txt').read_text() if (BASE / 'human.txt').exists() else None
    trial_module = importlib.machinery.SourceFileLoader('cornice_trial_ui_test', str(TRIAL)).load_module()
    TRIAL_STATE.mkdir(parents=True, exist_ok=True)
    current = {'pid': os.getpid(), 'processStart': trial_module.start_identity(os.getpid()),
               'release': str(first), 'run': str(BASE / 'session-run'), 'status': 'ready',
               'compositorPid': compositor.pid, 'brokerPid': broker.pid, 'shellPid': primary_shell.pid,
               'instance': ENV['HYPRLAND_INSTANCE_SIGNATURE'], 'display': ENV['WAYLAND_DISPLAY']}
    (TRIAL_STATE / 'current.json').write_text(json.dumps(current))
    TRIAL_ENV.update(HYPRLAND_INSTANCE_SIGNATURE=ENV['HYPRLAND_INSTANCE_SIGNATURE'],
                     WAYLAND_DISPLAY=ENV['WAYLAND_DISPLAY'], XDG_RUNTIME_DIR=str(RT),
                     DBUS_SESSION_BUS_ADDRESS=ENV['DBUS_SESSION_BUS_ADDRESS'])

    original_manifest = (first / 'manifest.json').read_bytes()
    original_identity = identities()
    invoke('reload-ui')
    wait_identity(original_identity)
    assert (first / 'manifest.json').read_bytes() == original_manifest
    assert_processes_unchanged()
    record('modern reload-ui preserves compiled UI identity, services, and client focus')

    invoke('ipc', 'desktop', 'observe', 'desktop2')
    wait(lambda: observer()['presentation'].get('active'))
    invoke('ipc', 'desktopObserver', 'takeover', 'true')
    wait(lambda: observer()['humanControl'])
    trial('update-ui', '--release', candidate, succeeds=False)
    assert not (first / 'cornice/shell').is_symlink()
    assert (first / 'manifest.json').read_bytes() == original_manifest
    assert observer()['humanControl'] and observer()['presentation'].get('active')
    invoke('ipc', 'desktopObserver', 'takeover', 'false')
    wait(lambda: not observer()['humanControl'])
    invoke('ipc', 'desktop', 'observe', 'main')
    wait(lambda: not observer()['open'])
    wait(lambda: human_state() == baseline_human)
    record('an active native takeover rejects updates before any pointer, plugin, or presentation mutation')

    result = trial('update-ui', '--release', candidate)
    identity = identities()
    expected_id = json.loads((candidate / 'manifest.json').read_text())['id']
    assert all(row['uiBuildId'] == expected_id for row in identity.values()), identity
    assert (first / 'cornice/shell').is_symlink()
    assert (first / 'cornice/shell').resolve() == candidate / 'cornice/shell'
    assert_processes_unchanged()
    wait(lambda: json.loads(invoke('ipc', 'desktopCooperation', 'status'))['visible'] is False)
    subprocess.run(['grim', '-o', 'human', str(BASE / 'updated-ui.png')], env=ENV, check=True, timeout=4)
    record('soft update reaches the new actual QML build on both original shell PIDs while native apps and human focus survive')

    bad = prepare(CANDIDATE_PRODUCT)
    root_qml = bad / 'cornice/shell/shell.qml'
    root_qml.write_text(root_qml.read_text() + '\ninvalid qml {\n')
    manifest = json.loads((bad / 'manifest.json').read_text())
    manifest['hashes']['cornice/shell/shell.qml'] = hashlib.sha256(root_qml.read_bytes()).hexdigest()
    (bad / 'manifest.json').write_text(json.dumps(manifest))
    before_manifest = (first / 'manifest.json').read_bytes()
    trial('update-ui', '--release', bad, succeeds=False)
    assert identities() == identity
    assert (first / 'cornice/shell').resolve() == candidate / 'cornice/shell'
    assert (first / 'manifest.json').read_bytes() == before_manifest
    assert_processes_unchanged()
    record('a genuine QML parser failure restores the prior UI pointer and manifest and leaves both original shell processes alive')

    trial('rollback-ui')
    assert not (first / 'cornice/shell').is_symlink()
    assert (first / 'manifest.json').read_bytes() == original_manifest
    assert identities() == original_identity
    invoke('ipc', 'shell', 'ping')
    invoke('ipc', 'shell', 'ping', env=secondary_environment('desktop2'))
    assert_processes_unchanged()
    record('explicit rollback restores the actual original UI build on both original shell PIDs')
except Exception:
    diagnostics = {}
    for label, arguments in [('observer', ('ipc', 'desktopObserver', 'status')),
                             ('desktop', ('ipc', 'desktop', 'status')),
                             ('desktops', ('desktop', 'list')),
                             ('windows', ('ipc', 'shell', 'windows'))]:
        try:
            diagnostics[label] = invoke(*arguments)
        except Exception as error:
            diagnostics[label] = str(error)
    (BASE / 'soft-failure-diagnostics.json').write_text(json.dumps(diagnostics, indent=2))
    raise
finally:
    cleanup()
