"""Exercise the real agent launcher while a human Chrome already runs."""
from desktop_harness import *
try:
    initialize()
    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    (config/'config.json').write_text(json.dumps({'agentDesktop':{'enabled':True},'background':{'enabled':False},'weather':{'intervalMinutes':0},'idle':{'lock':0,'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}))
    human_browser=start(['google-chrome-stable','--ozone-platform=wayland','--no-first-run','--no-default-browser-check','about:blank'],'human-chrome')
    wait(lambda:any('chrome' in c['class'].lower() for c in ctl('clients',True)))
    cli('create','agent1','--workspace','11','--virtual-output','1280x800');cli('resume','agent1')
    agent_env=ENV|{'CORNICE_DESKTOP_NAME':'agent1'}
    def agent_shell(*args):return subprocess.check_output([str(PRODUCT/'bin/cornice'),*args],env=agent_env,text=True,stderr=subprocess.PIPE,timeout=8).strip()
    # Compile the same real primary-seat virtual devices used by the native suite.
    for source,name in [('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')]:
        for mode,ext in [('client-header','h'),('private-code','c')]:subprocess.run(['wayland-scanner',mode,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+ext))],check=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'input'),*flags],check=True)
    keyboard=subprocess.Popen([str(BASE/'input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'input.log','w'),text=True,start_new_session=True);PROCESSES.append(keyboard)
    assert keyboard.stdout.readline().strip()=='ready'
    def send(event):
        keyboard.stdin.write(event+'\n');keyboard.stdin.flush()
        assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='done'
    state=cli('state','agent1');token='launcher-test-owner-token-0000000000001'
    ctl('seat present agent1 '+state['display']+' human current '+token)
    ctl('seat present-control '+token+' yes')
    before=human_state()
    wait(lambda:agent_shell('launcher')=='ok')
    agent_shell('ipc','launcher','setQuery','Google Chrome')
    info=json.loads(agent_shell('ipc','launcher','debug'));assert info['first']=='Google Chrome',info
    time.sleep(.3)
    send('key 28 1');send('key 28 0')
    def launched():
        ctl('seat presentation '+token)
        return next((c for c in ctl('clients',True) if 'chrome' in c['class'].lower() and c['workspace']['id']==11),None)
    try:client=wait(launched)
    except Exception:
        print('CLIENTS',json.dumps(ctl('clients',True)),flush=True)
        print('LAUNCHER',agent_shell('ipc','launcher','debug'),flush=True)
        raise
    OWNED_PIDS.append(client['pid'])
    command=pathlib.Path('/proc',str(client['pid']),'cmdline').read_bytes().split(b'\0')
    expected=str(pathlib.Path(ENV['HOME'])/'.local/share/cornice/desktops/agent1/chrome').encode()
    assert b'--user-data-dir='+expected in b' '.join(command),command
    assert not client['xwayland'],client
    assert human_state()==before,(human_state(),before)
    assert human_browser.poll() is None
    def fully_painted():
        from PIL import Image
        subprocess.run(['grim','-o','human',str(BASE/'agent-launcher-chrome.png')],env=ENV,check=True)
        current=next(c for c in ctl('clients',True) if c['pid']==client['pid'])
        agent=cli('state','agent1')
        x=round(current['at'][0]-agent['position'][0]+current['size'][0]-30)
        y=round(current['at'][1]-agent['position'][1]+current['size'][1]/2)
        with Image.open(BASE/'agent-launcher-chrome.png') as image:
            return min(image.convert('RGB').getpixel((x,y)))>200
    wait(fully_painted)
    record('real launcher Enter creates a separate native Wayland Chrome on the controlled agent seat while human Chrome stays open and human workspace/focus are unchanged')
finally:cleanup()
