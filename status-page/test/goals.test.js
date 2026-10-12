// Issue #197 AC2 + AC3 — goals on the status page: validate.js sanitising and render.js "Goals"
// section. Expected values are hand-written from the ticket, never copied from src/.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { renderPage } from '../src/render.js';
import { validPayload, validRun, hostRecord } from './fixtures.js';

const goal = (o = {}) => ({
  id: 'goal-a',
  spec: 'Ship the quoting tool v2',
  host: 'mac',
  state: 'running',
  scope_total: 7,
  scope_delivered: 3,
  last_cycle_at: '2026-09-21T10:00:00Z',
  ...o,
});
const goalsOf = (goals) => {
  const r = validateBeatPayload(validPayload({ goals }));
  expect(r.ok).toBe(true);
  return r.value;
};
const idsOf = (value) => (value.goals ?? []).map((g) => g.id);

describe('AC2 — validate.js goals', () => {
  it('keeps A, B, C and drops E (raw <script> spec) — the reporter fixture entries', () => {
    const v = goalsOf([
      goal({ id: 'A', state: 'running' }),
      goal({ id: 'B', state: 'held' }),
      goal({ id: 'C', state: 'waiting_jp' }),
      goal({ id: 'E', spec: '<script>alert(1)</script>', state: 'between_cycles' }),
    ]);
    expect(idsOf(v)).toEqual(['A', 'B', 'C']);
    expect(JSON.stringify(v)).not.toContain('<script>');
  });

  it('keeps all fields of a valid entry and drops unknown keys', () => {
    const v = goalsOf([{ ...goal(), extra: 'sneaky' }]);
    expect(v.goals).toEqual([goal()]);
  });

  it.each([
    ['state "exploded"', { state: 'exploded' }],
    ['spec "<img src=x>"', { spec: '<img src=x>' }],
    ['host "other"', { host: 'other' }],
    ['id containing &', { id: 'a&b' }],
    ['spec containing a double quote', { spec: 'say "hi"' }],
    ['spec containing a backtick', { spec: 'run `rm`' }],
    ['id containing >', { id: 'a>b' }],
  ])('drops only the entry with %s', (_label, bad) => {
    const v = goalsOf([goal({ id: 'good' }), goal({ id: 'bad', ...bad })]);
    expect(idsOf(v)).toEqual(['good']);
  });

  it('drops non-object entries without rejecting the payload', () => {
    const v = goalsOf([null, 'x', 7, goal({ id: 'good' })]);
    expect(idsOf(v)).toEqual(['good']);
  });

  it.each(['nope', 42, { id: 'x' }, null])('goals: %j (non-array) produces no goals key', (junk) => {
    const r = validateBeatPayload(validPayload({ goals: junk }));
    expect(r.ok).toBe(true);
    expect(r.value).not.toHaveProperty('goals');
  });

  it('a payload without goals validates to exactly the pre-change value', () => {
    const r = validateBeatPayload(validPayload());
    expect(r.ok).toBe(true);
    expect(r.value).toEqual({
      v: 1,
      sent_at: '2026-09-17T18:05:30Z',
      supervisor_last_tick: '2026-09-17T18:04:00Z',
      capacity: { running: 1, max: 3, queued: 0 },
      runs: [validRun()],
      completed: [],
      staging: [],
      approved: [],
    });
  });

  it('51 valid entries -> exactly the first 50 kept', () => {
    const many = Array.from({ length: 51 }, (_, i) => goal({ id: `g${String(i).padStart(2, '0')}` }));
    const ids = idsOf(goalsOf(many));
    expect(ids).toHaveLength(50);
    expect(ids).toContain('g49');
    expect(ids).not.toContain('g50');
  });

  it('cap applies before filtering: 50 bad entries then 1 good -> the good one (51st) is gone', () => {
    const bad = Array.from({ length: 50 }, (_, i) => goal({ id: `bad${i}`, state: 'exploded' }));
    const v = goalsOf([...bad, goal({ id: 'late-good' })]);
    expect(idsOf(v)).toEqual([]);
  });

  it('exactly 50 entries with one bad -> 49 kept (boundary)', () => {
    const fifty = Array.from({ length: 50 }, (_, i) => goal({ id: `g${i}`, state: i === 0 ? 'exploded' : 'held' }));
    expect(idsOf(goalsOf(fifty))).toHaveLength(49);
  });

  it('collapses whitespace in spec and caps it at 140 code points', () => {
    const v = goalsOf([goal({ id: 'w', spec: '  ship \t the\n  thing ' }), goal({ id: 'long', spec: 'x'.repeat(200) })]);
    expect(v.goals.find((g) => g.id === 'w').spec).toBe('ship the thing');
    expect(v.goals.find((g) => g.id === 'long').spec).toBe('x'.repeat(140));
  });

  it.each([
    [0, 0],
    [9999, 9999],
    [10000, 9999],
    [-5, 0],
  ])('scope_total %j is clamped to %j', (input, expected) => {
    const v = goalsOf([goal({ scope_total: input, scope_delivered: input })]);
    expect(v.goals[0].scope_total).toBe(expected);
    expect(v.goals[0].scope_delivered).toBe(expected);
  });

  it('omits non-numeric counts and a non-ISO last_cycle_at but keeps the entry', () => {
    const v = goalsOf([goal({ scope_total: 'many', scope_delivered: null, last_cycle_at: 'yesterday' })]);
    expect(v.goals).toHaveLength(1);
    expect(v.goals[0]).not.toHaveProperty('scope_total');
    expect(v.goals[0]).not.toHaveProperty('scope_delivered');
    expect(v.goals[0]).not.toHaveProperty('last_cycle_at');
  });

  it('accepts an entry with no optional fields at all', () => {
    const v = goalsOf([{ id: 'min', spec: 'minimal', host: 'vm', state: 'held' }]);
    expect(v.goals).toEqual([{ id: 'min', spec: 'minimal', host: 'vm', state: 'held' }]);
  });
});

