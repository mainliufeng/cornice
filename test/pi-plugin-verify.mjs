// Actual Pi package installation and resource loader; no model credentials/task.
import assert from 'node:assert/strict';
import {mkdtemp,readFile} from 'node:fs/promises';
import {realpathSync,readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,dirname,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
const product=resolve(process.env.CORNICE_TEST_PRODUCT||'.');
const base=await mkdtemp(join(tmpdir(),'cornice-pi-plugin-'));
const env={...process.env,PI_CODING_AGENT_DIR:base};delete env.CORNICE_AGENT_JOB;delete env.CORNICE_AGENT_BRIDGE;delete env.CORNICE_MCP_BINDING;
execFileSync('pi',['install',join(product,'plugins/pi-cornice')],{env,cwd:base});
const settings=JSON.parse(await readFile(join(base,'settings.json'),'utf8'));
assert.equal(settings.packages.length,1);
let root=dirname(realpathSync(execFileSync('which',['pi'],{encoding:'utf8'}).trim()));
while(true){try{if(JSON.parse(readFileSync(join(root,'package.json'),'utf8')).name==='@earendil-works/pi-coding-agent')break;}catch{}if(dirname(root)===root)throw new Error('Pi installation not found');root=dirname(root);}
const {DefaultResourceLoader}=await import(pathToFileURL(join(root,'dist/core/resource-loader.js')).href);
delete process.env.CORNICE_AGENT_BRIDGE;delete process.env.CORNICE_AGENT_JOB;
const loader=new DefaultResourceLoader({cwd:base,agentDir:base});await loader.reload();
assert.deepEqual(loader.getExtensions().errors,[]);
const server=loader.getExtensions().runtime.mcpServers.list().find(x=>x.name==='cornice');
assert.ok(server);assert.equal(server.config.command,join(product,'bin/cornice-desktop-mcp'));
assert.deepEqual(server.config.env,{CORNICE_HARNESS:'pi'});
assert.equal(JSON.parse(await readFile(join(product,'plugins/pi-cornice/package.json'),'utf8')).version,'0.3.0');
assert.ok(loader.getSkills().skills.some(x=>x.name==='cornice-desktop'));
const {Client}=await import(pathToFileURL(join(product,'native/agent/node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js')).href);
const {StdioClientTransport}=await import(pathToFileURL(join(product,'native/agent/node_modules/@modelcontextprotocol/sdk/dist/esm/client/stdio.js')).href);
const client=new Client({name:'pi-package-check',version:'1'});
try{await client.connect(new StdioClientTransport({command:server.config.command,env:{...env,...server.config.env},cwd:base,stderr:'pipe'}));
 const tools=await client.listTools();assert.equal(tools.tools.length,26);assert.ok(['desktop_acquire','desktop_snapshot','desktop_action'].every(name=>tools.tools.some(x=>x.name===name)));
 assert.equal(client.getServerVersion().version,'0.3.0');
 console.log('PASS real Pi local-package install discovers shared skill, registers independent MCP without job bridge, and lists 26 live tools; '+base);
}finally{await client.close();}
