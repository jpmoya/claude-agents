#!/usr/bin/env bash
# ci-metrics.sh (#356): CI job metrics from the GitHub Actions API.
#   collect  fetch jobs completed in the last 26 h for the repos in $CI_METRICS_REPOS, append new ones
#            (dedupe by job_id) to $CI_METRICS_DATA_DIR/ci-jobs.jsonl, trim lines older than 90 days
#   rollup   write $CI_METRICS_DATA_DIR/ci-daily.json from the last 24 h of ci-jobs.jsonl
#   weekly   post one Slack message (<= 15 lines) summarising ci-daily.json to $SLACK_WEBHOOK_URL
# Env: CI_METRICS_DATA_DIR, CI_METRICS_REPOS, CI_METRICS_NOW (epoch, tests), CI_METRICS_RELEASE (commit SHA),
#      CI_METRICS_ENVIRONMENT, GH_TOKEN, SLACK_WEBHOOK_URL, SENTRY_DSN.
# Any failure: message on stderr (secrets redacted), Sentry event (route ci-metrics/<step>), Slack alert, exit 1.
set -uo pipefail
set +x

STEP=${1:-}
DATA=${CI_METRICS_DATA_DIR:-metrics}
REPOS_FILE=${CI_METRICS_REPOS:-$(dirname "$0")/ci-metrics.repos}
NOW=${CI_METRICS_NOW:-$(date +%s)}
RELEASE=${CI_METRICS_RELEASE:-unknown}
ENVIRONMENT=${CI_METRICS_ENVIRONMENT:-ci}
JOBS=$DATA/ci-jobs.jsonl
DAILY=$DATA/ci-daily.json
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

