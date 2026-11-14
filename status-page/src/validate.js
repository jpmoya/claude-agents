// src/validate.js — pure allowlist validator for the frozen v1 heartbeat payload.
//
// Sanitise-by-reconstruction: build a fresh object from the allowlist below so an unknown key
// (or a `sessions` field) can never survive onto the object that reaches KV. Invariant: no
// free-text string reaches storage — every string field is an enum or a strict pattern. See
// issue #11 / #4 §5 for the full field table.
//
// Exactly one documented exception (issue #29): `runs[].title` is free text. It is length-capped
// (140 code points), has control characters and whitespace runs collapsed to one space, and is
// HTML-escaped at render. `runs[].url` is not an exception — it must match ISSUE_URL below.

import {
  STAGE_VOCAB,
  MARKER_VOCAB,
  STATE_VOCAB,
  NEEDS_VOCAB,
  PARKED_REASON_VOCAB,
  BLOCK_CLASS_VOCAB,
  CI_QUEUE_CATEGORY_VOCAB,
  CI_RUNNER_ROLE_VOCAB,
} from './vocab.js';

const ISO_8601_Z = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const REPO_ALIAS = /^[a-z0-9][a-z0-9-]{0,23}$/;
// where a goal name leads: a GitHub issue, a milestone page, or a cross-repo issue search
const GOAL_URL = /^https:\/\/github\.com\/(?:[\w.-]+\/[\w.-]+\/(?:issues\/\d+|milestone\/\d+(?:\?closed=1)?|issues\?q=[\w%.~-]+)|issues\?q=[\w%.~-]+|(?:users|orgs)\/[\w.-]+\/projects\/\d+)$/;
const ISSUE_URL = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/issues\/\d+$/;
// `ci_queue.runners[].current_job` (issue #655): a github.com PR URL, and the "owner/repo" shape
// that URL also gets interpolated into. Separate consts (not ISSUE_URL) since a PR and an issue
// live under different path segments.
const PR_URL = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+$/;
const REPO_FULL = /^[\w.-]+\/[\w.-]+$/;
const TITLE_WHITESPACE_OR_CONTROL = /[\u0000-\u001f\u007f\s]+/g;
const MAX_TITLE_CODE_POINTS = 140;
const MAX_RUNS = 20;
const MAX_COMPLETED = 10;
const MAX_STAGING = 60;
const MILESTONE = /^[\w .,()&/+:-]{1,60}$/;
const RELEASE = /^v\d+\.\d+\.\d+$/;
const MAX_GOALS = 50;
const GOAL_STATES = ['running', 'between_cycles', 'waiting_jp', 'held', 'queued', 'delivered', 'stopped'];
// why the head of the queue is not starting (#320): a closed list, never free text
const GOAL_PAUSED = ['Mac on battery'];
const GOAL_HOSTS = ['mac', 'vm'];
const GOAL_UNSAFE = /[<>&"`]/;

/** True iff `value` is a string that is exactly a GitHub issue URL. render.js re-checks with it. */
export function isIssueUrl(value) {
  return typeof value === 'string' && ISSUE_URL.test(value);
}

/** True iff `value` is a string that is exactly a GitHub PR URL. render.js re-checks with it
 * before ever emitting an `href` for a busy runner's `current_job.pr_url` (issue #655). */
export function isPrUrl(value) {
  return typeof value === 'string' && PR_URL.test(value);
}

function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isIsoTimestamp(value) {
  return typeof value === 'string' && ISO_8601_Z.test(value);
}

function clampInt(value, min, max) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null;
  const rounded = Math.round(value);
  return Math.min(max, Math.max(min, rounded));
}

function isIntInRange(value, min, max) {
  return typeof value === 'number' && Number.isInteger(value) && value >= min && value <= max;
}

/** Clamps an integer 0-99 field (capacity.*, runs[].restarts); non-numeric -> 0. */
function clampCount(value) {
  const clamped = clampInt(value, 0, 99);
  return clamped === null ? 0 : clamped;
}

/** Sanitises `runs[].repo`: strict alias pattern, else "other". */
function sanitiseRepo(value) {
  return typeof value === 'string' && REPO_ALIAS.test(value) ? value : 'other';
}

/**
 * Sanitises the optional `runs[].title`: whitespace/control runs -> one space, trimmed, capped at
 * 140 code points. Non-string or empty result -> null (field omitted, run kept).
 */
