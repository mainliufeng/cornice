"""Real Pi and configured vision endpoint operate a nested GTK desktop."""
from desktop_harness import *
import fcntl
import hashlib
import shutil
import threading

def runtime(command, *args, prompt=None):
    result = subprocess.run([str(PRODUCT/'bin/cornice-agent-runtime'),command,*args],input=prompt,env=ENV,text=True,capture_output=True,timeout=15)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)

def physical(command):
    keyboard.stdin.write(command + '\n'); keyboard.stdin.flush()
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'done', command


def entry(title, name=None):
    client = wait(lambda: next((window for window in ctl('clients', True) if window['title'] == title), None))
    destination = BASE / ('model.geometry' if name else 'human.geometry')
    bounds = wait(lambda: json.loads(destination.read_text()))['entry']
    offset = cli('state', name)['position'] if name else [0, 0]
    physical(f"motion {round(client['at'][0] - offset[0] + bounds[0] + bounds[2] / 2)} {round(client['at'][1] - offset[1] + bounds[1] + bounds[3] / 2)}")
    physical('button 272 1'); physical('button 272 0')
    if name:
        wait(lambda: ctl('seat state ' + name, True)['windowAddress'] == client['address'])
    else:
        wait(lambda: ctl('activewindow', True)['address'] == client['address'])


def replace_entry(text):
    for command in ('mods 4', 'key 29 1', 'key 30 1', 'key 30 0', 'key 29 0', 'mods 0'):
        physical(command)
    physical('type ' + text)


def native_owner():
    owner = socket.socket(socket.AF_UNIX)
    owner.settimeout(5)
    owner.connect(str(RT / 'cornice' / ENV['HYPRLAND_INSTANCE_SIGNATURE'] / 'desktop.sock'))
    view = rpc(owner, 'present', {'name': 'modeltest'})
    assert view['active'] and view['native'] and not view['humanControl'], view
    return owner


def heartbeat(owner):
    view = rpc(owner, 'present-status', {'name': 'modeltest'})
    assert view['active'] and view['native'], view
    return view


def task_phase(phase, owner=None):
    if owner: heartbeat(owner)
    value = runtime('status', 'modeltest')
    return value if value['phase'] == phase else None


def terminal_result(accepted=None, owner=None, timeout=180):
    def ended():
        if owner: heartbeat(owner)
        value = runtime('status', 'modeltest')
        if accepted: assert value['runId'] == accepted['runId'], (accepted, value)
        return value if value['phase'] in terminal else None
    return wait(ended, timeout=timeout)


def save_run(label, value, owner=None):
    # A terminal status is written before Pi cleanup. Wait for the inherited
    # submission lock so evidence is final and the next request cannot race it.
    def released():
        if owner: heartbeat(owner)
        with open(directory / 'lock', 'a') as lock:
            try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: return False
            return True
    wait(released)
    # Each desktop reuses its job directory; preserve evidence before the next
    # genuine model request overwrites it. Do not copy private model config.
    destination = BASE / 'model-runs' / label
    destination.mkdir(parents=True)
    for filename in ('status.json', 'events.jsonl', 'pi.stderr.log', 'result.json', 'prompt.json', 'identity.json'):
        source = directory / filename
        if source.exists(): shutil.copyfile(source, destination / filename)
    assert json.loads((destination / 'status.json').read_text())['runId'] == value['runId']
    (destination / 'desktop-state.json').write_text(json.dumps({'human': human_state(), 'agent': cli('state', 'modeltest')}, ensure_ascii=False, indent=2))
    if owner: heartbeat(owner)
    cli('capture', 'modeltest', destination / 'agent-final.png')
    if owner: heartbeat(owner)
    subprocess.run(['grim', '-o', 'human', str(destination / 'physical-final.png')], env=ENV, check=True)
    if owner: heartbeat(owner)


recording_stop = threading.Event()
recording_errors = []
recorder = None
encoder = None

def record_desktop():
    began = time.monotonic()
    frames = 0
    try:
        while not recording_stop.is_set():
            image = cli('capture','modeltest',BASE/'record-frame.png')
            pixels = (BASE/'record-frame.png').read_bytes()
            due = max(frames+1, int((time.monotonic()-began)*5))
            while frames < due:
                encoder.stdin.write(pixels); frames += 1
            encoder.stdin.flush()
            recording_stop.wait(max(0, began+frames/5-time.monotonic()))
    except Exception as error:
        if not recording_stop.is_set(): recording_errors.append(str(error))

