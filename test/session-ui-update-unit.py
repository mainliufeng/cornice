#!/usr/bin/env python3
"""Atomic UI publication/recovery fixtures; the real compositor has a separate suite."""
import argparse
import contextlib
import importlib.machinery
import io
import json
import os
from pathlib import Path
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
trial = importlib.machinery.SourceFileLoader('cornice_ui_trial_unit', str(ROOT / 'bin/cornice-session-trial')).load_module()


class Fixture:
    def __init__(self, base):
        self.base = base
        self.old = self.release('old')
        self.new = self.release('new')
        self.info = {'release': str(self.old), 'pid': os.getpid(), 'processStart': trial.start_identity(os.getpid()),
                     'status': 'ready', 'shellPid': os.getpid(), 'compositorPid': os.getpid(), 'brokerPid': os.getpid(), 'instance': 'private-instance'}
        self.context = {'release': self.old, 'environment': {'HYPRLAND_INSTANCE_SIGNATURE': 'private-instance'}, 'info': self.info}
        trial.atomic(base / 'current.json', self.info)
        self.current_bytes = (base / 'current.json').read_bytes()
        self.original_manifest = (self.old / 'manifest.json').read_bytes()
        self.original_inode = trial.ui_identity(self.old / 'cornice/shell')
        self.active = False
        self.calls = []
        self.generations = {'': 'old', 'desktop2': 'old'}
        self.shells = [{'name': name, 'pid': os.getpid(), 'processStart': trial.start_identity(os.getpid()),
                        'beforeBuild': 'old', 'beforeTransport': 'qt-local-v1', 'beforePlatform': trial.ui_platform_id(self.old / 'cornice')} for name in ('', 'desktop2')]

    def release(self, name, legacy=False):
        release = self.base / 'releases' / name
        contents = {'Hyprland': 'native-compositor', 'cornice/bin/cornice-desktopd': 'broker-wrapper',
                    'cornice/bin/cornice-desktop': 'broker-cli', 'cornice/bin/cornice-agent-view': 'ui-helper',
                    'cornice/bin/cornice': 'test-cli',
                    'cornice/config/session-services.json': '{}',
                    'cornice/native/bin/cornice-desktop-runtime': 'broker-native',
                    'cornice/native/agent/desktop-endpoint.mjs': 'shared-native-endpoint',
                    'cornice/native/qml/Cornice/Desktop/module': 'native-qml-module',
                    'cornice/native/qml/Cornice/Platform/module': 'platform-native-module',
                    'cornice/shell/shell.qml': 'legacy root' if legacy else 'modern root',
                    'cornice/shell/plugins/runtime-control/Controller.qml': 'controller',
                    'cornice/shell/Commons/UiBuild.qml': 'unprepared'}
        for relative, contents in contents.items():
            file = release / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(contents)
        trial.ui_build(release / 'cornice/shell', name)
        self.rehash(release)
        return release

    def rehash(self, release):
        manifest = {'id': release.name, 'hashes': {str(p.relative_to(release)): trial.digest(p)
                    for p in release.rglob('*') if p.is_file() and p.name != 'manifest.json'}, 'stable': {'hashes': {}}}
        trial.atomic(release / 'manifest.json', manifest)

    def desktops(self, *_, cold=False):
        if self.active:
            raise RuntimeError('UI update refused during desktop presentation, takeover or lock')
        return [{'name': 'main', 'primary': True, 'paused': True, 'occupied': False},
                {'name': 'desktop2', 'primary': False, 'paused': True, 'occupied': False}]

    def cli(self, cli, context, name, *arguments):
        self.calls.append((name, arguments))
        if arguments == ('ping',):
            return 'pong test'
        if arguments[0] == 'reload-ui' and '--prepare' in arguments:
            return 'ready'
        if arguments[0] == 'reload-ui' or arguments == ('ipc', 'shell', 'call', 'cn.runtime-control', 'reload', '{}'):
            root = self.old / 'cornice/shell/shell.qml'
            if 'invalid' not in root.read_text():
                self.generations[name] = None if root.read_text() == 'legacy root' else json.loads(
                    (self.old / 'cornice/shell/Commons/UiBuild.qml').read_text().split('id: ', 1)[1].split(';', 1)[0])
            return 'requested'
        raise AssertionError(arguments)

    def runtime(self, cli, context, name):
        if self.generations[name] is None:
            raise RuntimeError('cornice: unknown method: shell.runtimeIdentity')
        return {'uiBuildId': self.generations[name], 'platformBuildId': trial.ui_platform_id(self.old / 'cornice'), 'ipcTransport': 'qt-local-v1', 'pid': os.getpid(), 'desktop': name or 'main', 'instance': 'private-instance'}

    def update(self, release=None, strategy='soft'):
        with contextlib.redirect_stdout(io.StringIO()):
            trial.update_ui(argparse.Namespace(release=str(release or self.new), strategy=strategy))

    def rollback(self):
        with contextlib.redirect_stdout(io.StringIO()):
            trial.rollback_ui(argparse.Namespace())

    def unchanged(self):
        assert trial.ui_identity(self.old / 'cornice/shell') == self.original_inode
        assert (self.old / 'manifest.json').read_bytes() == self.original_manifest
        assert (self.base / 'current.json').read_bytes() == self.current_bytes


