# Issue #658 — harden infra/ci-runners/ci-queue-collect.sh's busy-runner-to-job matching under a
# deep queued backlog. Root cause (PM's analysis on the issue): `_ciq_collect_repo` walks
# queued-source runs before any in_progress-source run (the #645(b) fix, which protects `oldest`
# from being starved by in_progress runs), then stops at MAX_RUN_LOOKUPS_PER_REPO total job
# lookups. When a repo's queued backlog alone is >= the cap, the cap is exhausted before the
# in_progress run that holds a busy runner's job is ever looked up, so `current_job` is missing
# for that runner THIS cycle even though it's genuinely busy.
#
# No live network calls: `gh api` is replaced by the collector's own CI_QUEUE_FIXTURE_DIR seam
# (same pattern as test-ciqueue-collector.sh / test-ciqueue-oldest-truncation.sh). Self-contained:
# does not depend on load order relative to any other test-*.sh file. Prefix _ciqbl_ / CIQBL.
# Placeholder repo name only (public repo), same convention as test-ciqueue-oldest-truncation.sh.
#
# Safe to source into run-tests.sh's shared shell: no top-level `exit`, every helper prefixed
# _ciqbl_, every test function declares its own locals.

HERE_CIQBL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT_CIQBL=$(cd "$HERE_CIQBL/../../.." && pwd)
COLLECTOR_CIQBL="$REPO_ROOT_CIQBL/infra/ci-runners/ci-queue-collect.sh"
CIQBL_REPO="example-owner/busy-link-backlog"
CIQBL_SAFE="example-owner__busy-link-backlog"

# _ciqbl_runners_fixtures <dir> <busy-runner-names-csv> <idle-runner-names-csv> — every name in
# <busy-runner-names-csv> is registered online+busy; every name in <idle-runner-names-csv> is
# registered online, not busy. All in the org list (repo-level list left empty) so runners_busy
# equals exactly the busy-name count.
_ciqbl_runners_fixtures() {
  local dir=$1 busy_csv=$2 idle_csv=$3 id=1 runners='[' n name
  if [ -n "$busy_csv" ]; then
    IFS=',' read -ra _ciqbl_bnames <<< "$busy_csv"
    for name in "${_ciqbl_bnames[@]}"; do
      runners="$runners{\"id\":$id,\"name\":\"$name\",\"status\":\"online\",\"busy\":true},"
      id=$((id + 1))
    done
  fi
  if [ -n "$idle_csv" ]; then
    IFS=',' read -ra _ciqbl_inames <<< "$idle_csv"
    for name in "${_ciqbl_inames[@]}"; do
      runners="$runners{\"id\":$id,\"name\":\"$name\",\"status\":\"online\",\"busy\":false},"
      id=$((id + 1))
    done
  fi
  runners="${runners%,}]"
  [ "$runners" = ']' ] && runners='[]'
  n=$((id - 1))
  echo "{\"total_count\":$n,\"runners\":$runners}" > "$dir/runners-org.json"
  echo '{"total_count":0,"runners":[]}' > "$dir/runners-repo.json"
}

# _ciqbl_queued_runs <dir> <id...> — writes a queued-run fixture (with one queued job each) for
# every given id, oldest (lowest id) = earliest created_at, so a stable "oldest" story holds.
_ciqbl_queued_runs() {
  local dir=$1; shift
  local runs='[' id ts=100
  for id in "$@"; do
    runs="$runs{\"id\":$id,\"name\":\"CI\",\"event\":\"schedule\",\"actor\":{\"login\":\"someone\"}},"
    echo "{\"jobs\":[{\"id\":$((id + 90000)),\"status\":\"queued\",\"created_at\":\"2026-01-01T00:$(printf '%02d' $((ts % 60))):00Z\"}]}" > "$dir/jobs-$id.json"
    ts=$((ts + 1))
  done
  runs="${runs%,}]"
  echo "{\"workflow_runs\":$runs}" > "$dir/runs-${CIQBL_SAFE}-queued.json"
}

