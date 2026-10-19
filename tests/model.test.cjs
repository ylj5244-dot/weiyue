const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const modelPath = path.join(__dirname, '../Resources/ui/model.js');
const M = fs.existsSync(modelPath) ? require(modelPath) : {};
const NOW = '2026-10-18T01:02:03.456Z';
const ACCOUNT = '9007199254740993123';

function fixture() {
  const state = M.createState(ACCOUNT);
  M.upsertGroups(state, [
    { id: 'group-a', name: '甲群', selected: true },
    { id: 'group-b', name: '乙群', selected: true },
    { id: 'group-c', name: '未选择群', selected: false }
  ]);
  M.ingestMessages(state, 'group-a', [
    { id: '9007199254740993001', groupId: 'group-a', senderId: 'user-1', senderName: '同名', text: '第一条 AI 分析', sentAt: '2026-10-17T10:00:00.000Z', attachments: [] },
    { id: '9007199254740993002', groupId: 'group-a', senderId: 'user-2', senderName: '同名', text: '第二条 AI 材料', sentAt: '2026-10-17T11:00:00.000Z', attachments: [] },
    { id: '9007199254740993003', groupId: 'group-a', senderId: 'user-1', senderName: '同名', text: '第三条 无关材料', sentAt: '2026-10-18T00:00:00.000Z', attachments: [{ type: 'image', url: 'https://example.com/image.jpg' }] }
  ]);
  M.ingestMessages(state, 'group-b', [
    { id: '9007199254740993001', groupId: 'group-b', senderId: 'user-2', senderName: '同名', text: '乙群相同消息编号', sentAt: '2026-10-17T10:30:00.000Z', attachments: [], sourceURL: 'https://api.weibo.com/chat?group=group-b' }
  ]);
  return state;
}

test('empty startup does not fabricate messages and classic browser export works', () => {
  assert.equal(typeof M.createState, 'function', 'ReaderModel.createState must exist');
  const state = M.createState();
  assert.deepEqual(state.messages, []);
  assert.deepEqual(state.bookmarks, []);
  assert.equal(state.accountId, '');
  const sandbox = { window: {} };
  vm.runInNewContext(fs.readFileSync(modelPath, 'utf8'), sandbox);
  assert.equal(typeof sandbox.window.ReaderModel.searchMessages, 'function');
});

test('web search choice and sourced answers survive restart, discussion deletion and restoration without changing originals', () => {
  const state=fixture(), W=require('../Resources/ui/web-search.js');
  assert.equal(W.requestOptions(state.settings,'Question').webSearchEnabled,false);
  state.settings.webSearchEnabled=true;
  const metadata={status:'success',query:'News',searchedAt:NOW,sources:[{id:'网页1',title:'Release notes',url:'https://example.com/news',publishedAt:null,siteName:'Example',excerpt:'Quoted result'}]};
  state.discussions=[{id:'web-d1',accountId:ACCOUNT,createdAt:NOW,messages:[{role:'assistant',content:'Answer [网页1]',webSearch:metadata}]}];
  const original=JSON.parse(JSON.stringify(state));
  assert.deepEqual(M.normalizeState(JSON.parse(JSON.stringify(state))),original);
  M.deleteDiscussions(state,['web-d1'],NOW);
  let restored=M.normalizeState(JSON.parse(JSON.stringify(state)));
  assert.deepEqual(restored.discussions[0].messages[0].webSearch,metadata);
  M.restoreDiscussions(restored,['web-d1']);
  assert.deepEqual(M.normalizeState(restored).discussions[0].messages[0].webSearch,metadata);
  assert.deepEqual(restored.messages,original.messages);assert.equal(restored.settings.webSearchEnabled,true);
  for(const wrong of ['true',1,null,{}]){const bad=JSON.parse(JSON.stringify(original));bad.settings.webSearchEnabled=wrong;assert.throws(()=>M.normalizeState(bad));}
  for(const change of [m=>m.sources[0].url='http://127.0.0.1',m=>m.sources[0].id='网页2',m=>m.sources[0].title='x'.repeat(501),m=>m.searchedAt='bad',m=>m.status='empty']){
    const bad=JSON.parse(JSON.stringify(original));change(bad.discussions[0].messages[0].webSearch);assert.throws(()=>M.normalizeState(bad));
  }
  const wrongRole=JSON.parse(JSON.stringify(original));wrongRole.discussions[0].messages[0].role='user';assert.throws(()=>M.normalizeState(wrongRole));
});

