// Issue #660 — live duration/health metrics. validate.js's allowlist for the new, additive
// `ci_queue.ci_metrics` / `ci_queue.ci_health` sub-fields. Expected values are hand-written from
// the ticket's Expected Behavior payload shape, never copied from src/.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { CI_METRICS_CATEGORY_VOCAB, CI_HEALTH_VOCAB } from '../src/vocab.js';
import { validPayload, validCiQueue, validCiMetrics, validCiMetricsCategory, validCiQueueWithMetrics } from './fixtures.js';

describe('CI_METRICS_CATEGORY_VOCAB / CI_HEALTH_VOCAB', () => {
  it('CI_METRICS_CATEGORY_VOCAB is exactly [prod_deploy, staging_deploy, sales_tool_pr, ops_tool_pr]', () => {
    expect(CI_METRICS_CATEGORY_VOCAB).toEqual(['prod_deploy', 'staging_deploy', 'sales_tool_pr', 'ops_tool_pr']);
  });

  it('CI_HEALTH_VOCAB is exactly [ok, degraded, down]', () => {
    expect(CI_HEALTH_VOCAB).toEqual(['ok', 'degraded', 'down']);
  });
});

describe('a valid ci_metrics/ci_health passes through unchanged', () => {
  it('keeps every field exactly as sent, nested under ci_queue', () => {
    const ciQueue = validCiQueueWithMetrics();
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).toEqual(ciQueue);
  });

  it('accepts a single category and an empty categories[]', () => {
    const ciQueue = validCiQueueWithMetrics({ ci_metrics: validCiMetrics({ categories: [validCiMetricsCategory()] }) });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.ci_metrics.categories).toEqual([validCiMetricsCategory()]);

    const ciQueueEmpty = validCiQueueWithMetrics({ ci_metrics: validCiMetrics({ categories: [] }) });
    const r2 = validateBeatPayload(validPayload({ ci_queue: ciQueueEmpty }));
    expect(r2.ok).toBe(true);
    expect(r2.value.ci_queue.ci_metrics.categories).toEqual([]);
  });

  it('accepts a null pass_rate_pct (zero eligible runs today)', () => {
    const ciQueue = validCiQueueWithMetrics({
      ci_metrics: validCiMetrics({ categories: [validCiMetricsCategory({ pass_rate_pct: null })] }),
    });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.ci_metrics.categories[0].pass_rate_pct).toBeNull();
  });

  it.each(CI_HEALTH_VOCAB)('accepts ci_health: %s', (health) => {
    const ciQueue = validCiQueueWithMetrics({ ci_health: health });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.ci_health).toBe(health);
  });
});

describe('ci_metrics/ci_health absent or malformed: additive, never drops the rest of ci_queue', () => {
  it('a ci_queue with neither key at all validates fine, with neither key present', () => {
    const r = validateBeatPayload(validPayload({ ci_queue: validCiQueue() }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('ci_metrics');
    expect(r.value.ci_queue).not.toHaveProperty('ci_health');
  });

  it.each(['nope', 42, null, [], { as_of: 'not-iso', categories: [] }])(
    'a malformed ci_metrics (%j) drops only ci_metrics, ci_queue and ci_health survive',
    (junk) => {
      const ciQueue = validCiQueueWithMetrics({ ci_metrics: junk });
      const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
      expect(r.ok).toBe(true);
      expect(r.value.ci_queue).not.toHaveProperty('ci_metrics');
      expect(r.value.ci_queue.ci_health).toBe('ok');
      expect(r.value.ci_queue.runners_busy).toBe(validCiQueue().runners_busy);
    },
  );

  it.each(['nope', 42, null, {}, []])('a malformed ci_health (%j) drops only ci_health, ci_queue and ci_metrics survive', (junk) => {
    const ciQueue = validCiQueueWithMetrics({ ci_health: junk });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('ci_health');
    expect(r.value.ci_queue.ci_metrics).toEqual(validCiMetrics());
  });

  it('a category key not in CI_METRICS_CATEGORY_VOCAB drops ci_metrics only', () => {
    const ciQueue = validCiQueueWithMetrics();
    ciQueue.ci_metrics.categories[0] = { ...validCiMetricsCategory(), key: 'spam' };
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('ci_metrics');
    expect(r.value.ci_queue.ci_health).toBe('ok');
  });

  it('a duplicate category key drops ci_metrics only', () => {
    const ciQueue = validCiQueueWithMetrics();
    ciQueue.ci_metrics.categories[1] = { ...ciQueue.ci_metrics.categories[1], key: ciQueue.ci_metrics.categories[0].key };
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('ci_metrics');
  });

  it('more than 4 category entries drops ci_metrics only', () => {
    const ciQueue = validCiQueueWithMetrics();
    ciQueue.ci_metrics.categories.push(validCiMetricsCategory({ key: 'staging_deploy' }));
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('ci_metrics');
  });

  it.each([
    ['n', 0], // n must be >= 1 (a present category always has at least one completed run)
    ['n', 1.5],
    ['n', '3'],
    ['avg_secs', -1],
    ['avg_secs', 86401],
    ['p50_secs', 1.5],
    ['p90_secs', -1],
    ['pass_rate_pct', -1],
    ['pass_rate_pct', 101],
    ['pass_rate_pct', '50'],
  ])('an invalid %s (%j) drops ci_metrics only', (field, value) => {
    const ciQueue = validCiQueueWithMetrics();
    ciQueue.ci_metrics.categories[0] = { ...validCiMetricsCategory(), [field]: value };
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('ci_metrics');
  });

  it('a non-ISO ci_metrics.as_of drops ci_metrics only', () => {
    const ciQueue = validCiQueueWithMetrics();
    ciQueue.ci_metrics.as_of = 'yesterday';
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('ci_metrics');
  });

  it('accepts a null top-level pass_rate_pct (zero eligible runs today, across every category)', () => {
    const ciQueue = validCiQueueWithMetrics({ ci_metrics: validCiMetrics({ pass_rate_pct: null, pass_rate_n: 0 }) });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.ci_metrics.pass_rate_pct).toBeNull();
    expect(r.value.ci_queue.ci_metrics.pass_rate_n).toBe(0);
  });

  it.each([
    ['pass_rate_pct', -1],
    ['pass_rate_pct', 101],
    ['pass_rate_pct', '50'],
    ['pass_rate_n', -1],
    ['pass_rate_n', 1.5],
    ['pass_rate_n', '10'],
  ])('an invalid top-level %s (%j) drops ci_metrics only', (field, value) => {
    const ciQueue = validCiQueueWithMetrics();
    ciQueue.ci_metrics[field] = value;
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('ci_metrics');
  });

  it.each(['pass_rate_pct', 'pass_rate_n'])('a missing top-level %s drops ci_metrics only (both are required)', (field) => {
    const ciQueue = validCiQueueWithMetrics();
    delete ciQueue.ci_metrics[field];
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue).not.toHaveProperty('ci_metrics');
  });

  it('dropping a malformed ci_metrics never leaks any of its content into the serialised value', () => {
    const ciQueue = validCiQueueWithMetrics();
    ciQueue.ci_metrics.as_of = 'yesterday';
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(JSON.stringify(r.value)).not.toContain('yesterday');
  });
});
