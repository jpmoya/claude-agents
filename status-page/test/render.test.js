// Direct unit tests of src/render.js — esc() defense-in-depth (tested directly per
// skills/quality-gate/SKILL.md even though the payload is already enum-validated), the
// no-data-yet state, and AC15's static/greppable properties of the emitted HTML.

import { describe, it, expect } from 'vitest';
import { esc, renderPage, PAGE_REFRESH_SECS } from '../src/render.js';
import { formatCet } from '../src/render.js'; // issue #29

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };

describe('esc() — HTML-escapes even though inputs are already enum-validated (defence in depth)', () => {
  it('escapes <, >, &, "', () => {
    expect(esc('<script>alert("xss")&</script>')).toBe(
      '&lt;script&gt;alert(&quot;xss&quot;)&amp;&lt;/script&gt;'
    );
  });

  // test-reviewer finding 4, first round: pinning the single quote to the exact numeric entity
  // &#39; over-specified an encoding the ticket never names (&#x27; and &apos; are equally valid
  // HTML). Assert only that it becomes *some* valid escaped form, not raw.
  it('escapes a single quote to a valid HTML entity (exact encoding unspecified)', () => {
    expect(esc("it's")).toMatch(/^it(&#39;|&#x27;|&apos;)s$/);
  });

  it('handles null and undefined without throwing, returns empty string', () => {
    expect(esc(null)).toBe('');
    expect(esc(undefined)).toBe('');
  });

  it('passes plain alphanumeric text through unchanged', () => {
    expect(esc('project-a')).toBe('project-a');
  });
});

describe('renderPage — both hosts null renders the first-deploy state', () => {
  it('shows "no data from either host yet" text', () => {
    const html = renderPage({ mac: null, vm: null }, { staleSecs: 1500, offlineSecs: 4500 }, 0);
    expect(html).toContain('no data from either host yet');
  });
});

describe('AC15 — static, greppable page properties', () => {
  const sampleHosts = {
    mac: {
      v: 1,
      received_at: '2026-09-17T18:00:00Z',
      supervisor_last_tick: '2026-09-17T18:00:00Z',
      capacity: { running: 1, max: 3, queued: 0 },
      runs: [],
    },
    vm: null,
  };

  it('PAGE_REFRESH_SECS is <= 30 (AC15: auto-refresh interval <= 30s)', () => {
    expect(PAGE_REFRESH_SECS).toBeLessThanOrEqual(30);
  });

  it('emits <meta http-equiv="refresh"> whose content matches the PAGE_REFRESH_SECS constant', () => {
    const html = renderPage(sampleHosts, thresholds, 0);
    const match = html.match(/<meta[^>]*http-equiv="refresh"[^>]*content="(\d+)"/i);
    expect(match).not.toBeNull();
    expect(Number(match[1])).toBe(PAGE_REFRESH_SECS);
    expect(Number(match[1])).toBeLessThanOrEqual(30);
  });

  it('declares a mobile-first viewport meta tag (375px readability)', () => {
    const html = renderPage(sampleHosts, thresholds, 0);
    expect(html).toMatch(/<meta[^>]*name="viewport"[^>]*content="[^"]*width=device-width/i);
  });

  it('supports prefers-color-scheme for both light and dark', () => {
    const html = renderPage(sampleHosts, thresholds, 0);
    expect(html).toMatch(/prefers-color-scheme:\s*dark/i);
  });

  it('uses only an inline <style> block, no linked stylesheet', () => {
    const html = renderPage(sampleHosts, thresholds, 0);
    expect(html).toMatch(/<style/i);
    expect(html).not.toMatch(/<link[^>]*rel="stylesheet"/i);
  });

  it('loads no third-party resources: no external origin in any src/href/@import/url()', () => {
    const html = renderPage(sampleHosts, thresholds, 0);
    const externalRefs = [
      ...html.matchAll(/(?:src|href)\s*=\s*"(https?:)?\/\/[^"]+"/gi),
      ...html.matchAll(/@import\s+(?:url\()?["']?(https?:)?\/\/[^"')]+/gi),
      ...html.matchAll(/url\(\s*["']?(https?:)?\/\/[^)'"]+/gi),
    ];
    expect(externalRefs).toHaveLength(0);
  });

  it('emits no <script> tag (no client-side JS)', () => {
    const html = renderPage(sampleHosts, thresholds, 0);
    expect(html).not.toMatch(/<script/i);
  });
});

describe('AC4 leak test (render half) — planted strings never reach the HTML text', () => {
  it('a run whose sanitised repo/stage/marker are already "other" never leaks raw planted text', () => {
    // render.js receives already-validated data (validate.js is the sanitisation boundary), so
    // this exercises esc()/renderPage with fields that HAVE been sanitised to "other" and
    // confirms nothing upstream of render can reintroduce the raw string.
    const hosts = {
      mac: {
        v: 1,
        received_at: '2026-09-17T18:00:00Z',
        supervisor_last_tick: '2026-09-17T18:00:00Z',
        capacity: { running: 1, max: 3, queued: 0 },
        runs: [
          {
            repo: 'other',
            issue: 42,
            state: 'running',
            stage: 'other',
            marker: 'other',
            started_at: '2026-09-17T18:00:00Z',
            last_activity_at: '2026-09-17T18:00:00Z',
            restarts: 0,
          },
        ],
      },
      vm: null,
    };
    const html = renderPage(hosts, thresholds, 0);
    expect(html).not.toContain('URGENT fix prod outage');
    expect(html).not.toContain('/Users/jp/dev/claude-agents/secrets.env');
    expect(html).not.toContain('[ERROR] worker crashed');
  });
});

describe('Staleness badge is computed from received_at only, never sent_at (clock-skew defense)', () => {
  // test-reviewer finding 1, first round (Tier 1 FAIL, empirically verified with a mutant): the
  // badge copy itself ("live"/"stale"/"offline") is only named as a vocabulary in #11 / #4 §5,
  // never specified verbatim, so these assert case-insensitive word matches rather than exact
  // copy or an invented data-* markup contract (none exists in the design). But matching
  // /offline/i against the *whole document* is satisfied by the inline <style> block alone (a
  // `.badge.offline{}` CSS rule is virtually guaranteed given the live/stale/offline
  // vocabulary), so the style block is stripped first, and a negative control (fresh
  // received_at, must render "live" and must NOT match "offline") closes the mutant the
  // test-reviewer demonstrated: an always-"live" renderer that ships `.badge.offline{}` CSS now
  // fails the negative control's "not /offline/i" half AND fails the positive case, because
  // stripping the style leaves nothing else in the document to match "offline" against.
  //
  // Assumption (flagging per advisor guidance, not silently baking in): the page has no legend
  // listing all three badge words together — §5 enumerates per-host content as "badge,
  // last-seen, capacity, then the run list," no legend. If the developer's implementation needs
  // one, that's a TEST DEFECT to raise against this test, not a silent workaround.
  function stripStyle(html) {
    return html.replace(/<style[\s\S]*?<\/style>/gi, '');
  }

  it('a host with a fresh sent_at but a received_at older than offlineSecs renders as offline', () => {
    const hosts = {
      mac: {
        v: 1,
        sent_at: '1970-01-01T00:00:00Z', // fresh relative to `now` below (epoch 0)
        received_at: '1969-01-01T00:00:00Z', // ~1 year before `now` — far past offlineSecs
        supervisor_last_tick: '1970-01-01T00:00:00Z',
        capacity: { running: 0, max: 3, queued: 0 },
        runs: [],
      },
      vm: null,
    };
    const now = 0; // 1970-01-01T00:00:00Z, matches sent_at exactly
    const body = stripStyle(renderPage(hosts, thresholds, now));
    expect(body).toMatch(/offline/i);
    expect(body).not.toMatch(/\blive\b/i);
  });

  it('a host with a fresh received_at renders as live, not offline (negative control)', () => {
    const hosts = {
      mac: {
        v: 1,
        sent_at: '1970-01-01T00:00:00Z',
        received_at: '1970-01-01T00:00:00Z', // fresh: equals `now`, well within staleSecs
        supervisor_last_tick: '1970-01-01T00:00:00Z',
        capacity: { running: 0, max: 3, queued: 0 },
        runs: [],
      },
      vm: null,
    };
    const now = 0;
    const body = stripStyle(renderPage(hosts, thresholds, now));
    expect(body).toMatch(/\blive\b/i);
    expect(body).not.toMatch(/offline/i);
  });
});

// Issue #29 formatCet unit tests kept; the pre-#62 page-layout blocks moved to grouped-render.test.js (#62 AC10).

describe('formatCet (#29 AC2/AC3)', () => {
  it.each([
    ['2026-09-19T12:05:33Z', 'Sat 19 Sep, 14:05'], // CEST = UTC+2; "Sep" not "Sept"
    ['2026-12-01T12:05:33Z', 'Tue 1 Dec, 13:05'], // CET = UTC+1; day is not zero-padded
    ['2026-09-19T22:00:00Z', 'Sun 20 Sep, 00:00'], // rolls over midnight; h23, never "24:00"
  ])('%s -> %s', (iso, expected) => {
    expect(formatCet(iso)).toBe(expected);
  });

  it.each([
    ['2026-03-29T00:59:59Z', 'Sun 29 Mar, 01:59'], // last second of CET (DST starts 01:00 UTC)
    ['2026-03-29T01:00:00Z', 'Sun 29 Mar, 03:00'], // first second of CEST: 02:xx is skipped
    ['2026-10-25T00:59:59Z', 'Sun 25 Oct, 02:59'], // last second of CEST (DST ends 01:00 UTC)
    ['2026-10-25T01:00:00Z', 'Sun 25 Oct, 02:00'], // first second of CET: clock went back an hour
  ])('switches CET/CEST automatically: %s -> %s', (iso, expected) => {
    expect(formatCet(iso)).toBe(expected);
  });

  it.each([
    ['undefined', undefined],
    ['empty string', ''],
    ['unparseable', 'not-a-date'],
    ['null', null],
    ['number', 1758283533000],
    ['object', {}],
  ])('returns "" for %s (never "Invalid Date")', (_label, value) => {
    expect(formatCet(value)).toBe('');
  });
});

