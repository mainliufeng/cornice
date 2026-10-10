"""Slow real AT-SPI applications must not stall other desktops or native viewing."""
from desktop_harness import *
ENV.pop('NO_AT_BRIDGE',None)
class MCP:
 def __init__(self,label,without_session=False):
  env=dict(ENV)
  for key in ('CORNICE_AGENT_JOB','CORNICE_MCP_BINDING'):env.pop(key,None)
  if without_session:env.pop('HYPRLAND_INSTANCE_SIGNATURE',None)
  self.p=subprocess.Popen([str(PRODUCT/'bin/cornice-desktop-mcp')],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/(label+'.log'),'w'),text=True,start_new_session=True)
  PROCESSES.append(self.p);self.number=0;self.replies={}
  self.request('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':label,'version':'1'}})
  self.p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');self.p.stdin.flush()
 def send(self,method,params):
  self.number+=1;self.p.stdin.write(json.dumps({'jsonrpc':'2.0','id':self.number,'method':method,'params':params})+'\n');self.p.stdin.flush();return self.number
 def receive(self,number):
  if number in self.replies:return self.replies.pop(number)
  while True:
   assert select.select([self.p.stdout],[],[],35)[0],('MCP timeout',number)
   line=self.p.stdout.readline();assert line,('MCP exited',self.p.poll())
   value=json.loads(line)
   if value.get('id')==number:
    assert 'error' not in value,value
    return value['result']
   if 'id' in value:self.replies[value['id']]=value['result']
 def request(self,method,params):return self.receive(self.send(method,params))
 def call(self,name,params=None,success=True):
  result=self.request('tools/call',{'name':name,'arguments':params or {}})
  assert bool(result.get('isError'))!=success,(name,result)
  return result
 def details(self,name,params=None):return self.call(name,params).get('structuredContent',{})
 def close(self):
  if self.p.poll() is None:self.p.stdin.close();self.p.wait(timeout=8)

