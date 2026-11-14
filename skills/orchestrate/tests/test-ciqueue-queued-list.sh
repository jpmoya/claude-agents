# Issue #657 — CI queue collector: queued-PR list + prod-merge category detection.
#
# Covers:
#   - _ciq_categorize's 5-rule cascade splitting the old single `deploy_release` bucket into
#     `prod_deploy` / `staging_deploy` / `deploy_release` (JP-ruled cascade, see the issue's
#     delivery-lead JP CONFIRMED comment), nested INSIDE the pre-existing deploy|release name
#     gate (dependabot/pr/other precedence unchanged — negative tests below prove the nesting).
#   - `ci_queue.categories[].queued[]`: a capped, per-category list of the actual queued runs
#     behind each category's count (repo, run_id, pr_url, title?, queued_at), built from data
#     already fetched for categories[]/current_job (zero new `gh api` calls — proven by an exact
#     call-count assertion), deduped GLOBALLY by run id (the scheduler/benjis-ops-tool repo-alias
#     double-fetch case).
#
# Self-contained: does not depend on test-ciqueue-collector.sh's helpers (load order between
# test-*.sh files is incidental, not a contract). Prefix _ciql_ / CIQL. Placeholder repo names
# only (public repo).

HERE_CIQL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT_CIQL=$(cd "$HERE_CIQL/../../.." && pwd)
COLLECTOR_CIQL="$REPO_ROOT_CIQL/infra/ci-runners/ci-queue-collect.sh"

_ciql_runners_fixtures() {  # <dir> — minimal valid runner-list fixtures (required before the repo loop runs)
  echo '{"total_count":1,"runners":[{"id":1,"busy":false}]}' > "$1/runners-org.json"
  echo '{"total_count":1,"runners":[{"id":2,"busy":false}]}' > "$1/runners-repo.json"
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
# -> writes a one-run queued fixture (queued run-list response + its job-lookup response, a
# single queued job at a fixed timestamp derived from the run id so ordering is deterministic)
# plus an empty in_progress list.
_ciql_one_run_fixture() {
  local dir=$1 safe=$2 id=$3 name=$4 branch=$5 event=$6 prnum=$7 pr_json='null' ts
  [ -z "$prnum" ] || pr_json="{\"number\":$prnum}"
  ts=$(printf '2026-01-01T%02d:00:00Z' "$((id % 24))")
  cat > "$dir/runs-${safe}-queued.json" <<EOF
{"workflow_runs":[{"id":$id,"name":"$name","head_branch":"$branch","event":"$event","actor":{"login":"someone"},"display_title":"$name #$id","pull_requests":[$pr_json]}]}
EOF
  # pull_requests must be [] not [null] when there's no PR.
  if [ "$prnum" = "" ]; then
    cat > "$dir/runs-${safe}-queued.json" <<EOF
{"workflow_runs":[{"id":$id,"name":"$name","head_branch":"$branch","event":"$event","actor":{"login":"someone"},"display_title":"$name #$id","pull_requests":[]}]}
EOF
  fi
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
  assert_eq "$(printf '%s' "$queued" | jq -c '.[0] | {repo, run_id, pr_url}')" \
    '{"repo":"example-owner/project-a","run_id":101,"pr_url":null}' \
    "queued[0] has repo/run_id/pr_url:null (no PR attached, item still included)" || return 1
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
  local pipe fixdir reposfile rc count queued_len i safe repo
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"

  # 3 repos x 5 queued runs each (MAX_RUN_LOOKUPS_PER_REPO=5), all same "other" category ->
  # 15 total queued jobs/runs, exceeding MAX_CI_QUEUE_QUEUED_ITEMS (10).
  local repos=""
  for i in 1 2 3; do
    repo="example-owner/cap-repo-$i"
    safe="example-owner__cap-repo-$i"
    repos="$repos $repo"
    local j rid
    for j in 1 2 3 4 5; do
      rid=$(( (i * 100) + j ))
      if [ "$j" = "1" ]; then
        cat > "$fixdir/runs-${safe}-queued.json" <<'HEADER'
{"workflow_runs":[
HEADER
      fi
      cat >> "$fixdir/runs-${safe}-queued.json" <<EOF
{"id":$rid,"name":"CI","head_branch":"feature/z","event":"schedule","actor":{"login":"someone"},"display_title":"CI #$rid","pull_requests":[]}$([ "$j" != "5" ] && echo ,)
EOF
      cat > "$fixdir/jobs-$rid.json" <<EOF
{"jobs":[{"id":$((rid + 90000)),"status":"queued","created_at":"$(printf '2026-01-01T%02d:00:00Z' "$((rid % 24))")"}]}
EOF
    done
    echo ']}' >> "$fixdir/runs-${safe}-queued.json"
    echo '{"workflow_runs":[]}' > "$fixdir/runs-${safe}-in_progress.json"
  done
  reposfile=$(_ciql_repos_file "$fixdir" $repos)

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  count=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="other") | .count')
  queued_len=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="other") | .queued | length')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0 even with more queued items than the cap" || return 1
  assert_eq "$count" "15" "categories[].count stays per-job/uncapped-by-display (15 jobs across 3 repos)" || return 1
  assert_eq "$queued_len" "10" "categories[].queued[] is truncated to MAX_CI_QUEUE_QUEUED_ITEMS (10), never erroring" || return 1
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
  # building queued[] adds zero calls: it reuses the same $run/$jobsjson already fetched above.
  assert_eq "$calls" "5" "the categorize split + queued[] list add zero new gh api calls" || return 1
}

test_ciql_malformed_created_at_skipped_not_crashing() {
  local pipe fixdir reposfile rc queued_len other_count
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciql_runners_fixtures "$fixdir"
  reposfile=$(_ciql_repos_file "$fixdir" "example-owner/project-garbled")
  echo '{"workflow_runs":[{"id":301,"name":"CI","head_branch":"feature/w","event":"schedule","actor":{"login":"someone"},"display_title":"CI #301","pull_requests":[]}]}' \
    > "$fixdir/runs-example-owner__project-garbled-queued.json"
  echo '{"workflow_runs":[]}' > "$fixdir/runs-example-owner__project-garbled-in_progress.json"
  # One job has a numeric (garbled) created_at instead of a string — must never crash the cycle.
  echo '{"jobs":[{"id":90301,"status":"queued","created_at":12345},{"id":90302,"status":"queued","created_at":"2026-01-01T00:00:00Z"}]}' \
    > "$fixdir/jobs-301.json"

  _ciql_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  other_count=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="other") | .count')
  queued_len=$(printf '%s' "$CIQL_OUT" | jq -c '.categories[] | select(.key=="other") | .queued | length')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "a garbled created_at on one job never aborts the cycle" || return 1
  assert_eq "$other_count" "1" "the run's one genuinely-valid queued job is still counted" || return 1
  assert_eq "$queued_len" "1" "the run still gets exactly one queued[] entry, using the valid job's timestamp" || return 1
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
run_test test_ciql_zero_queued_items_empty_categories_no_error
run_test test_ciql_zero_new_api_calls_exact_count
run_test test_ciql_malformed_created_at_skipped_not_crashing
run_test test_ciql_pr_event_named_staging_stays_pr_not_staging_deploy
run_test test_ciql_non_deploy_release_cleanup_name_stays_other
