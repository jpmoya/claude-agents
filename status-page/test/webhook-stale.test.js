// #773 / #782: the "no webhook received in N minutes" banner. Source of truth is the VM receiver's newest event time
// (`webhook_last_event_at`, published by the VM host only while the receiver feed is stale, so the beat's change hash stays constant
// during an outage); the Mac's own apply of events is never an alert. The page computes the minutes from its own clock.
// Expected values are hand-written.

import { describe, it, expect } from 'vitest';
import { deriveAlerts, WEBHOOK_STALE_MINUTES } from '../src/alerts.js';
import { validateBeatPayload } from '../src/validate.js';
import { validPayload, hostRecord } from './fixtures.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-11-19T12:00:00Z') / 1000;
const ago = (mins) => new Date((NOW - mins * 60) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const host = (extra = {}) => ({ ...hostRecord({ runs: [], received_at: ago(1) }), supervisor_last_tick: ago(2), capacity: { running: 0, max: 3, queued: 0 }, ...extra });
const ids = (alerts) => alerts.map((a) => a.id);

describe('webhook stale banner (VM receiver time)', () => {
  it('the page threshold is 30 minutes, the host default', () => {
    expect(WEBHOOK_STALE_MINUTES).toBe(30);
  });

  it('AC3: shows "no webhook received in 31 minutes" when the VM receiver last event is 31 minutes old', () => {
    const alerts = deriveAlerts({ mac: null, vm: host({ webhook_last_event_at: ago(31) }) }, thresholds, NOW);
    expect(ids(alerts)).toEqual(['webhook-stale-vm']);
    expect(alerts[0].title).toBe('The VM is not receiving GitHub webhooks');
    expect(alerts[0].detail).toContain('no webhook received in 31 minutes');
    expect(alerts[0].severity).toBe('amber');
  });

  it('AC3: exactly one alert, from the VM receiver time, whatever the Mac says or does (live, slow, with the legacy field)', () => {
    const mac = host({ webhook_stale: { since: ago(90) }, supervisor_last_tick: ago(14) });
    const alerts = deriveAlerts({ mac, vm: host({ webhook_last_event_at: ago(45) }) }, thresholds, NOW);
    expect(ids(alerts)).toEqual(['webhook-stale-vm']);
    expect(alerts[0].detail).toContain('no webhook received in 45 minutes');
  });

  it('AC3: keeps counting on the page side while the beat stays constant', () => {
    const rec = host({ webhook_last_event_at: ago(31) });
    expect(deriveAlerts({ vm: rec }, thresholds, NOW + 9 * 60)[0].detail).toContain('no webhook received in 40 minutes');
  });

  it('AC2: a live but slow Mac with a VM receiver event 5 minutes ago raises nothing', () => {
    const slowMac = host({ supervisor_last_tick: ago(14) });
    expect(deriveAlerts({ mac: slowMac, vm: host({ webhook_last_event_at: ago(5) }) }, thresholds, NOW)).toEqual([]);
  });

  it('AC2: a value younger than the threshold raises nothing even when published (a beat that has not caught up yet)', () => {
    expect(deriveAlerts({ vm: host({ webhook_last_event_at: ago(29) }) }, thresholds, NOW)).toEqual([]);
  });

  it('AC1: a stale Mac (heartbeat older than the stale threshold) with webhook_stale set raises only the stale-supervisor alert', () => {
    const staleMac = { ...host({ webhook_stale: { since: ago(90) } }), received_at: ago(30) };
    expect(ids(deriveAlerts({ mac: staleMac, vm: host() }, thresholds, NOW))).toEqual(['host-stale-mac']);
    const offlineMac = { ...host({ webhook_stale: { since: ago(90) } }), received_at: ago(200) };
    expect(ids(deriveAlerts({ mac: offlineMac, vm: host() }, thresholds, NOW))).toEqual(['host-offline-mac']);
  });

  it('AC1: the legacy webhook_stale field on any live host (the Mac keeps sending it until it syncs) raises nothing', () => {
    expect(deriveAlerts({ mac: host({ webhook_stale: { since: ago(45) } }), vm: host({ webhook_stale: { since: ago(31) } }) }, thresholds, NOW)).toEqual([]);
  });

  it('AC3 negative: no VM record, or the field absent or unreadable: no alert (fail quiet)', () => {
    expect(deriveAlerts({ mac: host({ webhook_last_event_at: ago(90) }), vm: null }, thresholds, NOW)).toEqual([]);
    expect(deriveAlerts({ mac: host() }, thresholds, NOW)).toEqual([]);
    expect(deriveAlerts({ mac: host(), vm: host() }, thresholds, NOW)).toEqual([]);
    expect(deriveAlerts({ vm: host({ webhook_last_event_at: 'yesterday' }) }, thresholds, NOW)).toEqual([]);
    expect(deriveAlerts({ vm: host({ webhook_last_event_at: null }) }, thresholds, NOW)).toEqual([]);
  });

  it('a stale VM host raises only the host alert, not a webhook alert on its old data', () => {
    const offline = { ...host({ webhook_last_event_at: ago(90) }), received_at: ago(200) };
    expect(ids(deriveAlerts({ vm: offline }, thresholds, NOW))).toEqual(['host-offline-vm']);
  });

  it('a Mac-only record carrying the VM field (wrong host) is ignored', () => {
    expect(deriveAlerts({ mac: host({ webhook_last_event_at: ago(90) }) }, thresholds, NOW)).toEqual([]);
  });
});

describe('webhook_last_event_at in the beat payload', () => {
  it('survives validation as a plain ISO string', () => {
    const r = validateBeatPayload({ ...validPayload(), webhook_last_event_at: ago(31) });
    expect(r.ok).toBe(true);
    expect(r.value.webhook_last_event_at).toBe(ago(31));
  });

  it('is dropped (never a rejection) when malformed, and absent stays absent', () => {
    for (const bad of [null, 'x', [], {}, { since: ago(31) }, 5, 'not a date']) {
      const r = validateBeatPayload({ ...validPayload(), webhook_last_event_at: bad });
      expect(r.ok).toBe(true);
      expect('webhook_last_event_at' in r.value).toBe(false);
    }
    expect('webhook_last_event_at' in validateBeatPayload(validPayload()).value).toBe(false);
  });

  it('the legacy webhook_stale key is no longer stored', () => {
    const r = validateBeatPayload({ ...validPayload(), webhook_stale: { since: ago(31) } });
    expect(r.ok).toBe(true);
    expect('webhook_stale' in r.value).toBe(false);
  });
});