test('1000 independent markers survive deletion, recovery, and JSON restart without truncation', () => {
  const state = fixture();
  const revision = state.revision;
  for (let i = 0; i < 1000; i++) {
    const bookmark = M.addBookmark(state, { groupId: 'group-a', messageId: '9007199254740993001', note: `标记 ${i}`, now: NOW });
    assert.equal(bookmark.createdAt, NOW);
    assert.equal(bookmark.messageSentAt, '2026-10-17T10:00:00.000Z');
  }
  assert.equal(state.revision, revision + 1000);
  assert.equal(new Set(state.bookmarks.map(b => b.id)).size, 1000);
  const removedId = state.bookmarks[12].id;
  M.removeBookmark(state, removedId, { now: NOW });
  assert.equal(state.bookmarks.length, 1000);
  assert.equal(state.bookmarks[12].deletedAt, NOW);
  const restored = M.normalizeState(JSON.parse(JSON.stringify(state)));
  M.restoreBookmark(restored, removedId);
  assert.equal(restored.bookmarks[12].deletedAt, null);
  assert.equal(restored.bookmarks[999].note, '标记 999');
  assert.equal(restored.bookmarks[12].snapshot.id, '9007199254740993001');
  assert.equal(restored.bookmarks[12].accountId, ACCOUNT);
  assert.equal(restored.revision, state.revision + 1);
});

test('identity, search scope, inclusive time range, and equal message IDs in different groups remain distinct', () => {
  const state = fixture();
  assert.equal(M.messageKey(state.messages[0]), 'group-a:9007199254740993001');
  assert.deepEqual(M.findMembers(state, 'group-a', '同名'), [{ id: 'user-1', name: '同名', count: 2 }, { id: 'user-2', name: '同名', count: 1 }]);
  assert.deepEqual(M.searchMessages(state, { groupId: 'group-a', senderId: 'user-2', query: 'ai', from: '2026-10-17T11:00:00.000Z', to: '2026-10-17T11:00:00.000Z' }).map(m => m.id), ['9007199254740993002']);
  assert.equal(M.searchMessages(state, { groupId: 'group-b' })[0].text, '乙群相同消息编号');
  assert.deepEqual(M.findMembers(state, 'group-a', '不存在'), []);
  assert.throws(() => M.searchMessages(state, { from: '2026-10-18T00:00:00.000Z', to: '2026-10-17T00:00:00.000Z' }), /时间|范围|date|range/i);
  M.ingestMessages(state, 'group-a', [{ id: 'member-search-a', groupId: 'group-a', senderId: '7943876498', senderName: 'Alpha成员', text: '甲群成员', sentAt: NOW, attachments: [] }]);
  M.ingestMessages(state, 'group-b', [{ id: 'member-search-b', groupId: 'group-b', senderId: '7943876000', senderName: '另一成员', text: '乙群成员', sentAt: NOW, attachments: [] }]);
  const member = [{ id: '7943876498', name: 'Alpha成员', count: 1 }];
  assert.deepEqual(M.findMembers(state, 'group-a', '7943876498'), member, 'full ID matches without converting it to a number');
  assert.deepEqual(M.findMembers(state, 'group-a', '438764'), member, 'partial ID matches');
  assert.deepEqual(M.findMembers(state, 'group-a', 'ALPHA'), member, 'name matching remains case insensitive');
  assert.deepEqual(M.findMembers(state, 'group-a', '7943876'), member, 'matching IDs in another group are excluded');
  assert.deepEqual(M.findMembers(state, 'group-a', '7943876000'), []);
  assert.deepEqual(M.findMembers(state, 'group-b', '7943876498'), []);
});

