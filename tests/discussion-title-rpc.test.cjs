'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const T=require('../Resources/ui/discussion-titles.js');
const M=require('../Resources/ui/model.js');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
const start=source.indexOf('  function rpc('),end=source.indexOf('  window.onNativeEvent =',start);
assert.ok(start>0&&end>start);
function harness(){
  let now=0,timerID=0;const timers=new Map(),calls=[];
  const box={native:true,rpcSequence:0,pendingRPC:new Map(),window:{webkit:{messageHandlers:{app:{postMessage:request=>calls.push(request)}}}},
    setTimeout:(callback,delay)=>{const id=++timerID;timers.set(id,{callback,at:now+delay});return id;},clearTimeout:id=>timers.delete(id)};
  vm.createContext(box);vm.runInContext(source.slice(start,end),box);
  function advance(ms){now+=ms;for(const [id,timer] of [...timers])if(timer.at<=now){timers.delete(id);timer.callback();}}
  function reply(request,result={},ok=true){box.window.nativeReceive({id:request.id,ok,result,error:ok?undefined:'cancel unavailable'});}
  const state=M.createState('synthetic');state.discussions=['one','two'].map(id=>({id,accountId:'synthetic',title:'原有标题',messages:[{role:'user',content:'讨论主题 '+id}],contextSnapshots:[]}));
  const queue=T.createQueue({getState:()=>state,canRun:()=>true,configuration:()=>({model:'mock',baseURL:'https://example.invalid/v1'}),save:async()=>{},
    request:payload=>box.rpc('titleDiscussion',payload),cancel:job=>box.rpc('cancelDiscussionTitle',{accountId:job.state.accountId})});
  return {box,state,queue,calls,advance,reply};
}
test('actual title bridge permits a provider response beyond the generic 25-second deadline',async()=>{
  const h=harness();h.queue.enqueue('one');await tick();h.advance(30000);await tick();
  assert.equal(h.calls.length,1);assert.equal(h.queue.status().activeId,'one');
  h.reply(h.calls[0],{title:'较慢服务返回的标题'});await tick();assert.equal(h.state.discussions[0].title,'较慢服务返回的标题');
});
test('actual title timeout waits for account-specific cancellation before advancing the queue',async()=>{
  const h=harness();h.queue.enqueueAll();await tick();h.advance(650000);await tick();
  assert.equal(h.calls[1].action,'cancelDiscussionTitle');assert.equal(h.calls[1].payload.accountId,'synthetic');
  assert.equal(h.calls.filter(call=>call.action==='titleDiscussion').length,1);assert.equal(h.queue.status().activeId,'one');
  h.reply(h.calls[0],{title:'超时后的迟到标题'});await tick();assert.equal(h.state.discussions[0].title,'原有标题');
  h.reply(h.calls[1]);await tick();assert.equal(h.calls[2].action,'titleDiscussion');assert.equal(h.calls[2].payload.discussionId,'two');
  assert.equal(h.queue.status().failed,1);assert.ok(!h.calls.some(call=>call.action==='cancelAI'));
});
test('unconfirmed timeout cancellation pauses backfill and rechecks cancellation on resume',async()=>{
  const h=harness();h.queue.enqueueAll();await tick();h.advance(650000);await tick();
  h.advance(25000);await tick();assert.equal(h.queue.status().paused,true);assert.equal(h.queue.status().failed,1);
  assert.equal(h.calls.filter(call=>call.action==='titleDiscussion').length,1);
  h.queue.resume();await tick();assert.equal(h.calls.at(-1).action,'cancelDiscussionTitle');
  assert.equal(h.calls.filter(call=>call.action==='titleDiscussion').length,1);
  h.reply(h.calls.at(-1));await tick();assert.equal(h.queue.status().paused,false);assert.equal(h.calls.at(-1).action,'titleDiscussion');
  assert.ok(!h.calls.some(call=>call.action==='cancelAI'));
});
