# #779 — orchestrate.sh renamed launcher.sh; orchestrate.sh stays as a thin compatibility wrapper.
#   AC1  launcher.sh holds the behaviour; the wrapper is <= 10 lines and only execs it; both names give identical stdout, stderr
#        (TTY note aside) and exit code, including exit 2 on jpmoya/claude-agents
#   AC2  nothing depends on the script's own basename: both names create the same pid-file / state names and the same claim
#   AC3  `git grep orchestrate.sh` returns only the wrapper, the compatibility tests (this one and the merge-base guard in
#        test-skip-mockups-after-terminal.sh, which reads the launcher under its pre-rename name) and the changelog (living.md)
#   AC4  hooks that read the Bash command decide the same for either name (no hook keys on the script name)
#   AC5  the supervisor calls launcher.sh; the orchestrator agent, `claude --agent orchestrator` and the orchestrate skill keep their names
# Fake gh = tests/lib mk_fake_gh; `claude` is a stub so nothing real starts. Prefix lr_ / LR_. Placeholder repo names only.

HERE_LR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_LR=$(cd "$HERE_LR/.." && pwd)
ROOT_LR=$(cd "$SKILL_LR/../.." && pwd)
NEW_LR="$SKILL_LR/launcher.sh"
OLD_LR="$SKILL_LR/orchestrate.sh"

lr_env() {  # lr_env <owner/repo the fake gh resolves the checkout to> -> LR_HOME LR_PIPE LR_REPO LR_BIN
  LR_HOME=$(new_home); LR_PIPE=$(new_pipe); LR_REPO="$LR_PIPE/checkout"
  fixture_repo "$LR_REPO" "$1"
  LR_BIN="$LR_HOME/.local/bin"; mkdir -p "$LR_BIN"
  mk_fake_gh "$LR_BIN"
  echo "$1" > "$LR_BIN/gh-name-with-owner"
  printf '#!/bin/bash\nexit 0\n' > "$LR_BIN/claude"; chmod +x "$LR_BIN/claude"   # never start a real session
  printf 'MEM_FLOOR_MB=0\nCLAIM_SETTLE_SECS=0\n' > "$LR_HOME/.claude/pipeline/config.local.sh"
}

lr_run() {  # lr_run <script> <args…> -> LR_OUT (stdout) LR_ERR (stderr) LR_RC; neither stream is a TTY
  local script=$1; shift; LR_RC=0
  LR_OUT=$(HOME="$LR_HOME" PATH="$LR_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$LR_PIPE" QUEUE="$LR_PIPE/queue" \
    LOGDIR="$LR_HOME/logs/pipeline" bash "$script" "$@" 2>"$LR_PIPE/stderr.txt") || LR_RC=$?
  LR_ERR=$(cat "$LR_PIPE/stderr.txt")
}

