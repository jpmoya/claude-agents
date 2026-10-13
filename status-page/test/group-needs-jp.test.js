// #139 rules 2-5 in groupTickets: parked_reason demotion, 14-day staleness (max of gate_at and
// last_activity_at), Parked 7-day-hide exemption for demoted rows. Expected values hand-derived
// from the ticket's rules; days are converted to hours with the same `ago` helper as group.test.js.

import { describe, it, expect } from 'vitest';
import { groupTickets } from '../src/group.js';
import { validRun, hostRecord } from './fixtures.js';

const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;
const ago = (hours) => new Date((NOW - hours * 3600) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const days = (d) => d * 24;
const urlOf = (n) => `https://github.com/example-owner/project-a/issues/${n}`;
const NEEDS = 'Needs JP';
const PARKED = 'Parked';

const held = (issue, o = {}) =>
  validRun({ issue, url: urlOf(issue), title: `T${issue}`, state: 'held', marker: 'BLOCKED', last_activity_at: ago(1), ...o });
const group = (runs) => groupTickets({ mac: hostRecord({ runs }), vm: null }, NOW);
const issuesOf = (g, heading) => g.find((x) => x.heading === heading).rows.map((r) => r.issue);
/** A run with the timestamps given in days, `undefined` = key absent. */
const aged = (issue, { gate, act, ...o } = {}) => {
  const run = held(issue, o);
  delete run.last_activity_at;
  if (act !== undefined) run.last_activity_at = ago(days(act));
  if (gate !== undefined) run.gate_at = ago(days(gate));
  return run;
};

describe('#139 rule 4 — staleness: max(gate_at, last_activity_at) older than 14 days -> Parked', () => {
  it('gate_at 15d and last_activity 15d -> Parked, visible despite the 7-day hide', () => {
    const g = group([aged(1, { gate: 15, act: 15 })]);
    expect(issuesOf(g, PARKED)).toEqual([1]);
    expect(issuesOf(g, NEEDS)).toEqual([]);
  });

  it('gate_at 15d but last_activity 2d ago -> stays in Needs JP', () => {
    const g = group([aged(2, { gate: 15, act: 2 })]);
    expect(issuesOf(g, NEEDS)).toEqual([2]);
    expect(issuesOf(g, PARKED)).toEqual([]);
  });

  it('gate_at 13d (last_activity 13d) -> stays in Needs JP', () => {
    expect(issuesOf(group([aged(3, { gate: 13, act: 13 })]), NEEDS)).toEqual([3]);
  });

  it('boundary: exactly 14d is "not older than 14 days" -> Needs JP; 14d + 1h -> Parked', () => {
    const g = group([aged(4, { gate: 14, act: 14 }), aged(5, { gate: 14, act: 14 }), ]);
    expect(issuesOf(g, NEEDS).sort()).toEqual([4, 5]);
    const stale = group([{ ...aged(6, { act: 14 }), gate_at: ago(days(14) + 1), last_activity_at: ago(days(14) + 1) }]);
    expect(issuesOf(stale, PARKED)).toEqual([6]);
  });

  it('gate_at missing: falls back to last_activity_at alone (15d -> Parked, 13d -> Needs JP)', () => {
    const g = group([aged(7, { act: 15 }), aged(8, { act: 13 })]);
    expect(issuesOf(g, PARKED)).toEqual([7]);
    expect(issuesOf(g, NEEDS)).toEqual([8]);
  });

  it('gate_at 2d old but last_activity 15d old -> Needs JP (the later timestamp wins)', () => {
    expect(issuesOf(group([aged(9, { gate: 2, act: 15 })]), NEEDS)).toEqual([9]);
  });

  it('no gate_at and no last_activity_at -> stays in Needs JP', () => {
    expect(issuesOf(group([aged(10, {})]), NEEDS)).toEqual([10]);
  });

  it('unparseable gate_at is treated as missing', () => {
    const run = aged(11, { act: 15 });
    run.gate_at = 'yesterday';
    expect(issuesOf(group([run]), PARKED)).toEqual([11]);
  });

  it.each(['MOCKUPS PENDING APPROVAL', 'AWAITING GO', 'EFFORT APPROVAL NEEDED', 'BLOCKED'])('stale %s -> Parked', (marker) => {
    expect(issuesOf(group([aged(12, { gate: 20, act: 20, marker })]), PARKED)).toEqual([12]);
  });
});

describe('#139 rules 2-3 — parked_reason set by the host demotes to Parked', () => {
  it.each(['answered', 'out_of_scope'])('parked_reason %s -> Parked, not Needs JP (fresh timestamps)', (reason) => {
    const g = group([held(1, { parked_reason: reason })]);
    expect(issuesOf(g, PARKED)).toEqual([1]);
    expect(issuesOf(g, NEEDS)).toEqual([]);
  });

  it('a held Needs-marker run with no parked_reason and fresh timestamps stays in Needs JP (control)', () => {
    expect(issuesOf(group([held(2)]), NEEDS)).toEqual([2]);
  });

  it('a demoted row keeps the fields the page renders (issue, title, marker, host) — nothing is deleted', () => {
    const row = group([held(3, { parked_reason: 'answered', marker: 'AWAITING GO' })]).find((x) => x.heading === PARKED).rows[0];
    expect(row).toMatchObject({ issue: 3, title: 'T3', marker: 'AWAITING GO', host: 'mac' });
  });
});

describe('#139 rule 5 — Parked 7-day hide: demoted rows exempt, ordinary rows still hidden', () => {
  it('demoted rows (answered / out_of_scope / stale) 30 days old are shown in Parked', () => {
    const g = group([
      held(1, { parked_reason: 'answered', last_activity_at: ago(days(30)) }),
      held(2, { parked_reason: 'out_of_scope', last_activity_at: ago(days(30)) }),
      aged(3, { gate: 30, act: 30 }),
    ]);
    expect(issuesOf(g, PARKED).sort((a, b) => a - b)).toEqual([1, 2, 3]);
  });

  it('an ordinary Parked row (no reason, non-Needs marker) 8 days old is still hidden', () => {
    const g = group([held(4, { marker: 'PASS', last_activity_at: ago(days(8)) })]);
    expect(issuesOf(g, PARKED)).toEqual([]);
  });

  it('an ordinary Parked row 6 days old is still shown (control)', () => {
    const g = group([held(5, { marker: 'PASS', last_activity_at: ago(days(6)) })]);
    expect(issuesOf(g, PARKED)).toEqual([5]);
  });

  it('Parked cap of 10 still applies to demoted rows, newest first', () => {
    // issue i has last activity i days ago (i = 1..12) -> newest 10 are issues 1..10
    const runs = Array.from({ length: 12 }, (_v, i) => held(i + 1, { parked_reason: 'answered', last_activity_at: ago(days(i + 1)) }));
    expect(issuesOf(group(runs), PARKED)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  });
});
