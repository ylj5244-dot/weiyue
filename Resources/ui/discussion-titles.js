(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.ReaderDiscussionTitles = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  const clip = (value, count) => Array.from(String(value || '')).slice(0, count).join('');
  function input(discussion) {
    const turns = (discussion.messages || []).filter(turn => turn && ['user','assistant'].includes(turn.role) && turn.status !== 'pending' && typeof turn.content === 'string' && turn.content.trim());
    const indices = [...new Set([0,1,...Array.from({length:Math.min(8,turns.length)},(_,i)=>Math.max(0,turns.length-8)+i)])].filter(i=>i<turns.length).sort((a,b)=>a-b);
    return {turns:indices.map(i=>({role:turns[i].role,content:clip(turns[i].content,1400)})),
      sources:(discussion.contextSnapshots || []).slice(0,3).map(item=>clip(item.text,600)),
      range:clip(discussion.rangeSummary && discussion.rangeSummary.label,160)};
  }
  function fingerprint(discussion) {
    const data=input(discussion);
    if (!data.turns.length && !data.sources.some(Boolean)) return '';
    const value=JSON.stringify(data);let a=2166136261,b=2246822519;
    for(let i=0;i<value.length;i++){a=Math.imul(a^value.charCodeAt(i),16777619);b=Math.imul(b^value.charCodeAt(i),3266489917);}
    return (a>>>0).toString(16).padStart(8,'0')+(b>>>0).toString(16).padStart(8,'0');
  }
  function normalizeTitle(value) {
    const invalid=()=>new Error('模型未返回合适的简短标题，已保留原来的标题。');
    if(typeof value!=='string'||value.length>2048)throw invalid();
    let title=value.trim().normalize('NFC');
    if(/[\r\n\u0085\u2028\u2029]/.test(title))throw invalid();
    const wrappers=[['**','**'],['__','__'],['*','*'],['_','_'],['`','`'],['"','"'],["'","'"],['“','”'],['‘','’'],['「','」'],['『','』']];
    for(let pass=0;pass<6;pass++) {
      const previous=title;
      title=title.replace(/^(?:标题|title)\s*[:：]\s*/i,'').replace(/^#{1,6}\s+/,'');
      for(const [left,right] of wrappers)if(title.startsWith(left)&&title.endsWith(right)&&title.length>=left.length+right.length){title=title.slice(left.length,-right.length).trim();break;}
      if(previous===title)break;
    }
    title=title.replace(/[\t ]+/g,' ');
    if(!title||Array.from(title).length>32||!/[\p{L}\p{N}]/u.test(title)||/[\p{Cc}{}\[\]<>`*#]/u.test(title)||
      /^(?:[-+•]|[0-9]+\.(?![0-9])|[0-9]+[)）、]|[一二三四五六七八九十]+[、.)）]|(?:理由|解释|推理过程|思考过程|analysis|reasoning)\s*[:：])/i.test(title)||
      /^(?:以下是|我建议|我认为|这个标题|此标题|here is|the title is|let['’]s)/i.test(title))throw invalid();
    return title;
  }
  function needsTitle(discussion) {
    if(!discussion || discussion.deletedAt)return false;
    const key=fingerprint(discussion), info=discussion.titleInfo;
    return !!key && (!info || info.version!==1 || info.source!=='ai' || info.fingerprint!==key || !discussion.title);
  }
  function createQueue(hooks) {
    const pending=new Set(),failures=new Map();
    let active=null,generation=0,paused=false,scheduled=false,cancelBarrier=null,cancellationBlock=null,cancellationEpoch=0;
    const current = id => {const state=hooks.getState();return state.discussions.find(d=>d.id===id&&d.accountId===state.accountId&&!d.deletedAt);};
    function notify(){if(hooks.onChange)hooks.onChange(status());}
    function status(){
      let failed=0,lastError='';
      for(const [id,error] of failures){const d=current(id);if(d && fingerprint(d)===error.fingerprint){failed++;lastError=error.message;}}
      return {activeId:active?active.id:null,remaining:pending.size+(active?1:0),failed,lastError:cancellationBlock?cancellationBlock.message:lastError,paused,
        missing:hooks.getState().discussions.filter(d=>d.accountId===hooks.getState().accountId&&needsTitle(d)).length};
    }
    function enqueue(id, retry=false, quiet=false) {
      const d=current(id);if(!d)return;
      const failed=failures.get(id),key=fingerprint(d);
      if(failed && failed.fingerprint!==key)failures.delete(id);
      if(!needsTitle(d) && !(failed && failed.saveOnly))return;
      if(failures.has(id)&&!retry)return;
      if(active && active.id===id)return;
      pending.add(id);kick();if(!quiet)notify();
    }
    function enqueueAll(retry=false){for(const d of hooks.getState().discussions)enqueue(d.id,retry,true);notify();}
    function kick(){
      if(scheduled||active||paused||cancelBarrier||!hooks.canRun()||!pending.size)return;
      scheduled=true;Promise.resolve().then(()=>{scheduled=false;if(!active&&!paused&&!cancelBarrier&&hooks.canRun())run();});
    }
    async function run(){
      const id=pending.values().next().value;if(id===undefined)return;pending.delete(id);
      const d=current(id),state=hooks.getState();
      if(!d || (!needsTitle(d)&&!failures.get(id)?.saveOnly)){notify();kick();return;}
      const job={id,state,generation,fingerprint:fingerprint(d),configuration:hooks.configuration()};active=job;notify();
      const valid=()=>active===job && generation===job.generation && hooks.getState()===state && current(id)===d;
      let applied=false;
      try {
        // The native side reads the saved discussion, never an arbitrary prompt supplied by the renderer.
        await hooks.save();if(!valid())return;
        if(failures.get(id)?.saveOnly && !needsTitle(d)){failures.delete(id);return;}
        const result=await hooks.request({accountId:state.accountId,discussionId:id,...job.configuration});
        if(!valid())return;
        if(fingerprint(d)!==job.fingerprint){pending.add(id);return;}
        const title=normalizeTitle(result && result.title);
        d.title=title;d.titleInfo={version:1,source:'ai',fingerprint:job.fingerprint,model:String(job.configuration.model || '').slice(0,240).replace(/[\uD800-\uDBFF]$/,''),generatedAt:new Date().toISOString()};state.revision++;applied=true;
        await hooks.save();if(valid())failures.delete(id);
      } catch(error) {
        if(valid()) {
          const message=String(error && error.message || error);
          failures.set(id,{fingerprint:job.fingerprint,message,saveOnly:applied});
          if(error && error.titleCancellationUnconfirmed){paused=true;cancellationBlock={job,message};}
        }
      } finally {
        if(active===job){active=null;notify();kick();}
      }
    }
    function cancelJob(job,resumeAfter=false){
      const epoch=cancellationEpoch,resumeGeneration=generation;
      const relevant=()=>cancelBarrier===barrier && cancellationEpoch===epoch && hooks.getState().accountId===job.state.accountId;
      const barrier=Promise.resolve().then(()=>hooks.cancel(job)).then(()=>{
        // Cleanup can replace the current state object for the same account.
        // Reset epochs and the active barrier exclude obsolete confirmations.
        if(!relevant())return;
        if(cancellationBlock && cancellationBlock.job===job)cancellationBlock=null;
        if(resumeAfter && generation===resumeGeneration){paused=false;enqueue(job.id,true,true);}
      }).catch(error=>{
        if(relevant()){paused=true;cancellationBlock={job,message:'未能确认标题请求已停止：'+String(error && error.message || error)};}
      });
      cancelBarrier=barrier;
      barrier.finally(()=>{if(cancelBarrier===barrier)cancelBarrier=null;kick();notify();});
    }
    function interrupt(requeue){
      generation++;
      const previous=active;active=null;
      if(previous && requeue && current(previous.id))pending.add(previous.id);
      if(previous)cancelJob(previous);
      notify();
    }
    function activityChanged(){if(!hooks.canRun()){if(active)interrupt(true);}else kick();}
    function pause(){paused=true;interrupt(true);}
    function resume(){if(cancellationBlock){if(!cancelBarrier)cancelJob(cancellationBlock.job,true);}else{paused=false;kick();}notify();}
    function retry(){for(const id of failures.keys())enqueue(id,true,true);resume();}
    function reset(){pending.clear();failures.clear();paused=false;cancellationBlock=null;cancellationEpoch++;interrupt(false);}
    return {enqueue,enqueueAll,kick,activityChanged,pause,resume,retry,reset,status};
  }
  return {input,fingerprint,normalizeTitle,needsTitle,createQueue};
});
