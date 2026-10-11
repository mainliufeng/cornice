// Real SDK + stdio transport; no desktop, browser, GPU or host socket.
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createServer} from 'node:net';
const root=resolve(process.env.CORNICE_TEST_PRODUCT || '.');
const {desktopSocketPath}=await import(pathToFileURL(join(root,'native/agent/desktop-endpoint.mjs')).href);
const {Client}=await import(pathToFileURL(join(root,'native/agent/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js')).href);
const {StdioClientTransport}=await import(pathToFileURL(join(root,'native/agent/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js')).href);
const directory=await mkdtemp(join(tmpdir(),'cornice-mcp-lifecycle-'));
const runtime=join(directory,'runtime');
const socketPath=desktopSocketPath(runtime,'test');
await mkdir(dirname(socketPath),{recursive:true});
const peers=new Set(),leases=new Map();let serial=0,failedRelease=false;
const state={name:'fixture',seatId:'fixture-seat',generation:'1',primary:false,number:2,available:true,paused:false,agentPaused:false,controlMode:'agent',agentAllowed:true};
const fixture=createServer(socket=>{
 peers.add(socket);socket.on('close',()=>peers.delete(socket));let input='';
 socket.on('data',data=>{
  input+=data;let end;
  while((end=input.indexOf('\n'))>=0){
   const request=JSON.parse(input.slice(0,end));input=input.slice(end+1);
   const reply=(result,keep=false)=>socket[keep?'write':'end'](JSON.stringify({id:request.id,ok:true,result})+'\n');
   if(request.method==='acquire-desktop'){
    const lease={...state,socket:socketPath,instance:'test',token:'credential-'+(++serial),taskToken:'reservation-'+serial,controller:request.params.controller};
    leases.set(lease.controller,lease);reply(lease,true);
   } else if(request.method==='desktop.task'){
    const lease=leases.get(request.controller),old=lease.token;lease.token='rotated-'+(++serial);lease.generation=String(serial);
    reply({binding:{...lease},control:{...state,generation:lease.generation},notice:old+' '+lease.token+' '+lease.taskToken});
   } else if(request.method==='desktop.handoff'){
    const lease=leases.get(request.controller);reply({state:{...state,generation:lease.generation,notice:lease.token+' '+lease.taskToken}});
   } else if(request.method==='desktop.release' && failedRelease){
    const lease=leases.get(request.controller);socket.end(JSON.stringify({id:request.id,ok:false,error:'release unavailable: '+lease.token+' '+lease.taskToken})+'\n');
   } else reply(state);
  }
 });
});
await new Promise(resolve=>fixture.listen(socketPath,resolve));
const client=new Client({name:'cornice-lifecycle-test',version:'1'});
const transport=new StdioClientTransport({command:join(root,'bin/cornice-desktop-mcp'),env:{PATH:process.env.PATH,XDG_RUNTIME_DIR:runtime,HYPRLAND_INSTANCE_SIGNATURE:'test'},stderr:'pipe'});
transport.stderr?.on('data',()=>{});
const call=(name,args={})=>client.callTool({name,arguments:args});
const acquire=async()=>{const result=await call('desktop_acquire');assert.ok(!result.isError,JSON.stringify(result));return result.structuredContent.desktop;};
try{
 await client.connect(transport);
 const survivor=await acquire(),rotating=await acquire();
 for(let index=0;index<32;index++){
  const result=await call('desktop_restore',{desktop:rotating});assert.ok(!result.isError,JSON.stringify(result));
  assert.ok(!JSON.stringify(result).includes('credential-') && !JSON.stringify(result).includes('rotated-') && !JSON.stringify(result).includes('reservation-'));
 }
 console.log('PASS binding rotations redact both previous and new credentials without returning the binding');
 const latest=[...leases.values()].at(-1);
 const finished=await call('desktop_finish',{desktop:rotating,outcome:'completed',reason:'verified '+latest.token+' '+latest.taskToken});
 assert.ok(!finished.isError,JSON.stringify(finished));assert.equal(finished.structuredContent.reason,'verified [REDACTED] [REDACTED]');
 const obsolete=await call('desktop_state',{desktop:rotating});assert.ok(obsolete.isError && obsolete.content[0].text.includes('finished, expired or unknown'));
 assert.ok(!(await call('desktop_state',{desktop:survivor})).isError);
 console.log('PASS finishing retires the reference including live state reads, preserves final-result redaction and leaves other tasks active');
 for(let index=0;index<64;index++){
  const desktop=await acquire();assert.ok(!(await call('desktop_finish',{desktop,outcome:'completed',reason:'fixture verified'})).isError);
  assert.ok((await call('desktop_state',{desktop})).isError);
 }
 assert.ok(peers.size<=1,'Finished reservations were retained: '+peers.size);
 assert.ok(!(await call('desktop_state',{desktop:survivor})).isError);
 console.log('PASS repeated task churn retires every completed reference and reservation while preserving the live task');
 const failing=await acquire();failedRelease=true;
 const failure=await call('desktop_finish',{desktop:failing,outcome:'cancelled',reason:'fixture failure'});assert.ok(failure.isError);
 assert.ok(failure.content[0].text.includes('[REDACTED]') && !failure.content[0].text.includes('credential-') && !failure.content[0].text.includes('reservation-'));
 assert.ok((await call('desktop_state',{desktop:failing})).isError);failedRelease=false;
 console.log('PASS uncertain finish failure keeps its error redacted and retires local task resources rather than retaining a dead owner');
}finally{
 await client.close();for(const peer of peers)peer.destroy();await new Promise(resolve=>fixture.close(resolve));await rm(directory,{recursive:true,force:true});
}
