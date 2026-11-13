# Issue #182 follow-on (PR #683): PM spec runs (supervisor step 3c) count against MAX_CONCURRENT, like intake runs.
# Before, count_running read orch-*.pid and intake-*.pid only. That stayed hidden while a live spec run kept the tick lock
# (every later tick exited at the lock); once ticks run beside a live intake or spec run, each tick could start one more
# spec run past the cap.
# Reuses the sp_* harness of test-spec-run-supervisor.sh (stub gh / claude, whole ticks); that file sorts after this one in
# run-tests.sh, so its helpers are loaded here with its cases switched off. Placeholder repo names only.

HERE_SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_SRC="$HERE_SRC/../pipeline-lib.sh"
if ! declare -f sp_env >/dev/null 2>&1; then
  eval "src_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_SRC/test-spec-run-supervisor.sh"
  eval "$(declare -f src_real_run_test | sed '1s/src_real_run_test/run_test/')"
fi

# src_tick — one supervisor tick, then (bounded, 5 s) wait for every spec launch its log reports. No wait for the stub to
# exit: here it stays alive on purpose.
src_tick() {
  HOME="$SP_HOME" PATH="$SP_D:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$SP_PIPE" QUEUE="$SP_PIPE/queue" LOGDIR="$SP_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" /bin/bash "$SUP_SP" >/dev/null 2>&1
  local want i=0; want=$(grep -c '\[spec\] .* launched (attempt' "$SP_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  while [ "$(sp_pm_launches)" -lt "${want:-0}" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  return 0
}
src_kill_runs() {  # stop the held stub runs (the pid file names the shell waiting on the run)
  local f pid
  for f in "$SP_PIPE"/spec-*.pid; do
    [ -e "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null); [ -n "$pid" ] || continue
    pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null
  done
  pkill -f "$SP_D/claude" 2>/dev/null
  return 0
}

test_src_count_running_counts_live_spec_and_intake_runs() {
  local pipe n p=99999; pipe=$(new_pipe)
  while kill -0 "$p" 2>/dev/null; do p=$((p - 1)); done   # a pid with no process
  /bin/sleep 60 & local live=$!
  echo "$live" > "$pipe/orch-project-a_repo-a-1.pid"     # a running orchestrator
  echo "$live" > "$pipe/intake-project-a_repo-a-2.pid"   # a running intake run
  echo "$live" > "$pipe/spec-project-a_repo-a-3.pid"     # a running spec run
  echo "$p" > "$pipe/spec-project-a_repo-a-4.pid"        # a spec run that has exited
  echo "$live" > "$pipe/goal-x.pid"                      # a delivery lead: a coordinator, never a slot
  n=$( . "$LIB_SRC" 2>/dev/null; PIPE="$pipe"; count_running 2>/dev/null )
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null; rm -rf "$pipe"
  # hand count: orchestrator + intake + live spec = 3 (dead spec and the goal pid are not slots)
  assert_eq "$n" "3" "count_running counts a live spec run as it counts a live intake run" || return 1
}

test_src_live_spec_run_holds_its_slot_across_ticks() {
  sp_env; echo 'MAX_CONCURRENT=1' >> "$SP_HOME/.claude/pipeline/config.local.sh"
  # the stub PM logs its launch and then stays alive (20 s) while $D/hold exists
  perl -pi -e 's|^exit 0$|[ -f "\$D/hold" ] && exec /bin/sleep 20\nexit 0|' "$SP_D/claude"; touch "$SP_D/hold"
  sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec
  sp_issue 8 project-a/repo-a user-feedback user-feedback-needs-spec
  src_tick
  local n1 alive=no; n1=$(sp_pm_launches); kill -0 "$(cat "$SP_PIPE"/spec-*.pid 2>/dev/null | head -1)" 2>/dev/null && alive=yes
  src_tick; src_tick
  local n_full l8 ticks eight_full; n_full=$(sp_pm_launches); l8=$(sp_labels 8); eight_full=$(grep -c 'ISSUE=8 ' "$SP_D/claude.log")
  # step 4 lists agent-in-progress issues once per tick that got past the lock
  ticks=$(grep -c -- '^issue list --repo project-a/repo-a --state open --label agent-in-progress ' "$SP_D/gh-calls.log" 2>/dev/null)
  # control: free the slot; the waiting idea now gets its spec run
  rm -f "$SP_D/hold"; src_kill_runs; sleep 0.3
  src_tick
  local eight_free; eight_free=$(grep -c 'ISSUE=8 ' "$SP_D/claude.log")
  src_kill_runs; sp_cleanup
  assert_eq "$n1" "1" "first tick starts one spec run" || return 1
  assert_eq "$alive" "yes" "precondition: that run is still alive" || return 1
  [ "${ticks:-0}" -ge 3 ] || { fail "precondition: the later ticks ran beside the live spec run (ticks past the lock: ${ticks:-0})"; return 1; }
  assert_eq "$n_full" "1" "MAX_CONCURRENT=1: no second spec run while the first holds the slot" || return 1
  assert_eq "$l8" "user-feedback,user-feedback-needs-spec" "the waiting idea keeps its labels" || return 1
  assert_eq "$eight_full" "0" "the second idea was not started while the slot was held" || return 1
  assert_eq "$eight_free" "1" "once the slot is free the second idea gets its spec run" || return 1
}

run_test test_src_count_running_counts_live_spec_and_intake_runs
run_test test_src_live_spec_run_holds_its_slot_across_ticks
