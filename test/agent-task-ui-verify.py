"""Real task submission failures remain visible without taking desktop focus.

The missing Pi binary is a deliberate dependency fault, not a model substitute.
A malformed job status then exercises the real status reader's failure path.
"""
from desktop_harness import *


def ui(target, method, *args):
    path = RT / ('cornice-' + ENV.get('USER', 'user') + '.sock')
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(2)
        connection.connect(str(path))
        connection.sendall((json.dumps({'target':target, 'method':method, 'args':list(args)}) + '\n').encode())
        answer = b''
        while b'\n' not in answer:
            chunk = connection.recv(65536)
            if not chunk: raise RuntimeError('UI socket closed')
            answer += chunk
    reply = json.loads(answer.split(b'\n', 1)[0])
    if not reply['ok']: raise ValueError(reply)
    return json.loads(reply['result']) if method in ('status', 'geometry', 'promptDraft', 'controls') else reply['result']


def send(command):
    keyboard.stdin.write(command + '\n'); keyboard.stdin.flush()
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'done', command


def open_prompt(name='agent1'):
    ui('desktop', 'prompt', name)
    def mapped_prompt():
        layer = next((item for item in ctl('layers', True)['human']['levels']['3'] if item['namespace'] == 'cornice-agent-prompt'), None)
        return layer and layer['alpha'] >= .99 and layer['w'] > 0 and layer['h'] > 0 and ui('desktop', 'promptDraft')['focused']
    wait(mapped_prompt)


def submit():
    for command in ('mods 4', 'key 28 1', 'key 28 0', 'mods 0'): send(command)


def close_prompt():
    send('key 1 1'); send('key 1 0')
    wait(lambda: not ui('desktop', 'status')['prompt']['open'])


def blocked_start():
    # Delay the real runtime at a private dependency read, without substituting
    # a CLI, model, worker or response. Status polling does not read this config.
    actual_config = model_config.read_bytes()
    model_config.unlink(); os.mkfifo(model_config, 0o600)
    submit()
    def running_start():
        for path in pathlib.Path('/proc').iterdir():
            if not path.name.isdigit(): continue
            try:
                command = (path / 'cmdline').read_bytes().split(b'\0')
                if b'start' in command and b'agent1' in command and any(part.endswith(b'/cornice-agent-runtime') for part in command):
                    return int(path.name)
            except OSError: pass
    return actual_config, wait(running_start)


def release_start(config, regular_config):
    # Restore the regular dependency before EOF lets start spawn its real worker.
    with model_config.open('wb') as stream:
        stream.write(config); stream.flush()
        model_config.unlink(); model_config.write_bytes(regular_config)


def task():
    return ui('desktop', 'status')['tasks'].get('agent1', {})


def controls():
    return ui('desktopObserver', 'controls')


def status_icon():
    return next(item for item in controls() if item['name'] == 'status')


def hover_status():
    icon = status_icon()
    send(f"motion {round(icon['x'] + icon['width']/2)} {round(icon['y'] + icon['height']/2)}")
    previous = None
    def visible_menu():
        nonlocal previous
        rows = [item for item in controls() if item['name'] in ('takeover', 'run', 'prompt', 'cancel', 'manage', 'task-status')]
        row = next((item for item in rows if item['name'] == 'task-status'), None)
        menu = next((item for item in ctl('layers', True)['human']['levels']['3'] if item['namespace'] == 'cornice-desktop-menu'), None)
        # QML creates delegates and the layer before their first layout/commit.
        # Wait for visibility and stable geometry, without making bounds part of
        # readiness: a genuinely clipped final layout must still fail below.
        if not row or not menu or menu['alpha'] < .99 or len(rows) != 6 or any(item['width'] <= 0 or item['height'] <= 0 or abs(item['width'] - menu['w']) > 1 for item in rows):
            previous = None
            return None
        geometry = tuple(menu[key] for key in ('x', 'y', 'w', 'h')) + tuple(tuple(item[key] for key in ('name', 'x', 'y', 'width', 'height')) for item in rows)
        stable = geometry == previous
        previous = geometry
        if not stable: return None
        # The alpha goal alone does not prove a visible output frame was painted.
        # Sample the opaque panel near its right edge, above the detailed row.
        path = photograph('task-menu-ready')
        import gi
        gi.require_version('GdkPixbuf', '2.0')
        from gi.repository import GdkPixbuf
        image = GdkPixbuf.Pixbuf.new_from_file(str(path))
        x, y = round(menu['x'] + menu['w'] - 4), round(menu['y'] + min(menu['h'] - 2, 20))
        offset = y * image.get_rowstride() + x * image.get_n_channels()
        actual = tuple(image.get_pixels()[offset:offset + 3])
        expected = (24, 29, 35)  # Color.panel from the fixture's foreground/background.
        if max(abs(a - b) for a, b in zip(actual, expected)) > 6: return None
        return row, menu
    return wait(visible_menu)


