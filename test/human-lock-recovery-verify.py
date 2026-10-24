"""Independent real UI/guard crash recovery, private logind and compositor only."""
from desktop_harness import *


def owners():
    found=[]
    for proc in pathlib.Path('/proc').iterdir():
        if not proc.name.isdigit():continue
        try:
            if str(pam).encode() in (proc/'cmdline').read_bytes() and b'cornice-human-lock' in (proc/'cmdline').read_bytes():
                if ('XDG_RUNTIME_DIR='+str(RT)).encode() in (proc/'environ').read_bytes().split(b'\0'):found.append(int(proc.name))
        except (FileNotFoundError,PermissionError,ProcessLookupError):pass
    return found


def events():
    return [json.loads(line) for line in (BASE/'logind-events').read_text().splitlines()]


try:
    initialize()
    pam=BASE/'pam';pam.mkdir();(pam/'permit').write_text('auth required pam_permit.so\n')
    (pam/'other').write_text('auth required pam_deny.so\n')
    ok('eval hl.config({misc={allow_session_lock_restore=true}})')
    cli('lock-policy','desktop2','continue');cli('resume','desktop2');binding=bind('desktop2')
    start(['/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),'recovery-window',str(BASE/'app.txt')],
        'recovery-app',ENV|{'WAYLAND_DISPLAY':cli('state','desktop2')['display']})
    wait(lambda:any(c['title']=='recovery-window' for c in ctl('clients',True)))
    frame=tool(binding,'capture');tool(binding,'input',{'frameId':frame['frameId'],'action':'text','text':'before-recovery'})
    wait(lambda:(BASE/'app.txt').read_text()=='before-recovery')
    system_bus=subprocess.check_output(['dbus-daemon','--session','--fork','--print-address=1','--print-pid=1'],env=ENV,text=True).splitlines()
    OWNED_BUS_PIDS.append(int(system_bus[1]));guard_env=ENV|{'DBUS_SYSTEM_BUS_ADDRESS':system_bus[0]}
    fixture=subprocess.Popen(['/usr/bin/python3',str(ROOT/'test/logind-fixture.py'),system_bus[0],str(BASE/'logind-events')],
        env=guard_env,stdin=subprocess.PIPE,stdout=open(BASE/'logind-fixture.log','w'),stderr=subprocess.STDOUT,start_new_session=True,text=True)
    PROCESSES.append(fixture);wait(lambda:any(e['event']=='ready' for e in events()))
    config=BASE/'config/cornice/config.json';config.parent.mkdir(parents=True,exist_ok=True)
    config.write_text(json.dumps({'agentDesktop':{'enabled':True},'weather':{'intervalMinutes':0},
        'bar':{'layout':{'left':[{'id':'cn.agent-desktop'}],'center':[],'right':[]}},
        'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,
                'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False},
        'lock':{'pamService':'permit','pamDirectory':str(pam),'emergencyUnlock':True}}))
    ui_env=guard_env|{'CORNICE_ISOLATED_TEST':'0'}
    ui=start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'recovery-ui',ui_env)
    wait(lambda:json.loads(shell('ipc','lock','status'))['humanLockAvailable'])
    wait(lambda:json.loads(shell('ipc','idle','status'))['sleepGuardReady'])
    shell('lock');wait(lambda:ctl('seat lock-state',True)['secure'] and ctl('seat lock-state',True)['scope']=='scoped')
    assert not cli('state','desktop2')['paused']
    lock_id=ctl('seat lock-state',True)['lockId'];owner=wait(owners);assert len(owner)==1,owner
    os.kill(owner[0],signal.SIGKILL)
    wait(lambda:ctl('seat lock-state',True)['secure'] and ctl('seat lock-state',True)['ownerConnected'] and ctl('seat lock-state',True)['lockId']!=lock_id)
    assert ctl('seat lock-state',True)['scope']=='session' and cli('state','desktop2')['paused']
    tool(binding,'capture',succeeds=False)
    record('native lock owner death escalates to full lock and real UI restores authentication without restoring agent input')
    shell('suspend');wait(lambda:len([e for e in events() if e['event']=='suspend'])==1)
    assert all(e['state']['scope']=='session' and e['state']['secure'] for e in events() if e['event']=='suspend')
    fixture.stdin.write('{"event":"resume"}\n');fixture.stdin.flush()
    wait(lambda:json.loads(shell('ipc','idle','status'))['sleepGuardReady'])
    assert ctl('seat lock-state',True)['locked'] and cli('state','desktop2')['paused']
    shell('lock','emergency-unlock');wait(lambda:not ctl('seat lock-state',True)['locked'])
    assert cli('state','desktop2')['paused']
    record('real shell suspend command waits for secure full lock on private logind; simulated wake retains lock and revoked agent authority')
    shell('lock');wait(lambda:ctl('seat lock-state',True)['secure'])
    os.killpg(ui.pid,signal.SIGKILL);ui.wait()
    wait(lambda:ctl('seat lock-state',True)['scope']=='session' and not ctl('seat lock-state',True)['ownerConnected'])
    restarted=start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'recovery-ui-restarted',ui_env)
    wait(lambda:ctl('seat lock-state',True)['secure'] and ctl('seat lock-state',True)['ownerConnected'])
    assert ctl('seat lock-state',True)['scope']=='session' and cli('state','desktop2')['paused']
    tool(binding,'capture',succeeds=False)
    shell('lock','emergency-unlock');wait(lambda:not ctl('seat lock-state',True)['locked'])
    assert cli('state','desktop2')['paused'] and (BASE/'app.txt').read_text()=='before-recovery'
    for path in (BASE/'recovery-ui.log',BASE/'recovery-ui-restarted.log'):
        assert not any(e in path.read_text() for e in ('TypeError:','ReferenceError:','is not a type','Cannot assign','Unable to assign [undefined] to QColor'))
    record('whole UI/guard SIGKILL keeps orphaned full protection; restarting restores only authentication and original app content remains unchanged')
finally:
    cleanup()
