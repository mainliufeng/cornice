// Real shared MCP SDK/transport and pinned browser catalog; test-only Unix Broker fixture.
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,chmod,mkdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.env.CORNICE_TEST_PRODUCT || '.');
const {Client}=await import(pathToFileURL(join(root,'native/agent/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js')).href);
const {StdioClientTransport}=await import(pathToFileURL(join(root,'native/agent/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js')).href);
const dir=await mkdtemp(join(tmpdir(),'cornice-mcp-transport-'));
// A test-only Unix Broker fixture exercises the actual stdio transport without
// retaining the deleted embedded-executor job bridge in production.
const {createServer}=await import('node:net');
let mode='state';
const runtime=join(dir,'runtime');await mkdir(join(runtime,'cornice/test'),{recursive:true});
const socketPath=join(runtime,'cornice/test/desktop.sock');
const fixture=createServer(socket=>{
 let input='';socket.on('data',data=>{
  input+=data;const end=input.indexOf('\n');if(end<0)return;
  const request=JSON.parse(input.slice(0,end));
  if(mode==='nonzero'){socket.end(JSON.stringify({ok:false,error:'fixture action failed'})+'\n');return;}
  if(mode==='malformed'){socket.end('invalid json\n');return;}
  let result={name:'fixture',seatId:'fixture-id',generation:'1',primary:false,number:2,available:true,paused:false,agentPaused:false,controlMode:'agent',agentAllowed:true};
  if(request.method==='acquire-desktop') {socket.write(JSON.stringify({ok:true,result:{...result,socket:socketPath,instance:'test',token:'test-old-broker-token'}})+'\n');return;}
  if(mode==='array')result=[];
  if(mode==='interrupted')result={interrupted:true,control:{paused:true}};
  socket.end(JSON.stringify({ok:true,result})+'\n');
 });
});
await new Promise(resolve=>fixture.listen(socketPath,resolve));
const binding=join(dir,'binding.json');
await writeFile(binding,JSON.stringify({name:'fixture',seatId:'fixture-id',generation:'1',socket:socketPath,instance:'test',token:'test-only-token'}),{mode:0o600});
const marker=join(dir,'unexpected-node-options');
const injection=join(dir,'env-fixture.mjs');
await writeFile(injection,`import {writeFileSync} from 'node:fs';writeFileSync(${JSON.stringify(marker)},'inherited');`);
const client=new Client({name:'cornice-transport-test',version:'1'});
const transport=new StdioClientTransport({command:join(root,'bin/cornice-desktop-mcp'),env:{PATH:process.env.PATH,CORNICE_MCP_BINDING:binding,OPENAI_API_KEY:'test-only-secret',NODE_OPTIONS:'--import='+injection},stderr:'pipe'});
transport.stderr?.on('data',()=>{});
try{
 await client.connect(transport);
 const tools=await client.listTools();assert.equal(tools.tools.length,27);
 assert.ok(tools.tools.some(tool=>tool.name==='desktop_snapshot'));
 const call=async(name,args={},error=false)=>{const value=await client.callTool({name,arguments:args});assert.equal(!!value.isError,error,JSON.stringify(value));return value;};
 assert.equal((await call('desktop_state')).structuredContent.name,'fixture');
 assert.equal(await readFile(marker,'utf8').catch(()=>undefined),undefined);
 for(const failure of ['nonzero','malformed','array']){
  mode=failure;const value=await call('desktop_state',{},true);assert.ok(value.content[0].text.length);
 }
 mode='interrupted';const interrupted=await call('desktop_capture');assert.equal(interrupted.structuredContent.interrupted,true);assert.equal(interrupted.content.length,1);
 mode='state';
 await call('desktop_input',{action:'text',text:'missing frame'},true);
 await call('desktop_workspace',{workspace:'1',slot:1},true);
 await call('desktop_action',{elementRef:'missing',action:'click'},true);
 await call('desktop_action',{snapshotId:'test',elementRef:'test',action:'setText'},true);
 await call('desktop_state',{unexpected:true},true);
 await call('browser_evaluate',{function:'()=>1'},true);
 await call('browser_click',{target:'e1'},true);
 await call('desktop_finish',{outcome:'completed',reason:'fixture verified'});
 await call('desktop_launch',{argv:['anything']},true);
 console.log('PASS shared MCP validates native arguments, Broker failures, interruption, environment stripping and terminal control');
}finally{await client.close();}
const automatic=new Client({name:'cornice-old-broker-test',version:'1'});
try {
 await automatic.connect(new StdioClientTransport({command:join(root,'bin/cornice-desktop-mcp'),env:{PATH:process.env.PATH,XDG_RUNTIME_DIR:runtime,HYPRLAND_INSTANCE_SIGNATURE:'test'},stderr:'pipe'}));
 const acquired=await automatic.callTool({name:'desktop_acquire',arguments:{}});
 assert.ok(!acquired.isError,acquired);const desktop=acquired.structuredContent.desktop;
 assert.ok(!(await automatic.callTool({name:'desktop_state',arguments:{desktop}})).isError);
 const unsupported=await automatic.callTool({name:'desktop_handoff',arguments:{desktop,action:'status'}});
 assert.ok(unsupported.isError && unsupported.content[0].text.includes('Updated Cornice Broker'));
 console.log('PASS updated MCP keeps ordinary automatic desktop operations compatible with the previous Broker and explicitly rejects unavailable cooperation');
}finally{await automatic.close();await new Promise(resolve=>fixture.close(resolve));}

const catalog=new Client({name:'cornice-browser-catalog-test',version:'1'});
try{
 await catalog.connect(new StdioClientTransport({command:process.execPath,args:[join(root,'native/agent/node_modules/@playwright/mcp/cli.js'),'--image-responses','omit','--no-webmcp','--codegen','none'],cwd:dir,env:{PATH:process.env.PATH,HOME:dir},stderr:'pipe'}));
 const actual=await catalog.listTools();
 const pinned=JSON.parse(await readFile(join(root,'native/agent/browser-schema.json'),'utf8'));
 for(const expected of pinned.tools){const found=actual.tools.find(tool=>tool.name===expected.name);assert.ok(found);assert.deepEqual(found.inputSchema,expected.inputSchema);}
 console.log('PASS every allowlisted browser schema matches the real pinned Playwright MCP catalog');
}finally{await catalog.close();}
