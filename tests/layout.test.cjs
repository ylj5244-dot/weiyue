'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const layout = require('../Resources/ui/layout.js');

test('desktop gives the reader the remaining width', () => {
  const result = layout.resolveLayout(1440, layout.defaults);
  assert.equal(result.sidebarWidth, 220); assert.equal(result.inspectorWidth, 330); assert.equal(result.centerWidth, 878);
});
test('oversized saved panes are clamped without stealing the reading minimum', () => {
  const result = layout.resolveLayout(1000, { sidebarWidth: 380, inspectorWidth: 620 });
  assert.equal(result.centerWidth, 430); assert.ok(result.sidebarWidth >= 188); assert.ok(result.inspectorWidth >= 280);
  assert.equal(result.sidebarWidth + result.inspectorWidth + result.centerWidth + 12, 1000);
});
test('narrow windows temporarily collapse secondary panes without overwriting preferences', () => {
  const saved = { ...layout.defaults, sidebarWidth: 280, inspectorWidth: 400 };
  const narrow = layout.resolveLayout(850, saved), restored = layout.resolveLayout(1440, saved);
  assert.equal(narrow.sidebarCollapsed, true); assert.equal(narrow.inspectorCollapsed, false); assert.ok(narrow.centerWidth >= 430);
  assert.equal(restored.sidebarCollapsed, false); assert.equal(restored.sidebarWidth, 280); assert.equal(restored.inspectorWidth, 400);
});
test('small windows always retain the main reading pane', () => {
  for (const width of [0, 320, 500, 640, 715]) {
    const result = layout.resolveLayout(width, layout.defaults);
    assert.equal(result.sidebarCollapsed, true); assert.equal(result.inspectorCollapsed, true); assert.equal(result.centerWidth, width);
  }
});
test('a deliberately collapsed inspector leaves space for the sidebar', () => {
  const result = layout.resolveLayout(800, { inspectorCollapsed: true, sidebarWidth: 260 });
  assert.equal(result.sidebarCollapsed, false); assert.equal(result.inspectorCollapsed, true); assert.equal(result.centerWidth, 534);
});
test('saved collapsed state survives wide-window restoration', () => {
  const saved = layout.readPreferences(JSON.parse(JSON.stringify({ ...layout.defaults, sidebarCollapsed: true, inspectorCollapsed: true })));
  const result = layout.resolveLayout(1900, saved);
  assert.equal(result.centerWidth, 1900); assert.equal(result.sidebarCollapsed, true); assert.equal(result.inspectorCollapsed, true);
});
test('untrusted or corrupted UI preferences cannot create nonfinite or negative sizes', () => {
  for (const saved of [null, [], 'wrong', { sidebarWidth: NaN, inspectorWidth: Infinity }, { sidebarWidth: -50, inspectorWidth: 1e6, inspectorCollapsed: 'true' }]) {
    const result = layout.resolveLayout(1280, saved);
    for (const value of Object.values(result)) if (typeof value === 'number') assert.ok(Number.isFinite(value) && value >= 0);
    assert.ok(result.centerWidth >= 430);
  }
});
test('pane bounds stay inside all viewport sizes and collapse combinations', () => {
  for (let width = 300; width <= 2000; width += 17) for (const left of [false, true]) for (const right of [false, true]) {
    const result = layout.resolveLayout(width, { sidebarCollapsed: left, inspectorCollapsed: right, sidebarWidth: 380, inspectorWidth: 620 });
    const total = result.centerWidth + result.sidebarWidth + result.inspectorWidth + (result.sidebarCollapsed ? 0 : 6) + (result.inspectorCollapsed ? 0 : 6);
    assert.equal(total, width); assert.ok(result.centerWidth >= Math.min(width, 430));
  }
});
test('content minima override narrower saved panes without rewriting preferences', () => {
  const saved = { sidebarWidth: 188, inspectorWidth: 280, sidebarCollapsed: false, inspectorCollapsed: false };
  const original = { ...saved };
  const result = layout.resolveLayout(1440, saved, { sidebarMin: 220, centerMin: 500, inspectorMin: 320 });
  assert.equal(result.sidebarWidth, 220); assert.equal(result.inspectorWidth, 320);
  assert.equal(result.sidebarMin, 220); assert.equal(result.inspectorMin, 320); assert.equal(result.centerMin, 500);
  assert.equal(result.minimumThreePaneWidth, 1052);
  assert.deepEqual(saved, original);
});
test('both divider limits reserve the content minimum of the reader and opposite pane', () => {
  const minima = { sidebarMin: 220, centerMin: 500, inspectorMin: 320 };
  const saved = { sidebarWidth: 240, inspectorWidth: 340 };
  const result = layout.resolveLayout(1200, saved, minima);
  assert.equal(result.sidebarMax, 348); assert.equal(result.inspectorMax, 448);
  for (const side of ['sidebar', 'inspector']) {
    const atLimit = layout.resolveLayout(1200, { ...saved, [side + 'Width']: result[side + 'Max'] }, minima);
    assert.equal(atLimit.centerWidth, 500);
    assert.equal(atLimit[side === 'sidebar' ? 'inspectorWidth' : 'sidebarWidth'], side === 'sidebar' ? saved.inspectorWidth : saved.sidebarWidth);
    assert.equal(layout.clamp(-999, result[side + 'Min'], result[side + 'Max']), minima[side + 'Min']);
  }
});
test('responsive collapse follows content minima exactly and restores saved widths', () => {
  const minima = { sidebarMin: 220, centerMin: 500, inspectorMin: 320 };
  const saved = { sidebarWidth: 300, inspectorWidth: 440 };
  const fit = layout.resolveLayout(1052, saved, minima), below = layout.resolveLayout(1051, saved, minima);
  assert.equal(fit.sidebarCollapsed, false); assert.equal(fit.inspectorCollapsed, false); assert.equal(fit.centerWidth, 500);
  assert.equal(below.sidebarCollapsed, true); assert.equal(below.inspectorCollapsed, false); assert.ok(below.centerWidth >= 500);
  assert.equal(layout.resolveLayout(826, saved, minima).inspectorCollapsed, false);
  assert.equal(layout.resolveLayout(825, saved, minima).inspectorCollapsed, true);
  const restored = layout.resolveLayout(1600, saved, minima);
  assert.equal(restored.sidebarWidth, 300); assert.equal(restored.inspectorWidth, 440);
});
test('a user-collapsed pane gives its space to remaining panes with content minima', () => {
  const minima = { sidebarMin: 220, centerMin: 500, inspectorMin: 320 };
  const fit = layout.resolveLayout(726, { inspectorCollapsed: true }, minima);
  assert.equal(fit.sidebarCollapsed, false); assert.equal(fit.inspectorCollapsed, true);
  assert.equal(fit.sidebarWidth, 220); assert.equal(fit.centerWidth, 500);
  const below = layout.resolveLayout(725, { inspectorCollapsed: true }, minima);
  assert.equal(below.sidebarCollapsed, true); assert.equal(below.centerWidth, 725);
});
test('content minima respect policy floors and bounded side widths', () => {
  const result = layout.resolveLayout(1600, layout.defaults, { sidebarMin: 99999, centerMin: -20, inspectorMin: Infinity });
  assert.equal(result.sidebarMin, 380); assert.equal(result.centerMin, 430); assert.equal(result.inspectorMin, 280);
  assert.equal(result.sidebarWidth, 380); assert.ok(result.sidebarMax >= result.sidebarMin);
  for (const minima of [null, [], 'wrong', { sidebarMin: '220px', centerMin: NaN, inspectorMin: -300 }]) {
    const fallback = layout.resolveLayout(1440, layout.defaults, minima);
    assert.equal(fallback.sidebarMin, 188); assert.equal(fallback.centerMin, 430); assert.equal(fallback.inspectorMin, 280);
  }
});
test('content-aware layouts fit all window sizes and collapse combinations', () => {
  for (const minima of [{ sidebarMin: 220, centerMin: 500, inspectorMin: 320 }, { sidebarMin: 280, centerMin: 600, inspectorMin: 380 }]) {
    for (let width = 0; width <= 2000; width += 17) for (const left of [false, true]) for (const right of [false, true]) {
      const result = layout.resolveLayout(width, { sidebarCollapsed: left, inspectorCollapsed: right, sidebarWidth: 380, inspectorWidth: 620 }, minima);
      const total = result.centerWidth + result.sidebarWidth + result.inspectorWidth + (result.sidebarCollapsed ? 0 : 6) + (result.inspectorCollapsed ? 0 : 6);
      assert.equal(total, width); assert.ok(result.centerWidth >= Math.min(width, minima.centerMin));
      for (const side of ['sidebar', 'inspector']) {
        if (!result[side + 'Collapsed']) assert.ok(result[side + 'Width'] >= minima[side + 'Min']);
        assert.ok(result[side + 'Max'] >= result[side + 'Min']);
      }
    }
  }
});
test('bookmark labels retain year month day and time', () => {
  assert.match(layout.formatDate('2026-10-18T12:34:00'), /^2026\.10\.18 12:34$/);
  assert.equal(layout.formatDate('invalid'), '时间未知');
});

