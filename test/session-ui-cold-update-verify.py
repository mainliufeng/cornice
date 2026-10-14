"""Actual SDDM-shaped login and owner-managed cold UI migration in a private session."""
import desktop_harness as harness
from desktop_harness import *
import struct
import shutil
import threading

assert os.environ.get('CORNICE_TEST_SANDBOX') == '1'
BASELINE_PRODUCT = pathlib.Path(os.environ['CORNICE_TEST_UI_BASELINE'])
CANDIDATE_PRODUCT = PRODUCT
TRIAL = ROOT / 'bin/cornice-session-trial'
TEST_ENV = None
login = None


def trial(*args, succeeds=True, timeout=120):
    result = subprocess.run([str(TRIAL), *map(str, args)], env=TEST_ENV,
                            capture_output=True, text=True, timeout=timeout)
    (BASE / ('trial-' + str(time.monotonic_ns()) + '.json')).write_text(json.dumps({
        'arguments': list(map(str, args)), 'exit': result.returncode,
        'stdout': result.stdout, 'stderr': result.stderr}))
    assert (result.returncode == 0) == succeeds, (args, result.stdout, result.stderr)
    return result


def status():
    return json.loads(trial('status', timeout=15).stdout)


def prepare(source):
    return pathlib.Path(json.loads(trial('prepare', '--hyprland', os.environ['CORNICE_TEST_HYPRLAND'],
                                        '--cornice', source, '--config', configuration).stdout)['prepared'])


