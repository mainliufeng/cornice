#!/usr/bin/env node
/**
 * Production browser-tool boundary regressions.
 * Run: node test/agent-browser-tools-verify.ts
 * In Codex, run with escalation so real MCP can bind its private Unix socket.
 * Optional: CORNICE_TEST_PI=/path/to/pi CORNICE_TEST_PRODUCT=/path/to/cornice
 *
 * Pi's actual loader compiles the production module. Only ExtensionAPI scheduling
 * and desktop invoke replies are fixtures. The runtime test launches the real
 * Node/MCP subprocess and only initializes/lists tools: no browser or host seat.
 */
import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { accessSync, constants, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";

const PREFIX = "mcp__cornice_browser__";
const ALLOWED = ["browser_snapshot","browser_navigate","browser_navigate_back","browser_click",
  "browser_hover","browser_drag","browser_type","browser_fill_form","browser_select_option",
  "browser_press_key","browser_tabs","browser_wait_for","browser_handle_dialog"];
const FORBIDDEN = ["browser_run_code","browser_evaluate","browser_file_upload","browser_take_screenshot",
  "browser_install","browser_resize","browser_console_messages","browser_network_requests","browser_pdf_save"];
const delay = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

function executable(name: string): string {
  for (const path of name.includes("/") ? [resolve(name)] :
    (process.env.PATH ?? "").split(":").map(directory => join(directory || ".",name))) {
    try { accessSync(path,constants.X_OK); return realpathSync(path); } catch {}
  }
  throw new Error("Pi executable not found: "+name);
}
function packageRoot(entry: string): string {
  for (let path = dirname(entry); ; path = dirname(path)) {
    try {
      if (JSON.parse(readFileSync(join(path,"package.json"),"utf8")).name === "@earendil-works/pi-coding-agent")
        return path;
    } catch {}
    if (dirname(path) === path) throw new Error("Pi package directory not found");
  }
}

const product = resolve(process.env.CORNICE_TEST_PRODUCT ?? fileURLToPath(new URL("../",import.meta.url)));
const piEntry = executable(process.env.CORNICE_TEST_PI ?? "pi");
const piRoot = packageRoot(piEntry);
const artifacts = mkdtempSync(join(tmpdir(),"cornice-agent-browser-tools-"));
const mcpTemporary = mkdtempSync("/tmp/cmcp-browser-regression-");
const workspace = join(artifacts,"workspace");
mkdirSync(workspace,{mode:0o700});
const originalEnvironment = Object.fromEntries(["CORNICE_AGENT_BRIDGE","CORNICE_AGENT_JOB","CORNICE_AGENT_WORKSPACE"]
  .map(key => [key,process.env[key]]));
const checks: {name:string;elapsedMs:number}[] = [];
let supervisor: ChildProcessWithoutNullStreams | undefined;
let runtimePid: number | undefined;
let runtimeStartTime: string | undefined;
const timers: ReturnType<typeof setTimeout>[] = [];
async function check(name: string, run: () => unknown | Promise<unknown>) {
  const started = performance.now(); await run();
  checks.push({name,elapsedMs:Math.round(performance.now()-started)}); console.log("ok "+name);
}
function report(pass: boolean, error?: unknown) {
  writeFileSync(join(artifacts,"report.json"),JSON.stringify({
    pass,checks,product,artifacts,
    fixture:"test API/invoke replies; actual Pi loader, runtime and installed Node/MCP",
    ...(error === undefined ? {} : {error:error instanceof Error ? error.stack : String(error)}),
  },null,2));
  console.log(JSON.stringify({pass,checks:checks.length,artifacts}));
}

try {
  const {loadExtensions} = await import(pathToFileURL(join(piRoot,"dist/core/extensions/loader.js")).href);
  const {getMcpToolExposure} = await import(pathToFileURL(join(piRoot,"dist/core/mcp-servers.js")).href);
  const tools = new Map<string,any>(), hooks = new Map<string,Function[]>();
  const registrations: any[] = [], unregisters: string[] = [];
  let names = ["desktop_browser_connect","desktop_capture",PREFIX+"browser_snapshot"];
  let catalogReads = 0, registrationDelay = 50;
  const api = {
    on(event: string, handler: Function) { hooks.set(event,[...(hooks.get(event) ?? []),handler]); },
    registerTool(tool: any) { tools.set(tool.name,tool); },
    getActiveTools() { return [...names]; },
    // Deliberately retain stale catalog names after unregister. Readiness must
    // use active tools, matching Pi's separate inventory/active-tool contracts.
    getAllTools() { ++catalogReads; return [{name:PREFIX+"browser_snapshot"}]; },
    setActiveTools(next: string[]) { names = [...next]; },
    unregisterMcpServer(server: string) {
      unregisters.push(server); names = names.filter(name => !name.startsWith(PREFIX));
    },
    registerMcpServer(server: string, config: any) {
      registrations.push({server,config});
      timers.push(setTimeout(() => {
        names.push(...Object.keys(config.toolExposure).map(name => PREFIX+name));
      },registrationDelay));
    },
  };
  const baseline = {available:true,controlMode:"agent",paused:false,humanLocked:false,
    seatId:"fixture-seat",generation:"fixture-generation"};
  let state: any = {...baseline};
  let endpoint = "http://127.0.0.1:32145/fixture-cdp-grant-one";
  let interrupted = false;
  const calls: string[] = [];
  const invoke = async (operation: string) => {
    calls.push(operation);
    if (operation === "state") return {...state};
    assert.equal(operation,"browser");
    return interrupted ? {interrupted:true,message:"Fixture human owns control",control:{...state}} :
      {cdpUrl:endpoint,transport:"authorized-proxy-to-pipe"};
  };
  // The adapter is test-only. The imported registerBrowserTools implementation
  // and its Type/defineTool dependencies are loaded by installed Pi unchanged.
  (globalThis as any).__corniceBrowserTest = {api,invoke};
  const adapter = join(artifacts,"load-production-browser.ts");
  writeFileSync(adapter,
    "import { registerBrowserTools } from "+JSON.stringify(join(product,"native/agent/browser-tools.ts"))+";\n"+
    "export default function() { const fixture = (globalThis as any).__corniceBrowserTest; registerBrowserTools(fixture.api, fixture.invoke); }\n");
  process.env.CORNICE_AGENT_BRIDGE = join(product,"bin/cornice-agent-runtime");
  process.env.CORNICE_AGENT_JOB = artifacts;
  process.env.CORNICE_AGENT_WORKSPACE = workspace;
  await check("actual Pi loader registers the production browser extension",async () => {
    const result = await loadExtensions([adapter],artifacts);
    assert.deepEqual(result.errors,[]); assert.equal(result.extensions.length,1);
    assert.ok(tools.has("desktop_browser_connect"));
    for (const hook of ["tool_call","tool_result","session_shutdown"]) assert.equal(hooks.get(hook)?.length,1);
  });
  const callHook = (toolName = PREFIX+"browser_click") => hooks.get("tool_call")![0]({toolName,input:{}});
  await check("browser calls before connection are blocked",async () => {
    assert.equal((await callHook()).block,true);
  });
  await check("interrupted connect does not register MCP or grant control",async () => {
    interrupted = true; const result = await tools.get("desktop_browser_connect").execute("paused",{});
    assert.equal(result.details.interrupted,true); assert.equal(registrations.length,0); interrupted = false;
  });
  let connection: any;
  await check("connect result contains no CDP endpoint or seat grant",async () => {
    connection = await tools.get("desktop_browser_connect").execute("connect",{});
    assert.equal(connection.details.connected,true);
    assert.equal(connection.details.observation,"accessibility-tree");
    for (const secret of [endpoint,new URL(endpoint).pathname.slice(1)]) {
      assert.ok(!JSON.stringify(connection.content).includes(secret));
      assert.ok(!JSON.stringify(connection.details).includes(secret));
    }
  });
  await check("only 13 MCP tree/form tools plus connect are public",() => {
    const {server,config} = registrations.at(-1);
    assert.equal(server,"cornice_browser"); assert.equal(config.exposure,"hidden");
    assert.deepEqual(Object.keys(config.toolExposure).sort(),[...ALLOWED].sort());
    assert.equal(Object.keys(config.toolExposure).length+tools.size,14);
    for (const name of ALLOWED) assert.equal(getMcpToolExposure(config,name),"direct");
    for (const name of FORBIDDEN) assert.equal(getMcpToolExposure(config,name),"hidden");
    assert.deepEqual(connection.details.tools,[...ALLOWED].map(name => PREFIX+name));
    assert.equal(config.command,join(product,"bin/cornice-agent-runtime"));
    assert.deepEqual(config.args,["browser-mcp"]);
  });
  await check("normal browser call is allowed and unrelated tools are untouched",async () => {
    assert.equal(await callHook(),undefined);
    const before = calls.length; assert.equal(await callHook("desktop_capture"),undefined);
    assert.equal(calls.length,before);
  });
  for (const [name,change] of [
    ["finished task",{taskFinished:true}],
    ["human takeover",{controlMode:"human"}],
    ["paused desktop",{controlMode:"paused",paused:true}],
    ["paused flag with agent mode",{paused:true}],
    ["agentPaused flag",{agentPaused:true}],
    ["generation change",{generation:"fixture-next-generation"}],
    ["seat lifecycle change",{seatId:"fixture-next-seat"}],
    ["unavailable output",{available:false}],
    ["full session lock",{humanLocked:true,lockScope:"full",humanLockPolicy:"continue"}],
    ["daily lock pause policy",{humanLocked:true,lockScope:"human",humanLockPolicy:"pause"}],
  ] as const) {
    await check(name+" blocks browser tool call",async () => {
      state = {...baseline,...change}; const result = await callHook();
      assert.equal(result.block,true); assert.match(result.reason,/No browser action was sent/); state = {...baseline};
    });
  }
  await check("daily lock with explicit continue policy retains agent control",async () => {
    state = {...baseline,humanLocked:true,lockScope:"human",humanLockPolicy:"continue"};
    assert.equal(await callHook(),undefined); state = {...baseline};
  });
  await check("tool result recursively redacts endpoint and grant values",async () => {
    const grant = new URL(endpoint).pathname.slice(1);
    const event = {toolName:PREFIX+"browser_snapshot",
      content:[{type:"text",text:"fixture "+endpoint+" "+grant}],
      details:{url:endpoint,nested:[{grant,message:"nested "+grant}]},
    };
    const before = structuredClone(event); const result = await hooks.get("tool_result")![0](event);
    for (const secret of [endpoint,grant]) assert.ok(!JSON.stringify(result).includes(secret));
    assert.deepEqual(event,before);
    assert.match(JSON.stringify(result),/REDACTED/);
    assert.equal(await hooks.get("tool_result")![0]({...event,toolName:"desktop_capture"}),undefined);
  });
  await check("tool result redacts endpoint and grant used as object keys",async () => {
    const grant = new URL(endpoint).pathname.slice(1);
    const result = await hooks.get("tool_result")![0]({
      toolName:PREFIX+"browser_snapshot",content:[],
      details:{[endpoint]:"fixture",nested:{[grant]:"fixture"}},
    });
    for (const secret of [endpoint,grant]) assert.ok(!JSON.stringify(result).includes(secret));
  });
  await check("reconnect waits for active tools instead of stale tool inventory",async () => {
    endpoint = "http://127.0.0.1:32145/fixture-cdp-grant-two"; registrationDelay = 200;
    let settled = false;
    const pending = tools.get("desktop_browser_connect").execute("reconnect",{}).then((result: any) => {
      settled = true; return result;
    });
    await delay(100);
    assert.equal(settled,false); assert.ok(!names.includes(PREFIX+"browser_snapshot"));
    const result = await pending;
    assert.equal(result.details.connected,true); assert.ok(names.includes(PREFIX+"browser_snapshot"));
    assert.equal(catalogReads,0); assert.equal(registrations.length,2);
    const filtered = await hooks.get("tool_result")![0]({
      toolName:PREFIX+"browser_snapshot",content:[{type:"text",text:endpoint+" fixture-cdp-grant-one"}],details:{},
    });
    assert.ok(!JSON.stringify(filtered).includes(endpoint));
    assert.ok(!JSON.stringify(filtered).includes("fixture-cdp-grant-one"));
  });
  await check("session shutdown unregisters browser MCP",async () => {
    const before = unregisters.length; await hooks.get("session_shutdown")![0]({});
    assert.equal(unregisters.length,before+1); assert.equal(unregisters.at(-1),"cornice_browser");
  });

  const stderr: string[] = [];
  // A real private parent replicates Pi's detached MCP child lifecycle. Its only
  // fixture behavior is forwarding stdio; browser-mcp remains production code.
  const supervisorCode = String.raw`
import json, os, subprocess, sys
environment = dict(os.environ, CORNICE_AGENT_PI_PID=str(os.getpid()))
child = subprocess.Popen([sys.argv[1], 'browser-mcp'], stdin=subprocess.PIPE,
  stdout=sys.stdout, stderr=sys.stderr, start_new_session=True, env=environment)
print(json.dumps({'fixtureChildPid': child.pid}), flush=True)
for line in sys.stdin:
    child.stdin.write(line.encode()); child.stdin.flush()
`;
  const runtimeEnv = {
    PATH:process.env.PATH ?? "/usr/bin:/bin", HOME:workspace,
    CORNICE_AGENT_WORKSPACE:workspace,CORNICE_AGENT_NODE:process.execPath,CORNICE_AGENT_MCP_TMP:mcpTemporary,
    PLAYWRIGHT_MCP_CDP_ENDPOINT:"http://127.0.0.1:1/fixture-runtime-seat-grant",
    CORNICE_MODEL_TOKEN:"fixture-model-secret",API_KEY:"fixture-arbitrary-secret",
    WAYLAND_DISPLAY:"fixture-must-not-reach-mcp",DBUS_SESSION_BUS_ADDRESS:"unix:path="+join(artifacts,"absent-bus"),
    NODE_OPTIONS:"--require="+join(artifacts,"must-not-load.cjs"),
    PLAYWRIGHT_BROWSERS_PATH:join(artifacts,"must-not-inherit"),
    XDG_RUNTIME_DIR:workspace,HYPRLAND_INSTANCE_SIGNATURE:"fixture-not-a-session",
  };
  let requestId = 0;
  const responses = new Map<number,{resolve:Function;reject:Function;timer:ReturnType<typeof setTimeout>}>();
  let resolvePid: Function, rejectPid: Function;
  const pidPromise = new Promise<number>((resolve,reject) => {resolvePid=resolve;rejectPid=reject;});
  const pidTimeout = setTimeout(() => rejectPid(new Error("Runtime parent did not report child pid")),10000);
  supervisor = spawn("python3",["-u","-c",supervisorCode,join(product,"bin/cornice-agent-runtime")],
    {env:runtimeEnv,stdio:["pipe","pipe","pipe"]});
  supervisor.stderr.on("data",data => stderr.push(String(data).slice(0,16000)));
  const lines = createInterface({input:supervisor.stdout});
  lines.on("line",line => {
    try {
      const value = JSON.parse(line);
      if (value.fixtureChildPid) {clearTimeout(pidTimeout); resolvePid(value.fixtureChildPid);}
      if (typeof value.id === "number" && responses.has(value.id)) {
        const waiting = responses.get(value.id)!; clearTimeout(waiting.timer); responses.delete(value.id);
        waiting.resolve(value);
      }
    } catch {}
  });
  supervisor.on("error",error => {
    clearTimeout(pidTimeout); rejectPid(error);
    for (const request of responses.values()) {clearTimeout(request.timer);request.reject(error);}
  });
  supervisor.on("close",() => {
    for (const request of responses.values()) {
      clearTimeout(request.timer); request.reject(new Error("Runtime MCP exited: "+stderr.join("")));
    }
  });
  function request(method: string, params: unknown = {}): Promise<any> {
    const id = ++requestId;
    return new Promise((resolve,reject) => {
      const timer = setTimeout(() => {responses.delete(id);reject(new Error("MCP request timed out: "+method+" "+stderr.join("")));},10000);
      responses.set(id,{resolve,reject,timer});
      supervisor!.stdin.write(JSON.stringify({jsonrpc:"2.0",id,method,params})+"\n");
    });
  }
  await check("production runtime launches real installed Node/MCP",async () => {
    runtimePid = await pidPromise;
    const initialStat = readFileSync("/proc/"+runtimePid+"/stat","utf8");
    runtimeStartTime = initialStat.slice(initialStat.lastIndexOf(")")+2).split(" ")[19];
    const ready = await request("initialize",{
      protocolVersion:"2025-06-18",capabilities:{},clientInfo:{name:"cornice-boundary-regression",version:"1"},
    });
    assert.ok(!ready.error,JSON.stringify(ready.error)); assert.ok(ready.result?.serverInfo);
    supervisor!.stdin.write(JSON.stringify({jsonrpc:"2.0",method:"notifications/initialized"})+"\n");
    const inventory = await request("tools/list"); assert.ok(!inventory.error);
    const actual = new Set(inventory.result.tools.map((tool: any) => tool.name));
    for (const name of ALLOWED) assert.ok(actual.has(name),"installed MCP lacks "+name);
    const config = registrations.at(-1).config;
    for (const name of actual) assert.equal(getMcpToolExposure(config,name),ALLOWED.includes(name as string) ? "direct" : "hidden");
    writeFileSync(join(artifacts,"mcp-tools.json"),JSON.stringify([...actual],null,2));
    assert.equal(realpathSync("/proc/"+runtimePid+"/exe"),realpathSync(process.execPath));
  });
  await check("runtime child receives only grant and private workspace environment",() => {
    const environment = Object.fromEntries(readFileSync("/proc/"+runtimePid+"/environ","utf8")
      .split("\0").filter(Boolean).map(entry => {
        const delimiter = entry.indexOf("="); return [entry.slice(0,delimiter),entry.slice(delimiter+1)];
      }));
    assert.deepEqual(Object.keys(environment).sort(),[
      "HOME","PATH","TMPDIR","XDG_CONFIG_HOME","XDG_CACHE_HOME","PLAYWRIGHT_MCP_CDP_ENDPOINT","PWTEST_SOCKETS_DIR",
    ].sort());
    assert.equal(environment.HOME,workspace); assert.equal(environment.TMPDIR,mcpTemporary);
    assert.equal(environment.PWTEST_SOCKETS_DIR,mcpTemporary);
    assert.equal(environment.PLAYWRIGHT_MCP_CDP_ENDPOINT,runtimeEnv.PLAYWRIGHT_MCP_CDP_ENDPOINT);
    for (const key of ["CORNICE_MODEL_TOKEN","API_KEY","NODE_OPTIONS","WAYLAND_DISPLAY","DBUS_SESSION_BUS_ADDRESS","PLAYWRIGHT_BROWSERS_PATH"])
      assert.equal(environment[key],undefined);
  });
  await check("real detached MCP child stops when its parent dies",async () => {
    supervisor!.kill("SIGKILL");
    const until = Date.now()+5000;
    while (Date.now()<until) {
      try {
        const stat = readFileSync("/proc/"+runtimePid+"/stat","utf8");
        const status = stat.slice(stat.lastIndexOf(")")+2).split(" ")[0];
        if (status === "Z" || status === "X") return;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
        throw error;
      }
      await delay(50);
    }
    throw new Error("MCP child remained alive after fixture parent death");
  });
  writeFileSync(join(artifacts,"runtime.stderr.log"),stderr.join(""));
  report(true);
} catch (error) {
  report(false,error); process.exitCode = 1;
} finally {
  for (const timer of timers) clearTimeout(timer);
  delete (globalThis as any).__corniceBrowserTest;
  for (const [key,value] of Object.entries(originalEnvironment)) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
  if (supervisor && !supervisor.killed) supervisor.kill("SIGKILL");
  if (runtimePid && runtimeStartTime && existsSync("/proc/"+runtimePid)) {
    try {
      const stat = readFileSync("/proc/"+runtimePid+"/stat","utf8");
      const fields = stat.slice(stat.lastIndexOf(")")+2).split(" ");
      if (fields[19] === runtimeStartTime && fields[0] !== "Z")
        process.kill(runtimePid,"SIGKILL");
    } catch {}
  }
  rmSync(mcpTemporary,{recursive:true,force:true});
}
