const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const modulePath = require.resolve('../Resources/ui/model.js').replace(/model\.js$/, 'reader-personalization.js');
const P = fs.existsSync(modulePath) ? require(modulePath) : {};
const message = (senderId, senderName = '成员', extra = {}) => ({ accountId: 'account-a', groupId: 'group-a', senderId, senderName, text: '普通发言', ...extra });
const state = (members = [], messages = []) => ({ accountId: 'account-a', settings: { followedMembers: members }, messages });

test('system notice policy matches only the complete trimmed sender name or id', () => {
  assert.equal(typeof P.isSystemNotice, 'function', 'reader personalization policy must exist');
  for (const value of [message('system', '粉丝群'), message(' 粉丝群 ', '通知'), message('system', '  粉丝群  ')]) assert.equal(P.isSystemNotice(value), true);
  for (const value of [null, {}, message('person', '我的粉丝群'), message('粉丝群成员', '普通成员'), message('person', '普通成员', { text: '粉丝群发布了通知' })]) assert.equal(P.isSystemNotice(value), false);
});
test('followed members default to empty, normalize whitespace, deduplicate by id and never mutate source data', () => {
  assert.equal(typeof P.read, 'function');
  assert.deepEqual(P.read({ accountId: 'a', settings: {} }), []);
  const raw = [{ senderId: ' 123 ', name: ' 关注的人 ' }, { senderId: '123', name: '重复' }, { senderId: '456', name: '' }];
  const original = JSON.stringify(raw), normalized = P.read(state(raw));
  assert.deepEqual(normalized, [{ senderId: '123', name: '关注的人' }, { senderId: '456', name: '' }]);
  normalized[0].name = '变更'; assert.equal(JSON.stringify(raw), original);
});
test('follow validation rejects malformed identities and oversized lists', () => {
  assert.equal(typeof P.validate, 'function');
  for (const invalid of [null, {}, [null], [{ senderId: 123 }], [{ senderId: ' ' }], [{ senderId: 'unknown' }], [{ senderId: 'a\nb' }], [{ senderId: 'a'.repeat(201) }], [{ senderId: 'a', name: 4 }], [{ senderId: 'a', name: 'x'.repeat(101) }]]) assert.throws(() => P.validate(invalid));
  assert.throws(() => P.validate(Array.from({ length: 201 }, (_, index) => ({ senderId: String(index + 1), name: '' }))));
});
test('following uses sender id across groups of the current account without confusing duplicate names', () => {
  assert.equal(typeof P.isFollowed, 'function');
  const value = state([{ senderId: 'one', name: '同名' }]);
  assert.equal(P.isFollowed(value, message('one', '已改名', { groupId: 'group-b' })), true);
  assert.equal(P.isFollowed(value, message('two', '同名')), false);
  assert.equal(P.isFollowed(value, message('one', '同名', { accountId: 'account-b' })), false);
  assert.equal(P.isFollowed(value, 'one'), true);
  assert.equal(P.isFollowed(state(), 'one'), false);
});
test('toggle adds and removes members immutably and enforces the limit only on a new addition', () => {
  assert.equal(typeof P.toggle, 'function');
  const original = [{ senderId: 'one', name: '甲' }];
  const added = P.toggle(original, { senderId: 'two', name: '乙' });
  assert.equal(original.length, 1); assert.equal(added.length, 2);
  assert.deepEqual(P.toggle(added, { senderId: 'one', name: '甲' }), [{ senderId: 'two', name: '乙' }]);
  assert.deepEqual(P.toggle(original, { senderId: 'one', name: '新备注' }, true), [{ senderId: 'one', name: '新备注' }]);
  const full = Array.from({ length: 200 }, (_, index) => ({ senderId: String(index + 1), name: '' }));
  assert.throws(() => P.toggle(full, { senderId: 'new', name: '' }, true));
  assert.equal(P.toggle(full, full[0], false).length, 199);
});
test('seen member discovery ignores foreign accounts and system senders, keeps distinct ids and prioritizes the current group', () => {
  assert.equal(typeof P.seenMembers, 'function');
  const value = state([], [message('other-group', '另一群', { groupId: 'group-b' }), message('one', '同名'), message('two', '同名'), message('foreign', '其他账号', { accountId: 'account-b' }), message('notice', '粉丝群'), message('unknown'), message('one', '新名称')]);
  const members = P.seenMembers(value, 'group-a');
  assert.deepEqual(members.map(item => item.senderId), ['one', 'two', 'other-group']);
  assert.equal(members[0].name, '新名称');
});

