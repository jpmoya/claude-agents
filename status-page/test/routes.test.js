// GET /, GET /robots.txt, 404 catch-all, and the "X-Robots-Tag applied in one place to every
// response" invariant (AC16). Routes table + robots content are taken verbatim from issue #11 /
// #4 §5.

import { describe, it, expect, beforeEach } from 'vitest';
import worker, { __resetRateLimiter } from '../src/index.js';
import { createMockKV } from './mock-kv.js';
import { makeEnv, getRequest, validPayload, validRun, beatRequest, TOKEN_MAC } from './fixtures.js';

beforeEach(() => {
  __resetRateLimiter();
});

function seededRecord(overrides = {}) {
  return JSON.stringify({ ...validPayload(), received_at: '2026-09-17T18:00:00Z', ...overrides });
}

describe('GET / — server-rendered HTML page', () => {
  it('returns 200 with an HTML content type', async () => {
    const kv = createMockKV({ 'host:mac': seededRecord(), 'host:vm': seededRecord() });
    const env = makeEnv({ STATUS: kv });
    const res = await worker.fetch(getRequest('/'), env, {});
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toMatch(/text\/html/);
  });

  it('Cache-Control is max-age=15 (AC16)', async () => {
    const kv = createMockKV({ 'host:mac': seededRecord(), 'host:vm': seededRecord() });
    const env = makeEnv({ STATUS: kv });
    const res = await worker.fetch(getRequest('/'), env, {});
    expect(res.headers.get('Cache-Control')).toBe('max-age=15');
  });

  it('reads KV exactly twice per render (host:mac, host:vm)', async () => {
    const kv = createMockKV({ 'host:mac': seededRecord(), 'host:vm': seededRecord() });
    const env = makeEnv({ STATUS: kv });
    await worker.fetch(getRequest('/'), env, {});
    expect(kv._calls().get).toBe(2);
  });

  it('returns 405 for POST /', async () => {
    const env = makeEnv();
    const res = await worker.fetch(getRequest('/', { method: 'POST' }), env, {});
    expect(res.status).toBe(405);
  });

  it('renders "no data from either host yet" on first deploy (both KV keys empty)', async () => {
    const env = makeEnv();
    const res = await worker.fetch(getRequest('/'), env, {});
    const html = await res.text();
    expect(html).toContain('no data from either host yet');
  });

  it('AC4 leak test (HTML half): planted strings never reach the rendered page', async () => {
    const plantedTitle = 'URGENT fix prod outage before demo';
    const plantedPath = '/Users/jp/dev/claude-agents/secrets.env';
    const plantedLogLine = '2026-09-17T18:00:00Z [ERROR] worker crashed, dumping stack';

    const env = makeEnv();
    await worker.fetch(
      beatRequest({
        token: TOKEN_MAC,
        body: validPayload({
          runs: [validRun({ repo: plantedTitle, stage: plantedPath, marker: plantedLogLine })],
        }),
      }),
      env,
      {}
    );

    const res = await worker.fetch(getRequest('/'), env, {});
    const html = await res.text();
    expect(html).not.toContain(plantedTitle);
    expect(html).not.toContain(plantedPath);
    expect(html).not.toContain(plantedLogLine);
  });

  it('a "sessions" field planted alongside a valid payload never surfaces in the HTML (AC4)', async () => {
    const plantedSessionTitle = 'planted interactive session title';
    const env = makeEnv();
    await worker.fetch(
      beatRequest({
        token: TOKEN_MAC,
        body: validPayload({ sessions: [{ id: 'sess-1', title: plantedSessionTitle }] }),
      }),
      env,
      {}
    );

    const res = await worker.fetch(getRequest('/'), env, {});
    const html = await res.text();
    expect(html).not.toContain(plantedSessionTitle);
  });
});

describe('GET /robots.txt', () => {
  it('returns 200 with "User-agent: *" / "Disallow: /"', async () => {
    const env = makeEnv();
    const res = await worker.fetch(getRequest('/robots.txt'), env, {});
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toContain('User-agent: *');
    expect(text).toContain('Disallow: /');
  });

  it('returns 405 for POST /robots.txt', async () => {
    const env = makeEnv();
    const res = await worker.fetch(getRequest('/robots.txt', { method: 'POST' }), env, {});
    expect(res.status).toBe(405);
  });
});

describe('Unknown routes -> 404', () => {
  it('returns 404 for an unrecognised path', async () => {
    const env = makeEnv();
    const res = await worker.fetch(getRequest('/does-not-exist'), env, {});
    expect(res.status).toBe(404);
  });
});

describe('AC16 — X-Robots-Tag: noindex applied in one place to EVERY response', () => {
  const cases = [
    ['GET /', () => getRequest('/')],
    ['GET /status.json', () => getRequest('/status.json')],
    ['GET /robots.txt', () => getRequest('/robots.txt')],
    ['GET /does-not-exist (404)', () => getRequest('/does-not-exist')],
    ['POST /beat without auth (401)', () => beatRequest({ body: validPayload(), token: null })],
  ];

  it.each(cases)('%s carries X-Robots-Tag: noindex', async (_label, buildRequest) => {
    const kv = createMockKV({ 'host:mac': seededRecord(), 'host:vm': seededRecord() });
    const env = makeEnv({ STATUS: kv });
    const res = await worker.fetch(buildRequest(), env, {});
    expect(res.headers.get('X-Robots-Tag')).toBe('noindex');
  });
});

