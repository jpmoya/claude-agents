# Regression for claude-agents#22 — supervisor.sh step 1 read "this run's pid is dead" as "a run just
# ended". A relaunch that is only waiting in the queue also has a dead pid, so every 2-minute tick
# counted it as another failed restart (phantom escalations), the gate branch parked it and deleted
# the queued relaunch JP had just asked for, and a BLOCKED marker inside the grace window was
# queued and counted on the same tick that logged "waiting".
#
#   AC1 (1a, 1b)      a queued run is never counted
#   AC2 (2a, 2b, 2c)  a queued manual relaunch is invisible to step 1 (orchestrate.sh drops the stale .pid)
#   AC3 (3a, 3b)      BLOCKED inside grace means "wait", once; past the window it parks as before
#   AC4 (4a, 4b, 4c)  real exits still restart, back off and escalate
#
# Every case runs in an isolated HOME + PIPE + QUEUE + LOGDIR with the fake gh (config.sh prepends
# $HOME/.local/bin to PATH). "Tick" = one run of supervisor.sh. DISPATCH_REPOS stays empty.
# Placeholder repo names only.

HERE_SQ=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_SQ="$HERE_SQ/../orchestrate.sh"
SUP_SQ="$HERE_SQ/../supervisor.sh"

SQ_READY='**[product-manager] READY FOR ENGINEERING**'
SQ_AWAITING_GO='**[infra-operator] AWAITING GO**'
SQ_BLOCKED='**[fullstack-developer] BLOCKED**'

# sq_env <full|open> -> sets SQ_PIPE, SQ_HOME, SQ_REPO, SQ_GH. "full" fills every MAX_CONCURRENT slot
# with live placeholders (has_capacity false); "open" leaves them free.
sq_env() {
  local mode=$1 i
  SQ_PIPE=$(new_pipe); SQ_HOME=$(new_home)
  SQ_REPO="$SQ_PIPE/repo-a"
  SQ_GH="$SQ_HOME/.local/bin"
  fixture_repo "$SQ_REPO" "project-a/repo-a"
  mk_fake_gh "$SQ_GH"
  echo "project-a/repo-a" > "$SQ_GH/gh-name-with-owner"
  if [ "$mode" = "full" ]; then
    for i in 1 2 3; do mk_running "$SQ_PIPE" "$i" "$SQ_REPO"; done
  fi
}

# sq_free_slots — kill the placeholders, forget their state, zero the memory floor and stub claude so
# the next tick can launch regardless of the host's free RAM, without starting a real process.
sq_free_slots() {
  local i
  cleanup_running
  for i in 1 2 3; do rm -f "$SQ_PIPE/orch-$i".*; done
  echo 'MEM_FLOOR_MB=0' > "$SQ_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\nexit 0\n' > "$SQ_GH/claude"
  chmod +x "$SQ_GH/claude"
}

sq_cleanup() { cleanup_running; rm -rf "$SQ_PIPE" "$SQ_HOME"; }

sq_marker() { printf '%s\n' "$1" > "$SQ_GH/gh-issue-latest-marker"; }

