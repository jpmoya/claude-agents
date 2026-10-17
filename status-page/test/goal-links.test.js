// Goal names link to their registry issue.

import { describe, it, expect } from 'vitest';
import { validateBeatPayload } from '../src/validate.js';
import { renderPage } from '../src/render.js';
import { validPayload, hostRecord } from './fixtures.js';

const closed = (o = {}) => ({
  id: 'c1',
  title: 'Closed goal',
  repos: ['org/repo-a'],
  host: '',
  state: 'delivered',
  closed_at: '2026-09-20T09:00:00Z',
  ...o,
});
const running = (o = {}) => ({ id: 'r1', title: 'Live goal', repos: ['org/repo-a'], host: 'mac', state: 'running', scope_total: 4, scope_delivered: 1, ...o });
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
const goalsHtml = (html) => (/<section class="group">\s*<h2>Goals<\/h2>[\s\S]*?<\/section>/.exec(html) || [''])[0];

const URL1 = 'https://github.com/jpmoya/claude-agents/issues/320';
describe('goal name links', () => {
  it('keeps a valid GitHub issue url and drops anything else', () => {
    expect(goalsOf([running({ url: URL1 })])[0].url).toBe(URL1);
    expect(goalsOf([running({ url: 'javascript:alert(1)' })])[0].url).toBeUndefined();
    expect(goalsOf([running({ url: 'https://evil.example/issues/1' })])[0].url).toBeUndefined();
  });
  it('links a live goal title and a closed goal title, with no raw URL text', () => {
    const html = goalsHtml(render(rec([running({ url: URL1 }), closed({ url: URL1.replace('320', '321') })])));
    expect(html).toContain(`<a href="${URL1}" target="_blank" rel="noopener">Live goal</a>`);
    expect(html).toContain('<a href="https://github.com/jpmoya/claude-agents/issues/321" target="_blank" rel="noopener">Closed goal</a>');
    expect(text(html)).not.toContain('https://');
  });
  it('shows a plain name when there is no url', () => {
    expect(goalsHtml(render(rec([running()])))).not.toContain('<a ');
  });
  it('accepts a cross-repo search and a milestone page, rejects other hosts and quotes', () => {
    const search = 'https://github.com/issues?q=is%3Aissue%20label%3A%22goal%3A%20X%22%20repo%3Ao%2Fr';
    expect(goalsOf([running({ url: search })])[0].url).toBe(search);
    const ms = 'https://github.com/o/r/milestone/4?closed=1';
    expect(goalsOf([running({ url: ms })])[0].url).toBe(ms);
    expect(goalsOf([running({ url: 'https://github.com/issues?q="><script>' })])[0].url).toBeUndefined();
    expect(goalsOf([running({ url: 'https://evil.com/issues?q=a' })])[0].url).toBeUndefined();
  });
});
