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

// ---- Issue #29: 7-column table, CET timestamps, clickable ticket title ------------------------
// Expected strings are hand-written from the ticket (weekday/month names checked against a
// calendar: 2026-09-19 Sat, 2026-12-01 Tue, 2026-09-20 Sun, 2026-03-29 Sun, 2026-10-25 Sun).

const GOOD_URL = 'https://github.com/example-owner/project-a/issues/42';
const BAD_URLS = [
  'javascript:alert(1)',
  'https://evil.example/example-owner/project-a/issues/42',
  'http://github.com/example-owner/project-a/issues/42',
  'https://github.com/example-owner/project-a/issues/42?x=1',
  'https://github.com/example-owner/project-a/pull/42',
  'https://github.com/example-owner/project-a/issues/42" onclick="x',
  42,
];

function runFixture(overrides = {}) {
  return {
    repo: 'zz-alias',
    issue: 42,
    state: 'running',
    stage: 'test-writer',
    marker: 'TESTS WRITTEN',
    started_at: '2026-01-02T03:04:05Z',
    last_activity_at: '2026-09-19T12:05:33Z',
    restarts: 0,
    ...overrides,
  };
}

function hostsWith(runs, hostOverrides = {}) {
  return {
    mac: {
      v: 1,
      received_at: '2026-09-19T12:05:33Z',
      supervisor_last_tick: '2026-09-19T12:05:00Z',
      capacity: { running: 1, max: 3, queued: 0 },
      runs,
      ...hostOverrides,
    },
    vm: null,
  };
}

/** Inner HTML of every <th> in document order. */
function headerCells(html) {
  return [...html.matchAll(/<th[^>]*>([\s\S]*?)<\/th>/g)].map((m) => m[1].trim());
}

