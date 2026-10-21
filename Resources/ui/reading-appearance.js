(function(root,factory){
  'use strict'; const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.ReaderReadingAppearance=api;
})(typeof window!=='undefined'?window:globalThis,function(){
  'use strict';
  const defaultFont='-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC","Hiragino Sans GB",sans-serif';
  const colors={background:['--bg'],panel:['--panel','--control'],sidebar:['--sidebar','--chrome','--inspector'],text:['--text'],secondary:['--secondary','--tertiary'],accent:['--blue','--blue-hover'],line:['--line','--control-edge'],soft:['--soft','--blue-light']};
  function density(value){
    return [null,{lineHeight:1.35,messageGap:0,groupGap:2},{lineHeight:1.5,messageGap:1,groupGap:4},{lineHeight:1.65,messageGap:2,groupGap:6},{lineHeight:1.85,messageGap:5,groupGap:10},{lineHeight:2.1,messageGap:9,groupGap:16}][Number.isInteger(value)&&value>=1&&value<=5?value:3];
  }
  function isLevel(value){return Number.isInteger(value)&&value>=1&&value<=5;}
  function consecutiveGap(value,readingDensity){
    // The 22px action lane and 2px body inset remain reserved at every level.
    // Follow preserves existing 1.0.8 density measurements and migrations.
    return isLevel(value)?[0,0,8,20,38,64][value]:density(readingDensity).messageGap;
  }
  function normalizePreferences(raw){
    const p=raw&&typeof raw==='object'?raw:{};
    return {density:isLevel(p.density)?p.density:3,consecutiveSpacing:isLevel(p.consecutiveSpacing)?p.consecutiveSpacing:'follow',skinId:typeof p.skinId==='string'?p.skinId:'default',fontChoice:typeof p.fontChoice==='string'?p.fontChoice:'system'};
  }
  function fontName(value){
    if(typeof value!=='string'||!value.trim()||value.length>120||/[\x00-\x1f\x7f"'\\;{}<>():,]/.test(value))throw new Error('字体名称无效。');
    return value;
  }
  function fontCSS(value){return value==='system'?defaultFont:'"'+fontName(value)+'",'+defaultFont;}
  function validateSkin(value){
    if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(key=>!['format','version','name','fontFamily','light','dark'].includes(key))||value.format!=='weiyue-skin'||value.version!==1||typeof value.name!=='string'||!value.name.trim()||value.name.length>80)throw new Error('不是有效的微阅皮肤文件。');
    const result={format:value.format,version:1,name:value.name};
    if(value.fontFamily!==undefined)result.fontFamily=fontName(value.fontFamily);
    for(const mode of ['light','dark']){
      const source=value[mode];if(!source||typeof source!=='object'||Array.isArray(source))throw new Error('缺少日间或夜间配色。');
      result[mode]={};for(const [key,color] of Object.entries(source)){if(!Object.hasOwn(colors,key)||typeof color!=='string'||!/^#[a-f0-9]{6}$/i.test(color))throw new Error('皮肤颜色必须使用受支持的字段和 #RRGGBB 格式。');result[mode][key]=color;}
    }
    return result;
  }
  function skinCatalog(raw){
    const builtInSkins=[{id:'default',name:'微阅原生'}],skins=[],seen=new Set(['default']);
    for(const item of Array.isArray(raw?.builtInSkins)?raw.builtInSkins:[]){
      try{const {id,...source}=item;if(['paper-green','claude-code'].includes(id)&&!seen.has(id)){builtInSkins.push({id,...validateSkin(source)});seen.add(id);}}catch(_){}
    }
    for(const item of Array.isArray(raw?.skins)?raw.skins:[]){
      try{const {id,...source}=item;if(/^[a-f0-9]{64}$/.test(id)&&!seen.has(id)){skins.push({id,...validateSkin(source)});seen.add(id);}}catch(_){}
    }
    return {builtInSkins,skins};
  }
  function accentInk(value){
    if(typeof value!=='string'||!/^#[a-f0-9]{6}$/i.test(value))return '#ffffff';
    const [r,g,b]=value.slice(1).match(/../g).map(pair=>parseInt(pair,16)/255).map(channel=>channel<=.04045?channel/12.92:((channel+.055)/1.055)**2.4);
    return r*.2126+g*.7152+b*.0722>.179?'#000000':'#ffffff';
  }
  function mount(options){
    const $=id=>document.getElementById(id),root=document.documentElement,dialog=$('reading-appearance-dialog');
    let data={preferences:normalizePreferences(),...skinCatalog(),fonts:[],systemFonts:[]},busy=false,face=null,generation=0;
    const message=(value,error=false)=>{const el=$('reading-appearance-status');el.textContent=value||'';el.classList.toggle('error',error);el.hidden=!value;};
    function render(){
      const p=data.preferences;
      dialog.querySelectorAll('[data-reading-density]').forEach(button=>{button.setAttribute('aria-pressed',String(Number(button.dataset.readingDensity)===p.density));});
      dialog.querySelectorAll('[data-consecutive-spacing]').forEach(button=>{button.setAttribute('aria-pressed',String(button.dataset.consecutiveSpacing===String(p.consecutiveSpacing)));});
      const labels=['','紧凑','偏紧','标准','舒展','宽松'];
      $('reading-spacing-status').textContent=p.consecutiveSpacing==='follow'?'当前跟随：'+labels[p.density]+'密度':'已独立设置：'+labels[p.consecutiveSpacing]+' · 额外间隔 '+consecutiveGap(p.consecutiveSpacing,p.density)+' px';
      const skin=$('reading-skin'),font=$('reading-font');skin.replaceChildren();
      const builtIns=document.createElement('optgroup');builtIns.label='内置皮肤';data.builtInSkins.forEach(item=>builtIns.append(new Option(item.name,item.id)));skin.append(builtIns);
      if(data.skins.length){const imported=document.createElement('optgroup');imported.label='已导入皮肤';data.skins.forEach(item=>imported.append(new Option(item.name,item.id)));skin.append(imported);}skin.value=p.skinId;
      font.replaceChildren(new Option('系统默认','system'));
      if(data.fonts.length){const group=document.createElement('optgroup');group.label='已导入字体';data.fonts.forEach(item=>group.append(new Option(item.family+' · '+item.name,'import:'+item.id)));font.append(group);}
      if(data.systemFonts.length){const group=document.createElement('optgroup');group.label='本机字体';data.systemFonts.forEach(name=>group.append(new Option(name,'family:'+name)));font.append(group);}
      font.value=p.fontChoice;
      dialog.querySelectorAll('button,select').forEach(control=>{control.disabled=busy;});
      $('open-reading-appearance').disabled=busy;
    }
    function applyColors(){
      Object.values(colors).flat().forEach(name=>root.style.removeProperty(name));
      root.style.removeProperty('--reading-accent-ink');
      const skin=[...data.builtInSkins,...data.skins].find(item=>item.id!=='default'&&item.id===data.preferences.skinId);
      root.classList.toggle('custom-reading-skin',!!skin);
      if(skin){const mode=root.dataset.colorScheme==='dark'?'dark':'light';for(const [key,color] of Object.entries(skin[mode]))colors[key].forEach(name=>root.style.setProperty(name,color));if(skin[mode].accent)root.style.setProperty('--reading-accent-ink',accentInk(skin[mode].accent));}
      root.dataset.readingSkin=skin?skin.id:'default';
    }
    async function restore(raw){
      if(!raw||!raw.preferences)return;
      const token=++generation,p=normalizePreferences(raw.preferences);
      const next={preferences:p,...skinCatalog(raw),fonts:Array.isArray(raw.fonts)?raw.fonts:[],systemFonts:Array.isArray(raw.systemFonts)?raw.systemFonts.filter(name=>{try{return !!fontName(name);}catch(_){return false;}}):[]};
      if(![...next.builtInSkins,...next.skins].some(item=>item.id===p.skinId))p.skinId='default';
      let family='system',newFace=null,warning=raw.warning||'';
      try{
        if(p.fontChoice.startsWith('family:'))family=fontName(p.fontChoice.slice(7));
        if(p.fontChoice.startsWith('import:')){
          const font=raw.fontData,id=p.fontChoice.slice(7);
          if(!font||font.id!==id||!/^[a-f0-9]{64}$/.test(id)||typeof font.base64!=='string'||font.base64.length>48*1024*1024)throw new Error('字体文件未能载入。');
          const bytes=Uint8Array.from(atob(font.base64),char=>char.charCodeAt(0));
          family='WeiyueImported_'+id;newFace=new FontFace(family,bytes);await newFace.load();
        }
      }catch(error){family='system';newFace=null;warning='字体显示暂用系统默认：'+error.message;}
      if(token!==generation)return;
      const anchor=options.beforeApply?options.beforeApply():null;
      if(newFace)document.fonts.add(newFace);if(face)document.fonts.delete(face);face=newFace;
      data=next;const level=density(next.preferences.density);
      root.style.setProperty('--reading-line-height',String(level.lineHeight));root.style.setProperty('--reading-message-gap',level.messageGap+'px');root.style.setProperty('--reading-consecutive-gap',consecutiveGap(p.consecutiveSpacing,p.density)+'px');root.style.setProperty('--reading-group-gap',level.groupGap+'px');root.style.setProperty('--reading-font',fontCSS(family));
      root.dataset.readingDensity=String(p.density);root.dataset.readingConsecutiveSpacing=String(p.consecutiveSpacing);applyColors();render();message(warning,!!warning);
      if(options.afterApply)options.afterApply(anchor);
      return {warning};
    }
    async function perform(action,payload,success){
      if(busy)return;
      if(options.canUse&&!options.canUse()){message('请在微阅 Mac 应用中使用阅读与皮肤设置。',true);return;}
      busy=true;message('正在处理…');render();
      try{const result=await options.rpc(action,payload||{});if(!result.cancelled){const applied=result.preferences?await restore(result):null;if(!result.warning&&!applied?.warning)message(success||'已保存，重新打开后仍会生效。');}else message('已取消');}
      catch(error){message(error.message||String(error),true);}
      finally{busy=false;render();}
    }
    function save(change){return perform('saveReadingAppearance',{preferences:{...data.preferences,...change}});}
    dialog.querySelectorAll('[data-reading-density]').forEach(button=>button.addEventListener('click',()=>save({density:Number(button.dataset.readingDensity)})));
    dialog.querySelectorAll('[data-consecutive-spacing]').forEach(button=>button.addEventListener('click',()=>save({consecutiveSpacing:button.dataset.consecutiveSpacing==='follow'?'follow':Number(button.dataset.consecutiveSpacing)})));
    $('reading-skin').addEventListener('change',()=>save({skinId:$('reading-skin').value}));
    $('reading-font').addEventListener('change',()=>save({fontChoice:$('reading-font').value}));
    $('import-reading-skin').addEventListener('click',()=>perform('importReadingSkin',{},'皮肤已导入并应用。'));
    $('import-reading-font').addEventListener('click',()=>perform('importReadingFont',{},'字体已导入并应用，仅在微阅中使用。'));
    $('export-reading-sample').addEventListener('click',()=>perform('exportReadingSkinSample',{},'皮肤样例已导出。'));
    $('reset-reading-appearance').addEventListener('click',()=>save({density:3,consecutiveSpacing:'follow',skinId:'default',fontChoice:'system'}));
    $('close-reading-appearance').addEventListener('click',()=>{if(!busy)dialog.close();});
    $('done-reading-appearance').addEventListener('click',()=>{if(!busy)dialog.close();});
    dialog.addEventListener('cancel',event=>{if(busy)event.preventDefault();});
    dialog.addEventListener('close',()=>{if(options.onDialogChange)options.onDialogChange();});
    new MutationObserver(applyColors).observe(root,{attributes:true,attributeFilter:['data-color-scheme']});
    render();
    return {restore,open(){dialog.showModal();render();if(options.onDialogChange)options.onDialogChange();},isBusy:()=>busy};
  }
  return {density,consecutiveGap,normalizePreferences,skinCatalog,accentInk,validateSkin,fontCSS,defaultFont,mount};
});
