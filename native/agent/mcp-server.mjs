import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { AjvJsonSchemaValidator } from "@modelcontextprotocol/sdk/validation/ajv";
import { connect as connectSocket } from "node:net";
import { readFile, lstat, mkdtemp, chmod, rm } from "node:fs/promises";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { desktopSocketPath } from "./desktop-endpoint.mjs";
import { tmpdir } from "node:os";
import { AsyncLocalStorage } from "node:async_hooks";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const bindingFile = process.env.CORNICE_MCP_BINDING;
const contexts = new Map(), current = new AsyncLocalStorage(), redactions = new AsyncLocalStorage();
const makeContext=()=>({controller:randomUUID(),finished:false});
const legacy = bindingFile ? makeContext() : undefined;
const context=()=>current.getStore();
const active = state => state.agentAllowed !== false && !state.paused && !state.agentPaused && state.available && state.controlMode === "agent" &&
  (!state.humanLocked || (state.lockScope === "human" && state.humanLockPolicy === "continue"));
// Retain credentials only for live tasks and the call currently producing a
// response. Rotated and completed task credentials do not become global history.
function rememberSecrets(...values) {
  const secrets=redactions.getStore();
  for(const value of values)if(typeof value === "string" && value)secrets?.add(value);
}
function secretValues() {
  const values=new Set(redactions.getStore() || []);
  for(const c of [...contexts.values(),...(legacy?[legacy]:[]),...(context()?[context()]:[])]) {
    for(const value of [c.binding?.token,c.binding?.taskToken,...(c.browserSecrets || [])])
      if(typeof value === "string" && value)values.add(value);
  }
  return values;
}
const sanitize = (value,secrets=secretValues()) => {
  if (typeof value === "string") { for (const secret of secrets) value = value.replaceAll(secret, "[REDACTED]"); return value; }
  if (Array.isArray(value)) return value.map(item=>sanitize(item,secrets));
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k,v]) => [k,sanitize(v,secrets)]));
  return value;
};
async function privateJSON(path) {
  const info=await lstat(path);
  if(!info.isFile() || info.isSymbolicLink() || info.uid!==process.getuid() || (info.mode&0o077) || info.size>16384)
    throw new Error("Private local configuration owned by this user is required");
  return JSON.parse(await readFile(path,"utf8"));
}
async function credential() {
  const c=context();
  const value=c.automatic ? c.binding : await privateJSON(bindingFile);
  if (!value?.token || !value.socket || !value.name || !value.seatId || !value.generation) throw new Error("Invalid desktop binding");
  if (c.identity && (c.identity.name !== value.name || c.identity.seatId !== value.seatId || c.identity.instance !== value.instance))
    throw new Error("Assigned desktop changed. Start a new task; no action was sent.");
  c.identity ||= {name:value.name,seatId:value.seatId,instance:value.instance};
  rememberSecrets(value.token,value.taskToken); c.binding = value;
  return value;
}
async function brokerEndpoint() {
  const runtime=process.env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`;
  const instance=process.env.HYPRLAND_INSTANCE_SIGNATURE;
  if(instance && /^[A-Za-z0-9_.-]+$/.test(instance)) {
    const socket=desktopSocketPath(runtime,instance);
    const info=await lstat(socket).catch(()=>undefined);
    if(info?.isSocket() && info.uid===process.getuid()) return {instance,socket};
  }
  const endpoint=await privateJSON(join(runtime,"cornice/active.json")).catch(()=>{throw new Error("Cornice desktop service is unavailable. Start Cornice in the desktop session.");});
  if(!/^[A-Za-z0-9_.-]+$/.test(endpoint.instance) || endpoint.socket!==desktopSocketPath(runtime,endpoint.instance))
    throw new Error("Invalid active desktop endpoint");
  return endpoint;
}
function cancelled(signal, submitted=false) {
  if (signal?.aborted) throw new Error(submitted ? "Desktop call cancelled after submission; action outcome may be uncertain. Inspect state before continuing." : "Desktop call cancelled before submission; no action was sent.");
}
async function acquire(params, extra={}) {
  cancelled(extra.signal);
  if(bindingFile) throw new Error("This session already has an explicit assignment; automatic acquisition is unavailable");
  const endpoint=await brokerEndpoint(), c=makeContext(), reference=randomUUID();
  cancelled(extra.signal);
  const socket=connectSocket(endpoint.socket); c.reservation=socket; c.automatic=true;
  try {
    const lease=await new Promise((resolveReply,reject)=> {
      let input=Buffer.alloc(0),done=false;
      const timer=setTimeout(()=>complete(new Error("Desktop allocation timed out; no desktop was selected")),15000);
      function complete(error,result) {if(done)return;done=true;clearTimeout(timer);extra.signal?.removeEventListener("abort",abort);error?reject(error):resolveReply(result);}
      function abort() {socket.destroy();complete(new Error("Desktop allocation cancelled; reservation released."));}
      extra.signal?.addEventListener("abort",abort,{once:true});
      if(extra.signal?.aborted)abort();
      socket.on("error",error=>complete(error));
      socket.on("end",()=>complete(new Error("Desktop allocation connection ended")));
      socket.on("connect",()=>{if(extra.signal?.aborted)return abort();socket.write(JSON.stringify({id:reference,method:"acquire-desktop",params:{...params,controller:c.controller,harness:harnessName()}})+"\n");});
      socket.on("data",chunk=>{
        input=Buffer.concat([input,chunk]);
        if(input.length>16384)return complete(new Error("Desktop allocation exceeded transport budget"));
        while(input.includes(10)) {
          const end=input.indexOf(10),line=input.subarray(0,end);input=input.subarray(end+1);
          try {
            const reply=JSON.parse(line.toString());
            if(reply.event === "desktop-state") {
              c.revision=reply.revision;
              // Logging is an observable MCP event for capable external clients,
              // not a request to start another Codex/Pi model turn.
              server.sendLoggingMessage({level:"info",logger:"cornice.desktop",data:sanitize({desktop:reference,event:reply.event,revision:reply.revision,state:reply.state})}).catch(()=>{});
              continue;
            }
            if(!reply.ok)throw new Error(reply.error||"Desktop allocation failed");complete(null,reply.result);
          }catch(error){complete(error);}
        }
      });
    });
    if(lease.socket!==endpoint.socket || lease.instance!==endpoint.instance || !lease.token)throw new Error("Allocation identity mismatch");
    c.binding=lease;rememberSecrets(lease.token,lease.taskToken);
    const state=await current.run(c,()=>invoke("state",{},extra));
    cancelled(extra.signal);
    c.reference=reference;contexts.set(reference,c);
    return {...state,desktop:reference,created:lease.created};
  } catch(error) {socket.destroy();throw error;}
}
function rpc(value, method, params, requestId, options={}) {
  cancelled(options.signal);
  const controller=context().controller;
  return new Promise((resolveReply,reject) => {
    const socket = connectSocket(value.socket); let input = Buffer.alloc(0), done = false, submitted=false;
    const timer = setTimeout(() => complete(new Error("Desktop response timed out. Action outcome is uncertain; inspect state before deciding what to do next.")), options.timeoutMs || 8000);
    function complete(error,result) { if (done) return; done=true; clearTimeout(timer);options.signal?.removeEventListener("abort",abort);socket.destroy();error ? reject(error) : resolveReply(result); }
    function abort() {complete(new Error(submitted ? "Desktop call cancelled after submission; action outcome may be uncertain. Inspect state before continuing." : "Desktop call cancelled before submission; no action was sent."));}
    options.signal?.addEventListener("abort",abort,{once:true});
    if(options.signal?.aborted)abort();
    socket.on("error", error => complete(error));
    socket.on("end", () => { if (!done) complete(new Error("Desktop service disconnected; action outcome may be uncertain")); });
    socket.on("connect", () => {if(options.signal?.aborted || done)return abort();submitted=true;socket.write(JSON.stringify({id:controller+":"+String(requestId || randomUUID()),method,token:value.token,controller,harness:harnessName(),params})+"\n");});
    socket.on("data", chunk => {
      input = Buffer.concat([input,chunk]);
      if (input.length > 64*1024*1024) return complete(new Error("Desktop response exceeded the transport budget"));
      const end = input.indexOf(10); if (end < 0) return;
      try { const reply=JSON.parse(input.subarray(0,end).toString()); if (!reply.ok) throw new Error(reply.error || "Desktop action failed"); complete(null,reply.result); }
      catch(error) { complete(error); }
    });
  });
}
function verifyState(state) {
  if(typeof state.primary!=="boolean" || typeof state.agentAllowed!=="boolean" || !Number.isInteger(state.number) || state.number<1)
    throw new Error("Updated Cornice Broker is required; desktop permission contract is unavailable. No action was sent.");
}
async function invoke(operation,params={},extra={}) {
  const c=context();
  cancelled(extra.signal);
  if (c.finished) throw new Error("Task already finished; its desktop reference no longer permits actions or live state reads");
  const value=await credential();
  cancelled(extra.signal);
  if(operation==="finish") {
    try {await rpc(value,"desktop.release",{},extra.requestId,extra);}
    catch(error) {if(!/binding revoked|binding revoked or unknown/.test(error.message))throw error;}
    finally {c.finished=true;c.reservation?.destroy();}
    return {outcome:params.outcome,reason:params.reason};
  }
  if(operation === "restore" || operation === "wait") {
    if(!c.automatic || !value.taskToken)throw new Error("Task-owned acquisition is required for restoration and event waiting");
    const result=await rpc({...value,token:value.taskToken},"desktop.task",{...params,action:operation},extra.requestId,{...extra,timeoutMs:operation === "wait" ? params.seconds*1000+3000 : 8000});
    if(result.binding){c.binding=result.binding;rememberSecrets(c.binding.token,c.binding.taskToken);await closeBrowser();}
    const {binding,...details}=result;return details;
  }
  if (operation === "handoff" || (operation === "state" && c.automatic && value.taskToken && !c.finished)) {
    if (!value.taskToken) throw new Error("Updated Cornice Broker and task-owned acquisition are required for cooperation requests");
    const result = await rpc({...value, token:value.taskToken}, "desktop.handoff", operation === "state" ? {action:"status"} : params, extra.requestId,extra);
    if (result.binding) { c.binding=result.binding;rememberSecrets(c.binding.token,c.binding.taskToken);await closeBrowser(); }
    if(operation === "handoff" && params.action === "request") c.handoffId = result.state.handoff?.id;
    verifyState(result.state);
    if(operation === "state")result.state.bindingRefreshRequired = result.state.generation !== value.generation && active(result.state);
    return operation === "state" ? result.state : {control:result.state,request:result.state.handoff || null,history:result.state.handoffs || []};
  }
  const result=await rpc(value,"desktop."+(operation==="browser_connect"?"browser":operation),params,extra.requestId,
    operation==="browser" || operation==="launch" ? {...extra,timeoutMs:15000} : extra);
  if(operation==="state")verifyState(result);
  return result;
}
async function closeBrowser() {
  const c=context(), old=c.browser;rememberSecrets(...(c.browserSecrets || []));
  c.browser=undefined;c.browserIdentity=undefined;c.browserSecrets=undefined;
  if(old)await old.close().catch(()=>{});
}
async function retireContext(c) {
  if(c.reference)contexts.delete(c.reference);
  c.reservation?.destroy();c.reservation=undefined;
  await closeBrowser();
  if(c.browserHome)await rm(c.browserHome,{recursive:true,force:true}).catch(error=>console.error("Cornice MCP temporary browser cleanup failed: "+sanitize(error.message)));
  c.browserHome=undefined;c.binding=undefined;c.identity=undefined;
}
async function connectBrowser(extra) {
  const c=context(), state=await invoke("state",{},extra);
  if(!active(state))throw new Error("Desktop control is interrupted. No browser action was sent.");
  const connection=await invoke("browser",{},extra);if(connection.interrupted)return connection;
  const endpoint=new URL(connection.cdpUrl);
  if(endpoint.protocol!=="http:" || endpoint.hostname!=="127.0.0.1" || !endpoint.port || endpoint.pathname==="/")throw new Error("Invalid authorized browser endpoint");
  rememberSecrets(connection.cdpUrl,endpoint.pathname.slice(1));await closeBrowser();
  c.browserHome ||= await mkdtemp(join(process.env.CORNICE_MCP_TMPDIR || tmpdir(),"cornice-mcp-"));await chmod(c.browserHome,0o700);
  const client=new Client({name:"cornice-browser-adapter",version:"0.1.0"});
  const transport=new StdioClientTransport({command:join(root,"bin/cornice-desktop-mcp"),args:["--browser"],env:{PATH:process.env.PATH || "/usr/bin:/bin",PLAYWRIGHT_MCP_CDP_ENDPOINT:connection.cdpUrl,CORNICE_MCP_BROWSER_HOME:c.browserHome},cwd:c.browserHome,stderr:"pipe"});
  transport.stderr?.on("data",()=>{});
  try {
    await client.connect(transport);const available=await client.listTools();
    for(const tool of browserTools)if(!available.tools.some(item=>item.name===tool.name))throw new Error("Pinned browser tool missing: "+tool.name);
    const fresh=await invoke("state",{},extra);
    if(!active(fresh) || fresh.seatId!==state.seatId || fresh.generation!==state.generation)throw new Error("Control changed during browser connection; reconnect after restoration");
    c.browser=client;c.browserIdentity={seatId:state.seatId,generation:state.generation};c.browserSecrets=[connection.cdpUrl,endpoint.pathname.slice(1)];
    return {connected:true,seatId:state.seatId,generation:state.generation,observation:"accessibility-tree"};
  } catch(error) {await client.close().catch(()=>{});throw error;}
}
const object = (properties={},required=[])=>({type:"object",properties,required,additionalProperties:false});
const string={type:"string"}, number={type:"number"};
const nativeTools=[
  {name:"desktop_handoff",description:"Request human takeover with precise instructions; read the task/status history; resolve completed or cancelled at the user's request, including remotely releasing this request's human takeover; resume only after resolution. Requests pause input. Keep the desktop reference and requestId; never reacquire. UI completion does not wake the harness automatically: read status or desktop_wait, then resume and observe afresh.",inputSchema:{...object({action:{enum:["request","status","resolve","resume"]},title:{type:"string",minLength:1,maxLength:160},instructions:{type:"string",minLength:1,maxLength:4000},requestId:string,outcome:{enum:["completed","cancelled"]},note:{type:"string",minLength:1,maxLength:2000}},["action"]),oneOf:[{properties:{action:{const:"status"}}},{properties:{action:{const:"request"}},required:["title","instructions"]},{properties:{action:{const:"resolve"}},required:["requestId","outcome","note"]},{properties:{action:{const:"resume"}},required:["requestId"]}]}},
  {name:"desktop_state",description:"Read the assigned desktop's identity, permissions, controller and workspace. Begin here; no default desktop fallback.",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"desktop_capture",description:"Capture this desktop only. Use pixelSize coordinates and the returned fresh frameId for native input. Prefer browser trees for browser tasks.",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"desktop_windows",description:"List windows on this desktop's current workspace.",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"desktop_snapshot",description:"Read the real AT-SPI element tree of a window on this desktop's current workspace (focused window by default). Returns roles, text, states and short-lived element references. Unsupported applications fail explicitly; use capture when visual information is needed.",inputSchema:object({windowId:string,maxNodes:{type:"integer",minimum:1,maximum:300},maxDepth:{type:"integer",minimum:1,maximum:20}}),annotations:{readOnlyHint:true}},
  {name:"desktop_action",description:"Perform a semantic native click, setText or focus using a fresh desktop_snapshot. One mutation invalidates its references. Desktop/workspace/control changes reject stale actions.",inputSchema:{...object({snapshotId:string,elementRef:string,action:{enum:["click","setText","focus"]},text:{type:"string",maxLength:8192}},["snapshotId","elementRef","action"]),oneOf:[{properties:{action:{enum:["click","focus"]}}},{properties:{action:{const:"setText"}},required:["text"]}]}},
  {name:"desktop_input",description:"Send one native action to this desktop using a fresh frameId. Chord key names use XKB, e.g. CTRL,a or Return.",inputSchema:object({frameId:string,action:{enum:["click","move","text","chord","scroll"]},x:number,y:number,text:{type:"string",maxLength:16384},keys:{type:"array",items:string,minItems:1,maxItems:8},button:{enum:["left","right","middle"]},delta:number,axis:{enum:["vertical","horizontal"]}},["frameId","action"])},
  {name:"desktop_workspace",description:"Switch this desktop's own workspace. Give a workspace identifier or slot 1–10; observe again afterwards.",inputSchema:{...object({workspace:{type:"string",minLength:1,maxLength:128},slot:{type:"integer",minimum:1,maximum:10}}),oneOf:[{required:["workspace"]},{required:["slot"]}]}},
  {name:"desktop_focus",description:"Focus an exact windowId in this desktop's current workspace, then observe again.",inputSchema:object({windowId:string},["windowId"])},
  {name:"desktop_launch",description:"Launch an application on this desktop. Browser tasks use desktop_browser_connect. This is application launch, not an OS sandbox.",inputSchema:object({argv:{type:"array",items:string,minItems:1,maxItems:128}},["argv"])},
  {name:"desktop_browser_connect",description:"Open or reconnect this desktop's managed browser. Then use browser_tabs and browser_snapshot. Uses only the Broker's authorized CDP grant.",inputSchema:object()},
  {name:"desktop_restore",description:"Receive a fresh task binding after explicit operator restoration. Does not resume a paused desktop, undo independent human control, or bypass a later lock/permission change. Reconnect browser and observe after success.",inputSchema:object()},
  {name:"desktop_wait",description:"Wait for explicit input restoration or completion/cancellation of the current human cooperation request. Does not resume or obtain control.",inputSchema:object({seconds:{type:"integer",minimum:1,maximum:30},reason:string},["seconds","reason"])},
  {name:"desktop_finish",description:"Release task control after verified completion, cancellation or an explained blocker. Retire the desktop reference; further actions and live state reads require a new task.",inputSchema:object({outcome:{enum:["completed","cancelled","blocked"]},reason:string},["outcome","reason"])}
];
const browserSpec=JSON.parse(await readFile(join(root,"native/agent/browser-schema.json"),"utf8"));
const installedBrowser=JSON.parse(await readFile(join(root,"native/agent/node_modules/@playwright/mcp/package.json"),"utf8"));
if(installedBrowser.version!==browserSpec.version) throw new Error("Pinned browser dependency and tool schema differ");
const browserTools=browserSpec.tools;
const acquireTool={name:"desktop_acquire",description:"Acquire an allowed, idle desktop for this task. Reuse an unoccupied secondary desktop, preserving its applications, or create a new one if none is free. Use createNew for an empty desktop. An occupied preferredDesktop creates a new desktop; primary is never chosen implicitly. Keep the returned desktop reference and include it in every following tool call.",inputSchema:object({preferredDesktop:{type:"string",minLength:1,maxLength:64},createNew:{type:"boolean"}})};
const allTools=[acquireTool,...nativeTools,...browserTools].map(tool=>({...tool,inputSchema:{...tool.inputSchema,properties:{...tool.inputSchema.properties,...(tool.name==="desktop_acquire"?{}:{desktop:{type:"string",minLength:1,maxLength:128}})}}}));
const validator=new AjvJsonSchemaValidator();
const validators=new Map(allTools.map(tool=>[tool.name,validator.getValidator(tool.inputSchema)]));
const server=new Server({name:"cornice-desktop",version:"0.4.0"},{capabilities:{tools:{},logging:{}},instructions:"Begin a desktop task with desktop_acquire. Retain its desktop reference and include it in every native and browser tool call. Each task has independent control. Primary desktop requires pre-enabled permission and explicit selection. On interruption stop input; do not reacquire to escape pause, human takeover or lock. Finish after verifying the requested result."});
function harnessName() {
  const name=process.env.CORNICE_HARNESS || server.getClientVersion()?.name || "external";
  if (/codex/i.test(name)) return "codex";
  if (/(^|[ _.\/-])pi($|[ _.\/-])/i.test(name)) return "pi";
  return name.toLowerCase().replace(/[^a-z0-9_.-]+/g,"-").slice(0,64) || "external";
}
server.setRequestHandler(ListToolsRequestSchema,async()=>({tools:allTools}));
const taskQueues=new Map();
server.setRequestHandler(CallToolRequestSchema,(request,extra)=> {
  const run=()=>redactions.run(new Set(),async()=> {
    let task;
    try {
      cancelled(extra.signal);
      const name=request.params.name,args=request.params.arguments || {};
      const validate=validators.get(name);if(!validate)throw new Error("Unknown desktop tool");
      const valid=validate(args);if(!valid.valid)throw new Error("Invalid tool arguments: "+valid.errorMessage);
      if(name==="desktop_acquire") {
        const result=await acquire(args,extra);return {content:[{type:"text",text:JSON.stringify(sanitize(result))}],structuredContent:sanitize(result)};
      }
      const {desktop,...params}=args;
      const c=desktop ? contexts.get(desktop) : legacy;
      if(!c)throw new Error("Desktop reference is finished, expired or unknown. Call desktop_acquire for a new task and retain its reference.");
      task=c;
      return await current.run(c,async()=> {
        if(c.finished)throw new Error("Task already finished; its desktop reference no longer permits actions or live state reads");
        if(name.startsWith("browser_")) {
          const state=await invoke("state",{},extra);
          if(!c.browser || !active(state) || state.seatId!==c.browserIdentity.seatId || state.generation!==c.browserIdentity.generation) {
            await closeBrowser();throw new Error("Browser control interrupted or changed. Reconnect after explicit restoration and read a fresh snapshot; no browser action was sent.");
          }
          cancelled(extra.signal);
          return sanitize(await c.browser.callTool({name,arguments:params},undefined,{signal:extra.signal}));
        }
        const operation=name.slice("desktop_".length);let result;
        if(operation==="browser_connect")result=await connectBrowser(extra);
        else result=await invoke(operation,operation==="capture"?{encoding:"jpeg"}:params,extra);
        if(operation==="finish"){c.finished=true;await closeBrowser();}
        const {imageBase64,pngBase64,mimeType,...details}=result;
        const content=[{type:"text",text:JSON.stringify(sanitize(details))}];
        if(imageBase64 || pngBase64)content.push({type:"image",data:imageBase64 || pngBase64,mimeType:mimeType || "image/png"});
        return {content,structuredContent:sanitize(details)};
      });
    }catch(error){return {isError:true,content:[{type:"text",text:sanitize(error.message || String(error))}]};}
    finally {if(task?.finished)await current.run(task,()=>retireContext(task));}
  });
  // Serialize mutations within one task, while independent desktops keep
  // responding during a slow native application or browser request.
  const key=request.params.name === "desktop_acquire" ? Symbol() : request.params.arguments?.desktop || "explicit-binding";
  const previous=taskQueues.get(key) || Promise.resolve();
  const pending=previous.then(run,run);
  const settled=pending.then(()=>{},()=>{});
  taskQueues.set(key,settled);
  settled.finally(()=>{if(taskQueues.get(key)===settled)taskQueues.delete(key);});
  return pending;
});
let closing=false;
const heartbeat=setInterval(()=> {
  for(const c of [...contexts.values(),...(legacy?[legacy]:[])])
    if(c.binding && !c.finished && !closing)current.run(c,()=>invoke("state").catch(()=>{}));
},1000);
heartbeat.unref();
async function close() {
  if(closing)return;closing=true;clearInterval(heartbeat);
  for(const c of [...contexts.values(),...(legacy?[legacy]:[])])await current.run(c,async()=> {
    if(c.binding && !c.finished)await rpc(c.binding,"desktop.release",{},"disconnect").catch(()=>{});
    await retireContext(c);
  });
  await server.close().catch(()=>{});
}
process.on("SIGTERM",()=>{close().finally(()=>process.exit(0));});
process.on("SIGINT",()=>{close().finally(()=>process.exit(0));});
process.stdin.on("end",()=>{close().finally(()=>process.exit(0));});
await server.connect(new StdioServerTransport());
