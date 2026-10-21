'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const modulePath = path.join(__dirname, '../Resources/ui/compact-reader.js');
const C = fs.existsSync(modulePath) ? require(modulePath) : {};
const group = {id:'g', selected:true};
function policy(options) {
  assert.equal(typeof C.syncPresentation, 'function', 'compact sync policy is available');
  return C.syncPresentation({group, native:true, ...options});
}
test('short sync status distinguishes real completion from waiting, loading and failure', () => {
  assert.equal(policy({}).short, '等待同步');
  assert.equal(policy({info:{state:'idle'}}).short, '同步已开启');
  assert.equal(policy({info:{state:'idle',updatedAt:'2026-10-21T00:00:00Z'}}).short, '已同步');
  for (const [state, short] of [['error','同步异常'],['backoff','等待重试'],['paused','已暂停']]) {
    const result=policy({info:{state,text:'连接已断开，请稍后再试'}});
    assert.equal(result.short,short); assert.equal(result.detail,'连接已断开，请稍后再试'); assert.equal(result.syncAction,'重试同步');
  }
  assert.equal(policy({info:{state:'loading',phase:'history'}}).short,'加载历史…');
  assert.equal(policy({info:{state:'loading',phase:'refresh'}}).short,'补全附件…');
  assert.equal(policy({info:{state:'loading',phase:'live'}}).short,'同步中…');
});
test('disabled, standby and demo states cannot inherit a stale success status', () => {
  const info={state:'idle',updatedAt:'2026-10-21T00:00:00Z'};
  for (const [options, short] of [[{group:null},'未选群聊'],[{group:{selected:false}},'未启用同步'],[{standby:true},'待机中'],[{demo:true},'演示内容']]) {
    const value=policy({...options,info});assert.equal(value.short,short);assert.equal(value.syncDisabled,true);assert.equal(value.historyDisabled,true);
  }
  assert.equal(policy({native:false}).syncDisabled,true);
  assert.equal(policy({locked:true}).syncDisabled,true);
  assert.equal(policy({info:{state:'loading',phase:'history'}}).historyDisabled,true);
  assert.equal(policy({info:{state:'idle',hasMore:false}}).historyAction,'没有更早消息');
});
test('visible filter summary retains query, type, member identity, both dates and audience', () => {
  assert.equal(typeof C.activeFilters,'function','active filter summary is available');
  assert.deepEqual(C.activeFilters({}),[]);
  assert.deepEqual(C.activeFilters({query:'  现金流  ',type:'document',memberId:'u-17',memberName:'成员甲',from:'2026-10-20',to:'2026-10-21',followed:true}),[
    '只看关注','搜索：现金流','类型：文件','成员：成员甲（u-17）','时间：2026-10-20 至 2026-10-21'
  ]);
  assert.deepEqual(C.activeFilters({memberId:'missing',from:'2026-10-20'}),['成员：missing','时间：2026-10-20 起']);
  assert.deepEqual(C.activeFilters({to:'2026-10-21'}),['时间：截至 2026-10-21']);
});
test('popover placement respects pane edges, short windows and triggers near the bottom', () => {
  assert.equal(typeof C.placePopover,'function','bounded popover placement is available');
  for (const width of [1024,820,650,430]) {
    const bounds={left:220,right:220+width,top:40,bottom:550};
    const value=C.placePopover({left:bounds.right-72,right:bounds.right-12,top:90,bottom:120},{width:350,height:600},bounds);
    assert.ok(value.left>=bounds.left+8);assert.ok(value.left+value.width<=bounds.right-8);assert.ok(value.top>=bounds.top+8);assert.ok(value.top+value.maxHeight<=bounds.bottom-8);
  }
  const value=C.placePopover({left:10,right:80,top:470,bottom:500},{width:350,height:280},{left:0,right:430,top:0,bottom:520});
  assert.ok(value.top<470);assert.equal(value.maxHeight,280);
});

