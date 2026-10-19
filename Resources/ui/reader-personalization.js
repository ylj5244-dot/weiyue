(function (root, factory) {
  'use strict';
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.ReaderPersonalization = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';
  const limits = { members: 200, senderId: 200, name: 100 };
  const trimmed = value => typeof value === 'string' ? value.trim() : '';
  const invalidIdentity = value => !value || /^(?:unknown(?:[:\s]|$)|null$|undefined$|0$)/i.test(value) || value === '粉丝群';
  function isSystemNotice(message) {
    return !!message && (trimmed(message.senderName) === '粉丝群' || trimmed(message.senderId) === '粉丝群');
  }
  function member(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('重点关注成员必须包含成员 ID。');
    const senderId = trimmed(value.senderId), name = value.name === undefined ? '' : trimmed(value.name);
    if (typeof value.senderId !== 'string' || invalidIdentity(senderId) || senderId.length > limits.senderId || /[\u0000-\u001f\u007f]/.test(senderId)) throw new Error('请输入有效的成员 ID，最多 200 字。');
    if ((value.name !== undefined && typeof value.name !== 'string') || name.length > limits.name || /[\u0000-\u001f\u007f]/.test(name)) throw new Error('备注名最多 100 字，不能包含换行或控制字符。');
    return { senderId, name };
  }
  function validate(members) {
    if (!Array.isArray(members)) throw new Error('重点关注成员必须是列表。');
    if (members.length > limits.members) throw new Error('最多设置 200 位重点关注成员。');
    const seen = new Set(), result = [];
    for (const value of members) {
      const item = member(value);
      if (!seen.has(item.senderId)) { seen.add(item.senderId); result.push(item); }
    }
    return result;
  }
  function read(state) {
    const settings = state && state.settings;
    return settings && Object.prototype.hasOwnProperty.call(settings, 'followedMembers') ? validate(settings.followedMembers) : [];
  }
  function isFollowed(state, messageOrSenderId) {
    if (!state || !state.accountId) return false;
    const message = messageOrSenderId && typeof messageOrSenderId === 'object' ? messageOrSenderId : null;
    if (message && message.accountId !== state.accountId) return false;
    const senderId = trimmed(message ? message.senderId : messageOrSenderId);
    return !!senderId && read(state).some(item => item.senderId === senderId);
  }
  function toggle(members, value, force) {
    const result = validate(members), item = member(value), index = result.findIndex(entry => entry.senderId === item.senderId);
    const follow = typeof force === 'boolean' ? force : index < 0;
    if (!follow) { if (index >= 0) result.splice(index, 1); }
    else if (index >= 0) result[index] = item;
    else {
      if (result.length >= limits.members) throw new Error('最多设置 200 位重点关注成员。');
      result.push(item);
    }
    return result;
  }
  function seenMembers(state, groupId) {
    const seen = new Map();
    for (const message of state && Array.isArray(state.messages) ? state.messages : []) {
      if (!message || message.accountId !== state.accountId || isSystemNotice(message)) continue;
      const senderId = trimmed(message.senderId);
      if (invalidIdentity(senderId) || senderId.length > limits.senderId || /[\u0000-\u001f\u007f]/.test(senderId)) continue;
      const name = trimmed(message.senderName).replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, limits.name), previous = seen.get(senderId);
      seen.set(senderId, { senderId, name: name || (previous && previous.name) || '', inCurrentGroup: message.groupId === groupId || !!(previous && previous.inCurrentGroup) });
    }
    return Array.from(seen.values()).sort((a, b) => Number(b.inCurrentGroup) - Number(a.inCurrentGroup));
  }
  function mount(adapter) {
    const make = (tag, id, text) => {
      const node = document.createElement(tag);
      if (id) node.id = id;
      if (text !== undefined) node.textContent = text;
      return node;
    };
    const button = (id, text, className) => { const node = make('button', id, text); node.type = 'button'; node.className = className || 'secondary-button'; return node; };
    const dialog = make('dialog', 'reader-personalization-dialog'); dialog.className = 'reader-personalization-dialog';
    dialog.setAttribute('aria-labelledby', 'reader-personalization-title'); dialog.setAttribute('aria-describedby', 'reader-personalization-description');
    const header = make('header'); header.className = 'reader-follow-header';
    const heading = make('div'), title = make('h2', 'reader-personalization-title', '重点关注');
    const description = make('p', 'reader-personalization-description', '按成员 ID 识别，保存后在当前账号的所有群中生效。');
    heading.append(title, description);
    const dismiss = button('reader-follow-close', '×', 'reader-follow-dismiss'); dismiss.setAttribute('aria-label', '关闭重点关注设置');
    header.append(heading, dismiss);
    const body = make('div'); body.className = 'reader-follow-body';
    const followedSection = make('section'), followedTitle = make('h3', 'reader-followed-heading');
    const followedList = make('ul', 'reader-followed-list'), followedEmpty = make('p', 'reader-followed-empty', '还没有重点关注成员。可以从下方搜索，或手动输入 ID。');
    followedList.className = 'reader-follow-list'; followedList.setAttribute('aria-labelledby', 'reader-followed-heading'); followedEmpty.className = 'reader-follow-hint';
    followedSection.append(followedTitle, followedList, followedEmpty);
    const searchSection = make('section'), searchLabel = make('label', null, '搜索已见成员'); searchLabel.htmlFor = 'reader-follow-search';
    const search = make('input', 'reader-follow-search'); search.type = 'search'; search.placeholder = '搜索姓名或成员 ID'; search.autocomplete = 'off';
    const resultHint = make('p', 'reader-follow-result-hint'); resultHint.className = 'reader-follow-hint'; resultHint.setAttribute('aria-live', 'polite');
    const results = make('ul', 'reader-follow-results'); results.className = 'reader-follow-list reader-follow-results'; results.setAttribute('aria-label', '已见成员搜索结果');
    searchSection.append(searchLabel, search, resultHint, results);
    const manual = make('form', 'reader-follow-manual'); manual.className = 'reader-follow-manual';
    manual.append(make('h3', null, '手动添加'));
    const fields = make('div'); fields.className = 'reader-follow-fields';
    const idLabel = make('label', null, '成员 ID'), nameLabel = make('label', null, '备注名（可选）');
    idLabel.htmlFor = 'reader-follow-id'; nameLabel.htmlFor = 'reader-follow-name';
    const manualId = make('input', 'reader-follow-id'), manualName = make('input', 'reader-follow-name');
    manualId.type = manualName.type = 'text'; manualId.maxLength = limits.senderId; manualName.maxLength = limits.name;
    manualId.autocomplete = manualName.autocomplete = 'off'; manualId.placeholder = '输入完整成员 ID'; manualName.placeholder = '便于辨认的名称';
    idLabel.append(manualId); nameLabel.append(manualName);
    const add = button('reader-follow-add', '添加'); add.type = 'submit'; fields.append(idLabel, nameLabel, add); manual.append(fields);
    body.append(followedSection, searchSection, manual);
    const footer = make('footer'); footer.className = 'reader-follow-footer';
    const error = make('p', 'reader-follow-error'); error.className = 'reader-follow-error'; error.hidden = true; error.setAttribute('role', 'alert');
    const actions = make('div'); actions.className = 'reader-follow-actions';
    const status = make('span', 'reader-follow-status'), cancel = button('reader-follow-cancel', '取消'), save = button('reader-follow-save', '保存', 'primary-button');
    status.setAttribute('aria-live', 'polite'); actions.append(status, cancel, save); footer.append(error, actions);
    dialog.append(header, body, footer); document.body.append(dialog);
    let accountId = null, draft = null, baseline = '', busy = false, session = 0, known = [];
    let catalogMessages = null, catalogLength = -1, catalogGroup = null, catalogRevision = -1;
    const currentState = () => adapter.getState() || {};
    const showError = value => { error.textContent = value ? (value.message || String(value)) : ''; error.hidden = !value; };
    const dirty = () => draft !== null && JSON.stringify(draft) !== baseline;
    function renderLocks() {
      dialog.querySelectorAll('input, button').forEach(node => { node.disabled = busy; });
      save.disabled = busy || !dirty(); save.textContent = busy ? '正在保存…' : '保存';
      status.textContent = busy ? '正在保存更改' : dirty() ? '有未保存的更改' : '最多关注 200 位成员';
    }
    function close() {
      const wasOpen = dialog.open;
      ++session; busy = false; draft = null; known = []; catalogMessages = null;
      if (dialog.open) dialog.close();
      if (wasOpen && adapter.onDialogChange) adapter.onDialogChange(false);
    }
    function active() {
      if (!draft || currentState().accountId !== accountId) { if (draft) close(); return false; }
      return !busy;
    }
    function edit(value, follow) {
      if (!active()) return false;
      try { draft = toggle(draft, value, follow); showError(null); renderLists(); return true; }
      catch (failure) { showError(failure); return false; }
    }
    function row(item, followed, showGroup) {
      const node = make('li'); node.dataset.senderId = item.senderId;
      const text = make('div'); text.className = 'reader-follow-member';
      const name = make('strong', null, item.name || item.senderId), identity = make('span', null, 'ID：' + item.senderId + (showGroup && item.inCurrentGroup ? ' · 当前群' : ''));
      text.append(name, identity);
      const action = button(null, followed ? '取消关注' : '关注'); action.dataset.action = followed ? 'unfollow' : 'follow';
      action.setAttribute('aria-label', (followed ? '取消关注 ' : '关注 ') + (item.name || item.senderId) + '，ID ' + item.senderId);
      action.addEventListener('click', () => edit(item, !followed)); node.append(text, action); return node;
    }
    function renderLists() {
      if (!draft) return;
      followedTitle.textContent = '已关注 · ' + draft.length;
      followedList.replaceChildren(...draft.map(item => row(item, true, false))); followedEmpty.hidden = draft.length > 0;
      const query = trimmed(search.value).toLocaleLowerCase(), followed = new Set(draft.map(item => item.senderId));
      const matches = known.filter(item => !query || item.senderId.toLocaleLowerCase().includes(query) || item.name.toLocaleLowerCase().includes(query));
      results.replaceChildren(...matches.slice(0, 60).map(item => row(item, followed.has(item.senderId), true)));
      resultHint.textContent = matches.length ? matches.length > 60 ? '找到 ' + matches.length + ' 位，显示前 60 位；输入更完整的姓名或 ID 可缩小范围。' : '找到 ' + matches.length + ' 位成员，当前群成员排在前面。' : query ? '没有找到匹配成员，可在下方手动添加。' : '暂无已见成员，可在下方手动添加。';
      renderLocks();
    }
    function refreshCatalog(state) {
      const messages = state.messages || [], groupId = adapter.getGroupId ? adapter.getGroupId() : null;
      if (messages !== catalogMessages || messages.length !== catalogLength || groupId !== catalogGroup || state.revision !== catalogRevision) {
        known = seenMembers(state, groupId); catalogMessages = messages; catalogLength = messages.length; catalogGroup = groupId; catalogRevision = state.revision;
      }
    }
    function render() {
      if (!draft) return;
      const state = currentState();
      if (state.accountId !== accountId) { close(); return; }
      refreshCatalog(state); renderLists();
    }
    function open() {
      const state = currentState();
      if (!state.accountId) return false;
      if (dialog.open && state.accountId === accountId) { render(); search.focus(); return true; }
      if (dialog.open) close();
      ++session; accountId = state.accountId; draft = read(state); baseline = JSON.stringify(draft); busy = false;
      search.value = ''; manualId.value = ''; manualName.value = ''; showError(null);
      refreshCatalog(state); renderLists(); dialog.showModal();
      if (adapter.onDialogChange) adapter.onDialogChange(true);
      search.focus(); return true;
    }
    function addManual(event) {
      event.preventDefault();
      if (edit({ senderId: manualId.value, name: manualName.value }, true)) { manualId.value = ''; manualName.value = ''; manualId.focus(); }
    }
    async function persistDraft() {
      if (!active() || !dirty()) return;
      const savingSession = session, savingAccount = accountId, value = validate(draft);
      busy = true; showError(null); renderLocks();
      try { await adapter.save(value); }
      catch (failure) {
        if (savingSession !== session) return;
        if (currentState().accountId !== savingAccount) { close(); return; }
        busy = false; showError(failure); renderLocks(); return;
      }
      if (savingSession !== session) return;
      if (currentState().accountId !== savingAccount) { close(); return; }
      close(); if (adapter.onChange) adapter.onChange(value);
    }
    search.addEventListener('input', renderLists);
    manual.addEventListener('submit', addManual); add.addEventListener('click', addManual);
    save.addEventListener('click', persistDraft);
    dismiss.addEventListener('click', () => { if (!busy) close(); }); cancel.addEventListener('click', () => { if (!busy) close(); });
    dialog.addEventListener('cancel', event => { event.preventDefault(); if (!busy) close(); });
    dialog.addEventListener('close', () => { if (!dialog.open && draft) { close(); if (adapter.onDialogChange) adapter.onDialogChange(false); } });
    return { open, close, render, element: dialog };
  }
  return { limits, isSystemNotice, read, validate, isFollowed, toggle, seenMembers, mount };
});
