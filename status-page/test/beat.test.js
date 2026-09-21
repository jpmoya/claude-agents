// POST /beat — AC3 (auth + host isolation) and the size/format edges of AC4, exercised through
// the exported `fetch` handler with a hand-written mock KV. Expected status codes/headers are
// taken verbatim from the routes table in issue #11 / #4 §5.

import { describe, it, expect, beforeEach } from 'vitest';
import worker, { __resetRateLimiter } from '../src/index.js';
import { createMockKV } from './mock-kv.js';
import { makeEnv, validPayload, beatRequest, sizedBeatBody, TOKEN_MAC, TOKEN_VM } from './fixtures.js';
import { validRun, getRequest } from './fixtures.js'; // issue #29

beforeEach(() => {
  __resetRateLimiter();
});

describe('AC3 — POST /beat auth', () => {
  it('returns 401 for a missing Authorization header, and changes nothing', async () => {
    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body: validPayload(), token: null }), env, {});
    expect(res.status).toBe(401);
    const body = await res.text();
    expect(body).toBe('');
    expect(env.STATUS._calls().put).toBe(0);
  });

  it('returns 401 for a bad token, and changes nothing', async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      beatRequest({ body: validPayload(), token: 'not-a-real-token' }),
      env,
      {}
    );
    expect(res.status).toBe(401);
    expect(env.STATUS._calls().put).toBe(0);
  });

  it('accepts a valid TOKEN_MAC and stores under host:mac', async () => {
    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body: validPayload(), token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
    const stored = env.STATUS._dump();
    expect(stored).toHaveProperty('host:mac');
    expect(stored).not.toHaveProperty('host:vm');
  });

  it('accepts a valid TOKEN_VM and stores under host:vm', async () => {
    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body: validPayload(), token: TOKEN_VM }), env, {});
    expect(res.status).toBe(204);
    const stored = env.STATUS._dump();
    expect(stored).toHaveProperty('host:vm');
    expect(stored).not.toHaveProperty('host:mac');
  });
});

describe('AC3 — host isolation: a valid token for host X can only update host X', () => {
  it('TOKEN_MAC beat does not touch a pre-existing host:vm record', async () => {
    const vmSeed = JSON.stringify({ v: 1, received_at: '2026-09-17T00:00:00Z', seeded: 'vm-untouched' });
    const kv = createMockKV({ 'host:vm': vmSeed });
    const env = makeEnv({ STATUS: kv });

    const res = await worker.fetch(beatRequest({ body: validPayload(), token: TOKEN_MAC }), env, {});

    expect(res.status).toBe(204);
    expect(kv._dump()['host:vm']).toBe(vmSeed); // byte-identical: untouched
  });

  it('the host label comes from which secret matched, never from the request body', async () => {
    // Body claims to be "vm"; token is TOKEN_MAC. Per design (#4 §2/§5): label = which secret
    // matched, body content is never trusted for the label.
    const env = makeEnv();
    const payload = validPayload({ host: 'vm' }); // sanitise-by-reconstruction should drop this key too
    const res = await worker.fetch(beatRequest({ body: payload, token: TOKEN_MAC }), env, {});

    expect(res.status).toBe(204);
    const stored = env.STATUS._dump();
    expect(stored).toHaveProperty('host:mac');
    expect(stored).not.toHaveProperty('host:vm');
  });
});

