"""Real isolated direct task allocation/create under human lock; no host sockets."""
from desktop_harness import *
from mcp_client import MCP
from urllib.parse import quote


def provider(scope, label):
    process = subprocess.Popen([str(PRODUCT/'bin/cornice-human-lock'), '--scope', scope,
        '--pam-service', 'permit', '--pam-directory', str(pam), '--allow-emergency'],
        env=ENV, stdin=subprocess.PIPE, stdout=open(BASE/(label+'.events'),'w'),
        stderr=open(BASE/(label+'.log'),'w'), text=True, start_new_session=True)
    PROCESSES.append(process)
    def secure():
        assert process.poll() is None, (label, process.returncode)
        return any(json.loads(line).get('event') == 'secure'
                   for line in (BASE/(label+'.events')).read_text().splitlines() if line.endswith('}'))
    wait(secure, 12)
    assert ctl('seat lock-state', True)['secure']
    return process


def unlock(process):
    process.stdin.write('emergency-unlock\n'); process.stdin.flush()
    wait(lambda: not ctl('seat lock-state', True)['locked'])
    process.wait(timeout=5)


def acquired(client, **params):
    task = client.details('desktop_acquire', params)
    assert not task['primary'] and task['lockedTaskActive'] and task['activity']=='running', task
    return task, {'desktop':task['desktop']}


def clock_pixels(path):
    # MCP images may be JPEG encoded: decode the real painted bit strip using
    # color dominance, rather than requiring byte-exact green after compression.
    from PIL import Image
    image=Image.open(path).convert('RGB')
    for y in range(0,image.height,4):
        begin=None
        for x in range(image.width+1):
            red,green,blue=image.getpixel((x,y)) if x<image.width else (0,0,255)
            colored=blue<100 and red+green>120 and max(red,green)>110
            if colored and begin is None:begin=x
            if colored or begin is None:continue
            length=x-begin
            if length>=256:
                return sum((1<<bit) for bit in range(32)
                    if image.getpixel((int(begin+(bit+.5)*length/32),y))[1]>
                       image.getpixel((int(begin+(bit+.5)*length/32),y))[0])
            begin=None
    raise AssertionError('Application clock pixels absent from actual observer output')


def captured(client, target, path):
    result = client.call('desktop_capture', target)
    path.write_bytes(base64.b64decode(next(item['data'] for item in result['content'] if item['type']=='image')))
    return result['structuredContent']


def finish(client, target, outcome='completed'):
    return client.call('desktop_finish', target|{'outcome':outcome,'reason':'isolated lifecycle verification'})


