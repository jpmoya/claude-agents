// src/validate.js — pure allowlist validator for the frozen v1 heartbeat payload.
//
// Sanitise-by-reconstruction: build a fresh object from the allowlist below so an unknown key
// (or a `sessions` field) can never survive onto the object that reaches KV. Invariant: no
// free-text string reaches storage — every string field is an enum or a strict pattern. See
// issue #11 / #4 §5 for the full field table.

import { STAGE_VOCAB, MARKER_VOCAB, STATE_VOCAB } from './vocab.js';

const ISO_8601_Z = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const REPO_ALIAS = /^[a-z0-9][a-z0-9-]{0,23}$/;
const MAX_RUNS = 20;

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

/** Sanitises a single capacity field: integer 0-99, clamped; non-numeric -> 0. */
function sanitiseCapacityField(value) {
  const clamped = clampInt(value, 0, 99);
  return clamped === null ? 0 : clamped;
}

/** Sanitises `runs[].repo`: strict alias pattern, else "other". */
function sanitiseRepo(value) {
  return typeof value === 'string' && REPO_ALIAS.test(value) ? value : 'other';
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
    restarts: sanitiseCapacityField(rawRun.restarts),
  };

  if (isIsoTimestamp(rawRun.started_at)) run.started_at = rawRun.started_at;
  if (isIsoTimestamp(rawRun.last_activity_at)) run.last_activity_at = rawRun.last_activity_at;

  return run;
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
    running: sanitiseCapacityField(rawCapacity.running),
    max: sanitiseCapacityField(rawCapacity.max),
    queued: sanitiseCapacityField(rawCapacity.queued),
  };

  value.runs = parsedBody.runs.map(sanitiseRun).filter((run) => run !== null);

  return { ok: true, value };
}