@contextlib.contextmanager
def fixture():
    with tempfile.TemporaryDirectory(prefix='cornice-ui-update-unit-', dir='/tmp') as temporary:
        base = Path(temporary)
        with patch.object(trial, 'STATE', base):
            f = Fixture(base)
            wait = trial.ui_wait
            with patch.object(trial, 'ui_context', return_value=f.context), \
                 patch.object(trial, 'ui_preflight'), \
                 patch.object(trial, 'ui_shells', side_effect=lambda *_: (f.desktops(), f.shells)[1]), \
                 patch.object(trial, 'ui_desktops', side_effect=f.desktops), \
                 patch.object(trial, 'ui_cli', side_effect=f.cli), \
                 patch.object(trial, 'ui_runtime', side_effect=f.runtime), \
                 patch.object(trial, 'ui_wait', side_effect=lambda *a, **k: wait(*a, timeout=.2, platform=k.get('platform'))):
                yield f


with fixture() as f:
    f.update()
    assert (f.old / 'cornice/shell').is_symlink()
    assert (f.old / 'cornice/shell').resolve() == f.new / 'cornice/shell'
    manifest = trial.verify_release(f.old)
    assert manifest['uiOverlay']['id'] == 'new'
    assert f.generations == {'': 'new', 'desktop2': 'new'}
    assert (f.base / 'current.json').read_bytes() == f.current_bytes
    f.rollback()
    f.unchanged()
    assert f.generations == {'': 'old', 'desktop2': 'old'}
    prepared = [args for _, args in f.calls if args == ('reload-ui', '--prepare', '--bootstrap')]
    assert len(prepared) == 2
print('PASS actual rename-exchange publishes one immutable UI for two existing shells, then restores the exact old directory/manifest')

for target in ('Hyprland', 'cornice/bin/cornice-desktop', 'cornice/native/agent/desktop-endpoint.mjs',
               'cornice/native/qml/Cornice/Desktop/module', 'cornice/bin/cornice-agent-view'):
    with fixture() as f:
        (f.new / target).write_text('incompatible change')
        f.rehash(f.new)
        try:
            f.update()
            raise AssertionError('incompatible update accepted')
        except RuntimeError as error:
            assert 'incompatible' in str(error)
        f.unchanged()
        assert not f.calls
print('PASS compositor, Broker CLI, UI helper, native endpoint and native QML changes are rejected before any UI or IPC mutation')

with fixture() as f:
    (f.new / 'cornice/shell/untracked.qml').write_text('unprepared extra')
    try:
        f.update()
        raise AssertionError('untracked QML accepted')
    except RuntimeError as error:
        assert 'differs from the manifest' in str(error)
    f.unchanged()
with fixture() as f:
    f.active = True
    try:
        f.update()
        raise AssertionError('active presentation accepted')
    except RuntimeError as error:
        assert 'presentation' in str(error)
    f.unchanged()
    assert not f.calls
print('PASS untracked QML or active takeover leaves original UI, manifest and supervisor state untouched')

with fixture() as f:
    (f.new / 'cornice/shell/shell.qml').write_text('invalid root')
    f.rehash(f.new)
    try:
        f.update()
        raise AssertionError('failed QML accepted')
    except RuntimeError as error:
        assert 'previous UI restored' in str(error), str(error)
    f.unchanged()
    assert f.generations == {'': 'old', 'desktop2': 'old'}
print('PASS build readback failure automatically restores the old UI with one cached public reload per prepared shell')

