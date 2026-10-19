'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const bridge = require('../Resources/bridge/weibo.js');
const flush = () => new Promise(resolve => setImmediate(resolve));
const START = 1700000000;
function records(count) {
  return Array.from({length:count},(_,i)=>({id:String(9007199254740993000n+BigInt(i)),from_uid:'22',from_user:{screen_name:'合成成员'},time:START+i,content:'合成 '+i}));
}
function fixture(data=[]) {
  let time=1800000000000, serial=0, identity={accountId:'1001',epoch:1}, responder=null;
  const timers=new Map(), events=[], requests=[];
  const sync=bridge.createSynchronizer({
    getIdentity:()=>identity, now:()=>time, emit:event=>events.push(event), AbortController,
    setTimeout(fn,ms){const id=++serial;timers.set(id,{fn,at:time+ms});return id;},clearTimeout(id){timers.delete(id);},
    async fetch(url,init) {
      requests.push({url,init});
      if(responder)return responder(url,init);
      const cursor=new URL(url).searchParams.get('max_mid');
      return new Response(JSON.stringify({messages:data.filter(item=>!cursor||BigInt(item.id)<=BigInt(cursor)).slice(-20)}));
    }
  });
  const f={sync,events,requests,timers,setResponder(fn){responder=fn;},setIdentity(value){identity=value;sync.reset();},
    async advance(ms) {
      const end=time+ms; await flush();
      for(let guard=0;guard<20000;guard++){
        const due=[...timers.entries()].filter(([,item])=>item.at<=end).sort((a,b)=>a[1].at-b[1].at)[0];
        if(!due)break;time=due[1].at;timers.delete(due[0]);due[1].fn();await flush();
      }
      time=end;await flush();
    },
    async finish(promise,limit=1000){let settled=false;promise.finally(()=>{settled=true;}).catch(()=>{});for(let i=0;!settled&&i<limit;i++)await f.advance(250);assert.equal(settled,true,'range settled');return promise;}
  };
  sync.configure({accountId:'1001',groups:[{id:'11',oldestId:'1',newestId:'9999999999999999999',loadedCount:9999}],initialHistoryCount:0});
  return f;
}
function request(from,to,id='range-1'){return {accountId:'1001',groupId:'11',from:new Date(from*1000).toISOString(),to:new Date(to*1000).toISOString(),requestId:id};}

test('range traversal ignores cached bounds, covers inclusive endpoints and preserves sync/reading state',async()=>{
  const f=fixture(records(550)), result=await f.finish(f.sync.loadRange(request(START+105,START+304)));
  assert.equal(result.coverage.complete,true);assert.equal(result.coverage.loadedCount,200);assert.equal(result.messages.length,200);
  assert.ok(result.messages.every(message=>message.accountId==='1001'));
  assert.equal(result.messages[0].text,'合成 105');assert.equal(result.messages.at(-1).text,'合成 304');
  assert.ok(result.coverage.pages>20);
  assert.equal(new URL(f.requests[0].url).searchParams.has('max_mid'),false,'fresh head despite local cached bounds');
  assert.ok(f.requests.every(({init})=>init.method==='GET'&&init.credentials==='same-origin'&&!init.body));
  assert.equal(f.events.filter(event=>event.type==='sync'&&event.phase==='history').length,0);
  const rangeEvents=f.events.filter(event=>event.type==='rangeProgress');
  assert.equal(rangeEvents.at(-1).status,'complete');assert.equal(rangeEvents.at(-1).loadedCount,200);
  assert.ok(rangeEvents.every(event=>event.requestId==='range-1'&&event.accountId==='1001'&&event.groupId==='11'));
  // Background polling may refresh its latest page, but the range itself never
  // archives its 200 selected records or alters the older-history cursor.
  const history=f.sync.loadHistory('11',1);const historyResult=await f.finish(history);
  assert.equal(historyResult.oldestId,'1');
  f.sync.pause();
});

test('an endpoint exactly equal to oldest page time continues to include same-time messages on the next page',async()=>{
  const data=records(45);data.forEach((item,i)=>{item.time=START+(i<10?0:i<30?1:2);});
  const f=fixture(data), result=await f.finish(f.sync.loadRange(request(START+1,START+1)));
  assert.equal(result.coverage.complete,true);assert.equal(result.messages.length,20);assert.equal(result.coverage.pages,2);f.sync.pause();
});

