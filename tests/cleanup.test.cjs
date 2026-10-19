const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('../Resources/ui/cleanup.js');

function message(id, groupId='g', attachments=[]) { return {accountId:'a',id,groupId,senderId:'u',senderName:'Demo',sentAt:'2026-10-18T00:00:00.000Z',text:'text '+id,attachments}; }
function fixture() {
  const messages = ['plain','bookmark','collection','discussion','anchor'].map(id => message(id));
  messages.push(message('image','g',[{type:'image',url:'https://wx1.sinaimg.cn/a.png',name:'a.png'}]));
  messages.push(message('doc','g',[{type:'document',url:'https://weibo.com/a.pdf',name:'a.pdf'}]));
  messages[5].extractedContents=[{attachmentIndex:0,text:'image text',kind:'image'}];
  messages[6].extractedContents=[{attachmentIndex:0,text:'doc text',kind:'document'}];
  messages.push(message('other','other'));
  return {version:1,accountId:'a',revision:2,groups:[{id:'g'},{id:'other'}],messages,
    bookmarks:[{groupId:'g',messageId:'bookmark',snapshot:messages[1]}],
    collections:[{messageIds:['g:collection'],messages:[messages[2]]}],
    discussions:[{contextSnapshots:[messages[3]]}],progress:{g:{auto:{messageId:'anchor'}}},settings:{}};
}
const options = categories => ({scope:'group',groupId:'g',categories});

test('text cleanup protects bookmarks, collections, discussions and every reading anchor', () => {
  const state=fixture(), preview=C.preview(state,options(['text']));
  assert.deepEqual(preview.messageKeys,['g:plain']);
  assert.deepEqual(preview.textKeys,['g:plain','g:image','g:doc']);
  assert.equal(preview.protectedCount,4); assert.equal(preview.counts.text,3);
  const result=C.apply(state,options(['text']),'2026-10-18T01:00:00.000Z');
  assert.equal(state.messages.length,8); assert.equal(result.state.messages.length,7);
  assert.equal(result.state.messages.find(x=>x.id==='image').text,'');
  assert.equal(result.state.messages.find(x=>x.id==='image').attachments.length,1);
  assert.equal(result.state.messages.find(x=>x.id==='doc').text,'');
  assert.equal(result.state.revision,3); assert.deepEqual(result.state.progress,state.progress);
  assert.deepEqual(result.state.cleanup.suppressedMessageKeys,preview.messageKeys);
  assert.deepEqual(C.filterIncoming(result.state,[message('plain'),message('new'),message('plain','other')]).map(x=>x.groupId+':'+x.id),['g:new','other:plain']);
  assert.equal(C.filterIncoming(result.state,[message('image')])[0].text,'');
});

test('image and document cleanup are separate and preserve source metadata', () => {
  const state=fixture(), result=C.apply(state,options(['image']),'2026-10-18T01:00:00.000Z');
  assert.equal(result.state.messages.length,8);
  assert.equal(result.summary.assetRefs.length,1); assert.equal(result.summary.assetRefs[0].kind,'image');
  const image=result.state.messages.find(x=>x.id==='image'), doc=result.state.messages.find(x=>x.id==='doc');
  assert.deepEqual(image.extractedContents,[]); assert.equal(doc.extractedContents.length,1);
  assert.equal(image.attachments[0].url,'https://wx1.sinaimg.cn/a.png');
  assert.equal(C.isMediaSuppressed(result.state,image.attachments[0]),true);
  assert.equal(C.isMediaSuppressed(result.state,doc.attachments[0]),false);
  assert.equal(result.state.cleanup.suppressedMessageKeys.length,0);
});

test('shared assets are protected across bookmarks and outside selected group', () => {
  const state=fixture();
  state.messages.find(x=>x.id==='bookmark').attachments=[{type:'image',url:'http://wx1.sinaimg.cn/a.png#other',name:'renamed.png'}];
  assert.equal(C.preview(state,options(['image'])).assetRefs.length,0);
  state.messages.find(x=>x.id==='bookmark').attachments=[];
  state.messages.find(x=>x.id==='other').attachments=[{type:'image',url:'https://wx1.sinaimg.cn/a.png'}];
  assert.equal(C.preview(state,options(['image'])).assetRefs.length,0);
  assert.equal(C.preview(state,{scope:'all',categories:['image']}).assetRefs.length,1);
});

