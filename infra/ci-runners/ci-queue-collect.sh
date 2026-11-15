#!/usr/bin/env bash
# ci-queue-collect.sh (#643): snapshots live GitHub Actions queue depth + runner load and writes
# $PIPE/status-ci.json, which report-status.sh then rides along in the beat payload as the
# optional `ci_queue` key. Host-side only (default host: the Mac, enabled via
# CI_QUEUE_COLLECT_ENABLED=1 in ~/.claude/pipeline/config.local.sh) — no new Worker secret, no
# Worker-side cron hitting GitHub. Piggybacks on the existing reconcile/heartbeat cycle
# (report-status.sh invokes this in the background, fire-and-forget); this script throttles
# itself so calling it often is harmless.
#
# Usage: ci-queue-collect.sh          run one collection cycle (or skip it, throttled); always exit 0
#
# On any API failure — including a simulated 403/429, a curl failure, or a 200 response that
# parses but is missing its expected top-level key (malformed/unexpected shape) — the PREVIOUS
# $PIPE/status-ci.json is left byte-for-byte untouched — this script never writes a
# partial/zeroed snapshot. A single failure is reported to Sentry only; a Slack post (existing
# webhook, no new one) fires once a failure streak reaches 2 consecutive cycles (#663 AC6 — was
# 3; an intermittent pair of failures a day apart used to never page at all), carrying the
# redacted tail of `gh api`'s own stderr for diagnosis. A mkdir-based lock (same stale-reclaim
# pattern as report-status.sh's own) keeps two near-simultaneous invocations from both slipping
# past the throttle and doubling the real API calls.
#
# #663 AC4: one configured repo failing (renamed/archived/access lost) no longer aborts the whole
# cycle — every OTHER repo's data still gets collected and written; the failing repo's name is
# surfaced in the new `unavailable_repos` field. Only "every configured repo failed" still aborts
# the cycle (same previous-snapshot-kept contract as any other API failure — see
# `collect_once`'s own comment for why a snapshot with zero repos' worth of real data would
# violate this file's own "never a partial/zeroed write" invariant).
#
# #663 AC3: `_ciq_call`'s `gh api` invocation is now wrapped in a timeout (default 55s, safely
# under the 60s stale-lock-reclaim window above) — a hung call used to never return at all, so it
# never reached the existing failure-counting path. See `_ciq_gh_api`/`_ciq_timeout_bin` below for
# why this isn't just `timeout "$secs" ...` (stock macOS, where this runs, ships neither `timeout`
# nor `gtimeout` by default).
#
# API calls per cycle (bounded, #637): 2 runner-list calls (org + jpmoya/claude-agents repo-level)
# + 2 run-list calls per repo (status=queued, status=in_progress) + up to
# MAX_RUN_LOOKUPS_PER_REPO job-lookup calls per repo, + 1 extra run-list call per repo ONLY when
# that repo's queued backlog spans more than one page (#645 review finding 1 — see
# _ciq_collect_repo's "last page" fetch below), + (#660, only when CI_QUEUE_METRICS_ENABLED=1 AND
# this cycle's own slower metrics cadence is due) exactly 1 more run-list call per repo
# (status=completed) — see _ciq_collect_metrics_once. No --paginate anywhere (one HTTP call per `gh api`
# invocation) — each call also uses a fixed per_page instead of walking pages.
#
# #648: runners_busy/runners_total now count ONLINE runners only (status=="online"), with a new
# runners_offline count and a per-runner runners[] array (identity + 24h/72h utilization rollup).
#
# CORRECTED (post-BLOCKED ruling, see the issue's corrected AC3/AC6 text): GitHub's numeric runner
# `id` is NOT stable across a slot's re-registration — live evidence showed every ephemeral job
# mints a brand-new id AND a new name suffix together for the same physical slot; only a dead/
# offline registration ever keeps an old id. History is therefore keyed by SLOT: a runner's `name`
# with its trailing `-[0-9]+` numeric suffix stripped (e.g. `gha-CI-ubuntu-8gb-ash-2-1-29555` ->
# slot `gha-CI-ubuntu-8gb-ash-2-1`), computed once per registration in _ciq_merge_runners. A slot
# is online if any of its CURRENT cycle's registrations is online; busy if any online registration
# is busy. `runners[].id`/`.name`/`.role` come from the slot's current (most recent == highest-id)
# registration. runners_busy/runners_total/runners_offline stay counted PER REGISTRATION (AC1 is
# unaffected by this — that counting never depended on the keying scheme).
#
# This adds ZERO new `gh api` calls: the runner list was already fetched above for the busy/total
# count; only how it's processed/stored changes (AC9). History is a new append-only sample file,
# $PIPE/ci-runner-samples.jsonl by default (ONE line per currently-known SLOT per cycle, not per
# registration — a dead duplicate sharing a slot with a live one must never dilute that slot's
# utilization): {ts, slot, id, name, online, busy, role} — `id`/`name`/`role` ride along (the slot's
# current representative) so a slot that stops being returned by the API (deregistered) can still
# be shown, using its last-known identity, until its samples age out past the 72h window; `ts` is a
# unix epoch, not ISO, since this is a local sample stream, not part of the beat payload itself),
# pruned to 72h + one cycle's buffer every cycle.
# util_24h_pct/util_72h_pct for a given cycle are computed from samples taken BEFORE that cycle's
# own append (so a slot's very first-ever cycle reports null, not 0/100 from its own single
# fresh sample — AC7); the fresh sample is appended after the rollup, feeding the NEXT cycle.
# `runners[]` is ordered live-slots-first (then lingering slots), each group sorted by slot name,
# BEFORE the MAX_SAMPLE_RUNNERS cap is applied — never sorted by id/age, which would evict the
# currently-live slots in favor of whichever happened to have a lower id.
#
# #655: two more per-slot fields. `history_secs` (AC A) = now - the oldest retained sample's `ts`
# for that slot (0 for a slot with no prior samples), so render.js can flag a util_24h_pct/
# util_72h_pct that's still "building" instead of looking like a confident full-window average.
# `current_job` (AC B) = {repo, run_id, pr_url?}, attached only to a slot that's busy THIS cycle,
# matched from an in_progress job's `runner_name` (reduced to a slot the same way a registration
# is). This adds ZERO new `gh api` calls: `_ciq_collect_repo` already fetches each run's job list
# for the existing queued-jobs/categories[] extraction; this only reads one more field
# (`runner_name`) off jobs already in hand, plus the run's own `pull_requests[]` (already present
# on every run object the queued/in_progress run-list calls return — no per-job extra call).
# `pr_url` prefers `pull_requests[0].html_url` but GitHub's real shape for that field has no
# `html_url` (verified live against org repos before implementing) — only `number` — so it's built
# as `https://github.com/<repo>/pull/<number>` from the validated `repo` + that `number` instead.
#
# #658: `current_job` could still go missing for a genuinely busy runner (100% of the time, not
# intermittently) whenever a repo's queued backlog alone reached MAX_RUN_LOOKUPS_PER_REPO — the
# job-lookup cap was exhausted on queued runs before the in_progress run holding the busy runner's
# job was ever looked up. `_ciq_collect_repo` now reserves part of that SAME bounded cap for
# in_progress-source runs (capped by the current online+busy runner count), rather than letting
# queued runs always win it all — see that function's comment for the exact split. Still zero new
# `gh api` calls: the total number of job lookups per repo stays min(run count, cap), only which
# runs get them changes.
#
# #658 (round 2 — PR #664 review finding): the round-1 reservation above picks the OLDEST `r`
# in_progress runs every cycle. When a repo has MORE in_progress runs than `r`, a NEWER in_progress
# run holding the busy runner's job can simply never be among the oldest `r`, so `current_job`
# stays null forever for that runner — not intermittently, 100% of the time. `_ciq_collect_repo`'s
# in_progress-side selection is now sticky-then-rotation (see that function's comment): a run
# already known to be holding a busy runner's job is looked up again first (no flicker), and the
# remaining budget rotates through the rest by a cursor that advances every cycle, so every
# in_progress run is eventually looked up.
#
# #658 (round 3 — PR #667 review finding): round 2's sticky set had no cap of its own, so once it
# grew to fill the entire in_progress selection budget (every slot held by a run that keeps being
# busy), the rotation side got ZERO slots and an unresolved run could stay unlinked for as long as
# the sticky jobs kept running — unbounded, not the stated cycle bound. Round 3's own fix capped
# sticky at (budget - 1) whenever ANY unresolved rotation candidate existed, at all — too blunt
# (round 4 below fixed it): most rotation candidates sit on runners that are, and stay, idle, so
# that cap evicted an already-resolved busy-runner link every cycle with nothing to show for it.
# `_ciq_collect_repo` now caps sticky at (budget - 1) only when there is a real competing busy
# runner left unresolved — see that function's comment (items (d)/(e)) for the exact mechanism
# and the resulting bound. This needs cross-cycle memory: a new state
# file, $CI_QUEUE_IP_STATE_FILE (separate from $STATE_FILE, which _ciq_write_fails fully overwrites
# every cycle), keyed by repo: {"<repo>": {"sticky": [<run id>...], "cursor": <run id>}}. Written
# atomically, same mktemp+mv pattern as $OUT, and ONLY once the whole cycle has already succeeded
# (see _ciq_update_ip_state) — a failed cycle leaves it byte-for-byte untouched, same contract as
# $OUT/$STATE_FILE. A missing or corrupt/unparseable file is treated as "no sticky set, cursor 0"
# for every repo — it never aborts the cycle. Still zero new `gh api` calls: this only changes
# which in_progress run IDs fill the existing r/qsel/pextra slots.
#
# #657: the old single `deploy_release` category bucket conflated a prod merge/deploy with a
# staging deploy with release housekeeping. `_ciq_categorize` now applies a 5-rule cascade
# (JP-ruled, see the issue's delivery-lead JP CONFIRMED comment) ONLY once a run's name has
# already matched the pre-existing deploy|release gate: name contains "staging" -> `staging_deploy`
# regardless of branch; else name contains "cleanup"/"announce" -> stays `deploy_release`
# (housekeeping denylist); else `head_branch == "main"` -> `prod_deploy`; else `head_branch ==
# "staging"` -> `staging_deploy`; else `deploy_release` (unchanged fallback). `head_branch` is
# already present on every run object the existing queued/in_progress run-list calls return — no
# new `gh api` call; see _ciq_categorize's own comment for the live-data cases that ruled out the
# ticket's simpler branch-only rule. `ci_queue.categories[].queued[]` is new: a capped
# (MAX_CI_QUEUE_QUEUED_ITEMS per category) list, NESTED inside each category entry, of the ACTUAL
# queued runs behind that category's count — repo, run_id, pr_url (always present, nullable),
# title (optional), queued_at. Built from the FULL per-repo queued-run list (qjson/qlast — the
# same `status=queued` run-list responses already fetched for queued_total/`oldest`), NOT from
# the job-lookup-capped selection used for categories[].count/current_job: that cap
# (MAX_RUN_LOOKUPS_PER_REPO) exists to bound `gh api` calls, and building queued[] from it would
# collapse to ~1 item per repo exactly when the runner fleet is busy (the #658 reservation leaves
# the queued side only 1-2 of the cap's slots under load) — precisely the deep-backlog scenario
# this ticket exists for. Still zero new `gh api` calls: a `status=queued` run's own `created_at`
# IS its queued-since timestamp, no job lookup needed. Deduped GLOBALLY by run id in collect_once
# (the scheduler/benjis-ops-tool repo alias in scripts/ci-metrics.repos means the same physical
# run can otherwise appear via two entries). Documented limitation: categories[].count stays
# per-JOB (from the job-lookup-capped loop, unchanged) while `queued[]` is per-RUN from the full
# list — a category's count and the length of its own `queued[]` can legitimately disagree, by
# design, not a bug (see _ciq_collect_repo's own comment for the full reasoning).
#
# Env (production): CI_QUEUE_COLLECT_ENABLED (gate, read by report-status.sh, not this script),
#   PIPE, GH_TOKEN (optional — the host's own `gh` auth is used), SLACK_WEBHOOK_URL, SENTRY_DSN,
#   CI_QUEUE_REPOS_FILE (default: scripts/ci-metrics.repos), CI_QUEUE_ORG (default: Benjis-Plants),
#   CI_QUEUE_SELF_REPO (default: jpmoya/claude-agents — its runners are repo-level, not org-level),
#   CI_QUEUE_INTERVAL_SECS (default 240 — "every ~3-5 min"), CI_QUEUE_PROD_DEPLOY_LABEL (default
#   benjis-ci-prod-deploy — the GitHub runner label that sets `runners[].role` to "prod_deploy"),
#   CI_QUEUE_GH_TIMEOUT_SECS (#663 AC3, default 55 — per-call `gh api` timeout).
#   #660: CI_QUEUE_METRICS_ENABLED — THIS SCRIPT defaults it to 0 when run directly (so a bare
#   invocation never makes an extra live call); config.sh defaults it to 1 for the
#   report-status.sh path (automatic once a host already has CI_QUEUE_COLLECT_ENABLED=1), and a
#   host opts OUT by setting CI_QUEUE_METRICS_ENABLED=0 in its own config.local.sh.
#   CI_QUEUE_METRICS_INTERVAL_SECS (default 900 — its own, slower, decoupled cadence),
#   CI_QUEUE_DEGRADED_QUEUE_AGE_SECS (default 900), CI_QUEUE_DEGRADED_PASS_RATE_PCT (default 80),
#   CI_QUEUE_DEGRADED_MIN_SAMPLES (default 5), CI_QUEUE_DOWN_STALE_CYCLES (default 3).
# Env (tests): CI_QUEUE_FIXTURE_DIR (canned `gh api` JSON responses instead of a live call — see
#   _ciq_call below; mirrors ci-report.sh's CI_REPORT_JOBS_FILE seam), CI_QUEUE_FIXTURE_FAIL=1
#   (simulate every API call failing), CI_QUEUE_FORCE=1 (skip the throttle), CI_QUEUE_OUT /
#   CI_QUEUE_ATTEMPT_FILE / CI_QUEUE_STATE_FILE / CI_QUEUE_LOCKDIR (relocate the written files),
#   CI_QUEUE_CALL_LOG (dump the total API call count to this path, for the AC6 bound test),
#   CI_QUEUE_SAMPLES_FILE (relocate the per-runner sample stream), CI_QUEUE_NOW (epoch seconds —
#   freezes "now" for the sample/prune/rollup window math so tests are deterministic),
#   CI_QUEUE_IP_STATE_FILE (relocate the #658 round-2 sticky/cursor state file — default
#   $(dirname "$STATE_FILE")/ci-queue-collect.ip-state.json, deliberately derived from $STATE_FILE
#   rather than $PIPE directly, since existing tests override CI_QUEUE_STATE_FILE to a per-test tmp
#   dir without ever setting PIPE).
#   #660: CI_QUEUE_METRICS_FORCE=1 (skip ONLY the metrics cycle's own throttle, independent of
#   CI_QUEUE_FORCE), CI_QUEUE_METRICS_OUT / CI_QUEUE_METRICS_ATTEMPT_FILE /
#   CI_QUEUE_METRICS_STATE_FILE (relocate the metrics-only written files), CI_QUEUE_METRICS_PER_PAGE.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PIPE=${PIPE:-$HOME/.claude/pipeline/state}
OUT=${CI_QUEUE_OUT:-$PIPE/status-ci.json}
ATTEMPT_FILE=${CI_QUEUE_ATTEMPT_FILE:-$PIPE/ci-queue-collect.attempt}
STATE_FILE=${CI_QUEUE_STATE_FILE:-$PIPE/ci-queue-collect.state}
# #658 round 2: separate from $STATE_FILE (which _ciq_write_fails fully overwrites every cycle).
# Derived from $STATE_FILE's own dirname, not $PIPE directly, so tests that override
# CI_QUEUE_STATE_FILE alone (without ever setting PIPE) stay hermetic.
IP_STATE_FILE=${CI_QUEUE_IP_STATE_FILE:-"$(dirname "$STATE_FILE")/ci-queue-collect.ip-state.json"}
# Shared with the daily ci-metrics.sh->Slack pipeline's own repo list (read-only here, never
# written) — #660's live metrics fetch (_ciq_collect_metrics_once) reuses this same `repos()` loop,
# so editing this file for the Slack pipeline also changes which repos the live metrics cover. No
# call is ever made INTO that pipeline (PR #713 review, LOW) — only the file is shared.
REPOS_FILE=${CI_QUEUE_REPOS_FILE:-$HERE/../../scripts/ci-metrics.repos}
ORG=${CI_QUEUE_ORG:-Benjis-Plants}
SELF_REPO=${CI_QUEUE_SELF_REPO:-jpmoya/claude-agents}
INTERVAL=${CI_QUEUE_INTERVAL_SECS:-240}
PER_PAGE=${CI_QUEUE_PER_PAGE:-100}   # GitHub's max; free (same single call), shrinks how often a repo needs the extra last-page fetch below
# Bounds total API calls per cycle (#637): 2 (runners) + 2*repos (run lists) + repos*MAX_RUN_LOOKUPS_PER_REPO (job lookups)
# + up to 1*repos extra (#645 — only repos whose queued backlog exceeds one page get the last-page fetch).
MAX_RUN_LOOKUPS_PER_REPO=5
RELEASE=${CI_QUEUE_RELEASE:-$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)}
ENVIRONMENT=${CI_QUEUE_ENVIRONMENT:-$(hostname -s 2>/dev/null || echo unknown)}
# #663 AC3: per-`gh api`-call timeout, safely under the 60s stale-lock-reclaim window in main().
GH_TIMEOUT_SECS=${CI_QUEUE_GH_TIMEOUT_SECS:-55}

