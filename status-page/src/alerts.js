// src/alerts.js — pure derivation of the status page's alert banner. No I/O, no rendering.
//
// Everything is computed at render time from what the two hosts already publish (the stored heartbeat records), so the
// banner adds no GitHub call and no host-side state: ages are `now` minus a published timestamp, never a published age
// (a published age would change the heartbeat hash on every tick and burn the KV write budget).
//
// Five alert families (JP, 2026-11-19; pipeline-audit-2026-11-18 sections 3 and 5, #762; #769 adds the fifth):
//   1. a goal cannot be read (amber, skipped by the queue, blocks nothing else: host `goal_stall[]`) or stalls the goal queue
//      (red: a slot holder with no lead cycle for GOAL_STALL_HOURS)
//   2. run slots idle while work waits         (free slots + a queued run older than IDLE_SLOT_MINUTES, per host)
//   3. paused tickets nobody is working on     (held runs: waiting on JP, answered but not relaunched, or just parked)
//   4. a supervisor slow, or a host not reporting (tick-to-report gap > TICK_SLOW_MINUTES; heartbeat older than the stale threshold)
//   5. the release router has not fired       (host `scheduled_triggers[]`, auto-release entries, newest fire across live hosts, #769)
//   6. GitHub webhooks stopped arriving       (the VM host's `webhook_last_event_at`, the receiver's newest event, published only while stale, #773/#782)
// A stale or offline host is reported once (family 4) and its old data raises no other alert.

import { isIssueUrl } from './validate.js';
import { groupTickets, keyOf, liveTicketKeys } from './group.js';
import { selectGoalSnapshot, goalAlertSources, goalSnapshotAlerts } from './goal-snapshot.js';

export const IDLE_SLOT_MINUTES = 10;
export const TICK_SLOW_MINUTES = 15;
export const GOAL_STALL_HOURS = 6;
export const ANSWER_GRACE_MINUTES = 10; // an answered ticket may wait this long (2 supervisor ticks) for its relaunch before it counts as stuck (#780)
export const TRIGGER_OVERDUE_FACTOR = 3; // alert when the newest fire is older than this many intervals ...
export const TRIGGER_REPORT_LAG_MINUTES = 10; // ... plus the host's keep-alive (600 s): last_fired_at is not in the beat's change hash, so it can be that stale
export const WEBHOOK_STALE_MINUTES = 30; // mirrors the host default WEBHOOK_STALE_MINUTES: the page computes the age itself from the VM receiver's last event
export const ALERT_LIST_MAX = 6; // tickets shown in the unowned-tickets alert; the rest are counted
const TITLE_WORDS = 5;

const HOST_KEYS = ['mac', 'vm'];
const HOST_LABELS = { mac: 'Mac', vm: 'VM' };
const FINISHED_PARKED = ['auto_retry', 'out_of_scope']; // the supervisor owns an auto-retry; an out-of-scope repo is not ours to run
const ANSWER_MARKERS = ['DECISION', 'JP CONFIRMED'];

function epoch(iso) {
  const ms = typeof iso === 'string' ? Date.parse(iso) : NaN;
  return Number.isNaN(ms) ? null : ms / 1000;
}