test('local imported file is protected by saved snapshot even without live message', () => {
  const state=fixture(), local=message('import-1','local-files',[{type:'document',name:'local.pdf'}]);
  local.localPath='/safe/local.pdf';state.messages.push(local);state.collections.push({messageIds:['local-files:import-1'],messages:[local]});
  assert.equal(C.preview(state,{scope:'all',categories:['document']}).assetRefs.length,1);
  assert.equal(C.preview(state,{scope:'all',categories:['document']}).assetRefs.some(x=>x.localPath),false);
});

test('undo restores removed records and extraction without losing newer messages or bookmarks', () => {
  const before=fixture(), cleaned=C.apply(before,options(['text','image']),'2026-10-18T01:00:00.000Z').state;
  cleaned.messages.push(message('new')); cleaned.bookmarks.push({groupId:'g',messageId:'new',snapshot:message('new')});
  const restored=C.undo(cleaned,before);
  assert.equal(restored.messages.length,9); assert.equal(restored.bookmarks.length,2);
  assert.equal(restored.messages.find(x=>x.id==='image').extractedContents.length,1);
  assert.equal(restored.messages.find(x=>x.id==='image').text,'text image');
  assert.equal(restored.cleanup.suppressedMessageKeys.length,0);
  assert.equal(restored.cleanup.suppressedAssetKeys.length,0);
  assert.equal(restored.revision,cleaned.revision+1);
});

test('explicit media restore unblocks only selected source and does not mutate input', () => {
  const state=C.apply(fixture(),options(['image','document'])).state;
  const restored=C.restoreMedia(state,{url:'https://wx1.sinaimg.cn/a.png'});
  assert.equal(C.isMediaSuppressed(restored,{url:'https://wx1.sinaimg.cn/a.png'}),false);
  assert.equal(C.isMediaSuppressed(restored,{url:'https://weibo.com/a.pdf'}),true);
  assert.equal(C.isMediaSuppressed(state,{url:'https://wx1.sinaimg.cn/a.png'}),true);
});

test('malformed cleanup choices and cross-account snapshots are rejected', () => {
  for (const bad of [{scope:'group',categories:['text']},{scope:'other',categories:['text']},{scope:'all',categories:[]},{scope:'all',categories:['all']}]) assert.throws(()=>C.preview(fixture(),bad));
  const foreign=fixture(); foreign.accountId='b'; assert.throws(()=>C.undo(fixture(),foreign));
});

test('cleaned media cannot be resurrected by merging newly synced OCR fields', () => {
  const before=fixture(), clean=C.apply(before,options(['image'])).state;
  const incoming=C.filterIncoming(clean,before.messages);
  const img=incoming.find(x=>x.id==='image'); assert.deepEqual(img.extractedContents,[]);
  assert.equal(before.messages.find(x=>x.id==='image').extractedContents.length,1);
});

test('independent cleanups retain files after clearing text and round-trip state extension', () => {
  const M=require('../Resources/ui/model.js'), before=fixture();
  // Normalize via the actual state model after adding its required fixture fields.
  before.groups.forEach(group=>Object.assign(group,{accountId:'a',name:group.id,selected:true}));
  before.bookmarks=[];before.collections=[];before.discussions=[];before.progress={};before.settings={baseURL:'',model:''};
  const textOnly=C.apply(before,{scope:'all',categories:['text']}).state;
  assert.deepEqual(textOnly.messages.map(x=>x.id).sort(),['doc','image']);
  assert.equal(C.preview(textOnly,{scope:'all',categories:['image']}).assetRefs.length,1);
  assert.equal(C.preview(textOnly,{scope:'all',categories:['document']}).assetRefs.length,1);
  const roundTrip=M.normalizeState(JSON.parse(JSON.stringify(textOnly)));
  assert.deepEqual(roundTrip.cleanup,textOnly.cleanup);
  assert.equal(C.filterIncoming(roundTrip,before.messages).find(x=>x.id==='image').text,'');
});
