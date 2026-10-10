import os,json,subprocess,select,time,tempfile
from pathlib import Path
root=str(Path(__file__).resolve().parent.parent)
home=tempfile.mkdtemp(prefix='cornice-codex-plugin-')
env=dict(os.environ,CODEX_HOME=home,PATH=root+'/bin:'+os.environ['PATH'])
subprocess.run(['codex','plugin','marketplace','add',root],env=env,check=True,capture_output=True)
subprocess.run(['codex','plugin','add','cornice@cornice-local','--json'],env=env,check=True,capture_output=True)
p=subprocess.Popen(['codex','app-server','--stdio'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(str(Path(home)/'server.log'),'w'),text=True)
number=0
def request(method,params):
 global number
 number+=1;p.stdin.write(json.dumps(dict(jsonrpc='2.0',id=number,method=method,params=params))+'\n');p.stdin.flush()
 end=time.monotonic()+35
 while time.monotonic()<end:
  if not select.select([p.stdout],[],[],1)[0]:continue
  line=p.stdout.readline()
  if not line:raise RuntimeError('server exited')
  value=json.loads(line)
  if value.get('id')==number:
   if 'error' in value:raise RuntimeError(value['error'])
   return value['result']
 raise RuntimeError('request timeout '+method)
try:
 request('initialize',{'clientInfo':{'name':'cornice-plugin-verifier','version':'1'},'capabilities':{'experimentalApi':True}})
 p.stdin.write('{"method":"initialized"}\n');p.stdin.flush()
 skills=request('skills/list',{'cwds':[root],'forceReload':True})
 skill=next(item for entry in skills['data'] for item in entry['skills'] if item.get('pluginId')=='cornice@cornice-local')
 assert skill['enabled'] and skill['name']=='cornice:cornice-desktop'
 assert '/0.3.0/' in skill['path']
 assert Path(skill['path']).read_text()==(Path(root)/'plugins/cornice/skills/cornice-desktop/SKILL.md').read_text()
 result=request('mcpServerStatus/list',{})
 server=next(item for item in result['data'] if item['pluginId']=='cornice@cornice-local')
 assert server['toolsError'] is None and len(server['tools'])==26
 assert server['serverInfo']['name']=='cornice-desktop'
 assert server['serverInfo']['version']=='0.3.0',server['serverInfo']
 assert {'desktop_acquire','desktop_snapshot','desktop_action'} <= set(server['tools'])
 assert json.loads((Path(root)/'plugins/cornice/.mcp.json').read_text())['mcpServers']['cornice']['env']=={'CORNICE_HARNESS':'codex'}
 report={'skill':skill['name'],'plugin':server['pluginId'],'tools':sorted(server['tools']),'artifacts':home}
 (Path(home)/'result.json').write_text(json.dumps(report,indent=2))
 print('PASS actual Codex plugin install, canonical skill discovery and 26 live shared MCP tools; '+home)
finally:
 p.stdin.close()
 try:p.wait(timeout=8)
 except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=5)
