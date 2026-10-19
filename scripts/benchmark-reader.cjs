'use strict';
// Synthetic-only benchmark. No application archive, session or credentials are read.
const {performance}=require('node:perf_hooks');
const M=require('../Resources/ui/model.js');
const {ArchiveIndex,HeightIndex,CoalescedQueue}=require('../Resources/ui/reader-performance.js');
const count=5000;
const state=M.createState('synthetic-benchmark');
M.upsertGroups(state,[{id:'group',name:'Synthetic performance fixture',selected:true}]);
M.ingestMessages(state,'group',Array.from({length:count},(_,i)=>({id:String(i),groupId:'group',senderId:'u'+i%50,senderName:'Demo '+i%50,text:'Synthetic message '+i+' '+('example '.repeat(i%20+2)),sentAt:new Date(1700000000000+i*30000).toISOString(),attachments:[]})));
const index=new ArchiveIndex(state.messages);
function measure(work){const times=[];for(let i=0;i<80;i++){const start=performance.now();work();times.push(performance.now()-start);}times.sort((a,b)=>a-b);return {medianMs:+times[40].toFixed(4),p95Ms:+times[76].toFixed(4)};}
async function main(){
  const range=new HeightIndex(Array(count).fill(80)).range(200000,900,700);
  const queue=new CoalescedQueue();let release,writes=0;
  const first=queue.request('a',async()=>{writes++;await new Promise(resolve=>release=resolve);});
  await new Promise(resolve=>setTimeout(resolve,5));
  const remaining=Array.from({length:99},()=>queue.request('a',async()=>{writes++;}));release();await Promise.all([first,...remaining]);
  console.log(JSON.stringify({fixtureMessages:count,legacyFullArchiveQuery:measure(()=>M.searchMessages(state,{groupId:'group'})),indexedUnfilteredQuery:measure(()=>index.search({groupId:'group'})),indexedKeywordQuery:measure(()=>index.search({groupId:'group',query:'message 4999'})),legacyExtraSnapshotClone:measure(()=>JSON.parse(JSON.stringify(state))),rendering:{legacyMessageCards:count,windowedMessageCards:range.end-range.start,viewportHeight:900,overscanPixels:700,estimatedRowHeight:80},saving:{requests:100,legacyQueuedWrites:100,coalescedWrites:writes}},null,2));
}
main().catch(error=>{console.error(error);process.exitCode=1;});
