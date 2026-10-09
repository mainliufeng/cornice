import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { AjvJsonSchemaValidator } from "@modelcontextprotocol/sdk/validation/ajv";
import { connect as connectSocket } from "node:net";
import { spawn } from "node:child_process";
import { readFile, lstat, mkdtemp, chmod, rm } from "node:fs/promises";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { homedir, tmpdir } from "node:os";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const bindingFile = process.env.CORNICE_MCP_BINDING || join(process.env.XDG_STATE_HOME || join(homedir(), ".local/state"), "cornice/harness/codex.binding.json");
const job = process.env.CORNICE_AGENT_JOB;
let identity, binding, finished = false, browser, browserIdentity, browserHome;
const secrets = new Set();
const instanceId = randomUUID();
process.env.CORNICE_DESKTOP_CONTROLLER = instanceId;
const active = state => state.agentAllowed !== false && !state.taskFinished && !state.paused && !state.agentPaused && state.available && state.controlMode === "agent" &&
  (!state.humanLocked || (state.lockScope === "human" && state.humanLockPolicy === "continue"));
const sanitize = value => {
  if (typeof value === "string") { for (const secret of secrets) value = value.replaceAll(secret, "[REDACTED]"); return value; }
  if (Array.isArray(value)) return value.map(sanitize);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k,v]) => [k,sanitize(v)]));
  return value;
};
async function credential() {
  const info = await lstat(bindingFile).catch(() => { throw new Error("No desktop assigned. Use cornice desktop attach NAME codex after enabling Agent control on that desktop. No desktop was selected automatically."); });
  if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.getuid() || (info.mode & 0o077) || info.size > 16384)
    throw new Error("A private desktop binding file owned by this user is required");
  const value = JSON.parse(await readFile(bindingFile, "utf8"));
  if (!value.token || !value.socket || !value.name || !value.seatId || !value.generation) throw new Error("Invalid desktop binding");
  if (identity && (identity.name !== value.name || identity.seatId !== value.seatId || identity.instance !== value.instance))
    throw new Error("Assigned desktop changed. Start a new MCP session; no action was sent.");
  identity ||= {name:value.name,seatId:value.seatId,instance:value.instance};
  secrets.add(value.token); binding = value;
  return value;
}
function rpc(value, method, params, requestId) {
  return new Promise((resolveReply,reject) => {
    const socket = connectSocket(value.socket); let input = Buffer.alloc(0), done = false;
    const timer = setTimeout(() => complete(new Error("Desktop response timed out. Action outcome is uncertain; inspect state before deciding what to do next.")), 8000);
    function complete(error,result) { if (done) return; done=true; clearTimeout(timer); socket.destroy(); error ? reject(error) : resolveReply(result); }
    socket.on("error", error => complete(error));
    socket.on("end", () => { if (!done) complete(new Error("Desktop service disconnected; action outcome may be uncertain")); });
    socket.on("connect", () => socket.write(JSON.stringify({id:instanceId+":"+String(requestId || randomUUID()),method,token:value.token,controller:instanceId,params})+"\n"));
    socket.on("data", chunk => {
      input = Buffer.concat([input,chunk]);
      if (input.length > 64*1024*1024) return complete(new Error("Desktop response exceeded the transport budget"));
      const end = input.indexOf(10); if (end < 0) return;
      try { const reply=JSON.parse(input.subarray(0,end).toString()); if (!reply.ok) throw new Error(reply.error || "Desktop action failed"); complete(null,reply.result); }
      catch(error) { complete(error); }
    });
  });
}
function bridge(operation, params, signal) {
  return new Promise((resolveReply,reject) => {
    const executable = process.env.CORNICE_AGENT_BRIDGE;
    if (!executable) return reject(new Error("Desktop job bridge is missing"));
    const child = spawn(executable,["bridge",operation],{stdio:["pipe","pipe","pipe"],signal}); let out="",error="";
    const timer=setTimeout(()=>{child.kill("SIGKILL");reject(new Error("Desktop job response timed out; action outcome may be uncertain"));},operation==="wait"?(params.seconds || 30)*1000+5000:10000);
    child.on("error",error=>{clearTimeout(timer);reject(error);});
    child.stdout.on("data",data=>{out+=data;if(Buffer.byteLength(out)>64*1024*1024){child.kill("SIGKILL");reject(new Error("Desktop response exceeded the transport budget"));}});
    child.stderr.on("data",data=>{error=(error+data).slice(-8192);});
    child.on("close",code=> { clearTimeout(timer); if(code!==0) return reject(new Error(error.trim() || "Desktop job bridge failed")); try {const value=JSON.parse(out);if(!value || typeof value!=="object" || Array.isArray(value)) throw new Error("Invalid desktop bridge response");resolveReply(value);} catch(e){reject(e);} });
    child.stdin.on("error",reject); child.stdin.end(JSON.stringify(params));
  });
}
function verifyState(state) {
  if(typeof state.primary!=="boolean" || typeof state.agentAllowed!=="boolean" || !Number.isInteger(state.number) || state.number<1)
    throw new Error("Updated Cornice Broker is required; desktop permission contract is unavailable. No action was sent.");
}
async function invoke(operation,params={},extra={}) {
  if (finished && operation !== "state") throw new Error("Task already finished; no further actions allowed");
  if (job) {
    const result=await bridge(operation,params,extra.signal);
    if(operation==="state") verifyState(result);
    return result;
  }
  const value=await credential();
  if(operation==="finish") {
    await rpc(value,"desktop.release",{},extra.requestId); finished=true; return {outcome:params.outcome,reason:params.reason};
  }
  const result=await rpc(value,"desktop."+(operation==="browser_connect"?"browser":operation),params,extra.requestId);
  if(operation==="state") verifyState(result);
  return result;
}
async function closeBrowser() {
  const old=browser; browser=undefined; browserIdentity=undefined;
  if(old) await old.close().catch(()=>{});
}
async function connectBrowser(extra) {
  const state=await invoke("state",{},extra);
  if(!active(state)) throw new Error("Desktop control is interrupted. Wait for explicit restoration; no browser action was sent.");
  const connection=await invoke("browser",{},extra);
  if(connection.interrupted) return connection;
  const endpoint=new URL(connection.cdpUrl);
  if(endpoint.protocol!=="http:" || endpoint.hostname!=="127.0.0.1" || !endpoint.port || endpoint.pathname==="/") throw new Error("Invalid authorized browser endpoint");
  secrets.add(connection.cdpUrl); secrets.add(endpoint.pathname.slice(1));
  await closeBrowser();
  browserHome ||= await mkdtemp(join(process.env.CORNICE_AGENT_MCP_TMP || tmpdir(),"cornice-mcp-")); await chmod(browserHome,0o700);
  const client=new Client({name:"cornice-browser-adapter",version:"0.1.0"});
  const transport=new StdioClientTransport({command:join(root,"bin/cornice-desktop-mcp"),args:["--browser"],
    env:{PATH:process.env.PATH || "/usr/bin:/bin",PLAYWRIGHT_MCP_CDP_ENDPOINT:connection.cdpUrl,CORNICE_MCP_BROWSER_HOME:browserHome},cwd:browserHome,stderr:"pipe"});
  transport.stderr?.on("data",()=>{}); // Credential-bearing diagnostics never enter model context.
  try {
    await client.connect(transport); const available=await client.listTools();
    for(const tool of browserTools) if(!available.tools.some(item=>item.name===tool.name)) throw new Error("Pinned browser tool missing: "+tool.name);
    const current=await invoke("state",{},extra);
    if(!active(current) || current.seatId!==state.seatId || current.generation!==state.generation) throw new Error("Control changed during browser connection; reconnect after restoration");
    browser=client;browserIdentity={seatId:state.seatId,generation:state.generation};
    return {connected:true,seatId:state.seatId,generation:state.generation,observation:"accessibility-tree"};
  } catch(error) { await client.close().catch(()=>{}); throw error; }
}
const object = (properties={},required=[])=>({type:"object",properties,required,additionalProperties:false});
const string={type:"string"}, number={type:"number"};
const nativeTools=[
  {name:"desktop_state",description:"Read the assigned desktop's identity, permissions, controller and workspace. Begin here; no default desktop fallback.",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"desktop_capture",description:"Capture this desktop only. Use pixelSize coordinates and the returned fresh frameId for native input. Prefer browser trees for browser tasks.",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"desktop_windows",description:"List windows on this desktop's current workspace.",inputSchema:object(),annotations:{readOnlyHint:true}},
  {name:"desktop_input",description:"Send one native action to this desktop using a fresh frameId. Chord key names use XKB, e.g. CTRL,a or Return.",inputSchema:object({frameId:string,action:{enum:["click","move","text","chord","scroll"]},x:number,y:number,text:{type:"string",maxLength:16384},keys:{type:"array",items:string,minItems:1,maxItems:8},button:{enum:["left","right","middle"]},delta:number,axis:{enum:["vertical","horizontal"]}},["frameId","action"])},
  {name:"desktop_workspace",description:"Switch this desktop's own workspace. Give a workspace identifier or slot 1–10; observe again afterwards.",inputSchema:{...object({workspace:{type:"string",minLength:1,maxLength:128},slot:{type:"integer",minimum:1,maximum:10}}),oneOf:[{required:["workspace"]},{required:["slot"]}]}},
  {name:"desktop_focus",description:"Focus an exact windowId in this desktop's current workspace, then observe again.",inputSchema:object({windowId:string},["windowId"])},
  {name:"desktop_launch",description:"Launch an application on this desktop. Browser tasks use desktop_browser_connect. This is application launch, not an OS sandbox.",inputSchema:object({argv:{type:"array",items:string,minItems:1,maxItems:128}},["argv"])},
  {name:"desktop_browser_connect",description:"Open or reconnect this desktop's managed browser. Then use browser_tabs and browser_snapshot. Uses only the Broker's authorized CDP grant.",inputSchema:object()},
  {name:"desktop_wait",description:"Wait for explicit restoration after interruption. Does not resume or obtain control.",inputSchema:object({seconds:{type:"integer",minimum:1,maximum:30},reason:string},["seconds","reason"])},
  {name:"desktop_finish",description:"Release task control after verified completion, cancellation or an explained blocker. No more actions can follow.",inputSchema:object({outcome:{enum:["completed","cancelled","blocked"]},reason:string},["outcome","reason"])}
];
const browserSpec=JSON.parse(await readFile(join(root,"native/agent/browser-schema.json"),"utf8"));
const installedBrowser=JSON.parse(await readFile(join(root,"native/agent/node_modules/@playwright/mcp/package.json"),"utf8"));
if(installedBrowser.version!==browserSpec.version) throw new Error("Pinned browser dependency and tool schema differ");
const browserTools=browserSpec.tools;
const allTools=[...nativeTools,...browserTools];
const validator=new AjvJsonSchemaValidator();
const validators=new Map(allTools.map(tool=>[tool.name,validator.getValidator(tool.inputSchema)]));
const server=new Server({name:"cornice-desktop",version:"0.1.0"},{capabilities:{tools:{}},instructions:"Operate only the explicitly assigned desktop. Begin with desktop_state. Browser tasks: desktop_browser_connect, browser_tabs, fresh browser_snapshot, semantic actions. Native tasks: fresh desktop_capture before input. Permission off, human takeover and session lock interrupt control. Never resume or rebind yourself, fall back to another desktop, or replay uncertain actions. After explicit restoration reconnect and observe again. Finish only after verifying the requested result."});
server.setRequestHandler(ListToolsRequestSchema,async()=>({tools:allTools}));
let sequence=Promise.resolve();
server.setRequestHandler(CallToolRequestSchema,(request,extra)=> {
  const run=async()=> {
    try {
      const name=request.params.name,params=request.params.arguments || {};
      const validate=validators.get(name);if(!validate) throw new Error("Unknown desktop tool");
      const valid=validate(params); if(!valid.valid) throw new Error("Invalid tool arguments: "+valid.errorMessage);
      if(finished && name!=="desktop_state") throw new Error("Task already finished; no further actions allowed");
      if(name.startsWith("browser_")) {
        const current=await invoke("state",{},extra);
        if(!browser || !active(current) || current.seatId!==browserIdentity.seatId || current.generation!==browserIdentity.generation) {
          await closeBrowser(); throw new Error("Browser control interrupted or changed. Reconnect after explicit restoration and read a fresh snapshot; no browser action was sent.");
        }
        const result=await browser.callTool({name,arguments:params});
        return sanitize(result);
      }
      const operation=name.slice("desktop_".length); let result;
      if(operation==="browser_connect") result=await connectBrowser(extra);
      else if(operation==="wait" && job) result=await invoke("wait",params,extra);
      else if(operation==="wait") {
        const end=Date.now()+params.seconds*1000;
        do {
          if(extra.signal.aborted) throw new Error("Desktop wait cancelled");
          result=await invoke("state",{},extra);
          if(active(result)) break;
          await new Promise(resolve=>setTimeout(resolve,250));
        } while(Date.now()<end);
        result={control:result,interrupted:!active(result)};
      } else result=await invoke(operation,operation==="capture"?{encoding:"jpeg"}:params,extra);
      if(operation==="finish") {finished=true;await closeBrowser();}
      const {imageBase64,pngBase64,mimeType,...details}=result;
      const content=[{type:"text",text:JSON.stringify(sanitize(details))}];
      if(imageBase64 || pngBase64) content.push({type:"image",data:imageBase64 || pngBase64,mimeType:mimeType || "image/png"});
      return {content,structuredContent:sanitize(details)};
    } catch(error) {return {isError:true,content:[{type:"text",text:sanitize(error.message || String(error))}]};}
  };
  const pending=sequence.then(run,run);sequence=pending.then(()=>{},()=>{});return pending;
});
// Keep the Broker's single-controller lease alive even during model thinking.
const heartbeat=setInterval(()=> {
  if((binding || job) && !finished && !closing) invoke("state").catch(()=>{});
},1000);
heartbeat.unref();
let closing=false;
async function close() {
  if(closing) return;closing=true;clearInterval(heartbeat);
  await closeBrowser();
  if(!job && binding && !finished) await rpc(binding,"desktop.release",{},"disconnect").catch(()=>{});
  if(browserHome) await rm(browserHome,{recursive:true,force:true});
  await server.close().catch(()=>{});
}
process.on("SIGTERM",()=>{close().finally(()=>process.exit(0));});
process.on("SIGINT",()=>{close().finally(()=>process.exit(0));});
process.stdin.on("end",()=>{close().finally(()=>process.exit(0));});
await server.connect(new StdioServerTransport());
