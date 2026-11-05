// backlog[] — the "Backlog priority" reorder view (standalone, non-goal agent-go tickets; JP's
// stored priority rank, lowest first). Covers validate.js sanitisation, group.js's cross-host
// merge/sort and the no-JS render.js section (this page never emits <script>; grouped-render.test.js
// pins that for the whole page).

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
  it('ranked items sort first (lowest rank), unranked after by issue number', () => {
    const mac = hostRecord({
      backlog: [bi(30, { rank: 0 }), bi(20)],
    });
    const rows = buildBacklog({ mac, vm: null });
    expect(rows.map((r) => r.issue)).toEqual([30, 20]);
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

describe('render.js — Backlog priority section (no JS)', () => {
  it('renders a heading with the row count and a row per ticket', () => {
    const mac = hostRecord({
      backlog: [bi(11, { title: 'First', rank: 0 }), bi(12, { title: 'Second', rank: 1 })],
    });
    const html = renderPage({ mac, vm: null }, thresholds, NOW);
    expect(html).toMatch(/<h2[^>]*>\s*Backlog priority \(2\)\s*<\/h2>/);
    expect(html).toContain('#11');
    expect(html).toContain('First');
    expect(html).toContain('#12');
    expect(html).toContain('Second');
  });

  it('prints the backlog-priority.sh set command with keys in display order', () => {
    const mac = hostRecord({
      backlog: [bi(30, { rank: 0 }), bi(20)],
    });
    const html = renderPage({ mac, vm: null }, thresholds, NOW);
    const cmdMatch = /<pre class="backlog-cmd">([\s\S]*?)<\/pre>/.exec(html);
    expect(cmdMatch).not.toBeNull();
    expect(cmdMatch[1]).toContain('backlog-priority.sh set');
    const i30 = cmdMatch[1].indexOf('example-owner/project-a#30');
    const i20 = cmdMatch[1].indexOf('example-owner/project-a#20');
    expect(i30).toBeGreaterThan(-1);
    expect(i20).toBeGreaterThan(i30);
  });

  it('an empty backlog renders "(0)", "none" and no command block', () => {
    const html = renderPage({ mac: hostRecord({}), vm: null }, thresholds, NOW);
    expect(html).toMatch(/<h2[^>]*>\s*Backlog priority \(0\)\s*<\/h2>/);
    expect(html).not.toContain('class="backlog-cmd"');
  });

  it('never emits <script>, and escapes a hostile title', () => {
    const mac = hostRecord({ backlog: [validBacklogItem({ title: '<script>alert(1)</script>' })] });
    const html = renderPage({ mac, vm: null }, thresholds, NOW);
    expect(html).not.toMatch(/<script/i);
    expect(html).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
  });
});
