"""Real baseline/candidate shell rendering under the same private compositor."""
from desktop_harness import *
from PIL import Image

errors=('ReferenceError:', 'TypeError:', 'is not a type', 'Cannot assign', 'Unable to assign [undefined] to QColor')

def run_shell(product, label, expected_errors):
    log=BASE/(label+'.log')
    env=ENV|{'CORNICE_PATH':str(product),'CORNICE_SHELL_SOCKET':str(RT/(label+'.sock')),
             'CORNICE_ISOLATED_TEST':'0','QML_IMPORT_PATH':str(ROOT/'native/build/qml')+':'+str(ROOT/'native/platform-build/qml')}
    process=start([str(product/'bin/cornice-qs'),'-p',str(product/'shell')],label,env)
    try:
        wait(lambda: process.poll() is not None or 'Configuration Loaded' in log.read_text())
        assert process.poll() is None,log.read_text()
        def geometry():
            result=subprocess.run([str(product/'bin/cornice'),'ipc','bar','geometry'],env=env,text=True,capture_output=True,timeout=4)
            if result.returncode:return False
            return json.loads(result.stdout)
        wait(geometry)
        def rendered():
            subprocess.run(['grim','-o','human',str(BASE/(label+'.png'))],env=ENV,check=True)
            color=Image.open(BASE/(label+'.png')).convert('RGB').getpixel((640,15))
            expected=(13,17,23)  # mono theme barBackground, away from text and compositor notices.
            return color if (min(color)>200 if expected_errors else all(abs(actual-wanted)<=4 for actual,wanted in zip(color,expected))) else None
        color=wait(rendered)
        time.sleep(.25)
        text=log.read_text()
        if expected_errors:
            assert 'Panel.qml[110:' in text and "Cannot read property 'r' of undefined" in text,text
            assert 'Polkit.qml[104:' in text and 'Polkit.qml[166:' in text,text
            assert 'Unable to assign [undefined] to QColor' in text,text
        else:
            assert not any(e in text for e in errors),text
        return color
    finally:
        process.terminate();process.wait(timeout=8)

try:
    initialize()
    config=BASE/'config/cornice/config.json';config.parent.mkdir(parents=True,exist_ok=True)
    config.write_text(json.dumps({'agentDesktop':{'enabled':True},'weather':{'intervalMinutes':0},
        'bar':{'layout':{'left':[{'id':'cn.workspaces'}],'center':[],'right':[]}},
        'idle':{'lock':0,'screenOffAc':0,'screenOffBattery':0,'dimAc':0,'dimBattery':0,
                'lockOnSleep':False,'lockOnLockSignal':False,'lockOnLidClose':False}}))
    baseline=os.environ.get('CORNICE_TEST_QML_BASELINE')
    if baseline:
        baseline=pathlib.Path(baseline)
        before={str(p.relative_to(baseline)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in baseline.rglob('*.qml')}
        baseline_color=run_shell(baseline,'baseline-shell',True)
        assert before=={str(p.relative_to(baseline)):hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in baseline.rglob('*.qml')}
        (BASE/'baseline-qml-sha256.json').write_text(json.dumps(before,indent=2))
        record('unmodified baseline reproduces media/polkit Color lookup errors and wrong white bar under the same Qt/compositor')
    color=run_shell(PRODUCT,'candidate-shell',False)
    (BASE/'result.json').write_text(json.dumps({'qt':subprocess.check_output(['pkg-config','--modversion','Qt6Core'],text=True).strip(),
        'candidateBarPixel':color,'baselineBarPixel':baseline_color if baseline else None},indent=2))
    record('explicit Commons.Color resolves real theme colors across the full candidate shell; rendered bar is dark and no QML errors remain')
finally:
    cleanup()
