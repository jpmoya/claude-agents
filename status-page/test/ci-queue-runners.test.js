// Issue #648 — per-runner utilization data on the `ci_queue` beat payload (online-only runner
// counting is covered by the bash suite against the live collector; this file covers AC8's
// validate.js allowlist for the new `runners[]` / `runners_offline` fields, plus the
// `CI_RUNNER_ROLE_VOCAB` enum). Expected values are hand-written from the ticket's Expected
// Behavior payload shape, never copied from src/.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { CI_RUNNER_ROLE_VOCAB } from '../src/vocab.js';
import { validPayload, validCiQueue, validCiQueueRunner, validCiQueueWithRunners } from './fixtures.js';

describe('CI_RUNNER_ROLE_VOCAB', () => {
  it('is exactly [general, prod_deploy]', () => {
    expect(CI_RUNNER_ROLE_VOCAB).toEqual(['general', 'prod_deploy']);
  });
});

describe('AC8(a) — a valid runners[]/runners_offline passes through unchanged', () => {
  it('keeps runners[] and runners_offline exactly as sent', () => {
    const ciQueue = validCiQueueWithRunners();
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).toEqual(ciQueue);
  });

  it('accepts a prod_deploy-role runner with null util percentages (newly-seen runner)', () => {
    const runner = validCiQueueRunner({ role: 'prod_deploy', util_24h_pct: null, util_72h_pct: null });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners).toEqual([runner]);
  });

  it('a ci_queue with no runners[]/runners_offline at all (old-collector shape) still passes with those keys omitted', () => {
    const ciQueue = validCiQueue();
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('runners');
    expect(r.value.ci_queue).not.toHaveProperty('runners_offline');
  });
});

describe('AC8(b) — a malformed runners[] entry drops only that entry', () => {
  const siblingsSurvive = (result, ciQueue) => {
    expect(result.ok).toBe(true);
    expect(result.value).toHaveProperty('ci_queue');
    expect(result.value.ci_queue.runners_busy).toBe(ciQueue.runners_busy);
    expect(result.value.ci_queue.categories).toEqual(ciQueue.categories);
  };

  it('an out-of-bounds name (too long) drops that entry, the rest of ci_queue and the beat survive', () => {
    const ciQueue = validCiQueueWithRunners({
      runners: [validCiQueueRunner(), validCiQueueRunner({ id: 2, name: 'x'.repeat(101) })],
    });
    const payload = validPayload({ ci_queue: ciQueue });
    const r = validateBeatPayload(payload);
    siblingsSurvive(r, ciQueue);
    expect(r.value.ci_queue.runners).toEqual([validCiQueueRunner()]);
    expect(r.value.runs).toEqual(validPayload().runs);
  });

  it('a bad-charset name drops that entry', () => {
    const ciQueue = validCiQueueWithRunners({
      runners: [validCiQueueRunner(), validCiQueueRunner({ id: 2, name: 'bad name!' })],
    });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    siblingsSurvive(r, ciQueue);
    expect(r.value.ci_queue.runners).toEqual([validCiQueueRunner()]);
  });

  it('a non-integer id drops that entry', () => {
    const ciQueue = validCiQueueWithRunners({
      runners: [validCiQueueRunner(), validCiQueueRunner({ id: 2.5 })],
    });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    siblingsSurvive(r, ciQueue);
    expect(r.value.ci_queue.runners).toEqual([validCiQueueRunner()]);
  });

  it('a role outside the vocab drops that entry', () => {
    const ciQueue = validCiQueueWithRunners({
      runners: [validCiQueueRunner(), validCiQueueRunner({ id: 2, role: 'super-admin' })],
    });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    siblingsSurvive(r, ciQueue);
    expect(r.value.ci_queue.runners).toEqual([validCiQueueRunner()]);
  });

  it('a non-boolean online/busy drops that entry', () => {
    const ciQueue = validCiQueueWithRunners({
      runners: [validCiQueueRunner(), validCiQueueRunner({ id: 2, online: 'yes' })],
    });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    siblingsSurvive(r, ciQueue);
    expect(r.value.ci_queue.runners).toEqual([validCiQueueRunner()]);
  });

  it('an out-of-range util_24h_pct (101) drops that entry', () => {
    const ciQueue = validCiQueueWithRunners({
      runners: [validCiQueueRunner(), validCiQueueRunner({ id: 2, util_24h_pct: 101 })],
    });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    siblingsSurvive(r, ciQueue);
    expect(r.value.ci_queue.runners).toEqual([validCiQueueRunner()]);
  });

  it('every entry malformed leaves an empty runners[] array, ci_queue itself still present', () => {
    const ciQueue = validCiQueueWithRunners({ runners: [validCiQueueRunner({ id: 'nope' })] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners).toEqual([]);
  });
});

describe('AC8(c) — runners[] longer than the cap is truncated, never rejected whole', () => {
  it('31 valid entries truncate to 30, ci_queue still present', () => {
    const runners = Array.from({ length: 31 }, (_, i) => validCiQueueRunner({ id: i + 1 }));
    const ciQueue = validCiQueueWithRunners({ runners });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners).toHaveLength(30);
    expect(r.value.ci_queue.runners.map((x) => x.id)).toEqual(runners.slice(0, 30).map((x) => x.id));
  });

  it('exactly 30 entries all survive', () => {
    const runners = Array.from({ length: 30 }, (_, i) => validCiQueueRunner({ id: i + 1 }));
    const ciQueue = validCiQueueWithRunners({ runners });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners).toHaveLength(30);
  });
});

describe('runners_offline malformed drops only that key, not the whole ci_queue', () => {
  it('a non-integer runners_offline omits the key, ci_queue + runners[] survive', () => {
    const ciQueue = validCiQueueWithRunners({ runners_offline: 'one' });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('runners_offline');
    expect(r.value.ci_queue.runners).toEqual([validCiQueueRunner()]);
  });

  it('an out-of-range runners_offline (1000) omits the key only', () => {
    const ciQueue = validCiQueueWithRunners({ runners_offline: 1000 });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('runners_offline');
  });
});

describe('runners malformed at the top level (not an array) omits only that key', () => {
  it('runners: "nope" omits the runners key, rest of ci_queue survives', () => {
    const ciQueue = validCiQueueWithRunners({ runners: 'nope' });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('runners');
    expect(r.value.ci_queue.runners_offline).toBe(1);
  });
});
