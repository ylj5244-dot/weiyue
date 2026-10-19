(function (root) {
  'use strict';
  const clone = value => JSON.parse(JSON.stringify(value));
  const categories = { writing: '写作风格', format: '展示格式', other: '其他要求' };
  let generated = 0;
  function makeId() { return 'pref-' + (root.crypto && root.crypto.randomUUID ? root.crypto.randomUUID() : Date.now().toString(36) + '-' + (++generated)); }
  function mount(adapter) {
    const $ = id => document.getElementById(id);
    const libraryDialog = $('preferences-dialog');
    let account = adapter.getAccountId(), draft = null, tab = 'entries', selectedId = null;
    let librarySession = 0, librarySaving = false, quickSignature = '';
    const isLocked = () => !!adapter.isLocked();
    const isLibraryLocked = () => !!(adapter.isLibraryLocked ? adapter.isLibraryLocked() : adapter.isLocked());
    const currentItems = () => draft ? draft[tab] : [];
    const currentItem = () => currentItems().find(item => item.id === selectedId);
    function layoutChanged() { root.dispatchEvent(new CustomEvent('weiyue:preferences-dialog-change', { detail: { open: libraryDialog.open } })); }
    function showError(id, error) {
      const node = $(id); node.textContent = error ? (error.message || String(error)) : ''; node.hidden = !error;
      if (error && node.closest('dialog')?.open) node.scrollIntoView({ block: 'nearest' });
    }
    function clearLibrary() { ++librarySession; librarySaving = false; draft = null; selectedId = null; }
    function closeLibrary() { clearLibrary(); if (libraryDialog.open) libraryDialog.close(); layoutChanged(); render(); }
    function close() { clearLibrary(); if (libraryDialog.open) libraryDialog.close(); quickSignature = ''; layoutChanged(); }
    function setDisabledWithin(formId, disabled, saving) {
      $(formId).querySelectorAll('input, textarea, select, button').forEach(node => { node.disabled = node.hasAttribute('data-close-preferences') ? saving : disabled; });
    }
    function renderLocks() {
      const locked = isLibraryLocked();
      $('open-preferences').disabled = locked || librarySaving;
      if (libraryDialog.open) {
        const blocked = locked || librarySaving;
        setDisabledWithin('preferences-form', blocked, librarySaving);
        const index = currentItems().findIndex(item => item.id === selectedId);
        $('preference-move-up').disabled = blocked || index <= 0;
        $('preference-move-down').disabled = blocked || index < 0 || index >= currentItems().length - 1;
        $('preferences-save').textContent = librarySaving ? '正在保存…' : '保存偏好库';
      }
    }
    function render() {
      const nextAccount = adapter.getAccountId();
      if (nextAccount !== account) { close(); account = nextAccount; }
      const library = adapter.getLibrary(), active = library.entries.filter(item => item.enabled).length;
      $('preferences-status').textContent = active ? active + ' 项生效' : library.entries.length ? '全部停用' : '未设置';
      $('preferences-status').classList.toggle('is-active', active > 0);
      const quick = library.quickPrompts.filter(item => item.enabled), locked = isLocked(), libraryLocked = isLibraryLocked();
      const signature = JSON.stringify([account, locked, libraryLocked, quick]);
      if (quickSignature !== signature) {
        quickSignature = signature;
        const fragment = document.createDocumentFragment();
        quick.forEach(item => {
          const button = document.createElement('button'); button.type = 'button'; button.className = 'quick-prompt-button';
          button.dataset.quickPromptId = item.id; button.textContent = item.title; button.title = item.prompt; button.disabled = locked;
          button.addEventListener('click', () => { if (button.disabled || isLocked()) return; adapter.fillPrompt(item.prompt); });
          fragment.appendChild(button);
        });
        if (!quick.length) {
          const button = document.createElement('button'); button.type = 'button'; button.className = 'quick-prompt-empty'; button.textContent = '＋ 自定义快捷提问'; button.disabled = libraryLocked;
          button.addEventListener('click', () => { if (!button.disabled && !isLibraryLocked()) openLibrary('quickPrompts'); }); fragment.appendChild(button);
        }
        $('quick-prompts').replaceChildren(fragment);
      }
      renderLocks();
    }
    function renderList() {
      if (!draft) return;
      const items = currentItems(), isEntry = tab === 'entries';
      $('preferences-list-count').textContent = items.length + (isEntry ? ' 项偏好' : ' 个提问');
      const fragment = document.createDocumentFragment();
      items.forEach(item => {
        const button = document.createElement('button'); button.type = 'button'; button.className = 'preference-list-item'; button.dataset.preferenceId = item.id;
        button.setAttribute('aria-pressed', String(item.id === selectedId));
        const title = document.createElement('strong'); title.textContent = item.title || (isEntry ? '未命名偏好' : '未命名提问');
        const meta = document.createElement('span'); meta.textContent = (isEntry ? categories[item.category] + ' · ' : '') + (item.enabled ? '已启用' : '已停用');
        button.append(title, meta);
        button.addEventListener('click', () => { if (isLibraryLocked() || librarySaving || button.disabled) return; selectedId = item.id; renderDraft(); });
        fragment.appendChild(button);
      });
      if (!items.length) { const empty = document.createElement('p'); empty.className = 'preferences-list-empty'; empty.textContent = isEntry ? '还没有保存偏好。' : '还没有快捷提问。'; fragment.appendChild(empty); }
      $('preferences-items').replaceChildren(fragment);
    }
    function renderDraft() {
      if (!draft) return;
      const isEntry = tab === 'entries', item = currentItem();
      ['entries', 'quick'].forEach(key => { const active = (key === 'entries') === isEntry; const button = $('preferences-tab-' + key); button.setAttribute('aria-selected', String(active)); button.tabIndex = active ? 0 : -1; });
      $('preferences-panel').setAttribute('aria-labelledby', 'preferences-tab-' + (isEntry ? 'entries' : 'quick'));
      $('preferences-guide').textContent = isEntry ? '启用的偏好会随下次提问带给 AI，已经提交的请求和回答不会改变。' : '点击快捷提问会填入输入框，你可以继续编辑，再决定是否发送。按这里的顺序显示，停用后可随时恢复。';
      $('preference-add').innerHTML = '<svg><use href="#i-plus"/></svg>' + (isEntry ? '添加偏好' : '添加提问');
      $('preference-editor').hidden = !item; $('preference-editor-empty').hidden = !!item;
      if (item) {
        $('preference-editor-title').textContent = isEntry ? '编辑偏好' : '编辑快捷提问';
        $('preference-title').value = item.title; $('preference-title').placeholder = isEntry ? '例如：写作语气' : '例如：梳理主要观点'; $('preference-title').maxLength = 120;
        $('preference-enabled').checked = item.enabled;
        $('preference-category-row').hidden = !isEntry; $('preference-category').value = item.category || 'other';
        $('preference-content-label').textContent = isEntry ? '具体要求' : '提问内容';
        $('preference-content').value = isEntry ? item.content : item.prompt; $('preference-content').maxLength = 12000;
        $('preference-content').placeholder = isEntry ? '例如：用完整段落表达观点，少用空泛的过渡语。' : '例如：请梳理这些资料的主要观点，并标注各自的出处。';
        $('preference-content-hint').textContent = isEntry ? '尽量写清楚你希望 AI 怎么做；停用可保留内容但暂不使用。' : '填写完整问题；点击快捷按钮只会填入，不会自动提交资料。';
      }
      renderList(); renderLocks();
    }
    function openLibrary(nextTab) {
      if (isLibraryLocked() || librarySaving || libraryDialog.open) return;
      ++librarySession; draft = clone(adapter.getLibrary()); tab = nextTab || 'entries'; selectedId = currentItems()[0]?.id || null;
      showError('preferences-error', null); renderDraft(); libraryDialog.showModal(); renderLocks(); layoutChanged();
      $('preferences-panel').scrollTop = 0;
      (currentItem() ? $('preference-title') : $('preference-add')).focus({ preventScroll: true });
    }
    function edit(field, value) {
      if (isLibraryLocked() || librarySaving) return;
      const item = currentItem(); if (!item) return; item[field] = value;
      showError('preferences-error', null); if (field !== 'content' && field !== 'prompt') { renderList(); renderLocks(); }
    }
    $('open-preferences').addEventListener('click', () => { if (!$('open-preferences').disabled) openLibrary(); });
    document.querySelectorAll('[data-close-preferences]').forEach(button => button.addEventListener('click', () => {
      if (button.disabled) return;
      if (!librarySaving) closeLibrary();
    }));
    libraryDialog.addEventListener('cancel', event => { if (librarySaving) event.preventDefault(); });
    libraryDialog.addEventListener('close', () => { if (!libraryDialog.open) { clearLibrary(); layoutChanged(); render(); } });
    ['entries', 'quick'].forEach(key => {
      const button = $('preferences-tab-' + key);
      const activate = () => { if (button.disabled || isLibraryLocked() || librarySaving || !draft) return; tab = key === 'entries' ? 'entries' : 'quickPrompts'; selectedId = currentItems()[0]?.id || null; showError('preferences-error', null); renderDraft(); $('preferences-panel').scrollTop = 0; };
      button.addEventListener('click', activate);
      button.addEventListener('keydown', event => { if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return; event.preventDefault(); const destination = event.key === 'Home' ? 'entries' : event.key === 'End' ? 'quick' : key === 'entries' ? 'quick' : 'entries'; $('preferences-tab-' + destination).click(); $('preferences-tab-' + destination).focus(); });
    });
    $('preference-title').addEventListener('input', event => edit('title', event.target.value));
    $('preference-category').addEventListener('change', event => edit('category', event.target.value));
    $('preference-enabled').addEventListener('change', event => edit('enabled', event.target.checked));
    $('preference-content').addEventListener('input', event => edit(tab === 'entries' ? 'content' : 'prompt', event.target.value));
    $('preference-add').addEventListener('click', () => {
      if (isLibraryLocked() || librarySaving || !draft || $('preference-add').disabled) return;
      const items = currentItems(), limit = tab === 'entries' ? 100 : 50;
      if (items.length >= limit) { showError('preferences-error', '最多保存 ' + limit + (tab === 'entries' ? ' 项偏好。' : ' 个快捷提问。')); return; }
      const item = tab === 'entries' ? { id: makeId(), title: '', category: 'writing', content: '', enabled: true } : { id: makeId(), title: '', prompt: '', enabled: true };
      items.push(item); selectedId = item.id; showError('preferences-error', null); renderDraft(); $('preference-title').focus();
    });
    $('preference-delete').addEventListener('click', () => {
      if (isLibraryLocked() || librarySaving || !draft || $('preference-delete').disabled) return;
      const items = currentItems(), index = items.findIndex(item => item.id === selectedId); if (index < 0) return;
      items.splice(index, 1); selectedId = items[Math.min(index, items.length - 1)]?.id || null; showError('preferences-error', null); renderDraft();
    });
    ['up', 'down'].forEach(direction => $('preference-move-' + direction).addEventListener('click', () => {
      if (isLibraryLocked() || librarySaving || !draft || $('preference-move-' + direction).disabled) return;
      const items = currentItems(), index = items.findIndex(item => item.id === selectedId), next = index + (direction === 'up' ? -1 : 1);
      if (index < 0 || next < 0 || next >= items.length) return;
      [items[index], items[next]] = [items[next], items[index]]; renderList(); renderLocks();
    }));
    $('preferences-form').addEventListener('submit', async event => {
      event.preventDefault(); if (isLibraryLocked() || librarySaving || !draft) return;
      const session = librarySession, saveAccount = adapter.getAccountId();
      try {
        const value = root.ReaderPreferences.validate(clone(draft));
        librarySaving = true; showError('preferences-error', null); renderLocks();
        await adapter.saveLibrary(value);
        if (session !== librarySession || saveAccount !== adapter.getAccountId()) return;
        closeLibrary();
      } catch (error) {
        if (session !== librarySession || saveAccount !== adapter.getAccountId()) return;
        librarySaving = false; showError('preferences-error', error); renderLocks();
      }
    });
    render();
    return { render, close };
  }
  root.ReaderPreferencesUI = { mount };
})(typeof window !== 'undefined' ? window : globalThis);
