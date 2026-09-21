// #62 AC5, 6, 7, 8, 9 — the regrouped page. Expected strings hand-written from the ticket.

import { describe, it, expect } from 'vitest';
import { renderPage } from '../src/render.js';
import { validRun, validCompleted, validStagingItem, validApprovedItem, hostRecord } from './fixtures.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;
const ago = (hours) => new Date((NOW - hours * 3600) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const urlOf = (n) => `https://github.com/example-owner/project-a/issues/${n}`;
const run = (issue, o = {}) => validRun({ issue, url: urlOf(issue), title: `Title${issue}`, last_activity_at: ago(1), ...o });
const render = (mac, vm) => renderPage({ mac, vm }, thresholds, NOW);

const HEADINGS = ['Running', 'Queued', 'Approved, waiting for a slot', 'Needs JP', 'On staging (awaiting production)', 'Parked', 'Done'];
const h2 = (name) => new RegExp(`<h2[^>]*>\\s*${name.replace(/[()]/g, '\\$&')} \\((\\d+)\\)\\s*</h2>`);

/** HTML from the named group's <h2> up to the next <h2> (or end). */
function section(html, name) {
  const m = h2(name).exec(html);
  expect(m, `heading "${name}" present`).not.toBeNull();
  const rest = html.slice(m.index + m[0].length);
  const next = rest.search(/<h2/);
  return next === -1 ? rest : rest.slice(0, next);
}
const ths = (frag) => [...frag.matchAll(/<th[^>]*>([\s\S]*?)<\/th>/g)].map((m) => m[1].trim());
const count = (html, re) => (html.match(re) || []).length;

describe('AC6 — seven headings, in order, with counts, no per-host run table', () => {
  const mac = hostRecord({
    runs: [run(1, { state: 'running' }), run(2, { state: 'running' }), run(3, { state: 'queued' }), run(4, { state: 'held', marker: 'BLOCKED' })],
    completed: [validCompleted({ issue: 5, url: urlOf(5), closed_at: ago(2) })],
  });
  const vm = hostRecord({ runs: [], staging: [validStagingItem({ issue: 6, url: urlOf(6) })] });
  const html = render(mac, vm);

  it('has the seven <h2> headings in the stated order', () => {
    const positions = HEADINGS.map((n) => html.search(h2(n)));
    for (const p of positions) expect(p).toBeGreaterThan(-1);
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);
  });

  it('each heading carries the row count', () => {
    expect(Number(h2('Running').exec(html)[1])).toBe(2);
    expect(Number(h2('Queued').exec(html)[1])).toBe(1);
    expect(Number(h2('Approved, waiting for a slot').exec(html)[1])).toBe(0);
    expect(Number(h2('Needs JP').exec(html)[1])).toBe(1);
    expect(Number(h2('On staging (awaiting production)').exec(html)[1])).toBe(1);
    expect(Number(h2('Parked').exec(html)[1])).toBe(0);
    expect(Number(h2('Done').exec(html)[1])).toBe(1);
  });

  it('renders exactly seven <table> elements when both hosts have data', () => {
    expect(count(html, /<table/g)).toBe(7);
  });

  it('an empty group renders "(0)" and a single "none" row', () => {
    const s = section(html, 'Parked');
    expect(count(s, /<tr>\s*<td[^>]*>\s*none\s*<\/td>/g)).toBe(1);
  });

  it('host health blocks still render name, badge, last seen and capacity for both hosts', () => {
    expect(html).toContain('Mac');
    expect(html).toContain('VM');
    expect(count(html, /class="badge live"/g)).toBe(2);
    expect(count(html, /Last seen:/g)).toBe(2);
    expect(html).toContain('Capacity: running 1 / max 3 (queued 0)');
  });

  it('one host never seen: its block reads "no data yet", still seven tables', () => {
    const h = render(mac, null);
    expect(h).toContain('no data yet');
    expect(count(h, /<table/g)).toBe(7);
  });

  it('neither host seen: "no data from either host yet" is still shown', () => {
    expect(render(null, null)).toContain('no data from either host yet');
  });

  it('no <script> and no third-party resource', () => {
    expect(html).not.toMatch(/<script/i);
    expect(html).not.toMatch(/(src|href)="https?:\/\/(?!github\.com)/i);
  });
});

describe('AC6 — columns', () => {
  const mac = hostRecord({
    runs: [run(1, { state: 'running' }), run(3, { state: 'queued' }), run(4, { state: 'held', marker: 'BLOCKED' }), run(9, { state: 'held', marker: 'PASS' })],
    completed: [validCompleted({ issue: 5, url: urlOf(5), closed_at: ago(2), release: 'v1.3.0', marker: 'DEPLOYED' })],
    approved: [validApprovedItem({ issue: 8, url: urlOf(8) })],
    staging: [validStagingItem({ issue: 6, url: urlOf(6) })],
  });
  const html = render(mac, null);
  const runCols = ['Issue', 'Ticket', 'Host', 'State', 'Stage', 'Marker', 'Last activity', 'Restarts'];

  it.each(['Running', 'Queued', 'Needs JP', 'Parked'])('%s columns', (name) => {
    expect(ths(section(html, name))).toEqual(runCols);
  });
  it.each(['Approved, waiting for a slot', 'On staging (awaiting production)'])('%s columns', (name) => {
    expect(ths(section(html, name))).toEqual(['Issue', 'Ticket', 'Updated']);
  });
  it('Done columns, and the release shows when present', () => {
    const s = section(html, 'Done');
    expect(ths(s)).toEqual(['Issue', 'Ticket', 'Closed', 'Release', 'Final marker']);
    expect(s).toContain('v1.3.0');
  });
});

describe('AC5 — a ticket on both hosts renders exactly once, with the newer row\'s host', () => {
  const build = (macAgo, vmAgo) =>
    render(
      hostRecord({ runs: [run(739, { title: 'Dup ticket', state: 'held', marker: 'BLOCKED', last_activity_at: ago(macAgo) })] }),
      hostRecord({ runs: [run(739, { title: 'Dup ticket', state: 'restarting', last_activity_at: ago(vmAgo) })] })
    );

  it('VM row newer: one "#739" in the page, in Running, host VM', () => {
    const html = build(9, 3);
    expect(count(html, /#739(?!\d)/g)).toBe(1);
    const s = section(html, 'Running');
    expect(s).toMatch(/#739(?!\d)/);
    expect(s).toContain('VM');
    expect(s).toContain('restarting');
    expect(section(html, 'Needs JP')).not.toMatch(/#739(?!\d)/);
  });

  it('Mac row newer: one "#739", in Needs JP, host Mac', () => {
    const html = build(3, 9);
    expect(count(html, /#739(?!\d)/g)).toBe(1);
    const s = section(html, 'Needs JP');
    expect(s).toMatch(/#739(?!\d)/);
    expect(s).toContain('Mac');
    expect(section(html, 'Running')).not.toMatch(/#739(?!\d)/);
  });
});

describe('AC7 — caps and ageing in the HTML', () => {
  it('25 running rows across hosts -> "Running (25)" and 25 rows', () => {
    const mac = hostRecord({ runs: Array.from({ length: 13 }, (_v, i) => run(i + 1, { state: 'running' })) });
    const vm = hostRecord({ runs: Array.from({ length: 12 }, (_v, i) => run(i + 101, { state: 'running' })) });
    const html = render(mac, vm);
    expect(Number(h2('Running').exec(html)[1])).toBe(25);
    expect(count(section(html, 'Running'), /<tbody>[\s\S]*?<\/tbody>/g)).toBe(1);
    expect(count(section(html, 'Running'), /<td>#\d+<\/td>/g)).toBe(25);
  });

  it('12 parked rows -> "Parked (10)"; a 17-day-old parked row is hidden', () => {
    const runs = Array.from({ length: 12 }, (_v, i) => run(i + 1, { state: 'held', marker: 'PASS', last_activity_at: ago(i + 1) }));
    const html = render(hostRecord({ runs }), null);
    expect(Number(h2('Parked').exec(html)[1])).toBe(10);
    const old = render(hostRecord({ runs: [run(50, { state: 'held', marker: 'PASS', last_activity_at: ago(24 * 17) })] }), null);
    expect(Number(h2('Parked').exec(old)[1])).toBe(0);
    expect(old).not.toMatch(/#50(?!\d)/);
  });

  it('a 30-day-old AWAITING GO is still listed under Needs JP', () => {
    const html = render(hostRecord({ runs: [run(60, { state: 'held', marker: 'AWAITING GO', last_activity_at: ago(24 * 30) })] }), null);
    expect(Number(h2('Needs JP').exec(html)[1])).toBe(1);
    expect(section(html, 'Needs JP')).toMatch(/#60(?!\d)/);
  });

  it('Done keeps 7-day retention: an 8-day-old completed ticket is not shown', () => {
    const html = render(hostRecord({ completed: [validCompleted({ issue: 70, url: urlOf(70), closed_at: ago(24 * 8) })] }), null);
    expect(Number(h2('Done').exec(html)[1])).toBe(0);
  });
});

describe('AC8 — escaping and href re-check on every row kind', () => {
  const evil = '<img src=x onerror=1>';
  const escapedEvil = '&lt;img src=x onerror=1&gt;';

  it('a staging title is escaped, never raw', () => {
    const html = render(hostRecord({ staging: [validStagingItem({ issue: 6, title: evil, url: urlOf(6) })] }), null);
    expect(html).not.toContain(evil);
    expect(section(html, 'On staging (awaiting production)')).toContain(escapedEvil);
  });

  it('an approved title and a done title are escaped', () => {
    const html = render(
      hostRecord({ approved: [validApprovedItem({ issue: 8, title: evil, url: urlOf(8) })], completed: [validCompleted({ issue: 5, title: evil, url: urlOf(5), closed_at: ago(1) })] }),
      null
    );
    expect(html).not.toContain(evil);
    expect(section(html, 'Approved, waiting for a slot')).toContain(escapedEvil);
    expect(section(html, 'Done')).toContain(escapedEvil);
  });

  it('a run title is escaped', () => {
    const html = render(hostRecord({ runs: [run(1, { state: 'running', title: evil })] }), null);
    expect(html).not.toContain(evil);
  });

  const BAD = 'javascript:alert(1)';
  it.each([
    ['On staging (awaiting production)', { staging: [{ ...validStagingItem({ issue: 6 }), url: BAD }] }],
    ['Approved, waiting for a slot', { approved: [{ ...validApprovedItem({ issue: 8 }), url: BAD }] }],
    ['Done', { completed: [{ ...validCompleted({ issue: 5, closed_at: ago(1) }), url: BAD }] }],
    ['Running', { runs: [{ ...run(1, { state: 'running' }), url: BAD }] }],
  ])('%s: a stored url failing isIssueUrl gets no href; title is plain text', (name, rec) => {
    // Bypasses validation on purpose: render must re-check (defence in depth).
    const html = render(hostRecord(rec), null);
    expect(html).not.toContain('javascript:');
    const s = section(html, name);
    expect(s).not.toContain('href=');
    expect(s).toMatch(/Title1|Staged ticket|Approved ticket|Fix login redirect/);
  });

  it('a valid issue url gets an href in a staging row (control)', () => {
    const html = render(hostRecord({ staging: [validStagingItem({ issue: 6, url: urlOf(6) })] }), null);
    expect(section(html, 'On staging (awaiting production)')).toContain(`href="${urlOf(6)}"`);
  });
});

describe('AC9 — backward compatibility with today\'s record shape', () => {
  const old = (runs) => hostRecord({ runs }); // no staging / approved / completed / release keys

  it('renders without throwing; approved and staging read (0)', () => {
    const html = render(old([run(1, { state: 'running' })]), old([run(2, { state: 'held', marker: 'PASS' })]));
    expect(Number(h2('Approved, waiting for a slot').exec(html)[1])).toBe(0);
    expect(Number(h2('On staging (awaiting production)').exec(html)[1])).toBe(0);
    expect(Number(h2('Running').exec(html)[1])).toBe(1);
    expect(Number(h2('Parked').exec(html)[1])).toBe(1);
  });

  it('a done row without release renders (empty Release cell, no "undefined")', () => {
    const html = render(hostRecord({ completed: [validCompleted({ issue: 5, url: urlOf(5), closed_at: ago(1) })] }), null);
    expect(Number(h2('Done').exec(html)[1])).toBe(1);
    expect(html).not.toContain('undefined');
  });
});
