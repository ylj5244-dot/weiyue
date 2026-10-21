'use strict';
const test = require('node:test'), assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const UI = require('../Resources/ui/app.js'), Actions = require('../Resources/ui/message-actions.js');
test('stop stays available for every AI path and locks only during acknowledgement', () => {
  for (const field of ['busyAI','preparingContext','inlineBusy','rangeOperation']) {
    assert.deepEqual(UI.aiStopState({[field]:true}), {visible:true,disabled:false,label:'停止'});
  }
  assert.deepEqual(UI.aiStopState({cancellingAI:true}), {visible:true,disabled:true,label:'正在停止…'});
  assert.equal(UI.aiStopState({}).visible,false);
  assert.equal(UI.aiStopState({busyAI:true,quitting:true}).visible,false);
});
test('message copy preserves the original paragraphs, punctuation and whitespace', () => {
  const text='  原文第一行\n第二行\n\nEnglish text.  ';
  assert.equal(Actions.copyText({text,attachments:[]}),text);
});
test('non-text copy carries real attachment names and usable links without inventing content', () => {
  assert.equal(Actions.copyText({text:'',attachments:[{name:'报告.pdf',url:'https://example.invalid/report.pdf'},{name:'图.png'}]}),'报告.pdf\nhttps://example.invalid/report.pdf\n\n图.png');
  assert.equal(Actions.copyText({text:'',attachments:[]}), '');
});
test('new discussion clears all current sources and draft but preserves saved history', () => {
  const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
  const start=source.indexOf('  function newDiscussion()'),end=source.indexOf('\n  function ',start+5);
  assert.ok(start>=0,'actual new-discussion action must be testable');
  const saved={id:'old',contextSnapshots:[{text:'old material'}],messages:[{role:'user',content:'old question'}]};
  const sandbox={context:[{text:'old material'}],contextCollectionId:'old-collection',pendingRange:{snapshots:[1]},summarySourcePage:3,currentDiscussionId:'old',state:{discussions:[saved]}, question:{value:'old draft',focus(){}},contextBusy:()=>false,abandonCurrentDiscussion(clear){assert.equal(clear,true);sandbox.currentDiscussionId=null;sandbox.contextCollectionId=null;},renderConversation(){},renderContext(){},renderAIControls(){},refreshMountedCards(){},$:()=>sandbox.question};
  vm.createContext(sandbox);vm.runInContext(source.slice(start,end)+'\nnewDiscussion();',sandbox);
  assert.equal(sandbox.context.length,0);assert.equal(sandbox.pendingRange,null);assert.equal(sandbox.summarySourcePage,0);assert.equal(sandbox.question.value,'');
  assert.equal(sandbox.state.discussions[0],saved);assert.equal(saved.contextSnapshots[0].text,'old material');
});
test('a newer navigation wins over a deferred density/font anchor restoration', () => {
  const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
  const start=source.indexOf('  readingAppearance = window.ReaderReadingAppearance.mount('), end=source.indexOf("\n  inlineTranslation =",start);
  assert.ok(start>=0&&end>start,'use the actual appearance integration');
  const calls=[],frames=[];
  let integration;
  const sandbox={window:{ReaderReadingAppearance:{mount(options){integration=options;return {};}}},rpc(){},activeView:'chats',mode:'reader',renderReader(){},native:true,ready:true,demo:false,quitting:false,state:{accountId:'a'},activeGroupId:'g',readingNavigationEpoch:7,visibleMessage:()=>({accountId:'a',groupId:'g',messageId:'230',offset:0}),settleReading(){},scrollToMessage(id){calls.push(id);},requestAnimationFrame(fn){frames.push(fn);},scheduleLayout(){}};
  vm.createContext(sandbox);vm.runInContext(source.slice(start,end),sandbox);
  const anchor=integration.beforeApply();integration.afterApply(anchor);
  assert.deepEqual(calls,['230'],'layout restores immediately');
  sandbox.readingNavigationEpoch++;calls.push('210');
  frames.shift()();assert.deepEqual(calls,['230','210'],'a later jump must not be overwritten on the next frame');
  calls.length=0;const next=integration.beforeApply();integration.afterApply(next);frames.shift()();
  assert.deepEqual(calls,['230','230'],'ordinary reflow still settles its original anchor');
});

test('a later bookmark jump is not overwritten by a queued pane-resize restoration',()=>{
 const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
 const start=source.indexOf("  window.addEventListener('weiyue:layout-start'"),end=source.indexOf("  window.addEventListener('resize'",start);
 const listeners={},frames=[],calls=[];
 const box={resizingAnchor:null,readingNavigationEpoch:4,state:{accountId:'a'},activeGroupId:'g',userScrollUntil:0,suppressScrollUntil:0,Date,window:{addEventListener:(name,fn)=>listeners[name]=fn},visibleMessage:()=>({accountId:'a',groupId:'g',messageId:'before-resize',offset:0}),scrollToMessage:id=>calls.push(id),scheduleLayout(){},requestAnimationFrame:fn=>frames.push(fn)};
 vm.createContext(box);vm.runInContext(source.slice(start,end),box);
 listeners['weiyue:layout-start']();listeners['weiyue:layout-end']();
 box.readingNavigationEpoch++;calls.push('new-bookmark');frames.forEach(fn=>fn());
 assert.equal(calls.at(-1),'new-bookmark');
});
