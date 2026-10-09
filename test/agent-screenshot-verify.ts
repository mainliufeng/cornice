#!/usr/bin/env node
// Actual Pi loader and request-only context projection; no desktop/model access.
import assert from "node:assert/strict";
import {realpathSync,readFileSync} from "node:fs";
import {dirname,resolve,join} from "node:path";
import {pathToFileURL} from "node:url";
import {execFileSync} from "node:child_process";
const product=resolve(process.env.CORNICE_TEST_PRODUCT || ".");
const pi=realpathSync(execFileSync("which",[process.env.CORNICE_TEST_PI || "pi"],{encoding:"utf8"}).trim());
let root=dirname(pi);
while(true){try{if(JSON.parse(readFileSync(join(root,"package.json"),"utf8")).name==="@earendil-works/pi-coding-agent")break;}catch{} if(dirname(root)===root)throw new Error("Pi package not found");root=dirname(root);}
const {loadExtensions}=await import(pathToFileURL(join(root,"dist/core/extensions/loader.js")).href);
process.env.CORNICE_AGENT_BRIDGE=join(product,"bin/cornice-agent-runtime");
const loaded=await loadExtensions([join(product,"native/agent/desktop.ts")],"/tmp");
assert.deepEqual(loaded.errors,[]);
const extension=loaded.extensions[0];
assert.equal(extension.tools.size,0,"Pi must not implement duplicate desktop tools");
const servers=loaded.runtime.mcpServers.list();
assert.equal(servers.length,1);assert.equal(servers[0].name,"cornice");
assert.equal(servers[0].config.command,join(product,"bin/cornice-desktop-mcp"));
const {latestDesktopScreenshot}=await import(pathToFileURL(join(product,"native/agent/screenshot-context.ts")).href);
const old={role:"toolResult",toolName:"mcp__cornice__desktop_capture",toolCallId:"old",content:[{type:"text",text:"frame1"},{type:"image",data:"fixture",mimeType:"image/jpeg"}],isError:false,timestamp:1};
const fresh={...old,toolCallId:"fresh",timestamp:2};
const unrelated={...old,toolName:"other_capture"};
const result=latestDesktopScreenshot([old,unrelated,fresh]);
assert.equal(result[0].content.length,1);assert.equal(result[1].content.length,2);assert.equal(result[2].content.length,2);
assert.equal(old.content.length,2);assert.equal(result[0].toolCallId,"old");
let hooked=[old,fresh];
for(const handler of extension.handlers.get("context")) hooked=(await handler({type:"context",messages:hooked})).messages;
assert.equal(hooked[0].content.length,1);assert.equal(hooked[1].content.length,2);
console.log("PASS actual Pi loader registers shared MCP and prunes only old desktop images");
