// Issue #756 AC12 — a render failure is captured with release / environment / route tags only and answered
// with a bare 500. Since the Jobs-tab follow-up the Scheduled jobs section lives on GET /jobs, so that is the
// route whose failure is pinned here; GET / keeps its own capture and no longer renders the section. Same
// mocking pattern as pipelines.test.js: capture.js is mocked to observe the call, render.js's renderPage and
// renderJobsPage are pass-through spies that one test makes throw.

import { describe, it, expect, beforeEach, vi } from 'vitest';

vi.mock('../src/capture.js', () => ({ captureError: vi.fn(async () => {}) }));
vi.mock('../src/render.js', async (importOriginal) => {
  const orig = await importOriginal();
  return { ...orig, renderPage: vi.fn(orig.renderPage), renderJobsPage: vi.fn(orig.renderJobsPage) };
});

import worker, { __resetRateLimiter } from '../src/index.js';
import * as render from '../src/render.js';
import { captureError } from '../src/capture.js';
import { createMockKV } from './mock-kv.js';
import { makeEnv, getRequest, hostRecord } from './fixtures.js';

beforeEach(() => {
  __resetRateLimiter();
  captureError.mockClear();
});

const cronRecord = () =>
  JSON.stringify({
    ...hostRecord({ received_at: '2026-11-19T09:59:00Z' }),
    cron: [{ name: 'layoff-scan-cron', schedule: '0 13 * * 1', schedule_human: 'Mondays at 13:00', last_run: null, last_result: 'unknown', next_run: null }],
  });

describe('AC12 — render failure on /jobs is captured', () => {
  it('500 + noindex, the error body hides the cause, captureError gets release/environment/route only', async () => {
    render.renderJobsPage.mockImplementationOnce(() => {
      throw new Error('boom');
    });
    const env = makeEnv({ STATUS: createMockKV({ 'host:vm': cronRecord() }), RELEASE: 'abc1234def', ENVIRONMENT: 'production' });
    const res = await worker.fetch(getRequest('/jobs'), env, {});
    expect(res.status).toBe(500);
    expect(res.headers.get('X-Robots-Tag')).toBe('noindex');
    const body = await res.text();
    expect(body).toBe('Internal error');
    expect(captureError).toHaveBeenCalledTimes(1);
    const [err, tags] = captureError.mock.calls[0];
    expect(err).toBeInstanceOf(Error);
    expect(tags).toEqual({ release: 'abc1234def', environment: 'production', route: '/jobs' });
  });

  it('a healthy render does not capture anything and shows the section', async () => {
    const env = makeEnv({ STATUS: createMockKV({ 'host:vm': cronRecord() }) });
    const res = await worker.fetch(getRequest('/jobs'), env, {});
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('Scheduled jobs (1)');
    expect(captureError).not.toHaveBeenCalled();
  });

  it('GET / still captures its own failure under route "/" and no longer renders the section', async () => {
    render.renderPage.mockImplementationOnce(() => {
      throw new Error('boom');
    });
    const env = makeEnv({ STATUS: createMockKV({ 'host:vm': cronRecord() }), RELEASE: 'abc1234def', ENVIRONMENT: 'production' });
    const failed = await worker.fetch(getRequest('/'), env, {});
    expect(failed.status).toBe(500);
    expect(captureError.mock.calls[0][1]).toEqual({ release: 'abc1234def', environment: 'production', route: '/' });

    const ok = await worker.fetch(getRequest('/'), env, {});
    expect(ok.status).toBe(200);
    expect(await ok.text()).not.toContain('Scheduled jobs');
  });
});
