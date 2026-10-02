// #62 AC4/AC7 — groupTickets(hosts, nowEpochSecs): pure grouping. Expected values are
// hand-written from the ticket's eight rules, ordering and caps. Return shape assumed (see the
// stub's JSDoc): array of 7 { heading, rows } in page order; rows carry `issue`, run rows `host`.

import { describe, it, expect } from 'vitest';
import { groupTickets } from '../src/group.js';
import { validRun, validCompleted, validStagingItem, validApprovedItem, hostRecord } from './fixtures.js';

const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;
const ago = (hours) => new Date((NOW - hours * 3600) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const urlOf = (n) => `https://github.com/example-owner/project-a/issues/${n}`;

const H = {
  running: 'Running',
  queued: 'Queued',
  approved: 'Approved, waiting for a slot',
  needsJp: 'Needs JP',
  staging: 'On staging (awaiting production)',
  parked: 'Parked',
  done: 'Done',
};

const run = (issue, o = {}) => validRun({ issue, url: urlOf(issue), title: `T${issue}`, last_activity_at: ago(1), ...o });
const staged = (issue, o = {}) => validStagingItem({ issue, url: urlOf(issue), ...o });
const approvedItem = (issue, o = {}) => validApprovedItem({ issue, url: urlOf(issue), ...o });
const done = (issue, o = {}) => validCompleted({ issue, url: urlOf(issue), closed_at: ago(2), ...o });

const group = (hosts) => groupTickets({ mac: null, vm: null, ...hosts }, NOW);
const rowsOf = (groups, heading) => groups.find((g) => g.heading === heading)?.rows ?? null;
const issuesOf = (groups, heading) => rowsOf(groups, heading).map((r) => r.issue);
/** The single group name a ticket landed in; asserts exactly one. */
function where(groups, issue) {
  const hits = groups.filter((g) => g.rows.some((r) => r.issue === issue)).map((g) => g.heading);
  expect(hits).toHaveLength(1);
  return hits[0];
}

describe('groupTickets — structure', () => {
  it('returns the seven groups in the stated order, even when empty', () => {
    const g = group({});
    expect(g.map((x) => x.heading)).toEqual([H.running, H.queued, H.approved, H.needsJp, H.staging, H.parked, H.done]);
    for (const x of g) expect(x.rows).toEqual([]);
  });
});

describe('groupTickets — the eight rules, one test each', () => {
  it('rule 1: a running run -> Running', () => {
    expect(where(group({ mac: hostRecord({ runs: [run(1, { state: 'running' })] }) }), 1)).toBe(H.running);
  });

  it('rule 2: key in completed[] within 7 days -> Done', () => {
    expect(where(group({ mac: hostRecord({ completed: [done(2)] }) }), 2)).toBe(H.done);
  });

  it('rule 3: key in approved[] -> Approved', () => {
    expect(where(group({ mac: hostRecord({ approved: [approvedItem(3)] }) }), 3)).toBe(H.approved);
  });

  it('rule 4: a queued run -> Queued', () => {
    expect(where(group({ mac: hostRecord({ runs: [run(4, { state: 'queued' })] }) }), 4)).toBe(H.queued);
  });

  it('rule 5: key in staging[] -> On staging (even with no run at all)', () => {
    expect(where(group({ vm: hostRecord({ staging: [staged(5)] }) }), 5)).toBe(H.staging);
  });

  it('rule 6: a restarting run -> Running, state cell keeps "restarting"', () => {
    const g = group({ mac: hostRecord({ runs: [run(6, { state: 'restarting' })] }) });
    expect(where(g, 6)).toBe(H.running);
    expect(rowsOf(g, H.running)[0].state).toBe('restarting');
  });

  it.each(['MOCKUPS PENDING APPROVAL', 'AWAITING GO', 'EFFORT APPROVAL NEEDED', 'BLOCKED'])('rule 7: held + %s -> Needs JP', (marker) => {
    expect(where(group({ mac: hostRecord({ runs: [run(7, { state: 'held', marker })] }) }), 7)).toBe(H.needsJp);
  });

  it.each(['TESTS WRITTEN', 'DEPLOYED', 'other', 'DECISION', 'JP CONFIRMED'])('rule 8: held + %s -> Parked', (marker) => {
    expect(where(group({ mac: hostRecord({ runs: [run(8, { state: 'held', marker })] }) }), 8)).toBe(H.parked);
  });
});

describe('groupTickets — precedence conflicts (first matching rule wins)', () => {
  it('running beats completed (1 over 2)', () => {
    const g = group({ mac: hostRecord({ runs: [run(1, { state: 'running' })], completed: [done(1)] }) });
    expect(where(g, 1)).toBe(H.running);
  });

  it('running beats staging (1 over 5)', () => {
    const g = group({ mac: hostRecord({ runs: [run(1, { state: 'running' })] }), vm: hostRecord({ staging: [staged(1)] }) });
    expect(where(g, 1)).toBe(H.running);
  });

  it('completed beats approved and staging (2 over 3, 5)', () => {
    const g = group({ mac: hostRecord({ completed: [done(2)], approved: [approvedItem(2)], staging: [staged(2)] }) });
    expect(where(g, 2)).toBe(H.done);
  });

  it('approved beats a queued run (3 over 4)', () => {
    const g = group({ mac: hostRecord({ runs: [run(3, { state: 'queued' })], approved: [approvedItem(3)] }) });
    expect(where(g, 3)).toBe(H.approved);
  });

  it('queued beats staging (4 over 5)', () => {
    const g = group({ mac: hostRecord({ runs: [run(4, { state: 'queued' })] }), vm: hostRecord({ staging: [staged(4)] }) });
    expect(where(g, 4)).toBe(H.queued);
  });

  it('staging beats a stale held BLOCKED run from the other host (5 over 7)', () => {
    const g = group({ mac: hostRecord({ runs: [run(5, { state: 'held', marker: 'BLOCKED' })] }), vm: hostRecord({ staging: [staged(5)] }) });
    expect(where(g, 5)).toBe(H.staging);
  });

  it('staging beats a restarting run (5 over 6)', () => {
    const g = group({ mac: hostRecord({ runs: [run(6, { state: 'restarting' })] }), vm: hostRecord({ staging: [staged(6)] }) });
    expect(where(g, 6)).toBe(H.staging);
  });

  it('completed older than 7 days does not count as Done: falls through to the run rule', () => {
    const g = group({ mac: hostRecord({ runs: [run(9, { state: 'held', marker: 'BLOCKED' })], completed: [done(9, { closed_at: ago(24 * 8) })] }) });
    expect(where(g, 9)).toBe(H.needsJp);
  });

  it('completed exactly-ish 6 days old still counts as Done', () => {
    expect(where(group({ mac: hostRecord({ completed: [done(9, { closed_at: ago(24 * 6) })] }) }), 9)).toBe(H.done);
  });

  it('a held AWAITING GO dated 30 days ago is still Needs JP (never aged out)', () => {
    const g = group({ mac: hostRecord({ runs: [run(10, { state: 'held', marker: 'AWAITING GO', last_activity_at: ago(24 * 30) })] }) });
    expect(where(g, 10)).toBe(H.needsJp);
  });

  it('keys without a url match on repo#issue across runs and staging', () => {
    const r = validRun({ repo: 'project-a', issue: 11, state: 'held', marker: 'BLOCKED', last_activity_at: ago(1) });
    const s = validStagingItem({ repo: 'project-a', issue: 11, url: undefined });
    delete s.url;
    delete r.url;
    expect(where(group({ mac: hostRecord({ runs: [r] }), vm: hostRecord({ staging: [s] }) }), 11)).toBe(H.staging);
  });
});

describe('groupTickets — one row per ticket across hosts', () => {
  it('same url: Mac held at T-9h, VM restarting at T-3h -> one row, host vm, Running', () => {
    const g = group({
      mac: hostRecord({ runs: [run(739, { state: 'held', marker: 'BLOCKED', last_activity_at: ago(9) })] }),
      vm: hostRecord({ runs: [run(739, { state: 'restarting', last_activity_at: ago(3) })] }),
    });
    expect(where(g, 739)).toBe(H.running);
    const rows = rowsOf(g, H.running).filter((r) => r.issue === 739);
    expect(rows).toHaveLength(1);
    expect(rows[0].host).toBe('vm');
  });

  it('timestamps swapped -> the Mac held row wins, ticket is Needs JP, host mac', () => {
    const g = group({
      mac: hostRecord({ runs: [run(739, { state: 'held', marker: 'BLOCKED', last_activity_at: ago(3) })] }),
      vm: hostRecord({ runs: [run(739, { state: 'restarting', last_activity_at: ago(9) })] }),
    });
    expect(where(g, 739)).toBe(H.needsJp);
    expect(rowsOf(g, H.needsJp)[0].host).toBe('mac');
  });

  it('exact timestamp tie -> Mac wins', () => {
    const t = ago(2);
    const g = group({
      mac: hostRecord({ runs: [run(5, { state: 'held', marker: 'BLOCKED', last_activity_at: t })] }),
      vm: hostRecord({ runs: [run(5, { state: 'running', last_activity_at: t })] }),
    });
    expect(where(g, 5)).toBe(H.needsJp);
    expect(rowsOf(g, H.needsJp)[0].host).toBe('mac');
  });

  it('a row with no last_activity_at loses to one that has it', () => {
    const noTs = run(5, { state: 'running' });
    delete noTs.last_activity_at;
    const g = group({
      mac: hostRecord({ runs: [noTs] }),
      vm: hostRecord({ runs: [run(5, { state: 'held', marker: 'BLOCKED', last_activity_at: ago(50) })] }),
    });
    expect(where(g, 5)).toBe(H.needsJp);
    expect(rowsOf(g, H.needsJp)[0].host).toBe('vm');
  });

  it('a mixed fixture puts every ticket key in exactly one group', () => {
    const g = group({
      mac: hostRecord({
        runs: [run(1), run(2, { state: 'queued' }), run(3, { state: 'held', marker: 'BLOCKED' }), run(4, { state: 'held', marker: 'PASS' }), run(5, { state: 'restarting' })],
        completed: [done(6)],
        staging: [staged(7)],
      }),
      vm: hostRecord({ runs: [run(1, { state: 'held', marker: 'PASS', last_activity_at: ago(30) }), run(4, { state: 'held', marker: 'PASS' })], approved: [approvedItem(8)] }),
    });
    const all = g.flatMap((x) => x.rows.map((r) => r.issue));
    expect([...all].sort((a, b) => a - b)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
  });
});

describe('groupTickets — ordering, caps and ageing (#62 AC7)', () => {
  it('Running is uncapped: 25 running rows across both hosts -> all 25', () => {
    const mac = Array.from({ length: 13 }, (_v, i) => run(i + 1, { state: 'running' }));
    const vm = Array.from({ length: 12 }, (_v, i) => run(i + 101, { state: 'running' }));
    const g = group({ mac: hostRecord({ runs: mac }), vm: hostRecord({ runs: vm }) });
    expect(rowsOf(g, H.running)).toHaveLength(25);
  });

  it('Queued is uncapped: 25 queued rows -> all 25', () => {
    const a = Array.from({ length: 13 }, (_v, i) => run(i + 1, { state: 'queued' }));
    const b = Array.from({ length: 12 }, (_v, i) => run(i + 101, { state: 'queued' }));
    expect(rowsOf(group({ mac: hostRecord({ runs: a }), vm: hostRecord({ runs: b }) }), H.queued)).toHaveLength(25);
  });

  it('Parked: 12 fresh rows -> newest 10 shown', () => {
    // issue i has last activity i hours ago -> issue 1 newest; the two oldest (11, 12) are cut
    const runs = Array.from({ length: 12 }, (_v, i) => run(i + 1, { state: 'held', marker: 'PASS', last_activity_at: ago(i + 1) }));
    const g = group({ mac: hostRecord({ runs }) });
    expect(issuesOf(g, H.parked)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  });

  it('Parked: a 17-day-old row is hidden, a 6-day-old row is shown', () => {
    const g = group({
      mac: hostRecord({
        runs: [run(1, { state: 'held', marker: 'PASS', last_activity_at: ago(24 * 17) }), run(2, { state: 'held', marker: 'PASS', last_activity_at: ago(24 * 6) })],
      }),
    });
    expect(issuesOf(g, H.parked)).toEqual([2]);
  });

  it('Needs JP: 25 rows -> capped at 20, newest first, none aged out', () => {
    const runs = Array.from({ length: 20 }, (_v, i) => run(i + 1, { state: 'held', marker: 'BLOCKED', last_activity_at: ago(24 * 30 + i) }));
    const more = Array.from({ length: 5 }, (_v, i) => run(i + 101, { state: 'held', marker: 'AWAITING GO', last_activity_at: ago(24 * 40 + i) }));
    const g = group({ mac: hostRecord({ runs }), vm: hostRecord({ runs: more }) });
    const out = issuesOf(g, H.needsJp);
    expect(out).toHaveLength(20);
    expect(out[0]).toBe(1); // newest (30 days ago); every 40-day row is older and cut
    expect(out.every((n) => n <= 20)).toBe(true);
  });

  it('Running rows are ordered newest last_activity_at first', () => {
    const g = group({ mac: hostRecord({ runs: [run(1, { state: 'running', last_activity_at: ago(5) }), run(2, { state: 'running', last_activity_at: ago(1) }), run(3, { state: 'running', last_activity_at: ago(3) })] }) });
    expect(issuesOf(g, H.running)).toEqual([2, 3, 1]);
  });

  it('Running: a row with no last_activity_at sorts last', () => {
    const missing = run(1, { state: 'running' });
    delete missing.last_activity_at;
    const g = group({ mac: hostRecord({ runs: [missing, run(2, { state: 'running', last_activity_at: ago(90) })] }) });
    expect(issuesOf(g, H.running)).toEqual([2, 1]);
  });

  it('Approved: 25 items -> 20 shown, newest updated_at first', () => {
    const items = Array.from({ length: 25 }, (_v, i) => approvedItem(i + 1, { updated_at: ago(i + 1) }));
    const g = group({ mac: hostRecord({ approved: items.slice(0, 20) }), vm: hostRecord({ approved: items.slice(20) }) });
    const out = issuesOf(g, H.approved);
    expect(out).toHaveLength(20);
    expect(out[0]).toBe(1);
    expect(out[19]).toBe(20);
  });

  it('On staging: 70 items across hosts -> 60 shown, newest updated_at first, missing updated_at last', () => {
    const noTs = staged(500);
    delete noTs.updated_at;
    const a = Array.from({ length: 35 }, (_v, i) => staged(i + 1, { updated_at: ago(i + 1) }));
    const b = Array.from({ length: 35 }, (_v, i) => staged(i + 101, { updated_at: ago(100 + i) }));
    const g = group({ mac: hostRecord({ staging: [noTs, ...a] }), vm: hostRecord({ staging: b }) });
    const out = issuesOf(g, H.staging);
    expect(out).toHaveLength(60);
    expect(out[0]).toBe(1);
    expect(out).not.toContain(500);
  });

  it('Done: 25 within 7 days -> 20 shown, newest closed_at first; 8-day-old excluded', () => {
    const items = Array.from({ length: 25 }, (_v, i) => done(i + 1, { closed_at: ago(i + 1) }));
    const g = group({ mac: hostRecord({ completed: [...items.slice(0, 10), done(900, { closed_at: ago(24 * 8) })] }), vm: hostRecord({ completed: items.slice(10) }) });
    const out = issuesOf(g, H.done);
    expect(out).toHaveLength(20);
    expect(out[0]).toBe(1);
    expect(out).not.toContain(900);
  });

  it('Done: the same ticket completed on both hosts appears once', () => {
    const g = group({ mac: hostRecord({ completed: [done(3)] }), vm: hostRecord({ completed: [done(3)] }) });
    expect(issuesOf(g, H.done)).toEqual([3]);
  });
});

// ---- Issue #140: Needs JP grouped by (repo, milestone) -----------------------------------------
// Expected orders hand-derived from the ticket's "Grouping" rules and fixtures.

describe('groupTickets — Needs JP by (repo, milestone) (#140)', () => {
  const blocked = (issue, repo, milestone, hoursAgo, o = {}) => {
    const r = run(issue, { state: 'held', marker: 'BLOCKED', repo, last_activity_at: ago(hoursAgo), ...o });
    if (milestone !== undefined) r.milestone = milestone;
    return r;
  };
  const needs = (runs) => issuesOf(group({ mac: hostRecord({ runs }) }), H.needsJp);

  it('ticket fixture: no-milestone quoting (4), scheduler Release 3 (3), quoting Release 3 - ... (2); newest first inside', () => {
    const LONG = 'Release 3 - Clean Up Quote Status and Actions';
    const runs = [
      blocked(1, 'scheduler', 'Release 3', 5),
      blocked(2, 'scheduler', 'Release 3', 1), // newest of scheduler
      blocked(3, 'scheduler', 'Release 3', 3),
      blocked(4, 'quoting', LONG, 2),
      blocked(5, 'quoting', LONG, 4),
      blocked(6, 'quoting', undefined, 6),
      blocked(7, 'quoting', undefined, 2),
      blocked(8, 'quoting', undefined, 8),
      blocked(9, 'quoting', undefined, 1),
    ];
    // none-quoting (4 rows): 9(1h) 7(2h) 6(6h) 8(8h); scheduler: 2(1h) 3(3h) 1(5h); quoting R3: 4(2h) 5(4h)
    expect(needs(runs)).toEqual([9, 7, 6, 8, 2, 3, 1, 4, 5]);
  });

  it('tie on count: alphabetical by repo alias', () => {
    const runs = [
      blocked(1, 'scheduler', 'R1', 1), blocked(2, 'scheduler', 'R1', 2),
      blocked(3, 'quoting', 'R1', 3), blocked(4, 'quoting', 'R1', 4),
    ];
    expect(needs(runs)).toEqual([3, 4, 1, 2]);
  });

  it('tie on count, same repo: alphabetical by milestone', () => {
    const runs = [
      blocked(1, 'quoting', 'Beta', 1), blocked(2, 'quoting', 'Beta', 2),
      blocked(3, 'quoting', 'Alpha', 3), blocked(4, 'quoting', 'Alpha', 4),
    ];
    expect(needs(runs)).toEqual([3, 4, 1, 2]);
  });

  it('tie on count, same repo: "no release" sorts after a named milestone', () => {
    const runs = [
      blocked(1, 'quoting', undefined, 1), blocked(2, 'quoting', undefined, 2),
      blocked(3, 'quoting', 'Zeta', 3), blocked(4, 'quoting', 'Zeta', 4),
    ];
    expect(needs(runs)).toEqual([3, 4, 1, 2]);
  });

  it('same milestone title in two repos -> two separate, contiguous groups (larger first)', () => {
    const runs = [
      blocked(1, 'quoting', 'Release 3', 1), // newest overall, but belongs to the smaller group
      blocked(2, 'scheduler', 'Release 3', 2),
      blocked(3, 'scheduler', 'Release 3', 3),
    ];
    expect(needs(runs)).toEqual([2, 3, 1]);
  });

  it('negative: a run with milestone absent sorts as "no release" and does not throw', () => {
    const runs = [blocked(1, 'quoting', undefined, 1), blocked(2, 'quoting', 'Beta', 2), blocked(3, 'quoting', 'Beta', 3)];
    expect(() => needs(runs)).not.toThrow();
    expect(needs(runs)).toEqual([2, 3, 1]);
  });

  it('cap: 25 rows -> exactly 20, taken in group order; the last group is truncated, not dropped', () => {
    const runs = [];
    let n = 100;
    for (let i = 0; i < 10; i++) runs.push(blocked(n++, 'alpha', 'M', 1 + i)); // 100..109
    for (let i = 0; i < 9; i++) runs.push(blocked(n++, 'beta', 'M', 1 + i)); // 110..118
    for (let i = 0; i < 6; i++) runs.push(blocked(n++, 'gamma', 'M', 1 + i)); // 119..124
    const got = needs(runs);
    expect(got).toHaveLength(20);
    // alpha 10 + beta 9 + newest 1 of gamma (119, 1h ago)
    expect(got.slice(0, 10)).toEqual([100, 101, 102, 103, 104, 105, 106, 107, 108, 109]);
    expect(got.slice(10, 19)).toEqual([110, 111, 112, 113, 114, 115, 116, 117, 118]);
    expect(got[19]).toBe(119);
  });

  it('group order uses the row count before the cap', () => {
    const runs = [];
    for (let i = 0; i < 21; i++) runs.push(blocked(100 + i, 'zeta', 'M', 1 + i));
    for (let i = 0; i < 5; i++) runs.push(blocked(200 + i, 'alpha', 'M', 1 + i));
    const got = needs(runs);
    expect(got).toHaveLength(20);
    expect(got.every((i) => i >= 100 && i < 121)).toBe(true); // 21-row group first, fills the cap
  });

  it('other groups are unchanged: Parked stays newest-first, not grouped', () => {
    const runs = [
      run(1, { state: 'held', marker: 'TESTS FAIL', repo: 'b', last_activity_at: ago(3), milestone: 'X' }),
      run(2, { state: 'held', marker: 'TESTS FAIL', repo: 'a', last_activity_at: ago(1), milestone: 'Y' }),
      run(3, { state: 'held', marker: 'TESTS FAIL', repo: 'b', last_activity_at: ago(2), milestone: 'X' }),
    ];
    expect(issuesOf(group({ mac: hostRecord({ runs }) }), H.parked)).toEqual([2, 3, 1]);
  });
});

describe('status-page README documents Needs JP grouping (#140 AC6)', () => {
  it('"Status groups" mentions milestone grouping, "no release" and runs[].milestone', async () => {
    const { readFileSync } = await import('node:fs');
    const md = readFileSync(new URL('../README.md', import.meta.url), 'utf8');
    const start = md.indexOf('### Status groups');
    expect(start).toBeGreaterThan(-1);
    const rest = md.slice(start + 5);
    const next = rest.search(/\n##+ /);
    const section = next === -1 ? rest : rest.slice(0, next);
    expect(section).toContain('milestone');
    expect(section).toContain('no release');
    expect(section).toContain('runs[].milestone');
  });
});
