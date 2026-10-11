"""Real first-keyboard attachment before and after native panel mapping."""
from desktop_harness import *
import re

held = None
try:
    assert os.getenv('CORNICE_TEST_SANDBOX') == '1'
    config = BASE/'hyprland.lua'
    config.write_text('hl.monitor({output="",mode="1280x800",position="auto",scale=1})\nhl.config({xwayland={enabled=false},misc={disable_hyprland_logo=true,disable_splash_rendering=true,force_default_wallpaper=0},debug={disable_logs=false,enable_stdout_logs=true}})\n')
    bus = subprocess.check_output(['dbus-daemon','--session','--fork','--print-address=1','--print-pid=1'],env=ENV,text=True).splitlines()
    ENV['DBUS_SESSION_BUS_ADDRESS']=bus[0]
    OWNED_BUS_PIDS.append(int(bus[1]))
    start(['mutter','--headless','--wayland','--no-x11','--wayland-display=parent','--virtual-monitor','1280x800'],'mutter')
    wait(lambda:(RT/'parent').is_socket())
    ENV.update(WAYLAND_DISPLAY='parent',AQ_DRM_DEVICES='/dev/null',LIBSEAT_BACKEND='noop')
    start([os.environ['CORNICE_TEST_HYPRLAND'],'-c',str(config)],'Hyprland')
    ENV['HYPRLAND_INSTANCE_SIGNATURE']=wait(lambda:next((p.name for p in (RT/'hypr').glob('*') if (p/'.socket.sock').is_socket()),None))
    initial=[m['name'] for m in ctl('monitors',True)]
    ok('output create headless human')
    ok('eval hl.monitor({output="human",mode="1280x800",position="0x0",scale=1})')
    for name in initial:ok('eval hl.monitor({output='+json.dumps(name)+',disabled=true})')
    wait(lambda:len(ctl('monitors',True))==1)
    ENV['WAYLAND_DISPLAY']=wait(lambda:next((p.name for p in RT.glob('wayland-*') if p.is_socket()),None))
    ok('dispatch hl.dsp.focus({monitor="human"})')
    ok('dispatch hl.dsp.focus({workspace="1"})')
    settings=BASE/'config/cornice';settings.mkdir(parents=True,exist_ok=True)
    (settings/'config.json').write_text(json.dumps({'agentDesktop':{'enabled':False},'background':{'enabled':False},'weather':{'intervalMinutes':0},'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}))
    start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice')
    wait(lambda:'pong' in shell('ping'))
    assert not ctl('devices',True)['keyboards']
    # The management list can be empty before primary acquisition; real wl_seat
    # registry identity is checked in each WAYLAND_DEBUG wtype trace below.
    (BASE/'initial-seat-list.json').write_text(json.dumps(ctl('seat list',True)))
    for source,name in (('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')):
        for mode,extension in (('client-header','h'),('private-code','c')):
            subprocess.run(['wayland-scanner',mode,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+extension))],check=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'input'),*flags],check=True)
    held=subprocess.Popen([str(BASE/'input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'held-input.log','w'),text=True,start_new_session=True)
    PROCESSES.append(held)
    assert select.select([held.stdout],[],[],5)[0] and held.stdout.readline().strip()=='ready'
    wait(lambda:len(ctl('devices',True)['keyboards'])==1)
    def opened():return any(row['id']=='cn.launcher' and row['open'] for row in json.loads(shell('ipc','shell','windows')))
    def type_with_wtype(text,label):
        result=subprocess.run(['wtype',text],env=ENV|{'WAYLAND_DEBUG':'client'},capture_output=True,text=True,timeout=5)
        (BASE/(label+'-wayland.log')).write_text(result.stderr)
        assert result.returncode==0,(label,result.returncode,result.stderr[-1500:])
        seats=re.findall(r'wl_seat[@#]\d+\.name\("([^"]+)"\)',result.stderr)
        assert seats==['Hyprland'],(label,seats)
        time.sleep(.25)
        debug=json.loads(shell('ipc','launcher','debug'))
        layers=ctl('layers',True)
        (BASE/(label+'-state.json')).write_text(json.dumps({'debug':debug,'layers':layers,'seats':ctl('seat list',True),'devices':ctl('devices',True)}))
        subprocess.run(['grim','-o','human',str(BASE/(label+'.png'))],env=ENV,check=True)
        print('ACTUAL',label,json.dumps(debug),flush=True)
        return debug
    shell('launcher');wait(opened)
    prior=type_with_wtype('held','keyboard-before-panel')
    assert prior['query']=='held',prior
    record('a persistent first keyboard before panel mapping lets real wtype type into the native launcher')
    shell('ipc','shell','hide','cn.launcher');wait(lambda:not opened())
    held.stdin.close();held.wait(timeout=5);held=None
    wait(lambda:not ctl('devices',True)['keyboards'])
    shell('launcher');wait(opened)
    late=type_with_wtype('late','panel-before-keyboard')
    assert late['query']=='late',late
    record('mapping the same native panel before the first keyboard preserves layer focus after capability becomes available')
    shell('ipc','shell','hide','cn.launcher');wait(lambda:not opened())
    wait(lambda:not ctl('devices',True)['keyboards'])
    destination=BASE/'under-lock.txt';destination.write_text('')
    start(['/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),'under-lock-window',str(destination)],'under-lock-app',ENV|{'WAYLAND_DEBUG':'client'})
    app=wait(lambda:next((row for row in ctl('clients',True) if row['title']=='under-lock-window'),None))
    ok('dispatch hl.dsp.focus({window='+json.dumps(app['address'])+'})')
    assert not ctl('devices',True)['keyboards']
    pam=BASE/'pam';pam.mkdir()
    (pam/'deny').write_text('auth required pam_deny.so\n')
    locker=subprocess.Popen([str(PRODUCT/'bin/cornice-human-lock'),'--scope','session','--pam-service','deny','--pam-directory',str(pam),'--allow-emergency'],env=ENV|{'WAYLAND_DEBUG':'client'},stdin=subprocess.PIPE,stdout=open(BASE/'cold-lock-events','w'),stderr=open(BASE/'cold-lock-wayland.log','w'),text=True,start_new_session=True)
    PROCESSES.append(locker)
    wait(lambda:ctl('seat lock-state',True)['secure'] and ctl('seat lock-state',True)['scope']=='session')
    wait(lambda:any(json.loads(line).get('event')=='secure' for line in (BASE/'cold-lock-events').read_text().splitlines()))
    held=subprocess.Popen([str(BASE/'input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'cold-lock-input.log','w'),text=True,start_new_session=True)
    PROCESSES.append(held)
    assert select.select([held.stdout],[],[],5)[0] and held.stdout.readline().strip()=='ready'
    # Synchronize the real lock client's wl_keyboard binding and enter, rather
    # than only the injector roundtrip. The ordinary application must not enter.
    wait(lambda:re.search(r'wl_keyboard[@#]\d+\.enter\(', (BASE/'cold-lock-wayland.log').read_text()))
    for command in ('type secret','key 28 1','key 28 0'):
        held.stdin.write(command+'\n');held.stdin.flush()
        assert select.select([held.stdout],[],[],5)[0] and held.stdout.readline().strip()=='done'
    wait(lambda:'authentication-failed' in (BASE/'cold-lock-events').read_text())
    state=ctl('seat lock-state',True)
    assert state['secure'] and state['scope']=='session',state
    assert destination.read_text()==''
    assert not re.search(r'wl_keyboard[@#]\d+\.enter\(', (BASE/'under-lock-app.log').read_text())
    (BASE/'cold-lock-state.json').write_text(json.dumps({'lock':state,'devices':ctl('devices',True),'applicationText':destination.read_text()}))
    subprocess.run(['grim','-o','human',str(BASE/'cold-keyboard-lock.png')],env=ENV,check=True)
    record('a first keyboard attached during full lock enters only the native lock; real input reaches PAM while the underlying GTK application receives neither focus nor text')
    locker.stdin.write('emergency-unlock\n');locker.stdin.flush()
    wait(lambda:not ctl('seat lock-state',True)['locked'])
    locker.wait(timeout=5);assert locker.returncode==0
finally:
    cleanup()
