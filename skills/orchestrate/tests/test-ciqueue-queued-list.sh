# Issue #657 — CI queue collector: queued-PR list + prod-merge category detection.
#
# Covers:
#   - _ciq_categorize's 5-rule cascade splitting the old single `deploy_release` bucket into
#     `prod_deploy` / `staging_deploy` / `deploy_release` (JP-ruled cascade, see the issue's
#     delivery-lead JP CONFIRMED comment), nested INSIDE the pre-existing deploy|release name
#     gate (dependabot/pr/other precedence unchanged — negative tests below prove the nesting).
#   - `ci_queue.categories[].queued[]`: a capped, per-category list of the actual queued runs
#     behind each category's count (repo, run_id, pr_url, title?, queued_at), built from the
#     FULL per-repo queued-run list (not the job-lookup-capped subset — a busy-fleet regression
#     test below proves the list survives even when the job-lookup budget is nearly exhausted by
#     in_progress runs), deduped GLOBALLY by run id (the scheduler/benjis-ops-tool repo-alias
#     double-fetch case).
#
# Self-contained: does not depend on test-ciqueue-collector.sh's helpers (load order between
# test-*.sh files is incidental, not a contract). Prefix _ciql_ / CIQL. Placeholder repo names
# only (public repo).

HERE_CIQL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT_CIQL=$(cd "$HERE_CIQL/../../.." && pwd)
COLLECTOR_CIQL="$REPO_ROOT_CIQL/infra/ci-runners/ci-queue-collect.sh"

_ciql_runners_fixtures() {  # <dir> [online] [busy] — valid runner-list fixtures; one org runner, default idle
  local dir=$1 online=${2:-false} busy=${3:-false}
  cat > "$dir/runners-org.json" <<EOF
{"total_count":1,"runners":[{"id":1,"status":"$([ "$online" = "true" ] && echo online || echo offline)","busy":$busy}]}
EOF
  echo '{"total_count":1,"runners":[{"id":2,"status":"offline","busy":false}]}' > "$dir/runners-repo.json"
}

_ciql_repos_file() {  # <dir> <repo...> -> prints a path to a repos file listing the given repos
  local dir=$1; shift
  local f="$dir/repos.txt"
  printf '%s\n' "$@" > "$f"
  printf '%s' "$f"
}

_ciql_run() {  # _ciql_run <pipe> <fixturedir> <reposfile> -> sets CIQL_OUT / CIQL_CALLS, returns the collector's exit code
  local pipe=$1 fixdir=$2 reposfile=$3 rc
  ( CI_QUEUE_FORCE=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" \
    CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_REPOS_FILE="$reposfile" \
    CI_QUEUE_FIXTURE_DIR="$fixdir" \
    bash "$COLLECTOR_CIQL" )
  rc=$?
  CIQL_OUT=$(cat "$pipe/status-ci.json" 2>/dev/null)
  CIQL_CALLS=$(cat "$pipe/calls.log" 2>/dev/null)
  return "$rc"
}

# _ciql_one_run_fixture <dir> <repo-safe> <run-id> <name> <branch> <event> <pr-number-or-empty>
# -> writes a one-run queued fixture: the queued run-list response (carrying `created_at` — the
# queued[] source of truth, #657) and its job-lookup response (a matching queued job, needed only
# because categories[].count is still per-job), plus an empty in_progress list.
_ciql_one_run_fixture() {
  local dir=$1 safe=$2 id=$3 name=$4 branch=$5 event=$6 prnum=$7 pr_json='[]' ts
  [ -z "$prnum" ] || pr_json="[{\"number\":$prnum}]"
  ts=$(printf '2026-01-01T%02d:00:00Z' "$((id % 24))")
  cat > "$dir/runs-${safe}-queued.json" <<EOF
{"workflow_runs":[{"id":$id,"name":"$name","head_branch":"$branch","event":"$event","actor":{"login":"someone"},"display_title":"$name #$id","created_at":"$ts","pull_requests":$pr_json}]}
EOF
  echo '{"workflow_runs":[]}' > "$dir/runs-${safe}-in_progress.json"
  cat > "$dir/jobs-$id.json" <<EOF
{"jobs":[{"id":$((id + 90000)),"status":"queued","created_at":"$ts"}]}
EOF
}

test_ciql_prod_deploy_main_branch() {
  local pipe fixdir reposfile rc cat queued
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/project-a")
  _ciql_one_run_fixture "$fixdir" "example-owner__project-a" 101 "Auto-release" "main" "push" ""

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  cat=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="prod_deploy")')
  queued=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="prod_deploy") | .queued')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$(printf '%s' "$cat" | jq '.count')" "1" "a deploy|release-named run on head_branch main categorizes prod_deploy" || return 1
  assert_eq "$(printf '%s' "$queued" | jq 'length')" "1" "prod_deploy's queued[] carries the one item" || return 1
  assert_eq "$(printf '%s' "$queued" | jq -c '.[0] | {repo, run_id, pr_url, queued_at}')" \
    '{"repo":"example-owner/project-a","run_id":101,"pr_url":null,"queued_at":"2026-01-01T05:00:00Z"}' \
    "queued[0] has repo/run_id/pr_url:null/queued_at (from the run's own created_at, no PR attached)" || return 1
}