test('short pages alone are not treated as exhausted; empty response confirms available history',async()=>{
  const f=fixture(records(7)), result=await f.finish(f.sync.loadRange(request(START-100,START+100)));
  assert.equal(result.coverage.complete,true);assert.equal(result.coverage.pages,2);assert.equal(result.messages.length,7);assert.match(result.coverage.reason,/接口可提供/);f.sync.pause();
});

test('explicit has_more false confirms endpoint exhaustion, while empty has_more true stays partial',async()=>{
  for(const hasMore of [false,true]){
    const f=fixture();f.setResponder(()=>new Response(JSON.stringify({messages:hasMore?[]:records(4),has_more:hasMore})));
    const result=await f.finish(f.sync.loadRange(request(START-10,START+10)));
    assert.equal(result.coverage.complete,!hasMore);assert.equal(result.coverage.pages,1);f.sync.pause();
  }
});

test('duplicates are deduplicated and malformed or repeated cursor pages never claim complete',async()=>{
  const f=fixture();let calls=0;
  f.setResponder(()=>new Response(JSON.stringify({messages:++calls===1?[...records(20),records(20)[0]]:records(20)})));
  const result=await f.finish(f.sync.loadRange(request(START-10,START+100)));
  assert.equal(result.coverage.complete,false);assert.equal(result.messages.length,20);assert.match(result.coverage.reason,/游标/);f.sync.pause();
});

test('timestamp inversions within a page and across pages produce partial evidence',async()=>{
  for(const across of [false,true]){
    const data=records(40);if(across)data[19].time=START+100;else data[30].time=START+100;
    const f=fixture(data),result=await f.finish(f.sync.loadRange(request(START-10,START+200)));
    assert.equal(result.coverage.complete,false);assert.ok(result.messages.length>=20);assert.match(result.coverage.reason,/时间顺序异常/);f.sync.pause();
  }
});

test('cancelRange aborts only its own transport, returns retained partial messages, and normal sync remains usable',async()=>{
  const f=fixture(records(40));let calls=0;
  f.setResponder((url,init)=>{
    if(++calls===1)return new Response(JSON.stringify({messages:records(40).slice(-20)}));
    return new Promise((resolve,reject)=>init.signal.addEventListener('abort',()=>reject(new Error('aborted')),{once:true}));
  });
  const pending=f.sync.loadRange(request(START-10,START+100));await f.advance(300);
  assert.equal(f.sync.cancelRange({accountId:'1001',requestId:'range-1'}).cancelled,true);
  const result=await f.finish(pending);assert.equal(result.coverage.complete,false);assert.equal(result.messages.length,20);assert.match(result.coverage.reason,/已取消/);
  assert.equal(f.events.filter(event=>event.type==='messages').length,0,'range does not archive');
  f.setResponder(()=>new Response(JSON.stringify({messages:[]})));
  const normal=await f.finish(f.sync.syncNow('11'));assert.equal(normal.cancelled,false);f.sync.pause();
});

test('account reset cancels an unresponsive range immediately and never emits its result to another account',async()=>{
  const f=fixture();let resolve;
  f.setResponder(()=>new Promise(yes=>{resolve=yes;}));
  const pending=f.sync.loadRange(request(START,START+10));await f.advance(1);
  f.setIdentity({accountId:'2002',epoch:2});
  const result=await f.finish(pending);assert.equal(result.coverage.complete,false);assert.equal(result.messages.length,0);
  resolve(new Response(JSON.stringify({messages:records(5)})));await f.advance(1);
  assert.equal(f.events.some(event=>event.type==='messages'),false);
  assert.equal(f.events.filter(event=>event.type==='rangeProgress').length,1);f.sync.pause();
});