for after in (False, True):
    with fixture() as f:
        exchange = trial.ui_exchange

        def interrupted(left, right):
            if after:
                exchange(left, right)
            raise SystemExit('simulated process loss')

        with patch.object(trial, 'ui_exchange', side_effect=interrupted):
            try:
                f.update()
                raise AssertionError('interruption was swallowed')
            except SystemExit:
                pass
        assert (f.base / 'ui-overlay.json').exists()
        # Recovery also works offline; a stopped desktop cannot answer IPC.
        with patch.object(trial, 'is_running', return_value=False):
            f.rollback()
        f.unchanged()
print('PASS process loss immediately before or after exchange is recoverable from durable inode identities without a running session')

with fixture() as f:
    f.update()
    second = f.release('second')
    f.shells = [row | {'beforeBuild': 'new'} for row in f.shells]
    f.update(second)
    assert f.generations == {'': 'second', 'desktop2': 'second'}
    f.rollback()
    assert f.generations == {'': 'new', 'desktop2': 'new'}
    assert (f.old / 'cornice/shell').resolve() == f.new / 'cornice/shell'
    f.rollback()
    f.unchanged()
print('PASS consecutive UI upgrades preserve each previous overlay and reach the initial UI through successive rollbacks')

with fixture() as f:
    f.update()
    (f.old / 'manifest.json').write_text('{}')
    try:
        f.rollback()
        raise AssertionError('independent manifest overwritten')
    except RuntimeError as error:
        assert 'changed independently' in str(error)
    assert (f.old / 'manifest.json').read_text() == '{}'
    assert (f.old / 'cornice/shell').resolve() == f.new / 'cornice/shell'
print('PASS independently modified metadata is preserved rather than silently overwritten by rollback')

with fixture() as f:
    f.generations[''] = 'new'
    shell = f.shells[0]
    try:
        trial.ui_wait(f.new / 'cornice/bin/cornice', f.context, shell, None)
        raise AssertionError('candidate pong treated as restored legacy root')
    except RuntimeError as error:
        assert 'readback timed out' in str(error)
    f.generations[''] = None
    trial.ui_wait(f.new / 'cornice/bin/cornice', f.context, shell, None)
print('PASS legacy rollback waits for the new runtimeIdentity method to disappear, not just a live pong')

with fixture() as f:
    f.update()
    normal = f.cli
    def interrupted_prepare(cli, context, name, *args):
        if args[0] == 'reload-ui' and '--prepare' in args and name == 'desktop2':
            raise RuntimeError('temporary socket timeout')
        return normal(cli, context, name, *args)
    with patch.object(trial, 'ui_cli', side_effect=interrupted_prepare):
        try:
            f.rollback()
            raise AssertionError('incomplete rollback falsely finalized')
        except RuntimeError as error:
            assert 'could not reload' in str(error)
    pointer = trial.read(f.base / 'ui-overlay.json')
    assert pointer['record'], 'incomplete rollback must remain reachable'
    record = trial.read(Path(pointer['record']) / 'record.json')
    assert record['phase'] == 'rollback-pending' and record['rollbackPending'] == ['desktop2']
    f.unchanged()
    assert f.generations == {'': 'old', 'desktop2': 'new'}
    f.rollback()
    f.unchanged()
    assert f.generations == {'': 'old', 'desktop2': 'old'}
    assert trial.read(f.base / 'ui-overlay.json')['record'] is None
print('PASS a temporary preparation failure preserves a reachable rollback-pending record and later repairs the existing shell')

with fixture() as f:
    matching = {'CORNICE_PATH': str(f.old / 'cornice'), 'HYPRLAND_INSTANCE_SIGNATURE': 'private-instance',
                'CORNICE_DESKTOP_NAME': 'desktop2'}
    with patch.object(trial, 'ui_environment', return_value=matching):
        assert trial.ui_peer_matches(os.getpid(), 'desktop2', f.context)
        assert not trial.ui_peer_matches(os.getpid(), '', f.context)
    for key, mismatch in (('CORNICE_PATH', str(f.new / 'cornice')),
                          ('HYPRLAND_INSTANCE_SIGNATURE', 'another-instance'),
                          ('CORNICE_DESKTOP_NAME', 'desktop3')):
        with patch.object(trial, 'ui_environment', return_value=matching | {key: mismatch}):
            assert not trial.ui_peer_matches(os.getpid(), 'desktop2', f.context)
print('PASS same-user peers with another product, compositor instance or seat name are rejected before native/UI actions')


with fixture() as f:
    f.shells = [shell | {'beforeTransport': None} for shell in f.shells]
    try:
        f.update()
        raise AssertionError('legacy soft migration accepted')
    except RuntimeError as error:
        assert 'strategy cold' in str(error)
    f.unchanged()
    assert not f.calls