test_ciql_staging_deploy_branch_staging() {
  local pipe fixdir reposfile rc cat
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/project-b")
  _ciql_one_run_fixture "$fixdir" "example-owner__project-b" 102 "Deploy to production" "staging" "push" ""

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  cat=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="staging_deploy")')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$(printf '%s' "$cat" | jq '.count')" "1" "the same deploy-named workflow on head_branch staging categorizes staging_deploy" || return 1
}

test_ciql_cleanup_name_stays_deploy_release_regardless_of_branch() {
  local pipe fixdir reposfile rc neither main
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/project-c")
  _ciql_one_run_fixture "$fixdir" "example-owner__project-c" 103 "Post-release cleanup" "chore/housekeeping" "workflow_run" ""

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  neither=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="deploy_release") | .count')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$neither" "1" "Post-release cleanup (name matches release, but neither main/staging) stays deploy_release" || return 1

  # Same name, but on head_branch main — the cleanup/announce denylist must win BEFORE the
  # branch check (rule 2 precedes rules 3/4), so this must also stay deploy_release, not prod_deploy.
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/project-c2")
  _ciql_one_run_fixture "$fixdir" "example-owner__project-c2" 104 "Announce release" "main" "workflow_run" ""
  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  main=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="deploy_release") | .count')
  local prod; prod=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="prod_deploy")')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$main" "1" "Announce release on head_branch main still stays deploy_release (cleanup/announce denylist precedes the branch rule)" || return 1
  assert_eq "$prod" "" "no prod_deploy entry is created for the Announce release run" || return 1
}

test_ciql_no_pr_pr_url_null_still_included() {
  local pipe fixdir reposfile rc queued
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/project-d")
  _ciql_one_run_fixture "$fixdir" "example-owner__project-d" 105 "CI" "feature/x" "schedule" ""

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  queued=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="other") | .queued[0]')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$(printf '%s' "$queued" | jq '.pr_url')" "null" "a queued run with no attached PR gets pr_url: null (field present, item kept)" || return 1
  assert_eq "$(printf '%s' "$queued" | jq '.run_id')" "105" "the item is still present with the right run_id" || return 1
}

test_ciql_dedup_same_run_id_across_aliased_repos() {
  local pipe fixdir reposfile rc items
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  # Two repo entries in ci-metrics.repos (the scheduler/benjis-ops-tool alias case) that both
  # happen to surface the identical run id 501 — same physical GitHub repo/run, two aliases.
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/alias-one" "example-owner/alias-two")
  _ciql_one_run_fixture "$fixdir" "example-owner__alias-one" 501 "CI" "feature/y" "schedule" ""
  _ciql_one_run_fixture "$fixdir" "example-owner__alias-two" 501 "CI" "feature/y" "schedule" ""

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  items=$(printf '%s' "$CIQL_OUT" | jq -c '[.categories[] | select(.key=="other") | .queued[]] | map(select(.run_id==501))')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$(printf '%s' "$items" | jq 'length')" "1" "run id 501, fetched via two repo aliases, dedupes to exactly one queued[] entry" || return 1
}

