"""Exercise compositor-native presentation and direct physical-seat input."""
from desktop_harness import *


_held_mods = {}

def send(command):
    if command.startswith('type ') and len(command[5:]) > 1:
        # Physical typing is asynchronous through Fcitx. Keep individual test
        # key presses separated so a focus/IME activation round-trip can finish.
        for char in command[5:]:
            send('type ' + char)
            time.sleep(.04)
        return
    # The virtual-keyboard protocol requires separate modifier events. Real
    # hardware updates this state itself; mirror it rather than testing bare keys.
    words = command.split()
    if len(words) == 3 and words[0] == 'motion':
        # The test virtual-pointer fixture caches its output size at startup.
        # Remap our current logical coordinates after an output mode change;
        # physical relative mice do not have this fixture-only limitation.
        monitor=next(item for item in ctl('monitors',True) if item['name']=='human')
        command='motion ' + str(round(float(words[1])*1280/(monitor['width']/monitor['scale']))) + ' ' + str(round(float(words[2])*800/(monitor['height']/monitor['scale'])))
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
    icon = next(item for item in menus if item['name'] == 'group')
    send(f"motion {round(icon['x']+icon['width']/2)} {round(icon['y']+icon['height']/2)}")
    def ready():
        row = next((item for item in json.loads(shell('ipc', 'desktopObserver', 'controls')) if item['name'] == ('control:' + name if name in ('run','takeover','permission','previews','preview-mode','manage') else 'view:' + name)), None)
        if not row or not row.get('enabled', True): return None
        if name == 'run':
            expected = '恢复 Agent 输入' if cli('state', status()['name'])['paused'] else '暂停 Agent 输入'
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
    if name == 'permission':
        print('PERMISSION ROW', row, status(),flush=True)
        subprocess.run(['grim','-o','human',str(BASE/'permission-before-click.png')],env=ENV,check=True)
    click(row['x'] + row['width'] / 2, row['y'] + row['height'] / 2)

