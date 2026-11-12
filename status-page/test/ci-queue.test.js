// Issue #643 — host-side CI queue collector + beat payload. This file covers AC8 (validate.js
// allowlist for the new optional top-level `ci_queue` key) and AC10 (the category vocab).
// Expected values are hand-written from the ticket's Expected Behavior payload shape, never
// copied from src/.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { CI_QUEUE_CATEGORY_VOCAB } from '../src/vocab.js';
import { validPayload, validCiQueue, validCiQueueQueuedItem } from './fixtures.js';

describe('AC10 — CI_QUEUE_CATEGORY_VOCAB', () => {
  it('is exactly [dependabot, prod_deploy, staging_deploy, deploy_release, pr, other] (issue #657 split)', () => {
    expect(CI_QUEUE_CATEGORY_VOCAB).toEqual(['dependabot', 'prod_deploy', 'staging_deploy', 'deploy_release', 'pr', 'other']);
  });
});

describe('AC8(a) — a valid ci_queue passes through unchanged', () => {
  it('keeps every field exactly as sent', () => {
    const r = validateBeatPayload(validPayload({ ci_queue: validCiQueue() }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).toEqual(validCiQueue());
  });

  it('accepts oldest: null and an empty categories[]', () => {
    const ciQueue = validCiQueue({ categories: [], queued_total: 0, oldest: null });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).toEqual(ciQueue);
  });

  it('accepts exactly 4 category entries (one per vocab key)', () => {
    const ciQueue = validCiQueue();
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.categories).toHaveLength(4);
  });

  it('accepts all 6 vocab keys at once (issue #657: MAX_CI_QUEUE_CATEGORIES tracks the vocab length)', () => {
    const ciQueue = validCiQueue({
      categories: CI_QUEUE_CATEGORY_VOCAB.map((key) => ({ key, count: 1 })),
    });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.categories).toHaveLength(6);
  });
});

describe('AC8(b) — ci_queue absent: no validation error, no ci_queue key', () => {
  it.each(['nope', 42, null, {}, []])('ci_queue: %j (not a valid object) produces no ci_queue key', (junk) => {
    const r = validateBeatPayload(validPayload({ ci_queue: junk }));
    expect(r.ok).toBe(true);
    expect(r.value).not.toHaveProperty('ci_queue');
  });

  it('a payload that never mentions ci_queue at all validates fine, with no ci_queue key', () => {
    const r = validateBeatPayload(validPayload());
    expect(r.ok).toBe(true);
    expect(r.value).not.toHaveProperty('ci_queue');
  });
});

