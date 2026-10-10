import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { latestDesktopScreenshot } from "./screenshot-context.ts";

// Pi-specific lifecycle/context only. All desktop/browser tools are shared MCP.
export default function(pi: ExtensionAPI) {
  const bridge=process.env.CORNICE_AGENT_BRIDGE;
  const command=bridge ? resolve(dirname(bridge),"cornice-desktop-mcp") :
    resolve(dirname(fileURLToPath(import.meta.url)),"../../bin/cornice-desktop-mcp");
  pi.registerMcpServer("cornice",{command,args:[],cwd:process.env.CORNICE_AGENT_WORKSPACE,
    timeout:75,exposure:"direct",description:"Acquire a task-owned Cornice desktop; native input and structured browser tools share Broker permissions."});
  pi.on("before_agent_start",async()=> {
    const end=Date.now()+15000;
    while(!pi.getActiveTools().includes("mcp__cornice__desktop_state")) {
      if(Date.now()>=end) throw new Error("Cornice MCP tools did not become ready");
      await new Promise(resolve=>setTimeout(resolve,50));
    }
  });
  pi.on("context",event=>({messages:latestDesktopScreenshot(event.messages)}));
  pi.on("session_shutdown",()=>{pi.unregisterMcpServer("cornice");});
}
