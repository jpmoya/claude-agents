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
# webhook, no new one) fires once a failure streak reaches 3 consecutive cycles. A mkdir-based
# lock (same stale-reclaim pattern as report-status.sh's own) keeps two near-simultaneous
# invocations from both slipping past the throttle and doubling the real API calls.
#
# API calls per cycle (bounded, #637): 2 runner-list calls (org + jpmoya/claude-agents repo-level)
# + 2 run-list calls per repo (status=queued, status=in_progress) + up to
# MAX_RUN_LOOKUPS_PER_REPO job-lookup calls per repo, + 1 extra run-list call per repo ONLY when
# that repo's queued backlog spans more than one page (#645 review finding 1 — see
# _ciq_collect_repo's "last page" fetch below). No --paginate anywhere (one HTTP call per `gh api`
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
# in_progress run is eventually looked up — bounding first resolution to at most
# ceil(in_progress_count / r) cycles, never unbounded. This needs cross-cycle memory: a new state
# file, $CI_QUEUE_IP_STATE_FILE (separate from $STATE_FILE, which _ciq_write_fails fully overwrites
# every cycle), keyed by repo: {"<repo>": {"sticky": [<run id>...], "cursor": <run id>}}. Written
# atomically, same mktemp+mv pattern as $OUT, and ONLY once the whole cycle has already succeeded
# (see _ciq_update_ip_state) — a failed cycle leaves it byte-for-byte untouched, same contract as
# $OUT/$STATE_FILE. A missing or corrupt/unparseable file is treated as "no sticky set, cursor 0"
# for every repo — it never aborts the cycle. Still zero new `gh api` calls: this only changes
# which in_progress run IDs fill the existing r/qsel/pextra slots.
#
# #657: the old single `deploy_release` category bucket conflated a prod merge/deploy with a
# staging deploy with release housekeeping. `_ciq_categorize` now also reads `head_branch`
# (already present on every run object the existing queued/in_progress run-list calls return — no
# new `gh api` call) to split a deploy|release-named workflow into `prod_deploy` (head_branch ==
# "main"), `staging_deploy` (head_branch == "staging"), or `deploy_release` (name matches but
# neither branch — e.g. release housekeeping). `ci_queue.queued_items[]` is new: a capped
# (MAX_CI_QUEUE_QUEUED_ITEMS per category) list of the ACTUAL queued runs behind each category's
# count — repo, run_id, pr_url (always present, nullable), title (optional), queued_at — built
# from the SAME run/job data already fetched per run for categories[]/current_job (zero new `gh
# api` calls), deduped GLOBALLY by run id in collect_once (the scheduler/benjis-ops-tool repo
# alias in scripts/ci-metrics.repos means the same physical run can otherwise appear via two
# entries). Documented limitation: categories[] stays per-JOB and is not deduped across that
# alias (unchanged, out of scope) — queued_items is per-RUN and IS deduped, so a category's count
# and the length of its queued_items can legitimately disagree under the alias; this is by
# design, not a bug.
#
# Env (production): CI_QUEUE_COLLECT_ENABLED (gate, read by report-status.sh, not this script),
#   PIPE, GH_TOKEN (optional — the host's own `gh` auth is used), SLACK_WEBHOOK_URL, SENTRY_DSN,
#   CI_QUEUE_REPOS_FILE (default: scripts/ci-metrics.repos), CI_QUEUE_ORG (default: Benjis-Plants),
#   CI_QUEUE_SELF_REPO (default: jpmoya/claude-agents — its runners are repo-level, not org-level),
#   CI_QUEUE_INTERVAL_SECS (default 240 — "every ~3-5 min"), CI_QUEUE_PROD_DEPLOY_LABEL (default
#   benjis-ci-prod-deploy — the GitHub runner label that sets `runners[].role` to "prod_deploy").
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