# #648: per-runner utilization history.
SAMPLES_FILE=${CI_QUEUE_SAMPLES_FILE:-$PIPE/ci-runner-samples.jsonl}
PROD_DEPLOY_LABEL=${CI_QUEUE_PROD_DEPLOY_LABEL:-benjis-ci-prod-deploy}
WINDOW_24H_SECS=86400
WINDOW_72H_SECS=259200
MAX_SAMPLE_RUNNERS=30   # mirrors status-page/src/validate.js's MAX_CI_QUEUE_RUNNERS cap
MAX_CI_QUEUE_QUEUED_ITEMS=10   # mirrors status-page/src/validate.js's MAX_CI_QUEUE_QUEUED_ITEMS cap, applied PER category (#657)

# #660: live duration/health metrics, decoupled from the queue-depth cadence above (own throttle,
# own attempt/fail-streak/output files — see _ciq_collect_metrics). THIS script's own default is
# OFF (CI_QUEUE_METRICS_ENABLED=0): every direct invocation that never sets this env var — every
# pre-#660 bash/vitest test, a developer running this script by hand — must see zero behavior
# change (no extra `gh api` call, no new file touched). Production is the opposite: config.sh
# (NOT this script) defaults it to 1 for the report-status.sh path, so metrics turns on
# automatically on whichever host already has CI_QUEUE_COLLECT_ENABLED=1 — a host opts OUT by
# setting CI_QUEUE_METRICS_ENABLED=0 in its own config.local.sh. report-status.sh forwards
# whatever that resolves to onto this script's launch line, same explicit-env pattern as its
# PIPE/SLACK_WEBHOOK_URL/SENTRY_DSN/GH_TOKEN siblings.
CI_QUEUE_METRICS_ENABLED=${CI_QUEUE_METRICS_ENABLED:-0}
CI_QUEUE_METRICS_INTERVAL_SECS=${CI_QUEUE_METRICS_INTERVAL_SECS:-900}   # 15 min, JP's "recommend every 15 min"
CI_QUEUE_METRICS_PER_PAGE=${CI_QUEUE_METRICS_PER_PAGE:-100}   # GitHub's max; the "capped history window" is just this one page
METRICS_OUT=${CI_QUEUE_METRICS_OUT:-$PIPE/ci-metrics.json}
METRICS_ATTEMPT_FILE=${CI_QUEUE_METRICS_ATTEMPT_FILE:-$PIPE/ci-queue-metrics.attempt}
METRICS_STATE_FILE=${CI_QUEUE_METRICS_STATE_FILE:-$PIPE/ci-queue-metrics.state}
MAX_CI_METRICS_DURATION_SECS=86400   # a single CI run realistically never exceeds a day; mirrors validate.js's cap
# ci_health thresholds (#660 — "cadence is this ticket's call, JP invited standard-metric judgment"):
CI_QUEUE_DEGRADED_QUEUE_AGE_SECS=${CI_QUEUE_DEGRADED_QUEUE_AGE_SECS:-900}   # 15 min, the issue's own example
CI_QUEUE_DEGRADED_PASS_RATE_PCT=${CI_QUEUE_DEGRADED_PASS_RATE_PCT:-80}
CI_QUEUE_DEGRADED_MIN_SAMPLES=${CI_QUEUE_DEGRADED_MIN_SAMPLES:-5}   # today's pass-rate leg needs at least this many eligible runs
CI_QUEUE_DOWN_STALE_CYCLES=${CI_QUEUE_DOWN_STALE_CYCLES:-3}   # metrics snapshot older than 3 of its own 15-min cycles -> down

repos() { grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[[:space:]]*$' "$REPOS_FILE"; }

# _ciq_timeout_bin — #663 AC3: prints the name of a GNU-coreutils-style `timeout` binary on PATH,
# or "" if neither exists. Stock macOS (where this script actually runs in production) ships
# neither `timeout` nor `gtimeout` by default — verified live, not assumed — so `_ciq_gh_api`
# below always has a fallback that needs no external binary at all.
_ciq_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'
  else printf ''
  fi
}

# _ciq_gh_api <secs> <api-path> -> `gh api`'s stdout; stderr is APPENDED (never overwritten — one
# file for the whole cycle) to $WORK/gh-stderr.log, so a later failure's handler can report what
# `gh` actually said (#663 AC6) without needing a variable to survive out of this function's own
# `$(...)` subshell (it can't — see _ciq_call's own call-counting comment for the same problem).
#
# Prefers a real `timeout`/`gtimeout` binary — those actively TERM-then-KILL the child process
# group on expiry, so they work regardless of whether the child itself does anything with a
# signal. The no-binary fallback must do the same active kill, NOT rely on a signal the child
# might ignore: `gh` is a Go binary, and the Go runtime installs its own SIGALRM handler that
# does nothing unless the program explicitly calls `signal.Notify` for it — a bare `perl -e
# 'alarm shift; exec @ARGV'` (a pending alarm surviving `exec`) only works if whatever `exec`
# replaces itself with dies on SIGALRM, which `gh` does not. So the fallback instead forks,
# `exec`s `gh` in the child, and the PARENT's alarm handler actively TERMs (then KILLs, after a
# 2s grace period) the child by pid — this kills `gh` whether or not it ever looks at signals.
# Exit code 124 on a timeout (matching GNU `timeout`'s own convention), and the "timed out"
# message lands in $WORK/gh-stderr.log so AC6's alert names the actual cause, not just "failed".
_ciq_gh_api() {
  local secs=$1 path=$2 tb
  tb=$(_ciq_timeout_bin)
  if [ -n "$tb" ]; then
    "$tb" "$secs" gh api "$path" 2>>"$WORK/gh-stderr.log"
  else
    perl -e '
      my $secs = shift;
      my $pid = fork();
      if (!defined $pid) { exit 125; }
      if ($pid == 0) { exec(@ARGV); exit 127; }
      $SIG{ALRM} = sub {
        print STDERR "gh api timed out after ${secs}s\n";
        kill "TERM", $pid;
        sleep 2;
        kill "KILL", $pid;
        waitpid($pid, 0);
        exit 124;
      };
      alarm($secs);
      waitpid($pid, 0);
      my $rc = $?;
      exit($rc & 127 ? 128 + ($rc & 127) : $rc >> 8);
    ' "$secs" gh api "$path" 2>>"$WORK/gh-stderr.log"
  fi
}

# _ciq_call <api-path> <fixture-basename> -> JSON on stdout; returns 1 on any failure (a real
# `gh api` non-zero exit — including a 403/429 HTTP error, a timeout (#663 AC3), or a forced test
# failure). Never raises an error to stdout: a failed call means the caller aborts the whole cycle
# (or, for a per-repo call, just that repo — see _ciq_collect_repo/#663 AC4) so the previous
# snapshot is kept untouched.
#
# Call counting (AC6): almost every call site captures this function's stdout via `$(...)`,
# which runs it in a subshell — a plain incremented shell variable would never survive back to
# the parent. Appending a byte to a file in $WORK (one per call, line count = call count) does.
_ciq_call() {
  printf '.' >> "$WORK/calls.count" 2>/dev/null || true
  if [ "${CI_QUEUE_FIXTURE_FAIL:-0}" = "1" ]; then return 1; fi
  if [ -n "${CI_QUEUE_FIXTURE_DIR:-}" ]; then
    local f="$CI_QUEUE_FIXTURE_DIR/$2"
    [ -r "$f" ] && cat "$f" || return 1
  else
    _ciq_gh_api "$GH_TIMEOUT_SECS" "$1" || return 1
  fi
}

# _ciq_call_shaped <api-path> <fixture-basename> <required-key> -> JSON on stdout; returns 1 on
# any failure OR when the response parses but is missing <required-key> (a malformed/unexpected
# 200 body). Without this, a malformed response would silently look like "zero runners/jobs" and
# get written as a false snapshot instead of aborting the cycle — the ticket treats a malformed
# response the same as an API failure (previous snapshot kept, never a partial/zeroed write).
_ciq_call_shaped() {
  local body
  body=$(_ciq_call "$1" "$2") || return 1
  printf '%s' "$body" | jq -e --arg k "$3" 'has($k)' >/dev/null 2>&1 || return 1
  printf '%s' "$body"
}

