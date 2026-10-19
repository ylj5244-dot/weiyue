const test = require('node:test');
const assert = require('node:assert/strict');
const T = require('../Resources/ui/discussion-titles.js');
const M = require('../Resources/ui/model.js');
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve, reject; const promise = new Promise((a,b) => {resolve=a;reject=b;}); return {promise,resolve,reject}; };
function fixture() {
  const state=M.createState('account');
  state.discussions=['one','two'].map(id=>({id,accountId:'account',createdAt:'2026-10-19T01:00:00.000Z',title:'原有提问 '+id,messages:[{role:'user',content:'分析光模块的需求和供给 '+id},{role:'assistant',content:'讨论了产能、客户预算和交付周期。'}],contextSnapshots:[]}));
  return state;
}
function harness() {
  let state=fixture(),available=true,failSave=false;
  const calls=[],requests=[],saves=[];let cancels=0;
  const queue=T.createQueue({getState:()=>state,canRun:()=>available,configuration:()=>({baseURL:'https://example.invalid/v1',model:'mock'}),
    request:payload=>{calls.push(payload);const request=deferred();requests.push(request);return request.promise;},
    cancel:()=>{cancels++;return Promise.resolve();},save:async()=>{if(failSave)throw new Error('disk unavailable');saves.push(JSON.parse(JSON.stringify(state)));}});
  return {queue,calls,requests,saves,get state(){return state;},set state(value){state=value;},set available(value){available=value;},set failSave(value){failSave=value;},get cancels(){return cancels;}};
}
test('title input is bounded, includes initial and recent topics, excludes hidden reasoning and errors',()=>{
  const state=fixture(),discussion=state.discussions[0];
  discussion.messages=Array.from({length:100},(_,i)=>({role:i%2?'assistant':'user',content:'turn'+i+' '+ '中'.repeat(10000),reasoning:'SECRET_REASONING',error:'KEY_ERROR'}));
  discussion.messages.push({role:'system',content:'SYSTEM_SECRET'},{role:'user',content:'PENDING_SECRET',status:'pending'});
  const input=T.input(discussion);const serialized=JSON.stringify(input);
  assert.ok(serialized.includes('turn0')&&serialized.includes('turn99'));
  assert.ok(!serialized.includes('turn50')&&!serialized.includes('SECRET')&&!serialized.includes('KEY_ERROR'));
  assert.ok(serialized.length<20000);
  const first=T.fingerprint(discussion);discussion.messages.push({role:'assistant',content:'新的主题：硅光封装'});assert.notEqual(T.fingerprint(discussion),first);
});
test('normalization unwraps a title and refuses explanations, JSON, blanks and markup',()=>{
  assert.equal(T.normalizeTitle('标题：**光模块供需与交付周期**'),'光模块供需与交付周期');
  assert.equal(T.normalizeTitle('“Optical capacity outlook”'),'Optical capacity outlook');
  for(const value of ['',null,'标题一\n标题二','{"title":"标题"}','<think>thinking</think>','1. 分析主题','---','长'.repeat(33),'理由：这更概括','以下是讨论标题'])assert.throws(()=>T.normalizeTitle(value));
  assert.equal(T.normalizeTitle('长'.repeat(32)),'长'.repeat(32));
});
test('decimal technology names and embedded book or quotation marks survive normalization',()=>{
  for(const value of ['1.6T光模块需求与供给','3.5GHz频段的部署','《资本论》中的价值理论','为什么重读《资本论》','“零利率”之后的资产定价'])assert.equal(T.normalizeTitle(value),value);
  assert.equal(T.normalizeTitle('标题：**“1.6T光模块需求”**'),'1.6T光模块需求');
});
test('one serialized queue backfills old history without changing creation order or primary messages',async()=>{
  const h=harness(),before=JSON.parse(JSON.stringify(h.state));h.queue.enqueueAll();await tick();
  assert.equal(h.calls.length,1);assert.equal(h.calls[0].discussionId,'one');
  h.requests[0].resolve({title:'光模块需求与产能'});await tick();
  assert.equal(h.calls.length,2);assert.equal(h.state.discussions[0].title,'光模块需求与产能');
  h.requests[1].resolve({title:'客户预算与交付周期'});await tick();
  assert.equal(h.queue.status().remaining,0);assert.equal(h.state.discussions[0].titleInfo.source,'ai');
  h.state.discussions.forEach((d,i)=>{assert.equal(d.createdAt,before.discussions[i].createdAt);assert.deepEqual(d.messages,before.discussions[i].messages);});
  h.queue.enqueueAll();await tick();assert.equal(h.calls.length,2);assert.doesNotThrow(()=>M.normalizeState(h.state));
});
test('changed content discards an obsolete title and requests a fresh one',async()=>{
  const h=harness();h.queue.enqueue('one');await tick();h.state.discussions[0].messages.push({role:'user',content:'再比较新主题'});
  h.requests[0].resolve({title:'过时标题'});await tick();assert.equal(h.state.discussions[0].title,'原有提问 one');assert.equal(h.calls.length,2);
  h.requests[1].resolve({title:'新的对比主题'});await tick();assert.equal(h.state.discussions[0].title,'新的对比主题');
});
test('account reset and deletion suppress late results without writes to another account',async()=>{
  const h=harness();h.queue.enqueueAll();await tick();h.queue.reset();h.state=M.createState('other');
  h.requests[0].resolve({title:'不能串号'});await tick();assert.equal(h.state.discussions.length,0);assert.equal(h.cancels,1);
  const d=harness();d.queue.enqueue('one');await tick();d.state.discussions[0].deletedAt='2026-10-19T02:00:00.000Z';d.requests[0].resolve({title:'已删除标题'});await tick();assert.equal(d.state.discussions[0].title,'原有提问 one');assert.equal(d.calls.length,1);
});
test('primary AI activity preempts title work; pause/resume does not cancel primary requests',async()=>{
  const h=harness();h.queue.enqueueAll();await tick();h.available=false;h.queue.activityChanged();
  h.requests[0].resolve({title:'不能写入的结果'});await tick();assert.equal(h.cancels,1);assert.equal(h.calls.length,1);assert.equal(h.state.discussions[0].title,'原有提问 one');
  h.available=true;h.queue.activityChanged();await tick();assert.equal(h.calls.length,2);
  h.queue.pause();h.requests[1].resolve({title:'暂停时的旧结果'});await tick();assert.equal(h.calls.length,2);assert.equal(h.queue.status().paused,true);
  h.queue.resume();await tick();assert.equal(h.calls.length,3);h.requests[2].resolve({title:'恢复后的标题'});await tick();
  assert.equal(h.state.discussions[0].title,'恢复后的标题');
});
test('failed titles preserve fallback, avoid retry loops, and can be retried explicitly',async()=>{
  const h=harness();h.queue.enqueueAll();await tick();h.requests[0].reject(new Error('provider unavailable'));await tick();h.requests[1].resolve({title:'有效标题'});await tick();
  assert.equal(h.state.discussions[0].title,'原有提问 one');assert.equal(h.queue.status().failed,1);
  h.queue.enqueueAll();await tick();assert.equal(h.calls.length,2);
  h.queue.retry();await tick();assert.equal(h.calls.length,3);h.requests[2].resolve({title:'重试成功标题'});await tick();assert.equal(h.queue.status().failed,0);
});
test('disk failure after generation is retried without another model charge',async()=>{
  const h=harness();h.queue.enqueue('one');await tick();h.failSave=true;h.requests[0].resolve({title:'已生成尚未保存'});await tick();
  assert.equal(h.calls.length,1);assert.equal(h.queue.status().failed,1);h.failSave=false;h.queue.retry();await tick();
  assert.equal(h.calls.length,1);assert.equal(h.queue.status().failed,0);assert.equal(h.saves.at(-1).discussions[0].title,'已生成尚未保存');
});
test('persisted AI title metadata survives reload and malformed metadata is rejected',()=>{
  const state=fixture(),d=state.discussions[0];d.titleInfo={version:1,source:'ai',fingerprint:T.fingerprint(d),model:'mock',generatedAt:'2026-10-19T02:00:00.000Z'};
  assert.equal(T.needsTitle(d),false);assert.doesNotThrow(()=>M.normalizeState(state));
  for(const patch of [{source:'invented'},{fingerprint:''},{generatedAt:'yesterday'},{version:9},{model:4}]) {const value=JSON.parse(JSON.stringify(state));Object.assign(value.discussions[0].titleInfo,patch);assert.throws(()=>M.normalizeState(value));}
});
test('bulk backfill publishes one update instead of repeatedly rebuilding the history list',()=>{
  const state=fixture();state.discussions=Array.from({length:500},(_,i)=>({...state.discussions[0],id:'d'+i}));let changes=0;
  const queue=T.createQueue({getState:()=>state,canRun:()=>false,onChange:()=>changes++});queue.enqueueAll();
  assert.equal(queue.status().remaining,500);assert.ok(changes<=2,'bulk enqueue should batch view notifications');
});
test('failed interrupt cancellation pauses the queue until a confirmed cancellation permits resume',async()=>{
  const state=fixture(),requests=[],cancels=[];
  const queue=T.createQueue({getState:()=>state,canRun:()=>true,configuration:()=>({model:'mock'}),save:async()=>{},
    request:()=>{const request=deferred();requests.push(request);return request.promise;},
    cancel:()=>{const request=deferred();cancels.push(request);return request.promise;}});
  queue.enqueueAll();await tick();queue.pause();await tick();cancels[0].reject(new Error('cancel unavailable'));await tick();
  assert.equal(queue.status().paused,true);queue.resume();await tick();
  assert.equal(cancels.length,2,'resume must reconfirm cancellation');assert.equal(requests.length,1,'no new title may start before cancellation');
  cancels[1].resolve();await tick();assert.equal(requests.length,2);assert.equal(queue.status().paused,false);
});
test('confirmed cancellation can resume after the same account state is reloaded by cleanup',async()=>{
  let state=fixture();const requests=[],cancels=[];
  const queue=T.createQueue({getState:()=>state,canRun:()=>true,configuration:()=>({model:'mock'}),save:async()=>{},
    request:()=>{const request=deferred();requests.push(request);return request.promise;},
    cancel:()=>{const request=deferred();cancels.push(request);return request.promise;}});
  queue.enqueueAll();await tick();queue.pause();await tick();cancels[0].reject(new Error('cancel unavailable'));await tick();
  state=M.normalizeState(JSON.parse(JSON.stringify(state)));queue.resume();await tick();cancels[1].resolve();await tick();
  assert.equal(queue.status().paused,false);assert.equal(requests.length,2);
});
test('a later pause remains effective while cancellation is being rechecked',async()=>{
  const state=fixture(),requests=[],cancels=[];
  const queue=T.createQueue({getState:()=>state,canRun:()=>true,configuration:()=>({model:'mock'}),save:async()=>{},
    request:()=>{const request=deferred();requests.push(request);return request.promise;},
    cancel:()=>{const request=deferred();cancels.push(request);return request.promise;}});
  queue.enqueueAll();await tick();queue.pause();await tick();cancels[0].reject(new Error('cancel unavailable'));await tick();
  queue.resume();await tick();queue.pause();cancels[1].resolve();await tick();
  assert.equal(queue.status().paused,true);assert.equal(requests.length,1);
  queue.resume();await tick();assert.equal(requests.length,2);
});