test('new messages, old history, and group switches do not move independent reading anchors or marker snapshots', () => {
  const state = fixture();
  M.setProgress(state, { groupId: 'group-a', messageId: '9007199254740993001', kind: 'auto', offset: 18, now: NOW });
  M.setProgress(state, { groupId: 'group-a', messageId: '9007199254740993002', kind: 'sessionStart', now: NOW });
  M.setProgress(state, { groupId: 'group-a', messageId: '9007199254740993003', kind: 'returnPoint', now: NOW });
  M.setProgress(state, { groupId: 'group-b', messageId: '9007199254740993001', now: NOW });
  M.addBookmark(state, { groupId: 'group-a', messageId: '9007199254740993001', now: NOW });
  const anchors = JSON.stringify(state.progress);
  const markers = JSON.stringify(state.bookmarks);
  M.ingestMessages(state, 'group-a', [
    { id: 'history', groupId: 'group-a', senderId: 'user-1', senderName: '旧昵称', text: '补载历史', sentAt: '2020-01-01T00:00:00.000Z', attachments: [] },
    { id: 'future', groupId: 'group-a', senderId: 'user-1', senderName: '新昵称', text: '新消息', sentAt: '2026-10-19T00:00:00.000Z', attachments: [] },
    { id: '9007199254740993001', groupId: 'group-a', senderId: 'user-1', senderName: '新昵称', text: '后来修改', sentAt: '2026-10-17T10:00:00.000Z', attachments: [] }
  ]);
  M.selectGroup(state, 'group-a', false);
  assert.equal(JSON.stringify(state.progress), anchors);
  assert.equal(JSON.stringify(state.bookmarks), markers);
  assert.equal(M.findMembers(state, 'group-a', '新昵称')[0].id, 'user-1');
  assert.equal(M.normalizeState(JSON.parse(JSON.stringify(state))).progress['group-b'].auto.messageId, '9007199254740993001');
});

test('saving or building AI context uses exactly the selected three deduplicated snapshots with provenance', () => {
  const state = fixture();
  const selected = ['group-a:9007199254740993002', 'group-b:9007199254740993001', 'group-a:9007199254740993003', 'group-a:9007199254740993002'];
  const collection = M.createCollection(state, { name: '明确选择', messageIds: selected, now: NOW });
  assert.equal(collection.messages.length, 3);
  assert.deepEqual(collection.messages.map(m => m.text), ['第二条 AI 材料', '乙群相同消息编号', '第三条 无关材料']);
  const context = M.buildContext(state, selected);
  assert.equal(context.messages.length, 3);
  assert.ok(context.text.includes('group-b:9007199254740993001'));
  assert.ok(context.text.includes('user-2'));
  assert.ok(context.text.includes('2026-10-17T10:30:00.000Z'));
  assert.ok(!context.text.includes('第一条 AI 分析'));
  state.messages[1].text = '后改动不改变资料';
  state.messages[2].attachments[0].url = 'https://example.com/changed';
  assert.equal(collection.messages[0].text, '第二条 AI 材料');
  assert.equal(collection.messages[2].attachments[0].url, 'https://example.com/image.jpg');
  M.selectGroup(state, 'group-b', false);
  assert.equal(collection.messages.length, 3);
  assert.deepEqual(M.buildContext(state, []), { messages: [], text: '' });
  assert.throws(() => M.createCollection(state, { name: 'missing', messageIds: ['group-a:missing'] }), /消息|message/i);
});

test('normalization preserves unknown JSON data and archived snapshots even when source messages are absent', () => {
  const state = fixture();
  M.addBookmark(state, { groupId: 'group-a', messageId: '9007199254740993001', now: NOW });
  M.createCollection(state, { name: '保留', messageIds: ['group-a:9007199254740993001'], now: NOW });
  state.discussions.push({ id: 'discussion-1', accountId: ACCOUNT, createdAt: NOW, messages: [{ role: 'user', content: '问题' }], extra: { nested: ['信息'] } });
  state.extension = { a: [1, 2] };
  state.settings.fontSize = 19;
  state.messages = [];
  const before = JSON.parse(JSON.stringify(state));
  const normalized = M.normalizeState(before);
  assert.deepEqual(normalized, before);
  normalized.extension.a.push(3);
  assert.deepEqual(before.extension.a, [1, 2]);
  assert.equal(normalized.collections[0].messages[0].text, '第一条 AI 分析');
});

