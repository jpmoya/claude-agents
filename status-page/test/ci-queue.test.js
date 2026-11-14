// Issue #643 — host-side CI queue collector + beat payload. This file covers AC8 (validate.js
// allowlist for the new optional top-level `ci_queue` key) and AC10 (the category vocab).
// Expected values are hand-written from the ticket's Expected Behavior payload shape, never
// copied from src/.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { CI_QUEUE_CATEGORY_VOCAB } from '../src/vocab.js';
import { validPayload, validCiQueue, validCiQueueWithQueuedItems, validCiQueueQueuedItem } from './fixtures.js';

describe('AC10 — CI_QUEUE_CATEGORY_VOCAB', () => {
  it('is exactly [dependabot, prod_deploy, staging_deploy, deploy_release, pr, other] (issue #657 split)', () => {
    expect(CI_QUEUE_CATEGORY_VOCAB).toEqual([
      'dependabot',
      'prod_deploy',
      'staging_deploy',
      'deploy_release',
      'pr',
      'other',
    ]);
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

  it('accepts a 4-entry categories[] (fewer than the now-6-key vocab — not every key need be present)', () => {
    const ciQueue = validCiQueue();
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.categories).toHaveLength(4);
  });

  it('accepts all 6 vocab keys at once (issue #657: prod_deploy/staging_deploy split)', () => {
    const ciQueue = validCiQueue({
      categories: CI_QUEUE_CATEGORY_VOCAB.map((key) => ({ key, count: 1 })),
    });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.categories).toHaveLength(6);
  });
});

describe('issue #657 — categories[].queued[]', () => {
  it('keeps a valid queued[] entry nested in its category, byte-for-byte', () => {
    const ciQueue = validCiQueueWithQueuedItems();
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).toEqual(ciQueue);
  });

  it('a category with no queued key at all (pre-#657 collector) validates fine, no queued key added', () => {
    const ciQueue = validCiQueue();
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    for (const cat of r.value.ci_queue.categories) {
      expect(cat).not.toHaveProperty('queued');
    }
  });

  it('a non-array queued (wrong type) just omits the key — never drops the category or ci_queue', () => {
    const ciQueue = validCiQueueWithQueuedItems();
    ciQueue.categories[1].queued = 'nope';
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.categories[1]).not.toHaveProperty('queued');
    expect(r.value.ci_queue.categories[1].key).toBe('prod_deploy');
  });

  it('a malformed individual queued[] item is dropped — the category and its other items survive', () => {
    const ciQueue = validCiQueueWithQueuedItems();
    ciQueue.categories[1].queued = [
      validCiQueueQueuedItem(),
      { repo: 'not a repo shape', run_id: 1, queued_at: '2026-09-21T11:45:00Z' },
      validCiQueueQueuedItem({ run_id: 99 }),
    ];
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    const queued = r.value.ci_queue.categories[1].queued;
    expect(queued).toHaveLength(2);
    expect(queued.map((q) => q.run_id)).toEqual([43050239599, 99]);
  });

  it('pr_url is always present (null when there is no attached PR) — the item is kept, not dropped', () => {
    const ciQueue = validCiQueueWithQueuedItems();
    ciQueue.categories[1].queued = [validCiQueueQueuedItem({ pr_url: undefined })];
    delete ciQueue.categories[1].queued[0].pr_url;
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.categories[1].queued[0]).toMatchObject({ pr_url: null });
  });

  it('title is optional free text, omitted when absent', () => {
    const ciQueue = validCiQueueWithQueuedItems();
    delete ciQueue.categories[1].queued[0].title;
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.categories[1].queued[0]).not.toHaveProperty('title');
  });

  it('more items than MAX_CI_QUEUE_QUEUED_ITEMS (10) are truncated, never an error', () => {
    const ciQueue = validCiQueueWithQueuedItems();
    ciQueue.categories[1].queued = Array.from({ length: 15 }, (_, i) => validCiQueueQueuedItem({ run_id: 1000 + i }));
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.categories[1].queued).toHaveLength(10);
  });

  it('a missing/invalid run_id drops just that queued item', () => {
    const ciQueue = validCiQueueWithQueuedItems();
    ciQueue.categories[1].queued = [validCiQueueQueuedItem(), validCiQueueQueuedItem({ run_id: 'nope' })];
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.categories[1].queued).toHaveLength(1);
  });

  it('a non-ISO queued_at drops just that queued item', () => {
    const ciQueue = validCiQueueWithQueuedItems();
    ciQueue.categories[1].queued = [validCiQueueQueuedItem(), validCiQueueQueuedItem({ queued_at: 'soon' })];
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.categories[1].queued).toHaveLength(1);
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

  it('more than 6 category entries (the now-6-key vocab length) drops ci_queue', () => {
    const payload = basePayload();
    // basePayload already has 4 (dependabot/deploy_release/pr/other); add the 2 remaining vocab
    // keys (still unique — must NOT exceed the cap yet) then a 7th that can only be a duplicate
    // (the vocab has exactly 6 keys) — the length check fires before the duplicate-key check, so
    // this is still testing MAX_CI_QUEUE_CATEGORIES overflow, not just the duplicate-key path.
    payload.ci_queue.categories.push({ key: 'prod_deploy', count: 1 });
    payload.ci_queue.categories.push({ key: 'staging_deploy', count: 1 });
    expect(payload.ci_queue.categories).toHaveLength(6); // sanity: still within the cap
    expect(validateBeatPayload(payload).ok).toBe(true);
    payload.ci_queue.categories.push({ key: 'other', count: 1 });
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
