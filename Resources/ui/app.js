// Pure policies are shared by the desktop UI and Node regression tests.
const ReaderViewPolicy = (function () {
  'use strict';
  function readPreferences(state) {
    if (state.settings.readerStandby === true) return {groupId:'',mode:'reader'};
    const group = state.groups.find(g => g.id === state.settings.activeGroupId) || state.groups.find(g => g.selected) || state.groups[0];
    return { groupId: group ? group.id : '', mode: state.settings.mode === 'reader' ? 'reader' : 'official' };
  }
  function rememberPreferences(state, value) {
    const groupId = typeof value.groupId === 'string' && state.groups.some(g => g.id === value.groupId) ? value.groupId : '';
    const mode = value.mode === 'reader' ? 'reader' : 'official';
    const rememberedGroupId = !groupId && state.settings.readerStandby === true ? state.settings.activeGroupId || '' : groupId;
    const leavesStandby = !!groupId && state.settings.readerStandby === true;
    if (state.settings.activeGroupId === rememberedGroupId && state.settings.mode === mode && !leavesStandby) return false;
    state.settings.activeGroupId = rememberedGroupId; state.settings.mode = mode;
    if (leavesStandby) state.settings.readerStandby = false;
    state.revision++; return true;
  }
  function chooseAnchor({ state, groupId, messages, visible, remembered, restore = false, filtered = false }) {
    const saved = (state.progress[groupId] || {}).auto;
    const candidates = filtered ? [visible] : restore ? [remembered, saved] : [visible, remembered, saved];
    for (const candidate of candidates) {
      if (!candidate || candidate.accountId !== state.accountId || candidate.groupId !== groupId) continue;
      if (!messages.some(message => message.groupId === groupId && message.id === candidate.messageId)) continue;
      const anchor = { accountId: state.accountId, groupId, messageId: candidate.messageId, offset: Math.max(0, Number(candidate.offset) || 0) };
      if (Number.isFinite(candidate.visualOffset)) anchor.visualOffset = candidate.visualOffset;
      return anchor;
    }
    return null;
  }
  function shouldTrackProgress({ mode, view, filtered, programmatic, userInitiated }) {
    return mode === 'reader' && view === 'chats' && !filtered && !programmatic && userInitiated;
  }
  function safePreviewURL(value) {
    try { const url = new URL(value && value.url); return url.protocol === 'weiyue-media:' && url.hostname && !url.username && !url.password ? url.href : null; }
    catch (_) { return null; }
  }
  function attachmentPresentation(attachment) {
    const item = attachment && typeof attachment === 'object' ? attachment : {};
    const kind = ['image', 'document', 'video', 'link'].includes(item.type) ? item.type : 'document';
    const name = typeof item.name === 'string' && item.name.trim() ? item.name : ({ image: '图片', document: '附件', video: '视频', link: '链接' })[kind];
    if (kind === 'image') return { kind, name, detail: '图片' };
    if (kind === 'video' || kind === 'link') return { kind, name, detail: '在独立窗口打开' };
    const extension = name.includes('.') ? name.split('.').pop() : '';
    let detail = /^[a-z0-9]{1,8}$/i.test(extension) ? extension.toUpperCase() : '文件';
    if (Number.isSafeInteger(item.size) && item.size >= 0) detail += ' · ' + (item.size >= 1048576 ? (item.size / 1048576).toFixed(1) + ' MB' : item.size >= 1024 ? (item.size / 1024).toFixed(1) + ' KB' : item.size + ' B');
    return { kind, name, detail };
  }
  function settingsProbePayload(action, configuration) {
    const payload = { accountId: configuration.accountId, baseURL: configuration.baseURL };
    if (action === 'testAI') payload.model = configuration.model;
    return payload;
  }
  async function flushWithLifecycle(options, quiesce, flush) {
    if (options && options.quitting === true) await quiesce();
    return flush();
  }
  function interruptPendingAI(state, discussionId, reason = '应用关闭前已取消本次请求，提问与资料已保留，重新打开后可重试。') {
    const discussion = state.discussions.find(item => item.id === discussionId && item.accountId === state.accountId && !item.deletedAt);
    if (!discussion || !Array.isArray(discussion.messages)) return '';
    const pending = discussion.messages[discussion.messages.length - 1];
    if (!pending || pending.role !== 'user' || pending.status !== 'pending') return '';
    pending.status = 'failed'; pending.error = reason; state.revision++;
    return pending.content || '';
  }
  function captureRenderAnchor(options, rememberVisible) { return options.restore ? null : rememberVisible(); }
  function attachmentReference(message, attachmentIndex) { return { groupId: message.groupId, messageId: message.id, attachmentIndex }; }
  function aiStopState(value) {
    return { visible: !value.quitting && !!(value.busyAI || value.preparingContext || value.inlineBusy || value.rangeOperation || value.cancellingAI), disabled: !!value.cancellingAI, label: value.cancellingAI ? '正在停止…' : '停止' };
  }
  return { aiStopState, flushWithLifecycle, interruptPendingAI, readPreferences, rememberPreferences, chooseAnchor, shouldTrackProgress, safePreviewURL, attachmentPresentation, settingsProbePayload, attachmentReference, captureRenderAnchor };
})();
if (typeof module === 'object' && module.exports) module.exports = ReaderViewPolicy;

