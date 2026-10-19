'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const U = require('../Resources/ui/group-unread.js');
const M = require('../Resources/ui/model.js');
const start = '2026-10-18T00:10:00.000Z';
const later = '2026-10-18T00:11:00.000Z';
const arrived = '2026-10-18T00:11:01.000Z';
function message(groupId, id, sentAt = arrived) { return {id: String(id), groupId, senderId: 'u', senderName: 'Synthetic', text: 'Synthetic message', sentAt, attachments: []}; }
function fixture(account = 'account-a') {
  const state = M.createState(account);
  M.upsertGroups(state, ['a','b','c'].map(id => ({id, name: id, selected: true})));
  for (const group of state.groups) M.ingestMessages(state, group.id, [message(group.id, '9007199254740993100', '2026-10-18T00:00:00.000Z')]);
  U.initialize(state, start); return state;
}
function ingest(state, groupId, batch, options = {}) {
  const existing = new Set(state.messages.filter(message => message.groupId === groupId).map(message => message.id));
  const accepted = M.ingestMessages(state, groupId, batch);
  U.observe(state, groupId, accepted, {activeGroupId: 'a', source: 'live', requestStartedAt: later, freshIds: new Set(accepted.filter(message => !existing.has(message.id)).map(message => message.id)), ...options});
}
test('initial cached messages quietly establish per-account per-group boundaries', () => {
  const state = fixture();
  assert.equal(U.count(state,'a'),0); assert.equal(U.count(state,'b'),0);
  const revision = state.revision;
  assert.equal(U.initialize(state,later),false); assert.equal(state.revision,revision);
  assert.equal(state.settings.groupUnread.b.baseline.id,'9007199254740993100');
  assert.equal(state.settings.groupUnread.b.acknowledgedAt,start);
});
test('inactive selected groups count only new IDs, independently of active group and duplicate edits', () => {
  const state = fixture();
  ingest(state,'b',[message('b','9007199254740993101'),message('b','9007199254740993102')]);
  ingest(state,'c',[message('c','9007199254740993101')]);
  ingest(state,'a',[message('a','9007199254740993101')]);
  assert.equal(U.count(state,'a'),0); assert.equal(U.count(state,'b'),2); assert.equal(U.count(state,'c'),1);
  ingest(state,'b',[{...message('b','9007199254740993101'),text:'edited metadata'}]);
  assert.equal(U.count(state,'b'),2);
});
test('newest-first live pagination counts every previously unseen newer message', () => {
  const state = fixture();
  for (const ids of [[105,106],[103,104],[100,101,102]]) ingest(state,'b',ids.map(id => message('b',String(9007199254740993000n+BigInt(id)))));
  assert.equal(U.count(state,'b'),6);
  assert.equal(state.settings.groupUnread.b.baseline.id,'9007199254740993100');
});
test('old history, replay cache, refresh and initial imports never inflate new-message reminders', () => {
  const state = fixture();
  ingest(state,'b',[message('b','9007199254740993099')]);
  for (const [index,source] of ['history','refresh','replay'].entries()) ingest(state,'b',[message('b',String(9007199254740993110n+BigInt(index)))],{source});
  assert.equal(U.count(state,'b'),0);
  const empty = M.createState('account-a'); M.upsertGroups(empty,[{id:'b',name:'b',selected:true}]); U.initialize(empty,start);
  ingest(empty,'b',[message('b','9007199254740993100')]);
  assert.equal(U.count(empty,'b'),0);
  ingest(empty,'b',[message('b','9007199254740993101')]); assert.equal(U.count(empty,'b'),1);
});
test('acknowledgement clears only that group and leaves reading anchors untouched', () => {
  const state = fixture(); M.setProgress(state,{groupId:'b',messageId:'9007199254740993100',offset:17,now:start});
  ingest(state,'b',[message('b','9007199254740993101')]); ingest(state,'c',[message('c','9007199254740993101')]);
  const progress = JSON.stringify(state.progress);
  U.acknowledge(state,'b',state.messages,'2026-10-18T00:12:00.000Z');
  assert.equal(U.count(state,'b'),0); assert.equal(U.count(state,'c'),1); assert.equal(JSON.stringify(state.progress),progress);
  // Click B, then A, while an older B request is still in flight.
  ingest(state,'b',[message('b','9007199254740993102')],{requestStartedAt:later});
  assert.equal(U.count(state,'b'),0);
  ingest(state,'b',[message('b','9007199254740993103')],{requestStartedAt:'2026-10-18T00:13:00.000Z'});
  assert.equal(U.count(state,'b'),1);
});
test('persistence and account switching retain independent reminders without replay increments', () => {
  const a = fixture(); ingest(a,'b',[message('b','9007199254740993101')]);
  const reopened = M.normalizeState(JSON.parse(JSON.stringify(a))); U.initialize(reopened,later);
  assert.equal(U.count(reopened,'b'),1);
  ingest(reopened,'b',[message('b','9007199254740993101')]); assert.equal(U.count(reopened,'b'),1);
  const b = fixture('account-b'); assert.equal(U.count(b,'b'),0);
  const before = JSON.stringify(reopened.settings.groupUnread);
  U.observe(reopened,'b',[{...message('b','9007199254740993102'),accountId:'account-b'}],{freshIds:new Set(['9007199254740993102'])});
  assert.equal(JSON.stringify(reopened.settings.groupUnread),before);
});
test('legacy events without provenance use acknowledgement time conservatively', () => {
  const state = fixture();
  ingest(state,'b',[message('b','9007199254740993101', '2026-10-18T00:09:00.000Z')],{requestStartedAt:undefined});
  assert.equal(U.count(state,'b'),0);
  ingest(state,'b',[message('b','9007199254740993102')],{requestStartedAt:undefined}); assert.equal(U.count(state,'b'),1);
});
test('strict model validation rejects malformed reminder state and accepts old versions', () => {
  const state = fixture(); assert.doesNotThrow(() => M.normalizeState(state));
  const changes = [entry=>{entry.count=-1},entry=>{entry.count=true},entry=>{entry.count=1.5},entry=>{entry.count=Number.MAX_SAFE_INTEGER+1},entry=>{entry.accountId='other'},entry=>{entry.groupId='a'},entry=>{entry.acknowledgedAt='today'},entry=>{entry.extra=true},entry=>{delete entry.count},entry=>{entry.baseline.id=''},entry=>{entry.baseline.sentAt='invalid'},entry=>{entry.baseline.extra=true}];
  for (const change of changes) { const bad=structuredClone(state);change(bad.settings.groupUnread.b);assert.throws(()=>M.normalizeState(bad)); }
  const wrongGroup=structuredClone(state);wrongGroup.settings.groupUnread.unknown={...wrongGroup.settings.groupUnread.b,groupId:'unknown'};assert.throws(()=>M.normalizeState(wrongGroup));
  for (const invalid of ['2026-02-30T00:00:00.000Z','2026-10-18T24:00:00.000Z','2026-10-18T00:00:00.1234567890Z','0000-01-01T00:00:00.000Z']) {
    const bad=structuredClone(state);bad.settings.groupUnread.b.acknowledgedAt=invalid;assert.throws(()=>M.normalizeState(bad));
  }
  const old=structuredClone(state);delete old.settings.groupUnread;assert.doesNotThrow(()=>M.normalizeState(old));
});
