'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const M=require('../Resources/ui/model.js');
const NOW='2026-10-18T01:02:03.000Z';
function fixture(){const state=M.createState('a');M.upsertGroups(state,[{id:'g',name:'Demo',selected:true}]);M.ingestMessages(state,'g',[{id:'1',groupId:'g',senderId:'u',senderName:'Demo',text:'Original content',sentAt:NOW,attachments:[{type:'image',url:'https://example.test/demo.png'}]}]);for(let i=0;i<3;i++)M.createCollection(state,{name:'Collection '+i,messageIds:['g:1'],now:NOW});M.addBookmark(state,{groupId:'g',messageId:'1',now:NOW});M.setProgress(state,{groupId:'g',messageId:'1',offset:8,now:NOW});state.discussions=[{id:'discussion',accountId:'a',collectionId:state.collections[0].id,messages:[{role:'assistant',content:'Saved discussion'}]}];state.collections[0].discussionId='discussion';return state;}
test('single and batch collection delete is reversible and preserves every source and AI discussion',()=>{
  const state=fixture(),ids=state.collections.slice(0,2).map(c=>c.id),before={messages:JSON.stringify(state.messages),bookmarks:JSON.stringify(state.bookmarks),progress:JSON.stringify(state.progress),discussions:JSON.stringify(state.discussions)};
  assert.equal(typeof M.removeCollections,'function');
  const removed=M.removeCollections(state,ids,NOW);assert.equal(removed.length,2);assert.equal(state.collections.filter(c=>!c.deletedAt).length,1);
  assert.ok(state.collections.slice(0,2).every(c=>c.deletedAt===NOW));
  for(const [key,value]of Object.entries(before))assert.equal(JSON.stringify(state[key]),value,key+' must remain unchanged');
  const restored=M.normalizeState(JSON.parse(JSON.stringify(state)));
  assert.equal(restored.collections.filter(c=>c.deletedAt).length,2,'recently deleted survives reopen');
  assert.equal(M.restoreCollections(restored,ids).length,2);assert.ok(restored.collections.every(c=>!c.deletedAt));assert.equal(restored.collections[0].discussionId,'discussion');
});
test('batch delete validates every ID before mutation and deduplicates selection',()=>{
  const state=fixture(),before=JSON.stringify(state),id=state.collections[0].id;
  assert.throws(()=>M.removeCollections(state,[id,'missing'],NOW));assert.equal(JSON.stringify(state),before);
  assert.throws(()=>M.removeCollections(state,[id], 'not-a-date'));assert.equal(JSON.stringify(state),before);
  assert.equal(M.removeCollections(state,[id,id],NOW).length,1);
  const revision=state.revision;assert.equal(M.removeCollections(state,[id],NOW).length,0);assert.equal(state.revision,revision);
  assert.throws(()=>M.restoreCollections(state,[id,'missing']));assert.equal(state.collections[0].deletedAt,NOW);
  assert.equal(M.restoreCollections(state,[id,id]).length,1);
});
test('malformed deletion metadata is rejected at restore and original collections stay backward compatible',()=>{
  const state=fixture();assert.ok(M.normalizeState(state).collections.every(c=>!c.deletedAt));
  state.collections[0].deletedAt='not-a-date';assert.throws(()=>M.normalizeState(state));
});

test('the actual collection picker limits select-all to current search and deleted/active scope',()=>{
  const fs=require('node:fs'),vm=require('node:vm'),source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
  const section=source.slice(source.indexOf('  function collectionItems()'),source.indexOf('  function renderCollections()',source.indexOf('  function collectionItems()')));
  const state=fixture(),ids=state.collections.map(c=>c.id),elements={};
  for(const name of ['collection-search','collections-select-all','collections-bulk-action','collections-undo'])elements[name]={value:'',disabled:false};
  const selection=new Set(ids),labels={},visibility={};
  const environment={state,deletedCollections:false,selectedCollectionIds:selection,collectionsBusy:false,collectionUndo:null,$:id=>elements[id],text:(id,value)=>labels[id]=value,show:(id,value)=>visibility[id]=value};
  const context=vm.createContext(environment);vm.runInContext(section,context);
  elements['collection-search'].value='Collection 1';vm.runInContext('updateCollectionSelection()',context);
  assert.deepEqual(Array.from(selection),[ids[1]],'hidden selected collections are never included in batch deletion');
  assert.equal(elements['collections-select-all'].checked,true);assert.equal(labels['collections-selection-count'],'已选 1 组');
  M.removeCollections(state,[ids[1]],NOW);vm.runInContext('updateCollectionSelection()',context);assert.equal(selection.size,0);assert.equal(elements['collections-bulk-action'].disabled,true);
  context.deletedCollections=true;elements['collection-search'].value='';
  assert.deepEqual(Array.from(vm.runInContext('collectionItems().map(item=>item.id)',context)),[ids[1]]);
  context.collectionUndo={ids:[ids[1]],deletedAt:NOW};vm.runInContext('updateCollectionSelection()',context);assert.equal(visibility['collections-undo-bar'],true);
  M.restoreCollections(state,[ids[1]]);vm.runInContext('updateCollectionSelection()',context);assert.equal(visibility['collections-undo-bar'],false);
});
test('delete confirmation has an explicit count, recovery copy and separate action controls',()=>{
  const fs=require('node:fs'),html=fs.readFileSync(require.resolve('../Resources/ui/index.html'),'utf8'),source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
  assert.match(html,/id="collection-delete-form"/);assert.match(html,/id="collections-undo"/);assert.match(html,/id="collections-select-all"/);assert.match(html,/原始聊天、附件文件、书签和 AI 讨论均保留/);
  assert.match(source,/pendingCollectionDeleteIds\.length \+ ' 组收藏'/);
  assert.match(source,/if \(ids\.includes\(contextCollectionId\)\) \{ contextCollectionId = null;/,'deleting active collection must detach its AI save target');
});
