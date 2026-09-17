// POST /beat rate limiting — design (#4 §5): "429 (> 60 req/min per CF-Connecting-IP)", a
// module-scope Map, fixed 60s window, bounded eviction, exported reset for test isolation.
// Uses fake timers so the window boundary is deterministic (no real-time flakiness).

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import worker, { __resetRateLimiter } from '../src/index.js';
import { makeEnv, validPayload, beatRequest, TOKEN_MAC } from './fixtures.js';

beforeEach(() => {
  __resetRateLimiter();
  vi.useFakeTimers();
  vi.setSystemTime(new Date('2026-09-17T18:00:00Z'));
});

afterEach(() => {
  vi.useRealTimers();
});

describe('rate limit: > 60 req/min per CF-Connecting-IP -> 429', () => {
  it('accepts exactly 60 requests from the same IP inside one window', async () => {
    const env = makeEnv();
    for (let i = 0; i < 60; i++) {
      const res = await worker.fetch(
        beatRequest({ body: validPayload(), token: TOKEN_MAC, ip: '203.0.113.5' }),
        env,
        {}
      );
      expect(res.status).toBe(204);
    }
  });

  it('rejects the 61st request from the same IP inside one window with 429', async () => {
    const env = makeEnv();
    for (let i = 0; i < 60; i++) {
      await worker.fetch(
        beatRequest({ body: validPayload(), token: TOKEN_MAC, ip: '203.0.113.5' }),
        env,
        {}
      );
    }
    const res = await worker.fetch(
      beatRequest({ body: validPayload(), token: TOKEN_MAC, ip: '203.0.113.5' }),
      env,
      {}
    );
    expect(res.status).toBe(429);
  });

  it('a different CF-Connecting-IP is unaffected by another IP hitting its cap', async () => {
    const env = makeEnv();
    for (let i = 0; i < 61; i++) {
      await worker.fetch(
        beatRequest({ body: validPayload(), token: TOKEN_MAC, ip: '203.0.113.5' }),
        env,
        {}
      );
    }
    const res = await worker.fetch(
      beatRequest({ body: validPayload(), token: TOKEN_MAC, ip: '198.51.100.9' }),
      env,
      {}
    );
    expect(res.status).toBe(204);
  });

  it('the window is fixed, not a permanent ban: the same IP is accepted again after 60s', async () => {
    const env = makeEnv();
    for (let i = 0; i < 61; i++) {
      await worker.fetch(
        beatRequest({ body: validPayload(), token: TOKEN_MAC, ip: '203.0.113.5' }),
        env,
        {}
      );
    }
    vi.setSystemTime(new Date('2026-09-17T18:01:01Z')); // > 60s later
    const res = await worker.fetch(
      beatRequest({ body: validPayload(), token: TOKEN_MAC, ip: '203.0.113.5' }),
      env,
      {}
    );
    expect(res.status).toBe(204);
  });
});
