const test = require('node:test');
const assert = require('node:assert/strict');
const S = require('../Resources/ui/storage-management.js');
const C = require('../Resources/ui/cleanup.js');
test('automatic cleanup defaults off and only accepts 1-4 whole days', () => {
  assert.deepEqual(S.preference({}), {enabled:false,retentionDays:3});
  for (const retentionDays of [0,5,-1,1.5,'2']) assert.throws(()=>S.preference({autoCleanup:{enabled:true,retentionDays}}));
  assert.deepEqual(S.preference({autoCleanup:{enabled:true,retentionDays:2}}), {enabled:true,retentionDays:2});
});
test('hourly schedule skips disabled, recent runs and a failure retry window', () => {
  const now=Date.parse('2026-10-21T12:00:00Z'), settings={autoCleanup:{enabled:true,retentionDays:3}};
  assert.equal(S.due({},now),false); assert.equal(S.due(settings,now),true);
  settings.autoCleanup.lastRunAt='2026-10-21T11:40:00Z';assert.equal(S.due(settings,now),false);
  settings.autoCleanup.lastError='incomplete';assert.equal(S.due(settings,now),true);
  assert.equal(S.due(settings,now,now-1000),false);
});
test('cleanup watermark survives manual cleaning and suppresses old replay, while references still merge',()=>{
  const msg=(id,sentAt)=>({accountId:'a',groupId:'g',id,text:'text',sentAt,attachments:[]});
  const state={accountId:'a',revision:2,messages:[msg('protected','2026-10-01T00:00:00Z')],bookmarks:[{groupId:'g',messageId:'protected'}],cleanup:{autoCutoffAt:'2026-10-18T00:00:00Z',autoPendingAssets:[{kind:'image',url:'https://wx1.sinaimg.cn/test.png'}]}};
  const incoming=[msg('old','2026-10-17T00:00:00Z'),msg('protected','2026-10-01T00:00:00Z'),msg('boundary','2026-10-18T00:00:00Z'),msg('unknown','?')];
  assert.deepEqual(C.filterIncoming(state,incoming).map(m=>m.id),['protected','boundary','unknown']);
  const next=C.apply(state,{scope:'all',categories:['text']}).state;
  assert.equal(next.cleanup.autoCutoffAt,state.cleanup.autoCutoffAt);assert.deepEqual(next.cleanup.autoPendingAssets,state.cleanup.autoPendingAssets);
});

test('millisecond retention watermark never accepts the records just deleted by native cleanup',()=>{
  const state={messages:[],cleanup:{autoCutoffAt:'2026-10-18T12:00:00.500Z'}};
  const input=['2026-10-18T12:00:00.400Z','2026-10-18T12:00:00.500Z'].map((sentAt,id)=>({groupId:'g',id:String(id),sentAt}));
  assert.deepEqual(C.filterIncoming(state,input).map(m=>m.id),['1']);
});
