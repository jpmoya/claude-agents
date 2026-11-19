# #632 — orchestrate.sh and direct-route repos.
#   AC2  a launch whose `gh repo view` resolves to jpmoya/claude-agents exits 2 with "direct-route repo … see CLAUDE.md",
#        the fake gh records no `issue comment` and no `issue edit`, no orch-* file exists under PIPE or QUEUE afterwards;
#        `--force` changes nothing
#   AC3  the same harness on an app repo proceeds past the refusal point (the claim comment is recorded)
#   AC4  stop / status on a pre-seeded claude-agents run behave as before (exit 0, no refusal message)
# Fake gh = tests/lib mk_fake_gh (gh-name-with-owner answers `repo view`); `claude` is a stub so nothing real starts.
# Prefix dro_ / DRO_. Placeholder repo names for the app repo (public repo).

HERE_DRO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_DRO="$HERE_DRO/../orchestrate.sh"

dro_env() {  # dro_env <owner/repo the fake gh resolves the checkout to> -> DRO_HOME DRO_PIPE DRO_REPO DRO_BIN
  DRO_HOME=$(new_home); DRO_PIPE=$(new_pipe); DRO_REPO="$DRO_PIPE/checkout"
  fixture_repo "$DRO_REPO" "$1"
  DRO_BIN="$DRO_HOME/.local/bin"; mkdir -p "$DRO_BIN"
  mk_fake_gh "$DRO_BIN"
  echo "$1" > "$DRO_BIN/gh-name-with-owner"
  printf '#!/bin/bash\nexit 0\n' > "$DRO_BIN/claude"; chmod +x "$DRO_BIN/claude"   # never start a real session
  printf 'MEM_FLOOR_MB=0\nCLAIM_SETTLE_SECS=0\n' > "$DRO_HOME/.claude/pipeline/config.local.sh"
}

dro_run() {  # dro_run <orchestrate.sh args…> -> DRO_OUT (stdout+stderr) DRO_RC
  DRO_OUT=$(HOME="$DRO_HOME" PATH="$DRO_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$DRO_PIPE" QUEUE="$DRO_PIPE/queue" \
    LOGDIR="$DRO_HOME/logs/pipeline" bash "$ORCH_DRO" "$@" 2>&1); DRO_RC=$?
}

