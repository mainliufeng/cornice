"""Exercise compositor-native presentation and direct physical-seat input."""
from desktop_harness import *


_held_mods = {}

def send(command):
    # The virtual-keyboard protocol requires separate modifier events. Real
    # hardware updates this state itself; mirror it rather than testing bare keys.
    words = command.split()
    if len(words) == 3 and words[0] == 'key' and int(words[1]) in {29:4,42:1,54:1,56:8,125:64}:
        _held_mods[int(words[1])] = {29:4,42:1,54:1,56:8,125:64}[int(words[1])] if int(words[2]) else 0
        send('mods ' + str(sum(set(_held_mods.values()))))
    keyboard.stdin.write(command + '\n'); keyboard.stdin.flush()
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'done', command


def status():
    return json.loads(shell('ipc', 'desktopObserver', 'status'))


def click(x, y):
    for event in (f'motion {round(x)} {round(y)}', 'button 272 1', 'button 272 0'):
        send(event)


def control(name):
    menus = json.loads(shell('ipc','desktopObserver','controls'))
    icon = next(item for item in menus if item['name'] == ('status' if name in ('run','takeover','prompt','cancel','permission') else 'switch'))
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
    send(f"motion {round(icon['x']+icon['width']/2)} {round(icon['y']+icon['height']+1)}")
    time.sleep(.6)
    assert ready(), ('menu closed in gap below icon',name)
    # Stop inside the popup across multiple service/model polls before clicking.
    # Pointer ownership must not depend on the lifetime of a row delegate.
    send(f"motion {round(row['x']+row['width']/2)} {round(row['y']+row['height']/2)}")
    time.sleep(1.3)
    row = ready()
    assert row, ('menu closed while hovering its row',name)
    click(row['x'] + row['width'] / 2, row['y'] + row['height'] / 2)

