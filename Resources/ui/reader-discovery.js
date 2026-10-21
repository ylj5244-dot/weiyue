(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.ReaderDiscovery=api;})(typeof window!=='undefined'?window:globalThis,function(){
  'use strict';
  const types=['all','link','image','document','video'];
  function kinds(message){
    const found=new Set((message.attachments||[]).map(item=>item.type));
    if(/https?:\/\/[^\s<>]+/i.test(message.text||''))found.add('link');
    return types.slice(1).filter(type=>found.has(type));
  }
  function queryText(message){return [message.text||'',...(message.attachments||[]).flatMap(item=>[item.name||'',item.url||''])].join('\n').toLocaleLowerCase();}
  function isOwn(state,message){return !!(state&&message&&typeof state.accountId==='string'&&state.accountId.trim()&&message.accountId===state.accountId&&typeof message.senderId==='string'&&message.senderId.trim()===state.accountId.trim());}
  function followedIds(state){return [...new Set(((state&&state.settings&&state.settings.followedMembers)||[]).map(item=>item.senderId).filter(id=>typeof id==='string'&&id))];}
  return {types,kinds,queryText,isOwn,followedIds};
});
