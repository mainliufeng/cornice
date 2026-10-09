"""Real GTK/Wayland input transfers and native workspace action contexts."""
from desktop_harness import *
import re

OWNER = 'seat-action-routing-test-owner-0000000001'
paths = {name: BASE / (name + '.txt') for name in ('human-window', 'agent-window')}
failures = []
evidence = []


def send(device, event):
    device.stdin.write(event + '\n'); device.stdin.flush()
    assert select.select([device.stdout], [], [], 5)[0] and device.stdout.readline().strip() == 'done', event


def key(device, code, super=False):
    if super:
        send(device, 'mods 64'); send(device, 'key 125 1')
    send(device, f'key {code} 1'); send(device, f'key {code} 0')
    if super:
        send(device, 'key 125 0'); send(device, 'mods 0')


def client(name):
    return next((item for item in ctl('clients', True) if item['title'] == name), None)


def dispatch(action, seat=None):
    if seat:
        state = cli('state', seat)
        return ctl('seat dispatch ' + seat + ' ' + state['display'] + ' ' + state['generation'] + ' ' + action)
    return ctl('dispatch ' + action)


def focus(name, seat=None):
    answer = dispatch('hl.dsp.focus({window=' + json.dumps('title:^' + name + '$') + '})', seat)
    assert answer == 'ok', answer


def widget(device, name, kind, click=True):
    window = wait(lambda: client(name))
    geometry = wait(lambda: json.loads(paths[name].with_suffix('.geometry').read_text()))[kind]
    x, y, width, height = geometry
    send(device, f"motion {round(window['at'][0] + x + width / 2)} {round(window['at'][1] + y + height / 2)}")
    if click:
        send(device, 'button 272 1'); send(device, 'button 272 0')


def text(name):
    return paths[name].read_text() if paths[name].exists() else ''


def offsets():
    return {name: (BASE / (name + '.log')).stat().st_size for name in paths}


def received(name, offset, method, code):
    # wl_keyboard and wl_pointer objects are bound from a named wl_seat. This
    # checks the actual protocol recipient, including GTK's primary-seat alias.
    log = (BASE / (name + '.log')).read_text(errors='replace')
    seats = dict(re.findall(r'wl_seat[@#](\d+)\.name\("([^"]+)"\)', log))
    kind = 'wl_keyboard' if method == 'key' else 'wl_pointer'
    devices = {}
    for seat_id, device_id in re.findall(r'wl_seat[@#](\d+)\.get_' + ('keyboard' if method == 'key' else 'pointer') + r'\(new id ' + kind + r'[@#](\d+)\)', log):
        devices[device_id] = seats.get(seat_id, '<unnamed>')
    result = []
    # New events only; protocol object/name mappings come from the full log.
    tail = log[offset:]
    for device_id, args in re.findall(kind + r'[@#](\d+)\.' + method + r'\(([^\n]+)\)', tail):
        values = [item.strip() for item in args.split(',')]
        if len(values) >= 4 and values[2] == str(code) and values[3] == '1':
            result.append(devices.get(device_id, '<unknown>'))
    return result


