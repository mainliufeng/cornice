"""Measure actual presentation feedback on the output displaying the seat."""
from desktop_harness import *
import statistics
try:
    initialize()
    laptop=os.getenv('CORNICE_PACING_LAPTOP')=='1'
    pixels='3072x1920' if laptop else '1280x800'
    scale=2 if laptop else 1
    ok('eval hl.monitor({output="human",mode="'+pixels+'@120",position="0x0",scale='+str(scale)+'})')
    cli('create','agent1','--workspace','11','--virtual-output',pixels)
    cli('resume','agent1')
    state=cli('state','agent1')
    if laptop:
        ok('eval hl.monitor({output='+json.dumps(state['output'])+',mode="3072x1920",position="auto",scale=2})')
        state=cli('state','agent1')
        assert state['pixelSize']==[3072,1920] and state['scale']==2,state
    print('GEOMETRY',json.dumps({'pixels':state['pixelSize'],'scale':state['scale'],'targetRefresh':next(m for m in ctl('monitors',True) if m['name']=='human')['refreshRate']}),flush=True)
    for name,xml in [('xdg','stable/xdg-shell/xdg-shell.xml'),('presentation','stable/presentation-time/presentation-time.xml'),('fifo','staging/fifo/fifo-v1.xml')]:
        for mode,ext in [('client-header','h'),('private-code','c')]:
            subprocess.run(['wayland-scanner',mode,'/usr/share/wayland-protocols/'+xml,str(BASE/(name+'.'+ext))],check=True)
    flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(ROOT/'test/presentation-probe.c'),*[str(BASE/(n+'.c')) for n in ('xdg','presentation','fifo')],'-o',str(BASE/'probe'),*flags],check=True)
    for source,name in [('virtual-keyboard-unstable-v1','virtual-keyboard'),('wlr-virtual-pointer-unstable-v1','virtual-pointer')]:
        for mode,ext in [('client-header','h'),('private-code','c')]:
            subprocess.run(['wayland-scanner',mode,str(FORK/'protocols'/(source+'.xml')),str(BASE/(name+'.'+ext))],check=True)
    input_flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
    subprocess.run(['cc','-I'+str(BASE),str(FORK/'hyprtester/multiseat/input.c'),str(BASE/'virtual-keyboard.c'),str(BASE/'virtual-pointer.c'),'-o',str(BASE/'input'),*input_flags],check=True)
    keyboard=subprocess.Popen([str(BASE/'input'),'Hyprland','human'],env=ENV,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(BASE/'input.log','w'),text=True,start_new_session=True);PROCESSES.append(keyboard)
    assert keyboard.stdout.readline().strip()=='ready'
    def send(event):
        keyboard.stdin.write(event+'\n');keyboard.stdin.flush()
        assert select.select([keyboard.stdout],[],[],5)[0] and keyboard.stdout.readline().strip()=='done'
    owner='presentation-pacing-owner-token-000000001'
    shown=json.loads(ctl('seat present agent1 '+state['display']+' human current '+owner));assert shown['active'],shown
    metrics={}
    for mode in ('plain','fifo','input'):
        log_start=len((BASE/'desktopd.log').read_text().splitlines())
        cli('launch','agent1','--',BASE/'probe','fifo' if mode.endswith('fifo') else mode)
        client=wait(lambda:next((c for c in ctl('clients',True) if c['title']=='presentation-probe'),None))
        pid=client['pid'];OWNED_PIDS.append(pid)
        if mode=='input':
            controlled=json.loads(ctl('seat present-control '+owner+' yes'));assert controlled['humanControl'],controlled
            send('motion 640 400');send('button 272 1');send('button 272 0')
            samples={'key':[],'pointer':[]}
            def feedback_rows():
                return [json.loads(l) for l in (BASE/'desktopd.log').read_text().splitlines()[log_start:] if l.startswith('{"output"')]
            for kind in ('key','pointer'):
                for i in range(8):
                    ctl('seat presentation '+owner)
                    started=time.monotonic_ns()
                    if kind=='key':send('key 30 1');send('key 30 0')
                    else:send('motion '+str(650+i*3)+' 400')
                    def input_presented():
                        return next((r for r in feedback_rows() if r['inputKind']==kind and r['timeNs']>=started),None)
                    row=wait(input_presented,timeout=1)
                    samples[kind].append((row['timeNs']-started)/1e6)
                    time.sleep(.02)
            assert max(samples['key']+samples['pointer'])<100,samples
            print('INPUT',json.dumps(samples),flush=True)
            (BASE/'native-input-latency.json').write_text(json.dumps(samples,indent=2))
            ctl('seat present-control '+owner+' no')
            cli('resume','agent1')
            ok('seat unpresent '+owner)
            # Make the private output genuinely display this workspace. Merely
            # ending observation leaves its lifecycle workspace active; a hidden
            # surface has no presentation event to wait for.
            ok('dispatch hl.dsp.focus({monitor='+json.dumps(state['output'])+'})')
            ok('dispatch hl.dsp.focus({workspace="11"})')
        # The compositor launch inherits broker stdout; wait for the real client.
        deadline=time.monotonic()+12
        while time.monotonic()<deadline:
            ctl('seat presentation '+owner)
            if not any(c['pid']==pid for c in ctl('clients',True)):break
            time.sleep(.2)
        else: raise AssertionError('presentation client stalled '+mode)
        lines=(BASE/'desktopd.log').read_text().splitlines()[log_start:]
        rows=[json.loads(l) for l in lines if l.startswith('{"output"')]
        native_rows=[r for r in rows if r['output']=='human']
        assert len(native_rows)>=90, (mode,len(native_rows))
        if mode=='input':assert rows[-1]['output']==state['output'],rows[-1]
        metric={'outputs':sorted(set(r['output'] for r in rows)),'refreshNs':statistics.median(r['refreshNs'] for r in rows),'feedbackP95Ms':sorted(r['feedbackMs'] for r in rows)[int(len(rows)*.95)-1],'frames':len(rows)}
        metrics[mode]=metric;print('METRIC',mode,json.dumps(metric),flush=True)
    (BASE/'presentation-pacing.json').write_text(json.dumps(metrics,indent=2))
    for mode,m in metrics.items():
        assert m['outputs']==(sorted(['human',state['output']]) if mode=='input' else ['human']),(mode,m)
        assert m['feedbackP95Ms']<100,(mode,m)
    record('real wp_presentation feedback and FIFO complete on the displayed output, with ordinary private-output pacing restored after leaving the view')
finally:cleanup()
