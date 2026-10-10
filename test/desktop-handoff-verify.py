"""Task-owned human cooperation with real MCP, native views and QML buttons."""
from desktop_harness import *
import hashlib
class MCP:
 def __init__(self,label,without_session=False):
  env=dict(ENV)
  for key in ('CORNICE_AGENT_JOB','CORNICE_MCP_BINDING'):env.pop(key,None)
  if without_session:env.pop('HYPRLAND_INSTANCE_SIGNATURE',None)
  self.p=subprocess.Popen([str(PRODUCT/'bin/cornice-desktop-mcp')],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/(label+'.log'),'w'),text=True,start_new_session=True)
  PROCESSES.append(self.p);self.number=0
  self.request('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':label,'version':'1'}})
  self.p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');self.p.stdin.flush()
 def send(self,method,params):
  self.number+=1;self.p.stdin.write(json.dumps({'jsonrpc':'2.0','id':self.number,'method':method,'params':params})+'\n');self.p.stdin.flush();return self.number
 def receive(self,number):
  while True:
   assert select.select([self.p.stdout],[],[],35)[0],('MCP timeout',number)
   line=self.p.stdout.readline();assert line,('MCP exited',self.p.poll())
   value=json.loads(line)
   if value.get('id')==number:
    assert 'error' not in value,value
    return value['result']
 def request(self,method,params):return self.receive(self.send(method,params))
 def call(self,name,params=None,success=True):
  result=self.request('tools/call',{'name':name,'arguments':params or {}})
  assert bool(result.get('isError'))!=success,(name,result)
  return result
 def details(self,name,params=None):return self.call(name,params).get('structuredContent',{})
 def close(self):
  if self.p.poll() is None:self.p.stdin.close();self.p.wait(timeout=8)

def shell(*args,env=None):
    result=subprocess.run([str(PRODUCT/'bin/cornice'),*args],env=env or ENV,text=True,capture_output=True,timeout=10)
    if result.returncode:raise subprocess.CalledProcessError(result.returncode,args,output=result.stdout,stderr=result.stderr)
    return result.stdout.strip()
def observer():return json.loads(shell('ipc','desktopObserver','status'))
def banner(env=None):return json.loads(shell('ipc','desktopCooperation','status',env=env))
def secondary_env(name):
    digest=hashlib.sha256(ENV['HYPRLAND_INSTANCE_SIGNATURE'].encode()).hexdigest()[:8]
    return ENV|{'CORNICE_SHELL_SOCKET':str(RT/('cs-'+digest+'-'+name+'.sock'))}
def send(line):
    keyboard.stdin.write(line+'\n');keyboard.stdin.flush()
    assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='done',line
def click_banner(name,env=None):
    row=wait(lambda:next((row for row in banner(env)['controls'] if row['name']==name),None))
    layers=ctl('layers',True)
    if env:
        output=cli('state',name)['output']
    else:output='human'
    layer=next(layer for entries in layers[output]['levels'].values() for layer in entries if layer['namespace']=='cornice-desktop-cooperation')
    position=cli('state',name)['position'] if env else [0,0]
    x=round(layer['x']-position[0]+row['x']+row['width']/2);y=round(layer['y']-position[1]+row['y']+row['height']/2)
    for line in (f'motion {x} {y}','button 272 1','button 272 0'):send(line)

