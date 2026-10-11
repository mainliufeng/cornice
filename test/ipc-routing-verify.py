#!/usr/bin/env python3
"""CLI routing contract against isolated socket endpoints, never host desktop IPC."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parent.parent


class Endpoint:
    def __init__(self, path, name):
        self.path, self.name, self.requests = path, name, []
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
                if request['method'] == 'rejected' or (request['method'] == 'setDnd' and request['args'] == ['invalid']):
                    reply = {'ok': False, 'error': 'rejected by endpoint'}
                else:
                    result = {'endpoint': self.name, **request}
                    if request['target'] == 'idle' and request['method'] == 'suspend':
                        result = 'full-lock-required'
                    elif request['target'] == 'lock' and request['method'] == 'status':
                        result['secure'] = True
                    reply = {'ok': True, 'result': result}
                connection.sendall((json.dumps(reply) + '\n').encode())

    def close(self):
        self.closed = True
        self.socket.close()
        self.path.unlink(missing_ok=True)


with tempfile.TemporaryDirectory(prefix='cornice-routing-', dir='/tmp') as temporary:
    base = Path(temporary)
    product = base / 'product'
    (product / 'bin').mkdir(parents=True)
    (product / 'config').mkdir()
    for name in ('cornice', 'cornice-agent-view'):
        shutil.copy2(ROOT / 'bin' / name, product / 'bin' / name)
    shutil.copy2(ROOT / 'config/session-services.json', product / 'config/session-services.json')
    fake_bin = base / 'fake-bin'
    fake_bin.mkdir()
    fallback = base / 'wrong-fallback'
    qs = product / 'bin/cornice-qs'
    qs.write_text('#!/bin/sh\nprintf fallback >> "$ROUTING_FALLBACK_LOG"\nexit 99\n')
    qs.chmod(0o755)
    state = base / 'seat.json'
    state.write_text(json.dumps({'seatId': 'seat-desktop2-1', 'generation': 7}))
    hyprctl = fake_bin / 'hyprctl'
    hyprctl.write_text('#!/bin/sh\ncat "$ROUTING_SEAT_STATE"\n')
    hyprctl.chmod(0o755)
    suspend = base / 'suspend-called'
    systemctl = fake_bin / 'systemctl'
    systemctl.write_text('#!/bin/sh\nprintf "%s" "$*" > "$ROUTING_SUSPEND_LOG"\n')
    systemctl.chmod(0o755)
    env = os.environ.copy()
    for name in list(env):
        if name.startswith(('CORNICE_', 'HYPRLAND_')):
            del env[name]
    env.update(CORNICE_PATH=str(product), XDG_RUNTIME_DIR=str(base), USER='routing',
               HYPRLAND_INSTANCE_SIGNATURE='routing-instance', PATH=str(fake_bin) + ':' + os.environ['PATH'],
               ROUTING_FALLBACK_LOG=str(fallback), ROUTING_SEAT_STATE=str(state), ROUTING_SUSPEND_LOG=str(suspend))
    digest = hashlib.sha256(env['HYPRLAND_INSTANCE_SIGNATURE'].encode()).hexdigest()[:8]
    primary = Endpoint(base / 'cornice-routing.sock', 'primary')
    secondary = Endpoint(base / ('cs-' + digest + '-desktop2.sock'), 'desktop2')
    custom = Endpoint(base / 'custom-primary.sock', 'custom-primary')
    native = env | {'HYPRLAND_SEAT_NAME': 'desktop2', 'HYPRLAND_SEAT_ID': 'seat-desktop2-1',
                    'HYPRLAND_SEAT_GENERATION': '7', 'HYPRLAND_ACTION_ID': 'native-launch-context'}
    scoped = env | {'CORNICE_DESKTOP_NAME': 'desktop2', 'CORNICE_SHELL_SOCKET': str(secondary.path),
                    'CORNICE_PRIMARY_SHELL_SOCKET': str(primary.path)}

    def run(*args, environment=None, succeeds=True, binary='cornice'):
        result = subprocess.run([str(product / 'bin' / binary), *args], env=environment or env,
                                capture_output=True, text=True, timeout=8)
        assert (result.returncode == 0) == succeeds, (args, result.returncode, result.stdout, result.stderr)
        return result

    def routed(expected, *args, environment=None):
        answer = run(*args, environment=environment)
        result = json.loads(answer.stdout)
        assert result['endpoint'] == expected, result
        return result

    try:
        for context in (scoped, native):
            assert routed('desktop2', 'launcher', environment=context)['args'] == ['cn.launcher', '{}']
            assert routed('desktop2', 'notifications', environment=context)['target'] == 'shell'
            for target in ('lock', 'idle', 'notifications'):
                routed('primary', 'ipc', target, 'status', environment=context)
            routed('primary', 'lock', 'status', environment=context)
            assert routed('primary', 'dnd', 'on', environment=context)['method'] == 'setDnd'
            routed('primary', 'dnd', environment=context)
            run('suspend', environment=context)
            assert suspend.read_text() == 'suspend'
        print('PASS native shortcuts and secondary shell route global services to primary, panels to their own desktop')

        # Declarative routing also applies to future services, without CLI changes.
        policy = product / 'config/session-services.json'
        declaration = json.loads(policy.read_text())
        declaration['services'].append({'id': 'cn.future', 'scope': 'session', 'targets': ['future']})
        policy.write_text(json.dumps(declaration))
        routed('primary', 'ipc', 'future', 'status', environment=scoped)
        arguments = ['a\nmultiline value', '', '--argument']
        assert routed('desktop2', 'ipc', 'local', 'arguments', *arguments, environment=scoped)['args'] == arguments
        print('PASS declared future services and intact empty/multiline IPC arguments use the common route')

        explicit = scoped | {'CORNICE_PRIMARY_SHELL_SOCKET': str(custom.path)}
        routed('custom-primary', 'ipc', 'lock', 'status', environment=explicit)
        legacy = env | {'CORNICE_SHELL_SOCKET': str(custom.path)}
        legacy.pop('HYPRLAND_INSTANCE_SIGNATURE')
        routed('custom-primary', 'ipc', 'lock', 'status', environment=legacy)
        routed('primary', 'ipc', 'lock', 'status', environment=env | {'CORNICE_SHELL_SOCKET': str(secondary.path)})
        endpoint = base / ('cs-' + digest + '-session.json')
        endpoint.write_text(json.dumps({'socket': str(custom.path)}))
        routed('custom-primary', 'lock', 'status', environment=native)
        routed('custom-primary', 'ping')
        socket_only = env | {'CORNICE_SHELL_SOCKET': str(secondary.path)}
        routed('custom-primary', 'lock', 'status', environment=socket_only)
        routed('desktop2', 'ping', environment=socket_only)
        requests_before = (len(primary.requests), len(secondary.requests), len(custom.requests))
        resolved = json.loads(run('path', '--json', environment=native).stdout)
        assert resolved['primarySocket'] == str(custom.path) and resolved['socket'] == str(secondary.path)
        assert requests_before == (len(primary.requests), len(secondary.requests), len(custom.requests))
        assert not fallback.exists()
        print('PASS custom endpoints and read-only JSON path resolution work without IPC or Quickshell discovery')

        # Helper must discard native routing state, not take a secondary async hop.
        result = run('desktop2', environment=native, binary='cornice-agent-view')
        assert json.loads(result.stdout)['endpoint'] == 'custom-primary'
        result = run('desktop2', '--handoff', 'request-123', environment=native, binary='cornice-agent-view')
        assert json.loads(result.stdout)['method'] == 'handoffStart'
        assert json.loads(result.stdout)['endpoint'] == 'custom-primary'
        print('PASS observer helper addresses primary directly and clears inherited native seat context')

        before = len(secondary.requests)
        for change in ({'HYPRLAND_SEAT_ID': 'previous-seat'}, {'HYPRLAND_SEAT_GENERATION': '6'}):
            result = run('launcher', environment=native | change, succeeds=False)
            assert 'stale or unavailable native seat' in result.stderr
        assert len(secondary.requests) == before
        routed('custom-primary', 'lock', 'status', environment=native | {'HYPRLAND_SEAT_GENERATION': '6'})
        missing_name = native.copy(); missing_name.pop('HYPRLAND_SEAT_NAME')
        routed('custom-primary', 'lock', 'status', environment=missing_name)
        assert 'stale or unavailable native seat' in run('launcher', environment=missing_name, succeeds=False).stderr
        print('PASS stale native identity and generation fail before local IPC while session actions stay available')

        before = len(primary.requests)
        run('dnd', 'invalid', environment=scoped, succeeds=False)
        assert [item['method'] for item in primary.requests[before:]] == ['setDnd']
        secondary.close()
        result = run('launcher', environment=scoped, succeeds=False)
        assert 'no responding desktop shell' in result.stderr
        missing = scoped | {'CORNICE_PRIMARY_SHELL_SOCKET': str(base / 'missing.sock')}
        result = run('lock', 'status', environment=missing, succeeds=False)
        assert 'no responding session shell' in result.stderr
        run('ipc', 'lock', 'rejected', environment=scoped, succeeds=False)
        assert not fallback.exists()
        print('PASS missing and rejected endpoints fail closed without config-wide shell discovery')

        endpoint.write_text('{broken')
        assert 'invalid primary shell endpoint' in run('ping', succeeds=False).stderr
        endpoint.unlink()
        bad_declaration = json.loads(policy.read_text())
        bad_declaration['services'].append({'id': 'cn.duplicate', 'scope': 'desktop', 'targets': ['lock']})
        policy.write_text(json.dumps(bad_declaration))
        assert 'invalid or missing service scope' in run('lock', 'status', environment=scoped, succeeds=False).stderr
        assert 'invalid or missing service scope' in run('path', '--json', environment=scoped, succeeds=False).stderr
        policy.write_text('{broken')
        assert 'invalid or missing service scope'  in run('lock', 'status', environment=scoped, succeeds=False).stderr
        assert not fallback.exists()
        print('PASS malformed route metadata or endpoint fails without fallback or wrong-desktop side effects')
    finally:
        for item in (primary, secondary, custom):
            if not item.closed:
                item.close()