test('group metadata refresh preserves the user selection and batch failures leave no partial updates', () => {
  const state = fixture();
  M.upsertGroups(state, [{ id: 'group-a', name: '更新群名', selected: false }]);
  assert.equal(state.groups[0].selected, true);
  assert.equal(state.groups[0].name, '更新群名');
  M.selectGroup(state, 'group-a', false);
  M.upsertGroups(state, [{ id: 'group-a', name: '新群名', selected: true }]);
  assert.equal(state.groups[0].selected, false);
  const before = JSON.stringify(state);
  assert.throws(() => M.upsertGroups(state, [{ id: 'group-a', name: '不应保存' }, { id: 2, name: '坏编号' }]));
  assert.equal(JSON.stringify(state), before);
});

test('malformed batches and cross-account entities fail explicitly without partial mutation', () => {
  const state = fixture();
  const before = JSON.stringify(state);
  const valid = { id: 'new', groupId: 'group-a', senderId: 'user-1', senderName: '名字', text: '正常', sentAt: NOW, attachments: [] };
  for (const malformed of [
    { ...valid, id: 9007199254740992 },
    { ...valid, accountId: 'different-account' },
    { ...valid, groupId: 'group-b' },
    { ...valid, sentAt: 'not-a-date' },
    { ...valid, attachments: {} }
  ]) {
    assert.throws(() => M.ingestMessages(state, 'group-a', [valid, malformed]));
    assert.equal(JSON.stringify(state), before);
  }
  assert.throws(() => M.ingestMessages(state, 'group-c', [{ ...valid, groupId: 'group-c' }]), /选择|selected/i);
  assert.throws(() => M.addBookmark(state, { groupId: 'group-a', messageId: 'missing' }));
  assert.throws(() => M.setProgress(state, { groupId: 'group-a', messageId: '9007199254740993001', kind: 'bookmark' }));
  assert.throws(() => M.upsertGroups(state, [{ id: 'cross-account', name: '错误', accountId: 'different-account' }]));
  for (const tamper of [
    s => { s.messages[0].accountId = 'different-account'; },
    s => { s.groups[0].accountId = 'different-account'; },
    s => { s.bookmarks = [{ accountId: ACCOUNT, id: 'bad' }]; },
    s => { s.version = 88; },
    s => { s.revision = -1; },
    s => { s.messages = 'broken'; }
  ]) {
    const corrupted = JSON.parse(before);
    tamper(corrupted);
    assert.throws(() => M.normalizeState(corrupted));
  }
  const foreign = fixture();
  foreign.messages[0].accountId = 'different-account';
  assert.throws(() => M.buildContext(foreign, ['group-a:9007199254740993001']), /账号|account/i);
});

test('identical or empty observations are no-ops while actual unread/message changes preserve metadata', () => {
  const state = fixture();
  const observation = { count: 500, messageId: '9007199254740993001', observedAt: NOW };
  M.upsertGroups(state, [{ id: 'group-a', name: '甲群', unreadCount: 500, unread_count: 500, observedUnreadSnapshot: observation }]);
  const originalGroup = state.groups[0];
  let revision = state.revision;
  assert.strictEqual(M.upsertGroups(state, [{ name: '甲群', id: 'group-a', selected: false, unreadCount: 500, unread_count: 500, observedUnreadSnapshot: { observedAt: NOW, messageId: '9007199254740993001', count: 500 } }]), state.groups);
  M.upsertGroups(state, []);
  assert.equal(state.revision, revision, 'repeated metadata must not schedule another disk save');
  assert.strictEqual(state.groups[0], originalGroup);
  M.upsertGroups(state, [{ id: 'group-a', name: '甲群更新', unreadCount: 499 }]);
  assert.equal(state.revision, revision + 1);
  assert.equal(state.groups[0].unreadCount, 499);
  assert.equal(state.groups[0].unread_count, 500);
  assert.deepEqual(state.groups[0].observedUnreadSnapshot, observation);
  const incoming = { ...state.messages[2], sync: { source: 'official', cursor: '9007199254740993003' } };
  M.ingestMessages(state, 'group-a', [incoming]);
  const originalMessage = state.messages[2];
  revision = state.revision;
  const replay = { ...incoming, sync: { cursor: '9007199254740993003', source: 'official' }, attachments: [{ url: 'https://example.com/image.jpg', type: 'image' }] };
  const returned = M.ingestMessages(state, 'group-a', [replay]);
  assert.equal(returned.length, 1, 'existing array return contract must remain compatible');
  M.ingestMessages(state, 'group-a', []);
  assert.equal(state.revision, revision);
  assert.strictEqual(state.messages[2], originalMessage);
  const changed = { ...state.messages[2], text: '实际修改' }; delete changed.sync;
  M.ingestMessages(state, 'group-a', [changed]);
  assert.equal(state.revision, revision + 1);
  assert.deepEqual(state.messages[2].sync, { source: 'official', cursor: '9007199254740993003' });
});

