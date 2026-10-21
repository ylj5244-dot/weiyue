'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
const section=source.slice(source.indexOf('  function cleanupOptions()'),source.indexOf("  $('open-cleanup').addEventListener"));
function fixture(rpc=async()=>({})) {
  const elements={'cleanup-undo':{disabled:true}};const context=vm.createContext({cleanupBusy:false,cleanupHasUndoReceipt:false,cleanupStatusRequest:0,cleanupPlan:{},cleanupEvents:[],accountEpoch:1,state:{accountId:'sample'},document:{querySelector:()=>({inert:false})},refreshMountedCards(){elements.messageDisabled=context.cleanupBusy;},renderAIControls(){elements.aiDisabled=context.cleanupBusy;},$:id=>elements[id]||(elements[id]={disabled:true}),rpc});
  vm.runInContext(section,context);return {context,elements,run:code=>vm.runInContext(code,context)};
}
test('preview unlock cannot enable undo when no cleanup receipt exists',async()=>{
  const f=fixture();await f.run('cleanupStatus()');f.run('lockCleanup(true);lockCleanup(false)');
  assert.equal(f.elements['cleanup-undo'].disabled,true,'preview alone does not create a recoverable cleanup');
});
test('a valid cleanup receipt enables undo only outside an in-flight operation',async()=>{
  const f=fixture(async()=>({receipt:{id:'available'}}));f.run('lockCleanup(true)');await f.run('cleanupStatus()');
  assert.equal(f.elements['cleanup-undo'].disabled,true,'late receipt replies cannot unlock busy cleanup');
  f.run('lockCleanup(false)');assert.equal(f.elements['cleanup-undo'].disabled,false);
  f.context.rpc=async()=>({});await f.run('cleanupStatus()');assert.equal(f.elements['cleanup-undo'].disabled,true,'used or missing receipt disables undo');
});
test('pending, failed and outdated receipt checks cannot leave undo enabled',async()=>{
  const pending=[];const f=fixture(()=>new Promise(resolve=>pending.push(resolve)));
  f.context.cleanupHasUndoReceipt=true;f.elements['cleanup-undo'].disabled=false;
  const old=f.run('cleanupStatus()');assert.equal(f.elements['cleanup-undo'].disabled,true,'rechecking status is pessimistic');
  const latest=f.run('cleanupStatus()');pending[1]({});await latest;pending[0]({receipt:{id:'stale'}});await old;
  assert.equal(f.elements['cleanup-undo'].disabled,true,'an older reply cannot resurrect a consumed receipt');
  f.context.rpc=async()=>{throw new Error('disk unavailable');};await f.run('cleanupStatus()');
  assert.equal(f.elements['cleanup-undo'].disabled,true,'failed checks do not enable undo');
});

test('cleanup completion refreshes message and AI controls after rendering the cleaned state',()=>{
  const f=fixture();f.run('lockCleanup(true)');
  assert.equal(f.elements.messageDisabled,true);assert.equal(f.elements.aiDisabled,true);
  f.run('lockCleanup(false)');assert.equal(f.elements.messageDisabled,false);assert.equal(f.elements.aiDisabled,false);
});
