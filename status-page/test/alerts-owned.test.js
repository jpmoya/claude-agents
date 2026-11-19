// #780 AC5: the "paused tickets have no one working on them" alert counts only UNOWNED tickets. A ticket is owned while a run on any host
// holds it (running, restarting, queued) or while JP's answer is within the grace the supervisor needs to relaunch it (answered_at,
// published by the host). Expected values are hand-written from the ticket: grace 10 minutes (2 supervisor ticks).

import { describe, it, expect } from 'vitest';
import { deriveAlerts, ANSWER_GRACE_MINUTES } from '../src/alerts.js';
import { validateBeatPayload } from '../src/validate.js';
import { validRun, validPayload, hostRecord } from './fixtures.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;
const ago = (mins) => new Date((NOW - mins * 60) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const urlOf = (n) => `https://github.com/example-owner/project-a/issues/${n}`;
const run = (issue, o = {}) => validRun({ issue, url: urlOf(issue), title: `Ticket number ${issue} about something long`, last_activity_at: ago(60), ...o });
const held = (issue, o = {}) => run(issue, { state: 'held', marker: 'BLOCKED', gate_at: ago(120), needs: 'Decision needed', ...o });
const host = (runs) => ({ ...hostRecord({ runs, received_at: ago(1) }), supervisor_last_tick: ago(2), capacity: { running: 1, max: 3, queued: 0 } });
const unowned = (mac, vm = null) => deriveAlerts({ mac, vm }, thresholds, NOW).find((a) => a.id === 'unowned-tickets');

describe('#780 unowned-tickets alert: owned tickets are left out', () => {
  it('the grace is 10 minutes (two supervisor ticks)', () => {
    expect(ANSWER_GRACE_MINUTES).toBe(10);
  });

  it('answered and relaunched: the run is queued or running now, so the ticket is not in the banner', () => {
    expect(unowned(host([run(10, { state: 'queued', marker: 'BLOCKED', started_at: ago(1) })]))).toBeUndefined();
    expect(unowned(host([run(11, { state: 'running' })]))).toBeUndefined();
  });

  it('answered and pending, within the grace: owned, not listed, and not counted in the title', () => {
    expect(unowned(host([held(20, { answered_at: ago(3) })]))).toBeUndefined();
    const a = unowned(host([held(20, { answered_at: ago(10) }), held(21)]));   // exactly at the grace is still pending
    expect(a.title).toBe('1 paused ticket has no one working on it');
    expect(a.items.map((i) => i.text)).toEqual(['#21 Ticket number 21 about something (waiting on JP)']);
  });

  it('answered and stuck, past the grace: listed as answered but not relaunched', () => {
    const a = unowned(host([held(30, { answered_at: ago(11) })]));
    expect(a.title).toBe('1 paused ticket has no one working on it');
    expect(a.detail).toBe('1 answered but never relaunched.');
    expect(a.items).toEqual([{ text: '#30 Ticket number 30 about something (answered, not relaunched)', url: urlOf(30) }]);
  });

  it('no answer: still counted as waiting on JP, as before', () => {
    const a = unowned(host([held(40, { marker: 'AWAITING GO', needs: 'Say go' })]));
    expect(a.items[0].text).toBe('#40 Ticket number 40 about something (waiting on JP)');
  });

  it('a live run on the other host owns the ticket even when the held copy looks newer', () => {
    const mac = host([held(50, { last_activity_at: ago(1) })]);
    const vm = host([run(50, { state: 'running', last_activity_at: ago(30) })]);
    expect(unowned(mac, vm)).toBeUndefined();
    const vmQueued = host([run(50, { state: 'queued', last_activity_at: ago(30), started_at: ago(30) })]);
    expect(unowned(mac, vmQueued)).toBeUndefined();
  });

  it('title count and items agree when owned and unowned tickets are mixed', () => {
    const mac = host([
      held(60, { answered_at: ago(2) }),                       // pending: owned
      held(61, { answered_at: ago(40) }),                      // stuck: counted
      held(62),                                                // waiting on JP: counted
      held(63, { marker: 'PASS', needs: undefined }),          // parked, nothing to resume it: counted
      held(64),                                                // owned by a run on the VM
    ]);
    const vm = host([run(64, { state: 'running' })]);
    const a = unowned(mac, vm);
    expect(a.title).toBe('3 paused tickets have no one working on them');
    expect(a.items).toHaveLength(3);
    expect(a.more).toBe(0);
    expect(a.items.map((i) => i.text.slice(0, 3))).toEqual(['#61', '#62', '#63']);
  });

  it('answered_at survives validation as a timestamp and is dropped when malformed', () => {
    const r = validateBeatPayload(validPayload({ runs: [held(70, { answered_at: ago(3) }), held(71, { answered_at: 'yesterday' })] }));
    expect(r.ok).toBe(true);
    expect(r.value.runs.find((x) => x.issue === 70).answered_at).toBe(ago(3));
    expect(r.value.runs.find((x) => x.issue === 71).answered_at).toBeUndefined();
  });
});
