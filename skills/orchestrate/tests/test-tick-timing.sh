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

# tt_nap — install $GS_BIN/nap <secs>: sleeps in 1 s steps and ends early once $GS_BIN/stop-naps exists, so no test leaves a long sleep behind
# (tt_stop_naps before gs_cleanup). Fake-gh wrappers call it instead of `sleep`.
tt_nap() {
  cat > "$GS_BIN/nap" <<'NAPEOF'
#!/bin/bash
d=$(dirname "$0"); i=0
while [ "$i" -lt "$1" ] && [ ! -f "$d/stop-naps" ]; do sleep 1; i=$((i + 1)); done
NAPEOF
  chmod +x "$GS_BIN/nap"
}
tt_stop_naps() { touch "$GS_BIN/stop-naps"; pkill -f "$GS_BIN/gh" 2>/dev/null; sleep 1.2; }   # the 1 s steps notice the stop file

# tt_slow_gh <secs> — wrap the sandbox's fake gh: `gh pr list --head` (the sweep's per-worktree lookup; the goal code's own pr lists stay fast) naps <secs>
tt_slow_gh() {
  tt_nap
  mv "$GS_BIN/gh" "$GS_BIN/gh.real"
  cat > "$GS_BIN/gh" <<EOF
#!/bin/bash
case "\$*" in "pr list --head "*) "\$(dirname "\$0")/nap" $1 ;; esac
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
  tt_stop_naps; gs_cleanup
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
  tt_slow_gh 40   # far longer than two sandbox ticks, so the first sweep is certainly still running at the second
  gs_tick
  rm -f "$GS_PIPE/worktree-sweep.last"   # make the 30-minute gate due again while the first sweep still holds its lock
  gs_tick
  local log; log=$(gs_log)
  kill "$(cat "$GS_PIPE/worktree-sweep.lockdir/pid" 2>/dev/null)" 2>/dev/null
  tt_stop_naps; gs_cleanup
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
  tt_stop_naps; gs_cleanup
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

# tt_hang_gh <bash case pattern over "$*"> — fake gh whose matching calls nap 60 s (a hung GitHub call); other calls pass through.
# Hung calls are recorded in $GS_BIN/hang-calls.log. Optional second argument: a path (glob allowed) that must exist for the hang to apply (e.g. the sweep's lock dir, or the fake claude's call dir).
tt_hang_gh() {
  tt_nap
  mv "$GS_BIN/gh" "$GS_BIN/gh.real"
  cat > "$GS_BIN/gh" <<EOF
#!/bin/bash
case "\$*" in "api repos/{owner}/{repo}"*) echo example-owner/project-a; exit 0 ;; esac   # the checkout-relative repo name lookup the fake gh does not know
case "\$*" in $1) [ -z "${2:-}" ] || ls -d ${2:-} >/dev/null 2>&1 && { echo "\$*" >> "\$(dirname "\$0")/hang-calls.log"; "\$(dirname "\$0")/nap" 60; } ;; esac
case "\$*" in "pr list --head "*) [ -n "${2:-}" ] && "\$(dirname "\$0")/nap" 60 ;; esac
exec "\$(dirname "\$0")/gh.real" "\$@"
EOF
  chmod +x "$GS_BIN/gh"
}

# A hung `gh api` call (the goal registry read, after the tick lock is held) must not keep the tick past its hard budget (6 s): the watcher
# signals the tick, then ends the foreground child; the tick exits 0 with the lock released and its total line written.
test_tt_ac4_hard_budget_ends_a_tick_stuck_in_a_hung_gh_call() {
  gs_env
  tt_hang_gh 'api*'
  export TICK_HARD_SECS=6 TICK_BUDGET_SECS=0
  local t0=$SECONDS
  gs_tick
  local took=$(( SECONDS - t0 ))
  unset TICK_HARD_SECS TICK_BUDGET_SECS
  local log rc free=no; log=$(gs_log); rc=$GS_RC
  flock -n "$GS_PIPE/supervisor.lock" true 2>/dev/null && free=yes
  tt_stop_naps; gs_cleanup
  [ "$took" -lt 40 ] || { fail "AC4: the tick ran ${took}s with a gh call hung for 60 s; the hard budget (6 s) must end it: $(printf '%s' "$log" | grep -F '[tick-' | tr '\n' ' ')"; return 1; }
  assert_eq "$rc" "0" "AC4: exit 0" || return 1
  assert_contains "$log" "[tick-watchdog] hard budget 6s passed" "AC4: watcher logged" || return 1
  assert_contains "$log" "the next tick starts clean" "AC4: the tick logged its own stop" || return 1
  assert_contains "$log" "[tick-timing] stage=total" "AC4: total line written by the EXIT handler" || return 1
  assert_eq "$free" "yes" "AC4: the tick lock is released" || return 1
}