function sanitiseTitle(value) {
  if (typeof value !== 'string') return null;
  const collapsed = value.replace(TITLE_WHITESPACE_OR_CONTROL, ' ').trim();
  const capped = Array.from(collapsed).slice(0, MAX_TITLE_CODE_POINTS).join('');
  return capped === '' ? null : capped;
}

/** Sanitises `runs[].stage`: known agent-roster enum, else "other". */
function sanitiseStage(value) {
  if (value === undefined || value === null || value === '') return '';
  return typeof value === 'string' && STAGE_VOCAB.includes(value) ? value : 'other';
}

/** Sanitises `runs[].marker`: known routing-marker enum, else "other". */
function sanitiseMarker(value) {
  if (value === undefined || value === null || value === '') return '';
  return typeof value === 'string' && MARKER_VOCAB.includes(value) ? value : 'other';
}

/**
 * Sanitises one run object. Returns the sanitised run, or null if the run must be dropped
 * (invalid `issue` or `state` — the two fields the table marks "run dropped" on violation).
 */
function sanitiseRun(rawRun) {
  if (!isPlainObject(rawRun)) return null;

  if (!isIntInRange(rawRun.issue, 1, 999999)) return null;
  if (!(typeof rawRun.state === 'string' && STATE_VOCAB.includes(rawRun.state))) return null;

  const run = {
    repo: sanitiseRepo(rawRun.repo),
    issue: rawRun.issue,
    state: rawRun.state,
    stage: sanitiseStage(rawRun.stage),
    marker: sanitiseMarker(rawRun.marker),
    restarts: clampCount(rawRun.restarts),
  };

  if (isIsoTimestamp(rawRun.started_at)) run.started_at = rawRun.started_at;
  if (isIsoTimestamp(rawRun.last_activity_at)) run.last_activity_at = rawRun.last_activity_at;

  if (isIsoTimestamp(rawRun.gate_at)) run.gate_at = rawRun.gate_at;
  if (typeof rawRun.needs === 'string' && NEEDS_VOCAB.includes(rawRun.needs)) run.needs = rawRun.needs;
  if (typeof rawRun.parked_reason === 'string' && PARKED_REASON_VOCAB.includes(rawRun.parked_reason)) {
    run.parked_reason = rawRun.parked_reason;
  }
  if (typeof rawRun.block_class === 'string' && BLOCK_CLASS_VOCAB.includes(rawRun.block_class)) {
    run.block_class = rawRun.block_class;
  }

  const title = sanitiseTitle(rawRun.title);
  if (title !== null) run.title = title;
  if (isIssueUrl(rawRun.url)) run.url = rawRun.url;

  if (typeof rawRun.milestone === 'string') {
    const milestone = rawRun.milestone.trim();
    if (MILESTONE.test(milestone)) run.milestone = milestone;
  }

  return run;
}

/**
 * Sanitises one completed[] item (issue #51), same helpers as runs. Returns null to drop the item:
 * invalid `issue`, or a `closed_at` that is not ISO-8601 Z (required). repo/title/url/marker are
 * reconstructed; title, url and marker are optional and omitted when absent or invalid.
 */
function sanitiseCompleted(rawItem) {
  if (!isPlainObject(rawItem)) return null;
  if (!isIntInRange(rawItem.issue, 1, 999999)) return null;
  if (!isIsoTimestamp(rawItem.closed_at)) return null;

  const item = {
    repo: sanitiseRepo(rawItem.repo),
    issue: rawItem.issue,
    closed_at: rawItem.closed_at,
  };

  const title = sanitiseTitle(rawItem.title);
  if (title !== null) item.title = title;
  if (isIssueUrl(rawItem.url)) item.url = rawItem.url;
  if (rawItem.marker !== undefined && rawItem.marker !== null) item.marker = sanitiseMarker(rawItem.marker);
  if (typeof rawItem.release === 'string' && RELEASE.test(rawItem.release)) item.release = rawItem.release;

  return item;
}

/**
 * Sanitises one staging[] / approved[] item (issue #62): {repo, issue, title?, url?, updated_at?}.
 * Invalid `issue` -> item dropped; the optional fields are omitted when absent or invalid.
 */