// A tiny DOM adapter supplies only the standard browser operations used by the
// real controller. Assertions exercise its event listeners and focus behavior.
class Element {
  constructor(doc,id) { this.ownerDocument=doc;this.id=id;this.hidden=false;this.disabled=false;this.isConnected=true;this.attrs={};this.listeners={};this.children=[];this.style={};this.parentElement=null;this.rect={left:20,right:100,top:30,bottom:60,width:80,height:30}; }
  append(...children) { for(const child of children){child.parentElement=this;this.children.push(child);} }
  setAttribute(k,v){this.attrs[k]=String(v);}
  getAttribute(k){return this.attrs[k];}
  contains(node){return node===this||this.children.some(child=>child.contains(node));}
  addEventListener(k,fn){(this.listeners[k]??=[]).push(fn);}
  removeEventListener(k,fn){this.listeners[k]=(this.listeners[k]||[]).filter(item=>item!==fn);}
  fire(type,extra={}) { const event={target:this,key:'',preventDefault(){this.defaultPrevented=true;},...extra};for(const fn of this.listeners[type]||[])fn(event);return event; }
  focus(options){this.ownerDocument.activeElement=this;this.focusOptions=options;}
  getBoundingClientRect(){return this.rect;}
  getClientRects(){return this.hidden?[]:[this.rect];}
  querySelectorAll(){return this.children.flatMap(child=>[child,...child.querySelectorAll()]);}
  closest(selector){return selector==='[hidden]'?(this.hidden?this:this.parentElement?.closest(selector)):null;}
}
function menuFixture() {
  assert.equal(typeof C.createPopoverController,'function','keyboard popover controller is available');
  const doc=new Element(null,'document');doc.activeElement=null;
  const win=new Element(doc,'window');Object.assign(win,{innerWidth:430,innerHeight:600});
  const trigger=new Element(doc,'trigger'),menu=new Element(doc,'menu'),first=new Element(doc,'first'),last=new Element(doc,'last');
  const secondTrigger=new Element(doc,'second-trigger'),secondMenu=new Element(doc,'second-menu'),secondInput=new Element(doc,'second-input');
  menu.hidden=true;secondMenu.hidden=true;menu.rect={width:350,height:200};secondMenu.rect={width:250,height:200};menu.append(first,last);secondMenu.append(secondInput);
  const changes=[];
  const controller=C.createPopoverController({document:doc,window:win,entries:[{key:'sync',trigger,panel:menu,initialFocus:()=>first},{key:'filter',trigger:secondTrigger,panel:secondMenu,initialFocus:()=>secondInput}],onChange:value=>changes.push(value)});
  return {doc,win,trigger,menu,first,last,secondTrigger,secondMenu,secondInput,changes,controller};
}
test('popover keyboard opening, Escape and toggle restore focus without opening two menus', () => {
  const f=menuFixture();f.trigger.fire('keydown',{key:'ArrowDown'});
  assert.equal(f.menu.hidden,false);assert.equal(f.trigger.getAttribute('aria-expanded'),'true');assert.equal(f.doc.activeElement,f.first);
  f.secondTrigger.fire('click');assert.equal(f.menu.hidden,true);assert.equal(f.secondMenu.hidden,false);assert.equal(f.doc.activeElement,f.secondInput);
  f.doc.fire('keydown',{key:'Escape',target:f.secondInput});assert.equal(f.secondMenu.hidden,true);assert.equal(f.doc.activeElement,f.secondTrigger);assert.equal(f.controller.isOpen(),false);
  f.trigger.fire('click');f.trigger.fire('click');assert.equal(f.menu.hidden,true);assert.equal(f.doc.activeElement,f.trigger);
});
test('outside clicks and Tab boundaries close the menu without stealing destination focus', () => {
  const f=menuFixture(),outside=new Element(f.doc,'outside');
  f.trigger.fire('click');f.doc.fire('click',{target:f.last});assert.equal(f.menu.hidden,false);
  outside.focus();f.doc.fire('click',{target:outside});assert.equal(f.menu.hidden,true);assert.equal(f.doc.activeElement,outside);
  f.trigger.fire('click');f.last.focus();const event=f.doc.fire('keydown',{key:'Tab',target:f.last});assert.equal(f.menu.hidden,true);assert.equal(event.defaultPrevented,undefined);
  f.trigger.fire('click');f.doc.fire('keydown',{key:'Tab',shiftKey:true,target:f.first});assert.equal(f.menu.hidden,true);
});
test('transition close clears menu state and disabled triggers cannot reopen it', () => {
  const f=menuFixture();f.trigger.fire('click');f.controller.close({restoreFocus:false});assert.equal(f.menu.hidden,true);assert.equal(f.trigger.getAttribute('aria-expanded'),'false');
  f.trigger.disabled=true;f.trigger.fire('click');assert.equal(f.menu.hidden,true);
  f.controller.destroy();f.secondTrigger.fire('click');assert.equal(f.secondMenu.hidden,true);
});
test('opening and closing a portal leaves ancestor scroll positions alone', () => {
  const f=menuFixture();f.trigger.fire('click');
  assert.equal(f.first.focusOptions?.preventScroll,true);
  f.doc.fire('keydown',{key:'Escape',target:f.first});
  assert.equal(f.trigger.focusOptions?.preventScroll,true);
});

