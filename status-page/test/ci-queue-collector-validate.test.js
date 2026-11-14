// Issue #648 (non-blocking review finding, see the BLOCKED comment): validate.js and the
// collector (infra/ci-runners/ci-queue-collect.sh) are otherwise only exercised against
// hand-written fixtures on each side of the boundary — a schema drift between the collector's
// real output shape and validate.js's sanitiser would never be caught by that alone (both sides
// could drift together and every test would still pass). This test runs the ACTUAL collector
// script against canned API fixtures (its own CI_QUEUE_FIXTURE_DIR seam — no live network calls)
// and feeds its real stdout JSON into validateBeatPayload, asserting the sanitised ci_queue is
// byte-for-byte equal to the collector's raw output: every field the collector emits must be one
// validate.js's allowlist actually accepts, unmodified.
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateBeatPayload } from '../src/validate.js';
import { validPayload } from './fixtures.js';

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '../..');
const COLLECTOR = join(REPO_ROOT, 'infra/ci-runners/ci-queue-collect.sh');

let root;
let fixdir;
let pipe;
let reposFile;

beforeAll(() => {
  root = mkdtempSync(join(tmpdir(), 'ciq-collector-validate-'));
  fixdir = join(root, 'fixtures');
  pipe = join(root, 'pipe');
  mkdirSync(fixdir, { recursive: true });
  mkdirSync(pipe, { recursive: true });

  // Zero repos -> no run-list fixtures needed; isolates this test to the #648 runner-identity/
  // history path (the #643 queue-depth path is covered elsewhere).
  reposFile = join(root, 'repos.txt');
  writeFileSync(reposFile, '');

  // Three registrations: a dead/offline duplicate sharing a slot with a live one (the exact live
  // bug the ticket describes), plus a lone prod_deploy-labeled runner.
  writeFileSync(
    join(fixdir, 'runners-org.json'),
    JSON.stringify({
      total_count: 3,
      runners: [
        { id: 10, name: 'gha-pool-1-10', status: 'offline', busy: false, labels: [{ name: 'benjis-ci' }] },
        { id: 20, name: 'gha-pool-1-20', status: 'online', busy: true, labels: [{ name: 'benjis-ci' }] },
        {
          id: 30,
          name: 'gha-pool-2-30',
          status: 'online',
          busy: false,
          labels: [{ name: 'benjis-ci-prod-deploy' }],
        },
      ],
    }),
  );
  writeFileSync(join(fixdir, 'runners-repo.json'), JSON.stringify({ total_count: 0, runners: [] }));

  // Pre-seed history for the "gha-pool-1" slot so this cycle's rollup is a non-null integer (not
  // just the null/first-seen branch) — exercises the full int-percentage path through validate.js.
  const now = 1700000000;
  const sampleLines = [
    { ts: now - 3600, slot: 'gha-pool-1', id: 20, name: 'gha-pool-1-20', online: true, busy: true, role: 'general' },
    { ts: now - 7200, slot: 'gha-pool-1', id: 20, name: 'gha-pool-1-20', online: true, busy: false, role: 'general' },
  ]
    .map((l) => JSON.stringify(l))
    .join('\n') + '\n';
  writeFileSync(join(pipe, 'ci-runner-samples.jsonl'), sampleLines);

  const env = {
    PATH: process.env.PATH,
    HOME: process.env.HOME,
    // main() does `mkdir -p "$PIPE"` unconditionally before anything else — without this, a bare
    // spawn would default to the real ~/.claude/pipeline/state and touch live pipeline state.
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
    // No SENTRY_DSN / SLACK_WEBHOOK_URL / GH_TOKEN: this cycle must succeed, so neither path fires.
  };

  const result = spawnSync('bash', [COLLECTOR], { env, encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`collector exited ${result.status}: stdout=${result.stdout} stderr=${result.stderr}`);
  }
});

afterAll(() => {
  rmSync(root, { recursive: true, force: true });
});

