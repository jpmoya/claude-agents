# Stall causes found by the 2026-10-19 sweep.
#  A  power_ok: on battery, dispatch continues while charge >= BATTERY_MIN_PCT (default 30); below it, unknown charge, or
#     BATTERY_MIN_PCT=0 -> still blocked. AC power -> ok. keep_awake: caffeinate only on Mac with a live run, never otherwise.
#  B  a loop-cap hold is relaunched once a [delivery-lead] DECISION / JP CONFIRMED is posted AFTER the hold; not before,
#     not for other holds (gate with alert), not for other comment kinds.
HERE_SL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f ar2_fixture >/dev/null 2>&1; then
  eval "sl_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_SL/test-supervisor-auto-retry.sh"
  eval "$(declare -f sl_real_run_test | sed '1s/sl_real_run_test/run_test/')"
fi

sl_power() {  # sl_power <pmset output> [BATTERY_MIN_PCT] -> prints ok|blocked
  local d; d=$(mktemp -d)
  printf '#!/bin/bash\nprintf "%%s\\n" "$PMSET_OUT"\n' > "$d/pmset"
  printf '#!/bin/bash\necho Darwin\n' > "$d/uname"; chmod +x "$d/pmset" "$d/uname"
  (
    unset ALLOW_BATTERY   # #442: an earlier file in the full run leaks ALLOW_BATTERY=1 into the shell; this case pins the unset default
    export PMSET_OUT="$1" PATH="$d:$PATH"; [ -n "${2:-}" ] && export BATTERY_MIN_PCT=$2
    eval "$(sed -n '/^power_ok() {/,/^}/p' "$HERE_SL/../supervisor.sh")"
    power_ok && echo ok || echo blocked
  )
  rm -rf "$d"
}

test_sl_power_ac_ok() {
  assert_eq "$(sl_power "Now drawing from 'AC Power'")" "ok" "AC power -> ok" || return 1
}
test_sl_power_battery_above_floor_ok() {
  local o="Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1)	45%; discharging; 3:00 remaining present: true"
  assert_eq "$(sl_power "$o")" "ok" "battery 45% >= 30 -> dispatch" || return 1
}
test_sl_power_battery_below_floor_blocked() {
  local o="Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1)	12%; discharging; 0:40 remaining present: true"
  assert_eq "$(sl_power "$o")" "blocked" "battery 12% < 30 -> blocked" || return 1
}
test_sl_power_battery_unknown_charge_blocked() {
  assert_eq "$(sl_power "Now drawing from 'Battery Power'")" "blocked" "no charge reading -> blocked (old behaviour)" || return 1
}
test_sl_power_min_zero_disables() {
  local o="Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1)	90%; discharging"
  assert_eq "$(sl_power "$o" 0)" "blocked" "BATTERY_MIN_PCT=0 -> never on battery" || return 1
}

