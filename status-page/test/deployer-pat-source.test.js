// #238: deployer.md names the Supabase PAT source per host, in both the RFP Finder and
// staging-model sections, and lets a repo CLAUDE.md override it.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const deployer = readFileSync(join(here, '..', '..', 'agents', 'deployer.md'), 'utf8');
const MAC = '~/.claude/projects/-Users-jean-philippemoya-dev/memory/reference_supabase-pat.md';
const VM = '~/.claude/projects/-home-claude/memory/reference_supabase-pat.md';
const staging = deployer.slice(deployer.indexOf('### Staging-model repos'));
const rfp = deployer.slice(deployer.indexOf('### Benjis RFP Finder'), deployer.indexOf('### Staging-model repos'));

describe('deployer.md PAT source', () => {
  it('staging-model section names Mac and VM PAT paths', () => {
    expect(staging).toContain(MAC);
    expect(staging).toContain(VM);
  });
  it('RFP Finder section names both hosts', () => {
    expect(rfp).toContain(MAC);
    expect(rfp).toContain(VM);
  });
  it('repo CLAUDE.md PAT source takes precedence', () => {
    expect(staging).toMatch(/CLAUDE\.md[^\n]*(takes precedence|wins)/i);
  });
});