function bulkMessages(groupId, start, count) {
  return Array.from({ length: count }, (_, offset) => {
    const index = start + offset;
    return { id: String(9007199254740993000n + BigInt(index)), groupId, senderId: index % 2 ? 'member-1' : 'member-2', senderName: '同名', text: `消息 ${index}`, sentAt: new Date(Date.UTC(2026, 9, 18) + index * 1000).toISOString(), attachments: [] };
  });
}

test('500 history messages and overlapping live batches grow to 5000 without moving six anchors or independent markers', () => {
  const state = M.createState(ACCOUNT);
  M.upsertGroups(state, [{ id: 'bulk-a', name: '历史群', selected: true, unreadCount: 500 }, { id: 'bulk-b', name: '另一群', selected: true }]);
  M.ingestMessages(state, 'bulk-a', bulkMessages('bulk-a', 500, 20));
  M.ingestMessages(state, 'bulk-b', bulkMessages('bulk-b', 500, 20));
  for (const groupId of ['bulk-a', 'bulk-b']) {
    for (const [offset, kind] of ['auto', 'sessionStart', 'returnPoint'].entries()) {
      M.setProgress(state, { groupId, messageId: String(9007199254740993500n + BigInt(offset)), kind, offset: offset + 7, now: NOW });
    }
    for (let i = 0; i < 15; i++) M.addBookmark(state, { groupId, messageId: String(9007199254740993500n + BigInt(i)), note: groupId + ' #' + i, now: NOW });
  }
  const anchors = JSON.stringify(state.progress), markers = JSON.stringify(state.bookmarks);
  M.ingestMessages(state, 'bulk-a', bulkMessages('bulk-a', 0, 500).reverse());
  M.ingestMessages(state, 'bulk-a', bulkMessages('bulk-a', 510, 20));
  assert.equal(M.searchMessages(state, { groupId: 'bulk-a' }).length, 530);
  M.selectGroup(state, 'bulk-a', false);
  M.searchMessages(state, { groupId: 'bulk-b' });
  M.selectGroup(state, 'bulk-a', true);
  M.ingestMessages(state, 'bulk-a', bulkMessages('bulk-a', 500, 4500).reverse());
  const sorted = M.searchMessages(state, { groupId: 'bulk-a' });
  assert.equal(sorted.length, 5000);
  assert.equal(sorted[0].id, '9007199254740993000');
  assert.equal(sorted[4999].id, '9007199254740997999');
  const revision = state.revision;
  M.ingestMessages(state, 'bulk-a', bulkMessages('bulk-a', 0, 5000));
  assert.equal(state.revision, revision, 'a repeated 5000-message batch must be a no-op');
  assert.equal(JSON.stringify(state.progress), anchors);
  assert.equal(JSON.stringify(state.bookmarks), markers);
  state.settings.ui = { activeGroupId: 'bulk-b', mode: 'reader', fontSize: 19 };
  state.sync = { 'bulk-a': { oldestId: '9007199254740993000', newestId: '9007199254740997999', hasMore: true } };
  const restored = M.normalizeState(JSON.parse(JSON.stringify(state)));
  assert.equal(restored.messages.length, 5020);
  assert.equal(new Set(restored.bookmarks.map(bookmark => bookmark.id)).size, 30);
  assert.equal(JSON.stringify(restored.progress), anchors);
  assert.equal(JSON.stringify(restored.bookmarks), markers);
  assert.deepEqual(restored.settings.ui, state.settings.ui);
  assert.deepEqual(restored.sync, state.sync);
});
