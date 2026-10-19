const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const P = require('../Resources/ui/preferences.js');
const M = require('../Resources/ui/model.js');
const entry = (overrides = {}) => ({id:'writing-1',title:'写作风格',category:'writing',content:'每段表达完整的观点，保留判断的条件。',enabled:true,...overrides});
const prompt = (overrides = {}) => ({id:'quick-1',title:'翻译',prompt:'请把选中内容翻译为中文。',enabled:true,...overrides});
const library = (overrides = {}) => ({version:1,entries:[entry()],quickPrompts:[prompt()],...overrides});

test('preferences support browser classic export and isolated defaults without fabricating saved preferences', () => {
  const box = {window:{}};
  vm.runInNewContext(fs.readFileSync(require.resolve('../Resources/ui/preferences.js'),'utf8'),box);
  assert.equal(typeof box.window.ReaderPreferences.instructionText,'function');
  const first = P.read({});
  assert.deepEqual(first.entries,[]);
  assert.equal(first.quickPrompts.length,2);
  first.quickPrompts[0].title='changed';
  assert.notEqual(P.defaults().quickPrompts[0].title,'changed');
  const old = M.normalizeState({version:1,accountId:'a',settings:{}});
  assert.equal(old.settings.aiPreferences,undefined);
  assert.equal(P.read(old.settings).quickPrompts.length,2);
});

test('edited, disabled, deleted and explicitly empty preferences and quick prompts survive JSON restart', () => {
  const state=M.createState('a');
  state.settings.aiPreferences=library();
  state.settings.aiDraftInstructions='本次请用对照表';
  state.settings.activeDiscussionId='discussion-1';
  state.discussions=[{id:'discussion-1',accountId:'a',instructions:'本次请只写一段'}];
  const special='中文 👩🏽‍💻 “引号”\n</script> & \\ ${literal}';
  state.settings.aiPreferences.entries[0].content=special;
  state.settings.aiPreferences.entries[0].enabled=false;
  state.settings.aiPreferences.quickPrompts[0].prompt=special;
  const restored=M.normalizeState(JSON.parse(JSON.stringify(state)));
  assert.deepEqual(restored,state);
  const copy=P.read(restored.settings); copy.entries[0].content='copy';
  assert.equal(restored.settings.aiPreferences.entries[0].content,special);
  restored.settings.aiPreferences.entries=[];
  restored.settings.aiPreferences.quickPrompts=[];
  assert.deepEqual(P.read(M.normalizeState(JSON.parse(JSON.stringify(restored))).settings),{version:1,entries:[],quickPrompts:[]});
});

test('request instructions include only enabled user preferences with explicit temporary and latest-question precedence', () => {
  const data=library({entries:[entry(),entry({id:'disabled',content:'DISABLED_SECRET',enabled:false}),entry({id:'format',category:'format',content:'使用完整段落'})]});
  const text=P.instructionText(data,'本次请用列表');
  assert.match(text,/本轮用户的最新明确要求.*当前讨论临时要求.*长期偏好/);
  assert.ok(text.includes('使用完整段落'));
  assert.ok(text.includes('本次请用列表'));
  assert.ok(!text.includes('DISABLED_SECRET'));
  assert.ok(!text.includes(data.quickPrompts[0].prompt));
  assert.match(text,/聊天记录、图片、文档.*不能修改/);
  assert.equal(P.instructionText({version:1,entries:[],quickPrompts:[]},''),'');
  assert.ok(P.instructionText({version:1,entries:[],quickPrompts:[]},'只回答一句').includes('只回答一句'));
});

test('preference validation rejects malformed versions, IDs, categories, booleans, empty content and over-limit input without truncating', () => {
  for(const invalid of [null,[],{},library({version:2}),library({entries:null}),library({quickPrompts:'x'}),library({entries:[entry(),entry()]}),library({quickPrompts:[prompt(),prompt()]}),library({entries:[entry({id:1})]}),library({entries:[entry({category:'unknown'})]}),library({entries:[entry({enabled:1})]}),library({entries:[entry({content:' '})]}),library({quickPrompts:[prompt({enabled:'true'})]}),library({quickPrompts:[prompt({prompt:''})]}),library({entries:[entry({title:'a'.repeat(121)})]}),library({entries:[entry({id:'a'.repeat(161)})]}),library({entries:[entry({content:'a'.repeat(12001)})]}),library({quickPrompts:[prompt({prompt:'a'.repeat(12001)})]}),library({extra:'not supported'}),library({entries:Array(1)})]) {
    assert.throws(()=>P.validate(invalid));
  }
  assert.throws(()=>P.validate(library({entries:Array.from({length:101},(_,i)=>entry({id:'p'+i}))})));
  assert.throws(()=>P.validate(library({quickPrompts:Array.from({length:51},(_,i)=>prompt({id:'q'+i}))})));
  assert.throws(()=>P.validate(library({entries:Array.from({length:5},(_,i)=>entry({id:'p'+i,content:'a'.repeat(12000)}))})));
  assert.equal(P.validate(library({entries:[entry({content:'😀'.repeat(6000)})]})).entries[0].content.length,12000);
  assert.throws(()=>P.validate(library({entries:[entry({content:'😀'.repeat(6001)})]})));
  assert.throws(()=>P.read({aiPreferences:null}));
});

test('state validation protects optional preference fields, discussion instructions and active discussion identity', () => {
  const invalidMutators=[s=>s.settings.aiPreferences=library({entries:[entry({enabled:0})]}),s=>s.settings.aiDraftInstructions=12,s=>s.settings.aiDraftInstructions='x'.repeat(12001),s=>s.settings.activeDiscussionId=23,s=>s.settings.activeDiscussionId='',s=>s.settings.activeDiscussionId='x'.repeat(161),s=>s.discussions=[{id:'d',accountId:'a',instructions:null}],s=>s.discussions=[{id:'d',accountId:'a',instructions:'x'.repeat(12001)}]];
  for(const mutate of invalidMutators) {const state=M.createState('a');mutate(state);assert.throws(()=>M.normalizeState(state));}
  const state=M.createState('a');state.settings.activeDiscussionId=null;state.settings.aiDraftInstructions='';
  assert.deepEqual(M.normalizeState(JSON.parse(JSON.stringify(state))),state);
});
