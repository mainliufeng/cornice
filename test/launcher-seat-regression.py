"""Real physical shortcuts, Chrome popups and launcher-to-CDP continuity."""
from desktop_harness import *
from cdp_client import Cdp
from PIL import Image, ImageChops
try:
    initialize()
    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    (config/'config.json').write_text(json.dumps({'agentDesktop':{'enabled':True},'bar':{'layout':{'left':[{'id':'cn.agent-desktop'},{'id':'cn.launcher'}],'center':[],'right':[]}},'background':{'enabled':False},'weather':{'intervalMinutes':0},'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}))
    primary_chat=start(['chatgpt','--ozone-platform=wayland'],'human-chatgpt')
    primary_chat_window=wait(lambda:next((c for c in ctl('clients',True) if c['class'].lower()=='chatgpt'),None),timeout=30)
    human_browser=start(['google-chrome-stable','--ozone-platform=wayland','--no-first-run','--no-default-browser-check','about:blank'],'human-chrome')
    wait(lambda:any('chrome' in c['class'].lower() for c in ctl('clients',True)))
    cli('create','agent1','--workspace','11','--virtual-output','1280x800');cli('resume','agent1')
    for source,name in [('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')]:
        for mode,ext in [('client-header','h'),('private-code','c')]:subprocess.run(['wayland-scanner',mode,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+ext))],check=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'input'),*flags],check=True)
    keyboard=subprocess.Popen([str(BASE/'input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'input.log','w'),text=True,start_new_session=True);PROCESSES.append(keyboard)
    assert keyboard.stdout.readline().strip()=='ready'
    def send(event):
        keyboard.stdin.write(event+'\n');keyboard.stdin.flush()
        assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='done'
    def key(code):send(f'key {code} 1');send(f'key {code} 0')
    def click(x,y):send(f'motion {x} {y}');send('button 272 1');send('button 272 0')
    ok('eval hl.bind("SUPER + R", hl.dsp.exec_cmd('+json.dumps(shlex.join([str(PRODUCT/'bin/cornice'),'launcher']))+'), {})')
    start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice')
    def status():return json.loads(shell('ipc','desktopObserver','status'))
    wait(lambda:json.loads(shell('ipc','desktop','status'))['available'])
    shell('ipc','desktop','observe','agent1');wait(lambda:status()['presentation'].get('active'))
    shell('ipc','desktopObserver','takeover','true');wait(lambda:status()['humanControl'])
    def opened():return any(w['id']=='cn.launcher' and w['open'] for w in json.loads(shell('ipc','shell','windows')))
    before=human_state()
    # Test the inherited physical-seat shortcut, including opening for the first time.
    send('motion 640 400')
    for index in range(8):
        send('mods 64');send('key 125 1');key(19);send('key 125 0');send('mods 0')
        try:wait(opened,timeout=3)
        except Exception:
            print('SHORTCUT FAILURE',index,status(),ctl('layers',True),flush=True);raise
        time.sleep(.35)
        key(30)
        wait(lambda:json.loads(shell('ipc','launcher','debug'))['query']=='a')
        key(1);wait(lambda:not opened())
        time.sleep(.25)
    record('eight consecutive Super+R presses each open launcher once and focus its text input')
    shell('launcher');wait(opened);shell('ipc','launcher','setQuery','Google Chrome')
    wait(lambda:json.loads(shell('ipc','launcher','debug'))['first']=='Google Chrome')
    time.sleep(.35);key(28)
    def launched():return next((c for c in ctl('clients',True) if 'chrome' in c['class'].lower() and c['workspace']['id']==11),None)
    client=wait(launched);OWNED_PIDS.append(client['pid']);wait(lambda:not opened())
    time.sleep(1)
    def shot(filename):
        time.sleep(.25)
        path=BASE/filename
        subprocess.run(['grim','-c','-o','human',str(path)],env=ENV,check=True)
        return Image.open(path).convert('RGB')
    send('motion 600 400');workspace_cursor=shot('cursor-workspace.png')
    send('motion 600 10');bar_a=shot('cursor-bar-a.png')
    send('motion 700 500');shot('cursor-other-workspace.png')
    send('motion 600 10');bar_b=shot('cursor-bar-b.png')
    crop=(580,380,645,445)
    assert ImageChops.difference(bar_a.crop(crop),bar_b.crop(crop)).getbbox() is None, 'stale seat cursor remains under bar cursor'
    assert ImageChops.difference(workspace_cursor.crop(crop),bar_a.crop(crop)).getbbox() is not None, 'workspace cursor fixture was not visible'
    record('moving the takeover pointer onto the bar hides the old workspace cursor; returning restores the seat cursor')
    click(1200,122);time.sleep(.35)
    subprocess.run(['grim','-o','human',str(BASE/'profile-before.png')],env=ENV,check=True)
    click(1050,350);time.sleep(.6)
    subprocess.run(['grim','-o','human',str(BASE/'profile-after.png')],env=ENV,check=True)
    shell('ipc','desktopObserver','takeover','false');wait(lambda:not status()['humanControl'])
    cli('resume','agent1');credential=bind('agent1')
    endpoint=tool(credential,'browser')['cdpUrl']
    cdp=Cdp(endpoint)
    pages=cdp.call('Target.getTargets')['targetInfos']
    assert any(p['url'].startswith('https://accounts.google.com/signin/chrome/sync') for p in pages),pages
    cdp.close()
    assert next(c['pid'] for c in ctl('clients',True) if c['address']==client['address'])==client['pid']
    assert human_browser.poll() is None
    record('launcher starts the same managed browser later used by CDP; Chrome profile sign-in reaches Google login without a lost click')
    # A detached singleton app uses its desktop profile rather than the primary instance.
    chat=cli('launch','agent1','--','chatgpt','--ozone-platform=wayland')
    def chat_window():return next((c for c in ctl('clients',True) if c['class'].lower()=='chatgpt' and c['workspace']['id']==11),None)
    chat_client=wait(chat_window,timeout=30)
    assert chat_client['pid'] != primary_chat_window['pid']
    assert any(c['address']==primary_chat_window['address'] for c in ctl('clients',True))
    profile=pathlib.Path(os.environ['HOME'])/'.local/share/cornice/desktops/agent1/chatgpt'
    wait(lambda:(profile/'Local State').exists(),timeout=10)
    record('real ChatGPT window opens on the secondary desktop with its own Electron profile')
finally:cleanup()
