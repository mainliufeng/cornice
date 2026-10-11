#!/usr/bin/python3
"""Real selection files/CLI and supervisor exit logic, confined to private /tmp.

Lifecycle execute callbacks below are test doubles; no compositor, GPU, desktop
socket, user manager, or physical session is started or controlled by this suite.
"""
import contextlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / 'bin/cornice-session-trial'
loader = importlib.machinery.SourceFileLoader('cornice_selection', str(CLI))
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)


@contextlib.contextmanager
def fixture():
    with tempfile.TemporaryDirectory(prefix='cornice-selection-', dir='/tmp') as directory:
        base = Path(directory)
        env = dict(os.environ, HOME=str(base / 'home'), ZDOTDIR=str(base / 'profile'),
                   CORNICE_TRIAL_STATE_DIR=str(base / 'state'), CORNICE_TEST_SANDBOX='1',
                   XDG_RUNTIME_DIR=str(base / 'runtime'), PYTHONDONTWRITEBYTECODE='1')
        for key in ('WAYLAND_DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE', 'DISPLAY'):
            env.pop(key, None)
        for name in ('home', 'profile', 'state', 'runtime'):
            (base / name).mkdir()
        profile = base / 'profile/.zprofile'
        profile.write_text('# original user configuration\nexport USER_SETTING="preserved"\n')
        stable = base / 'stable-file'
        stable.write_text('unchanged stable baseline')
        releases = []
        for name in ('a', 'b'):
            release = base / 'state/releases' / name
            release.mkdir(parents=True)
            (release / 'cornice').mkdir()
            for filename, content in (('runner', CLI.read_text()), ('Hyprland', '# test fixture; never executed'),
                                      ('hyprland.lua', '-- unit'), ('autostart.json', '[]')):
                (release / filename).write_text(content)
            m.atomic(release / 'manifest.json', {'id': name, 'release': str(release), 'product': str(release / 'cornice'),
                'loginSelectionSchema': 1, 'hashes': {name: m.digest(release / name) for name in ('runner', 'Hyprland', 'hyprland.lua', 'autostart.json')},
                'stable': {'hashes': {str(stable): m.digest(stable)}}})
            releases.append(release)
        previous = m.STATE
        m.STATE = base / 'state'
        try:
            with patch.dict(os.environ, env, clear=True):
                yield base, env, profile, releases
        finally:
            m.STATE = previous


def cli(env, *args, succeeds=True):
    result = subprocess.run([sys.executable, str(CLI), *map(str, args)], env=env,
                            capture_output=True, text=True, timeout=8)
    assert (result.returncode == 0) == succeeds, (args, result.stdout, result.stderr)
    return result.stdout


def choose(env, release):
    cli(env, 'select', '--release', release)
    return m.selection()


def login_with(callback):
    # Actual login/select/verify/cleanup control flow, with only compositor
    # execution substituted. Restore signal handlers altered by real login().
    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
    try:
        with patch.object(m.Trial, 'execute', callback):
            m.login()
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


def normal(trial):
    trial.mark_ready()
    trial.update('exited')


with fixture() as (base, env, profile, releases):
    original = profile.read_text()
    cli(env, 'arm', succeeds=False)  # Missing prepared pointer fails before profile mutation.
    assert profile.read_text() == original
    choose(env, releases[0])
    assert profile.read_text().startswith(original) and profile.read_text().count(m.HOOK_BEGIN) == 1
    assert m.read(m.STATE / 'login-profile-backup.json')['contents'] == original
    subprocess.run(['/usr/bin/zsh', '--login', '-c', 'test "$USER_SETTING" = preserved'], env=env, check=True, timeout=5)
    assert not (m.STATE / 'runs').exists(), 'ordinary login shell entered a desktop session'
    assert m.next_login()[1] == {'mode': 'persistent', 'release': str(releases[0])}
    entered = []
    def execute(trial):
        entered.append(trial.ticket)
        normal(trial)
    login_with(execute)
    login_with(execute)
    assert [ticket['release'] for ticket in entered] == [str(releases[0])] * 2
    assert all(ticket['persistent'] for ticket in entered)
    assert m.selection() is not None and not (m.STATE / 'selection-launch.json').exists()
    print('PASS: real select CLI preserves profile; two successful logout/login cycles retain the selected release')

