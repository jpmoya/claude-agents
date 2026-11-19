# #796 — the supervisor tick must not be starved by slow housekeeping.
#   AC1  every tick logs `[tick-timing] stage=total secs=<s>`; a stage over 5 s logs `[tick-timing] stage=<name> secs=<s>`
#   AC2  goal_step runs right after the since-sync: a slow worktree sweep (gh pr list sleeps) is a background job, so the tick
#        ends and the goal data (goalqueue.json, goal-sync.last) is written long before the sweep finishes
#   AC3  the sweep is a background job with its own lock (a second tick does not start a second one) and a time budget
#        (sweep_stale_worktrees stops at WORKTREE_SWEEP_DEADLINE)
#   AC4  soft budget: past TICK_BUDGET_SECS the pure housekeeping stages are skipped and logged; hard budget: TICK_HARD_SECS stops
#        the tick cleanly (exit 0, the lock released), also when it is stuck in a hung gh call
#   AC5  held runs whose repo directory is gone are skipped with ONE summary line, no per-run failed read; a failed read is
#        remembered for a few minutes
# Expected values come from the ticket or hand arithmetic in comments, never from the code under test.
# Isolation: the goal-sandbox tick (a copy of skills/orchestrate in an isolated HOME / PIPE / LOGDIR, fake gh/claude/hostname).
# Prefixed tt_ / TT_ (all test files share one shell). Placeholder repo names only (public repo).

. "$(dirname "${BASH_SOURCE[0]}")/lib/goal-sandbox.sh"
gs_tree_cleanup   # a tree left by an earlier file in the shared shell must not hide this file's edits

HERE_TT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# tt_slow_gh — wrap the sandbox's fake gh: `gh pr list --head` (the sweep's per-worktree lookup; the goal code's own pr lists stay fast) sleeps $1 seconds
tt_slow_gh() {
  mv "$GS_BIN/gh" "$GS_BIN/gh.real"
  cat > "$GS_BIN/gh" <<EOF
#!/bin/bash
case "\$*" in "pr list --head "*) sleep $1 ;; esac
exec "\$(dirname "\$0")/gh.real" "\$@"
EOF
  chmod +x "$GS_BIN/gh"
}

# tt_slow_hostname <secs> — every `hostname` call (pipeline_host, tags) takes <secs>: a cheap way to make a tick slow with no GitHub
tt_slow_hostname() {
  cat > "$GS_BIN/hostname" <<EOF
#!/bin/bash
sleep $1
echo "Host-A"
EOF
  chmod +x "$GS_BIN/hostname"
}

# tt_worktree — a checkout the sweep can read: one commit, origin/main, one feature worktree with a commit of its own
tt_worktree() {
  local ck=$GS_CK_A
  ( cd "$ck" && git checkout -q -b main 2>/dev/null; git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init \
    && git update-ref refs/remotes/origin/main "$(git rev-parse main)" \
    && git worktree add -q .worktrees/feat -b feat main \
    && cd .worktrees/feat && git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m own ) >/dev/null 2>&1
}

tt_wait_log() {  # <needle> <seconds> — wait for a supervisor.log line
  local i=0; while [ "$i" -lt $(( $2 * 5 )) ]; do gs_log | grep -qF -- "$1" && return 0; sleep 0.2; i=$((i + 1)); done; return 1
}

# ---------------------------------------------------------------- AC1: timing -----------------------------------

# Every tick that got the lock ends with a total line (hand arithmetic: a fast sandbox tick is far under 5 s, so no stage line).
test_tt_ac1_tick_logs_total_and_no_stage_line_for_fast_stages() {
  gs_env
  gs_tick
  local log; log=$(gs_log); gs_cleanup
  assert_contains "$log" "[tick-timing] stage=total secs=" "AC1: total line" || return 1
  assert_not_contains "$log" "[tick-timing] stage=goal-step" "AC1: a stage under 5 s logs nothing" || return 1
}

# A slow stage is named: hostname takes 3 s per call and goal_step calls it, so goal-step exceeds 5 s only with several calls;
# use 6 s per call to be unambiguous (one call > 5 s).
test_tt_ac1_a_stage_over_five_seconds_is_logged_by_name() {
  gs_env
  tt_slow_hostname 6
  gs_tick
  local log; log=$(gs_log); gs_cleanup
  printf '%s\n' "$log" | grep -qE '\[tick-timing\] stage=[a-z0-9-]+ secs=[0-9]+' || { fail "AC1: no stage timing line in: $log"; return 1; }
  assert_contains "$log" "[tick-timing] stage=total secs=" "AC1: total line still written" || return 1
}

# ---------------------------------------------------------------- AC2/AC3: sweep off the critical path ----------

