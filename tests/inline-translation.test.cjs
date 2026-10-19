'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const modulePath = require.resolve('../Resources/ui/model.js').replace('model.js', 'inline-translation.js');
const T = fs.existsSync(modulePath) ? require(modulePath) : {};

test('inline translation exposes an independent controller', () => {
  assert.equal(typeof T.create, 'function');
});

function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function fixture(options = {}) {
  const message = {accountId:'account-a',groupId:'group',id:'message',text:'Translate only this. <script>ignored()</script>',senderId:'person'};
  let state = {accountId:'account-a',revision:7,messages:[message],settings:{baseURL:'https://model.example/v1',model:'chosen-model',activeDiscussionId:'discussion',aiDraftInstructions:'Unrelated draft'},discussions:[{id:'discussion',messages:[{role:'user',content:'Do not touch this discussion'}]}]};
  let configuration = {accountId:state.accountId,baseURL:state.settings.baseURL,model:state.settings.model,thinking:'disabled',readMode:'auto',allowImages:true,allowPDF:true,webSearchEnabled:true};
  const calls = [], requests = [], saves = [], changes = [];
  const controller = T.create({
    getState:()=>state,getConfiguration:()=>configuration,
    rpc:(action,payload)=>{ calls.push({action,payload}); if(action==='ai'){const request=deferred();requests.push(request);return request.promise;}return options.cancelPromise || Promise.resolve({}); },
    persist:async target=>{saves.push(JSON.parse(JSON.stringify(target)));if(options.saveError)throw new Error(options.saveError);},
    onChange:message=>changes.push(message),assertCanStart:options.assertCanStart
  });
  return {controller,message,calls,requests,saves,changes,get state(){return state;},set state(value){state=value;},get configuration(){return configuration;},set configuration(value){configuration=value;}};
}
function progress(f,values={}) { return {type:'aiProgress',requestId:f.calls.find(call=>call.action==='ai').payload.requestId,accountId:f.message.accountId,...values}; }

test('request uses the current selected model and only the original text as translation data', async () => {
  const f=fixture(), original=JSON.stringify(f.state.discussions), preferences=JSON.stringify(f.state.settings);
  f.configuration={...f.configuration,model:'new-selected-model',thinking:'enabled'};
  const pending=f.controller.translate(f.message);
  assert.equal(f.controller.isBusy(),true);
  const payload=f.calls[0].payload;
  assert.equal(payload.model,'new-selected-model');assert.equal(payload.thinking,'enabled');assert.equal(payload.accountId,'account-a');
  assert.equal(payload.baseURL,'https://model.example/v1');assert.deepEqual(payload.sources,[]);assert.equal(payload.webSearchEnabled,false);
  assert.equal(payload.messages.length,2);assert.equal(payload.messages[0].role,'system');assert.match(payload.messages[0].content,/原文.*指令|指令.*原文/);
  assert.deepEqual(payload.messages[1],{role:'user',content:f.message.text});
  assert.equal(JSON.stringify(f.state.settings),preferences);assert.equal(JSON.stringify(f.state.discussions),original);
  f.requests[0].resolve({text:'只翻译这一条。'});await pending;
  assert.equal(f.controller.isBusy(),false);assert.equal(f.controller.get(f.message).status,'complete');
  assert.equal(f.controller.get(f.message).model,'new-selected-model');assert.equal(f.saves.length,1);assert.equal(f.state.revision,8);
  assert.equal(JSON.stringify(f.state.discussions),original);assert.equal(f.state.settings.activeDiscussionId,'discussion');assert.equal(f.state.settings.aiDraftInstructions,'Unrelated draft');
});

