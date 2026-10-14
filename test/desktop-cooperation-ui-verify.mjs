// Exercise actual QML service methods; doubles stay in this component test.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const source=readFileSync(new URL('../shell/plugins/agent-desktop/Service.qml',import.meta.url),'utf8');
const names=['awaitingContinuation','dismissCooperationRequest','dismissCooperationNotice','handoffMenuEntries','activateCooperation','continuationMessage','handoffLabel','startHandoff'];
const methods=names.map(name=>{
  const match=source.match(new RegExp('^  function '+name+'\\(([^)]*)\\) \\{([\\s\\S]*?)^  \\}', 'm'));
  assert.ok(match,'missing actual service method: '+name);
  return 'function '+name+'('+match[1]+') {'+match[2]+'}';
}).join('\n');
const calls=[];
const c={desktops:[],dismissedCooperationRequests:{},dismissedCooperationError:'',cooperationErrorKey:'',busy:false,
  DesktopSession:{agentShell:false},desktopLabel:name=>name,show:name=>calls.push(['show',name]),
  operate:args=>calls.push(['operate',...args]),runHelper:args=>calls.push(['helper',...args]),
  completeHandoff:(name,id)=>calls.push(['complete',name,id])};
c.root=c;
Object.defineProperties(c,{
  humanRequests:{get:()=>c.desktops.filter(item=>item.handoff?.status==='requested')},
  cooperationNotices:{get:()=>c.humanRequests.filter(item=>!c.dismissedCooperationRequests[item.handoff.id])},
  cooperationDesktops:{get:()=>c.desktops.filter(item=>item.handoff && (['requested','in_progress'].includes(item.handoff.status)||c.awaitingContinuation(item)))}
});
vm.createContext(c);vm.runInContext(methods,c);
const request=(id,name='desktop2')=>({name,occupied:true,paused:true,agentAllowed:true,handoff:{id,status:'requested',title:'请登录',instructions:'完成登录后点击完成'}});
c.desktops=[request('first')];
const before=JSON.stringify(c.desktops);
c.dismissCooperationNotice();
assert.equal(c.cooperationNotices.length,0);assert.equal(JSON.stringify(c.desktops),before);assert.deepEqual(calls,[]);
c.desktops=JSON.parse(before);assert.equal(c.cooperationNotices.length,0,'same request must remain dismissed after status refresh');
assert.equal(c.handoffMenuEntries(c.desktops[0])[1].label,'接管并处理');
console.log('PASS dismiss changes only local notice visibility, preserving request, input permissions and menu action across refresh');
c.desktops=[request('second')];assert.equal(c.cooperationNotices.length,1,'new request on same desktop must appear');
c.activateCooperation('first');assert.deepEqual(calls,[],'stale menu request must not act on replacement');
c.activateCooperation('second');
assert.equal(c.cooperationNotices.length,0,'taking control hides notice synchronously, before Broker refresh');
assert.equal(c.desktops[0].handoff.status,'requested');assert.equal(c.pendingRequestId,'second');
assert.deepEqual(calls,[['show','desktop2']]);calls.length=0;
c.desktops[0].handoff.status='in_progress';
assert.equal(c.cooperationNotices.length,0);
let entries=c.handoffMenuEntries(c.desktops[0]);
assert.equal(entries[1].label,'已完成，退出接管');assert.match(entries[0].detail,/完成登录/);assert.equal(entries[0].fullDetail,true);
c.activateCooperation('second');assert.deepEqual(calls,[['complete','desktop2','second']]);calls.length=0;
console.log('PASS new request reappears, stale request cannot activate, and takeover hides notice immediately while completion stays in menu');
c.desktops[0].handoff.status='completed';
assert.equal(c.cooperationNotices.length,0);assert.equal(c.cooperationDesktops.length,1);
entries=c.handoffMenuEntries(c.desktops[0]);
assert.match(entries[0].label,/等待 Agent 继续/);assert.match(entries[0].detail,/不会启动新的 Agent 任务/);
assert.equal(entries[1].label,'查看桌面');
c.activateCooperation('second');assert.deepEqual(calls,[['show','desktop2']]);calls.length=0;
c.desktops[0].handoff.restored=true;assert.equal(c.cooperationDesktops.length,0);c.activateCooperation('second');assert.deepEqual(calls,[]);
c.desktops=[request('third')];c.dismissCooperationRequest('desktop2','wrong');assert.equal(c.cooperationNotices.length,1);
c.desktops[0].handoff.status='cancelled';assert.equal(c.cooperationNotices.length,0);
assert.equal(c.handoffMenuEntries(c.desktops[0])[1].label,'查看桌面');
console.log('PASS completion/cancellation never opens an overlay; continuation is described honestly and restored tasks leave the active menu');
c.desktops=[request('primary','main')];c.desktops[0].primary=true;c.startHandoff('main','primary');
assert.equal(c.cooperationNotices.length,0);assert.deepEqual(calls,[['operate','handoff-start','main','primary']]);
const overlay=readFileSync(new URL('../shell/plugins/desktop-observer/Cooperation.qml',import.meta.url),'utf8');
const control=readFileSync(new URL('../shell/Commons/DesktopControl.qml',import.meta.url),'utf8');
const widget=readFileSync(new URL('../shell/plugins/agent-desktop/Widget.qml',import.meta.url),'utf8');
assert.match(overlay,/service\.cooperationNotices/);assert.doesNotMatch(overlay,/service\.cooperationDesktops/);
assert.match(overlay,/label:"收起";onClicked:root\.service\.dismissCooperationNotice\(\)/);
assert.match(control,/service\.cooperationMenuEntries/);assert.match(control,/service\.activateCooperation\(key\.slice\(8\)\)/);
assert.match(widget,/control\.entries\.filter\(item => item\.scope === "cooperation"\)/);
console.log('PASS primary and secondary desktops share the same notice/menu contract and grouped/split bar modes both expose cooperation');

