import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";

function invoke(operation: string, params: unknown, signal?: AbortSignal): Promise<any> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.env.CORNICE_AGENT_BRIDGE!, ["bridge", operation], { stdio: ["pipe", "pipe", "pipe"], signal });
    let out = "", error = "";
    child.stdout.on("data", data => out += data);
    child.stderr.on("data", data => error += data);
    child.on("error", reject);
    child.on("close", code => {
      try { resolve(code === 0 ? JSON.parse(out) : { error: error.trim(), interrupted: true }); }
      catch (e) { reject(e); }
    });
    child.stdin.end(JSON.stringify(params));
  });
}
export default function(pi: ExtensionAPI) {
  const tools = [
    ["state", "Read desktop control, identity and workspace even while interrupted", Type.Object({})],
    ["capture", "Capture assigned desktop. Read pixelSize and use its frameId for input", Type.Object({})],
    ["windows", "List windows of the assigned desktop", Type.Object({})],
    ["input", "Send one action with fresh frameId. Chords use XKB names: CTRL,a or Return", Type.Object({
      frameId: Type.String(), action: Type.Union(["click","move","text","chord","scroll"].map(value => Type.Literal(value))),
      x: Type.Optional(Type.Number()), y: Type.Optional(Type.Number()), text: Type.Optional(Type.String()),
      keys: Type.Optional(Type.Array(Type.String())), button: Type.Optional(Type.String()), delta: Type.Optional(Type.Number()) })],
    ["workspace", "Switch assigned desktop to its own workspace 1–10. Capture again afterwards", Type.Object({slot: Type.Integer({minimum:1,maximum:10})})],
    ["focus", "Focus a window on this desktop; capture again afterwards", Type.Object({windowId:Type.String()})],
    ["launch", "Launch an application on assigned desktop only", Type.Object({argv:Type.Array(Type.String())})],
    ["wait", "Wait for explicit human restoration. Never resumes control. Choose this or finish when interrupted", Type.Object({seconds:Type.Integer({minimum:1,maximum:300}),reason:Type.String()})],
    ["finish", "Record verified completion or explain cancellation/blocker", Type.Object({outcome:Type.Union([Type.Literal("completed"),Type.Literal("cancelled"),Type.Literal("blocked")]),reason:Type.String()})],
  ] as const;
  for (const [operation, description, parameters] of tools) {
    pi.registerTool(defineTool({name:"desktop_"+operation,label:"Desktop "+operation,description,parameters,
      async execute(_id, params, signal) {
        const result = await invoke(operation, params, signal);
        const image = result.pngBase64; delete result.pngBase64;
        const content: any[] = [{type:"text",text:JSON.stringify(result)}];
        if (image) content.push({type:"image",data:image,mimeType:"image/png"});
        return {content,details:result};
      }
    }));
  }
}
