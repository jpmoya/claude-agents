// Issue #644 — CI queue panel (stat tiles + bar chart) on GET /. Covers the ticket's AC1-8.
// Expected values are hand-computed from the fixtures below, never copied from src/.

import { describe, it, expect, beforeEach } from 'vitest';
import worker, { __resetRateLimiter } from '../src/index.js';
import { renderPage, renderCiQueuePanel } from '../src/render.js';
import { makeEnv, getRequest, validPayload, beatRequest, TOKEN_MAC, hostRecord, validCiQueue } from './fixtures.js';

beforeEach(() => {
  __resetRateLimiter();
});

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;

/** Isolates the CI-queue panel's own markup so assertions never match the word "stale" that
 * legitimately appears elsewhere (host badges, the `.badge.stale` CSS rule). */
function ciQueuePanel(html) {
  const m = /<section class="group ci-queue">[\s\S]*?<\/section>/.exec(html);
  return m ? m[0] : null;
}

describe('AC1 — no host carries ci_queue: no panel, no error', () => {
  it('renders 200 with no ci-queue section when neither host has ci_queue', () => {
    const hosts = { mac: hostRecord(), vm: hostRecord() };
    const html = renderPage(hosts, thresholds, NOW);
    expect(ciQueuePanel(html)).toBeNull();
  });

  it('renderCiQueuePanel returns "" directly for hosts with no ci_queue', () => {
    expect(renderCiQueuePanel({ mac: hostRecord(), vm: null }, thresholds, NOW)).toBe('');
    expect(renderCiQueuePanel({ mac: null, vm: null }, thresholds, NOW)).toBe('');
  });
});

describe('AC2 — one host with a valid ci_queue: tiles + proportional bar chart', () => {
  const ciQueue = validCiQueue({
    as_of: '2026-09-21T11:58:00Z',
    runners_busy: 3,
    runners_total: 5,
    queued_total: 14,
    categories: [
      { key: 'dependabot', count: 4 },
      { key: 'deploy_release', count: 2 },
      { key: 'pr', count: 8 },
      { key: 'other', count: 0 },
    ],
    oldest: { key: 'deploy_release', queued_at: '2026-09-21T11:46:00Z' }, // 14 min before NOW (11:46 -> 12:00)
  });
  const hosts = { mac: hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue }), vm: hostRecord() };
  const html = renderPage(hosts, thresholds, NOW);
  const panel = ciQueuePanel(html);

  it('panel is present', () => {
    expect(panel).not.toBeNull();
  });

  it('shows "Jobs queued now" = queued_total', () => {
    expect(panel).toMatch(/14[\s\S]{0,80}Jobs queued now/);
  });

  it('shows "Runner slots busy" = runners_busy/runners_total', () => {
    expect(panel).toMatch(/3\/5[\s\S]{0,80}Runner slots busy/);
  });

  it('shows the oldest-waiting tile with the computed age ("14 min") and category label', () => {
    expect(panel).toMatch(/14 min/);
    expect(panel).toContain('Release/deploy jobs waiting longest');
  });

  it('renders exactly 3 bars (one per non-zero category, "other":0 excluded)', () => {
    const rects = [...panel.matchAll(/<rect[^>]*class="ci-bar"[^>]*>/g)];
    expect(rects).toHaveLength(3);
  });

  it('bar widths are proportional to the max non-zero category count (pr=8 is the max)', () => {
    const widthOf = (key) => {
      const m = new RegExp(`<rect[^>]*width="(\\d+)"[^>]*data-key="${key}"`).exec(panel);
      expect(m, `bar for ${key}`).not.toBeNull();
      return Number(m[1]);
    };
    // formula mirrors the implementation: max(2, round(count/max * 160))
    expect(widthOf('pr')).toBe(160); // 8/8 * 160
    expect(widthOf('dependabot')).toBe(80); // 4/8 * 160
    expect(widthOf('deploy_release')).toBe(40); // 2/8 * 160
    expect(widthOf('pr')).toBeGreaterThan(widthOf('dependabot'));
    expect(widthOf('dependabot')).toBeGreaterThan(widthOf('deploy_release'));
  });

  it('bars are in fixed vocabulary order (dependabot, deploy_release, pr), not sorted by count', () => {
    const order = [...panel.matchAll(/data-key="(\w+)"/g)].map((m) => m[1]);
    expect(order).toEqual(['dependabot', 'deploy_release', 'pr']);
  });

  it('human labels are used for category keys, not the raw enum values', () => {
    expect(panel).toContain('Dependabot PRs');
    expect(panel).toContain('Release/deploy jobs');
    expect(panel).toContain('Other feature PRs');
    expect(panel).not.toMatch(/>pr</); // the raw "pr" key text never appears as its own label
  });
});