def photograph(name):
    path = BASE / (name + '.png')
    subprocess.run(['grim', '-o', 'human', str(path)], env=ENV, check=True)
    return path


try:
    model_config = BASE / 'agent-model.json'
    model_config.write_text(json.dumps({'endpoint':'http://127.0.0.1:1/v1', 'model':'ui-failure-verification',
        'token':'isolated-test-token', 'pi':str(BASE / 'missing-pi')}))
    ENV['CORNICE_AGENT_CONFIG'] = str(model_config)
    initialize()
    config = BASE / 'config/cornice'; config.mkdir(parents=True, exist_ok=True)
    (config / 'config.json').write_text(json.dumps({'agentDesktop':{'enabled':True},
        'bar':{'layout':{'left':['cn.agent-desktop'], 'center':[], 'right':[]}},
        'background':{'enabled':False}, 'weather':{'intervalMinutes':0},
        'idle':{'lock':0, 'screenOffAc':0, 'screenOffBattery':0, 'dimAc':0, 'dimBattery':0, 'lockOnSleep':False, 'lockOnLockSignal':False, 'lockOnLidClose':False}}))
    (config / 'theme.json').write_text(json.dumps({'colors':{'foreground':'#c9d1d9', 'background':'#0d1117', 'urgent':'#f85149'}}))
    start(['/usr/bin/python3', ROOT / 'test/agent-desktop-client.py', 'human-window', BASE / 'human.txt'], 'human-client')
    wait(lambda: any(item['title'] == 'human-window' for item in ctl('clients', True)))
    human = human_state()
    cli('create', 'agent1', '--virtual-output', '1280x800')
    cli('create', 'agent2', '--virtual-output', '1280x800')
    start([str(PRODUCT / 'bin/cornice-qs'), '-p', str(PRODUCT / 'shell')], 'primary-shell')
    wait(lambda: ui('desktop', 'status')['available'])
    ui('desktop', 'observe', 'agent1')
    wait(lambda: ui('desktopObserver', 'status')['presentation'].get('active'))

    for source, name in (('virtual-keyboard-unstable-v1', 'virtual-keyboard'), ('wlr-virtual-pointer-unstable-v1', 'virtual-pointer')):
        for mode, extension in (('client-header', 'h'), ('private-code', 'c')):
            subprocess.run(['wayland-scanner', mode, str(FORK / 'protocols' / (source + '.xml')), str(BASE / (name + '.' + extension))], check=True)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    subprocess.run(['cc', '-I' + str(BASE), str(FORK / 'hyprtester/multiseat/input.c'), str(BASE / 'virtual-keyboard.c'), str(BASE / 'virtual-pointer.c'), '-o', str(BASE / 'input'), *flags], check=True)
    keyboard = subprocess.Popen([str(BASE / 'input'), 'Hyprland', 'human'], env=ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=open(BASE / 'input.log', 'w'), text=True, start_new_session=True)
    PROCESSES.append(keyboard)
    assert select.select([keyboard.stdout], [], [], 5)[0] and keyboard.stdout.readline().strip() == 'ready'
    send('motion 640 500')

    open_prompt()
    prompt = 'Open only the current application and report what is visible.'
    send('type ' + prompt)
    try:
        wait(lambda: ui('desktop', 'promptDraft')['text'] == prompt)
    except RuntimeError:
        raise AssertionError(('actual draft after physical typing', ui('desktop', 'promptDraft'), ctl('seat input-target', True), ctl('layers', True)))
    for command in ('mods 4', 'key 28 1', 'key 28 0', 'mods 0'): send(command)
    failure = wait(lambda: (value if (value := task()).get('phase') == 'failed' else None))
    wait(lambda: not ui('desktop', 'status')['prompt']['open'])
    assert failure['runId'] and failure['message'] and 'missing-pi' in failure['message'], failure
    draft = ui('desktop', 'promptDraft')
    assert draft['text'] == prompt, (draft, failure)
    assert draft['submitted'] == prompt, (draft, failure)
    assert not any(item['namespace'] == 'cornice-agent-prompt' for level in ctl('layers', True)['human']['levels'].values() for item in level)
    assert human_state()['workspace'] == human['workspace'] and human_state()['window'] == human['window']
    assert not (BASE / 'human.txt').exists()
    record('real prompt Ctrl+Enter accepts a distinct run; actual missing Pi dependency fails, keeps the submitted draft and never reopens the keyboard layer')

    send('motion 640 500'); time.sleep(.3)
    icon = status_icon()
    screenshot = photograph('task-failure-badge')
    import gi
    gi.require_version('GdkPixbuf', '2.0')
    from gi.repository import GdkPixbuf
    image = GdkPixbuf.Pixbuf.new_from_file(str(screenshot)); pixels = image.get_pixels(); channels = image.get_n_channels()
    x, y = round(icon['x'] + icon['width'] - 4), round(icon['y'] + 3)
    offset = y * image.get_rowstride() + x * channels
    actual = tuple(pixels[offset:offset + 3]); expected = (248, 81, 73)
    assert max(abs(a - b) for a, b in zip(actual, expected)) < 12, ('alert badge not visibly painted', actual, expected, icon)
    row, menu = hover_status()
    assert row['alert'] and row['detail'] == failure['message'] and row['detailHeight'] > 0, row
    assert row['y'] + row['height'] <= menu['y'] + menu['h'] + 1, (row, menu)
    for item in controls():
        if item['name'] in ('takeover', 'run', 'prompt', 'cancel', 'manage'):
            assert item['detail'] == '' and item['detailHeight'] == 0 and item['height'] == 40, item
    photograph('task-failure-menu')
    record('real native Agent bar paints a persistent urgent badge; existing menu wraps the concrete task reason inside its bounds while ordinary rows retain their height')

    open_prompt()
    assert ui('desktop', 'promptDraft')['text'] == prompt
    send('key 1 1'); send('key 1 0')
    wait(lambda: not ui('desktop', 'status')['prompt']['open'])
    record('reopening the task prompt restores the failed run draft without automatic focus changes')

    directory = RT / 'cornice' / ENV['HYPRLAND_INSTANCE_SIGNATURE'] / 'jobs/agent1'
    status_file = directory / 'status.json'; original = status_file.read_bytes()
    status_file.write_text('{malformed real status')
    ui('desktop', 'refreshTasks')
    wait(lambda: ui('desktop', 'status')['taskError'] != '')
    assert not ui('desktop', 'status')['prompt']['open']
    row, menu = hover_status()
    assert row['alert'] and '状态读取失败' in row['label'] and '任务状态读取失败' in row['detail'], row
    assert row['y'] + row['height'] <= menu['y'] + menu['h'] + 1, (row, menu)
    photograph('task-status-read-error')
    status_file.write_bytes(original); ui('desktop', 'refreshTasks')
    wait(lambda: ui('desktop', 'status')['taskError'] == '')
    assert task()['runId'] == failure['runId'] and task()['phase'] == 'failed'
    assert human_state()['workspace'] == human['workspace'] and human_state()['window'] == human['window']
    record('a genuine malformed job record surfaces status-read failure instead of silently trusting cached state; repaired record clears only the read warning')
    for invalid_status in (None, [], {}, {'phase':''}):
        status_file.write_text(json.dumps(invalid_status)); ui('desktop', 'refreshTasks')
        wait(lambda: ui('desktop', 'status')['taskError'] != '')
        assert task()['runId'] == failure['runId'] and task()['phase'] == 'failed', 'Invalid task schema must preserve the last valid snapshot'
        assert not ui('desktop', 'status')['prompt']['open']
        row, menu = hover_status()
        assert row['alert'] and '状态读取失败' in row['label'] and '任务状态读取失败' in row['detail'], row
        assert row['y'] + row['height'] <= menu['y'] + menu['h'] + 1, (row, menu)
        if invalid_status is None: photograph('task-status-null-error')
        status_file.write_bytes(original); ui('desktop', 'refreshTasks')
        wait(lambda: ui('desktop', 'status')['taskError'] == '')
        assert task()['runId'] == failure['runId'] and task()['phase'] == 'failed'
    record('real valid-JSON null/array/missing-phase/empty-phase job records explicitly fail schema validation, retain the valid cached run and recover after repair')

    # A real missing token rejects start synchronously, before a run is accepted.
    actual_config = model_config.read_bytes()
    invalid_config = json.loads(actual_config); del invalid_config['token']
    model_config.write_text(json.dumps(invalid_config))
    open_prompt()
    assert ui('desktop', 'promptDraft')['text'] == prompt
    for command in ('mods 4', 'key 28 1', 'key 28 0', 'mods 0'): send(command)
    rejected = wait(lambda: (value if (value := ui('desktop', 'status')['submissionErrors'].get('agent1')) else None))
    assert 'token' in rejected and ui('desktop', 'status')['prompt']['open']
    assert ui('desktop', 'promptDraft')['text'] == prompt and ui('desktop', 'promptDraft')['error'] == rejected
    assert task()['runId'] == failure['runId'], 'Synchronous rejection must not invent an accepted run'
    send('key 1 1'); send('key 1 0')
    wait(lambda: not ui('desktop', 'status')['prompt']['open'])
    row, menu = hover_status()
    assert row['alert'] and row['detail'] == rejected and '未能启动' in row['label'], row
    assert row['y'] + row['height'] <= menu['y'] + menu['h'] + 1, (row, menu)
    photograph('task-start-rejected')
    record('real configuration rejection preserves the prompt and run identity; closing the editor keeps its concrete reason in the bar menu')

    model_config.write_bytes(actual_config)
    open_prompt()
    for command in ('mods 4', 'key 28 1', 'key 28 0', 'mods 0'): send(command)
    retry = wait(lambda: (value if (value := task()).get('phase') == 'failed' and value.get('runId') != failure['runId'] else None))
    wait(lambda: not ui('desktop', 'status')['prompt']['open'])
    assert not ui('desktop', 'status')['submissionErrors'].get('agent1')
    assert ui('desktop', 'promptDraft')['text'] == prompt
    assert human_state()['workspace'] == human['workspace'] and human_state()['window'] == human['window']
    record('a genuinely accepted retry clears only the prior submission rejection and retains its own failed draft without taking human input')

    open_prompt()
    regular_config, held_pid = blocked_start()
    close_prompt(); open_prompt('agent2')
    second_draft = 'Keep this new draft on the second desktop.'
    send('type ' + second_draft)
    wait(lambda: ui('desktop', 'promptDraft')['text'] == second_draft)
    release_start(regular_config, regular_config)
    switched_run = wait(lambda: (value if (value := task()).get('phase') == 'failed' and value.get('runId') != retry['runId'] else None))
    assert ui('desktop', 'status')['prompt'] == {'open':True, 'name':'agent2'}
    draft = ui('desktop', 'promptDraft')
    assert draft['focused'] and draft['text'] == second_draft and draft['error'] == '', draft
    record('a real delayed start acceptance for Agent 1 leaves the newer Agent 2 editor, draft and keyboard focus intact')

    close_prompt(); open_prompt()
    assert ui('desktop', 'promptDraft')['text'] == prompt
    regular_config, held_pid = blocked_start()
    close_prompt(); open_prompt()
    newer_draft = 'Keep this newer draft on the first desktop.'
    for command in ('mods 4', 'key 30 1', 'key 30 0', 'mods 0'): send(command)
    send('type ' + newer_draft)
    wait(lambda: ui('desktop', 'promptDraft')['text'] == newer_draft)
    release_start(regular_config, regular_config)
    reopened_run = wait(lambda: (value if (value := task()).get('phase') == 'failed' and value.get('runId') != switched_run['runId'] else None))
    assert ui('desktop', 'status')['prompt'] == {'open':True, 'name':'agent1'}
    draft = ui('desktop', 'promptDraft')
    assert draft['focused'] and draft['text'] == newer_draft and draft['error'] == '', draft
    record('a real delayed acceptance cannot close or overwrite a newer editor generation on the same Agent')

    regular_config, held_pid = blocked_start()
    close_prompt(); open_prompt('agent2')
    assert ui('desktop', 'promptDraft')['text'] == second_draft
    bad_config = json.loads(regular_config); del bad_config['token']
    release_start(json.dumps(bad_config).encode(), regular_config)
    old_error = wait(lambda: ui('desktop', 'status')['submissionErrors'].get('agent1'))
    assert 'token' in old_error and task()['runId'] == reopened_run['runId']
    assert ui('desktop', 'status')['prompt'] == {'open':True, 'name':'agent2'}
    draft = ui('desktop', 'promptDraft')
    assert draft['focused'] and draft['text'] == second_draft and draft['error'] == '', draft
    close_prompt()
    assert human_state()['workspace'] == human['workspace'] and human_state()['window'] == human['window']
    record('a genuine delayed Agent 1 configuration rejection is recorded for Agent 1 without polluting the Agent 2 editor or changing human state')

    (BASE / 'task-ui-verification.json').write_text(json.dumps({'failure':failure, 'draft':prompt, 'badgeRgb':actual,
        'menu':row, 'screenshot':'task-failure-menu.png'}, ensure_ascii=False, indent=2))
finally:
    cleanup()
