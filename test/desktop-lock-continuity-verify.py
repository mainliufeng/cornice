"""Real acquired MCP task continuity through daily lock and native takeover.
Runs only inside the resource-limited desktop sandbox, using the primary lock
provider route. Management-display routing is covered by human-lock-verify.py.
"""
from desktop_harness import *
from mcp_client import MCP
from native_viewer import NativeViewer
from cdp_client import Cdp


snapshots=[]

def snapshot(phase):
    row={"phase":phase,"lock":ctl("seat lock-state",True),
         "desktops":{name:cli("state",name) for name in ("continuing","pausing","task-continuing")}}
    snapshots.append(row)
    (BASE/"lock-states.json").write_text(json.dumps(snapshots,ensure_ascii=False,indent=2))
    public={"phase":phase,"scope":row["lock"]["scope"],"secure":row["lock"]["secure"],
            "locked":row["lock"]["locked"],"lockEpoch":row["lock"]["lockEpoch"],
            "desktops":{name:{key:state.get(key) for key in ("available","paused","generation","seatId","humanLocked","humanLockPolicy","lockScope","agentAllowed")} for name,state in row["desktops"].items()}}
    print("STATE "+json.dumps(public,ensure_ascii=False),flush=True)
    return row

def provider(scope,event):
    assert "WAYLAND_SOCKET" not in ENV
    assert ENV["WAYLAND_DISPLAY"] != cli("state","continuing")["display"]
    process=subprocess.Popen([str(PRODUCT/"bin/cornice-human-lock"),"--scope",scope,"--pam-service","permit","--pam-directory",str(pam),"--allow-emergency"],env=ENV|{"WAYLAND_DEBUG":"client"},stdin=subprocess.PIPE,stdout=open(BASE/(event+"-events"),"w"),stderr=open(BASE/(event+".log"),"w"),text=True,start_new_session=True)
    PROCESSES.append(process)
    def acknowledged():
        assert process.poll() is None,(event,process.returncode)
        for line in (BASE/(event+"-events")).read_text().splitlines():
            try: data=json.loads(line)
            except json.JSONDecodeError: continue
            if data.get("event")=="secure" and data.get("secure") is True: return True
        return False
    wait(acknowledged,10)
    return process

def unlock(process):
    process.stdin.write("emergency-unlock\n");process.stdin.flush()
    wait(lambda:not ctl("seat lock-state",True)["locked"])
    process.wait(timeout=5)
    assert process.returncode==0,process.returncode