function documentFixture() {
  const previous = global.document;
  class Element {
    constructor(tag) { this.tagName = tag.toUpperCase(); this.children = []; this.dataset = {}; this.attributes = {}; this.listeners = {}; this.value = ''; this.disabled = false; this.open = false; this._text = ''; }
    append(...children) { this.children.push(...children); }
    replaceChildren(...children) { this.children = children; this._text = ''; }
    set textContent(value) { this._text = String(value); this.children = []; }
    get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
    setAttribute(name, value) { this.attributes[name] = String(value); }
    addEventListener(name, callback) { (this.listeners[name] ||= []).push(callback); }
    async emit(name) { if (name === 'click' && this.disabled) return; const event = { target: this, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } }; await Promise.all((this.listeners[name] || []).map(callback => callback(event))); return event; }
    querySelectorAll(selector) { const tags = selector.split(',').map(value => value.trim().toUpperCase()); return this.children.flatMap(child => [...(tags.includes(child.tagName) ? [child] : []), ...child.querySelectorAll(selector)]); }
    showModal() { this.open = true; }
    close() { this.open = false; for (const callback of this.listeners.close || []) callback({ target: this }); }
    focus() { global.document.activeElement = this; }
  }
  const body = new Element('body');
  const find = (node, id) => node.id === id ? node : node.children.map(child => find(child, id)).find(Boolean);
  global.document = { body, createElement: tag => new Element(tag), getElementById: id => find(body, id) };
  return { get: id => global.document.getElementById(id), restore() { global.document = previous; } };
}
test('editor searches seen members and keeps failed edits available for retry before persisting', async () => {
  assert.equal(typeof P.mount, 'function');
  const dom = documentFixture();
  try {
    let current = state([], [message('one', '同名'), message('two', '同名')]), attempts = 0, changes = 0;
    const ui = P.mount({ getState: () => current, getGroupId: () => 'group-a', save: async members => { attempts++; if (attempts === 1) throw new Error('磁盘暂不可用'); current.settings.followedMembers = members; }, onChange: () => changes++ });
    ui.open(); dom.get('reader-follow-search').value = 'two'; await dom.get('reader-follow-search').emit('input');
    assert.equal(dom.get('reader-follow-results').children.length, 1);
    assert.equal(dom.get('reader-follow-results').children[0].dataset.senderId, 'two');
    await dom.get('reader-follow-results').querySelectorAll('button')[0].emit('click');
    assert.deepEqual(P.read(current), [], 'editing must not mutate persisted settings');
    assert.equal(dom.get('reader-followed-list').children[0].dataset.senderId, 'two');
    await dom.get('reader-follow-save').emit('click');
    assert.equal(ui.element.open, true); assert.match(dom.get('reader-follow-error').textContent, /磁盘暂不可用/);
    assert.equal(dom.get('reader-followed-list').children[0].dataset.senderId, 'two'); assert.equal(changes, 0);
    await dom.get('reader-follow-save').emit('click');
    assert.equal(ui.element.open, false); assert.equal(changes, 1); assert.deepEqual(P.read(current), [{ senderId: 'two', name: '同名' }]);
  } finally { dom.restore(); }
});
test('manual IDs are editable as a draft and cancelling leaves the stored list unchanged', async () => {
  assert.equal(typeof P.mount, 'function');
  const dom = documentFixture();
  try {
    const current = state([{ senderId: 'existing', name: '原成员' }]); let saves = 0;
    const ui = P.mount({ getState: () => current, getGroupId: () => 'group-a', save: async () => saves++ });
    ui.open(); dom.get('reader-follow-id').value = ' manual-id '; dom.get('reader-follow-name').value = ' 备注 ';
    await dom.get('reader-follow-add').emit('click');
    assert.equal(dom.get('reader-followed-list').children.length, 2);
    await dom.get('reader-followed-list').querySelectorAll('button')[0].emit('click');
    assert.equal(dom.get('reader-followed-list').children[0].dataset.senderId, 'manual-id');
    await dom.get('reader-follow-cancel').emit('click');
    assert.equal(saves, 0); assert.deepEqual(P.read(current), [{ senderId: 'existing', name: '原成员' }]);
    ui.open(); assert.equal(dom.get('reader-followed-list').children[0].dataset.senderId, 'existing'); ui.close();
  } finally { dom.restore(); }
});
test('switching accounts closes the editor and ignores a late save completion from the old account', async () => {
  assert.equal(typeof P.mount, 'function');
  const dom = documentFixture();
  try {
    let current = state(), release, changes = 0; const visibility = [];
    const ui = P.mount({ getState: () => current, getGroupId: () => 'group-a', save: () => new Promise(resolve => { release = resolve; }), onChange: () => changes++, onDialogChange: open => visibility.push(open) });
    ui.open(); dom.get('reader-follow-id').value = 'one'; await dom.get('reader-follow-add').emit('click');
    const saving = dom.get('reader-follow-save').emit('click');
    current = { ...state(), accountId: 'account-b' }; ui.render(); assert.equal(ui.element.open, false);
    release(); await saving; assert.equal(changes, 0); assert.deepEqual(P.read(current), []); assert.deepEqual(visibility, [true, false]);
  } finally { dom.restore(); }
});
