// Issue #663 — CI collector reliability, the status-page/src/* half: AC1 (collector-outage
// visibility: handleBeat carries `ci_queue` forward across beats that omit it, and render.js's
// panel gains a third "collector stopped" state past offlineSecs), AC2 (the "≥N" truncated-count
// tile), AC5 (online-only pool-summary counts + "showing 30 of N"). AC3/AC4/AC6 (the bash-side
// collector reliability fixes) are covered in skills/orchestrate/tests/test-ciqueue-reliability.sh
// and test-ciqueue-collector.sh. Expected values are hand-derived from the issue's own AC text,
// never copied from src/.

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import worker, { __resetRateLimiter } from '../src/index.js';
import { renderCiPage } from '../src/render.js';
import {
  makeEnv,
  getRequest,
  beatRequest,
  validPayload,
  TOKEN_MAC,
  TOKEN_VM,
  hostRecord,
  validCiQueue,
  validCiQueueRunner,
  validCiQueueWithRunners,
} from './fixtures.js';

beforeEach(() => {
  __resetRateLimiter();
});

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };

/** ISO-8601Z with no fractional seconds — `isIsoTimestamp` in validate.js rejects the
 * milliseconds `Date.prototype.toISOString()` always includes, so every ci_queue.as_of built
 * from a JS Date in this file goes through this first. */
function isoZ(ms) {
  return new Date(ms).toISOString().replace(/\.\d+Z$/, 'Z');
}

/** Isolates the CI-queue panel's own markup, same helper as render-ci-queue.test.js. */
function ciQueuePanel(html) {
  const m = /<section class="group ci-queue">[\s\S]*?<\/section>/.exec(html);
  return m ? m[0] : null;
}

// ---- AC1b — handleBeat carries ci_queue forward across a beat that omits it -------------------

describe('AC1b — POST /beat carries the previous ci_queue forward when the new beat omits it', () => {
  it('a beat without ci_queue keeps the previously-stored ci_queue, unchanged (same as_of)', async () => {
    const env = makeEnv();
    const ciQueue = validCiQueue({ as_of: '2026-09-21T12:00:00Z' });
    await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload({ ci_queue: ciQueue }) }), env, {});

    const res = await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload() }), env, {});
    expect(res.status).toBe(204);

    const stored = JSON.parse(env.STATUS._dump()['host:mac']);
    expect(stored.ci_queue).toEqual(ciQueue);
  });

  it('a beat that already carries its own ci_queue never fetches the previous record (no extra get())', async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      beatRequest({ token: TOKEN_MAC, body: validPayload({ ci_queue: validCiQueue() }) }),
      env,
      {},
    );
    expect(res.status).toBe(204);
    expect(env.STATUS._calls().get).toBe(0);
  });

  it('a beat that omits ci_queue fetches the previous record exactly once', async () => {
    const env = makeEnv();
    await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload({ ci_queue: validCiQueue() }) }), env, {});
    const res = await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload() }), env, {});
    expect(res.status).toBe(204);
    expect(env.STATUS._calls().get).toBe(1);
  });

  it('a host that never sent ci_queue, beating again without one, still has no ci_queue key (nothing to carry forward)', async () => {
    const env = makeEnv();
    await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload() }), env, {});
    const res = await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload() }), env, {});
    expect(res.status).toBe(204);
    const stored = JSON.parse(env.STATUS._dump()['host:mac']);
    expect(stored).not.toHaveProperty('ci_queue');
  });

  it('carry-forward is per-host: a VM beat omitting ci_queue never reads or inherits the Mac record', async () => {
    const env = makeEnv();
    await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload({ ci_queue: validCiQueue({ queued_total: 99 }) }) }), env, {});
    const res = await worker.fetch(beatRequest({ token: TOKEN_VM, body: validPayload() }), env, {});
    expect(res.status).toBe(204);
    const storedVm = JSON.parse(env.STATUS._dump()['host:vm']);
    expect(storedVm).not.toHaveProperty('ci_queue');
  });

  it('a beat that carries its own ci_queue overwrites the previous one (no stale carry-forward over fresh data)', async () => {
    const env = makeEnv();
    await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload({ ci_queue: validCiQueue({ queued_total: 1 }) }) }), env, {});
    const fresh = validCiQueue({ queued_total: 42, as_of: '2026-09-21T13:00:00Z' });
    await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload({ ci_queue: fresh }) }), env, {});
    const stored = JSON.parse(env.STATUS._dump()['host:mac']);
    expect(stored.ci_queue).toEqual(fresh);
  });
});

