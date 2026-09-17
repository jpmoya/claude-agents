// AC13: stale/offline thresholds are DERIVED from KEEPALIVE_SECS, not hand-picked.
// Expected values: hand arithmetic from AC13's own text — "stale_threshold == 2.5 x keepalive
// (rounded to nearest minute)", "offline_threshold == 3 x stale_threshold", keep-alive = 600s.

import { describe, it, expect } from 'vitest';
import { KEEPALIVE_SECS, computeThresholds } from '../src/vocab.js';

describe('AC13: derived stale/offline thresholds', () => {
  it('KEEPALIVE_SECS is 600 (ticket-specified keep-alive)', () => {
    expect(KEEPALIVE_SECS).toBe(600);
  });

  it('staleSecs == round(2.5 * keepalive) to the nearest minute, expressed in seconds', () => {
    const { staleSecs } = computeThresholds(KEEPALIVE_SECS);
    // 2.5 * 600 = 1500s = 25.0 min exactly -> rounds to 25 min -> 1500s
    const expectedStaleSecs = Math.round((2.5 * KEEPALIVE_SECS) / 60) * 60;
    expect(staleSecs).toBe(expectedStaleSecs);
  });

  it('offlineSecs == 3 * staleSecs', () => {
    const { staleSecs, offlineSecs } = computeThresholds(KEEPALIVE_SECS);
    expect(offlineSecs).toBe(3 * staleSecs);
  });

  it('is computed from ANY keepalive, not hard-coded for 600 (guards against a lookup table)', () => {
    // Guards against an implementation that hard-codes 1500/4500 for 600s and only
    // *coincidentally* satisfies the two relation tests above: try a different keepalive and
    // check the same formula independently. 2.5*300=750s=12.5min -> round-half-up -> 13min=780s.
    const { staleSecs: stale300 } = computeThresholds(300);
    expect(stale300).toBe(Math.round((2.5 * 300) / 60) * 60);
    expect(stale300).toBe(780);
  });

  it('shipped values with KEEPALIVE_SECS=600 are 25min/75min, in SECONDS (1500 / 4500)', () => {
    // Ticket: "The keep-alive is 600 s, so the shipped values are 25 min / 75 min."
    // /status.json exposes stale_secs/offline_secs (seconds), per the response shape in the
    // routes table, so the pinned assertion is in seconds: 25*60=1500, 75*60=4500.
    const { staleSecs, offlineSecs } = computeThresholds(600);
    expect(staleSecs).toBe(1500);
    expect(offlineSecs).toBe(4500);
  });
});
