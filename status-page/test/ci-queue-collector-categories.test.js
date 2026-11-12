// Issue #657 — prod_deploy/staging_deploy category split (out of the old single deploy_release
// bucket) + the new capped per-category queued_items list. Runs the ACTUAL collector script
// (infra/ci-runners/ci-queue-collect.sh) against canned CI_QUEUE_FIXTURE_DIR fixtures — no live
// network calls, same seam ci-queue-collector-validate.test.js's #648/#655 describes use — and
// feeds its real stdout JSON into validateBeatPayload, so a schema drift between the collector's
// real output shape and validate.js's sanitiser is caught the same way, for this ticket's fields.
//
// A sibling file (not an extension of ci-queue-collector-validate.test.js) to keep that file's
// already-passing #648/#655 fixtures untouched.
import { describe, it, expect } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateBeatPayload } from '../src/validate.js';
import { validPayload } from './fixtures.js';

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '../..');
const COLLECTOR = join(REPO_ROOT, 'infra/ci-runners/ci-queue-collect.sh');

function safeName(repo) {
  return repo.replace('/', '__');
}

/** runCollector({repos, fixtures}) -> {raw, calls}. Spawns the real collector once, cleans up after. */
function runCollector({ repos, fixtures, now = 1700000000 }) {
  const root = mkdtempSync(join(tmpdir(), 'ciq-categories-'));
  const fixdir = join(root, 'fixtures');
  const pipe = join(root, 'pipe');
  mkdirSync(fixdir, { recursive: true });
  mkdirSync(pipe, { recursive: true });
  const reposFile = join(root, 'repos.txt');
  writeFileSync(reposFile, repos.join('\n') + '\n');
  writeFileSync(join(fixdir, 'runners-org.json'), JSON.stringify({ total_count: 0, runners: [] }));
  writeFileSync(join(fixdir, 'runners-repo.json'), JSON.stringify({ total_count: 0, runners: [] }));
  for (const [name, content] of Object.entries(fixtures)) {
    writeFileSync(join(fixdir, name), typeof content === 'string' ? content : JSON.stringify(content));
  }

  const env = {
    PATH: process.env.PATH,
    HOME: process.env.HOME,
    PIPE: pipe,
    CI_QUEUE_FORCE: '1',
    CI_QUEUE_NOW: String(now),
    CI_QUEUE_OUT: join(pipe, 'status-ci.json'),
    CI_QUEUE_ATTEMPT_FILE: join(pipe, 'attempt'),
    CI_QUEUE_STATE_FILE: join(pipe, 'state.json'),
    CI_QUEUE_LOCKDIR: join(pipe, 'lockdir'),
    CI_QUEUE_SAMPLES_FILE: join(pipe, 'ci-runner-samples.jsonl'),
    CI_QUEUE_CALL_LOG: join(pipe, 'calls.log'),
    CI_QUEUE_REPOS_FILE: reposFile,
    CI_QUEUE_FIXTURE_DIR: fixdir,
  };

  const result = spawnSync('bash', [COLLECTOR], { env, encoding: 'utf8' });
  if (result.status !== 0) {
    rmSync(root, { recursive: true, force: true });
    throw new Error(`collector exited ${result.status}: stdout=${result.stdout} stderr=${result.stderr}`);
  }
  const raw = JSON.parse(readFileSync(join(pipe, 'status-ci.json'), 'utf8'));
  const calls = Number(readFileSync(join(pipe, 'calls.log'), 'utf8').trim());
  rmSync(root, { recursive: true, force: true });
  return { raw, calls };
}

/** One queued run with one queued job, for a given repo-safe-name fixture set. */
function queuedRunFixtures(safe, { id, name, event = 'push', headBranch, pullRequests = [], queuedAt }) {
  return {
    [`runs-${safe}-queued.json`]: {
      workflow_runs: [
        { id, name, event, actor: { login: 'jp' }, head_branch: headBranch, pull_requests: pullRequests },
      ],
    },
    [`runs-${safe}-in_progress.json`]: { workflow_runs: [] },
    [`jobs-${id}.json`]: { jobs: [{ id: id + 90000, status: 'queued', created_at: queuedAt }] },
  };
}

