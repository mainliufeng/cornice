"""Task-owned human cooperation with real MCP, native views and QML buttons."""
from desktop_harness import *
from mcp_client import MCP
from cooperation_visual import visible_cooperation, visible_cooperation_menu
import hashlib

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
def click_banner(name, dismiss=False):
    row,layer=visible_cooperation(banner,name,'cooperation-before-click-'+str(time.monotonic_ns()))
    if dismiss:row=banner()['dismiss']
    x=round(layer['x']+row['x']+row['width']/2);y=round(layer['y']+row['y']+row['height']/2)
    for line in (f'motion {x} {y}','button 272 1','button 272 0'):send(line)
def cooperation_menu(name, expected_label):
    # Native presentation retains the primary shell's physical Overlay bar.
    return visible_cooperation_menu(lambda:json.loads(shell('ipc','bar','geometry')),
                                    lambda x,y:send(f'motion {round(x)} {round(y)}'),name,
                                    'cooperation-menu-'+str(time.monotonic_ns()),expected_label)
def click_menu(row):
    x=round(row['x']+row['width']/2);y=round(row['y']+row['height']/2)
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
    visible_cooperation(banner,name,'cooperation-request',lambda row:row['status']=='requested')
    click_banner(name)
    wait(lambda:observer()['humanControl'])
    wait(lambda:a.details('desktop_handoff',target|{'action':'status'})['request']['status']=='in_progress')
    agent_env=secondary_env(name)
    wait(lambda:not banner()['visible'] and not banner(agent_env)['visible'])
    # Real keyboard input reaches the target desktop while Agent input is revoked.
    client=next(w for w in ctl('clients',True) if w['title']==name+'-window')
    st=cli('state',name);g=json.loads((BASE/(name+'.geometry')).read_text())['entry']
    x=round(client['at'][0]-st['position'][0]+g[0]+30);y=round(client['at'][1]-st['position'][1]+g[1]+g[3]/2)
    for line in (f'motion {x} {y}','button 272 1','button 272 0'):send(line)
    for character in 'human':send('type '+character);time.sleep(.04)
    wait(lambda:(BASE/(name+'.txt')).read_text()=='human')
    row,heading,_=cooperation_menu(name,'已完成，退出接管')
    assert '处理中' in heading['label'] and request['instructions'] in heading['detail']
    assert 'changed' in cli('handoff-complete',name,'wrong-request',succeeds=False)
    waitingId=a.send('tools/call',{'name':'desktop_wait','arguments':target|{'seconds':30,'reason':'等待人工步骤完成'}})
    click_menu(row)
    completedAt=time.monotonic()
    waited=a.receive(waitingId)
    assert waited['structuredContent']['cooperationResolved'] and waited['structuredContent']['interrupted'],waited
    assert time.monotonic()-completedAt<2,'completion did not promptly wake the waiting harness tool'
    wait(lambda:not observer()['humanControl'])
    done=wait(lambda:a.details('desktop_handoff',target|{'action':'status'})['request'] if a.details('desktop_handoff',target|{'action':'status'})['request']['status']=='completed' else None)
    assert [event['status'] for event in done['events']]==['requested','in_progress','completed'],done
    assert cli('state',name)['paused']
    assert not banner()['visible'] and not banner(agent_env)['visible']
    _,heading,_=cooperation_menu(name,'查看桌面')
    assert '等待 Agent 继续' in heading['label']
    send('motion 1000 700')
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
    visible_cooperation(banner,name,'cooperation-new-request',lambda row:row['requestId']==rid)
    shell('ipc','desktopObserver','takeover','true');wait(lambda:observer()['humanControl'])
    cancelled=a.details('desktop_handoff',target|{'action':'resolve','requestId':rid,'outcome':'cancelled','note':'用户远程要求退出接管'})
    assert cancelled['request']['status']=='cancelled'
    wait(lambda:not observer()['humanControl'] and not banner()['visible'])
    # A later ordinary manual takeover is unrelated to the resolved request.
    shell('ipc','desktopObserver','takeover','true');wait(lambda:observer()['humanControl'])
    assert not banner()['visible']
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
    wait(lambda:not banner()['visible'])
    row,heading,_=cooperation_menu('main','已完成，退出接管')
    click_menu(row)
    wait(lambda:a.details('desktop_handoff',ptarget|{'action':'status'})['request']['status']=='completed')
    assert not banner()['visible']
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