test_ciql_cap_truncates_without_crashing() {
  local pipe fixdir reposfile rc count queued_len i safe
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  safe="example-owner__cap-repo"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/cap-repo")

  # ONE repo, 15 queued runs, all same "other" category — single-repo proof that queued[] is NOT
  # bounded by MAX_RUN_LOOKUPS_PER_REPO (5): only 5 of these 15 ever get a job lookup (so
  # categories[].count stays 5), but queued[] (built from the full queued-run list) sees all 15,
  # truncated only by MAX_CI_QUEUE_QUEUED_ITEMS (10).
  : > "$fixdir/runs-${safe}-queued.json"
  echo '{"workflow_runs":[' > "$fixdir/runs-${safe}-queued.json"
  for i in $(seq 1 15); do
    cat >> "$fixdir/runs-${safe}-queued.json" <<EOF
{"id":$i,"name":"CI","head_branch":"feature/z","event":"schedule","actor":{"login":"someone"},"display_title":"CI #$i","created_at":"$(printf '2026-01-01T%02d:00:00Z' "$((i % 24))")","pull_requests":[]}$([ "$i" != "15" ] && echo ,)
EOF
    cat > "$fixdir/jobs-$i.json" <<EOF
{"jobs":[{"id":$((i + 90000)),"status":"queued","created_at":"$(printf '2026-01-01T%02d:00:00Z' "$((i % 24))")"}]}
EOF
  done
  echo ']}' >> "$fixdir/runs-${safe}-queued.json"
  echo '{"workflow_runs":[]}' > "$fixdir/runs-${safe}-in_progress.json"

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  count=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="other") | .count')
  queued_len=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="other") | .queued | length')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0 even with more queued items than the cap" || return 1
  assert_eq "$count" "5" "categories[].count stays bounded by MAX_RUN_LOOKUPS_PER_REPO (5), unchanged" || return 1
  assert_eq "$queued_len" "10" "categories[].queued[] sees the FULL 15-run backlog, truncated to MAX_CI_QUEUE_QUEUED_ITEMS (10) — not bounded by the job-lookup cap" || return 1
}

test_ciql_busy_fleet_backlog_not_starved() {
  local pipe fixdir reposfile rc queued_len safe i
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  safe="example-owner__busy-repo"
  # 1 org runner, online+busy (the repo-level runner-list is separately fixtured idle by
  # _ciql_runners_fixtures) — enough to make `busy` > 0 so the #658 in_progress reservation
  # actually kicks in below.
  cat > "$fixdir/runners-org.json" <<'EOF'
{"total_count":4,"runners":[
  {"id":1,"status":"online","busy":true},{"id":2,"status":"online","busy":true},
  {"id":3,"status":"online","busy":true},{"id":4,"status":"online","busy":true}
]}
EOF
  echo '{"total_count":0,"runners":[]}' > "$fixdir/runners-repo.json"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/busy-repo")

  # 4 in_progress runs (ids 601-604, each with a queued job of its own — same "the fleet is
  # genuinely busy" signal #658 relies on) + 20 queued runs (ids 701-720). Under the OLD
  # (job-lookup-loop-sourced) design, the #658 reservation (r = min(pcount=4, busy=4, cap-1=4))
  # would leave only 1 of the cap's 5 slots for the 20 queued runs, capping queued[] at ~1 — this
  # test proves the NEW (full-queued-run-list-sourced) design does not have that failure mode.
  local runs='[' i
  for i in 601 602 603 604; do
    runs="$runs{\"id\":$i,\"name\":\"CI\",\"event\":\"push\",\"actor\":{\"login\":\"someone\"}},"
    echo "{\"jobs\":[{\"id\":$((i+9000)),\"status\":\"in_progress\",\"created_at\":\"2026-11-10T00:00:00Z\",\"runner_name\":\"r$i\"}]}" > "$fixdir/jobs-$i.json"
  done
  runs="${runs%,}]"
  echo "{\"workflow_runs\":$runs}" > "$fixdir/runs-${safe}-in_progress.json"

  echo '{"workflow_runs":[' > "$fixdir/runs-${safe}-queued.json"
  for i in $(seq 701 720); do
    cat >> "$fixdir/runs-${safe}-queued.json" <<EOF
{"id":$i,"name":"CI","head_branch":"feature/q","event":"schedule","actor":{"login":"someone"},"created_at":"$(printf '2026-01-01T%02d:00:00Z' "$((i % 24))")","pull_requests":[]}$([ "$i" != "720" ] && echo ,)
EOF
    cat > "$fixdir/jobs-$i.json" <<EOF
{"jobs":[{"id":$((i + 9000)),"status":"queued","created_at":"$(printf '2026-01-01T%02d:00:00Z' "$((i % 24))")"}]}
EOF
  done
  echo ']}' >> "$fixdir/runs-${safe}-queued.json"

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  queued_len=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="other") | .queued | length')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0 under a busy fleet with a deep backlog" || return 1
  assert_eq "$queued_len" "10" "queued[] is capped at MAX_CI_QUEUE_QUEUED_ITEMS (10), NOT starved down to ~1 by the #658 in_progress reservation on the job-lookup cap" || return 1
}

test_ciql_zero_queued_items_empty_categories_no_error() {
  local pipe fixdir reposfile rc cats
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/project-empty")
  echo '{"workflow_runs":[]}' > "$fixdir/runs-example-owner__project-empty-queued.json"
  echo '{"workflow_runs":[]}' > "$fixdir/runs-example-owner__project-empty-in_progress.json"

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  cats=$(printf '%s' "$CIQL_OUT" | jq -c '.categories')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0 with nothing queued" || return 1
  assert_eq "$cats" "[]" "zero queued/in_progress runs -> empty categories[], never an error" || return 1
}

