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
    ['On staging (awaiting production)', { staging: [{ ...validStagingItem({ issue: 6 }), url: BAD }] }, 'Staged ticket'],
    ['Approved, waiting for a slot', { approved: [{ ...validApprovedItem({ issue: 8 }), url: BAD }] }, 'Approved ticket'],
    ['Done', { completed: [{ ...validCompleted({ issue: 5, closed_at: ago(1) }), url: BAD }] }, 'Fix login redirect'],
    ['Running', { runs: [{ ...run(1, { state: 'running' }), url: BAD }] }, 'Title1'],
  ])('%s: a stored url failing isIssueUrl gets no href; title is plain text', (name, rec, title) => {
    // Bypasses validation on purpose: render must re-check (defence in depth).
    const html = render(hostRecord(rec), null);
    expect(html).not.toContain('javascript:');
    const s = section(html, name);
    expect(s).not.toContain('href=');
    expect(s).toContain(title);
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


// ---------------------------------------------------------------------------------------------
// Re-homed from render.test.js (#62 AC10 amendment): the pre-#62 #29 / #51 layout assertions,
// restated against the grouped layout. Expected values hand-written from the #29 / #51 / #62
// tickets. Run-shaped groups have 8 columns: Issue0 Ticket1 Host2 State3 Stage4 Marker5
// Last activity6 Restarts7. Done: Issue0 Ticket1 Closed2 Release3 Final marker4.
// NOW = 2026-09-21 (Monday), 12:00Z; CEST = UTC+2.
// ---------------------------------------------------------------------------------------------

/** Cells of every <tbody> row in a fragment: string[][] (inner HTML, trimmed). */
const bodyRows = (frag) => {
  const tb = (frag.match(/<tbody>([\s\S]*?)<\/tbody>/) || [null, ''])[1];
  return [...tb.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/g)].map((r) => [...r[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((c) => c[1].trim()));
};
const GOOD_URL = 'https://github.com/example-owner/project-a/issues/42';
const BAD_URLS = [
  'javascript:alert(1)',
  'https://evil.example/example-owner/project-a/issues/42',
  'http://github.com/example-owner/project-a/issues/42',
  'https://github.com/example-owner/project-a/issues/42?x=1',
  'https://github.com/example-owner/project-a/pull/42',
  'https://github.com/example-owner/project-a/issues/42" onclick="x',
  42,
];
const runningRow = (o = {}) => run(42, { state: 'running', title: undefined, url: undefined, ...o });

describe('re-homed #29 — privacy: repo alias and started_at never shown', () => {
  const html = render(hostRecord({ runs: [runningRow({ repo: 'zz-alias', started_at: '2026-01-02T03:04:05Z', title: 'T', url: GOOD_URL })] }), null);
  it('no Repo / Started header', () => {
    expect(html).not.toContain('<th>Repo</th>');
    expect(html).not.toContain('<th>Started</th>');
  });
  it('the alias and started_at (raw or CET-formatted) appear nowhere; the row has 8 cells', () => {
    expect(html).not.toContain('zz-alias');
    expect(html).not.toContain('2026-01-02');
    expect(html).not.toContain('Fri 2 Jan');
    expect(bodyRows(section(html, 'Running'))[0]).toHaveLength(8);
  });
});

describe('re-homed #29 — Ticket cell and href contract on a run row', () => {
  const ticketCell = (html) => bodyRows(section(html, 'Running'))[0][1];

  it('title + valid url: <a target=_blank rel="noopener noreferrer"> wrapping the title', () => {
    const html = render(hostRecord({ runs: [runningRow({ title: 'Fix login redirect', url: GOOD_URL })] }), null);
    const anchor = `<a href="${GOOD_URL}" target="_blank" rel="noopener noreferrer">Fix login redirect</a>`;
    expect(html).toContain(anchor);
    expect(ticketCell(html)).toBe(anchor);
  });

  it('XSS title: escaped inside the link and in the plain-text form; no <script', () => {
    const title = '<script>alert(1)</script> & "quotes"';
    const esc = '&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quotes&quot;';
    const linked = render(hostRecord({ runs: [runningRow({ title, url: GOOD_URL })] }), null);
    expect(linked).toContain(esc);
    expect(linked).not.toMatch(/<script/i);
    const plain = render(hostRecord({ runs: [runningRow({ title })] }), null);
    expect(ticketCell(plain)).toBe(esc);
    expect(plain).not.toMatch(/<script/i);
  });

  it.each(BAD_URLS.map((u) => [String(u), u]))('bad url %s: title as plain text, no href anywhere', (_l, url) => {
    const html = render(hostRecord({ runs: [runningRow({ title: 'Fix login redirect', url })] }), null);
    expect(ticketCell(html)).toBe('Fix login redirect');
    expect(html).not.toContain('href');
    expect(html).not.toContain('onclick=');
  });

  it('title with no url: plain text, no <a>, no href', () => {
    const html = render(hostRecord({ runs: [runningRow({ title: 'Fix login redirect' })] }), null);
    expect(ticketCell(html)).toBe('Fix login redirect');
    expect(html).not.toContain('<a ');
    expect(html).not.toContain('href');
  });

  it('url with no title: empty Ticket cell and no href, beside a titled control row', () => {
    const html = render(hostRecord({ runs: [run(41, { state: 'running', title: 'Control title', last_activity_at: ago(1) }), runningRow({ url: GOOD_URL, last_activity_at: ago(2) })] }), null);
    const rows = bodyRows(section(html, 'Running'));
    expect(rows[0][1]).toContain('Control title'); // control (newest first)
    expect(rows[1][1]).toBe('');
    expect(rows[1].join('')).not.toContain('href');
  });

  it('legacy run (no title, no url): empty Ticket cell, beside a titled control row', () => {
    const html = render(hostRecord({ runs: [run(41, { state: 'running', title: 'Control title', url: undefined, last_activity_at: ago(1) }), runningRow({ last_activity_at: ago(2) })] }), null);
    const rows = bodyRows(section(html, 'Running'));
    expect(rows[0][1]).toBe('Control title');
    expect(rows[1][1]).toBe('');
  });

  it('every href sits on an <a> (count equal); no src / <link> / @import / <script', () => {
    const html = render(hostRecord({ runs: [runningRow({ title: 'Fix login redirect', url: GOOD_URL })] }), null);
    const anchors = count(html, /<a href=/g);
    expect(anchors).toBe(1); // control: the link is there
    expect(count(html, /href\s*=/gi)).toBe(anchors);
    expect(html).not.toMatch(/\ssrc\s*=/i);
    expect(html).not.toMatch(/<link\b/i);
    expect(html).not.toMatch(/@import/i);
    expect(html).not.toMatch(/<script/i);
  });
});

describe('re-homed #29 — CET timestamps in cells', () => {
  it('Last activity and host Last seen read "Sat 19 Sep, 14:05"; no seconds, no ISO', () => {
    const html = render(hostRecord({ received_at: '2026-09-19T12:05:33Z', runs: [runningRow({ last_activity_at: '2026-09-19T12:05:33Z' })] }), null);
    expect(html).toMatch(/Last seen[^<]*Sat 19 Sep, 14:05/);
    expect(bodyRows(section(html, 'Running'))[0][6]).toBe('Sat 19 Sep, 14:05');
    expect(html).not.toContain(':33');
    expect(html).not.toContain('2026-09-19T');
  });

  it('missing, empty and unparseable timestamps render empty; "Invalid Date" never appears', () => {
    const runs = [runningRow({ last_activity_at: undefined }), run(43, { state: 'running', last_activity_at: '' }), run(44, { state: 'running', last_activity_at: 'garbage' })];
    const html = render(hostRecord({ runs, received_at: 'not-a-date' }), null);
    expect(html).not.toContain('Invalid Date');
    const rows = bodyRows(section(html, 'Running'));
    expect(rows).toHaveLength(3);
    for (const cells of rows) expect(cells[6]).toBe('');
    const lastSeen = html.match(/Last seen([^<]*)</);
    expect(lastSeen).not.toBeNull();
    expect(lastSeen[1].replace(/[:\s]/g, '')).toBe(''); // label kept, value empty
  });
});

describe('re-homed #29 — the "none" row spans the group\'s column count', () => {
  const html = render(hostRecord(), hostRecord());
  it.each([
    ['Running', 8], ['Queued', 8], ['Needs JP', 8], ['Parked', 8],
    ['Approved, waiting for a slot', 3], ['On staging (awaiting production)', 3],
    ['Done', 5],
  ])('%s: colspan="%i"', (name, n) => {
    const s = section(html, name);
    expect(s).toContain(`colspan="${n}"`);
    expect(s).toMatch(/none/);
  });
});

describe('re-homed #51 — Done group', () => {
  const DAY = 24;
  const done = (issue, hoursAgo, o = {}) => validCompleted({ issue, title: `Ticket ${issue}`, url: urlOf(issue), closed_at: ago(hoursAgo), ...o });
  const doneOf = (mac, vm = null) => section(render(mac, vm), 'Done');
  const has = (frag, n) => new RegExp(`#${n}(?!\\d)`).test(frag);
  const bare = (o) => { const c = done(o.issue, o.h); delete c.url; delete c.title; return c; };

  it('a row shows #issue, linked title, CET close time, and the final marker', () => {
    // 2026-09-17T18:00:00Z is a Thursday; CEST -> 20:00; 3.75 days before NOW: inside 7 days
    const s = doneOf(hostRecord({ completed: [done(42, 1, { closed_at: '2026-09-17T18:00:00Z', marker: 'DEPLOYED' })] }));
    const cells = bodyRows(s)[0];
    expect(cells[0]).toBe('#42');
    expect(cells[1]).toBe(`<a href="${urlOf(42)}" target="_blank" rel="noopener noreferrer">Ticket 42</a>`);
    expect(cells[2]).toBe('Thu 17 Sep, 20:00');
    expect(cells[4]).toBe('DEPLOYED');
  });

  it('a missing marker leaves the Final marker cell empty (no "undefined", no "other")', () => {
    const c = done(43, 1);
    delete c.marker;
    const s = doneOf(hostRecord({ completed: [c] }));
    expect(bodyRows(s)[0][4]).toBe('');
    expect(s).not.toContain('undefined');
    expect(s).not.toContain('other');
  });

  it('merges both hosts, newest closed_at first', () => {
    const s = doneOf(hostRecord({ completed: [done(1, 5), done(3, 1)] }), hostRecord({ completed: [done(2, 3), done(4, 30)] }));
    expect(bodyRows(s).map((r) => r[0])).toEqual(['#3', '#2', '#1', '#4']); // 1h, 3h, 5h, 30h ago
  });

  it('same ticket on both hosts renders once, keeping the later closed_at (dedupe on url)', () => {
    const s = doneOf(hostRecord({ completed: [done(42, 2)] }), hostRecord({ completed: [done(42, 1)] }));
    expect(bodyRows(s)).toHaveLength(1);
    expect(s).toContain('Mon 21 Sep, 13:00'); // 11:00Z -> 13:00 CEST (later)
    expect(s).not.toContain('Mon 21 Sep, 12:00');
  });

  it('with no url on either copy, dedupes on repo + issue', () => {
    const s = doneOf(hostRecord({ completed: [bare({ issue: 77, h: 2 }), bare({ issue: 78, h: 3 })] }), hostRecord({ completed: [bare({ issue: 77, h: 1 })] }));
    expect(count(s, /#77(?!\d)/g)).toBe(1);
    expect(has(s, 78)).toBe(true);
  });

  it('7-day boundary: 6d23h shown, 7d1h and 8d hidden', () => {
    const s = doneOf(hostRecord({ completed: [done(61, 6 * DAY + 23), done(62, 7 * DAY + 1), done(63, 8 * DAY)] }));
    expect(has(s, 61)).toBe(true);
    expect(has(s, 62)).toBe(false);
    expect(has(s, 63)).toBe(false);
  });

  it('drops an entry whose closed_at is unparseable, keeps the valid one', () => {
    const s = doneOf(hostRecord({ completed: [done(71, 1, { closed_at: 'yesterday' }), done(72, 1)] }));
    expect(has(s, 72)).toBe(true);
    expect(has(s, 71)).toBe(false);
  });

  it('shows all 20 when each host sends its 10 newest distinct tickets', () => {
    const a = Array.from({ length: 10 }, (_v, i) => done(101 + i, i + 1));
    const b = Array.from({ length: 10 }, (_v, i) => done(201 + i, i + 1.1));
    const html = render(hostRecord({ completed: a }), hostRecord({ completed: b }));
    expect(Number(h2('Done').exec(html)[1])).toBe(20);
    const s = section(html, 'Done');
    for (const c of [...a, ...b]) expect(has(s, c.issue)).toBe(true);
  });

  it('empty state: hosts present, nothing completed -> "Done (0)" and exactly one "none" row', () => {
    const html = render(hostRecord(), hostRecord());
    expect(Number(h2('Done').exec(html)[1])).toBe(0);
    expect(count(section(html, 'Done'), /<tr>\s*<td[^>]*>\s*none\s*<\/td>/g)).toBe(1);
  });

  it('everything older than 7 days -> "Done (0)", the old ticket not listed', () => {
    const s = doneOf(hostRecord({ completed: [done(81, 9 * DAY)] }));
    expect(s).toMatch(/none/);
    expect(has(s, 81)).toBe(false);
  });

  it('one host never seen, the other has completed -> Done still lists it', () => {
    expect(has(doneOf(hostRecord({ completed: [done(91, 1)] }), null), 91)).toBe(true);
  });

  it('a hostile marker is escaped, never emitted as markup', () => {
    const s = doneOf(hostRecord({ completed: [done(95, 1, { marker: '"><img src=x onerror=alert(1)>' })] }));
    expect(s).not.toContain('<img');
    expect(s).toContain('&lt;img');
  });

  it('a non-issue url on a done row: titles as plain text, no href, host not leaked', () => {
    const s = doneOf(hostRecord({ completed: [done(93, 1, { url: 'https://evil.example/x' }), done(94, 2, { url: 'javascript:alert(1)' })] }));
    expect(s).toContain('Ticket 93');
    expect(s).toContain('Ticket 94');
    expect(s).not.toContain('evil.example');
    expect(s).not.toContain('javascript:');
    expect(s).not.toContain('href=');
  });
});