// ---- AC1c — render.js's third "collector stopped" state past offlineSecs ----------------------

describe('AC1c — renderCiQueuePanel: a third "collector stopped" state past offlineSecs', () => {
  const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;

  it('age exactly at offlineSecs renders "collector stopped since <ts>", not "stale"', () => {
    const asOf = new Date((NOW - thresholds.offlineSecs) * 1000).toISOString();
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue({ as_of: asOf }) });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toContain('collector stopped since');
    expect(panel).not.toMatch(/badge stale/);
  });

  it('age one second inside offlineSecs still renders "stale", not "collector stopped"', () => {
    const asOf = new Date((NOW - thresholds.offlineSecs + 1) * 1000).toISOString();
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue({ as_of: asOf }) });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toMatch(/badge stale/);
    expect(panel).not.toContain('collector stopped');
  });

  it('the offline badge reuses the existing "offline" CSS class (no new color)', () => {
    const asOf = new Date((NOW - thresholds.offlineSecs - 60) * 1000).toISOString();
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue({ as_of: asOf }) });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toMatch(/<span class="badge offline">collector stopped since/);
  });
});

// ---- AC1 full integration — a real beat sequence through POST /beat + GET /ci -----------------

describe('AC1 — a real beat sequence: ci_queue present, then omitted for >75 min, still shows "collector stopped"', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('3 consecutive beats omitting ci_queue spanning >75 min still render "collector stopped since <ts>" on /ci, never "no CI queue data yet"', async () => {
    vi.useFakeTimers();
    const t0 = new Date('2026-09-21T12:00:00Z');
    vi.setSystemTime(t0);
    const env = makeEnv();
    const ciQueue = validCiQueue({ as_of: isoZ(t0.getTime()) });
    const beat1 = await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload({ ci_queue: ciQueue }) }), env, {});
    expect(beat1.status).toBe(204);

    for (const minutesLater of [30, 55, 80]) {
      vi.setSystemTime(new Date(t0.getTime() + minutesLater * 60 * 1000));
      const res = await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload() }), env, {});
      expect(res.status).toBe(204);
    }

    // Still at t0+80min when /ci is read.
    const ciRes = await worker.fetch(getRequest('/ci'), env, {});
    const html = await ciRes.text();
    expect(html).toContain('collector stopped since');
    expect(html).not.toContain('no CI queue data yet');
  });

  it('a beat sequence omitting ci_queue for 30-74 min renders the carried-forward data with the existing "stale" badge', async () => {
    vi.useFakeTimers();
    const t0 = new Date('2026-09-21T12:00:00Z');
    vi.setSystemTime(t0);
    const env = makeEnv();
    const ciQueue = validCiQueue({ as_of: isoZ(t0.getTime()), queued_total: 11 });
    const beat1 = await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload({ ci_queue: ciQueue }) }), env, {});
    expect(beat1.status).toBe(204);

    vi.setSystemTime(new Date(t0.getTime() + 50 * 60 * 1000)); // 50 min later: inside 30-74
    const beatRes = await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload() }), env, {});
    expect(beatRes.status).toBe(204);

    const ciRes = await worker.fetch(getRequest('/ci'), env, {});
    const html = await ciRes.text();
    expect(html).toMatch(/badge stale/);
    expect(html).not.toContain('collector stopped');
    // the carried-forward data itself is still visible (queued_total=11), not blanked
    expect(html).toMatch(/11[\s\S]{0,80}Jobs queued now/);
  });
});

// ---- AC2 — "≥N" truncated-count tile ------------------------------------------------------------

