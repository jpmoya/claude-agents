// POST /beat — AC3 (auth + host isolation) and the size/format edges of AC4, exercised through
// the exported `fetch` handler with a hand-written mock KV. Expected status codes/headers are
// taken verbatim from the routes table in issue #11 / #4 §5.

import { describe, it, expect, beforeEach } from 'vitest';
import worker, { __resetRateLimiter } from '../src/index.js';
import { createMockKV } from './mock-kv.js';
import { makeEnv, validPayload, beatRequest, sizedBeatBody, TOKEN_MAC, TOKEN_VM } from './fixtures.js';

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

  // The 16 KB cap is exercised at the real edge (16383/16384/16385 bytes, measured with
  // TextEncoder in sizedBeatBody, not an arbitrarily-small/large pair) per test-reviewer
  // finding 2 on the first round. "Over 16 KB" per the routes table means the cap itself
  // (16384) succeeds and one byte past it is rejected.
  it('accepts a body of exactly 16383 bytes (one under the 16 KB cap)', async () => {
    const env = makeEnv();
    const body = sizedBeatBody(16383);
    const res = await worker.fetch(beatRequest({ body, token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
  });

  it('accepts a body of exactly 16384 bytes (the cap itself, not yet "over")', async () => {
    const env = makeEnv();
    const body = sizedBeatBody(16384);
    const res = await worker.fetch(beatRequest({ body, token: TOKEN_MAC }), env, {});
    expect(res.status).toBe(204);
  });

  it('returns 413 for a body of exactly 16385 bytes (one byte over the 16 KB cap)', async () => {
    const env = makeEnv();
    const body = sizedBeatBody(16385);
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
