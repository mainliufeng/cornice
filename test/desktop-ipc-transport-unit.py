#!/usr/bin/env python3
"""Real local socket backlog/deadline proof; never initializes a compositor."""
import errno
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
from unittest.mock import patch

os.environ.setdefault('CORNICE_TEST_HYPRLAND_SOURCE', '/tmp/not-used-by-transport-unit')
import desktop_harness as harness


def full_backlog(listener, address):
    fillers = []
    for _ in range(64):
        client = socket.socket(socket.AF_UNIX)
        client.settimeout(.05)
        try:
            client.connect(str(address))
            fillers.append(client)
        except BlockingIOError as error:
            client.close()
            assert error.errno in (errno.EAGAIN, errno.EWOULDBLOCK), error
            return fillers
    raise AssertionError('Private AF_UNIX backlog did not fill')


def accept_after(listener, fillers, delay, commands, response):
    def serve():
        time.sleep(delay)
        for _ in fillers:
            peer, _ = listener.accept()
            peer.close()  # These have sent nothing; they only hold the backlog.
        peer, _ = listener.accept()
        with peer:
            peer.settimeout(6)
            commands.append(peer.recv(4096))
            if response is not None:
                peer.sendall(response)
            else:
                # Wait for the tested response deadline, then peer teardown.
                while peer.recv(4096):
                    raise AssertionError('Unexpected command replay')
    thread = threading.Thread(target=serve)
    thread.start()
    return thread


with tempfile.TemporaryDirectory(prefix='cornice-test-ipc-') as directory:
    runtime = Path(directory)
    endpoint = runtime / 'hypr' / 'transport-unit' / '.socket.sock'
    endpoint.parent.mkdir(parents=True)
    env = harness.ENV | {'HYPRLAND_INSTANCE_SIGNATURE': 'transport-unit'}
    with patch.object(harness, 'RT', runtime), patch.object(harness, 'ENV', env):
        for scenario in ('eventual-connect', 'full-deadline', 'response-deadline'):
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(str(endpoint)); listener.listen(0)
                fillers = full_backlog(listener, endpoint)
                commands = []
                try:
                    if scenario == 'eventual-connect':
                        thread = accept_after(listener, fillers, .2, commands, b'ok')
                        assert harness.ctl('version') == 'ok'
                        thread.join(3); assert not thread.is_alive()
                        assert commands == [b'/version'], commands
                        print('PASS: real EAGAIN backlog drains and the exact private endpoint receives one command', flush=True)
                    elif scenario == 'full-deadline':
                        started = time.monotonic()
                        try:
                            harness.ctl('version')
                            raise AssertionError('Permanently full backlog was accepted')
                        except TimeoutError:
                            pass
                        elapsed = time.monotonic() - started
                        assert 3.8 <= elapsed < 4.8, elapsed
                        for _ in fillers:
                            peer, _ = listener.accept()
                            with peer:
                                peer.settimeout(.05)
                                try:
                                    assert not peer.recv(4096), 'Command submitted without a connection'
                                except TimeoutError:
                                    pass
                        print('PASS: a continuously full real backlog fails at the bounded total deadline without submitting', flush=True)
                    else:
                        thread = accept_after(listener, fillers, 1.2, commands, None)
                        started = time.monotonic()
                        try:
                            harness.ctl('version')
                            raise AssertionError('A missing response was accepted')
                        except TimeoutError:
                            pass
                        elapsed = time.monotonic() - started
                        thread.join(3); assert not thread.is_alive()
                        assert commands == [b'/version'], commands
                        assert 3.8 <= elapsed < 4.8, elapsed
                        print('PASS: connect and response share one deadline; a submitted command is never replayed', flush=True)
                finally:
                    for client in fillers:
                        client.close()
            endpoint.unlink()
print('Private compositor IPC transport checks passed; no compositor was started.')
