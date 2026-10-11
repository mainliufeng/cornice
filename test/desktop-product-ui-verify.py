"""Exercise desktop lifecycle notices and controls on real isolated QML surfaces."""
from desktop_harness import *
import hashlib
import threading
import shutil

class Task:
    def __init__(self, preferred):
        self.connection = socket.socket(socket.AF_UNIX)
        self.connection.settimeout(5)
        self.connection.connect(str(broker_socket()))
        self.lock = threading.RLock()
        self.buffer = b''
        self.stopped = threading.Event()
        self.errors = []
        self.controller = 'product-ui-test'
        self.binding = self.request('acquire-desktop', {'controller':self.controller,'harness':'codex','preferredDesktop':preferred})
        self.thread = threading.Thread(target=self.heartbeat, daemon=True)
        self.thread.start()
    def request(self, method, params, task=False):
        with self.lock:
            identity = str(time.monotonic_ns())
            value = {'id':identity,'method':method,'params':params}
            if hasattr(self,'binding'):
                value.update(controller=self.controller,token=self.binding['taskToken' if task else 'token'])
            self.connection.sendall((json.dumps(value)+'\n').encode())
            while True:
                while b'\n' not in self.buffer:
                    chunk=self.connection.recv(65536)
                    assert chunk,'Task socket closed'
                    self.buffer+=chunk
                line,self.buffer=self.buffer.split(b'\n',1)
                reply=json.loads(line)
                if reply.get('id') != identity:continue
                assert reply['ok'],reply
                return reply['result']
    def heartbeat(self):
        while not self.stopped.wait(1):
            try:self.request('desktop.handoff',{'action':'status'},task=True)
            except Exception as error:self.errors.append(str(error));return
    def handoff(self, **params):
        result=self.request('desktop.handoff',params,task=True)
        if 'binding' in result:self.binding=result['binding']
        return result['state']
    def text(self,text):
        frame=self.request('desktop.capture',{})
        self.request('desktop.input',{'frameId':frame['frameId'],'action':'text','text':text})
    def close(self,check=True):
        self.stopped.set();self.thread.join(timeout=6);self.connection.close()
        if check:assert not self.errors,self.errors


def local(name,*args):
    digest=hashlib.sha256(ENV['HYPRLAND_INSTANCE_SIGNATURE'].encode()).hexdigest()[:8]
    env=ENV|{'CORNICE_SHELL_SOCKET':str(RT/('cs-'+digest+'-'+name+'.sock'))}
    return subprocess.check_output([str(PRODUCT/'bin/cornice'),*map(str,args)],env=env,text=True,stderr=subprocess.PIPE,timeout=8).strip()
def status(name=None):return json.loads(local(name,'ipc','desktop','status') if name else shell('ipc','desktop','status'))
def observer():return json.loads(shell('ipc','desktopObserver','status'))
def cooperation(name=None):return json.loads(local(name,'ipc','desktopCooperation','status') if name else shell('ipc','desktopCooperation','status'))
def send(line):
    keyboard.stdin.write(line+'\n');keyboard.stdin.flush()
    assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='done',line

def click(x,y):
    for line in (f'motion {round(x)} {round(y)}','button 272 1','button 272 0'):send(line)
def key(code):send(f'key {code} 1');send(f'key {code} 0')
def panel_action(action,target=''):
    state=wait(lambda:json.loads(shell('ipc','desktopPanel','actions')))
    button=next(item for item in state['actions'] if item['key']==action and item['target']==target and item['visible'] and item['enabled'])
    assert 0 <= button['y'] < state['window']['height'],('Button is outside panel viewport',state)
    layers=wait(lambda:[layer for levels in ctl('layers',True)['human']['levels'].values() for layer in levels if layer['namespace']=='cornice-panel'])
    layer=layers[-1]
    stamp=str(time.monotonic_ns())
    (BASE/('panel-'+action+'-'+stamp+'.json')).write_text(json.dumps({'state':state,'button':button,'layers':layers}))
    subprocess.run(['grim','-o','human',str(BASE/('panel-'+action+'-'+stamp+'.png'))],env=ENV,check=True)
    click(layer['x']+button['x']+button['width']/2,layer['y']+button['y']+button['height']/2)

def menu(name=None):
    def controls():
        geometry=local(name,'ipc','bar','geometry') if name else shell('ipc','bar','geometry')
        return next(widget['controls'] for widget in json.loads(geometry) if widget['id']=='cn.agent-desktop')
    group=next(item for item in controls() if item['name']=='group')
    send(f"motion {round(group['x']+group['width']/2)} {round(group['y']+group['height']/2)}")
    def open_controls():
        rows=controls()
        return rows if any(item['name']=='control:current-heading' for item in rows) else None
    return wait(open_controls)