describe('#657 — category split (prod_deploy/staging_deploy) + queued_items, real collector', () => {
  const repo = 'example-owner/q657';
  const safe = safeName(repo);

  it('a queued run on main for a deploy|release-named workflow -> prod_deploy', () => {
    const { raw } = runCollector({
      repos: [repo],
      fixtures: queuedRunFixtures(safe, { id: 701, name: 'Auto-release', headBranch: 'main', queuedAt: '2026-11-10T01:00:00Z' }),
    });
    expect(raw.categories).toEqual([{ key: 'prod_deploy', count: 1 }]);
    expect(raw.queued_items).toEqual([{ key: 'prod_deploy', repo, run_id: 701, pr_url: null, queued_at: '2026-11-10T01:00:00Z' }]);
  });

  it('a queued run on staging for the same workflow name -> staging_deploy', () => {
    const { raw } = runCollector({
      repos: [repo],
      fixtures: queuedRunFixtures(safe, { id: 702, name: 'Auto-release', headBranch: 'staging', queuedAt: '2026-11-10T02:00:00Z' }),
    });
    expect(raw.categories).toEqual([{ key: 'staging_deploy', count: 1 }]);
    expect(raw.queued_items).toEqual([{ key: 'staging_deploy', repo, run_id: 702, pr_url: null, queued_at: '2026-11-10T02:00:00Z' }]);
  });

  it('a Post-release cleanup run (name matches but neither branch) -> deploy_release', () => {
    const { raw } = runCollector({
      repos: [repo],
      fixtures: queuedRunFixtures(safe, { id: 703, name: 'Post-release cleanup', headBranch: 'cleanup-branch', queuedAt: '2026-11-10T03:00:00Z' }),
    });
    expect(raw.categories).toEqual([{ key: 'deploy_release', count: 1 }]);
    expect(raw.queued_items).toEqual([{ key: 'deploy_release', repo, run_id: 703, pr_url: null, queued_at: '2026-11-10T03:00:00Z' }]);
  });

  it('a queued run with no attached PR -> list item has pr_url: null, still included (not dropped)', () => {
    const { raw } = runCollector({
      repos: [repo],
      fixtures: queuedRunFixtures(safe, { id: 704, name: 'CI', event: 'pull_request', headBranch: 'feature-x', pullRequests: [], queuedAt: '2026-11-10T04:00:00Z' }),
    });
    expect(raw.queued_items).toHaveLength(1);
    expect(raw.queued_items[0]).toMatchObject({ key: 'pr', repo, run_id: 704, pr_url: null });
  });

  it('two queued runs sharing the same run id (scheduler/benjis-ops-tool alias) dedupe to one list entry', () => {
    const repoA = 'Benjis-Plants/scheduler';
    const repoB = 'Benjis-Plants/benjis-ops-tool';
    const safeA = safeName(repoA);
    const safeB = safeName(repoB);
    const fixtures = {
      ...queuedRunFixtures(safeA, { id: 9999, name: 'CI', event: 'schedule', headBranch: 'main-alias', queuedAt: '2026-11-10T05:00:00Z' }),
      ...queuedRunFixtures(safeB, { id: 9999, name: 'CI', event: 'schedule', headBranch: 'main-alias', queuedAt: '2026-11-10T05:00:00Z' }),
    };
    const { raw } = runCollector({ repos: [repoA, repoB], fixtures });
    expect(raw.queued_items).toHaveLength(1);
    expect(raw.queued_items[0].run_id).toBe(9999);
    // Documented limitation: categories[] stays per-job/not deduped across the alias — both
    // repos' job lookups count, so the category count disagrees with the deduped list length.
    expect(raw.categories).toEqual([{ key: 'other', count: 2 }]);
  });

  it('more queued items than the cap -> truncated per category, never a crash', () => {
    const repos = ['example-owner/q657a', 'example-owner/q657b', 'example-owner/q657c'];
    let fixtures = {};
    let id = 801;
    for (const r of repos) {
      const s = safeName(r);
      const runs = [];
      for (let i = 0; i < 5; i++) {
        runs.push({ id, name: 'CI', event: 'schedule', actor: { login: 'jp' }, head_branch: 'main-unrelated', pull_requests: [] });
        fixtures[`jobs-${id}.json`] = { jobs: [{ id: id + 90000, status: 'queued', created_at: `2026-11-10T0${String(id % 9)}:00:00Z` }] };
        id += 1;
      }
      fixtures[`runs-${s}-queued.json`] = { workflow_runs: runs };
      fixtures[`runs-${s}-in_progress.json`] = { workflow_runs: [] };
    }
    const { raw } = runCollector({ repos, fixtures });
    // 15 total queued "other" runs across 3 repos (5 each, MAX_RUN_LOOKUPS_PER_REPO) — the
    // queued_items list for "other" is capped (MAX_CI_QUEUE_QUEUED_ITEMS), never a crash, never
    // silently unbounded.
    expect(raw.categories.find((c) => c.key === 'other').count).toBe(15);
    const otherItems = raw.queued_items.filter((i) => i.key === 'other');
    expect(otherItems.length).toBeGreaterThan(0);
    expect(otherItems.length).toBeLessThan(15);
    expect(otherItems.length).toBeLessThanOrEqual(10);
  });

  it('zero queued items -> empty list, no error', () => {
    const { raw } = runCollector({
      repos: [repo],
      fixtures: {
        [`runs-${safe}-queued.json`]: { workflow_runs: [] },
        [`runs-${safe}-in_progress.json`]: { workflow_runs: [] },
      },
    });
    expect(raw.queued_items).toEqual([]);
    expect(raw.categories).toEqual([]);
  });

  it('validateBeatPayload passes the real queued_items through unchanged', () => {
    const { raw } = runCollector({
      repos: [repo],
      fixtures: queuedRunFixtures(safe, { id: 705, name: 'Auto-release', headBranch: 'main', queuedAt: '2026-11-10T06:00:00Z' }),
    });
    const result = validateBeatPayload(validPayload({ ci_queue: raw }));
    expect(result.ok).toBe(true);
    expect(result.value.ci_queue).toEqual(raw);
  });

  it('adds zero new gh api calls for the category-split/queued_items path', () => {
    const { calls } = runCollector({
      repos: [repo],
      fixtures: queuedRunFixtures(safe, { id: 706, name: 'Auto-release', headBranch: 'main', queuedAt: '2026-11-10T07:00:00Z' }),
    });
    // 2 (org+repo runner lists) + 2 (queued+in_progress run lists) + 1 (one job lookup, already
    // made for categories[] before this ticket) = 5.
    expect(calls).toBe(5);
  });
});