function sanitiseListItem(rawItem) {
  if (!isPlainObject(rawItem)) return null;
  if (!isIntInRange(rawItem.issue, 1, 999999)) return null;

  const item = { repo: sanitiseRepo(rawItem.repo), issue: rawItem.issue };
  const title = sanitiseTitle(rawItem.title);
  if (title !== null) item.title = title;
  if (isIssueUrl(rawItem.url)) item.url = rawItem.url;
  if (isIsoTimestamp(rawItem.updated_at)) item.updated_at = rawItem.updated_at;
  return item;
}

const MAX_GOAL_REPOS = 20;
const GOAL_REPO = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;

/** Safe-text rule for goal id/spec: collapsed + capped like titles, and no <, >, &, " or `. Else null. */
function sanitiseGoalText(value) {
  const text = sanitiseTitle(value);
  return text === null || GOAL_UNSAFE.test(text) ? null : text;
}

/** Sanitises one goals[] entry (issue #197). Returns null to drop it. */
function sanitiseGoal(raw) {
  if (!isPlainObject(raw)) return null;
  const id = sanitiseGoalText(raw.id);
  // v1 goals carry a single-repo `spec`; a cross-repo label goal (#319) carries title, repos and order instead.
  const spec = raw.spec === undefined ? undefined : sanitiseGoalText(raw.spec);
  const title = raw.title === undefined ? undefined : sanitiseGoalText(raw.title);
  if (id === null || spec === null || title === null) return null;
  if (spec === undefined && title === undefined) return null;
  if (!GOAL_STATES.includes(raw.state)) return null;
  // a queued goal (#320) has no host yet; a closed one (delivered / stopped) no longer has one
  const hostless = raw.state === 'queued' || raw.state === 'delivered' || raw.state === 'stopped';
  if (!GOAL_HOSTS.includes(raw.host) && !(hostless && (raw.host === '' || raw.host === undefined))) return null;
  const goal = { id, host: raw.host === undefined ? '' : raw.host, state: raw.state };
  if (spec !== undefined) goal.spec = spec;
  if (title !== undefined) goal.title = title;
  if (raw.repos !== undefined) {
    if (!Array.isArray(raw.repos) || raw.repos.length > MAX_GOAL_REPOS) return null;
    if (!raw.repos.every((r) => typeof r === 'string' && GOAL_REPO.test(r))) return null;
    goal.repos = [...raw.repos];
  }
  if (isIntInRange(raw.priority, 1, 9999)) goal.priority = raw.priority;
  const order = clampInt(raw.order, 0, 999999);
  if (order !== null) goal.order = order;
  const total = clampInt(raw.scope_total, 0, 9999);
  if (total !== null) goal.scope_total = total;
  const delivered = clampInt(raw.scope_delivered, 0, 9999);
  if (delivered !== null) goal.scope_delivered = delivered;
  if (typeof raw.url === 'string' && GOAL_URL.test(raw.url)) goal.url = raw.url;
  if (isIsoTimestamp(raw.last_cycle_at)) goal.last_cycle_at = raw.last_cycle_at;
  if ((raw.state === 'delivered' || raw.state === 'stopped') && isIsoTimestamp(raw.closed_at)) goal.closed_at = raw.closed_at;
  if (raw.state === 'queued') {
    if (isIntInRange(raw.queue_pos, 1, 9999)) goal.queue_pos = raw.queue_pos;
    if (GOAL_PAUSED.includes(raw.paused)) goal.paused = raw.paused;
  }
  return goal;
}

function sanitiseList(raw, max = Infinity) {
  return Array.isArray(raw) ? raw.map(sanitiseListItem).filter((item) => item !== null).slice(0, max) : [];
}

const MAX_BACKLOG = 100;

/**
 * Sanitises one backlog[] item (backlog reorder view): standalone (non-goal) open agent-go
 * tickets, {repo, issue, title?, url?, rank?}. Invalid `issue` -> item dropped; `rank` (JP's
 * stored priority; lower = dispatched first) is omitted when absent or out of range — the
 * ticket then renders/sorts as "unranked", never as rank 0.
 */
function sanitiseBacklogItem(rawItem) {
  if (!isPlainObject(rawItem)) return null;
  if (!isIntInRange(rawItem.issue, 1, 999999)) return null;

  const item = { repo: sanitiseRepo(rawItem.repo), issue: rawItem.issue };
  const title = sanitiseTitle(rawItem.title);
  if (title !== null) item.title = title;
  if (isIssueUrl(rawItem.url)) item.url = rawItem.url;
  if (isIntInRange(rawItem.rank, 0, 999999)) item.rank = rawItem.rank;
  return item;
}

