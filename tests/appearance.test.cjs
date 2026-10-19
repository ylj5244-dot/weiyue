'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const policy=require('../Resources/ui/appearance.js');
test('explicit appearance overrides either system mode and invalid values default to system',()=>{
  for(const dark of [true,false]){assert.equal(policy.effective('light',dark),'light');assert.equal(policy.effective('dark',dark),'dark');assert.equal(policy.effective('system',dark),dark?'dark':'light');}
  for(const value of [undefined,null,'night','auto',true,{},''])assert.equal(policy.normalize(value),'system');
});
test('all historical dark CSS blocks use one explicit resolved appearance',()=>{
  const css=fs.readFileSync(require.resolve('../Resources/ui/app.css'),'utf8');
  assert.ok(!css.includes('prefers-color-scheme'),'OS dark rules must not override explicit light');
  for(const selector of ['.context-warning','.message-card.in-ai-context:not(.selected)','.collection-delete','.toolbar'])assert.ok(css.includes(':where(:root[data-color-scheme="dark"]) '+selector),selector);
  assert.match(css,/:root\[data-color-scheme="light"\]\s*\{ color-scheme:light;/);
  assert.match(css,/:root\[data-color-scheme="dark"\]\s*\{ color-scheme:dark;/);
});
test('real appearance controller restores, remembers choice and follows system changes only in system mode',()=>{
  const source=fs.readFileSync(require.resolve('../Resources/ui/appearance.js'),'utf8');
  const listeners={},events=[],stored=new Map(),root={dataset:{}},select={value:'',title:'',addEventListener(type,fn){listeners[type]=fn;}},symbol={setAttribute(name,value){this[name]=value;}};
  const media={matches:true,addEventListener(type,fn){this.change=fn;}};
  const window={matchMedia(){return media;},localStorage:{getItem:key=>stored.get(key),setItem:(key,value)=>stored.set(key,value)},dispatchEvent:event=>events.push(event)};
  const document={documentElement:root,readyState:'complete',getElementById:id=>id==='appearance-select'?select:id==='appearance-symbol'?symbol:null};
  vm.runInNewContext(source,{window,document,CustomEvent:class{constructor(type,options){this.type=type;this.detail=options.detail;}}});
  assert.equal(root.dataset.colorScheme,'dark');assert.equal(select.value,'system');
  select.value='light';listeners.change();assert.equal(root.dataset.colorScheme,'light');assert.equal(events[0].detail.appearance,'light');assert.equal(stored.get('weiyue.appearance.v1'),'light');
  media.matches=false;media.change();media.matches=true;media.change();assert.equal(root.dataset.colorScheme,'light');
  window.ReaderAppearance.restore('dark');assert.equal(select.value,'dark');assert.equal(symbol.href,'#i-moon');assert.equal(events.length,1,'Restoring native preference must not create a save loop');
  window.ReaderAppearance.restore('system');media.matches=false;media.change();assert.equal(root.dataset.colorScheme,'light');media.matches=true;media.change();assert.equal(root.dataset.colorScheme,'dark');
});
