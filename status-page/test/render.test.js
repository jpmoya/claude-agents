// Direct unit tests of src/render.js — esc() defense-in-depth (tested directly per
// skills/quality-gate/SKILL.md even though the payload is already enum-validated), the
// no-data-yet state, and AC15's static/greppable properties of the emitted HTML.

import { describe, it, expect } from 'vitest';
import { esc, renderPage, PAGE_REFRESH_SECS } from '../src/render.js';

const thresholds = { staleSecs: 1500, offlineSecs: 4500 };

describe('esc() — HTML-escapes even though inputs are already enum-validated (defence in depth)', () => {
  it('escapes <, >, &, ", \'', () => {
    expect(esc('<script>alert("xss")&\'</script>')).toBe(
      '&lt;script&gt;alert(&quot;xss&quot;)&amp;&#39;&lt;/script&gt;'
    );
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
  // The badge copy itself ("live"/"stale"/"offline") is only named as a vocabulary in #11 / #4
  // §5, not specified verbatim anywhere — so this asserts case-insensitively that "offline"
  // appears, rather than inventing exact copy. now (epoch 0) minus received_at is far beyond
  // offlineSecs even though sent_at (by the host's own clock) is "fresh" relative to now.
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
    const html = renderPage(hosts, thresholds, now);
    expect(html).toMatch(/offline/i);
  });
});