try:
    broker=initialize()
    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    (config/'config.json').write_text(json.dumps({'agentDesktop':{'enabled':True},'background':{'enabled':False},'weather':{'intervalMinutes':0},'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}))
    start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window',BASE/'human.txt'],'human')
    wait(lambda:len(ctl('clients',True))==1)
    qs=start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice')
    wait(lambda:json.loads(shell('ipc','desktop','status'))['available'])
    for source,name in (('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')):
        for mode,ext in (('client-header','h'),('private-code','c')):
            subprocess.run(['wayland-scanner',mode,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+ext))],check=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'human-input'),*flags],check=True)
    keyboard=subprocess.Popen([str(BASE/'human-input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'keyboard.log','w'),text=True,start_new_session=True);PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='ready'
    a=MCP('codex');b=MCP('pi')
    task=a.details('desktop_acquire');other=b.details('desktop_acquire')
    ref=task['desktop'];name=task['name'];target={'desktop':ref}
    a.call('desktop_launch',target|{'argv':['/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),name+'-window',str(BASE/(name+'.txt'))]})
    wait(lambda:any(w['title']==name+'-window' for w in ctl('clients',True)))
    frame=a.details('desktop_capture',target)
    request=a.details('desktop_handoff',target|{'action':'request','title':'请完成验证码','instructions':'在浏览器输入验证码，然后点击“已完成，退出接管”。'})['request'];rid=request['id']
    assert request['status']=='requested' and cli('state',name)['paused']
    assert a.details('desktop_handoff',target|{'action':'request','title':'请完成验证码','instructions':request['instructions']})['request']['id']==rid
    a.call('desktop_input',target|{'frameId':frame['frameId'],'action':'text','text':'must not type'},False)
    assert b.call('desktop_handoff',{'desktop':other['desktop'],'action':'resolve','requestId':rid,'outcome':'cancelled','note':'foreign'},False)['isError']
    assert a.call('desktop_handoff',target|{'action':'resume','requestId':rid},False)['isError']
    wait(lambda:banner()['visible'])
    subprocess.run(['grim','-o','human',str(BASE/'cooperation-request.png')],env=ENV,check=True)
    click_banner(name)
    wait(lambda:observer()['humanControl'])
    wait(lambda:a.details('desktop_handoff',target|{'action':'status'})['request']['status']=='in_progress')
    agent_env=secondary_env(name)
    wait(lambda:banner(agent_env)['visible'] and banner(agent_env)['controls'][0]['status']=='in_progress')
    # Real keyboard input reaches the target desktop while Agent input is revoked.
    client=next(w for w in ctl('clients',True) if w['title']==name+'-window')
    st=cli('state',name);g=json.loads((BASE/(name+'.geometry')).read_text())['entry']
    x=round(client['at'][0]-st['position'][0]+g[0]+30);y=round(client['at'][1]-st['position'][1]+g[1]+g[3]/2)
    for line in (f'motion {x} {y}','button 272 1','button 272 0'):send(line)
    for character in 'human':send('type '+character);time.sleep(.04)
    wait(lambda:(BASE/(name+'.txt')).read_text()=='human')
    subprocess.run(['grim','-o','human',str(BASE/'cooperation-in-progress.png')],env=ENV,check=True)
    assert 'changed' in cli('handoff-complete',name,'wrong-request',succeeds=False)
    waitingId=a.send('tools/call',{'name':'desktop_wait','arguments':target|{'seconds':30,'reason':'等待人工步骤完成'}})
    click_banner(name,agent_env)
    completedAt=time.monotonic()
    waited=a.receive(waitingId)
    assert waited['structuredContent']['cooperationResolved'] and waited['structuredContent']['interrupted'],waited
    assert time.monotonic()-completedAt<2,'completion did not promptly wake the waiting harness tool'
    wait(lambda:not observer()['humanControl'])
    done=wait(lambda:a.details('desktop_handoff',target|{'action':'status'})['request'] if a.details('desktop_handoff',target|{'action':'status'})['request']['status']=='completed' else None)
    assert [event['status'] for event in done['events']]==['requested','in_progress','completed'],done
    assert cli('state',name)['paused']
    a.call('desktop_handoff',target|{'action':'resume','requestId':rid})
    fresh=a.details('desktop_capture',target)
    assert fresh['generation']!=frame['generation']
    a.call('desktop_input',target|{'frameId':fresh['frameId'],'action':'text','text':'-agent'})
    wait(lambda:(BASE/(name+'.txt')).read_text()=='human-agent')
    record('real MCP request pauses input, actual QML button takes native control, physical typing works, Completed exits takeover and wakes the bounded wait, and fresh generations reject old frames')
    cli('pause',name)
    assert a.call('desktop_handoff',target|{'action':'resume','requestId':rid},False)['isError']
    a.call('desktop_finish',target|{'outcome':'blocked','reason':'operator paused after cooperation restoration'})
    replacement=a.details('desktop_acquire',{'preferredDesktop':name})
    assert replacement['name']==name
    target={'desktop':replacement['desktop']}
    request=a.details('desktop_handoff',target|{'action':'request','title':'请扫码' ,'instructions':'扫描二维码登录；无法在本机操作时，可在对话里撤回。'})['request'];rid=request['id']
    shell('ipc','desktopObserver','takeover','true');wait(lambda:observer()['humanControl'])
    cancelled=a.details('desktop_handoff',target|{'action':'resolve','requestId':rid,'outcome':'cancelled','note':'用户远程要求退出接管'})
    assert cancelled['request']['status']=='cancelled'
    wait(lambda:not observer()['humanControl'])
    # A later ordinary manual takeover is unrelated to the resolved request.
    shell('ipc','desktopObserver','takeover','true');wait(lambda:observer()['humanControl'])
    a.call('desktop_handoff',target|{'action':'resolve','requestId':rid,'outcome':'cancelled','note':'repeat remote cancellation'})
    assert observer()['humanControl']
    assert a.call('desktop_handoff',target|{'action':'resume','requestId':rid},False)['isError']
    shell('ipc','desktopObserver','takeover','false');wait(lambda:not observer()['humanControl'])
    assert a.call('desktop_handoff',target|{'action':'resume','requestId':rid},False)['isError']
    assert not b.details('desktop_state',{'desktop':other['desktop']})['paused']
    assert len(cli('state',name)['handoffs'])==2
    saved=json.loads((RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']/'desktops.json').read_text())
    assert len(saved[name]['handoffs'])==2
    record('remote chat resolution releases only its request takeover; history persists and later manual control or pause blocks resume both before and after initial restoration')
    # Primary uses the same cooperation contract after explicit enabled acquisition.
    shell('ipc','desktop','observe','main');wait(lambda:not observer()['open'])
    wait(lambda:cli('state','main')['available'])
    cli('allow-agent','main','on');primary=a.details('desktop_acquire',{'preferredDesktop':'main'})
    assert primary['name']=='main',primary
    ptarget={'desktop':primary['desktop']}
    pr=a.details('desktop_handoff',ptarget|{'action':'request','title':'主桌面步骤','instructions':'请在主桌面确认这个步骤。'})['request']
    shell('ipc','desktop','observe','main');wait(lambda:not observer()['open'])
    wait(lambda:banner()['visible']);click_banner('main')
    wait(lambda:a.details('desktop_handoff',ptarget|{'action':'status'})['request']['status']=='in_progress')
    click_banner('main')
    wait(lambda:a.details('desktop_handoff',ptarget|{'action':'status'})['request']['status']=='completed')
    cli('allow-agent','main','off')
    assert a.call('desktop_handoff',ptarget|{'action':'resume','requestId':pr['id']},False)['isError']
    record('explicitly enabled primary desktop has the same request and complete buttons; permission revocation blocks restoration')
    shell('ipc','shell','summon','cn.agent-desktop','{}')
    rows=wait(lambda:json.loads(shell('ipc','desktopPanel','controls')))
    assert next(row for row in rows if row['name']==name)['handoffs'][-1]['status']=='cancelled'
    assert next(row for row in rows if row['name']=='main')['handoffs'][-1]['status']=='completed'
    subprocess.run(['grim','-o','human',str(BASE/'cooperation-history.png')],env=ENV,check=True)
    record('actual management panel renders completed and cancelled task records with human instructions')
    a.close();b.close()
    assert all(item['status'] in ['completed','cancelled'] for item in cli('state',name)['handoffs'])
    waiting=MCP('recovery');pending=waiting.details('desktop_acquire',{'preferredDesktop':name})
    waiting.details('desktop_handoff',{'desktop':pending['desktop'],'action':'request','title':'恢复记录测试','instructions':'等待人工处理，不应在服务重启后恢复输入。'})
    broker.kill();broker.wait(timeout=5)
    broker=start([str(PRODUCT/'bin/cornice-desktopd')],'recovered-broker')
    wait(desktop_ready)
    recovered=cli('state',name)
    assert recovered['paused'] and recovered['handoff']['status']=='cancelled'
    assert recovered['handoff']['events'][-1]['status']=='cancelled'
    assert cli('state','main')['handoff']['status']=='completed'
    assert waiting.call('desktop_handoff',{'desktop':pending['desktop'],'action':'status'},False)['isError']
    waiting.close()
    record('broker restart preserves secondary and primary cooperation history, cancels orphaned pending requests, and does not restore old task credentials or input')
finally:
    cleanup();print('Private test directory:',BASE,flush=True)
