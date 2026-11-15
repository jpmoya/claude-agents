# Issue #658 round 4 (PR #667 review finding 2) — infra/ci-runners/ci-queue-collect.sh's sticky
# cap must evict an already-resolved busy-runner link ONLY when a real competing busy runner
# needs the room, never just because an idle-runner rotation candidate exists. Companion to
# test-ciqueue-busy-link-backlog.sh's round-1/round-2 cases (that file has no round-3-specific
# case of its own — round 3 only ever showed up in the collector's comment block, never in a
# test); this file adds the two round-4 boundary cases:
#   - a genuinely-competing multi-busy-runner backlog that still resolves (round-3's own fix,
#     unchanged by round 4 — proves round 4 didn't reintroduce the round-3 starvation bug)
#   - several busy runners plus a never-busy rotation candidate, where the links must hold
#     indefinitely once resolved (the round-4 fix itself — this is what round 3's unconditional
#     cap broke)
#
# No live network calls: same CI_QUEUE_FIXTURE_DIR seam as the other ci-queue-collect.sh suites.
# Self-contained, no load-order dependency. Prefix _ciqblsc_ / CIQBLSC. Placeholder repo name.

HERE_CIQBLSC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT_CIQBLSC=$(cd "$HERE_CIQBLSC/../../.." && pwd)
COLLECTOR_CIQBLSC="$REPO_ROOT_CIQBLSC/infra/ci-runners/ci-queue-collect.sh"
CIQBLSC_REPO="example-owner/busy-link-backlog"
CIQBLSC_SAFE="example-owner__busy-link-backlog"