dro_cleanup() {
  local f pid
  for f in "$DRO_PIPE"/orch-*.pid; do
    [ -e "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null); [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  done
  cleanup_running
  rm -rf "$DRO_HOME" "$DRO_PIPE"
}

dro_orch_files() { ls "$DRO_PIPE"/orch-* "$DRO_PIPE"/queue/orch-* 2>/dev/null | wc -l | tr -d ' '; }   # state + queue entries
dro_writes() { grep -cE '^issue (comment|edit) ' "$DRO_BIN/gh-calls.log"; }                               # the two launch-path writes
dro_non_repo_view_calls() { grep -vcE '^repo view ' "$DRO_BIN/gh-calls.log"; }                           # anything but the resolve

test_dro_ac2_direct_route_repo_is_refused_before_any_write_or_state_file() {
  dro_env jpmoya/claude-agents
  local rc=0 msg="jpmoya/claude-agents#627 is a direct-route repo"
  dro_run "$DRO_REPO" 627
  assert_eq "$DRO_RC" "2" "AC2: exit 2 (output: $DRO_OUT)" || rc=1
  assert_contains "$DRO_OUT" "$msg" "AC2: message names repo#issue and says direct-route repo" || rc=1
  assert_contains "$DRO_OUT" "see CLAUDE.md" "AC2: message points at CLAUDE.md" || rc=1
  assert_contains "$DRO_OUT" "interactive session with subagents" "AC2: message says who implements it" || rc=1
  assert_not_contains "$DRO_OUT" "launched orchestrator" "AC2: nothing launched" || rc=1
  assert_not_contains "$DRO_OUT" "queued #" "AC2: nothing queued" || rc=1
  assert_eq "$(dro_writes)" "0" "AC2: no issue comment / issue edit recorded" || rc=1
  assert_eq "$(dro_non_repo_view_calls)" "0" "AC2: the only gh call is the owner/repo resolve" || rc=1
  assert_eq "$(dro_orch_files)" "0" "AC2: no orch-* file under PIPE or QUEUE" || rc=1
  # --force is not a bypass (the point is that no instruction or habit can route this repo through the pipeline)
  dro_run --force "$DRO_REPO" 627
  assert_eq "$DRO_RC" "2" "AC2: --force still exits 2 (output: $DRO_OUT)" || rc=1
  assert_contains "$DRO_OUT" "direct-route repo" "AC2: --force gets the same refusal" || rc=1
  assert_eq "$(dro_writes)" "0" "AC2: --force made no write either" || rc=1
  assert_eq "$(dro_orch_files)" "0" "AC2: --force left no state file" || rc=1
  dro_cleanup; return $rc
}

test_dro_ac2_case_insensitive_resolve_is_refused_too() {
  dro_env JPMoya/Claude-Agents   # GitHub owner/repo is case-insensitive; `gh repo view` may echo the configured spelling
  local rc=0
  dro_run "$DRO_REPO" 627
  assert_eq "$DRO_RC" "2" "AC2: any-case owner/repo is refused (output: $DRO_OUT)" || rc=1
  assert_eq "$(dro_writes)" "0" "AC2: no write" || rc=1
  dro_cleanup; return $rc
}

test_dro_ac3_other_repo_proceeds_past_the_refusal_point() {
  dro_env example-owner/project-a
  local rc=0
  dro_run "$DRO_REPO" 42
  assert_not_contains "$DRO_OUT" "direct-route" "AC3: an app repo is not refused as direct-route" || rc=1
  grep -q '^issue comment 42 .*\*\*\[supervisor\] NOTE\*\* claim: ' "$DRO_BIN/gh-calls.log" \
    || { fail "AC3: the claim comment was not posted — the launch did not get past the refusal point (output: $DRO_OUT)"; rc=1; }
  dro_cleanup; return $rc
}

test_dro_ac4_stop_and_status_still_work_on_an_old_claude_agents_run() {
  dro_env jpmoya/claude-agents
  local rc=0 k
  k=$(rk "$DRO_REPO" 627)
  mk_running "$DRO_PIPE" 627 "$DRO_REPO"
  dro_run status 627
  assert_eq "$DRO_RC" "0" "AC4: status exits 0 (output: $DRO_OUT)" || rc=1
  assert_contains "$DRO_OUT" "#627  running (pid " "AC4: status lists the run as running" || rc=1
  assert_not_contains "$DRO_OUT" "direct-route" "AC4: status carries no refusal" || rc=1
  dro_run stop 627
  assert_eq "$DRO_RC" "0" "AC4: stop exits 0 (output: $DRO_OUT)" || rc=1
  assert_contains "$DRO_OUT" "stopped orchestrator for jpmoya/claude-agents#627" "AC4: stop kills the run" || rc=1
  assert_contains "$DRO_OUT" "wrote tombstone" "AC4: stop writes the tombstone" || rc=1
  assert_not_contains "$DRO_OUT" "direct-route" "AC4: stop carries no refusal" || rc=1
  assert_file_exists "$DRO_PIPE/orch-$k.stopped" "AC4: tombstone file" || rc=1
  dro_run status "jpmoya/claude-agents#627"
  assert_eq "$DRO_RC" "0" "AC4: status by <owner/repo>#N exits 0 (output: $DRO_OUT)" || rc=1
  assert_contains "$DRO_OUT" "#627  stopped (manual)" "AC4: status shows the stopped run" || rc=1
  dro_cleanup; return $rc
}

echo "-- direct-route repos: orchestrate.sh (issue #632 AC2-AC4)"
run_test test_dro_ac2_direct_route_repo_is_refused_before_any_write_or_state_file
run_test test_dro_ac2_case_insensitive_resolve_is_refused_too
run_test test_dro_ac3_other_repo_proceeds_past_the_refusal_point
run_test test_dro_ac4_stop_and_status_still_work_on_an_old_claude_agents_run
