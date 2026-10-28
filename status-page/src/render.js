// src/render.js — server-rendered HTML page. No JS emitted, no third-party resources.
//
// Mobile-first at 375px, prefers-color-scheme light/dark, inline <style>, <meta
// http-equiv="refresh" content="..."> driven by a page-refresh constant (AC15). Every value
// passes through esc() even though the payload is already enum-validated (defence in depth,
// tested directly per skills/quality-gate/SKILL.md).

import { isIssueUrl } from "./validate.js";
import { groupTickets } from "./group.js";
import { PIPELINES } from "./pipelines.js";

// Auto-refresh interval in seconds. Must stay <= 30 (AC15). Grepped directly by tests.
export const PAGE_REFRESH_SECS = 20;

const HOST_LABELS = { mac: "Mac", vm: "VM" };

/** @param {unknown} value */
export function esc(value) {
  if (value === null || value === undefined) return "";
  return String(value).replace(/[&<>"']/g, (ch) => {
    switch (ch) {
      case "&":
        return "&amp;";
      case "<":
        return "&lt;";
      case ">":
        return "&gt;";
      case '"':
        return "&quot;";
      case "'":
        return "&#39;";
      default:
        return ch;
    }
  });
}

// en-US + formatToParts, never .format() or en-GB: en-GB renders September as "Sept" and
// .format() punctuation varies with the ICU version (issue #29).
const CET_FORMAT = new Intl.DateTimeFormat("en-US", {
  timeZone: "Europe/Madrid",
  weekday: "short",
  day: "numeric",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

/**
 * ISO UTC string -> "Sat 19 Sep, 14:05" in Europe/Madrid (CET/CEST switches automatically).
 * Non-string, unparseable or missing input -> '' (never "Invalid Date").
 * @param {unknown} iso
 */
export function formatCet(iso) {
  if (typeof iso !== "string") return "";
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return "";
  const parts = {};
  for (const part of CET_FORMAT.formatToParts(new Date(ms)))
    parts[part.type] = part.value;
  return `${parts.weekday} ${parts.day} ${parts.month}, ${parts.hour}:${parts.minute}`;
}

/** Derives the live/stale/offline badge from `received_at` only (never `sent_at`). */
function computeBadge(receivedAt, thresholds, nowEpochSecs) {
  const receivedAtMs =
    typeof receivedAt === "string" ? Date.parse(receivedAt) : NaN;
  if (Number.isNaN(receivedAtMs)) return "offline";
  const ageSecs = nowEpochSecs - Math.floor(receivedAtMs / 1000);
  if (ageSecs >= thresholds.offlineSecs) return "offline";
  if (ageSecs >= thresholds.staleSecs) return "stale";
  return "live";
}

/**
 * Ticket cell: title linked to the issue when `url` passes isIssueUrl (re-checked here — never
 * trust that the stored value was validated), plain-text title otherwise, empty without a title.
 */
function renderTicketCell(run) {
  if (typeof run.title !== "string" || run.title === "") return "";
  if (!isIssueUrl(run.url)) return esc(run.title);
  return `<a href="${esc(run.url)}" target="_blank" rel="noopener noreferrer">${esc(run.title)}</a>`;
}

const RUN_COLUMNS = [
  "Issue",
  "Ticket",
  "Host",
  "State",
  "Stage",
  "Marker",
  "Last activity",
  "Restarts",
];
const NEEDS_COLUMNS = [
  "Issue",
  "Ticket",
  "Needs",
  "Host",
  "State",
  "Stage",
  "Marker",
  "Last activity",
  "Restarts",
];
const LIST_COLUMNS = ["Issue", "Ticket", "Updated"];
const DONE_COLUMNS = ["Issue", "Ticket", "Closed", "Release", "Final marker"];

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
  ci_pending: "CI/billing",
  ci_red: "CI/billing",
  merge_conflict: "merge conflict",
  dependency: "waiting on dependency",
  unsupported_project: "other",
  other: "other",
};
const parkedCells = (run) => {
  const cells = runCells(run);
  const label = BLOCK_LABELS[run.block_class];
  if (label) cells[5] = `${esc(run.marker)} — ${esc(label)}`; // fixed reason in the existing Marker cell
  return cells;
};
const listCells = (item) => [
  `#${esc(item.issue)}`,
  renderTicketCell(item),
  esc(formatCet(item.updated_at)),
];
const doneCells = (item) => [
  `#${esc(item.issue)}`,
  renderTicketCell(item),
  esc(formatCet(item.closed_at)),
  esc(item.release),
  esc(item.marker),
];

// Group heading -> table layout. Headings come from group.js; anything unlisted gets the run layout.
const LAYOUTS = {
  "Needs JP": { columns: NEEDS_COLUMNS, cells: needsCells },
  Parked: { columns: RUN_COLUMNS, cells: parkedCells },
  "Approved, waiting for a slot": { columns: LIST_COLUMNS, cells: listCells },
  "On staging (awaiting production)": {
    columns: LIST_COLUMNS,
    cells: listCells,
  },
  Done: { columns: DONE_COLUMNS, cells: doneCells },
};
const RUN_LAYOUT = { columns: RUN_COLUMNS, cells: runCells };

/** Zips column headers onto cell values as `<td data-label="...">` — the label a narrow-screen row stacks on. */
function tdsFor(columns, values) {
  return values
    .map((c, i) => `<td data-label="${esc(columns[i] ?? "")}">${c}</td>`)
    .join("");
}

function renderGroupSection(group) {
  const { columns, cells } = LAYOUTS[group.heading] || RUN_LAYOUT;
  const byMilestone = group.heading === "Needs JP";
  const label = (row) =>
    typeof row.milestone === "string" && row.milestone
      ? row.milestone
      : "no release";
  const sameGroup = (a, b) => label(a) === label(b) && a.repo === b.repo;
  const headerFor = (row, i) => {
    if (!byMilestone || (i > 0 && sameGroup(group.rows[i - 1], row))) return "";
    const n = group.rows.filter((r) => sameGroup(r, row)).length;
    return `<tr class="subhead"><td colspan="${columns.length}">${esc(`${label(row)} (${row.repo}) — ${n} waiting`)}</td></tr>`;
  };
  const rows = group.rows.length
    ? group.rows
        .map(
          (row, i) =>
            `${headerFor(row, i)}<tr>${tdsFor(columns, cells(row))}</tr>`,
        )
        .join("")
    : `<tr><td colspan="${columns.length}">none</td></tr>`;
  return `<section class="group">
    <h2>${esc(group.heading)} (${group.rows.length})</h2>
    <div class="table-scroll"><table>
      <tr class="cols">${columns.map((c) => `<th>${esc(c)}</th>`).join("")}</tr>
      <tbody>${rows}</tbody>
    </table></div>
  </section>`;
}

const GOAL_STATE_LABELS = {
  waiting_jp: "waiting on JP",
  held: "held",
  running: "running",
  between_cycles: "between cycles",
  queued: "queued",
};
const GOAL_STATE_ORDER = [
  "waiting_jp",
  "held",
  "running",
  "between_cycles",
  "queued",
];
const GOAL_CLOSED_LABELS = { delivered: "delivered", stopped: "stopped" };
const GOALS_CLOSED_SHOWN = 5;

/** Plain-language meaning of each goal state, from goal-lib.sh / build-runs-json.py (the order shown in the Legend). */
export const GOAL_LEGEND = [
  [
    "running",
    "The delivery lead is working on the goal right now (its process is alive).",
  ],
  [
    "between cycles",
    "Started and not stuck, but no process is running at this moment; the next cycle picks it up.",
  ],
  [
    "waiting on JP",
    "No ticket can move on its own: the open ones wait on a decision or promotion only JP can give (mockup approval, go, or a promotion). Shown from the tickets themselves, even when no delivery lead is running.",
  ],
  [
    "held",
    "Stopped by itself after several cycles without progress; it needs a look before it resumes.",
  ],
  [
    "queued",
    "Registered but not started yet; the number is its place in the start order (1 = next). A GitHub project with no running goal yet also shows here, linked to the project.",
  ],
  ["delivered", "Finished: every ticket in the goal has shipped."],
  [
    "stopped",
    "Cancelled by hand with the stop command; it does not run again unless resumed.",
  ],
];

function renderLegend() {
  const items = GOAL_LEGEND.map(
    ([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`,
  ).join("");
  return `<section class="group legend">
    <h2>Legend</h2>
    <h3>Goal states</h3>
    <dl>${items}</dl>
  </section>`;
}

/** A goal's name, linked to its ticket search / milestone / issue (already validated by validate.js as a github.com URL). */
function goalName(g, text) {
  const name = esc(text);
  return typeof g.url === "string" && g.url.startsWith("https://github.com/")
    ? `<a href="${esc(g.url)}" target="_blank" rel="noopener">${name}</a>`
    : name;
}
const GOAL_COLUMNS = [
  "Priority",
  "Goal",
  "Host",
  "State",
  "Delivered",
  "Last cycle",
];

/**
 * True when report `a` of a goal beats report `b`: a started goal beats a queued one (a stale queue view), then the goal's
 * own host's report, then a queued report that carries the pause reason (#320: only the Mac knows it is on battery),
 * then the newer received_at.
 */
function beats(a, b) {
  const started = (c) => (c.goal.state === "queued" ? 0 : 1);
  if (started(a) !== started(b)) return started(a) > started(b);
  if (a.own !== b.own) return a.own;
  const paused = (c) => (c.goal.paused ? 1 : 0);
  if (paused(a) !== paused(b)) return paused(a) > paused(b);
  return a.receivedMs > b.receivedMs;
}

/** Merges both hosts' goals: one entry per id — see beats(). */
function mergeGoals(hosts) {
  const winners = new Map();
  for (const hostKey of ["mac", "vm"]) {
    const rec = hosts[hostKey];
    if (!rec || !Array.isArray(rec.goals)) continue;
    const at = Date.parse(rec.received_at);
    const receivedMs = Number.isNaN(at) ? 0 : at;
    for (const g of rec.goals) {
      if (!g || typeof g !== "object" || typeof g.id !== "string") continue;
      const cand = { goal: g, own: g.host === hostKey, receivedMs };
      const cur = winners.get(g.id);
      if (!cur || beats(cand, cur)) winners.set(g.id, cand);
    }
  }
  const rank = (g) => {
    const i = GOAL_STATE_ORDER.indexOf(g.state);
    return i === -1 ? GOAL_STATE_ORDER.length : i;
  };
  return [...winners.values()]
    .map((w) => w.goal)
    .sort(
      (a, b) =>
        (Number.isInteger(a.priority) ? a.priority : 1e9) -
          (Number.isInteger(b.priority) ? b.priority : 1e9) ||
        rank(a) - rank(b) ||
        (a.state === "queued" && b.state === "queued"
          ? (a.queue_pos || 0) - (b.queue_pos || 0)
          : 0) ||
        (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
    );
}

/** "queued #2" for a queued goal (position in the queue, 1 = next), else the plain state label. */
function goalStateText(g) {
  const label = GOAL_STATE_LABELS[g.state] || g.state;
  return g.state === "queued" && Number.isInteger(g.queue_pos)
    ? `${label} #${g.queue_pos}`
    : label;
}

/** Compact list of the most recent closed goals: "Title (repos) — delivered, 20 Sep". */
function renderClosedGoals(closed) {
  if (closed.length === 0) return "";
  const recent = [...closed]
    .sort(
      (a, b) =>
        (b.closed_at || "").localeCompare(a.closed_at || "") ||
        (a.id < b.id ? -1 : 1),
    )
    .slice(0, GOALS_CLOSED_SHOWN);
  const items = recent
    .map((g) => {
      const name = goalName(g, g.title || g.spec);
      const when = g.closed_at ? `, ${esc(formatCet(g.closed_at))}` : "";
      return `<li>${name} — <span class="badge goal-${esc(g.state)}">${esc(GOAL_CLOSED_LABELS[g.state])}</span>${when}</li>`;
    })
    .join("");
  return `<div class="goals-closed"><h3>Recently closed</h3><ul>${items}</ul></div>`;
}

function renderGoalsSection(hosts) {
  const all = mergeGoals(hosts);
  const closed = all.filter((g) => g.state in GOAL_CLOSED_LABELS);
  const goals = all.filter((g) => !(g.state in GOAL_CLOSED_LABELS));
  if (all.length === 0) return "";
  const delivered = (g) =>
    Number.isInteger(g.scope_delivered) && Number.isInteger(g.scope_total)
      ? `${g.scope_delivered}/${g.scope_total}`
      : "–";
  // a cross-repo label goal (#319) shows its title, repos and order; a v1 goal its spec
  const goalCell = (g) =>
    g.title
      ? `<strong>${goalName(g, g.title)}</strong><br><small>${esc((g.repos || []).join(", "))}${Number.isInteger(g.order) ? ` · order ${esc(String(g.order))}` : ""}</small>`
      : goalName(g, g.spec);
  // the number shown is the goal's place in the start order (1 = next); it renumbers by itself as goals finish
  const cells = (g, i) => [
    esc(String(i + 1)),
    goalCell(g),
    esc(HOST_LABELS[g.host] || g.host || "–"),
    `<span class="badge goal-${esc(g.state)}${g.state === "queued" ? " goal-between_cycles" : ""}">${esc(goalStateText(g))}</span>${g.paused ? `<br><small>paused: ${esc(g.paused)}</small>` : ""}`,
    esc(delivered(g)),
    esc(formatCet(g.last_cycle_at) || "–"),
  ];
  const rows = goals
    .map((g, i) => `<tr>${tdsFor(GOAL_COLUMNS, cells(g, i))}</tr>`)
    .join("");
  const table =
    goals.length === 0
      ? ""
      : `<div class="table-scroll"><table>
      <tr class="cols">${GOAL_COLUMNS.map((c) => `<th>${esc(c)}</th>`).join("")}</tr>
      <tbody>${rows}</tbody>
    </table></div>`;
  return `<section class="group">
    <h2>Goals</h2>
    ${table}${renderClosedGoals(closed)}
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
  const capacity =
    host.capacity && typeof host.capacity === "object" ? host.capacity : {};

  return `<section class="host">
    <h2>${esc(label)} <span class="badge ${esc(badge)}">${esc(badge)}</span></h2>
    <p class="last-seen">Last seen: ${esc(formatCet(host.received_at))}</p>
    <p class="capacity">Capacity: running ${esc(capacity.running)} / max ${esc(capacity.max)} (queued ${esc(capacity.queued)})</p>
  </section>`;
}

/** Two-link nav ("Status" | "Pipelines"); the current page gets aria-current. */
function renderNav(current) {
  const link = (href, label, key) =>
    `<a href="${href}"${current === key ? ' aria-current="page"' : ""}>${label}</a>`;
  return `<nav>${link("/", "Status", "status")} ${link("/pipelines", "Pipelines", "pipelines")}</nav>`;
}

const ROOT_VARS_CSS = `  :root {
    color-scheme: light dark;
    --bg: #f7f8fa; --surface: #ffffff; --border: #e5e7eb; --text: #16181d; --muted: #6b7280;
    --accent: #4f46e5; --accent-soft: rgba(79, 70, 229, 0.1);
    --green: #16a34a; --green-soft: rgba(22, 163, 74, 0.12);
    --amber: #b45309; --amber-soft: rgba(217, 119, 6, 0.14);
    --red: #dc2626; --red-soft: rgba(220, 38, 38, 0.12);
    --gray: #6b7280; --gray-soft: rgba(107, 114, 128, 0.14);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0b0d10; --surface: #15181c; --border: #262a30; --text: #e6e8eb; --muted: #9aa1ab;
      --accent: #818cf8; --accent-soft: rgba(129, 140, 248, 0.16);
      --green: #4ade80; --green-soft: rgba(74, 222, 128, 0.14);
      --amber: #fbbf24; --amber-soft: rgba(251, 191, 36, 0.14);
      --red: #f87171; --red-soft: rgba(248, 113, 113, 0.14);
      --gray: #9aa1ab; --gray-soft: rgba(154, 161, 171, 0.14);
    }
  }
  * { box-sizing: border-box; }`;

const NAV_CSS = `  nav { margin-bottom: 1.5rem; display: flex; gap: 1.25rem; border-bottom: 1px solid var(--border); }
  nav a { padding: 0 0 0.6rem; color: var(--muted); text-decoration: none; font-weight: 500; font-size: 0.9rem; border-bottom: 2px solid transparent; margin-bottom: -1px; }
  nav a:hover { color: var(--text); }
  nav a[aria-current="page"] { color: var(--text); font-weight: 600; border-bottom-color: var(--accent); }`;

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
    : `${renderHostSection("mac", hosts.mac, thresholds, nowEpochSecs)}${renderHostSection("vm", hosts.vm, thresholds, nowEpochSecs)}${renderGoalsSection(hosts)}${renderLegend()}${groupTickets(hosts, nowEpochSecs).map(renderGroupSection).join("")}`;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="${PAGE_REFRESH_SECS}">
<title>Pipeline status</title>
<style>
${ROOT_VARS_CSS}
  body { font-family: -apple-system, "Inter", "Segoe UI", system-ui, sans-serif; margin: 0; padding: 1.5rem;
    max-width: 72rem; background: var(--bg); color: var(--text); -webkit-font-smoothing: antialiased; }
  h1 { font-size: 1.3rem; font-weight: 700; margin: 0 0 1.25rem; letter-spacing: -0.01em; }
  h2 { font-size: 0.95rem; font-weight: 600; margin: 0 0 0.75rem; }
  .badge { display: inline-flex; align-items: center; gap: 0.3em; padding: 0.15rem 0.6rem; border-radius: 0.375rem;
    font-weight: 600; font-size: 0.75rem; line-height: 1.4; }
  .badge.live { background: var(--green-soft); color: var(--green); }
  .badge.stale { background: var(--amber-soft); color: var(--amber); }
  .badge.offline { background: var(--red-soft); color: var(--red); }
  .badge.nodata { background: var(--gray-soft); color: var(--gray); }
  .badge.goal-running { background: var(--green-soft); color: var(--green); }
  .badge.goal-waiting_jp { background: var(--amber-soft); color: var(--amber); }
  .badge.goal-held { background: var(--red-soft); color: var(--red); }
  .badge.goal-between_cycles { background: var(--gray-soft); color: var(--gray); }
  .badge.goal-delivered { background: var(--green-soft); color: var(--green); }
  .badge.goal-stopped { background: var(--gray-soft); color: var(--gray); }
  .legend h3 { font-size: 0.8rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); margin: 1em 0 0.5em; }
  .legend dt { font-weight: 600; margin-top: 0.6em; font-size: 0.85rem; }
  .legend dd { margin: 0.1em 0 0 0; color: var(--muted); font-size: 0.85rem; }
  .goals-closed h3 { font-size: 0.8rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); margin: 1.25em 0 0.5em; }
  .goals-closed ul { margin: 0; padding-left: 1.1em; font-size: 0.85rem; color: var(--muted); }
  a { color: var(--accent); }
  .table-scroll { overflow-x: auto; -webkit-overflow-scrolling: touch; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
  th { text-align: left; padding: 0.5rem 0.6rem; font-weight: 600; font-size: 0.75rem; text-transform: uppercase;
    letter-spacing: 0.03em; color: var(--muted); border-bottom: 1px solid var(--border); }
  td { text-align: left; padding: 0.55rem 0.6rem; border-bottom: 1px solid var(--border); }
  tbody tr:hover { background: var(--accent-soft); }
  tbody tr:last-child td { border-bottom: none; }
  section.host, section.group { margin-bottom: 1.25rem; padding: 1.1rem 1.25rem; border-radius: 0.75rem;
    background: var(--surface); border: 1px solid var(--border); }
${NAV_CSS}
  @media (max-width: 640px) {
    body { padding: 1rem; }
    section.host, section.group { padding: 0.9rem; }
    .table-scroll { overflow-x: visible; }
    table, tbody { display: block; width: 100%; }
    tr.cols { display: none; }
    tbody tr { display: block; border: 1px solid var(--border); border-radius: 0.5rem; margin-bottom: 0.6rem; overflow: hidden; }
    tbody tr:last-child { margin-bottom: 0; }
    tbody tr.subhead { border: none; border-radius: 0; margin: 0 0 0.4rem; }
    td { display: flex; justify-content: space-between; align-items: baseline; gap: 1rem; text-align: right; border-bottom: 1px solid var(--border); }
    tbody tr td:last-child { border-bottom: none; }
    td[data-label]::before { content: attr(data-label); font-weight: 600; font-size: 0.7rem; text-transform: uppercase;
      letter-spacing: 0.03em; color: var(--muted); text-align: left; flex-shrink: 0; }
    td[colspan] { display: block; text-align: left; font-weight: 600; border-bottom: none; padding: 0.3rem 0.1rem; }
  }
</style>
</head>
<body>
${renderNav("status")}
<h1>Pipeline status</h1>
${body}
</body>
</html>`;
}

const PIPELINES_CSS = `${ROOT_VARS_CSS}
  body { font-family: -apple-system, "Inter", "Segoe UI", system-ui, sans-serif; margin: 0; padding: 1.5rem; max-width: 72rem; overflow-wrap: anywhere;
    background: var(--bg); color: var(--text); -webkit-font-smoothing: antialiased; }
  h1 { font-size: 1.3rem; font-weight: 700; margin: 0 0 1.25rem; letter-spacing: -0.01em; }
  h2 { font-size: 0.95rem; font-weight: 600; margin: 0 0 0.75rem; }
  a { color: var(--accent); }
${NAV_CSS}
  section.group { margin-bottom: 1.25rem; padding: 1.1rem 1.25rem; border-radius: 0.75rem;
    background: var(--surface); border: 1px solid var(--border); }
  .intake-docs h3 { font-size: 0.85rem; font-weight: 600; margin: 0.9rem 0 0.35rem; }
  .intake-docs h3:first-child { margin-top: 0; }
  .intake-docs p { margin: 0 0 0.5rem; font-size: 0.85rem; color: var(--text); line-height: 1.5; }
  .intake-docs ul { margin: 0 0 0.5rem; padding-left: 1.3rem; font-size: 0.85rem; color: var(--text); line-height: 1.5; }
  .intake-docs code { background: var(--bg); border: 1px solid var(--border); border-radius: 0.25rem; padding: 0.05rem 0.3rem; font-size: 0.82em; }
  .intake-docs li strong { color: var(--accent); }
  .story p { margin: 0 0 0.6rem; font-size: 0.88rem; color: var(--text); line-height: 1.55; }
  .story ol { margin: 0 0 0.5rem; padding-left: 1.4rem; font-size: 0.85rem; color: var(--text); line-height: 1.6; }
  .story li { margin-bottom: 0.3rem; }
  .category { margin: 1.75rem 0 0.75rem; }
  .category:first-of-type { margin-top: 1.25rem; }
  .category-title { font-size: 1.05rem; font-weight: 700; margin: 0 0 0.2rem; letter-spacing: -0.01em; }
  .category-note { font-size: 0.85rem; color: var(--muted); margin: 0 0 0.9rem; line-height: 1.5; }
  .track-summary { font-size: 0.82rem; color: var(--muted); margin: -0.35rem 0 0.75rem; line-height: 1.45; }
  .uml-scroll { overflow-x: auto; max-width: 100%; padding-bottom: 0.3rem; }
  .uml { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: row; align-items: stretch; gap: 0; width: max-content; }
  .uml li { max-width: 18rem; display: flex; align-items: center; }
  .uml .link { display: flex; align-items: center; justify-content: center; width: 1.8rem; flex: 0 0 auto;
    color: var(--muted); font-size: 1.1rem; align-self: center; }
  .uml .node { border: 1px solid var(--border); border-radius: 0.5rem; max-width: 18rem; box-sizing: border-box; overflow: hidden; }
  .uml .node b { display: block; padding: 0.4rem 0.7rem; font-size: 0.85rem; font-weight: 600;
    background: var(--bg); border-bottom: 1px solid var(--border); }
  .uml .node .chip { display: inline-block; margin: 0.45rem 0.7rem 0; padding: 0.15rem 0.5rem; border-radius: 0.375rem;
    font-size: 0.72rem; font-weight: 600; background: var(--accent-soft); color: var(--accent); }
  .uml .node .chip[data-soon] { background: var(--amber-soft); color: var(--amber); }
  .uml .node ul { margin: 0; padding: 0.4rem 0.7rem 0.4rem 1.7rem; font-size: 0.8rem; color: var(--muted); }
  @media (max-width: 640px) {
    .uml { flex-direction: column; width: 100%; }
    .uml li { max-width: 100%; }
    .uml .node { max-width: 100%; }
    .uml .link { width: auto; height: 1.4rem; transform: rotate(90deg); }
  }`;

/** UML-style box: stage name, the GitHub marker/label that routes into it (if any), and what it reads. */
function renderNode(stage) {
  const when = stage.when;
  const chip = when
    ? `<span class="chip"${when.coming ? ' data-soon="1"' : ""}>${esc(when.label)}${when.coming ? " (coming)" : ""}</span>`
    : "";
  const inputs = (stage.inputs || []).map((x) => `<li>${esc(x)}</li>`).join("");
  return `<div class="node"><b>${esc(stage.name)}</b>${chip}<ul>${inputs}</ul></div>`;
}

function renderTrack(track) {
  const items = track.stages
    .map((stage, i) => {
      const link =
        i > 0 ? '<span class="link" aria-hidden="true">&rarr;</span>' : "";
      return `<li>${link}${renderNode(stage)}</li>`;
    })
    .join("");
  const summary = track.summary
    ? `<p class="track-summary">${esc(track.summary)}</p>`
    : "";
  const id = track.id ? ` id="track-${esc(track.id)}"` : "";
  return `<section class="group"${id}><h2>${esc(track.title)}</h2>${summary}<div class="uml-scroll"><ol class="uml">${items}</ol></div></section>`;
}

/** Plain-language top-to-bottom narration: where a ticket starts, how it gets classified, which lane
 * that puts it in, and how it ships. Not drift-checked — scene-setting prose, not a stage list. */
function renderStory() {
  return `<section class="group story">
    <h2>The story: how a ticket gets from "reported" to "shipped"</h2>
    <p>Every ticket starts at one of five places, gets classified by either the <code>intake</code> agent or <code>product-manager</code>, lands in one of the lanes further down this page, and ships through the same release step at the end. In plain terms, step by step:</p>
    <ol>
      <li><strong>It starts somewhere.</strong> JP tells a session about a bug or idea directly; staff submit it through the in-app feedback form; Sentry's poller files it from a production error; the hourly backlog scan notices an issue nobody filed through those first two; or <code>pipeline-adjudicator</code> files its own self-heal fix ticket after a confirmed pipeline incident.</li>
      <li><strong>Someone classifies it.</strong> The feedback-form and Sentry paths go through the <code>intake</code> agent first, which reads it, decides bug vs. idea vs. duplicate vs. noise, and applies labels. Every other path — JP direct, the backlog scan, the adjudicator's own ticket — skips intake entirely and goes straight to <code>product-manager</code>, which classifies and labels it the same way intake would have.</li>
      <li><strong>Labels decide the lane.</strong> See "What intake decides, and where it lands" just below for the exact mapping. In short: a clear bug usually ends up in the Fast lane; anything bigger, unclear, or needing a spec goes through product-manager's own full review before a lane is picked.</li>
      <li><strong>The lane does the work.</strong> The full lane adds design and architecture gates where a ticket needs them, then locks in tests before the developer builds; the fast lane skips those gates and the developer writes one regression test instead. Both end in a code review.</li>
      <li><strong>It ships.</strong> Every lane finishes at the same release step: the deployer merges once both reviewers pass, and a risky-list change (a destructive database change, for instance) still waits on JP's own go-ahead — everything else goes out on its own.</li>
    </ol>
  </section>`;
}

/** Static documentation: how intake and product-manager classify a ticket, what each outcome is
 * called, and which track below it lands in. Not drift-checked — these mechanisms live in
 * supervisor.sh/agents, not in a PIPELINES stage list. */
function renderIntakeDocs() {
  return `<section class="group intake-docs">
    <h2>How tickets get picked up</h2>
    <h3><code>intake</code> is a classifier, not a lane — it runs before a ticket ever reaches one</h3>
    <p>The <code>intake</code> agent only ever triages one kind of raw input: a staff-feedback-form submission, or a Sentry-filed issue. It never appears as a stage in any track below — its whole job is to read that raw report, decide bug vs. idea vs. duplicate vs. noise, and attach the labels that route the ticket into <code>product-manager</code> and from there into a lane. A ticket JP reports directly, or that the backlog scan surfaces, never passes through intake at all: <code>product-manager</code> classifies and labels those itself.</p>
    <h3>What intake decides, and where it lands</h3>
    <ul>
      <li><strong>Feedback-form bug</strong> &rarr; intake labels it <code>bug</code> + <code>fast-lane</code> (a hint, not a guarantee) + <code>user-feedback</code>. <code>product-manager</code> then usually honours that hint and sends it into the <a href="#track-fast">Fast lane</a> — unless the fix needs a schema change or a new endpoint, which forces the <a href="#track-lane-rule">Lane rule</a> to pick the full lane instead.</li>
      <li><strong>Feedback-form idea, unclear report, or one missing required info</strong> &rarr; intake labels it <code>user-feedback-needs-spec</code>. A product-manager-only run writes the spec; it is not in any lane yet — it only enters one once that spec is approved and labelled into a lane.</li>
      <li><strong>Sentry-filed bug</strong> &rarr; intake labels it <code>bug</code> + <code>user-feedback</code>, never <code>fast-lane</code>. It waits for JP's go-ahead (or an auto-go setting), then <code>product-manager</code> picks the <a href="#track-code">full</a> or <a href="#track-fast">fast</a> lane itself, the same way it would for any other ticket.</li>
      <li><strong>Sentry noise, or a duplicate intake matches to an existing ticket</strong> &rarr; closed immediately by intake. It never reaches a lane.</li>
      <li><strong>JP reports a bug or idea directly to a session, or the hourly backlog scan surfaces one</strong> &rarr; no <code>intake</code> agent involved at all. <code>product-manager</code> classifies and labels it the same way, then routes it into a lane exactly as above.</li>
      <li><strong>A self-heal fix ticket from <code>pipeline-adjudicator</code></strong> &rarr; the adjudicator labels and queues its own ticket, bypassing intake (and the usual goal wait) the same way a direct JP report does.</li>
    </ul>
    <h3>Where the <code>user-feedback</code> label matters</h3>
    <p>The supervisor's dispatch loop normally only starts a ticket's own goal. <code>user-feedback</code> is the one exception: a ticket carrying that label is auto-dispatched even with no goal covering it. Everything else with just <code>agent-go</code> and no goal sits unclaimed until someone registers a goal for it.</p>
    <h3>What a "goal" is</h3>
    <p>A goal only exists if someone explicitly registers one with <code>deliver.sh</code> (a milestone, a single issue, "all milestones", or the standing staff-feedback goal). Goals are never created automatically.</p>
    <h3>How a ticket joins a goal</h3>
    <p>Automatically, once a goal that covers it has been registered: a milestone goal covers every ticket in that milestone, a single-issue goal covers just that issue, and the standing feedback goal covers every open <code>user-feedback</code> ticket that no other goal covers. Stopping a goal does not hand its tickets to the feedback goal: they wait until JP releases them (<code>deliver.sh release</code>). A ticket in an unregistered milestone is covered by nothing.</p>
  </section>`;
}

/** Plain-language heading + one-line note shown above each group of tracks (render-only; a track
 * with no `group`, or an unrecognised one, is rendered after these with no heading of its own). */
const TRACK_GROUPS = [
  {
    key: "main",
    heading: "The normal path for most tickets",
    note: "Every ordinary ticket moves through one of these — a fuller build with review gates, or a quick fix that skips them — and the rule below decides which.",
  },
  {
    key: "special",
    heading: "Special cases — only some tickets hit these",
    note: "Infrastructure changes, pipeline incidents, an unattended multi-ticket lead, and the shared release step every lane ends at.",
  },
];

/** Groups tracks by `group` (preserving each group's relative order), then renders a heading +
 * note per known group, falling back to an unheaded run for anything ungrouped. */
function renderGroupedTracks(data) {
  const byGroup = new Map(TRACK_GROUPS.map((g) => [g.key, []]));
  const rest = [];
  for (const track of data) {
    const bucket = byGroup.get(track.group);
    if (bucket) bucket.push(track);
    else rest.push(track);
  }
  const groups = TRACK_GROUPS.map((g) => {
    const tracks = byGroup.get(g.key);
    if (tracks.length === 0) return "";
    return `<div class="category"><h2 class="category-title">${esc(g.heading)}</h2><p class="category-note">${esc(g.note)}</p>${tracks.map(renderTrack).join("")}</div>`;
  }).join("");
  return `${groups}${rest.map(renderTrack).join("")}`;
}

/**
 * Pipelines tab: one UML-style diagram per lane (stage, routing marker/label, inputs), server-rendered, no JS.
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
${renderNav("pipelines")}
<h1>How tickets are routed</h1>
${renderStory()}
${renderIntakeDocs()}
${renderGroupedTracks(data)}
</body>
</html>`;
}
