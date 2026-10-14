// #250 decisions 1, 2 and 4 in groupTickets / validate / render. Expected values come from the ticket's
// "Decisions" and "Test fixtures" sections, not from src/.

import { describe, it, expect } from 'vitest';
import { groupTickets } from '../src/group.js';
import { validateBeatPayload } from '../src/validate.js';
import { renderPage } from '../src/render.js';
import { validPayload, validRun, validCompleted, hostRecord } from './fixtures.js';

const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;
const ago = (hours) => new Date((NOW - hours * 3600) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const urlOf = (n) => `https://github.com/example-owner/project-a/issues/${n}`;
const NEEDS = 'Needs JP';
const PARKED = 'Parked';
const DONE = 'Done';

const held = (issue, o = {}) =>
  validRun({ issue, url: urlOf(issue), title: `T${issue}`, state: 'held', marker: 'BLOCKED', last_activity_at: ago(1), ...o });
const group = (runs, completed = []) => groupTickets({ mac: hostRecord({ runs, completed }), vm: null }, NOW);
const issuesOf = (g, heading) => g.find((x) => x.heading === heading).rows.map((r) => r.issue);

describe('#250 decision 2 — group.js: auto_retry is demoted like answered', () => {
  it('held BLOCKED with parked_reason auto_retry -> Parked, not Needs JP', () => {
    const g = group([held(1, { parked_reason: 'auto_retry' })]);
    expect(issuesOf(g, PARKED)).toEqual([1]);
    expect(issuesOf(g, NEEDS)).toEqual([]);
  });

  it('auto_retry stays visible in Parked even when older than the 7-day Parked hide', () => {
    const g = group([held(2, { parked_reason: 'auto_retry', last_activity_at: ago(24 * 10), gate_at: ago(24 * 10) })]);
    expect(issuesOf(g, PARKED)).toEqual([2]);
  });
});

describe('#250 decision 1 — conservative default stays in Needs JP', () => {
  it('held BLOCKED with no parked_reason -> Needs JP', () => {
    const g = group([held(3)]);
    expect(issuesOf(g, NEEDS)).toEqual([3]);
    expect(issuesOf(g, PARKED)).toEqual([]);
  });

  it.each(['MOCKUPS PENDING APPROVAL', 'AWAITING GO', 'EFFORT APPROVAL NEEDED'])('%s with no parked_reason -> Needs JP', (marker) => {
    expect(issuesOf(group([held(4, { marker })]), NEEDS)).toEqual([4]);
  });
});

describe('#250 decision 4 — finished held runs are in neither Needs JP nor Parked', () => {
  it.each(['DEPLOYED', 'DEPLOYED TO STAGING', 'APPLIED', 'SPLIT'])('held run with marker %s -> omitted when not in completed[]', (marker) => {
    const g = group([held(5, { marker })]);
    expect(issuesOf(g, NEEDS)).toEqual([]);
    expect(issuesOf(g, PARKED)).toEqual([]);
    expect(issuesOf(g, DONE)).toEqual([]);
  });

  it('held DEPLOYED run that is in completed[] (closed 2h ago) -> Done only', () => {
    const g = group([held(6, { marker: 'DEPLOYED' })], [validCompleted({ issue: 6, url: urlOf(6), closed_at: ago(2) })]);
    expect(issuesOf(g, DONE)).toEqual([6]);
    expect(issuesOf(g, NEEDS)).toEqual([]);
    expect(issuesOf(g, PARKED)).toEqual([]);
  });

  it('held DEPLOYED run with a fresh last_activity_at (1h) is still omitted from Parked (not just aged out)', () => {
    expect(issuesOf(group([held(7, { marker: 'DEPLOYED', last_activity_at: ago(1) })]), PARKED)).toEqual([]);
  });
});

describe('#250 closed-ticket leak — held run whose issue is in completed[]', () => {
  it('in completed[] closed 10 days ago (outside the 7-day Done window) -> not in Needs JP', () => {
    const g = group([held(8)], [validCompleted({ issue: 8, url: urlOf(8), closed_at: ago(24 * 10) })]);
    expect(issuesOf(g, NEEDS)).toEqual([]);
  });

  it('in completed[] closed 10 days ago -> not in Parked either (closed tickets are dropped)', () => {
    const g = group([held(9)], [validCompleted({ issue: 9, url: urlOf(9), closed_at: ago(24 * 10) })]);
    expect(issuesOf(g, PARKED)).toEqual([]);
  });
});

describe('#250 payload — parked_reason auto_retry and block_class survive validation', () => {
  const runOut = (extra) => {
    const result = validateBeatPayload(validPayload({ runs: [validRun({ state: 'held', marker: 'BLOCKED', ...extra })] }));
    expect(result.ok).toBe(true);
    return result.value.runs[0];
  };

  it('parked_reason auto_retry is kept', () => {
    expect(runOut({ parked_reason: 'auto_retry' }).parked_reason).toBe('auto_retry');
  });

  it.each(['ci_pending', 'ci_red', 'merge_conflict', 'dependency', 'unsupported_project', 'other'])('block_class %s is kept', (block_class) => {
    expect(runOut({ block_class }).block_class).toBe(block_class);
  });

  it.each(['<script>', 'needs_jp', 'free text from a comment', '', 5, null])('invalid block_class %j is dropped, run kept', (block_class) => {
    const run = runOut({ block_class });
    expect(run).not.toHaveProperty('block_class');
    expect(run.issue).toBe(42);
  });
});

describe('#250 decision 2 — Parked rows show a fixed reason label', () => {
  const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
  const parkedHtml = (block_class) => {
    const html = renderPage(
      { mac: hostRecord({ runs: [held(10, { parked_reason: 'auto_retry', block_class })] }), vm: null },
      thresholds,
      NOW,
    );
    const m = /<h2[^>]*>\s*Parked \(\d+\)\s*<\/h2>/.exec(html);
    expect(m, 'Parked heading present').not.toBeNull();
    const rest = html.slice(m.index + m[0].length);
    const next = rest.search(/<h2/);
    return next === -1 ? rest : rest.slice(0, next);
  };

  // Text of the single Parked row for issue 10 (tags stripped), so a label must be rendered in that row itself.
  const rowText = (cls) => {
    const section = parkedHtml(cls);
    const rows = section.match(/<tr[\s\S]*?<\/tr>/g) || [];
    const row = rows.find((r) => r.includes('/issues/10'));
    expect(row, 'Parked row for #10 present').toBeDefined();
    return row.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');
  };
  const LABELS = ['CI/billing', 'merge conflict', 'waiting on dependency'];

  it.each([
    ['ci_pending', 'CI/billing'],
    ['ci_red', 'CI/billing'],
    ['merge_conflict', 'merge conflict'],
    ['dependency', 'waiting on dependency'],
  ])('block_class %s -> label "%s" in its Parked row and no other class label', (cls, label) => {
    const text = rowText(cls);
    expect(text).toContain(label);
    for (const other of LABELS.filter((l) => l !== label)) expect(text).not.toContain(other);
    expect(text).not.toMatch(/\bother\b/); // control: bare word "other" is only the label of class other
  });

  it.each(['other', 'unsupported_project'])('block_class %s -> bare label "other" in its Parked row', (cls) => {
    const text = rowText(cls);
    expect(text).toMatch(/\bother\b/);
    for (const l of LABELS) expect(text).not.toContain(l);
  });

  it('the Needs JP section never shows these labels (Parked only)', () => {
    const html = renderPage({ mac: hostRecord({ runs: [held(11)] }), vm: null }, thresholds, NOW);
    expect(html).not.toContain('waiting on dependency');
    expect(html).not.toContain('merge conflict');
  });
});
