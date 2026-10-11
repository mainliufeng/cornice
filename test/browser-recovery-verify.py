"""Real Chrome DOM survives replacement of its seat-authorized Broker proxy."""
from desktop_harness import *
from cdp_client import Cdp
import urllib.parse
import urllib.request
import shutil

try:
    broker = initialize()
    cli('resume', 'desktop2')
    binding = bind('desktop2')
    endpoint = tool(binding, 'browser')['cdpUrl']
    cdp = Cdp(endpoint)
    page = '<title>Browser recovery</title><input id="draft"><div id="state"></div>'
    target = cdp.call('Target.createTarget', {'url': 'data:text/html,' + urllib.parse.quote(page)})['targetId']
    cdp.call('Target.activateTarget', {'targetId': target})
    session = cdp.call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
    wait(lambda: cdp.call('Runtime.evaluate', {'expression': 'document.title', 'returnByValue': True}, session)['result'].get('value') == 'Browser recovery')
    cdp.call('Runtime.evaluate', {'expression': 'document.querySelector("#draft").value="未提交的表单"; window.ephemeral="memory-only"', 'returnByValue': True}, session)
    browser_pid = wait(lambda: next((client['pid'] for client in ctl('clients', True) if 'Browser recovery' in client['title']), None))
    record('Real managed Chrome contains an unsaved form and memory-only page state')

    for mode in ('graceful', 'crash'):
        if mode == 'graceful': broker.terminate()
        else: broker.kill()
        broker.wait(timeout=8)
        if mode == 'graceful':
            assert broker.returncode == 0, ('Broker crashed during normal shutdown', broker.returncode)
        assert pathlib.Path('/proc/' + str(browser_pid)).exists()
        try:
            cdp.call('Browser.getVersion'); raise AssertionError('Old CDP proxy survived Broker replacement')
        except (OSError, ConnectionError): pass
        cdp.close()
        broker = start([str(PRODUCT / 'bin/cornice-desktopd')], 'desktopd-' + mode)
        wait(desktop_ready)
        assert cli('state', 'desktop2')['paused']
        tool(binding, 'browser', succeeds=False)
        cli('resume', 'desktop2'); binding = bind('desktop2')
        endpoint = tool(binding, 'browser')['cdpUrl']; cdp = Cdp(endpoint)
        targets = cdp.call('Target.getTargets')['targetInfos']
        assert target in [entry['targetId'] for entry in targets]
        session = cdp.call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
        value = cdp.call('Runtime.evaluate', {'expression': '[document.querySelector("#draft").value,window.ephemeral]', 'returnByValue': True}, session)['result']['value']
        assert value == ['未提交的表单', 'memory-only'], value
        assert any(client['pid'] == browser_pid and 'Browser recovery' in client['title'] for client in ctl('clients', True))
        record(mode + ' Broker replacement keeps the same Chrome process, tab, draft and DOM; old grants stay revoked')

    # The managed browser remains attached to the private desktop after real
    # output geometry changes; this exercises compositor/native topology, not
    # a simulated logind resume event or a physical sleep operation.
    desktop = cli('state', 'desktop2')
    ok('eval hl.monitor({output=' + json.dumps(desktop['output']) + ',mode="1600x900",position="auto",scale=1})')
    wait(lambda: cli('state', 'desktop2')['pixelSize'] == [1600, 900])
    assert cdp.call('Runtime.evaluate', {'expression': 'window.ephemeral', 'returnByValue': True}, session)['result']['value'] == 'memory-only'
    record('Real private output resize retains browser state and authorized CDP after recovery')
    cdp.close()
    cli('reset', 'desktop2')
    assert pathlib.Path('/proc/' + str(browser_pid)).exists()
    cli('resume', 'desktop2'); binding = bind('desktop2')
    cdp = Cdp(tool(binding, 'browser')['cdpUrl'])
    assert target in [entry['targetId'] for entry in cdp.call('Target.getTargets')['targetInfos']]
    session = cdp.call('Target.attachToTarget', {'targetId': target, 'flatten': True})['sessionId']
    assert cdp.call('Runtime.evaluate', {'expression': 'document.querySelector("#draft").value', 'returnByValue': True}, session)['result']['value'] == '未提交的表单'
    record('Default desktop reset preserves real browser tabs and unsaved form state')
    cdp.close(); cli('pause', 'desktop2')
    cli('remove', 'desktop2', '--close-apps')
    wait(lambda: not pathlib.Path('/proc/' + str(browser_pid)).exists() or pathlib.Path('/proc/' + str(browser_pid) + '/stat').read_text().split()[2] == 'Z')
    record('Explicit remove --close-apps closes only the selected independently owned browser runtime')

    # A real Chrome process behind a deliberately slow configured launcher must
    # not block the Broker event loop or expire another native takeover lease.
    local = pathlib.Path(ENV['HOME']) / '.local/bin'; local.mkdir(parents=True, exist_ok=True)
    slow = local / 'slow-browser'
    slow.write_text('#!/bin/sh\nprintf started > "$CORNICE_BROWSER_START_FILE"\nsleep 3.5\nexec ' + shlex.quote(shutil.which('google-chrome-stable')) + ' "$@"\n')
    slow.chmod(0o700)
    settings = BASE / 'config/cornice/config.json'; settings.parent.mkdir(parents=True, exist_ok=True)
    original_settings = settings.read_bytes() if settings.exists() else None
    settings.write_text(json.dumps({'desktopApplications': {'browser': 'slowChrome', 'rules': {
        'slowChrome': {'executables': ['slow-browser'], 'backend': 'chromium', 'profile': 'slow-chrome',
            'arguments': ['--user-data-dir={profile}', '--ozone-platform=wayland', '--no-first-run', '--no-default-browser-check'],
            'environment': {'CORNICE_BROWSER_START_FILE': str(BASE / '{desktop}-started')}}}}}))
    cli('create', 'watch-desktop', '--virtual-output', '1280x800')
    cli('create', 'slow-desktop', '--virtual-output', '1280x800')
    cli('resume', 'slow-desktop'); slow_binding = bind('slow-desktop')
    viewer = socket.socket(socket.AF_UNIX); viewer.settimeout(2)
    viewer.connect(str(RT / 'cornice' / ENV['HYPRLAND_INSTANCE_SIGNATURE'] / 'desktop.sock'))
    assert rpc(viewer, 'present', {'name': 'watch-desktop'})['active']
    assert rpc(viewer, 'takeover', {'name': 'watch-desktop'})['humanControl']
    def request_browser(credential, label):
        process = subprocess.Popen([str(PRODUCT / 'bin/cornice'), 'desktop', 'tool', str(credential),
            'desktop.browser', '{}'], env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True)
        PROCESSES.append(process)
        return process
    slow_request = request_browser(slow_binding, 'slow')
    wait(lambda: (BASE / 'slow-desktop-started').exists())
    measurements = []
    deadline = time.monotonic() + 18
    while slow_request.poll() is None and time.monotonic() < deadline:
        before = time.monotonic()
        assert cli('doctor')['capabilities']['protocol'] == 1
        view = rpc(viewer, 'present-status', {'name': 'watch-desktop'})
        assert view['active'] and view['humanControl'], view
        measurements.append(time.monotonic() - before)
        assert measurements[-1] < 1.5, measurements
        time.sleep(.1)
    output, error = slow_request.communicate(timeout=2)
    assert slow_request.returncode == 0, (output, error)
    endpoint = json.loads(output)['cdpUrl']
    slow_cdp = Cdp(endpoint); assert slow_cdp.call('Browser.getVersion')['product']; slow_cdp.close()
    assert len(measurements) >= 3 and max(measurements) < 1.5, measurements
    (BASE / 'browser-startup-responsiveness.json').write_text(json.dumps(measurements, indent=2))
    assert rpc(viewer, 'present-status', {'name': 'watch-desktop'})['humanControl']
    rpc(viewer, 'release', {'name': 'watch-desktop'}); viewer.close()
    cli('remove', 'watch-desktop'); cli('pause', 'slow-desktop'); cli('remove', 'slow-desktop', '--close-apps')
    record('Real delayed Chrome startup preserves responsive Broker RPCs and another native takeover heartbeat')

    cli('create', 'cancel-desktop', '--virtual-output', '1280x800')
    cli('resume', 'cancel-desktop'); cancelled_binding = bind('cancel-desktop')
    cancelled_request = request_browser(cancelled_binding, 'cancelled')
    wait(lambda: (BASE / 'cancel-desktop-started').exists())
    assert cli('state', 'cancel-desktop')['browser']['state'] == 'starting'
    started = time.monotonic(); cli('pause', 'cancel-desktop')
    output, error = cancelled_request.communicate(timeout=2)
    assert cancelled_request.returncode != 0 and time.monotonic() - started < 2, (output, error)
    assert any(word in error.lower() for word in ('revoked', 'interrupted', 'changed')), error
    assert cli('state', 'cancel-desktop')['paused']
    tool(cancelled_binding, 'browser', succeeds=False)
    workspace = cli('state', 'cancel-desktop')['workspace'].removeprefix('name:')
    cancelled_window = wait(lambda: next((client for client in ctl('clients', True)
        if client['workspace']['name'] == workspace and 'chrome' in client['class'].lower()), None), 12)
    # Launch already crossed the application boundary before cancellation; keep
    # the application but expose no agent control and never repeat the launch.
    assert pathlib.Path('/proc/' + str(cancelled_window['pid'])).exists()
    cli('remove', 'cancel-desktop', '--close-apps')
    wait(lambda: not pathlib.Path('/proc/' + str(cancelled_window['pid'])).exists())
    if original_settings is None: settings.unlink()
    else: settings.write_bytes(original_settings)
    record('Pause during actual browser startup promptly rejects the pending grant, preserves submitted application life, and explicit close cleans it')
finally:
    cleanup()
