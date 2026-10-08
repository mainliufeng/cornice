"""Real Pi and configured vision endpoint operate a nested GTK desktop."""
from desktop_harness import *
import hashlib
import threading

def runtime(command, *args, prompt=None):
    result = subprocess.run([str(PRODUCT/'bin/cornice-agent-runtime'),command,*args],input=prompt,env=ENV,text=True,capture_output=True,timeout=15)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)

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
    human = human_state()
    cli('create','modeltest','--virtual-output','1280x800')
    cli('resume','modeltest')
    cli('launch','modeltest','--','/usr/bin/python3',ROOT/'test/agent-desktop-client.py','Model verification',BASE/'model.txt')
    wait(lambda: len(ctl('clients',True)) == 1)
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
    result = wait(lambda: (value if (value := runtime('status','modeltest'))['phase'] in terminal else None),timeout=180)
    assert result['phase'] == 'completed', result
    assert (BASE/'model.txt').read_text() == 'pi真实中文'
    assert int((BASE/'model.click').read_text()) >= 1
    assert human_state() == human
    record('real Pi + DeepSeek vision identifies GTK controls, types Chinese, clicks and verifies completion')
    runtime('start','modeltest',prompt='请先截图，然后等待直到我恢复 Agent 控制；如果控制被人接管要调用 desktop_wait 等待，不要中止。恢复后重新截图，在输入框末尾添加 restored，然后截图验证并完成。开始时先用 desktop_wait 等待30秒，让我进行接管。')
    directory = RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']/'jobs/modeltest'
    wait(lambda: (directory/'events.jsonl').exists() and 'desktop_capture' in (directory/'events.jsonl').read_text())
    with socket.socket(socket.AF_UNIX) as owner:
        owner.connect(str(RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']/'desktop.sock'))
        rpc(owner,'takeover',{'name':'modeltest'})
        shot = rpc(owner,'frame',{'name':'modeltest'})
        client = next(window for window in ctl('clients',True) if window['title'] == 'Model verification')
        geometry = json.loads((BASE/'model.geometry').read_text())['entry']
        state = cli('state','modeltest')
        rpc(owner,'human.input',{'name':'modeltest','frameId':shot['frameId'],'events':[{'action':'click',
            'x':client['at'][0]-state['position'][0]+geometry[0]+geometry[2]/2,
            'y':client['at'][1]-state['position'][1]+geometry[1]+geometry[3]/2}]})
        shot = rpc(owner,'frame',{'name':'modeltest'})
        # Human changes the real input, forcing model to inspect the new state.
        rpc(owner,'human.input',{'name':'modeltest','frameId':shot['frameId'],'events':[{'action':'chord','keys':['CTRL','a']}]})
        shot = rpc(owner,'frame',{'name':'modeltest'})
        rpc(owner,'human.input',{'name':'modeltest','frameId':shot['frameId'],'events':[{'action':'text','text':'human'}]})
        end=time.monotonic()+25
        while time.monotonic()<end:
            rpc(owner,'frame',{'name':'modeltest'})
            if runtime('status','modeltest')['phase'] == 'waiting': break
            time.sleep(.5)
        assert runtime('status','modeltest')['phase'] == 'waiting'
        rpc(owner,'release',{'name':'modeltest'})
    assert cli('state','modeltest')['paused']
    assert (BASE/'model.txt').read_text() == 'human'
    cli('resume','modeltest')
    result = wait(lambda: (value if (value := runtime('status','modeltest'))['phase'] in terminal else None),timeout=180)
    assert result['phase'] == 'completed', result
    assert (BASE/'model.txt').read_text() == 'humanrestored'
    assert human_state() == human
    record('real model senses takeover, chooses wait, sees human edits and continues with new frame after explicit resume')
    runtime('start','modeltest',prompt='这是一个只能连续执行的临时任务：先截图检查窗口。如果在操作前被人接管或暂停，任务就失效，必须 desktop_finish cancelled 并说明原因，不要等待恢复，也不要修改界面。')
    with socket.socket(socket.AF_UNIX) as owner:
        owner.connect(str(RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']/'desktop.sock'))
        rpc(owner,'takeover',{'name':'modeltest'})
        end = time.monotonic()+90
        while time.monotonic()<end:
            rpc(owner,'frame',{'name':'modeltest'})
            result = runtime('status','modeltest')
            if result['phase'] in terminal: break
            time.sleep(.5)
        assert result['phase'] == 'cancelled', result
        assert cli('state','modeltest')['controlMode'] == 'human'
        rpc(owner,'release',{'name':'modeltest'})
    assert (BASE/'model.txt').read_text() == 'humanrestored'
    assert cli('state','modeltest')['paused']
    record('real model chooses cancellation when interrupted task context requires it; human control is preserved')
    cli('resume','modeltest')
    runtime('start','modeltest',prompt='请先截图；如果控制被暂停，请调用 desktop_wait 等待，直到用户取消任务或恢复，不要操作窗口。')
    cli('pause','modeltest')
    wait(lambda: runtime('status','modeltest')['phase'] == 'waiting',timeout=90)
    duplicate = subprocess.run([str(PRODUCT/'bin/cornice-agent-runtime'),'start','modeltest'],input='另一个任务',env=ENV,text=True,capture_output=True,timeout=10)
    assert duplicate.returncode != 0 and 'already running' in duplicate.stderr
    assert cli('state','modeltest')['paused']
    pi_pid = runtime('status','modeltest')['piPid']
    runtime('cancel','modeltest')
    wait(lambda: runtime('status','modeltest')['phase'] == 'cancelled')
    wait(lambda: not pathlib.Path('/proc',str(pi_pid)).exists())
    assert (BASE/'model.txt').read_text() == 'humanrestored'
    assert human_state() == human
    record('duplicate submission cannot restore a paused job; user cancellation stops the real waiting Pi process')


finally:
    recording_stop.set()
    if recorder: recorder.join(10)
    if encoder:
        encoder.stdin.close(); encoder.wait(timeout=30)
        assert encoder.returncode == 0 and not recording_errors, recording_errors
    cleanup()
