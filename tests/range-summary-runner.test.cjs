const test=require('node:test'),assert=require('node:assert/strict');
const R=require('../Resources/ui/range-summary-runner.js'),S=require('../Resources/ui/range-summary.js'),P=require('../Resources/ui/preferences.js');
function fixture(count=230){return Array.from({length:count},(_,index)=>({id:String(index),accountId:'a',groupId:'g',senderId:'u',senderName:'User',sentAt:'2026-10-17T01:00:00Z',text:'Message '+index,attachments:[]}));}
const options={preferences:P.defaults(),prompt:'Summarize all selected messages',temporary:'TEMP_STYLE',coverage:'Verified complete'};
test('all originals are mapped exactly once before final merge with preferences on every request',async()=>{
 const calls=[],checkpoints=[],progress=[],snapshots=fixture();
 const output=await R.run({snapshots,options,request:async(messages,info)=>{calls.push({messages,info});return info.stage==='map'?'Notes [消息1]':'Final [消息1]';},checkpoint:async data=>checkpoints.push(data),progress:data=>progress.push(data),isCancelled:()=>false});
 const expected=S.plan(snapshots).length;assert.equal(calls.filter(c=>c.info.stage==='map').length,expected);assert.equal(output.batchCount,expected);assert.equal(calls.at(-1).info.stage,'reduce');assert.equal(output.text,'Final [消息1]');
 for(const call of calls)assert.match(call.messages[0].content,/TEMP_STYLE/);
 assert.equal(checkpoints.filter(c=>c.stage==='map').at(-1).completedBatches,expected);assert.equal(progress.length,calls.length);
 const sent=calls.filter(c=>c.info.stage==='map').flatMap(c=>[...c.messages[1].content.matchAll(/\[消息(\d+)\]（片段/g)].map(m=>Number(m[1])));assert.deepEqual(sent,Array.from({length:230},(_,i)=>i+1));
});
test('cancellation after a request stops before saving the late result or sending another batch',async()=>{let cancelled=false,calls=0,saves=0;await assert.rejects(R.run({snapshots:fixture(),options,request:async()=>{calls++;cancelled=true;return'late';},checkpoint:async()=>saves++,progress:()=>{},isCancelled:()=>cancelled}),/取消/);assert.equal(calls,1);assert.equal(saves,0);});
test('failed durable checkpoint prevents remaining AI calls',async()=>{let calls=0;await assert.rejects(R.run({snapshots:fixture(),options,request:async()=>{calls++;return'notes';},checkpoint:async()=>{throw Error('disk unavailable');},progress:()=>{},isCancelled:()=>false}),/disk unavailable/);assert.equal(calls,1);});
test('empty output and nonshrinking reduction fail explicitly instead of completing',async()=>{await assert.rejects(R.run({snapshots:fixture(1),options,request:async()=>'',checkpoint:async()=>{},progress:()=>{},isCancelled:()=>false}),/有效总结/);await assert.rejects(R.run({snapshots:fixture(1),options,request:async()=> 'X'.repeat(20000),checkpoint:async()=>{},progress:()=>{},isCancelled:()=>false}),/缩短/);});