function appFunction(name) {
  const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
  const start=source.indexOf('  function '+name+'('),end=source.indexOf('\n  function ',start+5);
  assert.ok(start>=0&&end>start,'actual application function is available');
  return source.slice(start,end);
}
test('native sync events update both short header and detailed controls without stale success', () => {
  const vm=require('node:vm'),nodes=new Map(),syncStates=new Map();
  const $=id=>{if(!nodes.has(id))nodes.set(id,{textContent:'',disabled:false,dataset:{},setAttribute(k,v){this[k]=v;}});return nodes.get(id);};
  const box={ReaderCompact:C,window:{ReaderCompact:C},currentGroup:()=>group,state:{settings:{}},activeGroupId:'g',syncStates,native:true,demo:false,ready:true,loadFailed:false,quitting:false,$,text:(id,value)=>$(id).textContent=value,clockDate:()=> '10:00'};
  vm.createContext(box);vm.runInContext(appFunction('renderSyncStatus'),box);
  for(const [state,short] of [['loading','加载历史…'],['error','同步异常'],['backoff','等待重试'],['idle','已同步']]) {
    syncStates.set('g',{state,phase:'history',text:'真实原始同步信息',updatedAt:'2026-10-21T02:00:00Z'});box.renderSyncStatus();
    assert.equal($('sync-status-short').textContent,short);assert.equal($('sync-status').textContent,'真实原始同步信息');
    assert.equal($('sync-now').disabled,state==='loading');assert.equal($('load-history').disabled,state==='loading');
  }
});
test('navigation hides unavailable saved anchors and keeps a usable manual anchor independent', () => {
  const vm=require('node:vm'),nodes=new Map();
  const $=id=>{if(!nodes.has(id))nodes.set(id,{hidden:false,disabled:false,children:[],replaceChildren(...children){this.children=children;},querySelector(){return this.children.find(child=>child.tag==='time');},setAttribute(k,v){this[k]=v;}});return nodes.get(id);};
  const messages=[{id:'real',accountId:'a',groupId:'g',sentAt:'2026-10-21T02:00:00Z'}];
  const box={$ ,state:{accountId:'a',settings:{},progress:{g:{manual:{accountId:'a',groupId:'g',messageId:'real'},returnPoint:{accountId:'a',groupId:'g',messageId:'deleted'}}}},activeGroupId:'g',archive:()=>({find:(_,id)=>messages.find(m=>m.id===id),forGroup:()=>messages}),window:{ReaderPersonalization:{isSystemNotice:()=>false}},fullDate:value=>value,node:(tag,cls,text)=>({tag,text}),icon:name=>({name}),show:(id,visible)=>$(id).hidden=!visible};
  vm.createContext(box);vm.runInContext(appFunction('renderProgressButtons'),box);box.renderProgressButtons();
  assert.equal($('manual-position').hidden,false);assert.equal($('manual-position').disabled,false);assert.equal($('return-position').hidden,true);assert.equal($('return-position').disabled,true);assert.equal($('coverage-action').disabled,false);
  messages.length=0;box.renderProgressButtons();assert.equal($('manual-position').hidden,true);assert.equal($('reader-navigation').hidden,true);
});

test('cross-group source jumps close the active menu before replacing the reading context', () => {
  const vm=require('node:vm'),calls=[],nodes=new Map();
  const message={id:'m',accountId:'a',groupId:'other',sentAt:'2026-10-21T02:00:00Z'};
  const box={compactReader:{close(){calls.push('close');}},settleReading(){},archive:()=>({find:()=>message}),window:{ReaderPersonalization:{isSystemNotice:()=>false}},state:{accountId:'a',settings:{},progress:{}},activeGroupId:'g',activeView:'chats',mode:'reader',readingNavigationEpoch:1,focusedSource:null,messageType:'all',readerFollowedOnly:false,memberId:'',saveReturnPoint(){calls.push('save-return');},$:id=>{if(!nodes.has(id))nodes.set(id,{value:''});return nodes.get(id);},renderSidebar(){calls.push('render');},renderHeader(){},renderViews(){},renderReader(){},saveViewPreferences(){},scrollToMessage:()=>true};
  vm.createContext(box);vm.runInContext(appFunction('jumpTo'),box);box.jumpTo('other','m');
  assert.equal(calls[0],'close');assert.equal(box.activeGroupId,'other');assert.equal(box.mode,'reader');
});

