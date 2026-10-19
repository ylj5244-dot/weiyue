(function (root, factory) {
  'use strict';
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.ReaderPerformance = api;
})(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';

  // Prefix sums with logarithmic updates let images change a row's height
  // without measuring or walking thousands of offscreen message elements.
  class HeightIndex {
    constructor(heights) {
      this.values = heights.map(value => Math.max(1, Number(value) || 1));
      this.tree = new Float64Array(heights.length + 1);
      this.values.forEach((value, index) => this.add(index, value));
    }
    add(index, delta) { for (let i = index + 1; i < this.tree.length; i += i & -i) this.tree[i] += delta; }
    update(index, value) {
      value = Math.max(1, Number(value) || 1);
      const difference = value - this.values[index];
      if (Math.abs(difference) < 0.5) return false;
      this.values[index] = value; this.add(index, difference); return true;
    }
    offset(end) { let value = 0; for (let i = Math.min(end, this.values.length); i > 0; i -= i & -i) value += this.tree[i]; return value; }
    total() { return this.offset(this.values.length); }
    indexAt(offset) {
      if (!this.values.length) return 0;
      offset = Math.max(0, offset); let index = 0, sum = 0;
      let bit = 1; while (bit * 2 < this.tree.length) bit *= 2;
      for (; bit; bit >>= 1) { const next = index + bit; if (next < this.tree.length && sum + this.tree[next] <= offset) { index = next; sum += this.tree[next]; } }
      return Math.min(index, this.values.length - 1);
    }
    range(top, height, overscan = 700) {
      if (!this.values.length) return { start: 0, end: 0 };
      const start = this.indexAt(Math.max(0, top - overscan));
      const end = Math.min(this.values.length, this.indexAt(Math.max(0, top + height + overscan - 0.01)) + 1);
      return { start, end };
    }
  }

  // Indexed reads consume already validated messages; persistence and ingestion
  // keep the model's full validation boundary. Searches still cover every row.
  class ArchiveIndex {
    constructor(messages) {
      this.source = messages; this.count = messages.length; this.groups = new Map(); this.byKey = new Map();
      this.all = messages.slice().sort((a, b) => Date.parse(a.sentAt) - Date.parse(b.sentAt));
      this.stamps = new WeakMap();
      for (const message of this.all) {
        if (!this.groups.has(message.groupId)) this.groups.set(message.groupId, []);
        this.groups.get(message.groupId).push(message); this.byKey.set(message.groupId + ':' + message.id, message);
        this.stamps.set(message, Date.parse(message.sentAt));
      }
    }
    forGroup(groupId) { return this.groups.get(groupId) || []; }
    find(groupId, id) { return this.byKey.get(groupId + ':' + id); }
    search(filters = {}) {
      const messages = filters.groupId ? this.forGroup(filters.groupId) : this.all;
      const query = String(filters.query || '').toLocaleLowerCase();
      const from = filters.from ? Date.parse(filters.from) : -Infinity, to = filters.to ? Date.parse(filters.to) : Infinity;
      if (Number.isNaN(from) || Number.isNaN(to) || from > to) throw new Error('搜索时间范围无效');
      if (!query && !filters.senderId && from === -Infinity && to === Infinity) return messages;
      return messages.filter(message => (!filters.senderId || message.senderId === filters.senderId) && (!query || message.text.toLocaleLowerCase().includes(query)) && this.stamps.get(message) >= from && this.stamps.get(message) <= to);
    }
  }

  // At most one operation in flight and one latest pending operation per account.
  // Every caller resolves only after the version covering its request is durable.
  class CoalescedQueue {
    constructor() { this.pending = new Map(); this.running = false; this.timer = null; }
    request(key, work, delay = 0) {
      const promise = new Promise((resolve, reject) => {
        const item = this.pending.get(key) || { waiters: [] };
        item.work = work; item.waiters.push({ resolve, reject }); this.pending.set(key, item);
      });
      if (!this.running) {
        if (this.timer !== null && delay === 0) { clearTimeout(this.timer); this.timer = null; }
        if (this.timer === null) this.timer = setTimeout(() => { this.timer = null; this.drain(); }, delay);
      }
      return promise;
    }
    async drain() {
      if (this.running) return; this.running = true;
      while (this.pending.size) {
        const [key, item] = this.pending.entries().next().value; this.pending.delete(key);
        try { const result = await item.work(); item.waiters.forEach(waiter => waiter.resolve(result)); }
        catch (error) { item.waiters.forEach(waiter => waiter.reject(error)); }
      }
      this.running = false;
    }
  }

  class VirtualList {
    constructor({ scroll, content, keyFor, createRow, onRendered, cacheTokenFor }) {
      this.scroll = scroll; this.content = content; this.keyFor = keyFor; this.createRow = createRow; this.onRendered = onRendered; this.cacheTokenFor = cacheTokenFor;
      this.items = []; this.positions = new Map(); this.nodes = new Map(); this.measured = new Map(); this.heights = new HeightIndex([]);
      this.top = document.createElement('div'); this.bottom = document.createElement('div');
      for (const spacer of [this.top, this.bottom]) { spacer.className = 'reader-spacer'; spacer.setAttribute('aria-hidden', 'true'); }
      this.frame = 0; this.width = 0; this.target = null; this.pendingScrollTop = null; this.lastAnchor = null; this.lastScrollTop = 0; this.needsMeasure = true;
      this.resizeObserver = new ResizeObserver(() => { this.needsMeasure = true; this.schedule(); }); this.resizeObserver.observe(scroll);
      scroll.addEventListener('scroll', () => { this.target = null; this.schedule(); }, { passive: true });
    }
    estimate(message) { return Math.min(700, 64 + Math.ceil((message.text || '').length / Math.max(25, (this.scroll.clientWidth - 120) / 7)) * 19 + ((message.attachments || []).length ? 200 : 0)); }
    visibleAnchor() {
      if (!this.scroll.clientHeight || !this.nodes.size) return null;
      const top = this.scroll.getBoundingClientRect().top;
      for (const row of this.nodes.values()) {
        const card = row.querySelector('.message-card'); if (!card) continue;
        const box = card.getBoundingClientRect();
        if (box.bottom > top + 15 && box.top < top + this.scroll.clientHeight) return { key: row._readerKey, offset: Math.max(0, top - box.top), visualOffset: top - box.top, accountId: card.dataset.accountId, groupId: card.dataset.groupId, messageId: card.dataset.messageId };
      }
      return null;
    }
    setItems(items, { anchor = null, scrollTop = 0 } = {}) {
      this.items = items; this.positions = new Map(items.map((item, index) => [this.keyFor(item), index]));
      this.heights = new HeightIndex(items.map(item => this.measured.get(this.keyFor(item)) || this.estimate(item)));
      // Clear elements even when keys coincide after an account change. The
      // account is included in keyFor, and object identity protects edited rows.
      if (anchor && this.positions.has(anchor.key)) { this.target = anchor; this.pendingScrollTop = null; }
      else { this.target = null; this.pendingScrollTop = Math.max(0, scrollTop); }
      this.render(true);
    }
    clear() {
      this.items = []; this.positions.clear(); this.nodes.forEach(row => this.resizeObserver.unobserve(row)); this.nodes.clear(); this.target = null; this.pendingScrollTop = null; this.lastAnchor = null;
      this.heights = new HeightIndex([]); this.content.replaceChildren();
    }
    schedule() { if (!this.frame) this.frame = requestAnimationFrame(() => { this.frame = 0; this.render(); }); }
    render(force = false) {
      if (!this.items.length || !this.scroll.clientHeight) return;
      const width = this.scroll.clientWidth;
      if (this.width && Math.abs(width - this.width) > 1) {
        if (!this.target && this.pendingScrollTop === null) this.target = this.lastAnchor || this.visibleAnchor();
        this.measured.clear();
        this.heights = new HeightIndex(this.items.map(item => this.estimate(item))); force = true;
      }
      this.width = width;
      let preserved = this.target;
      if (!preserved && this.pendingScrollTop === null) preserved = Math.abs(this.scroll.scrollTop - this.lastScrollTop) < 0.5 && this.lastAnchor && this.positions.has(this.lastAnchor.key) ? this.lastAnchor : this.visibleAnchor();
      let requestedTop = this.pendingScrollTop;
      if (this.target) { const position = this.positions.get(this.target.key); if (position !== undefined) requestedTop = this.heights.offset(position) + this.target.offset; }
      const initialRange = this.heights.range(requestedTop === null ? this.scroll.scrollTop : requestedTop, this.scroll.clientHeight);
      if (!force && !this.needsMeasure && requestedTop === null && this.start === initialRange.start && this.end === initialRange.end) {
        this.lastAnchor = this.visibleAnchor(); this.lastScrollTop = this.scroll.scrollTop; return;
      }
      let changed = false;
      // A bounded second pass covers ranges exposed when estimates become real.
      for (let pass = 0; pass < 2; pass++) {
        const passScrollTop = requestedTop === null ? this.scroll.scrollTop : requestedTop;
        const range = this.heights.range(passScrollTop, this.scroll.clientHeight);
        let replaced = false;
        if (force || this.start !== range.start || this.end !== range.end) {
          this.start = range.start; this.end = range.end; const nodes = new Map(), fragment = document.createDocumentFragment(); fragment.append(this.top);
          for (let index = range.start; index < range.end; index++) {
            const item = this.items[index], key = this.keyFor(item), previous = this.items[index - 1], next = this.items[index + 1]; let row = this.nodes.get(key);
            // Sequence-derived presentation can change even when this row and
            // both neighbours retain identity (for example after prepending).
            const cacheToken = this.cacheTokenFor ? this.cacheTokenFor(item, index) : undefined;
            if (!row || row._readerItem !== item || row._readerPrevious !== previous || row._readerNext !== next || row._readerCacheToken !== cacheToken) {
              if (row) this.resizeObserver.unobserve(row);
              row = document.createElement('div'); row.className = 'reader-virtual-row'; row._readerKey = key; row._readerItem = item; row._readerPrevious = previous; row._readerNext = next; row._readerCacheToken = cacheToken;
              row.append(...this.createRow(item, index)); this.resizeObserver.observe(row);
            }
            nodes.set(key, row); fragment.append(row);
          }
          this.nodes.forEach((row, key) => { if (!nodes.has(key)) this.resizeObserver.unobserve(row); });
          this.nodes = nodes; fragment.append(this.bottom); this.content.replaceChildren(fragment); changed = true; replaced = true;
        }
        this.top.style.height = this.heights.offset(range.start) + 'px'; this.bottom.style.height = (this.heights.total() - this.heights.offset(range.end)) + 'px';
        // Moving retained rows into the fragment temporarily empties the content.
        // WebKit clamps scrollTop immediately, even before the next layout read.
        // Restore every pass, not only explicit bookmark jumps.
        if (replaced || requestedTop !== null) this.scroll.scrollTop = passScrollTop;
        if (requestedTop !== null) { requestedTop = null; this.pendingScrollTop = null; }
        if (!preserved) preserved = this.visibleAnchor();
        let measured = false;
        // Layout reads are batched before the spacer writes / anchor adjustment.
        const sizes = Array.from(this.nodes, ([key, row]) => [key, row.getBoundingClientRect().height]);
        sizes.forEach(([key, height]) => { if (height > 0) { this.measured.set(key, height); measured = this.heights.update(this.positions.get(key), height) || measured; } });
        if (measured) {
          this.top.style.height = this.heights.offset(range.start) + 'px'; this.bottom.style.height = (this.heights.total() - this.heights.offset(range.end)) + 'px';
          if (preserved) this.align(preserved);
        } else if (this.target) this.align(this.target);
        force = false;
      }
      this.target = null; this.needsMeasure = false; this.lastAnchor = this.visibleAnchor(); this.lastScrollTop = this.scroll.scrollTop;
      if (changed && this.onRendered) this.onRendered();
    }
    align(anchor) {
      const row = this.nodes.get(anchor.key), card = row && row.querySelector('.message-card');
      if (card) this.scroll.scrollTop += card.getBoundingClientRect().top - this.scroll.getBoundingClientRect().top + (Number.isFinite(anchor.visualOffset) ? anchor.visualOffset : anchor.offset);
    }
    scrollTo(key, offset = 0) {
      if (!this.positions.has(key)) return false;
      this.target = { key, offset }; this.render(true);
      // Rendering can update estimates; align to the actual message, not the
      // surrounding date separator. Subsequent image resizes preserve this row.
      this.align({ key, offset }); return true;
    }
    card(key) { const row = this.nodes.get(key); return row ? row.querySelector('.message-card') : null; }
  }
  return { HeightIndex, ArchiveIndex, CoalescedQueue, VirtualList };
});
