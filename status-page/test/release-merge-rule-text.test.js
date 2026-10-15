// Issue #223: tracked rule text must state JP's 2026-10-12 auto-release decision.
// Expected values come from the ticket: the two verbatim JP quotes, the removed phrase
// "Merging stays JP's call", and AC2/AC5 wording. Docs-only ticket: checks are text checks.
//
// NOTE: the ticket cites agents/project-manager.md:30/:34/:52, but that file is now a thin
// deprecated alias (claude-agents#192). Those rules (JP-only list, "JP's recorded decisions
// win", "Plus whatever the brief adds") live in agents/delivery-lead.md, so the checks target it.

import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (p) => readFileSync(join(root, p), 'utf8');
const claudeMd = read('CLAUDE.md');
const deliveryLead = read('agents/delivery-lead.md');

const QUOTE_1 = 'the whole point of continuous deployment is not to wait for my staging approval';
const QUOTE_2 =
  'only destructive database changes should require safe route. Low risk database changes, the continuous deployment route. Use the risky list that Kimmy had given us';

const sentences = (t) => t.split(/(?<=[.!?])\s+|\n+/);

describe('AC1: JP decision quoted verbatim in tracked text', () => {
  it.each([
    ['CLAUDE.md', () => claudeMd],
    ['agents/delivery-lead.md', () => deliveryLead],
  ])('%s contains quote 1 verbatim', (_n, get) => {
    expect(get()).toContain(QUOTE_1);
  });

  it.each([
    ['CLAUDE.md', () => claudeMd],
    ['agents/delivery-lead.md', () => deliveryLead],
  ])('%s contains quote 2 verbatim', (_n, get) => {
    expect(get()).toContain(QUOTE_2);
  });

  it.each([
    ['CLAUDE.md', () => claudeMd],
    ['agents/delivery-lead.md', () => deliveryLead],
  ])('%s says releases NOT on the risky list merge to main without JP', (_n, get) => {
    // Positive polarity only: "not on the risky list" + "merges to main without JP",
    // and no sentence that makes such merges need JP.
    const s = sentences(get());
    const positive = s.filter(
      (x) => /not on the risky list/i.test(x) && /merges? to `?main`? without JP/i.test(x),
    );
    expect(positive.length, 'sentence: non-risky releases merge to main without JP').toBeGreaterThan(0);
    for (const x of positive) expect(x).not.toMatch(/\b(never|must not|may not|cannot|needs? JP|requires? JP)\b/i);
  });

  it.each([
    ['CLAUDE.md', () => claudeMd],
    ['agents/delivery-lead.md', () => deliveryLead],
  ])('%s says risky-list (destructive DB) changes stay JP-only', (_n, get) => {
    const ok = sentences(get()).some(
      (x) => /on the risky list/i.test(x) && !/not on the risky list/i.test(x) && /destructive database changes/i.test(x) && /stays? JP-only/i.test(x),
    );
    expect(ok, 'sentence: a change on the risky list stays JP-only').toBe(true);
  });

  it.each([
    ['CLAUDE.md', () => claudeMd],
    ['agents/delivery-lead.md', () => deliveryLead],
  ])('%s keeps a prod `go` JP has not given JP-only, in the same paragraph as the decision', (_n, get) => {
    const para = get().split(/\n+/).find((l) => l.includes(QUOTE_2));
    expect(para, 'paragraph containing quote 2').toBeDefined();
    expect(sentences(para).some((x) => /prod `go` JP has not given/i.test(x) && /JP-only/i.test(x))).toBe(true);
  });
});

describe('AC4: blanket "JP merges" wording is gone', () => {
  const files = ['CLAUDE.md', ...readdirSync(join(root, 'agents')).filter((f) => f.endsWith('.md')).map((f) => `agents/${f}`)];

  it.each(files)("%s has no \"Merging stays JP's call\"", (f) => {
    expect(read(f)).not.toContain("Merging stays JP's call");
  });

  it('delivery-lead JP-only list no longer lists every merge to main as JP-only', () => {
    // Old text: "merge or push to `main`, promotion of staging — merging it, not preparing it".
    expect(deliveryLead).not.toMatch(/merge or push to `main`, promotion of staging/);
  });
});