try:
    initialize()
    capabilities=ctl("seat capabilities",True)
    (BASE/"capabilities.json").write_text(json.dumps(capabilities,indent=2))
    assert all(feature in capabilities["features"] for feature in ("lock-scope-v1","private-output-v1","lock-aware-seat-input","lock-aware-export-v1","session-guard-v1")),capabilities
    print("Primary-display task continuity; management endpoint present:","management-display-v1" in capabilities["features"],flush=True)
    cli("create","continuing","--workspace","10","--virtual-output","1280x800","--human-lock-policy","continue")
    cli("create","pausing","--workspace","11","--virtual-output","1280x800")
    cli("create","task-continuing","--workspace","12","--virtual-output","1280x800","--human-lock-policy","continue")
    mcp=MCP("daily-lock-task")
    task=mcp.details("desktop_acquire",{"preferredDesktop":"task-continuing"})
    task_target={"desktop":task["desktop"]}
    assert task["name"]=="task-continuing"
    mcp.call("desktop_launch",task_target|{"argv":["/usr/bin/python3",str(ROOT/"test/agent-desktop-client.py"),"task-window",str(BASE/"task.txt")]})
    wait(lambda:any(c["title"]=="task-window" for c in ctl("clients",True)))
    task_before=mcp.details("desktop_state",task_target)
    task_frame=mcp.details("desktop_capture",task_target)
    mcp.call("desktop_input",task_target|{"frameId":task_frame["frameId"],"action":"text","text":"task-before-"})
    wait(lambda:(BASE/"task.txt").read_text()=="task-before-")
    bindings={}
    targets={}
    input_frames={}
    for name in ("continuing","pausing"):
        cli("resume",name)
        state=cli("state",name)
        start(["/usr/bin/python3",str(ROOT/"test/agent-desktop-client.py"),name+"-window",str(BASE/(name+".txt"))],name,ENV|{"WAYLAND_DISPLAY":state["display"]})
        wait(lambda:any(client["title"]==name+"-window" for client in ctl("clients",True)))
        bindings[name]=bind(name)
        targets[name]=cli("state",name)["windowId"]
        frame=tool(bindings[name],"capture")
        input_frames[name]=frame
        tool(bindings[name],"input",{"action":"text","text":"before-","frameId":frame["frameId"]})
        wait(lambda:(BASE/(name+".txt")).read_text()=="before-")
    binding=bindings["continuing"]
    browser=tool(binding,"browser")
    cdp=Cdp(browser["cdpUrl"])
    target=cdp.call("Target.createTarget",{"url":"data:text/html,<title>Lock continuity CDP</title><body>daily lock document</body>"})["targetId"]
    session=cdp.call("Target.attachToTarget",{"targetId":target,"flatten":True})["sessionId"]
    wait(lambda:cdp.call("Runtime.evaluate",{"expression":"document.body.textContent","returnByValue":True},session)["result"].get("value")=="daily lock document")
    browser_client=wait(lambda:next((c for c in ctl("clients",True) if c["title"].startswith("Lock continuity CDP")),None))
    OWNED_PIDS.append(browser_client["pid"])
    tool(binding,"focus",{"windowId":targets["continuing"]})
    before_frame=tool(binding,"capture")
    before=snapshot("before-human-lock")
    pam=BASE/"pam";pam.mkdir()
    (pam/"permit").write_text("auth required pam_permit.so\n")
    (pam/"other").write_text("auth required pam_deny.so\naccount required pam_deny.so\n")
    daily=provider("human","daily-primary")
    wait(lambda:ctl("seat lock-state",True)["scope"]=="scoped" and ctl("seat lock-state",True)["secure"])
    during=snapshot("during-human-lock")
    assert during["desktops"]["continuing"]["available"] and not during["desktops"]["continuing"]["paused"]
    assert during["desktops"]["continuing"]["generation"]==before["desktops"]["continuing"]["generation"]
    assert during["desktops"]["pausing"]["paused"]
    assert during["lock"]["lockEpoch"]>before["lock"]["lockEpoch"]
    task_locked=mcp.details("desktop_state",task_target)
    assert task_locked["humanLocked"] and task_locked["lockScope"]=="human" and task_locked["activity"]=="running"
    assert task_locked["generation"]==task_before["generation"]
    mcp.call("desktop_restore",task_target)
    task_frame=mcp.details("desktop_capture",task_target)
    mcp.call("desktop_input",task_target|{"frameId":task_frame["frameId"],"action":"text","text":"日常锁屏-"})
    wait(lambda:(BASE/"task.txt").read_text()=="task-before-日常锁屏-")
    record("real acquired MCP task retains reference, restore and Unicode input during daily lock")
    assert cdp.call("Runtime.evaluate",{"expression":"document.body.textContent","returnByValue":True},session)["result"]["value"]=="daily lock document"
    record("active original Chrome CDP session reads during primary-display human lock")
    error=tool(binding,"input",{"action":"text","text":"STALE","frameId":before_frame["frameId"]},succeeds=False)
    assert "stale" in error.lower(),error
    frame=tool(binding,"capture")
    (BASE/"private-during-human-lock.png").write_bytes(base64.b64decode(frame["pngBase64"]))
    tool(binding,"input",{"action":"text","text":"日常锁屏仍可输入","frameId":frame["frameId"]})
    wait(lambda:(BASE/"continuing.txt").read_text()=="before-日常锁屏仍可输入")
    tool(bindings["pausing"],"capture",succeeds=False)
    tool(bindings["pausing"],"input",{"action":"text","text":"FORBIDDEN","frameId":input_frames["pausing"]["frameId"]},succeeds=False)
    assert (BASE/"pausing.txt").read_text()=="before-"
    launched=tool(binding,"launch",{"argv":["/usr/bin/python3",str(ROOT/"test/agent-desktop-client.py"),"locked-launch-window",str(BASE/"locked-launch.txt")]})
    client=wait(lambda:next((c for c in ctl("clients",True) if c["title"]=="locked-launch-window"),None))
    OWNED_PIDS.append(client["pid"])
    assert cli("state","continuing")["generation"]==before["desktops"]["continuing"]["generation"]
    def visible_lock():
        from PIL import Image
        subprocess.run(["grim","-o","human",str(BASE/"primary-during-human-lock.png")],env=ENV,check=True)
        with Image.open(BASE/"primary-during-human-lock.png") as image:
            return max(high for low,high in image.convert("RGB").getextrema())>100
    wait(visible_lock)
    record("same original binding captures, inputs real Unicode and launches GTK; pause policy blocks its original binding")
    unlock(daily)
    after=snapshot("after-human-unlock")
    assert not after["desktops"]["continuing"]["paused"]
    assert after["desktops"]["continuing"]["generation"]==before["desktops"]["continuing"]["generation"]
    assert after["desktops"]["pausing"]["paused"]
    tool(binding,"focus",{"windowId":targets["continuing"]})
    frame=tool(binding,"capture")
    tool(binding,"input",{"action":"text","text":"-after","frameId":frame["frameId"]})
    wait(lambda:(BASE/"continuing.txt").read_text()=="before-日常锁屏仍可输入-after")
    assert cdp.call("Runtime.evaluate",{"expression":"document.title","returnByValue":True},session)["result"]["value"]=="Lock continuity CDP"
    record("human unlock retains original active binding and CDP; paused-policy desktop stays stopped")
    mcp.call("desktop_restore",task_target)
    task_unlocked=mcp.details("desktop_state",task_target)
    assert task_unlocked["generation"]==task_before["generation"] and task_unlocked["lockEpoch"]!=task_before["lockEpoch"]
    viewer=NativeViewer("task-continuing")
    viewer.request("present",{"name":"task-continuing"})
    viewer.request("takeover",{"name":"task-continuing"})
    # A real visible viewer keeps control beyond the 3s watchdog deadline.
    time.sleep(3.2)
    taken=mcp.details("desktop_state",task_target)
    assert taken["controlMode"]=="human" and taken["agentPaused"]
    mcp.call("desktop_restore",task_target,False)
    viewer.request("release",{"name":"task-continuing"})
    released=mcp.details("desktop_state",task_target)
    assert released["activity"]=="running" and not released["paused"]
    assert released["generation"]!=task_unlocked["generation"] and released["bindingRefreshRequired"]
    mcp.call("desktop_restore",task_target)
    task_frame=mcp.details("desktop_capture",task_target)
    mcp.call("desktop_input",task_target|{"frameId":task_frame["frameId"],"action":"text","text":"接管结束"})
    wait(lambda:(BASE/"task.txt").read_text()=="task-before-日常锁屏-接管结束")
    viewer.close()
    record("same real MCP task restores after daily unlock and normal takeover returns a fresh working input binding")
    full=provider("session","full-primary")
    wait(lambda:ctl("seat lock-state",True)["scope"]=="session" and ctl("seat lock-state",True)["secure"])
    full_state=snapshot("during-full-lock")
    mcp.call("desktop_restore",task_target,False)
    mcp.call("desktop_capture",task_target,False)
    mcp.call("desktop_input",task_target|{"frameId":task_frame["frameId"],"action":"text","text":"FORBIDDEN"},False)
    mcp.call("desktop_launch",task_target|{"argv":["/usr/bin/true"]},False)
    assert all(state["paused"] for state in full_state["desktops"].values())
    for name in ("continuing","pausing"):
        tool(bindings[name],"capture",succeeds=False)
        tool(bindings[name],"input",{"action":"text","text":"FORBIDDEN","frameId":input_frames[name]["frameId"]},succeeds=False)
        tool(bindings[name],"launch",{"argv":["/usr/bin/true"]},succeeds=False)
    try:
        cdp.call("Browser.getVersion")
        raise AssertionError("CDP survived full lock")
    except (ConnectionError,OSError): pass
    cdp.close()
    record("full lock revokes real original bindings, input/capture/launch and CDP")
    unlock(full)
    end=snapshot("after-full-unlock")
    assert all(state["paused"] for state in end["desktops"].values())
    mcp.call("desktop_restore",task_target,False)
    assert mcp.details("desktop_state",task_target)["paused"]
    mcp.call("desktop_finish",task_target|{"outcome":"cancelled","reason":"full lock revoked task; verification complete"})
    mcp.close()
    record("full unlock never automatically regrants any desktop or restores acquired MCP task")
    print("Artifacts:",BASE,flush=True)
finally:
    cleanup()