/** "7 min", "2 h 5 min", "3 h". */
export function formatDuration(secs) {
  const mins = Math.max(0, Math.round(secs / 60));
  if (mins < 60) return `${mins} min`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const words = (text, n) => String(text).trim().split(/\s+/).slice(0, n).join(' ');

/** live | stale | offline from the Worker's own receive time (same rule as the host badge). */
function freshness(record, thresholds, nowEpochSecs) {
  const at = epoch(record.received_at);
  if (at === null) return { state: 'offline', ageSecs: null };
  const ageSecs = nowEpochSecs - at;
  if (ageSecs >= thresholds.offlineSecs) return { state: 'offline', ageSecs };
  if (ageSecs >= thresholds.staleSecs) return { state: 'stale', ageSecs };
  return { state: 'live', ageSecs };
}

function goalName(g) {
  return g.title || g.spec || g.id;
}

function hostAlerts(key, record, thresholds, nowEpochSecs) {
  const label = HOST_LABELS[key];
  const out = [];
  const fresh = freshness(record, thresholds, nowEpochSecs);
  if (fresh.state !== 'live') {
    const since = fresh.ageSecs === null ? 'for a long time' : `for ${formatDuration(fresh.ageSecs)}`;
    out.push({
      id: `host-${fresh.state}-${key}`,
      severity: fresh.state === 'offline' ? 'red' : 'amber',
      title: `${label} has stopped reporting`,
      detail: `The ${label} has not sent a status update ${since}, so what this page shows for it is out of date.`,
      hint: `Check that the ${label} is awake and online and that its supervisor is running.`,
    });
    return { alerts: out, live: false };
  }

  // 2. idle slots: a free slot while the oldest queued run has waited longer than the limit
  const cap = record.capacity && typeof record.capacity === 'object' ? record.capacity : {};
  const queuedRuns = (Array.isArray(record.runs) ? record.runs : []).filter((r) => r && r.state === 'queued');
  const waits = queuedRuns.map((r) => epoch(r.started_at)).filter((t) => t !== null);
  if (Number.isInteger(cap.running) && Number.isInteger(cap.max) && cap.running < cap.max && waits.length > 0) {
    const oldestAge = nowEpochSecs - Math.min(...waits);
    if (oldestAge >= IDLE_SLOT_MINUTES * 60) {
      const queued = Math.max(queuedRuns.length, Number.isInteger(cap.queued) ? cap.queued : 0);
      out.push({
        id: `idle-slots-${key}`,
        severity: 'amber',
        title: `${label} has free run slots while tickets wait`,
        detail: `${cap.max - cap.running} of ${cap.max} slots are free, yet ${plural(queued, 'ticket has', 'tickets have')} been queued (the oldest for ${formatDuration(oldestAge)}).`,
        hint: `Queued tickets should start within a few minutes. Look at the ${label} supervisor log for drain lines, low memory or a slow tick.`,
      });
    }
  }

  // 4. slow supervisor: how long before the last report did the supervisor last tick?
  const sent = epoch(record.sent_at);
  const tick = epoch(record.supervisor_last_tick);
  if (sent !== null && tick !== null && sent - tick >= TICK_SLOW_MINUTES * 60) {
    out.push({
      id: `slow-tick-${key}`,
      severity: 'amber',
      title: `The ${label} supervisor is slow`,
      detail: `Its last tick was ${formatDuration(sent - tick)} before its latest report; ticks are meant to be about 2 minutes apart (alert at ${TICK_SLOW_MINUTES}).`,
      hint: `Check the ${label} supervisor log for a slow GitHub call or a stuck step.`,
    });
  }
  return { alerts: out, live: true };
}

/** 1. goals that stall the goal queue, from the hosts' `goal_stall[]` and from a slot holder whose lead has not cycled for GOAL_STALL_HOURS. */
function goalStallAlerts(liveRecords, nowEpochSecs) {
  const out = [];
  const seen = new Set();
  for (const { record } of liveRecords) {
    for (const s of Array.isArray(record.goal_stall) ? record.goal_stall : []) {
      if (!s || typeof s !== 'object') continue;
      const key = `${s.kind}|${s.goal}`;
      if (seen.has(key)) continue;
      seen.add(key);
      // A goal that cannot be read is skipped by the queue and blocks nothing but itself (JP, 2026-11-19): amber, not a stall.
      out.push({
        id: `goal-stall-${out.length + 1}`,
        severity: 'amber',
        title: `${s.goal} cannot be read (${s.reason}); it is skipped, other goals unaffected`,
        detail: 'The goal queue goes on without it, in the same priority order.',
        hint: s.hint,
      });
    }
  }
  for (const { key, record } of liveRecords) {
    const goals = Array.isArray(record.goals) ? record.goals : [];
    const queued = goals.filter((g) => g && g.state === 'queued');
    const holder = goals.find((g) => g && g.slot === 'holds' && (g.state === 'running' || g.state === 'between_cycles'));
    const last = holder ? epoch(holder.last_cycle_at) : null; // no timestamp: never reported idle (fail quiet)
    if (!holder || last === null || queued.length === 0) continue;
    const age = nowEpochSecs - last;
    const stallKey = `slot_idle|${holder.id}`;
    if (age < GOAL_STALL_HOURS * 3600 || seen.has(stallKey)) continue;
    seen.add(stallKey);
    out.push({
      id: `goal-stall-${out.length + 1}`,
      severity: 'red',
      title: `Goal queue stalled by ${goalName(holder)}`,
      detail: `It holds the goal slot but its delivery lead has not cycled for ${formatDuration(age)}. Waiting behind it: ${queued.map(goalName).join(', ')}.`,
      hint: `Check its delivery lead on the ${HOST_LABELS[holder.host] || HOST_LABELS[key]}, or stop the goal (deliver.sh stop) so the queue can move.`,
    });
  }
  return out;
}

/** 3. paused tickets nobody is working on, one winning run per ticket across the live hosts (group.js decides the winner and the group). */
function unownedAlert(liveHosts, nowEpochSecs) {
  const groups = groupTickets(liveHosts, nowEpochSecs);
  const needsJp = groups[3].rows;
  const parked = groups[5].rows;
  const rank = { answered: 0, jp: 1, paused: 2 };
  // #780: a ticket is owned (not unowned) while a run on ANY host holds it (running, restarting, queued), or while JP's answer is
  // fresh enough (answered_at within ANSWER_GRACE_MINUTES) that the supervisor's next tick will relaunch it.
  const live = liveTicketKeys(liveHosts);
  const pending = (run) => {
    const at = epoch(run.answered_at);
    return at !== null && nowEpochSecs - at <= ANSWER_GRACE_MINUTES * 60;
  };
  const stuck = (run) => epoch(run.answered_at) !== null; // answered, and past the grace (the pending ones were dropped above)
  const rows = [];
  for (const run of needsJp) {
    if (live.has(keyOf(run)) || pending(run)) continue;
    rows.push({ run, kind: stuck(run) ? 'answered' : 'jp' });
  }
  for (const run of parked) {
    if (run.state !== 'held' || FINISHED_PARKED.includes(run.parked_reason)) continue;
    if (live.has(keyOf(run)) || pending(run)) continue;
    const answered = run.parked_reason === 'answered' || ANSWER_MARKERS.includes(run.marker) || stuck(run);
    rows.push({ run, kind: answered ? 'answered' : 'paused' });
  }
  if (rows.length === 0) return null;
  rows.sort((a, b) => rank[a.kind] - rank[b.kind]);
  const count = (k) => rows.filter((r) => r.kind === k).length;
  const TAGS = { answered: 'answered, not relaunched', jp: 'waiting on JP', paused: 'paused, no one on it' };
  const parts = [];
  if (count('answered')) parts.push(`${count('answered')} answered but never relaunched`);
  if (count('jp')) parts.push(`${count('jp')} waiting on JP`);
  if (count('paused')) parts.push(`${count('paused')} parked with nothing to resume them`);
  return {
    id: 'unowned-tickets',
    severity: 'amber',
    title: `${plural(rows.length, 'paused ticket has', 'paused tickets have')} no one working on ${rows.length === 1 ? 'it' : 'them'}`,
    detail: `${parts.join(', ')}.`,
    hint: 'Relaunch the answered ones; reply on the issue for the ones waiting on JP.',
    items: rows.slice(0, ALERT_LIST_MAX).map(({ run, kind }) => ({
      text: `#${run.issue} ${typeof run.title === 'string' && run.title ? words(run.title, TITLE_WORDS) : 'ticket'} (${TAGS[kind]})`,
      url: isIssueUrl(run.url) ? run.url : null,
    })),
    more: Math.max(0, rows.length - ALERT_LIST_MAX),
  };
}

/** 5. the release router (a workflow file named auto-release*) has not fired for TRIGGER_OVERDUE_FACTOR intervals; the newest fire across the live hosts counts. */
function releaseRouterAlerts(liveRecords, nowEpochSecs) {
  // "repo|workflow" -> { fired: newest fire on any live host | null, since: oldest tracked_since on any live host | null }
  const seen = new Map();
  for (const { record } of liveRecords) {
    for (const t of Array.isArray(record.scheduled_triggers) ? record.scheduled_triggers : []) {
      if (!t || typeof t.workflow !== 'string' || !t.workflow.startsWith('auto-release') || !Number.isInteger(t.interval_minutes)) continue;
      const key = `${t.repo}|${t.workflow}`;
      const fired = epoch(t.last_fired_at);
      const since = epoch(t.tracked_since);
      const cur = seen.get(key) || { repo: t.repo, full: null, workflow: t.workflow, interval: t.interval_minutes, fired: null, since: null };
      if (typeof t.full_repo === 'string' && t.full_repo) cur.full = t.full_repo;
      if (fired !== null && (cur.fired === null || fired > cur.fired)) cur.fired = fired;
      if (since !== null && (cur.since === null || since < cur.since)) cur.since = since;
      seen.set(key, cur);
    }
  }
  const out = [];
  for (const { repo, full, workflow, interval, fired, since } of seen.values()) {
    // a workflow that never fired (every dispatch failing) is measured from when a host first tracked it; no timestamp at all: fail quiet
    const last = fired !== null ? fired : since;
    if (last === null) continue;
    const age = nowEpochSecs - last;
    if (age <= (TRIGGER_OVERDUE_FACTOR * interval + TRIGGER_REPORT_LAG_MINUTES) * 60) continue;
    out.push({
      id: `release-router-${repo}-${workflow.replace(/\.ya?ml$/, '')}`,
      severity: 'red',
      title: `The release router for ${full || repo} has not fired in ${Math.round(age / 60)} minutes`,
      detail: `${workflow} should fire every ${interval} minutes; ${fired === null ? `it has not fired once in the ${formatDuration(age)} since the host started tracking it` : `nothing has started it for ${formatDuration(age)}`}, so changes merged to staging are not being released.`,
      hint: 'Check the scheduled-triggers cron job on the host that fires it (crontab -l; scheduled-triggers.log: failed lines mean the dispatch is refused), then run the workflow by hand.',
    });
  }
  return out;
}

/**
 * 6. GitHub is not sending webhooks to the VM receiver (#782). The only signal is the VM host's `webhook_last_event_at` (its receiver's
 * newest accepted delivery); the Mac's own apply of events says nothing about GitHub, so a sleeping or slow Mac never raises this, and a
 * Mac's `webhook_stale` (the old per-host field) is ignored. The VM host must be live (a stale VM is reported once by family 4). The host
 * publishes the time only while it is old, so it stays constant during an outage; the page computes the minutes and re-checks the threshold.
 * A missing VM record or field fails quiet.
 */
function webhookStaleAlerts(liveRecords, nowEpochSecs) {
  const vm = liveRecords.find((r) => r.key === 'vm');
  const last = vm ? epoch(vm.record.webhook_last_event_at) : null;
  if (last === null) return [];
  const mins = Math.max(0, Math.floor((nowEpochSecs - last) / 60));
  if (mins < WEBHOOK_STALE_MINUTES) return [];
  return [
    {
      id: 'webhook-stale-vm',
      severity: 'amber',
      title: `The ${HOST_LABELS.vm} is not receiving GitHub webhooks`,
      detail: `Status: no webhook received in ${mins} minutes. The supervisors still poll GitHub every 20 minutes, so nothing is lost, but changes are noticed more slowly and the API budget is used faster.`,
      hint: 'Check the webhook receiver and its reverse proxy on the VM, and the hooks in GitHub (Recent Deliveries); WEBHOOK_EVENTS_ENABLED=0 returns to plain polling.',
    },
  ];
}

/**
 * @param {{ mac?: object|null, vm?: object|null }} hosts stored host records
 * @param {{ staleSecs: number, offlineSecs: number }} thresholds
 * @param {number} nowEpochSecs
 * @returns {{ id: string, severity: 'red'|'amber', title: string, detail: string, hint: string,
 *   items?: { text: string, url: string|null }[], more?: number }[]} most urgent first; [] when healthy
 */
export function deriveAlerts(hosts, thresholds, nowEpochSecs) {
  const stale = [];
  const perHost = [];
  const liveRecords = [];
  const liveHosts = {};
  for (const key of HOST_KEYS) {
    const record = hosts && hosts[key];
    if (!record || typeof record !== 'object') continue;
    const { alerts, live } = hostAlerts(key, record, thresholds, nowEpochSecs);
    if (live) {
      liveRecords.push({ key, record });
      liveHosts[key] = record;
      perHost.push(...alerts);
    } else {
      stale.push(...alerts);
    }
  }
  const goalSel = selectGoalSnapshot(hosts, thresholds, nowEpochSecs); // #795: goal alerts read the one fresh snapshot, not every live host
  const out = [...goalStallAlerts(goalAlertSources(goalSel, liveRecords), nowEpochSecs), ...goalSnapshotAlerts(goalSel, HOST_LABELS), ...releaseRouterAlerts(liveRecords, nowEpochSecs), ...webhookStaleAlerts(liveRecords, nowEpochSecs), ...stale];
  const unowned = unownedAlert(liveHosts, nowEpochSecs);
  const rank = (a) => (a.severity === 'red' ? 0 : 1);
  return [...out, ...perHost, ...(unowned ? [unowned] : [])].sort((a, b) => rank(a) - rank(b));
}
