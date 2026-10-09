"""Real private shell, scoped workspaces, menus and takeover lifecycle."""
from desktop_harness import *
import hashlib

try:
    broker = initialize()
    human = human_state()
    for name in ('agent1','agent2'):
        cli('create',name,'--virtual-output','1280x800')
    def agent_shell(name, *args):
        environment = dict(ENV, CORNICE_SHELL_SOCKET=str(RT/('cs-'+hashlib.sha256(ENV['HYPRLAND_INSTANCE_SIGNATURE'].encode()).hexdigest()[:8]+'-'+name+'.sock')))
        return subprocess.check_output([str(PRODUCT/'bin/cornice'), *args], env=environment,text=True,stderr=subprocess.PIPE,timeout=8).strip()
    wait(lambda: agent_shell('agent1','ping') == 'pong 0.2.5')
    wait(lambda: len(json.loads(agent_shell('agent1','ipc','bar','geometry'))) > 3)
    for name in ('agent1','agent2'):
        value = cli('state',name)
        assert len(value['workspaceSlots']) == 10 and value['workspaceSlots'][0]['active'], value
    cli('view-workspace','agent1','10')
    assert cli('state','agent1')['workspaceName'].endswith('-ws-10')
    assert cli('state','agent2')['workspaceName'].endswith('-ws-1')
    cli('view-workspace','agent1','1')
    assert human_state() == human
    record('two real Cornice shells and ten independent workspace slots; paused view navigation leaves human unchanged')
    cli('resume','agent1')
    binding = bind('agent1')
    shot = tool(binding,'capture')
    (BASE/'agent-bar.png').write_bytes(base64.b64decode(shot['pngBase64']))
    geometry = json.loads(agent_shell('agent1','ipc','bar','geometry'))
    workspace = next(item for item in geometry if item['id'] == 'cn.workspaces')
    tool(binding,'input',{'frameId':shot['frameId'],'action':'click','x':workspace['x']+workspace['width']-12,'y':workspace['y']+workspace['height']/2})
    wait(lambda: cli('state','agent1')['workspaceName'].endswith('-ws-10'))
    assert human_state() == human
    record('real Agent bar accepts pointer input and switches only its own workspace')
    shot = tool(binding,'capture')
    tool(binding,'input',{'frameId':shot['frameId'],'action':'chord','keys':['SUPER','2']})
    wait(lambda: cli('state','agent1')['workspaceName'].endswith('-ws-2'))
    assert human_state() == human
    record('Super+number changes only the Agent workspace namespace')
    cli('view-workspace','agent1','1')
    cli('launch','agent1','--','/usr/bin/python3',ROOT/'test/agent-desktop-client.py','agent1-window',BASE/'agent1.txt')
    wait(lambda: len(ctl('clients',True)) == 1)
    binding = bind('agent1')
    shot = tool(binding,'capture')
    tool(binding,'input',{'frameId':shot['frameId'],'action':'text','text':'agent before'})
    wait(lambda: (BASE/'agent1.txt').read_text() == 'agent before')
    def click_entry(connection=None):
        current = cli('state','agent1')
        client = next(window for window in ctl('clients',True) if window['title'] == 'agent1-window')
        bounds = json.loads((BASE/'agent1.geometry').read_text())['entry']
        event = {'action':'click','x':client['at'][0]-current['position'][0]+bounds[0]+bounds[2]/2,
                 'y':client['at'][1]-current['position'][1]+bounds[1]+bounds[3]/2}
        if connection:
            frame = rpc(connection,'frame',{'name':'agent1'})
            rpc(connection,'human.input',{'name':'agent1','frameId':frame['frameId'],'events':[event]})
        else:
            frame = tool(binding,'capture')
            tool(binding,'input',dict(event,frameId=frame['frameId']))
    with socket.socket(socket.AF_UNIX) as owner:
        owner.connect(str(RT/'cornice'/ENV['HYPRLAND_INSTANCE_SIGNATURE']/'desktop.sock'))
        rpc(owner,'takeover',{'name':'agent1'})
        assert cli('state','agent1')['controlMode'] == 'human'
        assert 'revoked' in tool(binding,'state',succeeds=False)
        click_entry(owner)
        shot = rpc(owner,'frame',{'name':'agent1'})
        rpc(owner,'human.input',{'name':'agent1','frameId':shot['frameId'],'events':[{'action':'text','text':' human edit'}]})
        rpc(owner,'release',{'name':'agent1'})
    assert cli('state','agent1')['controlMode'] == 'paused'
    cli('resume','agent1')
    binding = bind('agent1'); click_entry(); shot = tool(binding,'capture')
    tool(binding,'input',{'frameId':shot['frameId'],'action':'text','text':' agent after'})
    wait(lambda: (BASE/'agent1.txt').read_text() == 'agent before human edit agent after')
    assert human_state() == human
    record('takeover edits a real GTK app, release pauses, explicit resume creates fresh binding and continues')
    broker.kill(); broker.wait(timeout=5)
    restarted = start([str(PRODUCT/'bin/cornice-desktopd')],'desktopd-restart')
    wait(desktop_ready)
    wait(lambda: agent_shell('agent1','ping') == 'pong 0.2.5')
    wait(lambda: len(json.loads(agent_shell('agent1','ipc','bar','geometry'))) > 3)
    for name in ('agent1','agent2'):
        state = cli('state',name)
        assert state['paused']
        bars = [layer for level in ctl('layers',True)[state['output']]['levels'].values()
                for layer in level if layer['namespace'] == 'cornice-bar']
        assert len(bars) == 1, bars
    assert (BASE/'agent1.txt').read_text() == 'agent before human edit agent after'
    assert human_state() == human
    record('broker SIGKILL retires its shell children; restart restores exactly one bar per desktop and keeps input paused')

    # Inspect the actual rendered dot, and react to real window lifecycle
    # changes without switching the human workspace to refresh the bar.
    config=BASE/'config/cornice'; config.mkdir(parents=True,exist_ok=True)
    (config/'config.json').write_text(json.dumps({'agentDesktop':{'enabled':True},
        'bar':{'layout':{'left':['cn.workspaces'],'center':[],'right':[]}},
        'background':{'enabled':False},'weather':{'intervalMinutes':0},
        'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,'lockOnSleep':False}}))
    start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'human-shell')
    def workspace_widget(name=''):
        geometry=json.loads(agent_shell(name,'ipc','bar','geometry') if name else shell('ipc','bar','geometry'))
        return next((item for item in geometry if item['id']=='cn.workspaces'),{'controls':[]})
    def slot(number,name=''):
        controls=workspace_widget(name)['controls']
        return controls[number-1] if len(controls)>=number else {'dotVisible':False,'occupied':False,'active':False}
    wait(lambda:len(workspace_widget()['controls'])==10)
    window=start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window',BASE/'dots.txt'],'human-dots')
    client=wait(lambda:next((w for w in ctl('clients',True) if w['title']=='human-window'),None))
    wait(lambda:slot(1)['occupied'])
    assert slot(1)['active'] and not slot(1)['dotVisible']
    ok('dispatch hl.dsp.window.move({window="address:'+client['address']+'",workspace="3",follow=false})')
    wait(lambda:slot(3)['dotVisible'] and not slot(1)['occupied'])
    subprocess.run(['grim','-o','human',str(BASE/'human-workspace-dot.png')],env=ENV,check=True)
    from PIL import Image
    def painted_dot(path,widget,number):
        dot=widget['controls'][number-1]['dot']
        color=dot['color'].lstrip('#')
        expected=tuple(int(color[i:i+2],16) for i in (0,2,4))
        point=(round(widget['x']+dot['x']+dot['width']/2),round(widget['y']+dot['y']+dot['height']/2))
        actual=Image.open(path).convert('RGB').getpixel(point)
        assert max(abs(a-b) for a,b in zip(actual,expected))<35,(actual,expected,point)
    painted_dot(BASE/'human-workspace-dot.png',workspace_widget(),3)
    ok('dispatch hl.dsp.window.move({window="address:'+client['address']+'",workspace="4",follow=false})')
    wait(lambda:slot(4)['dotVisible'] and not slot(3)['occupied'])
    window.terminate();window.wait(timeout=5)
    wait(lambda:not slot(4)['occupied'])
    record('human workspace dots paint for occupied inactive slots and follow window open, move and close without changing workspace')
    cli('view-workspace','agent1','2')
    wait(lambda:slot(1,'agent1')['dotVisible'])
    assert not any(item['occupied'] for item in workspace_widget('agent2')['controls'])
    assert not any(item['occupied'] for item in workspace_widget()['controls'])
    cli('capture','agent1',BASE/'agent-workspace-dot.png')
    painted_dot(BASE/'agent-workspace-dot.png',workspace_widget('agent1'),1)
    record('Agent workspace dots paint from its own live toplevel list; human and other Agent occupancy stay isolated')

finally:
    cleanup()
