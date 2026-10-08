"""Exercise the actual fullscreen switcher and socket-owned human input lease."""
from desktop_harness import *


def send(command):
    keyboard.stdin.write(command + '\n'); keyboard.stdin.flush()
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'done', command


def status():
    return json.loads(shell('ipc', 'desktopObserver', 'status'))


def click(x, y):
    for event in (f'motion {round(x)} {round(y)}', 'button 272 1', 'button 272 0'):
        send(event)


def control(name):
    menus = json.loads(shell('ipc','desktopObserver','controls'))
    icon = next(item for item in menus if item['name'] == ('status' if name in ('run','takeover','prompt','cancel') else 'switch'))
    send(f"motion {round(icon['x']+icon['width']/2)} {round(icon['y']+icon['height']/2)}")
    def ready():
        row = next((item for item in json.loads(shell('ipc', 'desktopObserver', 'controls')) if item['name'] == name), None)
        if not row or not row.get('enabled', True): return None
        if name == 'run':
            expected = '运行 Agent' if cli('state', status()['name'])['paused'] else '暂停 Agent'
            if row['label'] != expected: return None
        return row
    row = wait(ready)
    wait(lambda: any(item['namespace'] == 'cornice-desktop-menu' for item in ctl('layers',True)['human']['levels']['3']))
    time.sleep(.1)
    click(row['x'] + row['width'] / 2, row['y'] + row['height'] / 2)

def entry(name, field="entry"):
    state = cli('state', name)
    client = next(c for c in ctl('clients', True) if c['title'] == name + '-window')
    geometry = json.loads((BASE / (name + '.geometry')).read_text())[field]
    layer = next(item for item in ctl('layers', True)['human']['levels']['2'] if item['namespace'] == 'cornice-desktop')
    # Private output has exactly the view's physical size and output scale.
    logical = state['logicalSize']
    toolbar = layer['h'] - logical[1]
    click(client['at'][0] - state['position'][0] + geometry[0] + geometry[2] / 2,
          toolbar + client['at'][1] - state['position'][1] + geometry[1] + geometry[3] / 2)


def rejected(connection, method, params):
    connection.sendall((json.dumps({'id': str(time.monotonic_ns()), 'method': method, 'params': params}) + '\n').encode())
    data = b''
    while True:
        while b'\n' not in data: data += connection.recv(65536)
        line, data = data.split(b'\n', 1)
        reply = json.loads(line)
        if 'event' in reply: continue
        assert not reply['ok'], reply
        return reply['error']

