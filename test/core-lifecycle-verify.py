"""Real compositor task restoration, retirement, budgets and stable login identities."""
from desktop_harness import *
import threading
import shutil

assert os.getenv('CORNICE_TEST_SANDBOX') == '1', 'Use the device/PID/resource sandbox'


def request(method, params=None, lease=None, identity=None, connection=None, success=True):
    owned = connection is None
    connection = connection or socket.socket(socket.AF_UNIX)
    if owned:
        connection.settimeout(40)
        connection.connect(str(broker_socket()))
    identity = identity or str(time.monotonic_ns())
    value = {'id': identity, 'method': method, 'params': params or {}}
    if lease:
        value.update(token=lease['taskToken'] if method in ('desktop.task', 'desktop.handoff') else lease['token'],
                     controller=lease['controller'], harness=lease['harness'])
    connection.sendall((json.dumps(value)+'\n').encode())
    received = b''
    try:
        while True:
            while b'\n' not in received:
                chunk=connection.recv(65536)
                assert chunk, 'Broker socket closed'
                received += chunk
            line, received = received.split(b'\n',1)
            response=json.loads(line)
            if response.get('id') != identity:
                continue
            assert bool(response['ok']) == success, (method,response)
            return response.get('result') if success else response['error']
    finally:
        if owned:
            connection.close()


class Task:
    def __init__(self, label, **params):
        self.connection=socket.socket(socket.AF_UNIX)
        self.connection.settimeout(10)
        self.connection.connect(str(broker_socket()))
        self.lease=request('acquire-desktop',{'controller':label,'harness':'core-test',**params},connection=self.connection)
        self.done=threading.Event()
        self.thread=threading.Thread(target=self.heartbeat,daemon=True)
        self.thread.start()
    def heartbeat(self):
        while not self.done.wait(.5):
            try:
                request('desktop.handoff',{'action':'status'},self.lease)
            except (OSError,AssertionError):
                return
    def call(self, method, params=None, **options):
        return request('desktop.'+method,params,self.lease,**options)
    def close(self):
        self.done.set();self.thread.join(timeout=3);self.connection.close()


