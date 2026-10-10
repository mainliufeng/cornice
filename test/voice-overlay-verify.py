"""Real Hyprvoice layer registration on presented secondary seats.

Tests visible startup error UI with absent local ASR models, not microphone/ASR.
"""
from desktop_harness import *
from PIL import Image, ImageChops
try:
    initialize()
    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    (config/'config.json').write_text(json.dumps({'agentDesktop':{'enabled':True},'bar':{'layout':{'left':[{'id':'cn.agent-desktop'}],'center':[],'right':[]}},'background':{'enabled':False},'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}))
    cli('create','agent1','--workspace','11','--virtual-output','1280x800');cli('resume','agent1')
    start([str(PRODUCT/'bin/cornice-qs'),'-p',str(PRODUCT/'shell')],'cornice')
    def status():return json.loads(shell('ipc','desktopObserver','status'))
    wait(lambda:json.loads(shell('ipc','desktop','status'))['available'])
    shell('ipc','desktop','observe','agent1');wait(lambda:status()['presentation'].get('active'))
    def shot(name):
        time.sleep(.4);path=BASE/name
        subprocess.run(['grim','-o','human',str(path)],env=ENV,check=True)
        return Image.open(path).convert('RGB')
    baseline=shot('voice-baseline.png')
    binary=os.environ['CORNICE_TEST_VOICE_BINARY']
    voice_env=dict(ENV,HYPRVOICE_CONFIG=str(BASE/'voice.json'))
    subprocess.run([binary,'init'],env=voice_env,check=True,capture_output=True)
    voice=start([binary,'serve'],'hyprvoice',voice_env)
    def request(action):
        r=subprocess.run([binary,action],env=voice_env,text=True,capture_output=True,timeout=8)
        assert r.returncode==0,(action,r.stderr)
        return json.loads(r.stdout)
    wait(lambda:(RT/'hyprvoice/control.sock').is_socket())
    wait(lambda:request('status').get('state',{}).get('phase')=='error')
    def layer():
        return next((l for monitor in ctl('layers',True).values() for layers in monitor['levels'].values() for l in layers if l.get('namespace')=='hyprvoice'),None)
    wait(layer)
    time.sleep(1.5)
    readonly=shot('voice-readonly.png')
    area=(0,600,1280,800)
    assert ImageChops.difference(baseline.crop(area),readonly.crop(area)).getbbox(), 'Hyprvoice mapped but missing from readonly presented output'
    record('real Hyprvoice floating UI is visible while observing a secondary desktop without control')
    shell('ipc','desktopObserver','takeover','true');wait(lambda:status()['humanControl'])
    takeover=shot('voice-takeover.png')
    assert ImageChops.difference(baseline.crop(area),takeover.crop(area)).getbbox(), 'Hyprvoice missing during takeover'
    record('the same local Hyprvoice floating UI stays visible during secondary takeover')
    request('quit');voice.wait(timeout=8)
    wait(lambda:layer() is None)
    cleared=shot('voice-cleared.png')
    assert ImageChops.difference(baseline.crop(area),cleared.crop(area)).getbbox() is None, 'closed overlay retained on presented desktop'
    record('quitting Hyprvoice removes its registered overlay without a ghost surface')
finally:cleanup()
