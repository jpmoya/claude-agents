// backlog[] — the "Backlog priority" reorder view (standalone, non-goal agent-go tickets; JP's
// stored priority rank, lowest first). Covers validate.js sanitisation, group.js's cross-host
// merge/sort, render.js's up/down reorder controls and inline same-origin <script>, and the
// POST /backlog-priority route (routes.test.js carries the full auth-gated request/response
// cases; this file only checks the keys this page would submit and its validation).

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { buildBacklog } from '../src/group.js';
import { renderPage } from '../src/render.js';
import { validPayload, validBacklogItem, hostRecord } from './fixtures.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-11-05T12:00:00Z') / 1000;

describe('validate.js — backlog[] sanitisation', () => {
  it('absent or non-array -> [], never a rejection', () => {
    for (const junk of [undefined, 'nope', 42, null, { a: 1 }]) {
      const r = validateBeatPayload(validPayload({ backlog: junk }));
      expect(r.ok).toBe(true);
      expect(r.value.backlog).toEqual([]);
    }
  });

  it('keeps repo/issue/title/url/rank; drops an item with an invalid issue', () => {
    const r = validateBeatPayload(
      validPayload({ backlog: [validBacklogItem({ rank: 0 }), { repo: 'project-a', issue: 'not-a-number' }] }),
    );
    expect(r.ok).toBe(true);
    expect(r.value.backlog).toEqual([validBacklogItem({ rank: 0 })]);
  });

  it('rank is optional and dropped when out of range or non-integer; the ticket is kept', () => {
    for (const bad of [-1, 1.5, 'zero', null]) {
      const r = validateBeatPayload(validPayload({ backlog: [validBacklogItem({ rank: bad })] }));
      const item = r.value.backlog[0];
      expect(item).toBeDefined();
      expect(item).not.toHaveProperty('rank');
    }
  });

  it('caps at 100 items', () => {
    const many = Array.from({ length: 150 }, (_, i) => validBacklogItem({ issue: i + 1, rank: i }));
    const r = validateBeatPayload(validPayload({ backlog: many }));
    expect(r.value.backlog).toHaveLength(100);
  });

  it('a hostile title/url never survives (same sanitisers as staging/approved)', () => {
    const r = validateBeatPayload(
      validPayload({ backlog: [validBacklogItem({ url: 'javascript:alert(1)', title: '<script>x</script>' })] }),
    );
    expect(r.value.backlog[0]).not.toHaveProperty('url');
    expect(r.value.backlog[0].title).toBe('<script>x</script>'.replace(/[\u0000-\u001f\u007f\s]+/g, ' ').trim());
  });
});

const urlFor = (n) => `https://github.com/example-owner/project-a/issues/${n}`;
const bi = (issue, overrides = {}) => validBacklogItem({ issue, url: urlFor(issue), ...overrides });

describe('group.js — buildBacklog: cross-host merge and order', () => {
  it('ranked items sort first (lowest rank), unranked after, keeping the host order', () => {
    const mac = hostRecord({
      backlog: [bi(30, { rank: 0 }), bi(20)],
    });
    const rows = buildBacklog({ mac, vm: null });
    expect(rows.map((r) => r.issue)).toEqual([30, 20]);
  });

  it('unranked tickets keep the host\'s own (milestone-first) order, never re-sorted by raw issue number', () => {
    // build-runs-json.py would have already put the v1.0.0 ticket (#50) before the no-milestone
    // one (#5) even though 50 > 5 -- buildBacklog must not undo that by sorting on .issue itself.
    const mac = hostRecord({ backlog: [bi(50), bi(5)] });
    const rows = buildBacklog({ mac, vm: null });
    expect(rows.map((r) => r.issue)).toEqual([50, 5]);
  });

  it('dedupes the same ticket seen from both hosts (same repo in both DISPATCH_REPOS)', () => {
    const item = bi(5, { rank: 2 });
    const mac = hostRecord({ backlog: [item] });
    const vm = hostRecord({ backlog: [item] });
    const rows = buildBacklog({ mac, vm });
    expect(rows).toHaveLength(1);
  });

  it('prefers the ranked copy over an unranked duplicate from the other host', () => {
    const mac = hostRecord({ backlog: [bi(5)] });
    const vm = hostRecord({ backlog: [bi(5, { rank: 1 })] });
    const rows = buildBacklog({ mac, vm });
    expect(rows[0].rank).toBe(1);
  });

  it('no data from either host -> []', () => {
    expect(buildBacklog({ mac: null, vm: null })).toEqual([]);
  });
});

