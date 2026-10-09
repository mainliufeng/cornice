#!/usr/bin/env node
/**
 * Regression tests for the production desktop extension and screenshot helper.
 *
 * Run with Node's native TypeScript support:
 *   node test/agent-screenshot-verify.ts
 * Optional: CORNICE_TEST_PI=/path/to/pi CORNICE_TEST_PRODUCT=/path/to/cornice
 *
 * Uses the installed Pi loader, its real tool-call pipeline and Photon codec.
 * Only the bridge responses and image pixels are test fixtures. No compositor,
 * application, credentials, model endpoint or user's desktop is accessed.
 */
import assert from "node:assert/strict";
import { accessSync, constants, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

function executable(name: string): string {
  const candidates = name.includes("/") ? [resolve(name)] :
    (process.env.PATH ?? "").split(":").map(directory => join(directory || ".", name));
  for (const candidate of candidates) {
    try { accessSync(candidate, constants.X_OK); return realpathSync(candidate); } catch {}
  }
  throw new Error("Installed Pi executable not found: " + name);
}

function piPackage(entry: string): { root: string; version: string } {
  for (let directory = dirname(entry); ; directory = dirname(directory)) {
    try {
      const metadata = JSON.parse(readFileSync(join(directory, "package.json"), "utf8"));
      if (metadata.name === "@earendil-works/pi-coding-agent")
        return { root: directory, version: metadata.version };
    } catch {}
    if (dirname(directory) === directory) break;
  }
  throw new Error("Pi executable is not inside a pi-coding-agent installation");
}

const product = resolve(process.env.CORNICE_TEST_PRODUCT ?? fileURLToPath(new URL("../", import.meta.url)));
const piEntry = executable(process.env.CORNICE_TEST_PI ?? "pi");
const pi = piPackage(piEntry);
const piRequire = createRequire(piEntry);
const artifactDir = mkdtempSync(join(tmpdir(), "cornice-agent-screenshot-"));
const checks: { name: string; elapsedMs: number }[] = [];
const originalArgv = process.argv[1];
const previousBridge = process.env.CORNICE_AGENT_BRIDGE;
const previousFixtureMode = process.env.CORNICE_TEST_SCREENSHOT_BRIDGE_MODE;
const previousFixtureData = process.env.CORNICE_TEST_SCREENSHOT_BRIDGE_DATA;

async function check(name: string, run: () => unknown | Promise<unknown>): Promise<void> {
  const start = performance.now();
  await run();
  checks.push({ name, elapsedMs: Math.round(performance.now() - start) });
  console.log("ok " + name);
}

function report(pass: boolean, error?: unknown): void {
  const value = {
    pass, checks, piVersion: pi.version, product, artifactDir,
    fixture: "synthetic image pixels and test-only bridge; real Pi and Photon",
    ...(error === undefined ? {} : { error: error instanceof Error ? error.stack : String(error) }),
  };
  writeFileSync(join(artifactDir, "report.json"), JSON.stringify(value, null, 2));
  console.log(JSON.stringify({ pass, checks: checks.length, artifactDir }));
}

try {
  // The production helper resolves Photon from the running Pi executable.
  process.argv[1] = piEntry;
  const { encodeScreenshot, latestDesktopScreenshot } = await import(
    pathToFileURL(join(product, "native/agent/screenshot-context.ts")).href);
  const { PhotonImage } = piRequire("@silvia-odwyer/photon-node");
  const { loadExtensions } = await import(
    pathToFileURL(join(pi.root, "dist/core/extensions/loader.js")).href);
  const { wrapToolDefinition } = await import(
    pathToFileURL(join(pi.root, "dist/core/tools/tool-definition-wrapper.js")).href);
  const corePackage = piRequire.resolve("@earendil-works/pi-agent-core/package.json");
  const coreMetadata = JSON.parse(readFileSync(corePackage, "utf8"));
  const { runToolCall } = await import(
    pathToFileURL(join(dirname(corePackage), coreMetadata.exports["."].import)).href);

  const width = 3072, height = 1920;
  const pixels = new Uint8Array(width * height * 4);
  let seed = 0x19f80a2;
  for (let index = 0; index < pixels.length; index += 4) {
    seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
    pixels[index] = seed; pixels[index + 1] = seed >>> 8;
    pixels[index + 2] = seed >>> 16; pixels[index + 3] = 255;
  }
  const fixture = new PhotonImage(pixels, width, height);
  let png: Uint8Array;
  try { png = fixture.get_bytes(); } finally { fixture.free(); }
  const pngBase64 = Buffer.from(png).toString("base64");

  await check("real Photon keeps 3072x1920 JPEG dimensions", () => {
    const image = encodeScreenshot(pngBase64, [width, height]);
    assert.equal(image.type, "image"); assert.equal(image.mimeType, "image/jpeg");
    const jpeg = Buffer.from(image.data, "base64");
    assert.equal(jpeg[0], 0xff); assert.equal(jpeg[1], 0xd8);
    const decoded = PhotonImage.new_from_byteslice(jpeg);
    try {
      assert.equal(decoded.get_width(), width); assert.equal(decoded.get_height(), height);
    } finally { decoded.free(); }
    writeFileSync(join(artifactDir, "synthetic-3072x1920.jpg"), jpeg);
    writeFileSync(join(artifactDir, "image-metadata.json"), JSON.stringify({
      pixelSize: [width, height], pngBytes: png.length, jpegBytes: jpeg.length,
    }, null, 2));
  });

  await check("PNG dimensions must match pixelSize", () => {
    assert.throws(() => encodeScreenshot(pngBase64, [width + 1, height]), /PNG dimensions do not match pixelSize/);
  });
  await check("missing PNG and malformed pixelSize are rejected", () => {
    assert.throws(() => encodeScreenshot(undefined, [width, height]), /PNG is missing/);
    for (const size of [undefined, [0,height], [width], [width,height,1], [1.5,height], ["3072",height]])
      assert.throws(() => encodeScreenshot(pngBase64, size), /pixelSize is invalid/);
  });
  await check("dimensions above 8192 fail before invoking the codec", () => {
    let loaded = false;
    const loader = () => { loaded = true; throw new Error("codec must not run"); };
    for (const size of [[8193,height],[width,8193]])
      assert.throws(() => encodeScreenshot(pngBase64,size,loader), /pixelSize is invalid/);
    assert.equal(loaded,false);
  });
  await check("JPEG above 12 MiB is rejected without resizing and source freed", () => {
    const size = [width,height];
    let decoded = 0, freed = 0;
    assert.throws(() => encodeScreenshot("fixture",size,() => ({
      PhotonImage: {new_from_byteslice: () => {
        ++decoded;
        return {
          get_width: () => width, get_height: () => height,
          get_bytes_jpeg: () => new Uint8Array(12*1024*1024+1),
          free: () => { ++freed; },
        };
      }},
    })), /JPEG exceeds the 12 MiB screenshot budget; use structured observation/);
    assert.equal(decoded,1); assert.equal(freed,1); assert.deepEqual(size,[width,height]);
  });
  await check("invalid encoded PNG is an explicit encoding error", () => {
    assert.throws(() => encodeScreenshot("not-a-png", [width,height]), /JPEG encoding failed/);
  });
  await check("codec dependency failure is explicit", () => {
    assert.throws(() => encodeScreenshot("fixture", [width,height], () => {
      throw new Error("fixture codec is unavailable");
    }), /JPEG encoding failed: fixture codec is unavailable/);
  });
  await check("JPEG quality is 85 and failed encoding frees the source", () => {
    let freed = 0;
    assert.throws(() => encodeScreenshot("fixture", [width,height], () => ({
      PhotonImage: { new_from_byteslice: () => ({
        get_width: () => width, get_height: () => height,
        get_bytes_jpeg: (quality: number) => { assert.equal(quality, 85); throw new Error("fixture encode failure"); },
        free: () => { ++freed; },
      }) },
    })), /JPEG encoding failed: fixture encode failure/);
    assert.equal(freed, 1);
  });
  await check("resized codec output is rejected and both images freed", () => {
    let decoded = 0, freed = 0;
    assert.throws(() => encodeScreenshot("fixture", [width,height], () => ({
      PhotonImage: { new_from_byteslice: () => {
        const source = ++decoded === 1;
        return {
          get_width: () => source ? width : width / 2,
          get_height: () => source ? height : height / 2,
          get_bytes_jpeg: () => new Uint8Array([0xff,0xd8,0xff,0xd9]),
          free: () => { ++freed; },
        };
      } },
    })), /JPEG dimensions do not match pixelSize/);
    assert.equal(freed, 2);
  });

  const image = { type: "image", data: "test-only-image", mimeType: "image/jpeg" };
  const oldText = { type: "text", text: '{"frameId":"old","workspace":"test-workspace"}' };
  const newText = { type: "text", text: '{"frameId":"fresh"}' };
  const call = (id: string, name: string) => ({type:"toolCall", id, name, arguments:{}});
  const assistant = (...content: unknown[]) => ({role:"assistant", content, timestamp:1});
  const messages: any[] = [
    {role:"user", content:[{type:"text",text:"fixture task"},image], timestamp:1},
    assistant(call("a","desktop_capture"),call("b","desktop_state")),
    {role:"toolResult",toolCallId:"a",toolName:"desktop_capture",content:[oldText,image],
      details:{frameId:"old",seatId:"fixture-seat",generation:"fixture-generation"},isError:false,timestamp:2},
    {role:"toolResult",toolCallId:"b",toolName:"desktop_state",content:[oldText],isError:false,timestamp:3},
    assistant(call("c","other_tool")),
    {role:"toolResult",toolCallId:"c",toolName:"other_tool",content:[image],isError:false,timestamp:4},
    assistant(call("d","desktop_wait")),
    {role:"toolResult",toolCallId:"d",toolName:"desktop_wait",content:[newText,image],
      details:{frameId:"fresh"},isError:false,timestamp:5},
    assistant(call("e","desktop_capture")),
    {role:"toolResult",toolCallId:"e",toolName:"desktop_capture",content:[newText],
      details:{interrupted:true},isError:false,timestamp:6},
  ];
  const before = structuredClone(messages);
  const pairing = (transcript: any[]) => ({
    calls: transcript.filter(message => message.role === "assistant")
      .flatMap(message => message.content.filter((part: any) => part.type === "toolCall")
        .map((part: any) => [part.id,part.name])),
    results: transcript.filter(message => message.role === "toolResult")
      .map(message => [message.toolCallId,message.toolName]),
  });
  await check("context keeps latest wait image despite later interrupted capture", () => {
    const projected = latestDesktopScreenshot(messages);
    assert.deepEqual(projected[2].content, [oldText]);
    assert.deepEqual(projected[7].content, [newText,image]);
    assert.equal(projected[9], messages[9]);
  });
  await check("context preserves text, metadata, timestamps, tool pairing and input history", () => {
    const projected = latestDesktopScreenshot(messages);
    assert.equal(projected.length, messages.length);
    assert.deepEqual(pairing(projected), pairing(messages));
    assert.equal(projected[2].toolCallId, "a"); assert.equal(projected[2].toolName, "desktop_capture");
    assert.equal(projected[2].details, messages[2].details);
    assert.equal(projected[2].timestamp, 2); assert.equal(projected[2].isError, false);
    assert.equal(projected[2].content[0], oldText);
    for (const index of [0,1,3,4,5,6,7,8,9]) assert.equal(projected[index], messages[index]);
    assert.deepEqual(messages, before);
  });
  await check("new capture prunes both older capture and wait images", () => {
    const latest = {role:"toolResult",toolCallId:"f",toolName:"desktop_capture",
      content:[newText,image],isError:false,timestamp:7};
    const transcript = [...messages, assistant(call("f","desktop_capture")), latest];
    const projected = latestDesktopScreenshot(transcript);
    assert.deepEqual(projected[2].content,[oldText]); assert.deepEqual(projected[7].content,[newText]);
    assert.equal(projected.at(-1),latest); assert.deepEqual(messages,before);
  });
  await check("context without desktop images preserves every message", () => {
    const transcript = [messages[0], messages[1], messages[3], messages[5], messages[9]];
    const projected = latestDesktopScreenshot(transcript);
    assert.deepEqual(projected,transcript);
    transcript.forEach((message,index) => assert.equal(projected[index],message));
    assert.deepEqual(latestDesktopScreenshot([]),[]);
  });

  const bridgeFixture = join(artifactDir,"bridge-fixture");
  writeFileSync(bridgeFixture, `#!/usr/bin/env python3
import json, os, sys
assert sys.argv[1] == 'bridge'
json.load(sys.stdin)
mode = os.environ['CORNICE_TEST_SCREENSHOT_BRIDGE_MODE']
if mode == 'nonzero':
    sys.stderr.write('Fixture application launch failed: executable missing\\n')
    sys.exit(7)
if mode == 'malformed':
    print('not-json')
elif mode == 'wrong-shape':
    print('[]')
elif mode == 'interrupted':
    print(json.dumps(dict(interrupted=True, message='Fixture human owns control',
      control=dict(paused=True))))
else:
    print(open(os.environ['CORNICE_TEST_SCREENSHOT_BRIDGE_DATA']).read())
`,{mode:0o700});
  const small = new PhotonImage(new Uint8Array(64*32*4).fill(255),64,32);
  const dataPath = join(artifactDir,"bridge-data.json");
  try {
    writeFileSync(dataPath,JSON.stringify({
      pngBase64:Buffer.from(small.get_bytes()).toString("base64"),pixelSize:[64,32],
      frameId:"fixture-fresh",workspace:"fixture-workspace",
    }));
  } finally { small.free(); }
  process.env.CORNICE_AGENT_BRIDGE = bridgeFixture;
  process.env.CORNICE_TEST_SCREENSHOT_BRIDGE_DATA = dataPath;

  let extension: any;
  await check("installed Pi loader loads the actual production extension", async () => {
    const loaded = await loadExtensions([join(product,"native/agent/desktop.ts")],artifactDir);
    assert.deepEqual(loaded.errors,[]);
    assert.equal(loaded.extensions.length,1); extension = loaded.extensions[0];
    for (const name of ["state","capture","windows","input","workspace","focus","launch","wait","finish"])
      assert.ok(extension.tools.has("desktop_"+name),name+" was not registered");
    assert.ok(extension.handlers.get("context")?.length);
  });
  let callSequence = 0;
  async function tool(name: string, parameters: unknown, mode: string): Promise<any> {
    process.env.CORNICE_TEST_SCREENSHOT_BRIDGE_MODE = mode;
    const toolCall = {type:"toolCall",id:"fixture-"+(++callSequence),name,arguments:parameters};
    const tools = [...extension.tools.values()].map((registered: any) => wrapToolDefinition(registered.definition));
    return runToolCall(toolCall,{
      assistantMessage:assistant(toolCall),context:{messages:[],tools},tools,
      signal:AbortSignal.timeout(10000),
    });
  }
  const errorText = (outcome: any) => outcome.result.content
    .filter((part: any) => part.type === "text").map((part: any) => part.text).join("\n");
  await check("nonzero bridge exit isError=true and never interrupted", async () => {
    const outcome = await tool("desktop_launch",{argv:["fixture-missing"]},"nonzero");
    assert.equal(outcome.isError,true);
    assert.match(errorText(outcome),/desktop_launch failed \(exit 7\): Fixture application launch failed/);
    assert.notEqual(outcome.result.details?.interrupted,true);
    assert.doesNotMatch(errorText(outcome),/"interrupted"\s*:\s*true/);
  });
  await check("malformed bridge JSON isError=true", async () => {
    const outcome = await tool("desktop_state",{},"malformed");
    assert.equal(outcome.isError,true); assert.match(errorText(outcome),/invalid response/);
    assert.notEqual(outcome.result.details?.interrupted,true);
  });
  await check("wrong JSON shape isError=true", async () => {
    const outcome = await tool("desktop_state",{},"wrong-shape");
    assert.equal(outcome.isError,true); assert.match(errorText(outcome),/expected a JSON object/);
  });
  await check("valid interruption retains control semantics without a tool error", async () => {
    const outcome = await tool("desktop_capture",{},"interrupted");
    assert.equal(outcome.isError,false); assert.equal(outcome.result.details.interrupted,true);
    assert.equal(outcome.result.content.length,1);
  });
  let capture: any;
  await check("production capture emits JPEG and preserves frame metadata", async () => {
    const outcome = await tool("desktop_capture",{},"capture"); capture = outcome.result;
    assert.equal(outcome.isError,false); assert.equal(capture.content[1].mimeType,"image/jpeg");
    assert.deepEqual(capture.details.pixelSize,[64,32]); assert.equal(capture.details.frameId,"fixture-fresh");
    assert.equal(capture.details.workspace,"fixture-workspace"); assert.equal(capture.details.pngBase64,undefined);
    assert.equal(JSON.parse(capture.content[0].text).pngBase64,undefined);
  });
  await check("registered Pi context hook prunes only history images", async () => {
    const old = {role:"toolResult",toolName:"desktop_capture",toolCallId:"old",
      content:capture.content,details:capture.details,isError:false,timestamp:1};
    const fresh = {...old,toolName:"desktop_wait",toolCallId:"fresh",timestamp:2};
    let projected = [old,fresh];
    for (const handler of extension.handlers.get("context")) {
      const result = await handler({type:"context",messages:projected});
      if (result?.messages) projected = result.messages;
    }
    assert.equal(projected[0].content.length,1); assert.equal(projected[1].content.length,2);
    assert.equal(projected[0].details,old.details); assert.equal(projected[0].toolCallId,"old");
    assert.equal(old.content.length,2); assert.equal(fresh.content.length,2);
  });
  report(true);
} catch (error) {
  report(false,error);
  process.exitCode = 1;
} finally {
  process.argv[1] = originalArgv;
  for (const [key,value] of [
    ["CORNICE_AGENT_BRIDGE",previousBridge],
    ["CORNICE_TEST_SCREENSHOT_BRIDGE_MODE",previousFixtureMode],
    ["CORNICE_TEST_SCREENSHOT_BRIDGE_DATA",previousFixtureData],
  ]) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
}