describe('AC8(c) — one malformed ci_queue sub-field drops the whole object, siblings survive', () => {
  // Each case is applied on top of a full valid payload (runs + capacity present), so the test
  // can assert those sibling top-level fields survive byte-for-byte — not just that the beat
  // doesn't 400.
  const basePayload = () => validPayload({ ci_queue: validCiQueue() });

  const siblingsSurvive = (result) => {
    expect(result.ok).toBe(true);
    expect(result.value).not.toHaveProperty('ci_queue');
    expect(result.value.runs).toEqual(validPayload().runs);
    expect(result.value.capacity).toEqual(validPayload().capacity);
  };

  it('a category key not in the vocab drops ci_queue, runs/capacity survive', () => {
    const payload = basePayload();
    payload.ci_queue.categories[0] = { key: 'spam', count: 1 };
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('a non-ISO as_of drops ci_queue, runs/capacity survive', () => {
    const payload = basePayload();
    payload.ci_queue.as_of = 'yesterday';
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('a fractional-seconds as_of (non-exact ISO-8601Z) drops ci_queue', () => {
    const payload = basePayload();
    payload.ci_queue.as_of = '2026-09-21T12:00:00.123Z';
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('a non-integer count (1.5) drops ci_queue', () => {
    const payload = basePayload();
    payload.ci_queue.categories[0].count = 1.5;
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('a string count ("3") drops ci_queue', () => {
    const payload = basePayload();
    payload.ci_queue.categories[0].count = '3';
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('a count out of range (1000) drops ci_queue', () => {
    const payload = basePayload();
    payload.ci_queue.categories[0].count = 1000;
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('a malformed oldest (bad key) drops ci_queue', () => {
    const payload = basePayload();
    payload.ci_queue.oldest = { key: 'nope', queued_at: '2026-09-21T11:45:00Z' };
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('a malformed oldest (non-ISO queued_at) drops ci_queue', () => {
    const payload = basePayload();
    payload.ci_queue.oldest = { key: 'pr', queued_at: 'not-a-date' };
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('more than MAX_CI_QUEUE_CATEGORIES (6) category entries drops ci_queue', () => {
    const payload = validPayload({
      ci_queue: validCiQueue({ categories: CI_QUEUE_CATEGORY_VOCAB.map((key) => ({ key, count: 1 })) }),
    });
    payload.ci_queue.categories.push({ key: 'other', count: 1 }); // 7th entry (a duplicate key, same as the pre-#657 version of this test)
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('a duplicate category key drops ci_queue', () => {
    const payload = basePayload();
    payload.ci_queue.categories[1] = { key: 'dependabot', count: 1 };
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('runners_busy out of range drops ci_queue', () => {
    const payload = basePayload();
    payload.ci_queue.runners_busy = 1000;
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('a non-object ci_queue.oldest (not null, not an object) drops ci_queue', () => {
    const payload = basePayload();
    payload.ci_queue.oldest = 'soon';
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('a non-object ci_queue (e.g. a string) produces no ci_queue key, siblings survive', () => {
    const payload = validPayload({ ci_queue: 'nope' });
    siblingsSurvive(validateBeatPayload(payload));
  });

  it('dropping ci_queue never leaks any of its content into the serialised value', () => {
    const payload = basePayload();
    payload.ci_queue.as_of = 'yesterday';
    const r = validateBeatPayload(payload);
    expect(JSON.stringify(r.value)).not.toContain('runners_busy');
  });
});

// Issue #657 — `ci_queue.queued_items[]`: an additive field, same reasoning as `runners[]`/
// `runners_offline` above (AC8(c)'s comment) — present-and-malformed never drops the whole
// `ci_queue`, and a single bad entry drops only that entry.
describe('issue #657 — ci_queue.queued_items[]', () => {
  it('absent queued_items: no key, rest of ci_queue still passes through', () => {
    const r = validateBeatPayload(validPayload({ ci_queue: validCiQueue() }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('queued_items');
  });

  it('a well-formed queued_items[] passes through unchanged, including pr_url: null', () => {
    const items = [
      validCiQueueQueuedItem(),
      validCiQueueQueuedItem({ key: 'pr', run_id: 2, pr_url: null, title: 'Fix the thing' }),
    ];
    const ciQueue = validCiQueue({ queued_items: items });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.queued_items).toEqual(items);
  });

  it('a malformed entry (bad category key) is dropped individually — ci_queue itself survives', () => {
    const good = validCiQueueQueuedItem({ run_id: 1 });
    const bad = validCiQueueQueuedItem({ run_id: 2, key: 'spam' });
    const ciQueue = validCiQueue({ queued_items: [good, bad] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.queued_items).toEqual([good]);
  });

  it('a malformed entry (missing run_id) is dropped individually, never crashes', () => {
    const good = validCiQueueQueuedItem({ run_id: 1 });
    const bad = { ...validCiQueueQueuedItem({ run_id: 2 }), run_id: 'not-a-number' };
    const ciQueue = validCiQueue({ queued_items: [good, bad] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.queued_items).toEqual([good]);
  });

  it('a malformed entry (bad repo shape) is dropped individually', () => {
    const good = validCiQueueQueuedItem({ run_id: 1 });
    const bad = validCiQueueQueuedItem({ run_id: 2, repo: 'not-a-repo' });
    const ciQueue = validCiQueue({ queued_items: [good, bad] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.queued_items).toEqual([good]);
  });

  it('a malformed entry (non-ISO queued_at) is dropped individually', () => {
    const good = validCiQueueQueuedItem({ run_id: 1 });
    const bad = validCiQueueQueuedItem({ run_id: 2, queued_at: 'not-a-date' });
    const ciQueue = validCiQueue({ queued_items: [good, bad] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.queued_items).toEqual([good]);
  });

  it('a malformed entry (invalid pr_url) drops pr_url to null, not the whole entry', () => {
    const item = validCiQueueQueuedItem({ run_id: 1, pr_url: 'javascript:alert(1)' });
    const ciQueue = validCiQueue({ queued_items: [item] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.queued_items).toEqual([{ ...item, pr_url: null }]);
  });

  it('a non-array queued_items (wrong type) omits the key, rest of ci_queue survives', () => {
    const ciQueue = validCiQueue({ queued_items: 'nope' });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('queued_items');
    expect(r.value.ci_queue.categories).toEqual(validCiQueue().categories);
  });

  it('a long/control-character title is capped and cleaned, same exception as runs[].title', () => {
    const longTitle = 'x'.repeat(500) + '\u0007\n\n  spaced  out';
    const item = validCiQueueQueuedItem({ run_id: 1, title: longTitle });
    const ciQueue = validCiQueue({ queued_items: [item] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    const outTitle = r.value.ci_queue.queued_items[0].title;
    expect(outTitle.length).toBeLessThanOrEqual(140);
    expect(outTitle).not.toMatch(/\s{2,}/);
  });

  it('more than MAX_CI_QUEUE_QUEUED_ITEMS entries for one category key are truncated, not rejected', () => {
    const items = Array.from({ length: 15 }, (_, i) => validCiQueueQueuedItem({ run_id: i + 1 }));
    const ciQueue = validCiQueue({ queued_items: items });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.queued_items.length).toBeLessThan(15);
    expect(r.value.ci_queue.queued_items.length).toBeGreaterThan(0);
  });

  it('the cap is applied independently per category key', () => {
    const deployItems = Array.from({ length: 15 }, (_, i) => validCiQueueQueuedItem({ run_id: i + 1, key: 'deploy_release' }));
    const prItems = Array.from({ length: 3 }, (_, i) => validCiQueueQueuedItem({ run_id: 1000 + i, key: 'pr' }));
    const ciQueue = validCiQueue({ queued_items: [...deployItems, ...prItems] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    const prOut = r.value.ci_queue.queued_items.filter((i) => i.key === 'pr');
    expect(prOut).toHaveLength(3);
  });
});
