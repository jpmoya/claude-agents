// POST /backlog-priority — the authenticated write path the Backlog priority section's
// &uarr;/&darr; buttons call (src/render.js's BACKLOG_REORDER_SCRIPT) to save a new order
// without a terminal. Covers src/backlog-priority.js's key validation and GitHub API calls, and
// index.js's auth gate / wiring (same requireSession check as GET /, /pipelines, /status.json).

import { describe, it, expect, vi, afterEach } from 'vitest';
import worker from '../src/index.js';
import { isValidKeyList } from '../src/backlog-priority.js';
import { makeEnv, getRequest, validSessionCookie } from './fixtures.js';

function postRequest(path, { body, cookie = validSessionCookie(), method = 'POST' } = {}) {
  const headers = { 'CF-Connecting-IP': '203.0.113.10', 'Content-Type': 'application/json' };
  if (cookie) headers['Cookie'] = `session=${cookie}`;
  return new Request(`https://status.example.workers.dev${path}`, {
    method,
    headers,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

describe('backlog-priority.js — isValidKeyList', () => {
  it('accepts a non-empty array of well-formed "owner/repo#issue" strings', () => {
    expect(isValidKeyList(['jpmoya/claude-agents#1', 'example-owner/project-a#30'])).toBe(true);
  });

  it.each([
    [undefined],
    [null],
    ['not-an-array'],
    [[]],
    [['missing-hash']],
    [['owner/repo#']],
    [['owner/repo#abc']],
    [[1, 2]],
    [Array.from({ length: 201 }, (_v, i) => `owner/repo#${i}`)],
  ])('rejects %j', (bad) => {
    expect(isValidKeyList(bad)).toBe(false);
  });
});

describe('POST /backlog-priority', () => {
  let fetchSpy;
  afterEach(() => fetchSpy && fetchSpy.mockRestore());

  const KEYS = ['example-owner/project-a#30', 'example-owner/project-a#20'];

  function mockGitHub({ existingIssue = 7, patchStatus = 200 } = {}) {
    const calls = [];
    fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (url, init = {}) => {
      const href = typeof url === 'string' ? url : url.url;
      calls.push({ href, method: init.method || 'GET' });
      if (href.includes('/issues?labels=')) {
        return new Response(JSON.stringify(existingIssue ? [{ number: existingIssue }] : []), { status: 200 });
      }
      if (init.method === 'POST' && href.endsWith('/issues')) {
        return new Response(JSON.stringify({ number: 99 }), { status: 201 });
      }
      if (init.method === 'PATCH') {
        return new Response(JSON.stringify({ number: existingIssue || 99 }), { status: patchStatus });
      }
      throw new Error(`unexpected fetch: ${href}`);
    });
    return calls;
  }

  it('requires sign-in: no session cookie redirects to /login', async () => {
    const env = makeEnv({ GITHUB_TOKEN: 'test-gh-token' });
    const res = await worker.fetch(postRequest('/backlog-priority', { body: { keys: KEYS }, cookie: null }), env, {});
    expect(res.status).toBe(302);
    expect(res.headers.get('Location')).toBe('/login');
  });

  it('returns 405 for GET', async () => {
    const env = makeEnv({ GITHUB_TOKEN: 'test-gh-token' });
    const res = await worker.fetch(getRequest('/backlog-priority'), env, {});
    expect(res.status).toBe(405);
  });

  it('503s when GITHUB_TOKEN is not configured, without calling GitHub', async () => {
    mockGitHub();
    const env = makeEnv(); // no GITHUB_TOKEN
    const res = await worker.fetch(postRequest('/backlog-priority', { body: { keys: KEYS } }), env, {});
    expect(res.status).toBe(503);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('400 on a malformed body or an empty/invalid key list', async () => {
    const env = makeEnv({ GITHUB_TOKEN: 'test-gh-token' });
    const bad = ['not json{', { keys: [] }, { keys: 'nope' }, { keys: ['bad-key'] }, {}];
    for (const body of bad) {
      const res = await worker.fetch(postRequest('/backlog-priority', { body }), env, {});
      expect(res.status).toBe(400);
    }
  });

  it('a signed-in, authorized request with a valid key list writes the registry issue and returns 204', async () => {
    const calls = mockGitHub({ existingIssue: 7 });
    const env = makeEnv({ GITHUB_TOKEN: 'test-gh-token' });
    const res = await worker.fetch(postRequest('/backlog-priority', { body: { keys: KEYS } }), env, {});
    expect(res.status).toBe(204);
    const patchCall = calls.find((c) => c.method === 'PATCH');
    expect(patchCall).toBeTruthy();
    expect(patchCall.href).toBe('https://api.github.com/repos/jpmoya/claude-agents/issues/7');
    // never a POST (create) when an issue already exists
    expect(calls.some((c) => c.method === 'POST')).toBe(false);
  });

  it('creates the registry issue first when none exists yet, then patches it', async () => {
    const calls = mockGitHub({ existingIssue: null });
    const env = makeEnv({ GITHUB_TOKEN: 'test-gh-token' });
    const res = await worker.fetch(postRequest('/backlog-priority', { body: { keys: KEYS } }), env, {});
    expect(res.status).toBe(204);
    expect(calls.some((c) => c.method === 'POST' && c.href.endsWith('/issues'))).toBe(true);
    const patchCall = calls.find((c) => c.method === 'PATCH');
    expect(patchCall.href).toBe('https://api.github.com/repos/jpmoya/claude-agents/issues/99');
  });

  it('502s when GitHub rejects the write, and never crashes', async () => {
    mockGitHub({ existingIssue: 7, patchStatus: 500 });
    const env = makeEnv({ GITHUB_TOKEN: 'test-gh-token' });
    const res = await worker.fetch(postRequest('/backlog-priority', { body: { keys: KEYS } }), env, {});
    expect(res.status).toBe(502);
  });

  it('carries X-Robots-Tag: noindex like every other response', async () => {
    const env = makeEnv(); // no GITHUB_TOKEN -> 503, cheapest path to exercise
    const res = await worker.fetch(postRequest('/backlog-priority', { body: { keys: KEYS } }), env, {});
    expect(res.headers.get('X-Robots-Tag')).toBe('noindex');
  });
});