test('progress is matched by request and account and stays attached to its source message', async () => {
  const f=fixture(), pending=f.controller.translate(f.message);
  assert.equal(f.controller.consumeProgress(progress(f,{requestId:'other',contentDelta:'wrong'})),false);
  assert.equal(f.controller.consumeProgress(progress(f,{accountId:'other',contentDelta:'wrong'})),false);
  assert.equal(f.controller.consumeProgress(progress(f,{phase:'thinking',reasoningDelta:'private thought'})),true);
  f.controller.consumeProgress(progress(f,{phase:'answering',contentDelta:'第一部分'}));f.controller.consumeProgress(progress(f,{contentDelta:'，第二部分'}));
  assert.equal(f.controller.get(f.message).text,'第一部分，第二部分');assert.equal(f.controller.get(f.message).status,'loading');
  assert.equal(f.state.settings.inlineTranslations,undefined);
  f.requests[0].resolve({text:'完整译文'});await pending;
  assert.equal(f.controller.consumeProgress(progress(f,{contentDelta:'late'})),false);assert.equal(f.controller.get(f.message).text,'完整译文');
});

test('cancel retains partial text as unfinished and holds the lock until native cancellation returns', async () => {
  const cancelled=deferred(),f=fixture({cancelPromise:cancelled.promise}),pending=f.controller.translate(f.message);
  f.controller.consumeProgress(progress(f,{contentDelta:'未完成部分'}));
  const stop=f.controller.cancel();assert.equal(f.controller.isBusy(),true);assert.equal(f.controller.get(f.message).status,'cancelled');
  assert.equal(f.calls[1].action,'cancelAI');
  f.requests[0].resolve({text:'late success'});await pending;
  assert.equal(f.controller.isBusy(),true);assert.equal(f.controller.get(f.message).text,'未完成部分');assert.equal(f.saves.length,0);
  cancelled.resolve({});await stop;assert.equal(f.controller.isBusy(),false);
  const retry=f.controller.translate(f.message,{force:true});assert.equal(f.controller.get(f.message).text,'');
  f.requests[1].resolve({text:'重试完成'});await retry;assert.equal(f.controller.get(f.message).status,'complete');
});

test('failure and empty output remain visible errors and never create a successful saved record', async () => {
  const f=fixture();let pending=f.controller.translate(f.message);
  f.controller.consumeProgress(progress(f,{contentDelta:'部分译文'}));f.requests[0].reject(new Error('服务暂不可用'));await pending;
  assert.equal(f.controller.get(f.message).status,'error');assert.equal(f.controller.get(f.message).text,'部分译文');assert.match(f.controller.get(f.message).error,/服务暂不可用/);assert.equal(f.saves.length,0);
  pending=f.controller.translate(f.message,{force:true});f.requests[1].resolve({text:'  '});await pending;
  assert.equal(f.controller.get(f.message).status,'error');assert.equal(f.saves.length,0);
});

test('truncated provider output is explicitly unfinished instead of being saved as complete', async () => {
  const f=fixture(),pending=f.controller.translate(f.message);
  f.controller.consumeProgress(progress(f,{contentDelta:'只有一半',warning:'模型输出达到长度上限，回答可能被截断。',finishReason:'length'}));
  f.requests[0].resolve({text:'只有一半'});await pending;
  assert.equal(f.controller.get(f.message).status,'error');assert.match(f.controller.get(f.message).error,/未完成|截断|长度/);assert.equal(f.saves.length,0);
});

test('changed source text cannot display an old translation or accept an old pending result', async () => {
  const f=fixture(),pending=f.controller.translate(f.message);
  const changed={...f.message,text:'Changed source'};f.state.messages=[changed];
  assert.equal(f.controller.get(changed),null);assert.equal(f.controller.consumeProgress(progress(f,{contentDelta:'stale'})),true);
  f.requests[0].resolve({text:'stale completion'});await pending;
  assert.equal(f.controller.get(changed),null);assert.equal(f.saves.length,0);assert.equal(f.controller.isBusy(),false);
});

test('reset and a new account reject late progress, completion and saving even with matching message IDs', async () => {
  const f=fixture(),old=f.state,pending=f.controller.translate(f.message);
  f.state={...f.state,accountId:'account-b',settings:{baseURL:'',model:''},messages:[{...f.message,accountId:'account-b'}]};
  f.controller.reset();
  assert.equal(f.controller.consumeProgress(progress(f,{contentDelta:'old account'})),false);
  f.requests[0].resolve({text:'old account'});await pending;
  assert.equal(f.controller.get(f.state.messages[0]),null);assert.equal(f.saves.length,0);assert.equal(old.settings.inlineTranslations,undefined);
});

