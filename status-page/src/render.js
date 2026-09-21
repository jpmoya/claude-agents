// src/render.js — server-rendered HTML page. No JS emitted, no third-party resources.
//
// Mobile-first at 375px, prefers-color-scheme light/dark, inline <style>, <meta
// http-equiv="refresh" content="..."> driven by a page-refresh constant (AC15). Every value
// passes through esc() even though the payload is already enum-validated (defence in depth,
// tested directly per skills/quality-gate/SKILL.md).

import { isIssueUrl } from './validate.js';
import { groupTickets } from './group.js';

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

const RUN_COLUMNS = ['Issue', 'Ticket', 'Host', 'State', 'Stage', 'Marker', 'Last activity', 'Restarts'];
const LIST_COLUMNS = ['Issue', 'Ticket', 'Updated'];
const DONE_COLUMNS = ['Issue', 'Ticket', 'Closed', 'Release', 'Final marker'];

const runCells = (run) => [
  `#${esc(run.issue)}`,
  renderTicketCell(run),
  esc(HOST_LABELS[run.host] || run.host),
  esc(run.state),
  esc(run.stage),
  esc(run.marker),
  esc(formatCet(run.last_activity_at)),
  esc(run.restarts),
];
const listCells = (item) => [`#${esc(item.issue)}`, renderTicketCell(item), esc(formatCet(item.updated_at))];
const doneCells = (item) => [
  `#${esc(item.issue)}`,
  renderTicketCell(item),
  esc(formatCet(item.closed_at)),
  esc(item.release),
  esc(item.marker),
];

// Group heading -> table layout. Headings come from group.js; anything unlisted gets the run layout.
const LAYOUTS = {
  'Approved, waiting for a slot': { columns: LIST_COLUMNS, cells: listCells },
  'On staging (awaiting production)': { columns: LIST_COLUMNS, cells: listCells },
  Done: { columns: DONE_COLUMNS, cells: doneCells },
};
const RUN_LAYOUT = { columns: RUN_COLUMNS, cells: runCells };

function renderGroupSection(group) {
  const { columns, cells } = LAYOUTS[group.heading] || RUN_LAYOUT;
  const rows = group.rows.length
    ? group.rows.map((row) => `<tr>${cells(row).map((c) => `<td>${c}</td>`).join('')}</tr>`).join('')
    : `<tr><td colspan="${columns.length}">none</td></tr>`;
  return `<section class="group">
    <h2>${esc(group.heading)} (${group.rows.length})</h2>
    <table>
      <tr>${columns.map((c) => `<th>${esc(c)}</th>`).join('')}</tr>
      <tbody>${rows}</tbody>
    </table>
  </section>`;
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

  return `<section class="host">
    <h2>${esc(label)} <span class="badge ${esc(badge)}">${esc(badge)}</span></h2>
    <p class="last-seen">Last seen: ${esc(formatCet(host.received_at))}</p>
    <p class="capacity">Capacity: running ${esc(capacity.running)} / max ${esc(capacity.max)} (queued ${esc(capacity.queued)})</p>
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
    : `${renderHostSection('mac', hosts.mac, thresholds, nowEpochSecs)}${renderHostSection('vm', hosts.vm, thresholds, nowEpochSecs)}${groupTickets(hosts, nowEpochSecs).map(renderGroupSection).join('')}`;

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
  section.host, section.group { margin-bottom: 1.5rem; }
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
