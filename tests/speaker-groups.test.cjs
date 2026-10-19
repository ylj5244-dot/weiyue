const test=require('node:test');const assert=require('node:assert/strict');
const S=require('../Resources/ui/speaker-groups.js');
const message=(id,senderId='person',time='2026-10-18T02:00:00Z',extra={})=>({id,accountId:'account',groupId:'group',senderId,senderName:'Member',sentAt:time,text:'Message',attachments:[],...extra});
const day=value=>new Date(value).toISOString().slice(0,10);
test('all consecutive messages from one real member share a frame even more than five minutes apart',()=>{
  const a=message('a'),b=message('b','person','2026-10-18T02:20:00Z'),c=message('c','person','2026-10-18T05:00:00Z');
  assert.equal(S.describe(a,null,b,day).position,'start');assert.equal(S.describe(b,a,c,day).position,'middle');assert.equal(S.describe(c,b,null,day).position,'end');
  assert.equal(S.describe(a,null,null,day).position,'single');assert.equal(S.describe(b,a,c,day).continuation,true);
  assert.equal(S.describe(a,null,b,day).tone,S.describe(c,b,null,day).tone);
});
test('member, account, group and displayed local-day boundaries split frames without merging unknown people',()=>{
  const a=message('a');
  for(const b of [message('b','other'),message('b','person',a.sentAt,{accountId:'other'}),message('b','person',a.sentAt,{groupId:'other'}),message('b','person','2026-10-19T02:00:00Z')])assert.equal(S.canJoin(a,b,day),false);
  for(const unknown of [undefined,null,'','  ','unknown','unknown:123','0','null','undefined'])assert.equal(S.canJoin({...message('a'),senderId:unknown},{...message('b'),senderId:unknown},day),false);
  assert.equal(S.canJoin(message('a','person','2026-10-18T15:59:00Z'),message('b','person','2026-10-18T16:01:00Z'),value=>new Date(Date.parse(value)+8*3600000).toISOString().slice(0,10)),false);
  assert.equal(S.canJoin(a,message('b','person','invalid'),()=> 'unknown'),false);
});
test('consecutive speaker blocks cycle through exactly three tones, including a returning speaker',()=>{
  assert.equal(S.PALETTE_SIZE,3);
  assert.equal(typeof S.describeAll,'function');
  const messages=[message('a'),message('b','person','2026-10-18T05:00:00Z'),message('c','other'),message('d'),message('e','third'),message('f','fourth')];
  const descriptions=S.describeAll(messages,day);
  assert.deepEqual(descriptions.map(item=>item.tone),[0,0,1,2,0,1]);
  assert.deepEqual(descriptions.map(item=>item.position),['start','end','single','single','single','single']);
  assert.deepEqual(descriptions.map(item=>item.continuation),[false,true,false,false,false,false]);
  assert.deepEqual(S.describeAll([],day),[]);
});
test('day, account, group and unknown-sender boundaries each advance the three-tone sequence',()=>{
  const messages=[message('a'),message('b','person','2026-10-19T02:00:00Z'),message('c','person','2026-10-19T02:00:00Z',{accountId:'second'}),message('d','person','2026-10-19T02:00:00Z',{accountId:'second',groupId:'second'}),message('e','unknown'),message('f','unknown')];
  assert.deepEqual(S.describeAll(messages,day).map(item=>item.tone),[0,1,2,0,1,2]);
  const midnight=[message('a','person','2026-10-18T15:59:00Z'),message('b','person','2026-10-18T16:01:00Z')];
  assert.deepEqual(S.describeAll(midnight,value=>new Date(Date.parse(value)+8*3600000).toISOString().slice(0,10)).map(item=>item.tone),[0,1]);
});
test('filtering derives blocks from the remaining messages and rebases the sequence at zero',()=>{
  const messages=[message('a'),message('b','other'),message('c'),message('d','third')];
  const filtered=[messages[0],messages[2],messages[3]],descriptions=S.describeAll(filtered,day);
  assert.deepEqual(descriptions.map(item=>item.tone),[0,0,1]);
  assert.deepEqual(descriptions.map(item=>item.position),['start','end','single']);
});
test('individual records alternate across a same-member frame without changing its group identity',()=>{
  const messages=Array.from({length:7},(_,index)=>message('m'+index));
  const descriptions=S.describeAll(messages,day);
  assert.deepEqual(descriptions.map(item=>item.messageTone),[0,1,2,0,1,2,0]);
  assert.ok(descriptions.every(item=>item.tone===0),'original group palette is unchanged');
  assert.deepEqual(descriptions.map(item=>item.position),['start','middle','middle','middle','middle','middle','end']);
  const filtered=S.describeAll([messages[0],messages[2],messages[5],messages[6]],day);
  assert.deepEqual(filtered.map(item=>item.messageTone),[0,1,2,0],'filtered display sequence starts a fresh coherent alternation');
});
test('large sequences format each timestamp at most once without retaining date keys across calls',()=>{
  const messages=Array.from({length:1000},(_,index)=>message('m'+index,'person',new Date(Date.parse('2026-10-18T15:59:00Z')+index*1000).toISOString()));
  let formats=0;const descriptions=S.describeAll(messages,value=>{formats++;return day(value);});
  assert.ok(formats<=messages.length,`formatted ${formats} times for ${messages.length} messages`);
  assert.ok(descriptions.every(item=>item.tone===0));
  const nextZone=S.describeAll(messages,value=>new Date(Date.parse(value)+8*3600000).toISOString().slice(0,10));
  assert.equal(nextZone[59].tone,0);assert.equal(nextZone[60].tone,1);
});

