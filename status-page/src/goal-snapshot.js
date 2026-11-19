// src/goal-snapshot.js — which host's goal list the status page shows (#795). Pure: no I/O, no rendering.
//
// The Goals section (rows, slot holder, queue order, priority) and the goal alerts used to merge every host's own `goals[]`, so a host that
// stopped syncing the registry (or stopped ticking) could still decide what the page said. Each beat now carries `goals_as_of`: when that
// host's goalqueue.json was last synced from the registry. The page takes the goal list from ONE host: the freshest `goals_as_of` among live
// hosts, ignoring a snapshot older than GOAL_SNAPSHOT_MAX_AGE_MINUTES. Ages are computed here at render time (now minus the published
// timestamp), never published, so the heartbeat hash does not churn. Beats without `goals_as_of` (old reporters) keep the old merge.

export const GOAL_SNAPSHOT_MAX_AGE_MINUTES = 30;
const TIE_SECS = 60; // two snapshots this close are the same moment: prefer the VM (the always-on host)
const HOST_KEYS = ['mac', 'vm'];

export function formatAge(secs) {
  const mins = Math.max(0, Math.round(secs / 60));
  if (mins < 60) return `${mins} min`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

function epoch(iso) {
  const ms = typeof iso === 'string' ? Date.parse(iso) : NaN;
  return Number.isNaN(ms) ? null : ms / 1000;
}

function isLive(record, thresholds, nowEpochSecs) {
  const at = epoch(record && record.received_at);
  return at !== null && nowEpochSecs - at < thresholds.staleSecs;
}

/** The winning host's goals with one overlay: the host a goal runs on, when live, may raise `between_cycles` to `running` (only that host sees
 *  its lead's pid) and supplies the cycle time and scope counts of its own goal. Everything else (rows, order, priority, slot, queue position) stays the snapshot's. */
function overlay(goals, winnerKey, hosts, thresholds, nowEpochSecs) {
  return goals
    .filter((g) => g && typeof g === 'object' && typeof g.id === 'string')
    .map((g) => {
      if (!HOST_KEYS.includes(g.host) || g.host === winnerKey) return g;
      const rec = hosts[g.host];
      if (!rec || !Array.isArray(rec.goals) || !isLive(rec, thresholds, nowEpochSecs)) return g;
      const own = rec.goals.find((o) => o && o.id === g.id && o.host === g.host);
      if (!own) return g;
      const out = { ...g };
      if (g.state === 'between_cycles' && own.state === 'running') out.state = 'running';
      for (const k of ['last_cycle_at', 'scope_total', 'scope_delivered']) if (own[k] !== undefined) out[k] = own[k];
      return out;
    });
}

/**
 * @param {{ mac?: object|null, vm?: object|null }} hosts stored host records
 * @param {{ staleSecs: number, offlineSecs: number }} thresholds
 * @param {number} nowEpochSecs
 * @returns {{ mode: 'legacy' }
 *   | { mode: 'snapshot', key: string, goals: object[], goal_stall: object[], ageSecs: number }
 *   | { mode: 'stale', key: string|null, ageSecs: number|null }}
 *  legacy: no host publishes `goals_as_of` (old reporters): the caller keeps the old merge.
 *  stale: some host does, but none is live with a snapshot within the age limit: show no goal rows, raise the amber alert.
 */
export function selectGoalSnapshot(hosts, thresholds, nowEpochSecs) {
  const maxAge = GOAL_SNAPSHOT_MAX_AGE_MINUTES * 60;
  const published = [];
  for (const key of HOST_KEYS) {
    const record = hosts && hosts[key];
    if (!record || typeof record !== 'object') continue;
    const asOf = epoch(record.goals_as_of);
    if (asOf !== null) published.push({ key, record, asOf, live: isLive(record, thresholds, nowEpochSecs) });
  }
  if (published.length === 0) return { mode: 'legacy' };
  const fresh = published.filter((p) => p.live && nowEpochSecs - p.asOf <= maxAge);
  if (fresh.length === 0) {
    const newest = published.reduce((a, b) => (b.asOf > a.asOf ? b : a));
    return { mode: 'stale', key: newest.key, ageSecs: Math.max(0, nowEpochSecs - newest.asOf) };
  }
  const win = fresh.reduce((a, b) => {
    if (Math.abs(a.asOf - b.asOf) <= TIE_SECS) return a.key === 'vm' ? a : b.key === 'vm' ? b : a;
    return b.asOf > a.asOf ? b : a;
  });
  return {
    mode: 'snapshot',
    key: win.key,
    goals: overlay(Array.isArray(win.record.goals) ? win.record.goals : [], win.key, hosts, thresholds, nowEpochSecs),
    goal_stall: Array.isArray(win.record.goal_stall) ? win.record.goal_stall : [],
    ageSecs: Math.max(0, nowEpochSecs - win.asOf),
  };
}

/** The record(s) the goal-stall alerts read, in alerts.js's `{ key, record }` shape: old merge for legacy beats, the snapshot's host only, nothing when stale. */
export function goalAlertSources(sel, liveRecords) {
  if (sel.mode === 'legacy') return liveRecords;
  if (sel.mode === 'snapshot') return [{ key: sel.key, record: { goals: sel.goals, goal_stall: sel.goal_stall } }];
  return [];
}

/** Amber alert when a host publishes goal lists but none is fresh. */
export function goalSnapshotAlerts(sel, hostLabels) {
  if (sel.mode !== 'stale') return [];
  const last = sel.key ? ` The newest copy is ${formatAge(sel.ageSecs)} old (from the ${hostLabels[sel.key]}).` : '';
  return [
    {
      id: 'goal-snapshot-stale',
      severity: 'amber',
      title: 'The goal list is out of date',
      detail: `No host has refreshed its goal list in ${GOAL_SNAPSHOT_MAX_AGE_MINUTES} minutes, so the Goals section is hidden rather than shown wrong.${last}`,
      hint: 'Check that a supervisor is ticking and that its goal sync is not failing (goal lines in the supervisor log); the VM is the usual source.',
    },
  ];
}
