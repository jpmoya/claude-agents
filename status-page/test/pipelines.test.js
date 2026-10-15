// Issue #273 — Pipelines tab. Expected values come from the ticket text (Content, Test fixtures, ACs).
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

vi.mock('../src/capture.js', () => ({ captureError: vi.fn(async () => {}) }));
vi.mock('../src/render.js', async (importOriginal) => {
  const orig = await importOriginal();
  return { ...orig, renderPipelines: vi.fn(orig.renderPipelines) };
});

import worker, { __resetRateLimiter } from '../src/index.js';
import * as render from '../src/render.js';
import { captureError as realCaptureError } from '../src/capture.js';
import { PIPELINES, findDrift } from '../src/pipelines.js';
import { createMockKV } from './mock-kv.js';
import { makeEnv, getRequest } from './fixtures.js';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');
const read = (p) => readFileSync(join(repoRoot, p), 'utf8');
const SOURCES = ['agents/orchestrator.md', 'agents/product-manager.md', 'agents/delivery-lead.md']
  .map(read)
  .join('\n');

beforeEach(() => {
  __resetRateLimiter();
  vi.clearAllMocks();
});

async function getPipelines(env = makeEnv()) {
  const res = await worker.fetch(getRequest('/pipelines'), env, {});
  return { res, html: await res.text() };
}

const stripStyle = (html) => html.replace(/<style[\s\S]*?<\/style>/g, '');
const tagSequence = (html) => [...html.matchAll(/<\/?([a-z0-9]+)/gi)].map((m) => m[1]);

describe('GET /pipelines — route (AC1)', () => {
  it('returns 200 text/html with noindex and every track title and stage name', async () => {
    const { res, html } = await getPipelines();
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toMatch(/text\/html/);
    expect(res.headers.get('X-Robots-Tag')).toBe('noindex');
    expect(PIPELINES.length).toBeGreaterThan(0);
    for (const track of PIPELINES) {
      expect(html).toContain(track.title);
      for (const stage of track.stages) expect(html).toContain(stage.name);
    }
  });

  it('POST /pipelines -> 405 with noindex', async () => {
    const res = await worker.fetch(getRequest('/pipelines', { method: 'POST' }), makeEnv(), {});
    expect(res.status).toBe(405);
    expect(res.headers.get('X-Robots-Tag')).toBe('noindex');
  });

  it('makes no KV reads or writes (AC8)', async () => {
    const kv = createMockKV();
    await getPipelines(makeEnv({ STATUS: kv }));
    expect(kv._calls()).toEqual({ get: 0, put: 0, delete: 0 });
  });
});

describe('nav on both pages (AC1)', () => {
  it.each([
    ['/', 'Status'],
    ['/pipelines', 'Pipelines'],
  ])('%s shows both links and marks only the current one', async (path, current) => {
    const res = await worker.fetch(getRequest(path), makeEnv(), {});
    const html = await res.text();
    expect(html).toMatch(/<a[^>]*href="\/"[^>]*>\s*Status\s*<\/a>|<[^>]*aria-current="page"[^>]*>\s*Status\s*</);
    expect(html).toMatch(/<a[^>]*href="\/pipelines"[^>]*>\s*Pipelines\s*<\/a>|<[^>]*aria-current="page"[^>]*>\s*Pipelines\s*</);
    const marked = [...html.matchAll(/<[^>]*aria-current="page"[^>]*>\s*([A-Za-z]+)/g)].map((m) => m[1]);
    expect(marked).toEqual([current]);
  });
});

describe('content (AC5) — seven items from the ticket', () => {
  const AGENTS = [
    'product-manager', 'ux-flow-designer', 'ui-ux-designer', 'solutions-architect', 'test-writer',
    'test-reviewer', 'fullstack-developer', 'code-reviewer', 'deployer', 'infra-planner',
    'infra-reviewer', 'infra-operator', 'pipeline-diagnostician', 'pipeline-adjudicator', 'delivery-lead',
  ];

  it('renders every agent stage named in the ticket', async () => {
    const { html } = await getPipelines();
    for (const a of AGENTS) expect(html, a).toContain(a);
  });

  it('has a track for each of the six pipelines', () => {
    const titles = PIPELINES.map((t) => t.title).join(' | ');
    for (const re of [/code ticket|full lane/i, /fast lane/i, /infra/i, /incident/i, /delivery lead/i, /release|promotion/i]) {
      expect(titles).toMatch(re);
    }
  });

  it('renders the branch-condition chips', async () => {
    const { html } = await getPipelines();
    for (const c of ['UI change: yes', 'UI change: no', 'Lane: fast', 'Lane: full', 'UX flow: yes', 'MOCKUPS APPROVED']) {
      expect(html, c).toContain(c);
    }
    expect(html).toMatch(/infra/);
  });

  it('shows the upfront mockup-gate skip chip labelled "coming"', async () => {
    const { html } = await getPipelines();
    expect(html).toMatch(/Upfront skip of mockup gate/);
    const chip = /Upfront skip of mockup gate[^<]*/.exec(html)[0];
    const around = html.slice(Math.max(0, html.indexOf(chip) - 200), html.indexOf(chip) + 300);
    expect(around.toLowerCase()).toContain('coming');
  });

  it('the real data carries exactly that condition with coming: true', () => {
    const conds = PIPELINES.flatMap((t) => t.stages.map((s) => s.when)).filter(Boolean);
    const upfront = conds.filter((c) => /Upfront skip of mockup gate/.test(c.label));
    expect(upfront.length).toBeGreaterThan(0);
    for (const c of upfront) expect(c.coming).toBe(true);
  });

  it('toggling coming changes only the chip label, not the markup structure', () => {
    const mk = (coming) => [
      { id: 't', title: 'Track', stages: [{ name: 'product-manager' }, { name: 'deployer', when: { label: 'Upfront skip of mockup gate', coming } }] },
    ];
    const on = render.renderPipelines(mk(true));
    const off = render.renderPipelines(mk(false));
    expect(on).not.toBe(off);
    expect(on.toLowerCase()).toContain('coming');
    expect(off.toLowerCase()).not.toContain('coming');
    expect(tagSequence(off)).toEqual(tagSequence(on));
  });
});