function virtualFixture(){
  const previous={document:global.document,ResizeObserver:global.ResizeObserver,requestAnimationFrame:global.requestAnimationFrame};let content,scroll,list,descriptions=[];
  class Element{
    constructor(name='div'){this.name=name;this.children=[];this.parent=null;this.style={};this.dataset={};this.className='';}
    append(...nodes){for(const child of nodes){if(child.name==='fragment'){this.append(...child.children.slice());continue;}if(child.parent)child.parent.children.splice(child.parent.children.indexOf(child),1);child.parent=this;this.children.push(child);}}
    replaceChildren(...nodes){for(const child of this.children)child.parent=null;this.children=[];this.append(...nodes);}
    setAttribute(){}addEventListener(){}
    querySelector(selector){for(const child of this.children){if(selector==='.message-card'&&child.className==='message-card')return child;const found=child.querySelector(selector);if(found)return found;}return null;}
    get height(){return this.fixedHeight===undefined?(this.style.height!==undefined?parseFloat(this.style.height)||0:this.children.reduce((n,c)=>n+c.height,0)):this.fixedHeight;}
    get top(){if(!this.parent)return 0;let offset=0;for(const sibling of this.parent.children){if(sibling===this)break;offset+=sibling.height;}return this.parent.top+offset-(this.parent===scroll?scroll.scrollTop:0);}
    getBoundingClientRect(){return {top:this.top,bottom:this.top+this.height,height:this.height,width:600};}
  }
  global.document={createElement:name=>new Element(name),createDocumentFragment:()=>new Element('fragment')};global.ResizeObserver=class{observe(){}unobserve(){}};global.requestAnimationFrame=()=>1;
  scroll=new Element();scroll.clientHeight=600;scroll.fixedHeight=600;scroll.clientWidth=600;scroll.scrollTop=0;content=new Element();scroll.append(content);
  const {VirtualList}=require('../Resources/ui/reader-performance.js');
  list=new VirtualList({scroll,content,keyFor:item=>item.id,cacheTokenFor:(item,index)=>descriptions[index].tone+':'+descriptions[index].position+':'+descriptions[index].messageTone,createRow:(item,index)=>{const card=new Element();card.className='message-card';card.fixedHeight=80;card.grouping=descriptions[index];card.dataset={messageId:item.id,accountId:item.accountId,groupId:item.groupId};return [card];}});
  return {list,setItems(items,options){descriptions=S.describeAll(items,day);list.setItems(items,options);},restore(){Object.assign(global,previous);}};
}
test('virtual row cache updates the previous final frame when new messages arrive and when filters change neighbours',()=>{
  const f=virtualFixture();try{
    const a=message('a'),b=message('b'),c=message('c');f.setItems([a,b]);const oldA=f.list.card('a'),oldB=f.list.card('b');assert.equal(oldB.grouping.position,'end');
    f.setItems([a,b,c]);assert.equal(f.list.card('a'),oldA);assert.notEqual(f.list.card('b'),oldB);assert.equal(f.list.card('b').grouping.position,'middle');assert.equal(f.list.card('c').grouping.position,'end');
    const other={...c,senderId:'other'};f.setItems([a,b,other]);assert.equal(f.list.card('b').grouping.position,'end');assert.equal(f.list.card('c').grouping.position,'single');assert.equal(f.list.card('c').grouping.tone,1);
    f.setItems([b,other]);assert.equal(f.list.card('b').grouping.position,'single');
  }finally{f.restore();}
});
test('prepending a block refreshes later cached tones even when a row and both neighbours are unchanged',()=>{
  const f=virtualFixture();try{
    const messages=Array.from({length:6},(_,index)=>message('m'+index,'speaker'+index));f.setItems(messages);
    const oldMiddle=f.list.card('m3');assert.equal(oldMiddle.grouping.tone,0);
    f.setItems([message('older','older-speaker'),...messages]);
    assert.equal(f.list.card('m3').grouping.tone,1);assert.notEqual(f.list.card('m3'),oldMiddle);
    const stableMiddle=f.list.card('m3');f.setItems([message('older','older-speaker'),...messages]);assert.equal(f.list.card('m3'),stableMiddle);
  }finally{f.restore();}
});
test('filtering an earlier block refreshes later cached tones with unchanged neighbours',()=>{
  const f=virtualFixture();try{
    const messages=Array.from({length:6},(_,index)=>message('m'+index,'speaker'+index));f.setItems(messages);
    const oldMiddle=f.list.card('m3');f.setItems(messages.slice(1));
    assert.equal(f.list.card('m3').grouping.tone,2);assert.notEqual(f.list.card('m3'),oldMiddle);
  }finally{f.restore();}
});
test('same-member prepend and filter invalidate record tones even when group tone and neighbours stay the same',()=>{
  const f=virtualFixture();try{
    const messages=Array.from({length:8},(_,index)=>message('m'+index));f.setItems(messages);
    const old=f.list.card('m4');assert.equal(old.grouping.messageTone,1);
    f.setItems([message('older'),...messages]);
    const shifted=f.list.card('m4');assert.equal(shifted.grouping.messageTone,2);assert.notEqual(shifted,old);
    assert.equal(shifted.grouping.tone,old.grouping.tone);assert.equal(shifted.grouping.position,old.grouping.position);
    f.setItems(messages.slice(1));assert.equal(f.list.card('m4').grouping.messageTone,0);
  }finally{f.restore();}
});
test('virtual windows preserve sequence tones and continuation across offscreen block boundaries',()=>{
  const f=virtualFixture();try{
    const messages=Array.from({length:120},(_,index)=>message('m'+index,'speaker'+Math.floor(index/3)));f.setItems(messages);
    assert.equal(f.list.scrollTo('m76'),true);assert.ok(f.list.start>0);assert.equal(f.list.card('m0'),null);
    for(const [key] of f.list.nodes){const index=Number(key.slice(1)),description=f.list.card(key).grouping;assert.equal(description.tone,Math.floor(index/3)%3);assert.equal(description.messageTone,index%3);assert.equal(description.position,['start','middle','end'][index%3]);}
    assert.equal(f.list.scrollTo('m0'),true);assert.equal(f.list.card('m0').grouping.tone,0);assert.equal(f.list.card('m1').grouping.position,'middle');
  }finally{f.restore();}
});