with fixture() as (base, env, profile, releases):
    choose(env, releases[0])
    def finished_but_diagnostic_failed(trial):
        normal(trial)
        raise OSError('diagnostic failed after normal compositor exit')
    login_with(finished_but_diagnostic_failed)
    assert m.selection() is not None and m.next_login()[1]['mode'] == 'persistent'
    print('PASS: post-exit diagnostic errors cannot revoke a normally ended selected session')

with fixture() as (base, env, profile, releases):
    m.atomic(m.STATE / 'prepared.json', {'release': str(releases[1])})
    cli(env, 'arm')
    choose(env, releases[0])
    assert not (m.STATE / 'pending.json').exists()
    cli(env, 'arm')
    assert m.next_login()[1] == {'mode': 'trial', 'release': str(releases[1])}
    entered = []
    def execute(trial):
        entered.append(trial.ticket)
        normal(trial)
    login_with(execute)
    assert not (m.STATE / 'pending.json').exists() and m.selection()['release'] == str(releases[0])
    assert m.next_login()[1]['mode'] == 'persistent'
    login_with(execute)
    assert [ticket['release'] for ticket in entered] == [str(releases[1]), str(releases[0])]
    assert [ticket['persistent'] for ticket in entered] == [False, True]
    print('PASS: newest select cancels old ticket; later arm runs once with priority then persistent selection resumes')

with fixture() as (base, env, profile, releases):
    choose(env, releases[0])
    manifest = m.read(releases[1] / 'manifest.json'); manifest.pop('loginSelectionSchema')
    m.atomic(releases[1] / 'manifest.json', manifest)
    m.atomic(m.STATE / 'prepared.json', {'release': str(releases[1])})
    cli(env, 'arm')
    assert str(releases[0] / 'runner') in profile.read_text() and str(releases[1] / 'runner') not in profile.read_text()
    with m.locked(): ticket = m.login_ticket()
    trial = m.Trial(ticket)
    with patch.object(trial, 'start', side_effect=RuntimeError('stop before any process')):
        try:
            trial.execute()
            raise AssertionError('fixture unexpectedly started')
        except RuntimeError as error:
            assert str(error) == 'stop before any process'
    generated = (trial.directory / 'hyprland.lua').read_text()
    assert str(CLI) in generated and str(releases[1] / 'runner') not in generated
    print('PASS: an older one-shot release uses the persistent control runner for login and explicit rollback hotkeys')

with fixture() as (base, env, profile, releases):
    choose(env, releases[0])
    m.atomic(m.STATE / 'pending.json', {'release': str(releases[1]), 'startupSeconds': 60})
    run = base / 'run'; run.mkdir()
    m.atomic(m.STATE / 'current.json', {'pid': os.getpid(), 'processStart': m.start_identity(os.getpid()), 'status': 'ready', 'run': str(run)})
    cli(env, 'rollback')
    assert (run / 'rollback').is_file() and m.selection() is None
    assert not (m.STATE / 'pending.json').exists() and m.next_login()[1]['mode'] == 'stable'
    print('PASS: explicit rollback marks only the private owned session and clears both future login choices')

with fixture() as (base, env, profile, releases):
    original = profile.read_text()
    choose(env, releases[0])
    cli(env, 'cancel')
    assert m.selection() is None and m.next_login()[1]['mode'] == 'stable'
    choose(env, releases[1])
    profile.write_text(profile.read_text() + '# user edit after hook installation\n')
    cli(env, 'remove-hook')
    assert profile.read_text() == original + '# user edit after hook installation\n'
    assert m.selection() is None
    print('PASS: cancel selects stable; remove-hook preserves original and subsequent user profile edits')

for malformed in ('{broken', '[]', '{"schema":1}', '{"schema":1,"id":"' + 'a'*32 + '","release":"/tmp/foreign","startupSeconds":60}'):
    with fixture() as (base, env, profile, releases):
        (m.STATE / 'selection.json').write_text(malformed)
        login_with(lambda trial: (_ for _ in ()).throw(AssertionError('malformed selection launched')))
        assert m.selection() is None and m.next_login()[1]['mode'] == 'stable'
        assert (m.STATE / 'selection-failure.json').is_file()
print('PASS: malformed JSON, shape, missing fields and foreign releases cannot repeatedly launch a selected session')

