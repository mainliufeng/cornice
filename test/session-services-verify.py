"""Real notification daemon sharing, endpoint recovery and readonly app actions."""
from desktop_harness import *

try:
    ENV.pop('CORNICE_PRIMARY_SHELL_SOCKET', None)
    ENV['CORNICE_SHELL_SOCKET'] = str(RT / 'custom-primary.sock')
    config = BASE / 'config/cornice'; config.mkdir(parents=True, exist_ok=True)
    (config / 'config.json').write_text(json.dumps({'background': {'enabled': False},
        'notifications': {'timeout': 60000}, 'weather': {'intervalMinutes': 0},
        'idle': {'lock': 0, 'screenOffAc': 0, 'screenOffBattery': 0, 'dimAc': 0, 'dimBattery': 0,
                 'lockOnSleep': False, 'lockOnLockSignal': False, 'lockOnLidClose': False}}))
    initialize()
    # No display is being presented while the primary endpoint starts later.
    primary = start([str(PRODUCT / 'bin/cornice-qs'), '-p', str(PRODUCT / 'shell')], 'cornice')
    wait(lambda: 'pong' in shell('ping'))
    desk_env = ENV | {'CORNICE_DESKTOP_NAME': 'desktop2'}
    def desk(*args):
        return subprocess.check_output([str(PRODUCT / 'bin/cornice'), *args], env=desk_env,
            text=True, stderr=subprocess.PIPE, timeout=8).strip()
    def shared(): return json.loads(desk('ipc', 'sessionServices', 'status'))
    def panel(which=shell): return json.loads(which('ipc', 'notificationPanel', 'state'))
    def observer(): return json.loads(shell('ipc', 'desktopObserver', 'status'))
    wait(lambda: shared()['states'].get('cn.notifications', {}).get('available'))
    assert shared()['connected'] and shared()['primarySocket'] == str(RT / 'custom-primary.sock')
    assert json.loads(shell('path', '--json'))['primarySocket'] == str(RT / 'custom-primary.sock')
    services = json.loads(desk('ipc', 'shell', 'services'))
    assert not set(services).intersection({'cn.lock', 'cn.idle', 'cn.notifications', 'cn.polkit'})
    record('Custom primary endpoint recovers on an unpresented desktop without duplicate session daemons')

    subprocess.run(['notify-send', '-t', '60000', 'Shared notification', 'Across desktops'], env=ENV, check=True)
    wait(lambda: panel(desk)['count'] == 1)
    assert panel(desk)['available'] and panel(desk)['unread'] == 1
    desk('notifications'); wait(lambda: json.loads(shell('ipc', 'notifications', 'status'))['unread'] == 0)
    record('Actual notify-send history, unread and secondary markRead share one owner')
    desk('dnd', 'on'); wait(lambda: panel(desk)['dnd'])
    assert json.loads(desk('ipc', 'menu', 'state'))['dnd']
    desk('dnd', 'off'); wait(lambda: not panel(desk)['dnd'])
    result = subprocess.run([str(PRODUCT / 'bin/cornice'), 'dnd', 'invalid'], env=desk_env, text=True, capture_output=True)
    assert result.returncode != 0
    desk('ipc', 'notifications', 'clear'); wait(lambda: panel(desk)['count'] == 0)
    record('DND on/off and clear agree across center and menu; invalid values fail')

    for source, name in [('virtual-keyboard-unstable-v1', 'virtual-keyboard'), ('wlr-virtual-pointer-unstable-v1', 'virtual-pointer')]:
        for mode, suffix in [('client-header', 'h'), ('private-code', 'c')]:
            subprocess.run(['wayland-scanner', mode, str(FORK / 'protocols' / (source + '.xml')), str(BASE / (name + '.' + suffix))], check=True)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    subprocess.run(['cc', '-I' + str(BASE), str(FORK / 'hyprtester/multiseat/input.c'), str(BASE / 'virtual-keyboard.c'),
                    str(BASE / 'virtual-pointer.c'), '-o', str(BASE / 'input'), *flags], check=True)
    device = subprocess.Popen([str(BASE / 'input'), 'Hyprland', 'human'], env=ENV, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=open(BASE / 'input.log', 'w'), text=True, start_new_session=True)
    PROCESSES.append(device); assert device.stdout.readline().strip() == 'ready'
    def send(event):
        device.stdin.write(event + '\n'); device.stdin.flush()
        assert select.select([device.stdout], [], [], 5)[0] and device.stdout.readline().strip() == 'done'
    def click(point, geometry):
        layers = ctl('layers', True)['human']['levels']
        layer = next(item for rows in layers.values() for item in rows
                     if item['namespace'] == 'cornice-panel' and item['pid'] == primary.pid)
        send('motion ' + str(round(point['x'] + layer['x'])) + ' ' + str(round(point['y'] + layer['y'])))
        send('button 272 1'); send('button 272 0')
    def card():
        data = panel(); assert data['cards'], data
        return data['cards'][0], data
    def fixture(label):
        log = BASE / (label + '.log')
        start(['/usr/bin/python3', ROOT / 'test/fake-notify-reply.py', '--default-action', '--expire', '60000',
               '--timeout', '120', '--summary', label, '--log', log], label + '-client')
        wait(lambda: log.exists() and 'sent id=' in log.read_text())
        return log

    action_log = fixture('readonly-action')
    cli('resume', 'desktop2'); shell('ipc', 'desktop', 'observe', 'desktop2')
    wait(lambda: observer()['presentation'].get('active'))
    shell('notifications'); wait(lambda: panel()['open'] and panel()['cards'])
    info, geometry = card(); assert info['readOnly'] and not info['canReply'], info
    click(info['activation'], geometry); time.sleep(.3)
    assert 'action id=' not in action_log.read_text() and 'replied id=' not in action_log.read_text()
    subprocess.run(['grim', '-o', 'human', str(BASE / 'notification-readonly.png')], env=ENV, check=True)
    record('Readonly notification center shows history but native click invokes no third-party action or reply')

    shell('ipc', 'desktopObserver', 'takeover', 'true'); wait(lambda: observer()['humanControl'])
    wait(lambda: panel()['cards'] and not panel()['cards'][0]['readOnly'])
    info, geometry = card(); click(info['activation'], geometry)
    wait(lambda: 'action id=' in action_log.read_text())
    record('Taking control enables the actual freedesktop default action')
    reply_log = fixture('takeover-reply')
    wait(lambda: panel()['cards'] and panel()['cards'][0]['canReply'])
    info, geometry = card(); click(info['reply'], geometry)
    wait(lambda: panel()['cards'] and panel()['cards'][0]['replying'])
    send('type shared-reply'); send('key 28 1'); send('key 28 0')
    wait(lambda: 'text=shared-reply' in reply_log.read_text())
    record('Taking control enables real typed inline reply with NotificationReplied delivery')

    if panel()['open']: shell('notifications')
    if not panel(desk)['open']: desk('notifications')
    def click_secondary(point):
        desktop = cli('state', 'desktop2')
        layers = ctl('layers', True)[desktop['output']]['levels']
        layer = next(item for rows in layers.values() for item in rows if item['namespace'] == 'cornice-panel')
        send('motion ' + str(round(point['x'] + layer['x'] - desktop['position'][0])) + ' ' +
             str(round(point['y'] + layer['y'] - desktop['position'][1])))
        send('button 272 1'); send('button 272 0')
    proxy_action = fixture('secondary-action')
    wait(lambda: panel(desk)['cards'] and panel(desk)['cards'][0]['canReply'])
    click_secondary(panel(desk)['cards'][0]['activation'])
    wait(lambda: 'action id=' in proxy_action.read_text())
    record('Secondary native center forwards the actual notification default action to its session owner')
    proxy_reply = fixture('secondary-reply')
    wait(lambda: panel(desk)['cards'] and panel(desk)['cards'][0]['canReply'])
    click_secondary(panel(desk)['cards'][0]['reply'])
    wait(lambda: panel(desk)['cards'] and panel(desk)['cards'][0]['replying'])
    send('type proxy-reply'); send('key 28 1'); send('key 28 0')
    wait(lambda: 'text=proxy-reply' in proxy_reply.read_text())
    record('Secondary native center forwards a real keyboard inline reply to its session owner')

    os.kill(primary.pid, signal.SIGTERM)
    wait(lambda: not panel(desk)['available'])
    assert panel(desk)['error']
    record('Owner loss is visible; unavailable services cannot claim successful mutations')

    # Disabled UI operations must not be queued and replayed after owner recovery.
    dnd_action = next(action for action in panel(desk)['actions'] if action['name'] == 'dnd')
    click_secondary(dnd_action)
    primary = start([str(PRODUCT / 'bin/cornice-qs'), '-p', str(PRODUCT / 'shell')], 'cornice-restarted')
    wait(lambda: 'pong' in shell('ping'))
    wait(lambda: panel(desk)['available'] and shared()['connected'])
    assert not panel(desk)['dnd'] and panel(desk)['count'] == 0
    record('Owner restart restores shared state without replaying a disabled mutation')
finally:
    cleanup()