// Run the actual event handlers with a small DOM adapter; pixel geometry and
// CSS wrapping are covered by the WKWebView integration harness.
function interactiveLayout({ width = 1440, preferences = layout.defaults } = {}) {
  const elements = new Map(), saved = new Map([['weiyue.pane-layout.v1', JSON.stringify(preferences)]]);
  const css = { '--sidebar-min-width': '220px', '--reader-min-width': '560px', '--inspector-min-width': '320px' };
  let resize;
  function element() {
    const listeners = new Map(), classes = new Set(), attributes = new Map(), styles = new Map();
    return {
      dataset: {}, attributes, styles, hidden: false,
      style: { setProperty: (name, value) => styles.set(name, value), removeProperty: name => styles.delete(name) },
      classList: { toggle: (name, enabled) => enabled ? classes.add(name) : classes.delete(name), add: name => classes.add(name), remove: name => classes.delete(name) },
      setAttribute: (name, value) => attributes.set(name, value),
      addEventListener: (name, callback) => { if (!listeners.has(name)) listeners.set(name, []); listeners.get(name).push(callback); },
      dispatch(name, event = {}) { for (const callback of listeners.get(name) || []) callback({ preventDefault() {}, button: 0, pointerId: 1, clientX: 0, ...event }); },
      focus() {}, setPointerCapture() {}, hasPointerCapture() { return false; }, replaceChildren() {},
      getBoundingClientRect: () => ({ width })
    };
  }
  const get = id => { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); };
  const events = [];
  const win = {
    localStorage: { getItem: key => saved.get(key), setItem: (key, value) => saved.set(key, value) },
    getComputedStyle: () => ({ getPropertyValue: name => css[name] || '' }),
    addEventListener() {}, dispatchEvent: event => events.push(event)
  };
  const context = { window: win, document: { getElementById: get, querySelector: () => get('workspace'), body: element() }, CustomEvent: class { constructor(type, options) { this.type = type; this.detail = options.detail; } }, ResizeObserver: class { constructor(callback) { resize = callback; } observe() {} } };
  vm.runInNewContext(fs.readFileSync(require.resolve('../Resources/ui/layout.js'), 'utf8'), context);
  return { get, css, events, api: win.ReaderLayout, resize: value => { width = value; resize(); }, saved: () => JSON.parse(saved.get('weiyue.pane-layout.v1')) };
}

