# Issue #658 round 4 (PR #667 code-review MEDIUM) — infra/ci-runners/ci-queue-collect.sh's sticky
# cap must be scoped to THIS repo's own busy-runner count, never the global online+busy-runner
# count shared across every repo (`$busy`), or a busy runner in a completely different repo keeps
# an unrelated repo's already-resolved link flickering forever (reviewer-reproduced: a repo with
# 4 resolved busy-runner links plus a 5th busy runner elsewhere evicts one of the 4 every cycle,
# with no real competitor in that repo at all). This exercises `collect_once`'s multi-repo loop
# directly (CI_QUEUE_REPOS_FILE listing two repos), not just a single `_ciq_collect_repo` call —
# the leak is specifically in how collect_once computed the busy count it handed to each repo.
#
# No live network calls: same CI_QUEUE_FIXTURE_DIR seam as the other ci-queue-collect.sh suites.
# Self-contained, no load-order dependency. Prefix _ciqblxr_ / CIQBLXR. Placeholder repo names.

HERE_CIQBLXR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT_CIQBLXR=$(cd "$HERE_CIQBLXR/../../.." && pwd)
COLLECTOR_CIQBLXR="$REPO_ROOT_CIQBLXR/infra/ci-runners/ci-queue-collect.sh"
CIQBLXR_REPO_A="example-owner/busy-link-backlog"
CIQBLXR_REPO_B="example-owner/busy-link-backlog-b"
CIQBLXR_SAFE_A="example-owner__busy-link-backlog"
CIQBLXR_SAFE_B="example-owner__busy-link-backlog-b"

_ciqblxr_mkbusy() {  # <dir> <run-id> <runner-name> <pr-number> -> prints the run object
  local dir=$1 id=$2 runner=$3 pr=$4
  echo "{\"jobs\":[{\"id\":$((id + 90000)),\"status\":\"in_progress\",\"created_at\":\"2026-01-01T00:00:00Z\",\"runner_name\":\"$runner\"}]}" > "$dir/jobs-$id.json"
  printf '{"id":%d,"name":"CI","event":"push","actor":{"login":"someone"},"pull_requests":[{"number":%d}]}' "$id" "$pr"
}

_ciqblxr_mkidle() {  # <dir> <run-id> <runner-name> -> prints the run object (no pull_requests)
  local dir=$1 id=$2 runner=$3
  echo "{\"jobs\":[{\"id\":$((id + 90000)),\"status\":\"in_progress\",\"created_at\":\"2026-01-01T00:00:00Z\",\"runner_name\":\"$runner\"}]}" > "$dir/jobs-$id.json"
  printf '{"id":%d,"name":"CI","event":"push","actor":{"login":"someone"},"pull_requests":[]}' "$id"
}