# _ciqbl_inprogress_run <dir> <run-id> <pr-number> <runner-name> — one in_progress run holding a
# single in_progress job assigned to <runner-name>, with pull_requests:[{number:<pr-number>}].
_ciqbl_inprogress_run_fixture() {
  local dir=$1 id=$2 pr=$3 runner=$4
  echo "{\"jobs\":[{\"id\":$((id + 90000)),\"status\":\"in_progress\",\"created_at\":\"2026-01-01T00:00:00Z\",\"runner_name\":\"$runner\"}]}" > "$dir/jobs-$id.json"
  printf '{"id":%d,"name":"CI","event":"push","actor":{"login":"someone"},"pull_requests":[{"number":%d}]}' "$id" "$pr"
}

_ciqbl_repos_file() {  # <dir> -> prints a path to a repos file listing exactly $CIQBL_REPO
  local dir=$1 f
  f="$dir/repos.txt"
  printf '%s\n' "$CIQBL_REPO" > "$f"
  printf '%s' "$f"
}

_ciqbl_run() {  # <pipe> <fixdir> <reposfile> -> sets CIQBL_OUT / CIQBL_CALLS, returns exit code
  local pipe=$1 fixdir=$2 reposfile=$3 rc
  ( CI_QUEUE_FORCE=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" \
    CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_REPOS_FILE="$reposfile" \
    CI_QUEUE_FIXTURE_DIR="$fixdir" \
    bash "$COLLECTOR_CIQBL" )
  rc=$?
  CIQBL_OUT=$(cat "$pipe/status-ci.json" 2>/dev/null)
  CIQBL_CALLS=$(cat "$pipe/calls.log" 2>/dev/null)
  return "$rc"
}

test_ciqbl_at_cap_queued_plus_one_busy_inprogress_run_resolves_link() {
  local pipe fixdir reposfile rc run601 runs
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqbl_repos_file "$fixdir")
  _ciqbl_runners_fixtures "$fixdir" "gha-zz-1-101" ""
  # 5 queued runs (exactly MAX_RUN_LOOKUPS_PER_REPO) + 1 in_progress run on the one busy runner.
  run601=$(_ciqbl_inprogress_run_fixture "$fixdir" 601 42 "gha-zz-1-101")
  runs=$(_ciqbl_queued_runs "$fixdir" 501 502 503 504 505)
  echo "{\"workflow_runs\":[$run601]}" > "$fixdir/runs-${CIQBL_SAFE}-in_progress.json"

  _ciqbl_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  local current_job calls
  current_job=$(printf '%s' "$CIQBL_OUT" | jq -c '.runners[] | select(.name=="gha-zz-1-101") | .current_job')
  calls=$CIQBL_CALLS
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$current_job" '{"repo":"example-owner/busy-link-backlog","run_id":601,"pr_url":"https://github.com/example-owner/busy-link-backlog/pull/42"}' \
    "AC: a busy runner's current_job resolves even with a queued backlog exactly at the cap" || return 1
  assert_eq "$calls" "9" "AC2: total calls stay at 2+2+5=9 — no new gh api calls" || return 1
}

