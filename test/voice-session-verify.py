"""Real Hyprvoice App/F8/native overlay in private real seats and PipeWire.

The audio source emits only zero samples and the test-only ASR worker returns
explicit synthetic transcripts. The production App, audio capture, native seat
routing, GTK overlay and clipboard insertion are real; microphone quality and
ASR accuracy are deliberately outside this regression's claims.
"""
from desktop_harness import *
import threading

APP = pathlib.Path(os.environ['CORNICE_TEST_VOICE_APP'])
OWNER = 'voice-session-owner-token-000000000000001'
checks, measurements = [], {}
heartbeat_stop = threading.Event()


def check(description):
    checks.append(description)
    record(description)


def run(*args):
    return subprocess.check_output(list(map(str, args)), env=ENV, text=True, timeout=4)


def command(action, succeeds=True):
    result = subprocess.run([str(APP), action], env=ENV, capture_output=True, text=True, timeout=5)
    value = json.loads(result.stdout)
    assert value['ok'] == succeeds and (result.returncode == 0) == succeeds, (action, result.stdout, result.stderr)
    return value


def state():
    return command('status')['state']


def phase(name, timeout=8):
    return wait(lambda: (value if (value := state())['phase'] == name and (name == 'recording' or not value['busy']) else None), timeout=timeout)


def send(event):
    keyboard.stdin.write(event + '\n')
    keyboard.stdin.flush()
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'done', event


def heartbeat():
    while not heartbeat_stop.wait(.8):
        try:
            ctl('seat presentation ' + OWNER)
        except (OSError, ValueError):
            return


def click_entry():
    # The private bar may still be laying out a just-opened window. Use fresh
    # client/widget geometry until the physical click actually focuses it.
    def click():
        window=next((item for item in ctl('clients',True) if item['title']=='voice-agent-window'),None)
        if not window:return None
        geometry=json.loads(agent_path.with_suffix('.geometry').read_text())['entry']
        offset=cli('state','agent1')['position']
        send(f"motion {round(window['at'][0]-offset[0]+geometry[0]+geometry[2]/2)} {round(window['at'][1]-offset[1]+geometry[1]+geometry[3]/2)}")
        send('button 272 1');send('button 272 0')
        return ctl('seat input-target',True).get('window',{}).get('address')==window['address']
    wait(click)


def contents():
    return [path.read_text() if path.exists() else '' for path in (human_path, agent_path)]


def ports():
    nodes = json.loads(run('pw-dump'))
    streams = [node for node in nodes if node['type'] == 'PipeWire:Interface:Node' and node['info']['props'].get('node.name') == 'hyprvoice']
    outputs, inputs = run('pw-link', '-o').splitlines(), run('pw-link', '-i').splitlines()
    if streams and not any(port.startswith('hyprvoice:') for port in inputs):
        run('pw-cli', 'set-param', streams[0]['id'], 'PortConfig', '{ direction: Input mode: dsp format: { mediaType: audio mediaSubtype: raw format: F32P channels: 1 position: [ MONO ] } }')
        return None
    source = next((port for port in outputs if port.startswith('voice-test-zero:')), None)
    target = next((port for port in inputs if port.startswith('hyprvoice:')), None)
    return (source, target) if source and target else None


def start_hold():
    (BASE / 'f8-release.json').unlink(missing_ok=True)
    (BASE / 'f8-press.json').unlink(missing_ok=True)
    send('key 66 1')
    reply = wait(lambda: {'ok':True} if state()['phase'] in ('starting','recording') else None)
    if not reply['ok']:
        (BASE / 'f8-failed-context.json').write_text(json.dumps({'reply': reply, 'inputTarget': ctl('seat input-target', True), 'presentation': ctl('seat presentation ' + OWNER, True), 'layers': ctl('layers', True), 'primaryWindow': ctl('activewindow', True), 'appState': state()}, ensure_ascii=False, indent=2))
    assert reply['ok'], reply
    source, target = wait(ports, timeout=3)
    run('pw-link', source, target)
    result = phase('recording')
    time.sleep(.35)
    return result


