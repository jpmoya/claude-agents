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

const encoder = new TextEncoder();

/**
 * Builds a valid v1 heartbeat payload serialised to exactly `targetBytes` UTF-8 bytes (measured
 * with TextEncoder, not JS string length), via an unknown top-level `padding` field. That field
 * is dropped by sanitise-by-reconstruction (validate.js), so a case accepted at exactly the cap
 * also proves the size gate reads the raw request body, not the sanitised value. Padding is
 * ASCII, so string length and UTF-8 byte length coincide.
 */
export function sizedBeatBody(targetBytes, overrides = {}) {
  const base = JSON.stringify(validPayload({ ...overrides, padding: '' }));
  const baseBytes = encoder.encode(base).length;
  const deficit = targetBytes - baseBytes;
  if (deficit < 0) {
    throw new Error(
      `sizedBeatBody: targetBytes ${targetBytes} is smaller than the unpadded payload (${baseBytes} bytes)`
    );
  }
  const padded = JSON.stringify(validPayload({ ...overrides, padding: 'x'.repeat(deficit) }));
  const actualBytes = encoder.encode(padded).length;
  if (actualBytes !== targetBytes) {
    throw new Error(
      `sizedBeatBody: size calculation error, got ${actualBytes} bytes, wanted ${targetBytes}`
    );
  }
  return padded;
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

/** One valid completed[] item (issue #51), per Expected Behavior 6. */
export function validCompleted(overrides = {}) {
  return {
    repo: 'project-a',
    issue: 42,
    title: 'Fix login redirect',
    url: 'https://github.com/example-owner/project-a/issues/42',
    closed_at: '2026-09-17T18:00:00Z',
    marker: 'DEPLOYED',
    ...overrides,
  };
}

// ---- issue #62 builders (placeholder repos only; expected values hand-written from the ticket) ----

/** One valid staging[] item (#62 Expected Behavior: {repo, issue, title?, url?, updated_at?}). */
export function validStagingItem(overrides = {}) {
  return {
    repo: 'project-a',
    issue: 7,
    title: 'Staged ticket',
    url: 'https://github.com/example-owner/project-a/issues/7',
    updated_at: '2026-09-20T10:00:00Z',
    ...overrides,
  };
}

/** One valid approved[] item — same shape as staging[]. */
export function validApprovedItem(overrides = {}) {
  return {
    repo: 'project-a',
    issue: 8,
    title: 'Approved ticket',
    url: 'https://github.com/example-owner/project-a/issues/8',
    updated_at: '2026-09-20T11:00:00Z',
    ...overrides,
  };
}

/** A stored KV host record (validated payload + received_at). Keys left undefined are omitted (today's shape). */
export function hostRecord({ runs = [], completed, staging, approved, received_at = '2026-09-21T12:00:00Z' } = {}) {
  const rec = {
    v: 1,
    sent_at: received_at,
    received_at,
    supervisor_last_tick: received_at,
    capacity: { running: 1, max: 3, queued: 0 },
    runs,
  };
  if (completed !== undefined) rec.completed = completed;
  if (staging !== undefined) rec.staging = staging;
  if (approved !== undefined) rec.approved = approved;
  return rec;
}
