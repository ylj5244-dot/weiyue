(function (root, factory) {
  'use strict';
  var preferences = (typeof module === 'object' && module.exports) ? require('./preferences.js') : (root && root.ReaderPreferences);
  var webSearch = (typeof module === 'object' && module.exports) ? require('./web-search.js') : (root && root.ReaderWebSearch);
  var groupUnread = (typeof module === 'object' && module.exports) ? require('./group-unread.js') : (root && root.ReaderGroupUnread);
  var api = factory(preferences, webSearch, groupUnread);
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.ReaderModel = api;
})(typeof window !== 'undefined' ? window : (typeof globalThis !== 'undefined' ? globalThis : this), function (Preferences, WebSearch, GroupUnread) {
  'use strict';

  var progressKinds = ['auto', 'manual', 'sessionStart', 'returnPoint', 'standbyView'];
  var sequence = 0;
  var has = function (object, key) { return Object.prototype.hasOwnProperty.call(object, key); };
  function fail(message) { throw new Error(message); }
  function preferenceAPI() { if (!Preferences) fail('个人偏好模块未加载'); return Preferences; }
  function object(value, label) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) fail(label + ' 必须是对象');
    return value;
  }
  function array(value, label) {
    if (!Array.isArray(value)) fail(label + ' 必须是数组');
    return value;
  }
  function string(value, label, allowEmpty) {
    if (typeof value !== 'string' || (!allowEmpty && !value.trim())) fail(label + ' 必须是字符串');
    return value;
  }
  function id(value, label) { return string(value, label || 'id', false); }
  function iso(value, label) {
    string(value, label || '时间', false);
    var stamp = Date.parse(value);
    if (!Number.isFinite(stamp)) fail((label || '时间') + ' 无效');
    return new Date(stamp).toISOString();
  }
  function nowISO(value) { return iso(value === undefined ? new Date().toISOString() : value, '创建时间'); }
  function anchorDate(value) {
    iso(value, '阅读消息时间');
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(value)) fail('阅读消息时间无效');
    var wall = value.slice(0, 19), parsed = new Date(wall + 'Z');
    if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 19) !== wall) fail('阅读消息时间无效');
  }

  // Copy only serializable data. Never silently discard malformed fields during restore.
  function clone(value, seen) {
    if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (!value || typeof value !== 'object') fail('数据包含无法保存的 JSON 值');
    seen = seen || new Set();
    if (seen.has(value)) fail('数据存在循环引用');
    seen.add(value);
    var output;
    if (Array.isArray(value)) {
      output = value.map(function (item) { return clone(item, seen); });
    } else {
      var proto = Object.getPrototypeOf(value);
      if (proto !== Object.prototype && proto !== null) fail('数据必须是普通 JSON 对象');
      output = {};
      Object.keys(value).forEach(function (key) {
        Object.defineProperty(output, key, { value: clone(value[key], seen), enumerable: true, writable: true, configurable: true });
      });
    }
    seen.delete(value);
    return output;
  }
  function equalJSON(left, right) {
    if (left === right) return true;
    if (!left || !right || typeof left !== 'object' || typeof right !== 'object') return false;
    if (Array.isArray(left) !== Array.isArray(right)) return false;
    var keys = Object.keys(left);
    if (keys.length !== Object.keys(right).length) return false;
    return keys.every(function (key) { return has(right, key) && equalJSON(left[key], right[key]); });
  }
  function mergeJSON(previous, incoming) {
    var merged = {};
    [previous, incoming].forEach(function (source) {
      Object.keys(source).forEach(function (key) {
        Object.defineProperty(merged, key, { value: source[key], enumerable: true, writable: true, configurable: true });
      });
    });
    return merged;
  }

  function account(entity, accountId, fill) {
    object(entity, '数据实体');
    if (fill && entity.accountId === undefined) entity.accountId = accountId;
    if (!accountId || entity.accountId !== accountId) fail('数据账号 accountId 与当前账号不一致');
  }
  function validateGroup(group, accountId, fill) {
    account(group, accountId, fill);
    id(group.id, '群 id');
    string(group.name, '群名称', true);
    if (fill && group.selected === undefined) group.selected = false;
    if (typeof group.selected !== 'boolean') fail('群 selected 必须是布尔值');
  }
  function messageKey(message) {
    object(message, '消息');
    return id(message.groupId, '群 id') + ':' + id(message.id, '消息 id');
  }
  function validateMessage(message, accountId, fill) {
    account(message, accountId, fill);
    messageKey(message);
    id(message.senderId, '成员 id');
    string(message.senderName, '成员名称', true);
    string(message.text, '消息文本', true);
    iso(message.sentAt, '消息时间');
    if (fill && message.attachments === undefined) message.attachments = [];
    array(message.attachments, '消息附件');
    if (message.sourceURL !== undefined) string(message.sourceURL, '消息出处', true);
  }
  function validateBookmark(bookmark, accountId, fill) {
    account(bookmark, accountId, fill);
    id(bookmark.id, '标记 id');
    id(bookmark.groupId, '标记群 id');
    id(bookmark.messageId, '标记消息 id');
    iso(bookmark.createdAt, '标记创建时间');
    iso(bookmark.messageSentAt, '标记消息时间');
    string(bookmark.note, '标记备注', true);
    validateMessage(bookmark.snapshot, accountId, fill);
    if (bookmark.snapshot.id !== bookmark.messageId || bookmark.snapshot.groupId !== bookmark.groupId) fail('标记快照与消息出处不一致');
    if (fill && bookmark.deletedAt === undefined) bookmark.deletedAt = null;
    if (bookmark.deletedAt !== null) iso(bookmark.deletedAt, '标记删除时间');
  }
  function validateCollection(collection, accountId, fill) {
    account(collection, accountId, fill);
    id(collection.id, '资料集 id');
    string(collection.name, '资料集名称', false);
    iso(collection.createdAt, '资料集创建时间');
    array(collection.messageIds, '资料集消息引用');
    array(collection.messages, '资料集消息快照');
    if (collection.messageIds.length !== collection.messages.length) fail('资料集消息引用与快照数量不一致');
    collection.messages.forEach(function (message, index) {
      validateMessage(message, accountId, fill);
      if (messageKey(message) !== collection.messageIds[index]) fail('资料集快照出处不一致');
    });
    unique(collection.messageIds, function (key) { return id(key, '消息引用'); }, '资料集消息引用');
    if (collection.discussionId !== undefined && collection.discussionId !== null) id(collection.discussionId, '讨论 id');
    if (collection.deletedAt !== undefined && collection.deletedAt !== null) iso(collection.deletedAt, '收藏删除时间');
  }
  function validateRangeSummary(discussion, accountId, fill) {
    var summary = object(discussion.rangeSummary, '时段总结');
    function fields(value, allowed, label) { Object.keys(value).forEach(function (key) { if (allowed.indexOf(key) < 0) fail(label + ' 存在未知字段 ' + key); }); }
    function count(value, label, minimum, maximum) { if (!Number.isSafeInteger(value) || value < (minimum || 0) || (maximum !== undefined && value > maximum)) fail('时段总结 ' + label + ' 无效'); return value; }
    function text(value, label, maximum, empty) { string(value, '时段总结 ' + label, empty); if (value.length > maximum) fail('时段总结 ' + label + ' 过长'); return value; }
    fields(summary, ['version','groupId','startAt','endAt','label','sourceCount','coverage','status','batchCount','completedBatches','partials','prompt','stage','round','reductionCompleted','finalText','rounds','error'], '时段总结');
    if (summary.version !== 1) fail('时段总结版本无效');
    id(summary.groupId, '时段总结群 id');
    var from = Date.parse(iso(summary.startAt, '时段开始时间')), to = Date.parse(iso(summary.endAt, '时段结束时间'));
    if (from > to) fail('时段总结起止时间无效');
    text(summary.label, '时段名称', 4096, false); text(summary.prompt, '总结要求', 100000, false);
    var snapshots = array(discussion.contextSnapshots, '时段消息快照');
    if (count(summary.sourceCount, '消息数量', 1) !== snapshots.length) fail('时段总结消息数量与快照不一致');
    var seen = new Set(), previousTime = -Infinity;
    for (var index = 0; index < snapshots.length; index++) {
      var snapshot = snapshots[index]; validateMessage(snapshot, accountId, false);
      snapshot.attachments.forEach(function (attachment) { object(attachment, '时段消息附件'); });
      var stamp = Date.parse(snapshot.sentAt);
      if (snapshot.groupId !== summary.groupId || stamp < from || stamp > to || stamp < previousTime || seen.has(snapshot.id)) fail('时段消息快照出处、时间或顺序不一致');
      previousTime = stamp; seen.add(snapshot.id);
    }
    var coverage = object(summary.coverage, '时段加载情况');
    fields(coverage, ['complete','reason','from','to','checkedAt','loadedCount','pages'], '时段加载情况');
    if (typeof coverage.complete !== 'boolean') fail('时段加载完整性无效');
    text(coverage.reason, '加载说明', 100000, false); iso(coverage.checkedAt, '时段核对时间');
    if (Date.parse(iso(coverage.from, '加载开始时间')) !== from || Date.parse(iso(coverage.to, '加载结束时间')) !== to || count(coverage.loadedCount, '已加载数量') !== summary.sourceCount) fail('时段加载范围或消息数量不一致');
    count(coverage.pages, '加载页数');
    if (['running','complete','failed','interrupted'].indexOf(summary.status) < 0) fail('时段总结状态无效');
    count(summary.batchCount, '总批次', 1); count(summary.completedBatches, '完成批次', 0, summary.batchCount);
    var partials = array(summary.partials, '分批摘要');
    if (partials.length !== summary.completedBatches) fail('已完成批次与分批摘要数量不一致');
    for (var p = 0; p < partials.length; p++) text(partials[p], '分批摘要', 1000000, false);
    if (has(summary, 'stage') && ['map','reduce'].indexOf(summary.stage) < 0) fail('时段总结阶段无效');
    ['round','rounds'].forEach(function (key) { if (has(summary, key)) count(summary[key], key, 1, 8); });
    if (has(summary, 'reductionCompleted')) count(summary.reductionCompleted, '汇总完成批次');
    if (has(summary, 'finalText')) text(summary.finalText, '最终总结', 1000000, false);
    if (has(summary, 'error')) text(summary.error, '错误说明', 100000, true);
    if (summary.status === 'complete' && (summary.completedBatches !== summary.batchCount || !has(summary, 'finalText'))) fail('时段总结尚未完成全部批次');
  }
  function unique(items, key, label) {
    var keys = new Set();
    items.forEach(function (item) {
      var value = key(item);
      if (keys.has(value)) fail(label + ' 存在重复 id');
      keys.add(value);
    });
  }
  function validateState(state, fill) {
    object(state, '状态');
    if (state.version !== 1) fail('不支持的状态 version');
    string(state.accountId, '账号 accountId', true);
    if (!Number.isSafeInteger(state.revision) || state.revision < 0) fail('状态 revision 无效');
    ['groups', 'messages', 'bookmarks', 'collections', 'discussions'].forEach(function (field) { array(state[field], field); });
    state.groups.forEach(function (group) { validateGroup(group, state.accountId, fill); });
    state.messages.forEach(function (message) { validateMessage(message, state.accountId, fill); });
    state.bookmarks.forEach(function (bookmark) { validateBookmark(bookmark, state.accountId, fill); });
    state.collections.forEach(function (collection) { validateCollection(collection, state.accountId, fill); });
    state.discussions.forEach(function (discussion) {
      account(discussion, state.accountId, fill);
      id(discussion.id, '讨论 id');
      if (discussion.createdAt !== undefined) iso(discussion.createdAt, '讨论创建时间');
      if (has(discussion, 'titleInfo')) {
        var titleInfo=object(discussion.titleInfo,'讨论标题信息');
        if(titleInfo.version!==1 || titleInfo.source!=='ai' || typeof titleInfo.fingerprint!=='string' || !/^[a-f0-9]{16}$/.test(titleInfo.fingerprint))fail('讨论标题信息无效');
        string(titleInfo.model,'标题模型',true);
        if(titleInfo.model.length>240)fail('标题模型名称过长');
        iso(titleInfo.generatedAt,'标题生成时间');
        if(typeof discussion.title!=='string' || !discussion.title.trim() || Array.from(discussion.title).length>32)fail('AI 标题无效');
      }
      if (has(discussion, 'deletedAt') && discussion.deletedAt !== null) {
        if (typeof discussion.deletedAt !== 'string' || discussion.deletedAt.indexOf('T') < 0) fail('讨论删除时间必须是 ISO 时间');
        iso(discussion.deletedAt, '讨论删除时间');
      }
      if (has(discussion, 'instructions')) preferenceAPI().validateInstructions(discussion.instructions);
      if (has(discussion, 'rangeSummary')) validateRangeSummary(discussion, state.accountId, fill);
      if (has(discussion, 'messages')) array(discussion.messages, '讨论消息').forEach(function (turn) {
        object(turn, '讨论消息');
        if (has(turn, 'webSearch')) {
          if (turn.role !== 'assistant') fail('联网来源只能关联 AI 回答');
          if (!WebSearch) fail('联网检索模块未加载');
          WebSearch.validate(turn.webSearch);
        }
      });
    });
    unique(state.groups, function (g) { return g.id; }, '群');
    unique(state.messages, messageKey, '消息');
    ['bookmarks', 'collections', 'discussions'].forEach(function (field) {
      unique(state[field], function (entity) { return entity.id; }, field);
    });
    object(state.progress, '阅读进度');
    Object.keys(state.progress).forEach(function (groupId) {
      id(groupId, '阅读群 id');
      var groupProgress = object(state.progress[groupId], '群阅读进度');
      Object.keys(groupProgress).forEach(function (kind) {
        if (progressKinds.indexOf(kind) === -1) fail('未知阅读进度类型');
        var anchor = groupProgress[kind];
        account(anchor, state.accountId, fill);
        if (anchor.groupId !== groupId) fail('阅读进度群 id 不一致');
        id(anchor.messageId, '阅读消息 id');
        if (!Number.isFinite(anchor.offset) || anchor.offset < 0) fail('阅读位置 offset 无效');
        iso(anchor.updatedAt, '阅读更新时间');
        if (has(anchor, 'messageSentAt')) anchorDate(anchor.messageSentAt);
      });
    });
    object(state.settings, '设置');
    string(state.settings.baseURL, 'API 地址', true);
    string(state.settings.model, '模型名称', true);
    if (has(state.settings, 'aiPreferences')) preferenceAPI().validate(state.settings.aiPreferences);
    if (has(state.settings, 'aiDraftInstructions')) preferenceAPI().validateInstructions(state.settings.aiDraftInstructions);
    if (has(state.settings, 'activeDiscussionId')) preferenceAPI().validateActiveDiscussionId(state.settings.activeDiscussionId);
    if (has(state.settings, 'webSearchEnabled') && typeof state.settings.webSearchEnabled !== 'boolean') fail('联网检索开关必须为布尔值');
    if (has(state.settings, 'readerStandby') && typeof state.settings.readerStandby !== 'boolean') fail('待机设置必须为布尔值');
    if (has(state.settings, 'groupUnread')) {
      if (!GroupUnread) fail('群聊新消息提醒模块未加载');
      GroupUnread.validate(state.settings.groupUnread, state.accountId, state.groups);
    }
    return state;
  }
  function writable(state) {
    validateState(state, false);
    if (state.revision === Number.MAX_SAFE_INTEGER) fail('状态 revision 超出安全范围');
    return state;
  }
  function createState(accountId) {
    accountId = accountId === undefined ? '' : accountId;
    string(accountId, '账号 accountId', true);
    return { version: 1, revision: 0, accountId: accountId, groups: [], messages: [], bookmarks: [], collections: [], progress: {}, discussions: [], settings: { baseURL: '', model: '' } };
  }
  function normalizeState(raw) {
    object(raw, '状态');
    var result = clone(raw);
    var defaults = createState(result.accountId === undefined ? '' : result.accountId);
    Object.keys(defaults).forEach(function (key) { if (!has(result, key)) result[key] = defaults[key]; });
    object(result.settings, '设置');
    if (!has(result.settings, 'baseURL')) result.settings.baseURL = '';
    if (!has(result.settings, 'model')) result.settings.model = '';
    return validateState(result, true);
  }
  function groupFor(state, groupId) {
    id(groupId, '群 id');
    var group = state.groups.find(function (entry) { return entry.id === groupId; });
    if (!group) fail('群不存在');
    return group;
  }
  function messageFor(state, groupId, messageId) {
    id(groupId, '群 id');
    id(messageId, '消息 id');
    var message = state.messages.find(function (entry) { return entry.groupId === groupId && entry.id === messageId; });
    if (!message) fail('本地消息不存在，请使用已保存快照查看缺口');
    return message;
  }
  function newId(state, prefix) {
    var existing = new Set(state.bookmarks.concat(state.collections, state.discussions).map(function (entity) { return entity.id; }));
    var candidate;
    do { candidate = prefix + '-' + Date.now().toString(36) + '-' + (++sequence).toString(36) + '-' + Math.random().toString(36).slice(2, 10); } while (existing.has(candidate));
    return candidate;
  }
  function upsertGroups(state, groups) {
    writable(state);
    var incoming = clone(array(groups, '群列表'));
    var positions = new Map(state.groups.map(function (group, index) { return [group.id, index]; }));
    incoming.forEach(function (group) {
      validateGroup(group, state.accountId, true);
      var previous = state.groups[positions.get(group.id)];
      // Only selectGroup changes an existing group's user-granted archive scope.
      if (previous) group.selected = previous.selected;
    });
    unique(incoming, function (group) { return group.id; }, '群列表');
    var changes = [];
    incoming.forEach(function (group) {
      var index = positions.get(group.id);
      if (index === undefined) changes.push({ value: group });
      else {
        var merged = mergeJSON(state.groups[index], group);
        if (!equalJSON(state.groups[index], merged)) changes.push({ index: index, value: merged });
      }
    });
    changes.forEach(function (change) {
      if (change.index === undefined) state.groups.push(change.value);
      else state.groups[change.index] = change.value;
    });
    if (changes.length) state.revision++;
    return state.groups;
  }
  function selectGroup(state, groupId, selected) {
    writable(state);
    selected = selected === undefined ? true : selected;
    if (typeof selected !== 'boolean') fail('selected 必须是布尔值');
    var group = groupFor(state, groupId);
    group.selected = selected;
    state.revision++;
    return group;
  }
  function ingestMessages(state, groupId, messages) {
    writable(state);
    if (!groupFor(state, groupId).selected) fail('只可归档已选择 selected 的群');
    var incoming = clone(array(messages, '消息列表'));
    incoming.forEach(function (message) {
      validateMessage(message, state.accountId, true);
      if (message.groupId !== groupId) fail('消息 groupId 与指定群不一致');
    });
    unique(incoming, messageKey, '消息列表');
    // Index once per batch; replaying thousands of overlapping messages remains
    // linear in the local archive plus the incoming batch, without moving anchors.
    var positions = new Map(state.messages.map(function (message, index) { return [messageKey(message), index]; }));
    var changes = [];
    incoming.forEach(function (message) {
      var index = positions.get(messageKey(message));
      if (index === undefined) { changes.push({ value: message }); return; }
      var previous = state.messages[index];
      // The public compound key is literal group:id; reject ambiguous collisions.
      if (previous.groupId !== message.groupId || previous.id !== message.id) fail('消息复合 id 冲突');
      var merged = mergeJSON(previous, message);
      if (!equalJSON(previous, merged)) changes.push({ index: index, value: merged });
    });
    changes.forEach(function (change) {
      if (change.index === undefined) state.messages.push(change.value);
      else state.messages[change.index] = change.value;
    });
    if (changes.length) state.revision++;
    return incoming;
  }
  function addBookmark(state, params) {
    writable(state);
    object(params, '标记参数');
    var source = messageFor(state, params.groupId, params.messageId);
    var bookmark = { id: newId(state, 'bookmark'), accountId: state.accountId, groupId: source.groupId, messageId: source.id, createdAt: nowISO(params.now), messageSentAt: source.sentAt, note: params.note === undefined ? '' : string(params.note, '标记备注', true), snapshot: clone(source), deletedAt: null };
    state.bookmarks.push(bookmark);
    state.revision++;
    return bookmark;
  }
  function bookmarkFor(state, bookmarkId) {
    id(bookmarkId, '标记 id');
    var bookmark = state.bookmarks.find(function (entry) { return entry.id === bookmarkId; });
    if (!bookmark) fail('标记不存在');
    return bookmark;
  }
  function removeBookmark(state, bookmarkId, options) {
    writable(state);
    var bookmark = bookmarkFor(state, bookmarkId);
    options = options === undefined ? {} : object(options, '删除参数');
    bookmark.deletedAt = nowISO(options.now);
    state.revision++;
    return bookmark;
  }
  function restoreBookmark(state, bookmarkId, options) {
    writable(state);
    var bookmark = bookmarkFor(state, bookmarkId);
    if (options !== undefined) { object(options, '恢复参数'); if (options.now !== undefined) nowISO(options.now); }
    bookmark.deletedAt = null;
    state.revision++;
    return bookmark;
  }
  function setProgress(state, params) {
    writable(state);
    object(params, '阅读进度参数');
    var source = messageFor(state, params.groupId, params.messageId);
    var kind = params.kind === undefined ? 'auto' : params.kind;
    if (progressKinds.indexOf(kind) === -1) fail('未知阅读进度类型');
    var offset = params.offset === undefined ? 0 : params.offset;
    if (!Number.isFinite(offset) || offset < 0) fail('阅读位置 offset 无效');
    var anchor = { accountId: state.accountId, groupId: source.groupId, messageId: source.id, messageSentAt: source.sentAt, offset: offset, updatedAt: nowISO(params.now) };
    if (!has(state.progress, source.groupId)) Object.defineProperty(state.progress, source.groupId, { value: {}, enumerable: true, writable: true, configurable: true });
    state.progress[source.groupId][kind] = anchor;
    state.revision++;
    return anchor;
  }
  function findMembers(state, groupId, query) {
    validateState(state, false);
    groupFor(state, groupId);
    query = query === undefined ? '' : string(query, '成员关键词', true).toLocaleLowerCase();
    var byId = new Map();
    state.messages.filter(function (message) { return message.groupId === groupId; }).forEach(function (message) {
      var current = byId.get(message.senderId);
      if (!current) byId.set(message.senderId, { id: message.senderId, name: message.senderName, count: 1, stamp: Date.parse(message.sentAt) });
      else { current.count++; if (Date.parse(message.sentAt) >= current.stamp) { current.name = message.senderName; current.stamp = Date.parse(message.sentAt); } }
    });
    return Array.from(byId.values()).filter(function (member) { return member.name.toLocaleLowerCase().includes(query) || member.id.toLocaleLowerCase().includes(query); }).map(function (member) { return { id: member.id, name: member.name, count: member.count }; });
  }
  function searchMessages(state, filters) {
    validateState(state, false);
    filters = filters === undefined ? {} : object(filters, '搜索参数');
    var groupId = filters.groupId;
    var senderId = filters.senderId;
    if (groupId !== undefined && groupId !== '') id(groupId, '群 id');
    if (senderId !== undefined && senderId !== '') id(senderId, '成员 id');
    var query = filters.query === undefined ? '' : string(filters.query, '搜索关键词', true).toLocaleLowerCase();
    var from = filters.from === undefined || filters.from === '' ? -Infinity : Date.parse(iso(filters.from, '开始时间'));
    var to = filters.to === undefined || filters.to === '' ? Infinity : Date.parse(iso(filters.to, '结束时间'));
    if (from > to) fail('搜索时间范围无效');
    return state.messages.filter(function (message) {
      var stamp = Date.parse(message.sentAt);
      return (!groupId || message.groupId === groupId) && (!senderId || message.senderId === senderId) && message.text.toLocaleLowerCase().includes(query) && stamp >= from && stamp <= to;
    }).slice().sort(function (a, b) { return Date.parse(a.sentAt) - Date.parse(b.sentAt); });
  }
  function selectedMessages(state, messageIds) {
    array(messageIds, '选中消息');
    var byKey = new Map(state.messages.map(function (message) { return [messageKey(message), message]; }));
    var chosen = new Set();
    var messages = [];
    messageIds.forEach(function (key) {
      id(key, '消息复合 id');
      if (chosen.has(key)) return;
      var message = byKey.get(key);
      if (!message) fail('选中的本地消息不存在：' + key);
      chosen.add(key);
      messages.push(clone(message));
    });
    return messages;
  }
  function createCollection(state, params) {
    writable(state);
    object(params, '资料集参数');
    var name = string(params.name, '资料集名称', false).trim();
    var messages = selectedMessages(state, params.messageIds);
    if (!messages.length) fail('请先选择消息');
    var collection = { id: newId(state, 'collection'), accountId: state.accountId, name: name, createdAt: nowISO(params.now), messageIds: messages.map(messageKey), messages: messages, discussionId: null };
    state.collections.push(collection);
    state.revision++;
    return collection;
  }
  function collectionsFor(state, collectionIds) {
    array(collectionIds, '收藏选择');
    var byId = new Map(state.collections.map(function (collection) { return [collection.id, collection]; }));
    var seen = new Set(), result = [];
    collectionIds.forEach(function (value) {
      id(value, '收藏 id');
      if (!byId.has(value)) fail('收藏不存在，请刷新列表后重试');
      if (!seen.has(value)) { seen.add(value); result.push(byId.get(value)); }
    });
    return result;
  }
  function removeCollections(state, collectionIds, now) {
    writable(state);
    var selected = collectionsFor(state, collectionIds).filter(function (collection) { return !collection.deletedAt; });
    var deletedAt = nowISO(now);
    selected.forEach(function (collection) { collection.deletedAt = deletedAt; });
    if (selected.length) state.revision++;
    return selected;
  }
  function restoreCollections(state, collectionIds) {
    writable(state);
    var selected = collectionsFor(state, collectionIds).filter(function (collection) { return !!collection.deletedAt; });
    selected.forEach(function (collection) { collection.deletedAt = null; });
    if (selected.length) state.revision++;
    return selected;
  }
  function discussionsFor(state, discussionIds) {
    array(discussionIds, '讨论选择');
    var byId = new Map(state.discussions.map(function (discussion) { return [discussion.id, discussion]; }));
    var seen = new Set(), result = [];
    for (var index = 0; index < discussionIds.length; index++) {
      var value = id(discussionIds[index], '讨论 id');
      if (!byId.has(value)) fail('讨论不存在，请刷新列表后重试');
      if (!seen.has(value)) { seen.add(value); result.push(byId.get(value)); }
    }
    return result;
  }
  function deleteDiscussions(state, discussionIds, now) {
    writable(state);
    var requested = discussionsFor(state, discussionIds);
    var selected = requested.filter(function (discussion) { return !discussion.deletedAt; });
    var deletedAt = nowISO(now);
    var clearActive = requested.some(function (discussion) { return discussion.id === state.settings.activeDiscussionId; });
    selected.forEach(function (discussion) { discussion.deletedAt = deletedAt; });
    if (clearActive) state.settings.activeDiscussionId = null;
    if (selected.length || clearActive) state.revision++;
    return selected;
  }
  function restoreDiscussions(state, discussionIds) {
    writable(state);
    var selected = discussionsFor(state, discussionIds).filter(function (discussion) { return !!discussion.deletedAt; });
    selected.forEach(function (discussion) { discussion.deletedAt = null; });
    if (selected.length) state.revision++;
    return selected;
  }
  function buildContext(state, messageIds) {
    validateState(state, false);
    var messages = selectedMessages(state, messageIds);
    var text = messages.map(function (message) {
      var group = state.groups.find(function (entry) { return entry.id === message.groupId; });
      var header = '[' + messageKey(message) + '] 群：' + (group ? group.name : message.groupId) + ' | 成员：' + message.senderName + ' (' + message.senderId + ') | 时间：' + message.sentAt;
      return header + '\n' + message.text + (message.attachments.length ? '\n附件：' + JSON.stringify(message.attachments) : '') + (message.sourceURL ? '\n来源：' + message.sourceURL : '');
    }).join('\n\n');
    return { messages: messages, text: text };
  }

  return { createState: createState, normalizeState: normalizeState, messageKey: messageKey, upsertGroups: upsertGroups, selectGroup: selectGroup, ingestMessages: ingestMessages, addBookmark: addBookmark, removeBookmark: removeBookmark, restoreBookmark: restoreBookmark, setProgress: setProgress, findMembers: findMembers, searchMessages: searchMessages, createCollection: createCollection, removeCollections: removeCollections, restoreCollections: restoreCollections, deleteDiscussions: deleteDiscussions, restoreDiscussions: restoreDiscussions, buildContext: buildContext };
});
