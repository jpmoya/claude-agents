// Issue #756 AC8/AC9 (+ the Jobs-tab follow-up) — the "Scheduled jobs" section on GET /jobs (moved off `/`):
// its columns, escaping and ordering, the "What it does" and "Host" columns, the beat round trip into KV,
// and /status.json echoing the sanitised cron[]. Expected strings are hand-written from the ticket, never
// copied from src/.

import { describe, it, expect, beforeEach } from 'vitest';
import worker, { __resetRateLimiter } from '../src/index.js';
import { renderPage, renderJobsPage } from '../src/render.js';
import { createMockKV } from './mock-kv.js';
import { makeEnv, getRequest, beatRequest, validPayload, hostRecord, TOKEN_VM, TOKEN_MAC } from './fixtures.js';

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

function hosts(cron, mac = null) {
  return { mac, vm: { ...hostRecord({ received_at: '2026-11-19T09:59:00Z' }), ...(cron === undefined ? {} : { cron }) } };
}

/** The whole /jobs document. */
function page(cron, mac = null) {
  return renderJobsPage(hosts(cron, mac));
}

/** Just the Scheduled jobs section's markup. */
function cronSection(html) {
  const m = /<section class="group cron">[\s\S]*?<\/section>/.exec(html);
  return m ? m[0] : null;
}

describe('AC8 — Scheduled jobs section on /jobs', () => {
  it('renders the Job / What it does / Host / Schedule / Last run / Last result / Next run columns', () => {
    const s = cronSection(page([item()]));
    expect(s).not.toBeNull();
    expect(s).toContain('<h2>Scheduled jobs (1)</h2>');
    for (const col of ['Job', 'What it does', 'Host', 'Schedule', 'Last run', 'Last result', 'Next run']) {
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
      page([
        item({
          name: '<script>x</script>',
          schedule: '"><b>',
          schedule_human: '<i>h</i>',
          last_run: '<u>t</u>',
          next_run: '<u>n</u>',
          description: '<img src=x onerror=alert(1)>',
          source: '<b>cron</b>',
        }),
      ]),
    );
    expect(s).toContain('&lt;script&gt;x&lt;/script&gt;');
    expect(s).toContain('&lt;img src=x onerror=alert(1)&gt;');
    expect(s).not.toContain('<script>x</script>');
    expect(s).not.toContain('<i>h</i>');
    expect(s).not.toContain('<b>');
    expect(s).not.toContain('<img');
  });

  it('absent, empty or non-array cron renders no section, just the empty-state line', () => {
    for (const cron of [undefined, [], 'nope']) {
      const html = page(cron);
      expect(cronSection(html)).toBeNull();
      expect(html).toContain('<p class="empty">no scheduled-job data yet</p>');
    }
  });

  it('merges jobs published by both hosts', () => {
    const mac = { ...hostRecord({ received_at: '2026-11-19T09:59:00Z' }), cron: [item({ name: 'mac-job' })] };
    const s = cronSection(page([item({ name: 'vm-job' })], mac));
    expect(s).toContain('mac-job');
    expect(s).toContain('vm-job');
    expect(s).toContain('<h2>Scheduled jobs (2)</h2>');
  });

  it('the page is a full document with the Jobs tab marked current', () => {
    const html = page([item()]);
    expect(html).toContain('<title>Scheduled jobs</title>');
    expect(html).toContain('<h1>Scheduled jobs</h1>');
    expect(html).toContain('<a href="/jobs" aria-current="page">Jobs</a>');
  });
});

describe('"What it does" column', () => {
  it('shows the description, and a dash when the item has none', () => {
    const s = cronSection(
      page([
        item({ name: 'with', description: 'Daily layoff/closure recruiting scan — posts new finds to Slack' }),
        item({ name: 'without' }),
        item({ name: 'blank', description: '' }),
      ]),
    );
    expect(s).toContain('Daily layoff/closure recruiting scan — posts new finds to Slack');
    const rowOf = (name) => new RegExp(`<tr><td[^>]*>${name}</td>([\\s\\S]*?)</tr>`).exec(s)[1];
    expect(rowOf('without')).toMatch(/^<td[^>]*data-label="What it does"[^>]*>—<\/td>/);
    expect(rowOf('blank')).toMatch(/^<td[^>]*data-label="What it does"[^>]*>—<\/td>/);
  });
});

