const test=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const vm=require('node:vm');
const W=require('../Resources/ui/web-search.js');
const metadata=()=>({status:'success',query:'DeepSeek latest release',searchedAt:'2026-10-18T03:00:00.000Z',sources:[{id:'网页1',title:'Release notes',url:'https://example.com/releases#new',publishedAt:'2026-10-17T01:00:00.000Z',siteName:'Example',excerpt:'A verified release.'}]});
test('classic browser and CommonJS exports expose the same strict request helper',()=>{
  const sandbox={window:{},URL};vm.runInNewContext(fs.readFileSync(require.resolve('../Resources/ui/web-search.js'),'utf8'),sandbox);assert.equal(typeof sandbox.window.ReaderWebSearch.requestOptions,'function');
  assert.deepEqual(W.requestOptions({baseURL:'https://api.deepseek.com'},'Question'),{webSearchEnabled:false,webSearchQuery:''});
  assert.deepEqual(W.requestOptions({baseURL:'https://api.deepseek.com',webSearchEnabled:true},'  Latest news  '),{webSearchEnabled:true,webSearchQuery:'Latest news'});
  assert.equal(W.requestOptions({baseURL:'https://api.deepseek.com',webSearchEnabled:true},'Question',{enabled:false}).webSearchEnabled,false);
  assert.equal(W.requestOptions({baseURL:'https://example.com',webSearchEnabled:true},'Question').webSearchEnabled,false);
  for(const wrong of [1,'true',null,{}]){assert.throws(()=>W.requestOptions({baseURL:'https://api.deepseek.com',webSearchEnabled:wrong},'Q'));assert.throws(()=>W.requestOptions({},'Q',{enabled:wrong}));}
  const unicode=W.requestOptions({baseURL:'https://api.deepseek.com',webSearchEnabled:true},'😀'.repeat(100)+'end').webSearchQuery;
  assert.equal(unicode,'😀'.repeat(64));assert.equal(unicode.length,128);
});
test('search eligibility only accepts exact official HTTPS provider and supported base/completion paths',()=>{
  for(const url of ['https://api.deepseek.com','https://api.deepseek.com/','https://api.deepseek.com/v1','https://api.deepseek.com/v1/','https://api.deepseek.com/chat/completions','https://api.deepseek.com/v1/chat/completions','https://api.deepseek.com:443/v1'])assert.equal(W.supportedProvider(url),true,url);
  for(const url of ['http://api.deepseek.com','https://api.deepseek.com.evil.test','https://other.api.deepseek.com','https://user@api.deepseek.com','https://@api.deepseek.com','https://api.deepseek.com:8443','https://api.deepseek.com?key=x','https://api.deepseek.com?','https://api.deepseek.com#','https://api.deepseek.com/other','https://api.deepseek.com/other/../v1','https://api.deepseek.com./v1'])assert.equal(W.supportedProvider(url),false,url);
});
test('public source URL validation rejects private/local/reserved/obfuscated endpoints and unsafe schemes',()=>{
  for(const url of ['https://example.com/report#part','http://www.example.org/report?lang=zh','https://8.8.8.8/news','https://例子.中国/新闻'])assert.equal(typeof W.safeURL(url),'string',url);
  for(const url of ['javascript:alert(1)','file:///etc/passwd','data:text/plain,hello','https://user:pass@example.com','https://@example.com','https://localhost/','https://host.local/','https://thing.internal','https://router.lan','https://host.home','https://example.localhost.','https://127.0.0.1','https://127.1','https://2130706433','https://0x7f000001','https://0177.0.0.1','https://10.0.0.1','https://172.31.0.1','https://192.168.1.1','https://169.254.169.254','https://100.64.0.1','https://192.0.2.1','https://198.18.0.1','https://198.51.100.1','https://203.0.113.1','https://224.0.0.1','https://[::1]/','https://[2001:4860:4860::8888]/','https://internal/','https://example.com\\@localhost','https://example.com/\nsecret','https://example.com/'+'x'.repeat(8192)])assert.equal(W.safeURL(url),null,url);
});
test('metadata is independently cloned, bounded and never relabels unsupported or malformed source records',()=>{
  const input=metadata(),result=W.normalize(input);assert.deepEqual(result,input);result.sources[0].title='Changed';assert.equal(input.sources[0].title,'Release notes');
  const changes=[x=>x.status='done',x=>x.query='x'.repeat(129),x=>x.searchedAt='yesterday',x=>x.sources.push({...x.sources[0]}),x=>x.sources[0].id='网页7',x=>x.sources[0].url='http://127.0.0.1/',x=>x.sources[0].title='x'.repeat(501),x=>x.sources[0].siteName='x'.repeat(301),x=>x.sources[0].excerpt='x'.repeat(1201),x=>x.sources[0].publishedAt='2026-10-18',x=>x.sources[0].extra='untrusted',x=>x.error='x'.repeat(501),x=>x.extra=true,x=>x.status='empty',x=>x.sources=[]];
  for(const change of changes){const value=metadata();change(value);assert.throws(()=>W.validate(value));assert.equal(W.normalize(value),null);}
  assert.equal(W.normalize(undefined),null);
  assert.deepEqual(W.normalize({status:'failed',query:'q',searchedAt:input.searchedAt,sources:[],error:'Search failed'}).sources,[]);
  const missingDate=metadata();missingDate.sources[0].publishedAt=null;assert.equal(W.normalize(missingDate).sources[0].publishedAt,null);
  assert.match(W.sourceInstruction,/不可信|不是指令/);assert.match(W.sourceInstruction,/发布日期|检索时间/);
});

test('followups retain distinct historical source namespaces across fresh search and search off',()=>{
  const one={status:'success',query:'first',searchedAt:'2026-10-18T00:00:00Z',sources:[{id:'网页1',title:'First',url:'https://example.com/first',publishedAt:null,siteName:'Example',excerpt:'Old evidence'}]};
  const two={...one,query:'second',sources:[{...one.sources[0],title:'Second',url:'https://example.com/second'}]};
  const messages=[{role:'user',content:'First?'},{role:'assistant',content:'First [网页1]',webSearch:one},{role:'user',content:'Second?'},{role:'assistant',content:'Second [网页1] and [历史网页2-1]',webSearch:two},{role:'user',content:'Explain the older source'}];
  const history=W.historyMessages(messages);
  assert.match(history[1].content,/First \[历史网页2-1\]/);assert.match(history[1].content,/https:\/\/example.com\/first/);
  assert.match(history[3].content,/Second \[历史网页4-1\] and \[历史网页2-1\]/);assert.match(history[3].content,/https:\/\/example.com\/second/);
  assert.match(history[3].content,/不是本次检索/);assert.equal(history.at(-1).content,'Explain the older source');
  assert.equal(messages[1].content,'First [网页1]');assert.equal(messages[1].webSearch.sources[0].id,'网页1');
  assert.equal(W.requestOptions({baseURL:'https://api.deepseek.com',webSearchEnabled:false},'Explain the older source').webSearchEnabled,false);
});