tasks=[]
try:
    broker=initialize()
    human=start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window',BASE/'human.txt'],'human')
    wait(lambda:any(c['title']=='human-window' for c in ctl('clients',True)))
    baseline=human_state()
    a=Task('task-a');tasks.append(a)
    name=a.lease['name']
    a.call('launch',{'argv':['/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),'restored-window',str(BASE/'restored.txt')]})
    wait(lambda:any(c['title']=='restored-window' for c in ctl('clients',True)))
    frame=a.call('capture')
    action={'frameId':frame['frameId'],'action':'text','text':'before-'}
    a.call('input',action,identity='dedup-input')
    a.call('input',action,identity='dedup-input')
    wait(lambda:(BASE/'restored.txt').read_text()=='before-')
    assert 'reused' in a.call('input',action|{'text':'wrong'},identity='dedup-input',success=False)
    assert cli('doctor')['taskHistorySize']==2
    record('Same live request ID executes once, changed payload is rejected, and native input reaches the intended GTK app')

    old=dict(a.lease)
    cli('pause',name)
    assert 'restoration' in a.call('task',{'action':'restore'},success=False)
    assert a.call('capture',success=False)
    result=[]
    waiter=threading.Thread(target=lambda:result.append(a.call('task',{'action':'wait','seconds':10})))
    waiter.start();time.sleep(.15)
    cli('resume',name)
    waiter.join(timeout=12)
    assert not waiter.is_alive() and result and not result[0]['control']['agentPaused'],result
    restored=a.call('task',{'action':'restore'})
    a.lease=restored['binding']
    assert a.lease['token']!=old['token'] and a.lease['generation']!=old['generation']
    assert request('desktop.capture',lease=old,success=False)
    frame=a.call('capture');a.call('input',{'frameId':frame['frameId'],'action':'text','text':'after'})
    wait(lambda:(BASE/'restored.txt').read_text()=='before-after')
    assert human_state()==baseline
    record('Operator resume wakes a real pending event wait; restore yields a fresh task binding, old credentials fail, app input resumes without human focus changes')

    b=Task('task-b');tasks.append(b)
    other=b.lease['name']
    b.call('workspace',{'slot':2})
    before=cli('doctor')['taskHistorySize'];assert before>=2
    a.done.set();a.thread.join(timeout=3)
    a.call('release')
    assert not cli('state',name)['occupied']
    assert cli('doctor')['taskHistorySize']==1
    assert not b.call('handoff',{'action':'status'})['state']['agentPaused']
    a.close()
    for index in range(12):
        task=Task('churn-'+str(index));tasks.append(task)
        task.call('workspace',{'slot':1})
        task.done.set();task.thread.join(timeout=3);task.call('release');task.close()
        assert cli('doctor')['taskHistorySize']==1
    record('Finish retires only its binding/history; repeated acquire-mutate-release never accumulates global history or interrupts the other owner')
    assert cli('reset',other,succeeds=False)
    assert cli('remove',other,succeeds=False)
    b.done.set();b.thread.join(timeout=3);b.call('release');b.close()
    assert cli('doctor')['taskHistorySize']==0
    record('Occupied reset/remove are denied; release clears history immediately without relying on socket disconnection')

    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    configFile=config/'config.json'
    count=len(cli('list')['desktops'])
    configFile.write_text(json.dumps({'agentDesktop':{'resources':{'maxDesktops':count,'maxPrivatePixels':134217728}}}))
    assert 'allocation limit' in cli('create','over-limit','--virtual-output','1280x800',succeeds=False)
    assert 'allocation limit' in request('acquire-desktop',{'controller':'over-limit','harness':'core-test','createNew':True},success=False)
    before=cli('state',name)['pixelSize']
    configFile.write_text(json.dumps({'agentDesktop':{'resources':{'maxDesktops':count,'maxPrivatePixels':320*240}}}))
    assert 'pixel budget' in request('fit',{'name':name,'width':8192,'height':8192,'scale':1},success=False)
    assert cli('state',name)['pixelSize']==before
    configFile.write_text(json.dumps({'agentDesktop':{'resources':{'maxDesktops':32,'maxPrivatePixels':134217728}}}))
    record('Direct creation and task allocation share the same count cap; resize rejects pixel-budget excess before changing the output')

    cli('create','persistent','--virtual-output','960x540')
    cli('lock-policy','persistent','continue')
    stable=cli('state','persistent')['stableId'];number=cli('state','persistent')['number']
    cli('resume','persistent');binding=bind('persistent')
    tool(binding,'workspace',{'slot':7})
    manifest=json.loads((BASE/'state/cornice/desktops.json').read_text())
    spec=manifest['desktops']['persistent']
    assert spec['stableId']==stable and spec['humanLockPolicy']=='continue' and spec['workspace'].endswith('ws-7')
    assert not any(key in spec for key in ('token','generation','seatId','captureGrant','taskToken'))
    cli('allow-agent','main','on')
    original_signature=ENV['HYPRLAND_INSTANCE_SIGNATURE']
    for task in tasks:task.close()
    cleanup()
    shutil.rmtree(RT);RT.mkdir(mode=0o700)
    for key in ('HYPRLAND_INSTANCE_SIGNATURE','WAYLAND_DISPLAY','DBUS_SESSION_BUS_ADDRESS'):
        ENV.pop(key,None)
    broker=initialize()
    rebuilt=cli('list')
    assert any(d['name']=='persistent' and d.get('available') for d in rebuilt['desktops']), rebuilt
    restored=cli('state','persistent')
    assert ENV['HYPRLAND_INSTANCE_SIGNATURE']!=original_signature
    assert restored['stableId']==stable and restored['number']==number
    assert restored['workspace']==spec['workspace'] and restored['humanLockPolicy']=='continue'
    assert restored['paused'] and not restored['occupied'] and cli('state','main')['agentAllowed'] is False
    tool(binding,'capture',succeeds=False)
    record('A genuine new compositor login rebuilds stable desktop identity, workspace mapping and lock policy; grants stay revoked and primary permission resets off')
    print('PASS core task lifecycle, resource policy and persistent desktop identities',flush=True)
finally:
    for task in tasks:task.close()
    cleanup()