const menu=readFileSync(new URL('../shell/Commons/DesktopMenu.qml',import.meta.url),'utf8');
assert.match(menu,/maximumLineCount:modelData\.fullDetail === true \? 2147483647 : 8/);
assert.match(menu,/elide:modelData\.fullDetail === true \? Text\.ElideNone : Text\.ElideRight/);
assert.match(menu,/contentHeight:column\.implicitHeight/);
console.log('PASS fullDetail opts actionable instructions into the existing bounded scroll viewport while ordinary descriptions keep eight lines');

const bar=readFileSync(new URL('../shell/plugins/bar/Bar.qml',import.meta.url),'utf8');
const barMethods=['configured','entriesFor'].map(name=>{
  const match=bar.match(new RegExp('^  function '+name+'\\(([^)]*)\\) \\{([\\s\\S]*?)^  \\}', 'm'));
  assert.ok(match,'missing actual bar method: '+name);
  return 'function '+name+'('+match[1]+') {'+match[2]+'}';
}).join('\n');
const b={layout:{left:[{id:'cn.launcher'}],center:[{id:'cn.clock'}],right:[{id:'cn.menu'}]},
  DesktopSession:{agentShell:false,service:{enabled:false}},Util:{option:(value,key,fallback)=>value[key]??fallback}};
vm.createContext(b);vm.runInContext(barMethods,b);
const ids=section=>Array.from(b.entriesFor(section),entry=>entry.id);
assert.deepEqual(ids('left'),['cn.launcher']);assert.deepEqual(ids('right'),['cn.menu']);
b.DesktopSession.service.enabled=true;
assert.deepEqual(ids('left'),['cn.launcher','cn.agent-desktop']);assert.deepEqual(ids('center'),['cn.clock']);
b.layout.right.push({id:'cn.agent-desktop',grouped:false});
assert.deepEqual(ids('left'),['cn.launcher']);assert.equal(ids('right').filter(id=>id==='cn.agent-desktop').length,1);
assert.equal(b.entriesFor('right')[1].grouped,false,'existing widget options and placement are retained');
b.DesktopSession.agentShell=true;
assert.deepEqual(ids('left'),['cn.workspaces','cn.launcher']);assert.equal(ids('right').filter(id=>id==='cn.agent-desktop').length,1);
b.layout.right.pop();b.DesktopSession.service.enabled=false;
assert.deepEqual(ids('left'),['cn.workspaces','cn.launcher','cn.agent-desktop']);
console.log('PASS enabled desktops guarantee one completion widget on primary/secondary; configured placement is preserved and disabled primary bar remains unchanged');

const literal=request('literal');literal.handoff.title='<b>任务标题</b>';literal.handoff.instructions='<b>COOPERATION TAIL MARKER</b>';
assert.equal(c.handoffMenuEntries(literal)[0].detail,'<b>任务标题</b>\n<b>COOPERATION TAIL MARKER</b>');
assert.match(menu,/text:modelData\.detail \|\| "";textFormat:Text\.PlainText/);
assert.match(overlay,/text:row\.modelData\.handoff\.title;textFormat:Text\.PlainText/);
assert.match(overlay,/text:row\.modelData\.handoff\.instructions;textFormat:Text\.PlainText/);
const panel=readFileSync(new URL('../shell/plugins/agent-desktop/Panel.qml',import.meta.url),'utf8');
assert.match(panel,/text:modelData\.instructions;textFormat:Text\.PlainText/);
console.log('PASS title/instructions preserve literal markup characters in notices, menu details and task history');

assert.match(overlay,/noticeScope:!!service && !DesktopSession\.agentShell/);
assert.match(control,/service\.cooperationMenuEntries/);
console.log('PASS session-owned notice has no private-shell duplicate while each desktop retains cooperation menu actions');