try:
    broker = initialize()
    assert 'locked-task-start-v1' in ctl('seat capabilities',True)['features']
    pam=BASE/'pam';pam.mkdir();(pam/'permit').write_text('auth required pam_permit.so\n')
    (pam/'other').write_text('auth required pam_deny.so\n')
    start(['/usr/bin/python3',ROOT/'test/agent-desktop-client.py','human-window',BASE/'human.txt'],'human')
    wait(lambda:any(c['title']=='human-window' for c in ctl('clients',True)))
    initial=cli('state','desktop2')
    assert initial['humanLockPolicy']=='pause' and initial['taskIdle']
    cli('create','disabled','--virtual-output','1280x800');cli('allow-agent','disabled','off')
    a,b=MCP('direct-a'),MCP('direct-b')
    lock=provider('human','direct-human')
    a.call('desktop_acquire',{'preferredDesktop':'disabled'},False)
    assert cli('state','disabled')['paused']
    cli('remove','disabled')
    epoch=ctl('seat lock-state',True)['lockEpoch']
    ia=a.send('tools/call',{'name':'desktop_acquire','arguments':{'preferredDesktop':'desktop2'}})
    ib=b.send('tools/call',{'name':'desktop_acquire','arguments':{'preferredDesktop':'desktop2'}})
    ra,rb=a.receive(ia),b.receive(ib)
    assert not ra.get('isError') and not rb.get('isError'),(ra,rb)
    first,second=ra['structuredContent'],rb['structuredContent']
    assert first['name']!=second['name'] and {first['name'],second['name']} >= {'desktop2'}
    assert first['created'] != second['created']
    assert all(t['lockedTaskActive'] and t['activity']=='running' and t['humanLockPolicy']=='pause' for t in (first,second))
    assert ctl('seat lock-state',True)['lockEpoch']==epoch
    one,two={'desktop':first['desktop']},{'desktop':second['desktop']}
    private=set(ctl('seat private-outputs',True))
    assert {first['output'],second['output']} <= private
    protected=ctl('seat lock-state',True)['protectedOutputs']
    assert {p['name'] for p in protected}=={'human'} and all(p['covered'] for p in protected)
    record('without setup or new switches, two contenders obtain distinct leases: one existing idle desktop and one new private desktop during human lock')

    a.call('desktop_launch',one|{'argv':['/usr/bin/python3',str(ROOT/'test/agent-desktop-client.py'),'locked-window',str(BASE/'agent.txt')]})
    wait(lambda:any(c['title']=='locked-window' for c in ctl('clients',True)))
    path=BASE/'new-task.png';frame=captured(a,one,path);clock=clock_pixels(path)
    a.call('desktop_input',one|{'frameId':frame['frameId'],'action':'text','text':'direct-锁中任务'})
    wait(lambda:(BASE/'agent.txt').read_text()=='direct-锁中任务')
    time.sleep(.25);captured(a,one,path);assert clock_pixels(path)!=clock
    cli('capture','main',BASE/'forbidden.png',succeeds=False)
    cli('resume','main',succeeds=False)
    a.call('desktop_acquire',{'preferredDesktop':'main'},False)
    assert 'session locked' in ctl('seat input-target-v2')
    cli('bind',first['name'],BASE/'forbidden.binding',succeeds=False)
    assert not (BASE/'human.txt').exists() or (BASE/'human.txt').read_text()==''
    subprocess.run(['grim','-o','human',str(BASE/'human-locked.png')],env=ENV,check=True)
    try:
        clock_pixels(BASE/'human-locked.png');raise AssertionError('human lock leaked a painted application clock')
    except AssertionError as error:
        assert 'Application clock pixels absent' in str(error),error
    record('real GTK Unicode input and painted frame progress; primary input/capture and normal locked management bind remain denied; human output has no application clock')

    assert a.details('desktop_browser_connect',one)['connected']
    a.call('browser_navigate',one|{'url':'data:text/html,'+quote('<title>Direct locked task</title><body>private browser document</body>')})
    assert 'private browser document' in str(a.call('browser_snapshot',one))
    finish(a,one)
    a.call('browser_snapshot',one,False);a.call('desktop_capture',one,False)
    assert cli('state',first['name'])['taskIdle']
    task,target=acquired(a,preferredDesktop=first['name'])
    assert task['name']==first['name'] and task['generation']!=first['generation']
    a.call('desktop_input',target|{'frameId':frame['frameId'],'action':'text','text':'FORBIDDEN'},False)
    record('real managed Chrome works for a new locked task; completion retires browser/reference/frame authority and permits a fresh lease')

    cli('pause',task['name']);stopped=cli('state',task['name']);assert not stopped['taskIdle']
    a.call('desktop_restore',target,False);a.call('desktop_capture',target,False)
    replacement,replacement_target=acquired(b,preferredDesktop=task['name'])
    assert replacement['created'] and replacement['name']!=task['name']
    assert cli('state',task['name'])['generation']==stopped['generation'] and cli('state',task['name'])['paused']
    finish(b,replacement_target);cli('remove',replacement['name'])
    finish(a,target,'blocked')
    cli('remove',task['name'],'--close-apps')
    record('manual pause preserves its task reservation and cannot be resurrected; another task gets a different private desktop')

    cross,cross_target=acquired(a,createNew=True)
    a.call('desktop_workspace',cross_target|{'workspace':'1'},False)
    a.call('desktop_restore',cross_target,False)
    assert cli('state',cross['name'])['paused'] and not cli('state',cross['name'])['taskIdle']
    finish(a,cross_target,'blocked');cli('remove',cross['name'])
    record('existing permission withdrawal remains effective; switching a lock-created task to the human output revokes it without fallback')

    # Full-lock upgrade raced with creation must revoke any winner before
    # standard secure acknowledgement. Neither an old epoch nor old device is valid.
    idle=cli('create','race-seat','--virtual-output','1280x800')
    export='test-only-export-'+'x'*48
    cmd='seat locked-task-start race-seat '+idle['seatId']+' '+idle['generation']+' '
    assert not ctl(cmd+str(int(epoch)-1)+' '+export).startswith('{')
    assert cli('state','race-seat')['generation']==idle['generation']
    full=subprocess.Popen([str(PRODUCT/'bin/cornice-human-lock'),'--scope','session','--pam-service','permit',
        '--pam-directory',str(pam),'--allow-emergency'],env=ENV,stdin=subprocess.PIPE,
        stdout=open(BASE/'race-full.events','w'),stderr=open(BASE/'race-full.log','w'),text=True,start_new_session=True)
    PROCESSES.append(full)
    pending=a.send('tools/call',{'name':'desktop_acquire','arguments':{'createNew':True}})
    raced=a.receive(pending)
    wait(lambda:ctl('seat lock-state',True)['scope']=='session' and ctl('seat lock-state',True)['secure'])
    if not raced.get('isError'):
        raced=raced['structuredContent'];a.call('desktop_capture',{'desktop':raced['desktop']},False)
        finish(a,{'desktop':raced['desktop']},'blocked')
    a.call('desktop_acquire',{'createNew':True},False)
    cli('create','forbidden-full','--virtual-output','1280x800',succeeds=False)
    assert not ctl(cmd+epoch+' '+export).startswith('{')
    b.call('desktop_capture',two,False);b.call('desktop_restore',two,False)
    finish(b,two,'blocked')
    unlock(full)
    assert cli('state','race-seat')['paused'] and not cli('state','race-seat')['taskIdle']
    cli('remove','race-seat');cli('remove',second['name'])
    record('stale epochs reject without rotating control; full-lock/create race fails closed; standard full lock revokes all leases and forbids creation')

    lock=provider('human','disconnect-human')
    task,target=acquired(a,createNew=True)
    a.close();wait(lambda:not cli('state',task['name'])['occupied'])
    assert cli('state',task['name'])['paused'] and not cli('state',task['name'])['taskIdle']
    fresh,ft=acquired(b,preferredDesktop=task['name'])
    assert fresh['name']!=task['name']
    finish(b,ft);cli('remove',fresh['name']);cli('remove',task['name'])
    record('lost harness connection revokes the old lease; a later task cannot revive that desktop')

    task,target=acquired(b,createNew=True)
    output=task['output'];ok('output remove '+output)
    wait(lambda:not ctl('seat state '+task['name']).startswith('{'))
    b.call('desktop_capture',target,False);b.call('desktop_restore',target,False)
    ok('seat create-private-output '+output+' '+ctl('seat lock-state',True)['lockEpoch'])
    ok('eval hl.monitor({output='+json.dumps(output)+',mode="1280x800",position="auto",scale=1})')
    b.call('desktop_capture',target,False)
    b.call('desktop_finish',target|{'outcome':'blocked','reason':'output disappeared'},False)
    record('same-name output recreation cannot revive a retired seat or old lease')

    task,target=acquired(b,createNew=True)
    unlock(lock)
    b.call('desktop_capture',target,False);b.call('desktop_restore',target,False)
    finish(b,target,'blocked')
    cli('remove',task['name'])
    record('human unlock invalidates lock-created leases; no automatic restore across lock epochs')

    lock=provider('human','restart-human')
    task,target=acquired(b,createNew=True)
    broker.kill();broker.wait(timeout=5)
    broker=start([str(PRODUCT/'bin/cornice-desktopd')],'desktopd-restarted');wait(desktop_ready)
    b.call('desktop_capture',target,False);b.call('desktop_restore',target,False)
    old=cli('state',task['name']);assert old['paused'] and not old['taskIdle']
    fresh,ft=acquired(b,preferredDesktop=task['name']);assert fresh['name']!=task['name']
    finish(b,ft);unlock(lock)
    record('Broker restart restores existing desktops paused, retires all old leases, and allocates later tasks separately')
    lock=provider('human','orphan-human')
    lock.kill();lock.wait(timeout=5);wait(lambda:not ctl('seat lock-state',True)['ownerConnected'])
    b.call('desktop_acquire',{'createNew':True},False)
    assert ctl('seat lock-state',True)['scope']=='session'
    record('owner loss preserves an orphaned full lock and refuses new task/output creation; private compositor is discarded still locked')
    b.close()
finally:
    cleanup()