test('replacing the state object for the same account invalidates pending results', async () => {
  const f=fixture(),pending=f.controller.translate(f.message);f.state=JSON.parse(JSON.stringify(f.state));
  f.requests[0].resolve({text:'stale object'});await pending;
  assert.equal(f.saves.length,0);assert.equal(f.controller.get(f.message),null);
});

test('saved results survive restart, retain their source model and invalidate when original text changes', async () => {
  const f=fixture(),pending=f.controller.translate(f.message);f.requests[0].resolve({text:'持久译文'});await pending;
  f.configuration={...f.configuration,model:'a-new-model'};f.controller.reset();
  assert.equal(f.controller.get(f.message).text,'持久译文');assert.equal(f.controller.get(f.message).model,'chosen-model');
  const before=f.calls.length;await f.controller.translate(f.message);assert.equal(f.calls.length,before);
  const changed={...f.message,text:'Changed original'};f.state.messages=[changed];assert.equal(f.controller.get(changed),null);
  const pendingAgain=f.controller.translate(changed);f.requests[1].resolve({text:'新的译文'});await pendingAgain;
  assert.equal(f.state.settings.inlineTranslations.items.length,1);assert.equal(f.state.settings.inlineTranslations.items[0].sourceText,'Changed original');
});

test('save failure keeps the received translation but clearly reports that it is not saved', async () => {
  const f=fixture({saveError:'磁盘只读'}),pending=f.controller.translate(f.message);f.requests[0].resolve({text:'收到的完整译文'});await pending;
  assert.equal(f.controller.get(f.message).status,'complete');assert.match(f.controller.get(f.message).saveError,/磁盘只读/);assert.equal(f.controller.get(f.message).text,'收到的完整译文');
});

test('local and shared AI locks prevent overlapping requests without changing the running translation', async () => {
  const f=fixture(),pending=f.controller.translate(f.message);
  await assert.rejects(f.controller.translate(f.message,{force:true}),/进行|等待|翻译/);assert.equal(f.requests.length,1);
  f.requests[0].resolve({text:'完成'});await pending;
  const locked=fixture({assertCanStart:()=>{throw new Error('讨论正在回答');}});
  await assert.rejects(locked.controller.translate(locked.message),/讨论正在回答/);assert.equal(locked.calls.length,0);
});

test('stored translation history is bounded and malformed or foreign records are ignored', async () => {
  const f=fixture();
  f.state.settings.inlineTranslations={version:1,items:[{accountId:'other',groupId:'group',messageId:'message',sourceText:f.message.text,text:'foreign',model:'m',baseURL:'b',createdAt:new Date().toISOString()},{accountId:'account-a',text:'broken'}]};
  assert.equal(f.controller.get(f.message),null);
  for(let i=0;i<105;i++){
    const message={...f.message,id:'m'+i,text:'source '+i};f.state.messages.push(message);
    const pending=f.controller.translate(message);f.requests[i].resolve({text:'translation '+i});await pending;
  }
  assert.equal(f.state.settings.inlineTranslations.items.length,100);
  assert.equal(f.state.settings.inlineTranslations.items[0].messageId,'m104');
  assert.ok(f.state.settings.inlineTranslations.items.every(record=>record.accountId==='account-a'));
  assert.equal(f.controller.get(f.state.messages.find(message=>message.id==='m0')),null);
});

function documentFixture() {
  const doc={createElement:tag=>new Element(tag)};
  class Element {
    constructor(tag){this.tagName=tag;this.ownerDocument=doc;this.children=[];this.attributes={};this.listeners={};this.textContent='';this.hidden=false;this.disabled=false;this.className='';}
    append(...children){this.children.push(...children);}
    replaceChildren(...children){this.children=children;}
    setAttribute(name,value){this.attributes[name]=value;}
    addEventListener(type,listener){this.listeners[type]=listener;}
    click(){if(!this.disabled&&this.listeners.click)this.listeners.click();}
    set innerHTML(value){throw new Error('Translation must never be parsed as HTML: '+value);}
    querySelector(selector){for(const child of this.children){if(child.className.split(' ').includes(selector.slice(1)))return child;const result=child.querySelector(selector);if(result)return result;}return null;}
  }
  return doc.createElement('div');
}

