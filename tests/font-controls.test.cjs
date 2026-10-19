'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

// Exercise the application's real listeners, including validation and persistence.
const source = fs.readFileSync(require.resolve('../Resources/ui/app.js'), 'utf8');
const start = source.indexOf('  const aiFontSizes = ');
const end = source.indexOf("  $('clear-selection').addEventListener", start);
assert.ok(start >= 0 && end > start, 'font control bindings are available');
const bindings = source.slice(start, end);
function fixture() {
  const nodes = new Map(), properties = new Map(), calls = { saves: 0, settles: 0, mutations: 0, anchors: [] };
  const get = id => {
    if (!nodes.has(id)) nodes.set(id, { value: '14', disabled: false, listeners: {}, addEventListener(type, listener) { this.listeners[type] = listener; } });
    return nodes.get(id);
  };
  const conversation = get('conversation');
  Object.assign(conversation, { scrollHeight: 900, clientHeight: 300, scrollTop: 600, getBoundingClientRect: () => ({ top: 100 }), querySelectorAll: () => [] });
  const box = { $: get, state: { accountId: 'synthetic-A', settings: {} }, ready: true, loadFailed: false,
    document: { documentElement: { style: { setProperty: (name, value) => properties.set(name, value) } } },
    mutate: fn => { calls.mutations++; fn(); }, persistQuietly: () => { calls.saves++; },
    visibleMessage: () => ({ messageId: 'message-7', offset: 19 }), settleReading: () => { calls.settles++; },
    scrollToMessage: (...value) => calls.anchors.push(value), notify: () => {} };
  vm.createContext(box); vm.runInContext(bindings, box); box.applyAIFontSize();
  const change = (id, size) => { const node = get(id); node.value = String(size); node.listeners.change(); };
  return { box, get, properties, calls, change };
}

test('reader dropdown selects its own three sizes and preserves the visible reading anchor without changing AI settings', () => {
  const f = fixture();
  for (const size of [16, 18, 14]) {
    f.change('font-button', size);
    assert.equal(f.properties.get('--reader-size'), size + 'px');
    assert.equal(f.properties.get('--ai-reader-size'), '14px');
    assert.deepEqual(f.calls.anchors.at(-1), ['message-7', 19, false]);
  }
  assert.equal(f.calls.settles, 3);
  assert.equal(f.calls.saves, 0, 'reader control retains the existing session-only behavior');
  assert.deepEqual(f.box.state.settings, {});
  for (const size of [12, 20, 22, 'bogus']) {
    f.change('font-button', size);
    assert.equal(f.get('font-button').value, '14');
    assert.equal(f.properties.get('--reader-size'), '14px');
  }
  assert.equal(f.calls.settles, 3, 'invalid and unchanged sizes do not disturb the anchor');
});

test('AI dropdown keeps all five choices, saves only its own setting and restores each account independently', () => {
  const f = fixture(); f.change('font-button', 18);
  for (const size of [16, 18, 20, 22, 14]) {
    f.change('ai-font-size', size);
    assert.equal(f.box.state.settings.aiFontSize, size);
    assert.equal(f.properties.get('--ai-reader-size'), size + 'px');
    assert.equal(f.properties.get('--reader-size'), '18px');
  }
  assert.equal(f.calls.saves, 5);
  f.change('ai-font-size', 12);
  assert.equal(f.get('ai-font-size').value, '14');
  assert.equal(f.calls.saves, 5);
  const accountA = f.box.state;
  f.box.state = { accountId: 'synthetic-B', settings: { aiFontSize: 22 } }; f.box.applyAIFontSize();
  assert.equal(f.get('ai-font-size').value, '22');
  f.change('ai-font-size', 20);
  assert.equal(accountA.settings.aiFontSize, 14);
  f.box.state = accountA; f.box.applyAIFontSize();
  assert.equal(f.get('ai-font-size').value, '14');
});

test('AI dropdown remains disabled until ready and while logged out or after a load failure', () => {
  for (const change of [{ ready: false }, { loadFailed: true }, { state: { accountId: '', settings: { aiFontSize: 18 } } }]) {
    const f = fixture(); Object.assign(f.box, change); f.box.applyAIFontSize();
    assert.equal(f.get('ai-font-size').disabled, true);
    const previous = f.box.state.settings.aiFontSize;
    f.change('ai-font-size', 22);
    assert.equal(f.box.state.settings.aiFontSize, previous);
    assert.equal(f.calls.saves, 0, 'synthetic change events cannot bypass the lock');
  }
});

test('AI resizing keeps the viewport on its visible answer instead of jumping to the end', () => {
  const f = fixture(), conversation = f.get('conversation');
  conversation.scrollTop = 220;
  const anchor = { getBoundingClientRect: () => ({ top: f.box.state.settings.aiFontSize === 22 ? 140 : 125, bottom: 200 }) };
  conversation.querySelectorAll = () => [anchor];
  f.change('ai-font-size', 22);
  assert.equal(conversation.scrollTop, 235);
});
