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
