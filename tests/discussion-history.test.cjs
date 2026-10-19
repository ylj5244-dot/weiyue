const test=require('node:test');
const assert=require('node:assert/strict');
const M=require('../Resources/ui/model.js');
const P=require('../Resources/ui/preferences.js');
const stamp='2026-10-18T01:00:00.000Z';
function fixture(){
  const state=M.createState('account');
  M.upsertGroups(state,[{id:'group',name:'Group',selected:true}]);
  M.ingestMessages(state,'group',[{id:'1',groupId:'group',senderId:'member',senderName:'Member',text:'Original chat',sentAt:stamp,attachments:[]}]);
  M.addBookmark(state,{groupId:'group',messageId:'1',note:'Read later',now:stamp});
  M.createCollection(state,{messageIds:['group:1'],name:'Saved source',now:stamp});
  state.settings.aiPreferences=P.defaults();state.settings.aiDraftInstructions='My temporary draft';state.settings.activeDiscussionId='d2';
  state.discussions=['d1','d2','d3'].map(id=>({id,accountId:'account',createdAt:stamp,title:id,instructions:'Writing style',contextSnapshots:JSON.parse(JSON.stringify(state.messages)),messages:[{role:'user',content:'Question'},{role:'assistant',content:'Answer'}]}));
  state.collections[0].discussionId='d2';return state;
}
const copy=value=>JSON.parse(JSON.stringify(value));
test('single discussion deletion is reversible and preserves chat, sources, bookmarks, collections and personal settings',()=>{
  const state=fixture(),before=copy(state),revision=state.revision;
  const changed=M.deleteDiscussions(state,['d2'],stamp);
  assert.equal(changed.length,1);assert.equal(changed[0].id,'d2');assert.equal(state.discussions[1].deletedAt,stamp);assert.equal(state.settings.activeDiscussionId,null);assert.equal(state.revision,revision+1);
  for(const key of ['messages','groups','bookmarks','collections','progress'])assert.deepEqual(state[key],before[key]);
  assert.deepEqual(state.settings.aiPreferences,before.settings.aiPreferences);assert.equal(state.settings.aiDraftInstructions,before.settings.aiDraftInstructions);
  const withoutFlag=copy(state.discussions);delete withoutFlag[1].deletedAt;assert.deepEqual(withoutFlag,before.discussions);
  assert.deepEqual(M.normalizeState(copy(state)),state);
  assert.equal(M.restoreDiscussions(state,['d2']).length,1);assert.equal(state.discussions[1].deletedAt,null);assert.equal(state.settings.activeDiscussionId,null);
  assert.deepEqual(M.normalizeState(copy(state)),state);
});
test('batch deletion and clear-all prevalidate all IDs, deduplicate repeats and remain idempotent',()=>{
  const state=fixture(),before=copy(state);
  assert.throws(()=>M.deleteDiscussions(state,['d1','missing'],stamp));assert.deepEqual(state,before);
  assert.throws(()=>M.deleteDiscussions(state,['d1',null],stamp));assert.deepEqual(state,before);
  assert.throws(()=>M.deleteDiscussions(state,['d1'],'bad-time'));assert.deepEqual(state,before);
  assert.equal(M.deleteDiscussions(state,['d1','d1','d2','d3'],stamp).length,3);const revision=state.revision;
  assert.equal(M.deleteDiscussions(state,['d1','d2','d3'],stamp).length,0);assert.equal(state.revision,revision);
  const deleted=copy(state);assert.throws(()=>M.restoreDiscussions(state,['d1','missing']));assert.deepEqual(state,deleted);
  assert.equal(M.restoreDiscussions(state,['d1','d2','d3']).length,3);const restoredRevision=state.revision;
  assert.equal(M.restoreDiscussions(state,['d1']).length,0);assert.equal(state.revision,restoredRevision);
  assert.equal(M.deleteDiscussions(state,[],stamp).length,0);assert.equal(state.revision,restoredRevision);
});
test('history operations reject cross-account entities and malformed deletedAt without partial changes',()=>{
  const state=fixture();state.discussions[2].accountId='other';const before=copy(state);
  assert.throws(()=>M.deleteDiscussions(state,['d1'],stamp));assert.deepEqual(state,before);
  assert.throws(()=>M.restoreDiscussions(state,['d1']));assert.deepEqual(state,before);
  for(const invalid of ['',0,true,{},'yesterday','2026-10-18']){const candidate=fixture();candidate.discussions[0].deletedAt=invalid;assert.throws(()=>M.normalizeState(candidate));}
  const empty=fixture();empty.discussions[0].deletedAt=null;assert.doesNotThrow(()=>M.normalizeState(empty));
});
