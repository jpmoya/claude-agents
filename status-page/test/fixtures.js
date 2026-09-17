// test/fixtures.js — shared valid payload/env builders. Expected values are hand-derived from
// the frozen v1 payload contract (#4 §5) and the validation table in issue #11, never copied
// from src/.

import { createMockKV } from './mock-kv.js';

// Placeholder test-only bearer tokens — never real secrets, obviously fake, used only in this
// in-repo test fixture (AC17: no real token/secret value appears in the repo).
export const TOKEN_MAC = 'test-token-mac-0000000000000000';
export const TOKEN_VM = 'test-token-vm-0000000000000000';

export function makeEnv(overrides = {}) {
  return {
    STATUS: createMockKV(),
    TOKEN_MAC,
    TOKEN_VM,
    ...overrides,
  };
}

/** One valid run object, per the runs[] field table. */
export function validRun(overrides = {}) {
  return {
    repo: 'project-a',
    issue: 42,
    state: 'running',
    stage: 'test-writer',
    marker: 'TESTS WRITTEN',
    started_at: '2026-09-17T18:00:00Z',
    last_activity_at: '2026-09-17T18:05:00Z',
    restarts: 0,
    ...overrides,
  };
}

/** A full, valid v1 heartbeat payload. */
export function validPayload(overrides = {}) {
  return {
    v: 1,
    sent_at: '2026-09-17T18:05:30Z',
    supervisor_last_tick: '2026-09-17T18:04:00Z',
    capacity: { running: 1, max: 3, queued: 0 },
    runs: [validRun()],
    ...overrides,
  };
}

export function beatRequest({
  body,
  token = TOKEN_MAC,
  ip = '203.0.113.10',
  headers = {},
  method = 'POST',
  url = 'https://status.example.workers.dev/beat',
} = {}) {
  const h = new Headers({
    'Content-Type': 'application/json',
    'CF-Connecting-IP': ip,
    ...headers,
  });
  if (token !== null) h.set('Authorization', `Bearer ${token}`);
  return new Request(url, {
    method,
    headers: h,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

export function getRequest(path, { ip = '203.0.113.10', method = 'GET' } = {}) {
  return new Request(`https://status.example.workers.dev${path}`, {
    method,
    headers: { 'CF-Connecting-IP': ip },
  });
}
