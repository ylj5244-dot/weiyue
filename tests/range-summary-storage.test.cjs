const test=require('node:test');
const assert=require('node:assert/strict');
const M=require('../Resources/ui/model.js');
function fixture(count=3){
  const state=M.createState('account'), snapshots=Array.from({length:count},(_,index)=>({accountId:'account',groupId:'group',id:String(index),senderId:'member',senderName:'Member',sentAt:new Date(Date.parse('2026-10-18T00:00:00Z')+index*1000).toISOString(),text:'Message '+index,attachments:[],contextScope:'text'}));
  const summary={version:1,groupId:'group',startAt:'2026-10-18T00:00:00.000Z',endAt:'2026-10-18T02:00:59.999Z',label:'Summary range',sourceCount:count,coverage:{complete:true,reason:'已核对时段',from:'2026-10-18T00:00:00.000Z',to:'2026-10-18T02:00:59.999Z',checkedAt:'2026-10-18T03:00:00Z',loadedCount:count,pages:2},status:'complete',batchCount:2,completedBatches:2,partials:['First [消息1]','Second [消息2]'],prompt:'Please summarize',stage:'reduce',round:1,reductionCompleted:1,rounds:1,finalText:'Summary [消息1] [消息2]'};
  state.discussions=[{id:'summary',accountId:'account',createdAt:'2026-10-18T03:00:00Z',contextSnapshots:snapshots,instructions:'Use paragraphs',messages:[{role:'user',content:'Summarize'},{role:'assistant',content:summary.finalText}],rangeSummary:summary}];
  state.settings.activeDiscussionId='summary';return state;
}
test('range summaries preserve 1501 ordered source snapshots, final citations and interrupted checkpoints across JSON restart',()=>{
  const state=fixture(1501);assert.deepEqual(M.normalizeState(JSON.parse(JSON.stringify(state))),state);
  const summary=state.discussions[0].rangeSummary;summary.status='interrupted';summary.error='Stopped';summary.stage='map';summary.completedBatches=1;summary.partials=['First [消息1]'];delete summary.finalText;
  assert.deepEqual(M.normalizeState(JSON.parse(JSON.stringify(state))),state);
  delete state.discussions[0].rangeSummary;delete state.discussions[0].contextSnapshots;
  assert.doesNotThrow(()=>M.normalizeState(state));
});
test('range summary metadata rejects corrupt counts, statuses, bounds and source relationships',()=>{
  const changes=[
    s=>s.version=2,s=>s.unknown=true,s=>s.status='done',s=>s.sourceCount=2,s=>s.sourceCount=Infinity,s=>s.sourceCount=true,
    s=>s.batchCount=0,s=>s.batchCount=1.5,s=>s.completedBatches=3,s=>s.completedBatches=-1,s=>s.partials=[],s=>s.partials[0]='',s=>s.finalText='',s=>delete s.finalText,
    s=>s.startAt='bad',s=>s.endAt='2026-10-17T00:00:00Z',s=>s.groupId='other',s=>s.coverage.complete='true',s=>s.coverage.loadedCount=4,s=>s.coverage.from='2026-10-17T00:00:00Z',s=>s.coverage.to='2026-10-19T00:00:00Z',s=>s.coverage.checkedAt='bad',s=>s.coverage.pages=-1,s=>s.coverage.pages=true,s=>s.coverage.extra=true,s=>s.stage='unknown',s=>s.round=0,s=>s.rounds=9,s=>s.reductionCompleted=-1,s=>s.prompt=null,s=>s.label='x'.repeat(4097),s=>s.partials[0]='x'.repeat(1000001)
  ];
  for(const change of changes){const state=fixture();change(state.discussions[0].rangeSummary);assert.throws(()=>M.normalizeState(state));}
  for(const change of [s=>s[0].accountId='other',s=>s[0].groupId='other',s=>s[0].id=s[1].id,s=>s[0].sentAt='2026-10-17T00:00:00Z',s=>s.reverse(),s=>s.pop()]){const state=fixture();change(state.discussions[0].contextSnapshots);assert.throws(()=>M.normalizeState(state));}
});
test('running checkpoints allow zero completed batches and partial coverage without claiming completion',()=>{
  const state=fixture(),summary=state.discussions[0].rangeSummary;
  summary.status='running';summary.completedBatches=0;summary.partials=[];summary.coverage.complete=false;summary.coverage.reason='请求失败，只能核对部分';delete summary.finalText;
  assert.deepEqual(M.normalizeState(state),state);
});
