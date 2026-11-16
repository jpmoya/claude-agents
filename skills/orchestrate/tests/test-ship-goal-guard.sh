# skills/orchestrate/ship-goal.sh + hooks/ship-goal-guard.sh — a turn cannot end while a ship-to-prod goal is unverified.
# verify-shipped.sh is replaced by a stub (its own behaviour is pinned in test-verify-shipped.sh); every case uses a throwaway
# ledger dir and HOME, never the host's ~/.claude/state. Exit 2 = the session must continue, 0 = it may stop. Prefix sg_ / SG_.

HERE_SG=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_SG=$(cd "$HERE_SG/../../.." && pwd)
GOAL_SG="$ROOT_SG/skills/orchestrate/ship-goal.sh"
HOOK_SG="$ROOT_SG/hooks/ship-goal-guard.sh"

sg_setup() {  # SG_D (scratch), a stub verify whose exit code and text the case sets with sg_verify
  SG_D=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-sg.XXXXXX")
  mkdir -p "$SG_D/ledger" "$SG_D/home"
  cat > "$SG_D/verify" <<'EOF'
#!/bin/bash
echo "$*" >> "$SG_DIR/verify-calls.log"
cat "$SG_DIR/verify-out"
exit "$(cat "$SG_DIR/verify-rc")"
EOF
  chmod +x "$SG_D/verify"
  sg_verify 1 "example-owner/project-a#7: NOT SHIPPED (feature.txt (absent on main))"
}

sg_verify() { printf '%s\n' "$1" > "$SG_D/verify-rc"; printf '%s\n' "$2" > "$SG_D/verify-out"; }
sg_cleanup() { rm -rf "$SG_D"; }

sg_goal() { env SG_DIR="$SG_D" SHIP_GOALS_DIR="$SG_D/ledger" SHIP_VERIFY="$SG_D/verify" bash "$GOAL_SG" "$@"; }

# sg_hook [stdin json] [extra env…] -> stderr in SG_OUT, returns the hook's exit code
sg_hook() {
  local in=${1:-'{}'}
  shift
  SG_OUT=$(printf '%s' "$in" | env -u PIPELINE_AGENT HOME="$SG_D/home" SG_DIR="$SG_D" SHIP_GOALS_DIR="$SG_D/ledger" \
    SHIP_VERIFY="$SG_D/verify" SGG_SHIP_GOAL="$GOAL_SG" SGG_CACHE_SECS=0 "$@" bash "$HOOK_SG" 2>&1)
  return $?
}

sg_status() { jq -r .status "$SG_D/ledger/$1.json"; }

test_sg_done_only_when_verification_passes() {
  sg_setup
  sg_goal start faster-ci example-owner/project-a '#7' 8 >/dev/null || { sg_cleanup; return 1; }
  assert_eq "$(sg_status faster-ci)" "open" "start opens the goal" || { sg_cleanup; return 1; }
  assert_eq "$(jq -c .prs "$SG_D/ledger/faster-ci.json")" "[7,8]" "PR numbers recorded" || { sg_cleanup; return 1; }
  sg_goal done faster-ci >/dev/null 2>&1; local rc=$?
  assert_eq "$rc" "1" "done fails while verification fails" || { sg_cleanup; return 1; }
  assert_eq "$(sg_status faster-ci)" "open" "still open" || { sg_cleanup; return 1; }
  sg_verify 0 "example-owner/project-a#7: SHIPPED"
  sg_goal done faster-ci >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "0" "done succeeds once verify-shipped exits 0" || { sg_cleanup; return 1; }
  assert_eq "$(sg_status faster-ci)" "done" "closed" || { sg_cleanup; return 1; }
  assert_contains "$(cat "$SG_D/verify-calls.log")" "example-owner/project-a 7 8" "verify got the repo and PRs" || { sg_cleanup; return 1; }
  sg_cleanup
}

test_sg_start_refuses_bad_input_and_duplicates() {
  sg_setup
  sg_goal start 'bad name' example-owner/project-a 7 >/dev/null 2>&1; local rc=$?
  assert_eq "$rc" "3" "bad name" || { sg_cleanup; return 1; }
  sg_goal start g1 example-owner/project-a >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "3" "no PRs" || { sg_cleanup; return 1; }
  sg_goal start g1 example-owner/project-a 7 >/dev/null 2>&1
  sg_goal start g1 example-owner/project-a 8 >/dev/null 2>&1; rc=$?
  assert_eq "$rc" "3" "an open goal is not silently replaced" || { sg_cleanup; return 1; }
  sg_cleanup
}

