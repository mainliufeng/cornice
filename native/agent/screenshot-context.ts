import type { AgentMessage } from "@earendil-works/pi-agent-core";

/** Request-only projection; keep the tool transcript and all textual evidence. */
export function latestDesktopScreenshot(messages: AgentMessage[]): AgentMessage[] {
  const isScreenshot = (message: AgentMessage): message is Extract<AgentMessage, { role: "toolResult" }> =>
    message.role === "toolResult" &&
    (message.toolName === "desktop_capture" || message.toolName === "desktop_wait" ||
     message.toolName === "mcp__cornice__desktop_capture" || message.toolName === "mcp__cornice__desktop_wait") &&
    message.content.some(part => part.type === "image");
  let latest = -1;
  for (let index = messages.length - 1; index >= 0; --index)
    if (isScreenshot(messages[index])) {
      latest = index;
      break;
    }
  return messages.map((message, index) =>
    index !== latest && isScreenshot(message)
      ? { ...message, content: message.content.filter(part => part.type !== "image") }
      : message);
}