test('message-local rendering uses literal text, preserves controls while streaming and supports folding and retry', async () => {
  const f=fixture(),host=documentFixture();
  f.controller.mount(host,f.message);assert.equal(host.hidden,true);
  const pending=f.controller.translate(f.message);f.controller.mount(host,f.message);
  assert.equal(host.hidden,false);const toggle=host.querySelector('.inline-translation-toggle');
  assert.equal(host.querySelector('.inline-translation-cancel').hidden,false);
  f.controller.consumeProgress(progress(f,{contentDelta:'<img src=x onerror=bad()>原样文字'}));f.controller.mount(host,f.message);
  assert.equal(host.querySelector('.inline-translation-toggle'),toggle);assert.equal(host.querySelector('.inline-translation-text').textContent,'<img src=x onerror=bad()>原样文字');
  toggle.click();assert.equal(host.querySelector('.inline-translation-body').hidden,true);assert.equal(toggle.attributes['aria-expanded'],'false');
  f.requests[0].resolve({text:'完整译文'});await pending;f.controller.mount(host,f.message);
  assert.equal(host.querySelector('.inline-translation-body').hidden,true);assert.equal(host.querySelector('.inline-translation-model').textContent,'chosen-model');
  f.configuration={...f.configuration,model:'selected-for-retry'};host.querySelector('.inline-translation-retry').click();
  assert.equal(f.calls[1].payload.model,'selected-for-retry');f.requests[1].resolve({text:'新的译文'});await new Promise(resolve=>setImmediate(resolve));
  f.controller.mount(host,f.message);assert.equal(host.querySelector('.inline-translation-text').textContent,'新的译文');
  assert.equal(host.querySelector('.inline-translation-body').hidden,false);assert.equal(host.querySelector('.inline-translation').attributes['data-status'],'complete');
});

test('source removal discards a pending display rather than leaving an eternal loading row if restored', async () => {
  const f=fixture(),pending=f.controller.translate(f.message);f.state.messages=[];f.requests[0].resolve({text:'removed'});await pending;
  f.state.messages=[f.message];assert.equal(f.controller.get(f.message),null);
});

test('combined saved text has a bounded size and excessively long output is never saved as complete', async () => {
  const f=fixture();
  for(let i=0;i<6;i++){const message={...f.message,id:'long'+i,text:'source '+i};f.state.messages.push(message);const pending=f.controller.translate(message);f.requests[i].resolve({text:'译'.repeat(220000)});await pending;}
  assert.ok(f.state.settings.inlineTranslations.items.reduce((sum,item)=>sum+item.sourceText.length+item.text.length,0)<=T.MAX_STORED_CHARS);
  const pending=f.controller.translate(f.message);f.requests[6].resolve({text:'译'.repeat(240001)});await pending;
  assert.equal(f.controller.get(f.message).status,'error');assert.equal(f.state.settings.inlineTranslations.items.some(record=>record.messageId===f.message.id),false);
});

test('a failed cancellation keeps the AI lock and exposes a way to retry stopping the pending request', async () => {
  const failed=deferred(),options={cancelPromise:failed.promise},f=fixture(options),host=documentFixture();
  const pending=f.controller.translate(f.message),stopping=f.controller.cancel();
  failed.reject(new Error('取消请求暂未响应'));await assert.rejects(stopping,/暂未响应/);
  assert.equal(f.controller.isBusy(),true);f.controller.mount(host,f.message);
  const stop=host.querySelector('.inline-translation-cancel');assert.equal(stop.hidden,false);assert.equal(stop.disabled,false);assert.equal(stop.textContent,'重试取消');
  assert.equal(host.querySelector('.inline-translation-retry').disabled,true);
  options.cancelPromise=Promise.resolve({});stop.click();await new Promise(resolve=>setImmediate(resolve));
  assert.equal(f.controller.isBusy(),false);assert.equal(f.calls.filter(call=>call.action==='cancelAI').length,2);
  f.requests[0].resolve({text:'不得显示的迟到结果'});await pending;assert.equal(f.saves.length,0);
});