describe('render.js — Backlog priority section', () => {
  it('renders a heading with the row count and a row per ticket', () => {
    const mac = hostRecord({
      backlog: [
        bi(11, { title: 'First', rank: 0 }),
        bi(12, { title: 'Second', rank: 1, url: 'https://github.com/example-owner/project-b/issues/12' }),
      ],
    });
    const html = renderPage({ mac, vm: null }, thresholds, NOW);
    expect(html).toMatch(/<h2[^>]*>\s*Backlog priority \(2\)\s*<\/h2>/);
    expect(html).toContain('<th>Repo</th>');
    expect(html).toContain('#11');
    expect(html).toContain('First');
    expect(html).toContain('data-label="Repo">example-owner/project-a<');
    expect(html).toContain('#12');
    expect(html).toContain('Second');
    expect(html).toContain('data-label="Repo">example-owner/project-b<');
  });

  it('the Repo column shows the real owner/repo from the url, never the sanitised alias (or "other")', () => {
    const mac = hostRecord({
      backlog: [bi(13, { repo: 'zz-alias', rank: 0 })],
    });
    const html = renderPage({ mac, vm: null }, thresholds, NOW);
    expect(html).toContain('data-label="Repo">example-owner/project-a<');
    expect(html).not.toContain('zz-alias');
    expect(html).not.toContain('data-label="Repo">other<');
  });

  it('an empty backlog renders "(0)" and "none"', () => {
    const html = renderPage({ mac: hostRecord({}), vm: null }, thresholds, NOW);
    expect(html).toMatch(/<h2[^>]*>\s*Backlog priority \(0\)\s*<\/h2>/);
    expect(html).toContain('<td colspan="5">none</td>');
  });

  it('escapes a hostile title (the page ships its own trusted reorder <script>, but never reflects data into one)', () => {
    const mac = hostRecord({ backlog: [validBacklogItem({ title: '<script>alert(1)</script>' })] });
    const html = renderPage({ mac, vm: null }, thresholds, NOW);
    expect(html).not.toContain('<script>alert(1)</script>');
    expect(html).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
  });

  it('a row with a parsable key is draggable, has a data-key attribute and a focusable drag handle', () => {
    const mac = hostRecord({
      backlog: [bi(30, { rank: 0 }), bi(20, { rank: 1 }), bi(10, { rank: 2 })],
    });
    const html = renderPage({ mac, vm: null }, thresholds, NOW);
    expect(html).toContain('data-key="example-owner/project-a#30"');
    expect(html).toContain('data-key="example-owner/project-a#20"');
    expect(html).toContain('data-key="example-owner/project-a#10"');
    // no more up/down buttons
    expect(html).not.toContain('bp-up');
    expect(html).not.toContain('bp-down');
    expect(html).not.toContain('data-dir=');
    // every row carries draggable="true" and a focusable handle
    expect(html).toMatch(/<tr draggable="true" data-key="example-owner\/project-a#30">/);
    expect(html).toMatch(/<tr draggable="true" data-key="example-owner\/project-a#20">/);
    expect(html).toMatch(/<tr draggable="true" data-key="example-owner\/project-a#10">/);
    expect(html.match(/class="bp-handle" tabindex="0" role="button"/g)).toHaveLength(3);
  });

  it('ships one inline, same-origin <script> (the reorder control) when there is a reorderable row', () => {
    const mac = hostRecord({ backlog: [bi(30, { rank: 0 })] });
    const html = renderPage({ mac, vm: null }, thresholds, NOW);
    expect(html).toMatch(/<script>/);
    expect(html).not.toMatch(/<script[^>]+\ssrc=/i);
    expect(html).toContain('/backlog-priority');
  });

  it('an empty backlog ships no <script> at all', () => {
    const html = renderPage({ mac: hostRecord({}), vm: null }, thresholds, NOW);
    expect(html).not.toMatch(/<script/i);
  });
});

