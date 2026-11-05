"""Real guard + isolated compositor/lock provider + private fake logind.

No host bus, display, input devices, credentials or physical sleep are available.
The driver responds to full-lock-required as QML does, using the real provider.
"""
from desktop_harness import *

def read_events(path):
    if not path.exists(): return []
    result = []
    for line in path.read_text().splitlines():
        try: result.append(json.loads(line))
        except json.JSONDecodeError: pass
    return result

def guard_events(): return read_events(BASE / 'guard-events')
def logind_events(): return read_events(BASE / 'logind-events')
def observed(name, after=0):
    return any(e.get('event') == name for e in guard_events()[after:])
def calls(case):
    return [e for e in logind_events() if e.get('event') == 'suspend' and e.get('case') == case]

def control(**values):
    token = time.monotonic_ns()
    fixture.stdin.write(json.dumps(values | {'id': token}) + '\n'); fixture.stdin.flush()
    wait(lambda: any(e.get('id') == token for e in logind_events()))

def reset(case, failures=0, error='', prepare=True):
    control(LidClosed=False, Docked=False, test={'case': case, 'failures': failures,
                                               'error': error, 'prepare': prepare})
    time.sleep(.7) # Observe the open edge before another close edge.

def lock():
    event = 'provider-' + str(time.monotonic_ns())
    p = subprocess.Popen([str(PRODUCT / 'bin/cornice-human-lock'), '--scope', 'session',
                          '--pam-service', 'permit', '--pam-directory', str(pam), '--allow-emergency'],
                         env=ENV, stdin=subprocess.PIPE, stdout=open(BASE / event, 'w'),
                         stderr=open(BASE / (event + '.log'), 'w'), start_new_session=True, text=True)
    PROCESSES.append(p)
    wait(lambda: any(e.get('secure') is True for e in read_events(BASE / event)))
    wait(lambda: ctl('seat lock-state', True).get('secure'))
    return p

def unlock(p):
    p.stdin.write('emergency-unlock\n'); p.stdin.flush()
    wait(lambda: not ctl('seat lock-state', True)['locked'])
    p.wait(timeout=5)

try:
    initialize()
    pam = BASE / 'pam'; pam.mkdir()
    (pam / 'permit').write_text('auth sufficient pam_permit.so\naccount required pam_permit.so\nsession required pam_permit.so\n')
    bus = subprocess.check_output(['dbus-daemon', '--session', '--fork', '--print-address=1', '--print-pid=1'], env=ENV, text=True).splitlines()
    OWNED_BUS_PIDS.append(int(bus[1]))
    guard_env = ENV | {'DBUS_SYSTEM_BUS_ADDRESS': bus[0]}
    fixture = subprocess.Popen(['/usr/bin/python3', str(ROOT / 'test/logind-fixture.py'), bus[0], str(BASE / 'logind-events')],
        env=guard_env, stdin=subprocess.PIPE, stdout=open(BASE / 'fixture.log','w'), stderr=subprocess.STDOUT,
        start_new_session=True, text=True)
    PROCESSES.append(fixture)
    wait(lambda: any(e['event'] == 'ready' for e in logind_events()))
    guard = subprocess.Popen([str(PRODUCT / 'bin/cornice-session-guard')], env=guard_env,
        stdin=subprocess.PIPE, stdout=open(BASE / 'guard-events','w'), stderr=open(BASE / 'guard.log','w'),
        start_new_session=True, text=True)
    PROCESSES.append(guard)
    wait(lambda: observed('inhibitor-ready'))
    assert any(e.get('event') == 'guard-started' and e.get('sleepPolicyVersion') == 1 for e in guard_events())
    record('new guard version starts with real management-display supervision and private inhibitor FDs')

    reset('retry', failures=2)
    offset = len(guard_events()); control(LidClosed=True)
    wait(lambda: observed('full-lock-required', offset))
    time.sleep(.5); assert not calls('retry')
    record('lid request cannot call logind before the actual compositor confirms a full secure lock')
    provider = lock()
    wait(lambda: len(calls('retry')) == 3, 65)
    wait(lambda: observed('prepare-for-sleep', offset))
    wait(lambda: observed('sleep-lock-secure', offset))
    failures = [e for e in guard_events()[offset:] if e.get('event') == 'suspend-failed']
    assert len(failures) == 2 and all(e.get('error') == 'org.freedesktop.login1.OperationInProgress' for e in failures)
    actual = calls('retry')
    assert all(e['state']['scope'] == 'session' and e['state']['secure'] for e in actual)
    gaps = [b['monotonic'] - a['monotonic'] for a,b in zip(actual, actual[1:])]
    assert gaps[0] >= 15 and gaps[1] >= 30, gaps
    record('real API failures retain error names; retries wait 15/30 seconds and recheck real full-lock state')
    control(event='resume'); wait(lambda: observed('resumed', offset)); unlock(provider)

    reset('open', failures=9)
    provider = lock(); offset = len(guard_events()); control(LidClosed=True)
    wait(lambda: observed('sleep-retry-scheduled', offset))
    control(LidClosed=False); wait(lambda: observed('lid-request-cancelled', offset))
    time.sleep(16); assert len(calls('open')) == 1
    record('opening the lid cancels an API retry; no delayed suspend is dispatched')
    unlock(provider)

    reset('denied', error='org.freedesktop.DBus.Error.AccessDenied')
    provider = lock(); offset = len(guard_events()); control(LidClosed=True)
    wait(lambda: observed('sleep-request-stopped', offset))
    assert not observed('sleep-retry-scheduled', offset) and len(calls('denied')) == 1
    record('authorization denial stops without a bypass or another request')
    control(LidClosed=False); time.sleep(.7); unlock(provider)

    reset('uncertain', prepare=False)
    provider = lock(); offset = len(guard_events()); control(LidClosed=True)
    wait(lambda: observed('suspend-unconfirmed', offset), 10)
    assert observed('sleep-request-stopped', offset)
    time.sleep(16); assert len(calls('uncertain')) == 1
    record('accepted-but-unconfirmed results are diagnosed and never duplicated')
    control(LidClosed=False); time.sleep(.7); unlock(provider)

    reset('lost-lock', failures=9)
    provider = lock(); offset = len(guard_events()); control(LidClosed=True)
    wait(lambda: observed('sleep-retry-scheduled', offset)); unlock(provider)
    wait(lambda: observed('sleep-lock-wait', offset), 20)
    assert len(calls('lost-lock')) == 1
    control(LidClosed=False); wait(lambda: observed('lid-request-cancelled', offset))
    record('losing the secure lock blocks the next API retry and produces lock-wait diagnostics')

    reset('docked'); offset = len(guard_events()); control(Docked=True, LidClosed=True)
    wait(lambda: any(e.get('event') == 'lid-policy' and e.get('docked') and e.get('action') == 'ignore' for e in guard_events()[offset:]))
    assert not calls('docked')
    record('configured docked-ignore policy remains observable and unchanged')
    assert guard.poll() is None
    print('PASS: all isolated sleep integration scenarios; no physical sleep possible', flush=True)
finally:
    cleanup()
