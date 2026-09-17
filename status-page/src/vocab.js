// src/vocab.js — enums + tunables for the status-page Worker.
//
// This file is *config data*, not logic (per the solutions-architect design on #4 §5): the two
// vocabularies and the keep-alive constant are plain arrays/numbers with no branching. The
// derived-threshold function below is the one piece of real logic in this file and is left as a
// throwing stub for the fullstack-developer.
//
// Source of truth (drift here degrades an unrecognised value to "other" in validate.js — it
// never becomes a validation error, per AC4):
//   - STAGE_VOCAB  <- filenames under `agents/` (excluding README.md)
//   - MARKER_VOCAB <- the deduplicated set of routing markers in hooks/pipeline-markers.sh
//                      (markers_for(), all agents except the human `jp` marker set)

export const STAGE_VOCAB = [
  'product-manager',
  'ux-flow-designer',
  'ui-ux-designer',
  'solutions-architect',
  'design-research',
  'test-writer',
  'test-reviewer',
  'fullstack-developer',
  'code-reviewer',
  'deployer',
  'infra-planner',
  'infra-reviewer',
  'infra-operator',
  'orchestrator',
];

export const MARKER_VOCAB = [
  'READY FOR ARCHITECTURE',
  'READY FOR ENGINEERING',
  'EFFORT APPROVAL NEEDED',
  'BLOCKED',
  'USER FLOW READY',
  'NO UX NEEDED',
  'NEEDS PM REVISION',
  'MOCKUPS PENDING APPROVAL',
  'SPEC RESOLVED',
  'SPLIT',
  'TESTS WRITTEN',
  'TEST UPHELD',
  'TESTS APPROVED',
  'TESTS FAIL',
  'PASS',
  'FAIL',
  'IMPLEMENTED',
  'TEST DEFECT',
  'DEPLOYED',
  'PLAN READY',
  'PLAN FAIL',
  'PLAN PASS',
  'APPLIED',
  'AWAITING GO',
];

// The `runs[].state` enum (validate.js table) — fixed by the frozen v1 payload contract,
// not derived from a repo scan the way STAGE_VOCAB/MARKER_VOCAB are.
export const STATE_VOCAB = ['running', 'restarting', 'queued', 'held'];

// Keep-alive interval in seconds — the single tunable. stale_secs/offline_secs (AC13) are
// derived from this, never hand-picked. Reverting to the originally-locked 5/15 min thresholds
// is a one-line change here.
export const KEEPALIVE_SECS = 600;

/**
 * Derives { staleSecs, offlineSecs } from a keep-alive interval, per AC13:
 *   staleSecs   = round(2.5 * keepaliveSecs) to the nearest minute, expressed in seconds
 *   offlineSecs = 3 * staleSecs
 * STUB — no arithmetic here yet. Throws until implemented by the fullstack-developer.
 */
export function computeThresholds(keepaliveSecs) {
  throw new Error('NotImplemented');
}
