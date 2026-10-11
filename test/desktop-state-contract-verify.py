"""Real compositor window/observer state across numeric and named workspaces."""
from desktop_harness import *

try:
    initialize()
    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    (config/'config.json').write_text(json.dumps({'agentDesktop':{'enabled':True},
        'bar':{'layout':{'left':['cn.workspaces','cn.active-window','cn.agent-desktop'],'center':[],'right':[]}},
        'background':{'enabled':False},'weather':{'intervalMinutes':0},
        'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,
            'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}))
    start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice')
    wait(lambda:json.loads(shell('ipc','desktop','status'))['available'])
    def scoped(name,*args):
        return subprocess.check_output([str(PRODUCT/'bin/cornice'),*args],
            env=ENV|{'CORNICE_DESKTOP_NAME':name},text=True,stderr=subprocess.PIPE,timeout=8).strip()
    def bar(name=None):return json.loads(scoped(name,'ipc','windows','state') if name else shell('ipc','windows','state'))
    def pills(name=None):
        rows=json.loads(scoped(name,'ipc','bar','geometry') if name else shell('ipc','bar','geometry'))
        return next(row['controls'] for row in rows if row['id']=='cn.workspaces')
    def observer():return json.loads(shell('ipc','desktopObserver','status'))
    def focus_address(name):
        address=cli('state',name)['windowAddress']
        return '' if address=='0x0' else address.lower()
    for mode,extension in [('client-header','h'),('private-code','c')]:
        subprocess.run(['wayland-scanner',mode,str(ROOT/'test/wlr-virtual-pointer-unstable-v1.xml'),str(BASE/('virtual-pointer.'+extension))],check=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(ROOT/'test/hover-pointer.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'pointer'),*flags],check=True)
    monitors=ctl('monitors',True)
    physical=next(m for m in monitors if m['name']=='human')
    # Default-seat absolute pointer maps to its physical output; private
    # desktop outputs must not halve the real coordinates.
    width=int(physical['width']/physical['scale'])
    height=int(physical['height']/physical['scale'])
    pointer=subprocess.Popen([str(BASE/'pointer'),'0','0',str(width),str(height),'interactive'],
        env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'pointer.log','w'),text=True,start_new_session=True)
    PROCESSES.append(pointer)
    def click_window(address):
        button=next(item for item in bar()['buttons'] if item['address']==address)
        pointer.stdin.write(f"{button['x']} {button['y']} click\n");pointer.stdin.flush()
        assert select.select([pointer.stdout],[],[],5)[0] and pointer.stdout.readline().strip()=='done'
    def clients(title):return [item for item in ctl('clients',True) if item['title']==title]
    def main_launch(title,index):
        start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py',title,BASE/(str(index)+'.txt')],str(index))
        return wait(lambda:next((item for item in clients(title) if item['pid']==PROCESSES[-1].pid),None))
    first=main_launch('human-window','human-first')
    second=main_launch('human-window','human-second')
    wait(lambda:len(bar()['windows'])==2 and bar()['focused']==second['address'])
    assert bar()['workspaceIdentity']['name']=='1'
    subprocess.run([str(PRODUCT/'bin/cornice-focus-window'),first['address'],'1'],env=ENV,check=True)
    wait(lambda:bar()['focused']==first['address'])
    record('primary numeric workspace retains both same-title windows and exact focus address')

    ok('dispatch hl.dsp.focus({workspace="name:review-main"})')
    named_first=main_launch('main-named','main-named-first')
    named_second=main_launch('main-named','main-named-second')
    wait(lambda:len(bar()['windows'])==2 and bar()['focused']==named_second['address'])
    identity=bar()['workspaceIdentity']
    assert identity['name']=='review-main' and identity['key']=='review-main',identity
    subprocess.run([str(PRODUCT/'bin/cornice-focus-window'),named_first['address'],json.dumps(identity)],env=ENV,check=True)
    wait(lambda:bar()['focused']==named_first['address'])
    assert ctl('activewindow',True)['address']==named_first['address']
    # A queued click from a previous workspace must not switch main back.
    ok('dispatch hl.dsp.focus({workspace="name:review-empty"})')
    wait(lambda:bar()['workspaceIdentity']['name']=='review-empty' and not bar()['windows'] and not bar()['focused'])
    subprocess.run([str(PRODUCT/'bin/cornice-focus-window'),named_first['address'],json.dumps(identity)],env=ENV,check=True)
    assert ctl('activeworkspace',True)['name']=='review-empty'
    record('primary named workspace shares normalized state/focus and rejects stale workspace clicks')
    ok('dispatch hl.dsp.focus({workspace="1"})')
    wait(lambda:bar()['workspaceIdentity']['name']=='1')
    human=human_state()

    cli('resume','desktop2');wait(lambda:'pong' in scoped('desktop2','ping'))
    for index in range(2):
        cli('launch','desktop2','--','/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),'same-title',str(BASE/('named'+str(index)+'.txt')))
        wait(lambda:len(clients('same-title'))==index+1)
    names=clients('same-title')
    current=cli('state','desktop2')
    wait(lambda:len(bar('desktop2')['windows'])==2 and bar('desktop2')['focused']==current['windowAddress'])
    assert bar('desktop2')['workspaceIdentity']['name']==current['workspaceName']
    assert next(p for p in pills('desktop2') if p['name']=='1')['occupied']
    cli('view-focus','desktop2',names[0]['address'])
    wait(lambda:bar('desktop2')['focused']==names[0]['address'])
    record('secondary named workspace lists both same-title windows, real focus and occupancy')

    cli('view-workspace','desktop2','2')
    cli('launch','desktop2','--','/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),'browse-window',str(BASE/'browse.txt'))
    browse=wait(lambda:next(iter(clients('browse-window')),None))
    cli('view-workspace','desktop2','1')
    wait(lambda:bar('desktop2')['workspaceIdentity']['name'].endswith('-ws-1'))
    # A queued window click carries the seat generation and workspace at the
    # time of the click. Neither assertion may be re-bound to current state.
    click_state=cli('state','desktop2')
    for generation,workspace in [(str(int(click_state['generation'])+1),click_state['workspaceName']),
                                 (click_state['generation'],browse['workspace']['name'])]:
        cli('view-focus','desktop2',names[-1]['address'],'--seat',click_state['seatId'],generation,
            '--workspace',workspace,succeeds=False)
        refused=cli('state','desktop2')
        assert refused['workspace']==click_state['workspace'] and refused['windowAddress']==click_state['windowAddress']
    record('stale window click generation and old workspace are rejected without changing native focus')
    shell('ipc','desktop','observe','desktop2');wait(lambda:observer()['presentation'].get('active'))
    wait(lambda:len(bar()['windows'])==2 and bar()['focused']==focus_address('desktop2'))
    agent_before=cli('state','desktop2')
    shell('ipc','desktopObserver','browse','name:'+browse['workspace']['name'])
    wait(lambda:observer()['presentation'].get('workspace')==browse['workspace']['name'])
    wait(lambda:bar()['workspaceIdentity']['name']==browse['workspace']['name'] and len(bar()['windows'])==1)
    assert bar()['windows'][0]['address']==browse['address'] and not bar()['focused'] and not bar()['title']
    assert next(p for p in pills() if p['name']=='2')['active']
    after=cli('state','desktop2')
    assert after['workspace']==agent_before['workspace'] and after['windowAddress']==agent_before['windowAddress']
    assert len(bar('desktop2')['windows'])==2
    click_window(browse['address']);time.sleep(.2)
    clicked=cli('state','desktop2')
    assert clicked['workspace']==after['workspace'] and clicked['windowAddress']==after['windowAddress']
    assert not bar()['focused'] and bar()['workspaceIdentity']['name']==browse['workspace']['name']
    subprocess.run(['grim','-o','human',str(BASE/'readonly-browse-windowbar.png')],env=ENV,check=True)
    record('readonly browse lists observed workspace without inventing focus or changing Agent state')
    shell('ipc','desktopObserver','follow');wait(lambda:observer()['presentation'].get('following'))
    wait(lambda:len(bar()['windows'])==2 and bar()['focused']==focus_address('desktop2'))
    shell('ipc','desktopObserver','takeover','true');wait(lambda:observer()['humanControl'])
    wait(lambda:bar()['focused']==focus_address('desktop2'))
    wait(lambda:next(item for item in json.loads(scoped('desktop2','ipc','desktop','status'))['desktops'] if item['name']=='desktop2')['controlMode']=='human')
    click_window(names[-1]['address'])
    wait(lambda:bar()['focused']==names[-1]['address'] and bar('desktop2')['focused']==names[-1]['address'])
    subprocess.run(['grim','-o','human',str(BASE/'takeover-exact-focus.png')],env=ENV,check=True)
    record('following and takeover share exact window identity on both rendered bars')
    shell('ipc','desktopObserver','takeover','false');wait(lambda:not observer()['humanControl'])
    shell('ipc','desktop','observe','main');wait(lambda:not observer()['open'])
    wait(lambda:bar()['workspaceIdentity']['name']=='1' and bar()['focused']==human['window'])
    assert {k:v for k,v in human_state().items() if k!='cursor'}=={k:v for k,v in human.items() if k!='cursor'}
    record('return to main restores its independent numeric workspace and focused window')

    cli('create','numeric','--workspace','11','--virtual-output','1280x800');cli('resume','numeric')
    wait(lambda:'pong' in scoped('numeric','ping'))
    for index in range(2):
        cli('launch','numeric','--','/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),'numeric-same',str(BASE/('numeric'+str(index)+'.txt')))
        wait(lambda:len(clients('numeric-same'))==index+1)
    # No shell IPC wakes or polls this unpresented desktop while its events
    # arrive. The first read must already expose the background window/focus.
    time.sleep(.5)
    background=bar('numeric')
    assert len(background['windows'])==2 and background['focused']==focus_address('numeric'),background
    assert background['workspaceIdentity']['id']==11
    record('numeric secondary seat uses the same identity contract without title-based focus')
finally:cleanup()