describe('AC4 — malformed / oversized requests', () => {
  it('returns 400 for unparsable JSON', async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      beatRequest({ body: '{not valid json', token: TOKEN_MAC }),
      env,
      {}
    );
    expect(res.status).toBe(400);
    expect(env.STATUS._calls().put).toBe(0);
  });

  it('returns 400 for v !== 1', async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      beatRequest({ body: validPayload({ v: 2 }), token: TOKEN_MAC }),
      env,
      {}
    );
    expect(res.status).toBe(400);
  });

  it('returns 400 for more than 20 runs', async () => {
    const env = makeEnv();
    const runs = Array.from({ length: 21 }, (_, i) => ({
      repo: 'project-a',
      issue: i + 1,
      state: 'running',
      stage: 'test-writer',
      marker: 'TESTS WRITTEN',
      started_at: '2026-09-17T18:00:00Z',
      last_activity_at: '2026-09-17T18:00:00Z',
      restarts: 0,
    }));
    const res = await worker.fetch(
      beatRequest({ body: validPayload({ runs }), token: TOKEN_MAC }),
      env,
      {}
    );
    expect(res.status).toBe(400);
  });

  // #62 AC3: the cap is now 128 KB (131072). Edge tested at cap-1 / cap / cap+1.
  it('accepts a body of exactly 131071 bytes (one under the 128 KB cap)', async () => {
    const env = makeEnv();
    const body = sizedBeatBody(131071);
    const res = await worker.fetch(beatRequest({ body, token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
  });

  it('accepts a body of exactly 131072 bytes (the cap itself, not yet "over")', async () => {
    const env = makeEnv();
    const body = sizedBeatBody(131072);
    const res = await worker.fetch(beatRequest({ body, token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
  });

  it('returns 413 for a body of exactly 131073 bytes (one byte over the 128 KB cap)', async () => {
    const env = makeEnv();
    const body = sizedBeatBody(131073);
    const res = await worker.fetch(beatRequest({ body, token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(413);
    expect(env.STATUS._calls().put).toBe(0);
  });
});

describe('POST /beat — method and headers', () => {
  it('returns 405 for GET /beat', async () => {
    const env = makeEnv();
    const res = await worker.fetch(
      new Request('https://status.example.workers.dev/beat', { method: 'GET' }),
      env,
      {}
    );
    expect(res.status).toBe(405);
  });

  it('204 success has an empty body and one put() call', async () => {
    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body: validPayload(), token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
    const text = await res.text();
    expect(text).toBe('');
    expect(env.STATUS._calls().put).toBe(1);
  });

  it('never sends Access-Control-Allow-Origin on /beat', async () => {
    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body: validPayload(), token: TOKEN_MAC }), env, {});
    expect(res.headers.get('Access-Control-Allow-Origin')).toBeNull();
  });

  it('401 response also has no Access-Control-Allow-Origin', async () => {
    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body: validPayload(), token: null }), env, {});
    expect(res.headers.get('Access-Control-Allow-Origin')).toBeNull();
  });
});

describe('AC3/AC4 — storage shape: stored value is the validated payload plus received_at', () => {
  it('stores received_at set by the Worker, not trusted from sent_at', async () => {
    const env = makeEnv();
    const res = await worker.fetch(beatRequest({ body: validPayload(), token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
    const stored = JSON.parse(env.STATUS._dump()['host:mac']);
    expect(stored).toHaveProperty('received_at');
    expect(typeof stored.received_at).toBe('string');
  });
});

// ---- Issue #29: optional runs[].title / runs[].url through POST /beat -------------------------

describe('#29 — POST /beat with the optional ticket fields', () => {
  const GOOD_URL = 'https://github.com/example-owner/project-a/issues/42';

  async function beat(env, runOverrides) {
    const res = await worker.fetch(
      beatRequest({ body: validPayload({ runs: [validRun(runOverrides)] }), token: TOKEN_MAC }),
      env,
      {}
    );
    return res;
  }
  const storedRun = (env) => JSON.parse(env.STATUS._dump()['host:mac']).runs[0];

  it('a run with a valid title + url returns 204 and both are stored', async () => {
    const env = makeEnv();
    const res = await beat(env, { title: 'Fix login redirect', url: GOOD_URL });
    expect(res.status).toBe(204);
    expect(storedRun(env).title).toBe('Fix login redirect');
    expect(storedRun(env).url).toBe(GOOD_URL);
  });

  it('a legacy run (neither field) returns 204, stores neither key, and the page renders an empty Ticket cell', async () => {
    const env = makeEnv();
    const res = await beat(env, {});
    expect(res.status).toBe(204);
    const stored = storedRun(env);
    expect(stored).not.toHaveProperty('title');
    expect(stored).not.toHaveProperty('url');

    const home = await worker.fetch(getRequest('/'), env, {});
    const html = await home.text();
    const tbody = html.match(/<tbody>([\s\S]*?)<\/tbody>/)[1];
    const cells = [...tbody.matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((m) => m[1].trim());
    expect(cells).toHaveLength(7); // the new 7-column layout
    expect(cells[1]).toBe(''); // Ticket
    expect(html).not.toContain('href');
  });

  it('a bad url is dropped (204, run kept, title kept, no url stored)', async () => {
    const env = makeEnv();
    const res = await beat(env, { title: 'Fix login redirect', url: 'javascript:alert(1)' });
    expect(res.status).toBe(204);
    expect(storedRun(env).title).toBe('Fix login redirect'); // control: the title survived
    expect(storedRun(env)).not.toHaveProperty('url');
  });

  it('a non-string title is dropped (204, run kept, no title stored, valid url still stored)', async () => {
    const env = makeEnv();
    const res = await beat(env, { title: 123, url: GOOD_URL });
    expect(res.status).toBe(204);
    expect(storedRun(env).url).toBe(GOOD_URL); // control: url survived
    expect(storedRun(env)).not.toHaveProperty('title');
    expect(storedRun(env).issue).toBe(42);
  });

  it('a 200-char title is accepted (204) and stored as 140 chars', async () => {
    const env = makeEnv();
    const res = await beat(env, { title: 'a'.repeat(200), url: GOOD_URL });
    expect(res.status).toBe(204);
    expect(storedRun(env).title).toHaveLength(140);
  });

  it('GET / after a titled beat shows the title as a link to the issue', async () => {
    const env = makeEnv();
    await beat(env, { title: 'Fix login redirect', url: GOOD_URL });
    const home = await worker.fetch(getRequest('/'), env, {});
    const html = await home.text();
    expect(html).toContain(
      `<a href="${GOOD_URL}" target="_blank" rel="noopener noreferrer">Fix login redirect</a>`
    );
  });
});
