"""Actual stdio MCP test client with newline-buffered protocol reads."""
from desktop_harness import *

class MCP:
 def __init__(self,label,without_session=False):
  env=dict(ENV)
  for key in ('CORNICE_AGENT_JOB','CORNICE_MCP_BINDING'):env.pop(key,None)
  if without_session:env.pop('HYPRLAND_INSTANCE_SIGNATURE',None)
  self.p=subprocess.Popen([str(PRODUCT/'bin/cornice-desktop-mcp')],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/(label+'.log'),'w'),text=True,start_new_session=True)
  PROCESSES.append(self.p);self.number=0;self.input=b"";self.replies={}
  self.request('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':label,'version':'1'}})
  self.p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');self.p.stdin.flush()
 def send(self,method,params):
  self.number+=1;self.p.stdin.write(json.dumps({'jsonrpc':'2.0','id':self.number,'method':method,'params':params})+'\n');self.p.stdin.flush();return self.number
 def receive(self,number):
  deadline=time.monotonic()+35
  while number not in self.replies:
   # Consume complete buffered lines before select. TextIO.readline may prefetch
   # a reply behind a notification even when the descriptor is no longer ready.
   while b'\n' not in self.input:
    remaining=deadline-time.monotonic()
    assert remaining>0 and select.select([self.p.stdout],[],[],remaining)[0],('MCP timeout',number)
    chunk=os.read(self.p.stdout.fileno(),65536);assert chunk,('MCP exited',self.p.poll())
    self.input+=chunk
   line,self.input=self.input.split(b'\n',1)
   value=json.loads(line)
   if 'id' in value:self.replies[value['id']]=value
  value=self.replies.pop(number)
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
