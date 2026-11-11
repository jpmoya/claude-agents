// Issue #644 — CI queue panel (stat tiles + bar chart), originally on GET /. Issue #649 moved the
// whole panel onto its own GET /ci tab and reworded/reformatted the "waiting longest" tile — this
// file is updated (not deleted) to point at the new page/copy, per #649 AC6. Expected values are
// hand-computed from the fixtures below, never copied from src/.

import { describe, it, expect, beforeEach } from 'vitest';
import worker, { __resetRateLimiter } from '../src/index.js';
import { renderPage, renderCiPage, renderCiQueuePanel } from '../src/render.js';
import { makeEnv, getRequest, validPayload, beatRequest, TOKEN_MAC, hostRecord, validCiQueue } from './fixtures.js';

beforeEach(() => {
  __resetRateLimiter();
});

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };
const NOW = Date.parse('2026-09-21T12:00:00Z') / 1000;

/** Isolates the CI-queue panel's own markup (tiles + chart only — the runner table lives in its
 * own sibling <section class="group ci-runners">, never matched by this helper) so assertions
 * never match the word "stale" that legitimately appears elsewhere (host badges, `.badge.stale`). */
function ciQueuePanel(html) {
  const m = /<section class="group ci-queue">[\s\S]*?<\/section>/.exec(html);
  return m ? m[0] : null;
}

describe('AC6 (#649) — the panel no longer renders on / at all', () => {
  it('GET / with a valid ci_queue fixture has no ci-queue section', () => {
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue() });
    const html = renderPage({ mac, vm: hostRecord() }, thresholds, NOW);
    expect(ciQueuePanel(html)).toBeNull();
  });

  it('renderPage never imports/uses ci_queue data for its own markup (grep: no "ci-tiles" on /)', () => {
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue() });
    const html = renderPage({ mac, vm: hostRecord() }, thresholds, NOW);
    expect(html).not.toContain('ci-tiles');
    expect(html).not.toContain('class="group ci-queue"');
  });
});

describe('AC1 — no host carries ci_queue: /ci still renders, no panel, no error', () => {
  it('renderCiPage renders a neutral empty state when neither host has ci_queue', () => {
    const hosts = { mac: hostRecord(), vm: hostRecord() };
    const html = renderCiPage(hosts, thresholds, NOW);
    expect(ciQueuePanel(html)).toBeNull();
    expect(html).toContain('no CI queue data yet');
  });

  it('renderCiQueuePanel still returns "" directly for hosts with no ci_queue', () => {
    expect(renderCiQueuePanel({ mac: hostRecord(), vm: null }, thresholds, NOW)).toBe('');
    expect(renderCiQueuePanel({ mac: null, vm: null }, thresholds, NOW)).toBe('');
  });
});