function sanitiseBacklog(raw) {
  return Array.isArray(raw) ? raw.map(sanitiseBacklogItem).filter((item) => item !== null).slice(0, MAX_BACKLOG) : [];
}

const MAX_CI_QUEUE_CATEGORIES = 4;

/** Sanitises one `ci_queue.categories[]` entry. Returns null on any violation. */
function sanitiseCiQueueCategory(raw) {
  if (!isPlainObject(raw)) return null;
  if (!(typeof raw.key === 'string' && CI_QUEUE_CATEGORY_VOCAB.includes(raw.key))) return null;
  if (!isIntInRange(raw.count, 0, 999)) return null;
  return { key: raw.key, count: raw.count };
}

/** Sanitises `ci_queue.oldest` (an object or exactly `null`). Returns {ok:false} on any violation. */
function sanitiseCiQueueOldest(raw) {
  if (raw === null) return { ok: true, value: null };
  if (!isPlainObject(raw)) return { ok: false };
  if (!(typeof raw.key === 'string' && CI_QUEUE_CATEGORY_VOCAB.includes(raw.key))) return { ok: false };
  if (!isIsoTimestamp(raw.queued_at)) return { ok: false };
  return { ok: true, value: { key: raw.key, queued_at: raw.queued_at } };
}

// `ci_queue.runners[]` (issue #648): bounded array of per-runner identity + utilization-history
// rollup. `name` follows GitHub's own self-hosted runner naming charset.
const MAX_CI_QUEUE_RUNNERS = 30;
const RUNNER_NAME = /^[A-Za-z0-9._-]{1,100}$/;

/** Sanitises one `ci_queue.runners[].util_*_pct` value: null, or an int 0-100. `undefined` signals "invalid, drop the entry". */
function sanitiseUtilPct(value) {
  if (value === null) return null;
  if (isIntInRange(value, 0, 100)) return value;
  return undefined;
}

// `ci_queue.runners[].history_secs` (issue #655, AC A): how far back this slot's retained sample
// history actually reaches — the render side's "building" badge is driven off this, never off a
// hand-waved default. Bounded to a bit over the collector's own retention window (72h + one
// cycle's buffer, see ci-queue-collect.sh's `keep`) so a garbled value can never inflate the badge
// math; a sane cap, not a tight one, since this is a duration not a count.
const MAX_HISTORY_SECS = 604800; // 7 days

/**
 * Sanitises `ci_queue.runners[].history_secs`. `undefined` signals "omit the key" — unlike
 * `util_*_pct`, a malformed/absent value never drops the whole runner entry: this is a brand-new
 * additive field (a pre-#655 collector never sends it at all), same reasoning as
 * `runners_offline`/`runners[]` themselves in sanitiseCiQueue below. `0` (a slot just seen for the
 * first time) is a real, meaningful value, so this checks range membership, not truthiness.
 */
function sanitiseHistorySecs(value) {
  if (isIntInRange(value, 0, MAX_HISTORY_SECS)) return value;
  return undefined;
}

// `ci_queue.runners[].current_job` (issue #655, AC B): `run_id` is GitHub's own numeric Actions
// run id — real ids are 11 digits, so this is bounded only by JS's safe-integer range, never by
// the much tighter `id` cap above (that one bounds a self-hosted runner's small registration id,
// a different number entirely).
const MAX_RUN_ID = Number.MAX_SAFE_INTEGER;

/**
 * Sanitises one `ci_queue.runners[].current_job`. Returns undefined to omit the whole key —
 * never fabricates a link from a partial/malformed shape (AC B's "never a broken or fabricated
 * href"). `repo`/`run_id` are required (the run-URL fallback needs both); `pr_url` is the only
 * optional sub-field — present-and-invalid drops just `pr_url`, keeping the run-URL fallback
 * available, rather than dropping the whole object over one bad sub-field.
 */
function sanitiseCurrentJob(raw) {
  if (!isPlainObject(raw)) return undefined;
  if (!(typeof raw.repo === 'string' && REPO_FULL.test(raw.repo))) return undefined;
  if (!isIntInRange(raw.run_id, 1, MAX_RUN_ID)) return undefined;
  const result = { repo: raw.repo, run_id: raw.run_id };
  if (typeof raw.pr_url === 'string' && PR_URL.test(raw.pr_url)) result.pr_url = raw.pr_url;
  return result;
}

