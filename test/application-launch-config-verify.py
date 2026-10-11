"""Real per-desktop launches driven by defaults and user configuration."""
from desktop_harness import *
from cdp_client import Cdp
import copy
import shutil

try:
    initialize()
    config=BASE/'config/cornice';config.mkdir(parents=True,exist_ok=True)
    path=config/'config.json'
    def configure(value):path.write_text(json.dumps(value))
    human=start(['google-chrome-stable','--ozone-platform=wayland','--no-first-run','--no-default-browser-check','about:blank'],'human-browser')
    wait(lambda:any('chrome' in c['class'].lower() for c in ctl('clients',True)))
    cli('create','agent1','--workspace','11','--virtual-output','1280x800');cli('resume','agent1')
    credential=bind('agent1');before=human_state()
    custom={'desktopApplications':{'rules':{'terminal':{'executables':['kitty'],'scope':'secondary','profile':'configured-terminal','arguments':['--title','Configured {desktop}','--override','confirm_os_window_close=0'],'environment':{'CORNICE_PROFILE_PROBE':'{profile}'}}}}}
    configure(custom)
    launched=cli('launch','agent1','--','kitty','/bin/sh','-c','printf "Cornice configured application\\n"; sleep 120')
    window=wait(lambda:next((w for w in ctl('clients',True) if w['title']=='Configured agent1'),None))
    profile=str(pathlib.Path(ENV['HOME'])/'.local/share/cornice/desktops/agent1/configured-terminal')
    environment=pathlib.Path('/proc',str(window['pid']),'environ').read_bytes().split(b'\0')
    assert ('CORNICE_PROFILE_PROBE='+profile).encode() in environment
    assert pathlib.Path(profile).is_dir() and window['workspace']['id']==11
    time.sleep(.5)
    shot=tool(credential,'capture');(BASE/'configured-application.png').write_bytes(base64.b64decode(shot['pngBase64']))
    record('a new configured application receives its own profile, argv template and environment on the correct desktop')
    # No user browser rule was supplied: the shipped default still applies.
    browser=tool(credential,'browser');cdp=Cdp(browser['cdpUrl'])
    assert cdp.call('Browser.getVersion')['product'];cdp.close()
    browser_window=wait(lambda:next((w for w in ctl('clients',True) if 'chrome' in w['class'].lower() and w['workspace']['id']==11),None))
    default_profile=str(pathlib.Path(ENV['HOME'])/'.local/share/cornice/desktops/agent1/chrome')
    command=pathlib.Path('/proc',str(browser_window['pid']),'cmdline').read_bytes().split(b'\0')
    assert ('--user-data-dir='+default_profile) in shlex.split(b' '.join(command).decode()),(default_profile,command,browser_window)
    record('omitted browser settings inherit the shipped managed Chrome rule')
    # Changing a live browser policy must report an error, never silently keep
    # old settings or terminate a running application.
    changed=copy.deepcopy(custom);changed['desktopApplications']['rules']['chrome']={'profile':'new-chrome'}
    configure(changed)
    assert 'configuration changed' in tool(credential,'browser',succeeds=False)
    assert any(w['pid']==browser_window['pid'] for w in ctl('clients',True))
    configure(custom);assert tool(credential,'browser')['cdpUrl']==browser['cdpUrl']
    record('changing a live browser policy is rejected without closing its window; restoring settings reconnects')
    cdp=Cdp(browser['cdpUrl'])
    cdp.call('Browser.close');cdp.close()
    # The window can disappear before the process exits. Policy changes apply
    # after the actual browser exit, not merely after a surface is unmapped.
    wait(lambda:not pathlib.Path('/proc',str(browser_window['pid'])).exists())
    wait(lambda:not any(w['pid']==browser_window['pid'] for w in ctl('clients',True)))
    # An executable unknown to Cornice's source can be selected as its browser.
    local=pathlib.Path(ENV['HOME'])/'.local/bin';local.mkdir(parents=True,exist_ok=True)
    wrapper=local/'configured-browser'
    environment_probe=BASE/'browser-environment.txt'
    wrapper.write_text("\n".join(["#!/bin/sh", 'printf "%s\\n" "$CORNICE_BROWSER_PROBE" > '+shlex.quote(str(environment_probe)), 'exec '+shlex.quote(shutil.which('google-chrome-stable'))+' "$@"', ""]));wrapper.chmod(0o700)
    custom['desktopApplications']['browser']='customChrome'
    custom['desktopApplications']['rules']['chrome']={'enabled':False}
    custom['desktopApplications']['rules']['customChrome']={'executables':['configured-browser'],'backend':'chromium','profile':'custom-browser','arguments':['--user-data-dir={profile}','--ozone-platform=wayland','--no-first-run','--no-default-browser-check'],'environment':{'CORNICE_BROWSER_PROBE':'{desktop}'}}
    existing=pathlib.Path(ENV['HOME'])/'existing-browser';existing.mkdir()
    marker=existing/'existing-data-marker';marker.write_text('preserve this profile')
    custom['desktopApplications']['rules']['customChrome']['profilePaths']={'agent1':'~/existing-browser'}
    configure(custom)
    browser=tool(credential,'browser');cdp=Cdp(browser['cdpUrl']);assert cdp.call('Browser.getVersion')['product'];cdp.close()
    custom_window=wait(lambda:next((w for w in ctl('clients',True) if 'chrome' in w['class'].lower() and w['workspace']['id']==11),None))
    expected=str(existing)
    assert marker.read_text()=='preserve this profile'
    assert ('--user-data-dir='+expected) in shlex.split(pathlib.Path('/proc',str(custom_window['pid']),'cmdline').read_text().replace('\0',' '))
    # Check this test value at the actual executable launch boundary.
    assert environment_probe.read_text().strip()=='agent1'
    record('a configured executable alias supplies the managed CDP browser with custom profile and environment')
    assert 'disabled' in cli('launch','agent1','--',str(wrapper),'--remote-debugging-port=9222',succeeds=False)
    assert 'disabled' in cli('launch','agent1','--',str(wrapper),'--user-data-dir=/tmp/shared',succeeds=False)
    for variable in ('WAYLAND_DISPLAY','CORNICE_DESKTOP_NAME','CORNICE_PRIMARY_SHELL_SOCKET','HYPRLAND_SEAT_GENERATION'):
        invalid=copy.deepcopy(custom);invalid['desktopApplications']['rules']['terminal']['environment'][variable]='wrong-desktop'
        configure(invalid);assert 'identity' in cli('launch','agent1','--','kitty',succeeds=False)
    invalid=copy.deepcopy(custom);invalid['desktopApplications']['rules']['terminal']['profile']='../shared'
    configure(invalid);assert 'directory name' in cli('launch','agent1','--','kitty',succeeds=False)
    invalid=copy.deepcopy(custom);invalid['desktopApplications']['rules']['terminal']['profilePaths']={'agent1':'relative/path'}
    configure(invalid);assert 'absolute or ~/' in cli('launch','agent1','--','kitty',succeeds=False)
    invalid=copy.deepcopy(custom);invalid['desktopApplications']['rules']['duplicate']={'executables':['kitty']}
    configure(invalid);assert 'multiple rules' in cli('launch','agent1','--','kitty',succeeds=False)
    path.write_text('{invalid json');assert 'invalid JSON' in cli('launch','agent1','--','kitty',succeeds=False)
    assert cli('list') and any(w['pid']==custom_window['pid'] for w in ctl('clients',True))
    record('debug/profile bypasses, compositor identity overrides, profile traversal and malformed configuration fail without killing the service')
    custom['desktopApplications']['rules']['terminal']['enabled']=False;configure(custom)
    plain=cli('launch','agent1','--','kitty','--title','Unadapted application','--override','confirm_os_window_close=0','sleep','120')
    plain_window=wait(lambda:next((w for w in ctl('clients',True) if w['title']=='Unadapted application'),None))
    assert not any(value.startswith(b'CORNICE_PROFILE_PROBE=') for value in pathlib.Path('/proc',str(plain_window['pid']),'environ').read_bytes().split(b'\0'))
    assert human.poll() is None and human_state()==before
    record('disabling a rule takes effect on the next launch and leaves the primary desktop unchanged')
finally:cleanup()