test_ciql_zero_new_api_calls_exact_count() {
  local pipe fixdir reposfile rc
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/project-calls")
  _ciql_one_run_fixture "$fixdir" "example-owner__project-calls" 201 "Auto-release" "main" "push" "9"

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  local calls; calls=$CIQL_CALLS
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  # 2 (runners) + 2 (queued + in_progress run lists) + 1 (one job lookup for the one run) = 5 —
  # building queued[] from the already-fetched queued-run list adds zero new calls.
  assert_eq "$calls" "5" "the categorize split + queued[] list add zero new gh api calls" || return 1
}

test_ciql_malformed_queued_run_skipped_not_crashing() {
  local pipe fixdir reposfile rc queued_len
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/project-garbled")
  # Two queued runs: one with a garbled (numeric) created_at, one genuinely valid — the garbled
  # one must never crash the cycle or take the valid one down with it.
  echo '{"workflow_runs":[
    {"id":301,"name":"CI","head_branch":"feature/w","event":"schedule","actor":{"login":"someone"},"created_at":12345,"pull_requests":[]},
    {"id":302,"name":"CI","head_branch":"feature/w","event":"schedule","actor":{"login":"someone"},"created_at":"2026-01-01T00:00:00Z","pull_requests":[]}
  ]}' > "$fixdir/runs-example-owner__project-garbled-queued.json"
  echo '{"workflow_runs":[]}' > "$fixdir/runs-example-owner__project-garbled-in_progress.json"
  echo '{"jobs":[{"id":90301,"status":"queued","created_at":"2026-01-01T00:00:00Z"}]}' > "$fixdir/jobs-301.json"
  echo '{"jobs":[{"id":90302,"status":"queued","created_at":"2026-01-01T00:00:00Z"}]}' > "$fixdir/jobs-302.json"

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  queued_len=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="other") | .queued | length')
  local ids; ids=$(printf '%s' "$CIQL_OUT" | jq -c '[.categories[] | select(.key=="other") | .queued[].run_id]')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "a garbled created_at on one queued run never aborts the cycle" || return 1
  assert_eq "$queued_len" "1" "the garbled run (301) is skipped; only the valid run (302) survives" || return 1
  assert_eq "$ids" "[302]" "the surviving queued[] entry is the valid run, not the garbled one" || return 1
}

test_ciql_pr_event_named_staging_stays_pr_not_staging_deploy() {
  local pipe fixdir reposfile rc pr staging
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/project-e")
  _ciql_one_run_fixture "$fixdir" "example-owner__project-e" 106 "Staging smoke tests" "feature/q" "pull_request" "3"

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  pr=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="pr") | .count')
  staging=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="staging_deploy")')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$pr" "1" "a pull_request-triggered run merely named 'Staging smoke tests' (no deploy/release substring) stays pr — the staging rule is nested inside the deploy|release gate, not a top-level override" || return 1
  assert_eq "$staging" "" "no staging_deploy entry is created" || return 1
}

test_ciql_non_deploy_release_cleanup_name_stays_other() {
  local pipe fixdir reposfile rc other deploy_release
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/project-f")
  _ciql_one_run_fixture "$fixdir" "example-owner__project-f" 107 "cleanup-logs" "feature/r" "schedule" ""

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  other=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="other") | .count')
  deploy_release=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="deploy_release")')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$other" "1" "a run named 'cleanup-logs' (no deploy/release substring) stays other — rule 2's cleanup/announce denylist only applies once the deploy|release gate has already matched" || return 1
  assert_eq "$deploy_release" "" "no deploy_release entry is created" || return 1
}

run_test test_ciql_prod_deploy_main_branch
run_test test_ciql_staging_deploy_branch_staging
run_test test_ciql_cleanup_name_stays_deploy_release_regardless_of_branch
run_test test_ciql_no_pr_pr_url_null_still_included
run_test test_ciql_dedup_same_run_id_across_aliased_repos
run_test test_ciql_cap_truncates_without_crashing
run_test test_ciql_busy_fleet_backlog_not_starved
run_test test_ciql_zero_queued_items_empty_categories_no_error
run_test test_ciql_zero_new_api_calls_exact_count
run_test test_ciql_malformed_queued_run_skipped_not_crashing
run_test test_ciql_pr_event_named_staging_stays_pr_not_staging_deploy
run_test test_ciql_non_deploy_release_cleanup_name_stays_other