/** Inner HTML of every <td> of every <tbody> row: string[][]. */
function bodyRows(html) {
  const tbody = (html.match(/<tbody>([\s\S]*?)<\/tbody>/) || [null, ''])[1];
  return [...tbody.matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/g)].map((row) =>
    [...row[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((c) => c[1].trim())
  );
}

const render = (hosts) => renderPage(hosts, thresholds, Date.parse('2026-09-19T12:06:00Z') / 1000);

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

describe('renderPage — 7-column table (#29 AC1)', () => {
  it('header cells are exactly Issue, Ticket, State, Stage, Marker, Last activity, Restarts, in order', () => {
    const html = render(hostsWith([runFixture()]));
    expect(headerCells(html)).toEqual(['Issue', 'Ticket', 'State', 'Stage', 'Marker', 'Last activity', 'Restarts']);
  });

  it('has no Repo or Started header', () => {
    const html = render(hostsWith([runFixture()]));
    expect(html).not.toContain('<th>Repo</th>');
    expect(html).not.toContain('<th>Started</th>');
  });

  it('does not render the run\'s repo alias or started_at anywhere in the HTML', () => {
    const html = render(hostsWith([runFixture()]));
    expect(html).not.toContain('zz-alias');
    expect(html).not.toContain('2026-01-02'); // raw started_at
    expect(html).not.toContain('Fri 2 Jan'); // ...or its CET-formatted form
    expect(bodyRows(html)[0]).toHaveLength(7); // and each body row really has 7 cells
  });

  it('the no-runs row spans 7 columns', () => {
    const html = render(hostsWith([]));
    expect(html).toContain('colspan="7"');
    expect(html).not.toContain('colspan="8"');
  });
});

describe('renderPage — CET timestamps (#29 AC2/AC3)', () => {
  it('Last activity and host Last seen read "Sat 19 Sep, 14:05"; no seconds, no ISO string', () => {
    const html = render(hostsWith([runFixture({ last_activity_at: '2026-09-19T12:05:33Z' })]));
    expect(html).toMatch(/Last seen[^<]*Sat 19 Sep, 14:05/);
    const cells = bodyRows(html)[0];
    expect(cells[5]).toBe('Sat 19 Sep, 14:05'); // Last activity is the 6th of 7 cells
    expect(html).not.toContain(':33');
    expect(html).not.toContain('2026-09-19T');
  });

  it('missing, empty and unparseable timestamps render empty; "Invalid Date" never appears', () => {
    const runs = [
      runFixture({ issue: 1, last_activity_at: undefined }),
      runFixture({ issue: 2, last_activity_at: '' }),
      runFixture({ issue: 3, last_activity_at: 'garbage' }),
    ];
    const html = render(hostsWith(runs, { received_at: 'not-a-date' }));
    expect(html).not.toContain('Invalid Date');
    const rows = bodyRows(html);
    expect(rows).toHaveLength(3);
    for (const cells of rows) expect(cells[5]).toBe(''); // Last activity
    const lastSeen = html.match(/Last seen([^<]*)</);
    expect(lastSeen).not.toBeNull();
    expect(lastSeen[1].replace(/[:\s]/g, '')).toBe(''); // label kept, value empty
  });
});

describe('renderPage — Ticket cell (#29 AC4/AC5/AC6)', () => {
  it('title + valid url renders an <a> with target=_blank and rel=noopener noreferrer wrapping the title', () => {
    const html = render(hostsWith([runFixture({ title: 'Fix login redirect', url: GOOD_URL })]));
    const anchor = `<a href="${GOOD_URL}" target="_blank" rel="noopener noreferrer">Fix login redirect</a>`;
    expect(html).toContain(anchor);
    expect(bodyRows(html)[0][1]).toBe(anchor); // Ticket is the 2nd cell
  });

  it('the XSS title renders HTML-escaped inside the link and the page still has no <script', () => {
    const html = render(
      hostsWith([runFixture({ title: '<script>alert(1)</script> & "quotes"', url: GOOD_URL })])
    );
    expect(html).toContain('&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quotes&quot;');
    expect(html).not.toMatch(/<script/i);
  });

  it('the XSS title is escaped in the plain-text (no url) form too', () => {
    const html = render(hostsWith([runFixture({ title: '<script>alert(1)</script> & "quotes"' })]));
    expect(bodyRows(html)[0][1]).toBe('&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quotes&quot;');
    expect(html).not.toMatch(/<script/i);
  });

  it.each(BAD_URLS.map((u) => [String(u), u]))(
    'bad url %s handed straight to renderPage: title as plain text, no href anywhere',
    (_label, url) => {
      const html = render(hostsWith([runFixture({ title: 'Fix login redirect', url })]));
      expect(bodyRows(html)[0][1]).toBe('Fix login redirect'); // control: the title is rendered, as text
      expect(html).not.toContain('href');
      expect(html).not.toContain('onclick=');
    }
  );

  it('title with a missing url renders as plain text with no <a>', () => {
    const html = render(hostsWith([runFixture({ title: 'Fix login redirect' })]));
    expect(bodyRows(html)[0][1]).toBe('Fix login redirect');
    expect(html).not.toContain('<a ');
    expect(html).not.toContain('href');
  });

  it('a url with no title renders an empty Ticket cell and no href, even for a valid url', () => {
    const rows = bodyRows(render(hostsWith([runFixture({ issue: 41, title: 'Control title', url: GOOD_URL }), runFixture({ url: GOOD_URL })])));
    expect(rows[0][1]).toContain('Control title'); // control: titles render at all
    expect(rows[1][1]).toBe('');
    expect(rows[1].join('')).not.toContain('href');
  });

  it('a legacy run (no title, no url) renders an empty Ticket cell (beside a titled run)', () => {
    const rows = bodyRows(render(hostsWith([runFixture({ issue: 41, title: 'Control title' }), runFixture()])));
    expect(rows[0][1]).toBe('Control title'); // control: titles render at all
    expect(rows[1][1]).toBe('');
  });

  it('the ticket link is navigation, not a loaded resource: every href sits on an <a>; no src/link/@import', () => {
    const html = render(hostsWith([runFixture({ title: 'Fix login redirect', url: GOOD_URL })]));
    const hrefs = [...html.matchAll(/href\s*=/gi)].length;
    const anchors = [...html.matchAll(/<a href=/g)].length;
    expect(anchors).toBe(1); // control: the link is there
    expect(hrefs).toBe(anchors);
    expect(html).not.toMatch(/\ssrc\s*=/i);
    expect(html).not.toMatch(/<link\b/i);
    expect(html).not.toMatch(/@import/i);
    expect(html).not.toMatch(/<script/i);
  });
});
