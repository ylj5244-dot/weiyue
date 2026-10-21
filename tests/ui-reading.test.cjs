'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const M = require('../Resources/ui/model.js');
const sandbox = {module: {exports: {}}, console, URL};
vm.runInNewContext(fs.readFileSync(require.resolve('../Resources/ui/app.js'), 'utf8'), sandbox);
const UI = sandbox.module.exports;
const plain = value => JSON.parse(JSON.stringify(value));
function fixture() {
  const state = M.createState('account-A');
  M.upsertGroups(state, [{id:'first',name:'首群',selected:true},{id:'second',name:'上次读的群',selected:true}]);
  M.ingestMessages(state, 'second', [
    {id:'same-id',groupId:'second',senderId:'u1',senderName:'甲',text:'上次读到这里',sentAt:'2026-10-17T00:00:00.000Z',attachments:[]},
    {id:'newest',groupId:'second',senderId:'u2',senderName:'乙',text:'刚到的新消息',sentAt:'2026-10-18T00:00:00.000Z',attachments:[]}
  ]);
  M.setProgress(state,{groupId:'second',messageId:'same-id',offset:8});
  return state;
}

test('reopening restores the chosen group and reader mode instead of the first group', () => {
  assert.equal(typeof UI.rememberPreferences, 'function', 'UI must expose its real preference policy to regression tests');
  const state = fixture();
  UI.rememberPreferences(state, {groupId:'second',mode:'reader'});
  const restored = M.normalizeState(JSON.parse(JSON.stringify(state)));
  assert.deepEqual(plain(UI.readPreferences(restored)), {groupId:'second',mode:'reader'});
  const revision = state.revision;
  assert.equal(UI.rememberPreferences(state, {groupId:'second',mode:'reader'}), false);
  assert.equal(state.revision, revision, 'reselecting the same view must not create redundant disk saves');
});

test('invalid saved group and mode recover to an available group without losing progress', () => {
  assert.equal(typeof UI.readPreferences, 'function');
  const state = fixture(); state.settings.activeGroupId='removed'; state.settings.mode='bad';
  const progress = JSON.stringify(state.progress);
  assert.deepEqual(plain(UI.readPreferences(state)),{groupId:'first',mode:'official'});
  assert.equal(JSON.stringify(state.progress),progress);
});

test('prepend history and append live messages keep the visible message anchor, never newest', () => {
  assert.equal(typeof UI.chooseAnchor, 'function');
  const state = fixture(), before = JSON.stringify(state.progress);
  const history = Array.from({length:500},(_,i)=>({id:'old-'+i,groupId:'second'}));
  const messages = history.concat(state.messages, [{id:'live',groupId:'second'}]);
  const anchor = UI.chooseAnchor({state,groupId:'second',messages,visible:{accountId:'account-A',groupId:'second',messageId:'same-id',offset:13}});
  assert.deepEqual(plain(anchor),{accountId:'account-A',groupId:'second',messageId:'same-id',offset:13});
  assert.equal(JSON.stringify(state.progress),before,'rendering must never write a reading position');
});

test('a render anchor preserves signed visual spacing before the next card', () => {
  const state = fixture();
  const visible = {accountId:'account-A',groupId:'second',messageId:'same-id',offset:0,visualOffset:-12};
  const anchor = UI.chooseAnchor({state,groupId:'second',messages:state.messages,visible});
  assert.equal(anchor.offset,0,'durable progress keeps the non-negative offset contract');
  assert.equal(anchor.visualOffset,-12,'rendering retains the space between viewport top and the first readable card');
});

test('clearing a search restores its original reading point rather than the first result', () => {
  assert.equal(typeof UI.chooseAnchor, 'function');
  const state = fixture();
  const remembered={accountId:'account-A',groupId:'second',messageId:'same-id',offset:17};
  const anchor=UI.chooseAnchor({state,groupId:'second',messages:state.messages,visible:{accountId:'account-A',groupId:'second',messageId:'newest',offset:0},remembered,restore:true});
  assert.deepEqual(plain(anchor),remembered);
});

