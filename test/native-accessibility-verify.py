"""Real GTK and Qt AT-SPI trees on private outputs and a private D-Bus."""
from desktop_harness import *
ENV.pop('NO_AT_BRIDGE',None)
ENV.pop('QT_LINUX_ACCESSIBILITY_ALWAYS_ON',None)
ENV.pop('QT_ACCESSIBILITY',None)
HELPER=PRODUCT/'native/bin/cornice-native-accessibility'

def invoke(window, **params):
 request={'operation':'snapshot','window':window,**params}
 if request['operation']=='action':
  seat='tree-a' if window.get('title')=='native-gtk-window' else 'tree-b'
  request.setdefault('authorization',{**ctl('seat state '+seat,True),'instance':ENV['HYPRLAND_INSTANCE_SIGNATURE']})
 result=subprocess.run([str(HELPER)],input=json.dumps(request),env=ENV,text=True,capture_output=True,timeout=6)
 (BASE/'helper.log').write_text(result.stderr)
 return json.loads(result.stdout)

def flatten(node):
 yield node
 for child in node.get('children',[]):yield from flatten(child)

try:
 initialize()
 for key in ('IsEnabled','ScreenReaderEnabled'):
  subprocess.run(['gdbus','call','--session','--dest','org.a11y.Bus','--object-path','/org/a11y/bus','--method','org.freedesktop.DBus.Properties.Set','org.a11y.Status',key,'<false>'],env=ENV,check=True,capture_output=True)
 cli('create','tree-a','--virtual-output','1280x800')
 cli('create','tree-b','--virtual-output','1280x800')
 cli('resume','tree-a');cli('resume','tree-b')
 start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window',BASE/'human.txt'],'human')
 cli('launch','tree-a','--','/usr/bin/python3',ROOT/'test/agent-desktop-client.py','native-gtk-window',BASE/'gtk.txt')
 cli('launch','tree-b','--',pathlib.Path(os.environ['TMPDIR'])/'native-accessibility-qt',BASE/'qt.txt')
 windows=wait(lambda:ctl('clients',True) if len(ctl('clients',True))==3 else None)
 for key in ('IsEnabled','ScreenReaderEnabled'):
  value=subprocess.check_output(['gdbus','call','--session','--dest','org.a11y.Bus','--object-path','/org/a11y/bus','--method','org.freedesktop.DBus.Properties.Get','org.a11y.Status',key],env=ENV,text=True)
  assert 'false' in value,(key,value)
 record('GTK and Qt are already mapped while accessibility IsEnabled and ScreenReaderEnabled remain false')
 human=human_state()
 for title,file,button_name in [('native-qt-window','qt.txt','Qt Record a click'),('native-gtk-window','gtk.txt','Record a click')]:
  window=next(w for w in windows if w['title']==title)
  def ready():
   result=invoke(window)
   (BASE/(file+'.last.json')).write_text(json.dumps(result))
   return result if result.get('ok') else None
  snapshot=wait(ready)
  if title=='native-qt-window':
   for key in ('IsEnabled','ScreenReaderEnabled'):
    value=subprocess.check_output(['gdbus','call','--session','--dest','org.a11y.Bus','--object-path','/org/a11y/bus','--method','org.freedesktop.DBus.Properties.Get','org.a11y.Status',key],env=ENV,text=True)
    assert 'true' in value,(key,value)
  (BASE/(file+'.tree.json')).write_text(json.dumps(snapshot,ensure_ascii=False,indent=2))
  nodes=list(flatten(snapshot['tree']))
  assert snapshot['nodeCount']==len(nodes) and snapshot['nodeCount']>2,snapshot
  assert 'human-window' not in str(snapshot) and ('native-qt-window' if 'gtk' in title else 'native-gtk-window') not in str(snapshot)
  entry=next(node for node in nodes if 'editable' in node.get('states',[]) and node['role']!='password text')
  button=next(node for node in nodes if node.get('name')==button_name and node.get('actions'))
  typed=invoke(window,operation='action',identity=entry['identity'],action='setText',text='真实元素树 中文')
  assert typed.get('ok'),typed
  wait(lambda:(BASE/file).exists() and (BASE/file).read_text()=='真实元素树 中文')
  # Fresh native identity after the mutation.
  fresh=invoke(window);button=next(node for node in flatten(fresh['tree']) if node.get('name')==button_name)
  clicked=invoke(window,operation='action',identity=button['identity'],action='click')
  assert clicked.get('ok'),clicked
  wait(lambda:(BASE/file).with_suffix('.click').exists() if 'gtk' in file else pathlib.Path(str(BASE/file)+'.click').exists())
  bounded=invoke(window,maxNodes=2,maxDepth=1)
  assert bounded['nodeCount']<=2 and bounded['truncated'],bounded
  foreign=invoke(window,operation='action',identity={'bus':entry['identity']['bus'],'path':'/org/a11y/atspi/accessible/999999','role':1,'name':'other'},action='click')
  assert not foreign.get('ok') and 'authorized window' in foreign['error'],foreign
  seat='tree-a' if 'gtk' in title else 'tree-b'
  entry=next(node for node in flatten(invoke(window)['tree']) if 'editable' in node.get('states',[]))
  authorization={**ctl('seat state '+seat,True),'instance':ENV['HYPRLAND_INSTANCE_SIGNATURE']}
  stale=invoke(window,operation='action',identity=entry['identity'],action='setText',text='SHOULD NOT TYPE',authorization={**authorization,'generation':'expired'})
  assert not stale.get('ok') and 'identity/view changed' in stale['error'],stale
  no_grant=invoke(window,operation='action',identity=entry['identity'],action='setText',text='SHOULD NOT TYPE',authorization={})
  assert not no_grant.get('ok') and 'authorization' in no_grant['error'],no_grant
  cli('pause',seat)
  paused=invoke(window,operation='action',identity=entry['identity'],action='setText',text='SHOULD NOT TYPE')
  assert not paused.get('ok') and 'paused' in paused['error'],paused
  cli('resume',seat)
  assert (BASE/file).read_text()=='真实元素树 中文'
  assert human_state()==human,(human_state(),human)
  record(title+' exposes real roles, text, states, actions and window geometry; Unicode edit and semantic click only affect its authorized window')
 missing=invoke({'pid':windows[0]['pid'],'title':'not-a-real-window'})
 assert not missing.get('ok') and 'unsupported' in missing['error'],missing
 qt_window=next(w for w in windows if w['title']=='native-qt-window')
 os.kill(qt_window['pid'],signal.SIGSTOP)
 began=time.monotonic()
 stopped=invoke(qt_window)
 elapsed=time.monotonic()-began
 os.kill(qt_window['pid'],signal.SIGCONT)
 assert not stopped.get('ok') and elapsed<5, (stopped,elapsed)
 record('stale generation, missing authorization, paused desktop reject writes; stalled Qt application has bounded failure')
 record('missing native window fails closed; tree budgets truncate and foreign object paths cannot be acted upon')
 print('Native accessibility verified:',BASE,flush=True)
finally:cleanup()
