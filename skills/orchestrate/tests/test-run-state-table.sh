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

# ---- #94: stage = the live process table (never log names) -------------------------------------
#
# Process-lookup hook contract (defined here; run-state.sh must honour it): when RS_PS_CMD is set,
# run-state.sh runs it (bash -c) INSTEAD of the real process table (/proc on Linux, `ps eww` on
# macOS). It prints one line per live claude process:
#     <start_epoch> TAB <PIPELINE_ISSUE> TAB <full command line>
# The stage of issue N = the value after `--agent` in the command line of the newest-start line whose
# PIPELINE_ISSUE == N exactly. Prompt text is never parsed for names. Orchestrator alive (pid alive)
# with no stage line -> "orchestrator". Nothing alive -> empty.

ps_line() {  # ps_line <secs_ago> <issue> <command line...> -> one fixture line on stdout
  local ago=$1 issue=$2; shift 2
  printf '%s\t%s\t%s\n' "$(( $(date +%s) - ago ))" "$issue" "$*"
}

stage_of() {  # stage_of <pipe> <issue> -> stage field (8) from derive_runs, RS_PS_CMD reading <pipe>/ps.fixture
  local tsv
  tsv=$( RS_PS_CMD="cat $1/ps.fixture" derive_runs_lines "$1" )
  field_for_issue "$tsv" "$2" 8
}

test_stage_is_agent_of_the_single_live_stage_process() {
  local pipe got
  pipe=$(new_pipe)
  mk_running "$pipe" 806 "$pipe/repo-a"
  ps_line 30 806 claude --dangerously-skip-permissions --agent code-reviewer -p "Review PR" > "$pipe/ps.fixture"
  got=$(stage_of "$pipe" 806)
  cleanup_running; rm -rf "$pipe"
  assert_eq "$got" "code-reviewer" "#94: stage = --agent of the live process whose PIPELINE_ISSUE is the ticket" || return 1
}

test_stage_parallel_processes_newest_start_wins_in_either_listing_order() {
  local pipe got1 got2
  pipe=$(new_pipe)
  mk_running "$pipe" 806 "$pipe/repo-a"
  { ps_line 60 806 claude --agent test-writer -p x; ps_line 5 806 claude --agent solutions-architect -p x; } > "$pipe/ps.fixture"
  got1=$(stage_of "$pipe" 806)
  { ps_line 5 806 claude --agent solutions-architect -p x; ps_line 60 806 claude --agent test-writer -p x; } > "$pipe/ps.fixture"
  got2=$(stage_of "$pipe" 806)
  cleanup_running; rm -rf "$pipe"
  assert_eq "$got1" "solutions-architect" "#94: two parallel stages -> the newest start wins (older listed first)" || return 1
  assert_eq "$got2" "solutions-architect" "#94: two parallel stages -> the newest start wins (older listed last)" || return 1
}

test_stage_suffixed_agent_name_is_reported_exactly_as_the_agent_flag() {
  # boundary: the exact --agent value is reported (no log-name-style suffix mapping, no trimming)
  local pipe got
  pipe=$(new_pipe)
  mk_running "$pipe" 806 "$pipe/repo-a"
  ps_line 5 806 claude --agent fullstack-developer -p "fix cycle" > "$pipe/ps.fixture"
  got=$(stage_of "$pipe" 806)
  cleanup_running; rm -rf "$pipe"
  assert_eq "$got" "fullstack-developer" "#94: stage is the bare agent name" || return 1
}

test_stage_orchestrator_only_process_reports_orchestrator() {
  local pipe got
  pipe=$(new_pipe)
  mk_running "$pipe" 806 "$pipe/repo-a"
  ps_line 200 806 claude --dangerously-skip-permissions --agent orchestrator -p "Drive x#806" > "$pipe/ps.fixture"
  got=$(stage_of "$pipe" 806)
  cleanup_running; rm -rf "$pipe"
  assert_eq "$got" "orchestrator" "#94: only the orchestrator process is alive -> stage = orchestrator" || return 1
}

