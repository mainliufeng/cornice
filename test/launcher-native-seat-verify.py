"""Physical seat shortcuts with real Wayland Fcitx, Chrome and Konsole."""
from desktop_harness import *

try:
    ENV.update(QT_IM_MODULE='wayland', GTK_IM_MODULE='fcitx', XMODIFIERS='@im=fcitx')
    initialize()
    # Match the laptop's native 2x scaling, with distinct desktop outputs.
    for monitor in ctl('monitors',True):
        ok('eval hl.monitor({output='+json.dumps(monitor['name'])+',mode="2560x1600",position="'+str(monitor['x'])+'x'+str(monitor['y'])+'",scale=2})')
    wait(lambda:all(m['scale']==2 for m in ctl('monitors',True)))
    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    (config/'config.json').write_text(json.dumps({'agentDesktop':{'enabled':True},'background':{'enabled':False},'weather':{'intervalMinutes':0},'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}))
    profile=BASE/'config/fcitx5/profile';profile.parent.mkdir(parents=True,exist_ok=True)
    profile.write_text('[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=pinyin\n\n[Groups/0/Items/0]\nName=keyboard-us\n\n[Groups/0/Items/1]\nName=pinyin\n\n[GroupOrder]\n0=Default\n')
    fcitx=start(['fcitx5','-D','--disable=vinput,cloudpinyin'],'fcitx')
    wait(lambda:'true' in subprocess.check_output(['gdbus','call','--session','--dest','org.freedesktop.DBus','--object-path','/org/freedesktop/DBus','--method','org.freedesktop.DBus.NameHasOwner','org.fcitx.Fcitx5'],env=ENV,text=True))
    primary=start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window',BASE/'human.txt'],'human-window')
    wait(lambda:any(c['title']=='human-window' for c in ctl('clients',True)))
    cli('resume','desktop2')
    cli('launch','desktop2','--','google-chrome-stable','--ozone-platform=wayland','about:blank')
    wait(lambda:any('chrome' in c['class'].lower() for c in ctl('clients',True)))
    for source,name in [('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')]:
        for mode,ext in [('client-header','h'),('private-code','c')]:
            subprocess.run(['wayland-scanner',mode,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+ext))],check=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'input'),*flags],check=True)
    keyboard=subprocess.Popen([str(BASE/'input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'input.log','w'),text=True,start_new_session=True);PROCESSES.append(keyboard)
    assert keyboard.stdout.readline().strip()=='ready'
    def send(event):
        keyboard.stdin.write(event+'\n');keyboard.stdin.flush()
        assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='done',event
    def key(code):send(f'key {code} 1');send(f'key {code} 0')
    def super_key(code):
        send('mods 64');send('key 125 1');key(code);send('key 125 0');send('mods 0')
    ok('eval hl.bind("SUPER + R", hl.dsp.exec_cmd('+json.dumps(shlex.join([str(PRODUCT/'bin/cornice'),'launcher']))+'), {})')
    start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice')
    def observer():return json.loads(shell('ipc','desktopObserver','status'))
    wait(lambda:json.loads(shell('ipc','desktop','status'))['available'])
    desk_env=ENV|{'CORNICE_DESKTOP_NAME':'desktop2'}
    def desk_shell(*args):return subprocess.check_output([str(PRODUCT/'bin/cornice'),*args],env=desk_env,text=True,stderr=subprocess.PIPE,timeout=8).strip()
    wait(lambda:'pong' in desk_shell('ping'))
    def opened(which=shell):return any(w['id']=='cn.launcher' and w['open'] for w in json.loads(which('ipc','shell','windows')))
    shell('ipc','desktop','observe','desktop2');wait(lambda:observer()['presentation'].get('active'))
    shell('ipc','desktopObserver','takeover','true');wait(lambda:observer()['humanControl'])
    before=human_state()
    for index in range(8):
        # The same sequence shown in the user's video, including empty workspaces.
        for slot,code in [(2,3),(3,4),(2,3),(1,2)]:
            super_key(code)
            wait(lambda:cli('state','desktop2')['workspaceName'].endswith('-ws-'+str(slot)))
        send('motion 100 730')
        super_key(19)
        wait(lambda:opened(desk_shell),timeout=3)
        assert not opened(), 'secondary shortcut opened primary launcher'
        wait(lambda:json.loads(desk_shell('ipc','launcher','debug')).get('focused',True))
        send('type term')
        wait(lambda:json.loads(desk_shell('ipc','launcher','debug'))['query']=='term')
        debug=json.loads(desk_shell('ipc','launcher','debug'))
        # The production desktop database order varies; navigate its real rows.
        names=debug['names'];target=names.index('Konsole')
        for selected in range(1,target+1):
            send('mods 4');send('key 29 1');key(36);send('key 29 0');send('mods 0')
            wait(lambda:json.loads(desk_shell('ipc','launcher','debug'))['selected']==selected)
        if index==0:
            subprocess.run(['grim','-o','human',str(BASE/'launcher-before-enter.png')],env=ENV,check=True)
        old={c['address'] for c in ctl('clients',True)}
        key(28)
        wait(lambda:not opened(desk_shell),timeout=3)
        window=wait(lambda:next((c for c in ctl('clients',True) if c['address'] not in old and 'konsole' in c['class'].lower()),None),timeout=10)
        assert window['workspace']['name']=='cornice-agent-desktop2-ws-1',window
        if index==0:
            subprocess.run(['grim','-o','human',str(BASE/'konsole-first-enter.png')],env=ENV,check=True)
        actual=cli('state','desktop2')
        ok('seat dispatch desktop2 '+actual['seatId']+' '+str(actual['generation'])+' hl.dsp.window.close({window="address:'+window['address']+'"})')
        wait(lambda:not any(c['address']==window['address'] for c in ctl('clients',True)))
        record('first Super+R, typed search, Ctrl+J and first Enter on native desktop: '+str(index+1))
    # Broker-owned secondary shell restart is independent of the main shell,
    # compositor, running apps and human view. Exercise the update mechanism.
    output=cli('state','desktop2')['output']
    def shell_pid():
        levels=ctl('layers',True).get(output,{}).get('levels',{})
        return next((layer['pid'] for rows in levels.values() for layer in rows if layer['namespace']=='cornice-bar'),None)
    previous_pid=shell_pid();assert previous_pid
    windows={c['address'] for c in ctl('clients',True)}
    os.kill(previous_pid,signal.SIGTERM)
    wait(lambda:shell_pid() and shell_pid()!=previous_pid,timeout=15)
    wait(lambda:'pong' in desk_shell('ping'))
    assert windows=={c['address'] for c in ctl('clients',True)}
    assert observer()['humanControl']
    super_key(19);wait(lambda:opened(desk_shell),timeout=3)
    send('type konsole');wait(lambda:json.loads(desk_shell('ipc','launcher','debug'))['query']=='konsole')
    old={c['address'] for c in ctl('clients',True)}
    key(28);wait(lambda:not opened(desk_shell),timeout=3)
    wait(lambda:any(c['address'] not in old and 'konsole' in c['class'].lower() for c in ctl('clients',True)))
    record('secondary shell restart retains apps and control; first shortcut and Enter still work')
    # A missing scoped shell must never discover the primary instance by config.
    missing=ENV|{'HYPRLAND_SEAT_NAME':'absent','HYPRLAND_SEAT_ID':'seat-absent'}
    result=subprocess.run([str(PRODUCT/'bin/cornice'),'launcher'],env=missing,capture_output=True,text=True,timeout=8)
    assert result.returncode!=0 and not opened()
    record('missing seat shell fails closed instead of opening another desktop')
    after=human_state()
    assert {k:v for k,v in after.items() if k!='cursor'}=={k:v for k,v in before.items() if k!='cursor'}, (before,after)
    assert not (BASE/'human.txt').exists()
    assert fcitx.poll() is None
    record('primary workspace, focused window and input remain unchanged')
finally:cleanup()
