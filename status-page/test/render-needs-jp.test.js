// #139 render — Needs JP gets a `Needs` column right after Ticket; labels are HTML-escaped; every
// other group keeps its columns; a row without a label renders an empty cell.

import { describe, it, expect } from 'vitest';
import { renderPage } from '../src/render.js';
import { validRun, validCompleted, validStagingItem, validApprovedItem, hostRecord } from './fixtures.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;
const ago = (hours) => new Date((NOW - hours * 3600) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const urlOf = (n) => `https://github.com/example-owner/project-a/issues/${n}`;
const run = (issue, o = {}) => validRun({ issue, url: urlOf(issue), title: `Title${issue}`, last_activity_at: ago(1), ...o });
const render = (mac) => renderPage({ mac, vm: null }, thresholds, NOW);

const h2 = (name) => new RegExp(`<h2[^>]*>\\s*${name.replace(/[()]/g, '\\$&')} \\((\\d+)\\)\\s*</h2>`);
function section(html, name) {
  const m = h2(name).exec(html);
  expect(m, `heading "${name}" present`).not.toBeNull();
  const rest = html.slice(m.index + m[0].length);
  const next = rest.search(/<h2/);
  return next === -1 ? rest : rest.slice(0, next);
}
const ths = (frag) => [...frag.matchAll(/<th[^>]*>([\s\S]*?)<\/th>/g)].map((m) => m[1].trim());
// #140: group header rows (a single colspan cell) are not data cells.
const tds = (frag) => [...frag.matchAll(/<td(?![^>]*colspan)[^>]*>([\s\S]*?)<\/td>/g)].map((m) => m[1].trim());

const base = ['Issue', 'Ticket', 'Host', 'State', 'Stage', 'Marker', 'Last activity', 'Restarts'];
const needsCols = ['Issue', 'Ticket', 'Needs', 'Host', 'State', 'Stage', 'Marker', 'Last activity', 'Restarts'];

const mac = hostRecord({
  runs: [
    run(1, { state: 'running' }),
    run(3, { state: 'queued' }),
    run(4, { state: 'held', marker: 'AWAITING GO', needs: 'Say go' }),
    run(9, { state: 'held', marker: 'PASS' }),
  ],
  completed: [validCompleted({ issue: 5, url: urlOf(5), closed_at: ago(2), release: 'v1.3.0', marker: 'DEPLOYED' })],
  approved: [validApprovedItem({ issue: 8, url: urlOf(8) })],
  staging: [validStagingItem({ issue: 6, url: urlOf(6) })],
});

describe('#139 Needs column', () => {
  const html = render(mac);

  it('Needs JP header: Issue, Ticket, Needs, then the rest', () => {
    expect(ths(section(html, 'Needs JP'))).toEqual(needsCols);
  });

  it('the Needs cell (3rd) shows the label', () => {
    const cells = tds(section(html, 'Needs JP'));
    expect(cells[0]).toBe('#4');
    expect(cells[2]).toBe('Say go');
    expect(cells).toHaveLength(needsCols.length);
  });

  it.each(['Running', 'Queued', 'Parked'])('%s keeps the unchanged column set', (name) => {
    expect(ths(section(html, name))).toEqual(base);
  });

  it('Approved / staging / Done columns unchanged', () => {
    expect(ths(section(html, 'Approved, waiting for a slot'))).toEqual(['Issue', 'Ticket', 'Updated']);
    expect(ths(section(html, 'On staging (awaiting production)'))).toEqual(['Issue', 'Ticket', 'Updated']);
    expect(ths(section(html, 'Done'))).toEqual(['Issue', 'Ticket', 'Closed', 'Release', 'Final marker']);
  });

  it('a Needs JP row without a label (old host payload) renders an empty Needs cell, other cells intact', () => {
    const cells = tds(section(render(hostRecord({ runs: [run(7, { state: 'held', marker: 'BLOCKED' })] })), 'Needs JP'));
    expect(cells).toHaveLength(needsCols.length);
    expect(cells[0]).toBe('#7');
    expect(cells[2]).toBe('');
    expect(cells[6]).toBe('BLOCKED'); // cells: Issue, Ticket, Needs, Host, State, Stage, Marker
  });

  it('an empty Needs JP group spans all nine columns', () => {
    expect(section(render(hostRecord({ runs: [] })), 'Needs JP')).toMatch(/<td colspan="9">\s*none\s*<\/td>/);
  });

  it('the label is HTML-escaped: no raw markup from a hostile needs value reaches the page', () => {
    const html2 = render(hostRecord({ runs: [run(2, { state: 'held', marker: 'BLOCKED', needs: '<img src=x onerror=alert(1)>' })] }));
    expect(html2).not.toContain('<img src=x');
    expect(tds(section(html2, 'Needs JP'))[2]).toBe('&lt;img src=x onerror=alert(1)&gt;');
  });

  it('a demoted row shows in Parked with the Parked (unchanged) columns', () => {
    const html3 = render(hostRecord({ runs: [run(2, { state: 'held', marker: 'BLOCKED', parked_reason: 'answered', last_activity_at: ago(24 * 30) })] }));
    expect(Number(h2('Needs JP').exec(html3)[1])).toBe(0);
    expect(Number(h2('Parked').exec(html3)[1])).toBe(1);
    expect(ths(section(html3, 'Parked'))).toEqual(base);
  });
});
