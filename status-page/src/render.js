// src/render.js — server-rendered HTML page. No JS emitted, no third-party resources.
//
// Mobile-first at 375px, prefers-color-scheme light/dark, inline <style>, <meta
// http-equiv="refresh" content="..."> driven by a page-refresh constant (AC15). Every value
// passes through esc() even though the payload is already enum-validated (defence in depth,
// tested directly per skills/quality-gate/SKILL.md).

import { isIssueUrl } from './validate.js';
import { groupTickets } from './group.js';
import { PIPELINES } from './pipelines.js';

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
const NEEDS_COLUMNS = ['Issue', 'Ticket', 'Needs', 'Host', 'State', 'Stage', 'Marker', 'Last activity', 'Restarts'];
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
const needsCells = (run) => {
  const cells = runCells(run);
  cells.splice(2, 0, esc(run.needs));
  return cells;
};
const BLOCK_LABELS = {
  ci_pending: 'CI/billing',
  ci_red: 'CI/billing',
  merge_conflict: 'merge conflict',
  dependency: 'waiting on dependency',
  unsupported_project: 'other',
  other: 'other',
};
const parkedCells = (run) => {
  const cells = runCells(run);
  const label = BLOCK_LABELS[run.block_class];
  if (label) cells[5] = `${esc(run.marker)} — ${esc(label)}`; // fixed reason in the existing Marker cell
  return cells;
};
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
  'Needs JP': { columns: NEEDS_COLUMNS, cells: needsCells },
  Parked: { columns: RUN_COLUMNS, cells: parkedCells },
  'Approved, waiting for a slot': { columns: LIST_COLUMNS, cells: listCells },
  'On staging (awaiting production)': { columns: LIST_COLUMNS, cells: listCells },
  Done: { columns: DONE_COLUMNS, cells: doneCells },
};
const RUN_LAYOUT = { columns: RUN_COLUMNS, cells: runCells };

function renderGroupSection(group) {
  const { columns, cells } = LAYOUTS[group.heading] || RUN_LAYOUT;
  const byMilestone = group.heading === 'Needs JP';
  const label = (row) => (typeof row.milestone === 'string' && row.milestone ? row.milestone : 'no release');
  const sameGroup = (a, b) => label(a) === label(b) && a.repo === b.repo;
  const headerFor = (row, i) => {
    if (!byMilestone || (i > 0 && sameGroup(group.rows[i - 1], row))) return '';
    const n = group.rows.filter((r) => sameGroup(r, row)).length;
    return `<tr><td colspan="${columns.length}">${esc(`${label(row)} (${row.repo}) — ${n} waiting`)}</td></tr>`;
  };
  const rows = group.rows.length
    ? group.rows.map((row, i) => `${headerFor(row, i)}<tr>${cells(row).map((c) => `<td>${c}</td>`).join('')}</tr>`).join('')
    : `<tr><td colspan="${columns.length}">none</td></tr>`;
  return `<section class="group">
    <h2>${esc(group.heading)} (${group.rows.length})</h2>
    <table>
      <tr>${columns.map((c) => `<th>${esc(c)}</th>`).join('')}</tr>
      <tbody>${rows}</tbody>
    </table>
  </section>`;
}

const GOAL_STATE_LABELS = { waiting_jp: 'waiting on JP', held: 'held', running: 'running', between_cycles: 'between cycles' };
const GOAL_STATE_ORDER = ['waiting_jp', 'held', 'running', 'between_cycles'];
const GOAL_COLUMNS = ['Goal', 'Host', 'State', 'Delivered', 'Last cycle'];