test_stage_orchestrator_alive_with_empty_process_list_reports_orchestrator() {
  local pipe got
  pipe=$(new_pipe)
  mk_running "$pipe" 806 "$pipe/repo-a"     # pid alive (run is running), no stage process in the table
  : > "$pipe/ps.fixture"
  got=$(stage_of "$pipe" 806)
  cleanup_running; rm -rf "$pipe"
  assert_eq "$got" "orchestrator" "#94: orchestrator alive, no stage process -> orchestrator" || return 1
}

test_stage_running_stage_beats_the_older_orchestrator_process() {
  local pipe got
  pipe=$(new_pipe)
  mk_running "$pipe" 806 "$pipe/repo-a"
  { ps_line 500 806 claude --agent orchestrator -p "Drive"; ps_line 20 806 claude --agent test-reviewer -p "Review"; } > "$pipe/ps.fixture"
  got=$(stage_of "$pipe" 806)
  cleanup_running; rm -rf "$pipe"
  assert_eq "$got" "test-reviewer" "#94: a live stage (newer) is reported, not the orchestrator that dispatched it" || return 1
}

test_stage_nothing_alive_is_empty_for_held_done_queued_and_restarting() {
  local pipe tsv
  pipe=$(new_pipe)
  mk_held "$pipe" 811 "$pipe/repo-a"
  mk_done "$pipe" 812 "$pipe/repo-a"
  mk_queued "$pipe" 813 "$pipe/repo-a"
  mk_restarting "$pipe" 814 "$pipe/repo-a"
  mk_stage_log "$pipe" 811 "deployer-recovery" 0     # stale log names must not leak into the stage
  mk_stage_log "$pipe" 812 "code-reviewer-3" 0
  mk_stage_log "$pipe" 814 "fullstack-developer-fix1" 0
  : > "$pipe/ps.fixture"
  tsv=$( RS_PS_CMD="cat $pipe/ps.fixture" derive_runs_lines "$pipe" )
  rm -rf "$pipe"
  assert_eq "$(field_for_issue "$tsv" 811 8)" "" "#94: held, nothing alive -> empty stage" || return 1
  assert_eq "$(field_for_issue "$tsv" 812 8)" "" "#94: done, nothing alive -> empty stage" || return 1
  assert_eq "$(field_for_issue "$tsv" 813 8)" "" "#94: queued -> empty stage" || return 1
  assert_eq "$(field_for_issue "$tsv" 814 8)" "" "#94: restarting (dead pid), nothing alive -> empty stage" || return 1
}

test_stage_prompt_text_with_agent_like_words_is_ignored() {
  # VM #919's fix cycle prompt starts "PR #932"; prompts also mention suffixed names. Only --agent counts.
  local pipe got
  pipe=$(new_pipe)
  mk_running "$pipe" 806 "$pipe/repo-a"
  ps_line 5 806 claude --dangerously-skip-permissions --agent fullstack-developer -p "PR #932 fix cycle: see run-806-code-reviewer-3.log, deployer-recovery, product-manager-retry" > "$pipe/ps.fixture"
  got=$(stage_of "$pipe" 806)
  cleanup_running; rm -rf "$pipe"
  assert_eq "$got" "fullstack-developer" "#94: names in the prompt text are ignored — only the --agent value counts" || return 1
}

test_stage_process_for_a_different_issue_is_ignored_including_prefix_numbers() {
  local pipe got
  pipe=$(new_pipe)
  mk_running "$pipe" 806 "$pipe/repo-a"      # pid alive, no stage process of its own
  { ps_line 5 999 claude --agent deployer -p x; ps_line 5 8060 claude --agent code-reviewer -p x; ps_line 5 80 claude --agent test-writer -p x; } > "$pipe/ps.fixture"
  got=$(stage_of "$pipe" 806)
  cleanup_running; rm -rf "$pipe"
  assert_eq "$got" "orchestrator" "#94: processes for #999, #8060 and #80 do not count for #806 (exact issue match) -> only the live orchestrator" || return 1
}

