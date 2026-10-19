const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const policyPath = path.join(__dirname, '../Resources/ui/ai-context.js');
const C = fs.existsSync(policyPath) ? require(policyPath) : {};
const M = require('../Resources/ui/model.js');
const message = { accountId: 'a', id: '1', groupId: 'g', senderId: 's', senderName: 'Alice', sentAt: '2026-10-18T00:00:00.000Z', text: 'Please read the report.', attachments: [{type:'document', name:'report.pdf'}, {type:'image', name:'private.png'}] };
const extraction = {text:'Revenue increased by 12%.', name:'report.pdf', kind:'document', method:'PDF text', pageCount:40, processedPages:20, truncated:true, warnings:['仅处理前 20 页']};
test('document AI context contains extracted body and explicit partial-read warnings without changing original', () => {
  assert.equal(typeof C.withExtraction, 'function');
  const original = JSON.stringify(message); const snapshot = C.withExtraction(message, 0, extraction);
  const result = C.contextText([snapshot], ()=>'Research', x=>x);
  assert.match(result, /Revenue increased by 12%/); assert.match(result, /仅处理前 20 页/); assert.match(result, /20.*40/); assert.match(result, /private.png.*未读取/);
  assert.equal(JSON.stringify(message), original); assert.equal(snapshot.text, message.text);
});
test('attachment-specific action excludes other attachments and unrelated original text', () => {
  assert.equal(typeof C.withExtraction, 'function');
  const snapshot = C.withExtraction(message, 0, extraction, true);
  const result = C.contextText([snapshot], ()=>'Research', x=>x);
  assert.match(result, /Revenue increased/); assert.doesNotMatch(result, /private.png|Please read/); assert.equal(snapshot.text, message.text);
});
test('text translation includes only selected chat text and never extracts files', () => {
  assert.equal(typeof C.textSnapshots, 'function');
  const snapshots=C.textSnapshots([message]); const result=C.contextText(snapshots, ()=>'Research',x=>x);
  assert.match(result, /Please read the report/); assert.doesNotMatch(result, /report.pdf|private.png|Revenue increased/);
});
test('metadata only context explicitly says unread and never claims content', () => {
  assert.equal(typeof C.contextText, 'function');
  const result=C.contextText([message],()=> 'Research', x=>x);
  assert.match(result,/report.pdf.*未读取/); assert.doesNotMatch(result,/Revenue increased/);
});
test('empty extraction fails and does not mark a file as read', () => {
  assert.equal(typeof C.withExtraction, 'function');
  assert.throws(()=> C.withExtraction(message,0,{...extraction,text:'  '}), /文字/);
});
test('imported document and context collection survive model validation and restore', () => {
  assert.equal(typeof C.importedMessage, 'function');
  const imported=C.importedMessage('a', {...extraction,id:'local-1',localPath:'/tmp/a/report.pdf'});
  const state=M.createState('a'); const collection=C.collection('a',[imported],'Document study','2026-10-18T00:00:00.000Z'); state.collections.push(collection);
  const restored=M.normalizeState(state);
  assert.equal(restored.collections[0].messages[0].extractedContents[0].text, extraction.text);
  assert.equal(restored.collections[0].messages[0].localPath, '/tmp/a/report.pdf');
});
test('oversize AI reference context fails explicitly instead of silently truncating', () => {
  assert.equal(typeof C.requestMessages, 'function');
  const large={...message,text:'x'.repeat(160001),attachments:[]};
  assert.throws(()=>C.requestMessages([large],[],()=> 'Research',x=>x), /过长|减少/);
});
test('AI request includes only provided sources and guards against instructions in OCR or documents', () => {
  assert.equal(typeof C.requestMessages, 'function');
  const snapshot=C.withExtraction(message,0,extraction,true);
  const payload=C.requestMessages([snapshot],[{role:'user',content:'Translate'}],()=> 'Research',x=>x);
  assert.match(payload[0].content,/不可信/); assert.match(payload[0].content,/OCR/); assert.match(payload[1].content,/Revenue increased/); assert.doesNotMatch(JSON.stringify(payload),/private.png/);
});
test('reading two individually selected files from one message retains both selected files only', () => {
  assert.equal(typeof C.mergeSnapshots, 'function');
  const source={...message, attachments:[...message.attachments,{type:'document',name:'unselected-secret.pdf'}]};
  const first=C.withExtraction(source,0,extraction,true);
  const second=C.withExtraction(source,1,{...extraction,name:'private.png',kind:'image',text:'Second selected text'},true);
  const merged=C.mergeSnapshots(first,second); const result=C.contextText([merged],()=> 'Research',x=>x);
  assert.match(result,/Revenue increased/); assert.match(result,/Second selected text/); assert.doesNotMatch(result,/unselected-secret|Please read/);
});
test('invalid saved extracted fields are unread metadata instead of crashing or claiming read', () => {
  const snapshot={...message,extractedContents:[{attachmentIndex:0,text:'malformed extraction',kind:'unsupported',warnings:null}]};
  assert.match(C.contextText([snapshot],()=> 'Research',x=>x),/report.pdf.*未读取/);
});
test('attachment refresh cannot reuse previously extracted text by array index', () => {
  const previous=C.withExtraction(message,0,extraction);
  const updated={...message,attachments:[{type:'document',name:'new.pdf',url:'https://example.test/new.pdf'},message.attachments[1]]};
  const merged=C.mergeSnapshots(previous,updated); const result=C.contextText([merged],()=> 'Research',x=>x);
  assert.doesNotMatch(result,/Revenue increased/); assert.match(result,/new.pdf.*未读取/);
});
test('legacy immutable snapshots remain readable but do not transfer extracted text to changed files', () => {
  const legacy=C.withExtraction(message,0,extraction); delete legacy.extractedContents[0].sourceFingerprint;
  assert.match(C.contextText([legacy],()=> 'Research',x=>x),/Revenue increased/);
  const updated={...message,attachments:[{...message.attachments[0],url:'https://example.test/replaced'},message.attachments[1]]};
  assert.doesNotMatch(C.contextText([C.mergeSnapshots(legacy,updated)],()=> 'Research',x=>x),/Revenue increased/);
});
test('extraction reference sends exact selected source identity and stores source binding', () => {
  assert.equal(typeof C.expectedAttachment,'function');
  const source={...message,attachments:[{type:'document',name:'report.pdf',url:'https://example.test/report'}]};
  assert.deepEqual(C.expectedAttachment(source,0),{url:'https://example.test/report',type:'document',name:'report.pdf'});
  const snapshot=C.withExtraction(source,0,extraction);
  assert.equal(typeof snapshot.extractedContents[0].sourceFingerprint,'string');
  snapshot.attachments[0].url='https://example.test/another';
  assert.doesNotMatch(C.contextText([snapshot],()=> 'Research',x=>x),/Revenue increased/);
});