# _ciqblsc_runners_fixtures <dir> <busy-runner-names-csv> <idle-runner-names-csv> — same shape as
# test-ciqueue-busy-link-backlog.sh's helper (all runners in the org list, repo-level list empty).
_ciqblsc_runners_fixtures() {
  local dir=$1 busy_csv=$2 idle_csv=$3 id=1 runners='[' n name
  if [ -n "$busy_csv" ]; then
    IFS=',' read -ra _ciqblsc_bnames <<< "$busy_csv"
    for name in "${_ciqblsc_bnames[@]}"; do
      runners="$runners{\"id\":$id,\"name\":\"$name\",\"status\":\"online\",\"busy\":true},"
      id=$((id + 1))
    done
  fi
  if [ -n "$idle_csv" ]; then
    IFS=',' read -ra _ciqblsc_inames <<< "$idle_csv"
    for name in "${_ciqblsc_inames[@]}"; do
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

_ciqblsc_queued_runs() {  # <dir> <id...> — 7 queued runs (above cap=5), one queued job each.
  local dir=$1; shift
  local runs='[' id
  for id in "$@"; do
    runs="$runs{\"id\":$id,\"name\":\"CI\",\"event\":\"schedule\",\"actor\":{\"login\":\"someone\"}},"
    echo "{\"jobs\":[{\"id\":$((id + 90000)),\"status\":\"queued\",\"created_at\":\"2026-01-01T00:00:00Z\"}]}" > "$dir/jobs-$id.json"
  done
  runs="${runs%,}]"
  echo "{\"workflow_runs\":$runs}" > "$dir/runs-${CIQBLSC_SAFE}-queued.json"
}

# _ciqblsc_inprogress_run <dir> <run-id> <pr-number> <runner-name> -> prints the run object (job
# fixture written as a side effect, same convention as test-ciqueue-busy-link-backlog.sh).
_ciqblsc_inprogress_run() {
  local dir=$1 id=$2 pr=$3 runner=$4
  echo "{\"jobs\":[{\"id\":$((id + 90000)),\"status\":\"in_progress\",\"created_at\":\"2026-01-01T00:00:00Z\",\"runner_name\":\"$runner\"}]}" > "$dir/jobs-$id.json"
  printf '{"id":%d,"name":"CI","event":"push","actor":{"login":"someone"},"pull_requests":[{"number":%d}]}' "$id" "$pr"
}

# _ciqblsc_inprogress_run_idle <dir> <run-id> <runner-name> -> like above but no pull_requests, so
# it never resolves a current_job even when its runner is online (used for the never-busy
# rotation candidate — its runner here is explicitly idle, so it can never go sticky either way).
_ciqblsc_inprogress_run_idle() {
  local dir=$1 id=$2 runner=$3
  echo "{\"jobs\":[{\"id\":$((id + 90000)),\"status\":\"in_progress\",\"created_at\":\"2026-01-01T00:00:00Z\",\"runner_name\":\"$runner\"}]}" > "$dir/jobs-$id.json"
  printf '{"id":%d,"name":"CI","event":"push","actor":{"login":"someone"},"pull_requests":[]}' "$id"
}

_ciqblsc_repos_file() {
  local dir=$1 f
  f="$dir/repos.txt"
  printf '%s\n' "$CIQBLSC_REPO" > "$f"
  printf '%s' "$f"
}

_ciqblsc_run() {  # <pipe> <fixdir> <reposfile> -> sets CIQBLSC_OUT / CIQBLSC_CALLS, returns exit code
  local pipe=$1 fixdir=$2 reposfile=$3 rc
  ( CI_QUEUE_FORCE=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" \
    CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" CI_QUEUE_SAMPLES_FILE="$pipe/ci-runner-samples.jsonl" \
    CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_REPOS_FILE="$reposfile" \
    CI_QUEUE_FIXTURE_DIR="$fixdir" \
    bash "$COLLECTOR_CIQBLSC" )
  rc=$?
  CIQBLSC_OUT=$(cat "$pipe/status-ci.json" 2>/dev/null)
  CIQBLSC_CALLS=$(cat "$pipe/calls.log" 2>/dev/null)
  return "$rc"
}

# test_ciqblsc_five_busy_runners_exceed_budget_still_resolves_by_cycle2 — round-3's own case:
# cap=5, 7 queued -> qreserve=1, pcount=5, busy=5 -> r=min(5,5,4)=4, psel=4. 5 busy runners
# competing for a 4-slot budget is a genuine hard bound (NOT a round-4 regression target) — the
# budget physically cannot resolve all 5 in one cycle. This only asserts the one guarantee round 3
# established and round 4 must not break: the run that misses cycle 1 is NOT starved forever, it
# resolves by cycle 2 at the latest (ascending rotation reaches it next).
test_ciqblsc_five_busy_runners_exceed_budget_still_resolves_by_cycle2() {
  local pipe fixdir reposfile rc r601 r602 r603 r604 r605 cj1 cj2
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqblsc_repos_file "$fixdir")
  _ciqblsc_runners_fixtures "$fixdir" "gha-aa-1-101,gha-bb-1-102,gha-cc-1-103,gha-dd-1-104,gha-ee-1-105" ""
  r601=$(_ciqblsc_inprogress_run "$fixdir" 601 1 "gha-aa-1-101")
  r602=$(_ciqblsc_inprogress_run "$fixdir" 602 2 "gha-bb-1-102")
  r603=$(_ciqblsc_inprogress_run "$fixdir" 603 3 "gha-cc-1-103")
  r604=$(_ciqblsc_inprogress_run "$fixdir" 604 4 "gha-dd-1-104")
  r605=$(_ciqblsc_inprogress_run "$fixdir" 605 5 "gha-ee-1-105")
  echo "{\"workflow_runs\":[$r601,$r602,$r603,$r604,$r605]}" > "$fixdir/runs-${CIQBLSC_SAFE}-in_progress.json"
  _ciqblsc_queued_runs "$fixdir" 501 502 503 504 505 506 507

  _ciqblsc_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  assert_exit0 "$rc" "cycle1 still exits 0" || { rm -rf "$pipe" "$fixdir"; return 1; }
  assert_eq "$CIQBLSC_CALLS" "9" "cycle1: calls stay at 2+2+5=9" || { rm -rf "$pipe" "$fixdir"; return 1; }
  cj1=$(printf '%s' "$CIQBLSC_OUT" | jq -c '.runners[] | select(.name=="gha-ee-1-105") | .current_job')

  _ciqblsc_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  cj2=$(printf '%s' "$CIQBLSC_OUT" | jq -c '.runners[] | select(.name=="gha-ee-1-105") | .current_job')
  local calls=$CIQBLSC_CALLS
  rm -rf "$pipe" "$fixdir"
  assert_exit0 "$rc" "cycle2 still exits 0" || return 1
  assert_eq "$calls" "9" "cycle2: calls stay at 2+2+5=9" || return 1
  # The 5th busy runner (ee) is the one a 4-slot budget cannot fit alongside the other 4 on cycle
  # 1 (ascending rotation order visits aa/bb/cc/dd first); it must not still be null by cycle 2.
  assert_eq "${cj1:-null}" "null" "sanity: ee's run (highest id) misses the 4-slot budget on cycle 1" || return 1
  assert_eq "$cj2" '{"repo":"example-owner/busy-link-backlog","run_id":605,"pr_url":"https://github.com/example-owner/busy-link-backlog/pull/5"}' \
    "AC (round 3, unchanged by round 4): the 5th busy runner resolves by cycle 2, never starved" || return 1
}