/** Merges both hosts' goals: one entry per id — the goal's own host's report wins, else the newer received_at. */
function mergeGoals(hosts) {
  const winners = new Map();
  for (const hostKey of ['mac', 'vm']) {
    const rec = hosts[hostKey];
    if (!rec || !Array.isArray(rec.goals)) continue;
    const at = Date.parse(rec.received_at);
    const receivedMs = Number.isNaN(at) ? 0 : at;
    for (const g of rec.goals) {
      if (!g || typeof g !== 'object' || typeof g.id !== 'string') continue;
      const cand = { goal: g, own: g.host === hostKey, receivedMs };
      const cur = winners.get(g.id);
      if (!cur || (cand.own && !cur.own) || (cand.own === cur.own && cand.receivedMs > cur.receivedMs)) {
        winners.set(g.id, cand);
      }
    }
  }
  const rank = (g) => {
    const i = GOAL_STATE_ORDER.indexOf(g.state);
    return i === -1 ? GOAL_STATE_ORDER.length : i;
  };
  return [...winners.values()]
    .map((w) => w.goal)
    .sort((a, b) => rank(a) - rank(b) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

function renderGoalsSection(hosts) {
  const goals = mergeGoals(hosts);
  if (goals.length === 0) return '';
  const delivered = (g) =>
    Number.isInteger(g.scope_delivered) && Number.isInteger(g.scope_total) ? `${g.scope_delivered}/${g.scope_total}` : '–';
  const cells = (g) => [
    esc(g.spec),
    esc(HOST_LABELS[g.host] || g.host),
    `<span class="badge goal-${esc(g.state)}">${esc(GOAL_STATE_LABELS[g.state] || g.state)}</span>`,
    esc(delivered(g)),
    esc(formatCet(g.last_cycle_at) || '–'),
  ];
  const rows = goals.map((g) => `<tr>${cells(g).map((c) => `<td>${c}</td>`).join('')}</tr>`).join('');
  return `<section class="group">
    <h2>Goals</h2>
    <table>
      <tr>${GOAL_COLUMNS.map((c) => `<th>${esc(c)}</th>`).join('')}</tr>
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

/** Two-link nav ("Status" | "Pipelines"); the current page gets aria-current. */
function renderNav(current) {
  const link = (href, label, key) =>
    `<a href="${href}"${current === key ? ' aria-current="page"' : ''}>${label}</a>`;
  return `<nav>${link('/', 'Status', 'status')} ${link('/pipelines', 'Pipelines', 'pipelines')}</nav>`;
}

const NAV_CSS = `  nav { margin-bottom: 0.75rem; }
  nav a { margin-right: 1rem; color: inherit; }
  nav a[aria-current="page"] { font-weight: 700; text-decoration: none; }`;

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
    : `${renderHostSection('mac', hosts.mac, thresholds, nowEpochSecs)}${renderHostSection('vm', hosts.vm, thresholds, nowEpochSecs)}${renderGoalsSection(hosts)}${groupTickets(hosts, nowEpochSecs).map(renderGroupSection).join('')}`;

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
  .badge.goal-running { background: #1a7f37; color: #ffffff; }
  .badge.goal-waiting_jp { background: #9a6700; color: #ffffff; }
  .badge.goal-held { background: #a40e26; color: #ffffff; }
  .badge.goal-between_cycles { background: #6e7781; color: #ffffff; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
  th, td { text-align: left; padding: 0.25rem; border-bottom: 1px solid rgba(127, 127, 127, 0.3); }
  section.host, section.group { margin-bottom: 1.5rem; }
${NAV_CSS}
  @media (prefers-color-scheme: dark) {
    body { background: #111111; color: #eeeeee; }
    th, td { border-bottom-color: rgba(255, 255, 255, 0.2); }
  }
</style>
</head>
<body>
${renderNav('status')}
<h1>Pipeline status</h1>
${body}
</body>
</html>`;
}

const PIPELINES_CSS = `  :root { color-scheme: light dark; }
  body { font-family: system-ui, sans-serif; margin: 0; padding: 1rem; max-width: 100%; overflow-wrap: anywhere; background: #ffffff; color: #111111; }
  h1 { font-size: 1.1rem; }
  h2 { font-size: 1rem; }
${NAV_CSS}
  section.group { margin-bottom: 1.5rem; }
  ol.track { list-style: none; margin: 0; padding: 0; max-width: 100%; }
  ol.track li { margin: 0; padding: 0; max-width: 100%; }
  .chip { display: inline-block; max-width: 100%; margin: 0.25rem 0; padding: 0.1rem 0.5rem; border-radius: 1rem; font-size: 0.8rem; background: #ddf4ff; color: #0a3069; }
  .chip[data-soon] { background: #fff8c5; color: #4d2d00; border: 1px dashed #9a6700; }
  .arrow { display: block; margin: 0.1rem 0 0.1rem 1rem; }
  .box { display: block; max-width: 100%; box-sizing: border-box; padding: 0.4rem 0.6rem; border: 1px solid rgba(127, 127, 127, 0.6); border-radius: 0.25rem; }
  @media (prefers-color-scheme: dark) {
    body { background: #111111; color: #eeeeee; }
    .chip { background: #0c2d6b; color: #cae8ff; }
    .chip[data-soon] { background: #3b2300; color: #ffe8a3; border-color: #d29922; }
  }`;

function renderTrack(track) {
  const items = track.stages
    .map((stage, i) => {
      const when = stage.when;
      const chip = when
        ? `<span class="chip"${when.coming ? ' data-soon="1"' : ''}>${esc(when.label)}${when.coming ? ' (coming)' : ''}</span>`
        : '<span class="chip" hidden></span>';
      const arrow = i > 0 ? '<span class="arrow" aria-hidden="true">&darr;</span>' : '';
      return `<li>${arrow}${chip}<span class="box">${esc(stage.name)}</span></li>`;
    })
    .join('');
  return `<section class="group"><h2>${esc(track.title)}</h2><ol class="track">${items}</ol></section>`;
}

/**
 * Pipelines tab: server-rendered routing diagram, no JS.
 * @param {Array<object>} [data]
 * @returns {string} full HTML document
 */
export function renderPipelines(data = PIPELINES) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pipelines</title>
<style>
${PIPELINES_CSS}
</style>
</head>
<body>
${renderNav('pipelines')}
<h1>How tickets are routed</h1>
${data.map(renderTrack).join('')}
</body>
</html>`;
}
