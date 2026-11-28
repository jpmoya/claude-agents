// src/validate.js — pure allowlist validator for the frozen v1 heartbeat payload.
//
// Sanitise-by-reconstruction: build a fresh object from the allowlist below so an unknown key
// (or a `sessions` field) can never survive onto the object that reaches KV. Invariant: no
// free-text string reaches storage — every string field is an enum or a strict pattern. See
// issue #11 / #4 §5 for the full field table.
//
// Documented exceptions (issues #29, #756): `runs[].title` is free text. It is length-capped
// (140 code points), has control characters and whitespace runs collapsed to one space, and is
// HTML-escaped at render. `runs[].url` is not an exception — it must match ISSUE_URL below.
// `cron[].name` / `.schedule` / `.schedule_human` (#756) are short strings held to a strict character
// set (see sanitiseCronItem), not free text. `cron[].description` is the third free-text exception: collapsed
// and capped at 140 code points like a title, and dropped when it carries markup, an email, a URL, a path,
// an assignment or a long token (CRON_DESCRIPTION_UNSAFE). `cron[].source` is an enum.

import {
  STAGE_VOCAB,
  MARKER_VOCAB,
  STATE_VOCAB,
  NEEDS_VOCAB,
  PARKED_REASON_VOCAB,
  BLOCK_CLASS_VOCAB,
  CI_QUEUE_CATEGORY_VOCAB,
  CI_RUNNER_ROLE_VOCAB,
  CI_METRICS_CATEGORY_VOCAB,
  CI_HEALTH_VOCAB,
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
// where a goal stands on the one goal slot (GOAL_SERIAL=1): holds it, waits for it (queued), or is exempt and runs alongside (feedback goals)
const GOAL_SLOT = ['holds', 'waits', 'alongside'];
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
  if (isIsoTimestamp(rawRun.answered_at)) run.answered_at = rawRun.answered_at; // #780: JP answered, no relaunch has used it yet
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
  if (GOAL_SLOT.includes(raw.slot) && raw.state !== 'delivered' && raw.state !== 'stopped') goal.slot = raw.slot;
  if (raw.state === 'queued') {
    if (isIntInRange(raw.queue_pos, 1, 9999)) goal.queue_pos = raw.queue_pos;
    if (GOAL_PAUSED.includes(raw.paused)) goal.paused = raw.paused;
  }
  return goal;
}

// ---- goal_stall[] (status-page alert banner): goals the queue skips because they cannot be read (they block nothing else). By reconstruction: a closed
// `kind` enum, short plain-text fields (no markup characters), at most MAX_GOAL_STALL items and MAX_GOAL_STALL_BLOCKED names each.
const GOAL_STALL_KINDS = ['unreadable', 'project_error', 'token_scope', 'agents_down'];
const MAX_GOAL_STALL = 5;
const MAX_GOAL_STALL_BLOCKED = 10;