// Issue #655 — history_secs + current_job, exercised against the real collector (own temp
// root/fixtures, separate from the #648 setup above so that one's zero-repo isolation is
// untouched). Proves: (a) history_secs is derived from pre-seeded sample history, (b) a busy
// slot's current_job is matched from a job already fetched for categories[] (zero new calls:
// asserted via the same CI_QUEUE_CALL_LOG seam #637's AC6 test uses), preferring a PR link built
// from the run's pull_requests[0].number (GitHub's real `pull_requests[]` shape has no `html_url`
// — verified live against benjis-ops-tool/scheduler before writing this), and (c) an idle slot
// with a same-named in_progress job (race/stale-assignment edge case) never gets a current_job —
// matching is gated on the slot being busy, not merely present.
describe('#655 — history_secs + current_job against the real collector', () => {
  let root2, fixdir2, pipe2, reposFile2, raw2;

  beforeAll(() => {
    root2 = mkdtempSync(join(tmpdir(), 'ciq-collector-655-'));
    fixdir2 = join(root2, 'fixtures');
    pipe2 = join(root2, 'pipe');
    mkdirSync(fixdir2, { recursive: true });
    mkdirSync(pipe2, { recursive: true });

    reposFile2 = join(root2, 'repos.txt');
    writeFileSync(reposFile2, 'owner1/repo1\n');

    // Two slots: gha-pool-1 (busy, has a matching in_progress job) and gha-pool-2 (idle, has a
    // same-named in_progress job that must NOT attach — the negative case).
    writeFileSync(
      join(fixdir2, 'runners-org.json'),
      JSON.stringify({
        total_count: 2,
        runners: [
          { id: 50, name: 'gha-pool-1-50', status: 'online', busy: true, labels: [{ name: 'benjis-ci' }] },
          { id: 60, name: 'gha-pool-2-60', status: 'online', busy: false, labels: [{ name: 'benjis-ci' }] },
        ],
      }),
    );
    writeFileSync(join(fixdir2, 'runners-repo.json'), JSON.stringify({ total_count: 0, runners: [] }));

    writeFileSync(join(fixdir2, 'runs-owner1__repo1-queued.json'), JSON.stringify({ total_count: 0, workflow_runs: [] }));
    writeFileSync(
      join(fixdir2, 'runs-owner1__repo1-in_progress.json'),
      JSON.stringify({
        total_count: 2,
        workflow_runs: [
          { id: 999001, event: 'pull_request', name: 'CI', actor: { login: 'jp' }, pull_requests: [{ number: 7 }] },
          { id: 999002, event: 'workflow_dispatch', name: 'CI', actor: { login: 'jp' }, pull_requests: [] },
        ],
      }),
    );
    writeFileSync(
      join(fixdir2, 'jobs-999001.json'),
      JSON.stringify({ total_count: 1, jobs: [{ status: 'in_progress', runner_name: 'gha-pool-1-50' }] }),
    );
    writeFileSync(
      join(fixdir2, 'jobs-999002.json'),
      JSON.stringify({ total_count: 1, jobs: [{ status: 'in_progress', runner_name: 'gha-pool-2-60' }] }),
    );

    // Pre-seed history for gha-pool-1 only: oldest retained sample 5400s (1.5h) before "now" ->
    // history_secs must equal exactly that span. gha-pool-2 has no prior samples -> history_secs 0.
    const now2 = 1700000000;
    writeFileSync(
      join(pipe2, 'ci-runner-samples.jsonl'),
      [{ ts: now2 - 5400, slot: 'gha-pool-1', id: 50, name: 'gha-pool-1-50', online: true, busy: true, role: 'general' }]
        .map((l) => JSON.stringify(l))
        .join('\n') + '\n',
    );

    const env2 = {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      PIPE: pipe2,
      CI_QUEUE_FORCE: '1',
      CI_QUEUE_NOW: String(now2),
      CI_QUEUE_OUT: join(pipe2, 'status-ci.json'),
      CI_QUEUE_ATTEMPT_FILE: join(pipe2, 'attempt'),
      CI_QUEUE_STATE_FILE: join(pipe2, 'state.json'),
      CI_QUEUE_LOCKDIR: join(pipe2, 'lockdir'),
      CI_QUEUE_SAMPLES_FILE: join(pipe2, 'ci-runner-samples.jsonl'),
      CI_QUEUE_CALL_LOG: join(pipe2, 'calls.log'),
      CI_QUEUE_REPOS_FILE: reposFile2,
      CI_QUEUE_FIXTURE_DIR: fixdir2,
    };

    const result2 = spawnSync('bash', [COLLECTOR], { env: env2, encoding: 'utf8' });
    if (result2.status !== 0) {
      throw new Error(`collector exited ${result2.status}: stdout=${result2.stdout} stderr=${result2.stderr}`);
    }
    raw2 = JSON.parse(readFileSync(join(pipe2, 'status-ci.json'), 'utf8'));
  });

  afterAll(() => {
    rmSync(root2, { recursive: true, force: true });
  });

  it('history_secs reflects the pre-seeded sample span per slot', () => {
    const pool1 = raw2.runners.find((r) => r.name === 'gha-pool-1-50');
    const pool2 = raw2.runners.find((r) => r.name === 'gha-pool-2-60');
    expect(pool1.history_secs).toBe(5400);
    expect(pool2.history_secs).toBe(0);
  });

  it('the busy slot gets current_job, built as a PR link from pull_requests[0].number (no html_url in the real shape)', () => {
    const pool1 = raw2.runners.find((r) => r.name === 'gha-pool-1-50');
    expect(pool1.current_job).toEqual({
      repo: 'owner1/repo1',
      run_id: 999001,
      pr_url: 'https://github.com/owner1/repo1/pull/7',
    });
  });

  it('the idle slot never gets current_job, even though a same-named in_progress job exists (gated on busy, not presence)', () => {
    const pool2 = raw2.runners.find((r) => r.name === 'gha-pool-2-60');
    expect(pool2).not.toHaveProperty('current_job');
  });

  it('adds zero new API calls beyond the existing per-cycle budget (2 + 2*repos + job-lookups already made for categories[])', () => {
    const calls = Number(readFileSync(join(pipe2, 'calls.log'), 'utf8').trim());
    // 2 (org+repo runner lists) + 2 (queued+in_progress run lists for the one repo) + 2 (one job
    // lookup per in_progress run, already made for categories[] before this ticket) = 6.
    expect(calls).toBe(6);
  });

  it('validateBeatPayload passes the real ci_queue object (history_secs + current_job included) through unchanged', () => {
    const result = validateBeatPayload(validPayload({ ci_queue: raw2 }));
    expect(result.ok).toBe(true);
    expect(result.value.ci_queue).toEqual(raw2);
  });
});