(function () {
  'use strict';
  if (typeof document === 'undefined') return;
  const M = window.ReaderModel, C = window.ReaderAIContext, P = window.ReaderPerformance, A = window.ReaderPreferences, S = window.ReaderRangeSummary, W = window.ReaderWebSearch, U = window.ReaderGroupUnread;
  const $ = id => document.getElementById(id);
  const native = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.app);
  const clone = value => JSON.parse(JSON.stringify(value));
  let state = M.createState();
  let ready = false, loadFailed = false, demo = false, hasAPIKey = false, accountName = '';
  let activeGroupId = '', activeView = 'chats', mode = 'official', deletedBookmarks = false;
  let memberId = '', selected = new Set(), context = [], contextCollectionId = null, currentDiscussionId = null;
  let bookmarkTarget = null, bookmarkNoteSaving = false, pendingCollection = null, collectionEditing = false, pendingCollectionKeys = [], busyAI = false, aiToken = 0;
  let queuedEvents = [], pendingRPC = new Map(), rpcSequence = 0, saveTail = Promise.resolve();
  let savedRevision = -1, saveError = '', accountEpoch = 0, layoutFrame = 0, toastTimer = 0, bannerTimer = 0;
  let progressTimer = 0, pendingProgress = null, suppressScrollUntil = 0, userScrollUntil = 0;
  let readingNavigationEpoch = 0;
  const sessionGroups = new Set(), viewportAnchors = new Map(), syncStates = new Map(), previewCache = new Map();
  let imageObserver = null, settingsBusy = false, preparingContext = false, preparationToken = 0, resizingAnchor = null;
  let quitting = false, quitPreparation = null, cancellingAI = false;
  let preferencesSaving = false, preferencesUI = null, followedUI = null, inlineTranslation = null, readingAppearance = null;
  let discussionTitles = null;
  let bookmarkGroupFilter = '', syncGroupsSaving = false;
  function inlineBusy() { return !!(inlineTranslation && inlineTranslation.isBusy()); }
  let discussionHistoryBusy = false, deletedDiscussions = false, pendingDiscussionDeleteIds = [];
  let rangeUI = null, rangeOperation = null, pendingRange = null, summarySourcePage = 0, focusedSource = null;
  let aiLive = null, aiLiveTimer = 0, cleanupBusy = false, cleanupPlan = null, cleanupEvents = [];
  let cleanupHasUndoReceipt = false, cleanupStatusRequest = 0;
  let modelCapabilities = { key: '', status: 'idle', value: null };
  function capabilityKey() { return JSON.stringify([accountEpoch,state.accountId,state.settings.baseURL || '',state.settings.model || '']); }
  function modelCapabilitiesLoading() { return modelCapabilities.key===capabilityKey() && modelCapabilities.status==='loading'; }
  function refreshModelCapabilities() {
    const key=capabilityKey();
    if (!native || demo || !ready || !state.accountId || !state.settings.baseURL || !state.settings.model) {modelCapabilities={key,status:'idle',value:null};return;}
    if (modelCapabilities.key===key) return;
    modelCapabilities={key,status:'loading',value:null};
    rpc('aiCapabilities',{accountId:state.accountId,baseURL:state.settings.baseURL,model:state.settings.model}).then(value=>{
      if(key!==capabilityKey() || modelCapabilities.key!==key)return;
      const valid=value && typeof value.thinking==='boolean' && typeof value.canDisableThinking==='boolean';
      modelCapabilities={key,status:valid?'ready':'unknown',value:valid?value:null};
      // A grey toggle must explicitly request thinking off. Preserve a previous
      // enabled choice; fixed-thinking/unknown models never rewrite this preference.
      if(valid && value.thinking && value.canDisableThinking && !['enabled','disabled'].includes(state.settings.thinking)) {
        mutate(()=>state.settings.thinking='disabled'); persistQuietly();
      }
      renderAIControls();
    }).catch(()=>{if(key===capabilityKey() && modelCapabilities.key===key){modelCapabilities={key,status:'unknown',value:null};renderAIControls();}});
  }
  function thinkingOption() {
    const current=modelCapabilities.key===capabilityKey() ? modelCapabilities : {status:'idle',value:null};
    const cap=current.value;
    if(current.status==='loading')return {mode:'auto',enabled:false,toggle:false,label:'确认中',hint:'正在确认模型的思考能力。'};
    if(cap && cap.thinking && cap.canDisableThinking) {
      const enabled=state.settings.thinking==='enabled';
      return {mode:enabled?'enabled':'disabled',enabled,toggle:true,label:enabled?'已开启':'已关闭',hint:enabled?'深度思考已开启，点击关闭。':'深度思考已关闭，点击开启。'};
    }
    if(cap && cap.thinking)return {mode:'enabled',enabled:true,toggle:false,label:'常开',hint:'此模型不能关闭思考。如需关闭，请选择支持思考开关的模型。'};
    return {mode:'auto',enabled:false,toggle:false,label:'模型默认',hint:'当前服务或模型没有已确认的思考开关，由模型决定是否思考；此状态不表示思考已关闭。'};
  }
  function aiConfiguration() {
    if(modelCapabilities.key!==capabilityKey() || modelCapabilities.status==='loading')throw new Error('正在确认模型能力，请稍后重试。');
    return {baseURL:state.settings.baseURL || '',model:state.settings.model || '',readMode:state.settings.readMode || 'auto',thinking:thinkingOption().mode,allowImages:!!state.settings.allowImages,allowPDF:!!state.settings.allowPDF};
  }
  let renderedFiltered = false, renderedGroupId = '';
  let deferredMessages = [];
  const selectedCollectionIds = new Set();
  const messageToggles = window.ReaderMessageActions.createToggles({
    model: M, getState: () => state,
    persist: source => source === state ? persist() : Promise.reject(new Error('账号已切换')),
    persistRollback: source => source === state ? persistQuietly() : Promise.resolve(),
    onChange: refreshMountedCards,
    onSaved: ({ kind, pressed }) => {
      renderSidebar(); renderBookmarks(); renderCollections(); renderProgressButtons();
      const labels = { manual: ['手动续读点已取消，其他阅读位置保留', '手动续读点已设置'], bookmark: ['书签已移入最近删除，备注与快照保留', '书签已加入，备注可在书签栏编辑'], collection: ['单条收藏已移入最近删除，多条合集与讨论保留', '已收藏这条消息'] };
      notify(labels[kind][pressed ? 1 : 0]);
    },
    onError: error => {
      renderSidebar(); renderBookmarks(); renderCollections(); renderProgressButtons();
      handleError(new Error('未能保存修改：' + errorText(error) + '。记录与后续编辑已保留，再次点击同一按钮可重试。'));
    }
  });
  let deletedCollections = false, collectionUndo = null, pendingCollectionDeleteIds = [], collectionsBusy = false, collectionSearchTimer = 0;
  let renderedSpeakers = [];
  let archiveIndex = null, archiveDirty = true, renderedMessages = [], syncRenderTimer = 0, searchTimer = 0, scrollFrame = 0;
  const syncDirtyGroups = new Set(), saveQueue = new P.CoalescedQueue();
  const readerList = new P.VirtualList({
    scroll: $('reader-scroll'), content: $('messages'), keyFor: message => message.accountId + ':' + M.messageKey(message),
    cacheTokenFor: (_, index) => renderedSpeakers[index].tone + ':' + renderedSpeakers[index].position + ':' + renderedSpeakers[index].messageTone,
    createRow: (message, index) => {
      const previous = renderedMessages[index - 1], date = dayDate(message.sentAt), children = [];
      if (!previous || dayDate(previous.sentAt) !== date) children.push(node('div', 'date-separator', date));
      const card = messageCard(message);
      const speaker = renderedSpeakers[index];
      card.classList.add('speaker-group', 'speaker-tone-' + speaker.tone, 'speaker-' + speaker.position, 'message-tone-' + speaker.messageTone);
      if (speaker.continuation) card.classList.add('continuation');
      card.title = (message.senderName || '未命名成员') + ' · ' + fullDate(message.sentAt);
      card.setAttribute('aria-label', card.title);
      children.push(card); return children;
    },
    onRendered: () => { refreshMountedCards(); observeMessageImages(); }
  });
  function archive() {
    if (archiveDirty || !archiveIndex || archiveIndex.source !== state.messages || archiveIndex.count !== state.messages.length) {
      archiveIndex = new P.ArchiveIndex(state.messages); archiveDirty = false;
    }
    return archiveIndex;
  }
  function scheduleSyncedRender(groupId) {
    syncDirtyGroups.add(groupId);
    if (syncRenderTimer) return;
    syncRenderTimer = setTimeout(() => {
      syncRenderTimer = 0; renderSidebar(); renderHeader();
      if (mode === 'reader' && activeView === 'chats' && (syncDirtyGroups.has(activeGroupId) || state.settings.readerStandby === true)) renderReader();
      syncDirtyGroups.clear();
    }, 120);
  }

  function icon(name) {
    const el = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', '#i-' + name); el.appendChild(use); el.setAttribute('aria-hidden', 'true');
    return el;
  }
  function node(tag, className, text) {
    const el = document.createElement(tag);
    if (className) el.className = className;
    if (text !== undefined) el.textContent = text;
    return el;
  }
  function button(label, className, handler, iconName) {
    const el = node('button', className); el.type = 'button';
    if (iconName) el.appendChild(icon(iconName));
    el.appendChild(node('span', '', label)); el.addEventListener('click', handler); return el;
  }
  function replace(id, children) { $(id).replaceChildren(...children); }
  function show(id, visible) { $(id).hidden = !visible; if(id==='discussion-list')$('discussion-history').setAttribute('aria-expanded',String(!!visible)); }
  function text(id, value) { const element = $(id); if (element.textContent !== String(value)) element.textContent = value; }
  function shortText(value, length = 80) { return value.length > length ? value.slice(0, length) + '…' : value; }
  function currentGroup() { return state.groups.find(g => g.id === activeGroupId); }
  function groupName(id) { if (id === 'local-files') return '本地文件'; return (state.groups.find(g => g.id === id) || {}).name || '群 ' + id; }
  function currentDiscussion() { return state.discussions.find(d => d.id === currentDiscussionId && !d.deletedAt); }
  function localSettingsLocked() { return !ready || loadFailed || !state.accountId || quitting || cleanupBusy || preferencesSaving; }
  function preferencesLocked() { return !ready || loadFailed || !state.accountId || settingsBusy || busyAI || inlineBusy() || preparingContext || cancellingAI || quitting || cleanupBusy || preferencesSaving || discussionHistoryBusy || modelCapabilitiesLoading(); }
  function restoreActiveDiscussion() {
    currentDiscussionId = state.settings.activeDiscussionId || null;
    const discussion = currentDiscussion();
    if (!discussion) { currentDiscussionId = null; return; }
    context = clone(discussion.contextSnapshots || []);
    contextCollectionId = state.collections.some(item => item.id === discussion.collectionId && !item.deletedAt) ? discussion.collectionId : null;
  }
  function recoverRangeSummaries() {
    const interrupted=state.discussions.filter(d=>!d.deletedAt && d.rangeSummary && d.rangeSummary.status==='running');
    if(interrupted.length){mutate(()=>interrupted.forEach(d=>{d.rangeSummary.status='interrupted';d.rangeSummary.error='上次总结未完成，已保存的消息和分批结果仍保留，可以重新生成。';}));persistQuietly();}
  }
  function rememberActiveDiscussion(clearDraft = false) {
    if (state.settings.activeDiscussionId === currentDiscussionId && (!clearDraft || !state.settings.aiDraftInstructions)) return;
    mutate(() => { state.settings.activeDiscussionId = currentDiscussionId; if (clearDraft) state.settings.aiDraftInstructions = ''; });
    persistQuietly();
  }
  async function savePersonalization(target, field, value) {
    if (localSettingsLocked()) throw new Error('请等待本地资料载入或保存完成后再修改。');
    const epoch = accountEpoch, hadValue = Object.prototype.hasOwnProperty.call(target, field), previous = target[field];
    preferencesSaving = true; renderAIControls();
    try {
      mutate(() => { target[field] = value; }); await persist();
      if (epoch !== accountEpoch) throw new Error('账号已切换，请在当前账号重新打开偏好库。');
    } catch (error) {
      if (epoch === accountEpoch) {
        mutate(() => { if (hadValue) target[field] = previous; else delete target[field]; });
        // Roll back only this field; messages arriving while saving must survive.
        persistQuietly();
      }
      throw error;
    } finally { if (epoch === accountEpoch) { preferencesSaving = false; renderAIControls(); } }
  }
  function fullDate(value) {
    if (!value) return '时间未知';
    const d = new Date(value); if (!Number.isFinite(d.getTime())) return '时间未知';
    const pad = n => String(n).padStart(2, '0');
    return d.getFullYear() + '年' + pad(d.getMonth() + 1) + '月' + pad(d.getDate()) + '日 ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }
  function dayDate(value) { return fullDate(value).split(' ')[0]; }
  function clockDate(value) { return fullDate(value).split(' ')[1] || ''; }
  function errorText(error) { return error && error.message ? error.message : String(error || '操作未完成'); }
  function notify(message) {
    clearTimeout(toastTimer); text('toast', message); show('toast', true);
    toastTimer = setTimeout(() => show('toast', false), 3400);
  }
  function banner(message, transient = false) {
    clearTimeout(bannerTimer); text('status-banner-text', message); show('status-banner', true); scheduleLayout();
    if (transient) bannerTimer = setTimeout(() => show('status-banner', false), 5000);
  }
  function handleError(error) { notify(errorText(error)); }
  function rpc(action, payload = {}) {
    if (!native) return Promise.reject(new Error('此操作需要在微阅 Mac 应用中使用。'));
    return new Promise((resolve, reject) => {
      const id = 'ui-' + Date.now() + '-' + (++rpcSequence);
      const timeout = setTimeout(async () => {
        pendingRPC.delete(id);
        if(action==='titleDiscussion') {
          // A title may use the provider's full response deadline. Release the
          // next queued title only after its independent native request stops.
          let error=new Error('标题生成等待超时，已取消请求；原有标题已保留。');
          try { await rpc('cancelDiscussionTitle',{accountId:payload.accountId}); }
          catch (_) { error=new Error('未能确认标题请求已停止，已暂停拟题。点击继续后将重新确认。');error.titleCancellationUnconfirmed=true; }
          reject(error);return;
        }
        if (['ai','testAI'].includes(action)) rpc('cancelAI').catch(() => {});
        if(action==='loadRange')rpc('cancelRange',{accountId:payload.accountId,requestId:payload.requestId}).catch(()=>{});
        reject(new Error(action === 'ai' ? '模型响应超时，已停止请求并保留提问与已收到的内容。' : '操作等待超时，请重试。'));
      }, ['ai','testAI','loadRange','titleDiscussion'].includes(action) ? 650000 : action === 'listModels' ? 190000 : ['downloadAttachment', 'openAttachment', 'revealAttachment', 'export', 'extractAttachment', 'importDocument','prepareImported','cleanupApply','cleanupUndo','cleanupPreview','loadHistory','syncNow'].includes(action) ? 180000 : action === 'attachmentPreview' ? 90000 : 25000);
      pendingRPC.set(id, { resolve, reject, timeout });
      try { window.webkit.messageHandlers.app.postMessage({ id, action, payload }); }
      catch (error) { clearTimeout(timeout); pendingRPC.delete(id); reject(error); }
    });
  }
  window.nativeReceive = function (response) {
    if (!response || !pendingRPC.has(response.id)) return;
    const task = pendingRPC.get(response.id); clearTimeout(task.timeout); pendingRPC.delete(response.id);
    if (response.ok) task.resolve(response.result || {});
    else task.reject(new Error(typeof response.error === 'string' ? response.error : '操作未完成，请重试。'));
  };
  window.onNativeEvent = function (event) {
    if (event && event.type === 'aiProgress') { if (!inlineTranslation || !inlineTranslation.consumeProgress(event)) receiveAIProgress(event); return; }
    if (event && event.type === 'rangeProgress') { receiveRangeProgress(event); return; }
    if (cleanupBusy) { cleanupEvents.push(event); return; }
    if (!ready) { queuedEvents.push(event); return; }
    try { receiveEvent(event); } catch (error) { banner('读取官方页面数据时遇到问题：' + errorText(error)); }
  };
  function setSaveStatus(status, label) {
    $('toolbar-center').className = 'toolbar-center ' + (status || ''); text('save-status', label);
  }
  function persist(options = {}) {
    if (!ready) return Promise.reject(new Error('资料仍在载入，请稍后重试。'));
    if (loadFailed) return Promise.reject(new Error('原有资料未能安全载入，已暂停保存。请重新打开应用。'));
    if (demo) { savedRevision = state.revision; setSaveStatus('', '演示 · 仅当前窗口'); return Promise.resolve({ revision: state.revision }); }
    if (!state.accountId) return Promise.reject(new Error('请先在官方页面登录微博，再保存资料。'));
    if (savedRevision >= state.revision && !saveError) return saveTail;
    const source = state, epoch = accountEpoch;
    setSaveStatus('saving', '正在保存…');
    const save = saveQueue.request(epoch + ':' + source.accountId, async () => {
      // postMessage snapshots synchronously. Avoid an additional full JSON clone
      // and skip intermediate revisions while another disk save is in flight.
      const revision = source.revision;
      const result = await rpc('save', { state: source });
      if (epoch === accountEpoch) {
        savedRevision = Math.max(savedRevision, Number.isInteger(result.revision) ? result.revision : revision);
        saveError = '';
        if (savedRevision >= state.revision) setSaveStatus('', '已保存至本机');
      }
      return result;
    }, options.defer ? 300 : 0).catch(error => {
      if (epoch === accountEpoch) { saveError = errorText(error); setSaveStatus('failed', '保存失败 · 点击重试'); }
      throw error;
    });
    saveTail = save; return save;
  }
  function persistQuietly() { const epoch = accountEpoch; return persist({ defer: true }).catch(error => { if (epoch === accountEpoch && state.accountId) banner('资料暂未保存到磁盘：' + errorText(error) + '。点击顶部「保存失败」可重试。'); }); }
  function commitPendingProgress() {
    clearTimeout(progressTimer); progressTimer = 0;
    const anchor = pendingProgress; pendingProgress = null;
    if (!anchor || anchor.accountId !== state.accountId) return false;
    M.setProgress(state, { groupId: anchor.groupId, messageId: anchor.messageId, offset: anchor.offset, kind: 'auto' });
    return true;
  }
  function isFiltered() { return !!(memberId || $('message-search').value || $('date-from').value || $('date-to').value); }
  function rememberVisibleAnchor() {
    const anchor = visibleMessage();
    if (anchor && anchor.accountId === state.accountId && !renderedFiltered) viewportAnchors.set(anchor.groupId, anchor);
    return anchor;
  }
  function saveViewPreferences() {
    if (state.accountId && ReaderViewPolicy.rememberPreferences(state, { groupId: activeGroupId, mode })) persistQuietly();
  }
  function settleReading() { rememberVisibleAnchor(); if (commitPendingProgress()) { persistQuietly(); renderProgressButtons(); } }
  function quiesceForQuit() {
    if (quitPreparation) return quitPreparation;
    if (discussionTitles) discussionTitles.pause();
    // Invalidate before yielding so a completed extraction or a pending save can never start a new request.
    if (inlineTranslation) inlineTranslation.reset();
    const rangeCancellation = cancelRangeSummary('应用关闭前已停止时段总结，已完成的批次仍保留。');
    quitting = true; ++preparationToken; ++aiToken; preparingContext = false; busyAI = false; cancellingAI = false;
    const question = ReaderViewPolicy.interruptPendingAI(state, currentDiscussionId);
    if (question) $('ai-question').value = question;
    preservePartialAI(currentDiscussion()); finishAILive();
    renderAIControls(); renderContext(); renderConversation();
    quitPreparation = Promise.all([rpc('cancelContent'), rpc('cancelAI'), rangeCancellation]);
    return quitPreparation;
  }
  window.resumeAfterCancelledQuit = function () {
    quitting = false; quitPreparation = null;
    renderAIControls(); renderContext(); renderConversation();
    aiState('应用继续保持打开。已取消的请求不会自动重发，提问与资料已保留。');
    return true;
  };
  window.flushBeforeQuit = async function (options) {
    if (!native || demo) return true;
    return ReaderViewPolicy.flushWithLifecycle(options, quiesceForQuit, flushSavedState);
  };
  async function flushSavedState() {
    // Incoming messages can enqueue a newer save while an earlier one is pending.
    // Only acknowledge quit after both the revision and the save queue are stable.
    while (true) {
      commitPendingProgress();
      const epoch = accountEpoch, observedTail = saveTail;
      await observedTail.catch(() => {});
      if (epoch !== accountEpoch) continue;
      if (state.accountId && (savedRevision < state.revision || saveError)) await persist();
      const finalTail = saveTail;
      await finalTail;
      if (epoch !== accountEpoch || finalTail !== saveTail || pendingProgress) continue;
      if (state.accountId && (savedRevision < state.revision || saveError)) continue;
      return true;
    }
  };
  function mutate(callback) { callback(); state.revision++; }
  function replaceAccount(raw, keyStatus, name) {
    if (discussionTitles) discussionTitles.reset();
    cancelRangeSummary('账号切换已停止时段总结。').catch(() => {});
    if (rangeUI) rangeUI.close();
    if (preferencesUI) preferencesUI.close();
    if (followedUI) followedUI.close();
    if (inlineTranslation) inlineTranslation.reset();
    bookmarkGroupFilter = ''; syncGroupsSaving = false; bookmarkTarget = null; bookmarkNoteSaving = false; messageToggles.reset();
    const previousRevision=state.revision;
    ReaderViewPolicy.interruptPendingAI(state,currentDiscussionId,'账号切换已中止请求，提问与已收到的内容已保留。');
    preservePartialAI(currentDiscussion());
    if(state.accountId && state.revision!==previousRevision) persistQuietly();
    finishAILive();
    if (commitPendingProgress()) persistQuietly();
    ++accountEpoch; ++aiToken; ++preparationToken; preparingContext = false; cancellingAI = false; resizingAnchor = null;
    modelCapabilities={key:'',status:'idle',value:null};
    clearTimeout(syncRenderTimer); syncRenderTimer = 0; syncDirtyGroups.clear(); clearTimeout(searchTimer); archiveDirty = true; readerList.clear();
    state = M.normalizeState(raw); savedRevision = state.revision; saveError = '';
    hasAPIKey = !!keyStatus; accountName = name || '';
    const preferences = ReaderViewPolicy.readPreferences(state); activeGroupId = preferences.groupId; mode = preferences.mode; activeView = 'chats';
    viewportAnchors.clear(); syncStates.clear(); previewCache.clear(); if (imageObserver) imageObserver.disconnect(); renderedGroupId = ''; renderedFiltered = false;
    selected.clear(); selectedCollectionIds.clear(); deletedCollections = false; collectionUndo = null; pendingCollectionDeleteIds = []; collectionsBusy = false; clearTimeout(collectionSearchTimer); $('collection-search').value = '';
    cleanupHasUndoReceipt = false; ++cleanupStatusRequest; updateCleanupUndo();
    context = []; contextCollectionId = null; currentDiscussionId = null; memberId = ''; pendingRange = null; focusedSource = null; summarySourcePage = 0; rangeOperation = null;
    busyAI = false; preferencesSaving = false; discussionHistoryBusy = false; deletedDiscussions = false; pendingDiscussionDeleteIds = []; show('discussion-history-error',false); sessionGroups.clear(); deferredMessages = []; restoreActiveDiscussion();
    $('message-search').value = ''; $('member-search').value = ''; $('date-from').value = ''; $('date-to').value = '';
    $('ai-question').value = ''; show('ai-state', false); show('member-popover', false); show('discussion-list', false);
    document.querySelectorAll('dialog[open]').forEach(dialog => dialog.close());
    setSaveStatus('', state.accountId ? '已保存至本机' : '等待登录');
    if (U.initialize(state)) persistQuietly();
    recoverRangeSummaries();renderAll({ restore: true });
  }
  function receiveEvent(event) {
    if (!event || typeof event !== 'object') return;
    if (event.type === 'account') { replaceAccount(event.state, event.hasAPIKey, event.accountName); return; }
    if (event.type === 'status') {
      if (event.text) { const message = String(event.text); banner(message, !/(失败|错误|异常|无法|未能|警告|损坏|恢复|超时)/.test(message)); }
      return;
    }
    if (event.type === 'profile') {
      if (event.accountId && state.accountId && event.accountId !== state.accountId) return;
      if (event.name) accountName = String(event.name); renderSidebar(); return;
    }
    if (!state.accountId || event.accountId !== state.accountId) return;
    if (event.type === 'sync') {
      const previous = syncStates.get(event.groupId) || {};
      syncStates.set(event.groupId, { ...previous, ...event, updatedAt: event.state === 'idle' ? new Date().toISOString() : previous.updatedAt });
      if (event.groupId === activeGroupId) renderSyncStatus();
      return;
    }
    if (event.type === 'groups') {
      const revision = state.revision; M.upsertGroups(state, event.groups || []); U.initialize(state);
      if (!activeGroupId && state.settings.readerStandby !== true) activeGroupId = (state.groups.find(g => g.selected) || state.groups[0] || {}).id || '';
      if (revision !== state.revision) { renderSidebar(); renderHeader(); persistQuietly(); }
      const pending = deferredMessages; deferredMessages = []; pending.forEach(receiveEvent);
    } else if (event.type === 'messages') {
      const group = state.groups.find(g => g.id === event.groupId);
      if (!group) { deferredMessages.push(event); return; }
      if (!group.selected) return;
      const incoming = window.ReaderCleanup ? ReaderCleanup.filterIncoming(state, event.messages || []) : event.messages || [];
      const revision = state.revision, index = archive();
      const freshIds = new Set(incoming.filter(message => !index.find(event.groupId, message.id)).map(message => message.id));
      const accepted = M.ingestMessages(state, event.groupId, incoming);
      U.observe(state, event.groupId, accepted, {activeGroupId, freshIds, source: event.messageSource, requestStartedAt: event.requestStartedAt});
      if (revision === state.revision) return;
      archiveDirty = true; scheduleSyncedRender(event.groupId); persistQuietly();
    }
  }
  function scheduleLayout() {
    cancelAnimationFrame(layoutFrame);
    layoutFrame = requestAnimationFrame(() => {
      if (!native || !ready) return;
      const r = $('official-host').getBoundingClientRect();
      const visible = activeView === 'chats' && mode === 'official' && !document.querySelector('dialog[open]') && !demo;
      rpc('layout', { x: r.x, y: r.y, width: r.width, height: r.height, visible }).catch(() => {});
    });
  }
  function renderAll(options = {}) { applyAIFontSize(); renderSidebar(); renderHeader(); renderViews(); renderReader(options); renderBookmarks(); renderCollections(); renderContext(); renderConversation(); renderAIControls(); scheduleLayout(); }
  function renderSidebar() {
    if (window.ReaderLayout) ReaderLayout.setData({ bookmarks: state.bookmarks, groups: state.groups, activeGroupId });
    text('group-count', String(state.groups.length));
    text('bookmark-count', String(state.bookmarks.filter(b => !b.deletedAt).length));
    text('collection-count', String(state.collections.filter(collection => !collection.deletedAt).length));
    ['chats', 'bookmarks', 'collections'].forEach(view => $('nav-' + view).classList.toggle('active', activeView === view));
    const query = $('group-search').value.trim().toLocaleLowerCase();
    const groups = state.groups.filter(g => g.name.toLocaleLowerCase().includes(query) || g.id.includes(query));
    const list = groups.map(group => {
      const row = node('div', 'group-row' + (group.id === activeGroupId ? ' active' : ''));
      const pick = node('button', 'group-pick'); pick.type = 'button'; pick.title = group.name + ' · 群 ID ' + group.id; pick.dataset.groupId = group.id;
      pick.appendChild(node('span', 'group-avatar', Array.from(group.name)[0] || '群'));
      const labels = node('span', 'group-label'); labels.appendChild(node('strong', '', group.name));
      const count = archive().forGroup(group.id).length;
      labels.appendChild(node('small', '', group.selected ? count + ' 条已保存' : '未开启本地保存')); pick.appendChild(labels);
      const unread = group.selected ? U.count(state, group.id) : 0;
      if (unread) {
        const badge = node('span', 'group-unread-badge', unread > 999 ? '999+' : String(unread));
        badge.title = unread + ' 条新消息 · 点击群聊清除提醒，保留原阅读位置'; badge.setAttribute('aria-hidden','true'); pick.appendChild(badge);
        pick.setAttribute('aria-label', group.name + '，' + unread + ' 条新消息，点击查看并清除提醒');
      } else pick.setAttribute('aria-label', group.name + '，暂无新消息提醒');
      pick.addEventListener('click', () => { if (setGroup(group.id) !== false && native) rpc('openOfficial', { groupId: group.id }).catch(handleError); });
      row.append(pick); return row;
    });
    if (!list.length) list.push(node('p', 'sidebar-empty', query ? '没有找到这个群聊。' : state.accountId ? '打开官方页面的群聊列表，群名称会显示在这里。' : '登录微博后，你的群聊会显示在这里。'));
    replace('group-list', list);
    text('account-name', demo ? '演示账号' : accountName || (state.accountId ? '微博账号' : '尚未连接账号'));
    text('account-subtitle', demo ? '示例内容 · 非真实群聊' : state.accountId ? 'ID ' + state.accountId : '在官方页面登录微博');
    text('account-avatar', Array.from(accountName || '微')[0]);
    $('account-name').closest('.account').classList.toggle('connected', !!state.accountId);
  }
  function renderHeader() {
    const group = currentGroup(), standby = state.settings.readerStandby === true && !activeGroupId;
    text('group-name', standby ? '待机中' : group ? group.name : '微博群聊');
    text('group-description', standby ? '所有已开启同步的群继续收取消息、累计未读提醒' : group ? (group.selected ? '已开启本地保存 · 自动同步' : '在「管理」中开启群聊同步与本地保存') : '连接账号，留住值得细读的讨论');
    $('enter-standby').disabled = !state.accountId || standby;
    text('standby-label', standby ? '已待机' : '进入待机');
    $('mode-official').disabled = standby;
    $('reader-area').classList.toggle('is-standby', standby);
    $('coverage-bar').hidden = standby;
    const messages = archive().forGroup(activeGroupId);
    let coverage = '本地尚未保存消息 · 在「管理」中开启同步';
    if (messages.length) coverage = '本地 ' + messages.length + ' 条 · ' + fullDate(messages[0].sentAt) + ' 至 ' + fullDate(messages[messages.length - 1].sentAt) + ' · 非完整历史';
    text('coverage-text', coverage); $('coverage-text').title = coverage;
    $('mode-official').classList.toggle('selected', mode === 'official'); $('mode-reader').classList.toggle('selected', mode === 'reader');
    text('ai-model-label', state.settings.model || '设置模型');
    renderSyncStatus();
  }
  function renderSyncStatus() {
    const group = currentGroup(), info = syncStates.get(activeGroupId);
    let label = !group ? '选择一个群聊开始同步' : !group.selected ? '在「管理」中开启此群同步' : demo ? '演示内容 · 不连接微博' : '等待同步当前群聊';
    if (info) {
      label = info.text || ({ loading: info.phase === 'history' ? '正在补充历史消息' : info.phase === 'refresh' ? '正在补全已有消息附件' : '正在同步新消息', idle: '实时同步已开启', paused: '同步已暂停', backoff: '稍后自动重试', error: '同步遇到问题' })[info.state] || '等待同步';
    }
    text('sync-status', label); $('sync-status').title = label;
    text('sync-time', info && info.updatedAt ? '更新于 ' + clockDate(info.updatedAt) : '');
    $('sync-bar').className = 'sync-bar' + (info && ['error', 'backoff'].includes(info.state) ? ' sync-error' : '') + (info && info.state === 'loading' ? ' sync-loading' : '');
    const permitted = !!(native && group && group.selected && !demo);
    $('sync-now').disabled = !permitted || !!(info && info.state === 'loading');
    text('sync-now', info && ['error', 'backoff', 'paused'].includes(info.state) ? '重试同步' : '立即同步');
    $('load-history').disabled = !permitted || !!(info && info.state === 'loading' && info.phase === 'history') || !!(info && info.hasMore === false);
    text('load-history', info && info.hasMore === false ? '没有更早消息' : '加载更早 500 条');
  }
  async function requestSync(history) {
    const group = currentGroup(); if (!native || !group || !group.selected || demo) return;
    const epoch = accountEpoch, groupId = group.id, prior = syncStates.get(groupId) || {};
    const isHistory = history || (prior.phase === 'history' && ['error', 'backoff', 'paused'].includes(prior.state));
    syncStates.set(groupId, { ...prior, state: 'loading', phase: isHistory ? 'history' : 'live', text: isHistory ? '正在请求更早的历史消息' : '正在请求最新消息' }); renderSyncStatus();
    try { await rpc(isHistory ? 'loadHistory' : 'syncNow', isHistory ? { groupId, count: 500 } : { groupId }); }
    catch (error) { if (epoch === accountEpoch) { syncStates.set(groupId, { ...prior, state: 'error', phase: isHistory ? 'history' : 'live', text: errorText(error) }); renderSyncStatus(); } }
  }
  function renderViews() {
    show('chat-view', activeView === 'chats'); show('bookmarks-view', activeView === 'bookmarks'); show('collections-view', activeView === 'collections');
    show('official-area', mode === 'official'); show('reader-area', mode === 'reader');
    if (native) show('official-placeholder', false);
    scheduleLayout();
  }
  function setView(view) { ++readingNavigationEpoch; settleReading(); activeView = view; show('member-popover', false); renderSidebar(); renderViews(); if (view === 'chats' && mode === 'reader') renderReader({ restore: true }); if (view === 'bookmarks') renderBookmarks(); if (view === 'collections') renderCollections(); }
  function setGroup(id) {
    if (!state.groups.some(group => group.id === id)) return false;
    ++readingNavigationEpoch; focusedSource = null;
    settleReading(); activeGroupId = id;
    if (state.settings.readerStandby === true) mutate(() => state.settings.readerStandby = false);
    const parked = (state.progress[id] || {}).standbyView;
    if (parked) {
      if (archive().find(id, parked.messageId)) viewportAnchors.set(id, parked);
      mutate(() => delete state.progress[id].standbyView);
    }
    memberId = ''; $('message-search').value = ''; $('date-from').value = ''; $('date-to').value = '';
    if (U.acknowledge(state, id, archive().forGroup(id))) persistQuietly();
    show('member-popover', false); activeView = 'chats'; renderSidebar(); renderHeader(); renderViews(); renderReader({ restore: true }); saveViewPreferences(); if (mode === 'reader') captureSessionStart(); if(rangeUI)rangeUI.render();
    return true;
  }
  function enterStandby() {
    if (!ready || !state.accountId || quitting || loadFailed) return;
    ++readingNavigationEpoch; settleReading(); saveViewPreferences();
    const parked = visibleMessage() || viewportAnchors.get(activeGroupId) || (state.progress[activeGroupId] || {}).auto;
    if (parked && parked.accountId === state.accountId && parked.groupId === activeGroupId && archive().find(activeGroupId, parked.messageId)) {
      M.setProgress(state, {groupId:activeGroupId,messageId:parked.messageId,offset:parked.offset || 0,kind:'standbyView'});
    }
    mutate(() => { state.settings.readerStandby = true; state.settings.mode = 'reader'; });
    activeGroupId = ''; mode = 'reader'; activeView = 'chats'; focusedSource = null;
    memberId = ''; $('message-search').value = ''; $('date-from').value = ''; $('date-to').value = ''; selected.clear();
    show('member-popover', false); show('date-filter', false);
    renderSidebar(); renderHeader(); renderViews(); renderReader({reset:true}); if(rangeUI)rangeUI.render(); persistQuietly();
    notify('已进入待机：所有已同步群继续累计新消息，阅读位置保留。');
  }
  function setMode(value, options = {}) {
    if (value === 'official' && state.settings.readerStandby === true && !activeGroupId) { notify('点击左侧群聊后即可打开官方聊天。'); return; }
    ++readingNavigationEpoch; settleReading(); mode = value; activeView = 'chats'; renderSidebar(); renderHeader(); renderViews();
    saveViewPreferences(); if (value === 'reader') { renderReader({ restore: true }); captureSessionStart(); }
    if (value === 'official' && native && options.navigate !== false) rpc('openOfficial', activeGroupId ? { groupId: activeGroupId } : {}).catch(handleError);
  }
  function resetFilters() { settleReading(); memberId = ''; $('message-search').value = ''; $('date-from').value = ''; $('date-to').value = ''; renderReader({ restore: true }); }
  function filterChanged() { settleReading(); renderReader(isFiltered() ? { reset: true } : { restore: true }); }
  function searchOptions() {
    const options = { groupId: activeGroupId };
    if (memberId) options.senderId = memberId;
    if ($('message-search').value.trim()) options.query = $('message-search').value.trim();
    if ($('date-from').value) options.from = new Date($('date-from').value + 'T00:00:00').toISOString();
    if ($('date-to').value) options.to = new Date($('date-to').value + 'T23:59:59.999').toISOString();
    return options;
  }
  function renderReader(options = {}) {
    const scroll = $('reader-scroll'), oldScroll = scroll.scrollTop, previousAnchor = ReaderViewPolicy.captureRenderAnchor(options, rememberVisibleAnchor);
    suppressScrollUntil = Date.now() + 200;
    const group = currentGroup(), filter = isFiltered();
    let messages = [];
    if (group) { try { messages = archive().search(searchOptions()); } catch (error) { banner(errorText(error)); } }
    if (!filter && focusedSource && focusedSource.accountId === state.accountId && focusedSource.groupId === activeGroupId && !messages.some(message=>message.id===focusedSource.id)) messages = [...messages,focusedSource].sort((a,b)=>Date.parse(a.sentAt)-Date.parse(b.sentAt)||a.id.localeCompare(b.id));
    messages = messages.filter(message => !window.ReaderPersonalization.isSystemNotice(message));
    const member = memberId && M.findMembers(state, activeGroupId, '').find(m => m.id === memberId);
    $('member-filter-button').replaceChildren(node('span', '', member ? shortText(member.name, 8) : '全部成员'), node('span', 'down-chevron', '⌄'));
    $('member-filter-button').classList.toggle('active', !!memberId);
    $('date-filter-button').classList.toggle('active', !!($('date-from').value || $('date-to').value));
    text('result-count', messages.length + (filter ? ' 条匹配消息' : focusedSource ? ' 条消息 · 含总结来源快照' : ' 条本地消息'));
    show('clear-filters', filter); renderProgressButtons();
    if (imageObserver) imageObserver.disconnect();
    const children = [];
    if (!messages.length) {
      const empty = node('div', 'reader-empty'); const emblem = node('span', 'empty-icon'); emblem.append(icon(filter ? 'search' : 'book')); empty.append(emblem);
      if (state.settings.readerStandby === true && !activeGroupId) {
        const selectedGroups = state.groups.filter(item => item.selected), total = selectedGroups.reduce((sum,item) => sum + U.count(state,item.id),0);
        empty.classList.add('standby-empty'); empty.append(node('h2', '', '暂时离开，也不会漏掉提醒'));
        empty.append(node('p', '', selectedGroups.length + ' 个群保持同步 · 共 ' + total + ' 条未读新消息\n点击左侧任一群，清除该群提醒并回到原阅读位置。'));
        const last = state.groups.find(item => item.id === state.settings.activeGroupId);
        if (last) empty.append(button('继续阅读「' + shortText(last.name,16) + '」', 'secondary-button', () => { if(setGroup(last.id) !== false && native) rpc('openOfficial',{groupId:last.id}).catch(handleError); }, 'book'));
        empty.append(node('p', 'small-note', '保持微阅打开且 Mac 未休眠时可持续同步；休眠或断网期间会延迟，恢复后继续补收。'));
      } else {
      empty.append(node('h2', '', filter ? '没有找到匹配消息' : '让值得细读的消息留在这里'));
      empty.append(node('p', '', filter ? '试试更换成员、关键词或时间范围。\n这里仅搜索已经保存在本机的消息。' : !group ? '先在官方页面登录微博，\n再从左侧选择你想阅读的群聊。' : !group.selected ? '在左侧「管理」中开启此群的本地保存。\n在官方页面浏览后，消息会显示在这里。' : '正在同步此群消息，请稍候。\n可点击「加载更早 500 条」继续补充历史。'));
      empty.append(button(filter ? '清除筛选' : '打开官方聊天', 'secondary-button', filter ? resetFilters : () => setMode('official'), filter ? 'refresh' : 'chat'));
      }
      children.push(empty);
    }
    let anchor = ReaderViewPolicy.chooseAnchor({ state, groupId: activeGroupId, messages, visible: previousAnchor, remembered: viewportAnchors.get(activeGroupId), restore: !!options.restore, filtered: filter });
    if (!anchor && !filter && messages.length) {
      const saved = viewportAnchors.get(activeGroupId) || (state.progress[activeGroupId] || {}).auto;
      const original = saved && archive().find(activeGroupId, saved.messageId);
      if (original && window.ReaderPersonalization.isSystemNotice(original)) {
        const nearest = messages.find(message => Date.parse(message.sentAt) >= Date.parse(original.sentAt)) || messages[messages.length - 1];
        anchor = { accountId: state.accountId, groupId: activeGroupId, messageId: nearest.id, offset: 0 };
      }
    }
    const previousGroup = renderedGroupId;
    renderedMessages = messages; renderedSpeakers = window.ReaderSpeakerGroups.describeAll(messages, dayDate); renderedGroupId = activeGroupId; renderedFiltered = filter; renderSelection();
    if (!messages.length) { readerList.clear(); replace('messages', children); }
    else readerList.setItems(messages, {
      anchor: !options.reset && anchor ? { ...anchor, key: anchor.accountId + ':' + anchor.groupId + ':' + anchor.messageId } : null,
      scrollTop: options.reset || options.restore || previousGroup !== activeGroupId ? 0 : oldScroll
    });
    refreshMountedCards();
  }
  function refreshMountedCards() {
    const contextKeys = new Set(context.map(M.messageKey));
    $('messages').querySelectorAll('.message-card').forEach(card => {
      const key = card.dataset.messageKey, checked = selected.has(key);
      const reference = { accountId: card.dataset.accountId, groupId: card.dataset.groupId, id: card.dataset.messageId };
      const manual = renderMessageToggle(card, '.manual-progress-action', 'manual', reference);
      const bookmark = renderMessageToggle(card, '.message-bookmark-action', 'bookmark', reference);
      renderMessageToggle(card, '.message-collect-action', 'collection', reference);
      card.classList.toggle('selected', checked); card.classList.toggle('in-ai-context', contextKeys.has(key)); card.classList.toggle('filtered-member', !!memberId);
      card.querySelector('.message-select').checked = checked;
      updateReadingMarkers(card, bookmark.pressed, manual.pressed);
      const message = archive().find(card.dataset.groupId, card.dataset.messageId) || renderedMessages.find(item => M.messageKey(item) === key);
      if (message) {
        const followed = window.ReaderPersonalization.isFollowed(state, message);
        card.classList.toggle('reader-followed', followed);
        const badge = card.querySelector('.reader-followed-badge'); if (badge) badge.hidden = !followed;
        if (inlineTranslation) inlineTranslation.mount(card.querySelector('.message-inline-translation'), message);
      }
    });
  }
  function renderMessageToggle(card, selector, kind, message) {
    const status = messageToggles.status(kind, message), control = card.querySelector(selector);
    if (!control) return status;
    const labels = { manual: ['从这里阅读', '已设续读点'], bookmark: ['加入书签', '已加书签'], collection: ['加入收藏', '已收藏'] };
    const descriptions = {
      manual: ['将这条消息设为手动续读点', '再次点击取消这个手动续读点，其他阅读位置保留'],
      bookmark: ['加入书签；已有最近删除的书签会恢复，备注与快照保留', '再次点击取消本消息的书签，可从最近删除恢复'],
      collection: ['直接收藏这条消息；已有最近删除的单条收藏会恢复', '再次点击取消本消息的单条收藏，多条合集与讨论保留']
    };
    control.disabled = status.saving || !ready || loadFailed || quitting || cleanupBusy || (kind === 'collection' && collectionsBusy);
    control.classList.toggle('is-active', status.pressed);
    control.classList.toggle('has-bookmark', kind === 'bookmark' && status.pressed);
    control.classList.toggle('save-failed', !!status.error);
    control.setAttribute('aria-pressed', String(status.pressed)); control.setAttribute('aria-busy', String(status.saving));
    control.querySelector('span').textContent = labels[kind][status.pressed ? 1 : 0];
    control.title = status.saving ? '正在保存，请稍候' : status.error ? '上次保存失败；点击重试本次修改，记录与后续编辑会保留。' : descriptions[kind][status.pressed ? 1 : 0];
    return status;
  }
  function updateReadingMarkers(card, bookmarked, manual) {
    card.classList.toggle('is-bookmarked', bookmarked);
    card.classList.toggle('is-manual-resume', manual);
    const markers = card.querySelector('.message-reading-markers');
    if (!markers) return;
    markers.hidden = !bookmarked && !manual;
    markers.querySelector('.bookmark-indicator').hidden = !bookmarked;
    markers.querySelector('.manual-resume-indicator').hidden = !manual;
  }
  function messageCard(message) {
    const key = M.messageKey(message), snapshotOnly = !archive().find(message.groupId,message.id);
    const card = node('article', 'message-card' + (context.some(item => M.messageKey(item) === key) ? ' in-ai-context' : '') + (selected.has(key) ? ' selected' : '') + (memberId ? ' filtered-member' : ''));
    card.dataset.messageId = message.id; card.dataset.messageKey = key; card.dataset.groupId = message.groupId; card.dataset.accountId = message.accountId;
    const check = document.createElement('input'); check.type = 'checkbox'; check.className = 'message-select'; check.checked = selected.has(key);
    check.disabled = snapshotOnly;
    check.setAttribute('aria-label', '选择 ' + message.senderName + ' ' + fullDate(message.sentAt) + ' 的消息');
    check.addEventListener('change', () => { if (check.checked) selected.add(key); else selected.delete(key); card.classList.toggle('selected', check.checked); renderSelection(); });
    const content = node('div', 'message-content'), heading = node('div', 'message-heading');
    const name = node('span', 'message-name', message.senderName || '未命名成员'); name.title = (message.senderName || '未命名成员') + '\n成员 ID ' + message.senderId;
    const time = node('time', 'message-time', clockDate(message.sentAt)); time.dateTime = message.sentAt; time.title = fullDate(message.sentAt);
    const followBadge = node('span', 'reader-followed-badge', '★ 重点关注'); followBadge.hidden = !window.ReaderPersonalization.isFollowed(state, message);
    heading.append(name, followBadge, node('span', 'message-user-id', 'ID ' + message.senderId), time);
    const markers = node('div', 'message-reading-markers'); markers.hidden = true;
    const bookmarkMarker = node('span', 'bookmark-indicator'); bookmarkMarker.hidden = true;
    bookmarkMarker.append(icon('bookmark'), node('span', '', '已加书签'));
    const manualMarker = node('span', 'manual-resume-indicator'); manualMarker.hidden = true;
    manualMarker.append(icon('book'), node('span', '', '手动续读点'));
    markers.append(bookmarkMarker, manualMarker);
    const bodyRow = node('div', 'message-body-row'); bodyRow.append(check, node('p', 'message-body', message.text || '［非文本消息］'));
    content.append(heading, markers, bodyRow, node('div', 'message-inline-translation'));
    if (snapshotOnly) content.append(node('p','context-warning','时段总结保存的原消息快照 · 未重新加入本地消息缓存，阅读位置保持不变。'));
    if (snapshotOnly && message.attachments && message.attachments.length) content.append(node('p','context-warning',message.attachments.map(item=>(item.name || '附件')+'（仅有附件信息，正文未读取）').join('\n')));
    if (!snapshotOnly && message.attachments && message.attachments.length) {
      const attachments = node('div', 'message-attachments');
      message.attachments.forEach((attachment, index) => attachments.append(attachmentCard(message, attachment, index))); content.append(attachments);
    }
    const actions = node('div', 'message-actions');
    const copy = button('复制', 'message-copy-action', () => copyMessage(message), 'copy');
    copy.disabled = !window.ReaderMessageActions.copyText(message); actions.append(copy);
    if(snapshotOnly){content.prepend(actions);card.append(content);return card;}
    actions.append(button('从这里阅读', 'manual-progress-action', () => toggleMessageAction('manual', message), 'book'));
    actions.append(button('加入书签', 'message-bookmark-action', () => toggleMessageAction('bookmark', message), 'bookmark'));
    actions.append(button('加入收藏', 'message-collect-action', () => toggleMessageAction('collection', message), 'folder'));
    if (window.ReaderMessageActions.hasEnglish(message.text)) actions.append(button('翻译成中文', 'message-translate-action', () => inlineTranslation.translate(message).catch(handleError), 'spark'));
    actions.append(button('加入讨论', 'message-discussion-action', () => addContext([message]), 'plus'));
    content.prepend(actions); card.append(content); return card;
  }
  async function copyMessage(message) {
    if (message.accountId !== state.accountId) return;
    const text = window.ReaderMessageActions.copyText(message); if (!text) return;
    try {
      if (native) await rpc('copy', {text});
      else await navigator.clipboard.writeText(text);
      notify('已复制');
    } catch (error) { handleError(error); }
  }
  async function attachmentAction(action, reference, status) {
    if (!native) { notify('请在微阅 Mac 应用中打开附件。'); return; }
    const epoch = accountEpoch; if (status) status.textContent = action === 'downloadAttachment' ? '正在准备下载…' : action === 'revealAttachment' ? '正在定位本地文件…' : '正在打开…';
    try {
      const result = await rpc(action, reference); if (epoch !== accountEpoch) return;
      if (status) status.textContent = result.cancelled ? '已取消' : action === 'downloadAttachment' ? '下载已完成' : action === 'revealAttachment' ? '已在访达中显示' : '已打开';
    } catch (error) { if (epoch === accountEpoch) { if (status) status.textContent = errorText(error); else handleError(error); } }
  }
  function attachmentCard(message, attachment, index) {
    const presentation = ReaderViewPolicy.attachmentPresentation(attachment), reference = ReaderViewPolicy.attachmentReference(message, index);
    const card = node('div', 'attachment-card ' + (presentation.kind === 'image' ? 'image-attachment' : 'file-attachment'));
    const supportsAI = ['image', 'document'].includes(presentation.kind), epoch = accountEpoch;
    card.classList.toggle('attachment-floating-card', supportsAI); card.dataset.attachmentIndex = String(index);
    const status = node('span', 'attachment-status'); status.setAttribute('aria-live', 'polite');
    const feedback = node('div', 'attachment-feedback'); feedback.append(status);
    const controls = node('div', 'attachment-controls');
    const current = () => epoch === accountEpoch && message.accountId === state.accountId && card.isConnected;
    const open = () => { if (current()) attachmentAction('openAttachment', reference, status); };
    if (supportsAI) { controls.classList.add('attachment-floating-actions'); controls.setAttribute('role', 'toolbar'); controls.setAttribute('aria-label', presentation.name + '的操作'); card.append(controls); }
    if (presentation.kind === 'image') {
      const frame = node('div', 'image-frame'), placeholder = node('span', 'image-placeholder', native ? '图片加载中…' : '在 Mac 应用中预览图片');
      const picture = document.createElement('img'); picture.alt = presentation.name; picture.hidden = true; picture.decoding = 'async';
      frame.append(picture, placeholder); frame.setAttribute('role', 'button'); frame.tabIndex = 0; frame.setAttribute('aria-label', '打开图片：' + presentation.name);
      const previewStatus = node('span', 'attachment-preview-status'); feedback.prepend(previewStatus);
      const suppressed = () => !!(window.ReaderCleanup && ReaderCleanup.isMediaSuppressed(state, attachment, message));
      card._previewSuppressed = suppressed;
      const openImage = () => { if (current()) suppressed() ? restorePreview() : open(); };
      frame.addEventListener('click', openImage);
      frame.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); openImage(); } });
      const cacheKey = state.accountId + ':' + message.groupId + ':' + message.id + ':' + index + ':' + JSON.stringify(attachment), epoch = accountEpoch;
      let loading = false;
      const load = async () => {
        if (!native || loading || picture.dataset.loaded === 'true' || epoch !== accountEpoch || suppressed()) return;
        loading = true; retry.hidden = true; placeholder.hidden = false; placeholder.textContent = '图片加载中…'; picture.hidden = true;
        try {
          let url = previewCache.get(cacheKey);
          if (!url) { const result = await rpc('attachmentPreview', reference); if (epoch !== accountEpoch || suppressed()) return; url = ReaderViewPolicy.safePreviewURL(result); if (!url) throw new Error('未取得安全的图片预览'); previewCache.set(cacheKey, url); }
          picture.onload = () => { if (epoch !== accountEpoch || suppressed()) return; picture.hidden = false; picture.dataset.loaded = 'true'; retry.hidden = true; placeholder.hidden = true; previewStatus.textContent = ''; loading = false; };
          picture.onerror = () => { if (epoch !== accountEpoch || suppressed()) return; retry.hidden = false; previewCache.delete(cacheKey); placeholder.hidden = false; placeholder.textContent = '图片暂不可用'; previewStatus.textContent = '点击重试，或从更多菜单到微博查看'; loading = false; };
          picture.src = url;
        } catch (error) { if (epoch === accountEpoch) { retry.hidden = false; placeholder.textContent = '图片暂不可用'; previewStatus.textContent = errorText(error); } loading = false; }
      };
      const restorePreview = () => {
        if (!current()) return;
        if (suppressed()) { state = ReaderCleanup.restoreMedia(state, message.localPath ? { localPath: message.localPath } : attachment); archiveDirty = true; persistQuietly(); }
        previewCache.delete(cacheKey); delete picture.dataset.loaded; load();
      };
      const retry = button(suppressed() ? '重新下载图片' : '重试', 'text-button', restorePreview); retry.hidden = !suppressed();
      retry.classList.add('attachment-preview-retry'); feedback.append(retry);
      if (suppressed()) { placeholder.textContent = '本地图片已清理'; previewStatus.textContent = '需要时可重新下载，原始消息仍保留。'; }
      card.append(frame); card._loadPreview = load;
    } else {
      const symbol = node('span', 'file-emblem'); symbol.append(icon(presentation.kind === 'document' ? 'folder' : 'export'));
      const detail = node('div', 'file-detail'); detail.append(node('strong', '', presentation.name), node('span', '', presentation.detail));
      const file = button('', 'attachment-open', open); file.setAttribute('aria-label', '打开' + presentation.name); file.title = '点击预览'; file.append(symbol, detail); card.append(file);
      if (!supportsAI) { controls.append(button('打开', 'text-button', open)); card.append(controls); }
    }
    const official = () => { if (!current()) return; setMode('official', { navigate: false }); if (native) rpc('openOfficial', reference).catch(handleError); };
    if (supportsAI) {
      let lastIntent = 'interpret';
      const retryTask = button('重试', 'text-button attachment-task-retry', () => perform(lastIntent)); retryTask.hidden = true; feedback.append(retryTask);
      const perform = async intent => {
        if (!current() || card.dataset.taskBusy === 'true') return;
        lastIntent = intent; retryTask.hidden = true; card.dataset.taskBusy = 'true';
        try { await readAttachment(message, index, intent, status); }
        catch (error) { if (current()) { status.textContent = errorText(error); status.dataset.failed = 'true'; } }
        finally { delete card.dataset.taskBusy; if (current()) { retryTask.hidden = status.dataset.failed !== 'true'; renderAIControls(); } }
      };
      const interpret = button('解读', 'text-button attachment-ai-action attachment-read', () => perform('interpret'), 'spark');
      interpret.title = '只解读这份附件，直接在右侧开始新讨论';
      const translate = button('翻译', 'text-button attachment-ai-action attachment-translate', () => perform('translate'));
      translate.title = '只翻译这份附件，直接在右侧开始新讨论';
      controls.append(interpret, translate);
      const more = node('label', 'attachment-more'), moreLabel = node('span', '', '⋯'), menu = document.createElement('select');
      moreLabel.setAttribute('aria-hidden', 'true'); menu.className = 'attachment-more-menu'; menu.title = '更多附件操作'; menu.setAttribute('aria-label', presentation.name + '：更多附件操作');
      [['','更多操作'],['add','加入讨论'],['save','另存为…'],['reveal','在访达中显示'],['official','到微博查看']].forEach(([value,label]) => { const option = node('option', '', label); option.value = value; option.disabled = !value; menu.append(option); }); menu.value = '';
      menu.addEventListener('change', async event => {
        event.stopPropagation(); const action = menu.value; menu.value = ''; if (!current()) return;
        if (action === 'add') { await perform('add'); return; }
        if (action === 'official') { official(); return; }
        if (!['save', 'reveal'].includes(action)) return;
        menu.disabled = true;
        try { await attachmentAction(action === 'save' ? 'downloadAttachment' : 'revealAttachment', reference, status); }
        finally { menu.disabled = false; }
      });
      more.append(moreLabel, menu); controls.append(more);
      card.addEventListener('mouseenter', () => { delete card.dataset.toolsDismissed; });
      card.addEventListener('focusin', () => { delete card.dataset.toolsDismissed; });
      card.addEventListener('keydown', event => { if (event.key === 'Escape') { card.dataset.toolsDismissed = 'true'; event.stopPropagation(); } });
      const locked = settingsBusy || busyAI || inlineBusy() || preparingContext || cancellingAI || quitting || cleanupBusy || preferencesSaving || discussionHistoryBusy || modelCapabilitiesLoading();
      interpret.disabled = translate.disabled = locked;
      menu.querySelector('option[value="add"]').disabled = locked;
    } else {
      controls.append(button('到微博查看', 'text-button attachment-official', official));
    }
    card.append(feedback);
    return card;
  }
  function observeMessageImages() {
    if (imageObserver) imageObserver.disconnect();
    if (!imageObserver) imageObserver = new IntersectionObserver(entries => { entries.forEach(entry => { if (entry.isIntersecting && entry.target._loadPreview) { imageObserver.unobserve(entry.target); entry.target._loadPreview(); } }); }, { root: $('reader-scroll'), rootMargin: '180px' });
    $('messages').querySelectorAll('.image-attachment').forEach(card => { if (!card._previewSuppressed || !card._previewSuppressed()) imageObserver.observe(card); });
  }
  function renderSelection() { show('selection-bar', selected.size > 0); text('selected-count', '已选 ' + selected.size + ' 条'); }
  function renderMembers() {
    const members = activeGroupId ? M.findMembers(state, activeGroupId, $('member-search').value.trim()).filter(member => !window.ReaderPersonalization.isSystemNotice({senderId: member.id, senderName: member.name})) : [];
    const all = button('全部成员', 'member-option' + (!memberId ? ' active' : ''), () => { memberId = ''; show('member-popover', false); filterChanged(); });
    const children = [all];
    members.forEach(member => {
      const option = node('button', 'member-option' + (memberId === member.id ? ' active' : '')); option.type = 'button';
      const label = node('span'); label.append(node('strong', '', member.name || '未命名成员'), node('small', '', 'ID ' + member.id));
      option.append(label, node('span', '', member.count + ' 条')); option.addEventListener('click', () => { memberId = member.id; show('member-popover', false); filterChanged(); }); children.push(option);
    });
    if (!members.length) children.push(node('p', 'sidebar-empty', '没有匹配成员。仅包含本地消息中出现过的成员。'));
    replace('member-list', children);
  }
  function visibleMessage() {
    if (mode !== 'reader' || activeView !== 'chats') return null;
    const anchor = readerList.visibleAnchor();
    if(anchor && !archive().find(activeGroupId,anchor.messageId))return null;
    return anchor ? { accountId: anchor.accountId, groupId: anchor.groupId, messageId: anchor.messageId, offset: anchor.offset, visualOffset: anchor.visualOffset } : null;
  }
  function captureSessionStart() {
    if (!activeGroupId || sessionGroups.has(activeGroupId)) return;
    const first = (state.progress[activeGroupId] || {}).auto || visibleMessage(); if (!first) return;
    try { M.setProgress(state, { groupId: activeGroupId, messageId: first.messageId, kind: 'sessionStart', offset: first.offset || 0 }); sessionGroups.add(activeGroupId); persistQuietly(); } catch (error) { handleError(error); }
  }
  function renderProgressButtons() {
    const progress = state.progress[activeGroupId] || {};
    const buttons = [
      ['manual-position', 'manual', '回到手动续读点', '尚未设置', '由消息上的「从这里阅读」固定，滚动不会覆盖。'],
      ['return-position', 'returnPoint', '返回跳转前', '尚未跳转', '回到查看最新、定位原文或跳转续读点之前的位置。']
    ];
    buttons.forEach(([id, kind, label, empty, explanation]) => {
      const control = $(id), anchor = progress[kind];
      const message = anchor && archive().find(activeGroupId, anchor.messageId);
      const timestamp = anchor && (anchor.messageSentAt || (message && message.sentAt));
      const full = timestamp ? fullDate(timestamp) : '';
      const compact = full.replace('年', '-').replace('月', '-').replace('日', '');
      control.disabled = !anchor; control.hidden = !anchor;
      control.replaceChildren(node('span', 'reading-position-label', label), node('time', 'reading-position-time', anchor ? compact || '消息时间未知' : empty));
      if (timestamp) control.querySelector('time').dateTime = timestamp;
      control.title = explanation + (anchor ? '\n消息时间：' + (full || '未知') : '\n' + empty);
      control.setAttribute('aria-label', label + '，' + (anchor ? '消息时间 ' + (full || '未知') : empty));
    });
  }
  function scrollToMessage(id, offset = 0, highlight = true) {
    const key = state.accountId + ':' + activeGroupId + ':' + id;
    suppressScrollUntil = Date.now() + 350;
    if (!readerList.scrollTo(key, offset)) return false;
    const card = readerList.card(key);
    if (highlight && card) { card.classList.add('target-message'); setTimeout(() => card.classList.remove('target-message'), 2200); }
    return true;
  }
  function saveReturnPoint() {
    const anchor = visibleMessage() || (state.progress[activeGroupId] || {}).auto;
    if (anchor && activeGroupId) { M.setProgress(state, { groupId: activeGroupId, messageId: anchor.messageId, offset: anchor.offset || 0, kind: 'returnPoint' }); persistQuietly(); }
  }
  function goToReadingPosition(kind) {
    // A pending wheel save belongs to auto, even when the next action is a jump.
    // Settle it before reading the destination so "auto" never uses stale data.
    settleReading();
    const anchor = (state.progress[activeGroupId] || {})[kind]; if (!anchor) return;
    if (!archive().find(activeGroupId, anchor.messageId)) { banner('此阅读位置的原消息尚未载入本机，请加载对应历史。消息时间：' + fullDate(anchor.messageSentAt)); return; }
    if (window.ReaderPersonalization.isSystemNotice(archive().find(activeGroupId, anchor.messageId))) { notify('此位置对应已隐藏的系统通知，换一条消息设置续读点即可。'); return; }
    ++readingNavigationEpoch;
    if (kind !== 'returnPoint') saveReturnPoint();
    resetFilters();
    if (!scrollToMessage(anchor.messageId, anchor.offset)) banner('此阅读位置的原消息尚未载入本机，请加载对应历史。');
    renderProgressButtons();
  }
  function jumpTo(groupId, messageId, snapshot) {
    settleReading();
    const original = archive().find(groupId, messageId) || (snapshot && snapshot.accountId === state.accountId && snapshot.groupId === groupId && snapshot.id === messageId ? snapshot : null);
    if (original && window.ReaderPersonalization.isSystemNotice(original)) { notify('这条来自「粉丝群」的系统通知已在专注阅读中隐藏，保存的书签或收藏仍可查看。'); return; }
    if (!original) { banner('原消息尚未载入本机，无法定位。已保存的完整快照仍可在标记或收藏中查看。请在官方页面加载对应历史。'); return; }
    ++readingNavigationEpoch; focusedSource = archive().find(groupId,messageId) ? null : original;
    if (activeView === 'chats' && mode === 'reader') saveReturnPoint();
    activeGroupId = groupId; activeView = 'chats'; mode = 'reader'; memberId = '';
    if (state.settings.readerStandby === true) mutate(() => state.settings.readerStandby = false);
    if ((state.progress[groupId] || {}).standbyView) mutate(() => delete state.progress[groupId].standbyView);
    $('message-search').value = ''; $('date-from').value = ''; $('date-to').value = '';
    renderSidebar(); renderHeader(); renderViews(); renderReader({ restore: true }); saveViewPreferences();
    if (!scrollToMessage(messageId)) banner('原消息不在当前本地视图，已保留快照。');
  }
  function openDialog(id) { $(id).showModal(); scheduleLayout(); }
  async function toggleMessageAction(kind, message) {
    if (!ready || loadFailed || !state.accountId || quitting || cleanupBusy || (kind === 'collection' && collectionsBusy) || messageToggles.status(kind, message).saving) return;
    try {
      if (message.accountId !== state.accountId) return;
      if (kind === 'manual') settleReading();
      await messageToggles.toggle(kind, message);
    } catch (error) { handleError(error); }
  }
  function openBookmarkNote(bookmark) {
    if (!bookmark || bookmark.deletedAt || bookmark.accountId !== state.accountId || bookmarkNoteSaving) return;
    bookmarkTarget = bookmark.id;
    text('bookmark-message-time', groupName(bookmark.groupId) + ' · ' + fullDate(bookmark.messageSentAt));
    text('bookmark-preview', bookmark.snapshot.senderName + '：' + (bookmark.snapshot.text || '［非文本消息］'));
    $('bookmark-note').value = bookmark.note || ''; $('bookmark-form').querySelectorAll('button, textarea').forEach(control => { control.disabled = false; });
    show('bookmark-error', false); openDialog('bookmark-dialog'); $('bookmark-note').focus();
  }
  function renderBookmarks() {
    $('bookmarks-active').classList.toggle('selected', !deletedBookmarks); $('bookmarks-deleted').classList.toggle('selected', deletedBookmarks);
    const scope = $('bookmark-group-filter');
    scope.replaceChildren(new Option('所有群聊', ''), ...state.groups.map(group => new Option(group.name, group.id))); scope.value = bookmarkGroupFilter;
    const items = state.bookmarks.filter(b => (!bookmarkGroupFilter || b.groupId === bookmarkGroupFilter) && (deletedBookmarks ? !!b.deletedAt : !b.deletedAt)).slice().sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
    text('bookmarks-total', items.length + (deletedBookmarks ? ' 个可恢复书签' : ' 个书签 · 无数量上限'));
    const children = items.map(bookmark => {
      const card = node('article', 'bookmark-card'), top = node('div', 'bookmark-topline'), date = node('div', 'bookmark-date');
      card.dataset.bookmarkId = bookmark.id;
      date.append(icon('bookmark'), node('time', '', fullDate(bookmark.createdAt))); top.append(date); card.append(top);
      if (bookmark.note) card.append(node('p', 'bookmark-note', bookmark.note));
      card.append(node('p', 'bookmark-quote', bookmark.snapshot.text || '［非文本消息］'));
      card.append(node('p', 'bookmark-meta', groupName(bookmark.groupId) + ' · ' + bookmark.snapshot.senderName + '（ID ' + bookmark.snapshot.senderId + '）\n消息时间 ' + fullDate(bookmark.messageSentAt)));
      const bottom = node('div', 'card-bottom'), actions = node('div');
      if (deletedBookmarks) {
        bottom.append(node('span', 'muted', '删除于 ' + fullDate(bookmark.deletedAt)));
        actions.append(button('恢复书签', 'text-button', async () => { try { M.restoreBookmark(state, bookmark.id); await persist(); renderSidebar(); renderBookmarks(); notify('书签已恢复'); } catch (error) { handleError(error); } }, 'refresh'));
      } else {
        const present = state.messages.some(m => m.groupId === bookmark.groupId && m.id === bookmark.messageId);
        bottom.append(button(present ? '定位原文' : '原文待加载 · 查看说明', 'text-button', () => jumpTo(bookmark.groupId, bookmark.messageId), 'book'));
        actions.append(button(bookmark.note ? '编辑备注' : '添加备注', 'text-button bookmark-edit-action', () => openBookmarkNote(bookmark), 'book'));
        actions.append(button('加入讨论', 'text-button', () => addContext([bookmark.snapshot]), 'spark'));
        actions.append(button('删除', 'text-button', async () => { try { M.removeBookmark(state, bookmark.id); await persist(); renderSidebar(); renderBookmarks(); notify('书签已移至「最近删除」，可随时恢复'); } catch (error) { handleError(error); } }, 'trash'));
      }
      bottom.append(actions); card.append(bottom); return card;
    });
    if (!children.length) children.push(emptyLibrary(deletedBookmarks ? '没有已删除的书签' : '为下一次阅读留一个位置', deletedBookmarks ? '删除的书签会保留在这里，可以随时恢复。' : '在「专注阅读」中，将鼠标移到一条消息上，\n点击「加入书签」直接保存，备注可在这里编辑。', 'bookmark'));
    replace('bookmarks-list', children);
    refreshMountedCards();
  }
  function emptyLibrary(title, detail, glyph) { const empty = node('div', 'library-empty'), emblem = node('span', 'empty-icon'); emblem.append(icon(glyph)); empty.append(emblem, node('h2', '', title), node('p', '', detail)); return empty; }
  function collectionItems() {
    const query = $('collection-search').value.trim().toLocaleLowerCase();
    return state.collections.filter(collection => (deletedCollections ? !!collection.deletedAt : !collection.deletedAt) && (!query || collection.name.toLocaleLowerCase().includes(query) || collection.messages.some(message => message.text.toLocaleLowerCase().includes(query) || message.senderName.toLocaleLowerCase().includes(query)))).slice().sort((a, b) => Date.parse(deletedCollections ? b.deletedAt : b.createdAt) - Date.parse(deletedCollections ? a.deletedAt : a.createdAt));
  }
  function updateCollectionSelection() {
    const visible = collectionItems(), visibleIds = new Set(visible.map(collection => collection.id));
    selectedCollectionIds.forEach(id => { if (!visibleIds.has(id)) selectedCollectionIds.delete(id); });
    const all = $('collections-select-all'); all.checked = visible.length > 0 && selectedCollectionIds.size === visible.length; all.indeterminate = selectedCollectionIds.size > 0 && selectedCollectionIds.size < visible.length; all.disabled = !visible.length || collectionsBusy;
    text('collections-selection-count', selectedCollectionIds.size ? '已选 ' + selectedCollectionIds.size + ' 组' : '全选当前筛选');
    text('collections-bulk-action', deletedCollections ? '恢复所选' : '删除所选'); $('collections-bulk-action').disabled = !selectedCollectionIds.size || collectionsBusy;
    const undoable = collectionUndo && state.collections.some(collection => collectionUndo.ids.includes(collection.id) && collection.deletedAt === collectionUndo.deletedAt);
    show('collections-undo-bar', !!undoable); $('collections-undo').disabled = collectionsBusy;
    if (undoable) text('collections-undo-text', '已移入最近删除，可撤销本次操作');
  }
  function renderCollections() {
    const items = collectionItems();
    $('collections-active').classList.toggle('selected', !deletedCollections); $('collections-deleted').classList.toggle('selected', deletedCollections);
    text('collections-total', items.length + (deletedCollections ? ' 组可恢复资料' : $('collection-search').value.trim() ? ' 组匹配资料' : ' 组资料'));
    const children = items.map(collection => {
      const card = node('article', 'collection-card' + (selectedCollectionIds.has(collection.id) ? ' selected' : '')), top = node('div', 'collection-topline');
      const check = document.createElement('input'); check.type = 'checkbox'; check.className = 'collection-select'; check.checked = selectedCollectionIds.has(collection.id); check.disabled = collectionsBusy; check.setAttribute('aria-label', '选择收藏：' + collection.name);
      check.addEventListener('change', () => { if (check.checked) selectedCollectionIds.add(collection.id); else selectedCollectionIds.delete(collection.id); card.classList.toggle('selected', check.checked); updateCollectionSelection(); });
      top.append(check, deletedCollections ? node('strong', 'collection-title', collection.name) : button(collection.name, 'collection-title', () => openCollection(collection)), node('span', 'collection-count-chip', collection.messages.length + ' 条消息')); card.append(top);
      card.append(node('p', 'collection-preview', collection.messages.map(m => m.senderName + '：' + m.text).join('\n')));
      const sources = Array.from(new Set(collection.messages.map(m => groupName(m.groupId))));
      card.append(node('p', 'collection-meta', sources.join('、') + ' · ' + (deletedCollections ? '删除于 ' + fullDate(collection.deletedAt) : '收藏于 ' + fullDate(collection.createdAt))));
      const bottom = node('div', 'card-bottom'), actions = node('div');
      if (deletedCollections) {
        bottom.append(node('span', 'muted', '原始聊天、附件、标记和 AI 讨论均保留'));
        actions.append(button('恢复收藏', 'text-button', () => restoreCollectionSelection([collection.id]), 'refresh'));
      } else {
        bottom.append(button(collection.discussionId ? '继续讨论' : '打开资料并讨论', 'text-button', () => openCollection(collection), 'spark'));
        actions.append(button('重命名', 'text-button', () => renameCollection(collection)));
        actions.append(button('导出资料', 'text-button', () => exportCollection(collection), 'export'));
        actions.append(button('删除', 'text-button collection-delete', () => confirmCollectionDeletion([collection.id]), 'trash'));
      }
      bottom.append(actions); card.append(bottom); return card;
    });
    if (!children.length) children.push(emptyLibrary($('collection-search').value.trim() ? '没有匹配的收藏' : deletedCollections ? '没有已删除的收藏' : '收藏一段有价值的讨论', deletedCollections ? '删除的收藏会保留在这里，恢复后可以继续原有讨论。' : '勾选群聊消息，点击「收藏资料」。\n完整消息与出处会一起留在本机。', 'folder'));
    replace('collections-list', children); updateCollectionSelection(); refreshMountedCards();
  }
  function confirmCollectionDeletion(ids) {
    if (collectionsBusy || quitting) return;
    pendingCollectionDeleteIds = Array.from(new Set(ids)).filter(id => state.collections.some(collection => collection.id === id && !collection.deletedAt));
    if (!pendingCollectionDeleteIds.length) return;
    const names = pendingCollectionDeleteIds.slice(0, 3).map(id => state.collections.find(collection => collection.id === id).name);
    text('collection-delete-summary', '将 ' + pendingCollectionDeleteIds.length + ' 组收藏移入「最近删除」。');
    text('collection-delete-names', names.join('\n') + (pendingCollectionDeleteIds.length > 3 ? '\n等 ' + pendingCollectionDeleteIds.length + ' 组资料' : ''));
    text('confirm-collection-delete', '删除 ' + pendingCollectionDeleteIds.length + ' 组收藏'); $('confirm-collection-delete').disabled = false; show('collection-delete-error', false); openDialog('collection-delete-dialog');
  }
  async function restoreCollectionSelection(ids) {
    if (collectionsBusy || quitting || !ids.length) return;
    const epoch = accountEpoch; collectionsBusy = true; updateCollectionSelection();
    try {
      M.restoreCollections(state, ids); await persist(); if (epoch !== accountEpoch) return;
      ids.forEach(id => selectedCollectionIds.delete(id)); renderSidebar(); renderCollections(); notify('已恢复 ' + ids.length + ' 组收藏，原有资料和讨论仍可继续');
    } catch (error) { if (epoch === accountEpoch) handleError(error); }
    finally { if (epoch === accountEpoch) { collectionsBusy = false; renderCollections(); } }
  }
  $('collections-active').addEventListener('click', () => { deletedCollections = false; selectedCollectionIds.clear(); renderCollections(); });
  $('collections-deleted').addEventListener('click', () => { deletedCollections = true; selectedCollectionIds.clear(); renderCollections(); });
  $('collection-search').addEventListener('input', () => { selectedCollectionIds.clear(); clearTimeout(collectionSearchTimer); collectionSearchTimer = setTimeout(renderCollections, 120); });
  $('collections-select-all').addEventListener('change', event => { selectedCollectionIds.clear(); if (event.target.checked) collectionItems().forEach(collection => selectedCollectionIds.add(collection.id)); renderCollections(); });
  $('collections-bulk-action').addEventListener('click', () => { const ids = Array.from(selectedCollectionIds); if (deletedCollections) restoreCollectionSelection(ids); else confirmCollectionDeletion(ids); });
  $('collections-undo').addEventListener('click', () => { if (collectionUndo) restoreCollectionSelection(state.collections.filter(collection => collectionUndo.ids.includes(collection.id) && collection.deletedAt === collectionUndo.deletedAt).map(collection => collection.id)); });
  $('collection-delete-form').addEventListener('submit', async event => {
    event.preventDefault(); if (collectionsBusy || quitting || !pendingCollectionDeleteIds.length) return;
    const epoch = accountEpoch, ids = pendingCollectionDeleteIds.slice(); collectionsBusy = true; $('confirm-collection-delete').disabled = true; show('collection-delete-error', false);
    try {
      const removed = M.removeCollections(state, ids);
      if (removed.length) collectionUndo = { ids: removed.map(collection => collection.id), deletedAt: removed[0].deletedAt };
      if (ids.includes(contextCollectionId)) { contextCollectionId = null; renderContext(); }
      await persist(); if (epoch !== accountEpoch) return;
      ids.forEach(id => selectedCollectionIds.delete(id)); pendingCollectionDeleteIds = []; $('collection-delete-dialog').close(); renderSidebar(); renderCollections(); notify('已移入最近删除，可在收藏页面撤销');
    } catch (error) { if (epoch === accountEpoch) { text('collection-delete-error', '删除状态尚未保存，请重试：' + errorText(error)); show('collection-delete-error', true); renderSidebar(); renderCollections(); } }
    finally { if (epoch === accountEpoch) { collectionsBusy = false; $('confirm-collection-delete').disabled = false; updateCollectionSelection(); refreshMountedCards(); } }
  });
  function renameCollection(collection) {
    collectionEditing = true; pendingCollection = collection; pendingCollectionKeys = collection.messageIds.slice();
    text('collection-dialog-title', '重命名资料'); text('collection-selection-summary', '保留现有 ' + collection.messages.length + ' 条消息与讨论记录');
    text('confirm-collection', '保存名称'); $('collection-name').value = collection.name;
    show('collection-error', false); openDialog('collection-dialog'); $('collection-name').focus(); $('collection-name').select();
  }
  function contextText(messages) { return C.contextText(messages, groupName, fullDate); }
  function exportCollection(collection) {
    if (!native) { notify('演示模式不导出文件。请在 Mac 应用中使用导出。'); return; }
    const content = collection.name + '\n收藏于 ' + fullDate(collection.createdAt) + '\n\n' + contextText(collection.messages);
    rpc('export', { text: content, name: collection.name.replace(/[\/:*?"<>|]/g, '-') + '.txt' }).then(result => { if (!result.cancelled) notify('资料已导出'); }).catch(handleError);
  }
  function revealInspector() { if (window.ReaderLayout) ReaderLayout.setCollapsed('inspector', false); scheduleLayout(); }
  function abandonCurrentDiscussion(clearDraft = false) {
    const hadDiscussion = !!currentDiscussion();
    currentDiscussionId = null; contextCollectionId = null; show('ai-state', false);
    rememberActiveDiscussion(clearDraft || hadDiscussion);
    if (preferencesUI) preferencesUI.render();
    $('quick-prompts').hidden = !!(currentDiscussion() && currentDiscussion().messages.length);
  }
  function newDiscussion() {
    if (contextBusy()) return;
    context = []; pendingRange = null; summarySourcePage = 0;
    abandonCurrentDiscussion(true); $('ai-question').value = '';
    renderConversation(); renderContext(); renderAIControls(); refreshMountedCards(); $('ai-question').focus();
  }
  function contextBusy() { if (quitting) return true; if (settingsBusy || busyAI || inlineBusy() || preparingContext || cancellingAI || cleanupBusy || preferencesSaving || discussionHistoryBusy || modelCapabilitiesLoading()) { notify('请等待本次操作完成或取消后，再更换资料。'); return true; } return false; }
  function mergeContext(messages) {
    const map = new Map(context.map(m => [M.messageKey(m), m]));
    messages.forEach(message => map.set(M.messageKey(message), C.mergeSnapshots(map.get(M.messageKey(message)), message)));
    context = Array.from(map.values()); abandonCurrentDiscussion(); revealInspector(); renderContext(); renderConversation(); renderAIControls();
  }
  function startPreparation(label) {
    preparingContext = true; const operation = { epoch: accountEpoch, token: ++preparationToken, accountId: state.accountId };
    revealInspector(); aiState(label); renderAIControls(); renderContext(); return operation;
  }
  function preparationCurrent(operation) { return !quitting && operation.epoch === accountEpoch && operation.token === preparationToken; }
  function finishPreparation(operation) { if (preparationCurrent(operation)) { preparingContext = false; renderAIControls(); renderContext(); } }
  async function addContext(messages) {
    if (contextBusy()) return;
    const hasFiles = messages.some(message => (message.attachments || []).some(item => ['image', 'document'].includes(item.type)));
    if (!hasFiles || !native || demo) { mergeContext(messages); notify('已加入 ' + messages.length + ' 条资料，点击发送、翻译或解读时才提交给 AI'); return; }
    const operation = startPreparation('正在准备所选附件，尚未提交给 AI…'), prepared = [], failures = [];
    try {
      for (const original of messages) {
        let snapshot = clone(original);
        delete snapshot.contextScope; delete snapshot.contextAttachmentIndexes;
        for (let index = 0; index < snapshot.attachments.length; index++) {
          if (!preparationCurrent(operation)) return;
          if (!['image', 'document'].includes(snapshot.attachments[index].type)) continue;
          if ([...C.selectedExtractions(snapshot),...C.selectedModelFiles(snapshot)].some(item => item.attachmentIndex === index)) continue;
          aiState('正在准备：' + (snapshot.attachments[index].name || '附件') + ' · 尚未提交给 AI');
          try {
            const result = await rpc('extractAttachment', { accountId: operation.accountId, ...ReaderViewPolicy.attachmentReference(snapshot, index), expectedAttachment: C.expectedAttachment(snapshot, index), ...aiConfiguration() });
            if (!preparationCurrent(operation)) return;
            snapshot = C.withExtraction(snapshot, index, result);
          } catch (error) { if (!preparationCurrent(operation)) return; failures.push((snapshot.attachments[index].name || '附件') + '：' + errorText(error)); }
        }
        prepared.push(snapshot);
      }
      if (!preparationCurrent(operation)) return;
      mergeContext(prepared);
      aiState(failures.length ? '部分附件未能读取：' + failures.join('；') + '。可在资料卡中重新读取。未读取附件不会作为文件正文交给 AI。' : '资料已准备好，读取方式显示在每张资料卡中。发送时才提交给 AI。', failures.length > 0);
    } catch (error) { if (preparationCurrent(operation)) aiState(errorText(error), true); }
    finally { finishPreparation(operation); }
  }
  async function readAttachment(message, index, action, status) {
    if (!message || message.accountId !== state.accountId || contextBusy()) return false;
    if (!native || demo) { notify('请在微阅 Mac 应用中读取附件。'); return false; }
    const intent = window.ReaderAttachmentActions.normalize(action);
    const kind = ReaderViewPolicy.attachmentPresentation((message.attachments || [])[index]).kind;
    const question = window.ReaderAttachmentActions.prompt(kind, intent);
    if (intent !== 'add' && (!state.settings.baseURL || !state.settings.model || !hasAPIKey)) {
      if (status) status.textContent = '请先配置 AI 服务，再点击解读或翻译。';
      openSettings(); return false;
    }
    const label = intent === 'translate' ? '翻译' : '解读';
    const operation = startPreparation(intent === 'add' ? '正在准备附件，尚未提交给 AI…' : '正在准备附件，完成后开始' + label + '…');
    if (status) { status.textContent = '正在读取…'; if (status.dataset) delete status.dataset.failed; }
    try {
      const result = await rpc(message.localPath ? 'prepareImported' : 'extractAttachment', {accountId: operation.accountId, ...(message.localPath ? {localPath:message.localPath} : {...ReaderViewPolicy.attachmentReference(message,index),expectedAttachment:C.expectedAttachment(message,index)}), ...aiConfiguration()});
      if (!preparationCurrent(operation)) return false;
      const snapshot = C.withExtraction(message, index, result, true);
      finishPreparation(operation);
      if (intent !== 'add') {
        if (status) status.textContent = '正在' + label + '…';
        await startFocusedDiscussion([snapshot], question);
        if (preparationCurrent(operation) && status) status.textContent = label + '结果与状态见右侧' + (result.truncated ? ' · 原文读取有截断' : '');
      } else {
        mergeContext([snapshot]); aiState('附件已加入本次讨论资料，卡片会显示读取方式。发送时才提交给 AI。');
        if (status) status.textContent = '已加入讨论' + (result.truncated ? ' · 原文读取有截断' : '');
      }
      return true;
    } catch (error) { if (preparationCurrent(operation)) { if (status) { status.textContent = errorText(error); if (status.dataset) status.dataset.failed = 'true'; } aiState(errorText(error), true); } return false; }
    finally { finishPreparation(operation); }
  }
  async function startFocusedDiscussion(messages, question) {
    if (contextBusy()) return;
    context = clone(messages); abandonCurrentDiscussion(); revealInspector(); renderContext(); renderConversation();
    $('ai-question').value = question;
    await sendAI({preventDefault() {}});
  }
  function translateText(messages) {
    if (contextBusy()) return;
    const readable = messages.filter(message => message.text && message.text.trim());
    if (!readable.length) { notify('所选消息没有文字。图片请点击卡片上的「翻译」。'); return; }
    startFocusedDiscussion(C.textSnapshots(readable), C.TRANSLATE_TEXT).catch(handleError);
  }
  async function importDocument() {
    if (contextBusy()) return;
    if (!native || demo) { notify('请在微阅 Mac 应用中导入文件。'); return; }
    if (!state.accountId) { notify('请先登录微博，再导入资料。'); return; }
    const operation = startPreparation('选择文档或图片，将按当前模型准备资料…');
    try {
      const result = await rpc('importDocument', {accountId:operation.accountId,...aiConfiguration()});
      if (!preparationCurrent(operation)) return;
      if (result.cancelled) { aiState('已取消导入'); return; }
      const snapshot = C.importedMessage(operation.accountId, result); mergeContext([snapshot]);
      aiState('文件已保存到本地附件文件夹，读取方式见资料卡。发送时才交给 AI。');
    } catch (error) { if (preparationCurrent(operation)) aiState(errorText(error), true); }
    finally { finishPreparation(operation); }
  }
  async function saveContextCollection() {
    if (contextBusy() || !context.length) return;
    const epoch = accountEpoch;
    try {
      let collection = state.collections.find(item => item.id === contextCollectionId && !item.deletedAt);
      if (collection) mutate(() => { collection.messages = clone(context); collection.messageIds = context.map(M.messageKey); });
      else {
        collection = C.collection(state.accountId, context, (currentDiscussion() ? currentDiscussion().title : 'AI 资料') + ' · ' + dayDate(new Date().toISOString()));
        collection.discussionId = currentDiscussionId;
        mutate(() => { state.collections.push(collection); if (currentDiscussion()) currentDiscussion().collectionId = collection.id; }); contextCollectionId = collection.id;
      }
      await persist(); if (epoch !== accountEpoch) return;
      renderSidebar(); renderCollections(); renderContext(); notify('资料原文、附件提取文字与讨论已保存到收藏');
    } catch (error) { if (epoch === accountEpoch) handleError(error); }
  }
  function openCollection(collection) {
    if (collection.deletedAt) return;
    if (contextBusy()) return;
    context = clone(collection.messages); contextCollectionId = collection.id; currentDiscussionId = collection.discussionId || null;
    if (!currentDiscussion()) currentDiscussionId = null;
    rememberActiveDiscussion(true);
    revealInspector(); show('ai-state', false); renderContext(); renderConversation(); renderAIControls();
    if (currentDiscussion()) notify('已打开收藏资料与之前的讨论');
  }
  function renderContext() {
    const contextKeys = new Set(context.map(M.messageKey));
    $('messages').querySelectorAll('.message-card').forEach(card => card.classList.toggle('in-ai-context', contextKeys.has(card.dataset.messageKey)));
    text('context-count', '已选 ' + context.length + ' 条'); show('context-empty', !context.length); show('context-meta', !!context.length);
    const collection = state.collections.find(c => c.id === contextCollectionId && !c.deletedAt), locked = busyAI || inlineBusy() || preparingContext || cancellingAI || quitting || discussionHistoryBusy;
    text('context-source', collection ? collection.name : Array.from(new Set(context.map(m => groupName(m.groupId)))).join('、'));
    if (currentDiscussion() && currentDiscussion().rangeSummary) { renderSummarySources(currentDiscussion(), locked); return; }
    const children = context.map((message, index) => {
      const item = node('div', 'context-item'), content = node('div', 'context-item-content'), meta = node('div', 'context-item-meta');
      meta.append(node('strong', '', '[' + (index + 1) + '] ' + message.senderName), node('span', '', fullDate(message.sentAt)));
      meta.title = groupName(message.groupId) + ' · 成员 ID ' + message.senderId + ' · 消息 ID ' + message.id;
      content.append(meta);
      if (message.contextScope === 'attachments') content.append(node('p', 'context-scope-note', '本次仅使用所选附件'));
      else content.append(node('p', '', message.text || '［非文本消息］'));
      C.selectedExtractions(message).forEach(extraction => {
        const details = node('details', 'context-extraction'); details.append(node('summary', '', extraction.name + ' · 展开原文'));
        details.append(node('p', 'context-extraction-meta', C.extractionSummary(extraction)));
        if (extraction.truncated || extraction.warnings.length) details.append(node('p', 'context-warning', (extraction.truncated ? '此文件只提取了部分内容。' : '') + extraction.warnings.join('；')));
        details.append(node('pre', '', extraction.text)); content.append(details);
        const ask = button(extraction.kind === 'image' ? '翻译成中文' : '解读文档', 'text-button context-interpret', () => {
          const focused = C.withExtraction(message, extraction.attachmentIndex, extraction, true);
          startFocusedDiscussion([focused], extraction.kind === 'image' ? C.TRANSLATE_IMAGE : '请解读本次文档：先用简体中文概括核心内容，再整理关键结论、依据和需要留意的问题。引用时注明资料序号和原文中的页码（如有），区分原文陈述与推断；对缺页、截断或无法读取之处明确说明。').catch(handleError);
        }, 'spark'); ask.disabled = locked; content.append(ask);
        if (extraction.truncated || extraction.warnings.length) content.append(node('p', 'context-warning', extraction.name + '：' + (extraction.truncated ? '内容有截断。' : '') + extraction.warnings.join('；')));
      });
      C.selectedModelFiles(message).forEach(file => {
        content.append(node('p','context-direct',file.name + '\n' + C.modelFileSummary(file)));
        if (file.warnings.length) content.append(node('p','context-extraction-meta',file.warnings.join('；')));
        const ask = button(file.kind === 'image' ? '翻译图片' : '解读文档','text-button',() => { const focused=clone(message); focused.contextScope='attachments'; focused.contextAttachmentIndexes=[file.attachmentIndex]; startFocusedDiscussion([focused],file.kind === 'image' ? C.TRANSLATE_IMAGE : '请用简体中文解读随附文档，概括内容、结论与依据，并注明页码；看不清处请明确说明。').catch(handleError); },'spark');
        ask.disabled=locked; content.append(ask);
      });
      if (message.contextScope !== 'text') (message.attachments || []).forEach((attachment, attachmentIndex) => {
        if (message.contextScope === 'attachments' && !(message.contextAttachmentIndexes || []).includes(attachmentIndex)) return;
        if ([...C.selectedExtractions(message),...C.selectedModelFiles(message)].some(extraction => extraction.attachmentIndex === attachmentIndex)) return;
        content.append(node('p', 'context-warning', (attachment.name || '附件') + ' · 尚未读取内容'));
        if (!message.localPath && ['image', 'document'].includes(attachment.type)) {
          const retry = button('读取附件并加入讨论', 'text-button', () => readAttachment(message, attachmentIndex, false)); retry.disabled = locked; content.append(retry);
        }
      });
      const sources = node('div', 'context-source-actions');
      if(message.contextScope !== 'text') (message.attachments || []).forEach((attachment,index)=>{ if(!['image','document'].includes(attachment.type) || message.contextScope === 'attachments' && !(message.contextAttachmentIndexes || []).includes(index))return; const reprepare=button('重新读取：'+(attachment.name || '附件 '+(index+1)),'text-button',()=>readAttachment(message,index,false));reprepare.title='按当前设置重新准备这份附件';reprepare.disabled=locked;sources.append(reprepare); });
      if (message.localPath) sources.append(button('在访达中显示', 'text-button', () => rpc('revealImported', {accountId:state.accountId,localPath:message.localPath}).catch(handleError), 'folder'));
      else sources.append(button('定位原消息', 'text-button', () => jumpTo(message.groupId, message.id), 'book'));
      content.append(sources);
      const remove = button('', 'icon-button small', () => { if (contextBusy()) return; context = context.filter(m => M.messageKey(m) !== M.messageKey(message)); abandonCurrentDiscussion(); renderContext(); renderConversation(); }, 'close');
      remove.title = '从本次讨论移除'; remove.setAttribute('aria-label', '移除 ' + message.senderName + ' 的这条资料'); remove.disabled = locked; item.append(content, remove); return item;
    });
    replace('context-list', children); $('clear-context').disabled = locked;
    if ($('save-ai-context')) $('save-ai-context').disabled = locked || !context.length;
  }
  function webSourceLink(source, label, className = 'citation-link web-citation') {
    const link = node('a', className, label); link.href = source.url; link.rel = 'noopener noreferrer'; link.title = source.title; return link;
  }
  function appendWebCitations(parent, metadata, history) {
    const sources = new Map((metadata && metadata.status==='success' ? metadata.sources : []).map(source => [source.id,source]));
    (history || []).forEach((message,index)=>{const old=W.normalize(message.webSearch);if(old)old.sources.forEach((source,number)=>sources.set('历史网页'+(index+1)+'-'+(number+1),source));});
    Array.from(parent.childNodes).filter(child => child.nodeType === Node.TEXT_NODE).forEach(child => {
      const fragment = document.createDocumentFragment(); let offset = 0;
      for (const match of child.textContent.matchAll(/\[(网页[1-5]|历史网页[1-9]\d*-[1-5])\]/g)) {
        fragment.append(document.createTextNode(child.textContent.slice(offset,match.index)));
        const source = sources.get(match[1]);
        fragment.append(source ? webSourceLink(source,match[0]) : document.createTextNode(match[0])); offset=match.index+match[0].length;
      }
      fragment.append(document.createTextNode(child.textContent.slice(offset))); child.replaceWith(fragment);
    });
  }
  function webSearchSources(metadata) {
    const box=node('details','web-sources'), success=metadata.status==='success';
    box.open=!success;
    box.append(node('summary','',success?'联网参考 · '+metadata.sources.length+' 个来源':metadata.status==='empty'?'联网搜索未找到结果':'联网搜索未完成'));
    box.append(node('p','web-source-time','检索于 '+fullDate(metadata.searchedAt)),node('p','web-source-query','搜索词：'+metadata.query));
    if(!success) box.append(node('p','context-warning',(metadata.error || (metadata.status==='empty'?'没有找到可用网页。':'搜索服务暂不可用。'))+' 本次回答未经联网核实。'));
    metadata.sources.forEach(source=>{
      const item=node('div','web-source-item'); item.append(webSourceLink(source,'['+source.id+'] '+source.title,'web-source-title'));
      item.append(node('small','',(source.siteName || new URL(source.url).hostname)+' · '+(source.publishedAt?'发布于 '+fullDate(source.publishedAt):'未提供发布时间')));
      if(source.excerpt)item.append(node('p','',source.excerpt)); box.append(item);
    });
    if(success)box.append(node('p','web-source-note','网页是参考资料，时效与结论仍需结合原文判断。'));
    return box;
  }
  function renderConversation() {
    const discussion = currentDiscussion(), messages = discussion && Array.isArray(discussion.messages) ? discussion.messages : [];
    $('quick-prompts').hidden = !!messages.length;
    text('discussion-title', discussion ? discussion.title || '讨论' : '新讨论'); show('ai-welcome', !messages.length);
    const children = messages.map(message => {
      const role = ['user', 'assistant', 'system'].includes(message.role) ? message.role : 'system';
      const block = node('div', 'conversation-message ' + role), label = node('div', 'conversation-message-label');
      if (role === 'assistant') label.append(icon('spark'));
      label.append(node('span', '', role === 'user' ? '你' : role === 'assistant' ? 'AI' : '讨论提示'));
      if (message.createdAt) label.title = fullDate(message.createdAt);
      const content = node('div', '');
      if (discussion && discussion.rangeSummary && role === 'assistant') appendSummaryCitations(content,message.content || '',discussion);
      else content.textContent = message.content || '';
      const webSearch=role==='assistant' ? W.normalize(message.webSearch) : null;
      appendWebCitations(content,webSearch,messages);
      block.append(label, content);
      if(webSearch)block.append(webSearchSources(webSearch));
      if(message.reasoning){const detail=node('details','stream-reasoning');detail.append(node('summary','','模型返回的思考内容'),node('pre','',message.reasoning));block.append(detail);}
      if(message.warnings && message.warnings.length) block.append(node('p','context-warning',message.warnings.join('；')));
      if (message.error) block.append(node('p', 'conversation-error', message.error));
      return block;
    });
    if (discussion && discussion.rangeSummary) children.unshift(summaryStatus(discussion));
    replace('conversation-messages', children);
    requestAnimationFrame(() => { $('conversation').scrollTop = messages.length ? $('conversation').scrollHeight : 0; });
  }
  function renderDiscussionHistory() {
    renderDiscussionTitleStatus();
    const locked = preferencesLocked() || collectionsBusy;
    const discussions = state.discussions.filter(discussion => deletedDiscussions ? !!discussion.deletedAt : !discussion.deletedAt).slice().reverse();
    $('discussions-active').classList.toggle('selected',!deletedDiscussions); $('discussions-deleted').classList.toggle('selected',deletedDiscussions);
    $('discussions-active').setAttribute('aria-pressed',String(!deletedDiscussions)); $('discussions-deleted').setAttribute('aria-pressed',String(deletedDiscussions));
    show('discussions-clear',!deletedDiscussions); show('discussions-restore-all',deletedDiscussions);
    $('discussions-clear').disabled=locked || !discussions.length; $('discussions-restore-all').disabled=locked || !discussions.length;
    text('discussion-history-note',deletedDiscussions ? discussions.length+' 条已删除 · 恢复后可继续讨论，来源仍保留。' : discussions.length+' 条讨论 · 删除后可在「最近删除」恢复。');
    const children = discussions.map(discussion => {
      const row = node('div','discussion-history-item'); row.dataset.discussionId=discussion.id;
      const item = node('button', 'discussion-row'); item.type = 'button';
      item.disabled=locked || !!discussion.deletedAt; item.setAttribute('aria-current',String(discussion.id===currentDiscussionId && !discussion.deletedAt));
      item.title=discussion.title || '未命名讨论';
      item.append(node('strong', '', discussion.title || '未命名讨论'), node('small', '', fullDate(discussion.deletedAt || discussion.createdAt) + (discussion.deletedAt ? ' · 已删除' : ' · '+(discussion.contextSnapshots || []).length+' 条资料')+(discussion.titleInfo && discussion.titleInfo.source==='ai'?' · AI 标题':'')));
      item.addEventListener('click', () => {
        if (discussion.deletedAt || item.disabled || contextBusy()) return;
        currentDiscussionId = discussion.id; contextCollectionId = state.collections.some(c => c.id === discussion.collectionId && !c.deletedAt) ? discussion.collectionId : null; context = clone(discussion.contextSnapshots || []);
        rememberActiveDiscussion();
        show('discussion-list', false); show('ai-state', false); renderContext(); renderConversation(); renderAIControls();
      });
      const action=discussion.deletedAt ? button('恢复','text-button discussion-restore',()=>changeDiscussionDeletion([discussion.id],true)) : button('','icon-button small discussion-delete',()=>confirmDiscussionDeletion([discussion.id]),'trash');
      action.disabled=locked; action.title=(discussion.deletedAt?'恢复':'删除')+'「'+(discussion.title || '未命名讨论')+'」'; action.setAttribute('aria-label',action.title);
      row.append(item,action); return row;
    });
    if (!children.length) children.push(node('p', 'sidebar-empty', deletedDiscussions ? '没有已删除的讨论。' : '发送第一条提问后，讨论会保存在这里。'));
    replace('discussion-items', children);
  }
  function titleConfigurationReady() { return native && !demo && ready && !loadFailed && !!state.accountId && hasAPIKey && !!state.settings.baseURL && !!state.settings.model; }
  function titleWorkAvailable() { return titleConfigurationReady() && !settingsBusy && !busyAI && !inlineBusy() && !preparingContext && !cancellingAI && !quitting && !cleanupBusy && !preferencesSaving && !discussionHistoryBusy && !collectionsBusy && !modelCapabilitiesLoading(); }
  function renderDiscussionTitleStatus() {
    if (!$('discussion-title-tools') || !discussionTitles) return;
    show('discussion-title-tools',!deletedDiscussions);
    const status=discussionTitles.status(),configured=titleConfigurationReady();
    const label=!configured?'配置 AI 后，可自动整理历史标题。':status.paused?'拟题已暂停':status.activeId?'正在整理标题 · 还剩 '+status.remaining+' 条':status.remaining?'等待当前操作完成 · '+status.remaining+' 条':status.failed?status.failed+' 条标题未完成，可重试':status.missing?status.missing+' 条讨论待拟题':'历史标题已整理';
    text('discussion-title-progress',label);
    text('discussion-title-action',!configured?'设置 AI':status.paused?'继续拟题':status.remaining?'暂停拟题':status.failed?'重试':'补全标题');
    $('discussion-title-action').disabled=quitting || (!status.missing && !status.remaining && !status.failed && !status.paused && configured);
    $('discussion-title-progress').title=status.lastError || '使用当前 AI 模型，根据已保存的提问与回复概括标题。';
  }
  function historyError(error,dialog=false) {
    const id=dialog?'discussion-delete-error':'discussion-history-error';text(id,error?errorText(error):'');show(id,!!error);
    if(error)$(id).scrollIntoView({block:'nearest'});
  }
  function renderDiscussionDeleteLocks() {
    ['discussion-delete-close','discussion-delete-cancel'].forEach(id=>$(id).disabled=discussionHistoryBusy);
    $('discussion-delete-confirm').disabled=preferencesLocked() || collectionsBusy;
    text('discussion-delete-confirm',discussionHistoryBusy?'正在保存…':pendingDiscussionDeleteIds.length>1?'清空 '+pendingDiscussionDeleteIds.length+' 条讨论':'删除讨论');
  }
  function confirmDiscussionDeletion(ids) {
    if(preferencesLocked() || collectionsBusy)return;
    pendingDiscussionDeleteIds=state.discussions.filter(d=>ids.includes(d.id)&&!d.deletedAt).map(d=>d.id);
    if(!pendingDiscussionDeleteIds.length)return;
    const count=pendingDiscussionDeleteIds.length,discussions=state.discussions.filter(d=>pendingDiscussionDeleteIds.includes(d.id));
    text('discussion-delete-title',count>1?'清空讨论历史':'删除讨论');
    text('discussion-delete-summary','将 '+count+' 条讨论移到「最近删除」'+(pendingDiscussionDeleteIds.includes(currentDiscussionId)?'，当前讨论会回到空白的新讨论。':'。'));
    text('discussion-delete-names',discussions.slice(0,20).map(d=>d.title || '未命名讨论').join('\n')+(count>20?'\n…另有 '+(count-20)+' 条':''));
    historyError(null,true);renderDiscussionDeleteLocks();openDialog('discussion-delete-dialog');
  }
  async function changeDiscussionDeletion(ids,restore=false) {
    if(preferencesLocked() || collectionsBusy)return;
    const epoch=accountEpoch,account=state.accountId,targets=state.discussions.filter(d=>ids.includes(d.id)&&(restore?!!d.deletedAt:!d.deletedAt));
    if(!targets.length)return;
    const prior=targets.map(d=>({discussion:d,had:Object.prototype.hasOwnProperty.call(d,'deletedAt'),value:d.deletedAt}));
    const previousActive=state.settings.activeDiscussionId,previousDraft=state.settings.aiDraftInstructions,oldCurrent=currentDiscussionId;
    const deletingCurrent=!restore&&targets.some(d=>d.id===oldCurrent);let changedActive,changedDraft;
    discussionHistoryBusy=true;historyError(null,!!$('discussion-delete-dialog').open);renderAIControls();renderContext();renderDiscussionDeleteLocks();
    try {
      (restore?M.restoreDiscussions:M.deleteDiscussions)(state,targets.map(d=>d.id));
      if(deletingCurrent)state.settings.aiDraftInstructions='';
      changedActive=state.settings.activeDiscussionId;changedDraft=state.settings.aiDraftInstructions;
      await persist();if(epoch!==accountEpoch || account!==state.accountId)return;
      if(deletingCurrent){currentDiscussionId=null;context=[];contextCollectionId=null;summarySourcePage=0;pendingRange=null;$('ai-question').value='';show('ai-state',false);}
      if($('discussion-delete-dialog').open)$('discussion-delete-dialog').close();pendingDiscussionDeleteIds=[];
      notify(restore?'已恢复 '+targets.length+' 条讨论':'已将 '+targets.length+' 条讨论移到最近删除');
    } catch(error) {
      if(epoch!==accountEpoch || account!==state.accountId)return;
      // Restore only fields this operation changed; concurrent incoming messages
      // and other account data must never be replaced by an old full snapshot.
      mutate(()=>{prior.forEach(item=>{if(item.had)item.discussion.deletedAt=item.value;else delete item.discussion.deletedAt;});if(state.settings.activeDiscussionId===changedActive){if(previousActive===undefined)delete state.settings.activeDiscussionId;else state.settings.activeDiscussionId=previousActive;}if(deletingCurrent&&state.settings.aiDraftInstructions===changedDraft){if(previousDraft===undefined)delete state.settings.aiDraftInstructions;else state.settings.aiDraftInstructions=previousDraft;}});
      await persistQuietly();if(epoch!==accountEpoch || account!==state.accountId)return;historyError(error,!!$('discussion-delete-dialog').open);
    } finally {
      if(epoch===accountEpoch&&account===state.accountId){discussionHistoryBusy=false;renderAIControls();renderContext();renderConversation();renderDiscussionHistory();renderDiscussionDeleteLocks();}
    }
  }
  function renderAIControls() {
    refreshModelCapabilities();
    const capabilitiesLoading=modelCapabilitiesLoading();
    const locked = settingsBusy || busyAI || inlineBusy() || preparingContext || cancellingAI || quitting || cleanupBusy || preferencesSaving || discussionHistoryBusy || capabilitiesLoading;
    const stop = ReaderViewPolicy.aiStopState({busyAI,preparingContext,inlineBusy:inlineBusy(),rangeOperation,cancellingAI,quitting});
    show('ai-cancel', stop.visible); $('ai-cancel').disabled=stop.disabled; text('ai-stop-label',stop.label); show('ai-send',!stop.visible);
    $('ai-send').disabled = locked; $('ai-question').disabled = locked;
    $('new-discussion').disabled = locked; $('ai-model-button').disabled = locked;
    $('context-list').querySelectorAll('button').forEach(control => { control.disabled = locked; });
    document.querySelectorAll('.attachment-ai-action,.attachment-task-retry').forEach(control => { control.disabled = locked; });
    document.querySelectorAll('.attachment-more-menu option[value="add"]').forEach(control => { control.disabled = locked; });
    $('clear-context').disabled = locked; $('save-ai-context').disabled = locked || !context.length;
    if ($('import-ai-document')) $('import-ai-document').disabled = locked;
    if ($('translate-selection')) $('translate-selection').disabled = locked;
    text('ai-model-label', state.settings.model || '设置模型');
    const thinking=thinkingOption();
    $('ai-thinking').setAttribute('aria-pressed',String(thinking.enabled)); $('ai-thinking').disabled=locked || !thinking.toggle || !ready || !state.accountId;
    $('ai-thinking').title=thinking.hint; $('ai-thinking').setAttribute('aria-label','深度思考：'+thinking.label+'。'+thinking.hint); text('thinking-state',thinking.label);
    const searchSupported=W.supportedProvider(state.settings.baseURL || ''), searchEnabled=searchSupported && state.settings.webSearchEnabled===true;
    $('ai-web-search').setAttribute('aria-pressed',String(searchEnabled)); $('ai-web-search').disabled=locked || !searchSupported || !ready || !state.accountId;
    text('web-search-state',searchEnabled?'已开启':'已关闭');
    const searchHint=!searchSupported?'联网搜索目前支持 DeepSeek 官方 API。':searchEnabled?'按本次提问检索，搜索词不含所选资料；搜索单独计费。点击关闭。':'开启后按本次提问检索网页，回答附来源。点击开启。';
    text('web-search-hint',searchHint); $('ai-web-search').title=searchHint; $('ai-web-search').setAttribute('aria-label','联网搜索：'+(searchEnabled?'已开启':'已关闭')+'。'+searchHint);
    if (preferencesUI) preferencesUI.render();
    if (followedUI) followedUI.render();
    $('open-followed-members').disabled = localSettingsLocked();
    renderSettingsLocks();
    if (rangeUI) rangeUI.render();
    if (discussionTitles) discussionTitles.activityChanged();
    if (!$('discussion-list').hidden) renderDiscussionHistory();
    if ($('discussion-delete-dialog').open) renderDiscussionDeleteLocks();
  }
  function aiState(message, isError) { text('ai-state', message); $('ai-state').className = 'ai-state' + (isError ? ' error' : ''); show('ai-state', !!message); }
  function startAILive(requestId) {
    clearInterval(aiLiveTimer); aiLive={requestId,accountId:state.accountId,started:Date.now(),phase:'preparing',content:'',reasoning:'',usage:null,warnings:[]};
    show('ai-progress',true); updateAILive(); aiLiveTimer=setInterval(updateAILive,250);
  }
  function receiveAIProgress(event) {
    if (!aiLive || event.requestId !== aiLive.requestId || event.accountId && event.accountId !== aiLive.accountId) return;
    if (event.phase) aiLive.phase=event.phase;
    if (event.contentDelta) aiLive.content+=event.contentDelta;
    if (event.reasoningDelta) aiLive.reasoning+=event.reasoningDelta;
    if (event.usage) aiLive.usage=event.usage;
    if (event.webSearch) aiLive.webSearch=W.normalize(event.webSearch);
    if (event.detail) aiLive.detail=event.detail;
    if(event.warning && !aiLive.warnings.includes(event.warning)) aiLive.warnings.push(event.warning);
    if (event.buffered) aiLive.buffered=true;
    updateAILive();
  }
  function updateAILive() {
    if (!aiLive) return;
    const phases={preparing:'准备资料',credentials:'检查服务凭据',authorizing:'读取已保存凭据',searching:'正在联网搜索',reading:'正在整理网页资料',connecting:'连接模型',uploading:'提交资料',waiting:'等待模型响应',thinking:'深度思考中',answering:'正在回答',completed:'回复完成'};
    text('ai-progress-label',phases[aiLive.phase] || '处理请求中'); text('ai-progress-time',Math.floor((Date.now()-aiLive.started)/1000)+' 秒');
    let block=$('ai-stream-block');
    if (!block) { block=node('div','conversation-message assistant'); block.id='ai-stream-block'; block.append(node('div','conversation-message-label','AI · 实时回复')); const reasoning=node('details','stream-reasoning'); reasoning.id='ai-stream-reasoning'; reasoning.append(node('summary','','模型返回的思考内容')); const pre=node('pre'); pre.id='ai-stream-thought'; reasoning.append(pre); const answer=node('div','stream-answer'); answer.id='ai-stream-answer'; block.append(reasoning,answer); $('conversation-messages').append(block); }
    const view=$('conversation'), nearEnd=view.scrollHeight-view.scrollTop-view.clientHeight<100;
    text('ai-stream-answer',aiLive.content || (['searching','reading'].includes(aiLive.phase) ? aiLive.detail || '正在检索网页，整理后交给模型回答。' : aiLive.phase === 'thinking' ? '模型正在思考，收到回答后会在这里逐步显示。' : '请求处理中，收到内容后会实时显示。'));
    show('ai-stream-reasoning',!!aiLive.reasoning); text('ai-stream-thought',aiLive.reasoning);
    if (nearEnd) view.scrollTop=view.scrollHeight;
  }
  function finishAILive(label) { clearInterval(aiLiveTimer); aiLiveTimer=0; show('ai-progress',false); aiLive=null; if(label) aiState(label); }
  function preservePartialAI(discussion) {
    if (!aiLive || !aiLive.content || !discussion) return;
    mutate(() => discussion.messages.push({role:'assistant',content:aiLive.content,reasoning:aiLive.reasoning,...(aiLive.webSearch?{webSearch:aiLive.webSearch}:{}),createdAt:new Date().toISOString(),status:'interrupted',error:'本次回复中断，以上为已收到的部分。'}));
  }
  function localMinute(date) {
    const pad = value => String(value).padStart(2,'0');
    return date.getFullYear()+'-'+pad(date.getMonth()+1)+'-'+pad(date.getDate())+'T'+pad(date.getHours())+':'+pad(date.getMinutes());
  }
  function summaryRange(raw) {
    const range = S.parseRange(raw.start,raw.end), now = Date.now();
    if (range.startMs > now || range.endMs >= Math.floor(now/60000)*60000+60000) throw new Error('请选择已经发生的时间段；结束时间最多为当前分钟。');
    if (range.endMs > now) { range.endMs=now; range.endAt=range.to=new Date(now).toISOString(); range.label=raw.start.replace('T',' ')+' 至 '+fullDate(range.endAt)+'（截至开始加载时刻）'; }
    return range;
  }
  function rangeMatches(raw,groupId=activeGroupId) { return pendingRange && pendingRange.accountId===state.accountId && pendingRange.groupId===groupId && pendingRange.raw.start===raw.start && pendingRange.raw.end===raw.end; }
  function previewRange(raw,groupId=activeGroupId) {
    const range=summaryRange(raw);
    if (rangeMatches(raw,groupId)) return {count:pendingRange.snapshots.length,complete:pendingRange.coverage.complete,reason:pendingRange.coverage.reason};
    const count=S.select(archive().forGroup(groupId),{accountId:state.accountId,groupId,...range}).length;
    return {count,complete:false,reason:'本机已保存 '+count+' 条；尚未向微博连续核对，不能确认完整。'};
  }
  function receiveRangeProgress(event) {
    const operation=rangeOperation;
    if (!operation || operation.cancelled || event.accountId!==operation.accountId || event.requestId!==operation.requestId || event.groupId!==operation.groupId) return;
    if(rangeUI)rangeUI.setProgress({stage:'loading',label:event.text || '正在核对并加载时段消息',pages:event.pages,count:event.loadedCount,detail:'按官方历史连续读取，正在确认时段覆盖。'});
    if(!rangeUI)aiState((event.text || '正在读取时段消息')+' · 已取得 '+(event.loadedCount || 0)+' 条');
  }
  async function cancelRangeSummary(reason='总结已取消，已完成的批次与消息快照仍保留。') {
    const operation=rangeOperation;
    if (!operation) return;
    if(!operation.discussion)reason='已停止时段读取。取得的消息留在当前窗口，可选择只总结已有部分。';
    operation.cancelled=true;
    if(operation.discussion && operation.epoch===accountEpoch) mutate(()=>{operation.discussion.rangeSummary.status='interrupted';operation.discussion.rangeSummary.error=reason;});
    await Promise.all([rpc('cancelRange',{accountId:operation.accountId,requestId:operation.requestId}).catch(()=>{}),rpc('cancelAI').catch(()=>{})]);
    if(operation.epoch===accountEpoch) {finishAILive();if(!rangeUI)aiState(reason,true);renderConversation();await persistQuietly();}
  }
  function appendSummaryCitations(element,value,discussion) {
    S.tokenizeCitations(value,discussion.contextSnapshots.length).forEach(token=>{
      if(token.type==='text')element.append(document.createTextNode(token.text));
      else {const source=discussion.contextSnapshots[token.number-1];const link=button('[消息'+token.number+']','citation-link',()=>jumpTo(source.groupId,source.id,source));link.title=source.senderName+' · '+fullDate(source.sentAt);element.append(link);}
    });
  }
  function summaryStatus(discussion) {
    const summary=discussion.rangeSummary,block=node('div','summary-info');
    block.append(node('strong','',groupName(summary.groupId)+' · '+summary.sourceCount+' 条消息 · '+(summary.coverage.complete?'已核对':'部分记录')));
    const metadata=node('details','summary-metadata'),heading=node('summary','','时间范围与来源说明');heading.title=summary.label;
    metadata.append(heading,node('p','',summary.label),node('p','',summary.coverage.reason),node('p','','范围：聊天文字与附件信息；图片和文档正文未自动读取。'));block.append(metadata);
    if(summary.status==='complete')metadata.append(node('p','','已完成 '+summary.batchCount+' 批梳理并汇总；点击 [消息编号] 可回看来源。'));
    else {block.append(node('p','context-warning',(summary.error || '正在生成总结')+' · 已完成 '+summary.completedBatches+'/'+summary.batchCount+' 批'));if(!busyAI){const retry=button('重新生成这段总结','text-button',()=>restartRangeSummary(discussion).catch(handleError));block.append(retry);}}
    if(summary.status!=='complete' && summary.partials && summary.partials.length){const detail=node('details','summary-sources'),chooser=node('select'),body=node('div','conversation-message');detail.append(node('summary','','查看已保存的 '+summary.partials.length+' 批结果'));summary.partials.forEach((value,index)=>{const option=node('option','','第 '+(index+1)+' 批');option.value=String(index);chooser.append(option);});const showBatch=()=>{body.replaceChildren();appendSummaryCitations(body,summary.partials[Number(chooser.value)] || '',discussion);};chooser.setAttribute('aria-label','查看哪一批结果');chooser.addEventListener('change',showBatch);detail.addEventListener('toggle',()=>{if(detail.open)showBatch();else body.replaceChildren();});detail.append(chooser,body);block.append(detail);}
    return block;
  }
  function renderSummarySources(discussion,locked) {
    const total=context.length,pageSize=20;summarySourcePage=Math.max(0,Math.min(summarySourcePage,Math.ceil(total/pageSize)-1));
    const detail=node('details','summary-sources');detail.append(node('summary','','已保存 '+total+' 条来源 · 展开查看'));
    context.slice(summarySourcePage*pageSize,(summarySourcePage+1)*pageSize).forEach((message,index)=>{
      const item=button('[消息'+(summarySourcePage*pageSize+index+1)+'] '+message.senderName+' · '+fullDate(message.sentAt)+'\n'+shortText(message.text || '［附件消息］',90),'summary-source-button',()=>jumpTo(message.groupId,message.id,message));detail.append(item);
    });
    if(total>pageSize){const nav=node('div','summary-info');const previous=button('上一页','text-button',()=>{summarySourcePage--;renderContext();$('context-list details').open=true;});previous.disabled=summarySourcePage===0;const next=button('下一页','text-button',()=>{summarySourcePage++;renderContext();$('context-list details').open=true;});next.disabled=(summarySourcePage+1)*pageSize>=total;nav.append(previous,node('span','', ' '+(summarySourcePage+1)+' / '+Math.ceil(total/pageSize)+' '),next);detail.append(nav);}
    replace('context-list',[node('p','summary-info',discussion.rangeSummary.coverage.complete?'时段消息已核对，可从总结引用跳回原文。':'时段记录未完整，当前总结仅覆盖已取得的消息。'),detail]);
    $('clear-context').disabled=locked;$('save-ai-context').disabled=locked || !total;
  }
  async function generateRangeSummary(operation,discussion,question) {
    const meta=discussion.rangeSummary;
    operation.discussion=discussion;
    const options={preferences:operation.preferences,temporary:'',prompt:question,groupName:groupName(meta.groupId),rangeLabel:meta.label,coverage:meta.coverage.reason};
    const check=()=>{if(operation.cancelled || operation.epoch!==accountEpoch || quitting || rangeOperation!==operation)throw ReaderRangeRunner.stopped();};
    await persist();check();
    const output=await ReaderRangeRunner.run({snapshots:discussion.contextSnapshots,options,isCancelled:()=>operation.cancelled || operation.epoch!==accountEpoch || quitting || rangeOperation!==operation,
      progress:info=>{const label=info.stage==='map'?'梳理消息 '+info.batch+'/'+info.totalBatches+' 批':'合并总结 · 第 '+info.round+' 轮 '+info.batch+'/'+info.totalBatches+' 批';if(rangeUI)rangeUI.setProgress({...info,label,complete:meta.coverage.complete,coverageReason:meta.coverage.reason});else aiState(label);},
      checkpoint:async checkpoint=>{check();mutate(()=>Object.assign(meta,checkpoint,{status:'running'}));await persist();check();},
      request:async(messages,info)=>{check();const requestId=operation.requestId+'-ai-'+(++aiToken);startAILive(requestId);const search=W.requestOptions(operation.configuration,question,{enabled:operation.configuration.webSearchEnabled===true && info.stage==='reduce' && info.totalBatches===1});const result=await rpc('ai',{...operation.configuration,...search,requestId,messages,sources:[]});check();if(result.cancelled)throw ReaderRangeRunner.stopped();if(aiLive && aiLive.warnings.some(value=>/截断|长度限制|达到.*上限|内容过滤器终止/.test(value)))throw new Error('模型输出提前中止，尚未完成整段总结。请查看服务提示，缩小时段或调整模型后重试。');if(search.webSearchEnabled)operation.webSearch=W.normalize(result.webSearch);finishAILive();return result.text;}
    });check();
    mutate(()=>{meta.status='complete';meta.finalText=output.text;meta.batchCount=output.batchCount;meta.completedBatches=output.batchCount;meta.rounds=output.rounds;delete meta.error;discussion.messages.push({role:'assistant',content:output.text,...(operation.webSearch?{webSearch:operation.webSearch}:{}),createdAt:new Date().toISOString()});});
    await persist();check();renderConversation();renderContext();if(!rangeUI)aiState('时段总结完成 · '+meta.sourceCount+' 条消息 · '+meta.batchCount+' 批'+(meta.coverage.complete?' · 已核对时段记录':' · 仅覆盖已加载部分'));
  }
  function summaryOperation(groupId) {return {epoch:accountEpoch,accountId:state.accountId,groupId,requestId:'range-'+Date.now()+'-'+Math.random().toString(36).slice(2,8),cancelled:false,preferences:clone(A.read(state.settings)),configuration:{accountId:state.accountId,...aiConfiguration(),webSearchEnabled:state.settings.webSearchEnabled===true}};}
  async function finishRangeOperation(operation,error) {
    if(operation.epoch!==accountEpoch || rangeOperation!==operation)return;
    if(error && operation.discussion){mutate(()=>{operation.discussion.rangeSummary.status=operation.cancelled?'interrupted':'failed';operation.discussion.rangeSummary.error=errorText(error);});await persistQuietly();}
    finishAILive();rangeOperation=null;busyAI=false;renderAIControls();renderContext();renderConversation();
    if (!error && operation.discussion && discussionTitles) discussionTitles.enqueue(operation.discussion.id);
    if(error && !rangeUI)aiState(errorText(error),true);
  }
  async function startRangeSummary(raw,question,allowPartial,groupId=activeGroupId) {
    if(preferencesLocked())throw new Error('请等待当前操作结束后再开始总结。');
    if(!native || demo)throw new Error('请在微阅 Mac 应用中使用时段总结。');
    const group=state.groups.find(item=>item.id===groupId && item.accountId===state.accountId);if(!group || !group.selected)throw new Error('请先勾选需要总结的群，开启消息同步。');
    if(!state.settings.baseURL || !state.settings.model || !hasAPIKey)throw new Error('请先在 AI 设置中配置可用模型和 API Key，再开始总结。');
    const range=summaryRange(raw),operation=summaryOperation(group.id);
    let failure=null;rangeOperation=operation;busyAI=true;aiState('');renderAIControls();revealInspector();
    try {
      if(!allowPartial || !rangeMatches(raw,group.id)){
        if(rangeUI)rangeUI.setProgress({stage:'loading',label:'正在从微博核对并加载记录',count:0,pages:0,complete:false});
        let loaded;
        try {loaded=await rpc('loadRange',{accountId:operation.accountId,groupId:group.id,from:range.startAt,to:range.endAt,requestId:operation.requestId});}
        catch(error){if(operation.cancelled)throw error;loaded={messages:archive().forGroup(group.id),coverage:{complete:false,reason:'未能核对完整时段：'+errorText(error)+'。当前仅使用本地已有消息。',checkedAt:new Date().toISOString(),pages:0}};}
        if(operation.epoch!==accountEpoch)throw ReaderRangeRunner.stopped();
        const snapshots=S.select(loaded.messages || [],{accountId:operation.accountId,groupId:group.id,...range});
        const info=loaded.coverage || {},coverage={complete:info.complete===true && !operation.cancelled,reason:operation.cancelled?'已停止读取，当前仅保留本次取得的 '+snapshots.length+' 条消息；没有提交给 AI。':String(info.reason || '尚未确认时段完整性。'),from:range.startAt,to:range.endAt,checkedAt:info.checkedAt || new Date().toISOString(),loadedCount:snapshots.length,pages:Number.isSafeInteger(info.pages)?info.pages:0};
        pendingRange={accountId:operation.accountId,groupId:group.id,raw:{...raw},range,snapshots,coverage};
        if(operation.cancelled)return {cancelled:true,incomplete:true,count:snapshots.length,reason:coverage.reason};
      }
      const loaded=pendingRange;
      if(rangeUI)rangeUI.setProgress({stage:'loaded',count:loaded.snapshots.length,pages:loaded.coverage.pages,complete:loaded.coverage.complete,coverageReason:loaded.coverage.reason});
      if(!loaded.coverage.complete && !allowPartial)return {incomplete:true,count:loaded.snapshots.length,reason:loaded.coverage.reason};
      if(!loaded.snapshots.length)throw new Error('所选时段没有取得可总结的消息。'+loaded.coverage.reason);
      const batches=S.plan(loaded.snapshots),id='discussion-'+Date.now()+'-'+Math.random().toString(36).slice(2,9);
      const discussion={id,accountId:state.accountId,createdAt:new Date().toISOString(),title:'时段总结 · '+loaded.range.label,collectionId:null,contextSnapshots:loaded.snapshots,instructions:'',messages:[{role:'user',content:question,createdAt:new Date().toISOString()}],rangeSummary:{version:1,groupId:group.id,startAt:loaded.range.startAt,endAt:loaded.range.endAt,label:loaded.range.label,sourceCount:loaded.snapshots.length,coverage:loaded.coverage,status:'running',batchCount:batches.length,completedBatches:0,partials:[],prompt:question}};
      mutate(()=>{state.discussions.push(discussion);state.settings.activeDiscussionId=id;state.settings.aiDraftInstructions='';});
      currentDiscussionId=id;context=discussion.contextSnapshots;contextCollectionId=null;summarySourcePage=0;renderConversation();renderContext();
      await generateRangeSummary(operation,discussion,question);return {complete:loaded.coverage.complete,count:loaded.snapshots.length,discussionId:discussion.id};
    }catch(error){failure=error;if(operation.cancelled)return {cancelled:true};throw error;}
    finally{await finishRangeOperation(operation,failure);}
  }
  async function restartRangeSummary(discussion) {
    if(contextBusy())return;
    if(!state.settings.baseURL || !state.settings.model || !hasAPIKey){openSettings();return;}
    const operation=summaryOperation(discussion.rangeSummary.groupId);rangeOperation=operation;busyAI=true;let failure;
    const summary=discussion.rangeSummary;aiState('');
    if(rangeUI)rangeUI.beginTracking({groupId:summary.groupId,groupName:groupName(summary.groupId),range:{start:localMinute(new Date(summary.startAt)),end:localMinute(new Date(summary.endAt))},label:summary.label,question:summary.prompt,count:summary.sourceCount,discussionId:discussion.id});
    revealInspector();
    mutate(()=>{summary.status='running';summary.completedBatches=0;summary.partials=[];['error','stage','round','rounds','reductionCompleted','finalText'].forEach(key=>delete summary[key]);});renderAIControls();renderConversation();
    try{await generateRangeSummary(operation,discussion,summary.prompt);}catch(error){failure=error;handleError(error);}finally{await finishRangeOperation(operation,failure);if(operation.epoch===accountEpoch && rangeUI)rangeUI.endTracking({cancelled:operation.cancelled,complete:summary.coverage.complete,count:summary.sourceCount,discussionId:discussion.id},operation.cancelled?null:failure);}
  }
  async function sendAI(event) {
    event.preventDefault(); if (settingsBusy || busyAI || inlineBusy() || preparingContext || cancellingAI || quitting || cleanupBusy || preferencesSaving || discussionHistoryBusy || modelCapabilitiesLoading()) return;
    const question=$('ai-question').value.trim(); if(!question){$('ai-question').focus();return;}
    if(demo || !native){aiState('演示模式不会调用模型。请在 Mac 应用中设置自己的 API。',true);return;}
    if(!state.accountId){aiState('请先登录微博，再开始讨论。',true);return;}
    if(!state.settings.baseURL || !state.settings.model || !hasAPIKey){openSettings();return;}
    const epoch=accountEpoch,token=++aiToken,requestId='ai-'+Date.now()+'-'+token,configuration={accountId:state.accountId,...aiConfiguration(),...W.requestOptions(state.settings,question)};
    const requestPreferences = clone(A.read(state.settings));
    busyAI=true;renderAIControls();renderContext();
    let discussion=currentDiscussion(),userMessage,responseReceived=false;
    try {
      if(!discussion){discussion={id:'discussion-'+Date.now()+'-'+Math.random().toString(36).slice(2,9),accountId:state.accountId,createdAt:new Date().toISOString(),title:shortText(question,32),collectionId:contextCollectionId,contextSnapshots:clone(context),instructions:'',messages:[]};mutate(()=>{state.discussions.push(discussion);state.settings.aiDraftInstructions='';state.settings.activeDiscussionId=discussion.id;const collection=state.collections.find(c=>c.id===contextCollectionId&&!c.deletedAt);if(collection)collection.discussionId=discussion.id;});currentDiscussionId=discussion.id;}
      const previous=discussion.messages[discussion.messages.length-1];
      if(previous&&previous.role==='user'&&previous.error&&previous.content===question){userMessage=previous;mutate(()=>{delete userMessage.error;userMessage.status='pending';});}
      else{userMessage={role:'user',content:question,createdAt:new Date().toISOString(),status:'pending'};mutate(()=>discussion.messages.push(userMessage));}
      aiState('正在保存提问…');renderConversation();startAILive(requestId);await persist();
      if(epoch!==accountEpoch||token!==aiToken)return;
      const history=W.historyMessages(discussion.messages), summaryIndex=discussion.rangeSummary ? discussion.messages.findIndex(message=>message.role==='assistant' && message.content===discussion.rangeSummary.finalText) : -1;
      const messages=discussion.rangeSummary
        ? S.followupMessages(summaryIndex>=0 ? history[summaryIndex].content : discussion.rangeSummary.finalText || (discussion.rangeSummary.partials || []).join('\n\n'),history,{preferences:requestPreferences,temporary:'',groupName:groupName(discussion.rangeSummary.groupId),rangeLabel:discussion.rangeSummary.label,coverage:discussion.rangeSummary.coverage.reason,prompt:question})
        : C.requestMessages(discussion.contextSnapshots,history,groupName,fullDate,{preferences:requestPreferences,temporary:''});
      $('ai-question').value='';aiState('已提交 '+discussion.contextSnapshots.length+' 条所选资料 · 可随时取消');
      const result=await rpc('ai',{...configuration,requestId,messages,sources:discussion.rangeSummary ? [] : C.modelSources(discussion.contextSnapshots)});
      if(epoch!==accountEpoch||token!==aiToken)return;
      if(result.cancelled)throw new Error('本次请求已取消，提问与资料已保留。');
      if(typeof result.text!=='string'||!result.text.trim())throw new Error('模型未返回可显示的文字，提问已保留。');
      const elapsed=Math.floor((Date.now()-aiLive.started)/1000),usage=aiLive.usage,warnings=aiLive.warnings,buffered=aiLive.buffered;
      const webSearch=W.normalize(result.webSearch);
      mutate(()=>{userMessage.status='sent';discussion.messages.push({role:'assistant',content:result.text,reasoning:aiLive.reasoning,warnings,...(webSearch?{webSearch}:{}),createdAt:new Date().toISOString()});});responseReceived=true;
      finishAILive();await persist();renderConversation();renderCollections();aiState('已完成 · '+elapsed+' 秒'+(usage&&usage.total_tokens?' · '+usage.total_tokens+' tokens':'')+(buffered?' · 服务一次性返回':'')+(warnings.length?' · '+warnings.join('；'):''),warnings.length>0);
    }catch(error){
      if(epoch!==accountEpoch||token!==aiToken)return;
      const message=errorText(error);
      if(responseReceived){aiState('回复已收到，但尚未保存到磁盘：'+message+'。点击顶部保存状态重试。',true);renderConversation();return;}
      preservePartialAI(discussion);finishAILive();
      if(userMessage){mutate(()=>{userMessage.status='failed';userMessage.error=message;});await persistQuietly();}
      $('ai-question').value=question;aiState(message,true);renderConversation();
    }finally{if(epoch===accountEpoch&&token===aiToken){busyAI=false;renderAIControls();renderContext();if(responseReceived && discussionTitles)discussionTitles.enqueue(discussion.id);}}
  }
  function openSettings() {
    $('api-read-mode').value=state.settings.readMode || 'auto'; $('api-allow-images').checked=!!state.settings.allowImages; $('api-allow-pdf').checked=!!state.settings.allowPDF;
    $('api-base-url').value = state.settings.baseURL || ''; $('api-model').value = state.settings.model || ''; $('api-key').value = '';
    text('key-status', hasAPIKey ? '此账号与地址的 Key 已保存' : '此地址尚未设置 Key'); $('api-key').placeholder = hasAPIKey ? '留空保留此地址的 Key' : '输入此地址对应的 Key'; show('settings-error', false); show('settings-feedback', false); show('model-choice-row', false); updateModelHint(); openDialog('settings-dialog');
    $('settings-dialog').scrollTop = 0; $('settings-body').scrollTop = 0; $('close-settings').focus({ preventScroll: true });
    requestAnimationFrame(() => { if ($('settings-dialog').open) { $('settings-dialog').scrollTop = 0; $('settings-body').scrollTop = 0; } });
    renderSettingsLocks(); renderAIControls(); loadStorageLocations();
  }
  $('toolbar-center').addEventListener('click', () => { if (saveError) persist().then(() => notify('资料已重新保存')).catch(handleError); });
  ['chats', 'bookmarks', 'collections'].forEach(view => $('nav-' + view).addEventListener('click', () => { if (view === 'bookmarks') bookmarkGroupFilter = ''; setView(view); }));
  $('bookmark-group-filter').addEventListener('change', () => { bookmarkGroupFilter = $('bookmark-group-filter').value; renderBookmarks(); });
  $('mode-official').addEventListener('click', () => setMode('official')); $('mode-reader').addEventListener('click', () => setMode('reader'));
  $('group-search').addEventListener('input', renderSidebar);
  $('manage-sync-groups').addEventListener('click', () => {
    if (!ready || !state.accountId || syncGroupsSaving || loadFailed || quitting) return;
    $('sync-groups-form').querySelectorAll('button, input').forEach(control => { control.disabled = false; });
    show('sync-groups-error', false);
    replace('sync-groups-list', state.groups.map(group => {
      const label = node('label', 'sync-group-row'), check = document.createElement('input');
      check.type = 'checkbox'; check.className = 'sync-group-checkbox'; check.dataset.groupId = group.id; check.checked = group.selected;
      label.append(check, node('span', '', group.name), node('small', 'muted', 'ID ' + group.id)); return label;
    }));
    openDialog('sync-groups-dialog');
  });
  $('sync-groups-dialog').addEventListener('cancel', event => { if (syncGroupsSaving) event.preventDefault(); });
  $('sync-groups-form').addEventListener('submit', async event => {
    event.preventDefault(); if (syncGroupsSaving) return;
    const epoch = accountEpoch, previous = new Map(state.groups.map(group => [group.id, group.selected]));
    syncGroupsSaving = true; $('sync-groups-form').querySelectorAll('button, input').forEach(control => { control.disabled = true; }); show('sync-groups-error', false);
    try {
      $('sync-groups-list').querySelectorAll('input').forEach(check => { M.selectGroup(state, check.dataset.groupId, check.checked); });
      U.initialize(state); await persist(); if (epoch !== accountEpoch) return;
      state.groups.filter(group => previous.get(group.id) && !group.selected).forEach(group => U.acknowledge(state, group.id, archive().forGroup(group.id))); persistQuietly();
      $('sync-groups-dialog').close(); renderSidebar(); renderHeader(); renderReader(); notify('同步选择已保存，当前阅读位置保留');
    } catch (error) {
      if (epoch !== accountEpoch) return;
      mutate(() => state.groups.forEach(group => { if (previous.has(group.id)) group.selected = previous.get(group.id); })); persistQuietly();
      text('sync-groups-error', errorText(error) + '。同步选择未更改，请重试。'); show('sync-groups-error', true);
    } finally { if (epoch === accountEpoch) { syncGroupsSaving = false; $('sync-groups-form').querySelectorAll('button, input').forEach(control => { control.disabled = false; }); } }
  });

  ['open-official', 'refresh-groups', 'reload-official'].forEach(id => $(id).addEventListener('click', () => {
    if (!native) { notify('这是浏览器预览。点击「加载演示」体验专注阅读，真实登录请使用 Mac 应用。'); return; }
    if (id === 'refresh-groups') $('sync-groups-dialog').close();
    setMode('official', { navigate: false });
    rpc('openOfficial', activeGroupId ? { groupId: activeGroupId } : {}).then(() => id === 'open-official' ? null : rpc('reloadOfficial')).catch(handleError);
  }));
  $('load-history').addEventListener('click', () => requestSync(true));
  $('sync-now').addEventListener('click', () => requestSync(false));
  $('coverage-action').addEventListener('click', () => {
    if (mode === 'official') { if (native) rpc('openOfficial', activeGroupId ? { groupId: activeGroupId } : {}).catch(handleError); return; }
    saveReturnPoint(); resetFilters(); suppressScrollUntil = Date.now() + 350;
    // Resolve the final message through the virtual list so measured row heights
    // cannot leave it below the viewport after an estimated scroll-to-bottom.
    const latest = renderedMessages[renderedMessages.length - 1];
    if (latest) scrollToMessage(latest.id, 0, false);
    renderProgressButtons();
  });
  $('message-search').addEventListener('input', () => { clearTimeout(searchTimer); searchTimer = setTimeout(filterChanged, 120); });
  $('member-filter-button').addEventListener('click', () => { show('member-popover', $('member-popover').hidden); if (!$('member-popover').hidden) { renderMembers(); $('member-search').focus(); } });
  $('member-search').addEventListener('input', renderMembers);
  $('date-filter-button').addEventListener('click', () => { show('date-filter', $('date-filter').hidden); });
  ['date-from', 'date-to'].forEach(id => $(id).addEventListener('change', filterChanged));
  $('clear-dates').addEventListener('click', () => { $('date-from').value = ''; $('date-to').value = ''; filterChanged(); });
  $('clear-filters').addEventListener('click', resetFilters);
  const aiFontSizes = [14, 16, 18, 20, 22];
  function applyAIFontSize() {
    const size = aiFontSizes.includes(state.settings.aiFontSize) ? state.settings.aiFontSize : 14;
    document.documentElement.style.setProperty('--ai-reader-size', size + 'px');
    $('ai-font-size').value = String(size);
    $('ai-font-size').disabled = !ready || loadFailed || !state.accountId;
  }
  $('ai-font-size').addEventListener('change', () => {
    const size = Number($('ai-font-size').value);
    if (!ready || loadFailed || !state.accountId || !aiFontSizes.includes(size)) { applyAIFontSize(); return; }
    const conversation = $('conversation');
    const atBottom = conversation.scrollHeight - conversation.clientHeight - conversation.scrollTop < 32;
    const top = conversation.getBoundingClientRect().top;
    const anchor = Array.from(conversation.querySelectorAll('.conversation-message')).find(item => item.getBoundingClientRect().bottom > top);
    const offset = anchor ? anchor.getBoundingClientRect().top - top : 0;
    mutate(() => { state.settings.aiFontSize = size; }); applyAIFontSize();
    if (atBottom) conversation.scrollTop = conversation.scrollHeight;
    else if (anchor) conversation.scrollTop += anchor.getBoundingClientRect().top - top - offset;
    persistQuietly();
  });
  let fontSize = 14;
  $('font-button').addEventListener('change', () => {
    const size = Number($('font-button').value);
    if (![14, 16, 18].includes(size) || size === fontSize) { $('font-button').value = String(fontSize); return; }
    const anchor = visibleMessage(); settleReading(); fontSize = size;
    document.documentElement.style.setProperty('--reader-size', fontSize + 'px');
    if (anchor) scrollToMessage(anchor.messageId, anchor.offset, false); notify('阅读字号 ' + fontSize);
  });
  $('clear-selection').addEventListener('click', () => { selected.clear(); renderReader(); });
  $('use-selection').addEventListener('click', () => { try { addContext(M.buildContext(state, Array.from(selected)).messages); } catch (error) { handleError(error); } });
  if ($('translate-selection')) $('translate-selection').addEventListener('click', () => { try { translateText(M.buildContext(state, Array.from(selected)).messages); } catch (error) { handleError(error); } });
  if ($('import-ai-document')) $('import-ai-document').addEventListener('click', importDocument);
  if ($('save-ai-context')) $('save-ai-context').addEventListener('click', saveContextCollection);
  function openMessageCollection(messages) {
    pendingCollectionKeys = messages.map(M.messageKey); pendingCollection = null; collectionEditing = false; if (!pendingCollectionKeys.length) return;
    text('collection-dialog-title', '加入收藏'); text('confirm-collection', '保存收藏');
    text('collection-selection-summary', '已选中 ' + pendingCollectionKeys.length + ' 条消息'); $('collection-name').value = (currentGroup() ? currentGroup().name : '群聊') + ' · ' + dayDate(new Date().toISOString()); show('collection-error', false); openDialog('collection-dialog'); $('collection-name').focus(); $('collection-name').select();
  }
  $('save-collection').addEventListener('click', () => { try { openMessageCollection(M.buildContext(state, Array.from(selected)).messages); } catch (error) { handleError(error); } });
  $('reader-scroll').addEventListener('wheel', () => { userScrollUntil = Date.now() + 1500; }, { passive: true });
  $('reader-scroll').addEventListener('touchstart', () => { userScrollUntil = Date.now() + 1500; }, { passive: true });
  $('reader-scroll').addEventListener('pointerdown', () => { userScrollUntil = Date.now() + 1500; }, { passive: true });
  $('reader-scroll').addEventListener('keydown', event => { if (['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', 'Home', 'End', ' '].includes(event.key)) userScrollUntil = Date.now() + 1500; });
  $('reader-scroll').addEventListener('scroll', () => {
    if (scrollFrame) return;
    scrollFrame = requestAnimationFrame(() => {
      scrollFrame = 0;
      if (!ReaderViewPolicy.shouldTrackProgress({ mode, view: activeView, filtered: isFiltered(), programmatic: Date.now() < suppressScrollUntil, userInitiated: Date.now() <= userScrollUntil })) return;
      const anchor = visibleMessage(); if (!anchor) return;
      pendingProgress = { accountId: state.accountId, groupId: activeGroupId, messageId: anchor.messageId, offset: anchor.offset };
      clearTimeout(progressTimer);
      progressTimer = setTimeout(() => { try { settleReading(); } catch (error) { handleError(error); } }, 650);
    });
  }, { passive: true });
  $('enter-standby').addEventListener('click', enterStandby);
  $('manual-position').addEventListener('click', () => goToReadingPosition('manual'));
  $('return-position').addEventListener('click', () => goToReadingPosition('returnPoint'));
  $('bookmarks-active').addEventListener('click', () => { deletedBookmarks = false; renderBookmarks(); });
  $('bookmarks-deleted').addEventListener('click', () => { deletedBookmarks = true; renderBookmarks(); });
  $('bookmark-dialog').addEventListener('cancel', event => { if (bookmarkNoteSaving) event.preventDefault(); });
  $('bookmark-form').addEventListener('submit', async event => {
    event.preventDefault(); if (!bookmarkTarget || bookmarkNoteSaving) return;
    const bookmark = state.bookmarks.find(item => item.id === bookmarkTarget && !item.deletedAt && item.accountId === state.accountId);
    if (!bookmark) return;
    const epoch = accountEpoch, oldNote = bookmark.note;
    bookmarkNoteSaving = true; $('bookmark-form').querySelectorAll('button, textarea').forEach(control => { control.disabled = true; });
    try {
      mutate(() => { bookmark.note = $('bookmark-note').value.trim(); });
      await persist(); if (epoch !== accountEpoch) return;
      $('bookmark-dialog').close(); renderSidebar(); renderBookmarks(); notify('书签备注已保存'); bookmarkTarget = null;
    } catch (error) {
      if (epoch !== accountEpoch) return;
      mutate(() => { bookmark.note = oldNote; }); persistQuietly();
      text('bookmark-error', errorText(error) + '。原备注未改变，你输入的内容仍保留在这里，可以重试。'); show('bookmark-error', true);
    } finally { if (epoch === accountEpoch) { bookmarkNoteSaving = false; $('bookmark-form').querySelectorAll('button, textarea').forEach(control => { control.disabled = false; }); } }
  });
  $('collection-form').addEventListener('submit', async event => {
    event.preventDefault(); const submit = $('confirm-collection'); submit.disabled = true; const epoch = accountEpoch;
    try {
      const name = $('collection-name').value.trim(); if (!name) throw new Error('请填写资料名称');
      if (!pendingCollection) pendingCollection = M.createCollection(state, { name, messageIds: pendingCollectionKeys });
      else mutate(() => { pendingCollection.name = name; });
      const collection = pendingCollection; await persist(); if (epoch !== accountEpoch) return;
      $('collection-dialog').close(); renderSidebar(); renderCollections();
      if (collectionEditing) { renderContext(); notify('资料已重命名'); }
      else { notify('已收藏 ' + collection.messages.length + ' 条消息，可在「资料库」查看'); }
      pendingCollection = null; collectionEditing = false;
    } catch (error) { text('collection-error', errorText(error) + '。内容仍在内存，请重试保存。'); show('collection-error', true); }
    finally { submit.disabled = false; }
  });
  $('settings-button').addEventListener('click', openSettings); $('ai-model-button').addEventListener('click', openSettings);
  async function loadStorageLocations() {
    const epoch = accountEpoch;
    ['copy-data-path', 'copy-attachments-path', 'reveal-data-folder', 'reveal-attachments-folder'].forEach(id => { $(id).disabled = true; });
    show('storage-error', false); $('refresh-storage').disabled = true;
    $('data-path').value = $('attachments-path').value = native && !demo ? '正在读取路径…' : '浏览器演示不在磁盘保存资料。';
    if (!native || demo) { $('refresh-storage').disabled = false; return; }
    try {
      const result = await rpc('storageLocations'); if (epoch !== accountEpoch) return;
      for (const [kind, field, property] of [['data', 'data-path', 'dataPath'], ['attachments', 'attachments-path', 'attachmentsPath']]) {
        const path = result[property]; if (typeof path !== 'string' || !path.startsWith('/')) throw new Error('未取得完整的本地保存路径，请刷新重试');
        $(field).value = path; $(field).style.height = 'auto'; $(field).style.height = Math.max(48, $(field).scrollHeight + 2) + 'px'; $('copy-' + kind + '-path').disabled = false; $('reveal-' + kind + '-folder').disabled = false;
      }
    } catch (error) { if (epoch === accountEpoch) { ['copy-data-path', 'copy-attachments-path', 'reveal-data-folder', 'reveal-attachments-folder'].forEach(id => { $(id).disabled = true; }); $('data-path').value = $('attachments-path').value = '暂未读取到路径'; text('storage-error', errorText(error)); show('storage-error', true); } }
    finally { $('refresh-storage').disabled = false; }
  }
  async function openStorageLocation(kind) {
    const button = $('reveal-' + kind + '-folder'), epoch = accountEpoch; button.disabled = true;
    try { await rpc('revealStorage', { kind }); }
    catch (error) { if (epoch === accountEpoch) { text('storage-error', errorText(error)); show('storage-error', true); } }
    finally { if (epoch === accountEpoch) button.disabled = false; }
  }
  async function copyStoragePath(kind) {
    const path = $(kind === 'data' ? 'data-path' : 'attachments-path').value;
    if (!path.startsWith('/')) return;
    try { await rpc('copy', { text: path }); notify('完整路径已复制'); } catch (error) { text('storage-error', errorText(error)); show('storage-error', true); }
  }
  $('refresh-storage').addEventListener('click', loadStorageLocations);
  ['data', 'attachments'].forEach(kind => {
    $('reveal-' + kind + '-folder').addEventListener('click', () => openStorageLocation(kind));
    $('copy-' + kind + '-path').addEventListener('click', () => copyStoragePath(kind));
  });
  function cleanupOptions() { return {scope:$('cleanup-scope').value,groupId:activeGroupId,categories:['text','image','document'].filter(kind=>$('cleanup-'+kind).checked)}; }
  function cleanupSourceState() {
    // The unsent AI tray is a user-selected reference too. Protect its sources without persisting a fake discussion.
    return {...state,discussions:state.discussions.concat(context.length ? [{id:'cleanup-draft-protection',contextSnapshots:context}] : [])};
  }
  function invalidateCleanup() { cleanupPlan=null; $('cleanup-apply').disabled=true; text('cleanup-summary','请选择类别，然后预览将清理的内容。'); }
  function updateCleanupUndo() { $('cleanup-undo').disabled=cleanupBusy || !cleanupHasUndoReceipt; }
  function lockCleanup(value) {
    cleanupBusy=value;
    ['cleanup-scope','cleanup-text','cleanup-image','cleanup-document','cleanup-preview','close-cleanup'].forEach(id=>$(id).disabled=value);
    $('cleanup-apply').disabled=value || !cleanupPlan;updateCleanupUndo();
  }
  function drainCleanupEvents() { const pending=cleanupEvents;cleanupEvents=[];pending.forEach(event=>window.onNativeEvent(event)); }
  async function cleanupStatus() {
    const epoch=accountEpoch,request=++cleanupStatusRequest;
    cleanupHasUndoReceipt=false;updateCleanupUndo();
    try {
      const result=await rpc('cleanupStatus',{accountId:state.accountId});
      if(epoch===accountEpoch && request===cleanupStatusRequest){cleanupHasUndoReceipt=!!result.receipt;updateCleanupUndo();}
    } catch (_) { if(epoch===accountEpoch && request===cleanupStatusRequest){cleanupHasUndoReceipt=false;updateCleanupUndo();} }
  }
  $('open-cleanup').addEventListener('click',()=>{
    if(busyAI||inlineBusy()||preparingContext||cancellingAI){notify('请先完成或取消当前 AI 任务，再清理缓存。');return;}
    $('cleanup-scope').value=activeGroupId?'group':'all';['text','image','document'].forEach(kind=>$('cleanup-'+kind).checked=false);
    invalidateCleanup();show('cleanup-error',false);$('settings-dialog').close();requestAnimationFrame(()=>{openDialog('cleanup-dialog');$('cleanup-scope').focus();});cleanupStatus();
  });
  ['cleanup-scope','cleanup-text','cleanup-image','cleanup-document'].forEach(id=>$(id).addEventListener('change',invalidateCleanup));
  $('cleanup-dialog').addEventListener('cancel',event=>{if(cleanupBusy)event.preventDefault();});
  $('cleanup-preview').addEventListener('click',async()=>{
    if(cleanupBusy)return;show('cleanup-error',false);const epoch=accountEpoch;
    try {
      lockCleanup(true);await flushSavedState();
      const options=cleanupOptions(),summary=ReaderCleanup.preview(cleanupSourceState(),options),revision=state.revision;
      const disk=await rpc('cleanupPreview',{accountId:state.accountId,revision,refs:summary.assetRefs});
      if(epoch!==accountEpoch)return;
      cleanupPlan={options,summary,revision};
      const size=disk.bytes>=1048576?(disk.bytes/1048576).toFixed(1)+' MB':Math.ceil((disk.bytes||0)/1024)+' KB';
      text('cleanup-summary','文字：'+summary.counts.text+' 条\n图片：'+summary.counts.image+' 项 · 文档：'+summary.counts.document+' 项\n已下载文件：'+disk.fileCount+' 个 · '+size+'\n自动保护 '+summary.protectedCount+' 条被引用的消息。');
    }catch(error){cleanupPlan=null;text('cleanup-error',errorText(error));show('cleanup-error',true);}
    finally{lockCleanup(false);drainCleanupEvents();}
  });
  $('cleanup-apply').addEventListener('click',async()=>{
    if(cleanupBusy||!cleanupPlan)return;const epoch=accountEpoch;
    try {
      lockCleanup(true);show('cleanup-error',false);settleReading();await flushSavedState();
      if(state.revision!==cleanupPlan.revision)throw new Error('预览后资料发生了更新，请重新预览再清理。');
      const prepared=ReaderCleanup.apply(cleanupSourceState(),cleanupPlan.options);
      prepared.state.discussions=prepared.state.discussions.filter(item=>item.id!=='cleanup-draft-protection');
      const result=await rpc('cleanupApply',{accountId:state.accountId,revision:state.revision,state:prepared.state,refs:prepared.summary.assetRefs});
      if(epoch!==accountEpoch)return;
      state=M.normalizeState(result.state);savedRevision=state.revision;saveError='';
      selected.clear();readerList.clear();archiveDirty=true;previewCache.clear();if(imageObserver)imageObserver.disconnect();renderAll({restore:true});
      cleanupPlan=null;text('cleanup-summary','清理完成。文件已移到系统废纸篓，书签、收藏和讨论已保留。需要时可撤销上一次清理。');setSaveStatus('','已保存至本机');
    }catch(error){text('cleanup-error',errorText(error));show('cleanup-error',true);cleanupPlan=null;}
    finally{lockCleanup(false);drainCleanupEvents();cleanupStatus();}
  });
  $('cleanup-undo').addEventListener('click',async()=>{
    if(cleanupBusy)return;const epoch=accountEpoch;
    try{
      lockCleanup(true);await flushSavedState();
      const result=await rpc('cleanupUndo',{accountId:state.accountId,revision:state.revision});if(epoch!==accountEpoch)return;
      state=ReaderCleanup.undo(state,result.beforeState);state.cleanup.lastUndoReceiptId=result.id;readerList.clear();archiveDirty=true;previewCache.clear();await persist();renderAll({restore:true});
      cleanupPlan=null;text('cleanup-summary','已恢复上一次清理的内容。'+(result.warnings||[]).join('；'));
    }catch(error){text('cleanup-error',errorText(error));show('cleanup-error',true);}
    finally{lockCleanup(false);drainCleanupEvents();cleanupStatus();}
  });
  function updateModelHint() {
    let deepseek = false; try { deepseek = new URL($('api-base-url').value).hostname === 'api.deepseek.com'; } catch (_) {}
    text('model-id-hint', deepseek ? '官方当前 deepseek-flash 对应 DeepSeek-V4.1-Flash-1017（2026-10-18 核实）。1017 是版本名；API 名称仍可能保持 deepseek-flash。刷新会直接请求服务最新列表。' : '填写 API 调用使用的模型 ID；可以读取服务商返回的可用模型。');
  }
  function readSettingsInputs(requireModel = true) {
    if (!native || demo) throw new Error('请在微阅 Mac 应用中配置和测试模型。');
    if (!state.accountId) throw new Error('请先在官方页面登录微博，再配置此账号的模型。');
    const baseURL = $('api-base-url').value.trim().replace(/\/+$/, ''), model = $('api-model').value.trim();
    let parsed; try { parsed = new URL(baseURL); } catch (_) { throw new Error('请填写有效的 HTTPS 服务地址'); }
    if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password || parsed.search || parsed.hash || /[?#]/.test(baseURL)) throw new Error('请使用不含账号密码、查询参数或片段的 HTTPS 服务地址');
    if (requireModel && !model) throw new Error('请填写或选择模型 ID');
    return { accountId: state.accountId, baseURL, model,readMode:$('api-read-mode').value,allowImages:$('api-allow-images').checked,allowPDF:$('api-allow-pdf').checked };
  }
  function renderSettingsLocks() {
    const locked = settingsBusy || busyAI || inlineBusy() || preparingContext || cancellingAI || quitting || cleanupBusy;
    ['save-settings', 'list-models', 'test-ai', 'authorize-ai', 'api-base-url', 'api-model', 'api-key', 'api-model-choice','api-read-mode','api-allow-images','api-allow-pdf'].forEach(id => { $(id).disabled = locked; });
  }
  function setSettingsBusy(value, action) {
    settingsBusy = value;
    ['save-settings', 'list-models', 'test-ai', 'authorize-ai', 'api-base-url', 'api-model', 'api-key', 'api-model-choice','api-read-mode','api-allow-images','api-allow-pdf'].forEach(id => { $(id).disabled = value; });
    text('list-models', value && action === 'listModels' ? '正在刷新…' : '刷新可用模型');
    text('test-ai', value && action === 'testAI' ? '正在测试…' : '测试连接');
    text('save-settings', value && action === 'save' ? '正在保存…' : '保存设置');
    renderAIControls();
  }
  async function prepareSettingsKey(configuration, epoch) {
    const key = $('api-key').value.trim();
    const result = key ? await rpc('saveKey', { accountId: configuration.accountId, baseURL: configuration.baseURL, key }) : await rpc('keyStatus', { accountId: configuration.accountId, baseURL: configuration.baseURL });
    if (epoch !== accountEpoch) throw new Error('账号已切换，请在当前账号下重新操作');
    if ($('api-base-url').value.trim().replace(/\/+$/, '') !== configuration.baseURL) throw new Error('API 地址已更改，请按当前地址重新操作');
    $('api-key').value = ''; text('key-status', result.hasAPIKey ? '此账号与地址的 Key 已保存' : '此地址尚未设置 Key');
    if (configuration.baseURL === state.settings.baseURL) hasAPIKey = !!result.hasAPIKey;
    return !!result.hasAPIKey;
  }
  async function runSettingsCheck(action) {
    if (settingsBusy || inlineBusy()) return;
    const epoch = accountEpoch; show('settings-error', false); show('settings-feedback', false); setSettingsBusy(true, action);
    try {
      const configuration = readSettingsInputs(action === 'testAI');
      if (!await prepareSettingsKey(configuration, epoch)) throw new Error('此账号与 API 地址尚未配置 Key，请先填写 Key');
      const result = await rpc(action, ReaderViewPolicy.settingsProbePayload(action, configuration));
      if (epoch !== accountEpoch) return;
      if (action === 'listModels') {
        const models = Array.isArray(result.models) ? result.models.filter(model => model && typeof model.id === 'string' && model.id) : [];
        if (!models.length) throw new Error('服务未返回可用的模型 ID；你仍可以按服务商文档手动填写。');
        const options = [node('option', '', '请选择模型 ID')]; options[0].value = '';
        models.forEach(model => { const option = node('option', '', model.name && model.name !== model.id ? model.name + ' · ' + model.id : model.id); option.value = model.id; options.push(option); });
        replace('api-model-choice', options); $('api-model-choice').value = models.some(model => model.id === configuration.model) ? configuration.model : ''; show('model-choice-row', true);
        text('settings-feedback', '已从服务实时刷新 ' + models.length + ' 个模型 · ' + new Date().toLocaleTimeString() + '。选择后保存。最新版本可能沿用同一个 API 名称；列表仅显示服务实际返回的 ID。');
      } else text('settings-feedback', '连接测试成功 · ' + configuration.model + '\n回复：' + shortText(typeof result.text === 'string' ? result.text : '服务已响应', 180));
      show('settings-feedback', true);
    } catch (error) { if (epoch === accountEpoch) { text('settings-error', errorText(error)); show('settings-error', true); } }
    finally { setSettingsBusy(false); }
  }
  $('api-base-url').addEventListener('input', () => {
    const unchanged = $('api-base-url').value.trim().replace(/\/+$/, '') === state.settings.baseURL;
    text('key-status', unchanged ? (hasAPIKey ? '此账号与地址的 Key 已保存' : '此地址尚未设置 Key') : '地址已更改 · 保存时检查对应 Key');
    $('api-key').placeholder = unchanged && hasAPIKey ? '留空保留此地址的 Key' : '输入此地址对应的 Key';
    show('model-choice-row', false); show('settings-feedback', false); updateModelHint();
  });
  $('api-model-choice').addEventListener('change', () => { if ($('api-model-choice').value) $('api-model').value = $('api-model-choice').value; });
  $('list-models').addEventListener('click', () => runSettingsCheck('listModels'));
  $('test-ai').addEventListener('click', () => runSettingsCheck('testAI'));
  $('authorize-ai').addEventListener('click', async () => {
    if (settingsBusy || inlineBusy() || !native || demo) return;
    const epoch = accountEpoch; setSettingsBusy(true, 'authorize');
    show('settings-error', false); text('settings-feedback', '请在 macOS 钥匙串提示中确认访问。此操作不会把密钥或聊天资料发送给任何服务。'); show('settings-feedback', true);
    try {
      const configuration = readSettingsInputs(false);
      const result = await rpc('authorizeAI', {accountId: configuration.accountId, baseURL: configuration.baseURL});
      if (epoch !== accountEpoch) return;
      if (!result.hasAPIKey) throw new Error('此账号与 API 地址没有已保存的 Key，请填写后保存。');
      hasAPIKey = true; text('settings-feedback', '钥匙串访问已确认，可以测试连接或继续翻译、解读。');
    } catch (error) { if (epoch === accountEpoch) { text('settings-error', errorText(error)); show('settings-error', true); show('settings-feedback', false); } }
    finally { setSettingsBusy(false); }
  });
  $('settings-form').addEventListener('submit', async event => {
    event.preventDefault(); if (settingsBusy || inlineBusy()) return; const epoch = accountEpoch; setSettingsBusy(true, 'save'); show('settings-error', false);
    try {
      const configuration = readSettingsInputs();
      const keyAvailable = await prepareSettingsKey(configuration, epoch); if (epoch !== accountEpoch) return;
      mutate(() => { state.settings.baseURL = configuration.baseURL; state.settings.model = configuration.model; state.settings.readMode=configuration.readMode; state.settings.allowImages=configuration.allowImages; state.settings.allowPDF=configuration.allowPDF; }); hasAPIKey = keyAvailable;
      await persist(); if (epoch !== accountEpoch) return; $('settings-dialog').close(); renderHeader(); renderAIControls(); notify(hasAPIKey ? 'AI 设置已保存' : '设置已保存，此 API 地址尚未配置 Key');
    } catch (error) { if (epoch === accountEpoch) { text('settings-error', errorText(error)); show('settings-error', true); } }
    finally { setSettingsBusy(false); }
  });
  document.querySelectorAll('[data-close-dialog]').forEach(el => el.addEventListener('click', () => $(el.dataset.closeDialog).close()));
  document.querySelectorAll('dialog').forEach(dialog => dialog.addEventListener('close', () => { $('api-key').value = ''; scheduleLayout(); }));
  $('ai-thinking').addEventListener('click',()=>{if($('ai-thinking').disabled || !thinkingOption().toggle)return;mutate(()=>state.settings.thinking=thinkingOption().enabled?'disabled':'enabled');renderAIControls();persistQuietly();});
  $('ai-web-search').addEventListener('click',()=>{if($('ai-web-search').disabled)return;mutate(()=>state.settings.webSearchEnabled=state.settings.webSearchEnabled!==true);renderAIControls();persistQuietly();});
  $('context-disclosure').addEventListener('toggle',scheduleLayout);
  $('ai-form').addEventListener('submit', sendAI);
  $('ai-question').addEventListener('keydown', event => { if (event.key === 'Enter' && !event.shiftKey && !event.isComposing && event.keyCode !== 229) { event.preventDefault(); $('ai-form').requestSubmit(); } });
  async function stopCurrentAI() {
    if (quitting || cancellingAI) return;
    if (inlineBusy() || rangeOperation) {
      const epoch=accountEpoch; cancellingAI=true; renderAIControls();
      try { if(inlineBusy())await inlineTranslation.cancel('翻译已停止，已收到的内容仍保留。');else await cancelRangeSummary(); }
      catch(error){if(epoch===accountEpoch&&!quitting)handleError(error);}
      finally{if(epoch===accountEpoch&&!quitting){cancellingAI=false;renderAIControls();renderContext();}}
      return;
    }
    if (preparingContext) {
      const epoch=accountEpoch; ++preparationToken; preparingContext=false; cancellingAI=true;
      aiState('正在停止读取…'); renderAIControls(); renderContext();
      try { await rpc('cancelContent'); if(epoch===accountEpoch&&!quitting)aiState('已停止读取，本次内容没有提交给 AI。'); }
      catch(error){if(epoch===accountEpoch&&!quitting)aiState(errorText(error),true);}
      finally{if(epoch===accountEpoch&&!quitting){cancellingAI=false;renderAIControls();renderContext();}}
      return;
    }
    if (!busyAI || quitting) return;
    const epoch = accountEpoch; ++aiToken; busyAI = false; cancellingAI = true;
    const question = ReaderViewPolicy.interruptPendingAI(state, currentDiscussionId, '本次请求已取消，提问与资料已保留。');
    if (question) $('ai-question').value = question;
    preservePartialAI(currentDiscussion()); finishAILive();
    aiState('正在取消，提问与资料会保留…'); renderAIControls(); renderContext(); renderConversation();
    try { await Promise.all([rpc('cancelAI'), persist()]); if (epoch === accountEpoch && !quitting) aiState('本次请求已取消，提问与资料已保留。'); }
    catch (error) { if (epoch === accountEpoch && !quitting) aiState(errorText(error), true); }
    finally { if (epoch === accountEpoch && !quitting) { cancellingAI = false; renderAIControls(); renderContext(); } }
  }
  $('ai-cancel').addEventListener('click', stopCurrentAI);
  $('clear-context').addEventListener('click', () => { if (contextBusy()) return; context = []; abandonCurrentDiscussion(); renderContext(); renderConversation(); });
  $('new-discussion').addEventListener('click', newDiscussion);
  $('discussion-history').addEventListener('click', () => { show('discussion-list', $('discussion-list').hidden); if (!$('discussion-list').hidden) {renderDiscussionHistory();if(discussionTitles&&!deletedDiscussions)discussionTitles.enqueueAll();} });
  $('discussion-title-action').addEventListener('click', () => {
    if(!titleConfigurationReady()){openSettings();return;}
    const status=discussionTitles.status();
    if(status.paused){discussionTitles.enqueueAll();discussionTitles.resume();}
    else if(status.remaining)discussionTitles.pause();
    else if(status.failed)discussionTitles.retry();
    else discussionTitles.enqueueAll();
  });
  $('close-discussion-history').addEventListener('click',()=>show('discussion-list',false));
  $('discussions-active').addEventListener('click',()=>{deletedDiscussions=false;historyError(null);renderDiscussionHistory();if(discussionTitles)discussionTitles.enqueueAll();});
  $('discussions-deleted').addEventListener('click',()=>{deletedDiscussions=true;historyError(null);renderDiscussionHistory();});
  $('discussions-clear').addEventListener('click',()=>confirmDiscussionDeletion(state.discussions.filter(d=>!d.deletedAt).map(d=>d.id)));
  $('discussions-restore-all').addEventListener('click',()=>changeDiscussionDeletion(state.discussions.filter(d=>d.deletedAt).map(d=>d.id),true));
  $('discussion-delete-form').addEventListener('submit',event=>{event.preventDefault();changeDiscussionDeletion(pendingDiscussionDeleteIds);});
  ['discussion-delete-close','discussion-delete-cancel'].forEach(id=>$(id).addEventListener('click',()=>{if(!discussionHistoryBusy)$('discussion-delete-dialog').close();}));
  $('discussion-delete-dialog').addEventListener('cancel',event=>{if(discussionHistoryBusy)event.preventDefault();});
  $('open-preferences').addEventListener('click', () => { if (!localSettingsLocked()) $('settings-dialog').close(); }, true);
  followedUI = window.ReaderPersonalization.mount({
    getState: () => state, getGroupId: () => activeGroupId,
    save: members => savePersonalization(state.settings, 'followedMembers', window.ReaderPersonalization.validate(members)),
    onChange: refreshMountedCards, onDialogChange: scheduleLayout
  });
  $('open-followed-members').addEventListener('click', () => { if (localSettingsLocked()) return; $('settings-dialog').close(); followedUI.open(); });
  readingAppearance = window.ReaderReadingAppearance.mount({rpc,canUse:()=>native&&ready&&!demo&&!quitting,
    beforeApply:()=>{const anchor=visibleMessage();settleReading();return anchor?{...anchor,navigationEpoch:readingNavigationEpoch}:null;},
    afterApply:anchor=>{
      const restore=()=>{if(anchor&&anchor.accountId===state.accountId&&anchor.groupId===activeGroupId&&anchor.navigationEpoch===readingNavigationEpoch)scrollToMessage(anchor.messageId,anchor.offset,false);};
      restore();requestAnimationFrame(restore);scheduleLayout();
    },
    onDialogChange:scheduleLayout
  });
  $('open-reading-appearance').addEventListener('click',()=>{if(quitting)return;$('settings-dialog').close();readingAppearance.open();});
  inlineTranslation = window.ReaderInlineTranslation.create({
    getState: () => state, getConfiguration: () => ({ accountId: state.accountId, ...aiConfiguration() }), rpc,
    persist: source => { if (source !== state) return Promise.reject(new Error('账号已切换')); return persist(); },
    onChange: () => { refreshMountedCards(); renderAIControls(); },
    assertCanStart: () => {
      if (!native || demo) throw new Error('请在微阅 Mac 应用中配置模型后翻译。');
      if (!ready || loadFailed || !state.accountId) throw new Error('请先登录微博并载入资料。');
      if (settingsBusy || busyAI || preparingContext || cancellingAI || quitting || cleanupBusy || preferencesSaving || discussionHistoryBusy || modelCapabilitiesLoading()) throw new Error('请等待当前操作完成后再翻译。');
      if (!state.settings.baseURL || !state.settings.model || !hasAPIKey) { openSettings(); throw new Error('请先设置模型服务与 API Key。'); }
    }, onError: handleError
  });
  preferencesUI = window.ReaderPreferencesUI.mount({
    getLibrary: () => A.read(state.settings),
    getAccountId: () => state.accountId, isLocked: preferencesLocked, isLibraryLocked: localSettingsLocked,
    saveLibrary: library => savePersonalization(state.settings, 'aiPreferences', A.validate(library)),
    fillPrompt: prompt => { if (preferencesLocked()) return; $('ai-question').value = prompt; $('ai-question').focus(); }
  });
  window.addEventListener('weiyue:preferences-dialog-change', scheduleLayout);
  rangeUI = window.ReaderRangeSummaryUI.mount({
    getAccountId:()=>state.accountId,getGroupId:()=>activeGroupId,getGroupName:()=>currentGroup()?.name || '',
    getDefaults:()=>{const now=new Date(),latest=localMinute(now),end=$('date-to').value ? $('date-to').value+'T23:59' : latest;return {start:$('date-from').value ? $('date-from').value+'T00:00' : localMinute(new Date(now.getFullYear(),now.getMonth(),now.getDate())),end:end>latest?latest:end};},
    preview:previewRange,start:startRangeSummary,cancel:cancelRangeSummary,
    showResult:id=>{const discussion=state.discussions.find(item=>item.id===id && !item.deletedAt);if(discussion && !contextBusy()){currentDiscussionId=id;context=discussion.contextSnapshots || [];contextCollectionId=discussion.collectionId || null;summarySourcePage=0;rememberActiveDiscussion();revealInspector();renderContext();renderConversation();renderAIControls();}},
    isLocked:groupId=>preferencesLocked() || !state.groups.find(item=>item.id===groupId)?.selected
  });
  window.addEventListener('weiyue:range-summary-dialog-change',scheduleLayout);
  $('dismiss-status').addEventListener('click', () => show('status-banner', false));
  document.addEventListener('click', event => { document.querySelectorAll('.compact-menu[open]').forEach(menu => { if (!menu.contains(event.target)) menu.open = false; }); if (!$('member-popover').hidden && !$('member-popover').contains(event.target) && !$('member-filter-button').contains(event.target)) show('member-popover', false); const path=event.composedPath();if(!$('discussion-list').hidden&&!path.includes($('discussion-list'))&&!path.includes($('discussion-history'))&&!path.includes($('discussion-delete-dialog')))show('discussion-list',false); });
  document.addEventListener('keydown', event => { if (event.key === 'Escape') { document.querySelectorAll('.compact-menu[open]').forEach(menu => menu.open = false); show('member-popover', false); show('discussion-list', false); } });
  window.addEventListener('weiyue:bookmark-note', event => { const value = event.detail || {}; openBookmarkNote(state.bookmarks.find(item => item.id === value.bookmarkId)); });
  window.addEventListener('weiyue:bookmark-jump', event => { const value = event.detail || {}; if (value.groupId && value.messageId) jumpTo(value.groupId, value.messageId); });
  window.addEventListener('weiyue:show-bookmarks', event => { bookmarkGroupFilter = event.detail && event.detail.groupId || ''; setView('bookmarks'); });
  window.addEventListener('weiyue:open-storage', () => { if (native && !demo) rpc('revealStorage', {kind:'data'}).catch(handleError); else notify('请在微阅 Mac 应用中打开保存文件夹。'); });
  window.addEventListener('weiyue:layout-start', () => { resizingAnchor = visibleMessage(); userScrollUntil = 0; suppressScrollUntil = Date.now() + 1000; });
  function keepLayoutAnchor() { suppressScrollUntil = Date.now() + 500; userScrollUntil = 0; if (resizingAnchor && resizingAnchor.accountId === state.accountId && resizingAnchor.groupId === activeGroupId) scrollToMessage(resizingAnchor.messageId, resizingAnchor.offset, false); scheduleLayout(); }
  window.addEventListener('weiyue:layout-change', keepLayoutAnchor);
  window.addEventListener('weiyue:layout-end', () => { keepLayoutAnchor(); requestAnimationFrame(() => { keepLayoutAnchor(); resizingAnchor = null; }); });
  window.addEventListener('weiyue:appearance-save',event=>{if(native && ready && !demo)rpc('saveAppearance',event.detail).catch(handleError);});
  window.addEventListener('weiyue:layout-save', event => { if (native && ready && !demo) rpc('saveLayout', { preferences: event.detail }).catch(handleError); });
  window.addEventListener('resize', scheduleLayout); new ResizeObserver(scheduleLayout).observe($('official-host'));

  function loadDemo() {
    if (native) return;
    demo = true; const sample = M.createState('demo-account');
    M.upsertGroups(sample, [{ id: 'demo-001', name: '科技与长期主义', selected: true }, { id: 'demo-002', name: '好书共读小组', selected: true }, { id: 'demo-003', name: '产品观察室', selected: false }]);
    const examples = [
      ['31001', '林间', '今天读到一个挺有意思的观点：工具缩短的是完成一件事的时间，但判断哪件事值得做，反而变得更重要了。'],
      ['31002', '阿远', '我最近也有这个感受。以前我们会问“这个功能能不能做”，现在更应该问“为什么需要它”。'],
      ['31003', '小满', '赞同。拿阅读来说，收藏越来越方便，但真正消化一段讨论，往往还是要停下来想一会儿。'],
      ['31001', '林间', '所以我开始给阅读留位置。不只是标记读到了哪里，也写一句当时想到什么。下次回来，能接上那一刻的思路。'],
      ['31004', '阿远', '补充一个不同角度：有时我们不是读得不够，而是缺少把几个观点放在一起比较的机会。'],
      ['31002', '阿远', '这里需要区分两件事：保存原话，和形成自己的判断。前者尽量完整，后者可以保留疑问。'],
      ['31003', '小满', '我把今天的讨论归成了三个问题：\n1. 什么信息值得反复读？\n2. 观点的依据是什么？\n3. 哪些条件变化后，需要重新考虑？'],
      ['31001', '林间', '第三个问题尤其值得留下。一个结论如果没有适用条件，就很难知道什么时候该修正。'],
      ['31005', '周末读者', '刚翻到前面的消息。这段可以收藏成一组，之后再拿新的例子来对照。'],
      ['31003', '小满', '那就先从一个小习惯开始：每次遇到想继续想的问题，留下一条带时间的标记。']
    ];
    const messages = examples.map((row, i) => ({ id: '90000000000000000' + i, groupId: 'demo-001', senderId: row[0], senderName: row[1], text: row[2], sentAt: new Date('2026-10-17T09:20:00+08:00').getTime() + i * 130000, attachments: [] })).map(m => ({ ...m, sentAt: new Date(m.sentAt).toISOString() }));
    M.ingestMessages(sample, 'demo-001', messages);
    M.ingestMessages(sample, 'demo-002', [{ id: '900000000000000009', groupId: 'demo-002', senderId: '41001', senderName: '书页', text: '读完一章后，写下一个仍然没有答案的问题。\n\n这是一条演示消息，所有人物与群聊均为虚构。', sentAt: '2026-10-17T03:00:00.000Z', attachments: [] }]);
    M.addBookmark(sample, { groupId: 'demo-001', messageId: messages[3].id, note: '从这里继续：记下当时的想法', now: '2026-10-17T02:13:27.000Z' });
    const collection = M.createCollection(sample, { name: '关于阅读与判断的三个问题', messageIds: [messages[3], messages[5], messages[6]].map(M.messageKey), now: '2026-10-17T02:15:30.000Z' });
    replaceAccount(sample, false, '演示账号'); demo = true; text('demo-badge', '演示 · 虚构内容'); text('load-demo', '重置演示');
    mode = 'reader'; activeView = 'chats'; context = clone(collection.messages); contextCollectionId = collection.id;
    setSaveStatus('', '演示 · 仅当前窗口'); renderAll();
  }
  $('load-demo').addEventListener('click', loadDemo);
  async function initialize() {
    renderAll();
    if (!native) {
      ready = true; show('demo-badge', true); show('load-demo', true); setSaveStatus('', '浏览器预览 · 未载入资料');
      text('official-placeholder-text', '这是微阅的浏览器预览。真实微博登录与保存请使用 Mac 应用。\n点击右上角「加载演示」可体验阅读与资料整理。'); return;
    }
    try {
      const result = await rpc('ready');
      if (window.ReaderLayout && result.layoutPreferences) ReaderLayout.restore(result.layoutPreferences);
      if(window.ReaderAppearance) ReaderAppearance.restore(result.appearance);
      if(readingAppearance&&result.readingAppearance)await readingAppearance.restore(result.readingAppearance);
      state = M.normalizeState(result.state || M.createState()); hasAPIKey = !!result.hasAPIKey; accountName = result.accountName || ''; savedRevision = state.revision;
      const preferences = ReaderViewPolicy.readPreferences(state); activeGroupId = preferences.groupId; mode = preferences.mode;
      restoreActiveDiscussion();
      ready = true; setSaveStatus('', state.accountId ? '已保存至本机' : '等待登录');
      if (U.initialize(state)) persistQuietly();
      recoverRangeSummaries();
      const events = queuedEvents; queuedEvents = []; events.forEach(receiveEvent); renderAll({ restore: true });
    } catch (error) { ready = true; loadFailed = true; setSaveStatus('failed', '载入失败'); banner('本地资料载入失败：' + errorText(error) + '。为保护原有资料，请关闭并重新打开应用。'); }
    scheduleLayout();
  }
  discussionTitles=window.ReaderDiscussionTitles.createQueue({
    getState:()=>state,canRun:titleWorkAvailable,
    configuration:()=>({baseURL:state.settings.baseURL,model:state.settings.model}),
    request:payload=>rpc('titleDiscussion',payload),cancel:job=>rpc('cancelDiscussionTitle',{accountId:job.state.accountId}),save:()=>persist(),
    onChange:()=>{renderDiscussionTitleStatus();if(!$('discussion-list').hidden)renderDiscussionHistory();const current=currentDiscussion();text('discussion-title',current?current.title || '讨论':'新讨论');}
  });
  initialize();
})();
