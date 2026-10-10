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
import { tmpdir } from "node:os";
import { AsyncLocalStorage } from "node:async_hooks";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const bindingFile = process.env.CORNICE_MCP_BINDING;
const contexts = new Map(), current = new AsyncLocalStorage(), secrets = new Set();
const makeContext=()=>({controller:randomUUID(),finished:false});
const legacy = bindingFile ? makeContext() : undefined;
const context=()=>current.getStore();
const active = state => state.agentAllowed !== false && !state.paused && !state.agentPaused && state.available && state.controlMode === "agent" &&
  (!state.humanLocked || (state.lockScope === "human" && state.humanLockPolicy === "continue"));
const sanitize = value => {
  if (typeof value === "string") { for (const secret of secrets) value = value.replaceAll(secret, "[REDACTED]"); return value; }
  if (Array.isArray(value)) return value.map(sanitize);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k,v]) => [k,sanitize(v)]));
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
  secrets.add(value.token); if(value.taskToken)secrets.add(value.taskToken); c.binding = value;
  return value;
}
async function brokerEndpoint() {
  const runtime=process.env.XDG_RUNTIME_DIR || `/run/user/${process.getuid()}`;
  const instance=process.env.HYPRLAND_INSTANCE_SIGNATURE;
  if(instance && /^[A-Za-z0-9_.-]+$/.test(instance)) {
    const socket=join(runtime,"cornice",instance,"desktop.sock");
    const info=await lstat(socket).catch(()=>undefined);
    if(info?.isSocket() && info.uid===process.getuid()) return {instance,socket};
  }
  const endpoint=await privateJSON(join(runtime,"cornice/active.json")).catch(()=>{throw new Error("Cornice desktop service is unavailable. Start Cornice in the desktop session.");});
  if(!/^[A-Za-z0-9_.-]+$/.test(endpoint.instance) || endpoint.socket!==join(runtime,"cornice",endpoint.instance,"desktop.sock"))
    throw new Error("Invalid active desktop endpoint");
  return endpoint;
}
async function acquire(params) {
  if(bindingFile) throw new Error("This session already has an explicit assignment; automatic acquisition is unavailable");
  const endpoint=await brokerEndpoint(), c=makeContext(), reference=randomUUID();
  const socket=connectSocket(endpoint.socket); c.reservation=socket; c.automatic=true;
  try {
    const lease=await new Promise((resolveReply,reject)=> {
      let input=Buffer.alloc(0),done=false;
      const timer=setTimeout(()=>complete(new Error("Desktop allocation timed out; no desktop was selected")),15000);
      function complete(error,result) {if(done)return;done=true;clearTimeout(timer);error?reject(error):resolveReply(result);}
      socket.on("error",error=>complete(error));
      socket.on("end",()=>complete(new Error("Desktop allocation connection ended")));
      socket.on("connect",()=>socket.write(JSON.stringify({id:reference,method:"acquire-desktop",params:{...params,controller:c.controller,harness:harnessName()}})+"\n"));
      socket.on("data",chunk=>{
        input=Buffer.concat([input,chunk]);
        if(input.length>16384)return complete(new Error("Desktop allocation exceeded transport budget"));
        const end=input.indexOf(10);if(end<0)return;
        try {const reply=JSON.parse(input.subarray(0,end).toString());if(!reply.ok)throw new Error(reply.error||"Desktop allocation failed");complete(null,reply.result);}catch(error){complete(error);}
      });
    });
    if(lease.socket!==endpoint.socket || lease.instance!==endpoint.instance || !lease.token)throw new Error("Allocation identity mismatch");
    c.binding=lease; secrets.add(lease.token); if(lease.taskToken)secrets.add(lease.taskToken);
    const state=await current.run(c,()=>invoke("state"));
    contexts.set(reference,c);
    return {...state,desktop:reference,created:lease.created};
  } catch(error) {socket.destroy();throw error;}
}
function rpc(value, method, params, requestId) {
  const controller=context().controller;
  return new Promise((resolveReply,reject) => {
    const socket = connectSocket(value.socket); let input = Buffer.alloc(0), done = false;
    const timer = setTimeout(() => complete(new Error("Desktop response timed out. Action outcome is uncertain; inspect state before deciding what to do next.")), 8000);
    function complete(error,result) { if (done) return; done=true; clearTimeout(timer); socket.destroy(); error ? reject(error) : resolveReply(result); }
    socket.on("error", error => complete(error));
    socket.on("end", () => { if (!done) complete(new Error("Desktop service disconnected; action outcome may be uncertain")); });
    socket.on("connect", () => socket.write(JSON.stringify({id:controller+":"+String(requestId || randomUUID()),method,token:value.token,controller,harness:harnessName(),params})+"\n"));
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
  if (c.finished && operation !== "state") throw new Error("Task already finished; no further actions allowed");
  const value=await credential();
  if(operation==="finish") {
    try {await rpc(value,"desktop.release",{},extra.requestId);}
    catch(error) {if(!/binding revoked|binding revoked or unknown/.test(error.message))throw error;}
    finally {c.finished=true;c.reservation?.destroy();}
    return {outcome:params.outcome,reason:params.reason};
  }
  if (operation === "handoff" || (operation === "state" && c.automatic && value.taskToken && !c.finished)) {
    if (!value.taskToken) throw new Error("Updated Cornice Broker and task-owned acquisition are required for cooperation requests");
    const result = await rpc({...value, token:value.taskToken}, "desktop.handoff", operation === "state" ? {action:"status"} : params, extra.requestId);
    if (result.binding) { c.binding=result.binding;secrets.add(c.binding.token);await closeBrowser(); }
    if(operation === "handoff" && params.action === "request") c.handoffId = result.state.handoff?.id;
    verifyState(result.state);
    return operation === "state" ? result.state : {control:result.state,request:result.state.handoff || null,history:result.state.handoffs || []};
  }
  const result=await rpc(value,"desktop."+(operation==="browser_connect"?"browser":operation),params,extra.requestId);
  if(operation==="state")verifyState(result);
  return result;
}
async function closeBrowser() {
  const c=context(), old=c.browser;c.browser=undefined;c.browserIdentity=undefined;
  if(old)await old.close().catch(()=>{});
}
async function connectBrowser(extra) {
  const c=context(), state=await invoke("state",{},extra);
  if(!active(state))throw new Error("Desktop control is interrupted. No browser action was sent.");
  const connection=await invoke("browser",{},extra);if(connection.interrupted)return connection;
  const endpoint=new URL(connection.cdpUrl);
  if(endpoint.protocol!=="http:" || endpoint.hostname!=="127.0.0.1" || !endpoint.port || endpoint.pathname==="/")throw new Error("Invalid authorized browser endpoint");
  secrets.add(connection.cdpUrl);secrets.add(endpoint.pathname.slice(1));await closeBrowser();
  c.browserHome ||= await mkdtemp(join(process.env.CORNICE_MCP_TMPDIR || tmpdir(),"cornice-mcp-"));await chmod(c.browserHome,0o700);
  const client=new Client({name:"cornice-browser-adapter",version:"0.1.0"});
  const transport=new StdioClientTransport({command:join(root,"bin/cornice-desktop-mcp"),args:["--browser"],env:{PATH:process.env.PATH || "/usr/bin:/bin",PLAYWRIGHT_MCP_CDP_ENDPOINT:connection.cdpUrl,CORNICE_MCP_BROWSER_HOME:c.browserHome},cwd:c.browserHome,stderr:"pipe"});
  transport.stderr?.on("data",()=>{});
  try {
    await client.connect(transport);const available=await client.listTools();
    for(const tool of browserTools)if(!available.tools.some(item=>item.name===tool.name))throw new Error("Pinned browser tool missing: "+tool.name);
    const fresh=await invoke("state",{},extra);
    if(!active(fresh) || fresh.seatId!==state.seatId || fresh.generation!==state.generation)throw new Error("Control changed during browser connection; reconnect after restoration");
    c.browser=client;c.browserIdentity={seatId:state.seatId,generation:state.generation};
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
  {name:"desktop_wait",description:"Wait for explicit input restoration or completion/cancellation of the current human cooperation request. Does not resume or obtain control.",inputSchema:object({seconds:{type:"integer",minimum:1,maximum:30},reason:string},["seconds","reason"])},
  {name:"desktop_finish",description:"Release task control after verified completion, cancellation or an explained blocker. No more actions can follow.",inputSchema:object({outcome:{enum:["completed","cancelled","blocked"]},reason:string},["outcome","reason"])}
];
const browserSpec=JSON.parse(await readFile(join(root,"native/agent/browser-schema.json"),"utf8"));
const installedBrowser=JSON.parse(await readFile(join(root,"native/agent/node_modules/@playwright/mcp/package.json"),"utf8"));
if(installedBrowser.version!==browserSpec.version) throw new Error("Pinned browser dependency and tool schema differ");
const browserTools=browserSpec.tools;
const acquireTool={name:"desktop_acquire",description:"Acquire an allowed, idle desktop for this task. Reuse an unoccupied secondary desktop, preserving its applications, or create a new one if none is free. Use createNew for an empty desktop. An occupied preferredDesktop creates a new desktop; primary is never chosen implicitly. Keep the returned desktop reference and include it in every following tool call.",inputSchema:object({preferredDesktop:{type:"string",minLength:1,maxLength:64},createNew:{type:"boolean"}})};
const allTools=[acquireTool,...nativeTools,...browserTools].map(tool=>({...tool,inputSchema:{...tool.inputSchema,properties:{...tool.inputSchema.properties,...(tool.name==="desktop_acquire"?{}:{desktop:{type:"string",minLength:1,maxLength:128}})}}}));
const validator=new AjvJsonSchemaValidator();
const validators=new Map(allTools.map(tool=>[tool.name,validator.getValidator(tool.inputSchema)]));
const server=new Server({name:"cornice-desktop",version:"0.4.0"},{capabilities:{tools:{}},instructions:"Begin a desktop task with desktop_acquire. Retain its desktop reference and include it in every native and browser tool call. Each task has independent control. Primary desktop requires pre-enabled permission and explicit selection. On interruption stop input; do not reacquire to escape pause, human takeover or lock. Finish after verifying the requested result."});
function harnessName() {
  const name=process.env.CORNICE_HARNESS || server.getClientVersion()?.name || "external";
  if (/codex/i.test(name)) return "codex";
  if (/(^|[ _.\/-])pi($|[ _.\/-])/i.test(name)) return "pi";
  return name.toLowerCase().replace(/[^a-z0-9_.-]+/g,"-").slice(0,64) || "external";
}
server.setRequestHandler(ListToolsRequestSchema,async()=>({tools:allTools}));
const taskQueues=new Map();
server.setRequestHandler(CallToolRequestSchema,(request,extra)=> {
  const run=async()=> {
    try {
      const name=request.params.name,args=request.params.arguments || {};
      const validate=validators.get(name);if(!validate)throw new Error("Unknown desktop tool");
      const valid=validate(args);if(!valid.valid)throw new Error("Invalid tool arguments: "+valid.errorMessage);
      if(name==="desktop_acquire") {
        const result=await acquire(args);return {content:[{type:"text",text:JSON.stringify(sanitize(result))}],structuredContent:sanitize(result)};
      }
      const {desktop,...params}=args;
      const c=desktop ? contexts.get(desktop) : legacy;
      if(!c)throw new Error("Call desktop_acquire first, then include its desktop reference in every tool call");
      return await current.run(c,async()=> {
        if(c.finished && name!=="desktop_state")throw new Error("Task already finished; no further actions allowed");
        if(name.startsWith("browser_")) {
          const state=await invoke("state",{},extra);
          if(!c.browser || !active(state) || state.seatId!==c.browserIdentity.seatId || state.generation!==c.browserIdentity.generation) {
            await closeBrowser();throw new Error("Browser control interrupted or changed. Reconnect after explicit restoration and read a fresh snapshot; no browser action was sent.");
          }
          return sanitize(await c.browser.callTool({name,arguments:params}));
        }
        const operation=name.slice("desktop_".length);let result;
        if(operation==="browser_connect")result=await connectBrowser(extra);
        else if(operation==="wait") {
          const end=Date.now()+params.seconds*1000;
          do {
            if(extra.signal.aborted)throw new Error("Desktop wait cancelled");
            result=await invoke("state",{},extra);if(active(result) || (c.handoffId && result.handoff?.id === c.handoffId && ["completed","cancelled"].includes(result.handoff.status) && !result.handoff.restored))break;
            await new Promise(resolve=>setTimeout(resolve,250));
          }while(Date.now()<end);
          result={control:result,interrupted:!active(result),cooperationResolved:!!(c.handoffId && result.handoff?.id === c.handoffId && ["completed","cancelled"].includes(result.handoff.status) && !result.handoff.restored)};
        }else result=await invoke(operation,operation==="capture"?{encoding:"jpeg"}:params,extra);
        if(operation==="finish"){c.finished=true;await closeBrowser();}
        const {imageBase64,pngBase64,mimeType,...details}=result;
        const content=[{type:"text",text:JSON.stringify(sanitize(details))}];
        if(imageBase64 || pngBase64)content.push({type:"image",data:imageBase64 || pngBase64,mimeType:mimeType || "image/png"});
        return {content,structuredContent:sanitize(details)};
      });
    }catch(error){return {isError:true,content:[{type:"text",text:sanitize(error.message || String(error))}]};}
  };
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
    await closeBrowser();
    c.reservation?.destroy();
    if(c.binding && !c.finished)await rpc(c.binding,"desktop.release",{},"disconnect").catch(()=>{});
    if(c.browserHome)await rm(c.browserHome,{recursive:true,force:true});
  });
  await server.close().catch(()=>{});
}
process.on("SIGTERM",()=>{close().finally(()=>process.exit(0));});
process.on("SIGINT",()=>{close().finally(()=>process.exit(0));});
process.stdin.on("end",()=>{close().finally(()=>process.exit(0));});
await server.connect(new StdioServerTransport());
