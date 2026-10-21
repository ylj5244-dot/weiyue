(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.ReaderContentPreview=api;})(typeof window!=='undefined'?window:globalThis,function(){
  'use strict';
  function title(attachment,message){
    const name=String(attachment.name||'').trim(),body=String(message.text||'').trim();
    if(name&&!/^(附件|链接|文档|文件|网页)$/.test(name))return name;
    if(attachment.type==='document'&&body.length<240&&/\.(pdf|docx?|xlsx?|pptx?|txt|md|rtf|csv)(\s|$)/i.test(body))return body;
    return attachment.type==='link' ? attachment.url||name||'网页链接' : name||'文档';
  }
  function redundantBody(message){
    const all=message.attachments||[],body=String(message.text||'').trim();
    return all.length===1&&['link','document'].includes(all[0].type)&&(!body||body===title(all[0],message)||body===all[0].url);
  }
  return {title,redundantBody};
});
