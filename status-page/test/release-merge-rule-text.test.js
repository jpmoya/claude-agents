// Issue #223: tracked rule text must state JP's 2026-10-12 auto-release decision.
// Expected values come from the ticket: the two verbatim JP quotes, the removed phrase
// "Merging stays JP's call", and AC2/AC5 wording. Docs-only ticket: checks are text checks.
//
// NOTE: the ticket cites agents/project-manager.md:30/:34/:52, but that file is now a thin
// deprecated alias (claude-agents#192). Those rules (JP-only list, "JP's recorded decisions
// win", "Plus whatever the brief adds") live in agents/delivery-lead.md, so the checks target it.

import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
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
  ])('%s says non-risky-list releases merge to main without JP, risky list stays JP-only', (_n, get) => {
    const s = sentences(get());
    const merge = s.some((x) => /risky list/i.test(x) && /merge/i.test(x) && /without JP/i.test(x));
    const jpOnly = s.some((x) => /risky/i.test(x) && /destructive/i.test(x) && /JP-only/i.test(x));
    expect(merge, 'sentence: non-risky releases merge to main without JP').toBe(true);
    expect(jpOnly, 'sentence: risky-list (destructive DB) changes stay JP-only').toBe(true);
  });

  it('prod `go` not given by JP stays JP-only (stated next to the decision)', () => {
    const ok = sentences(claudeMd).some((x) => /prod/i.test(x) && /`?go`?/.test(x) && /JP-only/i.test(x));
    expect(ok).toBe(true);
  });
});

describe('AC4: blanket "JP merges" wording is gone', () => {
  it("CLAUDE.md no longer contains \"Merging stays JP's call\"", () => {
    expect(claudeMd).not.toContain("Merging stays JP's call");
  });

  it.each(['CLAUDE.md', 'agents/delivery-lead.md', 'agents/project-manager.md'])(
    "%s has no \"Merging stays JP's call\"",
    (f) => {
      expect(read(f)).not.toContain("Merging stays JP's call");
    },
  );

  it('delivery-lead JP-only list no longer lists every merge to main as JP-only', () => {
    // Old text: "merge or push to `main`, promotion of staging — merging it, not preparing it".
    expect(deliveryLead).not.toMatch(/merge or push to `main`, promotion of staging/);
  });
});

describe('AC2: a brief cannot grant a permission the tracked text forbids', () => {
  it('delivery-lead states the rule in one sentence', () => {
    const ok = sentences(deliveryLead).some(
      (x) => /brief/i.test(x) && /(cannot|can't|never|may not|only adds? limits)/i.test(x) && /(grant|widen|permission|forbid)/i.test(x),
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
