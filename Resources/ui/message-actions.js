(function (root, factory) {
  'use strict';
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.ReaderMessageActions = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';
  function hasEnglish(text) {
    if (typeof text !== 'string' || !text.trim()) return false;
    // Character detection, not language or translation-worthiness inference.
    // Ignore only explicit code formatting and complete addresses; preserve
    // English surrounding them, including mixed Chinese/English and acronyms.
    var prose = text
      .replace(/(\x60{3,}|~{3,})[\s\S]*?(?:\1|$)/g, ' ')
      .replace(/(\x60+)[^\r\n]*?\1/g, ' ')
      .replace(/\b(?:[a-z][a-z0-9+.-]*:\/\/|mailto:|www\.)[^\s<>"'\u3000，。！？；：]+/gi, ' ')
      // Start at a complete local-part boundary so a long identifier without
      // an address does not cause a quadratic scan at every letter.
      .replace(/(?<![a-z0-9.!#$%&'*+\/=?^_\x60{|}~-])(?:[a-z0-9.!#$%&'*+\/=?^_\x60{|}~-]+|"[^"\r\n]+")@[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}/gi, ' ');
    return /[a-z]{2}/i.test(prose) || /(?:^|[^\p{L}\p{N}_])[ia](?![\p{L}\p{N}_])/iu.test(prose);
  }
  function sameMessage(state, item, message) {
    return item.accountId === state.accountId && item.groupId === message.groupId && item.messageId === message.id;
  }
  function matchingRecords(state, kind, message) {
    if (kind === 'bookmark') return state.bookmarks.filter(function (item) { return sameMessage(state, item, message); });
    var key = message.groupId + ':' + message.id;
    return state.collections.filter(function (item) { return item.accountId === state.accountId && item.messageIds.length === 1 && item.messageIds[0] === key; });
  }
  function isSelected(state, kind, message) {
    if (!state || !message || message.accountId !== state.accountId) return false;
    if (kind === 'manual') {
      var anchor = (state.progress[message.groupId] || {}).manual;
      return !!anchor && anchor.accountId === state.accountId && anchor.messageId === message.id;
    }
    return matchingRecords(state, kind, message).some(function (item) { return !item.deletedAt; });
  }
  function collectionTitle(message) {
    var preview = (message.text || '').replace(/\s+/g, ' ').trim();
    if (!preview) preview = ((message.attachments || [])[0] || {}).name || '非文本消息';
    return ((message.senderName || '未命名成员') + ' · ' + preview).slice(0, 120);
  }
  function createToggles(options) {
    var model = options.model, operations = new Map(), locks = new Map(), generation = 0;
    var own = function (object, key) { return Object.prototype.hasOwnProperty.call(object, key); };
    function keyFor(kind, message) { return JSON.stringify([kind, message.accountId, message.groupId, message.id]); }
    function lockFor(kind, message) { return kind === 'manual' ? JSON.stringify([kind, message.accountId, message.groupId]) : keyFor(kind, message); }
    function current(operation) { return operation.generation === generation && options.getState() === operation.source; }
    function status(kind, message) {
      var source = options.getState(), operation = operations.get(keyFor(kind, message)), busy = locks.get(lockFor(kind, message));
      var pressed = isSelected(source, kind, message);
      if (operation && current(operation) && operation.error) pressed = operation.previousPressed;
      if (busy && current(busy)) pressed = kind === 'manual' ? busy.previousManualId === message.id : busy.previousPressed;
      return { pressed: pressed, saving: !!busy && current(busy), error: operation && current(operation) ? operation.error || '' : '' };
    }
    // Roll back only touched properties. In particular, an auto-reading update
    // received during a manual-point save must never be replaced by an old copy.
    function apply(operation) {
      var source = operation.source, message = operation.message, kind = operation.kind, target = operation.target;
      var undo = [], changed = false;
      operation.rollback = function () { var restored = false; undo.reverse().forEach(function (restore) { restored = restore() || restored; }); if (restored) source.revision++; };
      function property(object, key, change) {
        var had = own(object, key), previous = object[key];
        change();
        var appliedHad = own(object, key), applied = object[key];
        if (had === appliedHad && previous === applied) return;
        changed = true;
        undo.push(function () {
          if (own(object, key) !== appliedHad || object[key] !== applied) return false;
          if (had) object[key] = previous; else delete object[key];
          return true;
        });
      }
      if (kind === 'manual') {
        var hadGroup = own(source.progress, message.groupId), group = hadGroup ? source.progress[message.groupId] : null;
        if (!group) { group = {}; Object.defineProperty(source.progress, message.groupId, { value: group, enumerable: true, writable: true, configurable: true }); }
        if (!hadGroup) undo.push(function () { if (source.progress[message.groupId] === group && !Object.keys(group).length) { delete source.progress[message.groupId]; return true; } return false; });
        if (target) property(group, 'manual', function () { model.setProgress(source, { groupId: message.groupId, messageId: message.id, kind: 'manual' }); });
        else if (group.manual && group.manual.messageId === message.id) property(group, 'manual', function () { delete group.manual; source.revision++; });
        return changed;
      }
      var records = matchingRecords(source, kind, message), active = records.filter(function (item) { return !item.deletedAt; });
      if (!target) {
        active.forEach(function (item) { property(item, 'deletedAt', function () { if (kind === 'bookmark') model.removeBookmark(source, item.id); else model.removeCollections(source, [item.id]); }); });
        return changed;
      }
      if (active.length) return false;
      var deleted = records.filter(function (item) { return !!item.deletedAt; }).sort(function (a, b) { return Date.parse(b.deletedAt) - Date.parse(a.deletedAt) || Date.parse(b.createdAt) - Date.parse(a.createdAt); });
      if (deleted.length) {
        property(deleted[0], 'deletedAt', function () { if (kind === 'bookmark') model.restoreBookmark(source, deleted[0].id); else model.restoreCollections(source, [deleted[0].id]); });
        return changed;
      }
      var list = kind === 'bookmark' ? source.bookmarks : source.collections, created = operation.created;
      if (created) { list.push(created); source.revision++; }
      else {
        created = kind === 'bookmark' ? model.addBookmark(source, { groupId: message.groupId, messageId: message.id, note: '' }) : model.createCollection(source, { name: collectionTitle(message), messageIds: [model.messageKey(message)] });
        operation.created = created;
      }
      var createdSnapshot = JSON.stringify(created);
      undo.push(function () {
        var index = list.indexOf(created);
        // Another action may already have edited the new bookmark or started a
        // discussion from the new collection. Keep that work and retry this ID.
        if (index < 0 || JSON.stringify(created) !== createdSnapshot || kind === 'collection' && source.discussions.some(function (discussion) { return discussion.collectionId === created.id; })) return false;
        list.splice(index, 1); return true;
      });
      return true;
    }
    async function toggle(kind, message) {
      if (!['manual', 'bookmark', 'collection'].includes(kind)) throw new Error('未知消息操作');
      var source = options.getState();
      if (!source || !message || !source.accountId || message.accountId !== source.accountId) throw new Error('账号已切换，请重新选择当前账号的消息。');
      if (!source.messages.some(function (item) { return item.accountId === source.accountId && item.groupId === message.groupId && item.id === message.id; })) throw new Error('原消息尚未载入本机，无法切换标记。');
      var key = keyFor(kind, message), lock = lockFor(kind, message);
      if (locks.has(lock) && current(locks.get(lock))) return { busy: true };
      locks.delete(lock);
      var operation = operations.get(key);
      if (!operation || !current(operation)) {
        var pressed = isSelected(source, kind, message);
        operation = { source: source, generation: generation, kind: kind, message: message, target: !pressed, previousPressed: pressed, previousManualId: ((source.progress[message.groupId] || {}).manual || {}).messageId, created: null };
        operations.set(key, operation);
      }
      // A different manual destination supersedes a failed request in that group.
      if (kind === 'manual') operations.forEach(function (other, otherKey) { if (other !== operation && other.kind === kind && lockFor(kind, other.message) === lock) operations.delete(otherKey); });
      operation.error = ''; locks.set(lock, operation);
      var saved = false;
      try {
        apply(operation);
        if (options.onChange) options.onChange();
        await options.persist(source);
        if (!current(operation)) return { stale: true };
        saved = true;
        operations.delete(key); locks.delete(lock);
        if (options.onChange) options.onChange();
        if (options.onSaved) options.onSaved({ kind: kind, pressed: operation.target, message: message });
        return { saved: true, pressed: operation.target };
      } catch (error) {
        if (saved) throw error;
        if (!current(operation)) return { stale: true };
        if (operation.rollback) operation.rollback();
        operation.error = error && error.message ? error.message : String(error);
        locks.delete(lock);
        if (options.persistRollback) { try { Promise.resolve(options.persistRollback(source)).catch(function () {}); } catch (_) {} }
        if (options.onChange) options.onChange();
        if (options.onError) options.onError(error, { kind: kind, pressed: operation.previousPressed, target: operation.target });
        return { failed: true };
      }
    }
    return { toggle: toggle, status: status, reset: function () { generation++; operations.clear(); locks.clear(); } };
  }
  function copyText(message) {
    var parts = [], text = typeof message.text === 'string' ? message.text : '';
    if (text) parts.push(text);
    (Array.isArray(message.attachments) ? message.attachments : []).forEach(function (item) {
      var lines = []; if (typeof item.name === 'string' && item.name.trim()) lines.push(item.name);
      if (typeof item.url === 'string' && /^https?:\/\//i.test(item.url)) lines.push(item.url);
      if (lines.length) parts.push(lines.join('\n'));
    });
    return parts.join('\n\n');
  }
  return { copyText: copyText, hasEnglish: hasEnglish, createToggles: createToggles, isSelected: isSelected, collectionTitle: collectionTitle };
});
