(function (root, factory) {
  'use strict';
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.ReaderGroupUnread = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';
  var has = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
  function fail() { throw new Error('群聊新消息提醒数据无效，原资料未被覆盖。'); }
  function object(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) fail();
    var proto = Object.getPrototypeOf(value);
    if (proto !== Object.prototype && proto !== null) fail();
    return value;
  }
  function fields(value, names) {
    object(value);
    if (Object.keys(value).length !== names.length || names.some(key => !has(value, key))) fail();
  }
  function date(value) {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(value) || !Number.isFinite(Date.parse(value))) fail();
    var year = Number(value.slice(0,4)), month = Number(value.slice(5,7)), day = Number(value.slice(8,10));
    var leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
    var days = [31,leap?29:28,31,30,31,30,31,31,30,31,30,31];
    if (year < 1 || month < 1 || month > 12 || day < 1 || day > days[month-1] || Number(value.slice(11,13)) > 23 || Number(value.slice(14,16)) > 59 || Number(value.slice(17,19)) > 59) fail();
    return Date.parse(value);
  }
  function stamp(now) { var value = now === undefined ? new Date().toISOString() : now; date(value); return new Date(value).toISOString(); }
  function boundary(value) {
    fields(value, ['id', 'sentAt']);
    if (typeof value.id !== 'string' || !value.id.trim() || value.id.length > 160) fail();
    date(value.sentAt); return value;
  }
  function validate(value, accountId, groups) {
    object(value);
    var ids = new Set(groups.map(group => group.id));
    Object.keys(value).forEach(groupId => {
      var entry = value[groupId]; fields(entry, ['accountId', 'groupId', 'count', 'acknowledgedAt', 'baseline']);
      if (!accountId || entry.accountId !== accountId || entry.groupId !== groupId || !ids.has(groupId)) fail();
      if (!Number.isSafeInteger(entry.count) || entry.count < 0) fail();
      date(entry.acknowledgedAt);
      if (entry.baseline !== null) boundary(entry.baseline);
    });
    return value;
  }
  function newer(message, baseline) {
    if (!baseline) return true;
    if (message.id === baseline.id) return false;
    // Weibo IDs are monotonic 64-bit integers; never coerce them to Number.
    if (/^\d+$/.test(message.id) && /^\d+$/.test(baseline.id)) return BigInt(message.id) > BigInt(baseline.id);
    var difference = Date.parse(message.sentAt) - Date.parse(baseline.sentAt);
    return difference ? difference > 0 : message.id > baseline.id;
  }
  function latest(messages, previous) {
    var value = previous || null;
    messages.forEach(message => { if (newer(message, value)) value = {id: message.id, sentAt: message.sentAt}; });
    return value;
  }
  function write(state, groupId, entry) {
    if (!state.settings.groupUnread) state.settings.groupUnread = {};
    var prior = has(state.settings.groupUnread, groupId) ? state.settings.groupUnread[groupId] : null;
    if (JSON.stringify(prior) === JSON.stringify(entry)) return false;
    Object.defineProperty(state.settings.groupUnread, groupId, {value: entry, enumerable: true, configurable: true, writable: true});
    state.revision++; return true;
  }
  function initialize(state, now) {
    if (!state.accountId) return false;
    if (state.settings.groupUnread) validate(state.settings.groupUnread, state.accountId, state.groups);
    var missing = state.groups.filter(group => group.selected && (!state.settings.groupUnread || !has(state.settings.groupUnread, group.id)));
    if (!missing.length) return false;
    var acknowledgedAt = stamp(now), byGroup = new Map(missing.map(group => [group.id, null]));
    state.messages.forEach(message => {
      if (byGroup.has(message.groupId) && newer(message, byGroup.get(message.groupId))) byGroup.set(message.groupId, {id: message.id, sentAt: message.sentAt});
    });
    missing.forEach(group => write(state, group.id, {accountId: state.accountId, groupId: group.id, count: 0, acknowledgedAt, baseline: byGroup.get(group.id)}));
    return true;
  }
  function count(state, groupId) {
    var map = state.settings.groupUnread;
    return map && has(map, groupId) && map[groupId].accountId === state.accountId ? map[groupId].count : 0;
  }
  function acknowledge(state, groupId, messages, now) {
    if (!state.accountId || !state.groups.some(group => group.id === groupId)) return false;
    var map = state.settings.groupUnread, prior = map && has(map, groupId) ? map[groupId] : null;
    return write(state, groupId, {accountId: state.accountId, groupId, count: 0, acknowledgedAt: stamp(now), baseline: latest(messages.filter(message => message.groupId === groupId), prior && prior.baseline)});
  }
  // Call after the archive accepts a batch, passing only IDs absent before that
  // ingest. Keep the acknowledgement boundary fixed across newest-first pages;
  // advancing it on every page would miss the rest of a large live backlog.
  function observe(state, groupId, messages, options) {
    options = options || {};
    var group = state.groups.find(item => item.id === groupId);
    if (!group || !group.selected) return false;
    var map = state.settings.groupUnread, prior = map && has(map, groupId) ? map[groupId] : null;
    if (!prior) { initialize(state, options.now); return true; }
    var entry = {...prior}, incoming = messages.filter(message => message.groupId === groupId && message.accountId === state.accountId);
    if (options.activeGroupId === groupId) {
      entry.count = 0; entry.baseline = latest(incoming, prior.baseline);
    } else if (!prior.baseline) {
      // An empty/newly enabled group establishes its initial snapshot quietly.
      entry.baseline = latest(incoming);
    } else if (!['history', 'refresh', 'replay'].includes(options.source)) {
      var requestTime = typeof options.requestStartedAt === 'string' ? Date.parse(options.requestStartedAt) : NaN;
      var acknowledged = Date.parse(prior.acknowledgedAt);
      var freshIds = options.freshIds || new Set();
      var additions = incoming.filter(message => freshIds.has(message.id) && newer(message, prior.baseline) &&
        (Number.isFinite(requestTime) ? requestTime > acknowledged : Date.parse(message.sentAt) > acknowledged)).length;
      if (additions > Number.MAX_SAFE_INTEGER - entry.count) fail();
      entry.count += additions;
    }
    return write(state, groupId, entry);
  }
  return Object.freeze({validate, initialize, acknowledge, observe, count, newer});
});
