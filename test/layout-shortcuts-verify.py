"""Real physical focus/layout shortcuts on human and native Agent desktops."""
from desktop_harness import *

OWNER = 'layout-shortcuts-owner-token-000000000001'
results = []


def send(event):
    keyboard.stdin.write(event + '\n'); keyboard.stdin.flush()
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'done', event


def shortcut(code):
    ctl('seat presentation ' + OWNER)
    for event in ('mods 64', 'key 125 1', f'key {code} 1', f'key {code} 0', 'key 125 0', 'mods 0'):
        send(event)


def current(seat=None):
    address = ctl('seat state ' + seat, True)['windowAddress'] if seat else ctl('activewindow', True)['address']
    return next(item for item in ctl('clients', True) if item['address'] == address)


def click_entry(name, seat=None):
    window = wait(lambda: next((item for item in ctl('clients', True) if item['title'] == name), None))
    geometry = wait(lambda: json.loads((BASE / (name + '.geometry')).read_text()))['entry']
    offset = cli('state', seat)['position'] if seat else [0, 0]
    send(f"motion {round(window['at'][0] - offset[0] + geometry[0] + geometry[2] / 2)} {round(window['at'][1] - offset[1] + geometry[1] + geometry[3] / 2)}")
    send('button 272 1'); send('button 272 0')
    wait(lambda: current(seat)['address'] == window['address'])
    return window


def geometry(prefix):
    return {item['title']: {'at': item['at'], 'size': item['size'], 'fullscreen': item['fullscreen']} for item in ctl('clients', True) if item['title'].startswith(prefix)}


def focus_cycles(seat=None):
    for mode, code in ((0, 49), (1, 50), (2, 33)):
        shortcut(49)  # Return to ordinary tiling before setting the next mode.
        wait(lambda: current(seat)['fullscreen'] == 0)
        shortcut(code)
        wait(lambda: current(seat)['fullscreen'] == mode)
        original = current(seat)['address']
        modes = {'seat': seat or 'human', 'mode': mode, 'next': [], 'prev': []}
        for direction, code in (('next', 36), ('prev', 37)):
            visited = set()
            for _ in range(3):
                before = current(seat)['address']
                shortcut(code)
                try:
                    after = wait(lambda: (item if (item := current(seat))['address'] != before and item['fullscreen'] == mode and item['fullscreenClient'] == mode else None), timeout=2)
                except RuntimeError:
                    (BASE / 'failed-focus-cycle.json').write_text(json.dumps({'seat': seat, 'mode': mode, 'direction': direction, 'before': before, 'after': current(seat), 'clients': ctl('clients', True)}, indent=2))
                    raise
                modes[direction].append(after['address']); visited.add(after['address'])
                assert all(item['fullscreen'] == 0 for item in ctl('clients', True) if item['workspace']['name'] == after['workspace']['name'] and item['address'] != after['address'])
                if seat:
                    assert ctl('activewindow', True)['address'] == human['window']
            assert len(visited) == 3 and current(seat)['address'] == original, modes
        results.append(modes)
        record(f"{seat or 'human'} physical Super+J/K production helper cycles all three windows next/prev and preserves mode {mode}")
    shortcut(49)
    wait(lambda: current(seat)['fullscreen'] == 0)


def widgets_settled(prefix):
    # Fullscreen-to-tiled configures are asynchronous. Inspect the real GTK
    # allocation recorded by each client before accepting its screenshot.
    for title, bounds in geometry(prefix).items():
        allocation = json.loads((BASE / (title + '.geometry')).read_text())['entry']
        if abs(allocation[2] - (bounds['size'][0] - 48)) > 3:
            return False
    return True


def ratio(prefix):
    windows = geometry(prefix)
    assert len(windows) >= 2 and all(item['fullscreen'] == 0 for item in windows.values()), windows
    master = min(windows.values(), key=lambda item: item['at'][0])
    width = max(item['at'][0] + item['size'][0] for item in windows.values()) - min(item['at'][0] for item in windows.values())
    return master['size'][0] / width


def adjust_ratio(prefix, other_prefix=None):
    before = ratio(prefix)
    other = geometry(other_prefix) if other_prefix else None
    shortcut(35)  # Super+H: native master mfact -0.025.
    lower = wait(lambda: (value if (value := ratio(prefix)) < before - .01 else None), timeout=2)
    assert abs(lower - before + .025) < .002, (prefix, before, lower)
    if other_prefix: assert geometry(other_prefix) == other
    shortcut(38)  # Super+L: native master mfact +0.025.
    restored = wait(lambda: (value if abs((value := ratio(prefix)) - before) < .002 else None), timeout=2)
    if other_prefix: assert geometry(other_prefix) == other
    results.append({'prefix': prefix, 'ratioBefore': before, 'ratioAfterH': lower, 'ratioAfterL': restored})
    record(prefix + ' physical Super+H/L change the actual master width by -/+0.025 and preserve the other workspace')


