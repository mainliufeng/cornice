// Test the actual Observer methods without loading Qt Quick or a compositor.
// Native state and host/service test doubles are confined to this test.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const source=readFileSync(new URL('../shell/plugins/desktop-observer/Observer.qml',import.meta.url),'utf8');
const names=['open','close','clearTakeoverIntent','takeControl','confirmTakeover','viewTargetChanged','returnedFromView'];
const methods=names.map(name => {
  const match=source.match(new RegExp('^  function '+name+'\\(([^)]*)\\) \\{([\\s\\S]*?)^  \\}', 'm'));
  assert.ok(match,'missing actual Observer method: '+name);
  return 'function '+name+'('+match[1]+') {'+match[2]+'}\n';
}).join('');
function fixture() {
  const reports=[],calls=[];
  const context={desktopName:'A',payloadJson:'{"name":"A"}',selectedWorkspace:'current',isOpen:true,
    requestedTakeover:false,requestedRequestId:'',requestedDesktop:'',
    service:{available:true,reportViewError:(...args)=>reports.push(args)},
    presentation:{item:{state:{active:true,name:'A',humanControl:false},error:'',
      takeHandoff:id=>calls.push(['handoff',id]),takeControl:enabled=>calls.push(['control',enabled])}},
    opened(){},dismissed(){}};
  context.root=context;vm.createContext(context);vm.runInContext(methods,context);
  return {context,reports,calls};
}
{
  const {context:c,reports}=fixture();
  c.takeControl(true,'request-A');
  c.presentation.item.state={active:true,name:'A',humanControl:true};c.confirmTakeover();
  assert.equal(c.requestedTakeover,false);assert.equal(c.requestedRequestId,'');assert.equal(c.requestedDesktop,'');
  c.desktopName='B';c.viewTargetChanged();c.presentation.item.error='B is unavailable';c.returnedFromView();
  assert.deepEqual(reports,[['B','B is unavailable',false,'']]);
  assert.equal(c.isOpen,false);assert.equal(c.service.selectedDesktop,'main');
  console.log('PASS completed A takeover cannot turn B view failure into a takeover retry');
}
{
  const {context:c,reports}=fixture();
  c.takeControl(true,'request-A');c.open('{"name":"B"}');c.desktopName='B';c.viewTargetChanged();
  c.presentation.item.state={active:true,name:'A',humanControl:true};c.confirmTakeover();
  c.presentation.item.error='B is unavailable';c.returnedFromView();
  assert.deepEqual(reports,[['B','B is unavailable',false,'']]);
  assert.equal(c.requestedRequestId,'');
  console.log('PASS switching targets revokes pending old takeover intent before new view errors');
}
{
  const {context:c,reports,calls}=fixture();
  c.takeControl(true,'request-A');
  c.presentation.item.state={active:true,name:'B',humanControl:true};c.confirmTakeover();
  assert.equal(c.requestedTakeover,true,'foreign state must not confirm the current request');
  c.presentation.item.error='takeover failed';c.returnedFromView();
  assert.deepEqual(reports,[['A','takeover failed',true,'request-A']]);
  assert.deepEqual(calls,[['handoff','request-A']]);assert.equal(c.requestedRequestId,'');
  console.log('PASS current takeover failure preserves its own desktop and request for an explicit retry');
}
{
  const {context:c,reports}=fixture();
  c.takeControl(true);c.close();assert.equal(c.requestedTakeover,false);
  c.open('{"name":"A"}');c.presentation.item.error='view failed';c.returnedFromView();
  assert.deepEqual(reports,[['A','view failed',false,'']]);
  console.log('PASS closing and reopening does not retain manual takeover intent');
}
assert.match(source,/function onReturned\(\) \{ root\.returnedFromView\(\) \}/);
assert.match(source,/function onStateChanged\(\) \{ root\.confirmTakeover\(\) \}/);
assert.match(source,/function onDesktopNameChanged\(\) \{ root\.viewTargetChanged\(\) \}/);

assert.match(source,/active:!!root\.service && root\.service\.enabled\s*source:active \? "Cooperation\.qml"/);
console.log('PASS cooperation notices remain mounted when an enabled desktop service becomes unavailable');