test('direct image metadata persists with safe identity, no OCR or base64, and only selected files go outbound', () => {
  const original={accountId:'a',groupId:'g',id:'1',senderId:'u',senderName:'User',sentAt:'2026-10-18T00:00:00Z',text:'caption',attachments:[{type:'image',name:'one.png',url:'https://example.com/one.png'},{type:'image',name:'two.png',url:'https://example.com/two.png'}]};
  const prepared=C.withExtraction(original,0,{direct:true,mode:'direct-image',name:'one.png',kind:'image',modelFile:{mode:'direct-image',name:'one.png',mimeType:'image/png',warnings:[],data:'must-not-persist'}},true);
  assert.equal(C.selectedExtractions(prepared).length,0);
  assert.equal(C.selectedModelFiles(prepared).length,1);
  assert.equal(C.modelSources([prepared]).length,1);
  assert.equal(C.modelSources([prepared])[0].expectedAttachment.url,'https://example.com/one.png');
  assert.ok(!JSON.stringify(prepared).includes('must-not-persist'));
  assert.ok(C.contextText([prepared]).includes('原图或文件随本次请求提供'));
  assert.equal(C.modelSources(C.textSnapshots([prepared])).length,0);
  const changed=JSON.parse(JSON.stringify(prepared));changed.attachments[0].url='https://example.com/new.png';
  assert.equal(C.modelSources([changed]).length,0);
});