// ---------------------------------------------------------------- render ----

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;
const withGoals = (goals, o = {}) => {
  const rec = hostRecord(o);
  if (goals !== undefined) rec.goals = goals;
  return rec;
};
const render = (mac, vm) => renderPage({ mac, vm }, thresholds, NOW);

/** HTML of the <section class="group"> whose <h2> is exactly "Goals", or null. */
function goalsSection(html) {
  const m = /<section class="group">\s*<h2>Goals<\/h2>[\s\S]*?<\/section>/.exec(html);
  return m ? m[0] : null;
}
/** Body rows as arrays of cell inner-HTML (rows containing <td>). */
function rowsOf(section) {
  return [...section.matchAll(/<tr>([\s\S]*?)<\/tr>/g)]
    .filter((m) => m[1].includes('<td'))
    .map((m) => [...m[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((c) => c[1].trim()));
}
const text = (s) => s.replace(/<[^>]+>/g, '').trim();

describe('AC3 — render.js Goals section', () => {
  const mac = withGoals([
    goal({ id: 'A', spec: 'Goal A spec', host: 'mac', state: 'running', scope_total: 7, scope_delivered: 3 }),
    goal({ id: 'B', spec: 'Goal B spec', host: 'mac', state: 'held', scope_total: 4, scope_delivered: 4 }),
    goal({ id: 'C', spec: 'Goal C spec', host: 'vm', state: 'waiting_jp', scope_total: undefined, scope_delivered: undefined, last_cycle_at: undefined }),
  ]);
  const html = render(mac, hostRecord());

  it('has a Goals section with exactly three rows', () => {
    const s = goalsSection(html);
    expect(s).not.toBeNull();
    expect(rowsOf(s)).toHaveLength(3);
  });

  it('has the columns Goal, Host, State, Delivered, Last cycle', () => {
    const s = goalsSection(html);
    const ths = [...s.matchAll(/<th[^>]*>([\s\S]*?)<\/th>/g)].map((m) => m[1].trim());
    expect(ths).toEqual(['Goal', 'Host', 'State', 'Delivered', 'Last cycle']);
  });

  it('orders waiting_jp, held, running (then id) and renders each cell', () => {
    const rows = rowsOf(goalsSection(html)).map((cells) => cells.map(text));
    // 2026-09-21T10:00:00Z = 12:00 CEST (UTC+2); 21 Sep 2026 is a Monday.
    expect(rows).toEqual([
      ['Goal C spec', 'VM', 'waiting on JP', '–', '–'],
      ['Goal B spec', 'Mac', 'held', '4/4', 'Mon 21 Sep, 12:00'],
      ['Goal A spec', 'Mac', 'running', '3/7', 'Mon 21 Sep, 12:00'],
    ]);
  });

  it('state badge uses the existing .badge class', () => {
    const s = goalsSection(html);
    expect(s).toMatch(/<[a-z]+ class="badge[^"]*"[^>]*>\s*running\s*</);
  });

  it('is placed after the host sections and above the per-ticket groups', () => {
    const goalsAt = html.search(/<h2>Goals<\/h2>/);
    const lastHostAt = html.lastIndexOf('<section class="host">');
    const firstGroupAt = html.search(/<h2>Running \(\d+\)<\/h2>/);
    expect(goalsAt).toBeGreaterThan(lastHostAt);
    expect(firstGroupAt).toBeGreaterThan(goalsAt);
  });

  it('orders all four states: waiting_jp, held, running, between_cycles, then id', () => {
    const m = withGoals([
      goal({ id: 'z-between', spec: 'S1', state: 'between_cycles' }),
      goal({ id: 'b-run', spec: 'S2', state: 'running' }),
      goal({ id: 'a-run', spec: 'S3', state: 'running' }),
      goal({ id: 'c-held', spec: 'S4', state: 'held' }),
      goal({ id: 'd-wait', spec: 'S5', state: 'waiting_jp' }),
    ]);
    const rows = rowsOf(goalsSection(render(m, null))).map((c) => [text(c[0]), text(c[2])]);
    expect(rows).toEqual([
      ['S5', 'waiting on JP'],
      ['S4', 'held'],
      ['S3', 'running'],
      ['S2', 'running'],
      ['S1', 'between cycles'],
    ]);
  });

  it('never emits a raw <script> and escapes a hostile spec', () => {
    const m = withGoals([goal({ id: 'E', spec: '<script>alert(1)</script>' })]);
    const out = render(m, null);
    expect(out).not.toContain('<script>');
    expect(goalsSection(out)).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
  });

  it('the same goal reported by both hosts renders once, keeping the goal\'s own host entry', () => {
    const m = withGoals([goal({ id: 'dup', spec: 'Dup goal', host: 'mac', state: 'running' })]);
    const v = withGoals([goal({ id: 'dup', spec: 'Dup goal', host: 'mac', state: 'held' })], {
      received_at: '2026-09-21T11:59:00Z',
    });
    const rows = rowsOf(goalsSection(render(m, v))).map((c) => c.map(text));
    expect(rows).toHaveLength(1);
    expect(rows[0][2]).toBe('running'); // mac reported it and goal.host === 'mac'
  });

  it('prefers the vm\'s entry when the goal\'s own host is vm, even if the mac report is newer', () => {
    const m = withGoals([goal({ id: 'dup', spec: 'Dup goal', host: 'vm', state: 'running' })], {
      received_at: '2026-09-21T12:00:00Z',
    });
    const v = withGoals([goal({ id: 'dup', spec: 'Dup goal', host: 'vm', state: 'held' })], {
      received_at: '2026-09-21T11:00:00Z',
    });
    const rows = rowsOf(goalsSection(render(m, v))).map((c) => c.map(text));
    expect(rows).toHaveLength(1);
    expect(rows[0][2]).toBe('held');
  });
});

describe('AC3 — no goals anywhere: output unchanged', () => {
  const base = () => hostRecord({ runs: [validRun()] });

  it('has no Goals section when no host reports goals', () => {
    expect(render(base(), base())).not.toMatch(/Goals/);
  });

  it('an empty or non-array goals value renders byte-identically to no goals key', () => {
    const plain = render(base(), base());
    expect(render(withGoals([], { runs: [validRun()] }), base())).toBe(plain);
    expect(render(withGoals('nope', { runs: [validRun()] }), base())).toBe(plain);
  });

  it('a first-deploy page (both hosts null) has no Goals section', () => {
    expect(renderPage({ mac: null, vm: null }, thresholds, NOW)).not.toMatch(/Goals/);
  });
});
