const test=require('node:test'),assert=require('node:assert/strict');
const D=require('../Resources/ui/reader-discovery.js'),P=require('../Resources/ui/reader-performance.js');
const m=(id,props={})=>({accountId:'a',groupId:'g',id,senderId:'u',senderName:'Name',sentAt:'2026-10-21T10:00:00Z',text:'',attachments:[],...props});
test('classification supports mixed attachments and inline links without treating image sources as shared links',()=>{
 assert.deepEqual(D.kinds(m('1',{text:'see https://example.com/a',attachments:[{type:'image',url:'https://img.example/a'}]})),['link','image']);
 assert.deepEqual(D.kinds(m('2',{attachments:[{type:'image',url:'https://img.example/a'},{type:'image'}]})),['image']);
 assert.deepEqual(D.kinds(m('3',{attachments:[{type:'document'},{type:'video'},{type:'link'}]})),['link','document','video']);
});
test('indexed searches combine type, attachment title or URL, sender, group and date filters',()=>{
 const data=[m('pdf',{attachments:[{type:'document',name:'季度报告.PDF',url:'https://example.com/report'}]}),m('image',{attachments:[{type:'image',name:'image.png'}]}),m('other',{groupId:'g2',senderId:'v',text:'https://example.com/hello'})];
 const index=new P.ArchiveIndex(data);
 assert.deepEqual(index.search({type:'document',query:'报告'}).map(m=>m.id),['pdf']);
 assert.deepEqual(index.search({type:'document',query:'EXAMPLE.COM/report',senderId:'u',groupId:'g'}).map(m=>m.id),['pdf']);
 assert.deepEqual(index.search({type:'link',senderIds:['v'],accountId:'a'}).map(m=>m.id),['other']);
 assert.deepEqual(index.search({type:'document',from:'2026-10-22T00:00:00Z'}),[]);
 assert.throws(()=>index.search({type:'unsupported'}));
 assert.deepEqual(index.search({senderIds:[]}),[]);
});
test('own messages and followed feed use account and stable sender ID, never display names',()=>{
 const state={accountId:'a',settings:{followedMembers:[{senderId:'u',name:'Name'}]}};
 assert.equal(D.isOwn(state,m('self',{senderId:'a'})),true);
 assert.equal(D.isOwn(state,m('same-name',{senderName:'a'})),false);
 assert.equal(D.isOwn(state,m('other',{accountId:'b',senderId:'a'})),false);
 assert.equal(D.isOwn({accountId:''},m('unknown',{accountId:'',senderId:''})),false);
 assert.deepEqual(D.followedIds(state),['u']);
});

test('followed render anchors retain their own source group without writing group progress',()=>{
  const UI=require('../Resources/ui/app.js');
  const state={accountId:'a',progress:{g1:{auto:{accountId:'a',groupId:'g1',messageId:'old',offset:0}}}};
  const visible={accountId:'a',groupId:'g2',messageId:'same',offset:12,visualOffset:8};
  const messages=[{accountId:'a',groupId:'g1',id:'same'},{accountId:'a',groupId:'g2',id:'same'}];
  assert.deepEqual(UI.chooseAnchor({state,groupId:'g1',messages,visible,filtered:true,acrossGroups:true}),visible);
  assert.equal(UI.shouldTrackProgress({mode:'reader',view:'followed',filtered:true,userInitiated:true}),false);
});

test('followed attachment official action selects its source group before opening the official view',()=>{
  const fs=require('node:fs'),vm=require('node:vm');const source=fs.readFileSync(require.resolve('../Resources/ui/app.js'),'utf8');
  const start=source.indexOf('    const official = () =>'),end=source.indexOf('\n    if (supportsAI)',start),calls=[];
  const box={current:()=>true,activeView:'followed',activeGroupId:'g1',message:{groupId:'g2'},native:true,reference:{groupId:'g2',messageId:'m'},setGroup:id=>{calls.push(['group',id]);box.activeGroupId=id;box.activeView='chats';return true;},setMode:mode=>calls.push(['mode',mode]),rpc:(action,payload)=>{calls.push([action,payload.groupId]);return Promise.resolve();},handleError(){}};
  vm.createContext(box);vm.runInContext(source.slice(start,end)+'\nofficial();',box);
  assert.deepEqual(calls,[['group','g2'],['mode','official'],['openOfficial','g2']]);
});
