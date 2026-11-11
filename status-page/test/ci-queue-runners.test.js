// Issue #648 — per-runner utilization data on the `ci_queue` beat payload (online-only runner
// counting is covered by the bash suite against the live collector; this file covers AC8's
// validate.js allowlist for the new `runners[]` / `runners_offline` fields, plus the
// `CI_RUNNER_ROLE_VOCAB` enum). Expected values are hand-written from the ticket's Expected
// Behavior payload shape, never copied from src/.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload, isPrUrl } from '../src/validate.js';
import { CI_RUNNER_ROLE_VOCAB } from '../src/vocab.js';
import {
  validPayload,
  validCiQueue,
  validCiQueueRunner,
  validCiQueueWithRunners,
  validCiQueueCurrentJob,
} from './fixtures.js';

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

// Issue #655 AC A — history-depth honesty. `runners[].history_secs` is a brand-new, additive
// per-entry field (same "a collector that predates this ticket never sends it" reasoning as
// `runners_offline`/`runners[]` themselves, per the sanitiseCiQueue block comment above): absent
// -> omitted (never defaults to 0, which would wrongly flag every pre-#655 snapshot as "building"
// at render time); present-and-malformed -> omitted, the rest of the entry (and its siblings)
// survive untouched — never drops the whole runner entry the way a bad `util_24h_pct` does.
describe('AC A — ci_queue.runners[].history_secs (issue #655)', () => {
  it('a valid history_secs passes through unchanged', () => {
    const runner = validCiQueueRunner({ history_secs: 3600 });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0].history_secs).toBe(3600);
  });

  it('history_secs: 0 (just-seen slot) passes through as 0, not omitted (=== null check, not falsy)', () => {
    const runner = validCiQueueRunner({ history_secs: 0 });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0].history_secs).toBe(0);
  });

  it('a runner entry with no history_secs at all (pre-#655 collector) survives with the key omitted', () => {
    const runner = validCiQueueRunner();
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0]).not.toHaveProperty('history_secs');
  });

  it('a negative history_secs omits only that key — the rest of the entry (and siblings) survive', () => {
    const runners = [validCiQueueRunner(), validCiQueueRunner({ id: 2, history_secs: -1 })];
    const ciQueue = validCiQueueWithRunners({ runners });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners).toHaveLength(2);
    expect(r.value.ci_queue.runners[1]).not.toHaveProperty('history_secs');
    expect(r.value.ci_queue.runners[1].id).toBe(2);
  });

  it('a non-integer history_secs (string) omits only that key', () => {
    const runner = validCiQueueRunner({ history_secs: 'lots' });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0]).not.toHaveProperty('history_secs');
  });

  it('an out-of-range history_secs (too large) omits only that key', () => {
    const runner = validCiQueueRunner({ history_secs: 10_000_000 });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0]).not.toHaveProperty('history_secs');
  });
});

// Issue #655 AC B — link busy runners to their work. `runners[].current_job` is additive/optional
// (same reasoning as history_secs above): absent, non-object, or malformed sub-fields omit the
// key (or just `pr_url`) without ever dropping the runner entry or fabricating a URL.
describe('AC B — ci_queue.runners[].current_job (issue #655)', () => {
  it('a fully valid current_job (with pr_url) passes through unchanged', () => {
    const job = validCiQueueCurrentJob();
    const runner = validCiQueueRunner({ busy: true, current_job: job });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0].current_job).toEqual(job);
  });

  it('a valid current_job with no pr_url (run-link-only case) passes through without a pr_url key', () => {
    const job = { repo: 'jpmoya/claude-agents', run_id: 43050239599 };
    const runner = validCiQueueRunner({ busy: true, current_job: job });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0].current_job).toEqual(job);
    expect(r.value.ci_queue.runners[0].current_job).not.toHaveProperty('pr_url');
  });

  it('an invalid pr_url (not a github.com PR URL) drops only pr_url, repo/run_id survive', () => {
    const job = validCiQueueCurrentJob({ pr_url: 'https://evil.example/pwned' });
    const runner = validCiQueueRunner({ busy: true, current_job: job });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0].current_job).toEqual({
      repo: job.repo,
      run_id: job.run_id,
    });
  });

  it('a javascript: pr_url (XSS attempt) drops only pr_url, never reaches storage', () => {
    const job = validCiQueueCurrentJob({ pr_url: 'javascript:alert(1)' });
    const runner = validCiQueueRunner({ busy: true, current_job: job });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0].current_job).not.toHaveProperty('pr_url');
  });

  it('a non-integer run_id drops the whole current_job (no pr_url to fall back to construct a link from)', () => {
    const job = validCiQueueCurrentJob({ run_id: 'abc', pr_url: undefined });
    delete job.pr_url;
    const runner = validCiQueueRunner({ busy: true, current_job: job });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0]).not.toHaveProperty('current_job');
  });

  it('a run_id that is a real 11-digit GitHub run id survives (not capped at a small int range)', () => {
    const job = validCiQueueCurrentJob({ run_id: 43065321522, pr_url: undefined });
    delete job.pr_url;
    const runner = validCiQueueRunner({ busy: true, current_job: job });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0].current_job.run_id).toBe(43065321522);
  });

  it('a malformed repo (not owner/repo shape) drops the whole current_job', () => {
    const job = validCiQueueCurrentJob({ repo: 'not-a-repo-shape' });
    const runner = validCiQueueRunner({ busy: true, current_job: job });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0]).not.toHaveProperty('current_job');
  });

  it('current_job: "nope" (not an object) omits the key, the rest of the runner entry survives', () => {
    const runner = validCiQueueRunner({ busy: true, current_job: 'nope' });
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0]).not.toHaveProperty('current_job');
    expect(r.value.ci_queue.runners[0].id).toBe(runner.id);
  });

  it('a runner entry with no current_job at all survives with the key omitted (idle runner case)', () => {
    const runner = validCiQueueRunner();
    const ciQueue = validCiQueueWithRunners({ runners: [runner] });
    const r = validateBeatPayload(validPayload({ ci_queue: ciQueue }));
    expect(r.ok).toBe(true);
    expect(r.value.ci_queue.runners[0]).not.toHaveProperty('current_job');
  });
});

describe('isPrUrl (issue #655) — the render-side re-check, mirrors isIssueUrl', () => {
  it('accepts exactly a github.com PR URL', () => {
    expect(isPrUrl('https://github.com/jpmoya/claude-agents/pull/42')).toBe(true);
  });

  it('rejects an issue URL, a non-github host, and non-string values', () => {
    expect(isPrUrl('https://github.com/jpmoya/claude-agents/issues/42')).toBe(false);
    expect(isPrUrl('https://evil.example/pull/42')).toBe(false);
    expect(isPrUrl(null)).toBe(false);
    expect(isPrUrl(42)).toBe(false);
  });
});