def rewrite_release_file(release, relative, contents):
    path = release / relative
    path.write_text(contents)
    manifest = json.loads((release / 'manifest.json').read_text())
    manifest['hashes'][relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    (release / 'manifest.json').write_text(json.dumps(manifest))


def invoke(*args, desktop='', succeeds=True):
    environment = ENV.copy()
    if desktop:
        environment['CORNICE_DESKTOP_NAME'] = desktop
    else:
        environment.pop('CORNICE_DESKTOP_NAME', None)
    result = subprocess.run([str(CANDIDATE_PRODUCT / 'bin/cornice'), *map(str, args)],
                            env=environment, capture_output=True, text=True, timeout=15)
    assert (result.returncode == 0) == succeeds, (args, result.stdout, result.stderr)
    return result.stdout.strip()


def desktops():
    return json.loads(invoke('desktop', 'list'))['desktops']


def observer():
    return json.loads(invoke('ipc', 'desktopObserver', 'status'))


def start_identity(pid):
    try:
        return pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def peers():
    digest = hashlib.sha256(ENV['HYPRLAND_INSTANCE_SIGNATURE'].encode()).hexdigest()[:8]
    result = {}
    for name in ('', 'desktop2'):
        path = RT / (f'cs-{digest}-{name}.sock' if name else f"cornice-{ENV['USER']}.sock")
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(2); connection.connect(str(path))
            pid, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        assert uid == os.getuid() and start_identity(pid), (name, pid, uid)
        result[name or 'main'] = {'pid': pid, 'processStart': start_identity(pid)}
    return result


def platform_maps(pid):
    paths = set()
    for line in pathlib.Path(f'/proc/{pid}/maps').read_text().splitlines():
        if 'libcornice_platform.so' in line:
            path = line.split(None, 5)[5]
            assert not path.endswith(' (deleted)'), path
            paths.add(path)
    assert paths, (pid, 'Platform module was not actually loaded')
    return {path: hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() for path in paths}


def scene():
    return {'windows': sorted((window['address'], window['pid'], window['title'], window['workspace']['name'],
                               tuple(window['at']), tuple(window['size']), window['monitor'], window['fullscreen'])
                             for window in ctl('clients', True)),
            'desktops': {item['name']: {'workspace': item['workspaceName'], 'windows': item['retainedWindowCount'],
                                      'seatId': item['seatId'], 'stableId': item['stableId'],
                                      'windowAddress': item['windowAddress'], 'cursor': item['cursor']}
                         for item in desktops()},
            'primary': {'workspace': ctl('activeworkspace', True)['name'],
                        'window': ctl('activewindow', True).get('address')},
            'text': {name: (BASE / (name + '.txt')).read_text() if (BASE / (name + '.txt')).exists() else None
                     for name in ('human', 'secondary')}}


def seed_text(name, title, output, text):
    if name == 'main': invoke('desktop', 'allow-agent', name, 'on')
    invoke('desktop', 'resume', name)
    binding = BASE / (name + '-seed.binding')
    invoke('desktop', 'bind', name, binding)
    def action(method, params):
        return json.loads(invoke('desktop', 'tool', binding, 'desktop.' + method, json.dumps(params)))
    state = json.loads(invoke('desktop', 'state', name))
    window = next(item for item in ctl('clients', True) if item['title'] == title)
    geometry = json.loads((BASE / (output + '.geometry')).read_text())['entry']
    frame = action('capture', {})
    action('input', {'frameId': frame['frameId'], 'action': 'click',
                    'x': round(window['at'][0] - state['position'][0] + geometry[0] + 30),
                    'y': round(window['at'][1] - state['position'][1] + geometry[1] + geometry[3] / 2)})
    frame = action('capture', {})
    action('input', {'frameId': frame['frameId'], 'action': 'text', 'text': text})
    wait(lambda: (BASE / (output + '.txt')).exists() and (BASE / (output + '.txt')).read_text() == text)
    invoke('desktop', 'pause', name)
    if name == 'main': invoke('desktop', 'allow-agent', name, 'off')


def payload():
    return {'manifest': (first / 'manifest.json').read_bytes().hex(),
            'shell': [(first / 'cornice/shell').stat().st_dev, (first / 'cornice/shell').stat().st_ino],
            'platform': [(first / 'cornice/native/qml/Cornice/Platform').stat().st_dev,
                         (first / 'cornice/native/qml/Cornice/Platform').stat().st_ino],
            'overlay': (TRIAL_STATE / 'ui-overlay.json').read_bytes().hex()
                       if (TRIAL_STATE / 'ui-overlay.json').exists() else None}


def assert_native_processes():
    current = status()['current']
    assert login.poll() is None
    for key, proof in native.items():
        assert current[key] == proof['pid'] and start_identity(proof['pid']) == proof['processStart'], (key, current, native)
    for pid, identity in application_pids.items():
        assert start_identity(pid) == identity, ('application exited or PID reused', pid)


def assert_native_and_apps():
    assert_native_processes()
    actual = scene()
    assert actual == original_scene, (actual, original_scene)


def idle():
    values = desktops()
    return len(values) == 2 and all(item['occupied'] is False and item['paused'] is True
                                   and item['presentation']['active'] is False for item in values)


def visual_health():
    current = status()['current']
    if current['status'] != 'ready' or current.get('healthFailures', 0) or current.get('degraded'):
        return None
    actual = peers(); layers = ctl('layers', True); views = {}
    for desktop in desktops():
        name = desktop['name']; ui_name = 'main' if desktop['primary'] else name
        bars = [layer for rows in layers.get(desktop['output'], {}).get('levels', {}).values() for layer in rows
                if layer['namespace'] == 'cornice-bar' and layer['alpha'] > 0 and layer['w'] > 24 and layer['h'] > 8]
        if len(bars) != 1 or bars[0]['pid'] != actual[ui_name]['pid']:
            return None
        geometry = json.loads(invoke('ipc', 'bar', 'geometry', desktop='' if desktop['primary'] else name))
        if not any(item['width'] > 0 and item['height'] > 0 for item in geometry):
            return None
        views[name] = {'output': desktop['output'], 'display': desktop['display'], 'bar': bars[0], 'geometry': geometry}
    return {'peers': actual, 'views': views}


def wait_visual_health():
    def probe():
        try: return visual_health()
        except (OSError, AssertionError, ValueError, subprocess.SubprocessError): return None
    return wait(probe, 40)


def save_views(label):
    evidence = wait_visual_health()
    for name, view in evidence['views'].items():
        path = BASE / (label + '-' + name + '.png')
        subprocess.run(['grim', '-o', view['output'], str(path)], env=ENV | {'WAYLAND_DISPLAY': view['display']}, check=True, timeout=5)
        assert path.stat().st_size > 1024 and path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), path
        view['screenshot'] = str(path)
    (BASE / (label + '-views.json')).write_text(json.dumps(evidence, indent=2))
    return evidence


