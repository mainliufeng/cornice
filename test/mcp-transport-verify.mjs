// Test-only bridge replies; real shared MCP SDK/transport and pinned browser catalog.
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.env.CORNICE_TEST_PRODUCT || '.');
const {Client}=await import(pathToFileURL(join(root,'native/agent/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js')).href);
const {StdioClientTransport}=await import(pathToFileURL(join(root,'native/agent/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js')).href);
const dir=await mkdtemp(join(tmpdir(),'cornice-mcp-transport-'));
await writeFile(join(dir,'mode'),'state');
const fixture=join(dir,'bridge-fixture');
await writeFile(fixture,`#!/usr/bin/python3
import json,sys,os
from pathlib import Path
json.load(sys.stdin)
assert not any(os.environ.get(k) for k in ('CORNICE_MODEL_TOKEN','OPENAI_API_KEY','NODE_OPTIONS'))
mode=(Path(__file__).parent/'mode').read_text()
if mode=='nonzero':sys.stderr.write('fixture launch failed');sys.exit(7)
if mode=='malformed':print('invalid json')
elif mode=='array':print('[]')
elif mode=='interrupted':print(json.dumps(dict(interrupted=True,control=dict(paused=True))))
else:print(json.dumps(dict(name='fixture',seatId='fixture-id',generation='1',primary=False,number=2,available=True,paused=False,agentPaused=False,controlMode='agent',agentAllowed=True)))
`);await chmod(fixture,0o700);
const client=new Client({name:'cornice-transport-test',version:'1'});
const transport=new StdioClientTransport({command:join(root,'bin/cornice-desktop-mcp'),env:{PATH:process.env.PATH,CORNICE_AGENT_JOB:dir,CORNICE_AGENT_BRIDGE:fixture,CORNICE_MODEL_TOKEN:'test-only-secret',OPENAI_API_KEY:'test-only-secret'},stderr:'pipe'});
transport.stderr?.on('data',()=>{});
try{
 await client.connect(transport);
 const tools=await client.listTools();assert.equal(tools.tools.length,23);
 const call=async(name,args={},error=false)=>{const value=await client.callTool({name,arguments:args});assert.equal(!!value.isError,error,JSON.stringify(value));return value;};
 assert.equal((await call('desktop_state')).structuredContent.name,'fixture');
 for(const mode of ['nonzero','malformed','array']){
  await writeFile(join(dir,'mode'),mode);const value=await call('desktop_state',{},true);assert.ok(value.content[0].text.length);
 }
 await writeFile(join(dir,'mode'),'interrupted');const interrupted=await call('desktop_capture');assert.equal(interrupted.structuredContent.interrupted,true);assert.equal(interrupted.content.length,1);
 await writeFile(join(dir,'mode'),'state');
 await call('desktop_input',{action:'text',text:'missing frame'},true);
 await call('desktop_workspace',{workspace:'1',slot:1},true);
 await call('desktop_state',{unexpected:true},true);
 await call('browser_evaluate',{function:'()=>1'},true);
 await call('browser_click',{target:'e1'},true); // no authorized browser session
 await call('desktop_finish',{outcome:'completed',reason:'fixture verified'});
 await call('desktop_launch',{argv:['anything']},true);
 console.log('PASS shared MCP validates arguments, bridge failures, interruption, environment stripping and terminal control');
}finally{await client.close();}
const catalog=new Client({name:'cornice-browser-catalog-test',version:'1'});
try{
 await catalog.connect(new StdioClientTransport({command:process.execPath,args:[join(root,'native/agent/node_modules/@playwright/mcp/cli.js'),'--image-responses','omit','--no-webmcp','--codegen','none'],cwd:dir,env:{PATH:process.env.PATH,HOME:dir},stderr:'pipe'}));
 const actual=await catalog.listTools();
 const pinned=JSON.parse(await readFile(join(root,'native/agent/browser-schema.json'),'utf8'));
 for(const expected of pinned.tools){const found=actual.tools.find(tool=>tool.name===expected.name);assert.ok(found);assert.deepEqual(found.inputSchema,expected.inputSchema);}
 console.log('PASS every allowlisted browser schema matches the real pinned Playwright MCP catalog');
}finally{await catalog.close();}