test('same message IDs from another group or account cannot replace the saved anchor', () => {
  assert.equal(typeof UI.chooseAnchor, 'function');
  const state=fixture();
  for (const foreign of [
    {accountId:'account-A',groupId:'first',messageId:'same-id',offset:99},
    {accountId:'account-B',groupId:'second',messageId:'same-id',offset:99}
  ]) {
    const anchor=UI.chooseAnchor({state,groupId:'second',messages:state.messages,visible:foreign});
    assert.equal(anchor.messageId,'same-id'); assert.equal(anchor.offset,8); assert.equal(anchor.accountId,'account-A'); assert.equal(anchor.groupId,'second');
  }
});

test('a missing saved message does not silently resolve to newest or another group', () => {
  assert.equal(typeof UI.chooseAnchor, 'function');
  const state=fixture();
  assert.equal(UI.chooseAnchor({state,groupId:'second',messages:[{id:'newest',groupId:'second'}],restore:true}),null);
});

test('automatic and filtered scrolling cannot advance reading progress', () => {
  assert.equal(typeof UI.shouldTrackProgress, 'function');
  const real={mode:'reader',view:'chats',filtered:false,programmatic:false,userInitiated:true};
  assert.equal(UI.shouldTrackProgress(real),true);
  for (const change of [{filtered:true},{programmatic:true},{userInitiated:false},{view:'bookmarks'},{mode:'official'}]) {
    assert.equal(UI.shouldTrackProgress({...real,...change}),false);
  }
});

test('only native media preview URLs become image sources', () => {
  assert.equal(typeof UI.safePreviewURL,'function');
  assert.equal(UI.safePreviewURL({url:'weiyue-media://cache/account-A/photo-1'}),'weiyue-media://cache/account-A/photo-1');
  for(const url of ['https://example.com/private.jpg','file:///etc/passwd','data:image/svg+xml,x','javascript:alert(1)','weiyue-media:broken']) {
    assert.equal(UI.safePreviewURL({url}),null);
  }
});

test('attachment presentation derives safe labels without consuming arbitrary URLs', () => {
  assert.equal(typeof UI.attachmentPresentation,'function');
  assert.deepEqual(plain(UI.attachmentPresentation({type:'image',name:'讨论配图',url:'https://untrusted.invalid/x'})),{kind:'image',name:'讨论配图',detail:'图片'});
  assert.deepEqual(plain(UI.attachmentPresentation({type:'document',name:'研报.pdf',size:2048})),{kind:'document',name:'研报.pdf',detail:'PDF · 2.0 KB'});
  assert.deepEqual(plain(UI.attachmentPresentation({type:'video',name:''})),{kind:'video',name:'视频',detail:'在独立窗口打开'});
});

test('settings probes never forward API keys or chat materials', () => {
  assert.equal(typeof UI.settingsProbePayload,'function');
  const input={accountId:'account-A',baseURL:'https://api.example.test/v1',model:'model-id',key:'secret',messages:[{content:'private group chat'}],contextSnapshots:[{text:'private'}]};
  assert.deepEqual(plain(UI.settingsProbePayload('listModels',input)),{accountId:'account-A',baseURL:'https://api.example.test/v1'});
  assert.deepEqual(plain(UI.settingsProbePayload('testAI',input)),{accountId:'account-A',baseURL:'https://api.example.test/v1',model:'model-id'});
});

test('attachment actions identify the saved attachment by its native index without forwarding URLs', () => {
  assert.equal(typeof UI.attachmentReference,'function');
  const message={id:'900000000000000003',groupId:'group-a',text:'private',attachments:[{url:'https://untrusted.invalid/a'}]};
  assert.deepEqual(plain(UI.attachmentReference(message,2)),{groupId:'group-a',messageId:'900000000000000003',attachmentIndex:2});
});

