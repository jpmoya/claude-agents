# Issue #451 — launchers reserve orch-<key>.pid before the claim-settle wait, so two launches on one host cannot both start.
# Placeholder repo names only. Reuses hc_env/hc_claims from test-hand-launch-claim.sh (sourced earlier by the runner).

HERE_PR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_PR="${R451_DIR:-$HERE_PR/..}"

pr_env() {  # real 2 s settle sleep so two launches can overlap; fake claude records every spawn
  hc_env
  rm -f "$HC_BIN/sleep"
  printf 'MEM_FLOOR_MB=0\nCLAIM_SETTLE_SECS=2\nCLAIM_WINDOW_SECS=600\n' > "$HC_HOME/.claude/pipeline/config.local.sh"
  hc_claims "$(hostname -s):5"
  : > "$HC_BIN/spawns.log"
  printf '#!/bin/bash\necho spawn >> "%s/spawns.log"\nexec /bin/sleep 30\n' "$HC_BIN" > "$HC_BIN/claude"
  PR_RK=$(rk "$HC_REPO" 42)
}
pr_launch() {  # pr_launch <issue> [args] — runs the code under test
  local n=$1; shift
  HOME="$HC_HOME" PATH="$HC_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$HC_PIPE" QUEUE="$HC_PIPE/queue" LOGDIR="$HC_HOME/logs/pipeline" \
    "$RS_PR/orchestrate.sh" "$@" "$HC_REPO" "$n" 2>&1
}
pr_spawns() { wc -l < "$HC_BIN/spawns.log" | tr -d ' '; }

test_pr451_manual_manual_one_spawn() {
  pr_env
  pr_launch 42 > "$HC_HOME/a.out" & local a=$!
  sleep 0.7
  local out rc; out=$(pr_launch 42); rc=$?
  wait "$a"; sleep 2.5
  local n; n=$(pr_spawns)
  hc_cleanup
  assert_eq "$n" "1" "#451: exactly one orchestrator spawned" || return 1
  assert_eq "$rc" "1" "#451: second manual launch exits non-zero" || return 1
  assert_contains "$out" "already running" "#451: second launcher reports already running" || return 1
}

test_pr451_second_force_launch_also_refused_during_wait() {
  pr_env
  pr_launch 42 > /dev/null & local a=$!
  sleep 0.7
  local out; out=$(pr_launch 42 --force)
  wait "$a"; sleep 2.5
  local n; n=$(pr_spawns)
  hc_cleanup
  assert_eq "$n" "1" "#451: --force during another launcher's wait does not double-spawn" || return 1
  assert_contains "$out" "already running" "#451: --force sees the reservation" || return 1
}

test_pr451_manual_vs_drain_entry_dropped() {  # a queued entry for a key a manual launcher holds is purged, not launched
  pr_env
  pr_launch 42 > /dev/null & local a=$!
  sleep 0.7
  mk_queued "$HC_PIPE" 42 "$HC_REPO"
  HOME="$HC_HOME" PATH="$HC_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$HC_PIPE" QUEUE="$HC_PIPE/queue" LOGDIR="$HC_HOME/logs/pipeline" \
    "$RS_PR/supervisor.sh" >/dev/null 2>&1
  wait "$a"; sleep 2.5
  local n q=gone; n=$(pr_spawns)
  [ -f "$(rkp "$HC_PIPE/queue/orch-42.json")" ] && q=kept
  hc_cleanup
  assert_eq "$n" "1" "#451: manual + drain spawn exactly one orchestrator" || return 1
  assert_eq "$q" "gone" "#451: drain drops the queue entry when a live pid holds the key" || return 1
}

test_pr451_lost_claim_restores_earlier_pid_content() {
  pr_env
  hc_claims otherhost:30 "$(hostname -s):5"
  echo 999999 > "$HC_PIPE/orch-$PR_RK.pid"    # earlier, dead pid
  local out rc; out=$(pr_launch 42); rc=$?
  local content; content=$(cat "$HC_PIPE/orch-$PR_RK.pid" 2>/dev/null || echo ABSENT)
  hc_cleanup
  assert_eq "$rc" "1" "#451: lost claim refuses" || return 1
  assert_eq "$content" "999999" "#451: lost claim puts the earlier pid content back" || return 1
}

test_pr451_lost_claim_without_earlier_file_leaves_none() {
  pr_env
  hc_claims otherhost:30 "$(hostname -s):5"
  pr_launch 42 >/dev/null
  local present=no; [ -f "$HC_PIPE/orch-$PR_RK.pid" ] && present=yes
  hc_cleanup
  assert_eq "$present" "no" "#451: no launcher pid left behind after a refused launch" || return 1
}

test_pr451_count_running_skips_own_key() {
  pr_env
  /bin/sleep 20 & local sp=$!   # not $$: hc_cleanup kills every pid it finds
  echo "$sp" > "$HC_PIPE/orch-$PR_RK.pid"
  local all own
  all=$( . "$RS_PR/config.sh"; . "$RS_PR/pipeline-lib.sh"; PIPE="$HC_PIPE"; count_running )
  own=$( . "$RS_PR/config.sh"; . "$RS_PR/pipeline-lib.sh"; PIPE="$HC_PIPE"; count_running "$PR_RK" )
  hc_cleanup
  assert_eq "$all" "1" "#451: control — a live reservation counts without the own-key argument" || return 1
  assert_eq "$own" "0" "#451: the launcher's own key is excluded" || return 1
}

test_pr451_launch_skip_event_tags() {
  pr_env
  local row
  ( . "$RS_PR/config.sh"; . "$RS_PR/pipeline-lib.sh"; PIPE="$HC_PIPE"; LOGDIR="$HC_HOME/logs/pipeline"; unset SLACK_WEBHOOK_URL
    launch_skip 42 orchestrate )
  row=$(cat "$HC_HOME/logs/pipeline/events.jsonl" 2>/dev/null)
  hc_cleanup
  assert_contains "$row" '"event":"launch_skip"' "#451: launch_skip row emitted" || return 1
  assert_contains "$row" '"reason":"pid-held"' "#451: reason pid-held" || return 1
  assert_contains "$row" '"route":"orchestrate"' "#451: route tag" || return 1
  assert_contains "$row" '"release":' "#451: release tag" || return 1
  assert_contains "$row" '"environment":' "#451: environment tag" || return 1
}

run_test test_pr451_manual_manual_one_spawn
run_test test_pr451_second_force_launch_also_refused_during_wait
run_test test_pr451_manual_vs_drain_entry_dropped
run_test test_pr451_lost_claim_restores_earlier_pid_content
run_test test_pr451_lost_claim_without_earlier_file_leaves_none
run_test test_pr451_count_running_skips_own_key
run_test test_pr451_launch_skip_event_tags