test_sl_keep_awake_only_with_live_run() {
  local d out1 out2; d=$(mktemp -d); mkdir -p "$d/pipe" "$d/queue" "$d/bin"
  printf '#!/bin/bash\necho "$*" >> "%s/caff"\n' "$d" > "$d/bin/caffeinate"
  printf '#!/bin/bash\necho Darwin\n' > "$d/bin/uname"; chmod +x "$d/bin/caffeinate" "$d/bin/uname"
  run_ka() { ( export PATH="$d/bin:$PATH" PIPE="$d/pipe" QUEUE="$d/queue"; slog() { :; }
      eval "$(sed -n '/^keep_awake() {/,/^}/p' "$HERE_SL/../supervisor.sh")"; keep_awake; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$d/caff" ] && break; sleep 0.1; done ); }
  run_ka; out1=$(cat "$d/caff" 2>/dev/null)
  sleep 300 & local sp=$!; echo $sp > "$d/pipe/orch-x-1.pid"
  run_ka; out2=$(cat "$d/caff" 2>/dev/null)
  kill $sp 2>/dev/null; rm -rf "$d"
  assert_eq "$out1" "" "no live run -> no caffeinate" || return 1
  assert_eq "$out2" "-i -t 300" "live run -> idle-sleep assertion" || return 1
}

# ---- B ----
sl_lc_fixture() {  # sl_lc_fixture <comment first line> <createdAt> [alert]
  sq_env open; sq_free_slots; ar2_install_gh
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  printf 'FAIL\n' > "$(rkp "$SQ_PIPE/orch-42.marker")"
  mkdir -p "$SQ_HOME/.claude/pipeline"
  printf '{"issue":42,"event":"validate","result":"fail","stage":"loop-cap","ts":"2026-01-01T00:00:00Z"}\n' > "$SQ_HOME/.claude/pipeline/runs.jsonl"
  [ -n "${3:-}" ] && echo "$3" > "$(rkp "$SQ_PIPE/orch-42.alert")"
  jq -nc --arg b "$1"$'\nResolves: x' --arg t "$2" '[{body:$b, createdAt:$t, author:{login:"x"}}]' > "$SQ_GH/gh-issue-comments-json-42"
  : > "$SQ_PIPE/claude.calls"
}

test_sl_loopcap_decision_after_hold_relaunches() {
  sl_lc_fixture '**[delivery-lead] DECISION**' "2099-01-01T00:00:00Z"
  ar2_tick
  local n h calls; n=$(ar2_launches); h=$(ar2_held); calls=$(gh_calls "$SQ_GH"); echo "LOG: $(sq_log | tail -5)"
  sq_cleanup
  assert_eq "$n" "1" "decision after loop-cap hold -> relaunched" || return 1
  assert_eq "$h" "absent" ".held cleared" || return 1
  assert_contains "$calls" "loop-cap hold resumed" "supervisor NOTE posted" || return 1
}
test_sl_loopcap_jp_confirmed_legacy_spelling_relaunches() {
  sl_lc_fixture '**[project-manager] JP CONFIRMED**' "2099-01-01T00:00:00Z"
  ar2_tick
  local n; n=$(ar2_launches); sq_cleanup
  assert_eq "$n" "1" "legacy JP CONFIRMED -> relaunched" || return 1
}
test_sl_loopcap_decision_before_hold_stays_held() {
  sl_lc_fixture '**[delivery-lead] DECISION**' "2020-01-01T00:00:00Z"
  ar2_tick
  local n h; n=$(ar2_no_launch); h=$(ar2_held); sq_cleanup
  assert_eq "$n" "0" "decision older than the hold -> no relaunch" || return 1
  assert_eq "$h" "present" "still held" || return 1
}
test_sl_loopcap_other_comment_stays_held() {
  sl_lc_fixture '**[code-reviewer] FAIL**' "2099-01-01T00:00:00Z"
  ar2_tick
  local n; n=$(ar2_no_launch); sq_cleanup
  assert_eq "$n" "0" "non-decision comment -> no relaunch" || return 1
}
test_sl_gate_hold_with_alert_not_resumed() {
  sl_lc_fixture '**[delivery-lead] DECISION**' "2099-01-01T00:00:00Z" "Pipeline #42 waiting on JP — AWAITING GO"
  ar2_tick
  local n; n=$(ar2_no_launch); sq_cleanup
  assert_eq "$n" "0" "gate hold (alert present) is never resumed by this path" || return 1
}

run_test test_sl_power_ac_ok
run_test test_sl_power_battery_above_floor_ok
run_test test_sl_power_battery_below_floor_blocked
run_test test_sl_power_battery_unknown_charge_blocked
run_test test_sl_power_min_zero_disables
run_test test_sl_keep_awake_only_with_live_run
run_test test_sl_loopcap_decision_after_hold_relaunches
run_test test_sl_loopcap_jp_confirmed_legacy_spelling_relaunches
run_test test_sl_loopcap_decision_before_hold_stays_held
run_test test_sl_loopcap_other_comment_stays_held
run_test test_sl_gate_hold_with_alert_not_resumed
