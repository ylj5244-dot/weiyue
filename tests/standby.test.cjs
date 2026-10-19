const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../Resources/ui/model.js');
const UI = require('../Resources/ui/app.js');
const U = require('../Resources/ui/group-unread.js');
function fixture() {
  const s=M.createState('standby-test');
  M.upsertGroups(s,['a','b'].map(id=>({id,name:id,selected:true})));
  for(const groupId of ['a','b']) M.ingestMessages(s,groupId,[{id:'100',groupId,senderId:'u',senderName:'Member',text:'Saved',sentAt:'2026-10-18T00:00:00Z',attachments:[]}]);
  M.setProgress(s,{groupId:'a',messageId:'100',kind:'manual'});
  M.setProgress(s,{groupId:'a',messageId:'100',kind:'auto'});
  s.settings.activeGroupId='a';s.settings.mode='reader';U.initialize(s,'2026-10-18T00:01:00Z');return s;
}
test('standby reload has no active group but retains last group and every reading anchor',()=>{
  const s=fixture(),progress=JSON.stringify(s.progress);s.settings.readerStandby=true;
  assert.deepEqual(UI.readPreferences(M.normalizeState(JSON.parse(JSON.stringify(s)))),{groupId:'',mode:'reader'});
  UI.rememberPreferences(s,{groupId:'',mode:'reader'});
  assert.equal(s.settings.activeGroupId,'a');assert.equal(JSON.stringify(s.progress),progress);
  UI.rememberPreferences(s,{groupId:'b',mode:'reader'});
  assert.equal(s.settings.readerStandby,false);assert.equal(s.settings.activeGroupId,'b');
});
test('standby counts new messages in every selected group and opening one clears only that group',()=>{
  const s=fixture();s.settings.readerStandby=true;
  for(const groupId of ['a','b']) {
    const accepted=M.ingestMessages(s,groupId,[{id:'101',groupId,senderId:'u',senderName:'Member',text:'New',sentAt:'2026-10-18T00:02:00Z',attachments:[]}]);
    U.observe(s,groupId,accepted,{activeGroupId:UI.readPreferences(s).groupId,freshIds:new Set(['101']),source:'live',requestStartedAt:'2026-10-18T00:02:00Z'});
  }
  assert.equal(U.count(s,'a'),1);assert.equal(U.count(s,'b'),1);
  U.acknowledge(s,'a',s.messages,'2026-10-18T00:03:00Z');
  assert.equal(U.count(s,'a'),0);assert.equal(U.count(s,'b'),1);assert.equal(s.progress.a.manual.messageId,'100');
});
test('standby flag is optional for old data and strictly boolean',()=>{
  const s=fixture();assert.equal(UI.readPreferences(s).groupId,'a');
  for(const value of ['true',1,null,{}]) {s.settings.readerStandby=value;assert.throws(()=>M.normalizeState(s));}
});
