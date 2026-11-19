// Issue #781 — the status page lists the tickets a repo's daily Sentry launch cap is holding, with the reset time in CET.
// Expected values are hand-written from the ticket, never copied from src/.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { renderPage } from '../src/render.js';
import { validPayload, hostRecord } from './fixtures.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-11-19T10:00:00Z') / 1000;
const text = (s) => s.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
const cap = (o = {}) => ({ repo: 'org/app', count: 3, max: 3, resets_at: '2026-11-20T09:10:00Z', held: [7, 8], ...o });
const capsOf = (sentry_cap) => {
  const r = validateBeatPayload(validPayload({ sentry_cap }));
  expect(r.ok).toBe(true);
  return r.value.sentry_cap;
};
const sectionOf = (html) => /<section class="group sentry-cap">[\s\S]*?<\/section>/.exec(html)?.[0] ?? '';

describe('#781 validate.js — sentry_cap', () => {
  it('keeps a well-formed record', () => {
    expect(capsOf([cap()])).toEqual([cap()]);
  });

  it('is absent without the field, for a non-array, and for a record with nothing held', () => {
    expect(capsOf(undefined)).toBeUndefined();
    expect(capsOf('x')).toBeUndefined();
    expect(capsOf([cap({ held: [] })])).toBeUndefined();
  });

  it('drops a record with a bad repo or reset time, and bad held entries one by one', () => {
    expect(capsOf([cap({ repo: '<script>' })])).toBeUndefined();
    expect(capsOf([cap({ resets_at: 'tomorrow' })])).toBeUndefined();
    expect(capsOf([cap({ held: [7, 'x', -1, 1.5, 9] })])[0].held).toEqual([7, 9]);
  });

  it('rebuilds the record: an extra key never survives and counts are clamped', () => {
    const [r] = capsOf([{ ...cap({ count: 5000 }), token: 'secret' }]);
    expect(r).not.toHaveProperty('token');
    expect(r.count).toBe(99);
  });
});

describe('#781 render.js — Held by Sentry cap', () => {
  const rec = (o) => ({ ...hostRecord(), ...o });
  const render = (mac, vm = null) => renderPage({ mac, vm }, thresholds, NOW);

  it('tags each held ticket with the reset time in CET (Madrid): 09:10 UTC in November is 10:10', () => {
    const s = text(sectionOf(render(rec({ sentry_cap: [cap()] }))));
    expect(s).toContain('Held by Sentry cap (2)');
    expect(s).toContain('#7 org/app');
    expect(s).toContain('#8 org/app');
    expect(s.match(/Held by Sentry cap, resets 10:10 CET/g)).toHaveLength(2);
  });

  it('is not limited by the run limit: more held tickets than the 20-run cap are all listed', () => {
    const held = Array.from({ length: 30 }, (_, i) => 100 + i);
    const s = text(sectionOf(render(rec({ sentry_cap: [cap({ held })] }))));
    expect(s).toContain('Held by Sentry cap (30)');
    expect(s).toContain('#129 org/app');
  });

  it('shows the ticket title when the backlog row for it carries one', () => {
    const backlog = [{ repo: 'other', issue: 7, title: 'Crash on save', url: 'https://github.com/org/app/issues/7' }];
    const s = text(sectionOf(render(rec({ sentry_cap: [cap({ held: [7] })], backlog }))));
    expect(s).toContain('#7 org/app Crash on save');
  });

  it('merges two hosts of one repo: earliest reset, union of tickets', () => {
    const mac = rec({ sentry_cap: [cap({ held: [7], resets_at: '2026-11-20T09:10:00Z' })] });
    const vm = rec({ sentry_cap: [cap({ held: [8], resets_at: '2026-11-19T20:00:00Z' })] });
    const s = text(sectionOf(render(mac, vm)));
    expect(s).toContain('Held by Sentry cap (2)');
    expect(s.match(/resets 21:00 CET/g)).toHaveLength(2);
  });

  it('renders no section when nothing is held', () => {
    expect(sectionOf(render(rec({})))).toBe('');
  });
});
