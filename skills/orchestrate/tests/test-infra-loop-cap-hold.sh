# Tests for claude-agents#100 — the infra `PLAN FAIL` loop cap (3rd consecutive PLAN FAIL) stopped
# correctly but left no distinguishable trace: the supervisor's only hold gate keys on
# `"stage":"structural"` (claude-agents#92) and the infra loop-cap fires no validate line at all, so
# every cap hit was relaunched as an ordinary restart until MAX_TOTAL burned it to a false "stalled"
# alert (same bug class as #88's code-track loop cap).
#
#   supervisor  loop-cap fail in this run + PLAN FAIL marker -> held, slog names loop-cap, no queue
#               PLAN FAIL marker, no loop-cap/structural fail this run (revision cycle 1/2) -> restart
#               loop-cap fail only in an earlier run (ts < .launched-at) -> restart
#               structural fail in this run still holds, unedited (regression against #92)
#   doc pins    orchestrator :96 infra PLAN FAIL row logs the loop-cap validate line before terminal;
#               :196-200 loop-cap section: code-track caps log the same line (no-op if #88 landed
#               first and already added it) and the unchanged-cap sentence names the log line
#
# Reuses the sq_* helpers of test-supervisor-queued-not-counted.sh and the ms_seed_run_line /
# ms_exited_run helpers of test-merged-pr-structural-hold.sh (same load trick both already use).
# Placeholder repos only.

HERE_LC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_LC=$(cd "$HERE_LC/../../.." && pwd)
ORCH_LC="$ROOT_LC/agents/orchestrator.md"

if ! declare -f sq_env >/dev/null 2>&1; then
  eval "lc_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_LC/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f lc_real_run_test | sed '1s/lc_real_run_test/run_test/')"
fi
if ! declare -f ms_exited_run >/dev/null 2>&1; then
  eval "lc_real2_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_LC/test-merged-pr-structural-hold.sh"
  eval "$(declare -f lc_real2_run_test | sed '1s/lc_real2_run_test/run_test/')"
fi

LC_PLAN_FAIL='**[infra-reviewer] PLAN FAIL: 3 findings**'

# lc_exited_run <stage> <secs-ago> — same shape as ms_exited_run but with the infra PLAN FAIL
# marker latest on the issue, so the case exercises the infra track rather than the code track.
lc_exited_run() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_marker "$LC_PLAN_FAIL"
  ms_seed_run_line "$1" "$2"
  sq_tick
  LC_LOG=$(sq_log)
  LC_HELD=$(sq_present "$SQ_PIPE/orch-42.held")
  LC_QUEUED=$(sq_present "$SQ_PIPE/queue/orch-42.json")
  sq_cleanup
}

test_lc_loop_cap_fail_in_this_run_holds() {
  lc_exited_run loop-cap 60   # 60 s ago >= launched 600 s ago: this run
  assert_eq "$LC_HELD" "present" "#100: loop-cap fail this run -> .held" || return 1
  assert_contains "$LC_LOG" "[held] #42" "#100: [held] line logged" || return 1
  assert_contains "$LC_LOG" "loop-cap" "#100: slog line names the loop-cap stop reason" || return 1
  assert_not_contains "$LC_LOG" "structural stop" "#100: loop-cap hold does not misreport structural wording" || return 1
  assert_not_contains "$LC_LOG" "[queue-restart] #42" "#100: no restart queued" || return 1
  assert_eq "$LC_QUEUED" "absent" "#100: no queue entry" || return 1
}

test_lc_plan_fail_no_loop_cap_line_restarts() {
  # Revision cycle 1 or 2 of 2: latest marker is PLAN FAIL, but no loop-cap (or structural) validate
  # fail was logged for this run -> ordinary restart, not held.
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_marker "$LC_PLAN_FAIL"
  sq_tick
  LC_LOG=$(sq_log)
  LC_HELD=$(sq_present "$SQ_PIPE/orch-42.held")
  sq_cleanup
  assert_contains "$LC_LOG" "[queue-restart] #42" "#100: PLAN FAIL round 1/2 (no loop-cap line) still restarts" || return 1
  assert_not_contains "$LC_LOG" "[held] #42" "#100: not held" || return 1
  assert_eq "$LC_HELD" "absent" "#100: no .held" || return 1
}

test_lc_loop_cap_fail_in_earlier_run_restarts() {
  lc_exited_run loop-cap 1200   # 1200 s ago < launched 600 s ago: an earlier run
  assert_contains "$LC_LOG" "[queue-restart] #42" "#100: stale loop-cap fail (before .launched-at) still restarts" || return 1
  assert_not_contains "$LC_LOG" "[held] #42" "#100: not held" || return 1
  assert_eq "$LC_HELD" "absent" "#100: no .held" || return 1
}

test_lc_structural_fail_still_holds_unedited() {
  # Regression: the #92 structural case must keep working exactly as before, with the infra PLAN
  # FAIL marker on the issue this time (structural stops are not code-track-only).
  lc_exited_run structural 60
  assert_eq "$LC_HELD" "present" "#100: structural fail this run still holds (unedited #92 behavior)" || return 1
  assert_contains "$LC_LOG" "[held] #42" "#100: [held] line logged" || return 1
  assert_contains "$LC_LOG" "structural stop" "#100: structural wording unchanged" || return 1
}

# ---- doc pins (agents/orchestrator.md) ----

lc_has() { grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }
lc_lacks() { if grep -qF -- "$2" "$1"; then fail "$(basename "$1"): must NOT contain [$2]"; return 1; fi; }

test_lc_orchestrator_plan_fail_row_logs_loop_cap() {
  local row
  row=$(grep -F '[infra-reviewer] PLAN FAIL' "$ORCH_LC" | head -1)
  assert_ne "$row" "" "#100: infra PLAN FAIL row exists" || return 1
  assert_contains "$row" '"stage":"loop-cap"' "#100: :96 row logs the loop-cap validate line" || return 1
  assert_contains "$row" 'log_run' "#100: :96 row calls log_run" || return 1
  assert_contains "$row" '"event":"validate"' "#100: :96 row logs a validate event" || return 1
  assert_contains "$row" '"result":"fail"' "#100: :96 row logs a fail result" || return 1
}

test_lc_orchestrator_loop_cap_section_code_track() {
  # Only meaningful if #88 has not already landed this line; if it has, this AC is a documented
  # no-op (grep would already find it) and the case is still valid — it just asserts the line exists.
  lc_has "$ORCH_LC" '"stage":"loop-cap"' || return 1
}

test_lc_orchestrator_unchanged_cap_sentence_names_log_line() {
  local sentence
  sentence=$(grep -F 'no ' "$ORCH_LC" | grep -F 'extends it' | head -1)
  assert_ne "$sentence" "" "#100: unchanged-cap sentence present" || return 1
  assert_contains "$sentence" '"stage":"loop-cap"' "#100: sentence names the exact log line" || return 1
}

run_test test_lc_loop_cap_fail_in_this_run_holds
run_test test_lc_plan_fail_no_loop_cap_line_restarts
run_test test_lc_loop_cap_fail_in_earlier_run_restarts
run_test test_lc_structural_fail_still_holds_unedited
run_test test_lc_orchestrator_plan_fail_row_logs_loop_cap
run_test test_lc_orchestrator_loop_cap_section_code_track
run_test test_lc_orchestrator_unchanged_cap_sentence_names_log_line