def verify_generation(expected, platform_hash):
    actual = wait_visual_health()['peers']
    for name, peer in actual.items():
        identity = json.loads(invoke('ipc', 'shell', 'runtimeIdentity', desktop='' if name == 'main' else name))
        assert identity['uiBuildId'] == expected, (name, identity, expected)
        assert set(platform_maps(peer['pid']).values()) == {platform_hash}, (name, platform_maps(peer['pid']))
    assert_native_and_apps()
    return actual


def budget_window():
    # Production crash recovery remains bounded. Wait out its real 60-second
    # window between independent maintenance/failure scenarios, never edit it.
    stable = wait_visual_health()['peers']
    deadline = time.monotonic() + 62
    while time.monotonic() < deadline:
        assert_native_and_apps()
        healthy = visual_health()
        assert healthy and healthy['peers'] == stable, ('UI recovery did not settle', healthy, stable)
        time.sleep(1)


class Reservation:
    def __init__(self):
        self.connection = socket.socket(socket.AF_UNIX); self.connection.settimeout(5)
        self.connection.connect(str(broker_socket()))
        self.lock = threading.RLock(); self.buffer = b''; self.stopped = threading.Event(); self.errors = []
        self.controller = 'cold-ui-regression'
        self.binding = self.request('acquire-desktop', {'preferredDesktop': 'desktop2', 'harness': 'codex', 'controller': self.controller})
        self.thread = threading.Thread(target=self.heartbeat, daemon=True); self.thread.start()
    def request(self, method, params):
        with self.lock:
            identity = str(time.monotonic_ns()); value = {'id': identity, 'method': method, 'params': params}
            if hasattr(self, 'binding'): value.update(controller=self.controller, token=self.binding['taskToken'])
            self.connection.sendall((json.dumps(value) + '\n').encode())
            while True:
                while b'\n' not in self.buffer:
                    chunk = self.connection.recv(65536); assert chunk, 'reservation socket closed'; self.buffer += chunk
                line, self.buffer = self.buffer.split(b'\n', 1); reply = json.loads(line)
                if reply.get('id') != identity: continue
                assert reply['ok'], reply
                return reply['result']
    def heartbeat(self):
        while not self.stopped.wait(1):
            try: self.request('desktop.handoff', {'action': 'status'})
            except Exception as error: self.errors.append(str(error)); return
    def close(self):
        self.stopped.set(); self.thread.join(timeout=6); self.connection.close(); assert not self.errors, self.errors


