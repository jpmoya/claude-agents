// Issue #273 — Pipelines tab. Expected values come from the ticket text (Content, Test fixtures, ACs).
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
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
// Text nodes only (between tags), outside <style>: what a reader sees.
const textNodes = (html) => [...stripStyle(html).matchAll(/>([^<>]+)</g)].map((m) => m[1].trim()).filter(Boolean);
// The element whose own text contains `label` (the chip), or null.
const elementWith = (html, label) => {
  const m = new RegExp(`<([a-z0-9]+)[^>]*>[^<]*${label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[^<]*</\\1>`, 'i').exec(html);
  return m ? m[0] : null;
};
// Guard against vacuous passes: the page was really served and carries real content.
function expectRealPage(res, html) {
  expect(res.status).toBe(200);
  expect(html).toContain('How tickets are routed');
  expect(html).toContain('product-manager');
  expect(html).toContain('fullstack-developer');
}

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

  it('POST /pipelines -> 405 with noindex and the same (empty) body as POST /', async () => {
    const res = await worker.fetch(getRequest('/pipelines', { method: 'POST' }), makeEnv(), {});
    const home = await worker.fetch(getRequest('/', { method: 'POST' }), makeEnv(), {});
    expect(home.status).toBe(405);
    expect(res.status).toBe(405);
    expect(res.headers.get('X-Robots-Tag')).toBe('noindex');
    expect(await res.text()).toBe(await home.text());
  });

  it('makes no KV reads or writes (AC8)', async () => {
    const kv = createMockKV();
    const { res, html } = await getPipelines(makeEnv({ STATUS: kv }));
    expectRealPage(res, html);
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
    expect(html).toMatch(/<a[^>]*href="\/"[^>]*>\s*Status\s*<\/a>/);
    expect(html).toMatch(/<a[^>]*href="\/pipelines"[^>]*>\s*Pipelines\s*<\/a>/);
    const marked = [...html.matchAll(/<a[^>]*(?:aria-current="page"|class="[^"]*\b(?:current|active)\b[^"]*")[^>]*>\s*([A-Za-z]+)/g)].map((m) => m[1]);
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

  it('renders the branch-condition chips as visible text', async () => {
    const { html } = await getPipelines();
    const text = textNodes(html).join('\n');
    for (const c of ['UI change: yes', 'UI change: no', 'Lane: fast', 'Lane: full', 'UX flow: yes']) {
      expect(text, c).toContain(c);
    }
    // `infra` label forks to the infra track: the bare word `infra` (not infra-planner / "Infra track").
    expect(textNodes(html).some((t) => /(?<![\w-])infra(?![\w-])/.test(t))).toBe(true);
    // schema change (or new endpoint) forces Lane: full
    expect(text).toMatch(/schema change/);
    // exact JP approval marker from the ticket
    expect(html).toContain('**[jp] MOCKUPS APPROVED**');
  });

  it('release / promotion track shows the risky list staying JP-only (item 6)', async () => {
    const { html } = await getPipelines();
    const track = PIPELINES.find((t) => /release|promotion/i.test(t.title));
    expect(track).toBeTruthy();
    const section = html.slice(html.indexOf(track.title));
    const end = section.indexOf('</section>');
    const text = textNodes(section.slice(0, end > 0 ? end : undefined)).join('\n');
    expect(text).toMatch(/risky/i);
    expect(text).toMatch(/JP/);
  });

  it('places conditional stages behind their condition and keeps the fast lane free of designers/test-writer', () => {
    const code = PIPELINES.find((t) => /code ticket|full lane/i.test(t.title));
    const stage = (t, n) => t.stages.find((s) => s.name === n);
    expect(stage(code, 'product-manager').when).toBeUndefined();
    expect(stage(code, 'ux-flow-designer').when.label).toBe('UX flow: yes');
    expect(stage(code, 'ui-ux-designer').when.label).toBe('UI change: yes');
    expect(code.stages.find((s) => /MOCKUPS APPROVED/.test(s.name)).when.label).toBe('UI change: yes');
    expect(stage(code, 'solutions-architect').when.label).toBe('READY FOR ARCHITECTURE');
    const fast = PIPELINES.find((t) => /fast lane/i.test(t.title));
    const fastNames = fast.stages.map((s) => s.name);
    for (const n of ['ux-flow-designer', 'ui-ux-designer', 'solutions-architect', 'test-writer']) {
      expect(fastNames, n).not.toContain(n);
    }
    expect(fastNames).toEqual(expect.arrayContaining(['product-manager', 'fullstack-developer', 'code-reviewer', 'deployer']));
  });

  it('shows the upfront mockup-gate skip chip labelled "coming" in the same chip element', async () => {
    const { html } = await getPipelines();
    const chip = elementWith(html, 'Upfront skip of mockup gate');
    expect(chip).not.toBeNull();
    expect(chip.toLowerCase()).toContain('coming');
  });

  it('the real data carries exactly that condition with coming: true', () => {
    const conds = PIPELINES.flatMap((t) => t.stages.map((s) => s.when)).filter(Boolean);
    const upfront = conds.filter((c) => /Upfront skip of mockup gate/.test(c.label));
    expect(upfront.length).toBeGreaterThan(0);
    for (const c of upfront) expect(c.coming).toBe(true);
  });

  it('toggling coming changes the chip label only: "coming" is in the chip when true, nowhere in the content when false', () => {
    const mk = (coming) => [
      { id: 't', title: 'Track', stages: [{ name: 'product-manager' }, { name: 'deployer', when: { label: 'Upfront skip of mockup gate', coming } }] },
    ];
    const on = render.renderPipelines(mk(true));
    const off = render.renderPipelines(mk(false));
    expect(on).not.toBe(off);
    const chipOn = elementWith(on, 'Upfront skip of mockup gate');
    const chipOff = elementWith(off, 'Upfront skip of mockup gate');
    expect(chipOn.toLowerCase()).toContain('coming');
    expect(chipOff.toLowerCase()).not.toContain('coming');
    expect(textNodes(off).join(' ').toLowerCase()).not.toContain('coming');
    for (const doc of [on, off]) {
      expect(doc).toContain('Track');
      expect(doc).toContain('product-manager');
      expect(doc).toContain('deployer');
    }
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
    const { res, html } = await getPipelines();
    expectRealPage(res, html);
    const text = stripStyle(html);
    expect(text).not.toMatch(/\b(ghp_|github_pat_|xox[bp]-|Bearer |TOKEN_)/);
    expect(text).not.toMatch(/(?<!&)#\d+/); // `&#39;` entities are not issue numbers
    expect(text).not.toMatch(/\.local/);
    expect(text).not.toMatch(/clog/);
  });

  it('works with JS off: no <script>, no client fetch', async () => {
    const { res, html } = await getPipelines();
    expectRealPage(res, html);
    expect(html).not.toMatch(/<script/i);
    expect(html).not.toMatch(/fetch\(/);
  });

  it('GET / has no <script> added', async () => {
    const res = await worker.fetch(getRequest('/'), makeEnv(), {});
    const html = await res.text();
    expect(res.status).toBe(200);
    expect(html).toContain('<h1>Pipeline status</h1>');
    expect(html).not.toMatch(/<script/i);
  });

  it('is phone-readable and has light + dark styles', async () => {
    const { res, html } = await getPipelines();
    expectRealPage(res, html);
    expect(html).toMatch(/<meta name="viewport"[^>]*width=device-width/);
    expect(html).toMatch(/max-width:\s*100%/);
    expect(html).toMatch(/overflow-wrap:\s*(anywhere|break-word)|word-break:\s*break-word/);
    expect(html).not.toMatch(/(?<!max-)(?<!min-)width:\s*\d{3,}px/);
    expect(html).toMatch(/@media \(prefers-color-scheme: dark\)/);
  });
});

describe('existing status view unchanged (AC3)', () => {
  // Expected body: the `/` output of the base commit 3b3d07b with empty KV, hand-embedded;
  // the only permitted difference is the added nav (markup + its CSS rules).
  const BASE_HOME = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="20">
<title>Pipeline status</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, sans-serif; margin: 0; padding: 1rem; background: #ffffff; color: #111111; }
  h1 { font-size: 1.1rem; }
  h2 { font-size: 1rem; }
  .badge { display: inline-block; padding: 0.15rem 0.5rem; border-radius: 0.25rem; font-weight: 600; }
  .badge.live { background: #1a7f37; color: #ffffff; }
  .badge.stale { background: #9a6700; color: #ffffff; }
  .badge.offline { background: #a40e26; color: #ffffff; }
  .badge.nodata { background: #6e7781; color: #ffffff; }
  .badge.goal-running { background: #1a7f37; color: #ffffff; }
  .badge.goal-waiting_jp { background: #9a6700; color: #ffffff; }
  .badge.goal-held { background: #a40e26; color: #ffffff; }
  .badge.goal-between_cycles { background: #6e7781; color: #ffffff; }
  .badge.goal-delivered { background: #1a7f37; color: #ffffff; }
  .badge.goal-stopped { background: #6e7781; color: #ffffff; }
  .goals-closed h3 { font-size: 0.95em; margin: 1em 0 0.3em; }
  .goals-closed ul { margin: 0; padding-left: 1.2em; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
  th, td { text-align: left; padding: 0.25rem; border-bottom: 1px solid rgba(127, 127, 127, 0.3); }
  section.host, section.group { margin-bottom: 1.5rem; }
  @media (prefers-color-scheme: dark) {
    body { background: #111111; color: #eeeeee; }
    th, td { border-bottom-color: rgba(255, 255, 255, 0.2); }
  }
</style>
</head>
<body>
<h1>Pipeline status</h1>
<p class="empty">no data from either host yet</p>
</body>
</html>`;

  it('GET / equals the pre-change page once the nav markup and nav CSS are removed', async () => {
    const res = await worker.fetch(getRequest('/'), makeEnv(), {});
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toMatch(/<nav[\s\S]*?<\/nav>/); // nav really is there
    const stripped = html
      .replace(/<nav[\s\S]*?<\/nav>\n?/g, '')
      .replace(/^[ \t]*nav[^\n]*\{[^\n]*\}[ \t]*\n/gm, '');
    expect(stripped).toBe(BASE_HOME);
  });

  it('GET /status.json is unchanged: same shape, thresholds and empty hosts', async () => {
    const res = await worker.fetch(getRequest('/status.json'), makeEnv(), {});
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(typeof body.generated_at).toBe('string');
    delete body.generated_at;
    expect(body).toEqual({ v: 1, keepalive_secs: 600, stale_secs: 1500, offline_secs: 4500, hosts: { mac: null, vm: null } });
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

  describe('alert path (secret present, fetch mocked at the network boundary)', () => {
    const HOOK = 'https://hooks.slack.test/services/T000/B000/XXXXXXXX';
    const tags = { release: 'abc1234def', environment: 'production', route: '/pipelines' };
    let fetchSpy;
    beforeEach(() => {
      fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('ok'));
    });
    afterEach(() => fetchSpy.mockRestore());

    it('posts once to the existing SLACK_WEBHOOK_URL with release, environment and route', async () => {
      const { captureError } = await vi.importActual('../src/capture.js');
      await captureError(new Error('boom'), tags, { SLACK_WEBHOOK_URL: HOOK });
      expect(fetchSpy).toHaveBeenCalledTimes(1);
      const [url, init] = fetchSpy.mock.calls[0];
      expect(url).toBe(HOOK);
      expect(init.method).toBe('POST');
      const payload = JSON.parse(init.body);
      expect(typeof payload.text).toBe('string');
      expect(payload.text).toContain('abc1234def');
      expect(payload.text).toContain('production');
      expect(payload.text).toContain('/pipelines');
    });

    it('the payload carries no secrets, error message, tokens or webhook URL', async () => {
      const { captureError } = await vi.importActual('../src/capture.js');
      const env = { SLACK_WEBHOOK_URL: HOOK, TOKEN_MAC: 'tok-mac-SECRET', TOKEN_VM: 'tok-vm-SECRET' };
      await captureError(new Error('leaky message ghp_ABCDEF user@example.com'), tags, env);
      const body = fetchSpy.mock.calls[0][1].body;
      for (const bad of ['ghp_', 'leaky message', 'user@example.com', 'tok-mac-SECRET', 'tok-vm-SECRET', HOOK, 'XXXXXXXX', 'Bearer']) {
        expect(body, bad).not.toContain(bad);
      }
    });

    it('never throws when the webhook call fails', async () => {
      const { captureError } = await vi.importActual('../src/capture.js');
      fetchSpy.mockRejectedValue(new Error('network down'));
      await expect(captureError(new Error('x'), tags, { SLACK_WEBHOOK_URL: HOOK })).resolves.toBeUndefined();
    });
  });
});
