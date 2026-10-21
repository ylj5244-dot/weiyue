(function(root,factory){const api=factory();if(typeof module==='object'&&module.exports)module.exports=api;if(root)root.ReaderText=api;})(typeof window!=='undefined'?window:globalThis,function(){
  'use strict';
  // SoftBank U+E412 (UTF-8 ee9092) maps to U+1F602; Unicode L2/10-132.
  const legacy={'/ee9092.png':'😂'};
  function tokenize(value,assets){
    const text=String(value||''),parts=[];let last=0;
    for(const match of text.matchAll(/\[([^\[\]\r\n]{1,40})\]/g)){
      const file=Object.prototype.hasOwnProperty.call(assets,match[1])?assets[match[1]]:null;
      const alias=match[1].toLowerCase(),emoji=Object.prototype.hasOwnProperty.call(legacy,alias)?legacy[alias]:null;
      if(!file&&!emoji)continue;
      if(match.index>last)parts.push({text:text.slice(last,match.index)});
      parts.push(file?{text:match[0],file}:{text:match[0],emoji});last=match.index+match[0].length;
    }
    if(last<text.length)parts.push({text:text.slice(last)});
    return parts;
  }
  function append(target,value,assets){
    for(const part of tokenize(value,assets)){
      if(part.emoji){const span=document.createElement('span');span.className='reader-legacy-emoticon';span.textContent=part.emoji;span.title=part.text;span.setAttribute('aria-label',part.text);target.append(span);continue;}
      if(!part.file){target.append(document.createTextNode(part.text));continue;}
      const image=document.createElement('img');image.className='reader-emoticon';image.src=part.file;image.alt=part.text;image.title=part.text;image.draggable=false;
      image.addEventListener('error',()=>image.replaceWith(document.createTextNode(part.text)),{once:true});target.append(image);
    }
    return target;
  }
  return {tokenize,append};
});
