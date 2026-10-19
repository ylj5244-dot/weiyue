(function (root) {
  'use strict';
  const DEFAULT_QUESTION = '请按话题梳理这段时间群里聊了什么，整理主要观点、分歧、结论和待解决的问题，并引用对应原消息。';
  const UNKNOWN_COVERAGE = '尚未向微博核对，不能确认完整。';
  const stageLabels = { loading: '正在加载并核对消息', loaded: '消息核对完成', checking: '正在核对时间范围', preparing: '正在准备消息', batching: '正在分批梳理', summarizing: '正在整理总结', merging: '正在合并各批总结', saving: '正在保存总结', cancelling: '正在停止…', cancelled: '已停止', failed: '未能完成总结', incomplete: '消息尚未加载完整', complete: '时段总结已完成' };
  const pad = value => String(value).padStart(2, '0');
  function localMinute(date) { return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) + 'T' + pad(date.getHours()) + ':' + pad(date.getMinutes()); }
  function number(value) { return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? Math.floor(value) : null; }
  function mount(adapter) {
    const $ = id => document.getElementById(id), dialog = $('range-summary-dialog');
    let account = adapter.getAccountId(), group = adapter.getGroupId ? adapter.getGroupId() : null;
    let session = 0, previewSequence = 0, previewTimer = null, busy = false, cancelling = false, incomplete = null, progress = null, coverageState = {}, task = null;
    const isLocked = () => !!adapter.isLocked(task ? task.groupId : group);
    const range = () => ({ start: $('range-summary-start').value, end: $('range-summary-end').value });
    const layoutChanged = () => root.dispatchEvent(new CustomEvent('weiyue:range-summary-dialog-change', { detail: { open: dialog.open } }));
    const panel = document.createElement('section'); panel.id = 'range-background-progress'; panel.className = 'range-background-progress'; panel.hidden = true; panel.setAttribute('aria-label', '时段总结任务');
    panel.innerHTML = '<div class="range-background-heading"><span class="activity-dot" aria-hidden="true"></span><strong id="range-background-label"></strong><div class="range-background-actions"><button id="range-background-view" type="button" class="text-button">查看任务</button><button id="range-background-stop" type="button" class="text-button">停止</button><button id="range-background-dismiss" type="button" class="icon-button small" aria-label="隐藏已结束的时段任务">×</button></div></div><p id="range-background-source"></p><p id="range-background-detail" role="status" aria-live="polite"></p>';
    $('conversation').before(panel);
    function errorText(error) { return error ? error.message || String(error) : ''; }
    function showError(error) { $('range-summary-error').textContent = errorText(error); $('range-summary-error').hidden = !error; }
    function validRange() {
      const value = range(), expression = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/;
      if (!expression.test(value.start) || !expression.test(value.end)) throw new Error('请选择完整的开始、结束日期和时间。');
      const start = new Date(value.start), end = new Date(value.end);
      if (!Number.isFinite(start.getTime()) || !Number.isFinite(end.getTime()) || localMinute(start) !== value.start || localMinute(end) !== value.end) throw new Error('所选日期或时间无效，请重新选择。');
      if (start > end) throw new Error('结束时间不能早于开始时间。');
      return value;
    }
    function coverage(info) {
      coverageState = { ...(info || {}) };
      const count = number(info && info.count), complete = info && info.complete === true;
      $('range-summary-count').textContent = count === null ? '尚未统计消息' : '已加载 ' + count.toLocaleString('zh-CN') + ' 条消息';
      const badge = $('range-summary-completeness'); badge.textContent = complete ? '已核对完整' : incomplete ? '尚未完整' : '待核对';
      badge.classList.toggle('is-complete', complete); badge.classList.toggle('is-incomplete', !!incomplete && !complete);
      $('range-summary-coverage').textContent = info && (info.reason || info.status) || (complete ? '已核对这段时间的可访问消息。' : UNKNOWN_COVERAGE);
    }
    function progressDetail() {
      if (!progress) return '';
      const parts = [];
      if (progress.detail) parts.push(progress.detail);
      const pages = number(progress.pages), count = number(progress.count), batch = number(progress.batch), total = number(progress.totalBatches);
      if (pages !== null) parts.push('已核对 ' + pages + ' 页');
      if (count !== null) parts.push('范围内 ' + count.toLocaleString('zh-CN') + ' 条消息');
      if (batch !== null && total !== null && total > 0) parts.push('第 ' + batch + ' / ' + total + ' 批');
      return parts.join(' · ');
    }
    function renderProgress() {
      const container = $('range-summary-progress'); container.hidden = !progress;
      container.classList.toggle('is-idle', !busy); panel.hidden = !task || !progress;
      if (!progress) return;
      const label = progress.label || stageLabels[progress.stage] || '正在处理…', detail = progressDetail();
      $('range-summary-progress-label').textContent = label;
      $('range-summary-progress-detail').textContent = detail;
      $('range-summary-progress-detail').hidden = !detail;
      if (!task) return;
      panel.classList.toggle('is-idle', !busy); panel.classList.toggle('is-error', ['failed', 'incomplete'].includes(progress.stage));
      $('range-background-label').textContent = label;
      $('range-background-source').textContent = task.groupName + ' · ' + (task.label || task.range.start.replace('T', ' ') + ' 至 ' + task.range.end.replace('T', ' '));
      $('range-background-source').title = $('range-background-source').textContent;
      $('range-background-detail').textContent = detail || (busy ? '任务在后台继续，可阅读其他群聊。' : '');
      $('range-background-detail').hidden = !detail && !busy;
      $('range-background-stop').hidden = !busy; $('range-background-stop').disabled = cancelling;
      $('range-background-stop').textContent = cancelling ? '停止中' : '停止';
      $('range-background-dismiss').hidden = busy;
      $('range-background-view').textContent = progress.stage === 'complete' && task.discussionId ? '查看总结' : incomplete ? '处理未完整消息' : '查看任务';
    }
    function renderLocks() {
      const locked = isLocked(); $('open-range-summary').disabled = !busy && !!adapter.isLocked(group);
      $('open-range-summary').title = busy ? '查看正在后台运行的时段总结' : '指定日期和时间，加载并总结这段时间的全部群聊消息';
      const blocked = busy || locked;
      ['start', 'end', 'question', 'today', 'yesterday', 'submit', 'retry', 'partial'].forEach(id => { $('range-summary-' + id).disabled = blocked; });
      $('range-summary-close').disabled = false;
      $('range-summary-close').setAttribute('aria-label', busy ? '收起时段总结，后台继续运行' : '关闭时段总结');
      $('range-summary-cancel').hidden = !busy; $('range-summary-cancel').disabled = cancelling;
      $('range-summary-cancel').textContent = cancelling ? '正在停止…' : '停止任务';
      $('range-summary-minimize').hidden = !busy;
      $('range-summary-submit').hidden = busy || !!incomplete;
      $('range-summary-retry').hidden = busy || !incomplete;
      $('range-summary-partial').hidden = busy || !incomplete;
      $('range-summary-partial').disabled = blocked || !incomplete || !number(incomplete.count);
      $('range-summary-partial').textContent = incomplete ? '仅总结已加载的 ' + (number(incomplete.count) || 0).toLocaleString('zh-CN') + ' 条' : '仅总结已加载消息';
      $('range-summary-partial-note').hidden = busy || !incomplete;
      $('range-summary-send-note').textContent = busy ? '收起窗口或切换群聊，任务会继续；进度显示在右侧。停止任务才会取消，退出应用会中断。' : '自动加载消息，过多时分批汇总。发送这段时间的消息给已设置的 AI 服务。';
      dialog.setAttribute('aria-busy', String(busy)); renderProgress();
    }
    function clearSession() {
      ++session; ++previewSequence; clearTimeout(previewTimer); previewTimer = null;
      busy = false; cancelling = false; incomplete = null; progress = null; coverageState = {}; task = null;
    }
    function dismiss() { ++previewSequence; clearTimeout(previewTimer); previewTimer = null; if (dialog.open) dialog.close(); layoutChanged(); renderLocks(); }
    // Account teardown is separate from dismissing a task's configuration sheet.
    function close() { clearSession(); dismiss(); }
    function render() {
      const nextAccount = adapter.getAccountId(), nextGroup = adapter.getGroupId ? adapter.getGroupId() : null;
      if (nextAccount !== account) { close(); account = nextAccount; }
      if (nextGroup !== group) { if (!task && !busy) dismiss(); group = nextGroup; }
      renderLocks();
    }
    async function preview() {
      if (!dialog.open || busy) return;
      const sequence = ++previewSequence, current = session, expectedAccount = account;
      try {
        const value = validRange(); showError(null);
        const result = await adapter.preview(value, task ? task.groupId : group);
        if (sequence !== previewSequence || current !== session || expectedAccount !== adapter.getAccountId() || !dialog.open || busy) return;
        coverage(result || {});
      } catch (error) {
        if (sequence !== previewSequence || current !== session || expectedAccount !== adapter.getAccountId() || !dialog.open || busy) return;
        coverage({}); showError(error);
      }
    }
    function rangeChanged() {
      if (busy) return;
      incomplete = null; progress = null; showError(null); coverage({}); renderLocks();
      ++previewSequence; clearTimeout(previewTimer); previewTimer = setTimeout(preview, 100);
    }
    function setPreset(yesterday) {
      if (busy || isLocked()) return;
      const now = new Date(), start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - (yesterday ? 1 : 0));
      const end = yesterday ? new Date(start.getFullYear(), start.getMonth(), start.getDate(), 23, 59) : now;
      $('range-summary-start').value = localMinute(start); $('range-summary-end').value = localMinute(end); rangeChanged();
    }
    function viewTask() { if (!task || dialog.open) return; dialog.showModal(); renderLocks(); layoutChanged(); $('range-summary-close').focus({ preventScroll: true }); }
    function open() {
      if (busy) { viewTask(); return; }
      if (adapter.isLocked(group) || dialog.open) return;
      render(); clearSession(); showError(null);
      const now = new Date(), defaults = adapter.getDefaults ? adapter.getDefaults() || {} : {};
      $('range-summary-start').value = defaults.start || localMinute(new Date(now.getFullYear(), now.getMonth(), now.getDate()));
      $('range-summary-end').value = defaults.end || localMinute(now);
      $('range-summary-question').value = DEFAULT_QUESTION;
      $('range-summary-group').textContent = adapter.getGroupName() || '当前群聊';
      coverage({}); dialog.showModal(); renderLocks(); layoutChanged(); preview(); $('range-summary-start').focus({ preventScroll: true });
    }
    function beginTracking(info) {
      task = { accountId: account, groupId: info.groupId, groupName: info.groupName || '群聊', range: info.range, label: info.label, discussionId: info.discussionId };
      $('range-summary-group').textContent = task.groupName;
      if (info.range) { $('range-summary-start').value = info.range.start; $('range-summary-end').value = info.range.end; }
      if (info.question) $('range-summary-question').value = info.question;
      busy = true; cancelling = false; incomplete = null; showError(null); progress = { stage: 'preparing', count: info.count }; renderLocks();
    }
    function endTracking(result, error) {
      busy = false; cancelling = false;
      if (error) { progress = { stage: 'failed', detail: errorText(error), count: coverageState.count }; showError(error); }
      else if (result && result.cancelled) { incomplete = result.incomplete && number(result.count) > 0 ? result : null; if (incomplete) coverage(result); progress = { stage: 'cancelled', detail: result.reason || '已停止；已完成的批次与消息快照仍保留。', count: number(result.count) !== null ? result.count : coverageState.count }; }
      else if (result && result.incomplete) { incomplete = result; progress = { stage: 'incomplete', count: result.count, detail: result.reason }; coverage(result); }
      else { progress = { stage: 'complete', count: result && number(result.count) !== null ? result.count : coverageState.count, detail: result && result.complete === false ? '仅覆盖已加载的部分消息。' : '总结与来源已保存，可继续追问。' }; if (task && result && result.discussionId) task.discussionId = result.discussionId; }
      renderLocks();
    }
    async function start(allowPartial) {
      if (busy || isLocked() || !dialog.open || allowPartial && (!incomplete || !number(incomplete.count))) return;
      let value;
      try { value = validRange(); } catch (error) { showError(error); return; }
      const current = session, expectedAccount = account, taskGroupId = task ? task.groupId : group, taskGroupName = task ? task.groupName : adapter.getGroupName();
      const question = $('range-summary-question').value.trim() || DEFAULT_QUESTION;
      ++previewSequence; clearTimeout(previewTimer); previewTimer = null;
      beginTracking({ groupId: taskGroupId, groupName: taskGroupName, range: value, question });
      progress = { stage: allowPartial ? 'preparing' : 'loading' }; renderLocks(); dismiss();
      try {
        const result = await adapter.start(value, question, !!allowPartial, taskGroupId);
        if (current !== session || expectedAccount !== adapter.getAccountId()) return;
        endTracking(result);
      } catch (error) { if (current !== session || expectedAccount !== adapter.getAccountId()) return; endTracking(null, error); }
    }
    async function cancel() {
      if (!busy || cancelling) return;
      const current = session, expectedAccount = account;
      cancelling = true; progress = { ...progress, stage: 'cancelling', label: '', detail: '正在停止当前加载或 AI 请求。' }; renderLocks();
      try { await adapter.cancel(); }
      catch (error) { if (current !== session || expectedAccount !== adapter.getAccountId()) return; cancelling = false; showError(error); renderLocks(); }
    }
    function setProgress(info) {
      if (!busy || cancelling || !info) return;
      progress = { ...info, count: number(info.count) === null ? coverageState.count : info.count };
      if (number(info.count) !== null || typeof info.complete === 'boolean' || info.coverageReason) {
        const next = { ...coverageState };
        if (number(info.count) !== null) next.count = info.count;
        if (typeof info.complete === 'boolean') next.complete = info.complete;
        if (info.coverageReason) next.reason = info.coverageReason;
        coverage(next);
      }
      renderProgress();
    }
    $('open-range-summary').addEventListener('click', open);
    $('range-summary-close').addEventListener('click', dismiss);
    $('range-summary-minimize').addEventListener('click', dismiss);
    $('range-background-view').addEventListener('click', () => { if (progress && progress.stage === 'complete' && task && task.discussionId && adapter.showResult) adapter.showResult(task.discussionId); else viewTask(); });
    $('range-background-stop').addEventListener('click', cancel);
    $('range-background-dismiss').addEventListener('click', () => { if (!busy) close(); });
    $('range-summary-form').addEventListener('submit', event => { event.preventDefault(); start(false); });
    $('range-summary-retry').addEventListener('click', () => start(false));
    $('range-summary-partial').addEventListener('click', () => start(true));
    $('range-summary-cancel').addEventListener('click', cancel);
    $('range-summary-start').addEventListener('input', rangeChanged);
    $('range-summary-end').addEventListener('input', rangeChanged);
    $('range-summary-today').addEventListener('click', () => setPreset(false));
    $('range-summary-yesterday').addEventListener('click', () => setPreset(true));
    dialog.addEventListener('cancel', event => { event.preventDefault(); dismiss(); });
    dialog.addEventListener('click', event => { const r = dialog.getBoundingClientRect(); if (event.target === dialog && (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom)) dismiss(); });
    dialog.addEventListener('close', () => { layoutChanged(); renderLocks(); });
    render();
    return { render, close, setProgress, beginTracking, endTracking };
  }
  root.ReaderRangeSummaryUI = { mount };
})(typeof window !== 'undefined' ? window : globalThis);
