'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const R=require('../Resources/ui/reading-appearance.js');
test('five density levels change both text leading and message spacing; standard preserves v107',()=>{
 const values=[1,2,3,4,5].map(R.density);
 assert.deepEqual(values[2],{lineHeight:1.65,messageGap:2,groupGap:6});
 for(let i=1;i<5;i++){assert.ok(values[i].lineHeight>values[i-1].lineHeight);assert.ok(values[i].messageGap>values[i-1].messageGap);}
 for(const value of [null,0,6,'5',true])assert.deepEqual(R.density(value),values[2]);
});
test('consecutive spacing follows legacy density until explicitly chosen and reserves the action lane',()=>{
 assert.equal(typeof R.consecutiveGap,'function','consecutive spacing control is available');
 assert.deepEqual([1,2,3,4,5].map(level=>R.consecutiveGap('follow',level)),[0,1,2,5,9]);
 assert.deepEqual([1,2,3,4,5].map(level=>R.consecutiveGap(level,3)),[0,16,40,80,144]);
 assert.equal(R.consecutiveGap(5,1),R.consecutiveGap(5,5),'independent spacing survives density changes');
 for(const value of [undefined,null,'5',true,0,6])assert.equal(R.consecutiveGap(value,3),2);
});
test('legacy reading preferences migrate without changing the chosen density, skin or font',()=>{
 assert.equal(typeof R.normalizePreferences,'function','preference migration is available');
 const old={density:5,skinId:'a'.repeat(64),fontChoice:'family:Arial'};
 assert.deepEqual(R.normalizePreferences(old),{...old,consecutiveSpacing:'follow'});
 for(const consecutiveSpacing of ['follow',1,2,3,4,5])assert.equal(R.normalizePreferences({...old,consecutiveSpacing}).consecutiveSpacing,consecutiveSpacing);
 for(const consecutiveSpacing of [undefined,null,true,0,6,1.5,'2'])assert.equal(R.normalizePreferences({...old,consecutiveSpacing}).consecutiveSpacing,'follow');
 assert.equal(R.normalizePreferences({fontChoice:null}).fontChoice,'system');
});
test('built-in skin IDs and imported hashes stay distinct while rejecting unknown built-ins',()=>{
 assert.equal(typeof R.skinCatalog,'function','skin catalog accepts native built-ins');
 const sample={format:'weiyue-skin',version:1,name:'纸页 · 青绿',light:{panel:'#fffdf6'},dark:{panel:'#222f28'}};
 const raw={builtInSkins:[{id:'default',name:'微阅原生'},{id:'paper-green',...sample},{id:'claude-code',...sample,name:'Claude Code 风格'},{id:'unknown',...sample}],skins:[{id:'a'.repeat(64),...sample},{id:'paper-green',...sample}]};
 const catalog=R.skinCatalog(raw);
 assert.deepEqual(catalog.builtInSkins.map(skin=>skin.id),['default','paper-green','claude-code']);
 assert.deepEqual(catalog.skins.map(skin=>skin.id),['a'.repeat(64)]);
 assert.equal(catalog.skins[0].name,catalog.builtInSkins[1].name,'same labels do not merge different IDs');
 assert.deepEqual(R.skinCatalog({}).builtInSkins,[{id:'default',name:'微阅原生'}],'old snapshots retain the original skin');
});
test('skin schema accepts color tokens and installed font names but not executable CSS or URLs',()=>{
 const skin={format:'weiyue-skin',version:1,name:'纸页',fontFamily:'PingFang SC',light:{panel:'#ffffff',accent:'#008866'},dark:{panel:'#202020'}};
 assert.deepEqual(R.validateSkin(skin),skin);
 for(const change of [{format:'other'},{version:2},{light:{panel:'url(https://bad.invalid)'}},{css:'body{}'},{fontFamily:'x; url(https://bad.invalid)'},{light:{unknown:'#ffffff'}}])assert.throws(()=>R.validateSkin({...skin,...change}));
});
test('font CSS is a quoted family with standard fallback, never a raw stylesheet',()=>{
 assert.equal(R.fontCSS('system'),R.defaultFont);
 assert.ok(R.fontCSS('思源宋体 CN').startsWith('"思源宋体 CN",'));
 assert.throws(()=>R.fontCSS('bad";color:red'));
});
test('colored action buttons keep readable text for light and dark skin accents',()=>{
 assert.equal(typeof R.accentInk,'function','skin action text derives from its fill');
 const luminance=hex=>{const values=hex.match(/[a-f0-9]{2}/gi).map(pair=>parseInt(pair,16)/255).map(v=>v<=0.04045?v/12.92:((v+0.055)/1.055)**2.4);return values[0]*.2126+values[1]*.7152+values[2]*.0722;};
 for(const accent of ['#277860','#79c9a3','#b55335','#d98b69','#ffffff','#000000']){
   const levels=[luminance(accent),luminance(R.accentInk(accent))].sort((a,b)=>a-b);
   assert.ok((levels[1]+.05)/(levels[0]+.05)>=4.5,'action text contrast for '+accent);
 }
});
test('both new skins provide three visibly different record backgrounds with readable day and night text',()=>{
 const css=require('node:fs').readFileSync(require.resolve('../Resources/ui/reading-appearance.css'),'utf8');
 const rules=[...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)];
 const channels=hex=>hex.slice(1).match(/../g).map(pair=>parseInt(pair,16));
 const luminance=hex=>{const [r,g,b]=channels(hex).map(v=>v/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4);return r*.2126+g*.7152+b*.0722;};
 for(const [skin,inks] of [['paper-green',{light:'#263a32',dark:'#e0e9dd'}],['claude-code',{light:'#302b27',dark:'#eee6db'}]]){
   for(const mode of ['light','dark']){
     const selector=':root[data-reading-skin="'+skin+'"]'+(mode==='dark'?'[data-color-scheme="dark"]':'');
     const rule=rules.find(rule=>rule[1].trim().endsWith(selector));
     assert.ok(rule,'record palette exists for '+skin+' '+mode);
     const colors=[...rule[2].matchAll(/--reading-record-[012]\s*:\s*(#[a-f0-9]{6})/gi)].map(match=>match[1]);
     assert.equal(colors.length,3);assert.equal(new Set(colors).size,3);
     for(let i=0;i<3;i++){
       const a=channels(colors[i]),b=channels(colors[(i+1)%3]);
       assert.ok(Math.hypot(...a.map((value,index)=>value-b[index]))>=12,'adjacent backgrounds differ visibly');
       const levels=[luminance(colors[i]),luminance(inks[mode])].sort((a,b)=>a-b);
       assert.ok((levels[1]+.05)/(levels[0]+.05)>=7,'body contrast '+skin+' '+mode+' '+i);
     }
   }
 }
});
