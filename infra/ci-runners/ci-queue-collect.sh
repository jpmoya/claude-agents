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
# runners_offline count and a per-runner runners[] array (identity + 24h/72h utilization rollup,
# keyed by GitHub's own stable numeric runner `id` — names change on re-registration, ids don't).
# This adds ZERO new `gh api` calls: the runner list was already fetched above for the busy/total
# count; only how it's processed/stored changes (AC9). History is a new append-only sample file,
# $PIPE/ci-runner-samples.jsonl by default (one line per currently-known runner per cycle:
# {ts, id, name, online, busy, role} — `name`/`role` ride along so a runner that stops being
# returned by the API (deregistered) can still be shown, using its last-known identity, until its
# samples age out past the 72h window; `ts` is a unix epoch, not ISO, since this is a local sample
# stream, not part of the beat payload itself), pruned to 72h + one cycle's buffer every cycle.
# util_24h_pct/util_72h_pct for a given cycle are computed from samples taken BEFORE that cycle's
# own append (so a runner's very first-ever cycle reports null, not 0/100 from its own single
# fresh sample — AC7); the fresh sample is appended after the rollup, feeding the NEXT cycle.
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

# #648: per-runner utilization history.
SAMPLES_FILE=${CI_QUEUE_SAMPLES_FILE:-$PIPE/ci-runner-samples.jsonl}
PROD_DEPLOY_LABEL=${CI_QUEUE_PROD_DEPLOY_LABEL:-benjis-ci-prod-deploy}
WINDOW_24H_SECS=86400
WINDOW_72H_SECS=259200
MAX_SAMPLE_RUNNERS=30   # mirrors status-page/src/validate.js's MAX_CI_QUEUE_RUNNERS cap

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
# then a pull_request(_target)-triggered run, else "other" (never silently dropped).
_ciq_categorize() {
  jq -r '
    if ((.actor.login // "") | ascii_downcase | contains("dependabot")) then "dependabot"
    elif ((.name // "") | ascii_downcase | (contains("deploy") or contains("release"))) then "deploy_release"
    elif (.event == "pull_request" or .event == "pull_request_target") then "pr"
    else "other" end'
}

# _ciq_collect_repo <repo> — appends one {cat, queued_at} line per queued job to
# $WORK/queued-jobs.jsonl. Returns 1 (aborting the whole cycle) on any API failure.
#
# #645 review finding 1 (backlog undercount): two independent bias sources, both fixed here:
#   (a) GitHub's run-list endpoint always returns newest-first with no ascending-sort query param
#       (confirmed against the REST docs — no sort/direction param on "List workflow runs for a
#       repository"). If a repo's queued backlog exceeds one page, the genuinely oldest queued
#       run sits on the LAST page, never this one. Below, when the queued call's `total_count`
#       says there's a page beyond what we fetched, one bounded extra call fetches exactly that
#       last page — the oldest queued run is then always among what we hold, regardless of how
#       deep the backlog is (2 calls total, not proportional to backlog size).
#   (b) Merging queued + in_progress runs and walking them oldest-id-first (as this used to do via
#       `unique_by`) is NOT safe on its own: in_progress runs generally have lower ids (they
#       started running earlier) than queued ones, so a repo with >= MAX_RUN_LOOKUPS_PER_REPO
#       in_progress runs could spend the whole job-lookup budget on runs that typically have zero
#       queued jobs, starving every actually-queued run of a lookup. Runs are now tagged by source
#       list and queued-source runs are always walked (oldest-id-first) before any in_progress-
#       source run, so the cap is spent on the runs likeliest to answer "oldest queued" first.
# Residual risk (documented, not fixed): a queued job inside an old in_progress run that isn't
# reached before the cap runs out can still be missed — unchanged from before, and orthogonal to
# (a)/(b) above.
_ciq_collect_repo() {
  local repo=$1 safe qjson pjson n=0 run id cat jobsjson qtotal page qlast=""
  safe=${repo//\//__}
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
  } | jq -s -c '
      group_by(.id)
      | map(if any(.[]; .source == "queued") then (map(select(.source == "queued")) | .[0]) else .[0] end)
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
    ' >> "$WORK/queued-jobs.jsonl" 2>/dev/null
  done < "$WORK/$safe.runs.jsonl"
  return 0
}

# _ciq_merge_runners <org-json> <repo-json> -> writes $WORK/runners-merged.json: one object per
# currently-known runner, {id, name, status, busy, role}, defensively defaulted (#648 AC2
# negative case: a runner object missing `status`/`busy` in the API response is treated as
# offline/not-busy, never crashes the cycle) and `role` derived from the GitHub labels GitHub
# itself returns (prod_deploy iff $PROD_DEPLOY_LABEL is among them, else general).
_ciq_merge_runners() {
  printf '%s\n%s\n' "$1" "$2" | jq -s --arg label "$PROD_DEPLOY_LABEL" -c '
    [.[].runners[]?]
    | map({
        id: (.id // -1),
        name: (.name // ""),
        status: (.status // "offline"),
        busy: (.busy == true),
        role: (if ([.labels[]?.name] | index($label)) then "prod_deploy" else "general" end)
      })
  ' > "$WORK/runners-merged.json" 2>/dev/null
}

# _ciq_runner_history <merged-runners-file> — the #648 per-runner sample/prune/rollup step.
# Writes $WORK/runners-out.json (the final `ci_queue.runners[]` array: identity from the CURRENT
# cycle for every currently-known runner, plus any runner that's dropped out of the API response
# but still has a sample inside the trailing 72h — using its last-known identity — so it doesn't
# vanish the instant it's deregistered; it ages out only once that 72h window empties, AC6).
# Returns 1 on any failure (propagates as a normal collect_once failure: $OUT is left untouched,
# the existing 3-failures-before-Slack/Sentry path in main() fires exactly as it does for an API
# failure — same seam, no new alert path, per the Observability section).
_ciq_runner_history() {
  local merged=$1 now keep old_pruned new_lines combined
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

  new_lines="$WORK/samples-new.jsonl"
  jq -c --argjson now "$now" '
    .[] | {ts: $now, id, name, online: (.status == "online"), busy: ((.status == "online") and (.busy == true)), role}
  ' "$merged" > "$new_lines" 2>/dev/null || return 1

  # Rollup is computed from $old (samples taken BEFORE this cycle's own append) — a runner seen
  # for the very first time this cycle has zero prior samples and reports null, not 0/100 (AC7).
  jq -n --argjson now "$now" --argjson w24 "$WINDOW_24H_SECS" --argjson w72 "$WINDOW_72H_SECS" \
    --argjson max "$MAX_SAMPLE_RUNNERS" --slurpfile old "$old_pruned" --slurpfile cur "$merged" '
    ($cur[0] // []) as $cur
    | ($cur | map(.id)) as $cur_ids
    | ($old | map(select(.ts >= ($now - $w72)) | .id)) as $recent72_ids
    | ($cur_ids + $recent72_ids | unique) as $ids
    | [ $ids[] as $id
        | ($old | map(select(.id == $id))) as $samples
        | ($samples | map(select(.ts >= ($now - $w24)))) as $s24
        | ($samples | map(select(.ts >= ($now - $w72)))) as $s72
        | ($cur | map(select(.id == $id)) | .[0]) as $c
        | (if $c != null then null else ($samples | sort_by(.ts) | if length > 0 then .[-1] else null end) end) as $last
        | {
            id: $id,
            name: (if $c != null then $c.name else ($last.name // "") end),
            online: (if $c != null then ($c.status == "online") else false end),
            busy: (if $c != null then (($c.status == "online") and ($c.busy == true)) else false end),
            role: (if $c != null then $c.role else ($last.role // "general") end),
            util_24h_pct: (if ($s24 | length) == 0 then null
              else ((100 * ([$s24[] | select(.busy == true)] | length) / ($s24 | length)) | round) end),
            util_72h_pct: (if ($s72 | length) == 0 then null
              else ((100 * ([$s72[] | select(.busy == true)] | length) / ($s72 | length)) | round) end)
          }
      ]
    | sort_by(.id)
    | .[0:$max]
  ' > "$WORK/runners-out.json" 2>/dev/null || return 1

  combined="$WORK/samples-combined.jsonl"
  cat "$old_pruned" "$new_lines" > "$combined" 2>/dev/null || return 1
  _ciq_write_samples_atomic "$(cat "$combined" 2>/dev/null)"
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
    _ciq_collect_repo "$repo" || return 1
  done < <(repos)

  _ciq_runner_history "$WORK/runners-merged.json" || return 1

  as_of=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  final=$(jq -n \
    --slurpfile jobs "$WORK/queued-jobs.jsonl" \
    --slurpfile runners "$WORK/runners-out.json" \
    --argjson busy "$busy" \
    --argjson total "$total" \
    --argjson offline "$offline" \
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
  : > "$WORK/calls.count"

  if collect_once; then
    _ciq_write_fails 0
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