describe('Host / source column', () => {
  it('reads "<Host> · <source>": Mac rows from the Mac host, VM rows from the VM host', () => {
    const mac = {
      ...hostRecord({ received_at: '2026-11-19T09:59:00Z' }),
      cron: [item({ name: 'a-launchd-job', source: 'launchd' }), item({ name: 'a-desktop-task', source: 'desktop' }), item({ name: 'a-mac-cron', source: 'cron' })],
    };
    const s = cronSection(page([item({ name: 'a-vm-job', source: 'cron' })], mac));
    expect(s).toMatch(/a-launchd-job<\/td>[\s\S]*?Mac &middot; launchd/);
    expect(s).toMatch(/a-desktop-task<\/td>[\s\S]*?Mac &middot; desktop/);
    expect(s).toMatch(/a-mac-cron<\/td>[\s\S]*?Mac &middot; cron/);
    expect(s).toMatch(/a-vm-job<\/td>[\s\S]*?VM &middot; cron/);
  });

  it('an item with no (or an unknown) source is a crontab job', () => {
    const s = cronSection(page([item({ name: 'old-beat' }), item({ name: 'odd-source', source: 'systemd' })]));
    expect(s.match(/VM &middot; cron/g)).toHaveLength(2);
    expect(s).not.toContain('systemd');
  });

  it('within the same result, Mac jobs come before VM jobs, then by name', () => {
    const mac = { ...hostRecord({ received_at: '2026-11-19T09:59:00Z' }), cron: [item({ name: 'zzz-mac' })] };
    const s = cronSection(page([item({ name: 'aaa-vm' })], mac));
    expect(s.indexOf('>zzz-mac<')).toBeLessThan(s.indexOf('>aaa-vm<'));
  });
});

describe('the main page no longer carries the section', () => {
  it('renderPage has no Scheduled jobs section even when a host published cron[]', () => {
    const html = renderPage(hosts([item()]), thresholds, NOW);
    expect(html).not.toContain('Scheduled jobs');
    expect(html).not.toContain('<section class="group cron">');
    expect(html).not.toContain('layoff-scan-cron');
  });
});

describe('beat -> KV -> page / status.json (AC7, AC9)', () => {
  it('a beat with cron[] stores the sanitised list; /status.json echoes it and /jobs renders it', async () => {
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

    const html = await (await worker.fetch(getRequest('/jobs'), env, {})).text();
    expect(html).toContain('<h2>Scheduled jobs (1)</h2>');
    expect(html).toContain('VM &middot; cron');
  });

  it('description and source survive the beat; the Mac host renders as Mac', async () => {
    const kv = createMockKV();
    const env = makeEnv({ STATUS: kv });
    const body = validPayload({
      cron: [item({ name: 'message-triage', schedule: '@every 900s', schedule_human: 'Every 15 minutes', description: 'Headless run of the message-triage agent.', source: 'launchd' })],
    });
    expect((await worker.fetch(beatRequest({ body, token: TOKEN_MAC }), env, {})).status).toBe(204);

    const json = await (await worker.fetch(getRequest('/status.json'), env, {})).json();
    expect(json.hosts.mac.cron[0].description).toBe('Headless run of the message-triage agent.');
    expect(json.hosts.mac.cron[0].source).toBe('launchd');

    const html = await (await worker.fetch(getRequest('/jobs'), env, {})).text();
    expect(html).toContain('Headless run of the message-triage agent.');
    expect(html).toContain('Mac &middot; launchd');
  });

  it('a beat without cron still validates (204) and /jobs shows the empty state, / no section', async () => {
    const kv = createMockKV();
    const env = makeEnv({ STATUS: kv });
    const res = await worker.fetch(beatRequest({ body: validPayload(), token: TOKEN_VM }), env, {});
    expect(res.status).toBe(204);
    const json = await (await worker.fetch(getRequest('/status.json'), env, {})).json();
    expect('cron' in json.hosts.vm).toBe(false);
    const jobs = await (await worker.fetch(getRequest('/jobs'), env, {})).text();
    expect(jobs).toContain('no scheduled-job data yet');
    const home = await (await worker.fetch(getRequest('/'), env, {})).text();
    expect(home).not.toContain('Scheduled jobs');
  });
});