# gh pr list --head sleeps 20 s for the worktree; the tick (a few seconds in the sandbox) must return long before that, with the goal data
# already written, and the sweep must still be running when it ends.
test_tt_ac2_slow_sweep_does_not_delay_the_tick_or_goal_sync() {
  gs_env
  tt_worktree
  tt_slow_gh 20
  local t0=$SECONDS
  gs_tick
  local took=$(( SECONDS - t0 )) q=no s=no done_yet=no
  [ -f "$GS_PIPE/goalqueue.json" ] && q=yes
  [ -f "$GS_PIPE/goal-sync.last" ] && s=yes
  gs_log | grep -qF "[worktree-sweep] background pass finished" && done_yet=yes
  local rc=$GS_RC timing running=no; timing=$(gs_log | grep -F '[tick-timing]' | tr '\n' ' ')
  [ -d "$GS_PIPE/worktree-sweep.lockdir" ] && running=yes
  kill "$(cat "$GS_PIPE/worktree-sweep.lockdir/pid" 2>/dev/null)" 2>/dev/null
  gs_cleanup
  [ "$took" -lt 15 ] || { fail "AC2: the tick took ${took}s while the sweep sleeps 20 s; it must not wait for it ($timing)"; return 1; }
  assert_eq "$rc" "0" "AC2: tick exit code" || return 1
  assert_eq "$q" "yes" "AC2: goalqueue.json written by the tick" || return 1
  assert_eq "$s" "yes" "AC2: goal-sync.last written by the tick" || return 1
  assert_eq "$done_yet" "no" "AC2: the sweep was still running when the tick ended" || return 1
  assert_eq "$running" "yes" "AC2: the sweep holds its own lock while it runs" || return 1
}

# Own lock: while a sweep is running a second launch is refused and logged, and no second job starts.
test_tt_ac3_second_sweep_launch_is_refused_while_one_runs() {
  gs_env
  tt_worktree
  tt_slow_gh 4
  gs_tick
  rm -f "$GS_PIPE/worktree-sweep.last"   # make the 30-minute gate due again while the first sweep still holds its lock
  gs_tick
  local log; log=$(gs_log)
  tt_wait_log "[worktree-sweep] background pass finished" 15
  gs_cleanup
  assert_contains "$log" "previous sweep still running" "AC3: second sweep refused while the first runs" || return 1
}

# The stamp is written at launch (a sweep that never finishes is not retried every tick).
test_tt_ac3_stamp_written_at_launch() {
  gs_env
  tt_worktree
  tt_slow_gh 4
  gs_tick
  local st=no; [ -s "$GS_PIPE/worktree-sweep.last" ] && st=yes
  tt_wait_log "[worktree-sweep] background pass finished" 15
  gs_cleanup
  assert_eq "$st" "yes" "AC3: worktree-sweep.last exists as soon as the tick ends" || return 1
}

