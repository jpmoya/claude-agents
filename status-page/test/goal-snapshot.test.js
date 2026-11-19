// #795: the Goals section and the goal alerts come from ONE host's fresh snapshot (`goals_as_of`), never from whichever host's local file wins.
// Expected values are hand-written. Ages are measured against a fixed NOW.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { selectGoalSnapshot, GOAL_SNAPSHOT_MAX_AGE_MINUTES } from '../src/goal-snapshot.js';
import { deriveAlerts } from '../src/alerts.js';
import { renderPage } from '../src/render.js';
import { validPayload, hostRecord } from './fixtures.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-11-19T12:00:00Z') / 1000;
const ago = (mins) => new Date((NOW - mins * 60) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const text = (s) => s.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
const goalsSection = (html) => (/<section class="group">\s*<h2>Goals<\/h2>[\s\S]*?<\/section>/.exec(html) || [''])[0];
const ids = (alerts) => alerts.map((a) => a.id);

const g = (o) => ({ id: 'a', title: 'Alpha', repos: ['org/r'], host: 'vm', state: 'between_cycles', priority: 1, ...o });
const rec = (goals, { asOf, receivedMins = 1, ...extra } = {}) => {
  const r = { ...hostRecord({ received_at: ago(receivedMins) }), goals, ...extra };
  if (asOf !== undefined) r.goals_as_of = ago(asOf);
  return r;
};
const render = (mac, vm) => renderPage({ mac, vm }, thresholds, NOW);

describe('validate.js: goals_as_of', () => {
  it('keeps an ISO UTC timestamp and drops anything else', () => {
    expect(validateBeatPayload(validPayload({ goals_as_of: '2026-11-19T11:55:00Z' })).value.goals_as_of).toBe('2026-11-19T11:55:00Z');
    for (const bad of ['yesterday', 12345, '<script>', '2026-11-19 11:55:00', null]) {
      const r = validateBeatPayload(validPayload({ goals_as_of: bad }));
      expect(r.ok).toBe(true);
      expect(r.value).not.toHaveProperty('goals_as_of');
    }
  });
});

describe('selectGoalSnapshot', () => {
  it('uses a 30 minute limit', () => expect(GOAL_SNAPSHOT_MAX_AGE_MINUTES).toBe(30));

  it('legacy: no host publishes goals_as_of', () => {
    expect(selectGoalSnapshot({ mac: rec([g()]), vm: rec([g()]) }, thresholds, NOW).mode).toBe('legacy');
    expect(selectGoalSnapshot({ mac: null, vm: null }, thresholds, NOW).mode).toBe('legacy');
  });

  it('two hosts disagree: the fresher snapshot wins', () => {
    const sel = selectGoalSnapshot({ mac: rec([g({ priority: 2 })], { asOf: 20 }), vm: rec([g({ priority: 1 })], { asOf: 3 }) }, thresholds, NOW);
    expect(sel.mode).toBe('snapshot');
    expect(sel.key).toBe('vm');
    expect(sel.goals[0].priority).toBe(1);
    expect(sel.ageSecs).toBe(180);
    const flipped = selectGoalSnapshot({ mac: rec([g({ priority: 2 })], { asOf: 2 }), vm: rec([g({ priority: 1 })], { asOf: 9 }) }, thresholds, NOW);
    expect(flipped.key).toBe('mac');
  });

  it('a tie within a minute prefers the VM', () => {
    const sel = selectGoalSnapshot({ mac: rec([g()], { asOf: 4 }), vm: rec([g()], { asOf: 4.5 }) }, thresholds, NOW);
    expect(sel.key).toBe('vm');
    const macNewerByHalfMinute = selectGoalSnapshot({ mac: rec([g()], { asOf: 4 }), vm: rec([g()], { asOf: 4.5 }) }, thresholds, NOW);
    expect(macNewerByHalfMinute.key).toBe('vm');
    const macNewerByFiveMinutes = selectGoalSnapshot({ mac: rec([g()], { asOf: 2 }), vm: rec([g()], { asOf: 7 }) }, thresholds, NOW);
    expect(macNewerByFiveMinutes.key).toBe('mac');
  });

  it('a host that stopped reporting is ignored even with a fresh-looking snapshot', () => {
    const sel = selectGoalSnapshot({ mac: rec([g({ priority: 2 })], { asOf: 1, receivedMins: 300 }), vm: rec([g({ priority: 1 })], { asOf: 25 }) }, thresholds, NOW);
    expect(sel.mode).toBe('snapshot');
    expect(sel.key).toBe('vm');
  });

  it('a live host whose registry sync stopped (snapshot older than 30 minutes) is ignored', () => {
    const sel = selectGoalSnapshot({ mac: rec([g({ priority: 2 })], { asOf: 31 }), vm: rec([g({ priority: 1 })], { asOf: 12 }) }, thresholds, NOW);
    expect(sel.key).toBe('vm');
    expect(selectGoalSnapshot({ mac: rec([g()], { asOf: 31 }), vm: null }, thresholds, NOW).mode).toBe('stale');
  });

  it('both stale: stale, naming the newest copy', () => {
    const sel = selectGoalSnapshot({ mac: rec([g()], { asOf: 90 }), vm: rec([g()], { asOf: 45 }) }, thresholds, NOW);
    expect(sel).toEqual({ mode: 'stale', key: 'vm', ageSecs: 45 * 60 });
  });

  it('a snapshot with no goals is still a fresh snapshot', () => {
    const r = rec([], { asOf: 2 });
    delete r.goals;
    const sel = selectGoalSnapshot({ mac: null, vm: r }, thresholds, NOW);
    expect(sel.mode).toBe('snapshot');
    expect(sel.goals).toEqual([]);
  });

  it('the host a goal runs on may only raise it to running and supply its cycle time and scope', () => {
    const vmRows = [g({ id: 'm', title: 'Mac goal', host: 'mac', state: 'between_cycles', priority: 1, slot: 'holds' })];
    const macRows = [g({ id: 'm', title: 'Mac goal (own)', host: 'mac', state: 'running', priority: 7, slot: undefined, last_cycle_at: '2026-11-19T11:50:00Z', scope_total: 4, scope_delivered: 2 })];
    const sel = selectGoalSnapshot({ mac: rec(macRows, { asOf: 3 }), vm: rec(vmRows, { asOf: 1 }) }, thresholds, NOW);
    expect(sel.key).toBe('vm');
    expect(sel.goals[0]).toMatchObject({ title: 'Mac goal', state: 'running', priority: 1, slot: 'holds', last_cycle_at: '2026-11-19T11:50:00Z', scope_total: 4, scope_delivered: 2 });
  });

  it('a stopped host does not overlay running onto the snapshot', () => {
    const vmRows = [g({ id: 'm', host: 'mac', state: 'between_cycles' })];
    const macRows = [g({ id: 'm', host: 'mac', state: 'running' })];
    const sel = selectGoalSnapshot({ mac: rec(macRows, { asOf: 3, receivedMins: 300 }), vm: rec(vmRows, { asOf: 1 }) }, thresholds, NOW);
    expect(sel.goals[0].state).toBe('between_cycles');
  });
});

describe('the Goals section', () => {
  it('the incident: a stale Mac queue does not make its goals the slot holder or its priorities win', () => {
    const mac = rec([g({ id: 's', title: 'Sales Workflow 3.0', host: 'mac', state: 'running', slot: 'holds', priority: 2 })], { asOf: 300, receivedMins: 300 });
    const vm = rec([g({ id: 'p', title: 'Plants Goal', host: 'vm', state: 'running', slot: 'holds', priority: 1 }), g({ id: 's', title: 'Sales Workflow 3.0', host: '', state: 'queued', slot: 'waits', priority: 3, queue_pos: 1 })], { asOf: 2 });
    const section = text(goalsSection(render(mac, vm)));
    expect(section).toContain('From the VM · registry read 2 min ago');
    expect(section.indexOf('Plants Goal')).toBeLessThan(section.indexOf('Sales Workflow 3.0'));
    expect(section.match(/HOLDS GOAL SLOT ·/g)).toHaveLength(1); // the legend above the table says it without a host
    expect(section).not.toContain('HOLDS GOAL SLOT · Mac');
    expect(section).toContain('waiting for slot');
  });

  it('shows no rows from stale data, and says why', () => {
    const section = text(goalsSection(render(rec([g({ title: 'Old Goal' })], { asOf: 50 }), null)));
    expect(section).not.toContain('Old Goal');
    expect(section).toContain('No host has a current goal list');
    expect(section).toContain('is 50 min old');
  });

  it('old beats (no goals_as_of anywhere) render exactly as before: no source line', () => {
    const section = text(goalsSection(render(rec([g({ title: 'Legacy Goal' })]), null)));
    expect(section).toContain('Legacy Goal');
    expect(section).not.toContain('registry read');
  });

  it('escapes nothing it should not trust: the producing host is a fixed label', () => {
    const html = render(null, rec([g()], { asOf: 5 }));
    expect(goalsSection(html)).toContain('From the VM');
  });
});

describe('goal alerts', () => {
  it('both hosts stale: one amber alert, no goal-stall alert from the stale data', () => {
    const stall = [{ kind: 'unreadable', goal: 'registry issue #9', reason: 'x', hint: 'h', blocked: ['A'] }];
    const alerts = deriveAlerts({ mac: rec([g()], { asOf: 90, goal_stall: stall }), vm: rec([g()], { asOf: 45, goal_stall: stall }) }, thresholds, NOW);
    expect(ids(alerts)).toEqual(['goal-snapshot-stale']);
    expect(alerts[0].severity).toBe('amber');
    expect(alerts[0].detail).toContain('45 min old (from the VM)');
  });

  it('a fresh snapshot raises no stale alert, and only the winner\'s goal_stall counts', () => {
    const stall = [{ kind: 'unreadable', goal: 'registry issue #9', reason: 'its block cannot be read', hint: 'fix it', blocked: ['A'] }];
    const none = deriveAlerts({ mac: rec([g()], { asOf: 1 }), vm: rec([g()], { asOf: 2 }) }, thresholds, NOW);
    expect(ids(none)).toEqual([]);
    const staleMacStall = deriveAlerts({ mac: rec([g()], { asOf: 25, goal_stall: stall }), vm: rec([g()], { asOf: 2 }) }, thresholds, NOW);
    expect(ids(staleMacStall)).toEqual([]);
    const winnerStall = deriveAlerts({ mac: rec([g()], { asOf: 25 }), vm: rec([g()], { asOf: 2, goal_stall: stall }) }, thresholds, NOW);
    expect(ids(winnerStall)).toEqual(['goal-stall-1']);
  });

  it('the slot-holder-idle alert reads the snapshot, not a stale host\'s holder', () => {
    const idleHolder = g({ id: 'h', title: 'Holder', host: 'mac', state: 'running', slot: 'holds', last_cycle_at: ago(7 * 60) });
    const waiter = g({ id: 'q', title: 'Waiter', host: '', state: 'queued', slot: 'waits', queue_pos: 1, priority: 2 });
    const staleMac = rec([idleHolder, waiter], { asOf: 25 });
    const freshVm = rec([g({ id: 'v', title: 'Other', host: 'vm', state: 'running', slot: 'holds', last_cycle_at: ago(5) }), { ...waiter }], { asOf: 1 });
    expect(ids(deriveAlerts({ mac: staleMac, vm: freshVm }, thresholds, NOW))).toEqual([]);
    const alerts = deriveAlerts({ mac: null, vm: rec([idleHolder, waiter], { asOf: 1 }) }, thresholds, NOW);
    expect(ids(alerts)).toEqual(['goal-stall-1']);
    expect(alerts[0].hint).toContain('on the Mac');
  });

  it('old beats: no goals_as_of anywhere raises no stale alert', () => {
    expect(ids(deriveAlerts({ mac: rec([g()]), vm: rec([g()]) }, thresholds, NOW))).toEqual([]);
  });
});
