// src/group.js — pure grouping of both hosts' facts into one row per ticket, one group per ticket
// (issue #62). No I/O, no rendering.

import { isIssueUrl } from './validate.js';

const DAY_SECS = 86400;
const DONE_RETENTION_SECS = 7 * DAY_SECS;
const PARKED_MAX_AGE_SECS = 7 * DAY_SECS;
const NEEDS_JP_MARKERS = ['MOCKUPS PENDING APPROVAL', 'AWAITING GO', 'EFFORT APPROVAL NEEDED', 'BLOCKED'];

const HOST_ORDER = ['mac', 'vm']; // tie -> Mac

const HEADINGS = {
  running: 'Running',
  queued: 'Queued',
  approved: 'Approved, waiting for a slot',
  needsJp: 'Needs JP',
  staging: 'On staging (awaiting production)',
  parked: 'Parked',
  done: 'Done',
};

const CAPS = { approved: 20, needsJp: 20, staging: 60, parked: 10, done: 20 };

const keyOf = (item) => (isIssueUrl(item.url) ? item.url : `${item.repo}#${item.issue}`);

function epoch(iso) {
  const ms = typeof iso === 'string' ? Date.parse(iso) : NaN;
  return Number.isNaN(ms) ? null : ms / 1000;
}

/** Newest first; missing/unparseable timestamps last. */
function newestFirst(rows, field) {
  return [...rows].sort((a, b) => {
    const ta = epoch(a[field]);
    const tb = epoch(b[field]);
    if (ta === null && tb === null) return 0;
    if (ta === null) return 1;
    if (tb === null) return -1;
    return tb - ta;
  });
}

function listOf(host, name) {
  return host && Array.isArray(host[name]) ? host[name].filter((i) => i && typeof i === 'object') : [];
}

/** Merges a list across hosts, one item per key; `field` decides which copy wins (later, else first seen). */
function mergeList(hosts, name, field, keep = () => true) {
  const byKey = new Map();
  for (const hostKey of HOST_ORDER) {
    for (const item of listOf(hosts[hostKey], name)) {
      if (!keep(item)) continue;
      const key = keyOf(item);
      const seen = byKey.get(key);
      if (!seen || (epoch(item[field]) ?? -Infinity) > (epoch(seen[field]) ?? -Infinity)) byKey.set(key, item);
    }
  }
  return byKey;
}

/**
 * @param {{ mac?: object|null, vm?: object|null }} hosts stored host records
 * @param {number} nowEpochSecs
 * @returns {{ heading: string, rows: object[] }[]} exactly 7 groups in page order; rows are capped
 *   and ordered. Every row has `issue`; run-derived rows also `host` ('mac'|'vm') and `state`.
 */
export function groupTickets(hosts, nowEpochSecs) {
  // One winning run per ticket: latest last_activity_at, missing loses, tie -> Mac.
  const winners = new Map();
  for (const hostKey of HOST_ORDER) {
    for (const run of listOf(hosts[hostKey], 'runs')) {
      const key = keyOf(run);
      const seen = winners.get(key);
      if (!seen || (epoch(run.last_activity_at) ?? -Infinity) > (epoch(seen.last_activity_at) ?? -Infinity)) {
        winners.set(key, { ...run, host: hostKey });
      }
    }
  }

  const done = mergeList(hosts, 'completed', 'closed_at', (item) => {
    const closed = epoch(item.closed_at);
    return closed !== null && nowEpochSecs - closed <= DONE_RETENTION_SECS;
  });
  const approved = mergeList(hosts, 'approved', 'updated_at');
  const staging = mergeList(hosts, 'staging', 'updated_at');

  const groups = { running: [], queued: [], approved: [], needsJp: [], staging: [], parked: [], done: [] };
  const seenKeys = new Set([...winners.keys(), ...done.keys(), ...approved.keys(), ...staging.keys()]);

  for (const key of seenKeys) {
    const run = winners.get(key);
    if (run && run.state === 'running') groups.running.push(run);
    else if (done.has(key)) groups.done.push(done.get(key));
    else if (approved.has(key)) groups.approved.push(approved.get(key));
    else if (run && run.state === 'queued') groups.queued.push(run);
    else if (staging.has(key)) groups.staging.push(staging.get(key));
    else if (run && run.state === 'restarting') groups.running.push(run);
    else if (run && run.state === 'held') {
      if (NEEDS_JP_MARKERS.includes(run.marker)) groups.needsJp.push(run);
      else {
        const last = epoch(run.last_activity_at);
        if (last === null || nowEpochSecs - last <= PARKED_MAX_AGE_SECS) groups.parked.push(run);
      }
    }
  }

  const build = (name, field) => {
    const rows = newestFirst(groups[name], field);
    return { heading: HEADINGS[name], rows: CAPS[name] ? rows.slice(0, CAPS[name]) : rows };
  };
  return [
    build('running', 'last_activity_at'),
    build('queued', 'last_activity_at'),
    build('approved', 'updated_at'),
    build('needsJp', 'last_activity_at'),
    build('staging', 'updated_at'),
    build('parked', 'last_activity_at'),
    build('done', 'closed_at'),
  ];
}