def entry(name, field="entry"):
    state = cli('state', name)
    client = next(c for c in ctl('clients', True) if c['title'] == name + '-window')
    geometry = json.loads((BASE / (name + '.geometry')).read_text())[field]
    logical = state['logicalSize']
    target = next(m for m in ctl('monitors', True) if m['name']=='human')
    factor = min(target['width']/state['pixelSize'][0], target['height']/state['pixelSize'][1])*state['scale']/target['scale']
    ox = (target['width']-state['pixelSize'][0]*factor*target['scale']/state['scale'])/target['scale']/2
    oy = (target['height']-state['pixelSize'][1]*factor*target['scale']/state['scale'])/target['scale']/2
    click(ox+(client['at'][0]-state['position'][0]+geometry[0]+geometry[2]/2)*factor,
          oy+(client['at'][1]-state['position'][1]+geometry[1]+geometry[3]/2)*factor)


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
    broker = initialize()
    for index in range(1, 4):
        cli('create', 'agent' + str(index), '--workspace', str(10 + index), '--virtual-output', '1280x800')
        cli('resume', 'agent' + str(index))
    # Pinyin runs solely on this sandbox's user bus and Wayland sockets.
    profile = BASE / 'config/fcitx5/profile'; profile.parent.mkdir(parents=True, exist_ok=True)
    profile.write_text('[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=pinyin\n\n[Groups/0/Items/0]\nName=keyboard-us\n\n[Groups/0/Items/1]\nName=pinyin\n\n[GroupOrder]\n0=Default\n')
    ENV.update(QT_IM_MODULE='fcitx', XMODIFIERS='@im=fcitx')
    fcitx = start(['fcitx5', '-D', '--disable=vinput,cloudpinyin'], 'fcitx', ENV | {'WAYLAND_DEBUG':'client'})
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
    ok('eval hl.bind("SUPER + F", hl.dsp.window.float(), {}); hl.bind("SUPER + M", hl.dsp.window.fullscreen({mode="fullscreen"}), {}); hl.bind("SUPER + Q", hl.dsp.window.close(), {}); hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), {mouse=true})')
    command=shlex.join(['/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),'native-launched',str(BASE/'launched.txt')])
    ok('eval hl.bind("SUPER + SHIFT + Return", hl.dsp.exec_cmd('+json.dumps(command)+'), {})')
    config = BASE / 'config/cornice'; config.mkdir(parents=True, exist_ok=True)
    (config / 'config.json').write_text(json.dumps({'agentDesktop': {'enabled': True}, 'bar': {'layout': {'left': [{'id': 'cn.agent-desktop'}, {'id': 'cn.launcher'}], 'center': [{'id': 'cn.clock'}], 'right': [{'id': 'cn.tray'}, {'id': 'cn.menu'}]}}, 'background': {'enabled': False}, 'weather': {'intervalMinutes': 0}, 'idle': {'lock': 0, 'screenOffAc': 0, 'screenOffBattery': 0, 'dimAc': 0, 'dimBattery': 0, 'lockOnSleep': False, 'lockOnLockSignal': False, 'lockOnLidClose': False}}))
    ENV['XDG_DATA_HOME'] = str(BASE / 'data')
    applications = BASE / 'data/applications'; applications.mkdir(parents=True)
    overlay_command = shlex.join(['/usr/bin/python3', str(ROOT / 'test/agent-desktop-client.py'), 'overlay-launched', str(BASE / 'overlay-launched.txt')])
    (applications / 'cornice-overlay-test.desktop').write_text('[Desktop Entry]\nType=Application\nName=Cornice Overlay Target Test\nExec=' + overlay_command + '\n')
    qs = start([str(PRODUCT / 'bin/cornice-qs'), '-p', str(PRODUCT / 'shell')], 'cornice')
    wait(lambda: json.loads(shell('ipc', 'desktop', 'status'))['available'])
    tray = start(['/usr/bin/python3', str(ROOT / 'test/fake-tray-menu.py')], 'tray-fixture')
    wait(lambda: any(item['id'] == 'cornice-menu-test' for item in json.loads(shell('ipc', 'tray', 'dump'))))
    def bar_click(identity):
        widget = next(item for item in json.loads(shell('ipc', 'bar', 'geometry')) if item['id'] == identity)
        click(widget['x'] + widget['width'] / 2, widget['y'] + widget['height'] / 2)
    def launch_overlay():
        bar_click('cn.launcher')
        try:
            wait(lambda: any(item['id'] == 'cn.launcher' and item['open'] for item in json.loads(shell('ipc', 'shell', 'windows'))))
        except Exception:
            print('LAUNCHER DIAGNOSTICS', shell('ipc', 'shell', 'windows'), shell('ipc', 'bar', 'geometry'), status(), ctl('layers', True), flush=True)
            subprocess.run(['grim', '-o', 'human', str(BASE/'native-launcher-failure.png')], env=ENV, check=True)
            raise
        shell('ipc', 'launcher', 'setQuery', 'Cornice Overlay Target Test')
        wait(lambda: json.loads(shell('ipc', 'launcher', 'debug'))['first'] == 'Cornice Overlay Target Test')
        send('key 28 1'); send('key 28 0')
        wait(lambda: not any(item['id'] == 'cn.launcher' and item['open'] for item in json.loads(shell('ipc', 'shell', 'windows'))))
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
    send(f"motion {round(icon['x']+icon['width']/2)} {round(icon['y']+icon['height']+1)}")
    time.sleep(.6)
    assert bar_agent(), 'desktop selector closed in gap below icon'
    send(f"motion {round(row['x']+row['width']/2)} {round(row['y']+row['height']/2)}")
    time.sleep(2.2)
    row = bar_agent()
    assert row, 'desktop selector closed while pointer remained in the popup'
    subprocess.run(['grim','-o','human',str(BASE/'hover-menu.png')],env=ENV,check=True)
    human['cursor']={'x':round(row['x']+row['width']/2),'y':round(row['y']+row['height']/2)}
    click(row['x']+row['width']/2,row['y']+row['height']/2)
    wait(lambda: status()['open'] and status()['name'] == 'agent1')
    view = wait(lambda: status() if status()['presentation'].get('active') else None)
    assert view['native'] and view['readonly'], view
    assert not any(l['namespace']=='cornice-desktop' for level in ctl('layers',True)['human']['levels'].values() for l in level)
    assert human_state()==human, (human_state(),human)
    subprocess.run(['grim','-o','human',str(BASE/'native-readonly.png')],env=ENV,check=True)
    displayed_clock(BASE/'native-readonly.png')  # Warm the image decoder outside timing.
    ages=[]
    for _ in range(5):
        shot=BASE/'native-clock.ppm'
        subprocess.run(['grim','-t','ppm','-o','human',str(shot)],env=ENV,check=True)
        captured=int(time.monotonic()*1000)&0xffffffff
        ages.append((captured-displayed_clock(shot))&0xffffffff)
        time.sleep(.03)
    frame_age=max(ages)
    assert frame_age<200,ages
    before=status()['presentation']['frames'];started=time.monotonic();time.sleep(2);after=status()['presentation']['frames']
    fps=(after-before)/(time.monotonic()-started)
    assert fps>=35,(before,after,fps)
    (BASE/'native-performance.json').write_text(json.dumps({'nativeSceneDrawsPerSecond':fps,'paintToCaptureMs':frame_age}))
    assert not list((RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']).glob('frame-*'))
    send('type blocked')
    assert not (BASE/'agent1.txt').exists() and not (BASE/'human.txt').exists()
    record('physical output renders the real agent scene at native output cadence without screenshot buffers; read-only blocks typing')
    geometry = json.loads(shell('ipc', 'bar', 'geometry'))
    for identity in ('cn.launcher', 'cn.clock', 'cn.tray', 'cn.menu'):
        assert any(item['id'] == identity and item['width'] > 0 for item in geometry), (identity, geometry)
    bar_click('cn.clock')
    wait(lambda: json.loads(shell('ipc', 'clockPanel', 'state'))['open'])
    time.sleep(.4)
    subprocess.run(['grim', '-o', 'human', str(BASE / 'native-complete-bar-panel.png')], env=ENV, check=True)
    send('key 1 1'); send('key 1 0')
    wait(lambda: not json.loads(shell('ipc', 'clockPanel', 'state'))['open'])
    assert status()['readonly'], status()
    icon = next(item for item in json.loads(shell('ipc', 'tray', 'dump')) if item['id'] == 'cornice-menu-test')
    click(icon['x'] + icon['width']/2, 16)
    time.sleep(.3)
    assert not json.loads(shell('ipc', 'tray', 'menuState'))['opened']
    for button in (273, 274):
        send('button ' + str(button) + ' 1'); send('button ' + str(button) + ' 0')
    send('scroll 10'); time.sleep(.2)
    assert not json.loads(shell('ipc', 'tray', 'menuState'))['opened']
    assert status()['readonly'], status()
    launch_overlay(); time.sleep(.3)
    assert not any(item['title'] == 'overlay-launched' for item in ctl('clients', True))
    assert not (BASE/'human.txt').exists() and not (BASE/'agent1.txt').exists()
    record('observing another desktop retains full Cornice controls while blocking third-party tray clicks, scroll and application launch')
    control('takeover');wait(lambda:status()['humanControl'])
    assert 'revoked' in tool(previous,'state',succeeds=False)
    click(icon['x'] + icon['width']/2, 16)
    wait(lambda: json.loads(shell('ipc', 'tray', 'menuState'))['opened'])
    time.sleep(.3)
    subprocess.run(['grim', '-o', 'human', str(BASE / 'native-complete-bar-tray.png')], env=ENV, check=True)
    send('key 1 1'); send('key 1 0')
    wait(lambda: not json.loads(shell('ipc', 'tray', 'menuState'))['opened'])
    launch_overlay()
    client = wait(lambda: next((item for item in ctl('clients', True) if item['title'] == 'overlay-launched'), None))
    assert client['workspace']['name'] == cli('state', 'agent1')['workspaceName'], client
    assert ctl('activewindow', True)['address'] == human['window']
    for event in ('key 125 1', 'key 16 1', 'key 16 0', 'key 125 0'): send(event)
    wait(lambda: not any(item['title'] == 'overlay-launched' for item in ctl('clients', True)))
    record('the restored physical bar launcher executes only on the taken-over seat and leaves the primary desktop unchanged')

    entry('agent1');send('type native')
    wait(lambda:(BASE/'agent1.txt').read_text()=='native')
    assert not (BASE/'human.txt').exists() and not (BASE/'agent2.txt').exists()
    record('physical pointer and keyboard directly control the agent GTK client, revoking its previous agent generation')
    subprocess.run(['fcitx5-remote','-o'],env=ENV,check=True)
    send('type nihao');time.sleep(.5)
    subprocess.run(['grim','-o','human',str(BASE/'native-pinyin.png')],env=ENV,check=True)
    send('key 57 1');send('key 57 0')
    wait(lambda:(BASE/'agent1.txt').read_text()=='native你好')
    subprocess.run(['fcitx5-remote','-c'],env=ENV,check=True)
    record('native physical input composes Chinese through real Fcitx into the agent application')
    time.sleep(.5)
    for event in ('mods 4','key 29 1','key 30 1','key 30 0','key 29 0','mods 0','type replaced'):send(event)
    subprocess.run(['grim','-o','human',str(BASE/'native-replaced.png')],env=ENV,check=True)
    wait(lambda:(BASE/'agent1.txt').read_text()=='replaced')
    entry('agent1','button');wait(lambda:(BASE/'agent1.click').read_text()=='1')
    # Stop the control service briefly: physical input must still reach the
    # client, proving it does not depend on a Cornice forwarding request.
    entry('agent1');os.kill(broker.pid,signal.SIGSTOP)
    try:
        send('type direct')
        wait(lambda:(BASE/'agent1.txt').read_text()=='replaceddirect',timeout=1)
    finally:os.kill(broker.pid,signal.SIGCONT)
    record('physical input continues while broker is stopped; no human.input RPC or frame acknowledgement is involved')
    for code in (33,50,50):
        send('key 125 1');send(f'key {code} 1');send(f'key {code} 0');send('key 125 0')
    client=wait(lambda:next(c for c in ctl('clients',True) if c['title']=='agent1-window' and c['floating']))
    assert client['fullscreen']==0
    x,y=client['at'];state=cli('state','agent1')
    click(x-state['position'][0]+50,y-state['position'][1]+20)
    send('key 125 1');send('button 272 1');send(f"motion {round(x-state['position'][0]+150)} {round(y-state['position'][1]+100)}");send('button 272 0');send('key 125 0')
    subprocess.run(['grim','-o','human',str(BASE/'native-drag.png')],env=ENV,check=True)
    wait(lambda:next(c for c in ctl('clients',True) if c['title']=='agent1-window')['at']!=[x,y])
    for command in ('key 125 1','key 42 1','key 28 1','key 28 0','key 42 0','key 125 0'):send(command)
    launched=wait(lambda:next((c for c in ctl('clients',True) if c['title']=='native-launched'),None))
    assert launched['workspace']['name']==cli('state','agent1')['workspaceName'],launched
    assert ctl('activewindow',True)['address']==human['window']
    seat_state=cli('state','agent1')
    cycle_env=ENV | {'HYPRLAND_SEAT_NAME':'agent1','HYPRLAND_SEAT_ID':seat_state['seatId'],'HYPRLAND_SEAT_GENERATION':seat_state['generation']}
    focused=seat_state['windowAddress']
    subprocess.run([str(PRODUCT/'bin/cornice-cycle-focus'),'next'],env=cycle_env,check=True)
    assert cli('state','agent1')['windowAddress']!=focused
    subprocess.run([str(PRODUCT/'bin/cornice-cycle-focus'),'prev'],env=cycle_env,check=True)
    assert cli('state','agent1')['windowAddress']==focused
    assert ctl('activewindow',True)['address']==human['window']
    record('the real Cornice focus-cycle helper targets the controlled seat in both directions')
    for command in ('key 125 1','key 16 1','key 16 0','key 125 0'):send(command)
    wait(lambda:not any(c['title']=='native-launched' for c in ctl('clients',True)))
    record('native window floating/fullscreen, Super-drag, application launch and close stay on the target seat')
    original_workspace=cli('state','agent1')['workspace']
    for event in ('key 125 1','key 42 1','key 5 1','key 5 0','key 42 0','key 125 0'):send(event)
    wait(lambda:next(c for c in ctl('clients',True) if c['title']=='agent1-window')['workspace']['name']=='cornice-agent-agent1-ws-4')
    assert cli('state','agent1')['workspace']==original_workspace
    for event in ('key 125 1','key 5 1','key 5 0','key 125 0'):send(event)
    wait(lambda:cli('state','agent1')['workspace']=='cornice-agent-agent1-ws-4')
    assert ctl('activewindow',True)['address']==human['window']
    record('Super+Shift+number moves the Agent window; Super+number switches only that seat')

    agent_shell = ENV | {'CORNICE_DESKTOP_NAME': 'agent1'}
    def agent_ui(method):
        return json.loads(subprocess.check_output([str(PRODUCT/'bin/cornice'),'ipc','desktop',method],env=agent_shell,text=True,timeout=8))
    for event in ('key 125 1','key 30 1','key 30 0','key 125 0'):send(event)
    wait(lambda:agent_ui('status')['prompt']=={'open':True,'name':'agent1'})
    send('type native controller prompt')
    wait(lambda:agent_ui('promptDraft')['text']=='native controller prompt')
    send('key 1 1');send('key 1 0')
    wait(lambda:not agent_ui('status')['prompt']['open'])
    record('seat-scoped Super+A unicasts to the correct private shell; native prompt typing works during takeover')

    control('takeover');wait(lambda:not status()['humanControl'])
    wait(lambda:cli('state','agent1')['paused'])
    agent_workspace=cli('state','agent1')['workspace']
    shell('ipc','desktopObserver','browse','name:cornice-agent-agent1-ws-2')
    wait(lambda:status()['presentation'].get('workspace')=='cornice-agent-agent1-ws-2')
    assert cli('state','agent1')['workspace']==agent_workspace
    for event in ('key 125 1','key 4 1','key 4 0','key 125 0'):send(event)
    wait(lambda:status()['presentation'].get('workspace')=='cornice-agent-agent1-ws-3')
    assert cli('state','agent1')['workspace']==agent_workspace
    shell('ipc','desktopObserver','takeover','true');wait(lambda:status()['humanControl'])
    assert cli('state','agent1')['workspace']=='cornice-agent-agent1-ws-3'
    shell('ipc','desktopObserver','takeover','false');wait(lambda:not status()['humanControl'])
    assert cli('state','agent1')['paused']
    shell('ipc','desktopObserver','follow')
    wait(lambda:status()['presentation'].get('following'))
    record('read-only browsing an empty workspace leaves the agent current workspace unchanged; Follow restores it')

    before_text=(BASE/'agent1.txt').read_text()
    for event in ('key 125 1','key 30 1','key 30 0','key 125 0'):send(event)
    wait(lambda:json.loads(shell('ipc','desktop','status'))['prompt']=={'open':True,'name':'agent1'})
    send('type readonly controller prompt')
    wait(lambda:json.loads(shell('ipc','desktop','promptDraft'))['text']=='readonly controller prompt')
    assert (BASE/'agent1.txt').read_text()==before_text
    send('key 1 1');send('key 1 0')
    wait(lambda:not json.loads(shell('ipc','desktop','status'))['prompt']['open'])
    record('readonly Super+A targets the selected desktop through its local controller UI without editing the application')
    control('main');wait(lambda:not status()['open'])
    wait(lambda:human_state()==human)
    record('application shortcut and button work; releasing control pauses agent, returning restores human workspace/focus/cursor')
    # Browser scroll is measured from the real rendered page's title. Its CDP
    # grant is deliberately revoked before physical takeover, as in production.
    from cdp_client import Cdp
    cli('resume','agent2'); browser_binding=bind('agent2')
    browser=tool(browser_binding,'browser');cdp=Cdp(browser['cdpUrl'])
    html='<title>native-scroll:0</title><body style="height:12000px;background:linear-gradient(white,teal)"><h1>Native wheel</h1><script>onscroll=()=>document.title="native-scroll:"+Math.round(scrollY)</script>'
    import urllib.parse
    created=cdp.call('Target.createTarget',{'url':'data:text/html,'+urllib.parse.quote(html),'newWindow':True})
    cdp.call('Target.activateTarget',{'targetId':created['targetId']})
    browser_window=wait(lambda:next((w for w in tool(browser_binding,'windows')['windows'] if w['title'].startswith('native-scroll:0')),None))
    tool(browser_binding,'focus',{'windowId':browser_window['id']})
    actual=cli('state','agent2')
    ok('seat dispatch agent2 '+actual['seatId']+' '+actual['generation']+' hl.dsp.window.fullscreen({mode="fullscreen"})')
    shell('desktop','observe','agent2');wait(lambda:status()['presentation'].get('active'))
    shell('ipc','desktopObserver','takeover','true');wait(lambda:status()['humanControl'])
    send('motion 640 400');send('scroll 100')
    wait(lambda:any(c['title'].startswith('native-scroll:') and int(c['title'].split(':')[1].split()[0])>0 for c in ctl('clients',True)))
    cdp.close()
    record('real Chrome scrolls from the physical wheel after CDP and automation input are revoked')
    # Emergency return must work in the compositor, even with no UI roundtrip.
    for event in ('key 29 1','key 56 1','key 1 1','key 1 0','key 56 0','key 29 0'):send(event)
    wait(lambda:not status()['open']);wait(lambda:cli('state','agent2')['paused'])
    assert ctl('activewindow',True)['address']==human['window']
    record('Ctrl+Alt+Esc returns to the human desktop and leaves the Agent paused')
    path=str(RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']/'desktop.sock')
    ok('eval hl.monitor({output="human",mode="3072x1920@120",position="0x0",scale=2})')
    cli('resume','agent1'); laptop_binding=bind('agent1')
    tool(laptop_binding,'workspace',{'workspace':'name:cornice-agent-agent1-ws-4'})
    laptop_window=next(w for w in tool(laptop_binding,'windows')['windows'] if w['title']=='agent1-window')
    tool(laptop_binding,'focus',{'windowId':laptop_window['id']})
    cli('pause','agent1')
    human_high=human_state()
    with socket.socket(socket.AF_UNIX) as owner, socket.socket(socket.AF_UNIX) as stranger:
        for connection in (owner,stranger):connection.settimeout(5);connection.connect(path)
        begin=time.monotonic()
        native=rpc(owner,'present',{'name':'agent1'})
        assert native['active'] and native['native']
        assert cli('state','agent1')['pixelSize']==[3072,1920]
        native=rpc(owner,'takeover',{'name':'agent1'})
        elapsed=time.monotonic()-begin
        assert native['humanControl'] and elapsed<3,elapsed
        assert 'required' in rejected(stranger,'takeover',{'name':'agent2'}).lower()
        assert 'owns' in rejected(stranger,'present',{'name':'agent2'}).lower()
        entry('agent1');send('type laptop')
        wait(lambda:(BASE/'agent1.txt').read_text().endswith('laptop'))
        subprocess.run(['grim','-o','human',str(BASE/'native-laptop-takeover.png')],env=ENV,check=True)
        displayed_clock(BASE/'native-laptop-takeover.png')
        (BASE/'native-laptop-performance.json').write_text(json.dumps({'takeoverSeconds':elapsed,'pixels':[3072,1920],'refreshHz':next(m for m in ctl('monitors',True) if m['name']=='human')['refreshRate']}))
    wait(lambda:cli('state','agent1')['paused'])
    wait(lambda:human_state()==human_high)
    record('full laptop resolution takeover has no frame deadline; another socket cannot steal control and disconnect restores the human view')
    pam=BASE/'native-pam';pam.mkdir();(pam/'permit').write_text('auth required pam_permit.so\n')
    with socket.socket(socket.AF_UNIX) as owner:
        owner.settimeout(5);owner.connect(path)
        rpc(owner,'present',{'name':'agent1'});rpc(owner,'takeover',{'name':'agent1'})
        locker=subprocess.Popen([str(PRODUCT/'bin/cornice-human-lock'),'--pam-service','permit','--pam-directory',str(pam),'--allow-emergency'],env=ENV,stdin=subprocess.PIPE,stdout=open(BASE/'native-lock-events','w'),stderr=open(BASE/'native-lock.log','w'),start_new_session=True,text=True)
        PROCESSES.append(locker)
        wait(lambda:ctl('seat lock-state',True)['secure'])
        wait(lambda:ctl('seat state agent1',True)['paused'])
        assert rpc(owner,'present-status',{'name':'agent1'})['active'] is False
        def visible_lock():
            from PIL import Image
            shot=BASE/'native-takeover-lock.png'
            subprocess.run(['grim','-o','human',str(shot)],env=ENV,check=True)
            with Image.open(shot) as image:
                assert image.size==(3072,1920),image.size
                return min(high for low,high in image.convert('RGB').getextrema())>100
        wait(visible_lock)
        locker.stdin.write('emergency-unlock\n');locker.stdin.flush()
        wait(lambda:not ctl('seat lock-state',True)['locked'])
        assert cli('state','agent1')['paused']
    record('real session lock revokes native takeover; unlocking does not restore control or resume the Agent')
    with socket.socket(socket.AF_UNIX) as owner:
        owner.settimeout(5);owner.connect(path)
        rpc(owner,'present',{'name':'agent1'});rpc(owner,'takeover',{'name':'agent1'})
        wait(lambda:cli('state','agent1')['paused'],timeout=5)
        time.sleep(5.2)
        assert rpc(owner,'present-status',{'name':'agent1'})['active'] is False
    wait(lambda:human_state()==human_high)
    record('lost heartbeats revoke physical takeover and restore the human scene without auto-resuming the Agent')
    shell('desktop','observe','agent1');wait(lambda:status()['presentation'].get('active'))
    shell('ipc','desktopObserver','takeover','true');wait(lambda:status()['humanControl'])
    control('permission');wait(lambda:not cli('state','agent1')['agentAllowed'])
    assert status()['humanControl'], 'disabling Agent permission must preserve human takeover'
    entry('agent1');send('type permissionoff')
    wait(lambda:'permissionoff' in (BASE/'agent1.txt').read_text())
    control('permission');wait(lambda:cli('state','agent1')['agentAllowed'])
    subprocess.run(['grim','-o','human',str(BASE/'permission-menu.png')],env=ENV,check=True)
    record('real bar permission switch revokes Agent permission and preserves native human input')
    qs.kill();qs.wait(timeout=5)
    wait(lambda:cli('state','agent1')['paused'])
    wait(lambda:human_state()==human_high)
    record('Cornice UI crash releases native presentation and takeover')
    with socket.socket(socket.AF_UNIX) as owner:
        owner.settimeout(5);owner.connect(path)
        rpc(owner,'present',{'name':'agent1'});rpc(owner,'takeover',{'name':'agent1'})
        broker.kill();broker.wait(timeout=5)
        wait(lambda:ctl('seat state agent1',True)['paused'],timeout=8)
        wait(lambda:human_state()==human_high)
    record('broker crash is recovered by the compositor lease, with the human workspace and focus intact')
finally:
    cleanup()
