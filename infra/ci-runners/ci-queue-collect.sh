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
# Env (production): CI_QUEUE_COLLECT_ENABLED (gate, read by report-status.sh, not this script),
#   PIPE, GH_TOKEN (optional — the host's own `gh` auth is used), SLACK_WEBHOOK_URL, SENTRY_DSN,
#   CI_QUEUE_REPOS_FILE (default: scripts/ci-metrics.repos), CI_QUEUE_ORG (default: Benjis-Plants),
#   CI_QUEUE_SELF_REPO (default: jpmoya/claude-agents — its runners are repo-level, not org-level),
#   CI_QUEUE_INTERVAL_SECS (default 240 — "every ~3-5 min"), CI_QUEUE_PROD_DEPLOY_LABEL (default
#   benjis-ci-prod-deploy — the GitHub runner label that sets `runners[].role` to "prod_deploy"),
#   CI_QUEUE_GH_TIMEOUT_SECS (#663 AC3, default 55 — per-call `gh api` timeout).
# Env (tests): CI_QUEUE_FIXTURE_DIR (canned `gh api` JSON responses instead of a live call — see
#   _ciq_call below; mirrors ci-report.sh's CI_REPORT_JOBS_FILE seam), CI_QUEUE_FIXTURE_FAIL=1
#   (simulate every API call failing), CI_QUEUE_FORCE=1 (skip the throttle), CI_QUEUE_OUT /
#   CI_QUEUE_ATTEMPT_FILE / CI_QUEUE_STATE_FILE / CI_QUEUE_LOCKDIR (relocate the written files),
#   CI_QUEUE_CALL_LOG (dump the total API call count to this path, for the AC6 bound test),
#   CI_QUEUE_SAMPLES_FILE (relocate the per-runner sample stream), CI_QUEUE_NOW (epoch seconds —
#   freezes "now" for the sample/prune/rollup window math so tests are deterministic).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PIPE=${PIPE:-$HOME/.claude/pipeline/state}
OUT=${CI_QUEUE_OUT:-$PIPE/status-ci.json}
ATTEMPT_FILE=${CI_QUEUE_ATTEMPT_FILE:-$PIPE/ci-queue-collect.attempt}
STATE_FILE=${CI_QUEUE_STATE_FILE:-$PIPE/ci-queue-collect.state}
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

# _ciq_categorize — reads one workflow_run JSON object on stdin, prints exactly one
# CI_QUEUE_CATEGORY_VOCAB key. Precedence: dependabot actor, then a deploy/release workflow name,
# then a pull_request(_target)-triggered run, else "other" (never silently dropped).
_ciq_categorize() {
  jq -r '
    if ((.actor.login // "") | ascii_downcase | contains("dependabot")) then "dependabot"
    elif ((.name // "") | ascii_downcase | (contains("deploy") or contains("release"))) then "deploy_release"
    elif (.event == "pull_request" or .event == "pull_request_target") then "pr"
    else "other" end'
}

# _ciq_collect_repo <repo> <online-busy-runner-count> — appends one {cat, queued_at} line per
# queued job to $WORK/$safe.queued-jobs.jsonl (PER-REPO, not the shared $WORK/queued-jobs.jsonl —
# #663 AC4: the caller only merges these into the shared files once this function returns 0, so a
# repo that fails PART WAY through this function's own run-lookup loop (queued jobs from its
# earlier, successful lookups already written) never leaks a partial count for a repo the caller
# is about to treat as entirely unavailable). Returns 1 on any API failure — aborting just THIS
# repo at the call site (#663 AC4; it used to abort the whole cycle).
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
# Residual risk (documented, not fixed): a queued job inside an old in_progress run that isn't
# reached before the cap runs out can still be missed — unchanged from before, and orthogonal to
# (a)/(b) above.
_ciq_collect_repo() {
  local repo=$1 busy=${2:-0} safe qjson pjson n=0 run id cat jobsjson qtotal page qlast="" distinct_count
  safe=${repo//\//__}
  : > "$WORK/$safe.queued-jobs.jsonl"
  : > "$WORK/$safe.running-jobs.jsonl"
  echo 0 > "$WORK/$safe.truncated"
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

  { printf '%s' "$qjson" | jq -c '.workflow_runs[]? | . + {source:"queued"}' 2>/dev/null
    [ -z "$qlast" ] || printf '%s' "$qlast" | jq -c '.workflow_runs[]? | . + {source:"queued"}' 2>/dev/null
    printf '%s' "$pjson" | jq -c '.workflow_runs[]? | . + {source:"in_progress"}' 2>/dev/null
  } | jq -s -c --argjson cap "$MAX_RUN_LOOKUPS_PER_REPO" --argjson busy "$busy" '
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
      | ($q[0:$qsel] + $p[0:$psel])
      | sort_by([(if .source == "queued" then 0 else 1 end), .id])
      | .[]
    ' > "$WORK/$safe.runs.jsonl" 2>/dev/null
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

  [ -r "$REPOS_FILE" ] || return 1
  : > "$WORK/unavailable-repos.txt"
  while read -r repo; do
    total_repos=$((total_repos + 1))
    safe=${repo//\//__}
    if _ciq_collect_repo "$repo" "$busy"; then
      cat "$WORK/$safe.queued-jobs.jsonl" >> "$WORK/queued-jobs.jsonl" 2>/dev/null
      cat "$WORK/$safe.running-jobs.jsonl" >> "$WORK/running-jobs.jsonl" 2>/dev/null
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

  as_of=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  final=$(jq -n \
    --slurpfile jobs "$WORK/queued-jobs.jsonl" \
    --slurpfile runners "$WORK/runners-out.json" \
    --argjson busy "$busy" \
    --argjson total "$total" \
    --argjson offline "$offline" \
    --argjson truncated "$truncated_bool" \
    --argjson unavailable_repos "$unavailable_json" \
    --argjson runners_total_sampled "$total_sampled" \
    --arg as_of "$as_of" \
    '
    ($jobs) as $j
    | (["dependabot","deploy_release","pr","other"]
        | map(. as $k | {key: $k, count: ([$j[] | select(.cat == $k)] | length)})
        | map(select(.count > 0))) as $cats
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
  : > "$WORK/calls.count"
  : > "$WORK/gh-stderr.log"   # #663 AC6: accumulates every _ciq_gh_api call's stderr this cycle

  if collect_once; then
    _ciq_write_fails 0
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