test('direct image request discloses the selected first frame and its warnings only', () => {
  const original={...message,attachments:[{type:'image',name:'selected.tiff',url:'https://example.test/selected.tiff'},{type:'document',name:'unselected.pdf',url:'https://example.test/unselected.pdf'}]};
  const other=C.withExtraction(original,1,{direct:true,mode:'direct-pdf',name:'unselected.pdf',kind:'document',pageCount:2,processedPages:2,warnings:['UNSELECTED READING WARNING']},true);
  const prepared=C.withExtraction(other,0,{direct:true,modelFile:{mode:'direct-image',name:'selected.tiff',pageCount:3,processedPages:1,warnings:['此图片有 3 帧/页，直接读图仅发送第一帧。','图片长边会缩至 2400 像素。']}},true);
  const payload=C.requestMessages([prepared],[{role:'user',content:'解读所选图片'}],()=> 'Research',x=>x);
  const reference=payload[1].content;
  assert.match(reference,/本次提供 1\/3 帧\/页/);
  assert.match(reference,/读取提示：此图片有 3 帧\/页，直接读图仅发送第一帧。；图片长边会缩至 2400 像素。/);
  assert.doesNotMatch(reference,/unselected\.pdf|UNSELECTED READING WARNING|Please read the report/);
  assert.equal(C.modelSources([prepared]).length,1);
  assert.equal(C.modelSources([prepared])[0].attachmentIndex,0);
});

test('direct PDF request carries prepared page counts and reading warnings in both direct modes', () => {
  for (const mode of ['direct-pdf','pdf-pages']) {
    const prepared=C.withExtraction(message,0,{direct:true,mode,name:'report.pdf',kind:'document',pageCount:3,processedPages:3,warnings:['只依据实际提供的页面读取。']},true);
    const reference=C.requestMessages([prepared],[],()=> 'Research',x=>x)[1].content;
    assert.match(reference,/本次提供 3\/3 页/);
    assert.match(reference,/读取提示：只依据实际提供的页面读取。/);
    assert.doesNotMatch(reference,/private\.png|帧\/页/);
  }
});

test('legacy direct metadata never invents a processed page count', () => {
  const summary=C.modelFileSummary({mode:'direct-pdf',pageCount:3});
  assert.match(summary,/共 3 页/);
  assert.match(summary,/本次提供数量未记录/);
  assert.doesNotMatch(summary,/[03]\/3 页/);
});

test('direct PDF local import preserves reference through normalized state without persisting bytes', () => {
  const imported=C.importedMessage('a',{id:'import-test',localPath:'/test/owned.pdf',direct:true,mode:'pdf-pages',name:'owned.pdf',kind:'document',pageCount:3,processedPages:3,warnings:[]});
  assert.equal(C.selectedModelFiles(imported)[0].pageCount,3);
  assert.deepEqual(C.modelSources([imported]),[{localPath:'/test/owned.pdf',id:'import-test',name:'owned.pdf'}]);
  const text=C.withExtraction(imported,0,{text:'local words',kind:'document',name:'owned.pdf'},true);
  const merged=C.mergeSnapshots(imported,text);
  assert.equal(C.modelSources([merged]).length,0);
  assert.equal(C.selectedExtractions(merged)[0].text,'local words');
});

test('every request carries current enabled preferences with explicit priority and preserves source boundaries', () => {
  const P = require('../Resources/ui/preferences.js'), library = P.defaults();
  library.entries = [
    {id:'style',title:'Writing',category:'writing',content:'Use complete paragraphs.',enabled:true},
    {id:'disabled',title:'Old',category:'format',content:'DISABLED_FORMAT',enabled:false}
  ];
  library.quickPrompts.push({id:'secret-prompt',title:'Quick',prompt:'UNSENT_QUICK_PROMPT',enabled:true});
  const history = [{role:'user',content:'For this answer only, give a short list.'}];
  let messages = C.requestMessages([message], history, () => 'Group', x => x, {preferences:library,temporary:'Use a table for this discussion.'});
  assert.match(messages[0].content,/Use complete paragraphs/);
  assert.match(messages[0].content,/Use a table/);
  assert.match(messages[0].content,/最新明确要求 > 当前讨论临时要求 > 长期偏好/);
  assert.match(messages[0].content,/不可信/);
  assert.doesNotMatch(messages[0].content,/DISABLED_FORMAT|UNSENT_QUICK_PROMPT/);
  assert.deepEqual(messages.at(-1),history[0]);
  library.entries[0].content = 'Use a neutral tone.';
  messages = C.requestMessages([],history,undefined,undefined,{preferences:library,temporary:''});
  assert.match(messages[0].content,/Use a neutral tone/);
  assert.doesNotMatch(messages[0].content,/Use complete paragraphs|Use a table/);
  library.entries=[];
  const empty = C.requestMessages([],history,undefined,undefined,{preferences:library,temporary:''});
  assert.deepEqual(empty,C.requestMessages([],history));
});
