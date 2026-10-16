// Issue #319 AC5 — status page shows a cross-repo (label) goal's title, repos and order.
// A v2 goal has no single `spec`. Expected values hand-written from the ticket.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { renderPage } from '../src/render.js';
import { validPayload, hostRecord } from './fixtures.js';

const labelGoal = (o = {}) => ({
  id: 'label-goal-1',
  title: 'Cross-repo goal model for the pipeline',
  repos: ['example-owner/project-a', 'example-owner/project-b'],
  order: 319,
  host: 'mac',
  state: 'running',
  scope_total: 3,
  scope_delivered: 1,
  last_cycle_at: '2026-09-21T10:00:00Z',
  ...o,
});
const goalsOf = (goals) => {
  const r = validateBeatPayload(validPayload({ goals }));
  expect(r.ok).toBe(true);
  return r.value.goals ?? [];
};

describe('#319 validate.js — label goal entries', () => {
  it('keeps a v2 entry (no spec) with title, repos and order', () => {
    const g = goalsOf([labelGoal()]);
    expect(g).toHaveLength(1);
    expect(g[0].title).toBe('Cross-repo goal model for the pipeline');
    expect(g[0].repos).toEqual(['example-owner/project-a', 'example-owner/project-b']);
    expect(g[0].order).toBe(319);
  });

  it('never lets markup through in title or repos', () => {
    const out = goalsOf([
      labelGoal({ id: 'ok' }),
      labelGoal({ id: 'x1', title: '<script>alert(1)</script>' }),
      labelGoal({ id: 'x2', repos: ['<img src=x>/y'] }),
    ]);
    expect(out.find((g) => g.id === 'ok')?.title).toBe('Cross-repo goal model for the pipeline');
    expect(JSON.stringify(out)).not.toContain('<script>');
    expect(JSON.stringify(out)).not.toContain('<img');
  });

  it('a v1 entry (spec, no title/repos/order) is still kept unchanged', () => {
    const v1 = { id: 'old', spec: 'Ship the quoting tool v2', host: 'vm', state: 'held' };
    expect(goalsOf([labelGoal(), v1]).find((g) => g.id === 'old')).toEqual(v1);
  });
});

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;

describe('#319 render.js — Goals section', () => {
  it('shows the goal title, both repos and the order', () => {
    const rec = hostRecord({});
    rec.goals = [labelGoal()];
    const html = renderPage({ mac: rec, vm: null }, thresholds, NOW);
    const m = /<section class="group">\s*<h2>Goals<\/h2>[\s\S]*?<\/section>/.exec(html);
    expect(m).not.toBeNull();
    expect(m[0]).toContain('Cross-repo goal model for the pipeline');
    expect(m[0]).toContain('example-owner/project-a');
    expect(m[0]).toContain('example-owner/project-b');
    expect(m[0]).toContain('319'); // order
  });
});
