"""Real bar clicks create a playable MP4 of the native presented desktop."""
from desktop_harness import *
from PIL import Image
try:
    initialize()
    ENV['PATH']='/home/liufeng/.local/bin:'+ENV['PATH']
    directory=pathlib.Path(ENV['HOME'])/'Videos/Cornice'
    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    (config/'config.json').write_text(json.dumps({'agentDesktop':{'enabled':True},'bar':{'layout':{'left':[{'id':'cn.recording'}],'center':[],'right':[]}},'background':{'enabled':False},'weather':{'intervalMinutes':0},'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}))
    cli('create','agent1','--workspace','11','--virtual-output','1280x800');cli('resume','agent1')
    cli('launch','agent1','--','/usr/bin/python3',ROOT/'test/agent-desktop-client.py','recorded-agent-window',BASE/'typed.txt')
    wait(lambda:any(c['title']=='recorded-agent-window' for c in ctl('clients',True)))
    for source,name in [('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')]:
        for mode,ext in [('client-header','h'),('private-code','c')]:subprocess.run(['wayland-scanner',mode,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+ext))],check=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'input'),*flags],check=True)
    keyboard=subprocess.Popen([str(BASE/'input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'input.log','w'),text=True,start_new_session=True);PROCESSES.append(keyboard)
    assert keyboard.stdout.readline().strip()=='ready'
    def send(event):
        keyboard.stdin.write(event+'\n');keyboard.stdin.flush()
        assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='done'
    def click():send('motion 20 16');send('button 272 1');send('button 272 0')
    start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice')
    def status():return json.loads(shell('ipc','recording','status'))
    wait(lambda:status()['state']=='idle')
    shell('ipc','desktop','observe','agent1');wait(lambda:json.loads(shell('ipc','desktopObserver','status'))['presentation'].get('active'))
    before=human_state()
    click();wait(lambda:status()['state']=='recording')
    assert shell('ipc','recording','start','human')=='busy'
    time.sleep(1.2)
    subprocess.run(['grim','-o','human',str(BASE/'recording-bar.png')],env=ENV,check=True)
    # Change real rendered pixels during capture, including a workspace change.
    shell('ipc','desktop','observe','');wait(lambda:not json.loads(shell('ipc','desktopObserver','status'))['open'])
    time.sleep(1.2)
    click();wait(lambda:status()['state']=='idle')
    state=status();assert not state['error'],state
    video=pathlib.Path(state['lastFile']);assert video.is_file() and video.parent==directory and video.stat().st_size>1000,state
    assert video.stat().st_mode & 0o077==0
    metadata=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',video],env=ENV,text=True))
    stream=next(s for s in metadata['streams'] if s['codec_type']=='video')
    assert stream['codec_name']=='h264' and (stream['width'],stream['height'])==(1280,800),metadata
    assert float(metadata['format']['duration'])>1
    frames=BASE/'frames';frames.mkdir()
    subprocess.run(['ffmpeg','-v','error','-i',video,'-vf','fps=2',str(frames/'%03d.png')],env=ENV,check=True)
    files=sorted(frames.glob('*.png'));assert len(files)>2
    assert Image.open(files[0]).tobytes()!=Image.open(files[-1]).tobytes(),'recording did not capture the native desktop changing'
    record('two real bar clicks start and stop native screen capture; a private H.264 MP4 shows the observed desktop and subsequent view change')
    assert shell('ipc','recording','start','not-an-output')=='no-output'
    assert shell('ipc','recording','stop')=='idle'
    record('invalid outputs and redundant stop fail safely without input grabs')
    # An output disappearing must finish the MP4 rather than orphan its recorder.
    ok('output create headless disposable')
    wait(lambda:'disposable' in [m['name'] for m in ctl('monitors',True)])
    wait(lambda:shell('ipc','recording','start','disposable')=='requested')
    wait(lambda:status()['state']=='recording');time.sleep(.5)
    ok('output remove disposable');wait(lambda:status()['state']=='idle')
    def recorder_gone():
        result=subprocess.run(['pgrep','-x','wf-recorder'],env=ENV,capture_output=True,text=True)
        rows=[pathlib.Path('/proc',pid,'stat').read_text() for pid in result.stdout.split() if pathlib.Path('/proc',pid,'stat').exists()]
        return not rows
    wait(recorder_gone,timeout=5)
    record('removing the recorded output terminates the recorder and restores idle state')
finally:cleanup()