test('opening reader from hidden official DOM never overwrites the saved anchor with stale scroll zero', () => {
  assert.equal(typeof UI.captureRenderAnchor,'function');
  const state=fixture(), memory=new Map(); let captures=0;
  const staleVisible={accountId:'account-A',groupId:'second',messageId:'newest',offset:0};
  const rememberStaleDOM=()=>{captures++;memory.set('second',staleVisible);return staleVisible;};
  const visible=UI.captureRenderAnchor({restore:true},rememberStaleDOM);
  const restored=UI.chooseAnchor({state,groupId:'second',messages:state.messages,visible,remembered:memory.get('second'),restore:true});
  assert.equal(captures,0,'just revealing the old DOM must not capture a new viewport anchor');
  assert.equal(memory.size,0); assert.equal(restored.messageId,'same-id'); assert.equal(restored.offset,8);
  const actualRead={accountId:'account-A',groupId:'second',messageId:'newest',offset:21};
  UI.captureRenderAnchor({},()=>{memory.set('second',actualRead);return actualRead;});
  const returning=UI.chooseAnchor({state,groupId:'second',messages:state.messages,remembered:memory.get('second'),restore:true});
  assert.equal(returning.messageId,'newest'); assert.equal(returning.offset,21,'real prior reading stays available when returning from search or another group');
});

test('routine save barrier does not cancel extraction or AI work', async () => {
  assert.equal(typeof UI.flushWithLifecycle, 'function');
  const events=[];
  const result=await UI.flushWithLifecycle({}, async()=>events.push('cancel'), async()=>{events.push('save');return true;});
  assert.equal(result,true); assert.deepEqual(events,['save']);
});
test('real quit invalidates work and awaits cancellation before saving state', async () => {
  assert.equal(typeof UI.flushWithLifecycle, 'function');
  const events=[]; let release;
  const cancellation=new Promise(resolve=>{release=resolve;});
  const pending=UI.flushWithLifecycle({quitting:true}, async()=>{events.push('invalidate');await cancellation;events.push('cancelled');}, async()=>{events.push('save');return true;});
  assert.deepEqual(events,['invalidate']); release(); await pending;
  assert.deepEqual(events,['invalidate','cancelled','save']);
});
test('quit stores pending AI question as retryable without changing completed or other-account discussion', () => {
  assert.equal(typeof UI.interruptPendingAI, 'function');
  const state=fixture(); state.discussions=[{id:'d',accountId:state.accountId,messages:[{role:'assistant',content:'Earlier reply'},{role:'user',content:'Translate this image',status:'pending'}]}, {id:'other',accountId:'other-account',messages:[{role:'user',content:'Other question',status:'pending'}]}];
  const revision=state.revision, other=JSON.stringify(state.discussions[1]);
  assert.equal(UI.interruptPendingAI(state,'d'),'Translate this image');
  assert.equal(state.discussions[0].messages[1].status,'failed'); assert.match(state.discussions[0].messages[1].error,/关闭.*取消/);
  assert.equal(state.revision,revision+1); assert.equal(state.discussions[0].messages[0].content,'Earlier reply'); assert.equal(JSON.stringify(state.discussions[1]),other);
  assert.equal(UI.interruptPendingAI(state,'d'),''); assert.equal(state.revision,revision+1);
  assert.equal(UI.interruptPendingAI(state,'other'),'');
});

