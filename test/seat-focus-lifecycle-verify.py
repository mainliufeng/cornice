"""Native close/focus policies and real xdg activation in isolated desktops."""
from desktop_harness import *

OWNER = None
checks = []
failures = []
references = {}


def heartbeat():
    if OWNER:
        value = rpc(OWNER, 'present-status', {'name': 'agent1'})
        assert value['active'] and value['humanControl'], value


def physical(command):
    heartbeat()
    keyboard.stdin.write(command + '\n'); keyboard.stdin.flush()
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'done', command


def dispatch(code, seat=None):
    heartbeat()
    if seat:
        state = cli('state', seat)
        answer = ctl('seat dispatch ' + seat + ' ' + state['display'] + ' ' + str(state['generation']) + ' ' + code)
        assert answer == 'ok', (code, answer)
    else:
        ok('dispatch ' + code)


def active(seat=None):
    address = ctl('seat state ' + seat, True)['windowAddress'] if seat else ctl('activewindow', True).get('address')
    return next((window for window in ctl('clients', True) if window['address'] == address), None)


def focus(window, seat=None):
    dispatch('hl.dsp.focus({window="address:' + window['address'] + '"})', seat)
    wait(lambda: active(seat) and active(seat)['address'] == window['address'])


def mode(value, seat=None):
    dispatch('hl.dsp.window.fullscreen_state({internal=' + str(value) + ',client=' + str(value) + ',action="set"})', seat)
    wait(lambda: active(seat) and active(seat)['fullscreen'] == value)


def client(title):
    return next((window for window in ctl('clients', True) if window['title'] == title), None)


def launch(title, seat=None):
    command = ['/usr/bin/python3', ROOT/'test/agent-desktop-client.py', title, BASE/(title+'.txt')]
    if seat and OWNER:
        dispatch('hl.dsp.exec_cmd(' + json.dumps(shlex.join(map(str,command))) + ')', seat)
    elif seat:
        cli('launch', seat, '--', *command)
    else:
        start(command, title)
    return wait(lambda: client(title))


def preserve_others():
    current = human_state()
    assert all(current[key] == human[key] for key in ('workspace','window','output')), (current,human)
    assert cli('state', 'agent2')['windowAddress'] == other['windowAddress']
    assert cli('state', 'agent2')['workspaceName'] == other['workspaceName']
    assert (BASE/'other-window.txt').read_text() == 'other-sentinel'
    assert (BASE/'human-window.txt').read_text() == 'human-sentinel'