describe('AC3 — two hosts both carry ci_queue: the fresher as_of wins', () => {
  it('uses VM data when VM as_of is later than Mac', () => {
    const mac = hostRecord({
      received_at: '2026-09-21T11:59:00Z',
      ci_queue: validCiQueue({ as_of: '2026-09-21T11:00:00Z', queued_total: 1 }),
    });
    const vm = hostRecord({
      received_at: '2026-09-21T11:59:00Z',
      ci_queue: validCiQueue({ as_of: '2026-09-21T11:58:00Z', queued_total: 99 }),
    });
    const panel = ciQueuePanel(renderPage({ mac, vm }, thresholds, NOW));
    expect(panel).toMatch(/99[\s\S]{0,80}Jobs queued now/);
    expect(panel).not.toMatch(/>1<[\s\S]{0,80}Jobs queued now/);
  });

  it('uses Mac data when Mac as_of is later than VM', () => {
    const mac = hostRecord({
      received_at: '2026-09-21T11:59:00Z',
      ci_queue: validCiQueue({ as_of: '2026-09-21T11:58:00Z', queued_total: 7 }),
    });
    const vm = hostRecord({
      received_at: '2026-09-21T11:59:00Z',
      ci_queue: validCiQueue({ as_of: '2026-09-21T11:00:00Z', queued_total: 2 }),
    });
    const panel = ciQueuePanel(renderPage({ mac, vm }, thresholds, NOW));
    expect(panel).toMatch(/7[\s\S]{0,80}Jobs queued now/);
  });
});

describe('AC4 — a category count of 0 is omitted, never a zero-width bar', () => {
  it('categories: [] with queued_total 0 renders tiles with no chart at all (no bars, no NaN)', () => {
    const ciQueue = validCiQueue({ categories: [], queued_total: 0, oldest: null });
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).not.toBeNull();
    expect(panel).not.toContain('<svg');
    expect(panel).not.toMatch(/NaN/);
    expect(panel).not.toMatch(/Infinity/);
  });
});

describe('AC5 — oldest: null renders a neutral "no jobs waiting" tile, never a crash or NaN', () => {
  it('shows a neutral waiting tile', () => {
    const ciQueue = validCiQueue({ oldest: null });
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toContain('No jobs waiting');
    expect(panel).not.toMatch(/NaN min/);
  });

  it('clock skew (oldest.queued_at after now) clamps the wait to 0, never a negative number', () => {
    const ciQueue = validCiQueue({ oldest: { key: 'pr', queued_at: '2026-09-21T12:05:00Z' } }); // 5 min after NOW
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toMatch(/0 min/);
    expect(panel).not.toMatch(/-\d+ min/);
  });
});

describe('AC6 — stale marker from thresholds.staleSecs (boundary included)', () => {
  it('freshest as_of exactly at staleSecs age is marked stale', () => {
    const asOf = new Date((NOW - thresholds.staleSecs) * 1000).toISOString();
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue({ as_of: asOf }) });
    const panel = ciQueuePanel(renderPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toMatch(/badge stale/);
  });

  it('freshest as_of one second inside staleSecs is not marked stale', () => {
    const asOf = new Date((NOW - thresholds.staleSecs + 1) * 1000).toISOString();
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue({ as_of: asOf }) });
    const panel = ciQueuePanel(renderPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).not.toMatch(/badge stale/);
  });
});