# #648: per-runner utilization history.
SAMPLES_FILE=${CI_QUEUE_SAMPLES_FILE:-$PIPE/ci-runner-samples.jsonl}
PROD_DEPLOY_LABEL=${CI_QUEUE_PROD_DEPLOY_LABEL:-benjis-ci-prod-deploy}
WINDOW_24H_SECS=86400
WINDOW_72H_SECS=259200
MAX_SAMPLE_RUNNERS=30   # mirrors status-page/src/validate.js's MAX_CI_QUEUE_RUNNERS cap
MAX_CI_QUEUE_QUEUED_ITEMS=10   # mirrors status-page/src/validate.js's MAX_CI_QUEUE_QUEUED_ITEMS cap, per category key (#657)

repos() { grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[[:space:]]*$' "$REPOS_FILE"; }

# _ciq_call <api-path> <fixture-basename> -> JSON on stdout; returns 1 on any failure (a real
# `gh api` non-zero exit — including a 403/429 HTTP error — or a forced test failure). Never
# raises an error to stdout: a failed call means the caller aborts the whole cycle so the
# previous snapshot is kept untouched.
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
    gh api "$1" 2>/dev/null || return 1
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

# _ciq_categorize — reads one workflow_run JSON object on stdin, prints exactly one
# CI_QUEUE_CATEGORY_VOCAB key. Precedence: dependabot actor, then a deploy/release workflow name,
# then a pull_request(_target)-triggered run, else "other" (never silently dropped) — UNCHANGED
# from before #657; the split below is a sub-decision made ONLY once a run has already matched
# the deploy/release name test, so it can never steal a run away from the `pr`/`other` buckets
# (e.g. a PR-triggered run literally named "Staging E2E" still categorizes as `pr`, not
# `staging_deploy` — JP's ruling on the issue was about splitting the deploy_release bucket, not
# reordering this outer precedence).
#
# #657 (JP-ruled 5-rule cascade, issue #657 delivery-lead JP CONFIRMED comment — supersedes the
# ticket's own simpler "head_branch == main/staging" rule, which live data showed misclassifies a
# schedule-triggered "Deploy Staging Preview" run (head_branch main, but a staging deploy by name
# and by what it does) and every workflow_run-triggered "Post-release cleanup"/"Announce release"
# run (head_branch main, inherited from the deploy it's chained off, not itself a prod-merge
# event) — checked in this order, once a run's name has already matched deploy|release:
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
_ciq_categorize() {
  jq -r '
    if ((.actor.login // "") | ascii_downcase | contains("dependabot")) then "dependabot"
    elif ((.name // "") | ascii_downcase | (contains("deploy") or contains("release"))) then
      ((.name // "") | ascii_downcase) as $name
      | if ($name | contains("staging")) then "staging_deploy"
        elif ($name | (contains("cleanup") or contains("announce"))) then "deploy_release"
        elif (.head_branch // "") == "main" then "prod_deploy"
        elif (.head_branch // "") == "staging" then "staging_deploy"
        else "deploy_release" end
    elif (.event == "pull_request" or .event == "pull_request_target") then "pr"
    else "other" end'
}

# _ciq_collect_repo <repo> <online-busy-runner-count> — appends one {cat, queued_at} line per
# queued job to $WORK/queued-jobs.jsonl. Returns 1 (aborting the whole cycle) on any API failure.
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
#            gets looked up, bounding first resolution to at most ceil(in_progress_count / r)
#            cycles (never unbounded).
#       The new cursor = the last rotation-selected id this cycle (unchanged if nothing was
#       selected from rotation, e.g. sticky alone filled the whole budget). The new sticky set is
#       NOT "whatever got looked up" — it is computed AFTER _ciq_runner_history, from exactly the
#       run ids that resolved into a BUSY runner's `current_job` this cycle (see
#       _ciq_update_ip_state). Using "any job with a runner_name" instead (the looser reading) is a
#       live starvation trap: an in_progress run sitting on an IDLE runner would go sticky and
#       permanently occupy the rotation budget, starving the one actually-busy run exactly like (c)
#       describes — proven by this ticket's "more in_progress runs than any fixed reservation"
#       test. GUARANTEE (state honestly, no stronger claim): resolves within at most
#       ceil(in_progress_count / r) collection cycles, then stays resolved (sticky) for as long as
#       that run keeps holding the busy runner's job — not necessarily within a single cycle when
#       in_progress runs outnumber the reservation.
# Residual risk (documented, not fixed): a queued job inside an old in_progress run that isn't
# reached before the cap runs out can still be missed — unchanged from before, and orthogonal to
# (a)/(b)/(c) above.
_ciq_collect_repo() {
  local repo=$1 busy=${2:-0} safe qjson pjson n=0 run id cat jobsjson qtotal page qlast="" sticky_in cursor_in
  safe=${repo//\//__}

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

  { printf '%s' "$qjson" | jq -c '.workflow_runs[]? | . + {source:"queued"}' 2>/dev/null
    [ -z "$qlast" ] || printf '%s' "$qlast" | jq -c '.workflow_runs[]? | . + {source:"queued"}' 2>/dev/null
    printf '%s' "$pjson" | jq -c '.workflow_runs[]? | . + {source:"in_progress"}' 2>/dev/null
  } | jq -s -c --argjson cap "$MAX_RUN_LOOKUPS_PER_REPO" --argjson busy "$busy" \
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
      | ($pstickyall[0:$psel]) as $pstickysel
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
    printf '%s' "$jobsjson" | jq -c --arg cat "$cat" '
      .jobs[]? | select(.status=="queued")
      | {cat: $cat, queued_at: (.created_at | sub("\\.[0-9]+Z$"; "Z"))}
    ' >> "$WORK/queued-jobs.jsonl" 2>/dev/null

    # #655 AC B: zero new API calls — $jobsjson is the SAME per-run job listing already fetched
    # above for the queued-jobs/categories[] extraction; this only pulls an extra field
    # (`runner_name`) out of jobs already in hand. `pr_url` is built from the run's own
    # `pull_requests[0]`, preferring `html_url` if GitHub ever returns one, else constructing
    # `https://github.com/<repo>/pull/<number>` from the validated `repo` + `number` — GitHub's
    # real `pull_requests[]` shape (verified live, see the PR description) carries `number`, not
    # `html_url`.
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

    # Only an in_progress job (one actually assigned a runner) is ever a current_job candidate;
    # the slot-level busy/race gating happens later in _ciq_runner_history, where the current
    # cycle's busy slots are known.
    printf '%s' "$jobsjson" | jq -c --slurpfile ctx "$WORK/run-${safe}-${id}.prctx.json" '
      ($ctx[0]) as $ctx
      | .jobs[]? | select(.status=="in_progress" and ((.runner_name // "") != ""))
      | {runner_name: .runner_name, repo: $ctx.repo, run_id: $ctx.run_id, pr_url: $ctx.pr_url}
    ' >> "$WORK/running-jobs.jsonl" 2>/dev/null

    # #657: one queued-ITEM line per RUN that has >= 1 queued job (not per job, unlike
    # queued-jobs.jsonl above — categories[] counts stay per-job; queued_items is per-run,
    # deduped globally by run id in collect_once; see that function's comment for why these two
    # populations are deliberately not the same shape). Zero new `gh api` calls: built entirely
    # from $run (already in hand) + $jobsjson/$ctx (already fetched above for queued-jobs.jsonl/
    # running-jobs.jsonl). `title` prefers the run's own `display_title` (GitHub's rendered
    # title for the run, already present on every run object — no new call); `pr_url` reuses the
    # same prctx this run already built. `queued_at` is the EARLIEST queued job's created_at
    # (fractional seconds stripped, same as queued-jobs.jsonl).
    printf '%s' "$run" | jq -c --arg cat "$cat" --argjson jj "$jobsjson" \
        --slurpfile ctx "$WORK/run-${safe}-${id}.prctx.json" '
      ($ctx[0]) as $ctx
      | ([$jj.jobs[]? | select(.status=="queued") | (.created_at | sub("\\.[0-9]+Z$"; "Z"))] | sort) as $qats
      | if ($qats | length) == 0 then empty else
          { key: $cat, repo: $ctx.repo, run_id: $ctx.run_id, pr_url: $ctx.pr_url, queued_at: $qats[0] }
          + (if (.display_title // null) != null then {title: .display_title} else {} end)
        end
    ' >> "$WORK/queued-items.jsonl" 2>/dev/null
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
    | .[0:$max]
  ' > "$WORK/runners-out.json" 2>/dev/null || return 1

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
collect_once() {
  local org_json repo_json busy total offline as_of final repo
  org_json=$(_ciq_call_shaped "orgs/$ORG/actions/runners?per_page=100" "runners-org.json" runners) || return 1
  repo_json=$(_ciq_call_shaped "repos/$SELF_REPO/actions/runners?per_page=100" "runners-repo.json" runners) || return 1
  _ciq_merge_runners "$org_json" "$repo_json" || return 1
  # #648: runners_busy/runners_total now count ONLINE runners only; runners_offline is new.
  busy=$(jq '[.[] | select(.status=="online" and .busy==true)] | length' "$WORK/runners-merged.json") || return 1
  total=$(jq '[.[] | select(.status=="online")] | length' "$WORK/runners-merged.json") || return 1
  offline=$(jq '[.[] | select(.status!="online")] | length' "$WORK/runners-merged.json") || return 1

  [ -r "$REPOS_FILE" ] || return 1
  while read -r repo; do
    _ciq_collect_repo "$repo" "$busy" || return 1
  done < <(repos)

  _ciq_runner_history "$WORK/runners-merged.json" "$WORK/running-jobs.jsonl" || return 1

  as_of=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  final=$(jq -n \
    --slurpfile jobs "$WORK/queued-jobs.jsonl" \
    --slurpfile items "$WORK/queued-items.jsonl" \
    --slurpfile runners "$WORK/runners-out.json" \
    --argjson busy "$busy" \
    --argjson total "$total" \
    --argjson offline "$offline" \
    --argjson max_items "$MAX_CI_QUEUE_QUEUED_ITEMS" \
    --arg as_of "$as_of" \
    '
    ($jobs) as $j
    # #657: prod_deploy/staging_deploy split out of the old single deploy_release bucket — this
    # vocab order must match status-page/src/vocab.js CI_QUEUE_CATEGORY_VOCAB exactly.
    | ["dependabot","prod_deploy","staging_deploy","deploy_release","pr","other"] as $vocab
    | ($vocab
        | map(. as $k | {key: $k, count: ([$j[] | select(.cat == $k)] | length)})
        | map(select(.count > 0))) as $cats
    | ($j | sort_by(.queued_at) | .[0]) as $o
    # #657: queued_items is a SEPARATE population from categories[]/oldest above — per-RUN (not
    # per-job) and deduped GLOBALLY by run id (first occurrence wins; the scheduler/benjis-ops-tool
    # repo alias means the same physical run can otherwise appear twice). Documented limitation:
    # categories[]/queued_total stay per-job and are not deduped across repo aliases — unchanged,
    # out of scope (see the issue) — so a given categorys queued_items list and its own
    # categories[].count can disagree under that alias, by design, not a bug.
    | ($items | group_by(.run_id) | map(.[0])) as $items_dedup
    | ($vocab
        | map(. as $k
              | ($items_dedup | map(select(.key == $k)) | sort_by(.queued_at) | .[0:$max_items])
          )
        | add // []) as $queued_items
    | {as_of: $as_of,
       runners_busy: ([$busy, 999] | min),
       runners_total: ([$total, 999] | min),
       runners_offline: ([$offline, 999] | min),
       queued_total: ([($j | length), 999] | min),
       categories: $cats,
       oldest: (if $o == null then null else {key: $o.cat, queued_at: $o.queued_at} end),
       queued_items: $queued_items,
       runners: ($runners[0] // [])}
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
    local fails
    fails=$(( $(_ciq_read_fails) + 1 ))
    _ciq_write_fails "$fails"
    sentry_report "ci-queue-collect: collection cycle failed (fails=$fails)"
    # Only on a failure STREAK reaching 3 (not every failed tick, which would spam the channel
    # every ~3-5 min): fire exactly once, on the transition into the streak.
    [ "$fails" -eq 3 ] && slack_post "CI queue collector: $fails consecutive failures [env=$ENVIRONMENT release=$RELEASE]"
  fi
  [ -z "${CI_QUEUE_CALL_LOG:-}" ] || wc -c < "$WORK/calls.count" | tr -d ' ' > "$CI_QUEUE_CALL_LOG" 2>/dev/null

  exit 0
}

main
