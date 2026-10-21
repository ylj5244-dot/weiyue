'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const S=require('../Resources/ui/message-sizing.js'),G=require('../Resources/ui/speaker-groups.js');
test('content widths follow the longest message in each actual consecutive speaker group',()=>{
 const messages=[['a',120],['a',460],['b',180],['a',220]].map(([senderId,width],i)=>({accountId:'account',groupId:'g',id:String(i),senderId,sentAt:'2026-10-21T01:00:00Z',width}));
 const groups=G.describeAll(messages);assert.deepEqual(S.groupWidths(messages,groups,m=>m.width),[460,460,180,220]);
 const filtered=[messages[0],messages[3]],filteredGroups=G.describeAll(filtered);assert.deepEqual(S.groupWidths(filtered,filteredGroups,m=>m.width),[220,220]);
 assert.deepEqual(S.groupWidths([],[],()=>100),[]);
});
test('header allowance occurs only at the start of each group',()=>{
 const messages=[1,2,3],groups=[{continuation:false},{continuation:true},{continuation:false}];
 assert.deepEqual(S.groupWidths(messages,groups,(m,first)=>m*30+(first?100:0)),[130,130,190]);
});
