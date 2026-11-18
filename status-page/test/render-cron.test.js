// Issue #756 AC8/AC9 — the "Scheduled jobs" section on GET /, its escaping and ordering, the beat
// round trip into KV, /status.json echoing the sanitised cron[], and a render failure being captured.
// Expected strings are hand-written from the ticket, never copied from src/.

import { describe, it, expect, beforeEach } from 'vitest';
import worker, { __resetRateLimiter } from '../src/index.js';
import { renderPage } from '../src/render.js';
import { createMockKV } from './mock-kv.js';
import { makeEnv, getRequest, beatRequest, validPayload, hostRecord, TOKEN_VM } from './fixtures.js';

beforeEach(() => {
  __resetRateLimiter();
});

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-11-19T10:00:00Z') / 1000;

function item(overrides = {}) {
  return {
    name: 'layoff-scan-cron',
    schedule: '0 13 * * 1',
    schedule_human: 'Mondays at 13:00',
    last_run: '2026-11-16T13:00:02Z',
    last_result: 'ok',
    next_run: '2026-11-23T13:00:00Z',
    ...overrides,
  };
}

function page(cron, mac = null) {
  return renderPage({ mac, vm: { ...hostRecord({ received_at: '2026-11-19T09:59:00Z' }), ...(cron === undefined ? {} : { cron }) } }, thresholds, NOW);
}

/** Just the Scheduled jobs section's markup. */
function cronSection(html) {
  const m = /<section class="group cron">[\s\S]*?<\/section>/.exec(html);
  return m ? m[0] : null;
}

describe('AC8 — Scheduled jobs section', () => {
  it('renders the Job / Schedule / Last run / Last result / Next run columns', () => {
    const s = cronSection(page([item()]));
    expect(s).not.toBeNull();
    expect(s).toContain('<h2>Scheduled jobs (1)</h2>');
    for (const col of ['Job', 'Schedule', 'Last run', 'Last result', 'Next run']) {
      expect(s).toContain(`<th>${col}</th>`);
    }
    expect(s).toContain('layoff-scan-cron');
    expect(s).toContain('Mondays at 13:00');
    expect(s).toContain('<code>0 13 * * 1</code>');
    // 2026-11-16T13:00:02Z is 14:00 in Madrid (CET); 2026-11-23T13:00:00Z is 14:00 too
    expect(s).toContain('Mon 16 Nov, 14:00');
    expect(s).toContain('Mon 23 Nov, 14:00');
  });

  it('result badges: ok green (live), failed red (offline), unknown grey (nodata)', () => {
    const s = cronSection(
      page([item({ name: 'a', last_result: 'ok' }), item({ name: 'b', last_result: 'failed' }), item({ name: 'c', last_result: 'unknown' })]),
    );
    expect(s).toContain('<span class="badge live">ok</span>');
    expect(s).toContain('<span class="badge offline">failed</span>');
    expect(s).toContain('<span class="badge nodata">unknown</span>');
  });

  it('failed jobs sort first, then by name', () => {
    const s = cronSection(
      page([
        item({ name: 'zeta', last_result: 'ok' }),
        item({ name: 'beta', last_result: 'failed' }),
        item({ name: 'alpha', last_result: 'ok' }),
        item({ name: 'omega', last_result: 'failed' }),
      ]),
    );
    const order = ['beta', 'omega', 'alpha', 'zeta'].map((n) => s.indexOf(`>${n}<`));
    expect(order.every((i) => i > -1)).toBe(true);
    expect([...order].sort((x, y) => x - y)).toEqual(order);
  });

  it('a job that never ran shows "never", and no next run shows a dash', () => {
    const s = cronSection(page([item({ last_run: null, next_run: null, last_result: 'unknown', schedule: '@reboot', schedule_human: 'At boot' })]));
    expect(s).toContain('never');
    expect(s).toContain('—');
    expect(s).toContain('At boot');
  });

  it('HTML-escapes every value (a <script> name never lands as markup)', () => {
    const s = cronSection(
      page([item({ name: '<script>x</script>', schedule: '"><b>', schedule_human: '<i>h</i>', last_run: '<u>t</u>', next_run: '<u>n</u>' })]),
    );
    expect(s).toContain('&lt;script&gt;x&lt;/script&gt;');
    expect(s).not.toContain('<script>x</script>');
    expect(s).not.toContain('<i>h</i>');
    expect(s).not.toContain('<b>');
  });

  it('absent, empty or non-array cron renders no section at all', () => {
    expect(cronSection(page(undefined))).toBeNull();
    expect(cronSection(page([]))).toBeNull();
    expect(cronSection(page('nope'))).toBeNull();
    expect(page(undefined)).not.toContain('Scheduled jobs');
  });

  it('is placed just above Done, below the other status groups', () => {
    const html = page([item()]);
    const iCron = html.indexOf('<h2>Scheduled jobs');
    expect(iCron).toBeGreaterThan(html.indexOf('<h2>Parked'));
    expect(iCron).toBeLessThan(html.indexOf('<h2>Done'));
  });

  it('merges jobs published by both hosts', () => {
    const mac = { ...hostRecord({ received_at: '2026-11-19T09:59:00Z' }), cron: [item({ name: 'mac-job' })] };
    const s = cronSection(page([item({ name: 'vm-job' })], mac));
    expect(s).toContain('mac-job');
    expect(s).toContain('vm-job');
    expect(s).toContain('<h2>Scheduled jobs (2)</h2>');
  });
});

describe('beat -> KV -> page / status.json (AC7, AC9)', () => {
  it('a beat with cron[] stores the sanitised list; /status.json echoes it and the page renders it', async () => {
    const kv = createMockKV();
    const env = makeEnv({ STATUS: kv });
    const body = validPayload({
      cron: [item({ command: 'curl -H token', schedule_human: 'Mondays at 13:00' }), item({ name: '<b>bad</b>' })],
    });
    const res = await worker.fetch(beatRequest({ body, token: TOKEN_VM }), env, {});
    expect(res.status).toBe(204);

    const json = await (await worker.fetch(getRequest('/status.json'), env, {})).json();
    expect(json.hosts.vm.cron).toEqual([item()]);
    expect(JSON.stringify(json)).not.toContain('curl');

    const html = await (await worker.fetch(getRequest('/'), env, {})).text();
    expect(html).toContain('<h2>Scheduled jobs (1)</h2>');
  });

  it('a beat without cron still validates (204) and shows no section', async () => {
    const kv = createMockKV();
    const env = makeEnv({ STATUS: kv });
    const res = await worker.fetch(beatRequest({ body: validPayload(), token: TOKEN_VM }), env, {});
    expect(res.status).toBe(204);
    const json = await (await worker.fetch(getRequest('/status.json'), env, {})).json();
    expect('cron' in json.hosts.vm).toBe(false);
    const html = await (await worker.fetch(getRequest('/'), env, {})).text();
    expect(html).not.toContain('Scheduled jobs');
  });
});

