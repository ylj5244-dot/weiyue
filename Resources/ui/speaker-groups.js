(function (root, factory) {
  'use strict';
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.ReaderSpeakerGroups = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';
  var PALETTE_SIZE = 3;
  function identifier(value) { return typeof value === 'string' && value.trim() ? value : null; }
  function sender(message) {
    var value = message && identifier(message.senderId);
    return value && !/^(?:unknown(?:[:\s]|$)|null$|undefined$|0$)/i.test(value) ? value : null;
  }
  function localDay(value) {
    var date = new Date(value);
    return Number.isFinite(date.getTime()) ? date.getFullYear() + '-' + date.getMonth() + '-' + date.getDate() : null;
  }
  function canJoin(previous, current, dayKey) {
    if (!previous || !current || !sender(previous) || sender(previous) !== sender(current)) return false;
    if (!identifier(previous.accountId) || previous.accountId !== current.accountId || !identifier(previous.groupId) || previous.groupId !== current.groupId) return false;
    if (!Number.isFinite(Date.parse(previous.sentAt)) || !Number.isFinite(Date.parse(current.sentAt))) return false;
    var day = dayKey || localDay, before = day(previous.sentAt), after = day(current.sentAt);
    return typeof before === 'string' && !!before && before === after;
  }
  function tone(blockIndex) {
    return Number.isInteger(blockIndex) && blockIndex >= 0 ? blockIndex % PALETTE_SIZE : 0;
  }
  function describe(message, previous, next, dayKey) {
    var before = canJoin(previous,message,dayKey), after = canJoin(message,next,dayKey);
    return {tone:0,position:before ? (after ? 'middle' : 'end') : (after ? 'start' : 'single'),continuation:before};
  }
  function describeAll(messages, dayKey) {
    // Count blocks and individual records before virtual windowing. Filtering or
    // inserting records can change every later block or record tone.
    var blockIndex = -1, before = false, day = dayKey || localDay, days = new Map();
    function cachedDay(value) {
      if (!days.has(value)) days.set(value,day(value));
      return days.get(value);
    }
    return messages.map(function (message, index) {
      // The previous row already evaluated our left boundary. Cache date keys
      // only for this call so a later filter, edit or timezone change is fresh.
      var after = canJoin(message,messages[index + 1],cachedDay);
      if (!before) blockIndex++;
      var description = {tone:tone(blockIndex),messageTone:tone(index),position:before ? (after ? 'middle' : 'end') : (after ? 'start' : 'single'),continuation:before};
      before = after;
      return description;
    });
  }
  return {canJoin:canJoin,tone:tone,describe:describe,describeAll:describeAll,PALETTE_SIZE:PALETTE_SIZE};
});