def check(description, conditions, details):
    result = {'description': description, 'ok': all(conditions), **details}
    evidence.append(result)
    if result['ok']:
        record(description)
    else:
        failures.append(result)
        print('FAIL', json.dumps(result), flush=True)
    (BASE / 'routing-evidence.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2))


def human_view():
    value = human_state()
    return {"workspace": value["workspace"]["address"], "window": value["window"],
            "cursor": value["cursor"], "output": value["output"]}


def keyboard(env, seat, name, layout):
    process = subprocess.Popen([str(BASE / 'input'), seat, 'human'], env=dict(env, MULTISEAT_TEST_LAYOUT=layout),
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(BASE / (name + '.log'), 'w'),
                               text=True, start_new_session=True)
    PROCESSES.append(process)
    assert select.select([process.stdout], [], [], 5)[0] and process.stdout.readline().strip() == 'ready'
    return process


def transfer(description, action, expected_code, expected_text, seat=None, device=None, keycode=None, target='agent-window'):
    before = {name: text(name) for name in paths}
    primary_token = ctl('seat input-target', True).get('token') if device != human_keyboard else None
    marker = offsets()
    if device:
        key(device, keycode, super=keycode != 65)
    else:
        assert dispatch(action, seat) == 'ok'
    time.sleep(.25)
    receivers = {name: received(name, marker[name], 'key', expected_code) for name in paths}
    wanted_seat = 'Hyprland' if target == 'human-window' else 'agent1'
    other = 'agent-window' if target == 'human-window' else 'human-window'
    check(description, [text(target) == before[target] + expected_text,
                        text(other) == before[other], receivers[target] == [wanted_seat], not receivers[other],
                        primary_token is None or ctl('seat input-target', True).get('token') == primary_token],
          {'before': before, 'after': {name: text(name) for name in paths}, 'receivers': receivers})


try:
    initialize()
    cli('create', 'agent1', '--workspace', '11', '--output', 'human'); cli('resume', 'agent1')
    for source, name in (('virtual-keyboard-unstable-v1', 'virtual-keyboard'), ('wlr-virtual-pointer-unstable-v1', 'virtual-pointer')):
        for mode, extension in (('client-header', 'h'), ('private-code', 'c')):
            subprocess.run(['wayland-scanner', mode, str(FORK / 'protocols' / (source + '.xml')), str(BASE / (name + '.' + extension))], check=True)
    source = (FORK / 'hyprtester/multiseat/input.c').read_text().replace('.layout = "us"', '.layout = getenv("MULTISEAT_TEST_LAYOUT") ?: "us"')
    (BASE / 'input.c').write_text(source)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    subprocess.run(['cc', '-I' + str(BASE), str(BASE / 'input.c'), str(BASE / 'virtual-keyboard.c'), str(BASE / 'virtual-pointer.c'), '-o', str(BASE / 'input'), *flags], check=True)
    human_keyboard = keyboard(ENV, 'Hyprland', 'human-input', 'de')
    agent_env = dict(ENV, WAYLAND_DISPLAY=cli('state', 'agent1')['display'])
    agent_keyboard = keyboard(agent_env, 'agent1', 'agent-input', 'us')
    for name, seat in (('human-window', None), ('agent-window', 'agent1')):
        env = dict(ENV, WAYLAND_DEBUG='1')
        if seat:
            state = cli('state', seat)
            env.update(WAYLAND_DISPLAY=state['display'], HYPRLAND_SEAT_NAME=seat, HYPRLAND_SEAT_ID=state['seatId'], HYPRLAND_SEAT_GENERATION=state['generation'])
            # Launch with the real seat launcher so placement uses its workspace.
            command = shlex.join(['/usr/bin/env', 'WAYLAND_DEBUG=1', '/usr/bin/python3', str(ROOT / 'test/agent-desktop-client.py'), name, str(paths[name])]) + ' 2>' + shlex.quote(str(BASE / (name + '.log')))
            cli('launch', seat, '--', '/bin/sh', '-c', command)
            window = wait(lambda: client(name)); OWNED_PIDS.append(window['pid'])
        else:
            start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', name, paths[name]], name, env)
        wait(lambda: client(name) and paths[name].with_suffix('.geometry').exists())
    focus('human-window'); widget(human_keyboard, 'human-window', 'entry')
    focus('agent-window', 'agent1'); widget(agent_keyboard, 'agent-window', 'entry')
    baseline = human_state()
    transfer('primary send_shortcut keeps native German keymap semantics', 'hl.dsp.send_shortcut({mods="",key="y"})', 44, 'y', target='human-window')
    transfer('hidden Agent send_shortcut uses Agent keymap and actual Agent wl_seat', 'hl.dsp.send_shortcut({mods="",key="y"})', 21, 'y', seat='agent1')
    transfer('Agent send_key_state down/up uses only Agent wl_keyboard', 'hl.dsp.send_key_state({mods="",key="x",state="down"})', 45, 'x', seat='agent1')
    assert dispatch('hl.dsp.send_key_state({mods="",key="x",state="up"})', 'agent1') == 'ok'
    ok('eval hl.bind("SUPER + F5",hl.dsp.send_shortcut({mods="",key="q"}),{}); hl.bind("F7",hl.dsp.pass({window="activewindow"}),{})')
    transfer('primary binding retains primary keyboard delivery', None, 16, 'q', device=human_keyboard, keycode=63, target='human-window')
    transfer('primary pass retains primary keyboard delivery', None, 65, '', device=human_keyboard, keycode=65, target='human-window')
    transfer('virtual Agent binding sends to Agent and preserves primary input token', None, 16, 'q', device=agent_keyboard, keycode=63)
    transfer('Agent pass forwards native bind through actual Agent wl_keyboard', None, 65, '', device=agent_keyboard, keycode=65)
    assert human_state() == baseline

    state = cli('state', 'agent1')
    assert ctl('seat present agent1 ' + state['display'] + ' human current ' + OWNER, True)['active']
    assert ctl('seat present-control ' + OWNER + ' yes', True)['humanControl']
    widget(human_keyboard, 'agent-window', 'entry')
    transfer('physical takeover binding targets Agent through actual Agent wl_keyboard', None, 16, 'q', device=human_keyboard, keycode=63)
    transfer('physical takeover pass leaves human GTK text unchanged', None, 65, '', device=human_keyboard, keycode=65)
    widget(human_keyboard, 'agent-window', 'button', False)
    before = {name: paths[name].with_suffix('.click').read_text() if paths[name].with_suffix('.click').exists() else '0' for name in paths}
    marker = offsets()
    assert dispatch('hl.dsp.send_shortcut({mods="",key="mouse:272"})', 'agent1') == 'ok'
    time.sleep(.25)
    after = {name: paths[name].with_suffix('.click').read_text() if paths[name].with_suffix('.click').exists() else '0' for name in paths}
    receiver = {name: received(name, marker[name], 'button', 272) for name in paths}
    check('synthetic pointer shortcut clicks only Agent GTK button on Agent wl_seat',
          [int(after['agent-window']) == int(before['agent-window']) + 1, after['human-window'] == before['human-window'], receiver['agent-window'] == ['agent1'], not receiver['human-window']],
          {'before': before, 'after': after, 'receivers': receiver})
    # Restore a pointer to a different surface at its own local coordinates,
    # then click without a new motion. This catches wrong target-relative
    # restore coordinates even when the original event reached the right seat.
    restore_path = BASE / 'agent-restore.txt'
    command = shlex.join(['/usr/bin/env', 'WAYLAND_DEBUG=1', '/usr/bin/python3', str(ROOT / 'test/agent-desktop-client.py'), 'agent-restore', str(restore_path)]) + ' 2>' + shlex.quote(str(BASE / 'agent-restore.log'))
    assert dispatch('hl.dsp.exec_cmd(' + json.dumps(command) + ')', 'agent1') == 'ok'
    restore_window = wait(lambda: client('agent-restore'))
    OWNED_PIDS.append(restore_window['pid'])
    wait(lambda: restore_path.with_suffix('.geometry').exists())
    def settled():
        for title, path in [('agent-window', paths['agent-window']), ('agent-restore', restore_path)]:
            bounds = json.loads(path.with_suffix('.geometry').read_text())['entry']
            if abs(bounds[2] - (client(title)['size'][0] - 48)) > 3:
                return False
        return True
    wait(settled)
    widget(human_keyboard, 'agent-window', 'button', False)
    geometry = json.loads(paths['agent-window'].with_suffix('.geometry').read_text())['button']
    expected_local = [geometry[0] + geometry[2] / 2, geometry[1] + geometry[3] / 2]
    mark = offsets()['agent-window']
    before_click = int(paths['agent-window'].with_suffix('.click').read_text())
    before_human = text('human-window')
    assert dispatch('hl.dsp.send_shortcut({mods="",key="mouse:272",window="title:^agent-restore$"})', 'agent1') == 'ok'
    time.sleep(.2)
    events = (BASE / 'agent-window.log').read_text(errors='replace')[mark:]
    enters = re.findall(r'wl_pointer[@#]\d+\.enter\([^\n]*, (-?[0-9.]+), (-?[0-9.]+)\)', events)
    send(human_keyboard, 'button 272 1'); send(human_keyboard, 'button 272 0')
    time.sleep(.2)
    check('cross-surface mouse shortcut restores Agent local coordinates and next no-motion physical click',
          [bool(enters), bool(enters) and all(abs(float(a)-b) < 2 for a,b in zip(enters[-1], expected_local)),
           int(paths['agent-window'].with_suffix('.click').read_text()) == before_click + 1, text('human-window') == before_human],
          {'restoredEnters': enters, 'expectedLocal': expected_local})
    assert dispatch('hl.dsp.window.close({window="title:^agent-restore$"})', 'agent1') == 'ok'
    wait(lambda: client('agent-restore') is None)
    subprocess.run(['grim', '-o', 'human', str(BASE / 'agent-action-routing.png')], env=ENV, check=True)
    ok('seat unpresent ' + OWNER)
    assert human_state() == baseline
    cli('resume', 'agent1')

    # Native numeric relative semantics start at the seat view, not the output's
    # independently active workspace. The silent move must preserve both views.
    focus('agent-window', 'agent1')
    assert dispatch('hl.dsp.window.move({workspace="+1",follow=false})', 'agent1') == 'ok'
    moved = wait(lambda: (window if (window := client('agent-window'))['workspace']['name'] != '11' else None))
    check('Agent relative window move starts at WS11 while human remains WS1',
          [moved['workspace']['name'] == '12', cli('state', 'agent1')['workspace'] == '11', human_state() == baseline], {'window': moved, 'human': human_state()})
    assert dispatch('hl.dsp.window.move({workspace="11",follow=false,window="title:^agent-window$"})', 'agent1') == 'ok'
    # Compare the unchanged primary resolver with the Agent context using the
    # same named origin and explicit window. This exercises native ordering and
    # wrap semantics rather than duplicating the resolver algorithm in Python.
    origin = 'name:routing-beta'
    for name in ('routing-alpha', 'routing-beta', 'routing-gamma'):
        assert dispatch('hl.dsp.focus({workspace=' + json.dumps('name:' + name) + '})', 'agent1') == 'ok'
    for selector in ('m+1', 'm-1', 'e+1', 'e-1', 'r+1', 'r-1', 'm~1', 'e~1', 'r~1', '+1', 'next'):
        move = 'hl.dsp.window.move({workspace=' + json.dumps(selector) + ',follow=false,window="title:^agent-window$"})'
        restore = 'hl.dsp.window.move({workspace=' + json.dumps(origin) + ',follow=false,window="title:^agent-window$"})'
        assert dispatch(restore, 'agent1') == 'ok'
        assert dispatch('hl.dsp.focus({workspace=' + json.dumps(origin) + '})', 'agent1') == 'ok'
        ok('dispatch hl.dsp.focus({workspace=' + json.dumps(origin) + '})')
        primary_answer = dispatch(move)
        primary_target = client('agent-window')['workspace']['name']
        assert dispatch(restore, 'agent1') == 'ok'
        ok('dispatch hl.dsp.focus({workspace="1"})')
        focus('human-window')
        before = human_view()
        focus('agent-window', 'agent1')
        agent_answer = dispatch(move, 'agent1')
        agent_target = client('agent-window')['workspace']['name']
        check('Agent named relative ' + selector + ' matches native primary semantics',
              [(primary_answer == 'ok') == (agent_answer == 'ok'), agent_target == primary_target,
               cli('state', 'agent1')['workspace'] == 'routing-beta', human_view() == before, text('human-window') == 'yq'],
              {'primaryAnswer': primary_answer, 'agentAnswer': agent_answer, 'primaryTarget': primary_target, 'agentTarget': agent_target})
    assert dispatch('hl.dsp.window.move({workspace="11",follow=false,window="title:^agent-window$"})', 'agent1') == 'ok'
    assert dispatch('hl.dsp.focus({workspace="11"})', 'agent1') == 'ok'
    subprocess.run(['grim', '-o', 'human', str(BASE / 'human-action-routing.png')], env=ENV, check=True)
    ok('output create headless action-target')
    ok('eval hl.monitor({output="action-target",mode="1280x800",position="1280x0",scale=1})')
    assert dispatch('hl.dsp.workspace.move({monitor="action-target"})', 'agent1') == 'ok'
    workspaces = ctl('workspaces', True)
    locations = {item['name']: item['monitor'] for item in workspaces}
    check('omitted workspace move moves Agent current WS without moving human WS',
          [locations.get('11') == 'action-target', locations.get('1') == 'human'], {'locations': locations})
    state = cli('state', 'agent1')
    check('moving the viewed workspace updates Agent monitor and pointer origin',
          [state['output'] == 'action-target', state['position'] == [1280, 0], 1280 <= state['cursor'][0] < 2560], {'state': state})
    if failures:
        raise AssertionError(json.dumps(failures, ensure_ascii=False, indent=2))
finally:
    cleanup()