test('installed layout reads CSS minima for geometry and accessible divider limits', () => {
  const f = interactiveLayout(), state = f.api.getState();
  assert.equal(state.centerMin, 560); assert.equal(state.minimumThreePaneWidth, 1112);
  for (const side of ['sidebar', 'inspector']) assert.equal(f.get(side + '-divider').attributes.get('aria-valuemin'), String(state[side + 'Min']));
  f.css['--reader-min-width'] = '600px'; f.api.refresh();
  assert.equal(f.api.getState().centerMin, 600);
});
test('pointer and keyboard resizing stop at content limits while preserving the opposite pane', () => {
  const f = interactiveLayout({ width: 1280, preferences: { sidebarWidth: 380, inspectorWidth: 620 } });
  const before = f.api.getState();
  const right = f.get('inspector-divider');
  right.dispatch('pointerdown'); right.dispatch('pointermove', { clientX: 5000 }); right.dispatch('pointerup');
  const after = f.api.getState();
  assert.equal(after.inspectorWidth, 320); assert.equal(after.sidebarWidth, before.sidebarWidth);
  assert.ok(after.centerWidth >= 560); assert.equal(f.saved().inspectorWidth, 320);
  const left = f.get('sidebar-divider');
  left.dispatch('keydown', { key: 'ArrowRight', shiftKey: true });
  assert.equal(f.api.getState().sidebarWidth, before.sidebarWidth + 48);
  for (let i = 0; i < 20; i++) left.dispatch('keydown', { key: 'ArrowLeft', shiftKey: true });
  assert.equal(f.api.getState().sidebarWidth, 220); assert.equal(f.api.getState().inspectorWidth, 320);
  f.css['--sidebar-min-width'] = '250px'; f.api.refresh();
  left.dispatch('keydown', { key: 'Home' });
  assert.equal(f.api.getState().sidebarWidth, 250); assert.equal(f.saved().sidebarWidth, 250);
});
test('dragging to either upper bound cannot consume the reading minimum', () => {
  for (const side of ['sidebar', 'inspector']) {
    const f = interactiveLayout({ width: 1200 });
    const before = f.api.getState(), divider = f.get(side + '-divider');
    divider.dispatch('pointerdown'); divider.dispatch('pointermove', { clientX: side === 'sidebar' ? 5000 : -5000 }); divider.dispatch('pointerup');
    const after = f.api.getState();
    assert.equal(after[side + 'Width'], before[side + 'Max']); assert.equal(after.centerWidth, 560);
    const opposite = side === 'sidebar' ? 'inspector' : 'sidebar';
    assert.equal(after[opposite + 'Width'], before[opposite + 'Width']);
  }
});
test('revealing a pane uses the content-aware narrow-window threshold', () => {
  const f = interactiveLayout({ width: 1000 });
  assert.equal(f.api.getState().sidebarCollapsed, true); assert.equal(f.api.getState().inspectorCollapsed, false);
  f.api.reveal('sidebar');
  assert.equal(f.api.getState().sidebarCollapsed, false); assert.equal(f.api.getState().inspectorCollapsed, true);
  f.api.reveal('inspector');
  assert.equal(f.api.getState().sidebarCollapsed, true); assert.equal(f.api.getState().inspectorCollapsed, false);
});
test('window resize never persists temporary pane reductions or automatic collapse', () => {
  const preferences = { sidebarWidth: 280, inspectorWidth: 440, sidebarCollapsed: false, inspectorCollapsed: false };
  const f = interactiveLayout({ width: 1600, preferences });
  f.resize(900);
  assert.equal(f.api.getState().sidebarCollapsed, true); assert.equal(f.api.getState().inspectorCollapsed, false);
  assert.equal(f.api.getState().inspectorWidth, 334); assert.equal(f.api.getState().centerWidth, 560);
  f.resize(880); assert.equal(f.api.getState().inspectorCollapsed, true);
  f.resize(1600); assert.equal(f.api.getState().sidebarWidth, 280); assert.equal(f.api.getState().inspectorWidth, 440);
  assert.deepEqual(f.saved(), preferences); assert.equal(f.events.filter(event => event.type === 'weiyue:layout-save').length, 0);
});
