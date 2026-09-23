# Regression for claude-agents#84 — the "marker progressed" branch reset `count` (the no-progress
# ceiling) but never `total` (the lifetime ceiling), so a healthy, advancing ticket that needed more
# than MAX_TOTAL poll cycles was parked and told JP it "made no progress" even on the same tick as a
# `[progress]` line (scheduler#793). Fix: reset `total` to 0 alongside `count` in that branch.
#
#   AC3  a progressing run is never escalated on the lifetime ceiling
#   AC4  a genuinely stuck run (marker unchanged, transient exit) still escalates — the #38 case
#   AC5  the no-progress ceiling (MAX_NO_PROGRESS) is untouched
#
# Reuses the sq_* helpers of test-supervisor-queued-not-counted.sh (same load trick as
# test-supervisor-fast-death-escalates.sh — run-tests.sh sources alphabetically, "queued-not-counted"
# is not loaded yet when this file runs). Issue 42 / placeholder repos only.

HERE_TR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "tr_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_TR/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f tr_real_run_test | sed '1s/tr_real_run_test/run_test/')"
fi

SQ_FAIL='**[code-reviewer] FAIL: 1 HIGH**'

# test_tr_3_progressing_run_never_escalates_on_lifetime_ceiling — AC3: .restarts total=5, count=1,
# last_marker = TESTS APPROVED; fake gh returns FAIL (a different marker) on a non-transient exit.
test_tr_3_progressing_run_never_escalates_on_lifetime_ceiling() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_seed_restarts 1 5 "$SQ_READY"
  sq_marker "$SQ_FAIL"
  sq_tick
  local log calls held total count
  log=$(sq_log); calls=$(gh_calls "$SQ_GH")
  held=$(sq_present "$SQ_PIPE/orch-42.held")
  total=$(sq_restarts_field total); count=$(sq_restarts_field count)
  sq_cleanup
  assert_contains "$log" "[progress] #42" "#84/AC3: progress logged" || return 1
  assert_contains "$log" "[queue-restart] #42" "#84/AC3: restart queued" || return 1
  assert_contains "$log" "count=1/3 total=1" "#84/AC3: total reset alongside count" || return 1
  assert_not_contains "$log" "[escalate] #42" "#84/AC3: no escalation on the lifetime ceiling" || return 1
  assert_eq "$held" "absent" "#84/AC3: not held" || return 1
  assert_not_contains "$calls" "issue comment" "#84/AC3: no supervisor NOTE posted" || return 1
  assert_eq "$total" "1" "#84/AC3: total=1 after the reset+increment" || return 1
  assert_eq "$count" "1" "#84/AC3: count=1 after the reset+increment" || return 1
}

# test_tr_4_stuck_run_with_unchanged_marker_still_escalates — AC4 (the #38 case): total=5, count=0,
# last_marker equal to the marker fake gh returns, transient (run under MIN_RUN_SECS) so count is
# untouched but total still climbs to MAX_TOTAL=6 and escalates.
test_tr_4_stuck_run_with_unchanged_marker_still_escalates() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 0 > "$SQ_PIPE/orch-42.launched-at"
  sq_seed_restarts 0 5 "$SQ_READY"
  sq_marker "$SQ_READY"
  sq_tick
  local log calls held
  log=$(sq_log); calls=$(gh_calls "$SQ_GH")
  held=$(sq_present "$SQ_PIPE/orch-42.held")
  sq_cleanup
  assert_contains "$log" "[escalate] #42" "#84/AC4: escalation logged" || return 1
  assert_eq "$held" "present" "#84/AC4: held" || return 1
  assert_contains "$calls" "issue comment 42" "#84/AC4: supervisor NOTE posted" || return 1
}

# test_tr_5_no_progress_ceiling_untouched — AC5: three consecutive ticks, unchanged marker, each run
# non-transient (long enough), still escalate at count = MAX_NO_PROGRESS = 3.
test_tr_5_no_progress_ceiling_untouched() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_marker "$SQ_READY"
  sq_tick
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  rm -f "$SQ_PIPE/queue/orch-42.json"
  sq_tick
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  rm -f "$SQ_PIPE/queue/orch-42.json"
  sq_tick
  local log calls held count
  log=$(sq_log); calls=$(gh_calls "$SQ_GH")
  held=$(sq_present "$SQ_PIPE/orch-42.held")
  count=$(sq_restarts_field count)
  sq_cleanup
  assert_eq "$count" "3" "#84/AC5: count reached MAX_NO_PROGRESS=3" || return 1
  assert_contains "$log" "[escalate] #42" "#84/AC5: escalation logged on the third no-progress exit" || return 1
  assert_eq "$held" "present" "#84/AC5: held" || return 1
  assert_contains "$calls" "issue comment 42" "#84/AC5: supervisor NOTE posted" || return 1
}

run_test test_tr_3_progressing_run_never_escalates_on_lifetime_ceiling
run_test test_tr_4_stuck_run_with_unchanged_marker_still_escalates
run_test test_tr_5_no_progress_ceiling_untouched
