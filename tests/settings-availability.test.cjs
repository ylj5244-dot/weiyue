'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const P = require('../Resources/ui/preferences.js');
const appSource = fs.readFileSync(require.resolve('../Resources/ui/app.js'), 'utf8');
const uiSource = fs.readFileSync(require.resolve('../Resources/ui/preferences-ui.js'), 'utf8');

function actualFunction(name) {
  const match = new RegExp('^  (?:async )?function ' + name + '\\(', 'm').exec(appSource);
  assert.ok(match, 'The application must define ' + name);
  const rest = appSource.slice(match.index + 3), next = /\n  (?:async )?function /.exec(rest);
  assert.ok(next, 'Could not locate the boundary after ' + name);
  return appSource.slice(match.index, match.index + 3 + next.index);
}
function deferred() { let resolve, reject; const promise = new Promise((yes,no)=>{resolve=yes;reject=no;}); return {promise,resolve,reject}; }
function dom() {
  const nodes = new Map(), close = new Element('button');
  function Element(tag = 'div', id = '') {
    this.tagName=tag;this.id=id;this.disabled=false;this.hidden=false;this.open=false;this.children=[];this.listeners={};this.dataset={};this.attributes={};this.value='';this.textContent='';
    this.classList={toggle(){},add(){},remove(){}};
  }
  Element.prototype.addEventListener=function(type,fn){(this.listeners[type] || (this.listeners[type]=[])).push(fn);};
  Element.prototype.emit=function(type,event={}){event.target=event.target || this;event.preventDefault=event.preventDefault || function(){};return Promise.all((this.listeners[type] || []).map(fn=>fn(event)));};
  Element.prototype.click=function(){return this.disabled?Promise.resolve():this.emit('click');};
  Element.prototype.append=function(...items){for(const item of items){if(item.tagName==='fragment')this.children.push(...item.children);else this.children.push(item);}};
  Element.prototype.appendChild=function(item){this.append(item);return item;};
  Element.prototype.replaceChildren=function(...items){this.children=[];this.append(...items);};
  Element.prototype.setAttribute=function(name,value){this.attributes[name]=value;};
  Element.prototype.hasAttribute=function(name){return Object.hasOwn(this.attributes,name);};
  Element.prototype.querySelectorAll=function(selector){
    if(this.id==='preferences-form' && selector==='input, textarea, select, button')return ['preference-title','preference-content','preference-category','preference-enabled','preference-add','preference-delete','preference-move-up','preference-move-down','preferences-save'].map(get).concat(close);
    const all=[];function visit(node){for(const child of node.children){if(selector==='button' && child.tagName==='button' || selector[0]==='.' && (child.className || '').split(' ').includes(selector.slice(1)))all.push(child);visit(child);}}visit(this);return all;
  };
  Element.prototype.showModal=function(){this.open=true;};Element.prototype.close=function(){this.open=false;this.emit('close');};
  Element.prototype.focus=function(){};Element.prototype.scrollIntoView=function(){};Element.prototype.closest=function(){return null;};
  function get(id){if(/temporary/.test(id))return null;if(!nodes.has(id))nodes.set(id,new Element('div',id));return nodes.get(id);}
  close.dataset.closePreferences='library';close.setAttribute('data-close-preferences','library');
  const document={getElementById:get,createElement:tag=>new Element(tag),createDocumentFragment:()=>new Element('fragment'),querySelectorAll:selector=>selector==='[data-close-preferences]'?[close]:[]};
  get('discussion-list').hidden=true;
  return {$:get,document,close,nodes};
}
function rootFixture() {
  const d=dom(),box={...d,ReaderViewPolicy:require('../Resources/ui/app.js'),rangeOperation:null,discussionTitles:{activityChanged(){}},ready:true,loadFailed:false,state:{accountId:'synthetic',settings:{}},context:[],settingsBusy:false,busyAI:false,inlineBusy:()=>false,preparingContext:false,cancellingAI:false,quitting:false,cleanupBusy:false,preferencesSaving:false,discussionHistoryBusy:false,modelCapabilitiesLoading:()=>false,refreshModelCapabilities:()=>{},show:(id,visible)=>{d.$(id).hidden=!visible;},text:(id,value)=>{d.$(id).textContent=String(value);},thinkingOption:()=>({enabled:false,toggle:false,label:'默认',hint:''}),W:{supportedProvider:()=>false},preferencesUI:null,followedUI:null,rangeUI:null,renderDiscussionHistory:()=>{},renderDiscussionDeleteLocks:()=>{}};
  vm.createContext(box);
  vm.runInContext(['localSettingsLocked','preferencesLocked','renderAIControls','renderSettingsLocks','setSettingsBusy'].map(actualFunction).join('\n'),box);
  let renders=0;const render=box.renderAIControls;box.renderAIControls=()=>{renders++;return render();};
  return {box,...d,get renders(){return renders;}};
}
function uiFixture(options={}) {
  const d=options.dom || dom();let account='synthetic',library={version:1,entries:[{id:'entry',title:'原偏好',category:'writing',content:'旧写作要求',enabled:true}],quickPrompts:[{id:'quick',title:'总结',prompt:'请总结',enabled:true}]};
  let libraryLocked=false,aiLocked=true;const saved=[],filled=[],root={ReaderPreferences:P,dispatchEvent(){},crypto:{randomUUID:()=> 'new-id'}};
  const box={window:root,document:d.document,CustomEvent:function(type){this.type=type;}};vm.createContext(box);vm.runInContext(uiSource,box);
  const adapter={getLibrary:()=>JSON.parse(JSON.stringify(library)),getAccountId:()=>account,isLocked:options.isLocked || (()=>aiLocked),isLibraryLocked:options.isLibraryLocked || (()=>libraryLocked),saveLibrary:async value=>{saved.push(value);if(options.save)await options.save(value);library=JSON.parse(JSON.stringify(value));},fillPrompt:prompt=>filled.push(prompt)};
  const ui=root.ReaderPreferencesUI.mount(adapter);
  return {...d,ui,saved,filled,get library(){return library;},set library(value){library=value;},set account(value){account=value;},set libraryLocked(value){libraryLocked=value;},set aiLocked(value){aiLocked=value;}};
}

