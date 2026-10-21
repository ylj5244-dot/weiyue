'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function rpcHarness(){
  let now=0,timerID=0;const timers=new Map(),calls=[];
  const box={native:true,rpcSequence:0,pendingRPC:new Map(),window:{webkit:{messageHandlers:{app:{postMessage:request=>calls.push(request)}}}},
    setTimeout:(callback,delay)=>{const id=++timerID;timers.set(id,{callback,at:now+delay});return id;},clearTimeout:id=>timers.delete(id)};
  vm.createContext(box);const start=source.indexOf('  function rpc('),end=source.indexOf('  window.onNativeEvent =',start);vm.runInContext(source.slice(start,end),box);
  return {box,calls,advance(ms){now+=ms;for(const [id,timer] of [...timers])if(timer.at<=now){timers.delete(id);timer.callback();}},reply(request,result){box.window.nativeReceive({id:request.id,ok:true,result});}};
}
test('automatic cleanup stays pending until the native transaction confirms its saved state',async()=>{
  const h=rpcHarness();let settled=false;
  const result=h.box.rpc('autoCleanup',{accountId:'a',revision:4}).finally(()=>{settled=true;});result.catch(()=>{});
  h.advance(30000);await tick();assert.equal(settled,false,'25-second generic deadline must not unlock a running cleanup');
  h.advance(600000);await tick();assert.equal(settled,false,'a mutation cannot time out independently of its native completion');
  h.reply(h.calls[0],{state:{accountId:'a',revision:6}});assert.equal((await result).state.revision,6);
});
test('document preview gets the full attachment download budget',async()=>{
  const h=rpcHarness();let settled=false;
  const result=h.box.rpc('previewContent').finally(()=>{settled=true;});result.catch(()=>{});
  h.advance(30000);await tick();assert.equal(settled,false);
  h.advance(150000);await assert.rejects(result,/超时/);
});
test('scheduled cleanup waits while an editing dialog is open',async()=>{
  const start=source.indexOf('  async function runAutomaticCleanup()'),end=source.indexOf('  async function loadStorageLocations()',start);
  const box={native:true,demo:false,ready:true,loadFailed:false,state:{accountId:'a',settings:{autoCleanup:{enabled:true}}},cleanupBusy:false,quitting:false,settingsBusy:false,busyAI:false,inlineBusy:()=>false,preparingContext:false,cancellingAI:false,preferencesSaving:false,discussionHistoryBusy:false,collectionsBusy:false,bookmarkNoteSaving:false,syncGroupsSaving:false,rangeOperation:null,messageToggles:{hasPending:()=>false},autoCleanupRetry:false,autoCleanupAttempt:0,ReaderStorage:{due:()=>true},accountEpoch:1,document:{querySelector:selector=>{assert.equal(selector,'dialog[open]:not(#storage-dialog)');return {id:'collection-dialog'};}},lockCleanup(){assert.fail('cleanup must not start while a draft dialog is open');}};
  vm.createContext(box);vm.runInContext(source.slice(start,end),box);await box.runAutomaticCleanup();
});