_ciqblxr_run() {  # <pipe> <fixdir> <reposfile> -> sets CIQBLXR_OUT / CIQBLXR_CALLS, returns exit code
  local pipe=$1 fixdir=$2 reposfile=$3 rc
  ( CI_QUEUE_FORCE=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" \
    CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_REPOS_FILE="$reposfile" \
    CI_QUEUE_FIXTURE_DIR="$fixdir" \
    bash "$COLLECTOR_CIQBLXR" )
  rc=$?
  CIQBLXR_OUT=$(cat "$pipe/status-ci.json" 2>/dev/null)
  CIQBLXR_CALLS=$(cat "$pipe/calls.log" 2>/dev/null)
  return "$rc"
}

# test_ciqblxr_busy_runner_in_other_repo_never_flickers_this_repos_resolved_links — the exact
# code-review reproduction: repo A has 4 busy runners (resolved links) + 4 idle rotation
# candidates (cap=5, 7 queued -> qreserve=1, pcount=8, GLOBAL busy=5 (4 in A + 1 in B) ->
# r=min(8,5,4)=4, psel=4 — all 4 of A's own busy runners fit exactly). Repo B has a single,
# unrelated, always-busy runner with its own in_progress run — it exists ONLY to inflate the
# GLOBAL busy count above repo A's own true count. Before the fix, A's cap used that global count
# directly and could never stop capping (4 resolved < 5 global, forever); after the fix A's cap
# uses a repo-scoped count that settles to 4 once B's own runner resolves to B, so A's links must
# hold stably for every cycle in this run, with zero exceptions.
test_ciqblxr_busy_runner_in_other_repo_never_flickers_this_repos_resolved_links() {
  local pipe fixdir reposfile rc i rA1 rA2 rA3 rA4 rA5 rA6 rA7 rA8 rB1 all_present
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  reposfile="$fixdir/repos.txt"
  printf '%s\n%s\n' "$CIQBLXR_REPO_A" "$CIQBLXR_REPO_B" > "$reposfile"

  cat > "$fixdir/runners-org.json" << 'JSON'
{"total_count":6,"runners":[
{"id":1,"name":"gha-aa-1-101","status":"online","busy":true},
{"id":2,"name":"gha-bb-1-102","status":"online","busy":true},
{"id":3,"name":"gha-cc-1-103","status":"online","busy":true},
{"id":4,"name":"gha-dd-1-104","status":"online","busy":true},
{"id":5,"name":"gha-ee-1-105","status":"online","busy":false},
{"id":6,"name":"gha-zz-1-900","status":"online","busy":true}
]}
JSON
  echo '{"total_count":0,"runners":[]}' > "$fixdir/runners-repo.json"

  local runs='[' id
  for id in 501 502 503 504 505 506 507; do
    runs="$runs{\"id\":$id,\"name\":\"CI\",\"event\":\"schedule\",\"actor\":{\"login\":\"someone\"}},"
    echo "{\"jobs\":[{\"id\":$((id + 90000)),\"status\":\"queued\",\"created_at\":\"2026-01-01T00:00:00Z\"}]}" > "$fixdir/jobs-$id.json"
  done
  runs="${runs%,}]"
  echo "{\"workflow_runs\":$runs}" > "$fixdir/runs-${CIQBLXR_SAFE_A}-queued.json"
  echo '{"workflow_runs":[]}' > "$fixdir/runs-${CIQBLXR_SAFE_B}-queued.json"

  rA1=$(_ciqblxr_mkbusy "$fixdir" 601 "gha-aa-1-101" 1)
  rA2=$(_ciqblxr_mkbusy "$fixdir" 602 "gha-bb-1-102" 2)
  rA3=$(_ciqblxr_mkbusy "$fixdir" 603 "gha-cc-1-103" 3)
  rA4=$(_ciqblxr_mkbusy "$fixdir" 604 "gha-dd-1-104" 4)
  rA5=$(_ciqblxr_mkidle "$fixdir" 605 "gha-ee-1-105")
  rA6=$(_ciqblxr_mkidle "$fixdir" 606 "gha-ee-1-105")
  rA7=$(_ciqblxr_mkidle "$fixdir" 607 "gha-ee-1-105")
  rA8=$(_ciqblxr_mkidle "$fixdir" 608 "gha-ee-1-105")
  echo "{\"workflow_runs\":[$rA1,$rA2,$rA3,$rA4,$rA5,$rA6,$rA7,$rA8]}" > "$fixdir/runs-${CIQBLXR_SAFE_A}-in_progress.json"

  rB1=$(_ciqblxr_mkbusy "$fixdir" 701 "gha-zz-1-900" 99)
  echo "{\"workflow_runs\":[$rB1]}" > "$fixdir/runs-${CIQBLXR_SAFE_B}-in_progress.json"

  for i in 1 2 3 4 5 6 7 8; do
    _ciqblxr_run "$pipe" "$fixdir" "$reposfile"; rc=$?
    assert_exit0 "$rc" "cycle $i still exits 0" || { rm -rf "$pipe" "$fixdir"; return 1; }
    all_present=$(printf '%s' "$CIQBLXR_OUT" | jq -r '
      [.runners[] | select(.name|test("^gha-(aa|bb|cc|dd)-1-10")) | (.current_job // null)]
      | all(. != null)')
    assert_eq "$all_present" "true" \
      "AC (cross-repo anti-flicker): all 4 of repo A own resolved links hold on cycle $i despite a busy runner in repo B" \
      || { rm -rf "$pipe" "$fixdir"; return 1; }
  done
  rm -rf "$pipe" "$fixdir"
}

run_test test_ciqblxr_busy_runner_in_other_repo_never_flickers_this_repos_resolved_links