test('local settings availability ignores model checks, API setup and in-flight AI while preserving genuine local write locks',()=>{
  const f=rootFixture(),b=f.box;assert.equal(b.localSettingsLocked(),false);
  for(const field of ['settingsBusy','busyAI','preparingContext','cancellingAI','discussionHistoryBusy']){b[field]=true;assert.equal(b.localSettingsLocked(),false,field+' must not disable local settings');b[field]=false;}
  b.inlineBusy=()=>true;b.modelCapabilitiesLoading=()=>true;assert.equal(b.localSettingsLocked(),false);assert.equal(b.preferencesLocked(),true);
  b.inlineBusy=()=>false;b.modelCapabilitiesLoading=()=>false;
  for(const field of ['loadFailed','quitting','cleanupBusy','preferencesSaving']){b[field]=true;assert.equal(b.localSettingsLocked(),true,field+' must block unsafe local writes');b[field]=false;}
  b.ready=false;assert.equal(b.localSettingsLocked(),true);b.ready=true;b.state.accountId='';assert.equal(b.localSettingsLocked(),true);
});

test('settings save roundtrip redraws the actual controls and cannot strand both local entries disabled',()=>{
  const f=rootFixture(),b=f.box,ui=uiFixture({dom:f,isLocked:()=>b.preferencesLocked(),isLibraryLocked:()=>b.localSettingsLocked()});b.preferencesUI=ui.ui;
  b.renderAIControls();assert.equal(f.$('open-preferences').disabled,false);assert.equal(f.$('open-followed-members').disabled,false);
  b.setSettingsBusy(true,'save');b.renderAIControls();const before=f.renders;b.setSettingsBusy(false);
  assert.ok(f.renders>before,'setSettingsBusy(false) must redraw derived disabled states');
  assert.equal(b.settingsBusy,false);assert.equal(f.$('save-settings').disabled,false);assert.equal(f.$('open-preferences').disabled,false);assert.equal(f.$('open-followed-members').disabled,false);
  b.modelCapabilitiesLoading=()=>true;b.renderAIControls();assert.equal(f.$('open-preferences').disabled,false);assert.equal(f.$('open-followed-members').disabled,false);assert.equal(f.$('ai-send').disabled,true);
});

test('preferences mount without removed temporary-requirement DOM and remain editable while quick prompts are AI-locked',async()=>{
  const f=uiFixture();assert.equal(f.$('open-preferences').disabled,false);assert.equal(f.$('quick-prompts').children[0].disabled,true);
  await f.$('open-preferences').click();assert.equal(f.$('preferences-dialog').open,true);assert.equal(f.$('preference-content').disabled,false);
  f.$('preference-content').value='AI回答时可保存的新要求';await f.$('preference-content').emit('input');await f.$('preferences-form').emit('submit');
  assert.equal(f.library.entries[0].content,'AI回答时可保存的新要求');assert.equal(f.$('preferences-dialog').open,false);assert.equal(f.saved.length,1);assert.deepEqual(f.filled,[]);
});

test('empty quick-prompt customization uses the local library lock while configured prompts retain the AI lock',async()=>{
  const f=uiFixture();f.library={version:1,entries:[],quickPrompts:[]};f.ui.render();
  const customize=f.$('quick-prompts').children[0];assert.equal(customize.disabled,false);await customize.click();assert.equal(f.$('preferences-dialog').open,true);
  await f.close.click();f.libraryLocked=true;f.ui.render();assert.equal(f.$('open-preferences').disabled,true);assert.equal(f.$('quick-prompts').children[0].disabled,true);
  f.libraryLocked=false;f.aiLocked=false;f.library={version:1,entries:[],quickPrompts:[{id:'q',title:'问题',prompt:'下一次提问',enabled:true}]};f.ui.render();await f.$('quick-prompts').children[0].click();assert.deepEqual(f.filled,['下一次提问']);
});

test('library save failure preserves the draft, unlocks editing and still permits cancel without saving',async()=>{
  const pending=deferred(),f=uiFixture({save:()=>pending.promise});await f.$('open-preferences').click();
  f.$('preference-content').value='保留失败的草稿';await f.$('preference-content').emit('input');const saving=f.$('preferences-form').emit('submit');
  assert.equal(f.$('preference-content').disabled,true);assert.equal(f.close.disabled,true);pending.reject(new Error('磁盘暂不可写'));await saving;
  assert.equal(f.$('preferences-dialog').open,true);assert.equal(f.$('preference-content').value,'保留失败的草稿');assert.equal(f.$('preference-content').disabled,false);assert.match(f.$('preferences-error').textContent,/磁盘暂不可写/);
  await f.close.click();assert.equal(f.$('preferences-dialog').open,false);assert.equal(f.library.entries[0].content,'旧写作要求');
});

test('changing accounts closes a pending library session and ignores its late save callback',async()=>{
  const pending=deferred(),f=uiFixture({save:()=>pending.promise});await f.$('open-preferences').click();const saving=f.$('preferences-form').emit('submit');
  f.account='other';f.ui.render();assert.equal(f.$('preferences-dialog').open,false);pending.resolve();await saving;assert.equal(f.$('preferences-dialog').open,false);
});
