"""Time real native shortcuts through compositor, shell state and workspace pills."""
from desktop_harness import *
import hashlib
import random


def ui(target, method, *args, agent=False):
    if agent:
        digest = hashlib.sha256(ENV['HYPRLAND_INSTANCE_SIGNATURE'].encode()).hexdigest()[:8]
        path = RT / ('cs-' + digest + '-agent1.sock')
    else:
        path = RT / ('cornice-' + ENV.get('USER', 'user') + '.sock')
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(2)
        connection.connect(str(path))
        connection.sendall((json.dumps({'target': target, 'method': method, 'args': list(args)}) + '\n').encode())
        data = b''
        while b'\n' not in data:
            data += connection.recv(65536)
        reply = json.loads(data.split(b'\n', 1)[0])
    if not reply['ok']:
        raise ValueError(reply)
    return json.loads(reply['result']) if method in ('status', 'geometry') else reply['result']


def send(event):
    keyboard.stdin.write(event + '\n')
    keyboard.stdin.flush()
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'done', event


def shortcut(slot):
    for event in ('mods 64', 'key 125 1', f'key {slot + 1} 1', f'key {slot + 1} 0', 'key 125 0', 'mods 0'):
        send(event)


def active_slot(agent=False):
    widget = next((item for item in ui('bar', 'geometry', agent=agent) if item['id'] == 'cn.workspaces'), {'controls': []})
    return [item['name'] for item in widget['controls'] if item['active']]


def service_workspace(agent=False):
    return next((item for item in ui('desktop', 'status', agent=agent)['desktops'] if item['name'] == 'agent1'), {}).get('workspaceName')


def seat_workspace():
    return next(item for item in ctl('seat list', True) if item['name'] == 'agent1')['workspace']


def snapshot():
    view = ui('desktopObserver', 'status')
    return {'workspace': view['presentation'].get('workspace'), 'control': view['humanControl'],
            'service': service_workspace(), 'bar': active_slot(),
            'agentService': service_workspace(agent=True), 'agentBar': active_slot(agent=True)}


def settled(view_slot, agent_slot, control):
    sample = snapshot()
    view_name = 'cornice-agent-agent1-ws-' + str(view_slot)
    agent_name = 'cornice-agent-agent1-ws-' + str(agent_slot)
    good = (sample['workspace'] == view_name and sample['control'] == control and sample['bar'] == [str(view_slot)]
            and sample['service'] == agent_name and sample['agentService'] == agent_name and sample['agentBar'] == [str(agent_slot)])
    return sample if good else None


def measure(label, slot, agent_slot, control, started):
    last = None
    deadline = started + 2
    while time.monotonic() < deadline:
        last = settled(slot, agent_slot, control)
        if last:
            result = {'label': label, 'slot': slot, 'responseMs': round((time.monotonic() - started) * 1000, 3), 'state': last}
            samples.append(result)
            print('RESPONSE', json.dumps(result), flush=True)
            return result
        time.sleep(.005)
    raise AssertionError(('workspace readers never converged', label, slot, snapshot()))