test_stage_log_names_are_no_longer_read() {
  # Negative fixture from the ticket: a stage log with no live process must not produce a stage.
  local pipe got_held got_running
  pipe=$(new_pipe)
  mk_held "$pipe" 805 "$pipe/repo-a"
  mk_stage_log "$pipe" 805 "code-reviewer-3" 0        # run-805-code-reviewer-3.log
  mk_running "$pipe" 806 "$pipe/repo-a"
  mk_stage_log "$pipe" 806 "test-writer" 0
  : > "$pipe/ps.fixture"
  got_held=$(stage_of "$pipe" 805)
  got_running=$(stage_of "$pipe" 806)
  cleanup_running; rm -rf "$pipe"
  assert_eq "$got_held" "" "#94: run-805-code-reviewer-3.log with no live process -> empty stage" || return 1
  assert_eq "$got_running" "orchestrator" "#94: a stage log never names the stage; live orchestrator with no stage process -> orchestrator" || return 1
}

test_stage_real_process_table_on_linux_reads_agent_and_pipeline_issue() {
  # No RS_PS_CMD: the real /proc path. A bash copy named `claude` carries PIPELINE_ISSUE in its env and
  # `--agent deployer` in its argv (the real launch shape). Linux only.
  [ "$(uname)" = "Linux" ] || return 0
  local pipe tmp pid got
  pipe=$(new_pipe); tmp=$(mktemp -d)
  cp "$(command -v bash)" "$tmp/claude"
  mk_running "$pipe" 890 "$pipe/repo-a"
  PIPELINE_ISSUE=890 "$tmp/claude" -c 'sleep 30; :' _ --agent deployer -p "Deploy" >/dev/null 2>&1 &
  pid=$!
  sleep 0.3
  got=$( unset RS_PS_CMD; derive_runs_lines "$pipe" | awk -F'\t' '$1 == 890 { print $8 }' )
  kill "$pid" 2>/dev/null; pkill -P "$pid" 2>/dev/null
  cleanup_running; rm -rf "$pipe" "$tmp"
  assert_eq "$got" "deployer" "#94: Linux /proc lookup — --agent of the process whose env has PIPELINE_ISSUE=890" || return 1
}

test_run_state_has_no_log_name_stage_parsing() {
  local src
  src=$(cat "$RS_RST/run-state.sh")
  case "$src" in *_rs_stage_for*) fail "#94: _rs_stage_for must be deleted from run-state.sh"; return 1 ;; esac
  # the only run-<n>-*.log use left is _rs_last_activity_for (last-activity mtime); no basename/agent extraction
  if grep -nE 'agent=\$\{base#|base=\$\(basename' "$RS_RST/run-state.sh" >/dev/null; then
    fail "#94: run-state.sh still derives a stage from a log file name"; return 1
  fi
  assert_contains "$src" "_rs_last_activity_for" "#94: _rs_last_activity_for stays" || return 1
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
run_test test_stage_is_agent_of_the_single_live_stage_process
run_test test_stage_parallel_processes_newest_start_wins_in_either_listing_order
run_test test_stage_suffixed_agent_name_is_reported_exactly_as_the_agent_flag
run_test test_stage_orchestrator_only_process_reports_orchestrator
run_test test_stage_orchestrator_alive_with_empty_process_list_reports_orchestrator
run_test test_stage_running_stage_beats_the_older_orchestrator_process
run_test test_stage_nothing_alive_is_empty_for_held_done_queued_and_restarting
run_test test_stage_prompt_text_with_agent_like_words_is_ignored
run_test test_stage_process_for_a_different_issue_is_ignored_including_prefix_numbers
run_test test_stage_log_names_are_no_longer_read
run_test test_stage_real_process_table_on_linux_reads_agent_and_pipeline_issue
run_test test_run_state_has_no_log_name_stage_parsing
run_test test_last_activity_at_is_newest_mtime_among_orch_and_run_logs
