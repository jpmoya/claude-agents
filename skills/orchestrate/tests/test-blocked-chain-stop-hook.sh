# hooks/blocked-chain-stop.sh — Stop hook enforcing CLAUDE.md "Interactive sessions act as the delivery lead".
# Every case builds a throwaway HOME (pipeline state + events.jsonl) and runs the hook against it; the host's real
# state is never touched. Exit 2 = session must continue, 0 = may stop. Prefix bcs_ / BCS_ (all tests share one shell).

HERE_BCS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_BCS=$(cd "$HERE_BCS/../../.." && pwd)
HOOK_BCS="$ROOT_BCS/hooks/blocked-chain-stop.sh"
BCS_REPO="Benjis-Plants/benjis-ops-tool"
BCS_KEY="Benjis-Plants_benjis-ops-tool-2169"

bcs_setup() {  # bcs_setup <launch age secs> <log text> [reason] -> sets BCS_H (fake HOME), BCS_P (state dir); dead pid
  local age=$1 logtxt=$2 reason=${3:-manual} ts
  BCS_H=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bcs.XXXXXX")
  BCS_P="$BCS_H/.claude/pipeline/state"
  mkdir -p "$BCS_P" "$BCS_H/logs/pipeline"
  ts=$(python3 -c "import time,sys; print(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time()-int(sys.argv[1]))))" "$age")
  printf '{"v":1,"ts":"%s","event":"run_launch","repo":"%s","issue":2169,"reason":"%s"}\n' "$ts" "$BCS_REPO" "$reason" > "$BCS_H/logs/pipeline/events.jsonl"
  printf '%s\n' "$logtxt" > "$BCS_P/orch-$BCS_KEY.log"
  echo "/home/x/benjis-ops-tool" > "$BCS_P/orch-$BCS_KEY.repo"
  sleep 0 & local p=$!; wait "$p" 2>/dev/null
  echo "$p" > "$BCS_P/orch-$BCS_KEY.pid"   # reaped, so dead
}

bcs_run() {  # bcs_run [stdin json] -> stderr in BCS_OUT, returns hook's exit code
  local in=${1:-'{}'}
  BCS_OUT=$(printf '%s' "$in" | env -u PIPELINE_AGENT HOME="$BCS_H" PIPE="$BCS_P" bash "$HOOK_BCS" 2>&1)
  return $?
}

bcs_cleanup() { rm -rf "$BCS_H"; }

