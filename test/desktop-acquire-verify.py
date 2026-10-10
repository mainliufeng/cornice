"""Real automatic desktop allocation, shared MCP tasks and browser isolation."""
from desktop_harness import *
from urllib.parse import quote
import re
ENV.pop("NO_AT_BRIDGE",None)

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

try:
 broker=initialize()
 defaults=cli('list')['desktops']
 assert len(defaults)==2 and {d['number'] for d in defaults}=={1,2},defaults
 initial=next(d for d in defaults if not d['primary'])
 assert initial['name']=='desktop2' and initial['paused'] and not initial['occupied'] and initial['activity']=='idle'
 assert cli('windows','desktop2')['windows']==[]
 record('fresh session initializes exactly primary plus one empty secondary; no extra agent desktops are preallocated')
 start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window',BASE/'human.txt'],'human')
 wait(lambda:len(ctl('clients',True))==1);baseline=human_state()
 cli('create','disabled','--virtual-output','1280x800');cli('allow-agent','disabled','off')
 a=MCP('codex-like',True);b=MCP('pi-like')
 tools=a.request('tools/list',{})['tools'];assert len(tools)==27
 assert 'desktop_acquire' in {x['name'] for x in tools}
 assert 'desktop_acquire first' in str(a.call('desktop_state',success=False))
 assert 'disabled' in str(a.call('desktop_acquire',{'preferredDesktop':'main'},False))
 assert 'does not exist' in str(a.call('desktop_acquire',{'preferredDesktop':'missing'},False))
 record('plugin connection alone grants no desktop; primary remains disabled and missing explicit target fails')
 # Both requests are queued before receiving either answer: allocation is atomic.
 ia=a.send('tools/call',{'name':'desktop_acquire','arguments':{}})
 ib=b.send('tools/call',{'name':'desktop_acquire','arguments':{}})
 first=a.receive(ia);second=b.receive(ib)
 assert not first.get('isError') and not second.get('isError'),(first,second)
 first=first['structuredContent'];second=second['structuredContent']
 assert first['name']=='desktop2' and not first['created']
 assert second['name']!='desktop2' and second['created'] and not second['primary']
 assert first['pixelSize']==second['pixelSize']==[1280,800]
 assert first['harness']=='codex' and second['harness']=='pi'
 assert first['occupied'] and second['occupied'] and first['activity']==second['activity']=='running'
 assert next(d for d in cli('list')['desktops'] if d['name']==first['name'])['harness']=='codex'
 assert human_state()==baseline and cli('state','disabled')['paused']
 assert not any(key in first for key in ('token','socket'))
 record('simultaneous independent harnesses atomically reuse an idle seat and create a fresh private desktop; GUI-app endpoint works without compositor environment')
 third=a.details('desktop_acquire',{'preferredDesktop':'desktop2'})
 assert third['created'] and third['name'] not in (first['name'],second['name'])
 record('an occupied requested desktop creates a new desktop; two tasks in one MCP process retain distinct references')
 for client,state,text in ((a,first,'甲桌面'),(b,second,'乙桌面'),(a,third,'丙桌面')):
  ref=state['desktop'];name=state['name'];path=BASE/(name+'.txt')
  client.call('desktop_launch',{'desktop':ref,'argv':['/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),name+'-window',str(path)]})
  wait(lambda:next((w for w in ctl('clients',True) if w['title']==name+'-window'),None))
  image=client.call('desktop_capture',{'desktop':ref})
  frame=image['structuredContent']
  (BASE/(name+'-native.jpg')).write_bytes(base64.b64decode(next(item['data'] for item in image['content'] if item['type']=='image')))
  client.call('desktop_input',{'desktop':ref,'frameId':frame['frameId'],'action':'text','text':text})
  wait(lambda:path.exists() and path.read_text()==text)
 assert human_state()==baseline
 # Real native trees are exposed through the same MCP and retain task scope.
 def nodes(tree):
  yield tree
  for child in tree.get('children',[]):yield from nodes(child)
 tree=a.details('desktop_snapshot',{'desktop':first['desktop']})
 assert tree['source']=='atspi' and tree['nodeCount']>2,tree
 entry=next(n for n in nodes(tree['tree']) if 'editable' in n.get('states',[]))
 action={'snapshotId':tree['snapshotId'],'elementRef':entry['elementRef'],'action':'setText','text':'MCP 原生元素输入'}
 assert a.call('desktop_action',{'desktop':first['desktop'],**{k:v for k,v in action.items() if k!='text'}},False)['isError']
 assert b.call('desktop_action',{'desktop':second['desktop'],**action},False)['isError']
 a.call('desktop_action',{'desktop':first['desktop'],**action})
 wait(lambda:(BASE/(first['name']+'.txt')).read_text()=='MCP 原生元素输入')
 assert a.call('desktop_action',{'desktop':first['desktop'],**action},False)['isError']
 tree=a.details('desktop_snapshot',{'desktop':first['desktop']})
 button=next(n for n in nodes(tree['tree']) if n.get('name')=='Record a click')
 a.call('desktop_action',{'desktop':first['desktop'],'snapshotId':tree['snapshotId'],'elementRef':button['elementRef'],'action':'click'})
 wait(lambda:(BASE/(first['name']+'.click')).exists())
 stale=a.details('desktop_snapshot',{'desktop':first['desktop']})
 staleEntry=next(n for n in nodes(stale['tree']) if 'editable' in n.get('states',[]))
 a.call('desktop_workspace',{'desktop':first['desktop'],'slot':2})
 assert a.call('desktop_action',{'desktop':first['desktop'],'snapshotId':stale['snapshotId'],'elementRef':staleEntry['elementRef'],'action':'setText','text':'wrong workspace'},False)['isError']
 a.call('desktop_workspace',{'desktop':first['desktop'],'slot':1})
 assert human_state()==baseline
 record('real native AT-SPI tree, Unicode setText and click work through MCP; cross-task, mutated and workspace-stale references fail closed')
 assert 'desktop_acquire first' in str(a.call('desktop_capture',success=False))
 assert 'desktop_acquire first' in str(a.call('desktop_capture',{'desktop':second['desktop']},False))
 record('real GTK Unicode input is isolated across all references, and missing or foreign references never fall back')
 # Independent browser clients even when sharing one Cornice MCP process.
 url=lambda title:'data:text/html,'+quote('<title>'+title+'</title><label>Answer<input aria-label="Answer"></label>')
 for state,title in ((first,'Task A'),(third,'Task C')):
  ref=state['desktop'];a.call('desktop_browser_connect',{'desktop':ref});a.call('browser_navigate',{'desktop':ref,'url':url(title)})
  tree=str(a.call('browser_snapshot',{'desktop':ref}));target=re.search(r'textbox "Answer" \[ref=([^\]]+)\]',tree).group(1)
  a.call('browser_type',{'desktop':ref,'target':target,'text':title+' 中文'})
 assert 'Task A 中文' in str(a.call('browser_snapshot',{'desktop':first['desktop']}))
 assert 'Task C 中文' in str(a.call('browser_snapshot',{'desktop':third['desktop']}))
 record('two tasks sharing one MCP retain independent managed Chrome pages, trees and semantic input')
 a.call('desktop_workspace',{'desktop':first['desktop'],'slot':2})
 a.call('desktop_finish',{'desktop':first['desktop'],'outcome':'completed','reason':'actual form and native input verified'})
 assert cli('state',first['name'])['paused']
 assert not a.details('desktop_state',{'desktop':third['desktop']})['paused']
 assert 'finished' in str(a.call('desktop_launch',{'desktop':first['desktop'],'argv':['false']},False))
 blank=b.details('desktop_acquire',{'createNew':True})
 assert blank['created'] and blank['name'] not in (first['name'],second['name'],third['name'])
 assert b.details('desktop_windows',{'desktop':blank['desktop']})['windows']==[]
 b.call('desktop_finish',{'desktop':blank['desktop'],'outcome':'completed','reason':'fresh desktop verified'})
 record('explicit createNew allocates a genuinely empty desktop even while an unoccupied desktop is available')
 fourth=b.details('desktop_acquire')
 assert not fourth['created'] and fourth['name']==first['name']
 assert any(w['title']==first['name']+'-window' for w in ctl('clients',True))
 b.call('desktop_workspace',{'desktop':fourth['desktop'],'slot':1})
 b.call('desktop_browser_connect',{'desktop':fourth['desktop']})
 tabs=str(b.call('browser_tabs',{'desktop':fourth['desktop'],'action':'list'}))
 tab=re.search(r'- (\d+):[^\n]*\[Task A\]',tabs)
 assert tab,tabs
 b.call('browser_tabs',{'desktop':fourth['desktop'],'action':'select','index':int(tab.group(1))})
 assert 'Task A 中文' in str(b.call('browser_snapshot',{'desktop':fourth['desktop']}))
 record('finish releases one task without interrupting another; released desktops are reused with native applications and browser content preserved across workspaces')
 cli('allow-agent',third['name'],'off')
 assert a.call('desktop_capture',{'desktop':third['desktop']},False)['isError']
 a.call('desktop_finish',{'desktop':third['desktop'],'outcome':'blocked','reason':'operator revoked permission'})
 assert not b.details('desktop_state',{'desktop':second['desktop']})['paused']
 # Explicit primary acquisition is possible only after the operator enables it.
 cli('allow-agent','main','on')
 primary=b.details('desktop_acquire',{'preferredDesktop':'main'})
 assert primary['primary'] and primary['name']=='main'
 b.call('desktop_finish',{'desktop':primary['desktop'],'outcome':'completed','reason':'explicit enabled primary allocation verified'})
 cli('allow-agent','main','off')
 record('primary selection requires explicit name and operator-enabled permission; release returns native primary input')
 a.close();b.close()
 wait(lambda:cli('state',second['name'])['paused'] and cli('state',fourth['name'])['paused'])
 assert human_state()==baseline
 record('permission revocation cannot be bypassed by a stale reference; connection closure pauses and releases only its own tasks')
 reuse=MCP('reuse');empty=reuse.details('desktop_acquire');assert empty['name']==fourth['name'] and not empty['created']
 os.kill(reuse.p.pid,signal.SIGSTOP)
 wait(lambda:cli('state',empty['name'])['paused'],timeout=9)
 reclaimed=MCP('reclaimed');fresh=reclaimed.details('desktop_acquire')
 assert fresh['name']==empty['name'] and fresh['desktop']!=empty['desktop']
 os.kill(reuse.p.pid,signal.SIGCONT)
 assert reuse.call('desktop_capture',{'desktop':empty['desktop']},False)['isError'];reuse.close()
 assert not reclaimed.details('desktop_state',{'desktop':fresh['desktop']})['paused']
 record('expired heartbeat releases occupancy; late old-owner actions and disconnection cannot stop the replacement owner')
 # A real native session lock denies fresh allocation and invalidates old input.
 for mode,ext in (('client-header','h'),('private-code','c')):
  subprocess.run(['wayland-scanner',mode,'/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml',str(BASE/('session-lock.'+ext))],check=True)
 subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/lock.c'),str(BASE/'session-lock.c'),'-o',str(BASE/'full-lock'),*subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client'],text=True).split()],check=True)
 locker=subprocess.Popen([str(BASE/'full-lock'),'human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'lock.log','w'),text=True,start_new_session=True);PROCESSES.append(locker)
 assert select.select([locker.stdout],[],[],5)[0] and locker.stdout.readline().strip()=='ready'
 wait(lambda:ctl('locked',True)['locked'])
 assert 'Unlock' in str(reclaimed.call('desktop_acquire',success=False))
 assert reclaimed.call('desktop_capture',{'desktop':fresh['desktop']},False)['isError']
 reclaimed.call('desktop_finish',{'desktop':fresh['desktop'],'outcome':'blocked','reason':'session locked'})
 locker.stdin.write('unlock\n');locker.stdin.flush();locker.wait(timeout=5)
 wait(lambda:not ctl('locked',True)['locked']);reclaimed.close()
 record('real session lock denies new acquisition and invalidates old control; cleanup neither unlocks nor resumes')
 print('PASS automatic task-owned desktop integration',flush=True)
finally:
 cleanup()