def card_click(name,secondary=False):
    row=wait(lambda:next((item for item in cooperation(name if secondary else None)['controls'] if item['name']==name),None))
    output=cli('state',name)['output'] if secondary else 'human'
    layer=next(layer for levels in ctl('layers',True)[output]['levels'].values() for layer in levels if layer['namespace']=='cornice-desktop-cooperation')
    offset=cli('state',name)['position'] if secondary else [0,0]
    click(layer['x']-offset[0]+row['x']+row['width']/2,layer['y']-offset[1]+row['y']+row['height']/2)


task=None
broker=None
try:
    ENV['XDG_DATA_HOME']=str(BASE/'data')
    applications=BASE/'data/applications';applications.mkdir(parents=True)
    app_argv=['/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),'ui-target-window',str(BASE/'ui-target.txt')]
    (applications/'cornice-ui-launch.desktop').write_text('[Desktop Entry]\nType=Application\nName=Cornice UI Launch Target\nExec='+shlex.join(app_argv)+'\n')
    broker=initialize()
    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    path=config/'config.json'
    settings={'agentDesktop':{'enabled':True,'resources':{'maxDesktops':2,'minAvailableMemoryMiB':0},'desktops':[{'name':'bootstrap-ui','virtualOutput':'1280x800'}]},'bar':{'layout':{'left':[{'id':'cn.agent-desktop'},{'id':'cn.launcher'},{'id':'cn.workspaces'}],'center':[],'right':[]}},'background':{'enabled':False},'weather':{'intervalMinutes':0},'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}
    def configure():path.write_text(json.dumps(settings))
    configure()
    start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window',BASE/'human.txt'],'human-app')
    wait(lambda:any(item['title']=='human-window' for item in ctl('clients',True)))
    before=human_state()
    primary=start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice')
    failure=wait(lambda:status() if status()['actionResult'].get('desktop')=='bootstrap-ui' else None)
    assert failure['available'] and failure['actionResult']['error'] and failure['bootstrapFailures']['bootstrap-ui']['attempts']>=1,failure
    for _ in range(4):
        time.sleep(.3)
        assert status()['actionResult']['detail']==failure['actionResult']['detail'],'successful refresh erased action failure'
    subprocess.run(['grim','-o','human',str(BASE/'product-error-notice.png')],env=ENV,check=True)
    cli('remove','desktop2')
    wait(lambda:any(item['name']=='bootstrap-ui' for item in cli('list')['desktops']),timeout=12)
    wait(lambda:status()['available'] and not status()['actionResult'] and not status()['bootstrapFailures'])
    assert cli('windows','bootstrap-ui')['windows']==[]
    record('failed real bootstrap allocation stays visible across successful health refreshes; freeing capacity retries and creates a truly empty desktop')
    for source,name in (('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')):
        for mode,extension in (('client-header','h'),('private-code','c')):subprocess.run(['wayland-scanner',mode,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+extension))],check=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'human-input'),*flags],check=True)
    keyboard=subprocess.Popen([str(BASE/'human-input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'keyboard.log','w'),text=True,start_new_session=True);PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='ready'
    settings['agentDesktop']['resources']['maxDesktops']=3;configure();shell('ipc','shell','reloadConfig')
    shell('ipc','shell','summon','cn.agent-desktop','{}')
    wait(lambda:json.loads(shell('ipc','desktopPanel','actions'))['open'])
    panel_action('create')
    created=wait(lambda:next((item for item in cli('list')['desktops'] if item['name'] not in ('main','bootstrap-ui')),None))
    wait(lambda:observer()['open'] and observer()['name']==created['name'])
    assert cli('windows',created['name'])['windows']==[]
    shell('ipc','desktop','observe','main');wait(lambda:not observer()['open']);cli('remove',created['name'])
    settings['agentDesktop']['resources']['maxDesktops']=2;configure();shell('ipc','shell','reloadConfig')
    record('actual Create Empty Desktop button allocates an empty native desktop and opens it in read-only view')
    shell('ipc','desktop','observe','bootstrap-ui');wait(lambda:observer()['presentation'].get('active'))
    workspace=cli('state','bootstrap-ui')['workspaceSlots'][1]['name']
    workspace_name=workspace.removeprefix('name:')
    shell('ipc','desktopObserver','browse',workspace)
    wait(lambda:observer()['presentation'].get('following') is False and observer()['presentation'].get('workspace')==workspace_name)
    # The primary shell owns the physical bar during read-only presentation.
    rows=menu()
    follow=next(item for item in rows if item['name']=='control:follow')
    assert follow['enabled'] and follow['target']=='bootstrap-ui',follow
    def browsed_bar():
        widget=next(item for item in json.loads(shell('ipc','bar','geometry')) if item['id']=='cn.workspaces')
        return next(item for item in widget['controls'] if item['active'])['name']=='2'
    wait(browsed_bar)
    assert cli('state','bootstrap-ui')['workspaceName'].endswith('-ws-1')
    subprocess.run(['grim','-o','human',str(BASE/'product-free-browse.png')],env=ENV,check=True)
    click(follow['x']+follow['width']/2,follow['y']+follow['height']/2)
    wait(lambda:observer()['presentation'].get('following') is True)
    assert cli('state','bootstrap-ui')['workspaceName'].endswith('-ws-1')
    record('read-only free browsing updates the native desktop bar without moving Agent workspace; actual Resume Follow menu returns to Agent current workspace')
    settings['desktopApplications']={'rules':{'ui-probe':{'executables':['python3'],'scope':'secondary','profile':'../invalid'}}}
    configure();shell('ipc','shell','reloadConfig')
    shell('ipc','desktopObserver','takeover','true');wait(lambda:observer()['humanControl'])
    # In takeover, the secondary shell owns its native bar and current workspace.
    wait(lambda:next(item for item in next(widget['controls'] for widget in json.loads(local('bootstrap-ui','ipc','bar','geometry')) if widget['id']=='cn.workspaces') if item['active'])['name']=='1')
    local('bootstrap-ui','launcher');wait(lambda:json.loads(local('bootstrap-ui','ipc','launcher','debug'))['focused'])
    local('bootstrap-ui','ipc','launcher','setQuery','Cornice UI Launch Target')
    wait(lambda:json.loads(local('bootstrap-ui','ipc','launcher','debug'))['first']=='Cornice UI Launch Target')
    key(28)
    failed=wait(lambda:status('bootstrap-ui') if status('bootstrap-ui')['actionResult'].get('operation')=='启动应用' else None)
    assert failed['actionResult']['error'] and not any(item['title']=='ui-target-window' for item in ctl('clients',True))
    wait(lambda:status()['actionResult'].get('operation')=='启动应用')
    shell('ipc','desktop','observe','main');wait(lambda:not observer()['open'])
    for _ in range(3):time.sleep(.3);assert status()['actionResult'].get('desktop')=='bootstrap-ui'
    assert cooperation()['visible'] and cooperation()['error']
    subprocess.run(['grim','-o','human',str(BASE/'product-returned-error.png')],env=ENV,check=True)
    settings['desktopApplications']['rules']['ui-probe']['enabled']=False;configure();shell('ipc','shell','reloadConfig')
    shell('ipc','desktop','observe','bootstrap-ui');wait(lambda:observer()['presentation'].get('active'))
    shell('ipc','desktopObserver','takeover','true');wait(lambda:observer()['humanControl'])
    local('bootstrap-ui','launcher');wait(lambda:json.loads(local('bootstrap-ui','ipc','launcher','debug'))['focused'])
    local('bootstrap-ui','ipc','launcher','setQuery','Cornice UI Launch Target');key(28)
    wait(lambda:any(item['title']=='ui-target-window' for item in ctl('clients',True)))
    wait(lambda:not status('bootstrap-ui')['actionResult'] and not status()['actionResult'])
    shell('ipc','desktop','observe','main');wait(lambda:not observer()['open'])
    record('launcher policy failure uses persistent contextual result; returning to main retains the notice, and successful corrected launch clears it without app-specific code')
    shell('ipc','shell','summon','cn.agent-desktop','{}')
    wait(lambda:json.loads(shell('ipc','desktopPanel','actions'))['open'])
    panel_action('reset','bootstrap-ui')
    confirm=wait(lambda:json.loads(shell('ipc','desktopPanel','actions'))['confirmation'])
    assert confirm['operation']=='reset' and confirm['windowCount']==1,confirm
    assert any(item['title']=='ui-target-window' for item in ctl('clients',True))
    panel_action('cancel');assert any(item['title']=='ui-target-window' for item in ctl('clients',True))
    panel_action('reset','bootstrap-ui');wait(lambda:json.loads(shell('ipc','desktopPanel','actions'))['confirmation'])
    panel_action('preserve');wait(lambda:cli('state','bootstrap-ui')['paused'])
    assert any(item['title']=='ui-target-window' for item in ctl('clients',True))
    shell('ipc','shell','hide','cn.agent-desktop')
    record('actual reset confirmation supports cancellation and preserves the running app by default')
    task=Task('bootstrap-ui')
    request=task.handoff(action='request',title='请完成人工步骤',instructions='在输入框键入 human，然后点击已完成，退出接管。')['handoff']
    wait(lambda:cooperation()['visible'])
    widget=next(item for item in json.loads(shell('ipc','bar','geometry')) if item['id']=='cn.agent-desktop')
    icon=next(item for item in widget['controls'] if item['name']=='group')
    assert icon['alert'] and icon['badge']==1,icon
    card_click('bootstrap-ui');wait(lambda:observer()['humanControl'])
    current=cli('state','bootstrap-ui');client=next(item for item in ctl('clients',True) if item['title']=='ui-target-window')
    entry=json.loads((BASE/'ui-target.geometry').read_text())['entry']
    click(client['at'][0]-current['position'][0]+entry[0]+30,client['at'][1]-current['position'][1]+entry[1]+entry[3]/2)
    for letter in 'human':send('type '+letter);time.sleep(.04)
    wait(lambda:(BASE/'ui-target.txt').read_text()=='human')
    card_click('bootstrap-ui',secondary=True)
    wait(lambda:not observer()['humanControl'] and cooperation('bootstrap-ui')['controls'][0]['continuation'])
    support=cli('state','bootstrap-ui')['continuation']
    assert support['eventWait'] and support['notifications'] and support['wakeHarness'] is False,support
    subprocess.run(['grim','-o','human',str(BASE/'product-waiting-continuation.png')],env=ENV,check=True)
    task.handoff(action='resume',requestId=request['id']);task.text('-agent')
    wait(lambda:(BASE/'ui-target.txt').read_text()=='human-agent')
    wait(lambda:not cooperation('bootstrap-ui')['visible'])
    task.close();task=None
    shell('ipc','desktop','observe','main');wait(lambda:not observer()['open'])
    assert not (BASE/'human.txt').exists()
    assert {k:v for k,v in before.items() if k!='cursor'}=={k:v for k,v in human_state().items() if k!='cursor'}
    record('global request badge and real handoff buttons preserve input: human typing, honest waiting state, and resumed Agent typing reach the same app while primary focus/workspace remain unchanged')
except Exception:
    # This PID belongs to the private test child. Never discover a host Broker.
    if broker and broker.poll() is None:
        proc=pathlib.Path('/proc')/str(broker.pid)
        try:
            assert ('XDG_RUNTIME_DIR='+str(RT)).encode() in (proc/'environ').read_bytes().split(b'\0')
            evidence={'pid':broker.pid,'command':(proc/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace')}
            for field in ('wchan','syscall','stack','status'):
                try:evidence[field]=(proc/field).read_text()
                except OSError as error:evidence[field]={'error':str(error)}
            (BASE/'failure-broker-process.json').write_text(json.dumps(evidence,indent=2))
            if shutil.which('gdb'):
                with (BASE/'failure-broker-backtrace.log').open('w') as output:
                    try:subprocess.run(['gdb','-q','-batch','-ex','set pagination off','-ex','thread apply all bt','-p',str(broker.pid)],env=ENV,stdout=output,stderr=subprocess.STDOUT,timeout=10)
                    except subprocess.TimeoutExpired:output.write('\nPrivate Broker backtrace timed out\n')
        except (OSError,AssertionError) as error:
            (BASE/'failure-broker-process.json').write_text(json.dumps({'pid':broker.pid,'error':str(error)}))
    diagnostics={}
    for name,read in [('observer',observer),('status',status),('desktops',lambda:cli('list')),('layers',lambda:ctl('layers',True))]:
        try:diagnostics[name]=read()
        except Exception as error:diagnostics[name]={'error':str(error)}
    (BASE/'failure-state.json').write_text(json.dumps(diagnostics,ensure_ascii=False,indent=2))
    try:subprocess.run(['grim','-o','human',str(BASE/'failure-screen.png')],env=ENV,check=True)
    except Exception:pass
    print('FAILURE STATE',json.dumps(diagnostics,ensure_ascii=False),flush=True)
    raise
finally:
    try:
        if task:task.close(check=False)
    finally:cleanup()
