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

  // Amended for #16 (PM ruling on the #16 TEST DEFECT): a Cloudflare KV namespace id is an opaque
  // identifier, not a credential, so `kv_namespaces[].id` may be a real 32-char lowercase hex id.
  // Any OTHER 32-char lowercase hex string in wrangler.jsonc (a token pasted into `vars`, an
  // account id, etc.) is still flagged. Whether a real id is present is #16's AC1, not this scan's.
  it('wrangler.jsonc contains no 32-char hex value outside kv_namespaces[].id', () => {
    const wranglerPath = join(STATUS_PAGE_DIR, 'wrangler.jsonc');
    const text = readFileSync(wranglerPath, 'utf-8');
    // Strip // comments (string-aware) and trailing commas so the JSONC parses as JSON.
    const json = text
      .replace(/"(?:[^"\\]|\\.)*"|\/\/[^\n]*/g, (m) => (m.startsWith('//') ? '' : m))
      .replace(/"(?:[^"\\]|\\.)*"|,(\s*[}\]])/g, (m, tail) => (tail !== undefined ? tail : m));
    const config = JSON.parse(json);

    const hex32 = /^[0-9a-f]{32}$/;
    const offenders = [];
    const visit = (node, path) => {
      if (typeof node === 'string') {
        const isKvId = /^kv_namespaces\[\d+\]\.id$/.test(path);
        if (hex32.test(node) && !isKvId) offenders.push(`${path} = ${node}`);
      } else if (Array.isArray(node)) {
        node.forEach((v, i) => visit(v, `${path}[${i}]`));
      } else if (node && typeof node === 'object') {
        for (const [k, v] of Object.entries(node)) visit(v, path ? `${path}.${k}` : k);
      }
    };
    visit(config, '');
    expect(offenders).toEqual([]);
  });
});
