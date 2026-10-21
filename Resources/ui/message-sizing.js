(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.ReaderMessageSizing=api;})(typeof window!=='undefined'?window:globalThis,function(){
  'use strict';
  // One width for a whole consecutive speaker group keeps its joined edges aligned.
  function groupWidths(messages,speakers,measure){
    const widths=new Array(messages.length);let start=0,width=0;
    for(let index=0;index<messages.length;index++){
      if(!speakers[index].continuation){for(let prior=start;prior<index;prior++)widths[prior]=width;start=index;width=0;}
      width=Math.max(width,Math.ceil(measure(messages[index],!speakers[index].continuation)));
    }
    for(let index=start;index<messages.length;index++)widths[index]=width;
    return widths;
  }
  function createMeasurer({fontFamily,fontSize,emoticons,tokenize,isFollowed,isOwn,hasEnglish,clockDate,redundantBody}){
    const canvas=document.createElement('canvas'),context=canvas.getContext('2d'),cache=new Map();
    function textWidth(value,size=fontSize,weight=400){
      const key=weight+':'+size+':'+value;if(cache.has(key))return cache.get(key);
      context.font=weight+' '+size+'px '+fontFamily;
      const width=context.measureText(String(value)).width;cache.set(key,width);return width;
    }
    return (message,first)=>{
      let body=0;
      if(!redundantBody(message))for(const line of String(message.text||'［非文本消息］').split('\n')){
        if(line.length>4096){body=5000;break;}
        body=Math.max(body,tokenize(line,emoticons).reduce((sum,part)=>sum+(part.file?fontSize*1.41:textWidth(part.emoji||part.text)),0));
      }
      const actions=['复制','从这里阅读','加入书签','加入收藏',...(hasEnglish(message.text)?['翻译成中文']:[]),'加入讨论'];
      // Match reader-controls-v108.css: 12px icon, 3px gap, 4px padding per side;
      // the outer rail has 4px padding and 1px border on each side.
      const actionWidth=actions.reduce((sum,label)=>sum+textWidth(label,10)+23,10)+(actions.length-1)*4;
      const followed=isFollowed(message),own=isOwn(message);
      const heading=textWidth(message.senderName||'未命名成员',fontSize+1,followed?750:700)+textWidth(clockDate(message.sentAt),10)+20+(followed?textWidth('★ 重点关注',10,700)+28:0)+(own?25:0);
      const rail=first&&!followed&&!own?heading+8+actionWidth:Math.max(first?heading:0,actionWidth);
      const attachments=(message.attachments||[]).reduce((sum,item)=>sum+(['image','video'].includes(item.type)?248:360)+8,0);
      return Math.max(body,rail,Math.min(720,Math.max(0,attachments-8)))+43;
    };
  }
  return {groupWidths,createMeasurer};
});