print('PASS an existing legacy transport cannot be silently bootstrapped through the unsafe soft path')

with fixture() as f:
    module = f.new / 'cornice/native/qml/Cornice/Platform/module'
    module.write_text('new platform binary')
    trial.ui_build(f.new / 'cornice/shell', 'new')
    f.rehash(f.new)
    try:
        f.update()
        raise AssertionError('same-PID Platform binary swap accepted')
    except RuntimeError as error:
        assert 'Platform changed' in str(error) and 'strategy cold' in str(error)
    f.unchanged()
    stops = []
    def stop(context, shell):
        stops.append(shell['name'])
    def replaced(cli, context, shell, expected, native, platform=None, fail_exited=False):
        f.generations[shell['name']] = expected
        return {'name': shell['name'], 'pid': shell['pid'] + 1000, 'processStart': 'replacement'}
    with patch.object(trial, 'ui_stop_shell', side_effect=stop), patch.object(trial, 'ui_replacement', side_effect=replaced):
        f.update(strategy='cold')
    assert stops == ['', 'desktop2']
    assert (f.old / 'cornice/native/qml/Cornice/Platform').is_symlink()
    trial.verify_release(f.old)
    trial.ui_hashes(f.old, trial.verify_release(f.old), 'cornice/native/')
    pointer = trial.read(f.base / 'ui-overlay.json')
    record = trial.read(Path(pointer['record']) / 'record.json')
    assert record['strategy'] == 'cold' and len(record['uiReplacements']) == 2
    # A future ordinary UI update must verify native files through the approved
    # Platform symlink, without globally following unknown directory symlinks.
    followup = f.release('post-cold-soft')
    (followup / 'cornice/native/qml/Cornice/Platform/module').write_text('new platform binary')
    trial.ui_build(followup / 'cornice/shell', 'post-cold-soft')
    f.rehash(followup)
    f.shells = [row | {'beforeBuild': 'new', 'beforePlatform': trial.ui_platform_id(f.old / 'cornice')} for row in f.shells]
    f.update(followup)
    assert f.generations == {'': 'post-cold-soft', 'desktop2': 'post-cold-soft'}
    f.rollback()
    assert f.generations == {'': 'new', 'desktop2': 'new'}
    assert (f.old / 'cornice/native/qml/Cornice/Platform').is_symlink()
    # No running GUI in this fixture: offline restoration still reverses both
    # atomically journaled pointers and restores the original manifest bytes.
    with patch.object(trial, 'is_running', return_value=False):
        f.rollback()
    f.unchanged()
    assert not (f.old / 'cornice/native/qml/Cornice/Platform').is_symlink()
    assert (f.old / 'cornice/native/qml/Cornice/Platform/module').read_text() == 'platform-native-module'
print('PASS cold publication supports the next real atomic soft update through its Platform symlink, then restores both exact original payloads')

with fixture() as f:
    f.update()
    pointer = trial.read(f.base / 'ui-overlay.json')
    directory = Path(pointer['record'])
    record = trial.read(directory / 'record.json')
    # The original UI is back on disk, but a supervisor replaced one process.
    trial.ui_exchange(f.old / 'cornice/shell', Path(record['slot']))
    trial.atomic(f.old / 'manifest.json', (directory / 'original-manifest.json').read_text())
    f.generations = {'': 'old', 'desktop2': 'old'}
    record['shells'][0]['pid'] = 99999999
    record['shells'][0]['processStart'] = 'old-gone'
    record['phase'] = 'rollback-pending'
    trial.atomic(directory / 'record.json', record)
    before = list(f.calls)
    peer = {'name': '', 'pid': os.getpid(), 'processStart': trial.start_identity(os.getpid())}
    with patch.object(trial, 'ui_socket_peer', return_value=peer):
        f.rollback()
    f.unchanged()
    final = trial.read(directory / 'record.json')
    assert final['phase'] == 'restored-with-replacement'
    assert final['replacements'][0]['previousPid'] == 99999999
    assert final['replacements'][0]['pid'] == os.getpid()
    assert f.calls == before, 'already restored authenticated replacement must never be reloaded'
    assert trial.read(f.base / 'ui-overlay.json')['record'] is None
print('PASS a lost old UI PID is reconciled only through authenticated replacement peer plus original compiled build, without replaying UI actions')