test_ciqbl_above_cap_queued_plus_one_busy_inprogress_run_resolves_link() {
  local pipe fixdir reposfile rc run601
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqbl_repos_file "$fixdir")
  _ciqbl_runners_fixtures "$fixdir" "gha-zz-1-101" ""
  # 7 queued runs (ABOVE MAX_RUN_LOOKUPS_PER_REPO) + 1 in_progress run on the one busy runner —
  # the exact deep-backlog scenario from the issue: under the old code, all 5 lookups would go to
  # queued runs and the in_progress run holding the busy runner's job would never be looked up.
  run601=$(_ciqbl_inprogress_run_fixture "$fixdir" 601 42 "gha-zz-1-101")
  _ciqbl_queued_runs "$fixdir" 501 502 503 504 505 506 507
  echo "{\"workflow_runs\":[$run601]}" > "$fixdir/runs-${CIQBL_SAFE}-in_progress.json"

  _ciqbl_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  local current_job calls
  current_job=$(printf '%s' "$CIQBL_OUT" | jq -c '.runners[] | select(.name=="gha-zz-1-101") | .current_job')
  calls=$CIQBL_CALLS
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$current_job" '{"repo":"example-owner/busy-link-backlog","run_id":601,"pr_url":"https://github.com/example-owner/busy-link-backlog/pull/42"}' \
    "AC: a busy runner's current_job reliably resolves even with a queued backlog above the cap (the bug)" || return 1
  assert_eq "$calls" "9" "AC2: total calls still stay at 2+2+5=9 — the fix reallocates lookups, it never adds any" || return 1
}

test_ciqbl_two_busy_runners_plus_deep_queue_both_resolve() {
  local pipe fixdir reposfile rc run601 run602
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqbl_repos_file "$fixdir")
  _ciqbl_runners_fixtures "$fixdir" "gha-aa-1-101,gha-bb-2-102" ""
  run601=$(_ciqbl_inprogress_run_fixture "$fixdir" 601 42 "gha-aa-1-101")
  run602=$(_ciqbl_inprogress_run_fixture "$fixdir" 602 43 "gha-bb-2-102")
  _ciqbl_queued_runs "$fixdir" 501 502 503 504 505 506
  echo "{\"workflow_runs\":[$run601,$run602]}" > "$fixdir/runs-${CIQBL_SAFE}-in_progress.json"

  _ciqbl_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  local cj1 cj2 calls
  cj1=$(printf '%s' "$CIQBL_OUT" | jq -c '.runners[] | select(.name=="gha-aa-1-101") | .current_job')
  cj2=$(printf '%s' "$CIQBL_OUT" | jq -c '.runners[] | select(.name=="gha-bb-2-102") | .current_job')
  calls=$CIQBL_CALLS
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$cj1" '{"repo":"example-owner/busy-link-backlog","run_id":601,"pr_url":"https://github.com/example-owner/busy-link-backlog/pull/42"}' \
    "both busy runners resolve despite a deep queue (runner 1)" || return 1
  assert_eq "$cj2" '{"repo":"example-owner/busy-link-backlog","run_id":602,"pr_url":"https://github.com/example-owner/busy-link-backlog/pull/43"}' \
    "both busy runners resolve despite a deep queue (runner 2)" || return 1
  assert_eq "$calls" "9" "AC2: total calls still stay at 2+2+5=9 even with 2 in_progress runs reserved" || return 1
}

test_ciqbl_deep_queue_nobody_busy_unaffected() {
  local pipe fixdir reposfile rc
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqbl_repos_file "$fixdir")
  _ciqbl_runners_fixtures "$fixdir" "" "gha-yy-1-99"
  _ciqbl_queued_runs "$fixdir" 501 502 503 504 505 506
  echo '{"workflow_runs":[]}' > "$fixdir/runs-${CIQBL_SAFE}-in_progress.json"

  _ciqbl_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  local current_job calls
  current_job=$(printf '%s' "$CIQBL_OUT" | jq -c '.runners[] | select(.name=="gha-yy-1-99") | .current_job')
  calls=$CIQBL_CALLS
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "${current_job:-null}" "null" "contrast: nobody busy -> no current_job, unchanged by the reservation logic" || return 1
  assert_eq "$calls" "9" "contrast: deep queue alone (no in_progress contention) still costs 2+2+5=9, same as before the fix" || return 1
}

run_test test_ciqbl_at_cap_queued_plus_one_busy_inprogress_run_resolves_link
run_test test_ciqbl_above_cap_queued_plus_one_busy_inprogress_run_resolves_link
run_test test_ciqbl_two_busy_runners_plus_deep_queue_both_resolve
run_test test_ciqbl_deep_queue_nobody_busy_unaffected
