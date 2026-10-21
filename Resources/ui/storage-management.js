(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.ReaderStorage=api;})(typeof window!=='undefined'?window:globalThis,function(){
  'use strict';
  function preference(settings){
    const value=settings.autoCleanup;if(!value)return {enabled:false,retentionDays:3};
    if(typeof value.enabled!=='boolean'||!Number.isInteger(value.retentionDays)||value.retentionDays<1||value.retentionDays>4)throw new Error('请选择保留最近 1–4 天的记录。');
    return {enabled:value.enabled,retentionDays:value.retentionDays};
  }
  function due(settings,now=Date.now(),lastAttempt=0){
    let value;try{value=preference(settings);}catch(_){return false;}
    if(!value.enabled||now-lastAttempt<300000)return false;
    const saved=settings.autoCleanup||{},last=Date.parse(saved.lastRunAt),interval=saved.lastError?300000:3600000;
    return !Number.isFinite(last)||now-last>=interval;
  }
  function bytes(value){const n=Math.max(0,Number(value)||0);if(n<1024)return n+' B';if(n<1048576)return (n/1024).toFixed(1)+' KB';if(n<1073741824)return (n/1048576).toFixed(1)+' MB';return (n/1073741824).toFixed(2)+' GB';}
  return {preference,due,bytes};
});
