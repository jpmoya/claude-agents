// JP (2026-11-18): the status page says which goal holds the one goal slot (GOAL_SERIAL=1) and on which host, which queued goals wait for it
// and which (feedback) goals run alongside. The reporter sends `slot`: holds | waits | alongside. Expected values are hand-written.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { renderPage } from '../src/render.js';
import { validPayload, hostRecord } from './fixtures.js';

const goalsOf = (goals) => {
  const r = validateBeatPayload(validPayload({ goals }));
  expect(r.ok).toBe(true);
  return r.value.goals ?? [];
};
const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;
const rec = (goals, o = {}) => ({ ...hostRecord(o), goals });
const render = (mac, vm) => renderPage({ mac, vm }, thresholds, NOW);
const text = (s) => s.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
function rowOf(html, title) {
  const m = /<section class="group">\s*<h2>Goals<\/h2>[\s\S]*?<\/section>/.exec(html);
  const rows = [...(m ? m[0] : '').matchAll(/<tr>([\s\S]*?)<\/tr>/g)].filter((r) => r[1].includes('<td'));
  const row = rows.find((r) => text(r[1]).includes(title));
  return row ? row[1] : '';
}
const holder = (o = {}) => ({ id: 'h', title: 'Holder', repos: ['org/repo-a'], host: 'vm', state: 'running', slot: 'holds', priority: 1, ...o });
const waiting = (o = {}) => ({ id: 'q', title: 'Waiter', repos: ['org/repo-a'], host: '', state: 'queued', queue_pos: 1, slot: 'waits', priority: 2, ...o });
const fb = (o = {}) => ({ id: 'f', title: 'Feedback', repos: ['org/repo-a'], host: 'mac', state: 'between_cycles', slot: 'alongside', priority: 3, ...o });

describe('validate.js — slot', () => {
  it('keeps holds, waits and alongside on a live goal', () => {
    expect(goalsOf([holder()])[0].slot).toBe('holds');
    expect(goalsOf([waiting()])[0].slot).toBe('waits');
    expect(goalsOf([fb()])[0].slot).toBe('alongside');
  });
  it('drops anything else, and any slot on a closed goal', () => {
    expect(goalsOf([holder({ slot: 'HOLDS' })])[0]).not.toHaveProperty('slot');
    expect(goalsOf([holder({ slot: '<script>' })])[0]).not.toHaveProperty('slot');
    expect(goalsOf([holder({ slot: 7 })])[0]).not.toHaveProperty('slot');
    expect(goalsOf([{ id: 'd', title: 'Done', host: 'mac', state: 'delivered', closed_at: '2026-09-20T10:00:00Z', slot: 'holds' }])[0]).not.toHaveProperty('slot');
  });
});

describe('render.js — slot badges', () => {
  const html = render(rec([holder(), waiting(), fb()], { received_at: '2026-09-21T11:59:00Z' }), null);
  it('marks the goal that holds the slot, with the host it runs on', () => {
    const t = text(rowOf(html, 'Holder'));
    expect(t).toContain('HOLDS GOAL SLOT');
    expect(t).toContain('VM');
    expect(rowOf(html, 'Holder')).toContain('slot-holds');
  });
  it('shows the host of the holder when it runs on the Mac', () => {
    const h = render(rec([holder({ host: 'mac' })]), null);
    expect(text(rowOf(h, 'Holder'))).toContain('HOLDS GOAL SLOT · Mac');
  });
  it('marks a queued goal as waiting for the slot, muted', () => {
    expect(text(rowOf(html, 'Waiter'))).toContain('waiting for slot');
    expect(rowOf(html, 'Waiter')).toContain('slot-waits');
    expect(text(rowOf(html, 'Waiter'))).not.toContain('HOLDS GOAL SLOT');
  });
  it('marks a slot-exempt goal as running alongside', () => {
    expect(text(rowOf(html, 'Feedback'))).toContain('runs alongside');
    expect(text(rowOf(html, 'Feedback'))).not.toContain('HOLDS GOAL SLOT');
  });
  it('shows no slot badge when the reporter sent none', () => {
    const plain = render(rec([holder({ slot: undefined })]), null);
    const t = text(rowOf(plain, 'Holder'));
    expect(t).not.toContain('HOLDS GOAL SLOT');
    expect(t).not.toContain('waiting for slot');
    expect(t).not.toContain('runs alongside');
  });
});

describe('render.js — icons, tooltips and legend', () => {
  const html = render(rec([holder(), waiting(), fb()], { received_at: '2026-09-21T11:59:00Z' }), null);
  it('draws an inline SVG icon and a tooltip on each badge', () => {
    for (const [title, cls] of [['Holder', 'slot-holds'], ['Waiter', 'slot-waits'], ['Feedback', 'slot-alongside']]) {
      const row = rowOf(html, title);
      expect(row).toMatch(new RegExp(`<span class="badge ${cls}" title="[^"]+"><svg class="slot-icon"`));
    }
    expect(rowOf(html, 'Holder')).toContain('running on the VM');
    expect(rowOf(html, 'Waiter')).toContain('Waiting for the goal slot');
    expect(rowOf(html, 'Feedback')).toContain('never holds or waits for the goal slot');
  });
  it('uses three different icons (padlock, hourglass, parallel arrows)', () => {
    const icon = (title) => /<svg class="slot-icon"[\s\S]*?<\/svg>/.exec(rowOf(html, title))[0];
    expect(new Set([icon('Holder'), icon('Waiter'), icon('Feedback')]).size).toBe(3);
    expect(icon('Holder')).toContain('<rect');
  });
  it('shows a legend of the three icons at the top of the Goals table', () => {
    const m = /<h2>Goals<\/h2>\s*(<p class="slot-legend"[\s\S]*?<\/p>)\s*<div class="table-scroll">/.exec(html);
    expect(m).not.toBeNull();
    const legend = text(m[1]);
    expect(legend).toContain('HOLDS GOAL SLOT');
    expect(legend).toContain('waiting for slot');
    expect(legend).toContain('runs alongside');
    expect((m[1].match(/<svg class="slot-icon"/g) || []).length).toBe(3);
  });
  it('has no legend when no goal carries a slot state', () => {
    expect(render(rec([holder({ slot: undefined })]), null)).not.toContain('slot-legend"');
  });
  it('keeps contrast in both colour schemes: badge colours come from the theme variables', () => {
    expect(html).toMatch(/\.badge\.slot-holds \{[^}]*var\(--green\)/);
    expect(html).toMatch(/\.badge\.slot-waits \{[^}]*var\(--muted\)/);
    expect(html).toMatch(/\.badge\.slot-alongside \{[^}]*var\(--text\)/);
  });
});

describe('render.js — priority and queue order', () => {
  it('shows a priority number only when one is set, and a slot-exempt goal never has one, listed after the queue', () => {
    const html = render(rec([fb({ priority: 1 }), holder({ priority: undefined, order: 40 }), waiting({ priority: undefined, order: 30 }), holder({ id: 'p', title: 'Prioritised', priority: 5, order: 99, slot: undefined })]), null);
    const rows = [...html.matchAll(/<tr><td[^>]*>([^<]*)<\/td><td[^>]*>([\s\S]*?)<\/td>/g)].map((m) => [m[1], text(m[2]).split(' ')[0]]);
    expect(rows).toEqual([['5', 'Prioritised'], ['–', 'Waiter'], ['–', 'Holder'], ['–', 'Feedback']]);
  });
});