lr_cleanup() {
  local f pid
  for f in "$LR_PIPE"/orch-*.pid; do
    [ -e "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null); [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  done
  cleanup_running
  rm -rf "$LR_HOME" "$LR_PIPE"
}

lr_parity() {  # lr_parity <label> <args…> — run both names in the current env; same stdout, stderr and rc. Leaves the launcher run in LR_*.
  local label=$1; shift; local rc=0 o1 e1 r1
  lr_run "$NEW_LR" "$@"; o1=$LR_OUT; e1=$LR_ERR; r1=$LR_RC
  lr_run "$OLD_LR" "$@"
  assert_eq "$LR_OUT" "$o1" "$label: identical stdout" || rc=1
  assert_eq "$LR_ERR" "$e1" "$label: identical stderr" || rc=1
  assert_eq "$LR_RC" "$r1" "$label: identical exit code" || rc=1
  LR_RC=$r1; LR_OUT=$o1; LR_ERR=$e1
  return $rc
}

test_lr_ac1_wrapper_is_a_short_exec_of_launcher() {
  local rc=0 n
  assert_file_exists "$NEW_LR" "AC1: launcher.sh exists" || rc=1
  [ -x "$NEW_LR" ] || { fail "AC1: launcher.sh is not executable"; rc=1; }
  [ -x "$OLD_LR" ] || { fail "AC1: the orchestrate.sh wrapper is not executable (supervisor and old callers exec it directly)"; rc=1; }
  n=$(wc -l < "$OLD_LR" | tr -d ' ')
  [ "$n" -le 10 ] || { fail "AC1: wrapper is $n lines, expected <= 10"; rc=1; }
  grep -qE '^[[:space:]]*exec .*launcher\.sh' "$OLD_LR" || { fail "AC1: wrapper does not exec launcher.sh"; rc=1; }
  grep -q '\-t 2' "$OLD_LR" || { fail "AC1: the deprecation note must be gated on stderr being a TTY (-t 2)"; rc=1; }
  assert_not_contains "$(cat "$OLD_LR")" "config.sh" "AC1: the wrapper carries no behaviour of its own" || rc=1
  [ "$(wc -l < "$NEW_LR" | tr -d ' ')" -gt 200 ] || { fail "AC1: launcher.sh does not hold the full former script"; rc=1; }
  return $rc
}

test_lr_ac1_direct_route_refusal_is_identical_through_the_wrapper() {
  lr_env jpmoya/claude-agents
  local rc=0
  lr_parity "AC1 refusal" "$LR_REPO" 627 || rc=1
  assert_eq "$LR_RC" "2" "AC1: exit 2 on the direct-route repo (output: $LR_OUT $LR_ERR)" || rc=1
  assert_contains "$LR_OUT$LR_ERR" "direct-route repo" "AC1: refusal message present" || rc=1
  lr_parity "AC1 refusal --force" --force "$LR_REPO" 627 || rc=1
  assert_eq "$LR_RC" "2" "AC1: --force still exits 2" || rc=1
  assert_eq "$(grep -cE '^issue (comment|edit) ' "$LR_BIN/gh-calls.log")" "0" "AC1: no issue write on either name" || rc=1
  lr_cleanup; return $rc
}

test_lr_ac1_status_queue_and_bad_issue_are_identical_through_the_wrapper() {
  lr_env example-owner/project-a
  local rc=0
  mk_running "$LR_PIPE" 41 "$LR_REPO"
  lr_parity "AC1 status N" status 41 || rc=1
  assert_eq "$LR_RC" "0" "AC1: status exits 0" || rc=1
  assert_contains "$LR_OUT" "#41  running (pid " "AC1: status lists the run" || rc=1
  lr_parity "AC1 status all" status || rc=1
  lr_parity "AC1 queue" queue || rc=1
  assert_eq "$LR_RC" "0" "AC1: queue exits 0" || rc=1
  lr_parity "AC1 non-numeric issue" "$LR_REPO" abc || rc=1
  assert_eq "$LR_RC" "2" "AC1: a non-numeric issue exits 2" || rc=1
  assert_contains "$LR_OUT$LR_ERR" "launcher.sh stop <N>" "AC1: hint names launcher.sh, whichever name was invoked" || rc=1
  lr_cleanup; return $rc
}

test_lr_ac1_deprecation_note_only_on_a_tty() {
  lr_env example-owner/project-a
  local rc=0 tty
  lr_run "$OLD_LR" queue
  assert_not_contains "$LR_ERR" "deprecated" "AC1: no note when stderr is not a TTY" || rc=1
  if command -v script >/dev/null 2>&1; then
    tty=$(HOME="$LR_HOME" PATH="$LR_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$LR_PIPE" QUEUE="$LR_PIPE/queue" \
      LOGDIR="$LR_HOME/logs/pipeline" script -q /dev/null bash "$OLD_LR" queue 2>&1 < /dev/null | tr -d '\r')
    assert_contains "$tty" "launcher.sh" "AC1: on a TTY the wrapper says to use launcher.sh" || rc=1
    assert_contains "$tty" "deprecated" "AC1: on a TTY the wrapper prints the deprecation note" || rc=1
  fi
  lr_cleanup; return $rc
}

lr_state_names() {  # sorted orch-* file names under PIPE and QUEUE, minus logs (nothing run-specific)
  ( cd "$LR_PIPE" && ls orch-* queue/orch-* 2>/dev/null | grep -v '\.log$' | sort | tr '\n' ' ' )
}

lr_claims() {  # claim comments posted for issue 42, minus timestamps / pids / hosts
  grep '^issue comment 42 ' "$LR_BIN/gh-calls.log" | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z?//g; s/pid[= ][0-9]+//g; s/host[= ][^ ]+//g'
}

test_lr_ac2_either_name_makes_the_same_state_files_and_claim() {
  local rc=0 s_new s_old c_new c_old
  lr_env example-owner/project-a
  lr_run "$NEW_LR" "$LR_REPO" 42
  assert_contains "$LR_OUT" "launched orchestrator for example-owner/project-a#42" "AC2: launcher.sh launches" || rc=1
  s_new=$(lr_state_names); c_new=$(lr_claims)
  lr_cleanup
  lr_env example-owner/project-a
  lr_run "$OLD_LR" "$LR_REPO" 42
  assert_contains "$LR_OUT" "launched orchestrator for example-owner/project-a#42" "AC2: the wrapper launches" || rc=1
  s_old=$(lr_state_names); c_old=$(lr_claims)
  lr_cleanup
  assert_contains "$s_new" "orch-example-owner_project-a-42.pid" "AC2: pid file keyed by repo+issue, not by script name" || rc=1
  assert_eq "$s_old" "$s_new" "AC2: same state and queue file names via either name" || rc=1
  assert_contains "$c_new" "claim:" "AC2: the claim comment is posted" || rc=1
  assert_eq "$c_old" "$c_new" "AC2: same claim comment via either name" || rc=1
  return $rc
}

test_lr_ac2_launcher_never_reads_its_own_basename() {
  local rc=0
  if grep -nE 'basename|\$0|\$\{0' "$NEW_LR" | grep -vE '^[0-9]+:[[:space:]]*#'; then
    fail "AC2: launcher.sh uses \$0/basename (above); it must locate itself only through BASH_SOURCE dirname"; rc=1
  fi
  assert_contains "$(cat "$NEW_LR")" 'dirname "${BASH_SOURCE[0]}"' "AC2: launcher.sh resolves HERE from BASH_SOURCE" || rc=1
  return $rc
}

test_lr_ac3_only_the_wrapper_the_compat_test_and_the_changelog_name_orchestrate_sh() {
  local rc=0 got want
  if ! git -C "$ROOT_LR" rev-parse --git-dir >/dev/null 2>&1; then echo "    (skipped: not a git checkout)"; return 0; fi
  got=$(git -C "$ROOT_LR" grep -l 'orchestrate\.sh' | sort | tr '\n' ' ')
  want="living.md skills/orchestrate/orchestrate.sh skills/orchestrate/tests/test-launcher-rename-779.sh skills/orchestrate/tests/test-skip-mockups-after-terminal.sh "
  assert_eq "$got" "$want" "AC3: files still naming orchestrate.sh" || rc=1
  return $rc
}

test_lr_ac4_command_reading_hooks_decide_the_same_for_either_name() {
  local rc=0 h cmd json o_new o_old r_new r_old H; H=$(new_home)
  for h in block-nonproject-goal dedupe-ticket-guard ticket-intake-guard no-duplicate-stage email-send-guard protect-locked-tests; do
    for cmd in '~/.claude/skills/orchestrate/NAME /work/project-a 123' 'NAME status 123' 'nohup ~/.claude/skills/orchestrate/NAME stop example-owner/project-a#9 &'; do
      json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "${cmd//NAME/launcher.sh}")
      r_new=0; o_new=$(printf '%s' "$json" | env -u PIPELINE_AGENT HOME="$H" bash "$ROOT_LR/hooks/$h.sh" 2>&1) || r_new=$?
      json=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "${cmd//NAME/orchestrate.sh}")
      r_old=0; o_old=$(printf '%s' "$json" | env -u PIPELINE_AGENT HOME="$H" bash "$ROOT_LR/hooks/$h.sh" 2>&1) || r_old=$?
      assert_eq "$r_old" "$r_new" "AC4: $h exit code for [$cmd]" || rc=1
      assert_eq "$o_old" "$o_new" "AC4: $h output for [$cmd]" || rc=1
    done
  done
  for h in block-orchestrator-agent blocked-chain-stop; do
    assert_contains "$(cat "$ROOT_LR/hooks/$h.sh")" "launcher.sh" "AC4: $h tells the agent to run launcher.sh" || rc=1
  done
  rm -rf "$H"; return $rc
}