# Exercise real desktop schema validation with transport doubles only; unlike
# Fixture.desktops, this checks occupied/paused strict booleans on every seat.
real_desktops = trial.ui_desktops
with tempfile.TemporaryDirectory(prefix='cornice-ui-cold-guard-', dir='/tmp') as temporary:
    base = Path(temporary)
    rows = [{'name': 'main', 'primary': True, 'paused': True, 'occupied': False, 'presentation': {'active': False}},
            {'name': 'desktop2', 'primary': False, 'paused': True, 'occupied': False, 'presentation': {'active': False}}]
    with patch.object(trial, 'ui_cli', return_value=json.dumps({'desktops': rows})):
        assert len(real_desktops(None, {}, cold=True)) == 2
    for key, value in (('occupied', True), ('occupied', None), ('paused', False), ('paused', None), ('humanLocked', True)):
        changed = [rows[0], rows[1] | {key: value}]
        with patch.object(trial, 'ui_cli', return_value=json.dumps({'desktops': changed})):
            try:
                real_desktops(None, {}, cold=True)
                raise AssertionError('unsafe cold desktop accepted: ' + key)
            except RuntimeError:
                pass
print('PASS cold maintenance refuses occupied, unpaused, locked and unverifiable seats before UI mutation')


# Module exchange is a second atomic rename. Interruptions at either boundary
# cannot make rollback guess which inode is the original payload.
for exchange_number in (1, 2):
    for after in (False, True):
        with fixture() as f:
            (f.new / 'cornice/native/qml/Cornice/Platform/module').write_text('new module')
            trial.ui_build(f.new / 'cornice/shell', 'new')
            f.rehash(f.new)
            exchange = trial.ui_exchange
            calls = [0]
            def interrupted(left, right):
                calls[0] += 1
                if calls[0] != exchange_number:
                    return exchange(left, right)
                if after:
                    exchange(left, right)
                raise SystemExit('process loss between payload exchanges')
            with patch.object(trial, 'ui_exchange', side_effect=interrupted):
                try:
                    f.update(strategy='cold')
                    raise AssertionError('process interruption swallowed')
                except SystemExit:
                    pass
            with patch.object(trial, 'is_running', return_value=False):
                f.rollback()
            f.unchanged()
            assert (f.old / 'cornice/native/qml/Cornice/Platform/module').read_text() == 'platform-native-module'
print('PASS cold rollback survives process loss on either side of each shell and Platform atomic exchange')

with fixture() as f:
    f.update()
    pointer = trial.read(f.base / 'ui-overlay.json')
    directory = Path(pointer['record'])
    record = trial.read(directory / 'record.json')
    trial.ui_exchange(f.old / 'cornice/shell', Path(record['slot']))
    trial.atomic(f.old / 'manifest.json', (directory / 'original-manifest.json').read_text())
    f.generations = {'': 'old', 'desktop2': 'old'}
    record['shells'][0].update(pid=99999999, processStart='old-gone')
    trial.atomic(directory / 'record.json', record)
    with patch.object(trial, 'ui_socket_peer', side_effect=RuntimeError('socket peer belongs to another product')):
        try:
            f.rollback()
            raise AssertionError('unverified replacement closed the journal')
        except RuntimeError as error:
            assert 'could not reload' in str(error)
    final = trial.read(directory / 'record.json')
    assert final['phase'] == 'rollback-pending' and not final['replacements']
    assert trial.read(f.base / 'ui-overlay.json')['record'] == str(directory)
print('PASS a dead UI PID with an unverified replacement remains explicitly rollback-pending for later recovery')

with fixture() as f:
    cli = f.new / 'cornice/bin/cornice'
    shell = f.shells[0] | {'output': 'private-main'}
    for layers in ({}, {'private-main': {'levels': {'2': [{'namespace': 'cornice-bar', 'pid': os.getpid() + 1}]}}}):
        with patch.object(trial, 'ipc', return_value=layers):
            try:
                trial.ui_wait(cli, f.context, shell, 'old', timeout=.1)
                raise AssertionError('compiled identity accepted without its actual UI bar')
            except RuntimeError as error:
                assert 'readback timed out' in str(error)
    layers = {'private-main': {'levels': {'2': [{'namespace': 'cornice-bar', 'pid': os.getpid()}]}}}
    with patch.object(trial, 'ipc', return_value=layers):
        trial.ui_wait(cli, f.context, shell, 'old', timeout=.1)
print('PASS modern UI readiness requires its own output and authenticated peer PID bar, beyond a compiled runtimeIdentity reply')
