"""Real ChatGPT: physical Quit during secondary-desktop takeover.

Run only through isolated-desktop-test.sh: no host profiles, credentials, bus,
network or physical input devices are exposed to these disposable instances.
"""
from desktop_harness import *

assert os.environ.get('CORNICE_TEST_SANDBOX') == '1'


def send(command):
    pointer.stdin.write(command + '\n')
    pointer.stdin.flush()
    assert select.select([pointer.stdout], [], [], 5)[0]
    assert pointer.stdout.readline().strip() == 'done'


def click(x, y):
    for command in (f'motion {round(x)} {round(y)}', 'button 272 1', 'button 272 0'):
        send(command)


def icons():
    return [item for item in json.loads(shell('ipc', 'tray', 'dump')) if item['title'] in ('ChatGPT', 'Codex')]


def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)


try:
    initialize()
    cli('resume', 'desktop2')
    config = BASE / 'config/cornice'
    config.mkdir(parents=True, exist_ok=True)
    (config / 'config.json').write_text(json.dumps({'agentDesktop': {'enabled': True},
        'weather': {'intervalMinutes': 0}, 'background': {'enabled': False},
        'idle': {'lock': 0, 'screenOffAc': 0, 'screenOffBattery': 0, 'dimAc': 0, 'dimBattery': 0}}))
    start([str(PRODUCT / 'bin/cornice-qs'), '-p', str(PRODUCT / 'shell')], 'shell')
    wait(lambda: json.loads(shell('ipc', 'desktop', 'status'))['available'])
    for source, name in (('virtual-keyboard-unstable-v1', 'virtual-keyboard'), ('wlr-virtual-pointer-unstable-v1', 'virtual-pointer')):
        for mode, extension in (('client-header', 'h'), ('private-code', 'c')):
            subprocess.run(['wayland-scanner', mode, str(FORK / 'protocols' / (source + '.xml')), str(BASE / (name + '.' + extension))], check=True)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    subprocess.run(['cc', '-I' + str(BASE), str(FORK / 'hyprtester/multiseat/input.c'), str(BASE / 'virtual-keyboard.c'),
                    str(BASE / 'virtual-pointer.c'), '-o', str(BASE / 'input'), *flags], check=True)
    pointer = subprocess.Popen([str(BASE / 'input'), 'Hyprland', 'human'], env=ENV, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=open(BASE / 'input.log', 'w'), text=True, start_new_session=True)
    PROCESSES.append(pointer)
    assert select.select([pointer.stdout], [], [], 5)[0] and pointer.stdout.readline().strip() == 'ready'
    state = cli('state', 'desktop2')
    app = start(['/usr/lib/chatgpt/ChatGPT', '--ozone-platform=wayland', '--disable-gpu',
                 '--user-data-dir=' + str(BASE / 'chatgpt')], 'chatgpt',
                ENV | {'WAYLAND_DISPLAY': state['display'], 'CORNICE_DESKTOP_NAME': 'desktop2'})
    wait(lambda: len(icons()) == 1, timeout=60)
    assert app.poll() is None
    shell('ipc', 'desktop', 'observe', 'desktop2')
    wait(lambda: json.loads(shell('ipc', 'desktopObserver', 'status'))['presentation'].get('active'))
    icon = icons()[0]
    click(icon['x'] + icon['width'] / 2, 16)
    time.sleep(.4)
    assert not json.loads(shell('ipc', 'tray', 'menuState'))['opened']
    record('read-only observation refuses physical tray interaction')
    shell('ipc', 'desktopObserver', 'takeover', 'true')
    wait(lambda: json.loads(shell('ipc', 'desktopObserver', 'status'))['humanControl'])
    icon = icons()[0]
    click(icon['x'] + icon['width'] / 2, 16)
    menu = wait(lambda: (value if (value := json.loads(shell('ipc', 'tray', 'menuState')))['opened'] else None))
    row = next(row for row in menu['columns'][0]['rows'] if row['text'] == 'Quit')
    layer = next(obj for obj in objects(ctl('layers', True)) if obj.get('namespace') == 'cornice-menu')
    subprocess.run(['grim', '-o', 'human', str(BASE / 'quit-menu.png')], env=ENV, check=True)
    click(layer['x'] + row['x'], layer['y'] + row['y'])
    wait(lambda: not icons(), timeout=30)
    wait(lambda: app.poll() is not None, timeout=30)
    record('physical Quit during secondary-desktop takeover removes the real ChatGPT tray icon and exits its process')
    shell('ipc', 'desktopObserver', 'takeover', 'false')
    assert not json.loads(shell('ipc', 'desktopObserver', 'status'))['humanControl']
finally:
    cleanup()