test_lr_ac5_callers_use_launcher_and_the_orchestrator_names_survive() {
  local rc=0
  assert_contains "$(cat "$SKILL_LR/supervisor.sh")" '/launcher.sh" --force' "AC5: the supervisor's forced launch calls launcher.sh" || rc=1
  assert_contains "$(cat "$SKILL_LR/supervisor.sh")" '--agent orchestrator' "AC5: supervisor still starts claude --agent orchestrator" || rc=1
  assert_contains "$(cat "$NEW_LR")" '--agent orchestrator' "AC5: launcher still starts claude --agent orchestrator" || rc=1
  assert_file_exists "$ROOT_LR/agents/orchestrator.md" "AC5: the orchestrator agent keeps its name" || rc=1
  assert_contains "$(cat "$SKILL_LR/SKILL.md")" "name: orchestrate" "AC5: the orchestrate skill keeps its name" || rc=1
  assert_contains "$(cat "$SKILL_LR/SKILL.md")" "launcher.sh" "AC5: SKILL.md tells the reader to run launcher.sh" || rc=1
  return $rc
}

echo "-- launcher.sh rename + orchestrate.sh wrapper (issue #779 AC1-AC5)"
run_test test_lr_ac1_wrapper_is_a_short_exec_of_launcher
run_test test_lr_ac1_direct_route_refusal_is_identical_through_the_wrapper
run_test test_lr_ac1_status_queue_and_bad_issue_are_identical_through_the_wrapper
run_test test_lr_ac1_deprecation_note_only_on_a_tty
run_test test_lr_ac2_either_name_makes_the_same_state_files_and_claim
run_test test_lr_ac2_launcher_never_reads_its_own_basename
run_test test_lr_ac3_only_the_wrapper_the_compat_test_and_the_changelog_name_orchestrate_sh
run_test test_lr_ac4_command_reading_hooks_decide_the_same_for_either_name
run_test test_lr_ac5_callers_use_launcher_and_the_orchestrator_names_survive
