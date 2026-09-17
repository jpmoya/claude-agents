// src/validate.js — pure allowlist validator for the frozen v1 heartbeat payload.
//
// Sanitise-by-reconstruction: build a fresh object from the allowlist below so an unknown key
// (or a `sessions` field) can never survive onto the object that reaches KV. Invariant: no
// free-text string reaches storage — every string field is an enum or a strict pattern. See
// issue #11 / #4 §5 for the full field table.
//
// STUB — no branching, no data access yet. Throws until implemented by the fullstack-developer.
// Tests exercise this both directly (unit) and indirectly via the exported `fetch` handler in
// src/index.js (also a throwing stub).

/**
 * @param {unknown} parsedBody - already-JSON-parsed request body
 * @returns {{ ok: true, value: object } | { ok: false, reason: 'bad-json'|'bad-version'|'too-many-runs' }}
 */
export function validateBeatPayload(parsedBody) {
  throw new Error('NotImplemented');
}
