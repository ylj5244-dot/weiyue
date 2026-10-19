/* Layout preferences contain dimensions only; chat records remain in the native store. */
(function (root, factory) {
  const policy = factory();
  if (typeof module === 'object' && module.exports) module.exports = policy;
  if (root) root.ReaderLayoutPolicy = policy;
  if (typeof document !== 'undefined') install(root, policy);

  function install(win, policy) {
    const app = document.getElementById('app'), workspace = document.querySelector('.workspace');
    if (!app || !workspace) return;
    const storageKey = 'weiyue.pane-layout.v1';
    let preferences = policy.readPreferences(null), current, activeDrag = null;
    try { preferences = policy.readPreferences(JSON.parse(win.localStorage.getItem(storageKey))); } catch (_) {}
    const $ = id => document.getElementById(id);
    const emit = (name, detail) => win.dispatchEvent(new CustomEvent('weiyue:' + name, { detail: detail || {} }));
    function persist() { try { win.localStorage.setItem(storageKey, JSON.stringify(preferences)); } catch (_) {} emit('layout-save', { ...preferences }); }
    function measure() { return Math.max(0, workspace.getBoundingClientRect().width); }
    function contentMinimums() {
      const style = win.getComputedStyle(app);
      const pixels = name => {
        const value = style.getPropertyValue(name).trim();
        return /^(?:\d+(?:\.\d+)?|\.\d+)px$/.test(value) ? Number.parseFloat(value) : undefined;
      };
      return { sidebarMin: pixels('--sidebar-min-width'), centerMin: pixels('--reader-min-width'), inspectorMin: pixels('--inspector-min-width') };
    }
    function apply(source) {
      current = policy.resolveLayout(measure(), preferences, contentMinimums());
      app.style.setProperty('--sidebar-width', current.sidebarWidth + 'px');
      app.style.setProperty('--inspector-width', current.inspectorWidth + 'px');
      app.classList.toggle('sidebar-collapsed', current.sidebarCollapsed);
      app.classList.toggle('inspector-collapsed', current.inspectorCollapsed);
      app.classList.toggle('compact-workspace', current.centerWidth < 550);
      for (const side of ['sidebar', 'inspector']) {
        const isLeft = side === 'sidebar', collapsed = current[side + 'Collapsed'];
        const button = $('toggle-' + side), divider = $(side + '-divider');
        const label = (collapsed ? '展开' : '收起') + (isLeft ? '群聊侧栏' : ' AI 侧栏');
        button.title = label; button.setAttribute('aria-label', label); button.setAttribute('aria-expanded', String(!collapsed));
        divider.hidden = collapsed;
        divider.setAttribute('aria-valuemin', String(current[side + 'Min']));
        divider.setAttribute('aria-valuemax', String(current[side + 'Max']));
        divider.setAttribute('aria-valuenow', String(Math.round(current[side + 'Width'])));
        divider.setAttribute('aria-valuetext', Math.round(current[side + 'Width']) + ' 像素');
      }
      emit('layout-change', { ...current, source: source || 'resize' });
    }
    function changePreferences(change, source) {
      emit('layout-start', { source });
      preferences = policy.readPreferences({ ...preferences, ...change });
      persist(); apply(source); emit('layout-end', { ...current, source });
    }
    function paneWidthChange(side, width) {
      const opposite = side === 'sidebar' ? 'inspector' : 'sidebar';
      const change = { [side + 'Width']: policy.clamp(width, current[side + 'Min'], current[side + 'Max']) };
      // Resize from the visible arrangement. Reusing an opposite pane's wider
      // saved preference would make that pane jump as the divider is moved.
      if (!current[opposite + 'Collapsed']) change[opposite + 'Width'] = current[opposite + 'Width'];
      return change;
    }
    function toggle(side) {
      if (!policy.limits[side]) return;
      const next = current[side + 'Collapsed'];
      const change = { [side + 'Collapsed']: !next };
      // An explicit reveal at a narrow width gets priority over the other pane.
      if (next && measure() < current.minimumThreePaneWidth) change[(side === 'sidebar' ? 'inspector' : 'sidebar') + 'Collapsed'] = true;
      changePreferences(change, 'toggle');
    }
    function reveal(side) { if (policy.limits[side] && current[side + 'Collapsed']) toggle(side); }
    function finishDrag(event) {
      if (!activeDrag || (event && event.pointerId !== undefined && event.pointerId !== activeDrag.pointerId)) return;
      const drag = activeDrag; activeDrag = null;
      app.classList.remove('is-resizing'); document.body.style.removeProperty('cursor');
      if (drag.divider.hasPointerCapture && drag.divider.hasPointerCapture(drag.pointerId)) drag.divider.releasePointerCapture(drag.pointerId);
      persist(); emit('layout-end', { ...current, source: 'drag' });
    }
    for (const side of ['sidebar', 'inspector']) {
      const divider = $(side + '-divider');
      $('toggle-' + side).addEventListener('click', () => toggle(side));
      divider.addEventListener('pointerdown', event => {
        if (event.button !== 0) return;
        event.preventDefault(); divider.focus();
        activeDrag = { side, divider, pointerId: event.pointerId, x: event.clientX, width: current[side + 'Width'] };
        divider.setPointerCapture(event.pointerId); app.classList.add('is-resizing'); document.body.style.cursor = 'col-resize';
        emit('layout-start', { ...current, source: 'drag' });
      });
      divider.addEventListener('pointermove', event => {
        if (!activeDrag || activeDrag.side !== side || activeDrag.pointerId !== event.pointerId) return;
        const delta = event.clientX - activeDrag.x;
        Object.assign(preferences, paneWidthChange(side, activeDrag.width + (side === 'sidebar' ? delta : -delta)));
        apply('drag');
      });
      divider.addEventListener('pointerup', finishDrag); divider.addEventListener('pointercancel', finishDrag); divider.addEventListener('lostpointercapture', finishDrag);
      divider.addEventListener('dblclick', () => changePreferences(paneWidthChange(side, policy.defaults[side + 'Width']), 'reset'));
      divider.addEventListener('keydown', event => {
        const amount = event.shiftKey ? 48 : 16;
        let width = current[side + 'Width'];
        if (event.key === 'Home') width = policy.defaults[side + 'Width'];
        else if (event.key === 'ArrowLeft') width += side === 'sidebar' ? -amount : amount;
        else if (event.key === 'ArrowRight') width += side === 'sidebar' ? amount : -amount;
        else return;
        event.preventDefault();
        changePreferences(paneWidthChange(side, width), 'keyboard');
      });
    }
    win.addEventListener('blur', () => finishDrag());
    function resizeWindow() { emit('layout-start', { source: 'window' }); apply('window'); emit('layout-end', { ...current, source: 'window' }); }
    if (typeof ResizeObserver !== 'undefined') new ResizeObserver(resizeWindow).observe(workspace);
    else win.addEventListener('resize', resizeWindow);
    for (const id of ['show-sidebar-bookmarks', 'all-sidebar-bookmarks']) $(id).addEventListener('click', () => emit('show-bookmarks', { groupId: $(id).dataset.groupId || '' }));
    $('open-storage-folder').addEventListener('click', () => emit('open-storage'));

    function setData(data) {
      const bookmarks = Array.isArray(data && data.bookmarks) ? data.bookmarks.filter(item => !item.deletedAt && item.groupId === data.activeGroupId) : [];
      const groups = Array.isArray(data && data.groups) ? data.groups : [];
      for (const id of ['show-sidebar-bookmarks', 'all-sidebar-bookmarks']) { $(id).dataset.groupId = data.activeGroupId || ''; $(id).disabled = !data.activeGroupId; }
      $('recent-bookmarks-empty').textContent = data.activeGroupId ? '本群还没有书签' : '选择群聊后显示本群书签';
      const recent = bookmarks.slice().sort((a, b) => policy.time(b.createdAt) - policy.time(a.createdAt)).slice(0, 3);
      $('recent-bookmarks-count').textContent = '· ' + bookmarks.length;
      $('recent-bookmarks-empty').hidden = !!recent.length;
      const rows = recent.map(bookmark => {
        const button = document.createElement('button'); button.type = 'button'; button.className = 'recent-bookmark';
        const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg'), use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
        use.setAttribute('href', '#i-bookmark'); svg.append(use); svg.setAttribute('aria-hidden', 'true');
        const content = document.createElement('span'); content.className = 'recent-bookmark-content';
        const quote = document.createElement('span'); quote.className = 'recent-bookmark-quote';
        quote.textContent = bookmark.note || bookmark.snapshot && bookmark.snapshot.text || '非文本消息';
        const date = document.createElement('time'); date.dateTime = bookmark.createdAt; date.textContent = policy.formatDate(bookmark.createdAt);
        const group = groups.find(item => item.id === bookmark.groupId);
        const source = group ? group.name || group.title || '群聊' : '群聊';
        button.title = source + '\n标记于 ' + date.textContent + '\n' + quote.textContent;
        content.append(quote, date); button.append(svg, content);
        button.addEventListener('click', () => emit('bookmark-jump', { groupId: bookmark.groupId, messageId: bookmark.messageId }));
        const row = document.createElement('div'); row.className = 'recent-bookmark-row'; row.dataset.bookmarkId = bookmark.id;
        const edit = document.createElement('button'); edit.type = 'button'; edit.className = 'text-button recent-bookmark-edit'; edit.textContent = '备注'; edit.title = '编辑书签备注'; edit.setAttribute('aria-label', '编辑书签备注：' + quote.textContent);
        edit.addEventListener('click', () => emit('bookmark-note', { bookmarkId: bookmark.id })); row.append(button, edit); return row;
      });
      $('recent-bookmarks-list').replaceChildren(...rows);
    }
    win.ReaderLayout = {
      setData, toggle, reveal,
      setCollapsed: (side, collapsed) => { if (policy.limits[side]) { if (!collapsed) reveal(side); else changePreferences({ [side + 'Collapsed']: true }, 'toggle'); } },
      restore: value => { preferences = policy.readPreferences(value); apply('restore'); },
      reset: () => changePreferences(policy.defaults, 'reset'),
      getState: () => ({ ...current, preferences: { ...preferences } }),
      refresh: () => apply('refresh')
    };
    apply('initial'); setData({});
  }
})(typeof window === 'undefined' ? null : window, function () {
  const defaults = Object.freeze({ sidebarWidth: 220, inspectorWidth: 330, sidebarCollapsed: false, inspectorCollapsed: false });
  const limits = Object.freeze({ sidebar: Object.freeze({ min: 188, max: 380 }), inspector: Object.freeze({ min: 280, max: 620 }) });
  const centerMin = 430, divider = 6, minimumThreePaneWidth = limits.sidebar.min + limits.inspector.min + centerMin + divider * 2;
  const clamp = (value, min, max) => Math.min(Math.max(Number.isFinite(value) ? value : min, min), Math.max(min, max));
  function readPreferences(value) {
    const source = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
    return {
      sidebarWidth: typeof source.sidebarWidth === 'number' ? clamp(source.sidebarWidth, limits.sidebar.min, limits.sidebar.max) : defaults.sidebarWidth,
      inspectorWidth: typeof source.inspectorWidth === 'number' ? clamp(source.inspectorWidth, limits.inspector.min, limits.inspector.max) : defaults.inspectorWidth,
      sidebarCollapsed: source.sidebarCollapsed === true,
      inspectorCollapsed: source.inspectorCollapsed === true
    };
  }
  function resolveLayout(width, value, contentMinimums) {
    const prefs = readPreferences(value); width = Math.max(0, Number.isFinite(width) ? width : 0);
    const minimums = contentMinimums && typeof contentMinimums === 'object' && !Array.isArray(contentMinimums) ? contentMinimums : {};
    // CSS declares the smallest tested widths for its controls. Dimensions stay
    // separate from saved preferences, so temporary constraints never erase a
    // user's wider layout or change the native persistence schema.
    const sidebarMin = clamp(minimums.sidebarMin, limits.sidebar.min, limits.sidebar.max);
    const inspectorMin = clamp(minimums.inspectorMin, limits.inspector.min, limits.inspector.max);
    const readingMin = Math.max(centerMin, Number.isFinite(minimums.centerMin) ? minimums.centerMin : centerMin);
    const threePaneMin = sidebarMin + inspectorMin + readingMin + divider * 2;
    let sidebarCollapsed = prefs.sidebarCollapsed, inspectorCollapsed = prefs.inspectorCollapsed;
    if (!sidebarCollapsed && !inspectorCollapsed && width < threePaneMin) sidebarCollapsed = true;
    if (!inspectorCollapsed && width < readingMin + inspectorMin + divider) inspectorCollapsed = true;
    if (!sidebarCollapsed && width < readingMin + sidebarMin + divider) sidebarCollapsed = true;
    const separators = (sidebarCollapsed ? 0 : divider) + (inspectorCollapsed ? 0 : divider);
    const available = Math.max(0, width - readingMin - separators);
    let sidebarWidth = sidebarCollapsed ? 0 : Math.max(sidebarMin, prefs.sidebarWidth);
    let inspectorWidth = inspectorCollapsed ? 0 : Math.max(inspectorMin, prefs.inspectorWidth);
    let excess = Math.max(0, sidebarWidth + inspectorWidth - available);
    const sideReduction = sidebarCollapsed ? 0 : Math.min(excess, sidebarWidth - sidebarMin);
    sidebarWidth -= sideReduction; excess -= sideReduction;
    if (!inspectorCollapsed) inspectorWidth -= Math.min(excess, inspectorWidth - inspectorMin);
    return {
      sidebarWidth, inspectorWidth, sidebarCollapsed, inspectorCollapsed,
      sidebarMin, inspectorMin, centerMin: readingMin, minimumThreePaneWidth: threePaneMin,
      centerWidth: Math.max(0, width - separators - sidebarWidth - inspectorWidth),
      sidebarMax: Math.max(sidebarMin, Math.min(limits.sidebar.max, available - inspectorWidth)),
      inspectorMax: Math.max(inspectorMin, Math.min(limits.inspector.max, available - sidebarWidth))
    };
  }
  function time(value) { const parsed = Date.parse(value); return Number.isFinite(parsed) ? parsed : 0; }
  function formatDate(value) {
    if (!time(value)) return '时间未知';
    const d = new Date(value), pad = n => String(n).padStart(2, '0');
    return d.getFullYear() + '.' + pad(d.getMonth() + 1) + '.' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
  }
  return { defaults, limits, centerMin, minimumThreePaneWidth, readPreferences, resolveLayout, clamp, time, formatDate };
});