samples = []
try:
    broker = initialize()
    config = BASE / 'config/cornice'
    config.mkdir(parents=True, exist_ok=True)
    (config / 'config.json').write_text(json.dumps({
        'agentDesktop': {'enabled': True},
        'bar': {'layout': {'left': [{'id': 'cn.workspaces'}, {'id': 'cn.agent-desktop'}], 'center': [], 'right': []}},
        'background': {'enabled': False}, 'weather': {'intervalMinutes': 0},
        'idle': {'lock': 0, 'screenOffAc': 0, 'screenOffBattery': 0, 'dimAc': 0, 'dimBattery': 0,
                 'lockOnSleep': False, 'lockOnLockSignal': False, 'lockOnLidClose': False}}))
    cli('create', 'agent1', '--virtual-output', '1280x800')
    cli('resume', 'agent1')
    wait(lambda: len(active_slot(agent=True)) == 1)
    start([str(PRODUCT / 'bin/cornice-qs'), '-p', str(PRODUCT / 'shell')], 'human-shell')
    wait(lambda: ui('desktop', 'status')['available'])
    # Pre-create static, empty workspaces. Application repaints cannot hide a
    # missing workspace notification or supply a fortuitous refresh.
    for slot in range(1, 10):
        ok('seat workspace agent1 name:cornice-agent-agent1-ws-' + str(slot))
    ok('seat workspace agent1 name:cornice-agent-agent1-ws-1')
    wait(lambda: service_workspace() == 'cornice-agent-agent1-ws-1' and service_workspace(agent=True) == 'cornice-agent-agent1-ws-1')
    for source, name in (('virtual-keyboard-unstable-v1', 'virtual-keyboard'), ('wlr-virtual-pointer-unstable-v1', 'virtual-pointer')):
        for mode, extension in (('client-header', 'h'), ('private-code', 'c')):
            subprocess.run(['wayland-scanner', mode, str(FORK / 'protocols' / (source + '.xml')), str(BASE / (name + '.' + extension))], check=True)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    subprocess.run(['cc', '-I' + str(BASE), str(FORK / 'hyprtester/multiseat/input.c'), str(BASE / 'virtual-keyboard.c'),
                    str(BASE / 'virtual-pointer.c'), '-o', str(BASE / 'input'), *flags], check=True)
    keyboard = subprocess.Popen([str(BASE / 'input'), 'Hyprland', 'human'], env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=open(BASE / 'input.log', 'w'), text=True, start_new_session=True)
    PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'ready'
    send('motion 640 400')
    human_before = human_state()
    ui('desktop', 'observe', 'agent1')
    wait(lambda: ui('desktopObserver', 'status')['presentation'].get('active'))
    ui('desktopObserver', 'takeover', 'true')
    wait(lambda: settled(1, 1, True))
    rng = random.Random(20261009)
    for slot in (2, 4, 3, 8, 6, 5, 9, 2):
        time.sleep(rng.uniform(.011, .191))
        started = time.monotonic()
        shortcut(slot)
        assert seat_workspace() == 'cornice-agent-agent1-ws-' + str(slot)
        measure('takeover', slot, slot, True, started)
    # Queue genuine presentation/list requests while their real broker is
    # briefly stopped. Native physical switching continues, and events arriving
    # during those requests must survive until the latest state is read back.
    os.kill(broker.pid, signal.SIGSTOP)
    try:
        ui('desktopObserver', 'follow')
        for slot in (1, 4, 8, 3, 7):
            shortcut(slot)
        assert seat_workspace() == 'cornice-agent-agent1-ws-7'
        time.sleep(.08)
    finally:
        os.kill(broker.pid, signal.SIGCONT)
    measure('pending-request-burst', 7, 7, True, time.monotonic())
    ui('desktopObserver', 'takeover', 'false')
    wait(lambda: settled(7, 7, False))
    for slot in (1, 4, 6, 2, 9, 3):
        time.sleep(rng.uniform(.011, .191))
        started = time.monotonic()
        shortcut(slot)
        assert seat_workspace() == 'cornice-agent-agent1-ws-7', 'readonly browsing changed Agent workspace'
        measure('readonly', slot, 7, False, started)
    for slot in (4, 8, 1, 6):
        shortcut(slot)
    measure('readonly-burst', 6, 7, False, time.monotonic())
    assert human_state()['workspace'] == human_before['workspace']
    assert human_state()['window'] == human_before['window']
    time.sleep(.15)  # Let the existing pill color transition finish for review.
    subprocess.run(['grim', '-o', 'human', str(BASE / 'workspace-response.png')], env=ENV, check=True)
    result = {'limitMs': 200, 'maximumMs': max(item['responseMs'] for item in samples), 'samples': samples,
              'screenshot': 'workspace-response.png', 'geometry': ui('bar', 'geometry')}
    (BASE / 'workspace-response.json').write_text(json.dumps(result, indent=2))
    slow = [item for item in samples if item['responseMs'] >= 200]
    assert not slow, ('workspace/bar response exceeded 200 ms', slow)
    record('native primary-seat workspace shortcuts update Observer, both Services and actual bar pills within 200 ms; readonly browsing and pending-request bursts preserve seat isolation')
finally:
    if samples:
        (BASE / 'workspace-response-samples.json').write_text(json.dumps(samples, indent=2))
    cleanup()