describe('BACKLOG_REORDER_SCRIPT — drag-and-drop and keyboard reorder logic', () => {
  // The script is plain same-origin JS with no module exports, so these tests load it into a
  // No jsdom/happy-dom in this project (zero runtime deps by design, and the test suite doesn't
  // carry one either), so this drives the *actual* shipped script against a minimal hand-rolled
  // fake DOM — just enough of the Element API the script touches (classList, getAttribute,
  // closest, querySelectorAll, insertBefore, previous/nextElementSibling, addEventListener) — and
  // invokes the listeners it registers directly, the same shape a browser's dispatch would use.
  class FakeEl {
    constructor(tag, attrs = {}) {
      this.tag = tag.toUpperCase();
      this.attrs = { ...attrs };
      this.children = [];
      this.parent = null;
      this._classes = new Set();
      this.textContent = '';
      this.listeners = {};
      this.getBoundingClientRect = () => ({ top: 0, height: 20 });
    }
    getAttribute(name) {
      return name in this.attrs ? this.attrs[name] : null;
    }
    get classList() {
      const self = this;
      return {
        add: (c) => self._classes.add(c),
        remove: (c) => self._classes.delete(c),
        contains: (c) => self._classes.has(c),
      };
    }
    appendChild(child) {
      child.parent = this;
      this.children.push(child);
    }
    insertBefore(child, ref) {
      if (child.parent) {
        const i = child.parent.children.indexOf(child);
        if (i > -1) child.parent.children.splice(i, 1);
      }
      child.parent = this;
      const idx = ref == null ? -1 : this.children.indexOf(ref);
      if (idx === -1) this.children.push(child);
      else this.children.splice(idx, 0, child);
    }
    get previousElementSibling() {
      if (!this.parent) return null;
      const i = this.parent.children.indexOf(this);
      return i > 0 ? this.parent.children[i - 1] : null;
    }
    get nextElementSibling() {
      if (!this.parent) return null;
      const i = this.parent.children.indexOf(this);
      return i >= 0 && i < this.parent.children.length - 1 ? this.parent.children[i + 1] : null;
    }
    matches(selector) {
      if (selector === 'tr[data-key]') return this.tag === 'TR' && this.attrs['data-key'] != null;
      if (selector.startsWith('.')) return this._classes.has(selector.slice(1));
      return false;
    }
    closest(selector) {
      let n = this;
      while (n) {
        if (n.matches(selector)) return n;
        n = n.parent;
      }
      return null;
    }
    querySelector(selector) {
      return this.querySelectorAll(selector)[0] || null;
    }
    querySelectorAll(selector) {
      const out = [];
      const walk = (node) => {
        for (const c of node.children) {
          if (c.matches(selector)) out.push(c);
          walk(c);
        }
      };
      walk(this);
      return out;
    }
    addEventListener(type, fn) {
      (this.listeners[type] = this.listeners[type] || []).push(fn);
    }
    focus() {}
  }

  function buildFakeBody(keys) {
    const body = new FakeEl('TBODY', { id: 'backlog-body' });
    for (const key of keys) {
      const tr = new FakeEl('TR', { draggable: 'true', 'data-key': key });
      const rank = new FakeEl('TD');
      rank._classes.add('bp-rank');
      const handle = new FakeEl('SPAN');
      handle._classes.add('bp-handle');
      tr.appendChild(rank);
      tr.appendChild(handle);
      body.appendChild(tr);
    }
    return body;
  }

  /** Loads the real BACKLOG_REORDER_SCRIPT (extracted from a render) against a fake body/document. */
  function loadScript(body) {
    const html = renderPage({ mac: hostRecord({ backlog: [bi(1)] }), vm: null }, thresholds, NOW);
    const scriptMatch = /<script>([\s\S]*?)<\/script>/.exec(html);
    expect(scriptMatch).not.toBeNull();
    const fakeDocument = { getElementById: (id) => (id === 'backlog-body' ? body : null) };
    const calls = [];
    const fakeFetch = (url, opts) => {
      calls.push({ url, opts });
      return Promise.resolve({ ok: true });
    };
    const fakeLocation = { reload: () => {} };
    // eslint-disable-next-line no-new-func
    const run = new Function('document', 'fetch', 'location', 'alert', scriptMatch[1]);
    run(fakeDocument, fakeFetch, fakeLocation, () => {});
    return calls;
  }

  function order(body) {
    return body.children.map((tr) => tr.getAttribute('data-key'));
  }

  it("Arrow Down on a row's handle moves it below its sibling and saves the new order", () => {
    const body = buildFakeBody(['a#30', 'a#20']);
    const calls = loadScript(body);
    const handle = body.children[0].children[1]; // first row's .bp-handle
    body.listeners.keydown[0]({ key: 'ArrowDown', target: handle, preventDefault: () => {} });
    expect(order(body)).toEqual(['a#20', 'a#30']);
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe('/backlog-priority');
    expect(JSON.parse(calls[0].opts.body)).toEqual({ keys: ['a#20', 'a#30'] });
  });

  it("Arrow Up on the second row's handle moves it above the first", () => {
    const body = buildFakeBody(['a#30', 'a#20']);
    loadScript(body);
    const handle = body.children[1].children[1];
    body.listeners.keydown[0]({ key: 'ArrowUp', target: handle, preventDefault: () => {} });
    expect(order(body)).toEqual(['a#20', 'a#30']);
  });

  it('Arrow Up on the first row is a no-op (no previous sibling)', () => {
    const body = buildFakeBody(['a#30', 'a#20']);
    loadScript(body);
    const handle = body.children[0].children[1];
    body.listeners.keydown[0]({ key: 'ArrowUp', target: handle, preventDefault: () => {} });
    expect(order(body)).toEqual(['a#30', 'a#20']);
  });

  it('a key other than Arrow Up/Down is ignored even with a handle focused', () => {
    const body = buildFakeBody(['a#30', 'a#20']);
    loadScript(body);
    const handle = body.children[0].children[1];
    body.listeners.keydown[0]({ key: 'Enter', target: handle, preventDefault: () => {} });
    expect(order(body)).toEqual(['a#30', 'a#20']);
  });

  it('dragging the first row over the second (past its midpoint) and dropping reorders and saves', () => {
    const body = buildFakeBody(['a#30', 'a#20']);
    const calls = loadScript(body);
    const dragged = body.children[0];
    const target = body.children[1];

    body.listeners.dragstart[0]({ target: dragged, dataTransfer: { setData: () => {} } });
    expect(dragged.classList.contains('bp-dragging')).toBe(true);

    body.listeners.dragover[0]({ target, clientY: 15, preventDefault: () => {} }); // below the 10px midpoint
    body.listeners.drop[0]({ target, preventDefault: () => {} });

    expect(order(body)).toEqual(['a#20', 'a#30']);
    expect(dragged.classList.contains('bp-dragging')).toBe(false);
    expect(calls).toHaveLength(1);
    expect(JSON.parse(calls[0].opts.body)).toEqual({ keys: ['a#20', 'a#30'] });
  });

  it('dragging over the row above the midpoint lands the dragged row before it', () => {
    const body = buildFakeBody(['a#30', 'a#20']);
    loadScript(body);
    const dragged = body.children[1]; // "a#20" starts second
    const target = body.children[0]; // "a#30"

    body.listeners.dragstart[0]({ target: dragged, dataTransfer: { setData: () => {} } });
    body.listeners.dragover[0]({ target, clientY: 5, preventDefault: () => {} }); // above the 10px midpoint
    body.listeners.drop[0]({ target, preventDefault: () => {} });

    expect(order(body)).toEqual(['a#20', 'a#30']);
  });

  it('dragend without a drop (e.g. dropped outside) still clears the dragging state', () => {
    const body = buildFakeBody(['a#30', 'a#20']);
    const calls = loadScript(body);
    const dragged = body.children[0];
    body.listeners.dragstart[0]({ target: dragged, dataTransfer: { setData: () => {} } });
    body.listeners.dragend[0]({});
    expect(dragged.classList.contains('bp-dragging')).toBe(false);
    expect(calls).toHaveLength(0); // never saved: no drop happened
  });
});