function officialCountFixture() {
  const vm=require('node:vm'),M=require('../Resources/ui/model.js'),P=require('../Resources/ui/reader-performance.js');
  const state=M.createState('a'),nodes=new Map(),timers=[];
  M.upsertGroups(state,[{id:'g',name:'当前群',selected:true},{id:'other',name:'其他群',selected:true}]);
  const message=(id,props={})=>({id,groupId:'g',senderId:'u',senderName:'成员',sentAt:'2026-10-21T02:00:00Z',text:'needle',attachments:[{type:'document',name:'needle.pdf'}],...props});
  M.ingestMessages(state,'g',[message('old'),message('notice',{text:'成员撤回了一条消息',attachments:[]})]);
  const $=id=>{if(!nodes.has(id))nodes.set(id,{value:'',textContent:'',hidden:false,disabled:false,dataset:{},classList:{toggle(){}},setAttribute(k,v){this[k]=v;}});return nodes.get(id);};
  const box={M,P,state,$,window:{ReaderCompact:C,ReaderPersonalization:require('../Resources/ui/reader-personalization.js')},ReaderDiscovery:require('../Resources/ui/reader-discovery.js'),
    activeGroupId:'g',activeView:'chats',mode:'official',messageType:'all',readerFollowedOnly:false,memberId:'',focusedSource:null,
    archiveDirty:true,archiveIndex:null,syncDirtyGroups:new Set(),syncRenderTimer:0,syncStates:new Map(),native:true,demo:false,ready:true,loadFailed:false,quitting:false,
    text:(id,value)=>$(id).textContent=value,show:(id,visible)=>$(id).hidden=!visible,fullDate:value=>value,clockDate:value=>value,
    setTimeout:fn=>{timers.push(fn);return timers.length;},renderSidebar(){},renderReader(){assert.fail('official updates must not render hidden message DOM');},banner(message){assert.fail(message);},errorText:error=>error.message};
  const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
  const functions=['currentGroup','archive','isFiltered','searchOptions','renderHeader','renderSyncStatus','scheduleSyncedRender'];
  // Load the shared result helpers when present; the old application still runs
  // through its real header/scheduler path and reproduces the stale-count bug.
  for(const name of ['readerResultMessages','renderReaderResultCount'])if(source.includes('  function '+name+'('))functions.push(name);
  vm.createContext(box);vm.runInContext(functions.map(appFunction).join('\n'),box);
  $('result-count').textContent='1 条本地消息';
  function append(messages,groupId='g') {
    M.ingestMessages(state,groupId,messages);box.archiveDirty=true;box.scheduleSyncedRender(groupId);
    while(timers.length)timers.shift()();
  }
  return {box,$,state,message,append};
}
test('official live updates refresh local coverage and visible counts while excluding withdrawal notices',()=>{
  const f=officialCountFixture();
  f.append([f.message('new'),f.message('new-notice',{text:'你撤回了一条消息',attachments:[]})]);
  assert.match(f.$('coverage-text').textContent,/本地 4 条/);
  assert.equal(f.$('result-count').textContent,'2 条本地消息');
  f.append([f.message('elsewhere',{groupId:'other'})],'other');
  assert.equal(f.$('result-count').textContent,'2 条本地消息','another group cannot change this group count');
});
test('official live updates preserve combined query, type, member, audience and date counts',()=>{
  const f=officialCountFixture();
  f.box.messageType='document';f.box.memberId='u';f.box.readerFollowedOnly=true;f.state.settings.followedMembers=[{senderId:'u',name:'成员'}];
  f.$('message-search').value='needle';f.$('date-from').value='2026-10-21';f.$('date-to').value='2026-10-21';
  f.$('result-count').textContent='1 条匹配消息';
  f.append([f.message('match'),f.message('wrong-member',{senderId:'v'}),f.message('wrong-type',{attachments:[{type:'link',url:'https://example.invalid/needle'}]}),f.message('wrong-day',{sentAt:'2026-10-19T02:00:00Z'}),f.message('wrong-query',{text:'other',attachments:[{type:'document',name:'other.pdf'}]})]);
  assert.match(f.$('coverage-text').textContent,/本地 7 条/);
  assert.equal(f.$('result-count').textContent,'2 条匹配消息');
  assert.equal(f.$('filter-result-count').textContent,'2 条匹配');
});
test('official count refresh retains summary source snapshots without duplication or filter leakage',()=>{
  const f=officialCountFixture();
  f.box.focusedSource={...f.message('snapshot',{text:'orphan source',attachments:[]}),accountId:'a'};
  f.$('result-count').textContent='2 条消息 · 含总结来源快照';
  f.append([f.message('new')]);assert.equal(f.$('result-count').textContent,'3 条消息 · 含总结来源快照');
  f.append([f.box.focusedSource]);assert.equal(f.$('result-count').textContent,'3 条消息 · 含总结来源快照','newly saved source is counted once');
  f.$('message-search').value='needle';f.box.renderHeader();assert.equal(f.$('result-count').textContent,'2 条匹配消息','filters continue excluding a nonmatching source snapshot');
  f.$('message-search').value='';f.box.renderHeader();assert.equal(f.$('result-count').textContent,'3 条消息 · 含总结来源快照');
});
