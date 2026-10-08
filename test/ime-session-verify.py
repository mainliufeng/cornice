"""Real Fcitx/pinyin and ordinary desktop controls in a device sandbox."""
from desktop_harness import *
assert os.getenv('CORNICE_TEST_SANDBOX') == '1'

def send(command):
    keyboard.stdin.write(command+'\n');keyboard.stdin.flush()
    assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='done',command

def remote(*args):
    return subprocess.check_output(['fcitx5-remote',*args],env=ENV,text=True).strip()

try:
    initialize()
    for source,name in (('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')):
        for mode,ext in (('client-header','h'),('private-code','c')):
            subprocess.run(['wayland-scanner',mode,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+ext))],check=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'human-input'),*flags],check=True)
    keyboard=subprocess.Popen([str(BASE/'human-input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'keyboard.log','w'),text=True,start_new_session=True)
    PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='ready'
    profile=BASE/'config/fcitx5/profile';profile.parent.mkdir(parents=True,exist_ok=True)
    profile.write_text('[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=pinyin\n\n[Groups/0/Items/0]\nName=keyboard-us\n\n[Groups/0/Items/1]\nName=pinyin\n\n[GroupOrder]\n0=Default\n')
    ENV.update(GTK_IM_MODULE='fcitx',QT_IM_MODULE='fcitx',XMODIFIERS='@im=fcitx')
    fcitx=start(['fcitx5','-D','--disable=vinput,cloudpinyin'],'fcitx')
    def ime_ready():
        assert fcitx.poll() is None, (BASE/'fcitx.log').read_text()
        owner=subprocess.run(['gdbus','call','--session','--dest','org.freedesktop.DBus','--object-path','/org/freedesktop/DBus','--method','org.freedesktop.DBus.NameHasOwner','org.fcitx.Fcitx5'],env=ENV,capture_output=True,text=True)
        return 'true' in owner.stdout
    wait(ime_ready)
    destinations=[]
    for index in range(2):
        path=BASE/('human-'+str(index)+'.txt');destinations.append(path)
        start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window' if index==0 else 'other-window',path],'gtk-'+str(index))
    wait(lambda:len(ctl('clients',True))==2)
    ok('dispatch hl.dsp.focus({workspace="1"})')
    # Exercise the migrated helper using actual windows and fullscreen state.
    before=ctl('activewindow',True)['address']
    for direction in ('next','prev'):
        subprocess.run([str(ROOT/'bin/cornice-cycle-focus'),direction],env=ENV,check=True)
        assert ctl('activewindow',True)['address']!=before
        before=ctl('activewindow',True)['address']
    record('migrated Super+J/K helper cycles real windows in both directions')
    ok('dispatch hl.dsp.window.fullscreen_state({internal=2,client=2})')
    subprocess.run([str(ROOT/'bin/cornice-cycle-focus'),'next'],env=ENV,check=True)
    assert ctl('activewindow',True)['fullscreen']==2
    ok('dispatch hl.dsp.window.fullscreen_state({internal=0,client=0})')
    record('focus cycling preserves fullscreen mode using the Lua dispatcher')
    ok('dispatch hl.dsp.focus({window="title:^human-window$"})')
    remote('-o');wait(lambda:remote()=='2')
    send('type nihao');time.sleep(.5)
    subprocess.run(['grim','-o','human',str(BASE/'pinyin-preedit.png')],env=ENV,check=True)
    send('key 57 1');send('key 57 0')
    wait(lambda:destinations[0].read_text()=='你好')
    record('real Fcitx pinyin converts nihao plus Space into 你好 in GTK')
    for index in range(3):cli('create','private'+str(index),'--virtual-output','1280x800')
    for index in range(3):
        name='private'+str(index)
        cli('resume',name)
        cli('launch',name,'--','/usr/bin/python3',ROOT/'test/agent-desktop-client.py',name,BASE/(name+'.txt'))
        wait(lambda:any(c['title']==name for c in ctl('clients',True)))
        cli('pause',name)
        cli('resume',name);cli('pause',name)
        assert fcitx.poll() is None,(BASE/'fcitx.log').read_text()
    time.sleep(.5)
    assert fcitx.poll() is None,(BASE/'fcitx.log').read_text()
    assert 'seat input source revoked' not in (BASE/'fcitx.log').read_text()
    ok('dispatch hl.dsp.focus({window="title:^human-window$"})')
    remote('-o');send('type zhongwen');send('key 57 1');send('key 57 0')
    wait(lambda:destinations[0].read_text()=='你好中文')
    record('Fcitx survives three Agent seats repeatedly resuming/pausing and continues human pinyin input')
    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    (config/'config.json').write_text(json.dumps({'agentDesktop':{'enabled':True},'background':{'enabled':False},'weather':{'intervalMinutes':0},'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}))
    start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice')
    wait(lambda:'pong' in shell('ping'))
    wait(lambda:any(w['id']=='cn.launcher' for w in json.loads(shell('ipc','shell','windows'))))
    shell('ipc','shell','summon','cn.launcher','{}')
    wait(lambda:any(w['id']=='cn.launcher' and w['open'] for w in json.loads(shell('ipc','shell','windows'))))
    time.sleep(.5)
    (BASE/'launcher-state.json').write_text(shell('ipc','shell','windows'))
    subprocess.run(['grim','-o','human',str(BASE/'launcher-open.png')],env=ENV,check=True)
    remote('-o');send('type zhongwen');time.sleep(.5)
    subprocess.run(['grim','-o','human',str(BASE/'launcher-preedit.png')],env=ENV,check=True)
    assert json.loads(shell('ipc','launcher','debug'))['query']==''
    send('key 57 1');send('key 57 0')
    wait(lambda:json.loads(shell('ipc','launcher','debug'))['query']=='中文')
    subprocess.run(['grim','-o','human',str(BASE/'launcher-chinese.png')],env=ENV,check=True)
    record('actual Cornice launcher receives composed Chinese through Fcitx and reports 中文 query')
    shell('ipc','shell','hide','cn.launcher')
    remote('-c')
    ok('eval hl.monitor({output="human",mode="2560x1600",position="0x0",scale=2})')
    page=BASE/'chrome-scale.html'
    page.write_text('<meta charset="utf-8"><p style="font:16px sans-serif">Chrome 原生缩放 Chinese text sample</p><script>setInterval(()=>document.title="ChromeScale:"+JSON.stringify({width:innerWidth,height:innerHeight,dpr:devicePixelRatio}),100)</script>')
    scaling={}
    for label,args in (('native',[]),('forced-two',['--force-device-scale-factor=2'])):
        browser=start(['/opt/google/chrome/google-chrome','--user-data-dir='+str(BASE/('chrome-'+label)),'--ozone-platform=wayland','--no-first-run','--no-default-browser-check',*args,page.as_uri()],'chrome-'+label)
        window=wait(lambda:next((c for c in ctl('clients',True) if c['title'].startswith('ChromeScale:')),None))
        ok('dispatch hl.dsp.focus({window="address:'+window['address']+'"})')
        ok('dispatch hl.dsp.window.fullscreen_state({internal=2,client=0})')
        time.sleep(.5)
        window=next(c for c in ctl('clients',True) if c['pid']==window['pid'])
        title=window['title'].split(' - Google Chrome')[0]
        scaling[label]=json.loads(title.removeprefix('ChromeScale:'))
        subprocess.run(['grim','-o','human',str(BASE/('chrome-scale-'+label+'.png'))],env=ENV,check=True)
        browser.terminate();browser.wait(timeout=10)
        wait(lambda:not any(c['pid']==window['pid'] for c in ctl('clients',True)))
    (BASE/'chrome-scaling.json').write_text(json.dumps(scaling,indent=2))
    assert scaling['native']['width']==1280 and scaling['native']['dpr']==2,scaling
    assert scaling['forced-two']['width']==640 and scaling['forced-two']['dpr']==4,scaling
    record('native Chrome uses 2x output correctly; forcing another 2x reproduces doubled UI and 4x DPR')

finally:
    cleanup()