# test_ciqblsc_four_busy_runners_plus_never_busy_candidate_hold_stably — the round-4 fix itself:
# 4 busy runners (gha-aa..dd) + 1 run sitting on a genuinely idle runner (gha-ee, never resolves).
# cap=5, 7 queued -> qreserve=1, pcount=5, busy=4 -> r=min(5,4,4)=4, psel=4: all 4 busy links fit
# the budget exactly, but the idle run is a permanent rotation candidate alongside them. Round 3's
# unconditional cap (sticky capped to psel-1 whenever ANY rotation candidate exists) would evict
# one of the 4 resolved links every single cycle forever to make room for probing the idle run —
# pure flicker with nothing ever found. Round 4 must hold all 4 stably once resolved.
test_ciqblsc_four_busy_runners_plus_never_busy_candidate_hold_stably() {
  local pipe fixdir reposfile rc r600 r601 r602 r603 r604 i resolved_at=0 all_present
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqblsc_repos_file "$fixdir")
  _ciqblsc_runners_fixtures "$fixdir" "gha-aa-1-101,gha-bb-1-102,gha-cc-1-103,gha-dd-1-104" "gha-ee-1-105"
  r600=$(_ciqblsc_inprogress_run_idle "$fixdir" 600 "gha-ee-1-105")
  r601=$(_ciqblsc_inprogress_run "$fixdir" 601 1 "gha-aa-1-101")
  r602=$(_ciqblsc_inprogress_run "$fixdir" 602 2 "gha-bb-1-102")
  r603=$(_ciqblsc_inprogress_run "$fixdir" 603 3 "gha-cc-1-103")
  r604=$(_ciqblsc_inprogress_run "$fixdir" 604 4 "gha-dd-1-104")
  echo "{\"workflow_runs\":[$r600,$r601,$r602,$r603,$r604]}" > "$fixdir/runs-${CIQBLSC_SAFE}-in_progress.json"
  _ciqblsc_queued_runs "$fixdir" 501 502 503 504 505 506 507

  for i in 1 2 3 4; do
    _ciqblsc_run "$pipe" "$fixdir" "$reposfile"; rc=$?
    assert_exit0 "$rc" "cycle $i still exits 0" || { rm -rf "$pipe" "$fixdir"; return 1; }
    assert_eq "$CIQBLSC_CALLS" "9" "cycle $i: calls stay at 2+2+5=9" || { rm -rf "$pipe" "$fixdir"; return 1; }
    all_present=$(printf '%s' "$CIQBLSC_OUT" | jq -r '
      [.runners[] | select(.name|test("^gha-(aa|bb|cc|dd)-1-10")) | (.current_job // null)]
      | all(. != null)')
    if [ "$resolved_at" -eq 0 ] && [ "$all_present" = "true" ]; then resolved_at=$i; fi
  done
  assert_ne "$resolved_at" "0" "AC: all 4 busy-runner links resolve within 4 cycles" || { rm -rf "$pipe" "$fixdir"; return 1; }

  # 4 further cycles: all 4 links must still be present every single time (no flicker from the
  # permanently-idle rotation candidate competing for the budget).
  for i in 5 6 7 8; do
    _ciqblsc_run "$pipe" "$fixdir" "$reposfile"; rc=$?
    all_present=$(printf '%s' "$CIQBLSC_OUT" | jq -r '
      [.runners[] | select(.name|test("^gha-(aa|bb|cc|dd)-1-10")) | (.current_job // null)]
      | all(. != null)')
    assert_exit0 "$rc" "cycle $i still exits 0" || { rm -rf "$pipe" "$fixdir"; return 1; }
    assert_eq "$all_present" "true" "AC (anti-flicker): all 4 links still hold on cycle $i" || { rm -rf "$pipe" "$fixdir"; return 1; }
  done
  rm -rf "$pipe" "$fixdir"
}

# test_ciqblsc_single_busy_runner_many_never_busy_candidates_hold_5_cycles — the exact case named
# in the ticket: ONE busy runner (resolves cycle 1 — cap=5, 7 queued -> qreserve=1, pcount=5,
# busy=1 -> r=min(5,1,4)=1, psel=1, so the single slot goes straight to the busy run since it is
# the lowest id and cursor starts at 0) plus 4 OTHER in_progress runs that sit on a genuinely idle
# runner and so can never go sticky themselves. Asserts the link holds for 5 consecutive cycles
# after resolving, not just the "one further cycle" the round-2 test above checks.
test_ciqblsc_single_busy_runner_many_never_busy_candidates_hold_5_cycles() {
  local pipe fixdir reposfile rc r601 r602 r603 r604 r605 i cj calls
  pipe=$(mktemp -d); fixdir=$(mktemp -d); reposfile=$(_ciqblsc_repos_file "$fixdir")
  _ciqblsc_runners_fixtures "$fixdir" "gha-aa-1-101" "gha-zz-1-199"
  r601=$(_ciqblsc_inprogress_run "$fixdir" 601 1 "gha-aa-1-101")
  r602=$(_ciqblsc_inprogress_run_idle "$fixdir" 602 "gha-zz-1-199")
  r603=$(_ciqblsc_inprogress_run_idle "$fixdir" 603 "gha-zz-1-199")
  r604=$(_ciqblsc_inprogress_run_idle "$fixdir" 604 "gha-zz-1-199")
  r605=$(_ciqblsc_inprogress_run_idle "$fixdir" 605 "gha-zz-1-199")
  echo "{\"workflow_runs\":[$r601,$r602,$r603,$r604,$r605]}" > "$fixdir/runs-${CIQBLSC_SAFE}-in_progress.json"
  _ciqblsc_queued_runs "$fixdir" 501 502 503 504 505 506 507

  _ciqblsc_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  cj=$(printf '%s' "$CIQBLSC_OUT" | jq -c '.runners[] | select(.name=="gha-aa-1-101") | .current_job')
  assert_exit0 "$rc" "cycle1 still exits 0" || { rm -rf "$pipe" "$fixdir"; return 1; }
  assert_eq "$CIQBLSC_CALLS" "9" "cycle1: calls stay at 2+2+5=9" || { rm -rf "$pipe" "$fixdir"; return 1; }
  assert_eq "$cj" '{"repo":"example-owner/busy-link-backlog","run_id":601,"pr_url":"https://github.com/example-owner/busy-link-backlog/pull/1"}' \
    "AC: the single busy runner resolves on cycle 1 (lowest id, cursor starts at 0)" || { rm -rf "$pipe" "$fixdir"; return 1; }

  for i in 2 3 4 5 6; do
    _ciqblsc_run "$pipe" "$fixdir" "$reposfile"; rc=$?
    cj=$(printf '%s' "$CIQBLSC_OUT" | jq -c '.runners[] | select(.name=="gha-aa-1-101") | .current_job')
    calls=$CIQBLSC_CALLS
    assert_exit0 "$rc" "cycle $i still exits 0" || { rm -rf "$pipe" "$fixdir"; return 1; }
    assert_eq "$calls" "9" "cycle $i: calls stay at 2+2+5=9" || { rm -rf "$pipe" "$fixdir"; return 1; }
    assert_eq "$cj" '{"repo":"example-owner/busy-link-backlog","run_id":601,"pr_url":"https://github.com/example-owner/busy-link-backlog/pull/1"}' \
      "AC (anti-flicker): still resolved on cycle $i, 4 never-busy candidates never evict it" || { rm -rf "$pipe" "$fixdir"; return 1; }
  done
  rm -rf "$pipe" "$fixdir"
}

run_test test_ciqblsc_five_busy_runners_exceed_budget_still_resolves_by_cycle2
run_test test_ciqblsc_four_busy_runners_plus_never_busy_candidate_hold_stably
run_test test_ciqblsc_single_busy_runner_many_never_busy_candidates_hold_5_cycles