describe('validate.js against the real collector output (issue #648)', () => {
  it('the collector produced a ci_queue with the expected runner shapes (sanity before comparing)', () => {
    const raw = JSON.parse(readFileSync(join(pipe, 'status-ci.json'), 'utf8'));
    expect(raw.runners_total).toBe(2);
    expect(raw.runners_busy).toBe(1);
    expect(raw.runners_offline).toBe(1);
    // The dead duplicate (id 10) merged into slot gha-pool-1's live registration (id 20) — one
    // entry, not two.
    expect(raw.runners).toHaveLength(2);
    const pool1 = raw.runners.find((r) => r.id === 20);
    expect(pool1).toBeDefined();
    expect(pool1.online).toBe(true);
    expect(pool1.busy).toBe(true);
    expect(raw.runners.some((r) => r.id === 10)).toBe(false);
    const prodDeploy = raw.runners.find((r) => r.id === 30);
    expect(prodDeploy.role).toBe('prod_deploy');
    // Seeded history -> a real (non-null) integer utilization percentage for slot gha-pool-1.
    expect(typeof pool1.util_24h_pct).toBe('number');
  });

  it('validateBeatPayload passes the real ci_queue object through unchanged', () => {
    const raw = JSON.parse(readFileSync(join(pipe, 'status-ci.json'), 'utf8'));
    const result = validateBeatPayload(validPayload({ ci_queue: raw }));
    expect(result.ok).toBe(true);
    // Whole-object equality (not just ok:true / spot fields): a field the collector emits that
    // validate.js's allowlist doesn't know about, or sanitises differently, would show up here as
    // a diff — this is the structural guard against collector/validate.js schema drift.
    expect(result.value.ci_queue).toEqual(raw);
  });
});

