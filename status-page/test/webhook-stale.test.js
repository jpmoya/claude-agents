// #773: the "no webhook received in N minutes" banner. The host publishes webhook_stale.since only while its queue is stale; the page
// computes the minutes from its own clock, so the beat's change hash stays constant during an outage. Expected values are hand-written.

import { describe, it, expect } from 'vitest';
import { deriveAlerts } from '../src/alerts.js';
import { validateBeatPayload } from '../src/validate.js';
import { validPayload, hostRecord } from './fixtures.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-11-19T12:00:00Z') / 1000;
const ago = (mins) => new Date((NOW - mins * 60) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const host = (extra = {}) => ({ ...hostRecord({ runs: [], received_at: ago(1) }), supervisor_last_tick: ago(2), capacity: { running: 0, max: 3, queued: 0 }, ...extra });

describe('webhook stale banner', () => {
  it('shows "no webhook received in 31 minutes" when the host reports a 31 minute old newest event', () => {
    const alerts = deriveAlerts({ mac: null, vm: host({ webhook_stale: { since: ago(31) } }) }, thresholds, NOW);
    expect(alerts.map((a) => a.id)).toEqual(['webhook-stale-vm']);
    expect(alerts[0].title).toBe('The VM is not receiving GitHub webhooks');
    expect(alerts[0].detail).toContain('no webhook received in 31 minutes');
    expect(alerts[0].severity).toBe('amber');
  });

  it('keeps counting on the page side while the beat stays constant', () => {
    const rec = host({ webhook_stale: { since: ago(31) } });
    expect(deriveAlerts({ vm: rec }, thresholds, NOW + 9 * 60)[0].detail).toContain('no webhook received in 40 minutes');
  });

  it('says nothing without the field (fresh event, or the switch is off)', () => {
    expect(deriveAlerts({ mac: host(), vm: host() }, thresholds, NOW)).toEqual([]);
  });

  it('ignores an unreadable since and a stale host (its old data raises only the host alert)', () => {
    expect(deriveAlerts({ vm: host({ webhook_stale: { since: 'yesterday' } }) }, thresholds, NOW)).toEqual([]);
    const offline = { ...host({ webhook_stale: { since: ago(90) } }), received_at: ago(200) };
    expect(deriveAlerts({ vm: offline }, thresholds, NOW).map((a) => a.id)).toEqual(['host-offline-vm']);
  });

  it('reports each host that has the problem, by name', () => {
    const alerts = deriveAlerts({ mac: host({ webhook_stale: { since: ago(45) } }), vm: host({ webhook_stale: { since: ago(31) } }) }, thresholds, NOW);
    expect(alerts.map((a) => a.id).sort()).toEqual(['webhook-stale-mac', 'webhook-stale-vm']);
  });
});

describe('webhook_stale in the beat payload', () => {
  it('survives validation as {since} only, and unknown keys inside it are dropped', () => {
    const r = validateBeatPayload({ ...validPayload(), webhook_stale: { since: ago(31), token: 'x' } });
    expect(r.ok).toBe(true);
    expect(r.value.webhook_stale).toEqual({ since: ago(31) });
  });

  it('is dropped (never a rejection) when malformed, and absent stays absent', () => {
    for (const bad of [null, 'x', [], { since: 'not a date' }, { since: 5 }, {}]) {
      const r = validateBeatPayload({ ...validPayload(), webhook_stale: bad });
      expect(r.ok).toBe(true);
      expect('webhook_stale' in r.value).toBe(false);
    }
    expect('webhook_stale' in validateBeatPayload(validPayload()).value).toBe(false);
  });
});