try:
    initialize()
    # Input is injected into the primary wl_seat, exactly as native takeover
    # receives a human keyboard/pointer; Agent screenshot tools stay separate.
    for source, name in (('virtual-keyboard-unstable-v1', 'virtual-keyboard'), ('wlr-virtual-pointer-unstable-v1', 'virtual-pointer')):
        for mode, extension in (('client-header', 'h'), ('private-code', 'c')):
            subprocess.run(['wayland-scanner', mode, str(FORK / 'protocols' / (source + '.xml')), str(BASE / (name + '.' + extension))], check=True)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    subprocess.run(['cc', '-I' + str(BASE), str(FORK / 'hyprtester/multiseat/input.c'), str(BASE / 'virtual-keyboard.c'), str(BASE / 'virtual-pointer.c'), '-o', str(BASE / 'input'), *flags], check=True)
    keyboard = subprocess.Popen([str(BASE / 'input'), 'Hyprland', 'human'], env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=open(BASE / 'input.log', 'w'), text=True, start_new_session=True)
    PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'ready'
    start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', 'human-window', BASE / 'human.txt'], 'human-client')
    entry('human-window')
    physical('type human-desktop-sentinel')
    wait(lambda: (BASE / 'human.txt').read_text() == 'human-desktop-sentinel')
    physical('motion 440 510')
    human = human_state()
    cli('create','modeltest','--virtual-output','1280x800')
    cli('resume','modeltest')
    cli('launch','modeltest','--','/usr/bin/python3',ROOT/'test/agent-desktop-client.py','Model verification',BASE/'model.txt')
    wait(lambda: len(ctl('clients',True)) == 2 and any(window['title'] == 'Model verification' for window in ctl('clients',True)))
    encoder = subprocess.Popen(['ffmpeg','-y','-loglevel','error','-f','image2pipe','-framerate','5','-vcodec','png','-i','-',
        '-c:v','libx264','-preset','veryfast','-crf','23','-pix_fmt','yuv420p',str(BASE/'real-pi-desktop.mp4')],stdin=subprocess.PIPE,stderr=open(BASE/'video.log','w'))
    recorder = threading.Thread(target=record_desktop,daemon=True); recorder.start()
    own_environment = dict(ENV, CORNICE_SHELL_SOCKET=str(RT/('cs-'+hashlib.sha256(ENV['HYPRLAND_INSTANCE_SIGNATURE'].encode()).hexdigest()[:8]+'-modeltest.sock')))
    def own_shell():
        return json.loads(subprocess.check_output([str(PRODUCT/'bin/cornice'),'ipc','desktop','status'],env=own_environment,text=True,stderr=subprocess.PIPE,timeout=8))
    wait(lambda: own_shell()['available'])
    binding = bind('modeltest')
    shot = tool(binding,'capture')
    tool(binding,'input',{'frameId':shot['frameId'],'action':'chord','keys':['SUPER','a']})
    wait(lambda: own_shell()['prompt']['open'])
    shot = tool(binding,'capture')
    (BASE/'super-a-prompt.png').write_bytes(base64.b64decode(shot['pngBase64']))
    tool(binding,'input',{'frameId':shot['frameId'],'action':'text','text':'在当前窗口输入框中输入 pi真实中文，然后点击 Record a click 按钮。截图核实后 desktop_finish completed。只操作这个窗口。'})
    shot = tool(binding,'capture')
    tool(binding,'input',{'frameId':shot['frameId'],'action':'chord','keys':['CTRL','Return']})
    wait(lambda: not own_shell()['prompt']['open'])
    record('Super+A opens actual Agent prompt; Chinese text and Ctrl+Enter submit a real Pi task')
    terminal = ('completed','cancelled','blocked','failed','needs_attention')
    directory = RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']/'jobs/modeltest'
    result = terminal_result()
    assert result['phase'] == 'completed', result
    assert (BASE/'model.txt').read_text() == 'pi真实中文'
    assert int((BASE/'model.click').read_text()) >= 1
    assert human_state() == human
    assert (BASE/'human.txt').read_text() == 'human-desktop-sentinel'
    save_run('01-input-and-click', result)
    record('real Pi + DeepSeek vision identifies GTK controls, types Chinese, clicks and verifies completion')
    with native_owner() as owner:
        accepted = runtime('start','modeltest',prompt='请先截图。若控制被人接管或暂停，必须调用 desktop_wait 等待，不要中止，不要试图恢复控制。只有人结束接管并明确恢复 Agent 控制之后，才重新截图，检查人修改后的输入框，在末尾添加 restored；然后截图核实，desktop_finish completed。等待期间不要修改界面。')
        view = rpc(owner,'takeover',{'name':'modeltest'})
        assert view['active'] and view['native'] and view['humanControl'], view
        assert cli('state','modeltest')['controlMode'] == 'human'
        assert 'revoked' in tool(binding,'state',succeeds=False)
        # The human edits through the compositor's physical-seat path; no
        # screenshot acknowledgement or broker input RPC participates.
        entry('Model verification', 'modeltest')
        replace_entry('human')
        wait(lambda: (BASE/'model.txt').read_text() == 'human')
        wait(lambda: task_phase('waiting', owner), timeout=90)
        assert heartbeat(owner)['humanControl']
        subprocess.run(['grim','-o','human',str(BASE/'native-model-takeover.png')],env=ENV,check=True)
        view = rpc(owner,'release',{'name':'modeltest'})
        assert view['active'] and not view['humanControl'], view
        assert cli('state','modeltest')['paused']
        # Ending takeover leaves the model waiting until explicit resume.
        time.sleep(.5)
        heartbeat(owner)
        assert runtime('status','modeltest')['phase'] in ('waiting', 'interrupted')
        assert (BASE/'model.txt').read_text() == 'human'
    wait(lambda: human_state() == human)
    cli('resume','modeltest')
    result = terminal_result(accepted)
    assert result['phase'] == 'completed', result
    assert (BASE/'model.txt').read_text() == 'humanrestored'
    assert (BASE/'human.txt').read_text() == 'human-desktop-sentinel'
    assert human_state() == human
    save_run('02-native-takeover-restored', result)
    record('real model waits through native physical takeover, sees human edits after explicit resume and restores the exact human scene')
    with native_owner() as owner:
        accepted = runtime('start','modeltest',prompt='这是一个只能连续执行的临时任务：先截图检查窗口。如果在操作前被人接管或暂停，任务就失效，必须 desktop_finish cancelled 并说明原因，不要等待恢复，也不要修改界面。')
        view = rpc(owner,'takeover',{'name':'modeltest'})
        assert view['active'] and view['native'] and view['humanControl'], view
        result = terminal_result(accepted, owner, timeout=90)
        assert result['phase'] == 'cancelled', result
        assert cli('state','modeltest')['controlMode'] == 'human'
        assert heartbeat(owner)['humanControl']
        assert (BASE/'model.txt').read_text() == 'humanrestored'
        save_run('03-context-cancelled', result, owner)
        view = rpc(owner,'release',{'name':'modeltest'})
        assert view['active'] and not view['humanControl'], view
        assert cli('state','modeltest')['paused']
    wait(lambda: human_state() == human)
    assert (BASE/'human.txt').read_text() == 'human-desktop-sentinel'
    record('real model chooses contextual cancellation during native takeover while human control and application contents remain intact')
    with native_owner() as owner:
        accepted = runtime('start','modeltest',prompt='请先截图；如果控制被暂停，请调用 desktop_wait 等待，直到用户取消任务或恢复，不要操作窗口。')
        cli('pause','modeltest')
        wait(lambda: task_phase('waiting', owner),timeout=90)
        duplicate = subprocess.run([str(PRODUCT/'bin/cornice-agent-runtime'),'start','modeltest'],input='另一个任务',env=ENV,text=True,capture_output=True,timeout=10)
        assert duplicate.returncode != 0 and 'already running' in duplicate.stderr
        assert cli('state','modeltest')['paused']
        assert runtime('status','modeltest')['runId'] == accepted['runId']
        pi_pid = runtime('status','modeltest')['piPid']
        runtime('cancel','modeltest')
        result = wait(lambda: task_phase('cancelled', owner))
        assert result['runId'] == accepted['runId']
        wait(lambda: not pathlib.Path('/proc',str(pi_pid)).exists())
        assert (BASE/'model.txt').read_text() == 'humanrestored'
        assert (BASE/'human.txt').read_text() == 'human-desktop-sentinel'
        assert cli('state','modeltest')['paused']
        assert not heartbeat(owner)['humanControl']
        save_run('04-user-cancelled', result, owner)
    wait(lambda: human_state() == human)
    record('duplicate submission leaves the real waiting Pi job paused; explicit user cancellation stops Pi and restores the exact human scene')


finally:
    recording_stop.set()
    if recorder: recorder.join(10)
    if encoder:
        encoder.stdin.close(); encoder.wait(timeout=30)
        assert encoder.returncode == 0 and not recording_errors, recording_errors
    cleanup()