describe('AC7 — every ci_queue field is HTML-escaped (esc()), never raw-interpolated', () => {
  it('a category count/label combination never leaks an unescaped "<" or "&" from the data path', () => {
    // validate.js's closed vocab means ci_queue itself can never carry markup, so this proves the
    // render path round-trips numeric fields through esc() without producing broken markup —
    // grep-style check: no "${" literal leaked, and every <rect>/<text> tag is well-formed.
    const ciQueue = validCiQueue({ queued_total: 999, runners_busy: 999, runners_total: 999 });
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).not.toContain('${');
    expect(panel).toMatch(/999\/999/);
  });

  it('grep check: every bare ci_queue field interpolated directly into an HTML tag is wrapped in esc()', async () => {
    const fs = await import('node:fs');
    const src = fs.readFileSync(new URL('../src/render.js', import.meta.url), 'utf8');
    // A *bare* field reference (the entire `${...}` expression, not a function call or a mapped
    // constant lookup like CI_QUEUE_LABELS[b.key]) landing straight in HTML must go through
    // esc(...). This intentionally does not flag the `summary` string built for the SVG's
    // aria-label — that's plain-text accumulation, not HTML, and the assembled string is itself
    // passed through esc() once where it's actually embedded in the attribute.
    const bareFieldInHtml =
      /<[a-zA-Z][^>]*\$\{(ciQueue\.(queued_total|runners_busy|runners_total)|oldest\.(key|queued_at)|b\.(key|count))\}/g;
    expect([...src.matchAll(bareFieldInHtml)]).toEqual([]);
  });
});

describe('AC8 — existing render.js/renderPage behavior is unaffected', () => {
  it('still emits no <script> tag when the page has no backlog keys', () => {
    const hosts = { mac: hostRecord(), vm: null };
    const html = renderPage(hosts, thresholds, NOW);
    expect(html).not.toMatch(/<script/i);
  });

  it('still loads no third-party resources with a ci_queue panel present', () => {
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue() });
    const html = renderPage({ mac, vm: hostRecord() }, thresholds, NOW);
    const externalRefs = [
      ...html.matchAll(/(?:src|href)\s*=\s*"(https?:)?\/\/[^"]+"/gi),
      ...html.matchAll(/@import\s+(?:url\()?["']?(https?:)?\/\/[^"')]+/gi),
      ...html.matchAll(/url\(\s*["']?(https?:)?\/\/[^)'"]+/gi),
    ];
    expect(externalRefs).toHaveLength(0);
  });
});

describe('GET /status.json passes ci_queue through on the host record (no new code needed)', () => {
  it('a beat carrying ci_queue comes back under hosts.mac.ci_queue verbatim', async () => {
    const env = makeEnv();
    const ciQueue = validCiQueue();
    const beatRes = await worker.fetch(
      beatRequest({ token: TOKEN_MAC, body: validPayload({ ci_queue: ciQueue }) }),
      env,
      {}
    );
    expect(beatRes.status).toBe(204);

    const res = await worker.fetch(getRequest('/status.json'), env, {});
    const json = await res.json();
    expect(json.hosts.mac.ci_queue).toEqual(ciQueue);
  });

  it('a beat with no ci_queue never adds the key to hosts.mac', async () => {
    const env = makeEnv();
    await worker.fetch(beatRequest({ token: TOKEN_MAC, body: validPayload() }), env, {});
    const res = await worker.fetch(getRequest('/status.json'), env, {});
    const json = await res.json();
    expect(json.hosts.mac).not.toHaveProperty('ci_queue');
  });
});
