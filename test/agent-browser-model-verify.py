"""Actual configured model operates its seat browser through Playwright MCP without images."""
from desktop_harness import *
import fcntl, re
from urllib.parse import quote

def runtime(command,*args,prompt=None):
 p=subprocess.run([str(PRODUCT/'bin/cornice-agent-runtime'),command,*args],input=prompt,env=ENV,text=True,capture_output=True,timeout=20)
 assert p.returncode==0,p.stderr
 return json.loads(p.stdout)
try:
 initialize()
 start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window',BASE/'human.txt'],'human-client')
 wait(lambda: any(w['title']=='human-window' for w in ctl('clients',True)))
 human=human_state()
 cli('create','browsermodel','--workspace','11','--virtual-output','1280x800','--human-lock-policy','continue')
 cli('resume','browsermodel')
 page='<title>Agent browser test</title><label>Agent text<input aria-label="Agent text"></label><button onclick="document.getElementById(\'result\').textContent=document.querySelector(\'input\').value">Verify</button><p id="result"></p>'
 url='data:text/html,'+quote(page)
 prompt='用你自己桌面的浏览器打开这个测试页面 '+url+' 。把 Agent text 输入框填写为 seat CDP中文，点 Verify，核实页面显示此结果再提交 completed。优先读取元素树；这是普通表单，无需截图。只操作此测试页面。'
 accepted=runtime('start','browsermodel',prompt=prompt)
 directory=RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']/'jobs/browsermodel'
 terminal=('completed','cancelled','blocked','failed','needs_attention')
 value=wait(lambda: (v if (v:=runtime('status','browsermodel'))['phase'] in terminal else None),timeout=220)
 assert value['phase']=='completed',value
 def released():
  with open(directory/'lock','a') as lock:
   try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
   except BlockingIOError:return False
   return True
 wait(released)
 events=[json.loads(line) for line in (directory/'events.jsonl').read_text().splitlines()]
 results=[e for e in events if e.get('type')=='tool_execution_end']
 names=[e['toolName'] for e in results]
 images=sum(sum(c.get('type')=='image' for c in e.get('result',{}).get('content',[])) for e in results)
 assert images==0,(images,names)
 assert 'desktop_browser_connect' in names and any(n.endswith('browser_click') for n in names) and any(n.endswith('browser_fill_form') or n.endswith('browser_type') for n in names),names
 assert any(re.search(r'paragraph \[ref=[^\]]+\]: seat CDP中文', json.dumps(e.get('result',{}),ensure_ascii=False)) for e in results if e['toolName'].endswith('browser_snapshot'))
 assert human_state()==human,(human,human_state())
 assert not any(e.get('type')=='extension_error' for e in events),[e for e in events if e.get('type')=='extension_error']
 result={'model':value['model'],'phase':value['phase'],'tools':names,'images':images,'humanUnchanged':True,'verifiedReason':value['message']}
 (BASE/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
 print(json.dumps(result,ensure_ascii=False,indent=2),flush=True)
 record('real Pi+configured model uses seat-bound Playwright MCP tree, fill, click and verification with zero screenshots')
finally:
 cleanup()