def status():return json.loads(shell('ipc','desktopObserver','status'))
try:
 initialize()
 config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
 (config/'config.json').write_text(json.dumps({'background':{'enabled':False},'weather':{'intervalMinutes':0},'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}))
 qs=start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice')
 wait(lambda:json.loads(shell('ipc','desktop','status'))['available'])
 a=MCP('codex-slow');c=MCP('codex-other')
 da=a.details('desktop_acquire');dc=c.details('desktop_acquire');shared=a.details('desktop_acquire')
 a.call('desktop_launch',{'desktop':da['desktop'],'argv':['/usr/bin/python3',str(ROOT/'test/native-accessibility-slow-gtk.py'),str(BASE/'slow.flag'),str(BASE/'slow.txt')]})
 wait(lambda:next((w for w in ctl('clients',True) if w['title']=='slow-native-window'),None))
 cli('create','observed','--virtual-output','1280x800');cli('resume','observed')
 cli('launch','observed','--','/usr/bin/python3',ROOT/'test/agent-desktop-client.py','observed-window',BASE/'view.txt')
 wait(lambda:next((w for w in ctl('clients',True) if w['title']=='observed-window'),None))
 # Warm native AT-SPI registration before timing slow application behavior.
 a.call('desktop_snapshot',{'desktop':da['desktop'],'maxNodes':4})
 metrics=[]
 for takeover in (False,True):
  shell('desktop','observe','observed');wait(lambda:status()['presentation'].get('active'))
  if takeover:shell('ipc','desktopObserver','takeover','true');wait(lambda:status()['humanControl'])
  before=status();(BASE/'slow.flag').touch()
  began=time.monotonic();number=a.send('tools/call',{'name':'desktop_snapshot','arguments':{'desktop':da['desktop'],'maxNodes':300}})
  time.sleep(.2)
  shared_began=time.monotonic();shared_state=a.call('desktop_state',{'desktop':shared['desktop']});shared_elapsed=time.monotonic()-shared_began
  state_began=time.monotonic();other=c.call('desktop_state',{'desktop':dc['desktop']});state_elapsed=time.monotonic()-state_began
  result=a.receive(number);snapshot_elapsed=time.monotonic()-began
  (BASE/'slow.flag').unlink()
  after=status()
  metric={'takeover':takeover,'snapshotSeconds':snapshot_elapsed,'otherStateSeconds':state_elapsed,'sameMcpStateSeconds':shared_elapsed,'before':before,'after':after,'snapshotResult':result,'other':other}
  metrics.append(metric);(BASE/'responsiveness.json').write_text(json.dumps(metrics,indent=2,ensure_ascii=False))
  print('MEASURE',json.dumps({'takeover':takeover,'snapshotSeconds':snapshot_elapsed,'otherStateSeconds':state_elapsed,'sameMcpStateSeconds':shared_elapsed,'openBefore':before.get('open'),'openAfter':after.get('open'),'humanBefore':before.get('humanControl'),'humanAfter':after.get('humanControl'),'error':after.get('error'),'snapshotError':result.get('isError')}),flush=True)
  assert state_elapsed<.5 and shared_elapsed<.5,(state_elapsed,shared_elapsed)
  assert after['open'] and after['humanControl']==takeover,(before,after)
  assert c.details('desktop_state',{'desktop':dc['desktop']})['occupied']
  assert a.details('desktop_state',{'desktop':shared['desktop']})['occupied']
  if after.get('open'):shell('desktop','observe','main')
 # Test actual native mutation retry history while a helper is in flight.
 # The token stays inside this private test bus; it is never printed.
 (BASE/'slow.flag').unlink(missing_ok=True)
 binding=bind(da['name']);lease=json.loads(binding.read_text())
 def raw_request(method,params,id):
  return {'id':id,'method':method,'params':params,'token':lease['token'],'controller':'native-response-test','harness':'test'}
 def connect_request(request):
  peer=socket.socket(socket.AF_UNIX);peer.settimeout(6);peer.connect(lease['socket'])
  peer.sendall((json.dumps(request)+'\n').encode());return peer
 def response(peer):
  data=b''
  while b'\n' not in data:data+=peer.recv(65536)
  return json.loads(data.split(b'\n')[0])
 def native(method,params,id):
  with connect_request(raw_request(method,params,id)) as peer:return response(peer)
 def nodes(tree):
  yield tree
  for child in tree.get('children',[]):yield from nodes(child)
 tree=native('desktop.snapshot',{'maxNodes':20},'native-tree-1');assert tree['ok'],tree
 button=next(n for n in nodes(tree['result']['tree']) if n.get('name')=='Record slow click')
 request=raw_request('desktop.action',{'snapshotId':tree['result']['snapshotId'],'elementRef':button['elementRef'],'action':'click'},'native-click-1')
 with connect_request(request) as first,connect_request(request) as duplicate:
  replies=[response(first),response(duplicate)]
 assert sum(r['ok'] for r in replies)==1,replies
 assert any('in progress' in r.get('error','') for r in replies),replies
 wait(lambda:(BASE/'slow.click').exists() and (BASE/'slow.click').read_text()=='1')
 with connect_request(request) as retry:assert response(retry)['ok']
 time.sleep(.2);assert (BASE/'slow.click').read_text()=='1'
 record('in-flight duplicate native mutation rejects clearly; retry after completion returns the real result without a second click')
 # Revocation can be processed while the native helper waits on the app.
 tree=native('desktop.snapshot',{'maxNodes':20},'native-tree-2');assert tree['ok'],tree
 button=next(n for n in nodes(tree['result']['tree']) if n.get('name')=='Record slow click')
 request=raw_request('desktop.action',{'snapshotId':tree['result']['snapshotId'],'elementRef':button['elementRef'],'action':'click'},'native-cancelled-click')
 window=next(w for w in ctl('clients',True) if w['title']=='slow-native-window')
 os.kill(window['pid'],signal.SIGSTOP)
 peer=connect_request(request);time.sleep(.1);peer.close()
 time.sleep(.25);os.kill(window['pid'],signal.SIGCONT)
 with connect_request(request) as retry:cancelled=response(retry)
 assert not cancelled['ok'] and 'uncertain' in cancelled['error'],cancelled
 time.sleep(.2);assert (BASE/'slow.click').read_text()=='1'
 record('owner disconnection cancels an in-flight helper and records uncertainty; retry cannot duplicate the native action')
 # Replacing a binding while a helper waits retires its token and retry history.
 tree=native('desktop.snapshot',{'maxNodes':20},'native-tree-3');assert tree['ok'],tree
 button=next(n for n in nodes(tree['result']['tree']) if n.get('name')=='Record slow click')
 request=raw_request('desktop.action',{'snapshotId':tree['result']['snapshotId'],'elementRef':button['elementRef'],'action':'click'},'native-revoked-click')
 os.kill(window['pid'],signal.SIGSTOP)
 with connect_request(request) as peer:
  time.sleep(.1);new_binding=bind(da['name']);revoked=response(peer)
 os.kill(window['pid'],signal.SIGCONT)
 assert not revoked['ok'] and 'binding revoked' in revoked['error'] and 'uncertain' in revoked['error'],revoked
 with connect_request(request) as retry:retired=response(retry)
 assert not retired['ok'] and 'binding' in retired['error'].lower(),retired
 lease=json.loads(new_binding.read_text())
 assert native('desktop.snapshot',{'maxNodes':20},'native-tree-after-revoke')['ok']
 time.sleep(.2);assert (BASE/'slow.click').read_text()=='1'
 record('binding revocation cancels an in-flight helper; retired tokens are rejected and a replacement binding remains usable')
 a.close();c.close()
 print('Response artifacts:',BASE,flush=True)
finally:cleanup()
