// src/render.js — server-rendered HTML page. No JS emitted, no third-party resources.
//
// Mobile-first at 375px, prefers-color-scheme light/dark, inline <style>, <meta
// http-equiv="refresh" content="..."> driven by a page-refresh constant (AC15). Every value
// passes through esc() even though the payload is already enum-validated (defence in depth,
// tested directly per skills/quality-gate/SKILL.md).

import { isIssueUrl } from './validate.js';

// Auto-refresh interval in seconds. Must stay <= 30 (AC15). Grepped directly by tests.
export const PAGE_REFRESH_SECS = 20;

const HOST_LABELS = { mac: 'Mac', vm: 'VM' };

// Completed table (issue #51): entries closed longer ago than this are not shown.
const COMPLETED_RETENTION_SECS = 7 * 86400;

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

// en-US + formatToParts, never .format() or en-GB: en-GB renders September as "Sept" and
// .format() punctuation varies with the ICU version (issue #29).
const CET_FORMAT = new Intl.DateTimeFormat('en-US', {
  timeZone: 'Europe/Madrid',
  weekday: 'short',
  day: 'numeric',
  month: 'short',
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
});

/**
 * ISO UTC string -> "Sat 19 Sep, 14:05" in Europe/Madrid (CET/CEST switches automatically).
 * Non-string, unparseable or missing input -> '' (never "Invalid Date").
 * @param {unknown} iso
 */
export function formatCet(iso) {
  if (typeof iso !== 'string') return '';
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return '';
  const parts = {};
  for (const part of CET_FORMAT.formatToParts(new Date(ms))) parts[part.type] = part.value;
  return `${parts.weekday} ${parts.day} ${parts.month}, ${parts.hour}:${parts.minute}`;
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

/**
 * Ticket cell: title linked to the issue when `url` passes isIssueUrl (re-checked here — never
 * trust that the stored value was validated), plain-text title otherwise, empty without a title.
 */
function renderTicketCell(run) {
  if (typeof run.title !== 'string' || run.title === '') return '';
  if (!isIssueUrl(run.url)) return esc(run.title);
  return `<a href="${esc(run.url)}" target="_blank" rel="noopener noreferrer">${esc(run.title)}</a>`;
}

function renderRunRow(run) {
  return `<tr>
    <td>#${esc(run.issue)}</td>
    <td>${renderTicketCell(run)}</td>
    <td>${esc(run.state)}</td>
    <td>${esc(run.stage)}</td>
    <td>${esc(run.marker)}</td>
    <td>${esc(formatCet(run.last_activity_at))}</td>
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
    : '<tr><td colspan="7">no active runs</td></tr>';

  return `<section class="host">
    <h2>${esc(label)} <span class="badge ${esc(badge)}">${esc(badge)}</span></h2>
    <p class="last-seen">Last seen: ${esc(formatCet(host.received_at))}</p>
    <p class="capacity">Capacity: running ${esc(capacity.running)} / max ${esc(capacity.max)} (queued ${esc(capacity.queued)})</p>
    <table>
      <thead>
        <tr><th>Issue</th><th>Ticket</th><th>State</th><th>Stage</th><th>Marker</th><th>Last activity</th><th>Restarts</th></tr>
      </thead>
      <tbody>${runRows}</tbody>
    </table>
  </section>`;
}

/** Merges both hosts' completed[]: parseable closed_at within 7 days, de-duplicated (url, else repo+issue) keeping the later closed_at, newest first. */
function mergeCompleted(hosts, nowEpochSecs) {
  const byKey = new Map();
  for (const host of [hosts.mac, hosts.vm]) {
    if (!host || !Array.isArray(host.completed)) continue;
    for (const item of host.completed) {
      if (!item || typeof item !== 'object') continue;
      const closedMs = typeof item.closed_at === 'string' ? Date.parse(item.closed_at) : NaN;
      if (Number.isNaN(closedMs)) continue;
      if (nowEpochSecs - closedMs / 1000 > COMPLETED_RETENTION_SECS) continue;
      const key = isIssueUrl(item.url) ? item.url : `${item.repo}#${item.issue}`;
      const seen = byKey.get(key);
      if (!seen || closedMs > seen.closedMs) byKey.set(key, { item, closedMs });
    }
  }
  return [...byKey.values()].sort((a, b) => b.closedMs - a.closedMs).map((entry) => entry.item);
}

function renderCompletedRow(item) {
  return `<tr>
    <td>#${esc(item.issue)}</td>
    <td>${renderTicketCell(item)}</td>
    <td>${esc(formatCet(item.closed_at))}</td>
    <td>${esc(item.marker)}</td>
  </tr>`;
}

function renderCompletedSection(hosts, nowEpochSecs) {
  const items = mergeCompleted(hosts, nowEpochSecs);
  const rows = items.length
    ? items.map(renderCompletedRow).join('')
    : '<tr><td colspan="4">no completed tickets</td></tr>';
  return `<section class="completed">
    <h2>Completed</h2>
    <table>
      <thead>
        <tr><th>Issue</th><th>Ticket</th><th>Closed</th><th>Final marker</th></tr>
      </thead>
      <tbody>${rows}</tbody>
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
    : `${renderHostSection('mac', hosts.mac, thresholds, nowEpochSecs)}${renderHostSection('vm', hosts.vm, thresholds, nowEpochSecs)}${renderCompletedSection(hosts, nowEpochSecs)}`;

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
  section.host, section.completed { margin-bottom: 1.5rem; }
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
