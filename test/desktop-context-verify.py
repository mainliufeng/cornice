"""Real session services and all Launcher entry paths share desktop context."""
from desktop_harness import *
import hashlib

try:
    # A native compositor shortcut must discover a configured primary endpoint,
    # while Broker-owned shells inherit that same endpoint explicitly.
    primary_socket = RT / 'primary-custom.sock'
    ENV.pop('CORNICE_SHELL_SOCKET',None)
    ENV.pop('CORNICE_PRIMARY_SHELL_SOCKET',None)
    initialize()
    ENV['CORNICE_SHELL_SOCKET'] = str(primary_socket)
    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    (config/'config.json').write_text(json.dumps({'agentDesktop':{'enabled':True},'bar':{'layout':{'left':[{'id':'cn.agent-desktop'},{'id':'cn.launcher'},{'id':'cn.active-window'}],'center':[],'right':[{'id':'cn.indicators'}]}},'background':{'enabled':False},'weather':{'intervalMinutes':0},'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False},'desktopApplications':{'rules':{'terminal':{'executables':['kitty'],'scope':'secondary','profile':'terminal-check','arguments':['--override','confirm_os_window_close=0'],'environment':{'CORNICE_PROFILE_PROBE':'{desktop}'}}}}}))
    primary=start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice')
    wait(lambda:json.loads(shell('ipc','desktop','status'))['available'])
    endpoint=RT/('cs-'+hashlib.sha256(ENV['HYPRLAND_INSTANCE_SIGNATURE'].encode()).hexdigest()[:8]+'-session.json')
    wait(lambda:endpoint.exists())
    assert json.loads(endpoint.read_text())['socket']==str(primary_socket)
    def desk_env(name,native=False):
        env=ENV.copy();env.pop('CORNICE_SHELL_SOCKET',None)
        if native:
            state=cli('state',name)
            env.update(HYPRLAND_SEAT_NAME=name,HYPRLAND_SEAT_ID=state['seatId'],HYPRLAND_SEAT_GENERATION=str(state['generation']))
        else:env['CORNICE_DESKTOP_NAME']=name
        return env
    def local(name,*args):
        return subprocess.check_output([str(PRODUCT/'bin/cornice'),*args],env=desk_env(name),text=True,stderr=subprocess.PIPE,timeout=8).strip()
    def service(name):return json.loads(local(name,'ipc','sessionServices','status'))
    cli('resume','desktop2');wait(lambda:'pong' in local('desktop2','ping'))
    wait(lambda:service('desktop2')['states'].get('cn.notifications',{}).get('available'))
    for name in ('desktop2','desktop3'):
        if name=='desktop3':cli('create',name,'--virtual-output','1280x800');cli('resume',name)
        wait(lambda:'pong' in local(name,'ping'))
        state=json.loads(local(name,'ipc','shell','debug'))
        assert not set(state['serviceModels'])&{'cn.lock','cn.idle','cn.notifications','cn.polkit'},state
        for args in [('lock','status'),('ipc','idle','status'),('dnd','on')]:
            result=subprocess.run([str(PRODUCT/'bin/cornice'),*args],env=desk_env(name,True),capture_output=True,text=True,timeout=8)
            assert result.returncode==0,(args,result.stderr)
        assert json.loads(shell('ipc','notifications','dnd')) is True
    record('custom primary endpoint, multiple seats and native shortcuts share exactly one session service owner')
    subprocess.run(['notify-send','--expire-time=0','Cornice context review','real shared notification'],env=ENV,check=True)
    for name in ('desktop2','desktop3'):
        wait(lambda:any(row.get('summary')=='Cornice context review' for row in service(name)['states']['cn.notifications']['snapshot']['history']))
        local(name,'notifications')
        panel=wait(lambda:json.loads(local(name,'ipc','notificationPanel','state')))
        assert panel['available'] and panel['count']>=1,panel
    record('real NotificationServer history and DND are visible in each desktop panel')
    # A real primary application and focus must survive secondary launches.
    start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window',BASE/'human.txt'],'human-app')
    wait(lambda:any(c['title']=='human-window' for c in ctl('clients',True)))
    before=human_state()
    for source,name in [('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')]:
        for mode,ext in [('client-header','h'),('private-code','c')]:
            subprocess.run(['wayland-scanner',mode,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+ext))],check=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'input'),*flags],check=True)
    keyboard=subprocess.Popen([str(BASE/'input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'input.log','w'),text=True,start_new_session=True);PROCESSES.append(keyboard)
    assert keyboard.stdout.readline().strip()=='ready'
    def send(event):
        keyboard.stdin.write(event+'\n');keyboard.stdin.flush()
        assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='done'
    def key(code):send(f'key {code} 1');send(f'key {code} 0')
    def observer():return json.loads(shell('ipc','desktopObserver','status'))
    shell('ipc','desktop','observe','desktop2');wait(lambda:observer()['presentation'].get('active'))
    shell('ipc','desktopObserver','takeover','true');wait(lambda:observer()['humanControl'])
    local('desktop2','launcher')
    wait(lambda:json.loads(local('desktop2','ipc','launcher','debug'))['focused'])
    probe=BASE/'terminal-context.txt'
    query='>printf "%s:%s" "$CORNICE_DESKTOP_NAME" "$CORNICE_PROFILE_PROBE" > '+shlex.quote(str(probe))+'; sleep 120'
    local('desktop2','ipc','launcher','setQuery',query)
    wait(lambda:json.loads(local('desktop2','ipc','launcher','debug'))['query']==query)
    key(28)
    wait(lambda:probe.exists())
    assert probe.read_text()=='desktop2:desktop2',probe.read_text()
    app=wait(lambda:next((c for c in ctl('clients',True) if c['class'].lower()=='kitty'),None))
    assert app['workspace']['name']==cli('state','desktop2')['workspaceName'],app
    record('Launcher command/terminal mode uses configured adaptation and the current takeover seat on first Enter')
    # Notifications identify the sending process before app class/name. Both
    # desktops use the same real GTK app class, so a class-first implementation
    # would steal primary focus or choose another process's window.
    for index in range(2):
        human_seat=cli('state','desktop2')
        cli('launch','desktop2','--human-seat',human_seat['seatId'],human_seat['generation'],
            '--','/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),
            'notification-app-'+str(index),str(BASE/('notification-'+str(index)+'.txt')))
        wait(lambda:any(c['title']=='notification-app-'+str(index) for c in ctl('clients',True)))
    notification_apps=[next(c for c in ctl('clients',True) if c['title']=='notification-app-'+str(index)) for index in range(2)]
    target=notification_apps[0]
    subprocess.run([str(PRODUCT/'bin/cornice-focus-app'),'--pid',str(target['pid']),
        '--desktop',target['class']+'.desktop','--name',target['class']],env=desk_env('desktop2'),check=True,stdout=subprocess.DEVNULL)
    wait(lambda:cli('state','desktop2')['windowAddress']==target['address'])
    primary_app=next(c for c in ctl('clients',True) if c['title']=='human-window')
    denied=subprocess.run([str(PRODUCT/'bin/cornice-focus-app'),'--pid',str(primary_app['pid']),
        '--desktop',target['class']+'.desktop'],env=desk_env('desktop2'),capture_output=True,text=True)
    assert denied.returncode!=0
    assert cli('state','desktop2')['windowAddress']==target['address']
    record('notification focus prefers exact sender PID and cannot cross desktop workspace boundaries')
    shell('ipc','desktopObserver','takeover','false');wait(lambda:not observer()['humanControl'])
    cli('pause','desktop2')
    denied=cli('launch','desktop2','--','kitty',succeeds=False)
    assert 'paused' in denied.lower(),denied
    assert not (BASE/'human.txt').exists()
    after=human_state()
    assert {k:v for k,v in before.items() if k!='cursor'}=={k:v for k,v in after.items() if k!='cursor'},(before,after)
    record('revocation rejects desktop writes and leaves primary application input/workspace/focus unchanged')
    # A disconnected service facade must keep last history but disable actions.
    os.killpg(primary.pid,signal.SIGTERM);primary.wait(timeout=5)
    unavailable=wait(lambda:service('desktop2') if service('desktop2')['error'] else None)
    assert not unavailable['states']['cn.notifications']['available'],unavailable
    denied=subprocess.run([str(PRODUCT/'bin/cornice'),'dnd','off'],env=desk_env('desktop2'),capture_output=True,text=True,timeout=8)
    assert denied.returncode!=0 and 'no responding' in denied.stderr,denied.stderr
    assert 'pong' in local('desktop2','ping')
    record('primary service disconnect is explicit, mutations fail closed and the independent desktop shell stays live')
finally:cleanup()
