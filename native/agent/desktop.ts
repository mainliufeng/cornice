import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { registerBrowserTools } from "./browser-tools.ts";
import { encodeScreenshot, latestDesktopScreenshot } from "./screenshot-context.ts";

function invoke(operation: string, params: unknown, signal?: AbortSignal): Promise<any> {
  return new Promise((resolve, reject) => {
    const bridge = process.env.CORNICE_AGENT_BRIDGE;
    if (!bridge) throw new Error("Desktop bridge executable is not configured");
    const child = spawn(bridge, ["bridge", operation], { stdio: ["pipe", "pipe", "pipe"], signal });
    let out = "", error = "";
    child.stdout.on("data", data => out += data);
    child.stderr.on("data", data => error += data);
    child.on("error", reject);
    child.on("close", (code, terminationSignal) => {
      if (code !== 0) {
        reject(new Error("desktop_" + operation + " failed (" +
          (terminationSignal ? "signal " + terminationSignal : "exit " + code) +
          "): " + (error.trim() || "Desktop bridge exited without a diagnostic")));
        return;
      }
      try {
        const result = JSON.parse(out);
        if (!result || typeof result !== "object" || Array.isArray(result))
          throw new Error("expected a JSON object");
        resolve(result);
      } catch (e) {
        reject(new Error("desktop_" + operation + " returned an invalid response: " +
          (e instanceof Error ? e.message : String(e))));
      }
    });
    child.stdin.on("error", reject);
    child.stdin.end(JSON.stringify(params));
  });
}
export default function(pi: ExtensionAPI) {
  registerBrowserTools(pi, invoke);
  pi.on("context", event => ({ messages: latestDesktopScreenshot(event.messages) }));
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
        const { pngBase64, ...details } = result;
        const content: any[] = [{type:"text",text:JSON.stringify(details)}];
        if (pngBase64 !== undefined)
          content.push(encodeScreenshot(pngBase64, details.pixelSize));
        return {content,details};
      }
    }));
  }
}
