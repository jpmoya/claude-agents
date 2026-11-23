// Status page alert banner (JP, 2026-11-19; pipeline-audit-2026-11-18, #762): the four alert families derived from what the hosts
// already publish. Expected values are hand-written from the thresholds in the brief (idle 10 min, tick 15 min, goal stall 6 h).

import { describe, it, expect, beforeAll, afterAll, vi } from 'vitest';
import { deriveAlerts, formatDuration, ALERT_LIST_MAX } from '../src/alerts.js';
import { validateBeatPayload } from '../src/validate.js';
import { renderPage } from '../src/render.js';
import { validPayload, validRun, hostRecord } from './fixtures.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;
const ago = (mins) => new Date((NOW - mins * 60) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const urlOf = (n) => `https://github.com/example-owner/project-a/issues/${n}`;
const run = (issue, o = {}) => validRun({ issue, url: urlOf(issue), title: `Ticket number ${issue} about something long`, last_activity_at: ago(60), ...o });
// a host that reported `reportedMinsAgo` minutes ago with its supervisor ticking `tickGapMins` before that report
const host = (o = {}) => {
  const { reportedMinsAgo = 1, tickGapMins = 1, runs = [], capacity = { running: 1, max: 3, queued: 0 }, ...rest } = o;
  const at = ago(reportedMinsAgo);
  return { ...hostRecord({ runs, received_at: at }), supervisor_last_tick: ago(reportedMinsAgo + tickGapMins), capacity, ...rest };
};
const ids = (alerts) => alerts.map((a) => a.id);
const derive = (mac, vm = null) => deriveAlerts({ mac, vm }, thresholds, NOW);
const queuedRun = (issue, minsAgo) => run(issue, { state: 'queued', started_at: ago(minsAgo), stage: '', marker: '' });

describe('formatDuration', () => {
  it('reads like a person would say it', () => {
    expect(formatDuration(7 * 60)).toBe('7 min');
    expect(formatDuration(125 * 60)).toBe('2 h 5 min');
    expect(formatDuration(180 * 60)).toBe('3 h');
  });
});

describe('healthy', () => {
  it('no alerts when both hosts are fresh, ticking, nothing queued or paused', () => {
    expect(derive(host(), host())).toEqual([]);
  });
  it('a host never seen raises nothing by itself', () => {
    expect(derive(host(), null)).toEqual([]);
    expect(derive(null, null)).toEqual([]);
  });
});

describe('alert 2 - idle slots while work waits', () => {
  const idle = (minsQueued, capacity = { running: 1, max: 3, queued: 2 }) =>
    derive(host({ capacity, runs: [queuedRun(1, minsQueued), queuedRun(2, 3)] }));
  it('fires per host when a slot is free and the oldest queued run has waited 11 minutes', () => {
    const a = idle(11);
    expect(ids(a)).toEqual(['idle-slots-mac']);
    expect(a[0].title).toBe('Mac has free run slots while tickets wait');
    expect(a[0].detail).toContain('2 of 3 slots are free');
    expect(a[0].detail).toContain('11 min');
    expect(a[0].severity).toBe('amber');
  });
  it('names the VM for the VM', () => {
    expect(ids(derive(null, host({ capacity: { running: 0, max: 5, queued: 1 }, runs: [queuedRun(1, 30)] })))).toEqual(['idle-slots-vm']);
  });
  it('is quiet at 9 minutes, when every slot is busy, and when nothing is queued', () => {
    expect(idle(9)).toEqual([]);
    expect(idle(40, { running: 3, max: 3, queued: 2 })).toEqual([]);
    expect(derive(host({ capacity: { running: 0, max: 3, queued: 0 }, runs: [] }))).toEqual([]);
  });
  it('does not count approved tickets as waiting work', () => {
    expect(derive(host({ capacity: { running: 0, max: 7, queued: 0 }, approved: [{ issue: 5, repo: 'project-a', url: urlOf(5) }] }))).toEqual([]);
  });
});

describe('alert 3 - paused tickets nobody is working on', () => {
  const held = (issue, o = {}) => run(issue, { state: 'held', marker: 'BLOCKED', gate_at: ago(120), ...o });
  const unowned = (runs, other = null) => derive(host({ runs }), other).find((a) => a.id === 'unowned-tickets');

  it('counts waiting-on-JP, answered-not-relaunched and parked tickets, each listed as "#n first five words (why)" linked to the issue', () => {
    const a = unowned([
      held(10, { marker: 'AWAITING GO', needs: 'Say go' }),
      held(11, { marker: 'DECISION' }),
      held(12, { marker: 'PASS' }),
    ]);
    expect(a.title).toBe('3 paused tickets have no one working on them');
    expect(a.detail).toBe('1 answered but never relaunched, 1 waiting on JP, 1 parked with nothing to resume them.');
    expect(a.items.map((i) => i.text)).toEqual([
      '#11 Ticket number 11 about something (answered, not relaunched)',
      '#10 Ticket number 10 about something (waiting on JP)',
      '#12 Ticket number 12 about something (paused, no one on it)',
    ]);
    expect(a.items[0].url).toBe(urlOf(11));
    expect(a.more).toBe(0);
  });
  it('a gate answered later (parked_reason answered) counts as answered, not relaunched', () => {
    const a = unowned([held(20, { parked_reason: 'answered' })]);
    expect(a.title).toBe('1 paused ticket has no one working on it');
    expect(a.items[0].text).toContain('(answered, not relaunched)');
  });
  it('leaves out auto-retry (the supervisor owns it), out-of-scope repos, finished tickets and running ones', () => {
    expect(
      unowned([
        held(30, { parked_reason: 'auto_retry' }),
        held(31, { parked_reason: 'out_of_scope' }),
        held(32, { marker: 'DEPLOYED TO STAGING' }),
        run(33, { state: 'running' }),
        run(34, { state: 'queued' }),
      ]),
    ).toBeUndefined();
  });
  it('a ticket running on the other host is not paused', () => {
    const mac = host({ runs: [held(40, { last_activity_at: ago(300) })] });
    const vm = host({ runs: [run(40, { state: 'running', last_activity_at: ago(2) })] });
    expect(derive(mac, vm).find((a) => a.id === 'unowned-tickets')).toBeUndefined();
  });
  it('lists at most ALERT_LIST_MAX tickets and counts the rest', () => {
    const many = Array.from({ length: 9 }, (_, i) => held(100 + i, { marker: 'PASS' }));
    const a = unowned(many);
    expect(ALERT_LIST_MAX).toBe(6);
    expect(a.title).toBe('9 paused tickets have no one working on them');
    expect(a.items).toHaveLength(6);
    expect(a.more).toBe(3);
  });
  it('a ticket with no title or url still lists, without a link', () => {
    const a = unowned([held(50, { title: undefined, url: undefined, marker: 'PASS' })]);
    expect(a.items[0]).toEqual({ text: '#50 ticket (paused, no one on it)', url: null });
  });
});

describe('alert 4 - supervisor slow, host not reporting', () => {
  it('fires when the last tick was 16 minutes before the last report, quiet at 14', () => {
    const a = derive(host({ tickGapMins: 16 }));
    expect(ids(a)).toEqual(['slow-tick-mac']);
    expect(a[0].detail).toContain('16 min');
    expect(derive(host({ tickGapMins: 14 }))).toEqual([]);
  });
  it('measures report minus tick, never now minus tick: an old-but-keepalive-fresh report is not a slow tick', () => {
    expect(derive(host({ reportedMinsAgo: 20, tickGapMins: 2 }))).toEqual([]);
  });
  it('a host silent for 30 minutes is stale (amber), for 80 minutes offline (red)', () => {
    const stale = derive(host({ reportedMinsAgo: 30 }));
    expect(ids(stale)).toEqual(['host-stale-mac']);
    expect(stale[0].severity).toBe('amber');
    const off = derive(null, host({ reportedMinsAgo: 80 }));
    expect(ids(off)).toEqual(['host-offline-vm']);
    expect(off[0].severity).toBe('red');
  });
  it('a stale host raises no other alert from its old data', () => {
    const old = host({ reportedMinsAgo: 40, tickGapMins: 30, capacity: { running: 0, max: 3, queued: 1 }, runs: [queuedRun(1, 90), run(2, { state: 'held', marker: 'PASS' })] });
    expect(ids(derive(old))).toEqual(['host-stale-mac']);
  });
});

describe('alert 1 - a goal stalls the goal queue', () => {
  const stall = (o = {}) => ({ kind: 'project_error', goal: 'CD hardening', reason: 'the project is closed', hint: 'reopen the project', ...o });
  const goal = (o) => ({ id: 'g', title: 'Holder', host: 'vm', state: 'running', slot: 'holds', ...o });
  const waiting = { id: 'q', title: 'Waiter', host: '', state: 'queued', queue_pos: 1, slot: 'waits' };

  it('a goal that cannot be read is amber, names the goal and the reason, and says it blocks nothing else', () => {
    const a = derive(host({ goal_stall: [stall()], tickGapMins: 20 }));
    expect(a[0].id).toBe('goal-stall-1');
    expect(a[0].severity).toBe('amber');
    expect(a[0].title).toBe('CD hardening cannot be read (the project is closed); it is skipped, other goals unaffected');
    expect(a[0].detail).toBe('The goal queue goes on without it, in the same priority order.');
    expect(a[0].hint).toBe('reopen the project');
    expect(ids(a)).toEqual(['goal-stall-1', 'slow-tick-mac']);
  });
  it('an older reporter that still sends blocked names gets the same amber, skipped text (the names are not shown)', () => {
    const a = derive(host({ goal_stall: [stall({ blocked: ['Sales Workflow 3.0', 'Plants'] })] }));
    expect(a[0].severity).toBe('amber');
    expect(a[0].title).toBe('CD hardening cannot be read (the project is closed); it is skipped, other goals unaffected');
    expect(a[0].detail).not.toContain('Sales Workflow');
  });
  it('the same stall reported by both hosts shows once', () => {
    expect(ids(derive(host({ goal_stall: [stall()] }), host({ goal_stall: [stall()] })))).toEqual(['goal-stall-1']);
  });
  it('a slot holder whose lead has not cycled for 7 hours, with a goal queued, is stalling it (red, unchanged)', () => {
    const a = derive(host({ goals: [goal({ last_cycle_at: ago(7 * 60) }), waiting] }));
    expect(a).toHaveLength(1);
    expect(a[0].title).toBe('Goal queue stalled by Holder');
    expect(a[0].detail).toBe('It holds the goal slot but its delivery lead has not cycled for 7 h. Waiting behind it: Waiter.');
  });
  it('is quiet at 5 hours, with no queued goal, and with no cycle timestamp at all', () => {
    expect(derive(host({ goals: [goal({ last_cycle_at: ago(5 * 60) }), waiting] }))).toEqual([]);
    expect(derive(host({ goals: [goal({ last_cycle_at: ago(9 * 60) })] }))).toEqual([]);
    expect(derive(host({ goals: [goal({}), waiting] }))).toEqual([]);
  });
});

describe('validate.js - goal_stall', () => {
  const sanitised = (goal_stall) => {
    const r = validateBeatPayload(validPayload({ goal_stall }));
    expect(r.ok).toBe(true);
    return r.value.goal_stall;
  };
  const ok = { kind: 'unreadable', goal: 'registry issue #12', reason: 'its goal block cannot be read', hint: 'fix or close registry issue #12' };
  it('keeps a well-formed entry, with or without the optional blocked names of an older reporter', () => {
    expect(sanitised([ok])).toEqual([ok]);
    expect(sanitised([{ ...ok, blocked: ['A', 'B'] }])).toEqual([{ ...ok, blocked: ['A', 'B'] }]);
  });
  it('drops unknown kinds, markup, and non-arrays; never rejects the beat; blocked is optional', () => {
    expect(sanitised([{ ...ok, kind: 'other' }])).toBeUndefined();
    expect(sanitised([{ ...ok, reason: '<script>x</script>' }])).toBeUndefined();
    expect(sanitised([{ ...ok, blocked: [] }])).toEqual([ok]);
    expect(sanitised([{ ...ok, blocked: 'A' }])).toEqual([ok]);
    expect(sanitised('nope')).toBeUndefined();
    expect(sanitised([ok, 7, null])).toEqual([ok]);
  });
  it('drops markup from a blocked name but keeps the rest; keeps at most 5 entries and 10 names', () => {
    expect(sanitised([{ ...ok, blocked: ['<b>', 'Fine'] }])[0].blocked).toEqual(['Fine']);
    expect(sanitised(Array.from({ length: 8 }, () => ok))).toHaveLength(5);
    expect(sanitised([{ ...ok, blocked: Array.from({ length: 14 }, (_, i) => `G${i}`) }])[0].blocked).toHaveLength(10);
  });
});

describe('render.js - banner', () => {
  const full = (mac, vm = null) => renderPage({ mac, vm }, thresholds, NOW);
  const render = (mac, vm = null) => { const h = full(mac, vm); return h.slice(h.indexOf('</style>')); }; // markup only, not the stylesheet
  it('shows a small green all-clear line when healthy, and nothing before any host reported', () => {
    expect(render(host())).toContain('data-testid="alerts-clear"');
    expect(render(host())).not.toContain('data-testid="pipeline-alerts"');
    const none = render(null);
    expect(none).not.toContain('alerts-clear');
    expect(none).not.toContain('pipeline-alerts');
  });
  it('shows one banner above the host blocks with every active alert, reason and fix hint', () => {
    const html = render(host({ tickGapMins: 20, runs: [run(7, { state: 'held', marker: 'PASS' })] }));
    expect(html).not.toContain('alerts-clear');
    expect(html.indexOf('data-testid="pipeline-alerts"')).toBeGreaterThan(html.indexOf('<h1>'));
    expect(html.indexOf('data-testid="pipeline-alerts"')).toBeLessThan(html.indexOf('<section class="host">'));
    expect(html).toContain('2 pipeline alerts');
    expect(html).toContain('The Mac supervisor is slow');
    expect(html).toContain('Fix: Check the Mac supervisor log');
    expect(html).toContain(`<a href="${urlOf(7)}"`);
  });
  it('the banner is amber unless an alert is red', () => {
    expect(render(host({ tickGapMins: 20 }))).toContain('<section class="alerts" data-testid');
    expect(render(host({ reportedMinsAgo: 80 }))).toContain('<section class="alerts alerts-red" data-testid');
  });
  it('escapes every alert value (a stall reason containing a script tag renders inert)', () => {
    const evil = { kind: 'project_error', goal: '<img src=x onerror=1>', reason: '<script>alert(1)</script>', hint: '"><b>' };
    const html = render(host({ goal_stall: [evil] }));
    expect(html).not.toContain('<script>alert(1)');
    expect(html).not.toContain('<img src=x');
    expect(html).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
  });
  it('uses the theme colour variables, so light and dark both work', () => {
    const html = full(host({ tickGapMins: 20 }));
    expect(html).toContain('.alerts li.alert-red { border-left-color: var(--red); background: var(--red-soft); }');
    expect(html).toContain('.alerts-clear {');
    expect(html).not.toMatch(/\.alerts[^{]*\{[^}]*#[0-9a-fA-F]{3,6}/);
  });
});

describe('alert 1b - a host gh token lost a required scope (gh-scope.sh)', () => {
  // deriveAlerts is pure and takes NOW; the clock is pinned anyway so nothing in the fixtures or validate.js can read the real one.
  beforeAll(() => { vi.useFakeTimers(); vi.setSystemTime(NOW * 1000); });
  afterAll(() => { vi.useRealTimers(); });
  const tok = (o = {}) => ({ kind: 'token_scope', goal: 'mac', reason: 'project', hint: 'run gh auth refresh -h github.com -s project on mac', ...o });
  it('is red, names the host and the scope, and carries the fix command', () => {
    const a = derive(host({ goal_stall: [tok()] }));
    expect(ids(a)).toEqual(['gh-token-scope-mac']);
    expect(a[0].severity).toBe('red');
    expect(a[0].title).toBe('The GitHub login on mac is missing the project permission');
    expect(a[0].hint).toBe('run gh auth refresh -h github.com -s project on mac');
  });
  it('shows even when the OTHER host owns the goal snapshot, and once per host', () => {
    const vm = host({ goals_as_of: ago(1), goals: [] });
    const a = derive(host({ goal_stall: [tok()] }), vm);
    expect(ids(a)).toEqual(['gh-token-scope-mac']);
    expect(ids(derive(host({ goal_stall: [tok()] }), host({ goal_stall: [tok({ goal: 'vm', reason: 'project, workflow' })] })))).toEqual(['gh-token-scope-mac', 'gh-token-scope-vm']);
  });
  it('the same host reported in both records shows once', () => {
    expect(ids(derive(host({ goal_stall: [tok()] }), host({ goal_stall: [tok(), tok({ reason: 'workflow' })] })))).toEqual(['gh-token-scope-mac']);
  });
  it('is not also listed as an unreadable goal', () => {
    expect(ids(derive(host({ goal_stall: [tok()] })))).toEqual(['gh-token-scope-mac']);
  });
  it('validate.js keeps a token_scope entry', () => {
    const r = validateBeatPayload(validPayload({ goal_stall: [tok()] }));
    expect(r.ok).toBe(true);
    expect(r.value.goal_stall).toEqual([tok()]);
  });
});
