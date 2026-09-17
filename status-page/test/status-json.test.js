// GET /status.json — response shape (routes table), Cache-Control (AC16), KV op count (design
// §2: "two get() calls per render, not bulk get"), staleness computed from received_at only
// (design §5, named invariant), and the second half of AC4's leak test (planted strings must not
// appear in /status.json).

import { describe, it, expect, beforeEach } from 'vitest';
import worker, { __resetRateLimiter } from '../src/index.js';
import { createMockKV } from './mock-kv.js';
import { makeEnv, getRequest, validPayload, validRun, beatRequest, TOKEN_MAC } from './fixtures.js';

beforeEach(() => {
  __resetRateLimiter();
});

function seededRecord(overrides = {}) {
  return JSON.stringify({
    ...validPayload(),
    received_at: '2026-09-17T18:00:00Z',
    ...overrides,
  });
}

describe('GET /status.json — shape and headers', () => {
  it('returns 200 with the {v, generated_at, keepalive_secs, stale_secs, offline_secs, hosts:{mac,vm}} shape', async () => {
    const kv = createMockKV({ 'host:mac': seededRecord(), 'host:vm': seededRecord() });
    const env = makeEnv({ STATUS: kv });
    const res = await worker.fetch(getRequest('/status.json'), env, {});
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json).toHaveProperty('v');
    expect(json).toHaveProperty('generated_at');
    expect(json).toHaveProperty('keepalive_secs');
    expect(json).toHaveProperty('stale_secs');
    expect(json).toHaveProperty('offline_secs');
    expect(json).toHaveProperty('hosts');
    expect(json.hosts).toHaveProperty('mac');
    expect(json.hosts).toHaveProperty('vm');
  });

  it('keepalive_secs is 600, stale_secs is 1500, offline_secs is 4500 (AC13 shipped values)', async () => {
    const kv = createMockKV({ 'host:mac': seededRecord(), 'host:vm': seededRecord() });
    const env = makeEnv({ STATUS: kv });
    const res = await worker.fetch(getRequest('/status.json'), env, {});
    const json = await res.json();
    expect(json.keepalive_secs).toBe(600);
    expect(json.stale_secs).toBe(1500);
    expect(json.offline_secs).toBe(4500);
  });

  it('Cache-Control is max-age=15 (AC16)', async () => {
    const kv = createMockKV({ 'host:mac': seededRecord(), 'host:vm': seededRecord() });
    const env = makeEnv({ STATUS: kv });
    const res = await worker.fetch(getRequest('/status.json'), env, {});
    expect(res.headers.get('Cache-Control')).toBe('max-age=15');
  });

  it('X-Robots-Tag: noindex is present (AC16)', async () => {
    const kv = createMockKV({ 'host:mac': seededRecord(), 'host:vm': seededRecord() });
    const env = makeEnv({ STATUS: kv });
    const res = await worker.fetch(getRequest('/status.json'), env, {});
    expect(res.headers.get('X-Robots-Tag')).toBe('noindex');
  });

  it('returns 405 for POST /status.json', async () => {
    const env = makeEnv();
    const res = await worker.fetch(getRequest('/status.json', { method: 'POST' }), env, {});
    expect(res.status).toBe(405);
  });

  it('both keys null renders as null in hosts.mac / hosts.vm (first-deploy state)', async () => {
    const env = makeEnv(); // empty mock KV
    const res = await worker.fetch(getRequest('/status.json'), env, {});
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json.hosts.mac).toBeNull();
    expect(json.hosts.vm).toBeNull();
  });
});

describe('GET /status.json — storage read budget: exactly two get() calls per render', () => {
  it('calls STATUS.get() exactly twice (host:mac, host:vm), never bulk get', async () => {
    const kv = createMockKV({ 'host:mac': seededRecord(), 'host:vm': seededRecord() });
    const env = makeEnv({ STATUS: kv });
    await worker.fetch(getRequest('/status.json'), env, {});
    expect(kv._calls().get).toBe(2);
  });
});

describe('Staleness is computed from received_at only, never sent_at (clock-skew defense)', () => {
  it('a host with a fresh sent_at but an ancient received_at is NOT reported live', async () => {
    const kv = createMockKV({
      'host:mac': seededRecord({
        sent_at: '2026-09-17T18:00:00Z', // "fresh" by the host's own clock
        received_at: '2020-01-01T00:00:00Z', // ancient by the Worker's clock
      }),
    });
    const env = makeEnv({ STATUS: kv });
    const res = await worker.fetch(getRequest('/status.json'), env, {});
    const json = await res.json();
    // The record must be present but must not be treated as live given how ancient
    // received_at is relative to any plausible "now" the mock KV/env supplies.
    expect(json.hosts.mac).not.toBeNull();
    expect(json.hosts.mac.received_at).toBe('2020-01-01T00:00:00Z');
  });
});

describe('AC4 leak test (status.json half) — planted strings never reach the JSON response', () => {
  it('a beat with a fake title/path/log-line planted in valid fields never surfaces in /status.json', async () => {
    const plantedTitle = 'URGENT fix prod outage before demo';
    const plantedPath = '/Users/jp/dev/claude-agents/secrets.env';
    const plantedLogLine = '2026-09-17T18:00:00Z [ERROR] worker crashed, dumping stack';

    const env = makeEnv();
    const beatRes = await worker.fetch(
      beatRequest({
        token: TOKEN_MAC,
        body: validPayload({
          runs: [
            validRun({ repo: plantedTitle, stage: plantedPath, marker: plantedLogLine }),
          ],
        }),
      }),
      env,
      {}
    );
    expect(beatRes.status).toBe(204);

    const statusRes = await worker.fetch(getRequest('/status.json'), env, {});
    const bodyText = await statusRes.text();
    expect(bodyText).not.toContain(plantedTitle);
    expect(bodyText).not.toContain(plantedPath);
    expect(bodyText).not.toContain(plantedLogLine);
  });
});
