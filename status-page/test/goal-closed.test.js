// Status page "Goals" section — closed goals (delivered / stopped) shown compactly, the most recent few, after the live
// goals. Expected values are hand-written, never copied from src/.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { renderPage } from '../src/render.js';
import { validPayload, hostRecord } from './fixtures.js';

const closed = (o = {}) => ({
  id: 'c1',
  title: 'Closed goal',
  repos: ['org/repo-a'],
  host: '',
  state: 'delivered',
  closed_at: '2026-09-20T09:00:00Z',
  ...o,
});
const running = (o = {}) => ({ id: 'r1', title: 'Live goal', repos: ['org/repo-a'], host: 'mac', state: 'running', scope_total: 4, scope_delivered: 1, ...o });
const goalsOf = (goals) => {
  const r = validateBeatPayload(validPayload({ goals }));
  expect(r.ok).toBe(true);
  return r.value.goals ?? [];
};

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;
const rec = (goals, o = {}) => ({ ...hostRecord(o), goals });
const render = (mac, vm) => renderPage({ mac, vm }, thresholds, NOW);
const text = (s) => s.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
const goalsHtml = (html) => (/<section class="group">\s*<h2>Goals<\/h2>[\s\S]*?<\/section>/.exec(html) || [''])[0];
const rowsOf = (section) =>
  [...section.matchAll(/<tr>([\s\S]*?)<\/tr>/g)]
    .filter((r) => r[1].includes('<td'))
    .map((r) => [...r[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((c) => text(c[1])));
// the compact list of closed goals lives in its own block inside the Goals section
const closedBlock = (html) => (/<div class="goals-closed">[\s\S]*?<\/div>/.exec(goalsHtml(html)) || [''])[0];

describe('validate.js — closed goals', () => {
  it('keeps a delivered and a stopped goal without a host, with closed_at', () => {
    const g = goalsOf([closed(), closed({ id: 'c2', state: 'stopped' })]);
    expect(g).toEqual([closed(), closed({ id: 'c2', state: 'stopped' })]);
  });

  it('still requires a host for a running goal, and drops a bad closed_at', () => {
    expect(goalsOf([running({ host: '' })])).toEqual([]);
    expect(goalsOf([closed({ closed_at: 'yesterday' })])[0]).not.toHaveProperty('closed_at');
  });

  it('ignores queue_pos and paused on a closed goal', () => {
    const g = goalsOf([closed({ queue_pos: 2, paused: 'Mac on battery' })])[0];
    expect(g).not.toHaveProperty('queue_pos');
    expect(g).not.toHaveProperty('paused');
  });
});

describe('render.js — closed goals', () => {
  it('keeps closed goals out of the main goals table', () => {
    const html = render(rec([running(), closed()]), null);
    expect(rowsOf(goalsHtml(html).replace(/<div class="goals-closed">[\s\S]*?<\/div>/, '')).map((c) => c[0])).toEqual(['Live goal org/repo-a']);
  });

  it('lists closed goals compactly: title, plain outcome, closed date, newest first', () => {
    const html = render(
      rec([
        closed({ id: 'old', title: 'Old one', closed_at: '2026-09-10T09:00:00Z' }),
        closed({ id: 'new', title: 'New one', closed_at: '2026-09-20T09:00:00Z' }),
        closed({ id: 'stp', title: 'Dropped one', state: 'stopped', closed_at: '2026-09-15T09:00:00Z' }),
      ]),
      null,
    );
    const block = text(closedBlock(html));
    expect(block).toContain('Recently closed');
    expect(block.indexOf('New one')).toBeGreaterThan(-1);
    expect(block.indexOf('New one')).toBeLessThan(block.indexOf('Dropped one'));
    expect(block.indexOf('Dropped one')).toBeLessThan(block.indexOf('Old one'));
    expect(block).toMatch(/Dropped one[^]*stopped/);
    expect(block).toMatch(/New one[^]*delivered/);
  });

  it('shows only the 5 most recent closed goals', () => {
    const goals = [1, 2, 3, 4, 5, 6, 7].map((n) => closed({ id: `c${n}`, title: `Goal ${n}`, closed_at: `2026-09-1${n}T09:00:00Z` }));
    const block = text(closedBlock(render(rec(goals), null)));
    for (const n of [3, 4, 5, 6, 7]) expect(block).toContain(`Goal ${n}`);
    for (const n of [1, 2]) expect(block).not.toContain(`Goal ${n}`);
  });

  it('shows the section for closed goals alone, and nothing when there are none', () => {
    expect(closedBlock(render(rec([closed()]), null))).toContain('Closed goal');
    expect(goalsHtml(render(rec([]), null))).toBe('');
  });

  it('merges both hosts reports of the same closed goal into one line', () => {
    const html = render(rec([closed()]), rec([closed()], { received_at: '2026-09-21T11:00:00Z' }));
    expect(text(closedBlock(html)).split('Closed goal').length - 1).toBe(1);
  });

  it('escapes the title', () => {
    expect(closedBlock(render(rec([closed({ title: 'a b' })]), null))).not.toContain('<script');
  });
});