try:
    ENV['PATH'] = str(FORK / 'build-agent-session/hyprctl') + os.pathsep + ENV['PATH']
    initialize()
    ok('eval hl.config({general={layout="master",gaps_in=0,gaps_out=0,border_size=0},master={mfact=0.5,orientation="left",special_scale_factor=1},misc={on_focus_under_fullscreen=2}})')
    for key, direction in (('j', 'next'), ('k', 'prev')):
        command = shlex.join([str(PRODUCT / 'bin/cornice-cycle-focus'), direction])
        ok('eval hl.bind("SUPER + ' + key + '",hl.dsp.exec_cmd(' + json.dumps(command) + '),{})')
    for key, mode in (('n', 0), ('m', 1), ('f', 2)):
        ok('eval hl.bind("SUPER + ' + key + '",hl.dsp.window.fullscreen_state({internal=' + str(mode) + ',client=' + str(mode) + ',action="set"}),{})')
    ok('eval hl.bind("SUPER + h",hl.dsp.layout("mfact -0.025"),{})')
    ok('eval hl.bind("SUPER + l",hl.dsp.layout("mfact +0.025"),{})')
    for source, name in (('virtual-keyboard-unstable-v1', 'virtual-keyboard'), ('wlr-virtual-pointer-unstable-v1', 'virtual-pointer')):
        for mode, extension in (('client-header', 'h'), ('private-code', 'c')):
            subprocess.run(['wayland-scanner', mode, str(FORK / 'protocols' / (source + '.xml')), str(BASE / (name + '.' + extension))], check=True)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    subprocess.run(['cc', '-I' + str(BASE), str(FORK / 'hyprtester/multiseat/input.c'), str(BASE / 'virtual-keyboard.c'), str(BASE / 'virtual-pointer.c'), '-o', str(BASE / 'input'), *flags], check=True)
    keyboard = subprocess.Popen([str(BASE / 'input'), 'Hyprland', 'human'], env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(BASE / 'input.log', 'w'), text=True, start_new_session=True)
    PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'ready'
    for name in ('human-window', 'human-second', 'human-third'):
        start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', name, BASE / (name + '.txt')], name)
    wait(lambda: len(ctl('clients', True)) == 3)
    click_entry('human-window')
    legacy_geometry = geometry('human-')
    legacy_error = ctl('dispatch layoutmsg mfact +0.025')
    assert legacy_error != 'ok' and geometry('human-') == legacy_geometry, legacy_error
    (BASE / 'legacy-layoutmsg-error.json').write_text(json.dumps({'error': legacy_error, 'version': ctl('version', True)}, indent=2))
    record('legacy layoutmsg dispatcher is rejected without changing human layout; native H/L bindings exercise the supported path')
    focus_cycles()
    adjust_ratio('human-')
    human = human_state()
    main_geometry = geometry('human-')
    cli('create', 'agent1', '--virtual-output', '1280x800'); cli('resume', 'agent1')
    for name in ('agent-first', 'agent-second', 'agent-third'):
        cli('launch', 'agent1', '--', '/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', name, BASE / (name + '.txt'))
        wait(lambda: any(item['title'] == name for item in ctl('clients', True)))
    seat = cli('state', 'agent1')
    assert ctl('seat present agent1 ' + seat['display'] + ' human current ' + OWNER, True)['active']
    assert ctl('seat present-control ' + OWNER + ' yes', True)['humanControl']
    click_entry('agent-first', 'agent1')
    focus_cycles('agent1')
    adjust_ratio('agent-', 'human-')
    wait(lambda: widgets_settled('agent-'), timeout=3)
    time.sleep(.08)
    subprocess.run(['grim', '-o', 'human', str(BASE / 'native-agent-tiled-shortcuts.png')], env=ENV, check=True)
    ctl('seat present-control ' + OWNER + ' no', True)
    readonly_focus = ctl('seat state agent1', True)['windowAddress']
    readonly_geometry = geometry('agent-')
    for code in (35, 38, 36, 37):
        shortcut(code); time.sleep(.1)
        assert geometry('agent-') == readonly_geometry and ctl('seat state agent1', True)['windowAddress'] == readonly_focus
        assert geometry('human-') == main_geometry and ctl('activewindow', True)['address'] == human['window']
    record('read-only native view blocks each physical H/L/J/K shortcut independently without changing either desktop')
    ok('seat unpresent ' + OWNER)
    wait(lambda: human_state() == human)
    record('leaving the native Agent desktop restores the exact human window, workspace, cursor and output state')
    # Human special workspaces must not resize the hidden ordinary workspace.
    ok('dispatch hl.dsp.workspace.toggle_special("layout-shortcuts")')
    for name in ('special-first', 'special-second'):
        start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', name, BASE / (name + '.txt')], name)
        wait(lambda: any(item['title'] == name and item['workspace']['type'] == 'special' for item in ctl('clients', True)))
    special_agent = geometry('agent-')
    adjust_ratio('special-', 'human-')
    assert geometry('agent-') == special_agent
    wait(lambda: widgets_settled('special-'), timeout=3)
    time.sleep(.08)
    subprocess.run(['grim', '-o', 'human', str(BASE / 'human-special-layout-shortcuts.png')], env=ENV, check=True)
    ok('dispatch hl.dsp.workspace.toggle_special("layout-shortcuts")')
    assert geometry('human-') == main_geometry
    receipt = {'checks': results, 'legacyError': legacy_error, 'policy': ctl('getoption misc:on_focus_under_fullscreen', True), 'version': ctl('version', True)}
    (BASE / 'layout-shortcuts-result.json').write_text(json.dumps(receipt, indent=2))
    print('RESULT', json.dumps(results), flush=True)
finally:
    cleanup()
