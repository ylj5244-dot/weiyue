'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../Resources/ui/model.js');
const A = require('../Resources/ui/message-actions.js');
const NOW = '2026-10-19T00:00:00.000Z';
function fixture(account = 'a') {
  const state = M.createState(account);
  M.upsertGroups(state, [{ id: 'g', name: 'Group', selected: true }, { id: 'h', name: 'Other', selected: true }]);
  for (const groupId of ['g', 'h']) M.ingestMessages(state, groupId, ['1', '2'].map(id => ({ id, groupId, senderId: 'u', senderName: 'Alice', text: 'Original ' + id, sentAt: NOW, attachments: [] })));
  return state;
}
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
function harness() {
  let state = fixture(); const saves = [], events = [], rollbacks = [];
  const controller = A.createToggles({ model: M, getState: () => state, persist: source => { const task = deferred(); saves.push({ ...task, source, snapshot: JSON.parse(JSON.stringify(source)) }); return task.promise; }, persistRollback: source => { rollbacks.push(source); }, onChange: () => events.push('change'), onSaved: value => events.push(value), onError: error => events.push(error.message) });
  return { controller, saves, events, rollbacks, get state() { return state; }, message: (id = '1', group = 'g') => state.messages.find(m => m.id === id && m.groupId === group), switchAccount: () => { controller.reset(); state = fixture('b'); events.length = 0; } };
}
async function commit(h, kind, message = h.message()) { const promise = h.controller.toggle(kind, message); h.saves.at(-1).resolve({}); await promise; }
test('manual toggles only its slot, moves to another message, and preserves auto/return/session anchors', async () => {
  const h = harness(); for (const kind of ['auto', 'returnPoint', 'sessionStart']) M.setProgress(h.state, { groupId: 'g', messageId: '2', kind, offset: 7, now: NOW });
  const before = JSON.stringify(h.state.progress.g); await commit(h, 'manual'); assert.equal(h.state.progress.g.manual.messageId, '1');
  await commit(h, 'manual', h.message('2')); assert.equal(h.state.progress.g.manual.messageId, '2'); await commit(h, 'manual', h.message('2'));
  assert.equal(JSON.stringify(h.state.progress.g), before); assert.equal(h.controller.status('manual', h.message('2')).pressed, false);
});
test('bookmark toggle soft-deletes old duplicates and restores the latest one with all metadata intact', async () => {
  const h = harness(), first = M.addBookmark(h.state, { groupId: 'g', messageId: '1', note: 'first note', now: NOW }), last = M.addBookmark(h.state, { groupId: 'g', messageId: '1', note: 'latest note', now: '2026-10-19T00:01:00.000Z' });
  const other = M.addBookmark(h.state, { groupId: 'h', messageId: '1', note: 'other group', now: NOW }), saved = JSON.stringify(last);
  assert.equal(h.controller.status('bookmark', h.message()).pressed, true); await commit(h, 'bookmark'); assert.ok(first.deletedAt && last.deletedAt); assert.equal(other.deletedAt, null);
  await commit(h, 'bookmark'); assert.equal(h.state.bookmarks.length, 3); assert.equal(JSON.stringify(last), saved); assert.ok(first.deletedAt); assert.equal(other.deletedAt, null);
});
test('single-message collections toggle without changing multi-message collections, sources or discussions', async () => {
  const h = harness(), single = M.createCollection(h.state, { name: 'Existing single', messageIds: ['g:1'], now: NOW }), multi = M.createCollection(h.state, { name: 'Multi keep', messageIds: ['g:1', 'g:2'], now: NOW }), other = M.createCollection(h.state, { name: 'Other keep', messageIds: ['h:1'], now: NOW });
  h.state.discussions = [{ id: 'd', accountId: 'a', collectionId: single.id, title: 'Keep', createdAt: NOW, updatedAt: NOW, messages: [{ role: 'user', content: 'Keep conversation', createdAt: NOW }] }]; single.discussionId = 'd';
  const original = JSON.stringify({ multi, other, messages: h.state.messages, discussions: h.state.discussions }), singleBefore = JSON.stringify(single);
  await commit(h, 'collection'); assert.ok(single.deletedAt); await commit(h, 'collection'); assert.equal(single.deletedAt, null); assert.equal(single.name, 'Existing single'); assert.equal(single.discussionId, 'd');
  assert.equal(JSON.stringify({ multi, other, messages: h.state.messages, discussions: h.state.discussions }), original); const clean = { ...single }; delete clean.deletedAt; assert.equal(JSON.stringify(clean), singleBefore);
});
test('new single collection is direct, uses an automatic title, and reuses its identity after cancel/reopen', async () => {
  const h = harness(); await commit(h, 'collection'); const collection = h.state.collections[0]; assert.deepEqual(collection.messageIds, ['g:1']); assert.equal(collection.name, 'Alice · Original 1');
  const id = collection.id; await commit(h, 'collection'); await commit(h, 'collection'); assert.equal(h.state.collections.length, 1); assert.equal(h.state.collections[0].id, id);
});
for (const kind of ['bookmark', 'collection']) test(kind + ' failed creation rolls back and retries the same target/identity without duplicates', async () => {
  const h = harness(), field = kind === 'bookmark' ? 'bookmarks' : 'collections'; let promise = h.controller.toggle(kind, h.message()); const id = h.state[field][0].id;
  assert.equal(h.controller.status(kind, h.message()).pressed, true, 'pending addition immediately shows its target'); assert.equal(h.controller.status(kind, h.message()).saving, true);
  await h.controller.toggle(kind, h.message()); assert.equal(h.saves.length, 1); h.saves[0].reject(new Error('disk failed')); await promise;
  assert.equal(h.state[field].length, 0); assert.equal(h.controller.status(kind, h.message()).pressed, false); assert.ok(h.controller.status(kind, h.message()).error); assert.equal(h.rollbacks.length, 1);
  promise = h.controller.toggle(kind, h.message()); assert.equal(h.state[field][0].id, id); h.saves.at(-1).resolve({}); await promise; assert.equal(h.state[field].length, 1); assert.equal(h.controller.status(kind, h.message()).pressed, true);
});
for (const kind of ['bookmark', 'collection']) test(kind + ' failed cancellation retains prior metadata and retries cancellation', async () => {
  const h = harness(); await commit(h, kind); const field = kind === 'bookmark' ? 'bookmarks' : 'collections', record = h.state[field][0]; if (kind === 'bookmark') record.note = 'preserve remark'; const before = JSON.stringify(record);
  const promise = h.controller.toggle(kind, h.message()); assert.equal(h.controller.status(kind, h.message()).pressed, false); assert.equal(h.controller.status(kind, h.message()).saving, true); h.saves.at(-1).reject(new Error('disk failed')); await promise;
  assert.equal(JSON.stringify(record), before); await commit(h, kind); assert.ok(record.deletedAt); assert.equal(h.state[field].length, 1); if (kind === 'bookmark') assert.equal(record.note, 'preserve remark');
});
test('failed manual change restores the previous manual anchor without rolling back a newer auto position', async () => {
  const h = harness(); M.setProgress(h.state, { groupId: 'g', messageId: '2', kind: 'manual', offset: 9, now: NOW }); const oldManual = JSON.stringify(h.state.progress.g.manual);
  const promise = h.controller.toggle('manual', h.message()); await h.controller.toggle('manual', h.message('2')); assert.equal(h.saves.length, 1, 'one manual operation per group');
  M.setProgress(h.state, { groupId: 'g', messageId: '1', kind: 'auto', offset: 33, now: NOW }); h.saves[0].reject(new Error('disk failed')); await promise;
  assert.equal(JSON.stringify(h.state.progress.g.manual), oldManual); assert.equal(h.state.progress.g.auto.offset, 33); await commit(h, 'manual'); assert.equal(h.state.progress.g.manual.messageId, '1');
});
test('manual destination changes immediately during save and returns to the prior destination on failure', async () => {
  const h = harness(); M.setProgress(h.state, { groupId: 'g', messageId: '2', kind: 'manual', offset: 9, now: NOW });
  const promise = h.controller.toggle('manual', h.message());
  assert.deepEqual(h.controller.status('manual', h.message()), { pressed: true, saving: true, error: '' });
  assert.deepEqual(h.controller.status('manual', h.message('2')), { pressed: false, saving: true, error: '' });
  assert.deepEqual(h.events, ['change'], 'save completion is never announced optimistically');
  h.saves[0].reject(new Error('disk failed')); await promise;
  assert.equal(h.controller.status('manual', h.message()).pressed, false);
  assert.equal(h.controller.status('manual', h.message('2')).pressed, true);
  const remove = h.controller.toggle('manual', h.message('2'));
  assert.deepEqual(h.controller.status('manual', h.message('2')), { pressed: false, saving: true, error: '' });
  h.saves.at(-1).resolve({}); await remove;
  assert.equal(h.controller.status('manual', h.message('2')).pressed, false);
});
test('6000 loaded messages show bookmark feedback before a slow disk save resolves and retain later arrivals on failure', async () => {
  const h = harness();
  h.state.messages.push(...Array.from({ length: 5996 }, (_, index) => ({ ...h.message(), id: 'bulk-' + index })));
  const before = h.state.messages.length, promise = h.controller.toggle('bookmark', h.message());
  assert.equal(before, 6000);
  assert.deepEqual(h.controller.status('bookmark', h.message()), { pressed: true, saving: true, error: '' });
  assert.deepEqual(h.events, ['change']);
  M.ingestMessages(h.state, 'g', [{ ...h.message(), id: 'later-arrival' }]);
  h.saves[0].reject(new Error('slow save failed')); await promise;
  assert.equal(h.controller.status('bookmark', h.message()).pressed, false);
  assert.equal(h.state.messages.length, before + 1);
  assert.ok(h.state.messages.some(message => message.id === 'later-arrival'));
});
test('manual save rollback handles legal group IDs that match inherited object properties', async () => {
  for (const groupId of ['__proto__', 'constructor']) {
    const h = harness(); M.upsertGroups(h.state, [{ id: groupId, name: 'Special ID', selected: true }]); M.ingestMessages(h.state, groupId, [{ ...h.message(), groupId }]);
    const message = h.message('1', groupId), promise = h.controller.toggle('manual', message); assert.equal(h.state.progress[groupId].manual.messageId, '1'); h.saves[0].reject(new Error('disk failure')); await promise;
    assert.equal(Object.hasOwn(h.state.progress, groupId), false); assert.equal(h.controller.status('manual', message).pressed, false);
  }
});
test('failed restore keeps the deleted record and retries restore rather than creating another', async () => {
  const h = harness(), b = M.addBookmark(h.state, { groupId: 'g', messageId: '1', note: 'saved', now: NOW }); M.removeBookmark(h.state, b.id, { now: NOW });
  const before = JSON.stringify(b), promise = h.controller.toggle('bookmark', h.message()); h.saves[0].reject(new Error('disk failed')); await promise; assert.equal(JSON.stringify(b), before);
  await commit(h, 'bookmark'); assert.equal(h.state.bookmarks.length, 1); assert.equal(b.deletedAt, null); assert.equal(b.note, 'saved');
});
for (const failure of [false, true]) test('account switch ignores late ' + (failure ? 'failure' : 'success') + ' for all three toggles', async () => {
  for (const kind of ['manual', 'bookmark', 'collection']) { const h = harness(), old = h.state, promise = h.controller.toggle(kind, h.message()); h.switchAccount(); const current = JSON.stringify(h.state); failure ? h.saves[0].reject(new Error('old failure')) : h.saves[0].resolve({}); await promise; assert.equal(JSON.stringify(h.state), current); assert.deepEqual(h.events, []); assert.equal(h.rollbacks.length, 0); assert.notEqual(h.state, old); }
});
test('a stale message from another account never targets matching IDs in the current account', async () => {
  const h = harness(), stale = h.message(); h.switchAccount(); await assert.rejects(h.controller.toggle('bookmark', stale), /账号|account/); assert.equal(h.saves.length, 0); assert.equal(h.state.bookmarks.length, 0);
});
test('failed new bookmark preserves a remark edited while its first save was pending', async () => {
  const h = harness(), promise = h.controller.toggle('bookmark', h.message()), b = h.state.bookmarks[0]; b.note = 'newer remark';
  h.saves[0].reject(new Error('disk failed')); await promise; assert.equal(h.state.bookmarks[0], b); assert.equal(b.note, 'newer remark'); assert.equal(h.controller.status('bookmark', h.message()).pressed, false);
  const retry = h.controller.toggle('bookmark', h.message()); assert.equal(h.controller.status('bookmark', h.message()).pressed, true); h.saves.at(-1).resolve({}); await retry;
  assert.equal(h.state.bookmarks.length, 1); assert.equal(h.state.bookmarks[0], b); assert.equal(h.controller.status('bookmark', h.message()).pressed, true);
});
test('failed new collection preserves a later rename and a new discussion reference', async () => {
  for (const rename of [false, true]) {
    const h = harness(), promise = h.controller.toggle('collection', h.message()), c = h.state.collections[0]; if (rename) c.name = 'newer name';
    h.state.discussions.push({ id: 'new-discussion', collectionId: c.id, content: 'do not orphan' });
    h.saves[0].reject(new Error('disk failed')); await promise; assert.equal(h.state.collections[0], c); assert.equal(h.controller.status('collection', h.message()).pressed, false);
    const retry = h.controller.toggle('collection', h.message()); assert.equal(h.controller.status('collection', h.message()).pressed, true); h.saves.at(-1).resolve({}); await retry;
    assert.equal(h.state.collections.length, 1); assert.equal(h.state.collections[0], c); assert.equal(h.state.discussions[0].collectionId, c.id); if (rename) assert.equal(c.name, 'newer name'); assert.equal(h.controller.status('collection', h.message()).pressed, true);
  }
});