/**
 * Sanitises one `ci_queue.runners[]` entry. Returns null to DROP just this one entry — unlike
 * `categories[]`, a single bad runner entry never takes down the whole `ci_queue` object (issue
 * #648 AC8(b)): a collector hiccup on one runner must not blank the whole panel.
 */
function sanitiseCiQueueRunner(raw) {
  if (!isPlainObject(raw)) return null;
  if (!isIntInRange(raw.id, 0, 999999999)) return null;
  if (!(typeof raw.name === 'string' && RUNNER_NAME.test(raw.name))) return null;
  if (typeof raw.online !== 'boolean') return null;
  if (typeof raw.busy !== 'boolean') return null;
  if (!(typeof raw.role === 'string' && CI_RUNNER_ROLE_VOCAB.includes(raw.role))) return null;
  const util24 = sanitiseUtilPct(raw.util_24h_pct);
  if (util24 === undefined) return null;
  const util72 = sanitiseUtilPct(raw.util_72h_pct);
  if (util72 === undefined) return null;
  const result = {
    id: raw.id,
    name: raw.name,
    online: raw.online,
    busy: raw.busy,
    role: raw.role,
    util_24h_pct: util24,
    util_72h_pct: util72,
  };

  const historySecs = sanitiseHistorySecs(raw.history_secs);
  if (historySecs !== undefined) result.history_secs = historySecs;

  const currentJob = sanitiseCurrentJob(raw.current_job);
  if (currentJob !== undefined) result.current_job = currentJob;

  return result;
}

// `ci_queue.unavailable_repos` (issue #663 AC4): the configured repos the collector could not
// reach this cycle (renamed/archived/access lost — see ci-queue-collect.sh's per-repo skip).
// Debug-only (no render.js consumer yet) — still validated to the same "owner/repo" shape as
// every other repo string in this file, never free text, and bounded so a garbled/huge array
// can't bloat storage.
const MAX_UNAVAILABLE_REPOS = 50;

/**
 * Sanitises `ci_queue.unavailable_repos`. `undefined` signals "omit the key" — same additive
 * reasoning as `runners_offline`/`runners[]` below: a collector that predates #663 never sends
 * this at all. A non-"owner/repo"-shaped entry is dropped individually (never takes down the
 * whole array), same pattern as `sanitiseCiQueueRunner`.
 */
function sanitiseUnavailableRepos(raw) {
  if (!Array.isArray(raw)) return undefined;
  return raw
    .filter((r) => typeof r === 'string' && REPO_FULL.test(r))
    .slice(0, MAX_UNAVAILABLE_REPOS);
}

/**
 * Sanitises the optional top-level `ci_queue` (issue #643): every field is an enum, a bounded
 * int (0-999), or an ISO-8601Z timestamp — no free text. Unlike every other optional field in
 * this file, a single malformed sub-field drops the WHOLE object (never partially rebuilt) —
 * a stale/garbled collector snapshot must disappear entirely, not corrupt one field while
 * keeping stale siblings. Returns null (key omitted) on any violation, including when `raw` is
 * absent/non-object.
 *
 * `runners[]` / `runners_offline` (issue #648) are the one exception to "drop the whole object":
 * they are newer, additive fields — a collector that predates #648 never sends them, and that
 * must keep showing the rest of the (still fully #643-shaped) panel, not disappear. So each is
 * independently optional: present-and-malformed (wrong type) just omits that one key, and a bad
 * `runners[]` entry (AC8(b)) drops only that entry, never the whole `ci_queue`.
 *
 * Issue #663 adds three more fields to that same "independently optional" set: `truncated`
 * (AC2 — the collector's run-lookup cap dropped at least one repo's queued/in_progress runs this
 * cycle, so `queued_total`/`categories[]` may be an undercount), `unavailable_repos` (AC4 — see
 * `sanitiseUnavailableRepos` above), and `runners_total_sampled` (AC5 — the pre-truncation count
 * behind `runners[]`'s `MAX_CI_QUEUE_RUNNERS` cap, so render.js can show "showing 30 of N").
 */
