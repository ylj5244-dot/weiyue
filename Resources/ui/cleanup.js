(function (root, factory) {
  'use strict';
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.ReaderCleanup = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';
  const clone = value => JSON.parse(JSON.stringify(value));
  const key = message => message.groupId + ':' + message.id;
  const kinds = new Set(['text', 'image', 'document']);
  function optionsFor(options) {
    if (!options || !['group', 'all'].includes(options.scope) || (options.scope === 'group' && !options.groupId)) throw new Error('请选择清理当前群或全部群。');
    if (!Array.isArray(options.categories) || !options.categories.length || options.categories.some(kind => !kinds.has(kind))) throw new Error('请选择文字消息、图片或文档。');
    return {...options, categories:Array.from(new Set(options.categories))};
  }
  function cleanupFor(state) {
    const value = state.cleanup || {};
    return {suppressedMessageKeys:Array.isArray(value.suppressedMessageKeys) ? value.suppressedMessageKeys : [],
      suppressedTextKeys:Array.isArray(value.suppressedTextKeys) ? value.suppressedTextKeys : [],
      suppressedAssetKeys:Array.isArray(value.suppressedAssetKeys) ? value.suppressedAssetKeys : [],
      detachedAssets:Array.isArray(value.detachedAssets) ? value.detachedAssets : [],
      ...(value.lastCleanedAt ? {lastCleanedAt:value.lastCleanedAt} : {}),
      ...(value.autoCutoffAt ? {autoCutoffAt:value.autoCutoffAt} : {}),
      ...(value.lastAutoCleanedAt ? {lastAutoCleanedAt:value.lastAutoCleanedAt} : {}),
      autoPendingAssets:Array.isArray(value.autoPendingAssets) ? value.autoPendingAssets : []};
  }
  function assetKey(ref) {
    if (typeof ref.localPath === 'string' && ref.localPath) return 'local:' + ref.localPath;
    if (typeof ref.url !== 'string' || !ref.url) return '';
    try { const url = new URL(ref.url); url.protocol = 'https:'; url.hash = ''; return 'remote:' + url.href; } catch (_) { return ''; }
  }
  function assets(message) {
    return (message.attachments || []).flatMap((attachment, attachmentIndex) => {
      if (!['image','document'].includes(attachment.type)) return [];
      const ref = {kind:attachment.type, groupId:message.groupId, messageId:message.id, attachmentIndex};
      if (message.localPath) ref.localPath = message.localPath;
      else if (attachment.url) ref.url = attachment.url;
      return assetKey(ref) ? [ref] : [];
    });
  }
  function references(state) {
    const protectedKeys = new Set(), snapshots = [];
    (state.bookmarks || []).forEach(bookmark => {
      // Deleted bookmarks retain a restorable snapshot, so their files remain safe too.
      protectedKeys.add(bookmark.groupId + ':' + bookmark.messageId);
      if (bookmark.snapshot) snapshots.push(bookmark.snapshot);
    });
    (state.collections || []).forEach(collection => {
      (collection.messageIds || []).forEach(item => protectedKeys.add(item));
      (collection.messages || []).forEach(message => { protectedKeys.add(key(message)); snapshots.push(message); });
    });
    (state.discussions || []).forEach(discussion => {
      (discussion.contextSnapshots || []).forEach(message => { protectedKeys.add(key(message)); snapshots.push(message); });
    });
    Object.entries(state.progress || {}).forEach(([groupId, progress]) => {
      Object.values(progress).forEach(anchor => { if (anchor && anchor.messageId) protectedKeys.add(groupId + ':' + anchor.messageId); });
    });
    return {protectedKeys, snapshots};
  }
  function bytes(text) {
    return typeof TextEncoder !== 'undefined' ? new TextEncoder().encode(text).length : unescape(encodeURIComponent(text)).length;
  }
  function preview(state, rawOptions) {
    const options = optionsFor(rawOptions), selected = new Set(options.categories), inScope = value => options.scope === 'all' || value.groupId === options.groupId;
    const {protectedKeys, snapshots} = references(state), protectedAssets = new Set();
    snapshots.concat((state.messages || []).filter(message => protectedKeys.has(key(message)) || !inScope(message))).forEach(message => assets(message).forEach(ref => protectedAssets.add(assetKey(ref))));
    const messageKeys = [], textKeys = [], candidateAssets = new Map();
    let protectedCount = 0, estimatedTextBytes = 0;
    (state.messages || []).forEach(message => {
      if (!inScope(message)) return;
      if (protectedKeys.has(key(message))) { protectedCount++; return; }
      if (selected.has('text') && message.text) {
        textKeys.push(key(message));
        // File categories remain independent: only text-only records disappear.
        // A message with attachments retains its author, time and download links.
        if (!(message.attachments || []).length) { messageKeys.push(key(message)); estimatedTextBytes += bytes(JSON.stringify(message)); }
        else estimatedTextBytes += bytes(message.text);
      }
      assets(message).forEach(ref => { if (selected.has(ref.kind) && !protectedAssets.has(assetKey(ref))) candidateAssets.set(assetKey(ref), ref); });
    });
    // Message cleanup keeps only file references, enabling a later, separate file cleanup.
    cleanupFor(state).detachedAssets.forEach(ref => { if (inScope(ref) && selected.has(ref.kind) && !protectedAssets.has(assetKey(ref))) candidateAssets.set(assetKey(ref), ref); });
    const assetRefs = Array.from(candidateAssets.values());
    return {options, messageKeys, textKeys, assetRefs, protectedCount, estimatedTextBytes,
      counts:{text:textKeys.length,image:assetRefs.filter(ref=>ref.kind==='image').length,document:assetRefs.filter(ref=>ref.kind==='document').length}};
  }
  function stripExtractions(message, suppressed) {
    if (!Array.isArray(message.extractedContents) || !message.extractedContents.length) return message;
    const indices = new Set(assets(message).filter(ref => suppressed.has(assetKey(ref))).map(ref => ref.attachmentIndex));
    if (!indices.size) return message;
    return {...message,extractedContents:message.extractedContents.filter(item => !indices.has(item.attachmentIndex))};
  }
  function apply(state, options, now = new Date().toISOString()) {
    if (!Number.isFinite(Date.parse(now))) throw new Error('清理时间无效。');
    const summary = preview(state,options), next = clone(state), removed = new Set(summary.messageKeys), clearedText = new Set(summary.textKeys), cleanup = cleanupFor(state);
    const detached = new Map(cleanup.detachedAssets.map(ref => [ref.groupId + '\n' + assetKey(ref),ref]));
    state.messages.filter(message=>removed.has(key(message))).forEach(message=>assets(message).forEach(ref=>detached.set(ref.groupId+'\n'+assetKey(ref),ref)));
    const suppressed = new Set(cleanup.suppressedAssetKeys.concat(summary.assetRefs.map(assetKey)));
    next.messages = next.messages.filter(message => !removed.has(key(message))).map(message => stripExtractions(clearedText.has(key(message)) ? {...message,text:'',locallyClearedText:true} : message,suppressed));
    next.cleanup = {...cleanup,suppressedMessageKeys:Array.from(new Set(cleanup.suppressedMessageKeys.concat(summary.messageKeys))),suppressedTextKeys:Array.from(new Set(cleanup.suppressedTextKeys.concat(summary.textKeys))),suppressedAssetKeys:Array.from(suppressed),detachedAssets:Array.from(detached.values()),lastCleanedAt:now};
    next.revision = state.revision + 1;
    return {state:next,summary};
  }
  function filterIncoming(state, incoming) {
    const cleanup=cleanupFor(state), removed=new Set(cleanup.suppressedMessageKeys), clearedText=new Set(cleanup.suppressedTextKeys), suppressed=new Set(cleanup.suppressedAssetKeys);
    const cutoff=Date.parse(cleanup.autoCutoffAt), retained=new Set((state.messages||[]).map(key));
    return incoming.filter(message=>!removed.has(key(message)) && (!Number.isFinite(cutoff) || retained.has(key(message)) || message.localPath || message.groupId==='local-files' || !Number.isFinite(Date.parse(message.sentAt)) || Date.parse(message.sentAt)>=cutoff)).map(message=>stripExtractions(clearedText.has(key(message)) ? {...message,text:'',locallyClearedText:true} : message,suppressed));
  }
  function isMediaSuppressed(state, attachment, message) {
    const ref = message && message.localPath ? {localPath:message.localPath} : attachment;
    return cleanupFor(state).suppressedAssetKeys.includes(assetKey(ref));
  }
  function restoreMedia(state, ref) {
    const next=clone(state), cleanup=cleanupFor(state), restored=assetKey(ref);
    next.cleanup={...cleanup,suppressedAssetKeys:cleanup.suppressedAssetKeys.filter(value=>value!==restored)};
    next.revision=state.revision+1;return next;
  }
  function undo(state, before) {
    if (!state.accountId || state.accountId!==before.accountId) throw new Error('这份清理记录属于其他账号，不能恢复。');
    const next=clone(state), positions=new Map(next.messages.map((message,index)=>[key(message),index])), clearedText=new Set(cleanupFor(state).suppressedTextKeys);
    (before.messages || []).forEach(message=>{
      const index=positions.get(key(message));
      if (index===undefined) { positions.set(key(message),next.messages.length);next.messages.push(clone(message));return; }
      const current=next.messages[index], currentAssets=assets(current), byIndex=new Map((current.extractedContents || []).map(item=>[item.attachmentIndex,item]));
      if (clearedText.has(key(current)) && !current.text) {
        current.text=message.text;
        if (message.locallyClearedText) current.locallyClearedText=true; else delete current.locallyClearedText;
      }
      (message.extractedContents || []).forEach(item=>{
        const prior=assets(message).find(ref=>ref.attachmentIndex===item.attachmentIndex), present=currentAssets.find(ref=>ref.attachmentIndex===item.attachmentIndex);
        if (prior && present && assetKey(prior)===assetKey(present) && !byIndex.has(item.attachmentIndex)) byIndex.set(item.attachmentIndex,clone(item));
      });
      if (byIndex.size) current.extractedContents=Array.from(byIndex.values());
    });
    next.cleanup={...clone(cleanupFor(before)),...Object.fromEntries(Object.entries(cleanupFor(state)).filter(([name])=>['autoCutoffAt','autoPendingAssets','lastAutoCleanedAt'].includes(name)))};next.revision=state.revision+1;return next;
  }
  return {preview,apply,filterIncoming,isMediaSuppressed,restoreMedia,undo,assetKey};
});
