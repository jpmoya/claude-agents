# Supports AC1 — the state_code table derive_runs() must implement, tested directly against the
# raw derive_runs() TSV output (not through the reporter), including the row PRECEDENCE ("in
# order" in the design table) and the two mtime-derived fields (stage, last_activity_at).
#
# derive_runs() record shape (design): issue, repo_path, state_code, pid, started_at,
# last_activity_at, restarts, stage — tab-separated, one line per recorded orchestrator.

HERE_RST=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_RST="$HERE_RST/.."

derive_runs_lines() {  # derive_runs_lines <pipe> -> derive_runs() output, one line per run
  ( PIPE="$1" QUEUE="$1/queue" bash -c '. "'"$RS_RST"'/run-state.sh"; derive_runs' )
}

field_for_issue() {  # field_for_issue <tsv> <issue> <field-index 1-based> -> value, or MISSING
  local tsv=$1 issue=$2 idx=$3
  echo "$tsv" | awk -F'\t' -v want="$issue" -v idx="$idx" '$1 == want { print $idx; found=1 } END { if (!found) print "MISSING" }'
}

test_state_table_running_precedes_stopped_when_pid_is_alive() {
  # "in order" precedence: pid alive wins even if a stale .stopped file is also present.
  local pipe out
  pipe=$(new_pipe)
  mk_running "$pipe" 801 "$pipe/repo-a"
  touch "$pipe/orch-801.stopped"   # stale marker from a previous lifecycle; must not win
  out=$(derive_runs_lines "$pipe")
  cleanup_running; rm -rf "$pipe"
  assert_eq "$(field_for_issue "$out" 801 3)" "running" "state-table: pid-alive beats a stale .stopped marker (order matters)" || return 1
}

test_state_table_stopped_precedes_held_when_both_files_present() {
  local pipe out
  pipe=$(new_pipe)
  mk_dead_pid "$pipe" 802
  echo "$pipe/repo-a" > "$pipe/orch-802.repo"
  touch "$pipe/orch-802.stopped" "$pipe/orch-802.held"
  out=$(derive_runs_lines "$pipe")
  rm -rf "$pipe"
  assert_eq "$(field_for_issue "$out" 802 3)" "stopped" "state-table: .stopped is checked before .held" || return 1
}

test_state_table_held_precedes_done_when_both_files_present() {
  local pipe out
  pipe=$(new_pipe)
  mk_dead_pid "$pipe" 803
  echo "$pipe/repo-a" > "$pipe/orch-803.repo"
  touch "$pipe/orch-803.held" "$pipe/orch-803.done"
  out=$(derive_runs_lines "$pipe")
  rm -rf "$pipe"
  assert_eq "$(field_for_issue "$out" 803 3)" "held" "state-table: .held is checked before .done" || return 1
}

test_state_table_no_markers_is_restarting() {
  local pipe out
  pipe=$(new_pipe)
  mk_restarting "$pipe" 804 "$pipe/repo-a"
  out=$(derive_runs_lines "$pipe")
  rm -rf "$pipe"
  assert_eq "$(field_for_issue "$out" 804 3)" "restarting" "state-table: dead pid, no marker files, is restarting" || return 1
}

test_state_table_queue_entry_no_pid_is_queued() {
  local pipe out
  pipe=$(new_pipe)
  mk_queued "$pipe" 805 "$pipe/repo-a"
  out=$(derive_runs_lines "$pipe")
  rm -rf "$pipe"
  assert_eq "$(field_for_issue "$out" 805 3)" "queued" "state-table: a queue entry with no orch-<issue>.pid at all is queued" || return 1
}

test_stage_is_agent_of_newest_mtime_log() {
  local pipe out
  pipe=$(new_pipe)
  mk_running "$pipe" 806 "$pipe/repo-a"
  mk_stage_log "$pipe" 806 "test-writer" 10
  mk_stage_log "$pipe" 806 "solutions-architect" 5
  mk_stage_log "$pipe" 806 "code-reviewer" 0   # newest
  out=$(derive_runs_lines "$pipe")
  cleanup_running; rm -rf "$pipe"
  assert_eq "$(field_for_issue "$out" 806 8)" "code-reviewer" "stage = agent name of the newest-mtime run-<issue>-<agent>.log" || return 1
}

test_last_activity_at_is_newest_mtime_among_orch_and_run_logs() {
  local pipe out expected actual
  pipe=$(new_pipe)
  mk_running "$pipe" 807 "$pipe/repo-a"
  # orch-807.log was created by mk_running (now); make run-807-*.log older, then touch orch log
  # to a known-newer timestamp so we can assert against it precisely.
  mk_stage_log "$pipe" 807 "fullstack-developer" 100
  local newer_ts
  newer_ts=$(python3 -c "import time; print(int(time.time()))")
  python3 -c "import os; os.utime('$pipe/orch-807.log', ($newer_ts, $newer_ts))"
  out=$(derive_runs_lines "$pipe")
  cleanup_running
  expected=$newer_ts
  actual=$(field_for_issue "$out" 807 6)
  rm -rf "$pipe"
  case "$actual" in
    ''|*[!0-9]*) fail "last_activity_at should be an epoch integer near $expected, got [$actual]"; return 1 ;;
  esac
  # allow +/-2s slack for the mtime->epoch round trip
  local diff=$((actual - expected)); [ "$diff" -lt 0 ] && diff=$((-diff))
  assert_le "$diff" 2 "last_activity_at should equal the newest mtime among orch-<n>.log / run-<n>-*.log (got $actual, expected ~$expected)" || return 1
}

run_test test_state_table_running_precedes_stopped_when_pid_is_alive
run_test test_state_table_stopped_precedes_held_when_both_files_present
run_test test_state_table_held_precedes_done_when_both_files_present
run_test test_state_table_no_markers_is_restarting
run_test test_state_table_queue_entry_no_pid_is_queued
run_test test_stage_is_agent_of_newest_mtime_log
run_test test_last_activity_at_is_newest_mtime_among_orch_and_run_logs