// Issue #657 — drift guard for the NEW categories[].queued[] shape specifically: the two describe
// blocks above never exercise a non-empty queued[] (the #648/#655 fixtures have no queued run at
// all), so a collector/validate.js shape mismatch on this new field would slip past both of them.
// Own temp root/fixtures, separate from the others above.
describe('#657 — categories[].queued[] against the real collector', () => {
  let root3, fixdir3, pipe3, reposFile3, raw3;

  beforeAll(() => {
    root3 = mkdtempSync(join(tmpdir(), 'ciq-collector-657-'));
    fixdir3 = join(root3, 'fixtures');
    pipe3 = join(root3, 'pipe');
    mkdirSync(fixdir3, { recursive: true });
    mkdirSync(pipe3, { recursive: true });

    reposFile3 = join(root3, 'repos.txt');
    writeFileSync(reposFile3, 'owner2/repo2\n');

    writeFileSync(join(fixdir3, 'runners-org.json'), JSON.stringify({ total_count: 0, runners: [] }));
    writeFileSync(join(fixdir3, 'runners-repo.json'), JSON.stringify({ total_count: 0, runners: [] }));

    // Two queued runs:
    //  - 888001: head_branch main, a deploy|release-named workflow (-> prod_deploy, #657 rule
    //    3), with an attached PR, a display_title, and a fractional-seconds `created_at` (the
    //    queued[] source of truth is now the RUN's own `created_at`, not its job's — this
    //    exercises the same fractional-seconds strip on that field instead).
    //  - 888002: no `display_title` at all (title omitted, not null — the exact mismatch this
    //    drift guard exists to catch; see validate.js's sanitiseCiQueueQueuedItem).
    writeFileSync(join(fixdir3, 'runs-owner2__repo2-queued.json'), JSON.stringify({
      total_count: 2,
      workflow_runs: [
        {
          id: 888001,
          name: 'Auto-release',
          head_branch: 'main',
          event: 'workflow_run',
          actor: { login: 'jp' },
          display_title: 'Auto-release #888001',
          created_at: '2026-11-10T10:00:00.500Z',
          pull_requests: [{ number: 7 }],
        },
        {
          id: 888002,
          name: 'CI',
          head_branch: 'feature/x',
          event: 'schedule',
          actor: { login: 'jp' },
          created_at: '2026-11-10T09:00:00Z',
          pull_requests: [],
        },
      ],
    }));
    writeFileSync(join(fixdir3, 'runs-owner2__repo2-in_progress.json'), JSON.stringify({ total_count: 0, workflow_runs: [] }));
    writeFileSync(
      join(fixdir3, 'jobs-888001.json'),
      JSON.stringify({ total_count: 1, jobs: [{ id: 1, status: 'queued', created_at: '2026-11-10T10:00:00.500Z' }] }),
    );
    writeFileSync(
      join(fixdir3, 'jobs-888002.json'),
      JSON.stringify({ total_count: 1, jobs: [{ id: 2, status: 'queued', created_at: '2026-11-10T09:00:00Z' }] }),
    );

    const env3 = {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      PIPE: pipe3,
      CI_QUEUE_FORCE: '1',
      CI_QUEUE_OUT: join(pipe3, 'status-ci.json'),
      CI_QUEUE_ATTEMPT_FILE: join(pipe3, 'attempt'),
      CI_QUEUE_STATE_FILE: join(pipe3, 'state.json'),
      CI_QUEUE_LOCKDIR: join(pipe3, 'lockdir'),
      CI_QUEUE_SAMPLES_FILE: join(pipe3, 'ci-runner-samples.jsonl'),
      CI_QUEUE_CALL_LOG: join(pipe3, 'calls.log'),
      CI_QUEUE_REPOS_FILE: reposFile3,
      CI_QUEUE_FIXTURE_DIR: fixdir3,
    };

    const result3 = spawnSync('bash', [COLLECTOR], { env: env3, encoding: 'utf8' });
    if (result3.status !== 0) {
      throw new Error(`collector exited ${result3.status}: stdout=${result3.stdout} stderr=${result3.stderr}`);
    }
    raw3 = JSON.parse(readFileSync(join(pipe3, 'status-ci.json'), 'utf8'));
  });

  afterAll(() => {
    rmSync(root3, { recursive: true, force: true });
  });

  it('the run categorizes prod_deploy with a populated queued[] (repo, run_id, pr_url, title, queued_at)', () => {
    const prodDeploy = raw3.categories.find((c) => c.key === 'prod_deploy');
    expect(prodDeploy).toBeDefined();
    expect(prodDeploy.count).toBe(1);
    expect(prodDeploy.queued).toEqual([
      {
        repo: 'owner2/repo2',
        run_id: 888001,
        pr_url: 'https://github.com/owner2/repo2/pull/7',
        title: 'Auto-release #888001',
        queued_at: '2026-11-10T10:00:00Z',
      },
    ]);
  });

  it('a run with no display_title OMITS the title key entirely (never title: null)', () => {
    const other = raw3.categories.find((c) => c.key === 'other');
    expect(other).toBeDefined();
    expect(other.queued).toEqual([
      {
        repo: 'owner2/repo2',
        run_id: 888002,
        pr_url: null,
        queued_at: '2026-11-10T09:00:00Z',
      },
    ]);
    expect(other.queued[0]).not.toHaveProperty('title');
  });

  it('validateBeatPayload passes the real ci_queue object (with queued[]) through unchanged', () => {
    const result = validateBeatPayload(validPayload({ ci_queue: raw3 }));
    expect(result.ok).toBe(true);
    expect(result.value.ci_queue).toEqual(raw3);
  });
});