def entry(name, field="entry"):
    state = cli('state', name)
    client = next(c for c in ctl('clients', True) if c['title'] == name + '-window')
    def client_geometry():
        try: return json.loads((BASE / (name + '.geometry')).read_text())[field]
        except (ValueError,KeyError): return None
    geometry = wait(client_geometry)
    logical = state['logicalSize']
    target = next(m for m in ctl('monitors', True) if m['name']=='human')
    factor = min(target['width']/state['pixelSize'][0], target['height']/state['pixelSize'][1])*state['scale']/target['scale']
    ox = (target['width']-state['pixelSize'][0]*factor*target['scale']/state['scale'])/target['scale']/2
    oy = (target['height']-state['pixelSize'][1]*factor*target['scale']/state['scale'])/target['scale']/2
    click(ox+(client['at'][0]-state['position'][0]+geometry[0]+geometry[2]/2)*factor,
          oy+(client['at'][1]-state['position'][1]+geometry[1]+geometry[3]/2)*factor)
    time.sleep(.2) # let GTK and the external input method accept pointer focus


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
    # This fixture supplies three explicit secondary desktops, replacing the
    # broker startup default so viewport/card-count checks stay deterministic.
    cli("remove", "desktop2")
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
    (config / 'config.json').write_text(json.dumps({'agentDesktop': {'enabled': True}, 'bar': {'layout': {'left': [{'id': 'cn.agent-desktop'}, {'id': 'cn.launcher'}], 'center': [{'id': 'cn.clock'}], 'right': [{'id': 'cn.tray'}, {'id': 'cn.screenshot'}, {'id': 'cn.menu'}]}}, 'background': {'enabled': False}, 'weather': {'intervalMinutes': 0}, 'idle': {'lock': 0, 'screenOffAc': 0, 'screenOffBattery': 0, 'dimAc': 0, 'dimBattery': 0, 'lockOnSleep': False, 'lockOnLockSignal': False, 'lockOnLidClose': False}}))
    ENV['XDG_DATA_HOME'] = str(BASE / 'data')
    applications = BASE / 'data/applications'; applications.mkdir(parents=True)
    overlay_command = shlex.join(['/usr/bin/python3', str(ROOT / 'test/agent-desktop-client.py'), 'overlay-launched', str(BASE / 'overlay-launched.txt')])
    (applications / 'cornice-overlay-test.desktop').write_text('[Desktop Entry]\nType=Application\nName=Cornice Overlay Target Test\nExec=' + overlay_command + '\n')
    qs = start([str(PRODUCT / 'bin/cornice-qs'), '-p', str(PRODUCT / 'shell')], 'cornice')
    wait(lambda: json.loads(shell('ipc', 'desktop', 'status'))['available'])
    if os.getenv('CORNICE_TEST_DESKTOP_MENU_ONLY') == '1':
        shell('ipc','desktop','observe','agent1');wait(lambda:status()['presentation'].get('active'))
        shell('ipc','desktopObserver','takeover','true');wait(lambda:status()['humanControl'])
        ok('eval hl.monitor({output="human",mode="3072x1920",position="0x0",scale=2})')
        time.sleep(1)
        control('permission')
        print('SHORT PERMISSION STATE',status(),cli('state','agent1'),flush=True)
        wait(lambda:not cli('state','agent1')['agentAllowed'])
        assert status()['humanControl']
        record('high-resolution grouped permission action targets the intended desktop and preserves takeover')
        raise SystemExit(0)
    # Real external-harness reservation automatically appears on the primary
    # desktop; the preview is only a read-only entry into native presentation.
    import threading
    preview_owner=socket.socket(socket.AF_UNIX);preview_owner.settimeout(5)
    preview_owner.connect(str(RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']/'desktop.sock'))
    cli('pause','agent3')
    lease=rpc(preview_owner,'acquire-desktop',{'controller':'preview-ui-codex','harness':'codex','preferredDesktop':'agent3'})
    preview_stop=threading.Event()
    preview_errors=[]
    def heartbeat(connection,binding,controller):
        while not preview_stop.wait(.5):
            try:
                identity=str(time.monotonic_ns())
                connection.sendall((json.dumps({'id':identity,'method':'desktop.state','params':{},'controller':controller,'token':binding['token']})+'\n').encode())
                data=b''
                while b'\n' not in data:data+=connection.recv(65536)
                reply=json.loads(data.split(b'\n')[0]);assert reply['ok'],reply
            except Exception as error:
                preview_errors.append(str(error));return
    preview_thread=threading.Thread(target=heartbeat,args=(preview_owner,lease,'preview-ui-codex'),daemon=True);preview_thread.start()
    pi_owner=socket.socket(socket.AF_UNIX);pi_owner.settimeout(5)
    pi_owner.connect(str(RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']/'desktop.sock'))
    cli('pause','agent2')
    pi_lease=rpc(pi_owner,'acquire-desktop',{'controller':'preview-ui-pi','harness':'pi','preferredDesktop':'agent2'})
    pi_thread=threading.Thread(target=heartbeat,args=(pi_owner,pi_lease,'preview-ui-pi'),daemon=True);pi_thread.start()
    def previews():return json.loads(shell('ipc','desktopPreviews','status'))
    try:
        card=wait(lambda:next((item for item in previews()['cards'] if item['name']=='agent3' and item['frames']>=3),None))
    except Exception:
        print('PREVIEW DIAGNOSTICS',previews(),shell('ipc','desktop','status'),cli('state','agent3'),preview_errors,flush=True)
        raise
    wait(lambda:{item['name'] for item in previews()['cards']}=={'agent2','agent3'} and all(item['frames']>=3 for item in previews()['cards']))
    assert cli('state','agent3')['harness']=='codex' and cli('state','agent2')['harness']=='pi'
    assert previews()['readonly'] and previews()['visible']
    assert not (BASE/'human.txt').exists() and not (BASE/'agent3.txt').exists()
    subprocess.run(['grim','-o','human',str(BASE/'floating-preview.png')],env=ENV,check=True)
    assert not json.loads(shell('ipc','desktop','status'))['alwaysShowPreviews']
    assert 'agent1' not in previews()['desktops']
    control('preview-mode')
    wait(lambda:json.loads(shell('ipc','desktop','status'))['alwaysShowPreviews'] and len(previews()['cards'])==3 and all(item['hasFrame'] for item in previews()['cards']))
    saved=json.loads((config/'config.json').read_text())
    assert saved['agentDesktop']['alwaysShowPreviews'] and saved['bar']['layout']['left'][0]['id']=='cn.agent-desktop'
    assert (config/'config.json.previous').exists()
    record('previews default to occupied desktops; the real Always switch persists with a backup and displays idle desktops without losing bar settings')
    group=next(item for item in next(item for item in json.loads(shell('ipc','bar','geometry')) if item['id']=='cn.agent-desktop')['controls'] if item['name']=='group')
    send(f"motion {round(group['x']+group['width']/2)} {round(group['y']+group['height']/2)}")
    rows=wait(lambda:json.loads(shell('ipc','desktopObserver','controls')) if any(item['name']=='control:all-heading' for item in json.loads(shell('ipc','desktopObserver','controls'))) else None)
    assert [row['label'] for row in rows if row.get('kind')=='section']==['切换桌面','当前桌面操作','所有桌面'],rows
    local=[row for row in rows if row.get('scope')=='desktop']
    assert local and all(row['target']=='main' for row in local),local
    assert next(row for row in rows if row['name']=='control:current-heading')['detail'].startswith('桌面 1'),rows
    assert next(row for row in rows if row['name']=='control:previews')['scope']=='all',rows
    subprocess.run(['grim','-o','human',str(BASE/'menu-scope-primary.png')],env=ENV,check=True)
    control('previews');wait(lambda:not previews()['visible'])
    control('previews');wait(lambda:previews()['visible'] and len(previews()['cards'])==3)
    send('motion 650 300')
    record('grouped menu separates switching, named current-desktop actions and global previews; idle desktops render and global hide/restore affects every card')
    # Cornice owns capture/selection and declares its interaction before any
    # overlay takes input. No shortcut or third-party namespace is recognized.
    def screenshot_state():return json.loads(shell('ipc','screenshot','status'))
    def screenshot_button():
        button=next(item for item in json.loads(shell('ipc','bar','geometry')) if item['id']=='cn.screenshot')
        assert button['width']>0 and button['height']>0,button
        click(round(button['x']+button['width']/2), round(button['y']+button['height']/2))
        wait(lambda:screenshot_state()['selecting'])
        time.sleep(.2) # The compositor commits the selection layer after frame readiness.
    subprocess.run(['grim','-o','human',str(BASE/'screenshot-button.png')],env=ENV,check=True)
    screenshot_button()
    send('motion 600 200');send('button 272 1');send('motion 800 400');send('button 272 0')
    wait(lambda:not screenshot_state()['active'])
    button_image=pathlib.Path(screenshot_state()['lastFile'])
    assert button_image.exists() and button_image.is_relative_to(pathlib.Path(ENV['HOME'])) and button_image.parent.name=='Screenshots',screenshot_state()
    assert screenshot_state()['clipboardCopied'] and button_image.stat().st_mode & 0o777 == 0o600
    assert subprocess.check_output(['wl-paste','--type','image/png'],env=ENV)==button_image.read_bytes()
    record('real screenshot bar button selects a region, saves the default private PNG and copies identical image bytes')
    def hover_menu():
        send(f"motion {round(group['x']+group['width']/2)} {round(group['y']+group['height']/2)}")
        row=wait(lambda:next((row for row in json.loads(shell('ipc','desktopObserver','controls')) if row['name']=='view:main'),None))
        send(f"motion {round(row['x']+100)} {round(row['y']+row['height']/2)}")
        return row
    # Use a different binding as well, so correctness cannot depend on Super+P.
    for shortcut,keycode,path in [('SUPER + P',25,BASE/'native-region.png'),('SUPER + O',24,BASE/'other-binding.png')]:
        command=shlex.join([str(PRODUCT/'bin/cornice'),'screenshot','region',str(path)])
        ok('eval hl.bind('+json.dumps(shortcut)+', hl.dsp.exec_cmd('+json.dumps(command)+'), {})')
        hover_menu()
        reference=BASE/'before-native-screenshot.png'
        subprocess.run(['grim','-o','human',str(reference)],env=ENV,check=True)
        send('key 125 1');send(f'key {keycode} 1');send(f'key {keycode} 0');send('key 125 0')
        wait(lambda:screenshot_state()['selecting'])
        time.sleep(.7)
        assert any(row['name']=='control:preview-mode' for row in json.loads(shell('ipc','desktopObserver','controls'))),'native selection closed the menu'
        assert screenshot_state()['interactionHeld']
        subprocess.run(['grim','-o','human',str(BASE/'menu-during-native-screenshot.png')],env=ENV,check=True)
        send('motion 600 200');send('button 272 1');send('motion 800 400');send('button 272 0')
        wait(lambda:path.exists())
        wait(lambda:not screenshot_state()['active'])
        assert not screenshot_state()['interactionHeld'] and screenshot_state()['lastFile']==str(path),screenshot_state()
        import gi
        gi.require_version('GdkPixbuf','2.0')
        from gi.repository import GdkPixbuf
        pixbuf=GdkPixbuf.Pixbuf.new_from_file(str(path))
        assert (pixbuf.get_width(),pixbuf.get_height())==(400,400),(pixbuf.get_width(),pixbuf.get_height())
        assert path.stat().st_mode & 0o777 == 0o600,oct(path.stat().st_mode)
        assert screenshot_state()['clipboardCopied'],screenshot_state()
        wait(lambda:subprocess.run(['wl-paste','--type','image/png'],env=ENV,capture_output=True,timeout=3).stdout==path.read_bytes())
        before=GdkPixbuf.Pixbuf.new_from_file(str(reference))
        def pixel(image,x,y):
            at=y*image.get_rowstride()+x*image.get_n_channels()
            return image.get_pixels()[at:at+3]
        for x,y in [(40,100),(100,200),(300,300)]:
            assert pixel(pixbuf,x,y)==pixel(before,1200+x,400+y),(x,y,pixel(pixbuf,x,y),pixel(before,1200+x,400+y))
        wait(lambda:not any(row['name']=='view:main' for row in json.loads(shell('ipc','desktopObserver','controls'))))
    record('native ScreencopyView exports real 2x region pixels, preserves the menu under two unrelated shortcuts and releases popup holds after saving')
    for cancel in ('escape','right-click'):
        hover_menu();assert shell('screenshot','region',str(BASE/'cancelled.png'))=='requested'
        wait(lambda:screenshot_state()['selecting'])
        time.sleep(.7)
        assert any(row['name']=='view:main' for row in json.loads(shell('ipc','desktopObserver','controls')))
        if cancel=='escape':send('key 1 1');send('key 1 0')
        else:send('motion 600 200');send('button 273 1');send('button 273 0')
        wait(lambda:not screenshot_state()['active'])
        assert not screenshot_state()['interactionHeld'] and not (BASE/'cancelled.png').exists()
        send('motion 650 300')
        wait(lambda:not any(row['name']=='view:main' for row in json.loads(shell('ipc','desktopObserver','controls'))))
    full=BASE/'native-screen.png';assert shell('screenshot','screen',str(full))=='requested'
    wait(lambda:full.exists());wait(lambda:not screenshot_state()['active'])
    pixbuf=GdkPixbuf.Pixbuf.new_from_file(str(full))
    assert (pixbuf.get_width(),pixbuf.get_height())==(2560,1600),(pixbuf.get_width(),pixbuf.get_height())
    record('Escape/right-click cancel releases input and menu holds without an image; full-screen capture retains native physical resolution')
    assert shell('ipc','screenshot','capture','bad','')=='invalid-mode'
    assert shell('ipc','screenshot','capture','region','relative.png')=='absolute-path-required'
    for path in (str(BASE/'missing-directory'/'failure.png'),''):
        assert shell('screenshot','region',path)=='requested'
        wait(lambda:screenshot_state()['selecting'])
        assert shell('ipc','screenshot','capture','region','')=='busy'
        send('motion 600 200');send('button 272 1');send('motion 800 400');send('button 272 0')
        wait(lambda:not screenshot_state()['active'])
        if path:
            assert screenshot_state()['error']=='无法保存截图' and not pathlib.Path(path).exists(),screenshot_state()
        else:
            saved=pathlib.Path(screenshot_state()['lastFile'])
            assert saved.is_relative_to(pathlib.Path(ENV['HOME'])) and saved.parent.name=='Screenshots' and saved.exists(),saved
            assert screenshot_state()['clipboardCopied'] and saved.stat().st_mode & 0o777 == 0o600
    assert not any(c['class']=='com.gabm.satty' for c in ctl('clients',True))
    # A keyboard/grab panel also uses the shared interaction contract.
    shell('launcher')
    def launcher_open():return any(w['id']=='cn.launcher' and w['open'] for w in json.loads(shell('ipc','shell','windows')))
    wait(launcher_open)
    assert shell('screenshot','region',str(BASE/'launcher-screenshot.png'))=='requested'
    wait(lambda:screenshot_state()['selecting']);time.sleep(.5)
    assert launcher_open()
    subprocess.run(['grim','-o','human',str(BASE/'native-screenshot-launcher.png')],env=ENV,check=True)
    send('key 1 1');send('key 1 0');wait(lambda:not screenshot_state()['active'])
    assert launcher_open()
    send('key 1 1');send('key 1 0');wait(lambda:not launcher_open())
    record('PNG clipboard data equals the saved private image; default Pictures/Screenshots save, failed-save cleanup, duplicate-request refusal and generic keyboard-panel preservation work without an editor')
    def release_and_check_previews():
        previous_frames={c['name']:c['frames'] for c in previews()['cards']}
        preview_stop.set();preview_thread.join(timeout=5);pi_thread.join(timeout=5);preview_owner.close();pi_owner.close()
        assert not preview_errors,preview_errors
        wait(lambda:not cli('state','agent3')['occupied'] and not cli('state','agent2')['occupied'])
        retained=wait(lambda:previews() if previews()['visible'] and len(previews()['cards'])==3 and all(c['frames']>previous_frames[c['name']] for c in previews()['cards'] if c['y']<previews()['bounds']['y']+previews()['bounds']['height']) else None)
        assert {c['name'] for c in retained['cards']}=={'agent1','agent2','agent3'},retained
        subprocess.run(['grim','-o','human',str(BASE/'preview-after-task.png')],env=ENV,check=True)
        record('Always mode keeps completed Harness previews visible with fresh frames and retained applications')
        shell('ipc','desktop','previewMode','active')
        wait(lambda:not json.loads(shell('ipc','desktop','status'))['alwaysShowPreviews'] and not previews()['visible'])
        shell('ipc','desktop','previewMode','always')
        wait(lambda:json.loads(shell('ipc','desktop','status'))['alwaysShowPreviews'] and len(previews()['cards'])==3)
        record('switching back to the default hides released desktops; Always restores their retained applications')
    if os.getenv('CORNICE_TEST_DESKTOP_PREVIEW_ONLY') == '1':
        # Many independent absolute pointer moves expose feedback from changing
        # local window coordinates that a single two-point drag cannot catch.
        first=previews()['cards'][0]
        px=round(first['x']+80);py=round(first['y']+20)
        send(f'motion {px} {py}');send('button 272 1')
        samples=[]
        for delta in list(range(15,271,15))+list(range(255,-1,-15)):
            send(f'motion {px-delta} {py}')
            target=first['x']-delta
            wait(lambda:abs(previews()['bounds']['x']-target)<=3,timeout=3)
            time.sleep(.04)
            actual=previews()['bounds']['x'];samples.append((delta,actual))
            assert abs(actual-target)<=3,(delta,actual,target)
        send('button 272 0')
        time.sleep(.15)
        assert abs(previews()['bounds']['x']-first['x'])<=3,previews()
        assert all(b[1]<=a[1]+1 for a,b in zip(samples[:18],samples[1:18])),samples
        assert all(b[1]>=a[1]-1 for a,b in zip(samples[18:],samples[19:])),samples
        # The fullscreen transparent hosting surface must never block the app.
        click(650,300)
        assert not status()['open'] and human_state()['window'],cli('state','main')
        record('36 physical drag samples track the pointer within 3 logical pixels in both directions with no rebound; clicks outside previews reach the primary application')
        # Make room at the right edge, then resize using physical pointer input.
        bounds=previews()['bounds']
        px=round(bounds['x']+80);py=round(bounds['y']+20)
        send(f'motion {px} {py}');send('button 272 1');send(f'motion {px-180} {py-60}');send('button 272 0')
        wait(lambda:previews()['bounds']['x'] < bounds['x']-170)
        time.sleep(.2) # let the released drag clamp to the bar before recording the resize origin
        bounds=previews()['bounds'];px=round(bounds['x']+bounds['width']-10);py=round(bounds['y']+bounds['height']-10)
        send(f'motion {px} {py}');send('button 272 1');send(f'motion {px+100} {py+30}');send('button 272 0')
        resized=wait(lambda:previews() if abs(previews()['preferredWidth']-420)<=3 and abs(previews()['cardHeight']-230)<=3 else None)
        wait(lambda:json.loads((config/'config.json').read_text())['agentDesktop'].get('previewWidth')==420)
        assert abs(resized['bounds']['x']-bounds['x'])<=3 and abs(resized['bounds']['y']-bounds['y'])<=3,(bounds,resized)
        assert json.loads((config/'config.json').read_text())['bar']['layout']['left'][0]['id']=='cn.agent-desktop'
        qs.terminate();qs.wait(timeout=5)
        qs=start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice-resized')
        wait(lambda:previews()['visible'] and previews()['preferredWidth']==420 and previews()['cardHeight']==230)
        subprocess.run(['grim','-o','human',str(BASE/'preview-resized.png')],env=ENV,check=True)
        record('real corner drag resizes preview width and card height without shifting the origin; atomic settings preserve bar configuration and survive a shell restart')
        # Exercise a real drag before changing the output and visible card count.
        first=previews()['cards'][0]
        send(f"motion {round(first['x']+80)} {round(first['y']+20)}");send('button 272 1')
        send('motion 100 80');send('button 272 0')
        wait(lambda:previews()['bounds']['x'] < first['x'])
        ok('output create headless extra-physical')
        ok('eval hl.monitor({output="extra-physical",mode="1024x768",position="1280x0",scale=1})')
        ok('eval hl.monitor({output="human",mode="800x600",position="0x0",scale=1})')
        def bounded():
            state=previews();bounds=state['bounds']
            return state if state['output']=='human' and bounds['x']>=0 and bounds['y']>=0 and bounds['x']+bounds['width']<=800 and bounds['y']+bounds['height']<=600 else None
        wait(bounded,timeout=5)
        shell('ipc','desktop','hidePreview','agent2')
        wait(lambda:len(previews()['cards'])==2 and bounded(),timeout=5)
        shell('ipc','desktop','restorePreviews')
        wait(lambda:len(previews()['cards'])==3 and bounded() and all(c['hasFrame'] for c in previews()['cards'] if c['y'] < previews()['bounds']['y'] + previews()['bounds']['height'] and c['y']+c['height'] > previews()['bounds']['y']),timeout=5)
        subprocess.run(['grim','-o','human',str(BASE/'preview-small-output.png')],env=ENV,check=True)
        record('dragged preview stays on primary.output after smaller output and visible card count changes')
        multiple=BASE/'multi-output-region.png'
        assert shell('screenshot','region',str(multiple))=='requested'
        wait(lambda:screenshot_state()['selecting'] and set(screenshot_state()['outputs'])=={'human','extra-physical'})
        # The absolute fixture is bound to human. Relative motion crosses outputs
        # like a physical mouse, including the gap before extra-physical.
        send('motion 400 200');send('relative 1080 0');send('button 272 1')
        send('relative 200 200');send('button 272 0')
        wait(lambda:multiple.exists());wait(lambda:not screenshot_state()['active'])
        img=GdkPixbuf.Pixbuf.new_from_file(str(multiple))
        assert (img.get_width(),img.get_height())==(200,200)
        assert shell('screenshot','region',str(BASE/'resize-cancelled.png'))=='requested'
        wait(lambda:screenshot_state()['selecting'])
        ok('eval hl.monitor({output="human",mode="1024x768",position="0x0",scale=1})')
        wait(lambda:not screenshot_state()['active'])
        assert not screenshot_state()['interactionHeld'] and not (BASE/'resize-cancelled.png').exists()
        ok('eval hl.monitor({output="human",mode="800x600",position="0x0",scale=1})')
        record('native selection works on a second physical output; changing output geometry cancels and releases all interaction state')
        release_and_check_previews()
        # The compositor emits an unsolicited event on the real owner sockets.
        # Its counter proves cached frames clear from the event, not service polling.
        assert shell('screenshot','region',str(BASE/'lock-cancelled.png'))=='requested'
        wait(lambda:screenshot_state()['selecting'])
        before={c['name']:c['invalidations'] for c in previews()['cards'] if c['hasFrame']}
        assert len(before)>=2,before
        pam=BASE/'preview-pam';pam.mkdir();(pam/'permit').write_text('auth required pam_permit.so\n')
        locker=subprocess.Popen([str(PRODUCT/'bin/cornice-human-lock'),'--scope','session','--pam-service','permit','--pam-directory',str(pam),'--allow-emergency'],env=ENV,stdin=subprocess.PIPE,stdout=open(BASE/'preview-lock-events','w'),stderr=open(BASE/'preview-lock.log','w'),start_new_session=True,text=True)
        PROCESSES.append(locker)
        wait(lambda:ctl('seat lock-state',True)['secure'],timeout=5)
        began=time.monotonic()
        cleared=wait(lambda:previews() if all(not c['hasFrame'] and c['invalidations']>before[c['name']] for c in previews()['cards'] if c['name'] in before) else None,timeout=.5)
        assert len(cleared['cards'])==3,cleared
        print('LOCK INVALIDATION',time.monotonic()-began,cleared,flush=True)
        wait(lambda:not screenshot_state()['active'],timeout=.5)
        assert not screenshot_state()['interactionHeld'] and not (BASE/'lock-cancelled.png').exists()
        assert shell('ipc','screenshot','capture','region','')=='locked'
        record('real session-lock notification immediately clears both cached preview images and cancels frozen screenshot selection')
        locker.stdin.write('emergency-unlock\n');locker.stdin.flush()
        wait(lambda:not ctl('seat lock-state',True)['locked'],timeout=5)
        cli('remove','agent3')
        wait(lambda:{card['name'] for card in previews()['cards']}=={'agent1','agent2'})
        assert any(client['title']=='agent3-window' for client in ctl('clients',True))
        record('removing a desktop removes only its preview card and retains shared applications')
        raise SystemExit(0)
    # Dragging only moves the shelf; clicking its close control hides it.
    send(f"motion {round(card['x']+80)} {round(card['y']+20)}");send('button 272 1')
    send(f"motion {round(card['x']+30)} {round(card['y']-20)}");send('button 272 0')
    card=wait(lambda:next((item for item in previews()['cards'] if item['name']=='agent3' and item['x'] < card['x']),None))
    click(card['x']+card['width']-20,card['y']+20)
    wait(lambda:previews()['visible'] and all(item['name']!='agent3' for item in previews()['cards']))
    group=next(item for item in next(item for item in json.loads(shell('ipc','bar','geometry')) if item['id']=='cn.agent-desktop')['controls'] if item['name']=='group')
    send(f"motion {round(group['x']+group['width']/2)} {round(group['y']+group['height']/2)}")
    restore=wait(lambda:next((item for item in json.loads(shell('ipc','desktopObserver','controls')) if item['name']=='control:previews'),None))
    click(restore['x']+restore['width']/2,restore['y']+restore['height']/2)
    card=wait(lambda:next((item for item in previews()['cards'] if item['name']=='agent3' and item['frames']>=2),None))
    click(card['x']+card['width']/2,card['y']+100)
    wait(lambda:status()['open'] and status()['name']=='agent3' and status()['readonly'])
    wait(lambda:not previews()['visible'])
    shell('ipc','desktop','observe','main');wait(lambda:not status()['open'])
    release_and_check_previews()
    send(f"motion {human['cursor']['x']} {human['cursor']['y']}")
    record('real harness preview renders fresh frames, moves, hides/restores from grouped bar and enters native read-only view without editing apps')
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
    icon = next(item for item in widget['controls'] if item['name'] == 'group')
    send(f"motion {round(icon['x']+icon['width']/2)} {round(icon['y']+icon['height']/2)}")
    def bar_agent():
        widget = next(item for item in json.loads(shell('ipc','bar','geometry')) if item['id'] == 'cn.agent-desktop')
        return next((item for item in widget['controls'] if item['name'] == 'view:agent1'),None)
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
    group=next(item for item in json.loads(shell('ipc','desktopObserver','controls')) if item['name']=='group')
    send(f"motion {round(group['x']+group['width']/2)} {round(group['y']+group['height']/2)}")
    heading=wait(lambda:next((row for row in json.loads(shell('ipc','desktopObserver','controls')) if row['name']=='control:current-heading' and row['target']=='agent1'),None))
    assert heading['detail'].startswith(cli('state','agent1')['label']) and '只读观察' in heading['detail'],heading
    assert all(row['target']=='agent1' for row in json.loads(shell('ipc','desktopObserver','controls')) if row.get('scope')=='desktop')
    subprocess.run(['grim','-o','human',str(BASE/'menu-scope-secondary.png')],env=ENV,check=True)
    send('motion 650 300');time.sleep(.5)
    send(f"motion {human['cursor']['x']} {human['cursor']['y']}")
    record('native desktop selection updates the named current-desktop heading and every local action target together')
    assert view['native'] and view['readonly'], view
    assert not any(l['namespace']=='cornice-desktop' for level in ctl('layers',True)['human']['levels'].values() for l in level)
    assert human_state()==human, (human_state(),human)
    # Capture the native scene currently presented to the viewer, including a
    # secondary desktop, rather than an unseen primary workspace.
    presented=BASE/'native-presented-screen.png'
    assert shell('screenshot','screen',str(presented))=='requested'
    wait(lambda:presented.exists());wait(lambda:not screenshot_state()['active'])
    assert displayed_clock(presented) > 0
    region=BASE/'native-presented-region.png'
    assert shell('screenshot','region',str(region))=='requested'
    wait(lambda:screenshot_state()['selecting'])
    time.sleep(.2) # Commit the input region before virtual pointer events.
    send('motion 600 200');send('button 272 1');send('motion 800 400');send('button 272 0')
    wait(lambda:region.exists());wait(lambda:not screenshot_state()['active'])
    assert shell('screenshot','region',str(BASE/'readonly-cancel.png'))=='requested'
    wait(lambda:screenshot_state()['selecting']);time.sleep(.2);send('key 1 1');send('key 1 0')
    wait(lambda:not screenshot_state()['active'])
    send(f"motion {human['cursor']['x']} {human['cursor']['y']}")
    assert human_state()==human and not (BASE/'agent1.txt').exists()
    screenshot_button()
    time.sleep(.2) # Wait for the exclusive layer keyboard-focus commit.
    send('key 1 1');send('key 1 0');wait(lambda:not screenshot_state()['active'])
    send(f"motion {human['cursor']['x']} {human['cursor']['y']}")
    assert not (BASE/'agent1.txt').exists() and human_state()==human
    record('screenshot bar button remains usable while viewing a secondary desktop read-only; cancellation never enters an application')
    record('Cornice screenshots capture the presented secondary desktop while read-only observation leaves applications and the primary seat untouched')
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
    control('permission')
    try:wait(lambda:not cli('state','agent1')['agentAllowed'])
    except Exception:
        print('PERMISSION DIAGNOSTICS',status(),shell('ipc','desktop','status'),shell('ipc','desktopObserver','controls'),flush=True)
        subprocess.run(['grim','-o','human',str(BASE/'permission-failure.png')],env=ENV,check=True)
        raise
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