describe('AC2/AC7 — one host with a valid ci_queue: tiles + proportional bar chart, on /ci', () => {
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
  const html = renderCiPage(hosts, thresholds, NOW);
  const panel = ciQueuePanel(html);

  it('panel is present on /ci', () => {
    expect(panel).not.toBeNull();
  });

  it('shows "Jobs queued now" = queued_total', () => {
    expect(panel).toMatch(/14[\s\S]{0,80}Jobs queued now/);
  });

  it('shows "Runner slots busy" = runners_busy/runners_total', () => {
    expect(panel).toMatch(/3\/5[\s\S]{0,80}Runner slots busy/);
  });

  it('shows the oldest-waiting tile as one unambiguous sentence naming the category then the formatted duration', () => {
    expect(panel).toContain('Longest wait: Release/deploy jobs &mdash; 14m');
    // never the old two-stacked-lines shape
    expect(panel).not.toMatch(/14 min/);
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

describe('AC3 (#643) — two hosts both carry ci_queue: the fresher as_of wins, on /ci', () => {
  it('uses VM data when VM as_of is later than Mac', () => {
    const mac = hostRecord({
      received_at: '2026-09-21T11:59:00Z',
      ci_queue: validCiQueue({ as_of: '2026-09-21T11:00:00Z', queued_total: 1 }),
    });
    const vm = hostRecord({
      received_at: '2026-09-21T11:59:00Z',
      ci_queue: validCiQueue({ as_of: '2026-09-21T11:58:00Z', queued_total: 99 }),
    });
    const panel = ciQueuePanel(renderCiPage({ mac, vm }, thresholds, NOW));
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
    const panel = ciQueuePanel(renderCiPage({ mac, vm }, thresholds, NOW));
    expect(panel).toMatch(/7[\s\S]{0,80}Jobs queued now/);
  });
});

describe('AC4 — a category count of 0 is omitted, never a zero-width bar', () => {
  it('categories: [] with queued_total 0 renders tiles with no chart at all (no bars, no NaN)', () => {
    const ciQueue = validCiQueue({ categories: [], queued_total: 0, oldest: null });
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).not.toBeNull();
    expect(panel).not.toContain('<svg');
    expect(panel).not.toMatch(/NaN/);
    expect(panel).not.toMatch(/Infinity/);
  });
});

describe('AC2 (#649) — "waiting longest" tile is one unambiguous sentence, never two disconnected lines', () => {
  it('oldest: null renders a neutral "No jobs waiting" tile, never a crash or NaN', () => {
    const ciQueue = validCiQueue({ oldest: null });
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toContain('No jobs waiting');
    expect(panel).not.toMatch(/NaNm/);
  });

  it('clock skew (oldest.queued_at after now) clamps the wait to 0m, never a negative number', () => {
    const ciQueue = validCiQueue({ oldest: { key: 'pr', queued_at: '2026-09-21T12:05:00Z' } }); // 5 min after NOW
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toContain('&mdash; 0m');
    expect(panel).not.toMatch(/-\d+m/);
  });

  it('reads as one sentence: the category label and the duration are in the same element, not two stacked labels', () => {
    const ciQueue = validCiQueue({ oldest: { key: 'pr', queued_at: '2026-09-21T11:36:39Z' } }); // 23m21s before NOW
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    // exactly one <div> carries both the category label and the duration
    const m = /<div class="ci-tile-value ci-tile-sentence">([^<]*)<\/div>/.exec(panel);
    expect(m).not.toBeNull();
    expect(m[1]).toBe('Longest wait: Other feature PRs &mdash; 23m');
    // never the old two-line shape: a bare tile-value with no text, followed by a separate "waiting longest" label
    expect(panel).not.toMatch(/waiting longest/);
  });
});

describe('AC1 (#649) — duration formatter boundaries, via the rendered tile', () => {
  it.each([
    [0, '0m'],
    [59, '59m'],
    [60, '1h 0m'],
    [1439, '23h 59m'],
    [1440, '1d 0h'],
    [1401, '23h 21m'],
  ])('%i minutes waiting renders "%s"', (mins, expected) => {
    const queuedAt = new Date((NOW - mins * 60) * 1000).toISOString();
    const ciQueue = validCiQueue({ oldest: { key: 'pr', queued_at: queuedAt } });
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toContain(`&mdash; ${expected}`);
  });
});

describe('AC3 (#649) — offline-aware busy tile', () => {
  it('runners_offline: 0 shows no offline note', () => {
    const ciQueue = validCiQueue({ runners_offline: 0, runners_busy: 2, runners_total: 5 });
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toContain('2/5');
    expect(panel).not.toContain('offline');
  });

  it('runners_offline: 2 shows a visible "2 offline" note alongside the ratio', () => {
    const ciQueue = validCiQueue({ runners_offline: 2, runners_busy: 1, runners_total: 4 });
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toContain('1/4');
    expect(panel).toContain('2 offline');
  });

  it('an old-collector payload with no runners_offline key at all shows no offline note', () => {
    const ciQueue = validCiQueue(); // never carries runners_offline
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).not.toContain('offline');
  });
});

describe('AC6 (#649) — stale marker from thresholds.staleSecs (boundary included), on /ci', () => {
  it('freshest as_of exactly at staleSecs age is marked stale', () => {
    const asOf = new Date((NOW - thresholds.staleSecs) * 1000).toISOString();
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue({ as_of: asOf }) });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).toMatch(/badge stale/);
  });

  it('freshest as_of one second inside staleSecs is not marked stale', () => {
    const asOf = new Date((NOW - thresholds.staleSecs + 1) * 1000).toISOString();
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue({ as_of: asOf }) });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).not.toMatch(/badge stale/);
  });
});

describe('AC10/AC7 — every ci_queue field is HTML-escaped (esc()), never raw-interpolated', () => {
  it('a category count/label combination never leaks an unescaped "<" or "&" from the data path', () => {
    const ciQueue = validCiQueue({ queued_total: 999, runners_busy: 999, runners_total: 999 });
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: ciQueue });
    const panel = ciQueuePanel(renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW));
    expect(panel).not.toContain('${');
    expect(panel).toMatch(/999\/999/);
  });

  it('grep check: every bare ci_queue/runner field interpolated directly into an HTML tag is wrapped in esc()', async () => {
    const fs = await import('node:fs');
    const src = fs.readFileSync(new URL('../src/render.js', import.meta.url), 'utf8');
    // A *bare* field reference (the entire `${...}` expression, not a function call or a mapped
    // constant lookup like CI_QUEUE_LABELS[b.key]) landing straight in HTML must go through
    // esc(...). Intentionally does not flag the `summary` string built for the SVG's aria-label
    // (plain-text accumulation, itself passed through esc() once where actually embedded).
    const bareFieldInHtml =
      /<[a-zA-Z][^>]*\$\{(ciQueue\.(queued_total|runners_busy|runners_total)|oldest\.(key|queued_at)|b\.(key|count)|r\.(name|util_24h_pct|util_72h_pct)|offline)\}/g;
    expect([...src.matchAll(bareFieldInHtml)]).toEqual([]);
  });
});

describe('AC8 — existing render.js/renderPage behavior is unaffected', () => {
  it('still emits no <script> tag when the page has no backlog keys', () => {
    const hosts = { mac: hostRecord(), vm: null };
    const html = renderPage(hosts, thresholds, NOW);
    expect(html).not.toMatch(/<script/i);
  });

  it('still loads no third-party resources with a ci_queue panel present, on /ci', () => {
    const mac = hostRecord({ received_at: '2026-09-21T11:59:00Z', ci_queue: validCiQueue() });
    const html = renderCiPage({ mac, vm: hostRecord() }, thresholds, NOW);
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
