"""Real foreign-toplevel activation follows its requested wl_seat, not the app socket."""
from desktop_harness import *

checks = []
failures = []

HELPER = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include "foreign.h"

struct Seat { struct wl_seat* resource; char name[128]; };
struct Window { struct zwlr_foreign_toplevel_handle_v1* resource; char title[256]; int closed; };
static struct wl_display* display;
static struct zwlr_foreign_toplevel_manager_v1* manager;
static struct Seat seats[64]; static int seat_count;
static struct Window windows[128]; static int window_count;
static void caps(void* data, struct wl_seat* seat, uint32_t value) {}
static void seat_name(void* data, struct wl_seat* seat, const char* name) {
    snprintf(((struct Seat*)data)->name, 128, "%s", name);
}
static const struct wl_seat_listener seat_listener = {caps, seat_name};
static void title(void* data, struct zwlr_foreign_toplevel_handle_v1* window, const char* name) {
    snprintf(((struct Window*)data)->title, 256, "%s", name);
}
static void app(void* data, struct zwlr_foreign_toplevel_handle_v1* window, const char* app) {}
static void output(void* data, struct zwlr_foreign_toplevel_handle_v1* window, struct wl_output* output) {}
static void state(void* data, struct zwlr_foreign_toplevel_handle_v1* window, struct wl_array* state) {}
static void done(void* data, struct zwlr_foreign_toplevel_handle_v1* window) {}
static void closed(void* data, struct zwlr_foreign_toplevel_handle_v1* window) { ((struct Window*)data)->closed = 1; }
static void parent(void* data, struct zwlr_foreign_toplevel_handle_v1* window, struct zwlr_foreign_toplevel_handle_v1* parent) {}
static const struct zwlr_foreign_toplevel_handle_v1_listener window_listener = {title, app, output, output, state, done, closed, parent};
static void toplevel(void* data, struct zwlr_foreign_toplevel_manager_v1* manager, struct zwlr_foreign_toplevel_handle_v1* resource) {
    if (window_count >= 128) exit(2);
    struct Window* window = &windows[window_count++]; window->resource = resource;
    zwlr_foreign_toplevel_handle_v1_add_listener(resource, &window_listener, window);
}
static void finished(void* data, struct zwlr_foreign_toplevel_manager_v1* manager) {}
static const struct zwlr_foreign_toplevel_manager_v1_listener manager_listener = {toplevel, finished};
static void global(void* data, struct wl_registry* registry, uint32_t id, const char* interface, uint32_t version) {
    if (!strcmp(interface, "wl_seat")) {
        if (seat_count >= 64) exit(2);
        struct Seat* seat = &seats[seat_count++];
        seat->resource = wl_registry_bind(registry, id, &wl_seat_interface, version < 5 ? version : 5);
        wl_seat_add_listener(seat->resource, &seat_listener, seat);
    } else if (!strcmp(interface, "zwlr_foreign_toplevel_manager_v1")) {
        manager = wl_registry_bind(registry, id, &zwlr_foreign_toplevel_manager_v1_interface, version < 3 ? version : 3);
        zwlr_foreign_toplevel_manager_v1_add_listener(manager, &manager_listener, NULL);
    }
}
static void removed(void* data, struct wl_registry* registry, uint32_t id) {}
static const struct wl_registry_listener registry_listener = {global, removed};
static void sync_display(void) { if (wl_display_roundtrip(display) < 0) exit(1); }
int main(void) {
    display = wl_display_connect(NULL); if (!display) return 1;
    struct wl_registry* registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    sync_display(); sync_display(); sync_display();
    if (!manager) return 2;
    puts("ready"); fflush(stdout);
    char line[512], seat_name[128], target[256];
    while (fgets(line, sizeof(line), stdin)) {
        sync_display(); sync_display();
        if (sscanf(line, "activate %127s %255s", seat_name, target) != 2) return 2;
        struct wl_seat* seat = NULL; struct zwlr_foreign_toplevel_handle_v1* window = NULL;
        for (int i = 0; i < seat_count; ++i) if (!strcmp(seats[i].name, seat_name)) seat = seats[i].resource;
        for (int i = 0; i < window_count; ++i)
            if (!windows[i].closed && !strcmp(windows[i].title, target)) window = windows[i].resource;
        if (!seat || !window) { fprintf(stderr, "Missing seat %s or target %s\n", seat_name, target); return 2; }
        zwlr_foreign_toplevel_handle_v1_activate(window, seat);
        sync_display(); puts("done"); fflush(stdout);
    }
    wl_display_disconnect(display); return 0;
}
'''


def client(title):
    return next((item for item in ctl('clients', True) if item['title'] == title), None)


def seat_state(name):
    state = cli('state', name)
    return {key: state.get(key) for key in ('workspace', 'workspaceName', 'windowAddress', 'cursor', 'position', 'monitor')}


def dispatch(code, seat=None):
    if seat:
        state = cli('state', seat)
        ok('seat dispatch ' + seat + ' ' + state['display'] + ' ' + state['generation'] + ' ' + code)
    else:
        ok('dispatch ' + code)


def focus(title, seat=None):
    dispatch('hl.dsp.focus({window=' + json.dumps('title:^' + title + '$') + '})', seat)
    address = client(title)['address']
    wait(lambda: (seat_state(seat)['windowAddress'] if seat else human_state()['window']) == address)


def workspace(value, seat):
    dispatch('hl.dsp.focus({workspace=' + json.dumps(value) + '})', seat)
    wait(lambda: cli('state', seat)['workspaceName'] == value)


def launch(title, seat=None):
    command = ['/usr/bin/python3', str(ROOT/'test/agent-desktop-client.py'), title, str(BASE/(title+'.txt'))]
    if seat:
        cli('launch', seat, '--', *command)
    else:
        start(command, title, ENV | {'WAYLAND_DEBUG': '1'})
    return wait(lambda: client(title))


def process(binary, label, arguments=(), env=None):
    proc = subprocess.Popen([str(BASE/binary), *arguments], env=env or ENV, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=open(BASE/(label+'.log'), 'w'), text=True, start_new_session=True)
    PROCESSES.append(proc)
    assert select.select([proc.stdout], [], [], 5)[0] and proc.stdout.readline().strip() == 'ready', label
    return proc


def command(proc, value):
    proc.stdin.write(value+'\n'); proc.stdin.flush()
    assert select.select([proc.stdout], [], [], 5)[0] and proc.stdout.readline().strip() == 'done', value


def snapshot():
    return {'human': human_state(), 'agent1': seat_state('agent1'), 'agent2': seat_state('agent2'),
            'windowModes': {window['title']: [window['fullscreen'], window['fullscreenClient']] for window in ctl('clients', True)}}


def check(label, conditions, before, after):
    item = {'description': label, 'ok': all(conditions), 'before': before, 'after': after}
    checks.append(item)
    if item['ok']:
        record(label)
    else:
        failures.append(item)
        print('FAIL', json.dumps(item), flush=True)
    (BASE/'foreign-activation.json').write_text(json.dumps({'checks': checks, 'failures': failures, 'version': ctl('version', True)}, indent=2))


def activate(proc, requested, title, expected=None):
    before = snapshot()
    command(proc, 'activate ' + requested + ' ' + title)
    time.sleep(.2)
    after = snapshot()
    if expected:
        actor = 'human' if requested == 'Hyprland' else requested
        current = after[actor]['window'] if actor == 'human' else after[actor]['windowAddress']
        conditions = [current == client(expected)['address']]
        conditions.extend(after[name] == before[name] for name in before if name != actor)
    else:
        conditions = [after == before]
    check(f'{requested} activates {title}: ' + (f'focus belongs only to {requested}' if expected else 'denied without fallback'), conditions, before, after)


try:
    initialize()
    ok('eval hl.config({input={follow_mouse=0},general={layout="master"}})')
    for xml, name in (('wlr-foreign-toplevel-management-unstable-v1', 'foreign'),
                      ('virtual-keyboard-unstable-v1', 'virtual-keyboard'), ('wlr-virtual-pointer-unstable-v1', 'virtual-pointer')):
        for mode, extension in (('client-header', 'h'), ('private-code', 'c')):
            subprocess.run(['wayland-scanner', mode, str(FORK/'protocols'/(xml+'.xml')), str(BASE/(name+'.'+extension))], check=True)
    (BASE/'foreign-helper.c').write_text(HELPER)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True).split()
    subprocess.run(['cc', '-I'+str(BASE), str(BASE/'foreign-helper.c'), str(BASE/'foreign.c'), '-o', str(BASE/'foreign-helper'), *flags], check=True)
    input_flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    subprocess.run(['cc', '-I'+str(BASE), str(FORK/'hyprtester/multiseat/input.c'), str(BASE/'virtual-keyboard.c'),
                    str(BASE/'virtual-pointer.c'), '-o', str(BASE/'input'), *input_flags], check=True)
    human_keyboard = process('input', 'human-input', ('Hyprland', 'human'))
    # Match trial startup: seats exist before ordinary applications bind their
    # initial registry. Late-seat GTK is a separate observed limitation below;
    # do not confuse a missing client keyboard binding with wrong-seat routing.
    for index in (1, 2):
        name = 'agent'+str(index)
        cli('create', name, '--workspace', str(10+index), '--virtual-output', '1280x800', '--human-lock-policy', 'continue')
        cli('resume', name)
    for title in ('human-window', 'human-other'):
        launch(title)
    # The ordinary human switcher retains native activation and cursor behavior.
    primary = process('foreign-helper', 'primary-foreign')
    command(primary, 'activate Hyprland human-window')
    wait(lambda: human_state()['window'] == client('human-window')['address'])
    command(human_keyboard, 'type human-sentinel')
    wait(lambda: (BASE/'human-window.txt').read_text() == 'human-sentinel')
    command(human_keyboard, 'motion 430 510')
    for index in (1, 2):
        name = 'agent'+str(index)
        launch(name+'-first', name); launch(name+'-second', name)
    focus('human-window')
    focus('agent1-first', 'agent1'); focus('agent2-first', 'agent2')
    agent_env = ENV | {'WAYLAND_DISPLAY': cli('state', 'agent1')['display']}
    foreign = process('foreign-helper', 'agent1-foreign', env=agent_env)
    agent_keyboard = process('input', 'agent1-input', ('agent1', cli('state', 'agent1')['output']), agent_env)
    activate(primary, 'Hyprland', 'human-other', 'human-other')
    focus('human-window')
    activate(foreign, 'agent1', 'agent1-second', 'agent1-second')
    activate(foreign, 'agent1', 'human-other')
    # Restore baseline damage only inside the sandbox so subsequent cases still
    # prove the same invariant against an old compositor.
    focus('human-window'); focus('agent1-first', 'agent1')
    activate(foreign, 'agent1', 'agent2-second')
    focus('agent2-first', 'agent2')
    for fullscreen in (1, 2):
        for policy in (1, 2):
            ok('eval hl.config({misc={on_focus_under_fullscreen=' + str(policy) + '}})')
            focus('agent2-first', 'agent2')
            dispatch('hl.dsp.window.fullscreen_state({internal=' + str(fullscreen) + ',client=' + str(fullscreen) + ',action="set"})', 'agent2')
            wait(lambda: client('agent2-first')['fullscreen'] == fullscreen)
            activate(foreign, 'agent1', 'agent2-second')
            dispatch('hl.dsp.window.fullscreen_state({internal=0,client=0,action="set"})', 'agent2')
            focus('agent2-first', 'agent2')
            dispatch('hl.dsp.window.fullscreen_state({internal=0,client=0,action="set"})', 'agent2')
    ok('eval hl.config({misc={on_focus_under_fullscreen=2}})')

    workspace('1', 'agent1')
    activate(foreign, 'agent1', 'human-other', 'human-other')
    before_text = (BASE/'human-other.txt').read_text() if (BASE/'human-other.txt').exists() else ''
    command(agent_keyboard, 'type sharedhuman')
    time.sleep(.2)
    check('requested Agent keyboard reaches human-socket shared window',
          [(BASE/'human-other.txt').exists() and (BASE/'human-other.txt').read_text() == before_text+'sharedhuman',
           (BASE/'human-window.txt').read_text() == 'human-sentinel'], {}, snapshot())
    workspace('12', 'agent1')
    focus('agent2-first', 'agent2')
    activate(foreign, 'agent1', 'agent2-second', 'agent2-second')
    command(agent_keyboard, 'type sharedagent')
    time.sleep(.2)
    check('requested Agent keyboard reaches other-Agent-socket shared window',
          [(BASE/'agent2-second.txt').exists() and (BASE/'agent2-second.txt').read_text() == 'sharedagent',
           (BASE/'human-window.txt').read_text() == 'human-sentinel'], {}, snapshot())
    workspace('11', 'agent1'); focus('agent1-first', 'agent1')
    focus('human-window'); focus('agent2-first', 'agent2')
    cli('pause', 'agent1')
    activate(foreign, 'agent1', 'agent1-second')
    activate(foreign, 'agent1', 'human-other')
    activate(foreign, 'agent1', 'agent2-second')
    cli('resume', 'agent1')
    focus('agent1-first', 'agent1')
    focus('human-window'); focus('agent2-first', 'agent2')

    # A real ext-session-lock client acquires the isolated compositor's full
    # lock; the long-lived protocol resource must become inert without falling
    # back to primary input. Authentication is private test-only PAM.
    pam = BASE/'pam'; pam.mkdir()
    (pam/'permit').write_text('auth required pam_permit.so\n')
    locker = subprocess.Popen([str(PRODUCT/'bin/cornice-human-lock'), '--scope', 'session', '--pam-service', 'permit',
                               '--pam-directory', str(pam), '--allow-emergency'], env=ENV, stdin=subprocess.PIPE,
                              stdout=open(BASE/'lock-events', 'w'), stderr=open(BASE/'lock.log', 'w'), text=True, start_new_session=True)
    PROCESSES.append(locker)
    wait(lambda: ctl('seat lock-state', True)['scope'] == 'session' and ctl('seat lock-state', True)['secure'])
    activate(foreign, 'agent1', 'agent1-second')
    activate(foreign, 'agent1', 'human-other')
    activate(foreign, 'agent1', 'agent2-second')
    subprocess.run(['grim', '-o', 'human', str(BASE/'full-lock.png')], env=ENV, check=True)
    locker.stdin.write('emergency-unlock\n'); locker.stdin.flush()
    wait(lambda: not ctl('seat lock-state', True)['locked'])
    assert cli('state', 'agent1')['paused'] and cli('state', 'agent2')['paused']
    # Screenshots are compositor exports of the real shared GTK client.
    cli('resume', 'agent1')
    workspace('12', 'agent1'); focus('agent2-second', 'agent1')
    capture = tool(bind('agent1'), 'capture')
    (BASE/'shared-agent-window.png').write_bytes(base64.b64decode(capture['pngBase64']))
    subprocess.run(['grim', '-o', 'human', str(BASE/'human-desktop.png')], env=ENV, check=True)
    # A GTK3 client already running before a third seat exists does not bind
    # that late wl_seat. Preserve this evidence as an unresolved capability,
    # while asserting the compositor never substitutes the human keyboard.
    late = launch('late-gtk-client')
    cli('create', 'agent3', '--virtual-output', '1280x800')
    cli('resume', 'agent3')
    state3 = cli('state', 'agent3')
    initial_workspace = state3['workspaceName']
    assert initial_workspace == 'cornice-agent-agent3-ws-1'
    assert not [window for window in ctl('clients', True) if window['workspace']['name'] == initial_workspace]
    env3 = ENV | {'WAYLAND_DISPLAY': state3['display']}
    third_keyboard = process('input', 'agent3-input', ('agent3', state3['output']), env3)
    third_foreign = process('foreign-helper', 'agent3-foreign', env=env3)
    workspace('1', 'agent3')
    before = snapshot()
    command(third_foreign, 'activate agent3 late-gtk-client')
    wait(lambda: cli('state', 'agent3')['windowAddress'] == late['address'])
    command(third_keyboard, 'type lateseat')
    time.sleep(.2)
    log = (BASE/'late-gtk-client.log').read_text(errors='replace')
    observation = {'kind': 'unresolved-late-GTK3-seat', 'nativeFocus': cli('state', 'agent3')['windowAddress'] == late['address'],
                   'clientBoundAgent3': '.name("agent3")' in log,
                   'receivedText': (BASE/'late-gtk-client.txt').read_text() if (BASE/'late-gtk-client.txt').exists() else '',
                   'otherSeatsUnchanged': snapshot() == before}
    (BASE/'late-seat-observation.json').write_text(json.dumps(observation, indent=2))
    assert observation['otherSeatsUnchanged'], observation
    assert observation['nativeFocus'], observation
    assert observation['receivedText'] == ('lateseat' if observation['clientBoundAgent3'] else ''), observation
    print('PASS' if observation['clientBoundAgent3'] else 'LIMITATION', json.dumps(observation), flush=True)
    dispatch('hl.dsp.focus({workspace=' + json.dumps('name:' + initial_workspace) + '})', 'agent3')
    wait(lambda: cli('state', 'agent3')['workspaceName'] == initial_workspace)
    before = snapshot()
    own = launch('dynamic-agent3-app', 'agent3')
    binding3 = bind('agent3')
    frame = tool(binding3, 'capture')
    tool(binding3, 'input', {'frameId': frame['frameId'], 'action': 'text', 'text': 'newseatworks'})
    wait(lambda: (BASE/'dynamic-agent3-app.txt').read_text() == 'newseatworks')
    bounds = wait(lambda: json.loads((BASE/'dynamic-agent3-app.geometry').read_text()))['button']
    position = cli('state', 'agent3')['position']
    frame = tool(binding3, 'capture')
    tool(binding3, 'input', {'frameId': frame['frameId'], 'action': 'click',
          'x': own['at'][0] - position[0] + bounds[0] + bounds[2] / 2,
          'y': own['at'][1] - position[1] + bounds[1] + bounds[3] / 2})
    wait(lambda: (BASE/'dynamic-agent3-app.click').read_text() == '1')
    frame = tool(binding3, 'capture')
    (BASE/'dynamic-new-seat-app.png').write_bytes(base64.b64decode(frame['pngBase64']))
    after = snapshot()
    result = {'newSeat': 'agent3', 'initialWorkspace': initial_workspace, 'initialApplicationCount': 0,
              'newApplicationText': (BASE/'dynamic-agent3-app.txt').read_text(),
              'newApplicationClickCount': int((BASE/'dynamic-agent3-app.click').read_text()),
              'otherSeatsUnchanged': all(after[name] == before[name] for name in ('human','agent1','agent2')) and
                  all(after['windowModes'].get(name) == mode for name,mode in before['windowModes'].items()),
              'before': before, 'after': after}
    (BASE/'dynamic-new-seat.json').write_text(json.dumps(result, indent=2))
    check('dynamic Agent starts empty and its newly launched GTK app receives independent text and clicks',
          [result['otherSeatsUnchanged'], own['workspace']['name'] == initial_workspace], {}, result)
    assert not failures, failures
    record('real foreign-toplevel requests preserve requested-seat focus/input, shared windows, pause and full-lock isolation')
finally:
    cleanup()