const fs = require('node:fs'), vm = require('node:vm'), appSource = fs.readFileSync(require.resolve('../Resources/ui/app.js'), 'utf8');
function actualFunction(name) {
  const match = new RegExp('^  (?:async )?function ' + name + '\\(', 'm').exec(appSource); assert.ok(match, name);
  const rest = appSource.slice(match.index + 3), next = /\n  (?:async )?function /.exec(rest); assert.ok(next, name + ' boundary'); return appSource.slice(match.index, match.index + 3 + next.index);
}
function node(tag, className = '', textContent = '') {
  const classes = new Set(className.split(' ').filter(Boolean));
  const item = { tag, className, textContent, children: [], dataset: {}, attributes: {}, listeners: {}, append(...children) { this.children.push(...children); }, prepend(...children) { this.children.unshift(...children); }, setAttribute(name, value) { this.attributes[name] = value; }, addEventListener(name, callback) { this.listeners[name] = callback; }, classList: { toggle(name, yes) { yes ? classes.add(name) : classes.delete(name); }, add(name) { classes.add(name); }, contains(name) { return classes.has(name); } } };
  Object.defineProperty(item, 'className', { get() { return Array.from(classes).join(' '); }, set(value) { classes.clear(); value.split(' ').filter(Boolean).forEach(name => classes.add(name)); } });
  item.querySelector = selector => { const matches = child => selector[0] === '.' ? child.classList.contains(selector.slice(1)) : child.tag === selector; for (const child of item.children) { if (matches(child)) return child; const nested = child.querySelector(selector); if (nested) return nested; } return null; };
  return item;
}
test('actual app toggle renderer keeps labels, pressed class, ARIA, retry hint and save lock consistent', () => {
  let status = { pressed: false, saving: false, error: '' }; const card = node('article'), control = node('button', 'message-bookmark-action'); control.append(node('span')); card.append(control);
  const box = { messageToggles: { status: () => status }, ready: true, loadFailed: false, quitting: false, cleanupBusy: false, collectionsBusy: false }; vm.createContext(box); vm.runInContext(actualFunction('renderMessageToggle'), box);
  box.renderMessageToggle(card, '.message-bookmark-action', 'bookmark', {}); assert.equal(control.querySelector('span').textContent, '加入书签'); assert.equal(control.attributes['aria-pressed'], 'false');
  status = { pressed: true, saving: false, error: '' }; box.renderMessageToggle(card, '.message-bookmark-action', 'bookmark', {}); assert.equal(control.querySelector('span').textContent, '已加书签'); assert.ok(control.classList.contains('is-active')); assert.equal(control.attributes['aria-pressed'], 'true'); assert.match(control.title, /再次点击取消/);
  status = { pressed: true, saving: true, error: '' }; box.renderMessageToggle(card, '.message-bookmark-action', 'bookmark', {}); assert.equal(control.disabled, true); assert.equal(control.attributes['aria-busy'], 'true');
  status = { pressed: true, saving: false, error: 'disk failure' }; box.renderMessageToggle(card, '.message-bookmark-action', 'bookmark', {}); assert.equal(control.disabled, false); assert.match(control.title, /重试/); assert.ok(control.classList.contains('save-failed')); assert.equal(control.querySelector('span').textContent, '已加书签');
});
test('actual message DOM puts each checkbox at its own body and wires all three direct toggles', async () => {
  const state = fixture(), selected = new Set(), calls = []; let snapshot = false;
  const box = { M, state, selected, context: [], memberId: '', node, icon: name => node('svg', name), document: { createElement: tag => node(tag) }, archive: () => ({ find: () => snapshot ? null : state.messages[0] }), fullDate: () => 'date', clockDate: () => 'time', window: { ReaderPersonalization: { isFollowed: () => false }, ReaderMessageActions: A }, renderSelection() {}, toggleMessageAction: (kind, message) => calls.push([kind, message.id]), button(label, className, callback) { const b = node('button', className); b.append(node('span', '', label)); b.listeners.click = callback; return b; } };
  vm.createContext(box); vm.runInContext(actualFunction('messageCard'), box); const card = box.messageCard(state.messages[0]), body = card.querySelector('.message-body-row'), check = card.querySelector('.message-select');
  assert.equal(card.children.length, 1); assert.equal(body.children[0], check); assert.equal(body.children[1].className, 'message-body'); assert.equal(check.disabled, false); assert.match(check.attributes['aria-label'], /选择 Alice/);
  check.checked = true; check.listeners.change(); assert.ok(selected.has('g:1')); check.checked = false; check.listeners.change(); assert.ok(!selected.has('g:1'));
  for (const selector of ['.manual-progress-action', '.message-bookmark-action', '.message-collect-action']) await card.querySelector(selector).listeners.click(); assert.deepEqual(calls, [['manual', '1'], ['bookmark', '1'], ['collection', '1']]);
  snapshot = true; const snapshotCard = box.messageCard(state.messages[0]); assert.equal(snapshotCard.querySelector('.message-select').disabled, true); assert.equal(snapshotCard.querySelector('.message-body-row').children[0], snapshotCard.querySelector('.message-select'));
});
