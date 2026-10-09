"""Real primary/secondary desktops and shared MCP in an isolated compositor."""
from desktop_harness import *
from urllib.parse import quote

class MCP:
 def __init__(self, binding=None, title='mcp'):
  env=dict(ENV)
  if binding: env['CORNICE_MCP_BINDING']=str(binding)
  self.p=subprocess.Popen([str(PRODUCT/'bin/cornice-desktop-mcp')],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/(title+'.log'),'w'),text=True,start_new_session=True)
  PROCESSES.append(self.p);self.number=0
  self.request('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'cornice-integration','version':'1'}})
  self.p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');self.p.stdin.flush()
 def request(self,method,params):
  self.number+=1
  self.p.stdin.write(json.dumps({'jsonrpc':'2.0','id':self.number,'method':method,'params':params})+'\n');self.p.stdin.flush()
  while True:
   assert select.select([self.p.stdout],[],[],25)[0], ('MCP timeout',method)
   line=self.p.stdout.readline()
   assert line,('MCP exited',self.p.poll(),method)
   reply=json.loads(line)
   if reply.get('id')==self.number:
    assert 'error' not in reply,reply
    return reply['result']
 def call(self,name,arguments=None,success=True):
  result=self.request('tools/call',{'name':name,'arguments':arguments or {}})
  assert bool(result.get('isError')) != success,(name,result)
  return result
 def details(self,name,params=None):return self.call(name,params).get('structuredContent',{})
 def close(self):
  if self.p.poll() is None:
   self.p.stdin.close();self.p.wait(timeout=8)

try:
 broker=initialize()
 primary=cli('list')['desktops'][0]
 assert primary['name']=='main' and primary['number']==1 and primary['primary'] and primary['agentAllowed'] is False
 assert 'disabled' in cli('resume','main',succeeds=False)
 assert 'disabled' in cli('bind','main',BASE/'forbidden.binding',succeeds=False)
 record('desktop 1 is the real primary seat, Agent permission defaults off and cannot be bound')
 for name in ('agent1','agent2'):
  cli('create',name,'--virtual-output','1280x800');cli('resume',name)
 assert [d['number'] for d in cli('list')['desktops']]==[1,2,3]
 start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window',BASE/'human.txt'],'human')
 for name in ('agent1','agent2'):
  cli('launch',name,'--','/usr/bin/python3',ROOT/'test/agent-desktop-client.py',name+'-window',BASE/(name+'.txt'))
 wait(lambda:len(ctl('clients',True))==3)
 ok('dispatch hl.dsp.focus({window="title:^human-window$"})')
 baseline=human_state()
 no_assignment=MCP(title='unassigned')
 tools=no_assignment.request('tools/list',{})['tools'];names={t['name'] for t in tools}
 assert len(names)==23 and {'desktop_state','desktop_browser_connect','browser_snapshot'} <= names
 assert not any(name in names for name in ('browser_evaluate','browser_file_upload','browser_run_code_unsafe','desktop_resume','desktop_bind'))
 assert 'No desktop assigned' in str(no_assignment.call('desktop_state',success=False))
 no_assignment.close()
 record('real MCP lists 23 bounded tools and never falls back to any desktop when unassigned')
 assignment=cli('attach','agent1','codex')['bindingFile']
 mcp=MCP(assignment,title='assigned')
 state=mcp.details('desktop_state');assert state['name']=='agent1' and state['number']==2
 captured=mcp.call('desktop_capture');frame=captured['structuredContent']
 image=next(c for c in captured['content'] if c['type']=='image')
 assert image['mimeType']=='image/jpeg' and base64.b64decode(image['data'])[:2]==b'\xff\xd8'
 assert 'imageBase64' not in frame and frame['pixelSize']==[1280,800]
 mcp.details('desktop_input',{'frameId':frame['frameId'],'action':'text','text':'MCP 中文输入'})
 wait(lambda:(BASE/'agent1.txt').read_text()=='MCP 中文输入')
 assert human_state()==baseline
 other=MCP(assignment,title='competing')
 assert 'Another harness' in str(other.call('desktop_state',success=False));other.close()
 assert mcp.details('desktop_state')['name']=='agent1'
 record('standard MCP image/metadata and Unicode input operate only desktop 2; competing harness rejected')
 mcp.details('desktop_workspace',{'slot':2})
 assert mcp.details('desktop_state')['workspace'].endswith('-ws-2') and human_state()==baseline
 mcp.details('desktop_workspace',{'workspace':'11'})
 stale=mcp.call('desktop_input',{'frameId':frame['frameId'],'action':'text','text':'WRONG'},success=False)
 assert 'stale' in str(stale).lower()
 record('same workspace API supports slots and explicit identifiers, and stale input is rejected')
 mcp.details('desktop_browser_connect')
 url='data:text/html,'+quote('<title>Unified MCP</title><label>Answer<input aria-label="Answer"></label><button onclick="document.getElementById(\'result\').textContent=document.querySelector(\'input\').value">Verify</button><p id="result"></p>')
 mcp.call('browser_navigate',{'url':url})
 snapshot=mcp.call('browser_snapshot')
 import re
 tree='\n'.join(c.get('text','') for c in snapshot['content'])
 entry=re.search(r'textbox "Answer" \[ref=([^\]]+)\]',tree).group(1)
 button=re.search(r'button "Verify" \[ref=([^\]]+)\]',tree).group(1)
 mcp.call('browser_type',{'element':'Answer','target':entry,'text':'统一桌面','submit':False})
 mcp.call('browser_click',{'element':'Verify','target':button})
 tree=str(mcp.call('browser_snapshot'))
 assert '统一桌面' in tree and 'REDACTED' not in url
 assert not any(c.get('type')=='image' for c in snapshot['content'])
 assert human_state()==baseline
 record('the same MCP proxies real authorized browser trees, form input and click with no screenshot')
 cli('allow-agent','agent1','off')
 assert mcp.call('browser_snapshot',success=False)['isError']
 assert mcp.call('desktop_capture',success=False)['isError']
 assert cli('state','agent1')['agentAllowed'] is False
 mcp.close()
 cli('allow-agent','main','on')
 main_binding=cli('attach','main','codex')['bindingFile']
 main=MCP(main_binding,title='main-mcp')
 state=main.details('desktop_state');assert state['primary'] and state['controlMode']=='agent'
 shot=main.call('desktop_capture');frame=shot['structuredContent']
 (BASE/'primary-mcp.jpg').write_bytes(base64.b64decode(next(c['data'] for c in shot['content'] if c['type']=='image')))
 main.call('desktop_input',{'frameId':frame['frameId'],'action':'click','x':100,'y':105})
 frame=main.details('desktop_capture')
 main.call('desktop_input',{'frameId':frame['frameId'],'action':'text','text':'Primary MCP 中文'})
 wait(lambda:(BASE/'human.txt').read_text()=='Primary MCP 中文')
 before_agent=cli('state','agent2')
 main.call('desktop_workspace',{'slot':2});assert cli('state','main')['workspace']=='2'
 main.call('desktop_workspace',{'workspace':'1'});assert cli('state','main')['workspace']=='1'
 assert cli('state','agent2')==before_agent
 record('enabled primary desktop uses identical MCP capture/input/workspace tools with native primary devices')
 main.call('desktop_browser_connect');main.call('browser_navigate',{'url':url})
 tree=str(main.call('browser_snapshot'))
 target=re.search(r'textbox "Answer" \[ref=([^\]]+)\]',tree).group(1)
 button=re.search(r'button "Verify" \[ref=([^\]]+)\]',tree).group(1)
 main.call('browser_type',{'target':target,'text':'Primary browser 中文'})
 main.call('browser_click',{'target':button})
 assert 'Primary browser 中文' in str(main.call('browser_snapshot'))
 assert cli('state','agent2')==before_agent
 record('primary desktop browser uses the same authorized CDP trees and semantic actions without affecting another desktop')
 # An existing non-Broker primary device models native input without touching
 # host devices. It is never tagged with the Broker's control generation.
 for source, name in (('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')):
  for mode, extension in (('client-header','h'),('private-code','c')):
   subprocess.run(['wayland-scanner',mode,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+extension))],check=True)
 flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
 subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'human-input'),*flags],check=True)
 keyboard=subprocess.Popen([str(BASE/'human-input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'primary-native.log','w'),text=True,start_new_session=True)
 PROCESSES.append(keyboard)
 assert select.select([keyboard.stdout],[],[],5)[0]
 ready=keyboard.stdout.readline().strip();assert ready=='ready',ready
 keyboard.stdin.write('key 30 1\n');keyboard.stdin.flush()
 assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='done'
 wait(lambda:cli('state','main')['paused'])
 assert main.call('desktop_input',{'frameId':frame['frameId'],'action':'text','text':'WRONG'},success=False)['isError']
 record('native primary input revokes Agent control before the event; stale input can no longer race the user')
 main.close();keyboard.terminate();keyboard.wait(timeout=5)
 cli('allow-agent','main','off')
 assert cli('state','main')['controlMode']=='human'
 cli('allow-agent','agent2','on');assignment=cli('attach','agent2','codex')['bindingFile']
 doomed=MCP(assignment,title='doomed');doomed.details('desktop_state')
 os.kill(doomed.p.pid,signal.SIGKILL);doomed.p.wait(timeout=5)
 wait(lambda:cli('state','agent2')['paused'],timeout=9)
 record('lost MCP heartbeat automatically revokes desktop input')
 assignment=cli('attach','agent2','codex')['bindingFile'];detached=MCP(assignment,title='detached')
 detached.details('desktop_state');cli('detach','codex')
 assert not pathlib.Path(assignment).exists() and cli('state','agent2')['paused']
 detached.call('desktop_capture',success=False);detached.close()
 record('operator detach revokes an active MCP owner and removes the private assignment')
 cli('allow-agent','main','on');assignment=cli('attach','main','codex')['bindingFile']
 locked=MCP(assignment,title='locked-main');locked.details('desktop_state')
 for mode, extension in (('client-header','h'),('private-code','c')):
  subprocess.run(['wayland-scanner',mode,'/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml',str(BASE/('session-lock.'+extension))],check=True)
 subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/lock.c'),str(BASE/'session-lock.c'),'-o',str(BASE/'full-lock'),*subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client'],text=True).split()],check=True)
 locker=subprocess.Popen([str(BASE/'full-lock'),'human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'primary-lock.log','w'),text=True,start_new_session=True);PROCESSES.append(locker)
 assert select.select([locker.stdout],[],[],5)[0] and locker.stdout.readline().strip()=='ready'
 wait(lambda:ctl('locked',True)['locked'])
 wait(lambda:cli('state','main')['paused'])
 locked.call('desktop_capture',success=False)
 assert 'Unlock' in cli('allow-agent','main','off',succeeds=False)
 locker.stdin.write('unlock\n');locker.stdin.flush();locker.wait(timeout=5)
 wait(lambda:not ctl('locked',True)['locked']);assert cli('state','main')['paused'];locked.close()
 record('session lock revokes primary MCP and prevents permission changes; unlock does not restore control')
 broker.terminate();broker.wait(timeout=5)
 restarted=start([str(PRODUCT/'bin/cornice'),'desktop','serve'],'desktop-restarted')
 wait(lambda:subprocess.run([str(PRODUCT/'bin/cornice'),'desktop','doctor'],env=ENV,capture_output=True).returncode==0)
 assert cli('state','main')['agentAllowed'] is False
 assert cli('state','agent1')['agentAllowed'] is False
 record('Broker restart resets primary permission off and preserves secondary permission choices')
 print('PASS unified desktop MCP integration',flush=True)
finally:
 cleanup()
