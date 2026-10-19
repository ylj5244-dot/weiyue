/* Appearance is a workspace preference. It never modifies chat/account data. */
(function (root, factory) {
  'use strict';
  const policy = factory();
  if (typeof module === 'object' && module.exports) module.exports = policy;
  if (root) root.ReaderAppearancePolicy = policy;
  if (typeof document === 'undefined') return;
  const key = 'weiyue.appearance.v1';
  const media = root.matchMedia('(prefers-color-scheme: dark)');
  let preference = 'system', bound = false;
  try { preference = policy.normalize(root.localStorage.getItem(key)); } catch (_) {}
  function apply() {
    const effective = policy.effective(preference, media.matches);
    document.documentElement.dataset.colorScheme = effective;
    document.documentElement.dataset.appearance = preference;
    const select = document.getElementById('appearance-select');
    if (select) { select.value = preference; select.title = policy.label(preference) + ' · 切换日间、夜间或跟随系统'; }
    const symbol = document.getElementById('appearance-symbol');
    if (symbol) symbol.setAttribute('href', effective === 'dark' ? '#i-moon' : '#i-sun');
    return effective;
  }
  function set(value, persist) {
    preference = policy.normalize(value); apply();
    if (persist) {
      try { root.localStorage.setItem(key, preference); } catch (_) {}
      root.dispatchEvent(new CustomEvent('weiyue:appearance-save', {detail:{appearance:preference}}));
    }
  }
  root.ReaderAppearance = {
    restore(value) { set(value, false); },
    getPreference() { return preference; },
    getEffective() { return policy.effective(preference, media.matches); }
  };
  function bind() {
    if (bound) return; bound = true;
    const select = document.getElementById('appearance-select');
    if (select) select.addEventListener('change', () => set(select.value, true));
    apply();
  }
  media.addEventListener('change', apply);
  // Run in <head> before content paint to avoid a light flash in dark windows.
  apply();
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind, {once:true});
  else bind();
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';
  function normalize(value) { return ['system','light','dark'].includes(value) ? value : 'system'; }
  function effective(value, systemDark) { const chosen=normalize(value); return chosen === 'system' ? (systemDark ? 'dark' : 'light') : chosen; }
  function label(value) { return {system:'跟随系统',light:'日间',dark:'夜间'}[normalize(value)]; }
  return {normalize,effective,label};
});