def close_case(subject, fullscreen, focus_close, retain):
    seat = subject if subject != 'human' else None
    name = f'{subject}-m{fullscreen}-c{focus_close}-r{retain}'
    ok('eval hl.config({input={focus_on_close=' + str(focus_close) + ',follow_mouse=0},misc={exit_window_retains_fullscreen=' + str(retain) + '}})')
    windows = [launch(name+'-'+str(index), seat) for index in range(3)]
    target = windows[2]
    focus(target, seat)
    mode(fullscreen, seat)
    # After closing the bottom-right slave, the native next candidate differs
    # from the oldest surviving window. Cursor policy deliberately selects it.
    offset = cli('state', seat)['position'] if seat else [0, 0]
    pointed = windows[1]
    physical(f"motion {round(pointed['at'][0]-offset[0]+pointed['size'][0]/2)} {round(pointed['at'][1]-offset[1]+pointed['size'][1]/2)}")
    assert active(seat)['address'] == target['address']
    dispatch('hl.dsp.window.close({window="address:' + target['address'] + '"})', seat)
    wait(lambda: client(target['title']) is None)
    # Native unmap focus is synchronous; give client configure/geometry a turn.
    time.sleep(.12)
    heartbeat()
    focused = active(seat)
    index = next((i for i, window in enumerate(windows) if focused and window['address'] == focused['address']), None)
    actual_mode = focused['fullscreen'] if focused else None
    expected_mode = fullscreen if fullscreen and retain in (1, 3) else 0
    item = {'subject': subject, 'mode': fullscreen, 'focusOnClose': focus_close, 'retain': retain,
            'candidateIndex': index, 'candidateMode': actual_mode, 'expectedMode': expected_mode}
    key = (fullscreen, focus_close, retain)
    if not seat:
        assert index is not None and actual_mode == expected_mode, item
        references[key] = index
    else:
        if index != references[key] or actual_mode != expected_mode:
            failures.append(dict(item, expectedIndex=references[key]))
        else:
            # A physical key must reach the selected survivor without clicking
            # or using an explicit focus command to repair the compositor.
            title = focused['title']
            physical('type survivor')
            text_path = BASE/(title+'.txt')
            try:
                wait(lambda: text_path.exists() and text_path.read_text() == 'survivor', timeout=2)
            except RuntimeError:
                failures.append(dict(item, actualInput=text_path.read_text() if text_path.exists() else None))
        preserve_others()
        subprocess.run(['grim', '-o', 'human', str(BASE/(name+'.png'))], env=ENV, check=True)
    checks.append(item)
    (BASE/'focus-lifecycle.json').write_text(json.dumps({'checks': checks, 'failures': failures}, indent=2))
    for window in windows:
        remaining = client(window['title'])
        if remaining:
            dispatch('hl.dsp.window.close({window="address:' + remaining['address'] + '"})', seat)
    wait(lambda: not any(client(window['title']) for window in windows))
    print('OBSERVED',name,'native close candidate/mode',str((index,actual_mode)),flush=True)


def activation_cases(seat=None):
    label = seat or 'human'
    helper_env = ENV | {'MULTISEAT_SEAT': seat or 'Hyprland'}
    if seat: helper_env['WAYLAND_DISPLAY'] = cli('state', seat)['display']
    blocker = launch(label+'-activation-blocker', seat)
    process = subprocess.Popen([str(BASE/'activation-client')], env=helper_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=open(BASE/(label+'-activation.log'),'w'), text=True, start_new_session=True)
    PROCESSES.append(process)
    try:
        assert select.select([process.stdout],[],[],5)[0] and process.stdout.readline().strip() == 'ready'
        target = wait(lambda: client('constraints-window'))
        def command(value):
            heartbeat()
            process.stdin.write(value+'\n');process.stdin.flush()
            assert select.select([process.stdout],[],[],5)[0], ('activation helper response', value)
            return process.stdout.readline().strip()
        for fullscreen in (1,2):
            for enabled, policy in ((False,2),(True,0),(True,1),(True,2)):
                mode(0,seat)
                ok('eval hl.config({misc={focus_on_activate=' + str(enabled).lower() + ',on_focus_under_fullscreen=' + str(policy) + ',exit_window_retains_fullscreen=0}})')
                focus(target,seat)
                # A real key event supplies the requesting application's valid,
                # single-use seat serial; the helper mints an actual xdg token.
                physical('key 42 1');physical('key 42 0')
                assert int(command('keys')) > 0
                focus(blocker,seat);mode(fullscreen,seat)
                assert command('activate') == 'done'
                time.sleep(.12)
                focused = active(seat)
                expected = target if enabled and policy in (1,2) else blocker
                expected_mode = fullscreen if expected is blocker or policy == 1 else 0
                item = {'subject':label,'activation':True,'mode':fullscreen,'focusOnActivate':enabled,'fullscreenPolicy':policy,
                        'actualFocus':focused['title'] if focused else None,'actualMode':focused['fullscreen'] if focused else None,
                        'expectedFocus':expected['title'],'expectedMode':expected_mode}
                if not focused or focused['address'] != expected['address'] or focused['fullscreen'] != expected_mode:
                    failures.append(item)
                if focused and focused['address'] == target['address'] and focused.get('urgent'):
                    failures.append(dict(item, urgentNotCleared=True))
                checks.append(item)
                (BASE/'focus-lifecycle.json').write_text(json.dumps({'checks':checks,'failures':failures},indent=2))
                if seat: preserve_others()
                print('OBSERVED',label,'real xdg activation',json.dumps(item),flush=True)
    finally:
        process.terminate();process.wait(timeout=5)
        remaining = client(blocker['title'])
        if remaining: dispatch('hl.dsp.window.close({window="address:' + blocker['address'] + '"})',seat)
        wait(lambda: client('constraints-window') is None and client(blocker['title']) is None)


