// AC17 (scannable half): "No token or secret value appears in the repo or the PR." This test
// walks status-page/ for the obvious high-risk shapes (a `wrangler secret put` value pasted
// inline, an Authorization: Bearer header with something that isn't the test placeholder, a
// `.dev.vars`/`.env` style KEY=VALUE secret line) and fails if it finds one.
//
// NOTE (scope, stated here and in the handoff): AC17 also says "a secret-pattern/gitleaks-style
// check runs as part of the PR" — that's a CI-workflow requirement, not Worker behaviour, and
// this repo has no CI workflow yet. This test covers only the "no secret value in the repo"
// half; wiring an actual gitleaks/CI step is out of a vitest test's reach and is called out as
// not covered, not silently dropped.

import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const STATUS_PAGE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry === '.git') continue;
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) walk(full, out);
    else out.push(full);
  }
  return out;
}

// Our own fixture tokens are deliberately obvious placeholders (see test/fixtures.js) — allow
// them explicitly so this scan doesn't false-positive on itself.
const ALLOWED_PLACEHOLDERS = ['test-token-mac-0000000000000000', 'test-token-vm-0000000000000000'];

describe('AC17 — no token or secret value appears in status-page/', () => {
  // Exclude this scanner file itself — its own comments describe the patterns being scanned for
  // (e.g. "Authorization: Bearer") and would otherwise false-positive against its own source.
  const SELF = fileURLToPath(import.meta.url);
  const files = walk(STATUS_PAGE_DIR).filter(
    (f) => !f.includes(`${STATUS_PAGE_DIR}/node_modules`) && f !== SELF
  );

  it('no file contains a wrangler secret bulk-style bearer value that is not our test placeholder', () => {
    const bearerPattern = /Authorization:\s*Bearer\s+([^\s"'`]+)/gi;
    const offenders = [];
    for (const file of files) {
      const text = readFileSync(file, 'utf-8');
      for (const match of text.matchAll(bearerPattern)) {
        const value = match[1].replace(/[`'"),]+$/, '');
        if (!ALLOWED_PLACEHOLDERS.includes(value) && !value.startsWith('${') && !value.startsWith('<')) {
          offenders.push(`${file}: ${match[0]}`);
        }
      }
    }
    expect(offenders).toEqual([]);
  });

  it('no file contains a plausible high-entropy secret assignment (TOKEN_MAC=/TOKEN_VM=<real-looking value>)', () => {
    const assignmentPattern = /(TOKEN_MAC|TOKEN_VM)\s*=\s*["']?([A-Za-z0-9_\-]{20,})["']?/g;
    const offenders = [];
    for (const file of files) {
      const text = readFileSync(file, 'utf-8');
      for (const match of text.matchAll(assignmentPattern)) {
        if (!ALLOWED_PLACEHOLDERS.includes(match[2])) offenders.push(`${file}: ${match[0]}`);
      }
    }
    expect(offenders).toEqual([]);
  });

  it('wrangler.jsonc does not embed a KV namespace id that looks like a real (non-placeholder) id', () => {
    const wranglerPath = join(STATUS_PAGE_DIR, 'wrangler.jsonc');
    const text = readFileSync(wranglerPath, 'utf-8');
    // Cloudflare resource ids are 32-char lowercase hex. A committed real one would leak infra
    // details; the design requires "a clearly-marked placeholder namespace id".
    const hexIdPattern = /"id"\s*:\s*"([0-9a-f]{32})"/g;
    const offenders = [...text.matchAll(hexIdPattern)];
    expect(offenders).toEqual([]);
  });
});