test('cancel while the question is saving invalidates sendAI before any API call', async () => {
  const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
  const sendFunction=source.slice(source.indexOf('  async function sendAI(event)'),source.indexOf('  function openSettings(',source.indexOf('  async function sendAI(event)')));
  const cancelListener=source.slice(source.indexOf("  async function stopCurrentAI()"),source.indexOf("  $('clear-context').addEventListener",source.indexOf("  async function stopCurrentAI()")));
  const state=fixture(); state.settings.baseURL='https://api.example.test/v1';state.settings.model='test-model';
  const rpcCalls=[],listeners={},question={value:'Translate this selected text',disabled:false,focus(){}};
  let releaseSave; const saving=new Promise(resolve=>{releaseSave=resolve;});
  const environment={ReaderViewPolicy:UI,W:require('../Resources/ui/web-search.js'),A:require('../Resources/ui/preferences.js'),state,console,question,rpcCalls,listeners,saving,context:[state.messages[0]],C:{requestMessages:()=>[]}};
  const run=vm.createContext(environment);
  vm.runInContext(`
    let settingsBusy=false,inlineTranslation=null,busyAI=false,preparingContext=false,cancellingAI=false,quitting=false,cleanupBusy=false,preferencesSaving=false,discussionHistoryBusy=false,rangeOperation=null,demo=false,native=true,hasAPIKey=true,accountEpoch=1,aiToken=0,currentDiscussionId=null,contextCollectionId=null,preparationToken=0;
    const $=id=>id==='ai-question'?question:{addEventListener:(event,handler)=>listeners[event]=handler};
    const currentDiscussion=()=>state.discussions.find(d=>d.id===currentDiscussionId);
    const clone=value=>JSON.parse(JSON.stringify(value)); const mutate=callback=>{callback();state.revision++;};
    const shortText=(text,n)=>text.slice(0,n),fullDate=value=>value,groupName=value=>value;
    const renderAIControls=()=>{},renderContext=()=>{},renderConversation=()=>{},renderCollections=()=>{},aiState=()=>{},openSettings=()=>{},errorText=error=>error.message;
    const modelCapabilitiesLoading=()=>false,inlineBusy=()=>false;
    const aiConfiguration=()=>({baseURL:state.settings.baseURL,model:state.settings.model}),startAILive=()=>{},finishAILive=()=>{},preservePartialAI=()=>{};
    const persist=()=>saving,persistQuietly=()=>saving;
    const rpc=async(action)=>{rpcCalls.push(action);return {cancelled:true};};
  `+sendFunction+cancelListener,run);
  const sending=vm.runInContext('sendAI({preventDefault(){}})',run);
  assert.equal(state.discussions[0].messages[0].status,'pending');
  const cancelling=listeners.click(); releaseSave(); await Promise.all([sending,cancelling]);
  assert.deepEqual(rpcCalls,['cancelAI']);
  assert.equal(state.discussions[0].messages[0].status,'failed');
  assert.equal(question.value,'Translate this selected text');
});

test('image extraction completing after real quit cannot start translation', async () => {
  const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
  const section=(start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
  const functions=[section('  function quiesceForQuit()', '  window.resumeAfterCancelledQuit'),section('  function contextBusy()', '  function mergeContext('),section('  function startPreparation(', '  async function addContext('),section('  async function readAttachment(', '  async function startFocusedDiscussion(')].join('\n');
  const state=fixture(),rpcCalls=[],translations=[];
  Object.assign(state.settings,{baseURL:'https://synthetic.invalid/v1',model:'synthetic-model'});
  const message={...state.messages[0],attachments:[{type:'image',name:'Selected image',url:'https://example.test/image.png'}]};
  let releaseExtraction;const extraction=new Promise(resolve=>{releaseExtraction=resolve;});
  const run=vm.createContext({ReaderViewPolicy:UI,C:require('../Resources/ui/ai-context.js'),window:{ReaderAttachmentActions:require('../Resources/ui/attachment-actions.js')},state,message,rpcCalls,translations,extraction});
  vm.runInContext(`
    const discussionTitles={pause:()=>rpcCalls.push('pauseTitles')};let settingsBusy=false,inlineTranslation=null,busyAI=false,preparingContext=false,cancellingAI=false,quitting=false,quitPreparation=null,preferencesSaving=false,discussionHistoryBusy=false,cleanupBusy=false,demo=false,native=true,hasAPIKey=true,accountEpoch=1,aiToken=0,currentDiscussionId=null,preparationToken=0;
    const modelCapabilitiesLoading=()=>false,inlineBusy=()=>false;
    const aiConfiguration=()=>({}),currentDiscussion=()=>null,finishAILive=()=>{},preservePartialAI=()=>{},cancelRangeSummary=async()=>{};
    const $=()=>({value:''}); const renderAIControls=()=>{},renderContext=()=>{},renderConversation=()=>{},revealInspector=()=>{},aiState=()=>{},notify=()=>{},errorText=error=>error.message;
    const rpc=async(action)=>{rpcCalls.push(action);return action==='extractAttachment'?extraction:{};};
    const startFocusedDiscussion=async(...args)=>translations.push(args); const mergeContext=()=>{};
  `+functions,run);
  const reading=vm.runInContext('readAttachment(message,0,true)',run);
  assert.deepEqual(rpcCalls,['extractAttachment']);
  await vm.runInContext('quiesceForQuit()',run);
  releaseExtraction({text:'This must not be submitted',kind:'image',name:'Selected image',warnings:[]});
  await reading;
  assert.deepEqual(rpcCalls,['extractAttachment','pauseTitles','cancelContent','cancelAI']); assert.equal(translations.length,0);
});
