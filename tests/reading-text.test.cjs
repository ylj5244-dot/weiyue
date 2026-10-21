'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const R=require('../Resources/ui/reading-text.js'),assets=require('../Resources/ui/weibo-emoticons.js'),P=require('../Resources/ui/reader-personalization.js');
test('named Weibo emoticons preserve source text and decode adjacent emoji safely',()=>{
 const input='你好[二哈][笑cry]🙂[未知]<script>alert(1)</script>';
 const parts=R.tokenize(input,assets);assert.equal(parts.map(p=>p.text).join(''),input);assert.equal(parts.filter(p=>p.file).length,2);assert.ok(parts.find(p=>p.text==='[二哈]').file.endsWith('2018new_erha_org.png'));assert.equal(parts.at(-1).text,'🙂[未知]<script>alert(1)</script>');
 assert.deepEqual(R.tokenize('[constructor][__proto__]',assets),[{text:'[constructor][__proto__]'}]);
});
test('all bundled expressions are actual local PNG files',()=>{
 for(const [name,file] of Object.entries(assets)){assert.match(file,/^emoticons\/[A-Za-z0-9_-]+\.png$/);const bytes=fs.readFileSync(path.join(__dirname,'../Resources/ui',file));assert.equal(bytes.subarray(0,8).toString('hex'),'89504e470d0a1a0a',name);}
});
test('complete withdrawal notices are hidden, while conversation about withdrawals and attachments survive',()=>{
 for(const text of ['小王撤回了一条消息','“某某”撤回了一条消息。','你撤回了一条消息','小王撤回了1条消息'])assert.equal(P.isSystemNotice({senderId:'u',senderName:'小王',text}),true,text);
 for(const text of ['为什么撤回了一条消息？','他说：小王撤回了一条消息','小王撤回了一条消息，我还没看见','这是讨论撤回消息的说明'])assert.equal(P.isSystemNotice({senderId:'u',senderName:'小王',text}),false,text);
 assert.equal(P.isSystemNotice({text:'小王撤回了一条消息',attachments:[{type:'image'}]}),false);
});

test('legacy SoftBank filename in the supplied screenshot resolves without changing its source token',()=>{assert.deepEqual(R.tokenize('[/ee9092.png]',assets),[{text:'[/ee9092.png]',emoji:'😂'}]);assert.deepEqual(R.tokenize('[/unknown.png]',assets),[{text:'[/unknown.png]'}]);});
