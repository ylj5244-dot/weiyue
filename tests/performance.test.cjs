'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
function performanceModule(){return require('../Resources/ui/reader-performance.js');}
test('a 5000-message archive mounts a bounded visible range instead of every message',()=>{
  const {HeightIndex}=performanceModule();
  const heights=new HeightIndex(Array(5000).fill(80));
  const range=heights.range(200000,900,700);
  assert.ok(range.end-range.start<=32);assert.ok(range.start>2000);
  assert.equal(heights.total(),400000);
  assert.match(source,/readerList\.setItems/,'the actual reader must use the virtual list');
  assert.doesNotMatch(source,/messages\.forEach\(\(message, index\) => \{\s*const date = dayDate/,'no whole archive DOM construction');
});
test('variable heights preserve arbitrary saved and historical anchors, including long messages',()=>{
  const {HeightIndex}=performanceModule(), heights=new HeightIndex([50,80,100,40,200]);
  assert.equal(heights.offset(3),230);assert.equal(heights.indexAt(230),3);
  heights.update(1,800);assert.equal(heights.offset(3),950);assert.equal(heights.indexAt(849),1);
  assert.deepEqual(heights.range(950,40,0),{start:3,end:4});
  assert.equal(heights.indexAt(-2),0);assert.equal(heights.indexAt(999999),4);
});
test('search remains exhaustive when messages are outside the mounted range',()=>{
  const {ArchiveIndex}=performanceModule();
  const messages=Array.from({length:5000},(_,i)=>({id:String(i),groupId:i%2?'a':'b',senderId:'u'+i%20,senderName:'User '+i%20,text:'Message '+i,sentAt:new Date(1700000000000+i*60000).toISOString()}));
  const index=new ArchiveIndex(messages);
  assert.equal(index.forGroup('a').length,2500);
  assert.deepEqual(index.search({groupId:'a',query:'Message 4999'}).map(m=>m.id),['4999']);
  assert.equal(index.find('b','4000').id,'4000');
  assert.equal(index.search({senderId:'u19'}).length,250);
  assert.throws(()=>index.search({from:'2026-12-01T00:00:00Z',to:'2026-01-01T00:00:00Z'}));
});
test('backlogged save requests coalesce but all callers await the newest durable version',async()=>{
  const {CoalescedQueue}=performanceModule(); const queue=new CoalescedQueue();
  let release,version=1;const saved=[];
  const first=queue.request('account-a',async()=>{await new Promise(resolve=>release=resolve);saved.push(1);return 1;});
  await new Promise(resolve=>setTimeout(resolve,5));
  const waiters=[];for(let i=2;i<=100;i++){version=i;waiters.push(queue.request('account-a',async()=>{saved.push(version);return version;}));}
  release();await first;const results=await Promise.all(waiters);
  assert.deepEqual(saved,[1,100]);assert.ok(results.every(result=>result===100));
});
test('save merging never crosses account or hides failures',async()=>{
  const {CoalescedQueue}=performanceModule();const queue=new CoalescedQueue();const saved=[];
  const first=queue.request('a',async()=>{saved.push('a');return 'a';},20);
  const second=queue.request('b',async()=>{saved.push('b');return 'b';},20);
  assert.deepEqual(await Promise.all([first,second]),['a','b']);assert.deepEqual(saved,['a','b']);
  await assert.rejects(queue.request('a',async()=>{throw new Error('disk failure');}),/disk failure/);
  assert.equal(await queue.request('a',async()=>3),3);
});

// A deterministic layout harness tests the real virtual-list controller without
// accessing the logged-in WebView or any user's archive.
function layoutFixture() {
  const scheduled=[];let scroll,content;
  class Element {
    constructor(name='div') { this.name=name;this.children=[];this.parent=null;this.style={};this.dataset={};this.className='';this.listeners={};this._top=0; }
    append(...nodes) { for(const child of nodes) { if(child.name==='fragment'){this.append(...child.children.slice());continue;} if(child.parent){child.parent.children.splice(child.parent.children.indexOf(child),1);if(scroll&&content)scroll.scrollTop=scroll.scrollTop;}child.parent=this;this.children.push(child); } }
    replaceChildren(...nodes) { for(const child of this.children)child.parent=null;this.children=[];if(this===content&&scroll)scroll.scrollTop=scroll.scrollTop;this.append(...nodes); }
    setAttribute(){}
    addEventListener(name,handler){this.listeners[name]=handler;}
    querySelector(selector){for(const child of this.children){if(selector==='.message-card'&&child.className==='message-card')return child;const result=child.querySelector(selector);if(result)return result;}return null;}
    get height(){if(this.style.height!==undefined)return parseFloat(this.style.height)||0;if(this.fixedHeight!==undefined)return this.fixedHeight;return this.children.reduce((n,child)=>n+child.height,0);}
    get top(){if(!this.parent)return this._top;let offset=0;for(const sibling of this.parent.children){if(sibling===this)break;offset+=sibling.height;}return this.parent.top+offset-(this.parent===scroll?scroll.scrollTop:0);}
    getBoundingClientRect(){return {top:this.top,bottom:this.top+this.height,height:this.height,width:this.clientWidth||600};}
  }
  scroll=new Element();scroll.clientHeight=800;scroll.fixedHeight=800;scroll.clientWidth=600;scroll._scrollTop=0;
  Object.defineProperty(scroll,'scrollTop',{get(){return this._scrollTop;},set(value){this._scrollTop=Math.max(0,Math.min(value,Math.max(0,content.height-this.clientHeight)));}});
  content=new Element();scroll.append(content);
  const originals={document:global.document,ResizeObserver:global.ResizeObserver,requestAnimationFrame:global.requestAnimationFrame};
  global.document={createElement:name=>new Element(name),createDocumentFragment:()=>new Element('fragment')};
  global.ResizeObserver=class{observe(){}unobserve(){}};
  global.requestAnimationFrame=callback=>{scheduled.push(callback);return scheduled.length;};
  const {VirtualList}=performanceModule();
  const list=new VirtualList({scroll,content,keyFor:m=>m.id,createRow:(m,index)=>{const card=new Element();card.className='message-card';card.fixedHeight=m.height;card.dataset={messageId:m.id,accountId:'sample',groupId:'g'};return index%20===0?[Object.assign(new Element(),{fixedHeight:30}),card]:[card];}});
  return {list,scroll,content,restore(){Object.assign(global,originals);},drain(){while(scheduled.length)scheduled.shift()();}};
}
test('real controller restores a far history anchor when the previous DOM was empty',()=>{
  const f=layoutFixture();try{
    const messages=Array.from({length:5000},(_,i)=>({id:String(i),height:40+i%8*15,text:'Message '+i}));
    f.list.setItems(messages,{anchor:{key:'4000',offset:17}});
    assert.equal(f.list.visibleAnchor().messageId,'4000');assert.equal(f.list.visibleAnchor().offset,17);
    assert.ok(f.list.nodes.size<45,'mounted DOM stays bounded');
    assert.equal(f.list.scrollTo('4980',23),true);assert.equal(f.list.visibleAnchor().messageId,'4980');assert.equal(f.list.visibleAnchor().offset,23);
    assert.equal(f.list.scrollTo('0'),true);assert.equal(f.list.visibleAnchor().messageId,'0');
    assert.equal(f.list.scrollTo('missing'),false);
  }finally{f.restore();}
});
test('prepend, incoming messages and image height changes preserve the visible message and offset',()=>{
  const f=layoutFixture();try{
    let messages=Array.from({length:1000},(_,i)=>({id:String(i),height:80,text:'Message '+i}));
    f.list.setItems(messages,{anchor:{key:'500',offset:9}});
    const anchor=f.list.visibleAnchor();
    messages=Array.from({length:500},(_,i)=>({id:'old-'+i,height:60,text:'History'})).concat(messages,{id:'new',height:80,text:'New'});
    f.list.setItems(messages,{anchor});
    assert.equal(f.list.visibleAnchor().messageId,'500');assert.equal(f.list.visibleAnchor().offset,9);
    const before=f.list.visibleAnchor();
    const imageAbove=f.list.card('499');imageAbove.fixedHeight=450;
    f.list.needsMeasure=true; f.list.render();
    assert.equal(f.list.visibleAnchor().messageId,before.messageId);assert.equal(f.list.visibleAnchor().offset,before.offset);
    assert.ok(f.list.nodes.size<45);
  }finally{f.restore();}
});
test('fast scrollbar moves mount the destination and preserve search selection on a one-row result',()=>{
  const f=layoutFixture();try{
    const messages=Array.from({length:5000},(_,i)=>({id:String(i),height:80,text:'Message '+i}));
    f.list.setItems(messages);
    f.scroll.scrollTop=200000;f.list.render();assert.ok(Number(f.list.visibleAnchor().messageId)>2000);
    f.scroll.scrollTop=10;f.list.render();assert.equal(f.list.visibleAnchor().messageId,'0');
    f.list.setItems([messages[4500]],{scrollTop:0});assert.equal(f.list.visibleAnchor().messageId,'4500');assert.equal(f.list.nodes.size,1);
  }finally{f.restore();}
});

test('explicit search reset cannot reuse a previous anchor that also happens to match the results',()=>{
  const f=layoutFixture();try{
    const messages=Array.from({length:1000},(_,i)=>({id:String(i),height:80,text:'Message '+i}));
    f.list.setItems(messages,{anchor:{key:'500',offset:12}});
    f.list.setItems(messages.filter((_,i)=>i%2===0),{scrollTop:0});
    assert.equal(f.list.visibleAnchor().messageId,'0');
  }finally{f.restore();}
});

test('initial top keeps its date heading visible while saved offsets still target the message itself',()=>{
  const f=layoutFixture();try{
    const messages=Array.from({length:100},(_,i)=>({id:String(i),height:80,text:'Message '+i}));
    f.list.setItems(messages,{scrollTop:0});assert.equal(f.scroll.scrollTop,0);
    f.list.scrollTo('0',10);assert.equal(f.list.visibleAnchor().offset,10);
  }finally{f.restore();}
});