function sanitiseCiQueue(raw) {
  if (!isPlainObject(raw)) return null;
  if (!isIsoTimestamp(raw.as_of)) return null;
  if (!isIntInRange(raw.runners_busy, 0, 999)) return null;
  if (!isIntInRange(raw.runners_total, 0, 999)) return null;
  if (!isIntInRange(raw.queued_total, 0, 999)) return null;
  if (!Array.isArray(raw.categories) || raw.categories.length > MAX_CI_QUEUE_CATEGORIES) return null;
  const categories = raw.categories.map(sanitiseCiQueueCategory);
  if (categories.some((c) => c === null)) return null;
  const keys = categories.map((c) => c.key);
  if (new Set(keys).size !== keys.length) return null; // no duplicate category keys
  const oldest = sanitiseCiQueueOldest(raw.oldest);
  if (!oldest.ok) return null;

  const result = {
    as_of: raw.as_of,
    runners_busy: raw.runners_busy,
    runners_total: raw.runners_total,
    queued_total: raw.queued_total,
    categories,
    oldest: oldest.value,
  };

  if (isIntInRange(raw.runners_offline, 0, 999)) {
    result.runners_offline = raw.runners_offline;
  }

  if (Array.isArray(raw.runners)) {
    result.runners = raw.runners
      .map(sanitiseCiQueueRunner)
      .filter((runner) => runner !== null)
      .slice(0, MAX_CI_QUEUE_RUNNERS);
  }

  if (typeof raw.truncated === 'boolean') {
    result.truncated = raw.truncated;
  }

  const unavailableRepos = sanitiseUnavailableRepos(raw.unavailable_repos);
  if (unavailableRepos !== undefined) result.unavailable_repos = unavailableRepos;

  if (isIntInRange(raw.runners_total_sampled, 0, 999)) {
    result.runners_total_sampled = raw.runners_total_sampled;
  }

  return result;
}

/**
 * @param {unknown} parsedBody - already-JSON-parsed request body
 * @returns {{ ok: true, value: object } | { ok: false, reason: 'bad-json'|'bad-version'|'too-many-runs' }}
 */
export function validateBeatPayload(parsedBody) {
  if (!isPlainObject(parsedBody)) {
    return { ok: false, reason: 'bad-json' };
  }

  if (parsedBody.v !== 1) {
    return { ok: false, reason: 'bad-version' };
  }

  if (!Array.isArray(parsedBody.runs)) {
    return { ok: false, reason: 'too-many-runs' };
  }

  if (parsedBody.runs.length > MAX_RUNS) {
    return { ok: false, reason: 'too-many-runs' };
  }

  const value = { v: 1 };

  if (isIsoTimestamp(parsedBody.sent_at)) value.sent_at = parsedBody.sent_at;
  if (isIsoTimestamp(parsedBody.supervisor_last_tick)) {
    value.supervisor_last_tick = parsedBody.supervisor_last_tick;
  }

  const rawCapacity = isPlainObject(parsedBody.capacity) ? parsedBody.capacity : {};
  value.capacity = {
    running: clampCount(rawCapacity.running),
    max: clampCount(rawCapacity.max),
    queued: clampCount(rawCapacity.queued),
  };

  value.runs = parsedBody.runs.map(sanitiseRun).filter((run) => run !== null);

  // Optional (issue #51): absent or non-array -> []; never a rejection. First 10 valid items kept.
  value.completed = Array.isArray(parsedBody.completed)
    ? parsedBody.completed.map(sanitiseCompleted).filter((item) => item !== null).slice(0, MAX_COMPLETED)
    : [];

  // Optional (issue #62): absent or non-array -> []; never a rejection.
  value.staging = sanitiseList(parsedBody.staging, MAX_STAGING);
  value.approved = sanitiseList(parsedBody.approved); // never truncated (jpmoya/claude-agents#386, #460)

  // Optional (backlog reorder view): absent or non-array -> []; never a rejection.
  value.backlog = sanitiseBacklog(parsedBody.backlog);

  // Optional (issue #197): absent or non-array -> no key. First 50 entries, then filtered.
  if (Array.isArray(parsedBody.goals)) {
    const goals = parsedBody.goals.slice(0, MAX_GOALS).map(sanitiseGoal).filter((g) => g !== null);
    if (goals.length > 0) value.goals = goals;
  }

  // Optional (issue #643): absent, non-object, or any single malformed sub-field -> no key
  // (never a rejection, never a partial rebuild — see sanitiseCiQueue).
  const ciQueue = sanitiseCiQueue(parsedBody.ci_queue);
  if (ciQueue !== null) value.ci_queue = ciQueue;

  return { ok: true, value };
}