sq_run() {  # sq_run <script> [args...] — the script under test in the isolated env
  HOME="$SQ_HOME" PATH="$SQ_GH:/usr/bin:/bin" PIPE="$SQ_PIPE" QUEUE="$SQ_PIPE/queue" LOGDIR="$SQ_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$@"
}
sq_tick() { sq_run "$SUP_SQ" >/dev/null 2>&1; }
sq_log() { cat "$SQ_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }

sq_iso_ago() {  # sq_iso_ago <secs> -> ISO-8601 UTC timestamp <secs> ago
  python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"
}

# sq_seed_restarts <count> <total> <last_marker> — a .restarts file with one history entry
sq_seed_restarts() {
  python3 -c "
import json, sys
json.dump({'count': int(sys.argv[1]), 'total': int(sys.argv[2]), 'transient_count': 0, 'last_marker': sys.argv[3],
           'history': [{'ts': '2026-01-01T00:00:00Z', 'exit': '0', 'marker': sys.argv[3], 'transient': False, 'run_secs': 600}]},
          open(sys.argv[4], 'w'))
" "$1" "$2" "$3" "$SQ_PIPE/orch-42.restarts"
}

# sq_seed_auto_restart_queue — an auto-restart queue entry step 2 cannot drain yet (not_before = now + 3600)
sq_seed_auto_restart_queue() {
  python3 -c "
import json, sys, time
json.dump({'issue': '42', 'repo': sys.argv[1], 'extra': '', 'reason': 'auto-restart',
           'queued_at': '2026-01-01T00:00:00Z', 'not_before': int(time.time()) + 3600}, open(sys.argv[2], 'w'))
" "$SQ_REPO" "$SQ_PIPE/queue/orch-42.json"
}

sq_restarts_field() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],'MISSING'))" "$SQ_PIPE/orch-42.restarts" "$1" 2>/dev/null || echo "NO-RESTARTS-FILE"; }
sq_history_len()    { python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('history',[])))" "$SQ_PIPE/orch-42.restarts" 2>/dev/null || echo "NO-RESTARTS-FILE"; }
sq_queue_field()    { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],'MISSING'))" "$SQ_PIPE/queue/orch-42.json" "$1" 2>/dev/null || echo "NO-QUEUE-ENTRY"; }
sq_present()        { if [ -e "$1" ]; then echo present; else echo absent; fi; }

# sq_queued_fixture <count> <total> — tests 1a/1b: an exited run (a real, non-transient exit 600 s ago)
# whose auto-restart is already queued and not yet due.
sq_queued_fixture() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_seed_restarts "$1" "$2" "$SQ_READY"
  sq_seed_auto_restart_queue
  sq_marker "$SQ_READY"
  cp "$SQ_PIPE/orch-42.restarts" "$SQ_PIPE/restarts.before"
  cp "$SQ_PIPE/queue/orch-42.json" "$SQ_PIPE/queue.before"
}

test_sq_1a_queued_run_tick_leaves_restart_state_untouched() {
  sq_queued_fixture 1 1
  sq_tick
  local restarts_same=no queue_same=no log
  cmp -s "$SQ_PIPE/orch-42.restarts" "$SQ_PIPE/restarts.before" && restarts_same=yes
  cmp -s "$SQ_PIPE/queue/orch-42.json" "$SQ_PIPE/queue.before" && queue_same=yes
  log=$(sq_log)
  sq_cleanup
  assert_eq "$restarts_same" "yes" "#22/1a: .restarts byte-identical after a tick on a queued run" || return 1
  assert_eq "$queue_same" "yes" "#22/1a: queue entry byte-identical after the tick" || return 1
  assert_contains "$log" "[queue-wait] #42" "#22/1a: tick logged queue-wait" || return 1
  assert_not_contains "$log" "[queue-restart] #42" "#22/1a: tick did not log a restart" || return 1
}

test_sq_1b_three_ticks_on_queued_run_never_escalate() {
  sq_queued_fixture 2 2
  sq_tick; sq_tick; sq_tick
  local restarts_same=no held log calls
  cmp -s "$SQ_PIPE/orch-42.restarts" "$SQ_PIPE/restarts.before" && restarts_same=yes
  held=$(sq_present "$SQ_PIPE/orch-42.held")
  log=$(sq_log); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$held" "absent" "#22/1b: no .held after three ticks on a queued run" || return 1
  assert_not_contains "$log" "[escalate] #42" "#22/1b: no escalation" || return 1
  assert_not_contains "$calls" "issue comment" "#22/1b: no supervisor NOTE posted" || return 1
  assert_eq "$restarts_same" "yes" "#22/1b: .restarts byte-identical after three ticks" || return 1
}

