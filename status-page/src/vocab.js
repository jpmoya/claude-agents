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
  'DEPLOYED TO STAGING',
  'PLAN READY',
  'PLAN FAIL',
  'PLAN PASS',
  'APPLIED',
  'AWAITING GO',
  'DECISION',
  'JP CONFIRMED',
];

// Fixed "what JP has to do" labels (issue #139) — the only values `runs[].needs` may carry — and the
// reasons a held ticket is demoted out of Needs JP by the host (`runs[].parked_reason`).
export const NEEDS_VOCAB = ['Approve mockups', 'Say go', 'Approve effort', 'Missing credential', 'Decision needed'];
export const PARKED_REASON_VOCAB = ['answered', 'out_of_scope', 'auto_retry'];
export const BLOCK_CLASS_VOCAB = ['ci_pending', 'ci_red', 'merge_conflict', 'dependency', 'unsupported_project', 'other'];

// `ci_queue.categories[].key` / `ci_queue.oldest.key` (issue #643, split by #657): a closed
// vocabulary — no free-text category labels ever reach storage. The Worker/render side maps
// each key to display text later (ticket #644; until #659 ships, render.js's label map falls
// back to "Other" for the two new keys below — documented, not a bug). #657 splits the old
// single `deploy_release` bucket via a 5-rule cascade (name contains "staging" -> `staging_deploy`
// regardless of branch; else name contains "cleanup"/"announce" -> stays `deploy_release`; else
// head_branch == "main" -> `prod_deploy`; else head_branch == "staging" -> `staging_deploy`; else
// `deploy_release`), applied only once a run's name has already matched deploy|release — see
// ci-queue-collect.sh's `_ciq_categorize` for the exact precedence. This order must match the
// collector's own `$vocab` array in `collect_once` exactly.
export const CI_QUEUE_CATEGORY_VOCAB = ['dependabot', 'prod_deploy', 'staging_deploy', 'deploy_release', 'pr', 'other'];

// `ci_queue.runners[].role` (issue #648): distinguishes the production-deploy-labeled runner
// (GitHub label `benjis-ci-prod-deploy`, #2440 in benjis-ops-tool) from the general `benjis-ci`
// pool — #649 (render, dependent on this ticket) styles/groups them separately. A closed
// vocabulary, same reasoning as CI_QUEUE_CATEGORY_VOCAB: no free-text label ever reaches storage.
export const CI_RUNNER_ROLE_VOCAB = ['general', 'prod_deploy'];

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
 */
export function computeThresholds(keepaliveSecs) {
  const staleSecs = Math.round((2.5 * keepaliveSecs) / 60) * 60;
  const offlineSecs = 3 * staleSecs;
  return { staleSecs, offlineSecs };
}