test('rate limits respect Retry-After and retry rather than claiming cached completeness',async()=>{
  const f=fixture(records(1));let calls=0;
  f.setResponder(()=>++calls===1?new Response('',{status:429,headers:{'Retry-After':'5'}}):new Response(JSON.stringify({messages:[]})));
  const pending=f.sync.loadRange(request(START-10,START+10));await f.advance(4999);
  assert.equal(calls,1);const result=await f.finish(pending);assert.equal(result.coverage.complete,true);
  assert.ok(f.events.some(event=>event.type==='rangeProgress'&&event.status==='backoff'));f.sync.pause();
});

test('HTTP failure preserves already received messages and a 10-minute rate limit deadline returns partial',async()=>{
  const f=fixture();let calls=0;
  f.setResponder(()=>++calls===1?new Response(JSON.stringify({messages:records(20)})):new Response('',{status:503}));
  const result=await f.finish(f.sync.loadRange(request(START-10,START+100)));
  assert.equal(result.coverage.complete,false);assert.equal(result.messages.length,20);assert.match(result.coverage.reason,/HTTP 503/);f.sync.pause();
  const blocked=fixture();blocked.setResponder(()=>new Response('',{status:429,headers:{'Retry-After':'3600'}}));
  const pending=blocked.sync.loadRange(request(START-10,START+10));await blocked.advance(600001);
  const timed=await pending;assert.equal(timed.coverage.complete,false);assert.match(timed.coverage.reason,/10 分钟/);blocked.sync.pause();
});

test('range validates account, selection, timestamps, future end and duplicate jobs',async()=>{
  const f=fixture();
  for(const bad of [{accountId:'2002'},{groupId:'99'},{from:'invalid'},{from:'2026-02-30T00:00:00.000Z'},{to:new Date(1900000000000).toISOString()},{from:new Date((START+20)*1000).toISOString()},{requestId:''}]){
    await assert.rejects(f.sync.loadRange({...request(START,START+10),...bad}));
  }
  let resolve;f.setResponder(()=>new Promise(yes=>{resolve=yes;}));
  const pending=f.sync.loadRange(request(START,START+10));await f.advance(1);
  await assert.rejects(f.sync.loadRange(request(START,START+10)),/正在读取/);
  assert.throws(()=>f.sync.cancelRange({accountId:'2002',requestId:'range-1'}),/账号/);
  f.sync.cancelRange({accountId:'1001',requestId:'range-1'});await f.finish(pending);
  resolve(new Response(JSON.stringify({messages:[]})));await f.advance(1);f.sync.pause();
});

test('page limit retains evidence while explicitly marking the range partial',async()=>{
  const f=fixture(records(5000)),result=await f.finish(f.sync.loadRange(request(START-1,START+6000)),500);
  assert.equal(result.coverage.complete,false);assert.equal(result.coverage.pages,200);assert.equal(result.messages.length,4000);assert.match(result.coverage.reason,/200 页/);f.sync.pause();
});

test('cancelling a queued range does not abort an unrelated in-flight live poll',async()=>{
  const f=fixture();let resolve;
  f.setResponder(()=>new Promise(yes=>{resolve=yes;}));
  const live=f.sync.syncNow('11');await f.advance(1);
  const pending=f.sync.loadRange(request(START,START+10));await f.advance(1);
  f.sync.cancelRange({accountId:'1001',requestId:'range-1'});
  const result=await f.finish(pending);assert.equal(result.coverage.complete,false);assert.equal(result.coverage.pages,0);
  assert.equal(f.requests[0].init.signal.aborted,false,'normal live request remains active');
  resolve(new Response(JSON.stringify({messages:[]})));await f.finish(live);
  assert.equal(f.requests.length,1,'cancelled queued range never dispatches');f.sync.pause();
});

test('deselecting a group cancels its range and rejects late pages without importing or claiming completeness',async()=>{
  const f=fixture();let resolve;
  f.setResponder(()=>new Promise(yes=>{resolve=yes;}));
  const pending=f.sync.loadRange(request(START,START+10));await f.advance(1);
  f.sync.configure({accountId:'1001',groups:[],initialHistoryCount:0});
  const result=await f.finish(pending);assert.equal(result.coverage.complete,false);assert.equal(result.messages.length,0);
  resolve(new Response(JSON.stringify({messages:records(5)})));await f.advance(1);
  assert.equal(f.events.some(event=>event.type==='messages'),false);f.sync.pause();
});
