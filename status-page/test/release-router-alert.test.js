// #769: "release router has not fired in N minutes" alert, derived from the hosts' published `scheduled_triggers[]`, and the validator
// that lets that key through /beat. Expected values are hand-written: auto-release every 5 min, alert past 3 x 5 = 15 min plus the
// 10-minute allowance for the beat's keep-alive (last_fired_at is kept out of the host's change hash, so the stored value can lag).

import { describe, it, expect } from 'vitest';
import { deriveAlerts } from '../src/alerts.js';
import { validateBeatPayload } from '../src/validate.js';
import { validPayload, hostRecord } from './fixtures.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-11-19T12:00:00Z') / 1000;
const ago = (mins) => new Date((NOW - mins * 60) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const trigger = (minsAgo, o = {}) => ({
  repo: 'ops', workflow: 'auto-release.yml', interval_minutes: 5, last_fired_at: minsAgo === null ? null : ago(minsAgo), ...o,
});
const host = (scheduled_triggers) => ({ ...hostRecord({ runs: [], received_at: ago(1) }), supervisor_last_tick: ago(2), capacity: { running: 0, max: 3, queued: 0 }, scheduled_triggers });
const derive = (mac, vm = null) => deriveAlerts({ mac, vm }, thresholds, NOW);
const router = (alerts) => alerts.filter((a) => a.id.startsWith('release-router-'));

describe('release router alert', () => {
  it('fires red when the newest fire is older than 3 intervals plus the report lag, and says how long', () => {
    const a = router(derive(host([trigger(26)])));
    expect(a).toHaveLength(1);
    expect(a[0].severity).toBe('red');
    expect(a[0].title).toBe('The ops release router has not fired in 26 minutes');
    expect(a[0].detail).toContain('every 5 minutes');
  });
  it('is quiet at 25 minutes and when it fired a minute ago', () => {
    expect(router(derive(host([trigger(25)])))).toEqual([]);
    expect(router(derive(host([trigger(1)])))).toEqual([]);
  });
  it('is quiet when no fire was ever reported (just enabled), and for workflows that are not the release router', () => {
    expect(router(derive(host([trigger(null)])))).toEqual([]);
    // same 5-minute interval and an age far past the threshold: only the workflow name keeps it quiet
    expect(router(derive(host([trigger(60, { workflow: 'stale-prs.yml', interval_minutes: 5 })])))).toEqual([]);
  });
  it('scales with the interval: 10 minutes gives 3 x 10 + 10 = 40 quiet, 41 red', () => {
    expect(router(derive(host([trigger(40, { interval_minutes: 10 })])))).toEqual([]);
    expect(router(derive(host([trigger(41, { interval_minutes: 10 })])))).toHaveLength(1);
  });
  it('uses the newest fire across both hosts: one host dispatching keeps it quiet', () => {
    expect(router(derive(host([trigger(120)]), host([trigger(3)])))).toEqual([]);
    expect(router(derive(host([trigger(120)]), host([trigger(90)])))).toHaveLength(1);
  });
  it('one alert per repo, so two repos each get their own', () => {
    const a = router(derive(host([trigger(60), trigger(60, { repo: 'sales' }), trigger(1, { repo: 'quoting' })])));
    expect(a.map((x) => x.title)).toEqual([
      'The ops release router has not fired in 60 minutes',
      'The sales release router has not fired in 60 minutes',
    ]);
  });
  it('a stale host raises only the host alert, never a router alert from its old data', () => {
    const stale = { ...host([trigger(500)]), received_at: ago(30) };
    const alerts = derive(stale);
    expect(alerts.map((a) => a.id)).toEqual(['host-stale-mac']);
  });
  it('a host that publishes no scheduled_triggers raises nothing', () => {
    expect(router(derive(host(undefined)))).toEqual([]);
  });
});

describe('validate.js - scheduled_triggers', () => {
  const sanitised = (scheduled_triggers) => {
    const r = validateBeatPayload(validPayload({ scheduled_triggers }));
    expect(r.ok).toBe(true);
    return r.value.scheduled_triggers;
  };
  it('keeps a valid entry by reconstruction (extra keys dropped)', () => {
    expect(sanitised([{ ...trigger(1), last_fired_at: '2026-11-19T11:59:00Z', command: 'rm -rf /' }])).toEqual([
      { repo: 'ops', workflow: 'auto-release.yml', interval_minutes: 5, last_fired_at: '2026-11-19T11:59:00Z' },
    ]);
  });
  it('keeps a null fire time, drops entries with a bad repo, workflow name or interval, and omits the key when none survive', () => {
    expect(sanitised([trigger(null)])[0].last_fired_at).toBeNull();
    expect(sanitised([trigger(1, { repo: 'a b' }), trigger(1, { workflow: '../x.yml' }), trigger(1, { workflow: 'x.sh' }), trigger(1, { interval_minutes: 0 }), trigger(1, { interval_minutes: '5' })])).toBeUndefined();
    expect(sanitised('nope')).toBeUndefined();
    expect(sanitised([trigger(1, { last_fired_at: 'yesterday' })])[0].last_fired_at).toBeNull();
  });
  it('caps the list at 50 entries', () => {
    expect(sanitised(Array.from({ length: 60 }, () => trigger(1)))).toHaveLength(50);
  });
});