function sanitiseGoalStall(raw) {
  if (!isPlainObject(raw) || !GOAL_STALL_KINDS.includes(raw.kind)) return null;
  const goal = sanitiseGoalText(raw.goal);
  const reason = sanitiseGoalText(raw.reason);
  const hint = sanitiseGoalText(raw.hint);
  if (goal === null || reason === null || hint === null) return null;
  // agents_down (#837): `since` is when the outage started (the page computes the duration); a malformed one is dropped, the entry kept
  if (raw.kind === 'agents_down') {
    return isIsoTimestamp(raw.since) ? { kind: raw.kind, goal, reason, hint, since: raw.since } : { kind: raw.kind, goal, reason, hint };
  }
  // `blocked` is optional since 2026-11-19: a goal that cannot be read is skipped and blocks nothing but itself, so a current reporter sends none.
  // An older reporter's names are still kept (cleaned), but never required.
  const blocked = Array.isArray(raw.blocked) ? raw.blocked.slice(0, MAX_GOAL_STALL_BLOCKED).map(sanitiseGoalText).filter((b) => b !== null) : [];
  return blocked.length > 0 ? { kind: raw.kind, goal, reason, hint, blocked } : { kind: raw.kind, goal, reason, hint };
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

// ---- sentry_cap[] (#781): a repo whose daily Sentry launch cap is holding tickets right now, published by the host.
const MAX_SENTRY_CAP = 20;
const MAX_SENTRY_CAP_HELD = 100;
const OWNER_REPO = /^[\w.-]+\/[\w.-]+$/;

/**
 * Sanitises one sentry_cap[] item by reconstruction: {repo: "owner/repo", count, max (0-99), resets_at (ISO UTC),
 * held: [issue numbers]}. A bad repo or resets_at drops the item; bad entries of `held` are dropped one by one.
 */
function sanitiseSentryCapItem(raw) {
  if (!isPlainObject(raw)) return null;
  if (typeof raw.repo !== 'string' || !OWNER_REPO.test(raw.repo)) return null;
  const resetsAt = sanitiseCronDate(raw.resets_at);
  if (resetsAt === null) return null;
  const held = Array.isArray(raw.held) ? raw.held.filter((n) => isIntInRange(n, 1, 999999)).slice(0, MAX_SENTRY_CAP_HELD) : [];
  return { repo: raw.repo, count: clampCount(raw.count), max: clampCount(raw.max), resets_at: resetsAt, held };
}

// ---- cron[] (issue #756): the host user's scheduled jobs, name + schedule + last run/result only.
const MAX_CRON = 50;
const CRON_NAME = /^[A-Za-z0-9._-]+$/;
const CRON_NAME_MAX = 80;
const CRON_SCHEDULE = /^[A-Za-z0-9@*/,?\- ]+$/; // a raw 5-field expression or an @special
const CRON_SCHEDULE_MAX = 60;
const CRON_HUMAN = /^[A-Za-z0-9 :,.()/@+-]+$/;
const CRON_HUMAN_MAX = 80;
const CRON_RESULTS = ['ok', 'failed', 'unknown'];
const CRON_SOURCES = ['cron', 'launchd', 'desktop'];
// `cron[].description`: plain text a person wrote to say what the job does (the first comment line of
// its script, a frontmatter description). Like a title it is collapsed and capped at 140 code points, but
// it is dropped (item kept, key omitted) when it could carry something that must never be published: markup
// characters, an email address, a URL, a home-relative or absolute path, a KEY=value assignment, or a
// long unbroken token (a secret). The em dash and a slash inside a word ("layoff/closure") are fine.
const CRON_DESCRIPTION_UNSAFE = /[<>&"`@]|:\/\/|~\/|(?:^|\s)\/[\w.-]|\b[A-Za-z_][A-Za-z0-9_]*=\S|[A-Za-z0-9_+-]{32,}|\b(?:sk|ghp|gho|xox[a-z]|AKIA)[-_A-Za-z0-9]{8,}/;

/**
 * Collapse whitespace/control runs, then test the WHOLE text for anything unsafe, and only then cap at
 * 140 code points (capping first could cut a long token below the pattern's length and let a fragment
 * through). Non-string, empty or unsafe -> null (the key is left out, the item is kept).
 */
function sanitiseCronDescription(value) {
  if (typeof value !== 'string') return null;
  const collapsed = value.replace(TITLE_WHITESPACE_OR_CONTROL, ' ').trim();
  if (collapsed === '' || CRON_DESCRIPTION_UNSAFE.test(collapsed)) return null;
  return Array.from(collapsed).slice(0, MAX_TITLE_CODE_POINTS).join('');
}

function sanitiseCronDate(value) {
  return isIsoTimestamp(value) && !Number.isNaN(Date.parse(value)) ? value : null;
}

/**
 * Sanitises one cron[] item by reconstruction (a `command`, `env` or any other extra key never
 * survives). Returns null to DROP the item when `name` or `schedule` is not a plain string in the
 * allowed character set (after trim and the length cap). `schedule_human` falls back to "" when
 * unusable, a date that is not ISO-8601 Z becomes null, and `last_result` outside the enum is
 * "unknown".
 */
function sanitiseCronItem(raw) {
  if (!isPlainObject(raw)) return null;
  if (typeof raw.name !== 'string' || typeof raw.schedule !== 'string') return null;
  const name = raw.name.trim().slice(0, CRON_NAME_MAX).trim();
  const schedule = raw.schedule.trim().slice(0, CRON_SCHEDULE_MAX).trim();
  if (!CRON_NAME.test(name) || !CRON_SCHEDULE.test(schedule)) return null;
  let human = typeof raw.schedule_human === 'string' ? raw.schedule_human.trim().slice(0, CRON_HUMAN_MAX).trim() : '';
  if (!CRON_HUMAN.test(human)) human = '';
  const item = {
    name,
    schedule,
    schedule_human: human,
    last_run: sanitiseCronDate(raw.last_run),
    last_result: CRON_RESULTS.includes(raw.last_result) ? raw.last_result : 'unknown',
    next_run: sanitiseCronDate(raw.next_run),
  };
  // Both optional: a beat from a host that predates them stores the item exactly as before.
  const description = sanitiseCronDescription(raw.description);
  if (description !== null) item.description = description;
  if (CRON_SOURCES.includes(raw.source)) item.source = raw.source;
  return item;
}

/** A non-array `cron` -> []; more than 50 items keeps the first 50 (before invalid ones are dropped). */
function sanitiseCron(raw) {
  if (!Array.isArray(raw)) return [];
  return raw.slice(0, MAX_CRON).map(sanitiseCronItem).filter((item) => item !== null);
}

// ---- scheduled_triggers[] (#769): the heartbeat of the workflows the supervisor fires in place of GitHub's cron (the release router above all).
// By reconstruction: a repo alias and a workflow file name held to a strict character set, a whole-minute interval and an ISO time or null.
const MAX_SCHEDULED_TRIGGERS = 50;
const TRIGGER_REPO = /^[A-Za-z0-9._-]{1,60}$/; // the host publishes the STATUS_REPO_ALIASES alias ("other" when unaliased); owner/repo travels only in full_repo below
const TRIGGER_FULL_REPO = /^(?!\.)[A-Za-z0-9._-]{1,60}\/(?!\.)[A-Za-z0-9._-]{1,100}$/; // #783: owner/repo, published only for aliased repos, used in the alert title only
const TRIGGER_WORKFLOW = /^[A-Za-z0-9._-]{1,80}\.ya?ml$/;
const MAX_TRIGGER_INTERVAL_MINUTES = 10080; // one week

function sanitiseScheduledTrigger(raw) {
  if (!isPlainObject(raw)) return null;
  if (typeof raw.repo !== 'string' || !TRIGGER_REPO.test(raw.repo)) return null;
  if (typeof raw.workflow !== 'string' || !TRIGGER_WORKFLOW.test(raw.workflow)) return null;
  const interval = raw.interval_minutes;
  if (!Number.isInteger(interval) || interval < 1 || interval > MAX_TRIGGER_INTERVAL_MINUTES) return null;
  const out = {
    repo: raw.repo,
    workflow: raw.workflow,
    interval_minutes: interval,
    last_fired_at: sanitiseCronDate(raw.last_fired_at),
    tracked_since: sanitiseCronDate(raw.tracked_since), // when the host first saw this line: "never fired" vs "just enabled"
  };
  if (typeof raw.full_repo === 'string' && TRIGGER_FULL_REPO.test(raw.full_repo)) out.full_repo = raw.full_repo; // additive: an older host omits it
  return out;
}

// #657: tracks CI_QUEUE_CATEGORY_VOCAB's length (not hand-picked) so adding/removing a vocab
// key never silently desyncs this cap.
const MAX_CI_QUEUE_CATEGORIES = CI_QUEUE_CATEGORY_VOCAB.length;

/**
 * Sanitises one `ci_queue.categories[]` entry. Returns null on any violation of the mandatory
 * `key`/`count` fields (that still drops the WHOLE `ci_queue`, per sanitiseCiQueue's contract).
 * `queued[]` (issue #657) is additive/optional WITHIN the entry, same reasoning as `runners[]`/
 * `runners_offline` within `ci_queue` itself: absent (a pre-#657 collector) or the wrong type
 * just omits the key; a malformed individual item is dropped on its own (see
 * sanitiseCiQueueQueued) — neither ever drops the category or the whole `ci_queue`.
 */
function sanitiseCiQueueCategory(raw) {
  if (!isPlainObject(raw)) return null;
  if (!(typeof raw.key === 'string' && CI_QUEUE_CATEGORY_VOCAB.includes(raw.key))) return null;
  if (!isIntInRange(raw.count, 0, 999)) return null;
  const result = { key: raw.key, count: raw.count };
  if (Array.isArray(raw.queued)) result.queued = sanitiseCiQueueQueued(raw.queued);
  return result;
}

// `ci_queue.categories[].queued[]` (issue #657): a capped list, NESTED inside each category
// entry, of the ACTUAL queued runs behind that category's count (not just the count) — repo,
// run_id, pr_url (always present, nullable — unlike current_job, which omits the whole key),
// title (optional free text, same exception as runs[].title), queued_at. No `key` field — it's
// implied by the parent category entry. `MAX_CI_QUEUE_QUEUED_ITEMS` mirrors
// `MAX_CI_QUEUE_RUNNERS`'s pattern, applied PER category entry (one noisy category must never
// crowd out another's items).
const MAX_CI_QUEUE_QUEUED_ITEMS = 10;

/**
 * Sanitises one `ci_queue.categories[].queued[]` entry. Returns null to DROP just this one entry
 * (same per-entry-drop reasoning as sanitiseCiQueueRunner — a single malformed queued item must
 * never blank the whole panel, let alone the category it lives in).
 */
function sanitiseCiQueueQueuedItem(raw) {
  if (!isPlainObject(raw)) return null;
  if (!(typeof raw.repo === 'string' && REPO_FULL.test(raw.repo))) return null;
  if (!isIntInRange(raw.run_id, 1, MAX_RUN_ID)) return null;
  if (!isIsoTimestamp(raw.queued_at)) return null;

  const item = { repo: raw.repo, run_id: raw.run_id, queued_at: raw.queued_at };
  // pr_url is always a present key (null when there's no attached PR) — the one deliberate
  // difference from current_job's "omit the whole key" convention (AC: "no attached PR -> list
  // item has pr_url: null, still included, not dropped").
  item.pr_url = typeof raw.pr_url === 'string' && PR_URL.test(raw.pr_url) ? raw.pr_url : null;
  const title = sanitiseTitle(raw.title);
  if (title !== null) item.title = title;
  return item;
}

/**
 * Sanitises one category entry's `queued[]`: non-array (already guarded by the caller) never
 * reaches here; each malformed entry is dropped individually (never fails the list, let alone
 * the category); capped at MAX_CI_QUEUE_QUEUED_ITEMS, preserving the collector's own order
 * (already oldest-queued_at-first) rather than re-sorting here.
 */
function sanitiseCiQueueQueued(raw) {
  return raw.map(sanitiseCiQueueQueuedItem).filter((item) => item !== null).slice(0, MAX_CI_QUEUE_QUEUED_ITEMS);
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

// `ci_queue.ci_metrics` (issue #660): a brand-new additive sibling of `runners[]`/
// `runners_offline` below — a pre-#660 collector never sends it, so absent/malformed drops only
// this key, never the whole `ci_queue` (same reasoning as those two).
const MAX_CI_METRICS_CATEGORIES = 4;
const MAX_METRICS_N = 999;
// A single CI run realistically never exceeds a day; generous, not tight, same reasoning as
// MAX_HISTORY_SECS above.
const MAX_METRICS_DURATION_SECS = 86400;

/** Sanitises one `ci_queue.ci_metrics.categories[].pass_rate_pct` (also reused for the top-level pass_rate_pct): null, or an int 0-100. `undefined` signals "invalid". */
function sanitiseMetricsPassRate(value) {
  if (value === null) return null;
  if (isIntInRange(value, 0, 100)) return value;
  return undefined;
}

/** Sanitises one `ci_queue.ci_metrics.categories[]` entry. Returns null on any violation. */
function sanitiseCiMetricsCategory(raw) {
  if (!isPlainObject(raw)) return null;
  if (!(typeof raw.key === 'string' && CI_METRICS_CATEGORY_VOCAB.includes(raw.key))) return null;
  if (!isIntInRange(raw.n, 1, MAX_METRICS_N)) return null;
  if (!isIntInRange(raw.avg_secs, 0, MAX_METRICS_DURATION_SECS)) return null;
  if (!isIntInRange(raw.p50_secs, 0, MAX_METRICS_DURATION_SECS)) return null;
  if (!isIntInRange(raw.p90_secs, 0, MAX_METRICS_DURATION_SECS)) return null;
  const passRate = sanitiseMetricsPassRate(raw.pass_rate_pct);
  if (passRate === undefined) return null;
  return {
    key: raw.key,
    n: raw.n,
    avg_secs: raw.avg_secs,
    p50_secs: raw.p50_secs,
    p90_secs: raw.p90_secs,
    pass_rate_pct: passRate,
  };
}

/**
 * Sanitises `ci_queue.ci_metrics` (issue #660). Unlike `ci_queue` itself, a malformed sub-field
 * here only ever drops this ONE key (never `ci_queue` as a whole) — see the comment above.
 * Returns null to omit the key.
 *
 * `categories[]` follows this file's "sanitise by reconstruction" convention (same as
 * `ci_queue.runners[]` below): one malformed entry drops only THAT entry, never the whole
 * `ci_metrics` object (fixed per PR #713 review — a single bad category, e.g. a negative
 * `avg_secs`, must not blank every category and the overall pass rate). A duplicate category key
 * is the same shape: the duplicate entry is dropped and the first occurrence of that key wins,
 * rather than dropping everything. `as_of`/`pass_rate_pct`/`pass_rate_n` stay whole-drop — they
 * are top-level fields of `ci_metrics` itself, not entries in a reconstructed list.
 *
 * `pass_rate_pct`/`pass_rate_n` are the issue's "today's OVERALL pass/fail rate" — computed by
 * the collector from today's eligible runs across ALL 4 categories at once (never a weighted
 * average re-derived from the per-category rates below, which would let a stale prior-day run
 * sitting in the same fetched page outweigh a real same-day failure) — both required fields, not
 * an additive exception like `runners[]`/`runners_offline` on `ci_queue`: every #660 collector
 * always emits them.
 */
function sanitiseCiMetrics(raw) {
  if (!isPlainObject(raw)) return null;
  if (!isIsoTimestamp(raw.as_of)) return null;
  if (!Array.isArray(raw.categories) || raw.categories.length > MAX_CI_METRICS_CATEGORIES) return null;
  const seenKeys = new Set();
  const categories = [];
  for (const rawCategory of raw.categories) {
    const category = sanitiseCiMetricsCategory(rawCategory);
    if (category === null) continue; // drop only this bad entry
    if (seenKeys.has(category.key)) continue; // duplicate key: keep the first occurrence only
    seenKeys.add(category.key);
    categories.push(category);
  }
  const passRate = sanitiseMetricsPassRate(raw.pass_rate_pct);
  if (passRate === undefined) return null;
  if (!isIntInRange(raw.pass_rate_n, 0, MAX_METRICS_N)) return null;
  return { as_of: raw.as_of, categories, pass_rate_pct: passRate, pass_rate_n: raw.pass_rate_n };
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

  // Additive (issue #660), same "present-and-malformed just omits this one key" reasoning as
  // runners[]/runners_offline above — a pre-#660 collector never sends either of these.
  const ciMetrics = sanitiseCiMetrics(raw.ci_metrics);
  if (ciMetrics !== null) result.ci_metrics = ciMetrics;

  if (typeof raw.ci_health === 'string' && CI_HEALTH_VOCAB.includes(raw.ci_health)) {
    result.ci_health = raw.ci_health;
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

  // Optional (alert banner): absent or non-array -> no key. First MAX_GOAL_STALL entries, then filtered.
  if (Array.isArray(parsedBody.goal_stall)) {
    const stalls = parsedBody.goal_stall.slice(0, MAX_GOAL_STALL).map(sanitiseGoalStall).filter((x) => x !== null);
    if (stalls.length > 0) value.goal_stall = stalls;
  }

  // Optional (#795): when this host's goal queue was last synced from the registry. Absent or not an ISO timestamp -> no key.
  if (isIsoTimestamp(parsedBody.goals_as_of)) value.goals_as_of = parsedBody.goals_as_of;

  // Optional (#769): absent or non-array -> no key. First 50 entries, then filtered.
  if (Array.isArray(parsedBody.scheduled_triggers)) {
    const triggers = parsedBody.scheduled_triggers.slice(0, MAX_SCHEDULED_TRIGGERS).map(sanitiseScheduledTrigger).filter((t) => t !== null);
    if (triggers.length > 0) value.scheduled_triggers = triggers;
  }

  // Optional (#782): the VM receiver's newest GitHub webhook event time (ISO-8601 Z), published by the VM host only while that feed is
  // stale. Anything else -> no key. The older per-host `webhook_stale` ({since}, #773) is no longer stored: the Mac's own apply of events
  // is not a webhook-health signal.
  const lastEvent = sanitiseCronDate(parsedBody.webhook_last_event_at);
  if (lastEvent !== null) value.webhook_last_event_at = lastEvent;

  // Optional (#781): absent or non-array -> no key. First MAX_SENTRY_CAP entries, then filtered; an item with nothing held is dropped.
  if (Array.isArray(parsedBody.sentry_cap)) {
    const caps = parsedBody.sentry_cap.slice(0, MAX_SENTRY_CAP).map(sanitiseSentryCapItem).filter((c) => c !== null && c.held.length > 0);
    if (caps.length > 0) value.sentry_cap = caps;
  }

  // Optional (issue #756): absent -> no key (an older host); present but not an array -> [].
  if ('cron' in parsedBody) value.cron = sanitiseCron(parsedBody.cron);

  // Optional (issue #643): absent, non-object, or any single malformed sub-field -> no key
  // (never a rejection, never a partial rebuild — see sanitiseCiQueue).
  const ciQueue = sanitiseCiQueue(parsedBody.ci_queue);
  if (ciQueue !== null) value.ci_queue = ciQueue;

  return { ok: true, value };
}