def layer():
    return next((item for level in ctl('layers', True)['human']['levels'].values() for item in level if item['namespace'] == 'hyprvoice'), None)


def photo(name):
    path = BASE / (name + '.png')
    subprocess.run(['grim', '-o', 'human', str(path)], env=ENV, check=True, timeout=4)
    return path


def visible_pixels(before, after, bounds):
    import gi
    gi.require_version('GdkPixbuf', '2.0')
    from gi.repository import GdkPixbuf
    pictures = [GdkPixbuf.Pixbuf.new_from_file(str(path)) for path in (before, after)]
    changed = count = 0
    for y in range(max(0, bounds['y'] + 40), min(800, bounds['y'] + bounds['h'] - 40), 4):
        for x in range(max(0, bounds['x'] + 40), min(1280, bounds['x'] + bounds['w'] - 40), 4):
            colors = []
            for image in pictures:
                offset = y * image.get_rowstride() + x * image.get_n_channels()
                colors.append(image.get_pixels()[offset:offset + 3])
            # The production panel and GTK editor both use light surfaces;
            # a small RGB difference covers its real painted white panel.
            # This bottom region contains no animated client clock.
            changed += max(abs(a - b) for a, b in zip(*colors)) > 3
            count += 1
    fraction = changed / max(1, count)
    assert count > 100 and fraction > .3, ('Hyprvoice layer exists but native output did not paint its actual pixels', fraction, bounds)
    return fraction


# Query the actual production GTK widget bounds on this test's private AT-SPI
# bus. Physical wl_pointer clicks below still exercise compositor overlay input.
INSPECT = r'''
import json, os, sys
from gi.repository import Gio, GLib
address = os.environ['AT_SPI_BUS_ADDRESS']
assert address.startswith('unix:path=' + os.environ['XDG_RUNTIME_DIR'] + '/')
bus = Gio.DBusConnection.new_for_address_sync(address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
def call(dest, path, interface, method, args=None):
    return bus.call_sync(dest, path, interface, method, args, None, Gio.DBusCallFlags.NONE, 1500, None).unpack()
values, seen = [], set()
def walk(dest, path):
    if (dest, path) in seen or len(seen) > 256: return
    seen.add((dest, path))
    try:
        name = call(dest, path, 'org.freedesktop.DBus.Properties', 'Get', GLib.Variant('(ss)', ('org.a11y.atspi.Accessible', 'Name')))[0]
        states = call(dest, path, 'org.a11y.atspi.Accessible', 'GetState')[0]
        if name:
            item = {'name':name, 'showing':bool(states[0] & (1 << 25)), 'sensitive':bool(states[0] & (1 << 24))}
            try: item['windowBounds'] = call(dest, path, 'org.a11y.atspi.Component', 'GetExtents', GLib.Variant('(u)', (1,)))[0]
            except GLib.Error: pass
            values.append(item)
        for child in call(dest, path, 'org.a11y.atspi.Accessible', 'GetChildren')[0]: walk(*child)
    except GLib.Error: pass
for dest, path in call('org.a11y.atspi.Registry', '/org/a11y/atspi/accessible/root', 'org.a11y.atspi.Accessible', 'GetChildren')[0]:
    pid = call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'GetConnectionUnixProcessID', GLib.Variant('(s)', (dest,)))[0]
    if pid == int(sys.argv[1]): walk(dest, path)
print(json.dumps(values, ensure_ascii=False))
'''


def widgets():
    return json.loads(subprocess.check_output(['/usr/bin/python3', '-c', INSPECT, str(app.pid)], env=app_env, text=True, timeout=8))


def click_overlay_button(name, receipt):
    button = wait(lambda: next((item for item in widgets() if item['name'] == name and item['showing'] and item['sensitive']), None))
    bounds = wait(layer)
    x, y, width, height = button['windowBounds']
    assert width > 5 and height > 5, button
    (BASE / receipt).write_text(json.dumps({'button': button, 'layer': bounds}, ensure_ascii=False, indent=2))
    send(f"motion {round(bounds['x'] + x + width / 2)} {round(bounds['y'] + y + height / 2)}")
    send('button 272 1'); send('button 272 0')


