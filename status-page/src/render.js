// src/render.js — server-rendered HTML page. No JS emitted, no third-party resources.
//
// Mobile-first at 375px, prefers-color-scheme light/dark, inline <style>, <meta
// http-equiv="refresh" content="..."> driven by a page-refresh constant (AC15). Every value
// passes through esc() even though the payload is already enum-validated (defence in depth,
// tested directly per skills/quality-gate/SKILL.md).

// Auto-refresh interval in seconds. Must stay <= 30 (AC15). Grepped directly by tests.
export const PAGE_REFRESH_SECS = 20;

const HOST_LABELS = { mac: 'Mac', vm: 'VM' };

/** @param {unknown} value */
export function esc(value) {
  if (value === null || value === undefined) return '';
  return String(value).replace(/[&<>"']/g, (ch) => {
    switch (ch) {
      case '&':
        return '&amp;';
      case '<':
        return '&lt;';
      case '>':
        return '&gt;';
      case '"':
        return '&quot;';
      case "'":
        return '&#39;';
      default:
        return ch;
    }
  });
}

/**
 * STUB (issue #29) — the developer replaces this. Contract: ISO UTC string -> "Sat 19 Sep, 14:05"
 * in Europe/Madrid (see the ticket's design decision 6); non-string / unparseable -> ''.
 */
export function formatCet(_iso) {
  throw new Error('NotImplemented');
}

/** Derives the live/stale/offline badge from `received_at` only (never `sent_at`). */
function computeBadge(receivedAt, thresholds, nowEpochSecs) {
  const receivedAtMs = typeof receivedAt === 'string' ? Date.parse(receivedAt) : NaN;
  if (Number.isNaN(receivedAtMs)) return 'offline';
  const ageSecs = nowEpochSecs - Math.floor(receivedAtMs / 1000);
  if (ageSecs >= thresholds.offlineSecs) return 'offline';
  if (ageSecs >= thresholds.staleSecs) return 'stale';
  return 'live';
}

function renderRunRow(run) {
  return `<tr>
    <td>${esc(run.repo)}</td>
    <td>#${esc(run.issue)}</td>
    <td>${esc(run.state)}</td>
    <td>${esc(run.stage)}</td>
    <td>${esc(run.marker)}</td>
    <td>${esc(run.started_at)}</td>
    <td>${esc(run.last_activity_at)}</td>
    <td>${esc(run.restarts)}</td>
  </tr>`;
}

function renderHostSection(key, host, thresholds, nowEpochSecs) {
  const label = HOST_LABELS[key] || key;
  if (!host) {
    // A never-seen host is neither "live" nor "offline" — a distinct third state so the two
    // badge words stay reserved for hosts we've actually heard from.
    return `<section class="host">
      <h2>${esc(label)}</h2>
      <p class="badge nodata">no data yet</p>
    </section>`;
  }

  const badge = computeBadge(host.received_at, thresholds, nowEpochSecs);
  const capacity = host.capacity && typeof host.capacity === 'object' ? host.capacity : {};
  const runs = Array.isArray(host.runs) ? host.runs : [];
  const runRows = runs.length
    ? runs.map(renderRunRow).join('')
    : '<tr><td colspan="8">no active runs</td></tr>';

  return `<section class="host">
    <h2>${esc(label)} <span class="badge ${esc(badge)}">${esc(badge)}</span></h2>
    <p class="last-seen">Last seen: ${esc(host.received_at)}</p>
    <p class="capacity">Capacity: running ${esc(capacity.running)} / max ${esc(capacity.max)} (queued ${esc(capacity.queued)})</p>
    <table>
      <thead>
        <tr><th>Repo</th><th>Issue</th><th>State</th><th>Stage</th><th>Marker</th><th>Started</th><th>Last activity</th><th>Restarts</th></tr>
      </thead>
      <tbody>${runRows}</tbody>
    </table>
  </section>`;
}

/**
 * @param {{ mac: object|null, vm: object|null }} hosts
 * @param {{ staleSecs: number, offlineSecs: number }} thresholds
 * @param {number} nowEpochSecs
 * @returns {string} full HTML document
 */
export function renderPage(hosts, thresholds, nowEpochSecs) {
  const bothEmpty = !hosts.mac && !hosts.vm;

  const body = bothEmpty
    ? '<p class="empty">no data from either host yet</p>'
    : `${renderHostSection('mac', hosts.mac, thresholds, nowEpochSecs)}${renderHostSection('vm', hosts.vm, thresholds, nowEpochSecs)}`;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="${PAGE_REFRESH_SECS}">
<title>Pipeline status</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui, sans-serif; margin: 0; padding: 1rem; background: #ffffff; color: #111111; }
  h1 { font-size: 1.1rem; }
  h2 { font-size: 1rem; }
  .badge { display: inline-block; padding: 0.15rem 0.5rem; border-radius: 0.25rem; font-weight: 600; }
  .badge.live { background: #1a7f37; color: #ffffff; }
  .badge.stale { background: #9a6700; color: #ffffff; }
  .badge.offline { background: #a40e26; color: #ffffff; }
  .badge.nodata { background: #6e7781; color: #ffffff; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
  th, td { text-align: left; padding: 0.25rem; border-bottom: 1px solid rgba(127, 127, 127, 0.3); }
  section.host { margin-bottom: 1.5rem; }
  @media (prefers-color-scheme: dark) {
    body { background: #111111; color: #eeeeee; }
    th, td { border-bottom-color: rgba(255, 255, 255, 0.2); }
  }
</style>
</head>
<body>
<h1>Pipeline status</h1>
${body}
</body>
</html>`;
}
