import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const SERVER = "cornice_browser";
const PREFIX = "mcp__cornice_browser__";
const TOOLS = ["browser_snapshot", "browser_navigate", "browser_navigate_back", "browser_click",
  "browser_hover", "browser_drag", "browser_type", "browser_fill_form", "browser_select_option",
  "browser_press_key", "browser_tabs", "browser_wait_for", "browser_handle_dialog"];

type Invoke = (operation: string, params: unknown, signal?: AbortSignal) => Promise<any>;
const active = (state: any) => !state.taskFinished && !state.paused && !state.agentPaused && state.available && state.controlMode === "agent" &&
  (!state.humanLocked || (state.lockScope === "human" && state.humanLockPolicy === "continue"));

export function registerBrowserTools(pi: ExtensionAPI, invoke: Invoke) {
  let generation: string | number | undefined, seatId: string | undefined;
  const secrets = new Set<string>();
  function sanitize(value: any): any {
    if (typeof value === "string") {
      for (const secret of secrets) value = value.replaceAll(secret, "[REDACTED]");
      return value;
    }
    if (Array.isArray(value)) return value.map(sanitize);
    if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [sanitize(k), sanitize(v)]));
    return value;
  }
  pi.on("tool_call", async event => {
    if (!event.toolName.startsWith(PREFIX)) return;
    const state = await invoke("state", {});
    if (!active(state) || state.generation !== generation || state.seatId !== seatId)
      return { block: true, reason: "Browser control interrupted or generation changed. Wait or finish; after explicit restoration call desktop_browser_connect and read a fresh snapshot. No browser action was sent." };
  });
  pi.on("tool_result", event => {
    if (event.toolName.startsWith(PREFIX))
      return { content: sanitize(event.content), details: sanitize(event.details) };
  });
  pi.on("session_shutdown", () => { pi.unregisterMcpServer(SERVER); });
  pi.registerTool(defineTool({
    name: "desktop_browser_connect", label: "Connect Agent browser",
    description: "Open or reconnect the managed browser on this Agent seat. Adds structured browser tools; then inspect tabs and a fresh accessibility snapshot. No screenshot needed. Never connects to the human browser.",
    parameters: Type.Object({}),
    async execute(_id, _params, signal) {
      const bridge = process.env.CORNICE_AGENT_BRIDGE;
      if (!bridge) throw new Error("Desktop bridge is not configured");
      const directory = resolve(dirname(bridge), "../native/agent");
      const cli = join(directory, "node_modules/@playwright/mcp/cli.js");
      if (!existsSync(cli)) throw new Error("Agent browser dependency is missing. Install the locked dependencies in native/agent before using browser tasks.");
      const pkg = JSON.parse(readFileSync(join(dirname(cli), "package.json"), "utf8"));
      if (pkg.version !== "0.0.83") throw new Error("Agent browser dependency does not match Cornice's tested version");
      const connection = await invoke("browser", {}, signal);
      if (connection.interrupted) return { content: [{ type: "text", text: JSON.stringify(connection) }], details: connection };
      const endpoint = new URL(connection.cdpUrl);
      if (endpoint.protocol !== "http:" || endpoint.hostname !== "127.0.0.1" || !endpoint.port || endpoint.pathname === "/")
        throw new Error("Desktop service returned an invalid authorized browser endpoint");
      secrets.add(connection.cdpUrl);
      secrets.add(endpoint.pathname.slice(1));
      const state = await invoke("state", {}, signal);
      if (!active(state)) throw new Error("Browser control was interrupted during connection; wait for explicit restoration");
      pi.setActiveTools(pi.getActiveTools().filter(name => !name.startsWith(PREFIX)));
      pi.unregisterMcpServer(SERVER);
      generation = state.generation; seatId = state.seatId;
      const job = process.env.CORNICE_AGENT_JOB;
      if (!job) throw new Error("Agent job directory is unavailable");
      pi.registerMcpServer(SERVER, {
        command: bridge, args: ["browser-mcp"],
        env: { PLAYWRIGHT_MCP_CDP_ENDPOINT: connection.cdpUrl, CORNICE_AGENT_NODE: process.execPath, CORNICE_AGENT_PI_PID: String(process.pid) },
        cwd: process.env.CORNICE_AGENT_WORKSPACE, timeout: 20, exposure: "hidden",
        toolExposure: Object.fromEntries(TOOLS.map(name => [name, "direct"])),
        description: "Structured browser controls for this Cornice Agent's seat; human control and generation are enforced by the desktop broker.",
      });
      const expected = PREFIX + "browser_snapshot";
      const until = Date.now() + 15000;
      while (!pi.getActiveTools().includes(expected)) {
        if (signal?.aborted) throw new Error("Browser connection aborted");
        if (Date.now() >= until) {
          pi.unregisterMcpServer(SERVER);
          generation = undefined; seatId = undefined;
          throw new Error("Agent browser tools did not become ready; inspect runtime diagnostics");
        }
        await new Promise(resolve => setTimeout(resolve, 50));
      }
      const details = { connected: true, seatId, generation, observation: "accessibility-tree", tools: TOOLS.map(name => PREFIX + name) };
      return { content: [{ type: "text", text: JSON.stringify(details) }], details };
    },
  }));
}