test_sq_2_queued_manual_relaunch_survives_gate_marker_then_launches() {
  sq_env full
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  local out rc
  out=$(sq_run "$ORCH_SQ" "$SQ_REPO" 42 2>&1); rc=$?
  # 2a — the no-capacity branch queues and drops the stale pid (.repo stays for the cross-machine guard)
  assert_exit0 "$rc" "#22/2a: queued relaunch exits 0" || { sq_cleanup; return 1; }
  assert_contains "$out" "queued #42" "#22/2a: relaunch was queued" || { sq_cleanup; return 1; }
  assert_file_absent "$SQ_PIPE/orch-42.pid" "#22/2a: stale orch-42.pid removed" || { sq_cleanup; return 1; }
  assert_file_exists "$SQ_PIPE/queue/orch-42.json" "#22/2a: queue entry written" || { sq_cleanup; return 1; }
  assert_file_exists "$SQ_PIPE/orch-42.repo" "#22/2a: .repo kept" || { sq_cleanup; return 1; }

  # 2b — the scheduler#625 reproduction: latest marker is a gate, capacity still full
  sq_marker "$SQ_AWAITING_GO"
  sq_tick
  local log; log=$(sq_log)
  assert_file_exists "$SQ_PIPE/queue/orch-42.json" "#22/2b: queued relaunch survives the tick" || { sq_cleanup; return 1; }
  assert_file_absent "$SQ_PIPE/orch-42.held" "#22/2b: not parked" || { sq_cleanup; return 1; }
  assert_file_absent "$SQ_PIPE/orch-42.restarts" "#22/2b: no restart state" || { sq_cleanup; return 1; }
  assert_not_contains "$log" "[held] #42" "#22/2b: no held log line" || { sq_cleanup; return 1; }
  assert_not_contains "$log" "[queue-restart] #42" "#22/2b: no restart log line" || { sq_cleanup; return 1; }

  # 2c — a slot opens: the queued relaunch drains
  sq_free_slots
  sq_tick
  log=$(sq_log)
  local launch_line pid queued
  launch_line=$(printf '%s\n' "$log" | grep -F "[launch] #42")
  pid=$(sq_present "$SQ_PIPE/orch-42.pid"); queued=$(sq_present "$SQ_PIPE/queue/orch-42.json")
  sq_cleanup
  assert_contains "$launch_line" "reason=queued" "#22/2c: drained with reason=queued" || return 1
  assert_eq "$pid" "present" "#22/2c: orch-42.pid written by the launch" || return 1
  assert_eq "$queued" "absent" "#22/2c: queue entry consumed" || return 1
}

test_sq_3_blocked_inside_grace_waits_then_parks_past_window() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"   # .start = now
  sq_marker "$SQ_BLOCKED"
  sq_tick
  local log; log=$(sq_log)
  # 3a
  assert_file_absent "$SQ_PIPE/orch-42.restarts" "#22/3a: no restart counted inside grace" || { sq_cleanup; return 1; }
  assert_file_absent "$SQ_PIPE/queue/orch-42.json" "#22/3a: nothing queued inside grace" || { sq_cleanup; return 1; }
  assert_file_absent "$SQ_PIPE/orch-42.held" "#22/3a: not parked inside grace" || { sq_cleanup; return 1; }
  assert_contains "$log" "[grace] #42" "#22/3a: grace logged" || { sq_cleanup; return 1; }
  assert_not_contains "$log" "[queue-restart] #42" "#22/3a: no restart logged" || { sq_cleanup; return 1; }

  # 3b — past the 1200 s window
  sq_iso_ago 1300 > "$SQ_PIPE/orch-42.start"
  sq_tick
  log=$(sq_log)
  local held alert restarts
  held=$(sq_present "$SQ_PIPE/orch-42.held"); restarts=$(sq_present "$SQ_PIPE/orch-42.restarts")
  alert=$(cat "$SQ_PIPE/orch-42.alert" 2>/dev/null)
  sq_cleanup
  assert_eq "$held" "present" "#22/3b: parked past the grace window" || return 1
  assert_contains "$alert" "waiting on JP" "#22/3b: alert says waiting on JP" || return 1
  assert_contains "$log" "[held] #42" "#22/3b: held logged" || return 1
  assert_eq "$restarts" "absent" "#22/3b: still no restart state" || return 1
}

