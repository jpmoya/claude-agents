// Issue #320 item 7 — the status page shows the queue position of each queued goal (1..n) and "paused: Mac on battery"
// when the only free host is a battery Mac. Expected values are hand-written from the ticket, never copied from src/.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { renderPage } from '../src/render.js';
import { validPayload, hostRecord } from './fixtures.js';

const queued = (o = {}) => ({ id: 'q1', title: 'Queued goal', repos: ['org/repo-a'], host: '', state: 'queued', queue_pos: 1, ...o });
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
function goalRows(html) {
  const m = /<section class="group">\s*<h2>Goals<\/h2>[\s\S]*?<\/section>/.exec(html);
  if (!m) return [];
  return [...m[0].matchAll(/<tr>([\s\S]*?)<\/tr>/g)]
    .filter((r) => r[1].includes('<td'))
    .map((r) => [...r[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((c) => text(c[1])).slice(1)); // slice(1): the Priority column is covered in goal-links.test.js
}

describe('#320 validate.js — queued goals', () => {
  it('keeps a queued goal without a host, with its queue position and pause reason', () => {
    const g = goalsOf([queued({ paused: 'Mac on battery' })]);
    expect(g).toEqual([queued({ paused: 'Mac on battery' })]);
  });

  it('a queued goal may omit the host field; a started goal may not', () => {
    const { host: _h, ...noHost } = queued();
    expect(goalsOf([noHost]).map((x) => x.id)).toEqual(['q1']);
    expect(goalsOf([{ id: 'r', spec: 's', state: 'running' }])).toEqual([]);
  });

  it('drops a pause reason that is not on the closed list, and a hostile one', () => {
    const g = goalsOf([queued({ paused: '<script>x</script>' })]);
    expect(g).toHaveLength(1);
    expect(g[0]).not.toHaveProperty('paused');
  });

  it('drops queue_pos below 1 and non-integers; ignores both on non-queued goals', () => {
    expect(goalsOf([queued({ queue_pos: 0 })])[0]).not.toHaveProperty('queue_pos');
    expect(goalsOf([queued({ queue_pos: 1.5 })])[0]).not.toHaveProperty('queue_pos');
    const run = goalsOf([{ id: 'r', spec: 's', host: 'mac', state: 'running', queue_pos: 3, paused: 'Mac on battery' }])[0];
    expect(run).not.toHaveProperty('queue_pos');
    expect(run).not.toHaveProperty('paused');
  });
});

describe('#320 render.js — queue position and paused reason', () => {
  it('shows "queued #n" for each queued goal, in queue order, after the started goals', () => {
    const goals = [
      queued({ id: 'q3', title: 'Third', queue_pos: 3 }),
      queued({ id: 'q1', title: 'First', queue_pos: 1 }),
      { id: 'run', spec: 'Running goal', host: 'mac', state: 'running' },
      queued({ id: 'q2', title: 'Second', queue_pos: 2 }),
    ];
    const rows = goalRows(render(rec(goals), null)).map((c) => [c[0].split(' ')[0], c[2]]);
    expect(rows).toEqual([
      ['Running', 'running'],
      ['First', 'queued #1'],
      ['Second', 'queued #2'],
      ['Third', 'queued #3'],
    ]);
  });

  it('shows "paused: Mac on battery" on the goal that carries it, and nowhere else', () => {
    const goals = [queued({ id: 'q1', title: 'First', queue_pos: 1, paused: 'Mac on battery' }), queued({ id: 'q2', title: 'Second', queue_pos: 2 })];
    const rows = goalRows(render(rec(goals), null));
    expect(rows[0][2]).toContain('paused: Mac on battery');
    expect(rows[1][2]).not.toContain('paused');
  });

  it('a queued goal has no host: the Host cell is a dash', () => {
    expect(goalRows(render(rec([queued()]), null))[0][1]).toBe('–');
  });

  it('merges both hosts: the report carrying the pause reason wins over a newer one without it', () => {
    const mac = rec([queued({ paused: 'Mac on battery' })], { received_at: '2026-09-21T11:00:00Z' });
    const vm = rec([queued()], { received_at: '2026-09-21T11:30:00Z' });
    const rows = goalRows(render(mac, vm));
    expect(rows).toHaveLength(1);
    expect(rows[0][2]).toContain('paused: Mac on battery');
  });

  it('merges both hosts: a started goal beats a stale queued report of the same id', () => {
    const mac = rec([queued({ id: 'g' })], { received_at: '2026-09-21T11:59:00Z' });
    const vm = rec([{ id: 'g', title: 'Queued goal', repos: ['org/repo-a'], host: 'vm', state: 'running' }], { received_at: '2026-09-21T11:00:00Z' });
    const rows = goalRows(render(mac, vm));
    expect(rows).toHaveLength(1);
    expect(rows[0][2]).toBe('running');
  });

  it('a goal both hosts own keeps the more active state whichever host pushed last (no flip-flop)', () => {
    const g = (host, state) => ({ id: 'project-22', title: 'Shared goal', repos: ['org/repo-a'], host, state });
    for (const [macAt, vmAt] of [['2026-09-21T11:59:00Z', '2026-09-21T11:00:00Z'], ['2026-09-21T11:00:00Z', '2026-09-21T11:59:00Z']]) {
      const rows = goalRows(render(rec([g('mac', 'between_cycles')], { received_at: macAt }), rec([g('vm', 'running')], { received_at: vmAt })));
      expect(rows).toHaveLength(1);
      expect(rows[0][2]).toBe('running');
    }
  });
});
