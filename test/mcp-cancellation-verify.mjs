// Real SDK and stdio transport, with a test-only local Broker fixture.
// No desktop, display, GPU, browser or user's socket is opened by this test.
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createServer} from 'node:net';
const root=resolve(process.env.CORNICE_TEST_PRODUCT || '.');
const {Client}=await import(pathToFileURL(join(root,'native/agent/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js')).href);
const {StdioClientTransport}=await import(pathToFileURL(join(root,'native/agent/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js')).href);
const directory=await mkdtemp(join(tmpdir(),'cornice-mcp-cancellation-'));
const path=join(directory,'broker.sock'),bindingPath=join(directory,'binding.json');
const launches=[],peers=new Set();let releaseFirst;
const state={name:'fixture',seatId:'fixture-id',generation:'1',primary:false,number:2,available:true,paused:false,agentPaused:false,controlMode:'agent',agentAllowed:true};
const fixture=createServer(socket=>{
 peers.add(socket);socket.on('close',()=>peers.delete(socket));let input='';
 socket.on('data',data=>{
  input+=data;let end;
  while((end=input.indexOf('\n'))>=0){
   const request=JSON.parse(input.slice(0,end));input=input.slice(end+1);
   const reply=result=>socket.end(JSON.stringify({ok:true,id:request.id,result})+'\n');
   if(request.method==='desktop.launch'){
    launches.push(request.params.argv);
    if(request.params.argv[0]==='blocked')releaseFirst=()=>reply({pid:1,seatId:'fixture-id'});
    else if(request.params.argv[0]==='submitted'){} // deliberate uncertain fixture action
    else reply({pid:2,seatId:'fixture-id'});
   } else reply(state);
  }
 });
});
await new Promise(resolve=>fixture.listen(path,resolve));
await writeFile(bindingPath,JSON.stringify({name:'fixture',seatId:'fixture-id',generation:'1',socket:path,instance:'test',token:'test-token'}),{mode:0o600});
const client=new Client({name:'cornice-cancellation-test',version:'1'});
const transport=new StdioClientTransport({command:join(root,'bin/cornice-desktop-mcp'),env:{PATH:process.env.PATH,CORNICE_MCP_BINDING:bindingPath},stderr:'pipe'});
transport.stderr?.on('data',()=>{});
const wait=async(fn)=>{const end=Date.now()+5000;while(!fn()){assert.ok(Date.now()<end,'fixture timeout');await new Promise(resolve=>setTimeout(resolve,10));}};
try{
 await client.connect(transport);
 const first=client.callTool({name:'desktop_launch',arguments:{argv:['blocked']}});
 await wait(()=>releaseFirst);
 const cancel=new AbortController();
 const queued=client.callTool({name:'desktop_launch',arguments:{argv:['cancelled-queued']}},undefined,{signal:cancel.signal}).catch(error=>error);
 // Ensure the real server received and queued it behind the blocked operation.
 await new Promise(resolve=>setTimeout(resolve,100));cancel.abort();
 assert.ok((await queued) instanceof Error);
 releaseFirst();assert.ok(!(await first).isError);
 // A request after the cancelled item completes only when the production queue
 // has passed the cancelled call. This makes the assertion deterministic.
 assert.ok(!(await client.callTool({name:'desktop_state',arguments:{}})).isError);
 assert.deepEqual(launches,[['blocked']]);
 console.log('PASS queued cancellation never submits a desktop mutation');
 const preCancelled=new AbortController();preCancelled.abort();
 await assert.rejects(client.callTool({name:'desktop_launch',arguments:{argv:['already-cancelled']}},undefined,{signal:preCancelled.signal}));
 assert.deepEqual(launches,[['blocked']]);
 console.log('PASS already-cancelled invocation is rejected before submission');
 const after=new AbortController();
 const submitted=client.callTool({name:'desktop_launch',arguments:{argv:['submitted']}},undefined,{signal:after.signal}).catch(error=>error);
 await wait(()=>launches.length===2);after.abort();assert.ok((await submitted) instanceof Error);
 assert.ok(!(await client.callTool({name:'desktop_state',arguments:{}})).isError);
 assert.deepEqual(launches,[['blocked'],['submitted']]);
 console.log('PASS cancellation after submission does not silently replay a mutation; following state read remains available');
}finally{
 await client.close();for(const peer of peers)peer.destroy();
 await new Promise(resolve=>fixture.close(resolve));await rm(directory,{recursive:true,force:true});
}