# The hard stop ends the tick's own hung child but not the background worktree sweep (own lock and budget). One tick: the sweep is launched
# early (its gh pr list naps), and every `gh api` made after that point hangs, so the watcher must end the tick's own child while the
# sweep, also a direct child of the tick, stays alive.
test_tt_ac4_hard_stop_leaves_the_background_sweep_running() {
  gs_env
  tt_worktree
  tt_hang_gh 'api*' "$GS_PIPE/worktree-sweep.lockdir"
  export TICK_HARD_SECS=6 TICK_BUDGET_SECS=0
  gs_tick
  unset TICK_HARD_SECS TICK_BUDGET_SECS
  local spid; spid=$(cat "$GS_PIPE/worktree-sweep.lockdir/pid" 2>/dev/null)
  local alive=no; [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null && alive=yes
  local log; log=$(gs_log)
  kill "$spid" 2>/dev/null; tt_stop_naps; gs_cleanup
  assert_contains "$log" "[tick-watchdog] hard budget 6s passed" "AC4: the hard stop fired" || return 1
  [ -n "$spid" ] || { fail "AC4: no sweep pid recorded"; return 1; }
  assert_eq "$alive" "yes" "AC4: the background sweep survived the hard stop" || return 1
}

# A launched orchestrator run survives the hard stop while the tick's hung gh is ended: the queued run is launched by the drain (step 2, fake claude
# that stays alive), every `gh api` after that point hangs, the hard stop fires at 6 s. Only the tick's own hung tool is killed.
test_tt_ac4_hard_stop_kills_the_hung_gh_but_not_a_launched_run() {
  gs_env
  gs_issue 77 open
  gs_comment 77 $'**[product-manager] READY FOR ENGINEERING**\nLane: fast'
  mkdir -p "$GS_PIPE/queue"
  python3 -c "import json,sys; json.dump({'issue':'77','repo':sys.argv[1],'extra':'','reason':'queued','queued_at':'2026-01-01T00:00:00Z','not_before':0}, open(sys.argv[2],'w'))" \
    "$GS_CK_A" "$GS_PIPE/queue/orch-example-owner_project-a-77.json"
  tt_hang_gh '*' "$GS_BIN/claude-calls.*"
  export TICK_HARD_SECS=6 TICK_BUDGET_SECS=0
  local t0=$SECONDS
  gs_tick
  local took=$(( SECONDS - t0 ))
  unset TICK_HARD_SECS TICK_BUDGET_SECS
  local rpid; rpid=$(cat "$GS_PIPE/orch-example-owner_project-a-77.pid" 2>/dev/null)
  local alive=no; [ -n "$rpid" ] && kill -0 "$rpid" 2>/dev/null && alive=yes
  local calls; calls=$(gs_claude_count)
  local log; log=$(gs_log)
  tt_stop_naps; gs_cleanup
  [ "$calls" -ge 1 ] || { fail "AC4: the queued run was never launched (no fake claude call); log: $(printf '%s' "$log" | tail -5 | tr '\n' ' ')"; return 1; }
  assert_contains "$log" "[tick-watchdog] hard budget 6s passed" "AC4: the hard stop fired after the launch" || return 1
  [ "$took" -lt 40 ] || { fail "AC4: the hung gh was not ended (${took}s)"; return 1; }
  assert_eq "$alive" "yes" "AC4: the launched orchestrator run survived the hard stop" || return 1
}

# The goal-sync stamp is written after the sync: a tick stopped mid-sync leaves it unwritten, so the next tick syncs again. ONLY the goal registry
# read hangs (every other gh call, and so every earlier stage, succeeds), so the tick is stopped inside goal_sync itself; the control assertions
# prove that: the hang was reached (a call was logged to the registry repo) and no goal data was saved either. Mutation check (done by hand): move
# the `echo "$now" > "$PIPE/goal-sync.last"` line in goal_step back above `goal_sync` and this test fails on the stamp assertion.
test_tt_ac2_goal_sync_stamp_is_written_after_the_sync_not_before() {
  gs_env
  tt_hang_gh '*example-owner/registry/issues*'
  export TICK_HARD_SECS=6 TICK_BUDGET_SECS=0
  gs_tick
  unset TICK_HARD_SECS TICK_BUDGET_SECS
  local stamp="MISSING"; [ -s "$GS_PIPE/goal-sync.last" ] && stamp=$(cat "$GS_PIPE/goal-sync.last")
  local q=no; [ -f "$GS_PIPE/goalqueue.json" ] && q=yes
  local reached=no; grep -aq "example-owner/registry/issues" "$GS_BIN/hang-calls.log" 2>/dev/null && reached=yes
  local log; log=$(gs_log)
  tt_stop_naps; gs_cleanup
  assert_contains "$log" "[tick-watchdog] hard budget 6s passed" "AC2: the tick was stopped by the hard budget" || return 1
  assert_eq "$reached" "yes" "AC2: the tick reached the goal registry read (goal_sync started)" || return 1
  assert_eq "$q" "no" "AC2: no goal queue was saved: the stop came inside the sync" || return 1
  assert_eq "$stamp" "MISSING" "AC2: no goal-sync.last was written for a sync that never finished" || return 1
}

# goal_step runs BEFORE the earlier stages' slow work (#796 AC2), not just before the sweep: a held run's issue read (step 1) hangs, the hard
# stop fires at 6 s, and the goal data (goalqueue.json, goal-sync.last) was already written. With goal_step back in its old late position the
# tick dies in step 1 first and neither file exists.
test_tt_ac2_goal_sync_is_written_before_a_hung_foreground_stage() {
  gs_env
  local rk="example-owner_project-a-77"
  echo "$GS_CK_A" > "$GS_PIPE/orch-$rk.repo"; touch "$GS_PIPE/orch-$rk.held"
  tt_hang_gh '*issues/77*'
  export TICK_HARD_SECS=6 TICK_BUDGET_SECS=0
  gs_tick
  unset TICK_HARD_SECS TICK_BUDGET_SECS
  local q=no s=no; [ -f "$GS_PIPE/goalqueue.json" ] && q=yes; [ -s "$GS_PIPE/goal-sync.last" ] && s=yes
  local log; log=$(gs_log)
  tt_stop_naps; gs_cleanup
  assert_contains "$log" "[tick-watchdog] hard budget 6s passed" "AC2: the tick really was stuck in the held-run read" || return 1
  assert_eq "$q" "yes" "AC2: goalqueue.json written before the hung stage" || return 1
  assert_eq "$s" "yes" "AC2: goal-sync.last written before the hung stage" || return 1
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
  assert_eq "$n1" "2" "AC5: the first tick fails the read once per check (answered, auto-retry)" || return 1
  assert_eq "$n2" "2" "AC5: the second tick makes no new failing read" || return 1
}

run_test test_tt_ac1_tick_logs_total_and_no_stage_line_for_fast_stages
run_test test_tt_ac1_a_stage_over_five_seconds_is_logged_by_name
run_test test_tt_ac2_slow_sweep_does_not_delay_the_tick_or_goal_sync
run_test test_tt_ac3_second_sweep_launch_is_refused_while_one_runs
run_test test_tt_ac3_stamp_written_at_launch
run_test test_tt_ac3_sweep_stops_at_its_deadline
run_test test_tt_ac4_soft_budget_skips_optional_late_stages_and_logs_them
run_test test_tt_ac4_hard_budget_ends_a_tick_stuck_in_a_hung_gh_call
run_test test_tt_ac4_hard_stop_leaves_the_background_sweep_running
run_test test_tt_ac4_hard_stop_kills_the_hung_gh_but_not_a_launched_run
run_test test_tt_ac2_goal_sync_stamp_is_written_after_the_sync_not_before
run_test test_tt_ac2_goal_sync_is_written_before_a_hung_foreground_stage
run_test test_tt_ac5_held_run_without_a_checkout_is_one_summary_line_not_a_failed_read
run_test test_tt_ac5_failed_read_is_remembered_for_a_few_minutes
gs_tree_cleanup