describe('AC2 — queued-count honesty: "≥N" when truncated, bare "N" otherwise', () => {
  const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;

  it('truncated: true shows "≥N" for the queued-total tile', () => {
    const mac = hostRecord({
      received_at: '2026-09-21T11:59:00Z',
      ci_queue: validCiQueue({ queued_total: 14, truncated: true }),
    });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toContain('≥14');
    expect(panel).toMatch(/≥14[\s\S]{0,80}Jobs queued now/);
  });

  it('truncated: false shows the bare number, no "≥"', () => {
    const mac = hostRecord({
      received_at: '2026-09-21T11:59:00Z',
      ci_queue: validCiQueue({ queued_total: 14, truncated: false }),
    });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).not.toContain('≥');
    expect(panel).toMatch(/>14</);
  });

  it('an old-collector payload with no truncated key at all shows the bare number (additive field, never required)', () => {
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue({ queued_total: 5 }) });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).not.toContain('≥');
  });
});

// ---- AC5 — online-only pool-summary counts + "showing 30 of N" ---------------------------------

describe('AC5 — runner pool summary counts online runners only, matching the main tile', () => {
  const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;

  it('an offline runner is excluded from both pool counts but still gets its own table row', () => {
    // A prod_deploy runner must be present for the summary line to render at all (unchanged
    // pre-#663 gate — see the "no prod_deploy runner at all" test below); it's set up idle here
    // so it doesn't interfere with the general-pool counts under test.
    const runners = [
      validCiQueueRunner({ id: 1, name: 'online-busy', role: 'general', online: true, busy: true }),
      validCiQueueRunner({ id: 2, name: 'offline-was-busy', role: 'general', online: false, busy: true }),
      validCiQueueRunner({ id: 3, name: 'online-idle', role: 'general', online: true, busy: false }),
      validCiQueueRunner({ id: 4, name: 'prod-online-idle', role: 'prod_deploy', online: true, busy: false }),
    ];
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueueWithRunners({ runners }) });
    const html = renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW);
    // General pool: online-busy + online-idle = 2 online, 1 busy. offline-was-busy excluded.
    expect(html).toMatch(/General pool: 1\/2 busy/);
    expect(html).toMatch(/Prod deploy: 0\/1 busy/);
    expect(html).toContain('offline-was-busy'); // still has its own row
  });

  it('the prod-deploy summary line still shows (as 0/0) when the only prod_deploy runner is offline — never vanishes', () => {
    const runners = [
      validCiQueueRunner({ id: 1, name: 'prod-offline', role: 'prod_deploy', online: false, busy: true }),
      validCiQueueRunner({ id: 2, name: 'general-online', role: 'general', online: true, busy: false }),
    ];
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueueWithRunners({ runners }) });
    const html = renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW);
    expect(html).toMatch(/<p class="ci-pool-summary">/);
    expect(html).toMatch(/Prod deploy: 0\/0 busy/);
  });

  it('no prod_deploy runner at all: no pool-summary line (unchanged pre-#663 behavior)', () => {
    const runners = [validCiQueueRunner({ id: 1, name: 'general-only', role: 'general' })];
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueueWithRunners({ runners }) });
    const html = renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW);
    expect(html).not.toMatch(/<p class="ci-pool-summary">/);
  });

  it('runners[] capped at 30 with a larger runners_total_sampled shows "showing 30 of N"', () => {
    const runners = Array.from({ length: 30 }, (_, i) => validCiQueueRunner({ id: i + 1, name: `r-${i + 1}` }));
    const mac = hostRecord({
      received_at: '2026-09-21T11:59:00Z',
      ci_queue: validCiQueueWithRunners({ runners, runners_total_sampled: 42 }),
    });
    const html = renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW);
    expect(html).toContain('showing 30 of 42');
  });

  it('runners_total_sampled equal to runners.length (no truncation) shows no "showing" note', () => {
    const runners = [validCiQueueRunner({ id: 1 }), validCiQueueRunner({ id: 2 })];
    const mac = hostRecord({
      received_at: '2026-09-21T11:59:00Z',
      ci_queue: validCiQueueWithRunners({ runners, runners_total_sampled: 2 }),
    });
    const html = renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW);
    expect(html).not.toContain('showing');
  });

  it('no runners_total_sampled at all (pre-#663 collector) shows no "showing" note', () => {
    const runners = [validCiQueueRunner({ id: 1 })];
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueueWithRunners({ runners }) });
    const html = renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW);
    expect(html).not.toContain('showing');
  });
});