for marker in ('{broken', json.dumps({'selectionId': 'a'*32, 'pid': 987654321, 'processStart': None}), '[]'):
    with fixture() as (base, env, profile, releases):
        choose(env, releases[0])
        (m.STATE / 'selection-launch.json').write_text(marker)
        assert m.next_login()[1]['mode'] == 'stable'
        login_with(lambda trial: (_ for _ in ()).throw(AssertionError('malformed marker launched')))
        assert m.selection() is None and not (m.STATE / 'selection-launch.json').exists()
assert not m.is_running({'pid': 987654321, 'processStart': None})
print('PASS: malformed launch markers fail closed; a missing process identity is never a live supervisor')

with fixture() as (base, env, profile, releases):
    choose(env, releases[0])
    (releases[0] / 'hyprland.lua').write_text('-- changed after selection')
    login_with(lambda trial: (_ for _ in ()).throw(AssertionError('changed release launched')))
    assert m.selection() is None and m.next_login()[1]['mode'] == 'stable'
    assert m.read(m.STATE / 'current.json')['status'] == 'rolled-back'
    print('PASS: real immutable hash validation failure clears selected launch before any compositor execution')

with fixture() as (base, env, profile, releases):
    first = choose(env, releases[0])
    with m.locked(): ticket = m.login_ticket()
    second = choose(env, releases[1])
    m.finish_selection(ticket, False)
    assert m.selection()['id'] == second['id'] and not (m.STATE / 'selection-launch.json').exists()
    print('PASS: old failing session cleanup removes its own marker while retaining a newer selected generation')

with fixture() as (base, env, profile, releases):
    choose(env, releases[0])
    m.atomic(m.STATE / 'pending.json', {'release': str(releases[1]), 'startupSeconds': 60})
    login_with(lambda trial: (_ for _ in ()).throw(RuntimeError('one-shot fixture startup failure')))
    assert m.selection()['release'] == str(releases[0]) and m.next_login()[1]['mode'] == 'persistent'
    print('PASS: a failed one-shot launch never revokes a separately selected persistent release')

# Exercise real process signal delivery and stale identity with no compositor.
child_code = '''import importlib.machinery,importlib.util,time,sys
loader=importlib.machinery.SourceFileLoader("child_trial",sys.argv[1]);spec=importlib.util.spec_from_loader(loader.name,loader)
m=importlib.util.module_from_spec(spec);loader.exec_module(m)
def execute(trial):
 trial.mark_ready()
 while True:
  trial.check_request()
  time.sleep(.02)
m.Trial.execute=execute
m.login()
'''
for death in (signal.SIGTERM, signal.SIGHUP, signal.SIGKILL):
    with fixture() as (base, env, profile, releases):
        choose(env, releases[0])
        child = subprocess.Popen([sys.executable, '-c', child_code, str(CLI)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if child.poll() is not None: raise AssertionError(child.communicate())
                if (m.STATE / 'current.json').exists() and m.read(m.STATE / 'current.json').get('status') == 'ready': break
                time.sleep(.02)
            else: raise AssertionError('private signal fixture not ready')
            child.send_signal(death)
            child.communicate(timeout=8)
            if death == signal.SIGKILL:
                assert m.selection() is not None and m.next_login()[1]['mode'] == 'stable'
                login_with(lambda trial: (_ for _ in ()).throw(AssertionError('stale crashed session relaunched')))
                assert m.selection() is None and not (m.STATE / 'selection-launch.json').exists()
            else:
                assert child.returncode == 0 and m.selection() is not None
                assert m.next_login()[1]['mode'] == 'persistent' and not (m.STATE / 'selection-launch.json').exists()
        finally:
            if child.poll() is None:
                child.kill(); child.communicate(timeout=3)
print('PASS: actual private SIGTERM/HUP preserve selection after ready; SIGKILL marker selects stable at the next login')

with fixture() as (base, env, profile, releases):
    manifest = m.read(releases[0] / 'manifest.json'); manifest.pop('loginSelectionSchema')
    m.atomic(releases[0] / 'manifest.json', manifest)
    original = profile.read_text()
    cli(env, 'select', '--release', releases[0], succeeds=False)
    assert m.selection() is None and profile.read_text() == original
    print('PASS: old one-shot-only snapshots cannot claim persistent selection support')
print('Selection unit checks passed; graphical session acceptance was not run.')