try:
    # A separate actual compositor guards the existing scene; only its private
    # parent display is shared with the genuine login trial below.
    sentinel = initialize(xwayland=True)
    cli('remove', 'desktop2')
    sentinel_env = ENV.copy(); sentinel_scene = human_state()
    TEST_ENV = ENV.copy()
    TEST_ENV.pop('HYPRLAND_INSTANCE_SIGNATURE'); TEST_ENV.pop('DISPLAY', None)
    TRIAL_STATE = BASE / 'cold-trial'
    TEST_ENV.update(WAYLAND_DISPLAY='parent', XDG_STATE_HOME=str(BASE / 'trial-user-state'),
                    CORNICE_TRIAL_STATE_DIR=str(TRIAL_STATE), ZDOTDIR=str(BASE / 'zsh'))
    profile = pathlib.Path(TEST_ENV['ZDOTDIR']) / '.zprofile'; profile.parent.mkdir()
    profile_original = '# Preserve the existing login profile\nexport CORNICE_TEST_PROFILE="original"\n'
    profile.write_text(profile_original)
    settings = BASE / 'config/cornice/config.json'; settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text(json.dumps({'agentDesktop': {'enabled': True}, 'background': {'enabled': False},
        'weather': {'intervalMinutes': 0}, 'idle': {'lock': 0, 'screenOffAc': 0, 'screenOffBattery': 0,
        'dimAc': 0, 'dimBattery': 0, 'lockOnSleep': False, 'lockOnLockSignal': False, 'lockOnLidClose': False}}))
    configuration = BASE / 'cold-session.lua'
    configuration.write_text('hl.monitor({output="",mode="1280x800",position="auto",scale=1})\n'
                            'hl.on("hyprland.start",function() hl.exec_cmd("/usr/bin/hyprctl output create headless trial") end)\n'
                            'hl.config({animations={enabled=false},xwayland={enabled=false},misc={disable_hyprland_logo=true,disable_splash_rendering=true,force_default_wallpaper=0}})\n')
    sddm = BASE / 'wayland-session'; sddm.write_text('print -r -- "stable fallback"\n')
    first = prepare(BASELINE_PRODUCT)
    # prepare always stages its invoking maintenance implementation. Replace
    # only this private snapshot's runner with the actual deployed legacy code.
    legacy_runner = BASELINE_PRODUCT.parent / 'runner'
    legacy_hash = hashlib.sha256(legacy_runner.read_bytes()).hexdigest()
    assert json.loads((BASELINE_PRODUCT.parent / 'manifest.json').read_text())['hashes']['runner'] == legacy_hash
    shutil.copy2(legacy_runner, first / 'runner')
    manifest = json.loads((first / 'manifest.json').read_text())
    manifest['hashes']['runner'] = legacy_hash
    (first / 'manifest.json').write_text(json.dumps(manifest))
    trial('arm', '--startup-seconds', '60')
    assert profile.read_text().startswith(profile_original)
    login = start(['/usr/bin/zsh', '--login', str(sddm), '/usr/bin/start-hyprland'], 'cold-login', TEST_ENV)
    def ready():
        info = status().get('current')
        assert login.poll() is None, ('real login exited before readiness', info)
        return info if info and info['status'] == 'ready' else None
    info = wait(ready, 75)
    assert info['pid'] == login.pid and not status()['armed'], info
    assert str(first / 'runner').encode() in pathlib.Path(f'/proc/{login.pid}/cmdline').read_bytes().split(b'\0')
    assert hashlib.sha256((first / 'runner').read_bytes()).hexdigest() == legacy_hash
    (BASE / 'cold-legacy-runner.json').write_text(json.dumps({'source': str(legacy_runner), 'sha256': legacy_hash, 'supervisorPid': login.pid, 'commandLine': pathlib.Path(f'/proc/{login.pid}/cmdline').read_bytes().decode().split('\0')}, indent=2))
    native = {key: {'pid': info[key], 'processStart': start_identity(info[key])}
              for key in ('pid', 'compositorPid', 'brokerPid')}
    ENV.update(TEST_ENV, HYPRLAND_INSTANCE_SIGNATURE=info['instance'], WAYLAND_DISPLAY=info['display'],
               CORNICE_PATH=str(first / 'cornice'), XDG_CONFIG_HOME=str(first / 'config-home'),
               QML_IMPORT_PATH=str(first / 'cornice/native/qml'))
    harness.PRODUCT = PRODUCT = first / 'cornice'
    wait(idle, 20)
    primary = start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', 'human-window', BASE / 'human.txt'], 'cold-human', ENV)
    invoke('desktop', 'resume', 'desktop2')
    invoke('desktop', 'launch', 'desktop2', '--', '/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', 'secondary-window', BASE / 'secondary.txt')
    wait(lambda: len(ctl('clients', True)) == 2)
    invoke('desktop', 'pause', 'desktop2'); wait(idle)
    seed_text('main', 'human-window', 'human', 'cold-primary-preserved')
    seed_text('desktop2', 'secondary-window', 'secondary', 'cold-secondary-preserved')
    wait(idle)
    application_pids = {window['pid']: start_identity(window['pid']) for window in ctl('clients', True)}
    OWNED_PIDS.extend(pid for pid in application_pids if pid != primary.pid)
    old_peers = wait_visual_health()['peers']
    original_scene = scene(); original_payload = payload()
    save_views('cold-before')
    old_platform_hash = hashlib.sha256((first / 'cornice/native/qml/Cornice/Platform/libcornice_platform.so').read_bytes()).hexdigest()
    for peer in old_peers.values(): assert set(platform_maps(peer['pid']).values()) == {old_platform_hash}
    candidate = prepare(CANDIDATE_PRODUCT)
    candidate_manifest = json.loads((candidate / 'manifest.json').read_text())
    new_platform_hash = hashlib.sha256((candidate / 'cornice/native/qml/Cornice/Platform/libcornice_platform.so').read_bytes()).hexdigest()
    assert new_platform_hash != old_platform_hash, 'This is a native Platform migration, not only another QML copy'
    result = json.loads(trial('update-ui', '--release', candidate, '--strategy', 'cold').stdout)
    assert result['strategy'] == 'cold' and result['uiReplaced'] and result['nativePidsUnchanged'], result
    migrated = verify_generation(candidate_manifest['id'], new_platform_hash)
    for name, peer in migrated.items(): assert peer['pid'] != old_peers[name]['pid'], (name, peer, old_peers)
    replaced = {item['name'] or 'main': item for item in result['uiReplacements']}
    assert set(replaced) == set(old_peers)
    assert all(replaced[name]['previousPid'] == old_peers[name]['pid'] and replaced[name]['pid'] == migrated[name]['pid'] for name in migrated)
    (BASE / 'cold-success.json').write_text(json.dumps({'result': result, 'before': old_peers, 'after': migrated, 'native': native, 'scene': original_scene}, indent=2))
    save_views('cold-updated')
    record('real SDDM-hook Supervisor/Broker replace only both UI actors, actually load new Platform and UiBuild, and preserve native/app PID, window, workspace and input content')

    budget_window()
    trial('rollback-ui')
    wait(lambda: invoke('ipc', 'shell', 'ping') and invoke('ipc', 'shell', 'ping', desktop='desktop2'))
    assert payload()['manifest'] == original_payload['manifest']
    restored = wait_visual_health()['peers']
    for peer in restored.values(): assert set(platform_maps(peer['pid']).values()) == {old_platform_hash}
    assert_native_and_apps(); save_views('cold-rolled-back')
    record('explicit cold rollback restores the actual legacy UI and Platform through their real owners without losing apps or restarting native session processes')

    invoke('ipc', 'desktop', 'observe', 'desktop2'); wait(lambda: observer()['presentation'].get('active'))
    invoke('ipc', 'desktopObserver', 'takeover', 'true'); wait(lambda: observer()['humanControl'])
    before = payload(); before_peers = peers()
    rejected = trial('update-ui', '--release', candidate, '--strategy', 'cold', succeeds=False)
    assert 'presentation' in rejected.stderr.lower() or 'takeover' in rejected.stderr.lower(), rejected.stderr
    assert payload() == before and peers() == before_peers and observer()['humanControl']
    invoke('ipc', 'desktopObserver', 'takeover', 'false'); wait(lambda: not observer()['humanControl'])
    invoke('ipc', 'desktop', 'observe', 'main'); wait(lambda: not observer()['open'])
    invoke('desktop', 'pause', 'desktop2'); wait(idle)
    reservation = Reservation()
    try:
        wait(lambda: any(item['occupied'] for item in desktops()))
        before = payload(); before_peers = peers()
        rejected = trial('update-ui', '--release', candidate, '--strategy', 'cold', succeeds=False)
        assert 'unoccupied' in rejected.stderr.lower() or 'paused' in rejected.stderr.lower(), rejected.stderr
        assert payload() == before and peers() == before_peers
    finally: reservation.close()
    wait(idle); assert_native_and_apps()
    record('active native takeover and a real task reservation reject cold maintenance before UI/module/manifest changes or UI signaling')

    budget_window()
    bad = prepare(CANDIDATE_PRODUCT)
    qml = bad / 'cornice/shell/shell.qml'
    rewrite_release_file(bad, 'cornice/shell/shell.qml', qml.read_text() + '\ninvalid qml {\n')
    before = payload(); before_peers = peers()
    rejected = trial('update-ui', '--release', bad, '--strategy', 'cold', succeeds=False, timeout=150)
    assert 'preflight' in rejected.stderr.lower() and 'syntax' in rejected.stderr.lower(), rejected.stderr
    assert payload() == before and peers() == before_peers
    assert_native_and_apps()
    record('actual Qt syntax preflight rejects broken QML before signaling either legacy UI or changing its files, module and manifest')

    runtime_bad = prepare(CANDIDATE_PRODUCT)
    qml = runtime_bad / 'cornice/shell/shell.qml'
    contents = qml.read_text()
    assert contents.count('  id: shell\n') == 1
    rewrite_release_file(runtime_bad, 'cornice/shell/shell.qml', contents.replace('  id: shell\n',
        '  id: shell\n  Timer { interval: 0; running: true; onTriggered: Qt.quit() }\n', 1))
    before = payload(); before_peers = peers()
    failed = trial('update-ui', '--release', runtime_bad, '--strategy', 'cold', succeeds=False, timeout=150)
    assert 'UI update failed' in failed.stderr and 'preflight' not in failed.stderr.lower(), failed.stderr
    assert peers()['desktop2'] == before_peers['desktop2'], 'sequential legacy migration changed the unaffected secondary UI'
    # A UI failure must never be reclassified as a native Broker failure.
    # Check that invariant before probing its replacement UI/module readiness.
    assert_native_and_apps()
    wait(lambda: invoke('ipc', 'shell', 'ping') and invoke('ipc', 'shell', 'ping', desktop='desktop2'), 60)
    assert payload()['manifest'] == before['manifest']
    for peer in wait_visual_health()['peers'].values(): assert set(platform_maps(peer['pid']).values()) == {old_platform_hash}
    assert_native_and_apps(); save_views('cold-failure-restored')
    record('syntax-valid runtime QML exit restores working legacy UI and loaded Platform through the actual old supervisor; secondary UI, native processes and both applications survive')

    budget_window()
    retried = json.loads(trial('update-ui', '--release', candidate, '--strategy', 'cold').stdout)
    assert retried['uiReplaced'] and retried['nativePidsUnchanged']
    verify_generation(candidate_manifest['id'], new_platform_hash); save_views('cold-retried')
    record('a failed cold migration remains retryable through the real recovery owners after the normal crash-budget window')
    trial('rollback')
    login.wait(timeout=25); assert login.returncode == 0

    # A separate true login runs the new supervisor to verify its generic
    # secondary-UI health recovery, including alive IPC with an unmapped bar.
    first = prepare(CANDIDATE_PRODUCT)
    new_runner_hash = hashlib.sha256(TRIAL.read_bytes()).hexdigest()
    assert hashlib.sha256((first / 'runner').read_bytes()).hexdigest() == new_runner_hash != legacy_hash
    trial('arm', '--startup-seconds', '60')
    login = start(['/usr/bin/zsh', '--login', str(sddm), '/usr/bin/start-hyprland'], 'new-cold-login', TEST_ENV)
    info = wait(ready, 75)
    assert info['pid'] == login.pid and not status()['armed']
    assert str(first / 'runner').encode() in pathlib.Path(f'/proc/{login.pid}/cmdline').read_bytes().split(b'\0')
    native = {key: {'pid': info[key], 'processStart': start_identity(info[key])}
              for key in ('pid', 'compositorPid', 'brokerPid')}
    ENV.update(TEST_ENV, HYPRLAND_INSTANCE_SIGNATURE=info['instance'], WAYLAND_DISPLAY=info['display'],
               CORNICE_PATH=str(first / 'cornice'), XDG_CONFIG_HOME=str(first / 'config-home'),
               QML_IMPORT_PATH=str(first / 'cornice/native/qml'))
    harness.PRODUCT = PRODUCT = first / 'cornice'; wait(idle, 20)
    for name in ('human', 'secondary'):
        (BASE / (name + '.txt')).unlink(missing_ok=True)
        (BASE / (name + '.geometry')).unlink(missing_ok=True)
    primary = start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', 'human-window', BASE / 'human.txt'], 'new-cold-human', ENV)
    invoke('desktop', 'resume', 'desktop2')
    invoke('desktop', 'launch', 'desktop2', '--', '/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', 'secondary-window', BASE / 'secondary.txt')
    wait(lambda: len(ctl('clients', True)) == 2)
    invoke('desktop', 'pause', 'desktop2'); wait(idle)
    seed_text('main', 'human-window', 'human', 'cold-primary-preserved')
    seed_text('desktop2', 'secondary-window', 'secondary', 'cold-secondary-preserved'); wait(idle)
    application_pids = {window['pid']: start_identity(window['pid']) for window in ctl('clients', True)}
    OWNED_PIDS.extend(pid for pid in application_pids if pid != primary.pid)
    stable = wait_visual_health()['peers']; original_scene = scene()
    save_views('new-runner-before')
    bar = first / 'cornice/shell/plugins/bar/Bar.qml'
    original_bar = bar.read_text(); original_manifest = (first / 'manifest.json').read_bytes()
    assert original_bar.count('      visible: true\n') == 1
    rewrite_release_file(first, 'cornice/shell/plugins/bar/Bar.qml', original_bar.replace(
        '      visible: true\n', '      visible: !DesktopSession.agentShell\n', 1))
    invoke('reload-ui', desktop='desktop2')
    target = next(item for item in desktops() if item['name'] == 'desktop2')
    def missing_bar():
        assert_native_processes()
        layers = ctl('layers', True).get(target['output'], {}).get('levels', {})
        return not any(layer['namespace'] == 'cornice-bar' and layer['alpha'] > 0
                       for rows in layers.values() for layer in rows)
    wait(missing_bar, 20)
    assert peers() == stable, 'the actual missing-bar failure must precede owner recovery'
    assert invoke('ipc', 'shell', 'ping', desktop='desktop2').startswith('pong')
    subprocess.run(['grim', '-o', target['output'], str(BASE / 'new-runner-missing-bar.png')], env=ENV | {'WAYLAND_DISPLAY': target['display']}, check=True, timeout=5)
    def ui_replaced():
        assert_native_processes()
        try:
            actual = peers()
            assert actual['main'] == stable['main']
            return actual if actual['desktop2'] != stable['desktop2'] else None
        except OSError: return None
    replaced = wait(ui_replaced, 25)
    broken_status = status()['current']
    # The Supervisor, not this test, terminated the authenticated unresponsive
    # surface's actor. Restore its private source for the Broker's next startup.
    bar.write_text(original_bar); (first / 'manifest.json').write_bytes(original_manifest)
    recovered = wait_visual_health()['peers']
    assert recovered['main'] == stable['main'] and recovered['desktop2'] != stable['desktop2']
    assert_native_and_apps(); save_views('new-runner-recovered')
    (BASE / 'new-runner-ui-recovery.json').write_text(json.dumps({'runnerHash': new_runner_hash,
        'before': stable, 'firstReplacement': replaced, 'after': recovered,
        'native': native, 'failureStatus': broken_status, 'scene': original_scene}, indent=2))
    record('new actual supervisor repairs an alive secondary UI with a missing bar by replacing only that UI; main UI, Broker, compositor, applications, input content, focus, cursor and layout survive')
    budget_window()
    trial('rollback'); login.wait(timeout=25); assert login.returncode == 0
    ENV.clear(); ENV.update(sentinel_env)
    assert sentinel.poll() is None and human_state() == sentinel_scene
    record('test-only login ends through its public rollback and the pre-existing isolated sentinel scene remains untouched')
except Exception:
    try: (BASE / 'cold-failure-status.json').write_text(json.dumps(status(), indent=2))
    except Exception: pass
    raise
finally:
    if login and login.poll() is None:
        try: trial('rollback'); login.wait(timeout=25)
        except Exception: pass
    cleanup()