try:
    initialize()
    ok('eval hl.config({general={layout="master",gaps_in=0,gaps_out=0,border_size=0},master={mfact=0.5,orientation="left",focus_master_on_close=false},input={follow_mouse=0},misc={on_focus_under_fullscreen=2}})')
    for source, name in (('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')):
        for scan, ext in (('client-header','h'),('private-code','c')):
            subprocess.run(['wayland-scanner',scan,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+ext))],check=True)
    flags = subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'input'),*flags],check=True)
    keyboard = subprocess.Popen([str(BASE/'input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                                stderr=open(BASE/'input.log','w'),text=True,start_new_session=True)
    PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip() == 'ready'
    for xml, name in (('/usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml','constraints'),
                      ('/usr/share/wayland-protocols/unstable/relative-pointer/relative-pointer-unstable-v1.xml','relative-pointer'),
                      ('/usr/share/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml','activation')):
        for scan, ext in (('client-header','h'),('private-code','c')):
            subprocess.run(['wayland-scanner',scan,xml,str(BASE/(name+'.'+ext))],check=True)
    flags = subprocess.check_output(['pkg-config','--cflags','--libs','gtk+-3.0','wayland-client'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/constraints.c'),str(BASE/'constraints.c'),str(BASE/'relative-pointer.c'),str(BASE/'activation.c'),'-o',str(BASE/'activation-client'),*flags],check=True)
    cases = [(m,0,0) for m in (0,1,2)] + [(m,0,r) for m in (1,2) for r in (1,2,3)] + [(m,1,0) for m in (0,1,2)]
    # Record the genuine primary policy's candidate; the Agent must select the
    # same layout/cursor candidate and preserve the same fullscreen mode.
    dispatch('hl.dsp.focus({workspace="3"})')
    if os.getenv('CORNICE_TEST_FOCUS_PHASE') != 'activation':
        for case in cases: close_case('human',*case)
    activation_cases()
    dispatch('hl.dsp.focus({workspace="1"})')
    sentinel = launch('human-window')
    focus(sentinel)
    physical('type human-sentinel')
    wait(lambda: (BASE/'human-window.txt').read_text() == 'human-sentinel')
    physical('motion 440 510')
    human = human_state()
    for name in ('agent1','agent2'):
        cli('create',name,'--virtual-output','1280x800');cli('resume',name)
    launch('other-window','agent2')
    binding = bind('agent2');shot = tool(binding,'capture')
    tool(binding,'input',{'frameId':shot['frameId'],'action':'text','text':'other-sentinel'})
    wait(lambda: (BASE/'other-window.txt').read_text() == 'other-sentinel')
    other = cli('state','agent2')
    OWNER = socket.socket(socket.AF_UNIX);OWNER.settimeout(5)
    OWNER.connect(str(RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']/'desktop.sock'))
    assert rpc(OWNER,'present',{'name':'agent1'})['native']
    assert rpc(OWNER,'takeover',{'name':'agent1'})['humanControl']
    if os.getenv('CORNICE_TEST_FOCUS_PHASE') != 'activation':
        for case in cases: close_case('agent1',*case)
    activation_cases('agent1')
    OWNER.close();OWNER = None
    wait(lambda: human_state() == human)
    (BASE/'focus-lifecycle.json').write_text(json.dumps({'checks':checks,'failures':failures,'version':ctl('version',True)},indent=2))
    assert not failures, failures
    record('Agent close and real xdg activation match native focus/fullscreen policies without disturbing human/agent2')
finally:
    if OWNER: OWNER.close()
    cleanup()