test_bcs_dead_and_blocked_exits_2() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs a delivery-lead decision on the failing check"
  bcs_run; local rc=$?
  assert_eq "$rc" "2" "dead + blocked must continue the session" || { bcs_cleanup; return 1; }
  assert_contains "$BCS_OUT" '[delivery-lead] DECISION' "message names the marker" || { bcs_cleanup; return 1; }
  assert_contains "$BCS_OUT" 'Resolves:' "message names Resolves line" || { bcs_cleanup; return 1; }
  assert_contains "$BCS_OUT" 'Madrid' "times shown in Madrid" || { bcs_cleanup; return 1; }
  assert_contains "$BCS_OUT" 'orchestrate.sh' "message says to relaunch" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_launched_minutes_ago_and_dead_exits_2() {
  bcs_setup 120 "claude exited with no output"
  bcs_run; local rc=$?
  assert_eq "$rc" "2" "run dead within 10 min must continue the session" || { bcs_cleanup; return 1; }
  assert_contains "$BCS_OUT" 'already exited' "message explains" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_old_dead_without_block_exits_0() {
  bcs_setup 3600 "all quiet, nothing to see"
  bcs_run; local rc=$?
  assert_eq "$rc" "0" "dead but not blocked and older than 10 min" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_live_run_exits_0() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs decision"
  sleep 30 & local lp=$!
  echo "$lp" > "$BCS_P/orch-$BCS_KEY.pid"
  bcs_run; local rc=$?
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  assert_eq "$rc" "0" "live pid must allow stopping" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_tombstone_exits_0() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs decision"
  touch "$BCS_P/orch-$BCS_KEY.stopped"
  bcs_run; local rc=$?
  assert_eq "$rc" "0" ".stopped tombstone must allow stopping" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_jp_only_block_exits_0() {
  bcs_setup 3600 "**[deployer] BLOCKED** needs JP: production go required before the prod migration"
  bcs_run; local rc=$?
  assert_eq "$rc" "0" "JP-only block must allow stopping" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_non_manual_launch_exits_0() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs decision" "supervisor"
  bcs_run; local rc=$?
  assert_eq "$rc" "0" "only manual launches count" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_older_than_3h_exits_0() {
  bcs_setup 14400 "**[orchestrator] BLOCKED** needs decision"
  bcs_run; local rc=$?
  assert_eq "$rc" "0" "launch older than 3 h is out of scope" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_loop_guard_second_attempt_exits_0() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs a delivery-lead decision"
  bcs_run; local rc1=$?
  bcs_run; local rc2=$?
  assert_eq "$rc1" "2" "first attempt blocks" || { bcs_cleanup; return 1; }
  assert_eq "$rc2" "0" "same fingerprint within 20 min lets the session stop" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_status_request_exits_0() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs decision"
  local tr="$BCS_H/t.jsonl"
  printf '{"type":"user","message":{"content":"what is the status?"}}\n' > "$tr"
  bcs_run "{\"transcript_path\":\"$tr\"}"; local rc=$?
  assert_eq "$rc" "0" "status question may end the turn" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_unrelated_cwd_repo_exits_0() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs decision"
  mkdir -p "$BCS_H/other" && git -C "$BCS_H/other" init -q && git -C "$BCS_H/other" remote add origin https://github.com/acme/unrelated.git
  bcs_run "{\"cwd\":\"$BCS_H/other\"}"; local rc=$?
  assert_eq "$rc" "0" "unrelated product checkout is out of scope" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_garbage_input_fails_open_and_logs() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs decision"
  bcs_run 'not json {{{'; local rc=$?
  assert_eq "$rc" "0" "parse error must fail open" || { bcs_cleanup; return 1; }
  assert_eq "$(grep -c fail-open "$BCS_H/logs/pipeline/blocked-chain-stop.log")" "1" "error logged" || { bcs_cleanup; return 1; }
  bcs_cleanup
}


test_bcs_prod_and_risky_list_blocks_are_jp_only() {
  local txt
  for txt in "**[deployer] BLOCKED** deploy to prod with a destructive migration" \
             "**[deployer] BLOCKED** merge to main requires JP approval of the risky list" \
             "**[deployer] BLOCKED** needs JP go before production"; do
    bcs_setup 3600 "$txt"
    bcs_run; local rc=$?
    assert_eq "$rc" "0" "JP-only gate must not trap the session: $txt" || { bcs_cleanup; return 1; }
    bcs_cleanup
  done
}

test_bcs_stop_hook_active_never_traps_twice() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs a delivery-lead decision on the failing check"
  bcs_run '{"stop_hook_active":true}'; local rc=$?
  assert_eq "$rc" "0" "already continuing because of a Stop hook" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_orchestrator_transcript_exits_0() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs a delivery-lead decision on the failing check"
  local tr="$BCS_H/t.jsonl"
  printf '{"type":"agent-setting","agentSetting":"orchestrator"}\n{"type":"user","message":{"content":"go"}}\n' > "$tr"
  bcs_run "{\"transcript_path\":\"$tr\"}"; local rc=$?
  assert_eq "$rc" "0" "headless orchestrator must be allowed to stop" || { bcs_cleanup; return 1; }
  assert_eq "$BCS_OUT" "" "no stderr" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_non_orchestrator_agent_setting_still_blocks() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs a delivery-lead decision on the failing check"
  local tr="$BCS_H/t.jsonl"
  printf '{"type":"user","message":{"content":"go"}}\n' > "$tr"
  bcs_run "{\"transcript_path\":\"$tr\"}"; local rc=$?
  assert_eq "$rc" "2" "interactive transcript still blocked" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_unreadable_transcript_fails_open_and_logs() {
  bcs_setup 3600 "**[orchestrator] BLOCKED** needs a delivery-lead decision on the failing check"
  bcs_run "{\"transcript_path\":\"$BCS_H/missing.jsonl\"}"; local rc=$?
  assert_eq "$rc" "0" "unreadable transcript fails open" || { bcs_cleanup; return 1; }
  assert_eq "$(grep -c 'transcript_path unreadable' "$BCS_H/logs/pipeline/blocked-chain-stop.log")" "1" "logged" || { bcs_cleanup; return 1; }
  bcs_cleanup
}

test_bcs_settings_registers_hook() {
  assert_contains "$(cat "$ROOT_BCS/settings.json")" 'hooks/blocked-chain-stop.sh' "registered as a Stop hook" || return 1
  bash -n "$HOOK_BCS" || return 1
}

run_test test_bcs_dead_and_blocked_exits_2
run_test test_bcs_launched_minutes_ago_and_dead_exits_2
run_test test_bcs_old_dead_without_block_exits_0
run_test test_bcs_live_run_exits_0
run_test test_bcs_tombstone_exits_0
run_test test_bcs_jp_only_block_exits_0
run_test test_bcs_non_manual_launch_exits_0
run_test test_bcs_older_than_3h_exits_0
run_test test_bcs_loop_guard_second_attempt_exits_0
run_test test_bcs_status_request_exits_0
run_test test_bcs_unrelated_cwd_repo_exits_0
run_test test_bcs_garbage_input_fails_open_and_logs
run_test test_bcs_settings_registers_hook
run_test test_bcs_prod_and_risky_list_blocks_are_jp_only
run_test test_bcs_stop_hook_active_never_traps_twice
run_test test_bcs_orchestrator_transcript_exits_0
run_test test_bcs_non_orchestrator_agent_setting_still_blocks
run_test test_bcs_unreadable_transcript_fails_open_and_logs