# Time budget: sweep_stale_worktrees stops at WORKTREE_SWEEP_DEADLINE and says so (deadline in the past => no worktree is examined).
test_tt_ac3_sweep_stops_at_its_deadline() {
  local home repo out
  home=$(new_home); repo="$home/repo"; fixture_repo "$repo" example-owner/project-a
  repo=$(cd "$repo" && pwd -P)
  ( cd "$repo" && git checkout -q -b main 2>/dev/null; git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init \
    && git update-ref refs/remotes/origin/main "$(git rev-parse main)" && git worktree add -q .worktrees/feat -b feat main ) >/dev/null 2>&1
  out=$(cd "$repo" && HOME="$home" bash -c '
    . "'"$HERE_TT"'/../pipeline-lib.sh"
    DISPATCH_REPOS=("example-owner/project-a:'"$repo"'")
    WORKTREE_SWEEP_DEADLINE=$(( $(date +%s) - 1 ))
    sweep_stale_worktrees' 2>&1)
  git -C "$repo" worktree prune >/dev/null 2>&1; rm -rf "$home"
  assert_contains "$out" "time budget reached" "AC3: the budget stop is logged" || return 1
  assert_not_contains "$out" "skipped $repo/.worktrees/feat" "AC3: no worktree was examined past the deadline" || return 1
}

# ---------------------------------------------------------------- AC4: watchdog ---------------------------------

# Soft budget 1 s, every hostname call takes 1 s: by the time step 3b is reached the budget is gone; the late optional stages are skipped.
test_tt_ac4_soft_budget_skips_optional_late_stages_and_logs_them() {
  gs_env
  tt_slow_hostname 1
  export TICK_BUDGET_SECS=1
  gs_tick
  unset TICK_BUDGET_SECS
  local log rc; log=$(gs_log); rc=$GS_RC; gs_cleanup
  assert_eq "$rc" "0" "AC4: the tick still exits 0" || return 1
  assert_contains "$log" "[tick-watchdog] soft budget 1s passed" "AC4: soft budget logged" || return 1
  assert_contains "$log" "skipping label-reconcile" "AC4: label reconcile named as skipped" || return 1
  assert_contains "$log" "[tick-timing] stage=total" "AC4: total line on the way out" || return 1
}

# Hard budget 2 s with a tick that takes longer (hostname 1 s per call): the watcher stops it cleanly; the lock is free afterwards.
test_tt_ac4_hard_budget_stops_the_tick_cleanly_and_frees_the_lock() {
  gs_env
  tt_slow_hostname 1
  export TICK_HARD_SECS=2 TICK_BUDGET_SECS=0
  gs_tick
  unset TICK_HARD_SECS TICK_BUDGET_SECS
  local log rc free=no; log=$(gs_log); rc=$GS_RC
  flock -n "$GS_PIPE/supervisor.lock" true 2>/dev/null && free=yes
  gs_cleanup
  assert_eq "$rc" "0" "AC4: a hard-stopped tick exits 0" || return 1
  assert_contains "$log" "[tick-watchdog] hard budget 2s passed" "AC4: the watcher logged the hard budget" || return 1
  assert_contains "$log" "the next tick starts clean" "AC4: the tick logged its own stop" || return 1
  assert_contains "$log" "[tick-timing] stage=total" "AC4: total line written by the EXIT handler" || return 1
  assert_eq "$free" "yes" "AC4: the tick lock is released" || return 1
}

# A hung `gh api` call (30 s; the goal registry read, after the tick lock is held) must not keep the tick past its hard budget: the watcher signals the tick, then ends the foreground child.
test_tt_ac4_hard_budget_ends_a_tick_stuck_in_a_hung_gh_call() {
  gs_env
  mv "$GS_BIN/gh" "$GS_BIN/gh.real"
  cat > "$GS_BIN/gh" <<'GHEOF'
#!/bin/bash
[ "$1" = api ] && sleep 30
exec "$(dirname "$0")/gh.real" "$@"
GHEOF
  chmod +x "$GS_BIN/gh"
  export TICK_HARD_SECS=3 TICK_BUDGET_SECS=0
  local t0=$SECONDS
  gs_tick
  local took=$(( SECONDS - t0 ))
  unset TICK_HARD_SECS TICK_BUDGET_SECS
  local log rc; log=$(gs_log); rc=$GS_RC
  pkill -f "$GS_BIN/gh" 2>/dev/null; gs_cleanup
  [ "$took" -lt 20 ] || { fail "AC4: the tick ran ${took}s with a gh call hung for 30 s; the hard budget (3 s) must end it: $(printf '%s' "$log" | grep -F '[tick-' | tr '\n' ' ')"; return 1; }
  assert_eq "$rc" "0" "AC4: exit 0" || return 1
  assert_contains "$log" "[tick-watchdog] hard budget 3s passed" "AC4: watcher logged" || return 1
}

# ---------------------------------------------------------------- AC5: held runs with no checkout ---------------

test_tt_ac5_held_run_without_a_checkout_is_one_summary_line_not_a_failed_read() {
  gs_env
  local rk="example-owner_project-a-77"
  echo "$GS_HOME/renamed-away-dir" > "$GS_PIPE/orch-$rk.repo"; touch "$GS_PIPE/orch-$rk.held"
  gs_tick
  gs_tick   # the second tick inside the log throttle must not repeat the line
  local log; log=$(gs_log); gs_cleanup
  assert_eq "$(printf '%s\n' "$log" | grep -c '\[held-skip\]')" "1" "AC5: one summary line across two ticks" || return 1
  assert_contains "$log" "#77" "AC5: the summary names the ticket" || return 1
  assert_not_contains "$log" "issue read failed" "AC5: no per-run failed read" || return 1
}

# A real read failure (the ticket is not in the fake GitHub) is logged once and then remembered: the second tick makes no new attempt.
test_tt_ac5_failed_read_is_remembered_for_a_few_minutes() {
  gs_env
  local rk="example-owner_project-a-77"
  echo "$GS_CK_A" > "$GS_PIPE/orch-$rk.repo"; touch "$GS_PIPE/orch-$rk.held"
  gs_tick
  local n1; n1=$(gs_log | grep -c 'issue read failed')
  gs_tick
  local n2; n2=$(gs_log | grep -c 'issue read failed')
  gs_cleanup
  assert_eq "$n1" "1" "AC5: the first tick fails the read once (the answered check; auto-retry reuses the memory)" || return 1
  assert_eq "$n2" "1" "AC5: the second tick makes no new failing read" || return 1
}

run_test test_tt_ac1_tick_logs_total_and_no_stage_line_for_fast_stages
run_test test_tt_ac1_a_stage_over_five_seconds_is_logged_by_name
run_test test_tt_ac2_slow_sweep_does_not_delay_the_tick_or_goal_sync
run_test test_tt_ac3_second_sweep_launch_is_refused_while_one_runs
run_test test_tt_ac3_stamp_written_at_launch
run_test test_tt_ac3_sweep_stops_at_its_deadline
run_test test_tt_ac4_soft_budget_skips_optional_late_stages_and_logs_them
run_test test_tt_ac4_hard_budget_stops_the_tick_cleanly_and_frees_the_lock
run_test test_tt_ac4_hard_budget_ends_a_tick_stuck_in_a_hung_gh_call
run_test test_tt_ac5_held_run_without_a_checkout_is_one_summary_line_not_a_failed_read
run_test test_tt_ac5_failed_read_is_remembered_for_a_few_minutes
gs_tree_cleanup
