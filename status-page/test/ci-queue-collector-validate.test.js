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
