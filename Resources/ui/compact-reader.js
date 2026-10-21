(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.ReaderCompact = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';

  function syncPresentation({ group, info, native, demo, standby, locked } = {}) {
    let short = '等待同步', detail = '等待同步当前群聊', tone = 'waiting';
    const permitted = !!(native && group && group.selected && !demo && !standby && !locked);
    if (standby) { short = '待机中'; detail = '所有已开启同步的群继续收取消息、累计未读提醒'; }
    else if (!group) { short = '未选群聊'; detail = '选择一个群聊开始同步'; }
    else if (!group.selected) { short = '未启用同步'; detail = '在「管理」中开启此群同步'; }
    else if (demo) { short = '演示内容'; detail = '演示内容 · 不连接微博'; }
    else if (info) {
      const statuses = {
        loading: [info.phase === 'history' ? '加载历史…' : info.phase === 'refresh' ? '补全附件…' : '同步中…', info.phase === 'history' ? '正在补充历史消息' : info.phase === 'refresh' ? '正在补全已有消息附件' : '正在同步新消息', 'loading'],
        idle: [info.updatedAt ? '已同步' : '同步已开启', '实时同步已开启', info.updatedAt ? 'success' : 'waiting'],
        paused: ['已暂停', '同步已暂停', 'paused'],
        backoff: ['等待重试', '稍后自动重试', 'error'],
        error: ['同步异常', '同步遇到问题', 'error']
      };
      [short, detail, tone] = statuses[info.state] || [short, detail, tone];
      detail = info.text || detail;
    }
    return {
      short, detail, tone,
      syncDisabled: !permitted || !!(info && info.state === 'loading'),
      historyDisabled: !permitted || !!(info && (info.state === 'loading' && info.phase === 'history' || info.hasMore === false)),
      syncAction: info && ['error', 'backoff', 'paused'].includes(info.state) ? '重试同步' : '立即同步',
      historyAction: info && info.hasMore === false ? '没有更早消息' : '加载更早 500 条'
    };
  }

  function activeFilters({ query = '', type = 'all', memberId = '', memberName = '', from = '', to = '', followed = false } = {}) {
    const labels = [], types = { link: '链接', image: '图片', document: '文件', video: '视频' };
    if (followed) labels.push('只看关注');
    if (query.trim()) labels.push('搜索：' + query.trim());
    if (types[type]) labels.push('类型：' + types[type]);
    if (memberId) labels.push('成员：' + (memberName ? memberName + '（' + memberId + '）' : memberId));
    if (from || to) labels.push('时间：' + (from && to ? from + ' 至 ' + to : from ? from + ' 起' : '截至 ' + to));
    return labels;
  }

  // Bounds are viewport coordinates. Menus live under body, outside the pane's
  // containment context, so a resized pane cannot clip them or offset them twice.
  function placePopover(anchor, size, bounds) {
    const gap = 6, inset = 8, leftEdge = bounds.left + inset, rightEdge = bounds.right - inset;
    const topEdge = bounds.top + inset, bottomEdge = bounds.bottom - inset;
    const width = Math.max(0, Math.min(size.width, rightEdge - leftEdge));
    const left = Math.max(leftEdge, Math.min(anchor.right - width, rightEdge - width));
    const below = Math.max(0, bottomEdge - anchor.bottom - gap), above = Math.max(0, anchor.top - gap - topEdge);
    const useAbove = size.height > below && above > below;
    const maxHeight = Math.max(0, Math.min(size.height, useAbove ? above : below));
    const top = useAbove ? Math.max(topEdge, anchor.top - gap - maxHeight) : Math.min(bottomEdge, Math.max(topEdge, anchor.bottom + gap));
    return { left, top, width, maxHeight };
  }

  function createPopoverController({ document: doc, window: win, entries, bounds, onChange = () => {} }) {
    const menus = new Map(entries.map(entry => [entry.key, entry])), listeners = [];
    let active = null;
    const listen = (target, type, listener) => { target.addEventListener(type, listener); listeners.push(() => target.removeEventListener(type, listener)); };
    const focusables = panel => Array.from(panel.querySelectorAll('button, input, select, textarea, a[href], [tabindex]:not([tabindex="-1"])')).filter(item => !item.disabled && !item.closest('[hidden]') && item.getClientRects().length);
    function reposition() {
      if (!active) return;
      const { trigger, panel, width = 350 } = active;
      const viewport = { left: 0, right: win.innerWidth, top: 0, bottom: win.innerHeight };
      const pane = bounds ? bounds() : viewport;
      const limits = { left: Math.max(viewport.left, pane.left), right: Math.min(viewport.right, pane.right), top: Math.max(viewport.top, pane.top), bottom: Math.min(viewport.bottom, pane.bottom) };
      panel.style.width = Math.min(width, Math.max(0, limits.right - limits.left - 16)) + 'px';
      panel.style.maxHeight = 'none';
      const placement = placePopover(trigger.getBoundingClientRect(), { width, height: panel.getBoundingClientRect().height }, limits);
      Object.assign(panel.style, { left: placement.left + 'px', top: placement.top + 'px', width: placement.width + 'px', maxHeight: placement.maxHeight + 'px' });
    }
    function close({ restoreFocus = true } = {}) {
      if (!active) return;
      const closing = active; active = null;
      closing.panel.hidden = true; closing.trigger.setAttribute('aria-expanded', 'false');
      if (restoreFocus && !closing.trigger.disabled && closing.trigger.isConnected) closing.trigger.focus({ preventScroll: true });
      onChange(null);
    }
    function open(key) {
      const entry = menus.get(key);
      if (!entry || entry.trigger.disabled) return;
      if (active === entry) { close(); return; }
      close({ restoreFocus: false }); active = entry;
      if (entry.beforeOpen) entry.beforeOpen();
      entry.panel.hidden = false; entry.trigger.setAttribute('aria-expanded', 'true'); reposition();
      entry.panel.scrollTop = 0;
      const preferred = entry.initialFocus && entry.initialFocus();
      const target = preferred && !preferred.disabled ? preferred : focusables(entry.panel)[0] || entry.panel;
      target.focus({ preventScroll: true }); onChange(key);
    }
    entries.forEach(entry => {
      entry.trigger.setAttribute('aria-expanded', 'false'); entry.trigger.setAttribute('aria-controls', entry.panel.id);
      listen(entry.trigger, 'click', () => open(entry.key));
      listen(entry.trigger, 'keydown', event => { if (event.key === 'ArrowDown') { event.preventDefault(); if (!active || active !== entry) open(entry.key); } });
    });
    listen(doc, 'click', event => {
      if (active && !active.panel.contains(event.target) && !active.trigger.contains(event.target)) close({ restoreFocus: active.panel.contains(doc.activeElement) });
    });
    listen(doc, 'keydown', event => {
      if (!active) return;
      if (event.key === 'Escape') { event.preventDefault(); close(); return; }
      if (event.key === 'Tab') {
        const items = focusables(active.panel);
        if (event.shiftKey && event.target === items[0] || !event.shiftKey && event.target === items[items.length - 1]) {
          // Returning to the trigger before the browser advances Tab keeps the
          // next focus destination in the toolbar, not in the hidden portal.
          close(); if (event.shiftKey) event.preventDefault();
        }
      }
    });
    listen(doc, 'focusin', event => { if (active && !active.panel.contains(event.target) && !active.trigger.contains(event.target)) close({ restoreFocus: false }); });
    listen(win, 'resize', reposition);
    return { open, close, reposition, isOpen: () => !!active, destroy() { close({ restoreFocus: false }); listeners.forEach(remove => remove()); } };
  }
  return { syncPresentation, activeFilters, placePopover, createPopoverController };
});