redact() { # stdin -> stdout without secret values
  local s; s=$(cat)
  [ -z "${GH_TOKEN:-}" ] || s=${s//"$GH_TOKEN"/***}
  [ -z "${SLACK_WEBHOOK_URL:-}" ] || s=${s//"$SLACK_WEBHOOK_URL"/***}
  printf '%s' "$s"
}

sentry_report() { # message
  local dsn=${SENTRY_DSN:-} body id
  [[ $dsn =~ ^(https?)://([^@:/]+)@([^/]+)/([0-9]+)/?$ ]] || return 0
  id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  body=$(jq -cn --arg m "$1" --arg r "$RELEASE" --arg e "$ENVIRONMENT" --arg route "ci-metrics/$STEP" --arg id "$id" \
    '{event_id:$id,message:$m,level:"error",platform:"other",release:$r,environment:$e,tags:{route:$route}}')
  curl -sS --max-time 10 -o /dev/null -X POST "${BASH_REMATCH[1]}://${BASH_REMATCH[3]}/api/${BASH_REMATCH[4]}/store/" \
    -H "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=${BASH_REMATCH[2]}, sentry_client=ci-metrics/1" \
    -H "Content-Type: application/json" --data "$body" >/dev/null 2>&1 || true
}

slack_post() { # text
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 1
  curl -sS --max-time 10 -o /dev/null -X POST -H 'Content-type: application/json' \
    --data "$(jq -cn --arg t "$1" '{text:$t}')" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
}

fail() { # message
  local m; m=$(printf '%s' "$1" | redact | tr '\n' ' ')
  echo "ERROR: ci-metrics/$STEP: $m" >&2
  sentry_report "$m"
  slack_post "CI metrics failure (ci-metrics/$STEP): $m [$RELEASE]" || true
  exit 1
}

slots() { sed -n 's/^SLOTS=\([0-9][0-9]*\).*/\1/p' "$REPOS_FILE" | head -1; }
repos() { grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[[:space:]]*$' "$REPOS_FILE"; }

GH_OUT=
gh_json() { # gh api args... -> GH_OUT; fails with captured stderr
  GH_OUT=$(gh api --paginate "$@" 2>"$WORK/gh.err") || fail "gh api $1 failed: $(cat "$WORK/gh.err")"
  [ -n "$GH_OUT" ] || fail "gh api $1 returned an empty response"
}

collect() {
  [ -r "$REPOS_FILE" ] || fail "repo config $REPOS_FILE not readable"
  local since cutoff win repo rid wf n=0
  win=$((NOW - 26*3600)); cutoff=$((NOW - 90*86400))
  since=$(jq -rn --argjson t "$((NOW - 3*86400))" '$t|strftime("%Y-%m-%d")')
  : > "$WORK/new.jsonl"
  while read -r repo; do
    n=$((n+1))
    gh_json "repos/$repo/actions/runs?per_page=100&created=>=$since"
    printf '%s' "$GH_OUT" | jq -s -r '[.[].workflow_runs[]?|[.id,.name]|@tsv]|.[]' > "$WORK/runs.tsv" 2>"$WORK/jq.err" \
      || fail "could not parse runs for $repo: $(cat "$WORK/jq.err")"
    while IFS=$'\t' read -r rid wf; do
      [ -n "$rid" ] || continue
      gh_json "repos/$repo/actions/runs/$rid/jobs?per_page=100&filter=latest"
      printf '%s' "$GH_OUT" | jq -s -c --arg repo "$repo" --arg wf "$wf" --argjson win "$win" '
        .[].jobs[]?
        | select(.status=="completed" and .started_at!=null and .completed_at!=null and .conclusion!="skipped")
        | select((.completed_at|fromdateiso8601) >= $win)
        | {ts:.completed_at, repo:$repo, workflow:$wf, job:.name, runner_name:.runner_name, result:.conclusion,
           queue_s:((.started_at|fromdateiso8601)-(.created_at|fromdateiso8601)),
           run_s:((.completed_at|fromdateiso8601)-(.started_at|fromdateiso8601)), job_id:.id}' \
        >> "$WORK/new.jsonl" 2>"$WORK/jq.err" || fail "could not parse jobs for $repo run $rid: $(cat "$WORK/jq.err")"
    done < "$WORK/runs.tsv"
  done < <(repos)
  [ "$n" -gt 0 ] || fail "no repos in $REPOS_FILE"
  mkdir -p "$DATA" || fail "cannot create $DATA"
  [ -e "$JOBS" ] || : > "$JOBS"
  # existing lines (trimmed to 90 d) then new ones; first occurrence of a job_id wins
  { cat "$JOBS"; cat "$WORK/new.jsonl"; } \
    | jq -R -c --argjson cut "$cutoff" 'fromjson? | select((.ts|fromdateiso8601) >= $cut)' \
    | jq -s -c 'reduce .[] as $r ({seen:{},out:[]}; if .seen[($r.job_id|tostring)] then . else .seen[($r.job_id|tostring)]=true | .out+=[$r] end) | .out[]' \
    > "$WORK/merged.jsonl" 2>"$WORK/jq.err" || fail "merge failed: $(cat "$WORK/jq.err")"
  if ! cmp -s "$WORK/merged.jsonl" "$JOBS"; then
    cp "$WORK/merged.jsonl" "$JOBS.tmp" && mv "$JOBS.tmp" "$JOBS" || fail "cannot write $JOBS"
  fi
}

rollup() {
  [ -s "$JOBS" ] || fail "no job data in $JOBS"
  local s; s=$(slots); s=${s:-1}
  jq -s --argjson now "$NOW" --argjson slots "$s" '
    def pct($p): sort as $a | if length==0 then null else $a[((($p*length)|ceil)-1)] end;
    def med: sort as $a | length as $n | if $n==0 then null elif $n%2==1 then $a[($n-1)/2] else (($a[$n/2-1]+$a[$n/2])/2) end;
    map(select((.ts|fromdateiso8601) >= ($now-86400))) as $r
    | {generated_at:($now|todate), window_s:86400, slots:$slots,
       jobs:($r|group_by(.job)|map({key:.[0].job, value:{
           run_s_median:(map(.run_s)|med), run_s_p90:(map(.run_s)|pct(0.9)),
           queue_s_median:(map(.queue_s)|med), queue_s_p90:(map(.queue_s)|pct(0.9)), count:length}})|from_entries),
       longest_queue_s:($r|map(.queue_s)|max),
       jobs_per_runner:($r|map(select(.runner_name!=null))|group_by(.runner_name)|map({key:.[0].runner_name,value:length})|from_entries),
       slot_busy_pct:(($r|map(select(.runner_name!=null and (.runner_name|startswith("GitHub Actions")|not))|.run_s)|add // 0) * 100 / ($slots*86400))}' \
    "$JOBS" > "$WORK/daily.json" 2>"$WORK/jq.err" || fail "rollup failed: $(cat "$WORK/jq.err")"
  mkdir -p "$DATA" && mv "$WORK/daily.json" "$DAILY" || fail "cannot write $DAILY"
}

weekly() {
  [ -s "$DAILY" ] || fail "no rollup at $DAILY"
  local msg
  msg=$(jq -r '
    (.jobs|to_entries) as $j
    | ($j|max_by(.value.queue_s_p90)) as $q | ($j|max_by(.value.run_s_median)) as $m
    | (.jobs_per_runner|to_entries|sort_by(.value)) as $r
    | ($q.value.queue_s_p90) as $qp | ($m.value.run_s_median) as $mm | .slot_busy_pct as $b
    | (if $qp > 120 and $b > 60 then "add slot" elif $mm > 600 then "split job" else "no change" end) as $sug
    | [ "CI weekly summary",
        "1. Longest p90 queue wait: \($q.key) (\($qp)s)",
        "2. Longest median job: \($m.key) (\($mm)s)",
        "3. Lowest-throughput runner: \($r[0].key // "n/a") (\($r[0].value // 0) jobs)",
        "Runner jobs: \([$r[]|"\(.key) \(.value)"]|join(", "))",
        "Slot busy: \($b|floor)%, longest queue wait: \(.longest_queue_s)s",
        "Suggested change: \($sug)" ] | join("\n")' "$DAILY" 2>"$WORK/jq.err") || fail "cannot build weekly message: $(cat "$WORK/jq.err")"
  [ -n "$msg" ] || fail "empty weekly message"
  slack_post "$msg" || fail "Slack post failed"
}

case $STEP in
  collect) collect ;;
  rollup) rollup ;;
  weekly) weekly ;;
  *) echo "usage: ci-metrics.sh collect|rollup|weekly" >&2; exit 2 ;;
esac
