// GET /jobs (the Scheduled jobs tab, moved off `/` — follow-up to issue #756): route, auth and nav wiring.
// Same shape as ci-route.test.js's route/nav cases. Expected values are hand-written.

import { describe, it, expect, beforeEach } from 'vitest';
import worker, { __resetRateLimiter } from '../src/index.js';
import { PAGE_REFRESH_SECS } from '../src/render.js';
import { createMockKV } from './mock-kv.js';
import { makeEnv, getRequest, hostRecord } from './fixtures.js';

beforeEach(() => {
  __resetRateLimiter();
});

const envWithJob = () =>
  makeEnv({
    STATUS: createMockKV({
      'host:vm': JSON.stringify({
        ...hostRecord({ received_at: '2026-11-19T09:59:00Z' }),
        cron: [{ name: 'layoff-scan-cron', schedule: '0 13 * * 1', schedule_human: 'Mondays at 13:00', last_run: null, last_result: 'unknown', next_run: null }],
      }),
    }),
  });

describe('GET /jobs — route', () => {
  it('returns 200 text/html with noindex when signed in', async () => {
    const res = await worker.fetch(getRequest('/jobs'), envWithJob(), {});
    expect(res.status).toBe(200);
    expect(res.headers.get('Content-Type')).toMatch(/text\/html/);
    expect(res.headers.get('X-Robots-Tag')).toBe('noindex');
    const html = await res.text();
    expect(html).toContain('<h1>Scheduled jobs</h1>');
    expect(html).toContain('layoff-scan-cron');
  });

  it('with no host data at all it still renders (empty-state line, nav intact)', async () => {
    const res = await worker.fetch(getRequest('/jobs'), makeEnv(), {});
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain('no scheduled-job data yet');
    expect(html).toContain('href="/jobs"');
  });

  it('no session cookie redirects (302) to /login, carrying noindex and no job data', async () => {
    const res = await worker.fetch(getRequest('/jobs', { cookie: null }), envWithJob(), {});
    expect(res.status).toBe(302);
    expect(res.headers.get('Location')).toBe('/login');
    expect(res.headers.get('X-Robots-Tag')).toBe('noindex');
    expect(await res.text()).not.toContain('layoff-scan-cron');
  });

  it('POST /jobs -> 405 with noindex', async () => {
    const res = await worker.fetch(getRequest('/jobs', { method: 'POST' }), makeEnv(), {});
    expect(res.status).toBe(405);
    expect(res.headers.get('X-Robots-Tag')).toBe('noindex');
  });

  it('carries the same auto-refresh meta tag as the other pages', async () => {
    const html = await (await worker.fetch(getRequest('/jobs'), makeEnv(), {})).text();
    expect(html).toContain(`<meta http-equiv="refresh" content="${PAGE_REFRESH_SECS}">`);
  });
});

describe('nav — five tabs, Jobs between CI and Learnings, current page marked', () => {
  it.each([
    ['/', 'Status'],
    ['/pipelines', 'Pipelines'],
    ['/ci', 'CI'],
    ['/jobs', 'Jobs'],
    ['/learnings', 'Learnings'],
  ])('%s lists Status | Pipelines | CI | Jobs | Learnings and marks only %s as current', async (path, current) => {
    const html = await (await worker.fetch(getRequest(path), makeEnv(), {})).text();
    const nav = /<nav>[\s\S]*?<\/nav>/.exec(html)[0];
    const labels = [...nav.matchAll(/<a[^>]*>([^<]+)<\/a>/g)].map((m) => m[1]);
    expect(labels).toEqual(['Status', 'Pipelines', 'CI', 'Jobs', 'Learnings']);
    expect(nav).toContain('<a href="/jobs"');
    const marked = [...nav.matchAll(/<a[^>]*aria-current="page"[^>]*>([^<]+)<\/a>/g)].map((m) => m[1]);
    expect(marked).toEqual([current]);
  });
});