test_sg_hook_blocks_then_allows() {
  sg_setup
  sg_goal start faster-ci example-owner/project-a 7 >/dev/null
  sg_hook; local rc=$?
  assert_eq "$rc" "2" "open unverified goal blocks the stop" || { sg_cleanup; return 1; }
  assert_contains "$SG_OUT" "not live on prod" "short reason" || { sg_cleanup; return 1; }
  assert_contains "$SG_OUT" "faster-ci" "names the goal" || { sg_cleanup; return 1; }
  assert_contains "$SG_OUT" "NOT SHIPPED (feature.txt" "carries the verification result" || { sg_cleanup; return 1; }
  sg_verify 0 "example-owner/project-a#7: SHIPPED"
  sg_hook; rc=$?
  assert_eq "$rc" "0" "verified goal lets the turn end" || { sg_cleanup; return 1; }
  assert_eq "$(sg_status faster-ci)" "done" "and is closed, so it never blocks again" || { sg_cleanup; return 1; }
  sg_cleanup
}

test_sg_hook_no_goals_or_pipeline_agent_exits_0() {
  sg_setup
  sg_hook; local rc=$?
  assert_eq "$rc" "0" "no goals" || { sg_cleanup; return 1; }
  sg_goal start g1 example-owner/project-a 7 >/dev/null
  SG_OUT=$(printf '{}' | env PIPELINE_AGENT=fullstack-developer HOME="$SG_D/home" SHIP_GOALS_DIR="$SG_D/ledger" SGG_SHIP_GOAL="$GOAL_SG" bash "$HOOK_SG" 2>&1); rc=$?
  assert_eq "$rc" "0" "pipeline stage processes are never trapped" || { sg_cleanup; return 1; }
  sg_cleanup
}

test_sg_hook_jp_only_block_in_last_message_exits_0() {
  sg_setup
  sg_goal start g1 example-owner/project-a 7 >/dev/null
  sg_hook '{"last_assistant_message":"Blocked: the production deploy needs JP go before I can continue."}'; local rc=$?
  assert_eq "$rc" "0" "blocked on a JP-only item may stop" || { sg_cleanup; return 1; }
  sg_hook '{"last_assistant_message":"Blocked on a flaky CI job, retrying later."}'; rc=$?
  assert_eq "$rc" "2" "blocked on something the session can fix may not" || { sg_cleanup; return 1; }
  sg_hook '{"last_assistant_message":"Blocked: the production deploy is still running."}'; rc=$?
  assert_eq "$rc" "2" "a running prod deploy is not a JP-only block (the 2026-11-16 incident)" || { sg_cleanup; return 1; }
  sg_hook '{"last_assistant_message":"All shipped to staging, the production deploy is next."}'; rc=$?
  assert_eq "$rc" "2" "mentioning prod without saying blocked does not escape" || { sg_cleanup; return 1; }
  sg_cleanup
}

test_sg_hook_never_loops_forever() {
  sg_setup
  sg_goal start g1 example-owner/project-a 7 >/dev/null
  sg_hook '{}' SGG_MAX_BLOCKS=2; local r1=$?
  sg_hook '{}' SGG_MAX_BLOCKS=2; local r2=$?
  sg_hook '{}' SGG_MAX_BLOCKS=2; local r3=$?
  assert_eq "$r1$r2$r3" "220" "two blocks, then the cap lets the session out" || { sg_cleanup; return 1; }
  assert_eq "$(sg_status g1)" "open" "the goal itself stays open" || { sg_cleanup; return 1; }
  sg_cleanup
}

test_sg_hook_ignores_stale_goals() {
  sg_setup
  sg_goal start g1 example-owner/project-a 7 >/dev/null
  sg_hook '{}' SGG_NOW=$(( $(date +%s) + 3 * 86400 )); local rc=$?
  assert_eq "$rc" "0" "a goal older than the TTL is another session's leftover" || { sg_cleanup; return 1; }
  sg_cleanup
}

test_sg_hook_reuses_a_fresh_result_instead_of_calling_github() {
  sg_setup
  sg_goal start g1 example-owner/project-a 7 >/dev/null
  sg_hook '{}' SGG_CACHE_SECS=3600 >/dev/null
  sg_hook '{}' SGG_CACHE_SECS=3600 >/dev/null
  assert_eq "$(wc -l < "$SG_D/verify-calls.log" | tr -d ' ')" "1" "second Stop within the cache window makes no verification call" || { sg_cleanup; return 1; }
  sg_cleanup
}

test_sg_cancel_releases_the_hook() {
  sg_setup
  sg_goal start g1 example-owner/project-a 7 >/dev/null
  sg_goal cancel g1 "JP dropped it" >/dev/null
  sg_hook; local rc=$?
  assert_eq "$rc" "0" "a cancelled goal does not block" || { sg_cleanup; return 1; }
  sg_cleanup
}

run_test test_sg_done_only_when_verification_passes
run_test test_sg_start_refuses_bad_input_and_duplicates
run_test test_sg_hook_blocks_then_allows
run_test test_sg_hook_no_goals_or_pipeline_agent_exits_0
run_test test_sg_hook_jp_only_block_in_last_message_exits_0
run_test test_sg_hook_never_loops_forever
run_test test_sg_hook_ignores_stale_goals
run_test test_sg_hook_reuses_a_fresh_result_instead_of_calling_github
run_test test_sg_cancel_releases_the_hook