try:
    initialize()
    for index in range(1, 4):
        cli('create', 'agent' + str(index), '--workspace', str(10 + index), '--virtual-output', '1280x800')
        cli('resume', 'agent' + str(index))
    # Pinyin runs solely on this sandbox's user bus and Wayland sockets.
    profile = BASE / 'config/fcitx5/profile'; profile.parent.mkdir(parents=True, exist_ok=True)
    profile.write_text('[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=pinyin\n\n[Groups/0/Items/0]\nName=keyboard-us\n\n[Groups/0/Items/1]\nName=pinyin\n\n[GroupOrder]\n0=Default\n')
    ENV.update(QT_IM_MODULE='fcitx', XMODIFIERS='@im=fcitx')
    fcitx = start(['fcitx5', '-D', '--disable=vinput,cloudpinyin'], 'fcitx')
    wait(lambda: 'true' in subprocess.run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus', '--object-path', '/org/freedesktop/DBus', '--method', 'org.freedesktop.DBus.NameHasOwner', 'org.fcitx.Fcitx5'], env=ENV, capture_output=True, text=True).stdout)
    subprocess.run(['fcitx5-remote', '-c'], env=ENV, check=True)
    start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', 'human-window', BASE / 'human.txt'], 'human')
    for index in range(1, 4):
        name = 'agent' + str(index)
        cli('launch', name, '--', '/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', name + '-window', BASE / (name + '.txt'))
    wait(lambda: len(ctl('clients', True)) == 4)
    ok('dispatch hl.dsp.focus({window="title:^human-window$"})')
    human = human_state()
    agent3 = cli('state', 'agent3')
    previous = bind('agent1')
    for source, name in (('virtual-keyboard-unstable-v1', 'virtual-keyboard'), ('wlr-virtual-pointer-unstable-v1', 'virtual-pointer')):
        for mode, extension in (('client-header', 'h'), ('private-code', 'c')):
            subprocess.run(['wayland-scanner', mode, str(FORK / 'protocols' / (source + '.xml')), str(BASE / (name + '.' + extension))], check=True)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    input_source = (FORK / 'hyprtester/multiseat/input.c').read_text()
    input_source = input_source.replace('        } else if (sscanf(line, "relative', '''        } else if (sscanf(line, "scroll %d", &dy) == 1) {
            zwlr_virtual_pointer_v1_axis_source(pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
            zwlr_virtual_pointer_v1_axis_discrete(pointer, now(), WL_POINTER_AXIS_VERTICAL_SCROLL, wl_fixed_from_int(dy), dy / 10);
            zwlr_virtual_pointer_v1_frame(pointer);
        } else if (sscanf(line, "relative''')
    (BASE / 'human-input.c').write_text(input_source)
    subprocess.run(['cc', '-I' + str(BASE), str(BASE / 'human-input.c'), str(BASE / 'virtual-keyboard.c'), str(BASE / 'virtual-pointer.c'), '-o', str(BASE / 'human-input'), *flags], check=True)
    keyboard = subprocess.Popen([str(BASE / 'human-input'), 'Hyprland', 'human'], env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(BASE / 'keyboard.log', 'w'), text=True, start_new_session=True)
    PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'ready'
    ok('eval hl.monitor({output="human",mode="2560x1600",position="0x0",scale=2})')
    config = BASE / 'config/cornice'; config.mkdir(parents=True, exist_ok=True)
    (config / 'config.json').write_text(json.dumps({'agentDesktop': {'enabled': True}, 'bar': {'layout': {'left': [{'id': 'cn.agent-desktop'}], 'center': [], 'right': []}}, 'background': {'enabled': False}, 'weather': {'intervalMinutes': 0}, 'idle': {'lock': 0, 'screenOffAc': 0, 'screenOffBattery': 0, 'dimAc': 0, 'dimBattery': 0, 'lockOnSleep': False, 'lockOnLockSignal': False, 'lockOnLidClose': False}}))
    qs = start([str(PRODUCT / 'bin/cornice-qs'), '-p', str(PRODUCT / 'shell')], 'cornice')
    wait(lambda: json.loads(shell('ipc', 'desktop', 'status'))['available'])
    # Use the actual bar button, then the fullscreen toolbar for every switch.
    layer = wait(lambda: next((item for item in ctl('layers', True)['human']['levels']['2'] if item['namespace'] == 'cornice-bar'), None))
    widget = next(item for item in json.loads(shell('ipc', 'bar', 'geometry')) if item['id'] == 'cn.agent-desktop')
    icon = next(item for item in widget['controls'] if item['name'] == 'switch')
    send(f"motion {round(icon['x']+icon['width']/2)} {round(icon['y']+icon['height']/2)}")
    def bar_agent():
        widget = next(item for item in json.loads(shell('ipc','bar','geometry')) if item['id'] == 'cn.agent-desktop')
        return next((item for item in widget['controls'] if item['name'] == 'agent1'),None)
    row = wait(bar_agent)
    wait(lambda: any(item['namespace'] == 'cornice-desktop-menu' for item in ctl('layers',True)['human']['levels']['3']))
    time.sleep(.15)
    subprocess.run(['grim','-o','human',str(BASE/'hover-menu.png')],env=ENV,check=True)
    click(row['x']+row['width']/2,row['y']+row['height']/2)
    wait(lambda: status()['open'] and status()['name'] == 'agent1')
    view = wait(lambda: status() if status()['frame'].get('scale') == 2 else None)
    ok('dismissnotify -1')
    layer = next(item for item in ctl('layers', True)['human']['levels']['2'] if item['namespace'] == 'cornice-desktop')
    assert [layer[k] for k in ('x', 'y', 'w', 'h')] == [0, 0, 1280, 800], layer
    assert view['readonly'] and view['fullscreen'] and view['frame']['pixelSize'][0] == 2560
    assert cli('state', 'agent3') == agent3
    subprocess.run(['grim', '-o', 'human', str(BASE / 'fullscreen-readonly-2x.png')], env=ENV, check=True)
    before = status(); time.sleep(2); after = status()
    fps = (after['paintedFrames'] - before['paintedFrames']) * 1000 / (after['lastPaintMs'] - before['lastPaintMs'])
    assert fps >= 13, fps
    (BASE / 'fullscreen-performance.json').write_text(json.dumps({'paintedFpsAt2x': round(fps, 2)}))
    send('type blocked')
    assert not (BASE / 'agent1.txt').exists() and not (BASE / 'human.txt').exists()
    record('actual fullscreen read-only UI occupies the entire output; private client renders at matching 2x scale')
    control('takeover')
    wait(lambda: status()['humanControl'])
    assert cli('state', 'agent1')['controlMode'] == 'human'
    assert 'revoked' in tool(previous, 'state', succeeds=False)
    assert 'human control' in cli('resume', 'agent1', succeeds=False).lower()
    assert 'human control' in cli('bind', 'agent1', BASE / 'denied.binding', succeeds=False).lower()
    entry('agent1'); send('type human')
    wait(lambda: (BASE / 'agent1.txt').read_text() == 'human')
    assert not (BASE / 'human.txt').exists() and not (BASE / 'agent2.txt').exists()
    record('real human-seat pointer and keyboard operate the Agent application; prior agent binding and resume are rejected')
    subprocess.run(['fcitx5-remote', '-o'], env=ENV, check=True)
    send('type nihao'); time.sleep(.5)
    subprocess.run(['grim', '-o', 'human', str(BASE / 'takeover-pinyin-preedit.png')], env=ENV, check=True)
    send('key 57 1'); send('key 57 0')
    wait(lambda: (BASE / 'agent1.txt').read_text() == 'human你好')
    subprocess.run(['fcitx5-remote', '-c'], env=ENV, check=True)
    assert fcitx.poll() is None
    record('real Fcitx pinyin commits Chinese through the fullscreen viewer into the Agent GTK entry')
    subprocess.run(['grim', '-o', 'human', str(BASE / 'fullscreen-takeover-2x.png')], env=ENV, check=True)
    # Test modifiers and application shortcuts through the real input path.
    for event in ('key 29 1', 'key 30 1', 'key 30 0', 'key 29 0', 'type replaced'):
        send(event)
    wait(lambda: (BASE / 'agent1.txt').read_text() == 'replaced')
    record('application Ctrl+A and subsequent typing preserve modifier and key-release semantics')
    entry('agent1', 'button')
    wait(lambda: (BASE / 'agent1.click').read_text() == '1')
    state = cli('state', 'agent1')
    client = next(c for c in ctl('clients', True) if c['title'] == 'agent1-window')
    geometry = json.loads((BASE / 'agent1.geometry').read_text())['entry']
    y = client['at'][1] - state['position'][1] + geometry[1] + geometry[3] / 2
    x = client['at'][0] - state['position'][0] + geometry[0]
    for event in (f'motion {round(x + 10)} {round(y)}', 'button 272 1', f'motion {round(x + 300)} {round(y)}', 'button 272 0'):
        send(event)
        time.sleep(.15)
    wait(lambda: len(json.loads((BASE / 'agent1.geometry').read_text())['selection']) == 2)
    send('type dragged'); wait(lambda: (BASE / 'agent1.txt').read_text() == 'dragged')
    record('real pointer clicks activate an Agent button; drag selection and typing replace the selected text')
    control('takeover'); wait(lambda: not status()['humanControl'])
    wait(lambda: cli('state', 'agent1')['paused'])
    assert not status()['frame'].get('humanLocked')
    control('run'); wait(lambda: not cli('state', 'agent1')['paused'])
    resumed = bind('agent1')
    snapshot = tool(resumed, 'capture')
    tool(resumed, 'input', {'action': 'text', 'text': ' Agent恢复', 'frameId': snapshot['frameId']})
    wait(lambda: (BASE / 'agent1.txt').read_text() == 'dragged Agent恢复')
    record('ending takeover leaves Agent paused; explicit Run Agent restores real Unicode tool input while Fcitx remains active')
    control('takeover'); wait(lambda: status()['humanControl'])
    for event in ('key 29 1', 'key 56 1', 'mods 12', 'key 1 1', 'key 1 0', 'key 56 0', 'key 29 0', 'mods 0'):
        send(event)
    wait(lambda: not status()['humanControl'] and cli('state', 'agent1')['paused'])
    assert status()['open'], 'Ctrl+Alt+Esc ends takeover without hiding the viewer'
    record('Ctrl+Alt+Esc ends takeover through actual keyboard modifiers and leaves the Agent paused')
    control('takeover'); wait(lambda: status()['humanControl'])
    send('key 42 1')
    control('agent2'); wait(lambda: status()['name'] == 'agent2' and status()['frame'].get('frameId'))
    wait(lambda: cli('state', 'agent1')['paused'])
    assert status()['readonly'] and cli('state', 'agent2')['controlMode'] == 'agent'
    send('key 42 0'); send('type blocked')
    assert not (BASE / 'agent2.txt').exists()
    record('direct Agent-to-Agent switch releases held input and takeover; destination starts read-only')
    page = BASE / 'scroll.html'
    page.write_text('<meta charset="utf-8"><body style="height:12000px;font:32px sans-serif">真实 Chrome · 滚动测试<script>setInterval(()=>document.title="Scroll:"+Math.round(scrollY),100)</script>')
    cli('launch', 'agent2', '--', '/opt/google/chrome/google-chrome', '--ozone-platform=wayland', '--no-first-run', '--no-default-browser-check', page.as_uri())
    chrome = wait(lambda: next((c for c in ctl('clients', True) if c['title'].startswith('Scroll:')), None))
    OWNED_PIDS.append(chrome['pid'])
    control('takeover'); wait(lambda: status()['humanControl'])
    state = cli('state', 'agent2')
    chrome = next(c for c in ctl('clients', True) if c['pid'] == chrome['pid'])
    x = chrome['at'][0] - state['position'][0] + chrome['size'][0] / 2
    y = 60 + chrome['at'][1] - state['position'][1] + chrome['size'][1] / 2
    click(x, y)
    wait(lambda: cli('state', 'agent2')['window'].startswith('Scroll:'))
    send('scroll 120')
    wait(lambda: any(c['title'].startswith('Scroll:') and int(c['title'].split(':', 1)[1].split(' ')[0]) > 0 for c in ctl('clients', True)), timeout=5)
    record('a real human wheel event scrolls actual Chrome content on the Agent desktop')
    control('takeover'); wait(lambda: cli('state', 'agent2')['paused'])
    control('run'); wait(lambda: not cli('state', 'agent2')['paused'])
    os.kill(chrome['pid'], signal.SIGTERM)
    wait(lambda: not any(c['pid'] == chrome['pid'] for c in ctl('clients', True)))
    control('run'); wait(lambda: cli('state', 'agent2')['paused'])
    control('run'); wait(lambda: not cli('state', 'agent2')['paused'])
    control(''); wait(lambda: not status()['open'])
    assert ctl('activeworkspace', True)['id'] == human['workspace']['id']
    assert ctl('activewindow', True)['address'] == human['window']
    assert cli('state', 'agent3') == agent3
    record('human button returns to the original human window/workspace; another running Agent remains unchanged')
    widget = next(item for item in json.loads(shell('ipc', 'bar', 'geometry')) if item['id'] == 'cn.agent-desktop')
    icon = next(item for item in widget['controls'] if item['name'] == 'switch')
    send(f"motion {round(icon['x']+icon['width']/2)} {round(icon['y']+icon['height']/2)}")
    def bar_agent():
        widget = next(item for item in json.loads(shell('ipc','bar','geometry')) if item['id'] == 'cn.agent-desktop')
        return next((item for item in widget['controls'] if item['name'] == 'agent1'),None)
    row = wait(bar_agent)
    wait(lambda: any(item['namespace'] == 'cornice-desktop-menu' for item in ctl('layers',True)['human']['levels']['3']))
    time.sleep(.15)
    subprocess.run(['grim','-o','human',str(BASE/'hover-menu.png')],env=ENV,check=True)
    click(row['x']+row['width']/2,row['y']+row['height']/2)
    wait(lambda: status()['open'] and status()['frame'].get('frameId'))
    wait(lambda: status()['keyboardReady'])
    send('key 1 1'); send('key 1 0'); wait(lambda: not status()['open'])
    record('Escape returns from read-only view without sending Escape to the Agent application')
    # The owner is a persistent socket, not a reusable agent credential.
    path = str(RT / 'cornice' / ENV['HYPRLAND_INSTANCE_SIGNATURE'] / 'desktop.sock')
    with socket.socket(socket.AF_UNIX) as owner, socket.socket(socket.AF_UNIX) as stranger:
        for connection in (owner, stranger): connection.settimeout(5); connection.connect(path)
        rpc(owner, 'takeover', {'name': 'agent1'})
        frame = rpc(owner, 'frame', {'name': 'agent1'})
        assert 'own' in rejected(stranger, 'human.input', {'name': 'agent1', 'frameId': frame['frameId'], 'events': [{'action': 'text', 'text': 'WRONG'}]}).lower()
        assert 'owns' in rejected(stranger, 'takeover', {'name': 'agent2'})
    wait(lambda: cli('state', 'agent1')['paused'])
    record('a second socket cannot steal takeover or inject input; owner disconnect pauses the Agent')
    with socket.socket(socket.AF_UNIX) as owner:
        owner.settimeout(5); owner.connect(path)
        rpc(owner, 'takeover', {'name': 'agent1'})
        frame = rpc(owner, 'frame', {'name': 'agent1'})
        rpc(owner, 'human.input', {'name': 'agent1', 'frameId': frame['frameId'], 'events': [{'action': 'key', 'code': 42, 'pressed': True}]})
        race_env = ENV | {'WAYLAND_DISPLAY': cli('state', 'agent1')['display']}
        race = start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', 'focus-race-window', BASE / 'race.txt'], 'race', race_env)
        wait(lambda: cli('state', 'agent1')['windowId'] != frame['windowId'])
        assert 'stale' in rejected(owner, 'human.input', {'name': 'agent1', 'frameId': frame['frameId'], 'events': [{'action': 'text', 'text': 'WRONG CLIENT'}]}).lower()
        wait(lambda: cli('state', 'agent1')['paused'])
        assert not (BASE / 'race.txt').exists()
        race.terminate(); race.wait(timeout=5)
    record('a real application focus race rejects stale human input and revokes takeover instead of redirecting text')
    with socket.socket(socket.AF_UNIX) as owner:
        owner.settimeout(5); owner.connect(path)
        rpc(owner, 'takeover', {'name': 'agent1'})
        wait(lambda: cli('state', 'agent1')['paused'], timeout=6)
    record('an unresponsive takeover owner loses control without logging out the human session')
    shell('desktop', 'observe', 'agent1'); wait(lambda: status()['frame'].get('frameId'))
    control('takeover'); wait(lambda: status()['humanControl'])
    cli('lock-policy', 'agent1', 'continue')
    shell('lock'); wait(lambda: json.loads(shell('ipc', 'lock', 'status'))['secure'])
    wait(lambda: cli('state', 'agent1')['paused'] and not status()['humanControl'])
    shell('lock', 'emergency-unlock'); wait(lambda: not json.loads(shell('ipc', 'lock', 'status'))['locked'])
    assert cli('state', 'agent1')['paused']
    record('human lock revokes takeover even under the continue policy; unlock does not restore either controller')
    shell('desktop', 'observe', 'agent1'); wait(lambda: status()['frame'].get('frameId'))
    control('takeover'); wait(lambda: status()['humanControl'])
    qs.terminate(); qs.wait(timeout=8)
    wait(lambda: cli('state', 'agent1')['paused'])
    assert fcitx.poll() is None
    record('viewer process exit releases takeover, pauses the Agent and preserves Fcitx')
    print('Artifacts:', BASE, flush=True)
except Exception:
    if 'qs' in globals() and qs.poll() is None:
        print('DIAGNOSTIC', status(), cli('state', 'agent1'), ctl('clients', True), flush=True)
        subprocess.run(['grim', '-o', 'human', str(BASE / 'failure.png')], env=ENV, check=True)
    raise
finally:
    cleanup()
