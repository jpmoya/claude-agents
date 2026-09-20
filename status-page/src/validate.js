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

import { STAGE_VOCAB, MARKER_VOCAB, STATE_VOCAB } from './vocab.js';

const ISO_8601_Z = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const REPO_ALIAS = /^[a-z0-9][a-z0-9-]{0,23}$/;
const ISSUE_URL = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/issues\/\d+$/;
const TITLE_WHITESPACE_OR_CONTROL = /[\u0000-\u001f\u007f\s]+/g;
const MAX_TITLE_CODE_POINTS = 140;
const MAX_RUNS = 20;
const MAX_COMPLETED = 10;

/** True iff `value` is a string that is exactly a GitHub issue URL. render.js re-checks with it. */
export function isIssueUrl(value) {
  return typeof value === 'string' && ISSUE_URL.test(value);
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
  return typeof value === 'string' && STAGE_VOCAB.includes(value) ? value : 'other';
}

/** Sanitises `runs[].marker`: known routing-marker enum, else "other". */
function sanitiseMarker(value) {
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

  const title = sanitiseTitle(rawRun.title);
  if (title !== null) run.title = title;
  if (isIssueUrl(rawRun.url)) run.url = rawRun.url;

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

  return item;
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

  return { ok: true, value };
}
