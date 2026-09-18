// #16 — status-page/wrangler.jsonc carries the real STATUS KV namespace id (from infra #12
// Step 2) instead of the placeholder. Expected values come from the #16 acceptance criteria.
//
// AC1's id check is a SHAPE check (32-char lowercase hex) plus a guard against the id that #12's
// operator rolled back ("Stale" comment on #16), not a hardcoded copy of the current id: the id
// lives in a mutable comment thread, and a locked literal would become a second source of truth
// the developer can't correct. Byte-identity to the newest id-comment is the developer's grep.
//
// Forbidden strings are built by concatenation so this file never matches the ticket's own
// `grep -r` (AC2) over status-page/.

import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const STATUS_PAGE_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');
const WRANGLER_PATH = join(STATUS_PAGE_DIR, 'wrangler.jsonc');
const wranglerText = () => readFileSync(WRANGLER_PATH, 'utf-8');

const PLACEHOLDER_ID = 'REPLACE_WITH_REAL_' + 'STATUS_KV_NAMESPACE_ID';
const STALE_ROLLED_BACK_ID = 'c17966bf8d8e425c9fe7bfd742eb9dc4';

function parseJsonc(text) {
  const json = text
    .replace(/"(?:[^"\\]|\\.)*"|\/\/[^\n]*/g, (m) => (m.startsWith('//') ? '' : m))
    .replace(/"(?:[^"\\]|\\.)*"|,(\s*[}\]])/g, (m, tail) => (tail !== undefined ? tail : m));
  return JSON.parse(json);
}

function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    if (entry === 'node_modules' || entry === '.git') continue;
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) walk(full, out);
    else out.push(full);
  }
  return out;
}

describe('#16 AC1 — kv_namespaces[0].id is a real KV namespace id', () => {
  it('is a 32-character lowercase hex string', () => {
    const id = parseJsonc(wranglerText()).kv_namespaces[0].id;
    expect(id).toMatch(/^[0-9a-f]{32}$/);
  });

  it('is not the id #12 rolled back', () => {
    const id = parseJsonc(wranglerText()).kv_namespaces[0].id;
    expect(id).not.toBe(STALE_ROLLED_BACK_ID);
  });
});

describe('#16 AC2 — the placeholder id string is gone from status-page/', () => {
  it('no file under status-page/ (excluding node_modules) contains it', () => {
    const offenders = walk(STATUS_PAGE_DIR).filter((f) => readFileSync(f, 'utf-8').includes(PLACEHOLDER_ID));
    expect(offenders).toEqual([]);
  });
});

describe('#16 AC3 — the // PLACEHOLDER comment line is removed', () => {
  it('wrangler.jsonc has no line with a // PLACEHOLDER comment', () => {
    const lines = wranglerText().split('\n').filter((l) => /\/\/\s*PLACEHOLDER/.test(l));
    expect(lines).toEqual([]);
  });
});

describe('#16 AC4 — header comment no longer refers to a placeholder id', () => {
  it("does not contain 'placeholder id below'", () => {
    expect(wranglerText()).not.toContain('placeholder id ' + 'below');
  });

  it('line 2 is exactly the ticket replacement text', () => {
    expect(wranglerText().split('\n')[1]).toBe(
      '// The infra issue (#12) created the STATUS KV namespace; its id is committed below. Infra still runs'
    );
  });

  it('lines 1 and 3 are unchanged', () => {
    const lines = wranglerText().split('\n');
    expect(lines[0]).toBe(
      '// Config, not provisioning — no `wrangler` command is run as part of this issue (#11).'
    );
    expect(lines[2]).toBe(
      '// `wrangler secret put TOKEN_MAC` / `TOKEN_VM`. See README.md for the full hand-off contract.'
    );
  });
});
