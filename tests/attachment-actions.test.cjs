const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const C = require('../Resources/ui/ai-context.js');
const UI = require('../Resources/ui/app.js');
const modulePath = require('node:path').join(__dirname, '../Resources/ui/attachment-actions.js');
const Actions = fs.existsSync(modulePath) ? require(modulePath) : null;

function harness(options = {}) {
  const source = fs.readFileSync(require.resolve('../Resources/ui/app.js'), 'utf8');
  const section = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));
  let release, reject;
  const extraction = new Promise((yes, no) => { release = yes; reject = no; });
  const message = { accountId:'a', groupId:'g', id:'m', senderId:'s', senderName:'Member', sentAt:'2026-10-19T00:00:00Z', text:'UNSELECTED_MESSAGE_TEXT', attachments:[
    {type:'image',name:'Selected image.png',url:'https://example.test/image.png'},
    {type:'document',name:'Selected report.pdf',url:'https://example.test/report.pdf'}
  ] };
  const calls = [], focused = [], joined = [], notices = [], status = {textContent:'',dataset:{}};
  const state = {accountId:'a',settings:{baseURL:'https://example.test/v1',model:'selected-model'}};
  const run = vm.createContext({ C, ReaderViewPolicy:UI, window:{ReaderAttachmentActions:Actions}, state, message, calls, focused, joined, notices, extraction, status });
  vm.runInContext(`
    let settingsBusy=false,busyAI=false,preparingContext=false,cancellingAI=false,quitting=false,preferencesSaving=false,discussionHistoryBusy=false,cleanupBusy=false,demo=false,native=true,ready=true,loadFailed=false,hasAPIKey=true,accountEpoch=1,preparationToken=0;
    const clone=v=>JSON.parse(JSON.stringify(v)),modelCapabilitiesLoading=()=>false,inlineBusy=()=>false,aiConfiguration=()=>({model:'selected-model'});
    const renderAIControls=()=>{},renderContext=()=>{},revealInspector=()=>{},openSettings=()=>notices.push('open-settings'),aiState=()=>{},notify=s=>notices.push(s),errorText=e=>e.message;
    const rpc=async(action,payload)=>{calls.push({action,payload});return extraction;};
    const mergeContext=items=>joined.push(items);
    const startFocusedDiscussion=async(items,prompt)=>{if(preparingContext)throw Error('preparation must finish before AI starts');focused.push({items,prompt});return true;};
  ` + section('  function contextBusy()', '  function mergeContext(')
    + section('  function startPreparation(', '  async function addContext(')
    + section('  async function readAttachment(', '  async function startFocusedDiscussion('), run);
  for (const [key, value] of Object.entries(options)) vm.runInContext(`${key}=${JSON.stringify(value)}`, run);
  const start = (index, action) => vm.runInContext(`readAttachment(message,${index},${JSON.stringify(action)},status)`, run);
  return {run, calls, focused, joined, notices, status, state, message, release, reject, start};
}
function extracted(kind='image') { return {kind,name:kind==='image'?'Selected image.png':'Selected report.pdf',text:'SELECTED_ATTACHMENT_TEXT',method:'synthetic extraction',pageCount:2,processedPages:2,warnings:[]}; }

test('attachment tasks distinguish image/document interpretation, translation and add-only', () => {
  assert.ok(Actions, 'attachment action policy exists');
  assert.equal(Actions.normalize(false),'add'); assert.equal(Actions.normalize(true),'translate');
  assert.match(Actions.prompt('document','translate'),/文档/);
  assert.match(Actions.prompt('image','interpret'),/图片/);
  assert.equal(Actions.prompt('image','add'),'');
  assert.throws(()=>Actions.normalize('unknown'));
});

for (const [index, kind, action] of [[0,'image','interpret'],[0,'image','translate'],[1,'document','interpret'],[1,'document','translate']]) {
  test(`${kind} ${action} starts one task scoped to exactly the selected attachment`, async () => {
    const h=harness(); const pending=h.start(index,action); assert.equal(h.calls.length,1);
    assert.equal(h.calls[0].payload.attachmentIndex,index); assert.equal(h.calls[0].payload.model,'selected-model');
    h.release(extracted(kind)); await pending;
    assert.equal(h.focused.length,1); assert.equal(h.joined.length,0);
    const task=h.focused[0], snapshot=task.items[0];
    assert.deepEqual(Array.from(snapshot.contextAttachmentIndexes),[index]); assert.equal(snapshot.contextScope,'attachments');
    assert.equal(task.prompt,Actions.prompt(kind,action));
    const sent=C.contextText(task.items);
    assert.ok(sent.includes('SELECTED_ATTACHMENT_TEXT')); assert.ok(!sent.includes('UNSELECTED_MESSAGE_TEXT'));
    assert.ok(!sent.includes(index===0?'Selected report.pdf':'Selected image.png'));
  });
}

test('more-menu add-only prepares selected file without starting AI', async () => {
  const h=harness(); const pending=h.start(1,'add'); h.release(extracted('document')); await pending;
  assert.equal(h.focused.length,0); assert.equal(h.joined.length,1);
});
test('rapid clicks do not duplicate extraction or start two AI tasks', async () => {
  const h=harness(); const first=h.start(0,'interpret'); await h.start(1,'translate');
  assert.equal(h.calls.length,1); h.release(extracted()); await first; assert.equal(h.focused.length,1);
});
test('late extraction after account switch cannot start or join a discussion', async () => {
  const h=harness(); const pending=h.start(0,'translate'); h.state.accountId='b'; vm.runInContext('accountEpoch++',h.run);
  h.release(extracted()); await pending; assert.equal(h.focused.length,0); assert.equal(h.joined.length,0);
});
test('stale card from another account is rejected before extraction', async () => {
  const h=harness(); h.message.accountId='old-account'; const pending=h.start(0,'interpret'); h.release(extracted()); await pending;
  assert.equal(h.calls.length,0); assert.equal(h.focused.length,0);
});
test('failed extraction keeps the current discussion and allows a retry', async () => {
  const h=harness(); const pending=h.start(1,'interpret'); h.reject(Error('Synthetic unreadable file')); await pending;
  assert.equal(h.focused.length,0); assert.equal(h.joined.length,0); assert.match(h.status.textContent,/Synthetic unreadable file/);
  assert.equal(vm.runInContext('preparingContext',h.run),false);
});
test('cleanup locks automatic attachment tasks before they change discussion state', async () => {
  const h=harness({cleanupBusy:true}); const pending=h.start(0,'interpret'); h.release(extracted()); await pending; assert.equal(h.calls.length,0);
});
test('automatic task requires configured AI while add-only remains available', async () => {
  const h=harness({hasAPIKey:false}); const pending=h.start(0,'interpret'); h.release(extracted()); await pending; assert.equal(h.calls.length,0);
  const add=harness({hasAPIKey:false}); const added=add.start(0,'add'); add.release(extracted()); await added; assert.equal(add.joined.length,1);
});
