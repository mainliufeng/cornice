"""Exercise Hyprvoice's production destination and paste code on real seats.

Only the already recognized transcript is fixed test data. This does not test
microphone recording, ASR accuracy or the deployed user's physical F8 key.
"""
from desktop_harness import *
import hashlib
from types import SimpleNamespace

PROBE = pathlib.Path(os.environ['CORNICE_TEST_VOICE_PROBE'])
OWNER = 'voice-seat-native-owner-token-0000000001'
config = BASE / 'hyprvoice.json'
captured = BASE / 'hotkey-target.json'
paths = {}
checks = []


def check(description):
    checks.append(description)
    record(description)


def contents():
    return {name: path.read_text() if path.exists() else '' for name, path in paths.items()}


def send(event):
    keyboard.stdin.write(event + '\n')
    keyboard.stdin.flush()
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'done', event


def key(code):
    send(f'key {code} 1')
    send(f'key {code} 0')


def workspace(slot):
    for event in ('mods 64', 'key 125 1', f'key {slot + 1} 1', f'key {slot + 1} 0', 'key 125 0', 'mods 0'):
        send(event)


def client(name):
    return next((item for item in ctl('clients', True) if item['title'] == name), None)


def click_entry(name, seat=None):
    window = wait(lambda: client(name))
    geometry = wait(lambda: json.loads(paths[name].with_suffix('.geometry').read_text()))
    offset = cli('state', seat)['position'] if seat else [0, 0]
    x, y, width, height = geometry['entry']
    send(f"motion {round(window['at'][0] - offset[0] + x + width / 2)} {round(window['at'][1] - offset[1] + y + height / 2)}")
    send('button 272 1')
    send('button 272 0')
    wait(lambda: ctl('seat input-target', True).get('window', {}).get('address') == window['address'])
    return window


def capture_hotkey(name):
    captured.unlink(missing_ok=True)
    key(66)  # Linux KEY_F8, delivered by the real primary wl_keyboard.
    value = wait(lambda: json.loads(captured.read_text()), timeout=8)
    destination = BASE / (name + '.json')
    destination.write_text(json.dumps(value))
    return destination, value


def daemon_request(action, succeeds=True, **params):
    request = dict(params, action=action)
    daemon.stdin.write(json.dumps(request) + '\n')
    daemon.stdin.flush()
    assert select.select([daemon.stdout], [], [], 12)[0], ('production Desktop server timed out', request)
    reply = json.loads(daemon.stdout.readline())
    assert reply['ok'] == succeeds, (request, reply)
    return SimpleNamespace(returncode=0 if reply['ok'] else 1, stdout=json.dumps(reply), stderr=reply.get('error', ''))


def probe(action, path, text=None, succeeds=True):
    if action in ('paste', 'rebind-paste'):
        return daemon_request(action, path=str(path), text=text, succeeds=succeeds)
    args = [str(PROBE), str(config), action, str(path)]
    if text is not None:
        args.append(text)
    result = subprocess.run(args, env=ENV, capture_output=True, text=True, timeout=12)
    if succeeds:
        assert result.returncode == 0, (action, result.stdout, result.stderr)
    else:
        assert result.returncode != 0, (action, result.stdout, result.stderr)
    return result


def reject_paste(path, description, action='paste'):
    before = contents()
    result = probe(action, path, '不应插入的过期语音', succeeds=False)
    time.sleep(.15)
    assert contents() == before, (description, before, contents())
    (BASE / (path.stem + '-rejection.txt')).write_text(result.stderr)
    check(description)


def show(name, control=True):
    state = cli('state', name)
    answer = ctl('seat present ' + name + ' ' + state['display'] + ' human current ' + OWNER, True)
    assert answer['active'], answer
    if control:
        answer = ctl('seat present-control ' + OWNER + ' yes', True)
        assert answer['humanControl'], answer
    return answer


def keepalive():
    ctl('seat presentation ' + OWNER)


def clipboard(seat='Hyprland'):
    return subprocess.check_output(['wl-paste', '--seat', seat, '--no-newline', '--type', 'text'], env=ENV, text=True, timeout=3, stderr=subprocess.PIPE)


def agent_shell(name, *args):
    digest = hashlib.sha256(ENV['HYPRLAND_INSTANCE_SIGNATURE'].encode()).hexdigest()[:8]
    environment = dict(ENV, CORNICE_SHELL_SOCKET=str(RT / ('cs-' + digest + '-' + name + '.sock')))
    return subprocess.check_output([str(PRODUCT / 'bin/cornice'), *args], env=environment, text=True, stderr=subprocess.PIPE, timeout=8).strip()