# _CIQ_CATEGORIZE_JQ — the categorize cascade as a reusable jq `def`, shared between
# _ciq_categorize (per-run, stdin, used by the job-lookup loop) and _ciq_collect_repo's bulk
# queued-run pass (building ci_queue.categories[].queued[], below) — the cascade lives in exactly
# ONE place so the two populations can never silently diverge. Precedence: dependabot actor, then
# a deploy/release workflow name, then a pull_request(_target)-triggered run, else "other" (never
# silently dropped) — UNCHANGED by #657: the 5-rule cascade below is a SUB-decision made only once
# a run has already matched the deploy/release name test, so it can never steal a run away from
# the `pr`/`other` buckets (e.g. a pull_request-triggered run literally named "Staging smoke
# tests" still categorizes as `pr`, not `staging_deploy` — JP's ruling was about splitting the
# deploy_release bucket, not reordering this outer precedence).
#
# #657 (JP-ruled 5-rule cascade — supersedes the ticket's own simpler "head_branch == main/
# staging" rule, which live data showed misclassifies a schedule-triggered "Deploy Staging
# Preview" run (head_branch main, but a staging deploy by name and by what it does) and every
# workflow_run-triggered "Post-release cleanup"/"Announce release" run (head_branch main,
# inherited from the deploy it's chained off, not itself a prod-merge event)), checked in this
# order once a run's name has already matched deploy|release:
#   1. name contains "staging" (case-insensitive) -> staging_deploy, regardless of branch/event.
#   2. else name contains "cleanup" or "announce" (case-insensitive) -> deploy_release (release
#      housekeeping; a denylist, so a future housekeeping workflow named e.g. "*release*" that
#      isn't caught by either word falls through to rule 3/4 below instead — accepted tradeoff,
#      JP confirmed, no ticket needed for it).
#   3. else name matches deploy|release AND head_branch == "main" -> prod_deploy.
#   4. else name matches deploy|release AND head_branch == "staging" -> staging_deploy.
#   5. else (matches deploy|release, neither branch) -> deploy_release (unchanged fallback bucket).
# `head_branch` is already present on every run object the existing queued/in_progress run-list
# calls return (verified against the REST docs and live data before implementing) — zero new
# `gh api` calls.
_CIQ_CATEGORIZE_JQ='
  def ciq_categorize:
    if ((.actor.login // "") | ascii_downcase | contains("dependabot")) then "dependabot"
    elif ((.name // "") | ascii_downcase | (contains("deploy") or contains("release"))) then
      ((.name // "") | ascii_downcase) as $name
      | if ($name | contains("staging")) then "staging_deploy"
        elif ($name | (contains("cleanup") or contains("announce"))) then "deploy_release"
        elif (.head_branch // "") == "main" then "prod_deploy"
        elif (.head_branch // "") == "staging" then "staging_deploy"
        else "deploy_release" end
    elif (.event == "pull_request" or .event == "pull_request_target") then "pr"
    else "other" end;
'

# _ciq_categorize — reads one workflow_run JSON object on stdin, prints exactly one
# CI_QUEUE_CATEGORY_VOCAB key (see _CIQ_CATEGORIZE_JQ above for the cascade itself).
_ciq_categorize() {
  jq -r "$_CIQ_CATEGORIZE_JQ"'ciq_categorize'
}

# _ciq_collect_repo <repo> <online-busy-runner-count> <repo-scoped-busy-runner-count> — appends
# one {cat, queued_at} line per queued job to $WORK/$safe.queued-jobs.jsonl, one
# {runner_name, repo, run_id, pr_url} line per in_progress job with an assigned runner to
# $WORK/$safe.running-jobs.jsonl, and (#657) one {key, repo, run_id, pr_url, queued_at, title?}
# line per run in the FULL queued-run list (every `status=queued` run, not just the job-lookup-
# capped subset) to $WORK/$safe.queued-items.jsonl — ALL per-repo, not the shared
# $WORK/queued-jobs.jsonl / running-jobs.jsonl / queued-items.jsonl (#663 AC4: the caller only
# merges these into the shared files once this function returns 0, so a repo that fails PART WAY
# through this function's own run-lookup loop (queued jobs from its earlier, successful lookups
# already written) never leaks a partial count for a repo the caller is about to treat as entirely
# unavailable). Returns 1 on any API failure — aborting just THIS repo at the call site (#663 AC4;
# it used to abort the whole cycle). The 3rd arg (#658 round 4 — see item (e) below and
# collect_once) estimates how many of the 2nd arg's GLOBAL busy-runner count are plausibly in
# THIS repo (defaults to the 2nd arg itself when omitted); it drives ONLY the sticky cap, never
# `$r`'s reservation, which stays intentionally global.
#
# #645 review finding 1 (backlog undercount): two independent bias sources, both fixed here:
#   (a) GitHub's run-list endpoint always returns newest-first with no ascending-sort query param
#       (confirmed against the REST docs — no sort/direction param on "List workflow runs for a
#       repository"). If a repo's queued backlog exceeds one page, the genuinely oldest queued
#       run sits on the LAST page, never this one. Below, when the queued call's `total_count`
#       says there's a page beyond what we fetched, one bounded extra call fetches exactly that
#       last page — the oldest queued run is then always among what we hold, regardless of how
#       deep the backlog is (2 calls total, not proportional to backlog size).
#   (b) Merging queued + in_progress runs and picking which ones get a job lookup needs to protect
#       TWO different consumers of the SAME bounded budget (MAX_RUN_LOOKUPS_PER_REPO), not one:
#       `oldest` (queued-stats, #645) and `current_job` (busy-runner linking, #655/#658). A plain
#       "queued always wins" order (the original #645 fix) starves `current_job` instead: once a
#       repo's queued backlog alone reaches the cap, every in_progress run — including the one
#       holding a genuinely busy runner's job — is pushed out, 100% of the time, not intermittently
#       (#658's root cause). The selection below reserves `r = min(in_progress-run count, the
#       online+busy runner count passed in, cap - (1 if any queued run exists else 0))` of the cap
#       for the OLDEST `r` in_progress-source runs, guarantees at least 1 slot for queued whenever
#       any queued run exists (so `oldest` can never be starved to zero, preserving #645(b)), and
#       gives any unused budget on either side back to the other (oldest-id-first on both sides) —
#       so the TOTAL number of job lookups per repo is always exactly min(run count, cap), unchanged
#       from before (#658 AC2: no new `gh api` calls — this reallocates lookups, it never adds any).
#       `r` is capped by the actual busy-runner count (not just "is there an in_progress run") so a
#       repo with many in_progress runs but nobody currently busy doesn't needlessly starve `oldest`.
#   (c) #658 round 2 (PR #664 review finding): picking the OLDEST `r` in_progress runs every cycle
#       is itself a starvation trap whenever a repo has MORE in_progress runs than `r` — a newer
#       in_progress run holding a busy runner's job can simply never be among the oldest `r`, so
#       `current_job` for that runner stays null 100% of the time, not intermittently. There is no
#       zero-extra-call way to always resolve within a single cycle when in_progress runs outnumber
#       the reservation — that is a genuine hard bound. Instead, WHICH in_progress runs fill the
#       r/qsel/pextra slots (the total selected stays exactly as computed above — only the members
#       change) is now sticky-then-rotation, using $CI_QUEUE_IP_STATE_FILE's per-repo
#       {sticky: [run id...], cursor: run id} (read once per cycle, see main()):
#         1. Sticky: any run id in the PREVIOUS cycle's sticky set gets looked up again first, in
#            ascending-id order — so a run already known to be holding a busy runner's job never
#            gets rotated away and loses its link next cycle (no flicker).
#         2. Rotation: the remaining budget goes to in_progress runs NOT in the sticky set, in
#            ascending-id order starting just after the persisted cursor and wrapping back to the
#            smallest id after the largest — so across cycles, every in_progress run eventually
#            gets looked up.
#       The new cursor = the last rotation-selected id this cycle (unchanged if nothing was
#       selected from rotation, e.g. sticky alone filled the whole budget). The new sticky set is
#       NOT "whatever got looked up" — it is computed AFTER _ciq_runner_history, from exactly the
#       run ids that resolved into a BUSY runner's `current_job` this cycle (see
#       _ciq_update_ip_state). Using "any job with a runner_name" instead (the looser reading) is a
#       live starvation trap: an in_progress run sitting on an IDLE runner would go sticky and
#       permanently occupy the rotation budget, starving the one actually-busy run exactly like (c)
#       describes — proven by this ticket's "more in_progress runs than any fixed reservation"
#       test.
#   (d) #658 round 3 (PR #667 review finding): (c)'s sticky set, as built, had NO cap of its own —
#       `$pstickyall[0:$psel]` could take the ENTIRE selection budget whenever that many runs were
#       sticky. Once the sticky set reached $psel (e.g. the repo has $psel genuinely-busy runners
#       whose jobs keep running), $rembudget dropped to 0 and stayed there for as long as those
#       jobs kept running — an unresolved rotation candidate (a newer busy runner never yet
#       matched) could then be starved INDEFINITELY, not just for one cycle, breaking (c)'s stated
#       bound entirely (reproduced: 5 sticky runs filling a budget of 4 holds a 5th busy runner's
#       run unlinked across 8+ cycles). Round-3's first fix capped sticky to `$psel - 1` whenever
#       ANY rotation candidate existed, at all — but most rotation candidates are in_progress runs
#       that will never resolve to a busy link at all (held by runners that are, and stay, idle).
#       Evicting a resolved sticky link to make room for probing those is pure anti-flicker
#       regression with nothing to show for it (PR #667 review finding 2).
#   (e) #658 round 4 (PR #667 review finding 2): sticky is now capped ONLY when there is a REAL
#       competing busy runner to make room for — i.e. when this repo's own busy-runner count
#       (`$repo_busy`, see below) is more than the sticky set already accounts for
#       (`$pstickyall | length`, the sticky ids still present among this cycle's in_progress
#       runs). First shipped using the GLOBAL `$busy` (this cycle's online+busy runner count
#       across every repo) in place of `$repo_busy` — a code-review finding on this same PR (the
#       actual PR, not a round number) caught that a busy runner in a DIFFERENT repo then kept
#       this repo's cap permanently active (global count staying above this repo's own resolved-
#       link count forever, since that other repo's runner structurally can never appear in this
#       repo's own `$p`), flickering an already-resolved link that had no real competition at
#       all. `$repo_busy` (collect_once, passed as `_ciq_collect_repo`'s 3rd arg) fixes this: it
#       estimates, from the PREVIOUS cycle's own output, how many of this cycle's busy runners
#       are plausibly in THIS repo (resolved to this repo last cycle, OR not resolved to any
#       repo last cycle at all — conservatively counted toward every repo so a brand-new busy
#       runner can never be under-counted, only over-counted for the one cycle before it
#       resolves). `$busy` itself stays global and is used ONLY for `$r`'s reservation above,
#       unchanged from round 1. With `$repo_busy`, the cap condition being true forces
#       `$pstickyall < $pcount` (there is a rotation candidate) AND `$pstickyall < $repo_busy`,
#       so an already-resolved link can only be evicted once this repo's OWN resolved-link count
#       has genuinely fallen behind this repo's OWN estimated busy-runner count — the exact
#       round-3 multi-busy-runner-in-one-repo scenario this fix must not regress, and nothing
#       else. If a sticky run's own busy runner reassigns to a different job while this run stays
#       in_progress (stale sticky), `$pstickyall` is momentarily INFLATED (the stale id still
#       counts), which can withhold a rotation slot for one cycle that a genuinely new busy
#       runner could have used — it self-corrects the very next cycle, since the stale run gets
#       relooked up (it is still in `$pstickysel`), resolves to "not busy" and drops out of next
#       cycle's sticky set on its own (sticky is rebuilt from actual resolved links each cycle,
#       never from stale state). One cycle of delay in a rare edge case, never permanent
#       starvation — the same one-cycle-lag shape as `$repo_busy`'s own "not yet resolved
#       anywhere" conservative counting above.
#         | (if ($rotcandidates|length) > 0 and ($pstickyall|length) < $repo_busy
#            then $psel - 1 else $psel end) as $stickycap
#       GUARANTEE (state honestly, no stronger claim): in the steady state where every currently
#       busy runner in THIS repo already has a resolved sticky link (`$pstickyall >= $repo_busy`),
#       sticky is NEVER capped — already-resolved busy-runner links hold indefinitely, no flicker,
#       regardless of how busy any OTHER repo's runners are, and rotation may get 0 slots for as
#       long as that holds (round-3's "rotation >= 1 slot every cycle" claim no longer holds in
#       this state — that was the over-cap bug (d) above). Whenever a busy runner's link in THIS
#       repo is NOT yet resolved (`$pstickyall < $repo_busy`), rotation is guaranteed >= 1 slot
#       this cycle, so every specific in_progress run gets a lookup attempt at least once every
#       `in_progress_count` cycles in the worst case (round-robin via the cursor), matching (c)'s
#       original ceil(in_progress_count / r) bound whenever rotation's slot count exceeds 1. Once
#       a run resolves it stays sticky (no flicker) unless bumped to make room for a genuinely
#       competing, not-yet-resolved busy runner IN THIS REPO — never permanently starved either
#       way, and never flickered by a busy runner elsewhere.
# Residual risk (documented, not fixed): a queued job inside an old in_progress run that isn't
# reached before the cap runs out can still be missed — unchanged from before, and orthogonal to
# (a)/(b)/(c)/(d)/(e) above. Additionally (round 4): in the steady state where sticky already
# covers every currently busy runner in a repo, rotation can get ZERO slots in that repo
# indefinitely (see the GUARANTEE above) — a queued job inside a non-sticky in_progress run (one
# that was never, or is not yet, busy-linked) is then never reached for as long as that steady
# state holds, same as round-2's behavior before round 3 existed.
_ciq_collect_repo() {
  local repo=$1 busy=${2:-0} repo_busy=${3:-} safe qjson pjson n=0 run id cat jobsjson qtotal page qlast="" sticky_in cursor_in distinct_count
  safe=${repo//\//__}
  # 3rd arg defaults to $busy (not hardcoded 0) — a direct call with only 2 args (e.g. a stray
  # existing test/caller) falls back to the pre-round-4 global-busy behavior, never to 0 (0 would
  # wrongly force the cap permanently on for any repo with sticky entries at all).
  [ -n "$repo_busy" ] || repo_busy=$busy
  : > "$WORK/$safe.queued-jobs.jsonl"
  : > "$WORK/$safe.running-jobs.jsonl"
  : > "$WORK/$safe.queued-items.jsonl"
  echo 0 > "$WORK/$safe.truncated"

  # #658 round 2: read this repo's previous-cycle sticky/cursor state (defensively — a missing or
  # malformed entry/file degrades to "no sticky set, cursor 0", never aborts the cycle). A fallback
  # ip-cursor file is written NOW (before any early return below) so _ciq_update_ip_state always
  # has a value to read even for a repo with nothing queued/in-progress this cycle — the old cursor
  # carries forward unchanged rather than resetting to 0.
  sticky_in=$(jq -c --arg repo "$repo" '
    (.[$repo].sticky // []) as $s | if ($s | type) == "array" then [$s[] | select(type == "number")] else [] end
  ' "$WORK/ip-state-in.json" 2>/dev/null)
  [ -n "$sticky_in" ] || sticky_in='[]'
  cursor_in=$(jq -r --arg repo "$repo" '
    (.[$repo].cursor // 0) as $c | if ($c | type) == "number" then ($c | floor) else 0 end
  ' "$WORK/ip-state-in.json" 2>/dev/null)
  case "$cursor_in" in (''|*[!0-9]*) cursor_in=0 ;; esac
  jq -n --argjson c "$cursor_in" '{cursor: $c}' > "$WORK/ip-cursor-$safe.json" 2>/dev/null
  qjson=$(_ciq_call_shaped "repos/$repo/actions/runs?status=queued&per_page=$PER_PAGE" "runs-${safe}-queued.json" workflow_runs) || return 1
  pjson=$(_ciq_call_shaped "repos/$repo/actions/runs?status=in_progress&per_page=$PER_PAGE" "runs-${safe}-in_progress.json" workflow_runs) || return 1

  qtotal=$(printf '%s' "$qjson" | jq '(.total_count // (.workflow_runs | length))' 2>/dev/null)
  if [ -n "$qtotal" ] && [ "$qtotal" -gt "$PER_PAGE" ] 2>/dev/null; then
    page=$(( (qtotal + PER_PAGE - 1) / PER_PAGE ))
    qlast=$(_ciq_call_shaped "repos/$repo/actions/runs?status=queued&per_page=$PER_PAGE&page=$page" "runs-${safe}-queued-lastpage.json" workflow_runs) || return 1
  fi

  # #663 AC2: truncation detection, deliberately kept as its OWN small pass rather than folded
  # into the selection pipeline below — the selection pipeline always slices down to exactly the
  # cap (`[ "$n" -le "$MAX_RUN_LOOKUPS_PER_REPO" ] || break` below never actually fires), so
  # truncation can only be inferred from the PRE-selection distinct run count, computed here from
  # the same three raw sources (deduped by id, same as the selection pipeline does). `>`, not
  # `>=`: a repo with EXACTLY `MAX_RUN_LOOKUPS_PER_REPO` runs got every one of them looked up, so
  # it is not truncated.
  distinct_count=$(
    { printf '%s' "$qjson" | jq -c '.workflow_runs[]? | {id}' 2>/dev/null
      [ -z "$qlast" ] || printf '%s' "$qlast" | jq -c '.workflow_runs[]? | {id}' 2>/dev/null
      printf '%s' "$pjson" | jq -c '.workflow_runs[]? | {id}' 2>/dev/null
    } | jq -s 'group_by(.id) | length' 2>/dev/null
  )
  case "$distinct_count" in ''|*[!0-9]*) distinct_count=0 ;; esac
  if [ "$distinct_count" -gt "$MAX_RUN_LOOKUPS_PER_REPO" ]; then
    echo 1 > "$WORK/$safe.truncated"
  fi

  # #657: build this repo's contribution to ci_queue.categories[].queued[] from the FULL queued
  # run list (qjson + qlast, already fetched above for queued_total/`oldest` — zero new `gh api`
  # calls), NOT from the job-lookup-capped selection below. The job-lookup cap
  # (MAX_RUN_LOOKUPS_PER_REPO) exists to bound `gh api` calls, not to bound how much of the
  # backlog JP gets to see — building queued[] from that capped set would silently collapse to
  # ~1 item per repo whenever the runner fleet is busy (the #658 in_progress reservation above
  # leaves the queued side only 1-2 of the cap's 5 slots under load), which is exactly the deep-
  # backlog scenario this ticket exists for (verified: 4 busy runners + 4 in_progress runs + 20
  # queued runs in one repo left only 1 job-lookup slot for 20 queued runs under the old design).
  # A `status=queued` run needs no job lookup at all to know it's queued or how long: `created_at`
  # (fractional seconds stripped, same as queued-jobs.jsonl) IS its queued-since timestamp, and
  # `ciq_categorize`/`pull_requests[0]`/`display_title` are already on the run object. Dedup by
  # id WITHIN this repo (qjson/qlast could in principle overlap); a malformed id/created_at drops
  # just that one run, never the whole repo (same type-guard reasoning as queued-jobs.jsonl).
  # Code-review finding (#657 follow-up): `ciq_categorize` and the $title extraction below call
  # ascii_downcase/split on `.name`, `.actor.login`, `.head_branch` and `.display_title` — any ONE
  # of those being a non-string (e.g. a run object where `name` came back numeric) throws a jq
  # type error, which (same as a malformed id/created_at) aborts this whole `jq -s` invocation and
  # silently drops the ENTIRE repo's queued[] contribution via the suppressed `2>/dev/null`, not
  # just the one bad run. The guard below is widened to cover all four fields, not just id/
  # created_at: each must be absent/null or a string. `.actor` itself is checked for object-or-
  # null first so a non-object `actor` (e.g. `actor: 5`) never reaches `.actor.login` at all.
  { printf '%s' "$qjson" | jq -c '.workflow_runs[]?'
    [ -z "$qlast" ] || printf '%s' "$qlast" | jq -c '.workflow_runs[]?'
  } | jq -s -c --arg repo "$repo" "$_CIQ_CATEGORIZE_JQ"'
      map(select(
        (.id | type) == "number" and (.created_at | type) == "string"
        and ((.display_title | type) as $t | $t == "null" or $t == "string")
        and ((.name | type) as $t | $t == "null" or $t == "string")
        and ((.head_branch | type) as $t | $t == "null" or $t == "string")
        and ((.actor | type) as $t
             | $t == "null"
               or ($t == "object" and ((.actor.login | type) as $u | $u == "null" or $u == "string")))
      ))
      | group_by(.id) | map(.[0])
      | map(
          . as $run
          | ($run.pull_requests[0]) as $pr
          # split("\n")[0] on an empty string gives [] (not [""]), so .[0] on that is null, not
          # "" -- the trailing `// ""` catches that case (a missing/empty display_title) so
          # $title == "" really means "omit the key", never a surprise null downstream.
          | (($run.display_title // "") | (split("\n")[0] // "") | .[0:140]) as $title
          | {
              key: ($run | ciq_categorize),
              repo: $repo,
              run_id: $run.id,
              pr_url: (if $pr == null then null
                       elif ($pr.html_url // null) != null then $pr.html_url
                       elif ($pr.number // null) != null then ("https://github.com/" + $repo + "/pull/" + ($pr.number | tostring))
                       else null end),
              queued_at: ($run.created_at | sub("\\.[0-9]+Z$"; "Z"))
            }
            + (if $title == "" then {} else {title: $title} end)
        )
      | .[]
    ' >> "$WORK/$safe.queued-items.jsonl" 2>/dev/null

  { printf '%s' "$qjson" | jq -c '.workflow_runs[]? | . + {source:"queued"}' 2>/dev/null
    [ -z "$qlast" ] || printf '%s' "$qlast" | jq -c '.workflow_runs[]? | . + {source:"queued"}' 2>/dev/null
    printf '%s' "$pjson" | jq -c '.workflow_runs[]? | . + {source:"in_progress"}' 2>/dev/null
  } | jq -s -c --argjson cap "$MAX_RUN_LOOKUPS_PER_REPO" --argjson busy "$busy" --argjson repo_busy "$repo_busy" \
        --argjson sticky "$sticky_in" --argjson cursor "$cursor_in" '
      group_by(.id)
      | map(if any(.[]; .source == "queued") then (map(select(.source == "queued")) | .[0]) else .[0] end)
      | (map(select(.source == "queued")) | sort_by(.id)) as $q
      | (map(select(.source == "in_progress")) | sort_by(.id)) as $p
      | ($q | length) as $qcount
      | ($p | length) as $pcount
      | (if $qcount > 0 then 1 else 0 end) as $qreserve
      | ([$pcount, $busy, (($cap - $qreserve) as $x | if $x < 0 then 0 else $x end)] | min) as $r
      | ([$qcount, ($cap - $r)] | min) as $qsel
      | ([($pcount - $r), ($cap - $r - $qsel)] | min) as $pextra
      | ($r + (if $pextra < 0 then 0 else $pextra end)) as $psel
      # #658 round 2: sticky-then-rotation selection among $p (total size stays $psel, unchanged).
      | ($p | map(.id)) as $pids
      | ($p | map(select(.id as $i | $sticky | index($i) != null))) as $pstickyall
      | (($pids | map(select(. > $cursor)) | sort) + ($pids | map(select(. <= $cursor)) | sort)) as $rotorder
      | ($rotorder | map(select((. as $i | $sticky | index($i)) == null))) as $rotcandidates
      # #658 round 4 (PR #667 review finding 2 and PR #667 code-review MEDIUM — see the comment
      # block above _ciq_collect_repo, item (e)): sticky is capped to $psel - 1 ONLY when there
      # is a real competing busy runner IN THIS REPO to make room for, i.e. this repo own busy-
      # runner count ($repo_busy, NOT the global $busy used for $r above) exceeds what sticky
      # already accounts for ($pstickyall, the sticky ids still among this cycle in_progress
      # runs). A rotation candidate existing is NOT by itself a reason to cap — most rotation
      # candidates sit on runners that are, and stay, idle, and evicting a resolved sticky link
      # to probe those is pure anti-flicker regression with nothing to show for it.
      | (if ($rotcandidates | length) > 0 and ($pstickyall | length) < $repo_busy
         then (($psel - 1) as $x | if $x < 0 then 0 else $x end) else $psel end) as $stickycap
      | ($pstickyall[0:$stickycap]) as $pstickysel
      | (($psel - ($pstickysel | length)) as $x | if $x < 0 then 0 else $x end) as $rembudget
      | ($rotcandidates[0:$rembudget]) as $introtids
      | ($p | map(select(.id as $i | $introtids | index($i) != null))) as $introtsel
      | ($pstickysel + $introtsel) as $psellist
      | (if ($introtids | length) > 0 then $introtids[-1] else $cursor end) as $newcursor
      | { runs: ($q[0:$qsel] + $psellist | sort_by([(if .source == "queued" then 0 else 1 end), .id])),
          cursor: $newcursor }
    ' > "$WORK/$safe.sel.json" 2>/dev/null
  if [ -s "$WORK/$safe.sel.json" ]; then
    jq -c '.runs[]' "$WORK/$safe.sel.json" > "$WORK/$safe.runs.jsonl" 2>/dev/null
    jq -c '{cursor: .cursor}' "$WORK/$safe.sel.json" > "$WORK/ip-cursor-$safe.json" 2>/dev/null
  fi
  [ -s "$WORK/$safe.runs.jsonl" ] || return 0   # nothing queued/in-progress for this repo: not a failure

  while IFS= read -r run; do
    n=$((n + 1))
    [ "$n" -le "$MAX_RUN_LOOKUPS_PER_REPO" ] || break
    id=$(printf '%s' "$run" | jq -r '.id')
    cat=$(printf '%s' "$run" | _ciq_categorize)
    jobsjson=$(_ciq_call_shaped "repos/$repo/actions/runs/$id/jobs?filter=latest&per_page=100" "jobs-${id}.json" jobs) || return 1
    # #657 hardening: a garbled/non-string `created_at` on just one job must never take down
    # every OTHER (otherwise valid) queued job on this same run — `sub()` throws on a non-string,
    # which would fail this whole jq invocation (jq aborts on the first error) and silently drop
    # the lot via the suppressed `2>/dev/null`. The type guard below means a malformed job is
    # simply skipped, not catastrophic for its run-mates.
    printf '%s' "$jobsjson" | jq -c --arg cat "$cat" '
      .jobs[]? | select(.status=="queued" and (.created_at | type) == "string")
      | {cat: $cat, queued_at: (.created_at | sub("\\.[0-9]+Z$"; "Z"))}
    ' >> "$WORK/$safe.queued-jobs.jsonl" 2>/dev/null

    # #655 AC B: zero new API calls — $jobsjson is the SAME per-run job listing already fetched
    # above for the queued-jobs/categories[] extraction; this only pulls an extra field
    # (`runner_name`) out of jobs already in hand. `pr_url` is built from the run's own
    # `pull_requests[0]`, preferring `html_url` if GitHub ever returns one, else constructing
    # `https://github.com/<repo>/pull/<number>` from the validated `repo` + `number` — GitHub's
    # real `pull_requests[]` shape (verified live, see the PR description) carries `number`, not
    # `html_url`. Only an in_progress job (one actually assigned a runner) is ever a candidate;
    # the slot-level busy/race gating happens later in _ciq_runner_history, where the current
    # cycle's busy slots are known.
    printf '%s' "$run" | jq -c --arg repo "$repo" --argjson run_id "$id" '
      (.pull_requests[0]) as $pr
      | {
          repo: $repo,
          run_id: $run_id,
          pr_url: (if $pr == null then null
                   elif ($pr.html_url // null) != null then $pr.html_url
                   elif ($pr.number // null) != null then ("https://github.com/" + $repo + "/pull/" + ($pr.number | tostring))
                   else null end)
        }
    ' > "$WORK/run-${safe}-${id}.prctx.json" 2>/dev/null
    printf '%s' "$jobsjson" | jq -c --slurpfile ctx "$WORK/run-${safe}-${id}.prctx.json" '
      ($ctx[0]) as $ctx
      | .jobs[]? | select(.status=="in_progress" and ((.runner_name // "") != ""))
      | {runner_name: .runner_name, repo: $ctx.repo, run_id: $ctx.run_id, pr_url: $ctx.pr_url}
    ' >> "$WORK/$safe.running-jobs.jsonl" 2>/dev/null
  done < "$WORK/$safe.runs.jsonl"
  return 0
}

# _ciq_merge_runners <org-json> <repo-json> -> writes $WORK/runners-merged.json: one object per
# currently-known REGISTRATION (not yet deduped by slot — that's _ciq_runner_history's job),
# {id, name, status, busy, role, slot}, defensively defaulted (#648 AC2 negative case: a runner
# object missing `status`/`busy` in the API response is treated as offline/not-busy, never
# crashes the cycle), `role` derived from the GitHub labels GitHub itself returns (prod_deploy iff
# $PROD_DEPLOY_LABEL is among them, else general), and `slot` = `name` with its trailing
# `-[0-9]+` numeric suffix stripped (an empty/missing name falls back to `id-<id>` so two
# differently-nameless registrations never collide into the same slot).
_ciq_merge_runners() {
  printf '%s\n%s\n' "$1" "$2" | jq -s --arg label "$PROD_DEPLOY_LABEL" -c '
    [.[].runners[]?]
    | map(
        (.name // "") as $n
        | {
            id: (.id // -1),
            name: $n,
            status: (.status // "offline"),
            busy: (.busy == true),
            role: (if ([.labels[]?.name] | index($label)) then "prod_deploy" else "general" end),
            slot: (if $n == "" then ("id-" + ((.id // -1) | tostring))
                   elif ($n | test("-[0-9]+$")) then ($n | sub("-[0-9]+$"; ""))
                   else $n end)
          }
      )
  ' > "$WORK/runners-merged.json" 2>/dev/null
}

# _ciq_runner_history <merged-registrations-file> <running-jobs-file> — the #648 per-SLOT
# sample/prune/rollup step (#655 additionally: history_secs + current_job).
# <merged-registrations-file> is $WORK/runners-merged.json, one entry PER REGISTRATION (as written
# by _ciq_merge_runners) — this function's first job is collapsing that down to one entry per
# SLOT before anything is sampled, so a dead duplicate registration sharing a slot with a live one
# never gets its own sample line (which would dilute that slot's utilization, see corrected AC3).
# <running-jobs-file> is $WORK/running-jobs.jsonl, one line per in_progress job with an assigned
# runner (written by _ciq_collect_repo, zero new API calls — see that function's comment):
# {runner_name, repo, run_id, pr_url|null}.
#
# Writes $WORK/runners-out.json (the final `ci_queue.runners[]` array: identity from the CURRENT
# cycle for every currently-known slot, plus any slot that's dropped out of the API response
# entirely but still has a sample inside the trailing 72h — using its last-known identity — so it
# doesn't vanish the instant it's deregistered; it ages out only once that 72h window empties,
# AC6). Live slots sort before lingering ones (then by slot name) BEFORE the cap is applied — never
# sorted by id/age, which would evict the currently-live slots instead of the dead ones.
#
# #655 AC A: each slot's `history_secs` is `now - (oldest retained sample's ts)`, computed from
# $old (samples taken BEFORE this cycle's own append — same basis as the util_*_pct rollup below,
# so the span and the percentage it's vouching for are always measuring the same window) — 0 for a
# slot with zero prior samples (first-ever cycle), never null (a real, meaningful value — "just
# started" IS the honest answer render.js's "building" badge wants).
#
# #655 AC B: `current_job` is attached only to a slot whose CURRENT cycle registration is busy
# ($c.busy == true, the same $c this function already derives online/busy from — a slot that
# merely has a stale/race in_progress job referencing its name, but isn't itself busy this cycle,
# must never get a link, same as render.js's own busy-only gate). Matched by slot-prefix keying —
# a running job's `runner_name` is reduced to a slot with the exact same stripping regex
# _ciq_merge_runners uses — first match wins (job order mirrors $running_jobs' own append order:
# repo order, then run order, then job order). Omitted entirely (never `null`) when unmatched.
# Returns 1 on any failure (propagates as a normal collect_once failure: $OUT is left untouched,
# the existing 3-failures-before-Slack/Sentry path in main() fires exactly as it does for an API
# failure — same seam, no new alert path, per the Observability section).
_ciq_runner_history() {
  local merged=$1 running_jobs=$2 now keep old_pruned by_slot new_lines combined
  now=${CI_QUEUE_NOW:-$(date +%s)}
  keep=$(( WINDOW_72H_SECS + INTERVAL ))

  old_pruned="$WORK/samples-old-pruned.jsonl"
  if [ -e "$SAMPLES_FILE" ]; then
    jq -c --argjson now "$now" --argjson keep "$keep" \
      'select((.ts | type) == "number" and (($now - .ts) <= $keep))' \
      "$SAMPLES_FILE" > "$old_pruned" 2>/dev/null || return 1
  else
    : > "$old_pruned"
  fi

  # Collapse registrations to one entry per slot: online if ANY of this cycle's registrations in
  # the slot is online, busy if ANY ONLINE one is busy; id/name/role come from the slot's current
  # (highest-id == most recently (re-)registered) registration.
  by_slot="$WORK/runners-by-slot.json"
  jq -c '
    group_by(.slot)
    | map(
        (max_by(.id)) as $rep
        | {
            slot: .[0].slot,
            id: $rep.id,
            name: $rep.name,
            role: $rep.role,
            online: (any(.[]; .status == "online")),
            busy: (any(.[]; .status == "online" and .busy == true))
          }
      )
  ' "$merged" > "$by_slot" 2>/dev/null || return 1

  new_lines="$WORK/samples-new.jsonl"
  jq -c --argjson now "$now" '
    .[] | {ts: $now, slot, id, name, online, busy, role}
  ' "$by_slot" > "$new_lines" 2>/dev/null || return 1

  # #655: slot-ify each running job's runner_name with the exact same stripping regex
  # _ciq_merge_runners uses, so the join below keys on the identical notion of "slot".
  local jobs_by_slot="$WORK/running-jobs-by-slot.json"
  if [ -e "$running_jobs" ]; then
    jq -s -c '
      map(
        (.runner_name // "") as $n
        | . + { slot: (if $n == "" then "" elif ($n | test("-[0-9]+$")) then ($n | sub("-[0-9]+$"; "")) else $n end) }
      )
      | map(select(.slot != ""))
    ' "$running_jobs" > "$jobs_by_slot" 2>/dev/null || return 1
  else
    printf '[]' > "$jobs_by_slot"
  fi

  # Rollup is computed from $old (samples taken BEFORE this cycle's own append) — a slot seen
  # for the very first time this cycle has zero prior samples and reports null, not 0/100 (AC7).
  # history_secs (AC A) is derived from the same $old/$samples basis, so it never disagrees with
  # the percentage it's vouching for. current_job (AC B) is matched from $jobs, gated on $c.busy.
  jq -n --argjson now "$now" --argjson w24 "$WINDOW_24H_SECS" --argjson w72 "$WINDOW_72H_SECS" \
    --argjson max "$MAX_SAMPLE_RUNNERS" --slurpfile old "$old_pruned" --slurpfile cur "$by_slot" \
    --slurpfile jobsfile "$jobs_by_slot" '
    ($cur[0] // []) as $cur
    | ($jobsfile[0] // []) as $jobs
    | ($cur | map(.slot)) as $cur_slots
    | ($old | map(select(.ts >= ($now - $w72)) | .slot)) as $recent72_slots
    | ($cur_slots + $recent72_slots | unique) as $slots
    | [ $slots[] as $slot
        | ($old | map(select(.slot == $slot))) as $samples
        | ($samples | map(select(.ts >= ($now - $w24)))) as $s24
        | ($samples | map(select(.ts >= ($now - $w72)))) as $s72
        | ($cur | map(select(.slot == $slot)) | .[0]) as $c
        | (if $c != null then null else ($samples | sort_by(.ts) | if length > 0 then .[-1] else null end) end) as $last
        | (if $c != null and $c.busy then ($jobs | map(select(.slot == $slot)) | .[0]) else null end) as $job
        | {
            _live: ($c != null),
            _slot: $slot,
            id: (if $c != null then $c.id else ($last.id // -1) end),
            name: (if $c != null then $c.name else ($last.name // "") end),
            online: (if $c != null then $c.online else false end),
            busy: (if $c != null then $c.busy else false end),
            role: (if $c != null then $c.role else ($last.role // "general") end),
            util_24h_pct: (if ($s24 | length) == 0 then null
              else ((100 * ([$s24[] | select(.busy == true)] | length) / ($s24 | length)) | round) end),
            util_72h_pct: (if ($s72 | length) == 0 then null
              else ((100 * ([$s72[] | select(.busy == true)] | length) / ($s72 | length)) | round) end),
            history_secs: (if ($samples | length) == 0 then 0 else ($now - ($samples | map(.ts) | min)) end),
            current_job: (if $job == null then null
              else { repo: $job.repo, run_id: $job.run_id }
                   + (if ($job.pr_url // null) != null then { pr_url: $job.pr_url } else {} end)
              end)
          }
      ]
    | sort_by([(if ._live then 0 else 1 end), ._slot])
    | map(del(._live, ._slot))
    | map(if .current_job == null then del(.current_job) else . end)
    | {runners: .[0:$max], total_sampled: ($slots | length)}
  ' > "$WORK/runners-combined.json" 2>/dev/null || return 1

  # #663 AC5: runners-out.json stays a plain array (not the {runners, total_sampled} wrapper
  # above) — it's read elsewhere as a bare array (e.g. collect_once's `--slurpfile runners`
  # below), so the cap + pre-cap-count split happens here, once, rather than making every
  # consumer unwrap a wrapper object.
  jq -c '.runners' "$WORK/runners-combined.json" > "$WORK/runners-out.json" 2>/dev/null || return 1
  jq -r '.total_sampled' "$WORK/runners-combined.json" > "$WORK/runners-total-sampled.txt" 2>/dev/null || return 1

  combined="$WORK/samples-combined.jsonl"
  cat "$old_pruned" "$new_lines" > "$combined" 2>/dev/null || return 1
  _ciq_write_samples_atomic "$(cat "$combined" 2>/dev/null)"
}

# _ciq_update_ip_state — #658 round 2: persists the sticky/cursor state consumed by
# _ciq_collect_repo's selection (see that function's comment). Called ONLY from main(), ONLY after
# collect_once has already returned success (i.e. $OUT has already been committed) — a failure in
# here must never flip the cycle's success/fail state, so every step is best-effort and the
# caller ignores this function's return value.
#
# The new sticky set is read from $WORK/runners-out.json (already written by _ciq_runner_history
# by the time this runs): exactly the run ids that resolved into a BUSY runner's `current_job`
# THIS cycle, grouped by repo — NOT "every run id that was looked up" and NOT "every run id with a
# runner_name" (both of those are starvation traps, see the function comment above). The new
# cursor per repo comes from $WORK/ip-cursor-<safe>.json, written by _ciq_collect_repo for every
# repo it processed (including a same-as-before fallback for a repo with nothing to select this
# cycle, so a repo's rotation progress is never silently reset to 0).
#
# #663 AC4 interaction: a repo listed in $WORK/unavailable-repos.txt contributed NO running-jobs
# data this cycle (it was skipped, not collected), so $sticky_map has no real signal for it at
# all — writing {sticky: [], cursor: ...} here anyway would silently wipe an already-resolved
# busy-runner link (and reset its rotation cursor) purely because of a transient per-repo failure
# (e.g. an AC3 `gh api` timeout), defeating #658's whole anti-flicker guarantee for a failure mode
# that never existed before #663 (a single repo failing used to abort the entire cycle, leaving
# $IP_STATE_FILE untouched instead). An unavailable repo's entry is instead carried forward
# byte-for-byte from $WORK/ip-state-in.json (this cycle's OWN input, read once in main()) — same
# "untouched on failure" contract as the rest of this file, just scoped to one repo instead of the
# whole state file.
_ciq_update_ip_state() {
  local sticky_map repo safe cursor entries tmp
  sticky_map=$(jq -c '
    [ .[] | select(.busy == true and (.current_job // null) != null) | .current_job ]
    | group_by(.repo)
    | map({key: .[0].repo, value: (map(.run_id) | unique)})
    | from_entries
  ' "$WORK/runners-out.json" 2>/dev/null)
  [ -n "$sticky_map" ] || sticky_map='{}'

  entries='{}'
  while read -r repo; do
    safe=${repo//\//__}
    if grep -qxF "$repo" "$WORK/unavailable-repos.txt" 2>/dev/null; then
      entries=$(jq -c --arg repo "$repo" --slurpfile prev "$WORK/ip-state-in.json" '
        (($prev[0] // {})[$repo]) as $p
        | .[$repo] = (if ($p | type) == "object" then $p else {sticky: [], cursor: 0} end)
      ' <<< "$entries" 2>/dev/null)
      [ -n "$entries" ] || entries='{}'
      continue
    fi
    cursor=$(jq -r '.cursor // 0' "$WORK/ip-cursor-$safe.json" 2>/dev/null)
    case "$cursor" in (''|*[!0-9]*) cursor=0 ;; esac
    entries=$(jq -c --arg repo "$repo" --argjson cursor "$cursor" --argjson smap "$sticky_map" '
      .[$repo] = {sticky: ($smap[$repo] // []), cursor: $cursor}
    ' <<< "$entries" 2>/dev/null)
    [ -n "$entries" ] || entries='{}'
  done < <(repos)

  mkdir -p "$(dirname "$IP_STATE_FILE")" 2>/dev/null
  tmp=$(mktemp "$IP_STATE_FILE.XXXXXX" 2>/dev/null) || return 1
  printf '%s' "$entries" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$IP_STATE_FILE" || { rm -f "$tmp"; return 1; }
}

# collect_once — one full collection pass: runner counts/history + every repo's queued jobs, then
# the final ci_queue JSON written atomically to $OUT. Returns 1 (no write) on any failure.
#
# #663 AC4: a single configured repo's failure (renamed/archived/access lost) no longer aborts
# this whole pass — it's recorded in `unavailable_repos` and skipped; every OTHER repo's data is
# still collected and written. Only "every configured repo failed" still returns 1 here (same
# previous-snapshot-kept contract as any other failure) — a snapshot built from zero repos' worth
# of real data would itself violate the "never write a partial/zeroed snapshot" invariant this
# function exists to uphold; see the file header.
collect_once() {
  local org_json repo_json busy total offline as_of final repo safe
  local total_repos=0 failed_repos=0 any_truncated=0 truncated_bool unavailable_json total_sampled
  org_json=$(_ciq_call_shaped "orgs/$ORG/actions/runners?per_page=100" "runners-org.json" runners) || return 1
  repo_json=$(_ciq_call_shaped "repos/$SELF_REPO/actions/runners?per_page=100" "runners-repo.json" runners) || return 1
  _ciq_merge_runners "$org_json" "$repo_json" || return 1
  # #648: runners_busy/runners_total now count ONLINE runners only; runners_offline is new.
  busy=$(jq '[.[] | select(.status=="online" and .busy==true)] | length' "$WORK/runners-merged.json") || return 1
  total=$(jq '[.[] | select(.status=="online")] | length' "$WORK/runners-merged.json") || return 1
  offline=$(jq '[.[] | select(.status!="online")] | length' "$WORK/runners-merged.json") || return 1

  # #658 round 4 (PR #667 review finding — see _ciq_collect_repo's comment item (e)): `$busy`
  # above is a GLOBAL online+busy-runner count, shared by every repo, but the sticky cap needs a
  # PER-REPO figure — using the global count let a busy runner in repo B keep forcing repo A to
  # evict an already-resolved link forever, since A's own resolved-link count could never catch
  # up to a global count permanently inflated by a runner that will never appear in A's own
  # in_progress list. This cycle's runners-merged.json doesn't yet know which repo a busy
  # runner's job belongs to (that's only learned by the per-repo job lookups the loop below
  # makes), so this reads the PREVIOUS cycle's own output ($OUT — read here, before anything this
  # cycle overwrites it) for the last known repo of each currently-busy runner slot (matched by
  # name): a busy runner already resolved to repo R last cycle counts toward R's budget; a busy
  # runner NOT resolved to any repo last cycle (brand new, or still unresolved) is conservatively
  # counted toward EVERY repo's budget — it might turn out to belong to any of them, so this can
  # only ever over-count for one cycle per such runner (self-corrects once it resolves), never
  # under-count, so round 3's anti-starvation guarantee is unaffected. Zero new `gh api` calls:
  # $OUT is a local file this script already writes every cycle.
  local prev_runners_json busy_by_repo_json
  prev_runners_json=$( [ -r "$OUT" ] && jq -c '(.runners // []) | map(select(type=="object"))' "$OUT" 2>/dev/null )
  [ -n "$prev_runners_json" ] || prev_runners_json='[]'
  busy_by_repo_json=$(jq -c -n --slurpfile cur "$WORK/runners-merged.json" --argjson prev "$prev_runners_json" '
    (($cur[0] // []) | map(select(.status=="online" and .busy==true)) | map(.name)) as $busy_names
    | ($prev | map(select((.name // "") as $n | $busy_names | index($n) != null))
             | map(select((.current_job // null) != null))) as $resolved
    | ($resolved | group_by(.current_job.repo) | map({key: .[0].current_job.repo, value: length}) | from_entries) as $byrepo
    | (($byrepo | [.[]] | add) // 0) as $resolved_count
    | { byrepo: $byrepo, unresolved: (($busy_names | length) - $resolved_count) }
  ' 2>/dev/null)
  [ -n "$busy_by_repo_json" ] || busy_by_repo_json='{"byrepo":{},"unresolved":0}'

  [ -r "$REPOS_FILE" ] || return 1
  : > "$WORK/unavailable-repos.txt"
  while read -r repo; do
    local repo_busy
    total_repos=$((total_repos + 1))
    safe=${repo//\//__}
    repo_busy=$(jq -r --arg repo "$repo" '((.byrepo[$repo] // 0) + .unresolved)' <<< "$busy_by_repo_json" 2>/dev/null)
    case "$repo_busy" in (''|*[!0-9]*) repo_busy=0 ;; esac
    if _ciq_collect_repo "$repo" "$busy" "$repo_busy"; then
      cat "$WORK/$safe.queued-jobs.jsonl" >> "$WORK/queued-jobs.jsonl" 2>/dev/null
      cat "$WORK/$safe.running-jobs.jsonl" >> "$WORK/running-jobs.jsonl" 2>/dev/null
      cat "$WORK/$safe.queued-items.jsonl" >> "$WORK/queued-items.jsonl" 2>/dev/null
      [ "$(cat "$WORK/$safe.truncated" 2>/dev/null)" = "1" ] && any_truncated=1
    else
      failed_repos=$((failed_repos + 1))
      printf '%s\n' "$repo" >> "$WORK/unavailable-repos.txt"
      # Isolated/partial degradation, not a whole-cycle failure: reported to Sentry so it's
      # visible, but never counted against the consecutive-failures streak (main()'s $STATE_FILE)
      # — that streak means "the collector itself is failing", not "one repo is unreachable".
      sentry_report "ci-queue-collect: repo $repo unavailable this cycle (skipped, others still collected)"
    fi
  done < <(repos)
  if [ "$total_repos" -gt 0 ] && [ "$failed_repos" -eq "$total_repos" ]; then
    return 1
  fi
  unavailable_json=$(jq -R -s -c 'split("\n") | map(select(length > 0))' "$WORK/unavailable-repos.txt" 2>/dev/null)
  [ -n "$unavailable_json" ] || unavailable_json='[]'
  if [ "$any_truncated" = "1" ]; then truncated_bool=true; else truncated_bool=false; fi

  _ciq_runner_history "$WORK/runners-merged.json" "$WORK/running-jobs.jsonl" || return 1
  total_sampled=$(cat "$WORK/runners-total-sampled.txt" 2>/dev/null)
  case "$total_sampled" in ''|*[!0-9]*) total_sampled=0 ;; esac

  # #660: own cadence, own failure handling — never aborts this (much more frequent) queue cycle.
  local metrics_json health_value
  metrics_json=$(_ciq_collect_metrics)
  health_value=$(_ciq_compute_health "$busy" "$total" "$WORK/queued-jobs.jsonl" "$metrics_json")

  as_of=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  final=$(jq -n \
    --slurpfile jobs "$WORK/queued-jobs.jsonl" \
    --slurpfile items "$WORK/queued-items.jsonl" \
    --slurpfile runners "$WORK/runners-out.json" \
    --argjson busy "$busy" \
    --argjson total "$total" \
    --argjson offline "$offline" \
    --argjson truncated "$truncated_bool" \
    --argjson unavailable_repos "$unavailable_json" \
    --argjson runners_total_sampled "$total_sampled" \
    --argjson max_items "$MAX_CI_QUEUE_QUEUED_ITEMS" \
    --arg as_of "$as_of" \
    --argjson metrics "${metrics_json:-null}" \
    --arg health "$health_value" \
    '
    ($jobs) as $j
    # #657: dedup $items GLOBALLY by run id (first occurrence wins) BEFORE grouping into
    # categories — the scheduler/benjis-ops-tool repo alias in scripts/ci-metrics.repos can
    # otherwise surface the identical physical run twice, once per alias.
    | ($items | group_by(.run_id) | map(.[0])) as $items_dedup
    # prod_deploy/staging_deploy split out of the old single deploy_release bucket — this vocab
    # order must match status-page/src/vocab.js CI_QUEUE_CATEGORY_VOCAB exactly.
    | ["dependabot","prod_deploy","staging_deploy","deploy_release","pr","other"] as $vocab
    | ($vocab
        | map(. as $k
            # del(.key), not a {repo, run_id, pr_url, title, queued_at} reconstruction — that
            # object-literal shorthand would materialise title: null for every item with no
            # title key (the {title} shorthand in jq means title: .title, and indexing a missing
            # key is null), when the contract (validate.js sanitiseCiQueueQueuedItem) is to OMIT
            # title entirely when absent. del(.key) strips only the now-redundant key field (the
            # parent category entry already carries it) and leaves every other field, present or
            # absent, exactly as queued-items.jsonl wrote it.
            | ($items_dedup | map(select(.key == $k)) | sort_by([.queued_at, .run_id]) | .[0:$max_items]
                 | map(del(.key))) as $queued
            | {key: $k, count: ([$j[] | select(.cat == $k)] | length), queued: $queued})
        # a category with zero looked-up JOBS this cycle can still have queued[] entries (the
        # job-lookup cap and the per-repo run selection are independent knobs) — include the
        # category whenever EITHER signal is non-empty, never drop real queued[] data because
        # count happened to be 0.
        | map(select(.count > 0 or (.queued | length) > 0))) as $cats
    | ($j | sort_by(.queued_at) | .[0]) as $o
    | {as_of: $as_of,
       runners_busy: ([$busy, 999] | min),
       runners_total: ([$total, 999] | min),
       runners_offline: ([$offline, 999] | min),
       queued_total: ([($j | length), 999] | min),
       categories: $cats,
       oldest: (if $o == null then null else {key: $o.cat, queued_at: $o.queued_at} end),
       runners: ($runners[0] // []),
       truncated: $truncated,
       unavailable_repos: $unavailable_repos,
       runners_total_sampled: $runners_total_sampled}
      + (if $metrics != null then {ci_metrics: $metrics} else {} end)
      + {ci_health: $health}
    ') || return 1

  _ciq_write_atomic "$final"
}

# _ciq_write_atomic <json> — temp file in the same dir as $OUT, then `mv` (atomic rename).
_ciq_write_atomic() {
  local tmp
  mkdir -p "$(dirname "$OUT")" 2>/dev/null
  tmp=$(mktemp "$OUT.XXXXXX" 2>/dev/null) || return 1
  printf '%s' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$OUT" || { rm -f "$tmp"; return 1; }
}

# _ciq_write_samples_atomic <content> — same atomic temp-file-then-mv pattern as _ciq_write_atomic,
# targeting $SAMPLES_FILE instead of $OUT (kept as a separate function, not a shared helper, so
# the AC2 test's literal `mv -f "$tmp" "$OUT"` grep stays meaningful for $OUT specifically).
_ciq_write_samples_atomic() {
  local tmp
  mkdir -p "$(dirname "$SAMPLES_FILE")" 2>/dev/null
  tmp=$(mktemp "$SAMPLES_FILE.XXXXXX" 2>/dev/null) || return 1
  printf '%s' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$SAMPLES_FILE" || { rm -f "$tmp"; return 1; }
}

_ciq_age() {  # <file> -> age in seconds, or empty if the file doesn't exist
  [ -e "$1" ] || return 0
  python3 -c "import os,sys,time
try: print(int(time.time() - os.path.getmtime(sys.argv[1])))
except OSError: pass" "$1" 2>/dev/null
}

# ---- #660: live duration/health metrics -------------------------------------------------------
# A second data pull, decoupled from the queue-depth cadence above: its own throttle (own
# attempt/output files, _ciq_metrics_due), its own fail-streak counter/Sentry/Slack path
# (_ciq_metrics_read_fails/_ciq_metrics_write_fails — never shares $STATE_FILE with the queue
# cycle: a queue success between two metrics failures must never reset the metrics streak, and
# vice versa), computed PURELY from the current cycle's single `status=completed&per_page=N`
# pull per repo (no persistent accumulation across cycles — the "capped history window" the issue
# asks for is just that one page, GitHub's own max of 100). On ANY failure (shaped-call failure,
# or a matched run missing run_started_at/updated_at — "a missing timestamp field", same
# malformed-response contract as the rest of the collector), the PREVIOUS $METRICS_OUT is left
# byte-for-byte untouched and this failure never aborts collect_once: the much more frequent queue
# cycle keeps refreshing busy/total/categories/runners on its own cadence regardless of whether
# the metrics endpoint is currently healthy.

# _ciq_metrics_due — true (0) iff neither $METRICS_OUT nor $METRICS_ATTEMPT_FILE was touched more
# recently than $CI_QUEUE_METRICS_INTERVAL_SECS ago (same dual-file pattern as _ciq_throttled,
# just inverted: this answers "is it time to try again", not "back off"). Neither file existing
# yet (cold start) is always due.
_ciq_metrics_due() {
  local age_out age_attempt min_age=""
  age_out=$(_ciq_age "$METRICS_OUT")
  age_attempt=$(_ciq_age "$METRICS_ATTEMPT_FILE")
  local a
  for a in "$age_out" "$age_attempt"; do
    [ -n "$a" ] || continue
    if [ -z "$min_age" ] || [ "$a" -lt "$min_age" ]; then min_age=$a; fi
  done
  [ -z "$min_age" ] && return 0
  [ "$min_age" -ge "$CI_QUEUE_METRICS_INTERVAL_SECS" ]
}

# _ciq_metrics_should_run — gate: disabled entirely unless CI_QUEUE_METRICS_ENABLED=1; once
# enabled, CI_QUEUE_METRICS_FORCE=1 bypasses this cycle's own throttle (test seam, mirrors
# CI_QUEUE_FORCE for the queue cycle — kept as a SEPARATE var so a test can force the queue cycle
# without also forcing metrics, and vice versa, to exercise the two independent throttles).
_ciq_metrics_should_run() {
  [ "${CI_QUEUE_METRICS_ENABLED:-0}" = "1" ] || return 1
  [ "${CI_QUEUE_METRICS_FORCE:-0}" = "1" ] && return 0
  _ciq_metrics_due
}

_ciq_metrics_read_fails() {
  [ -e "$METRICS_STATE_FILE" ] || { echo 0; return; }
  python3 -c "
import json
try:
    print(int(json.load(open('$METRICS_STATE_FILE')).get('fails', 0)))
except Exception:
    print(0)
" 2>/dev/null
}

_ciq_metrics_write_fails() {  # <n>
  mkdir -p "$(dirname "$METRICS_STATE_FILE")" 2>/dev/null
  python3 -c "import json; json.dump({'fails': $1}, open('$METRICS_STATE_FILE', 'w'))" 2>/dev/null
}

# _ciq_write_metrics_atomic <json> — same atomic temp-file-then-mv pattern as _ciq_write_atomic/
# _ciq_write_samples_atomic, targeting $METRICS_OUT (kept separate for the same grep-ability
# reason the samples writer is kept separate).
_ciq_write_metrics_atomic() {
  local tmp
  mkdir -p "$(dirname "$METRICS_OUT")" 2>/dev/null
  tmp=$(mktemp "$METRICS_OUT.XXXXXX" 2>/dev/null) || return 1
  printf '%s' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$METRICS_OUT" || { rm -f "$tmp"; return 1; }
}

# _CIQ_METRICS_CATEGORY_JQ — the jq fragment (inlined into _ciq_collect_metrics_once's single jq
# program per repo) that buckets one completed workflow_run into exactly one of the 4
# issue #660 categories, or "" (excluded — never silently mis-bucketed). Keyed on the run's OWN
# `.repository.full_name` (GitHub's real list-runs response includes this on every run object,
# verified live against Benjis-Plants/scheduler — see the PR description), NOT the API path used
# to fetch it: scheduler and benjis-ops-tool are the same physical repo (confirmed live, identical
# repo `id`), and GitHub itself resolves `.repository.full_name` to the canonical
# "Benjis-Plants/benjis-ops-tool" regardless of which alias path was queried — so categorizing on
# this field is what makes the cross-alias dedup below correct without any explicit alias map.
#
# Precedence (deliberate, not arbitrary): a pull_request(_target)-triggered run in one of the two
# tracked product repos is ALWAYS that repo's "PR CI" bucket, even if its workflow happens to be
# named "deploy" or "release" something — a PR-triggered run is never actually a deploy. Only once
# that's ruled out does a deploy/release-named run get bucketed by `head_branch` into
# prod_deploy/staging_deploy. This is a NEW categorization, separate from _ciq_categorize's
# existing dependabot/deploy_release/pr/other vocab (#643/#657 own that one) — #660 only adds one,
# never touches the other.
_CIQ_METRICS_CATEGORY_JQ='
  ((.repository.full_name) // "") as $mrepo
  | ((.name // "") | ascii_downcase) as $mname
  | (if $mrepo == "Benjis-Plants/benjis-sales-tool" then "sales_tool"
     elif $mrepo == "Benjis-Plants/benjis-ops-tool" then "ops_tool"
     else "" end) as $mproduct
  | (if $mproduct == "" then ""
     elif (.event == "pull_request" or .event == "pull_request_target") then
       (if $mproduct == "sales_tool" then "sales_tool_pr" else "ops_tool_pr" end)
     elif (($mname | contains("deploy")) or ($mname | contains("release"))) and .head_branch == "main" then "prod_deploy"
     elif (($mname | contains("deploy")) or ($mname | contains("release"))) and .head_branch == "staging" then "staging_deploy"
     else "" end)
'

# _ciq_collect_metrics_once — exactly 1 `status=completed` list call per tracked repo (AC), dedup
# by run `id` (the scheduler/benjis-ops-tool alias returns the SAME run from both API paths),
# categorize, validate required timestamps, compute avg/p50/p90 duration (seconds) + today's
# pass/fail rate per category, write atomically to $METRICS_OUT. Returns 1 (no write) on any
# failure — a malformed response OR a matched run missing run_started_at/updated_at.
_ciq_collect_metrics_once() {
  local repo cjson now today
  : > "$WORK/metrics-runs.jsonl"
  while read -r repo; do
    cjson=$(_ciq_call_shaped "repos/$repo/actions/runs?status=completed&per_page=$CI_QUEUE_METRICS_PER_PAGE" "runs-${repo//\//__}-completed.json" workflow_runs) || return 1
    printf '%s' "$cjson" | jq -c '
      .workflow_runs[]?
      | '"$_CIQ_METRICS_CATEGORY_JQ"' as $mcat
      | select($mcat != "")
      | {id, cat: $mcat, conclusion, run_started_at, updated_at}
    ' >> "$WORK/metrics-runs.jsonl" 2>/dev/null
  done < <(repos)

  now=${CI_QUEUE_NOW:-$(date +%s)}
  today=$(python3 -c "
import datetime,sys
print(datetime.datetime.fromtimestamp(int(sys.argv[1]), tz=datetime.timezone.utc).strftime('%Y-%m-%d'))
" "$now" 2>/dev/null) || return 1
  [ -n "$today" ] || return 1

  # Dedup by id first (group_by(.id) | map(.[0]) — same idiom _ciq_collect_repo uses), THEN
  # validate timestamps and compute duration/today-ness. A matched run with a null/missing
  # run_started_at or updated_at marks the whole batch `_bad` (checked right after, below) —
  # treated the SAME as a malformed response (Observability section): abort, no partial write.
  # _dur is clamped to [0, MAX_CI_METRICS_DURATION_SECS] — never negative (a bad clock on either
  # timestamp), and never above the cap validate.js enforces on avg/p50/p90: an unclamped outlier
  # (e.g. a deploy stuck for days on a manual environment-approval gate) would otherwise push a
  # whole category's avg/p50/p90 past that cap and validate.js would drop the ENTIRE ci_metrics
  # object over one pathological run — clamping here keeps the category present with an honest
  # "at least this long" duration instead.
  jq -s -c --arg today "$today" --argjson maxdur "$MAX_CI_METRICS_DURATION_SECS" '
    group_by(.id) | map(.[0])
    | map(
        if (.run_started_at == null or .updated_at == null) then {_bad: true}
        else
          ((.updated_at | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)
           - (.run_started_at | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) as $raw_dur
          | . + {
              _dur: ([[0, $raw_dur] | max, $maxdur] | min),
              _today: ((.updated_at | sub("\\.[0-9]+Z$"; "Z") | .[0:10]) == $today)
            }
        end
      )
  ' "$WORK/metrics-runs.jsonl" > "$WORK/metrics-runs-dedup.json" 2>/dev/null || return 1

  jq -e 'any(.[]; ._bad == true)' "$WORK/metrics-runs-dedup.json" >/dev/null 2>&1 && return 1

  # Eligibility (PR #713 review, MEDIUM — made the SAME run-status filter drive both duration AND
  # pass/fail rate, so the two halves of the metric never disagree): excludes null
  # (never-concluded/in-progress-looking, per the issue's own fixture) AND GitHub's "didn't really
  # run to a pass/fail verdict" conclusions — cancelled (a PR-concurrency-group supersede is
  # routine, not a CI failure), skipped (a path filter decided not to run it), neutral, and stale.
  # Verified live against benjis-ops-tool/benjis-sales-tool completed runs before writing this:
  # `cancelled`/`skipped` are common real conclusion VALUES (strings, never null) — treating only
  # literal `null` as "not a failure" would have left these dragging the rate down as failures,
  # contrary to the issue's intent. A run this excludes also finished in seconds (a supersede or a
  # skip), so counting it toward duration would drag avg/p50/p90 down too — this is applied BEFORE
  # `group_by(.cat)`, not just to the `_today` pass-rate subset, so a category whose runs are ALL
  # cancelled/skipped is simply absent from $durable (never appears in group_by's output), the
  # same "zero eligible runs -> category omitted" shape as zero completed runs, with no explicit
  # empty-check needed. Everything else not excluded (success, failure, timed_out,
  # action_required, startup_failure) counts; `success` is the only pass. `elig` is a single `def`
  # (not inlined separately per callsite) so duration, the per-category rate and the overall rate
  # can never drift apart again. `.conclusion as $c | ...` (not `$excluded | index(.conclusion)`
  # piped straight off `$excluded`) — jq's `|` rebinds the input to `$excluded` itself, so
  # `.conclusion` on the next line would index the ARRAY, not the run; binding it to a variable
  # first is required, not stylistic.
  #
  # The top-level `pass_rate_pct`/`pass_rate_n` (the issue's "today's OVERALL pass/fail rate",
  # distinct from each category's own) are computed from the SAME eligible-run definition across
  # ALL categories at once (categories are disjoint, so this is not a re-aggregation of the
  # per-category rates — a category-count-weighted average of already-computed rates would double
  # count nothing today against nine successes from a prior day sitting in the same 100-run page).
  #
  # Duration itself is a ROLLING window (every fetched completed run, not just today's), so $durable
  # is never further filtered by `._today` — only the pass-rate legs (`$overall_eligible`/
  # `$eligible` below) add that restriction on top of `elig`.
  local metrics_json
  metrics_json=$(jq -c --arg as_of "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def elig: (.conclusion as $c | $c != null and ((["cancelled", "skipped", "neutral", "stale"] | index($c)) == null));
    (map(select(._bad != true))) as $all
    | ($all | map(select(elig))) as $durable
    | ($durable | map(select(._today))) as $overall_eligible
    | ($overall_eligible | length) as $overall_n
    | (if $overall_n == 0 then null
       else (100 * ([$overall_eligible[] | select(.conclusion == "success")] | length) / $overall_n | round) end) as $overall_pr
    | ($durable
       | group_by(.cat)
       | map(
          (sort_by(._dur) | map(._dur)) as $durs
          | ($durs | length) as $n
          | (($durs | add) / $n | round) as $avg
          | ($durs[([(($n * 50 / 100) | ceil), 1] | max) - 1]) as $p50
          | ($durs[([(($n * 90 / 100) | ceil), 1] | max) - 1]) as $p90
          | (map(select(._today))) as $eligible
          | ($eligible | length) as $ecount
          | (if $ecount == 0 then null
             else (100 * ([$eligible[] | select(.conclusion == "success")] | length) / $ecount | round) end) as $pr
          | {key: .[0].cat, n: $n, avg_secs: $avg, p50_secs: $p50, p90_secs: $p90, pass_rate_pct: $pr}
         )
       | sort_by(.key)) as $categories
    | {as_of: $as_of, categories: $categories, pass_rate_pct: $overall_pr, pass_rate_n: $overall_n}
  ' "$WORK/metrics-runs-dedup.json") || return 1

  _ciq_write_metrics_atomic "$metrics_json"
}

# _ciq_collect_metrics — never fails/propagates (collect_once always proceeds to write $OUT
# regardless of this cycle's metrics outcome): runs _ciq_collect_metrics_once when due, tracks its
# own independent fail streak (Sentry on every failure, Slack once a streak of 3 is reached —
# same thresholds/paths as the queue cycle's own observability, deliberately not shared storage),
# then prints whatever is CURRENTLY cached in $METRICS_OUT (freshly written this cycle, carried
# forward from an earlier success, or the literal string "null" if metrics have never once
# succeeded) — the caller merges this straight into the final payload.
_ciq_collect_metrics() {
  # Disabled entirely: never touch $METRICS_OUT, not even to read it — a host that turns the
  # feature OFF (or never turns it on) must never surface a frozen/stale snapshot, and a test that
  # never overrides CI_QUEUE_METRICS_OUT must never read the real host's pipeline state.
  if [ "${CI_QUEUE_METRICS_ENABLED:-0}" != "1" ]; then printf 'null'; return; fi
  if _ciq_metrics_should_run; then
    touch "$METRICS_ATTEMPT_FILE" 2>/dev/null || true
    if _ciq_collect_metrics_once; then
      _ciq_metrics_write_fails 0
    else
      local f
      f=$(( $(_ciq_metrics_read_fails) + 1 ))
      _ciq_metrics_write_fails "$f"
      sentry_report "ci-queue-collect: metrics cycle failed (fails=$f)"
      [ "$f" -eq 3 ] && slack_post "CI queue collector: metrics fetch failing, $f consecutive cycles [env=$ENVIRONMENT release=$RELEASE]"
    fi
  fi
  if [ -r "$METRICS_OUT" ]; then cat "$METRICS_OUT"; else printf 'null'; fi
}

# _ciq_compute_health <busy> <total> <queued-jobs-file> <metrics-json-or-"null"> -> one of
# ok|degraded|down (#660's `ci_health`, a derived heuristic from signals already collected live —
# explicitly NOT comprehensive incident detection, per the issue). Computed every cycle regardless
# of whether metrics itself is enabled/due this cycle: the runner/queue-age signals below come
# from data collect_once already has in hand; only the pass-rate leg needs $metrics, and simply
# never fires when there's no metrics data yet (never treated as "wrong" by its absence).
#
# PR #713 review (MEDIUM): this function cannot see the collector's own process health — it only
# ever runs AS PART OF a cycle that is already succeeding (collect_once calls it right before
# writing $OUT, same cycle). Two honesty gaps that follow from that, and how each is covered:
#   (a) cold start — metrics enabled but $METRICS_OUT has never once been written, so the mtime
#       check below never fires and health silently read "ok" forever even if every metrics
#       attempt has been failing since the feature was turned on. Fixed below: the existing
#       consecutive-failure streak (_ciq_metrics_read_fails, already tracked for Sentry/Slack) is
#       also checked against CI_QUEUE_DOWN_STALE_CYCLES, which is current by the time this runs
#       (_ciq_collect_metrics always runs first in collect_once) and needs no prior snapshot to
#       exist.
#   (b) collector death — if collect_once itself stops completing (an earlier step keeps failing,
#       or the invoking cron/launchd job stops firing), this function is never called again and
#       NOTHING in $OUT, including its frozen `ci_health`, can self-report that staleness — a
#       dead process cannot update the one field that would say so. This is deliberately NOT
#       solved here: it is already solved one layer up, consumer-side, by
#       skills/orchestrate/report-status.sh's `_rs_ci_queue_json` (STATUS_CI_STALE_SECS, 20 min
#       default), which drops the ENTIRE `ci_queue` key (not just `ci_health`) once `status-ci.json`
#       itself goes stale — a stronger, more honest signal than a stale embedded `ci_health: ok`
#       would ever be, from the one place that's actually still running to notice.
_ciq_compute_health() {
  local busy=$1 total=$2 qfile=$3 metrics=$4 now

  if [ "$total" -le 0 ] 2>/dev/null; then echo down; return; fi

  # down (b): metrics have been persistently failing to refresh for CI_QUEUE_DOWN_STALE_CYCLES of
  # their own CI_QUEUE_METRICS_INTERVAL_SECS cadence. Covers both a stale-but-existing snapshot
  # (mtime check, needs a prior snapshot) AND a cold start that has never once succeeded (fails
  # streak, needs no prior snapshot) — either path alone must never false-alarm on its own: a
  # brand-new enable with zero attempts yet (mtime absent, fails streak 0) stays "ok" until one of
  # the two actually crosses the threshold.
  if [ "${CI_QUEUE_METRICS_ENABLED:-0}" = "1" ]; then
    if [ -e "$METRICS_OUT" ]; then
      local mage
      mage=$(_ciq_age "$METRICS_OUT")
      if [ -n "$mage" ] && [ "$mage" -gt $(( CI_QUEUE_DOWN_STALE_CYCLES * CI_QUEUE_METRICS_INTERVAL_SECS )) ] 2>/dev/null; then
        echo down; return
      fi
    else
      local mfails
      mfails=$(_ciq_metrics_read_fails)
      if [ -n "$mfails" ] && [ "$mfails" -ge "$CI_QUEUE_DOWN_STALE_CYCLES" ] 2>/dev/null; then
        echo down; return
      fi
    fi
  fi

  now=${CI_QUEUE_NOW:-$(date +%s)}

  # degraded (a): the oldest queued job has been waiting past the threshold while nobody is busy
  # (a genuinely stuck queue, not just a momentary blip) — reuses the SAME queued-jobs file the
  # main `oldest` field is built from, zero new data collection. Known limit (PR #713 review, LOW):
  # this only fires when `$busy` (ONLINE runners busy, across the whole org) is zero, so a job
  # stuck behind a busy GENERAL runner while a category-specific runner sits idle is never flagged
  # this way — acceptable for a heuristic, not comprehensive incident detection (per the issue).
  if [ "$busy" -le 0 ] 2>/dev/null && [ -s "$qfile" ]; then
    local oldest_at age2
    oldest_at=$(jq -rs 'sort_by(.queued_at) | .[0].queued_at // empty' "$qfile" 2>/dev/null)
    if [ -n "$oldest_at" ]; then
      age2=$(python3 -c "
import datetime, sys
try:
    t = datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    print(int(sys.argv[2]) - int(t.timestamp()))
except Exception:
    pass
" "$oldest_at" "$now" 2>/dev/null)
      if [ -n "$age2" ] && [ "$age2" -gt "$CI_QUEUE_DEGRADED_QUEUE_AGE_SECS" ] 2>/dev/null; then
        echo degraded; return
      fi
    fi
  fi

  # degraded (b): today's OVERALL pass rate (ci_metrics.pass_rate_pct/pass_rate_n — computed
  # directly from today's eligible runs across ALL categories at once, NOT a weighted average of
  # the already-computed per-category rates: .n on a category counts every run in the fetched
  # page regardless of day/conclusion, so weighting by it would let a stale prior-day run outweigh
  # a real same-day failure) has dropped below the threshold. Gated on
  # CI_QUEUE_DEGRADED_MIN_SAMPLES so one isolated failure right after the UTC day rollover (evening
  # in most of JP's timezones) doesn't read "degraded" off a sample size of one.
  if [ "$metrics" != "null" ] && [ -n "$metrics" ]; then
    local agg n
    agg=$(printf '%s' "$metrics" | jq -r '.pass_rate_pct // "null"' 2>/dev/null)
    n=$(printf '%s' "$metrics" | jq -r '.pass_rate_n // 0' 2>/dev/null)
    if [ -n "$agg" ] && [ "$agg" != "null" ] && [ -n "$n" ] && [ "$n" -ge "$CI_QUEUE_DEGRADED_MIN_SAMPLES" ] 2>/dev/null \
      && [ "$agg" -lt "$CI_QUEUE_DEGRADED_PASS_RATE_PCT" ] 2>/dev/null; then
      echo degraded; return
    fi
  fi

  echo ok
}

# _ciq_throttled — true (0) iff either $OUT or $ATTEMPT_FILE was touched more recently than
# $INTERVAL ago. Checking both (not just $OUT, per AC2) means a failing streak backs off at the
# same cadence instead of retrying on every single invocation (#637) — $OUT's own mtime alone
# never advances while every attempt fails.
_ciq_throttled() {
  local age_out age_attempt min_age=""
  age_out=$(_ciq_age "$OUT")
  age_attempt=$(_ciq_age "$ATTEMPT_FILE")
  local a
  for a in "$age_out" "$age_attempt"; do
    [ -n "$a" ] || continue
    if [ -z "$min_age" ] || [ "$a" -lt "$min_age" ]; then min_age=$a; fi
  done
  [ -n "$min_age" ] && [ "$min_age" -lt "$INTERVAL" ]
}

_ciq_read_fails() {
  [ -e "$STATE_FILE" ] || { echo 0; return; }
  python3 -c "
import json
try:
    print(int(json.load(open('$STATE_FILE')).get('fails', 0)))
except Exception:
    print(0)
" 2>/dev/null
}

_ciq_write_fails() {  # <n>
  mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
  python3 -c "import json; json.dump({'fails': $1}, open('$STATE_FILE', 'w'))" 2>/dev/null
}

# ---- observability (adapted from scripts/ci-metrics.sh's sentry_report/redact; not shared —
# ci-report.sh doesn't share one with ci-metrics.sh either) ------------------------------------
redact() {  # stdin -> stdout, with GH_TOKEN / SLACK_WEBHOOK_URL values stripped
  local s; s=$(cat)
  [ -z "${GH_TOKEN:-}" ] || s=${s//"$GH_TOKEN"/***}
  [ -z "${SLACK_WEBHOOK_URL:-}" ] || s=${s//"$SLACK_WEBHOOK_URL"/***}
  printf '%s' "$s"
}

sentry_report() {  # <message> — every failure, isolated or part of a streak (never Slack-gated)
  local dsn=${SENTRY_DSN:-} body id msg
  [[ $dsn =~ ^(https?)://([^@:/]+)@([^/]+)/([0-9]+)/?$ ]] || return 0
  msg=$(printf '%s' "$1" | redact)
  id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  body=$(jq -cn --arg m "$msg" --arg r "$RELEASE" --arg e "$ENVIRONMENT" --arg route "ci-queue/collect" --arg id "$id" \
    '{event_id:$id,message:$m,level:"error",platform:"other",release:$r,environment:$e,tags:{route:$route}}')
  curl -sS --max-time 10 -o /dev/null -X POST "${BASH_REMATCH[1]}://${BASH_REMATCH[3]}/api/${BASH_REMATCH[4]}/store/" \
    -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=${BASH_REMATCH[2]}, sentry_client=ci-queue-collect/1" \
    -H "Content-Type: application/json" --data "$body" >/dev/null 2>&1 || true
}

slack_post() {  # <text> — only on a failure streak (gated by the caller), never per-tick
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 1
  curl -sS --max-time 10 -o /dev/null -X POST -H 'Content-type: application/json' \
    --data "$(jq -cn --arg t "$1" '{text:$t}')" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
}

main() {
  mkdir -p "$PIPE" 2>/dev/null || true
  if [ "${CI_QUEUE_FORCE:-0}" != "1" ] && _ciq_throttled; then exit 0; fi

  # mkdir-based lock, same stale-reclaim pattern as report-status.sh's own LOCKDIR: report-status.sh
  # fires this in the background on every beat event (several per minute across concurrent
  # orchestrator runs), so without a lock two near-simultaneous invocations can both pass the
  # throttle check before either touches $ATTEMPT_FILE and double the real API calls against the
  # shared budget this script exists to protect (#637).
  LOCKDIR=${CI_QUEUE_LOCKDIR:-$PIPE/ci-queue-collect.lockdir}
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    local lock_age
    lock_age=$(_ciq_age "$LOCKDIR")
    if [ -n "$lock_age" ] && [ "$lock_age" -gt 60 ] 2>/dev/null && rmdir "$LOCKDIR" 2>/dev/null && mkdir "$LOCKDIR" 2>/dev/null; then
      :  # stale lock reclaimed
    else
      exit 0
    fi
  fi
  touch "$ATTEMPT_FILE" 2>/dev/null || true

  WORK=$(mktemp -d) || { rmdir "$LOCKDIR" 2>/dev/null; exit 0; }
  trap 'rm -rf "$WORK"; rmdir "$LOCKDIR" 2>/dev/null' EXIT
  : > "$WORK/queued-jobs.jsonl"
  : > "$WORK/running-jobs.jsonl"
  : > "$WORK/queued-items.jsonl"
  : > "$WORK/calls.count"
  : > "$WORK/gh-stderr.log"   # #663 AC6: accumulates every _ciq_gh_api call's stderr this cycle

  # #658 round 2: read once per cycle, defensively — a missing/corrupt/non-object file degrades to
  # "no sticky set, cursor 0" for every repo (never aborts the cycle).
  if [ -e "$IP_STATE_FILE" ] && jq -e 'type == "object"' "$IP_STATE_FILE" >/dev/null 2>&1; then
    cp "$IP_STATE_FILE" "$WORK/ip-state-in.json" 2>/dev/null || echo '{}' > "$WORK/ip-state-in.json"
  else
    echo '{}' > "$WORK/ip-state-in.json"
  fi

  if collect_once; then
    _ciq_write_fails 0
    _ciq_update_ip_state || true
  else
    local fails gh_err
    fails=$(( $(_ciq_read_fails) + 1 ))
    _ciq_write_fails "$fails"
    # #663 AC6: the last non-empty line of this cycle's `gh` stderr (redacted — see `redact`),
    # appended to both the Sentry event and the Slack alert so a failure streak is diagnosable
    # without needing to reproduce it. "" (omitted from the message) when gh was never actually
    # invoked this cycle (e.g. a fixture-based test failure, or no network attempt was made).
    gh_err=$(grep -v '^[[:space:]]*$' "$WORK/gh-stderr.log" 2>/dev/null | tail -n 1 | redact)
    sentry_report "ci-queue-collect: collection cycle failed (fails=$fails)${gh_err:+: gh error: $gh_err}"
    # #663 AC6: lowered from a 3-failure streak to 2 (an intermittent pair of failures a day apart
    # used to never alert at all) — still fires exactly once per streak, on the transition into it.
    if [ "$fails" -eq 2 ]; then
      slack_post "CI queue collector: $fails consecutive failures [env=$ENVIRONMENT release=$RELEASE]${gh_err:+ gh error: $gh_err}"
    fi
  fi
  [ -z "${CI_QUEUE_CALL_LOG:-}" ] || wc -c < "$WORK/calls.count" | tr -d ' ' > "$CI_QUEUE_CALL_LOG" 2>/dev/null

  exit 0
}

main