describe('drift guard (AC4)', () => {
  it('reports a stage name absent from the source docs', () => {
    const data = [{ id: 'x', title: 'X', stages: [{ name: 'made-up-stage' }, { name: 'deployer' }] }];
    const drift = findDrift(data, SOURCES);
    expect(drift).toContain('made-up-stage');
    expect(drift).not.toContain('deployer');
  });

  it('reports a condition label absent from the source docs, ignoring coming:true ones', () => {
    const data = [
      { id: 'x', title: 'X', stages: [
        { name: 'deployer', when: { label: 'Totally invented condition' } },
        { name: 'deployer', when: { label: 'Also invented but not shipped yet', coming: true } },
      ] },
    ];
    const drift = findDrift(data, SOURCES);
    expect(drift).toContain('Totally invented condition');
    expect(drift).not.toContain('Also invented but not shipped yet');
  });

  it('the real data has no drift against orchestrator.md / product-manager.md / delivery-lead.md', () => {
    expect(PIPELINES.length).toBeGreaterThan(0);
    expect(findDrift(PIPELINES, SOURCES)).toEqual([]);
  });

  it('every stage name that is an agent has agents/<name>.md', () => {
    expect(PIPELINES.length).toBeGreaterThan(0);
    const names = new Set(PIPELINES.flatMap((t) => t.stages.map((s) => s.name)));
    const agentLike = [...names].filter((n) => /^[a-z]+(-[a-z]+)+$/.test(n));
    expect(agentLike.length).toBeGreaterThan(0);
    for (const n of agentLike) expect(existsSync(join(repoRoot, 'agents', `${n}.md`)), n).toBe(true);
  });

  it('orchestrator.md carries the update-pipelines.js routing note', () => {
    const md = read('agents/orchestrator.md');
    expect(md).toMatch(/Routing changes:[^\n]*status-page\/src\/pipelines\.js[^\n]*same PR/);
  });
});

describe('public-page rules (leak, AC6, AC7)', () => {
  it('has no tokens, issue/PR numbers, .local hosts or clog', async () => {
    const { html } = await getPipelines();
    const text = stripStyle(html);
    expect(text).not.toMatch(/\b(ghp_|github_pat_|xox[bp]-|Bearer |TOKEN_)/);
    expect(text).not.toMatch(/#\d+/);
    expect(text).not.toMatch(/\.local/);
    expect(text).not.toMatch(/clog/);
  });

  it('works with JS off: no <script>, no client fetch', async () => {
    const { html } = await getPipelines();
    expect(html).not.toMatch(/<script/i);
    expect(html).not.toMatch(/fetch\(/);
  });

  it('GET / has no <script> added', async () => {
    const res = await worker.fetch(getRequest('/'), makeEnv(), {});
    expect(await res.text()).not.toMatch(/<script/i);
  });

  it('is phone-readable and has light + dark styles', async () => {
    const { html } = await getPipelines();
    expect(html).toMatch(/<meta name="viewport"[^>]*width=device-width/);
    expect(html).toMatch(/max-width:\s*100%/);
    expect(html).toMatch(/overflow-wrap:\s*(anywhere|break-word)|word-break:\s*break-word/);
    expect(html).not.toMatch(/(?<!max-)(?<!min-)width:\s*\d{3,}px/);
    expect(html).toMatch(/@media \(prefers-color-scheme: dark\)/);
  });
});

describe('observability (AC9)', () => {
  it('render failure -> 500 + noindex and captureError called with release, environment, route', async () => {
    render.renderPipelines.mockImplementationOnce(() => {
      throw new Error('boom');
    });
    const env = makeEnv({ RELEASE: 'abc1234def', ENVIRONMENT: 'production' });
    const res = await worker.fetch(getRequest('/pipelines'), env, {});
    expect(res.status).toBe(500);
    expect(res.headers.get('X-Robots-Tag')).toBe('noindex');
    expect(await res.text()).not.toContain('boom');
    expect(realCaptureError).toHaveBeenCalledTimes(1);
    const [err, tags] = realCaptureError.mock.calls[0];
    expect(err).toBeInstanceOf(Error);
    expect(tags).toMatchObject({ release: 'abc1234def', environment: 'production', route: '/pipelines' });
  });
});

describe('captureError (AC9, real module)', () => {
  it('is a no-op that never throws or calls the network when no alert secret is configured', async () => {
    const { captureError } = await vi.importActual('../src/capture.js');
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('ok'));
    await expect(
      captureError(new Error('x'), { release: 'abc', environment: 'staging', route: '/pipelines' }, {}),
    ).resolves.toBeUndefined();
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });
});