try:
    ENV['PATH'] = str(FORK / 'build-agent-session/hyprctl') + os.pathsep + ENV['PATH']
    initialize()
    start(['fcitx5','-D','--disable=vinput,cloudpinyin'],'fcitx')
    wait(lambda:'true' in subprocess.run(['gdbus','call','--session','--dest','org.freedesktop.DBus','--object-path','/org/freedesktop/DBus','--method','org.freedesktop.DBus.NameHasOwner','org.fcitx.Fcitx5'],env=ENV,capture_output=True,text=True).stdout)
    shell_config = BASE / 'config/cornice'
    shell_config.mkdir(parents=True, exist_ok=True)
    (shell_config / 'config.json').write_text(json.dumps({'agentDesktop': {'enabled': True}, 'background': {'enabled': False}, 'weather': {'intervalMinutes': 0},
        'idle': {'lock': 0, 'screenOffAc': 0, 'screenOffBattery': 0, 'dimAc': 0, 'dimBattery': 0, 'lockOnSleep': False, 'lockOnLockSignal': False, 'lockOnLidClose': False}}))
    start([str(PRODUCT / 'bin/cornice-qs'), '-p', str(PRODUCT / 'shell')], 'primary-shell',ENV | {'WAYLAND_DEBUG':'client'})
    wait(lambda: 'pong' in shell('ping'))
    for source, name in (('virtual-keyboard-unstable-v1', 'virtual-keyboard'), ('wlr-virtual-pointer-unstable-v1', 'virtual-pointer')):
        for mode, extension in (('client-header', 'h'), ('private-code', 'c')):
            subprocess.run(['wayland-scanner', mode, str(FORK / 'protocols' / (source + '.xml')), str(BASE / (name + '.' + extension))], check=True)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    subprocess.run(['cc', '-I' + str(BASE), str(FORK / 'hyprtester/multiseat/input.c'), str(BASE / 'virtual-keyboard.c'), str(BASE / 'virtual-pointer.c'), '-o', str(BASE / 'input'), *flags], check=True)
    keyboard = subprocess.Popen([str(BASE / 'input'), 'Hyprland', 'human'], env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(BASE / 'input.log', 'w'), text=True, start_new_session=True)
    PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'ready'

    human_path, agent_path = BASE / 'human.txt', BASE / 'agent.txt'
    start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', 'human-window', human_path], 'human-client')
    wait(lambda: any(item['title'] == 'human-window' for item in ctl('clients', True)))
    cli('create', 'agent1', '--virtual-output', '1280x800')
    cli('resume', 'agent1')
    cli('launch', 'agent1', '--', '/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', 'voice-agent-window', agent_path)
    wait(lambda: agent_path.with_suffix('.geometry').exists())
    seat = cli('state', 'agent1')
    assert ctl('seat present agent1 ' + seat['display'] + ' human current ' + OWNER, True)['active']
    assert ctl('seat present-control ' + OWNER + ' yes', True)['humanControl']
    heartbeats = threading.Thread(target=heartbeat, daemon=True)
    heartbeats.start()
    click_entry()

    # This isolated daemon has no ALSA discovery, device access, session manager
    # or external microphone. Tests explicitly link its sole zero source.
    pw_config = BASE / 'pipewire.conf'
    pw_config.write_text('''context.properties = { core.daemon = true core.name = pipewire-0 default.clock.rate = 16000 }
context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert support.* = support/libspa-support }
context.modules = [
 { name = libpipewire-module-protocol-native }
 { name = libpipewire-module-access args = { access.socket = { pipewire-0 = "unrestricted" pipewire-0-manager = "unrestricted" } } }
 { name = libpipewire-module-metadata }
 { name = libpipewire-module-spa-node-factory }
 { name = libpipewire-module-client-node }
 { name = libpipewire-module-adapter }
 { name = libpipewire-module-link-factory }
]
context.objects = [
 { factory = spa-node-factory args = { factory.name = support.node.driver node.name = voice-test-driver priority.driver = 20000 } }
 { factory = adapter args = { factory.name = support.null-audio-sink node.name = voice-test-zero media.class = Audio/Source/Virtual node.virtual = true audio.rate = 16000 audio.channels = 1 audio.position = [ MONO ] adapter.auto-port-config = { mode = dsp monitor = true position = preserve } } }
]
''')
    ENV.update(PIPEWIRE_REMOTE=str(RT / 'pipewire-0'), PIPEWIRE_RUNTIME_DIR=str(RT))
    start(['/usr/bin/pipewire', '-c', str(pw_config)], 'pipewire')
    wait(lambda: (RT / 'pipewire-0').is_socket())
    sources = [node['info']['props']['node.name'] for node in json.loads(run('pw-dump')) if node['type'] == 'PipeWire:Interface:Node' and node['info']['props'].get('media.class', '').startswith('Audio/Source')]
    assert sources == ['voice-test-zero'], sources
    check('private real PipeWire exposes exactly one synthetic zero source and no physical microphone')
    models = BASE / 'synthetic-models'
    models.mkdir()
    for name in ('funasr-encoder-f16.gguf', 'qwen3-0.6b-q8_0.gguf', 'fsmn-vad.gguf'):
        (models / name).touch()
    transcripts = ['只读切换保留的合成文字。', '新录音自动输入的合成文字。', '界面按钮结束的合成文字。']
    (RT / 'transcripts.json').write_text(json.dumps(transcripts, ensure_ascii=False))
    (RT / 'decode-count').write_text('0')
    worker = BASE / 'synthetic-asr-worker'
    worker.write_text('''#!/usr/bin/python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['XDG_RUNTIME_DIR'])
print('{"ready":true}', flush=True)
for line in sys.stdin:
    audio = pathlib.Path(json.loads(line)['audio'])
    assert audio.parent.resolve() == pathlib.Path(os.environ['TMPDIR']).resolve()
    wave = audio.read_bytes()
    assert wave[:4] == b'RIFF' and wave[36:40] == b'data'
    assert len(wave) > 44 and not any(wave[44:]), 'Only synthetic zero samples allowed'
    counter = root/'decode-count'
    index = int(counter.read_text())
    text = json.loads((root/'transcripts.json').read_text())[index]
    counter.write_text(str(index + 1))
    print(json.dumps({'text':text, 'speech':True}, ensure_ascii=False), flush=True)
''')
    worker.chmod(0o700)
    config = BASE / 'hyprvoice.json'
    config.write_text(json.dumps({'asr': {'backend': 'fun'}, 'fun': {'worker': str(worker), 'model_dir': str(models)}, 'scene': 'raw', 'context': {'enabled': False},
        'audio_source': 'voice-test-zero', 'auto_commit': True, 'max_recording_seconds': 30}))
    ENV['HYPRVOICE_CONFIG'] = str(config)
    a11y = subprocess.check_output(['dbus-daemon', '--session', '--fork', '--address=unix:path=' + str(RT / 'a11y'), '--print-address=1', '--print-pid=1'], env=ENV, text=True).splitlines()
    OWNED_BUS_PIDS.append(int(a11y[1]))
    app_env = dict(ENV, AT_SPI_BUS_ADDRESS=a11y[0], GTK_A11Y='atspi')
    app_env.pop('NO_AT_BRIDGE', None)
    start(['/usr/lib/at-spi2-registryd'], 'a11y-registry', env=app_env)
    app = start([str(APP), 'serve'], 'voice-app', env=app_env)
    wait(lambda: (RT / 'hyprvoice/control.sock').is_socket())
    phase('idle')
    assert state()['model_ready']
    # Use Cornice's actual registered press/release bindings, rather than
    # replacing them with test-only compositor commands.
    wait(lambda:any(item.get('dispatcher')=='notify' and item.get('arg')=='voice-press' for item in ctl('binds',True)), timeout=8)

    before = photo('native-agent-before-voice')
    start_hold()
    bounds = wait(layer)
    time.sleep(.15)
    recording = photo('native-agent-recording-overlay')
    measurements['recordingOverlayChangedFraction'] = visible_pixels(before, recording, bounds)
    assert any(item['name'] == '语音输入' and item['showing'] for item in widgets())
    assert ctl('seat input-target', True)['allowed'], 'non-interactive recording overlay stole application keyboard focus'
    check('actual production Hyprvoice recording overlay is visibly painted above the native Agent scene without stealing its keyboard focus')
    started = time.monotonic()
    ctl('seat present-control ' + OWNER + ' no', True)
    send('key 66 0')
    retained = phase('ready', timeout=3)
    measurements['readonlyStopAndRetainMs'] = round((time.monotonic() - started) * 1000, 2)
    assert retained['raw'] == transcripts[0] and retained['text'] == transcripts[0] and retained['seconds'] < 5, retained
    assert not (BASE / 'f8-release.json').exists(), 'readonly route unexpectedly forwarded the held F8 release'
    assert contents() == ['', ''], contents()
    photo('native-agent-readonly-retained')
    check('actual App stops held-F8 recording promptly when takeover becomes read-only, despite the swallowed key release; transcript is retained and no application is edited')
    ctl('seat present-control ' + OWNER + ' yes', True)
    click_entry()
    wait(lambda: state()['insertion_status'] == 'window')
    time.sleep(.2)
    assert contents() == ['', ''], 'restoring the original window automatically inserted a retained transcript'
    photo('native-agent-retained-restored-input')
    click_overlay_button('输入', 'physical-overlay-input-button.json')
    wait(lambda: contents() == ['', transcripts[0]])
    phase('idle')
    check('restoring the original Agent window shows the actual Input button without automatic insertion; a physical click explicitly rebinds fresh focus and inserts the retained result once')

    start_hold()
    send('key 66 0')
    wait(lambda: contents() == ['', transcripts[0] + transcripts[1]])
    phase('idle')
    check('fresh genuine Agent F8 press-and-release follows real audio capture, production App finalization and automatic seat-scoped paste')

    start_hold()
    click_overlay_button('结束录音', 'physical-overlay-stop-button.json')
    wait(lambda: contents() == ['', transcripts[0] + transcripts[1] + transcripts[2]], timeout=4)
    send('key 66 0')
    phase('idle')
    check('a physical primary-seat pointer click on the actual Hyprvoice overlay stop button reaches the production App above the native Agent desktop and inserts only into its focused Agent input')
    photo('native-agent-final-input')
    assert int((RT / 'decode-count').read_text()) == 3
    # The broker owns this presentation, so readonly managed callbacks carry
    # the same real viewer context as the deployed desktop switcher.
    ctl('seat unpresent ' + OWNER)
    shell('ipc', 'desktop', 'observe', 'agent1')
    wait(lambda:json.loads(shell('ipc','desktopObserver','status'))['presentation'].get('active'))
    send('key 66 1');send('key 66 0')
    wait(lambda:state()['error']!='' and not state()['busy'])
    assert not state()['busy'] and contents()==['',transcripts[0]+transcripts[1]+transcripts[2]]
    bounds=wait(layer);time.sleep(.15)
    photo('readonly-no-editor-voice-error')
    check('F8 without a local editor shows a registered native refusal overlay and does not record or write to an observed application')
    command('cancel')
    result = {'checks': checks, 'measurements': measurements, 'contents': contents(), 'realProductionApp': True, 'realPipeWire': True,
              'syntheticZeroAudio': True, 'syntheticTestAsr': True, 'realMicrophoneOrAsrAccuracyTested': False}
    (BASE / 'voice-session-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False), flush=True)
finally:
    heartbeat_stop.set()
    cleanup()