try:
    # Exec bindings inherit the compositor environment as well as the probe.
    # Use the fork's genuine CLI, never an RPC test double or host socket.
    ENV['PATH'] = str(FORK / 'build-agent-session/hyprctl') + os.pathsep + ENV['PATH']
    initialize()
    assert 'human-input-target-v1' in ctl('seat capabilities', True)['features']
    config.write_text('{}')
    # One retained production Desktop owns every seat's clipboard, exactly as
    # the daemon does when a user moves between their own and Agent desktops.
    daemon = subprocess.Popen([str(PROBE), str(config), 'serve'], env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=open(BASE / 'voice-daemon.log', 'w'), text=True, start_new_session=True)
    PROCESSES.append(daemon)
    for source, name in (('virtual-keyboard-unstable-v1', 'virtual-keyboard'), ('wlr-virtual-pointer-unstable-v1', 'virtual-pointer')):
        for mode, extension in (('client-header', 'h'), ('private-code', 'c')):
            subprocess.run(['wayland-scanner', mode, str(FORK / 'protocols' / (source + '.xml')), str(BASE / (name + '.' + extension))], check=True)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    subprocess.run(['cc', '-I' + str(BASE), str(FORK / 'hyprtester/multiseat/input.c'), str(BASE / 'virtual-keyboard.c'),
                    str(BASE / 'virtual-pointer.c'), '-o', str(BASE / 'human-input'), *flags], check=True)
    keyboard = subprocess.Popen([str(BASE / 'human-input'), 'Hyprland', 'human'], env=ENV, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=open(BASE / 'human-input.log', 'w'), text=True, start_new_session=True)
    PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'ready'
    command = shlex.join([str(PROBE), str(config), 'capture', str(captured)])
    ok('eval hl.bind("F8",hl.dsp.exec_cmd(' + json.dumps(command) + '),{})')

    paths['human-window'] = BASE / 'human.txt'
    start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', 'human-window', paths['human-window']], 'human-client')
    window = click_entry('human-window')
    human_capture, target = capture_hotkey('human-first')
    assert target['seat'] == 'Hyprland' and target['address'] == window['address'] and target['pid'] == window['pid'], target
    probe('paste', human_capture, '人类语音测试。')
    wait(lambda: contents()['human-window'] == '人类语音测试。')
    check('primary-seat F8 captures the genuine human application; production UTF-8 paste reaches its GTK input')

    sentinel = 'primary clipboard must survive agent voice input'
    daemon_request('copy', seat='Hyprland', text=sentinel)
    wait(lambda: clipboard() == sentinel)

    for name in ('agent1', 'agent2'):
        cli('create', name, '--virtual-output', '1280x800')
        cli('resume', name)
        cli('view-workspace', name, '1')
    for name, seat in (('agent1-window', 'agent1'), ('agent1-other', 'agent1'), ('agent2-window', 'agent2')):
        paths[name] = BASE / (name + '.txt')
        cli('launch', seat, '--', '/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', name, paths[name])
        wait(lambda: client(name) and paths[name].with_suffix('.geometry').exists())
    show('agent1')
    first = click_entry('agent1-window', 'agent1')
    agent_capture, target = capture_hotkey('agent1-first')
    assert target['seat'] == 'agent1' and target['address'] == first['address'] and target['pid'] == first['pid'], target
    probe('paste', agent_capture, 'Agent 一号语音测试。')
    wait(lambda: contents()['agent1-window'] == 'Agent 一号语音测试。')
    assert contents()['human-window'] == '人类语音测试。' and contents()['agent1-other'] == '' and contents()['agent2-window'] == ''
    assert clipboard() == sentinel and clipboard('agent1') == 'Agent 一号语音测试。'
    subprocess.run(['grim', '-o', 'human', str(BASE / 'agent1-voice-paste.png')], env=ENV, check=True)
    check('physical-seat F8 during native Agent takeover captures agent1; production clipboard paste reaches only its focused GTK input and preserves the human clipboard')

    keepalive()
    answer = ctl('seat present-control ' + OWNER + ' no', True)
    assert not answer['humanControl']
    result = probe('capture', BASE / 'readonly-target.json', succeeds=False)
    assert 'read only' in result.stderr
    captured.unlink(missing_ok=True)
    key(66)
    time.sleep(.2)
    assert not captured.exists(), 'readonly view forwarded F8 into the Agent'
    reject_paste(agent_capture, 'read-only observation rejects both fresh voice capture and a previously captured paste without editing any seat')

    ctl('seat present-control ' + OWNER + ' yes', True)
    click_entry('agent1-window', 'agent1')
    stale_workspace, before = capture_hotkey('stale-workspace')
    workspace(2)
    wait(lambda: cli('state', 'agent1')['workspaceName'] == 'cornice-agent-agent1-ws-2')
    workspace(1)
    click_entry('agent1-window', 'agent1')
    assert ctl('seat input-target', True)['token'] != before['token']
    reject_paste(stale_workspace, 'workspace away-and-back invalidates the original voice destination even when the same application is focused again')

    stale_focus, before = capture_hotkey('stale-focus')
    click_entry('agent1-other', 'agent1')
    reject_paste(stale_focus, 'explicit retry cannot rebind the original voice destination to a different application window', action='rebind-paste')
    click_entry('agent1-window', 'agent1')
    assert ctl('seat input-target', True)['token'] != before['token']
    reject_paste(stale_focus, 'window focus away-and-back invalidates the original voice destination without inserting into either application')
    probe('rebind-paste', stale_focus, '明确重提。')
    wait(lambda: contents()['agent1-window'] == 'Agent 一号语音测试。明确重提。')
    assert contents()['agent1-other'] == '' and clipboard() == sentinel
    check('explicit retry after returning to the original window rebinds its current seat token and fresh input guard before a single production paste')

    keepalive()
    agent_shell('agent1', 'ipc', 'shell', 'summon', 'cn.launcher', '{}')
    wait(lambda: any(item['id'] == 'cn.launcher' and item['open'] for item in json.loads(agent_shell('agent1', 'ipc', 'shell', 'windows'))))
    wait(lambda: not ctl('seat input-target', True)['allowed'])
    before = contents()
    launcher = probe('capture', BASE / 'launcher-target.json', succeeds=False)
    assert contents() == before and not (BASE / 'launcher-target.json').exists()
    (BASE / 'launcher-target-rejection.txt').write_text(launcher.stderr)
    agent_shell('agent1', 'ipc', 'shell', 'hide', 'cn.launcher')
    click_entry('agent1-window', 'agent1')
    check('the real Agent Launcher keyboard layer rejects voice capture instead of falling back to the underlying application')

    stale_view, before = capture_hotkey('stale-view')
    ok('seat unpresent ' + OWNER)
    show('agent1')
    click_entry('agent1-window', 'agent1')
    assert ctl('seat input-target', True)['token'] != before['token']
    reject_paste(stale_view, 'leaving and re-entering native takeover invalidates an old voice destination')

    show('agent2')
    second = click_entry('agent2-window', 'agent2')
    reject_paste(stale_view, 'explicit retry cannot rebind an agent1 result to a different seat', action='rebind-paste')
    second_capture, target = capture_hotkey('agent2-first')
    assert target['seat'] == 'agent2' and target['address'] == second['address'], target
    probe('paste', second_capture, 'Agent 二号语音测试。')
    wait(lambda: contents()['agent2-window'] == 'Agent 二号语音测试。')
    assert contents()['agent1-window'] == 'Agent 一号语音测试。明确重提。' and contents()['human-window'] == '人类语音测试。'
    assert clipboard() == sentinel and clipboard('agent1') == '明确重提。' and clipboard('agent2') == 'Agent 二号语音测试。'
    subprocess.run(['grim', '-o', 'human', str(BASE / 'agent2-voice-paste.png')], env=ENV, check=True)
    check('switching native takeover to agent2 routes fresh F8 capture and UTF-8 paste to agent2 while human and agent1 text and primary clipboard remain intact')

    ok('seat unpresent ' + OWNER)
    window = click_entry('human-window')
    final_capture, target = capture_hotkey('human-return')
    assert target['seat'] == 'Hyprland' and target['address'] == window['address'], target
    probe('paste', final_capture, '回到人的桌面。')
    wait(lambda: contents()['human-window'] == '人类语音测试。回到人的桌面。')
    assert contents()['agent1-window'] == 'Agent 一号语音测试。明确重提。' and contents()['agent2-window'] == 'Agent 二号语音测试。'
    assert clipboard('agent1') == '明确重提。' and clipboard('agent2') == 'Agent 二号语音测试。'
    subprocess.run(['grim', '-o', 'human', str(BASE / 'human-voice-return.png')], env=ENV, check=True)
    check('after leaving native Agent view, the same primary F8 binding and production paste return to the human application')
    result = {'checks': checks, 'contents': contents(), 'microphoneAsrTested': False, 'productionDestinationAndPasteTested': True, 'longLivedDesktopAcrossSeats': True}
    (BASE / 'voice-seat-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False), flush=True)
finally:
    cleanup()