describe('AC2: a brief cannot grant a permission the tracked text forbids', () => {
  it('delivery-lead states the rule in one sentence', () => {
    const ok = sentences(deliveryLead).some(
      (x) => /\bbrief\b/i.test(x) && /(cannot|can't|may not) (grant|widen)/i.test(x) && /forbids?/i.test(x),
    );
    expect(ok).toBe(true);
  });

  it('"JP\'s recorded decisions win" is tied to tracked text (not an untracked brief file)', () => {
    const ok = sentences(deliveryLead).some((x) => /recorded decision/i.test(x) && /(tracked|in git|CLAUDE\.md|agent rule)/i.test(x));
    expect(ok).toBe(true);
  });

  it('the brief clause adds limits only (no bare "Plus whatever the brief adds")', () => {
    expect(deliveryLead).not.toMatch(/Plus whatever the brief adds\./);
  });
});

describe('AC5: no new mechanism', () => {
  it('deployer.md does not read a router label', () => {
    expect(read('agents/deployer.md')).not.toMatch(/router/i);
  });

  it('no new "[jp] ROUTE direct" marker anywhere in rule text', () => {
    for (const f of ['CLAUDE.md', 'agents/delivery-lead.md', 'agents/deployer.md', 'agents/product-manager.md']) {
      expect(read(f), f).not.toMatch(/ROUTE direct/);
    }
  });
});

// Issue #279: docs describe continuous deployment as live; hand-promotion is a fallback only.
describe('#279: direct route is automatic, promotion by hand is a fallback', () => {
  const deployerDesc = read('agents/deployer.md').split('\n').find((l) => l.startsWith('description:'));
  const claudeLines = claudeMd.split('\n');
  const para = (prefix) => claudeLines.find((l) => l.startsWith(prefix)) ?? '';

  it('deployer description names the release bot / direct route and that only staging-route changes need JP', () => {
    expect(deployerDesc).not.toMatch(/manual review/i);
    expect(deployerDesc).toMatch(/release bot/i);
    expect(deployerDesc).toMatch(/direct route/i);
    expect(deployerDesc).toMatch(/only staging-route \(risky-list\) changes need JP/);
  });

  it('no "manual review" in agents/ or CLAUDE.md', () => {
    for (const f of ['CLAUDE.md', ...readdirSync(join(root, 'agents')).filter((x) => x.endsWith('.md')).map((x) => `agents/${x}`)]) {
      expect(read(f), f).not.toMatch(/manual review/i);
    }
  });

  it.each(['**Exception — promotion PRs.**', '**Exception — releases**'])('CLAUDE.md "%s" states it is a fallback', (p) => {
    const t = para(p);
    expect(t).not.toBe('');
    expect(t).toMatch(/fallback only/);
    expect(t).toMatch(/staging-route \(risky-list\) change JP has approved/);
    expect(t).toMatch(/release bot \/ `AUTO_PROMOTE_ENABLED` path is shown broken/);
  });

  it('CLAUDE.md Software development has the automatic-release sentence verbatim', () => {
    expect(claudeMd).toContain(
      'Production release is automatic for direct-route changes (release bot, `release/auto-*` PRs). Sessions never promote by hand and never tell JP prod is his to approve unless the router put the change on the staging route. Check recent `release/auto-*` PRs on `main` before describing the release flow; fetch `origin/main` before quoting a repo doc — local checkouts go stale.',
    );
  });

  it('delivery-lead never hand-promotes direct-route changes', () => {
    expect(deliveryLead).toMatch(/never hand-promotes? direct-route changes/i);
  });
});
