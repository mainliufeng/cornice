#!/usr/bin/env python3
"""Soft reload uses isolated per-seat socket fixtures, never the live desktop."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent


class Endpoint:
    def __init__(self, path):
        self.path, self.requests = path, []
        self.mode = 'ready'
        self.scans = self.loads = 0
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.bind(str(path))
        self.socket.listen()
        self.closed = False
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.closed:
            try:
                connection, _ = self.socket.accept()
            except OSError:
                break
            with connection:
                request = json.loads(connection.makefile().readline())
                self.requests.append(request)
                target, method, args = request['target'], request['method'], request['args']
                assert target == 'shell', request
                if method == 'runtimeIdentity':
                    result = json.dumps({'ipcTransport': 'legacy' if self.mode == 'legacy' else 'qt-local-v1'})
                elif method == 'reloadPlugins':
                    self.scans = self.loads = 0
                    result = 'ok'
                elif method == 'plugins':
                    self.scans += 1
                    absent = self.mode in ('absent', 'missing') or (self.mode == 'pending' and self.scans < 3)
                    result = json.dumps([] if absent else [{'id': 'cn.runtime-control'}])
                elif method == 'summon':
                    assert args == ['cn.runtime-control', '{"action":"prepare"}'], request
                    result = 'not-summonable' if self.mode == 'rejected' else 'ok'
                elif method == 'call':
                    assert args[0] == 'cn.runtime-control' and args[2] == '{}', request
                    if args[1] == 'status':
                        self.loads += 1
                        result = 'not-loaded' if self.mode == 'pending' and self.loads < 3 else 'ready'
                    else:
                        assert args[1] == 'reload', request
                        if self.mode == 'lost-reply':
                            continue
                        result = 'requested'
                else:
                    raise AssertionError(request)
                connection.sendall((json.dumps({'ok': True, 'result': result}) + '\n').encode())

    def reset(self, mode='ready'):
        self.mode, self.requests = mode, []
        self.scans = self.loads = 0

    def close(self):
        self.closed = True
        self.socket.close()
        self.path.unlink(missing_ok=True)


with tempfile.TemporaryDirectory(prefix='cornice-runtime-control-', dir='/tmp') as temporary:
    base = Path(temporary)
    product = base / 'product'
    (product / 'bin').mkdir(parents=True)
    (product / 'config').mkdir()
    shutil.copy2(ROOT / 'bin/cornice', product / 'bin/cornice')
    shutil.copy2(ROOT / 'config/session-services.json', product / 'config/session-services.json')
    fake_bin = base / 'fake-bin'
    fake_bin.mkdir()
    fallback = base / 'fallback'
    qs = product / 'bin/cornice-qs'
    qs.write_text('#!/bin/sh\nprintf fallback >> "$RELOAD_TEST_FALLBACK"\nexit 99\n')
    qs.chmod(0o755)
    desktop_state = base / 'desktop-state.json'
    desktop_state.write_text(json.dumps({'desktops': [{'name': 'main', 'primary': True,
                                                      'presentation': {'active': False}, 'humanTakeover': False}]}))
    desktop = product / 'bin/cornice-desktop'
    desktop.write_text('#!/bin/sh\ncat "$RELOAD_TEST_DESKTOP_STATE"\n')
    desktop.chmod(0o755)
    hyprctl = fake_bin / 'hyprctl'
    hyprctl.write_text('#!/bin/sh\nprintf \'%s\' \'{"seatId":"seat-2","generation":7}\'\n')
    hyprctl.chmod(0o755)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('CORNICE_', 'HYPRLAND_')):
            del env[key]
    env.update(CORNICE_PATH=str(product), XDG_RUNTIME_DIR=str(base), USER='reload-test',
               HYPRLAND_INSTANCE_SIGNATURE='reload-test-instance',
               PATH=str(fake_bin) + ':' + os.environ['PATH'], RELOAD_TEST_FALLBACK=str(fallback),
               RELOAD_TEST_DESKTOP_STATE=str(desktop_state))
    digest = hashlib.sha256(env['HYPRLAND_INSTANCE_SIGNATURE'].encode()).hexdigest()[:8]
    primary = Endpoint(base / 'primary.sock')
    secondary = Endpoint(base / ('cs-' + digest + '-desktop2.sock'))
    (base / ('cs-' + digest + '-session.json')).write_text(json.dumps({'socket': str(primary.path)}))
    native = env | {'HYPRLAND_SEAT_NAME': 'desktop2', 'HYPRLAND_SEAT_ID': 'seat-2',
                    'HYPRLAND_SEAT_GENERATION': '7'}
    scoped = env | {'CORNICE_DESKTOP_NAME': 'desktop2', 'CORNICE_SHELL_SOCKET': str(secondary.path)}

    def run(environment, *args, succeeds=True):
        answer = subprocess.run([str(product / 'bin/cornice'), 'reload-ui', *args],
                                env=environment, capture_output=True, text=True, timeout=13)
        assert (answer.returncode == 0) == succeeds, (answer.returncode, answer.stdout, answer.stderr)
        return answer

    def sequence(endpoint):
        return [(q['method'], q['args'][1] if q['method'] == 'call' else '') for q in endpoint.requests]

    try:
        for context, destination in ((env, primary), (scoped, secondary), (native, secondary)):
            primary.reset(); secondary.reset()
            assert run(context).stdout.strip() == 'requested'
            assert sequence(destination) == [('runtimeIdentity', ''), ('plugins', ''), ('summon', ''),
                                             ('call', 'status'), ('call', 'reload')]
            other = primary if destination is secondary else secondary
            assert not other.requests
        print('PASS primary, explicit desktop and native seat route all soft reload IPC to the same intended shell')

        primary.reset(); secondary.reset('pending')
        assert run(scoped, '--bootstrap').stdout.strip() == 'requested'
        assert secondary.scans == 3 and secondary.loads == 3
        assert sum(q['method'] == 'reloadPlugins' for q in secondary.requests) == 1
        assert sum(q['method'] == 'summon' for q in secondary.requests) == 1
        assert sequence(secondary).count(('call', 'reload')) == 1
        print('PASS asynchronous registry and loader readiness are awaited through read-only polling')

        for mode, diagnostic in (('rejected', 'not-summonable'), ('lost-reply', 'without a complete reply')):
            secondary.reset(mode)
            answer = run(scoped, succeeds=False)
            assert diagnostic in answer.stderr, answer.stderr
            expected = 1 if mode == 'lost-reply' else 0
            assert sequence(secondary).count(('call', 'reload')) == expected
            assert not primary.requests
            assert not fallback.exists()
        print('PASS rejection or an uncertain reload reply never replays actions or discovers another seat')

        secondary.reset('legacy')
        assert 'strategy cold' in run(scoped, '--bootstrap', succeeds=False).stderr
        assert sequence(secondary) == [('runtimeIdentity', '')]
        print('PASS legacy transport refuses even explicit bootstrap before any registry or reload mutation')

        secondary.reset('missing')
        assert 'unsupported' in run(scoped, succeeds=False).stderr
        assert sequence(secondary) == [('runtimeIdentity', ''), ('plugins', '')]
        print('PASS default discovery refuses a missing controller without rescanning or disposing live services')

        desktop_state.write_text(json.dumps({'desktops': [{'name': 'main', 'primary': True,
                                                          'presentation': {'active': True}}]}))
        for mode, arguments in (('ready', ()), ('missing', ('--bootstrap',))):
            secondary.reset(mode)
            assert 'presentation' in run(scoped, *arguments, succeeds=False).stderr
            assert sequence(secondary) == [('runtimeIdentity', ''), ('plugins', '')]
        desktop_state.write_text(json.dumps({'desktops': [{'name': 'main', 'primary': True,
                                                          'presentation': {'active': False}}]}))
        print('PASS active presentation rejects reload and explicit bootstrap before summon or service rescan')

        secondary.reset('absent')
        started = time.monotonic()
        answer = run(scoped, '--bootstrap', succeeds=False)
        assert 'discovery timed out' in answer.stderr
        assert time.monotonic() - started < 12
        assert all(q['method'] in ('runtimeIdentity', 'reloadPlugins', 'plugins') for q in secondary.requests)
        print('PASS missing plugin stops at the bounded readiness deadline before summon or reload')

        secondary.reset()
        answer = run(native | {'HYPRLAND_SEAT_GENERATION': '6'}, succeeds=False)
        assert 'stale or unavailable native seat' in answer.stderr
        assert not secondary.requests
        assert 'usage:' in run(scoped, 'extra', succeeds=False).stderr
        assert not secondary.requests
        secondary.close()
        assert 'no responding desktop shell' in run(scoped, succeeds=False).stderr
        assert not fallback.exists()
        print('PASS stale identity, invalid arguments and a missing scoped shell fail before wrong-seat effects')
    finally:
        for endpoint in (primary, secondary):
            if not endpoint.closed:
                endpoint.close()