# sq_exited_fixture <launched-secs-ago> — tests 4a-4c: a real exit, nothing queued
sq_exited_fixture() {
  sq_env open
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago "$1" > "$SQ_PIPE/orch-42.launched-at"
  sq_marker "$SQ_READY"
}

test_sq_4a_real_exit_is_counted_and_queued_with_backoff() {
  sq_exited_fixture 600
  local t0 t1; t0=$(date +%s)
  sq_tick
  t1=$(date +%s)
  local count total hist reason nb log
  count=$(sq_restarts_field count); total=$(sq_restarts_field total); hist=$(sq_history_len)
  reason=$(sq_queue_field reason); nb=$(sq_queue_field not_before)
  log=$(sq_log)
  sq_cleanup
  assert_eq "$count" "1" "#22/4a: count=1" || return 1
  assert_eq "$total" "1" "#22/4a: total=1" || return 1
  assert_eq "$hist" "1" "#22/4a: one history entry" || return 1
  assert_eq "$reason" "auto-restart" "#22/4a: queued as auto-restart" || return 1
  assert_le "$((t0 + 100))" "$nb" "#22/4a: not_before >= now+100" || return 1
  assert_le "$nb" "$((t1 + 140))" "#22/4a: not_before <= now+140" || return 1
  assert_contains "$log" "[queue-restart] #42" "#22/4a: restart logged" || return 1
}

test_sq_4b_short_run_is_transient_with_longer_backoff() {
  sq_exited_fixture 0
  local t0 t1; t0=$(date +%s)
  sq_tick
  t1=$(date +%s)
  local count transient nb
  count=$(sq_restarts_field count); transient=$(sq_restarts_field transient_count); nb=$(sq_queue_field not_before)
  sq_cleanup
  assert_eq "$transient" "1" "#22/4b: transient_count=1" || return 1
  assert_eq "$count" "0" "#22/4b: count=0" || return 1
  assert_le "$((t0 + 280))" "$nb" "#22/4b: not_before >= now+280" || return 1
  assert_le "$nb" "$((t1 + 320))" "#22/4b: not_before <= now+320" || return 1
}

test_sq_4c_third_real_exit_without_progress_escalates() {
  sq_exited_fixture 600
  sq_seed_restarts 2 2 "$SQ_READY"
  sq_tick
  local held queued log calls
  held=$(sq_present "$SQ_PIPE/orch-42.held"); queued=$(sq_present "$SQ_PIPE/queue/orch-42.json")
  log=$(sq_log); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$held" "present" "#22/4c: held after the third no-progress exit" || return 1
  assert_contains "$log" "[escalate] #42" "#22/4c: escalation logged" || return 1
  assert_contains "$calls" "issue comment 42" "#22/4c: supervisor NOTE posted" || return 1
  assert_eq "$queued" "absent" "#22/4c: no queue entry" || return 1
}

run_test test_sq_1a_queued_run_tick_leaves_restart_state_untouched
run_test test_sq_1b_three_ticks_on_queued_run_never_escalate
run_test test_sq_2_queued_manual_relaunch_survives_gate_marker_then_launches
run_test test_sq_3_blocked_inside_grace_waits_then_parks_past_window
run_test test_sq_4a_real_exit_is_counted_and_queued_with_backoff
run_test test_sq_4b_short_run_is_transient_with_longer_backoff
run_test test_sq_4c_third_real_exit_without_progress_escalates