// ---------------------------------------------------------------------------------------------
// Issue #51 — completed[] through the real routes (Expected Behavior 6–7, AC7, AC8).
// Each case reads back what was STORED / RENDERED, so a Worker that merely ignores `completed`
// (returning 204 as it does today) fails.
// ---------------------------------------------------------------------------------------------
import { validCompleted } from './fixtures.js';

describe('completed[] end to end (issue #51)', () => {
  const hourAgoIso = (hours = 1) =>
    new Date(Date.now() - hours * 3600 * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const storedMac = async (env) => JSON.parse(await env.STATUS.get('host:mac'));

  it('AC7 size: 20 runs + 10 completed, every title 140 ASCII chars, is < 128 KB and accepted (204) with all 30 stored', async () => {
    const title = 'T'.repeat(140);
    const runs = Array.from({ length: 20 }, (_v, i) =>
      validRun({ issue: i + 1, title, url: `https://github.com/example-owner/project-a/issues/${i + 1}` })
    );
    const completed = Array.from({ length: 10 }, (_v, i) =>
      validCompleted({ issue: 100 + i, title, url: `https://github.com/example-owner/project-a/issues/${100 + i}`, closed_at: hourAgoIso(i + 1) })
    );
    const body = JSON.stringify(validPayload({ runs, completed }));
    expect(new TextEncoder().encode(body).length).toBeLessThan(128 * 1024);

    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body, token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
    const stored = await storedMac(env);
    expect(stored.runs).toHaveLength(20);
    expect(stored.completed).toHaveLength(10);
    expect(stored.completed[0].title).toBe(title);
  });

  it('a valid completed[] is stored on the host record and served by /status.json', async () => {
    const env = makeEnv();
    const item = validCompleted({ closed_at: hourAgoIso() });
    const res = await worker.fetch(beatRequest({ body: validPayload({ completed: [item] }), token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
    const json = await (await worker.fetch(getRequest('/status.json'), env, {})).json();
    expect(json.hosts.mac.completed).toEqual([item]);
  });

  it('bad completed items never cause a 400: they are dropped or sanitised in what is stored', async () => {
    const good = validCompleted({ issue: 7, closed_at: hourAgoIso() });
    const noClosedAt = validCompleted({ issue: 8 });
    delete noClosedAt.closed_at;
    const items = [
      good,
      noClosedAt,
      validCompleted({ issue: 9, closed_at: 'yesterday' }),
      validCompleted({ issue: 0, closed_at: hourAgoIso() }),
      validCompleted({ issue: 10, url: 'https://evil.example/x', closed_at: hourAgoIso() }),
      validCompleted({ issue: 11, title: '<script>alert(1)</script>', closed_at: hourAgoIso() }),
    ];
    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body: validPayload({ completed: items, sessions: [{ id: 'x' }] }), token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
    const stored = await storedMac(env);
    expect(stored.completed.map((c) => c.issue)).toEqual([7, 10, 11]);
    expect(stored.completed[1]).not.toHaveProperty('url');
    expect(stored).not.toHaveProperty('sessions');
  });

  it('11 completed items are accepted (204) and the first 10 are stored', async () => {
    const items = Array.from({ length: 11 }, (_v, i) => validCompleted({ issue: i + 1, closed_at: hourAgoIso() }));
    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body: validPayload({ completed: items }), token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
    expect((await storedMac(env)).completed.map((c) => c.issue)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  });

  it('completed: "x" (non-array) is accepted (204) and stored as []', async () => {
    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body: validPayload({ completed: 'x' }), token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
    expect((await storedMac(env)).completed).toEqual([]);
  });

  it('AC2: GET / renders the Done group from the stored beat, escaped, with no <script tag', async () => {
    const env = makeEnv();
    await worker.fetch(
      beatRequest({
        body: validPayload({ completed: [validCompleted({ issue: 42, title: '<script>alert(1)</script>', closed_at: hourAgoIso() })] }),
        token: TOKEN_MAC,
      }),
      env,
      {}
    );
    const html = await (await worker.fetch(getRequest('/'), env, {})).text();
    expect(html).toContain('Done (1)');
    expect(html).toContain('&lt;script&gt;alert(1)&lt;/script&gt;');
    expect(html).not.toMatch(/<script/i);
  });

  it('AC2: the same ticket beaten by both hosts appears once on the page', async () => {
    const env = makeEnv();
    const item = validCompleted({ issue: 42, closed_at: hourAgoIso() });
    await worker.fetch(beatRequest({ body: validPayload({ completed: [item] }), token: TOKEN_MAC }), env, {});
    await worker.fetch(beatRequest({ body: validPayload({ completed: [item] }), token: 'test-token-vm-0000000000000000' }), env, {});
    const html = await (await worker.fetch(getRequest('/'), env, {})).text();
    expect(html.split('/issues/42"').length - 1).toBe(1);
  });

  it('AC8 (new Worker, old host): a beat with no completed key renders the page with Done (0) and a none row', async () => {
    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body: validPayload(), token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
    const html = await (await worker.fetch(getRequest('/'), env, {})).text();
    expect(html).toContain('Done (0)');
    expect(html).toMatch(/<tr><td[^>]*>none/);
    expect(html).not.toContain('<h2>Completed</h2>');
  });
});
