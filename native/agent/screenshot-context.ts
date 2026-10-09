import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { realpathSync } from "node:fs";
import { createRequire } from "node:module";

interface PhotonImage {
  get_width(): number;
  get_height(): number;
  get_bytes_jpeg(quality: number): Uint8Array;
  free(): void;
}
export interface ScreenshotPhoton {
  PhotonImage: { new_from_byteslice(bytes: Uint8Array): PhotonImage };
}

let photon: ScreenshotPhoton | undefined;
function loadPhoton(): ScreenshotPhoton {
  if (!photon) {
    // Resolve Pi's existing dependency from its executable, including symlinked
    // global installs. Cornice's installed extension is outside Pi's package.
    if (!process.argv[1]) throw new Error("Pi executable path is unavailable");
    photon = createRequire(realpathSync(process.argv[1]))("@silvia-odwyer/photon-node");
  }
  return photon!;
}

/** Encode without resizing: screenshot coordinates must retain pixelSize. */
export function encodeScreenshot(
  pngBase64: unknown,
  pixelSize: unknown,
  photonLoader: () => ScreenshotPhoton = loadPhoton,
): { type: "image"; data: string; mimeType: "image/jpeg" } {
  if (typeof pngBase64 !== "string" || pngBase64.length === 0)
    throw new Error("Desktop screenshot PNG is missing");
  if (!Array.isArray(pixelSize) || pixelSize.length !== 2 ||
      !pixelSize.every(value => Number.isSafeInteger(value) && value > 0 && value <= 8192))
    throw new Error("Desktop screenshot pixelSize is invalid");

  let source: PhotonImage | undefined;
  let encoded: PhotonImage | undefined;
  try {
    const codec = photonLoader();
    source = codec.PhotonImage.new_from_byteslice(Buffer.from(pngBase64, "base64"));
    const [width, height] = pixelSize;
    if (source.get_width() !== width || source.get_height() !== height)
      throw new Error("PNG dimensions do not match pixelSize");
    const jpeg = source.get_bytes_jpeg(85);
    if (!(jpeg instanceof Uint8Array) || jpeg.length === 0)
      throw new Error("JPEG encoder returned no image");
    // Bound one image below the provider body budget and Pi's resize limit.
    // Never silently resize: it would invalidate native input coordinates.
    if (jpeg.length > 12 * 1024 * 1024)
      throw new Error("JPEG exceeds the 12 MiB screenshot budget; use structured observation");
    encoded = codec.PhotonImage.new_from_byteslice(jpeg);
    if (encoded.get_width() !== width || encoded.get_height() !== height)
      throw new Error("JPEG dimensions do not match pixelSize");
    return { type: "image", data: Buffer.from(jpeg).toString("base64"), mimeType: "image/jpeg" };
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    throw new Error("Desktop screenshot JPEG encoding failed: " + reason);
  } finally {
    encoded?.free();
    source?.free();
  }
}

/** Request-only projection; keep the tool transcript and all textual evidence. */
export function latestDesktopScreenshot(messages: AgentMessage[]): AgentMessage[] {
  const isScreenshot = (message: AgentMessage): message is Extract<AgentMessage, { role: "toolResult" }> =>
    message.role === "toolResult" &&
    (message.toolName === "desktop_capture" || message.toolName === "desktop_wait") &&
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
