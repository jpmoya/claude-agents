# Orchestrator concurrency gate (agents/orchestrator.md, `wait_for_capacity`) — regression guard.
# The gate went silently inert once (pgrep -ax never matched anything, so ACTIVE was always 0) and
# nothing failed. These cases extract the shipped function, run it against a stub `ps` fixture in
# `ps -axo comm=,args=` format and a no-op `sleep`, and assert it blocks / passes at the right counts.
# Nothing here touches /tmp/pipeline: the stubs live in a mktemp -d dir.

HERE_GATE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_MD_GATE="$HERE_GATE/../../../agents/orchestrator.md"

# gate_rep <count> <line> — prints <line> <count> times
gate_rep() {
  local n=$1 line=$2 i=0
  while [ "$i" -lt "$n" ]; do
    printf '%s\n' "$line"
    i=$((i + 1))
  done
}

GATE_MATCH='claude claude --dangerously-skip-permissions --agent x -p y'

# gate_run <fixture-file> — runs the extracted wait_for_capacity with stub ps/sleep first on PATH.
# Prints the function's output; returns its exit code.
# HOME is a directory inside the mktemp -d holding a copy of the repo's config.sh and no
# config.local.sh, so results never depend on the host's installed config (#40). Knobs, read from
# the caller's scope (gate_case passes no arguments through):
#   GATE_NO_CONFIG=1      — leave config.sh out of the test HOME
#   GATE_LOCAL_CONFIG=... — write this text to $HOME/.claude/pipeline/config.local.sh
#   GATE_AFTER=...        — eval'd in the gate's shell after wait_for_capacity returns (its output
#                           is appended; the gate's exit code is kept)
gate_run() {
  local fixture=$1 dir out rc
  dir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-gate.XXXXXX")
  mkdir -p "$dir/home/.claude/skills/orchestrate" "$dir/home/.claude/pipeline"
  [ -n "${GATE_NO_CONFIG:-}" ] || cp "$HERE_GATE/../config.sh" "$dir/home/.claude/skills/orchestrate/config.sh"
  [ -z "${GATE_LOCAL_CONFIG:-}" ] || printf '%s\n' "$GATE_LOCAL_CONFIG" > "$dir/home/.claude/pipeline/config.local.sh"
  sed -n '/^wait_for_capacity() {/,/^}/p' "$ORCH_MD_GATE" > "$dir/gate.sh"
  printf '#!/bin/bash\ncat "%s"\n' "$fixture" > "$dir/ps"
  printf '#!/bin/bash\nexit 0\n' > "$dir/sleep"
  chmod +x "$dir/ps" "$dir/sleep"
  out=$( ( HOME="$dir/home"; PATH="$dir:$PATH"; . "$dir/gate.sh"; wait_for_capacity; rc=$?; eval "${GATE_AFTER:-}"; exit "$rc" ) 2>&1 ); rc=$?
  rm -rf "$dir"
  printf '%s\n' "$out"
  return "$rc"
}

# gate_case <fixture-builder-cmd...> — builds a fixture via the given command, runs the gate.
# Sets GATE_OUT / GATE_RC in the caller's scope (no subshell around the call).
gate_case() {
  local fixture
  fixture=$(mktemp "${TMPDIR:-/tmp}/orch-test-gate-fixture.XXXXXX")
  "$@" > "$fixture"
  GATE_OUT=$(gate_run "$fixture"); GATE_RC=$?
  rm -f "$fixture"
}

gate_fx_wrappers() { gate_rep 20 'bash bash -c claude --dangerously-skip-permissions --agent x -p y'; gate_rep 2 "$GATE_MATCH"; }
gate_fx_noflag()   { gate_rep 20 'claude claude --agent x -p y'; gate_rep 2 "$GATE_MATCH"; }

test_gate_extraction_nonempty_and_no_pgrep() {
  local fn
  fn=$(sed -n '/^wait_for_capacity() {/,/^}/p' "$ORCH_MD_GATE")
  [ -n "$fn" ] || { fail "wait_for_capacity not found in agents/orchestrator.md"; return 1; }
  assert_not_contains "$fn" "pgrep" "gate must not use pgrep" || return 1
}

test_gate_blocks_over_capacity() {
  gate_case gate_rep 12 "$GATE_MATCH"
  [ "$GATE_RC" -ne 0 ] || { fail "12 matching lines: expected non-zero, got 0"; return 1; }
  assert_contains "$GATE_OUT" "Aborting dispatch" "12 matching lines" || return 1
}

test_gate_passes_under_capacity() {
  gate_case gate_rep 3 "$GATE_MATCH"
  assert_exit0 "$GATE_RC" "3 matching lines" || return 1
}

test_gate_boundary_9_lines_passes() {
  gate_case gate_rep 9 "$GATE_MATCH"
  assert_exit0 "$GATE_RC" "9 lines (ACTIVE=8)" || return 1
}

test_gate_boundary_10_lines_blocks() {
  gate_case gate_rep 10 "$GATE_MATCH"
  [ "$GATE_RC" -ne 0 ] || { fail "10 lines (ACTIVE=9): expected non-zero, got 0"; return 1; }
}

test_gate_ignores_bash_wrappers() {
  gate_case gate_fx_wrappers
  assert_exit0 "$GATE_RC" "20 bash -c wrappers + 2 claude" || return 1
}

test_gate_ignores_claude_without_skip_permissions() {
  gate_case gate_fx_noflag
  assert_exit0 "$GATE_RC" "20 claude without flag + 2 matching" || return 1
}

test_gate_counts_macos_path_prefixed_comm() {
  gate_case gate_rep 10 "/opt/homebrew/bin/claude /opt/homebrew/bin/claude --dangerously-skip-permissions --agent x -p y"
  [ "$GATE_RC" -ne 0 ] || { fail "10 path-prefixed claude lines (ACTIVE=9): expected non-zero, got 0"; return 1; }
}

# --- #40: interactive sessions are not counted; ceiling comes from config ---------------------

GATE_INTERACTIVE='claude claude --dangerously-skip-permissions'

gate_fx_8_agent_9_interactive() { gate_rep 8 "$GATE_MATCH"; gate_rep 9 "$GATE_INTERACTIVE"; }

# gate_case_with <no-config> <local-config-text> <fixture-builder-cmd...> — gate_case with the
# gate_run knobs set for this one call only.
gate_case_with() {
  GATE_NO_CONFIG=$1; GATE_LOCAL_CONFIG=$2; shift 2
  gate_case "$@"
  GATE_NO_CONFIG=; GATE_LOCAL_CONFIG=
}

test_gate_ignores_interactive_sessions_mixed() {
  gate_case gate_fx_8_agent_9_interactive
  assert_exit0 "$GATE_RC" "8 --agent + 9 interactive (ACTIVE=7)" || return 1
}

test_gate_ignores_interactive_sessions_only() {
  gate_case gate_rep 30 "$GATE_INTERACTIVE"
  assert_exit0 "$GATE_RC" "0 --agent + 30 interactive" || return 1
}

test_gate_config_declares_max_claude_procs() {
  local cfg="$HERE_GATE/../config.sh" n after
  n=$(grep -c '^MAX_CLAUDE_PROCS=8' "$cfg")
  assert_eq "$n" "1" "config.sh: count of ^MAX_CLAUDE_PROCS=8 lines" || return 1
  after=$(grep -A1 '^MAX_CONCURRENT=3' "$cfg" | sed -n 2p)
  assert_contains "$after" "MAX_CLAUDE_PROCS=8" "line directly after MAX_CONCURRENT=3" || return 1
}

test_gate_example_config_mentions_max_claude_procs() {
  local after
  after=$(grep -A1 '^# MAX_CONCURRENT=3' "$HERE_GATE/../config.local.example.sh" | sed -n 2p)
  assert_eq "$after" "# MAX_CLAUDE_PROCS=8" "example: line directly under # MAX_CONCURRENT=3" || return 1
}

test_gate_honours_local_override() {
  gate_case_with "" "MAX_CLAUDE_PROCS=2" gate_rep 3 "$GATE_MATCH"
  assert_exit0 "$GATE_RC" "override 2, 3 --agent lines (ACTIVE=2)" || return 1
  gate_case_with "" "MAX_CLAUDE_PROCS=2" gate_rep 4 "$GATE_MATCH"
  [ "$GATE_RC" -ne 0 ] || { fail "override 2, 4 --agent lines (ACTIVE=3): expected non-zero, got 0"; return 1; }
}

test_gate_function_has_no_max_concurrent_or_16() {
  local fn
  fn=$(sed -n '/^wait_for_capacity() {/,/^}/p' "$ORCH_MD_GATE")
  [ -n "$fn" ] || { fail "wait_for_capacity not found in agents/orchestrator.md"; return 1; }
  assert_not_contains "$fn" "MAX_CONCURRENT" "gate must not use the orchestrator-slot variable" || return 1
  assert_not_contains "$fn" "=16" "gate must not carry a hand-raised ceiling" || return 1
  assert_contains "$fn" "MAX_CLAUDE_PROCS" "gate reads MAX_CLAUDE_PROCS" || return 1
}

test_gate_fallback_when_config_missing() {
  gate_case_with 1 "" gate_rep 9 "$GATE_MATCH"
  assert_exit0 "$GATE_RC" "no config.sh, 9 lines (ACTIVE=8)" || return 1
  gate_case_with 1 "" gate_rep 10 "$GATE_MATCH"
  [ "$GATE_RC" -ne 0 ] || { fail "no config.sh, 10 lines (ACTIVE=9): expected non-zero, got 0"; return 1; }
}

test_gate_fallback_when_value_garbage() {
  gate_case_with "" "MAX_CLAUDE_PROCS=abc" gate_rep 9 "$GATE_MATCH"
  assert_exit0 "$GATE_RC" "MAX_CLAUDE_PROCS=abc, 9 lines (ACTIVE=8)" || return 1
  gate_case_with "" "MAX_CLAUDE_PROCS=abc" gate_rep 10 "$GATE_MATCH"
  [ "$GATE_RC" -ne 0 ] || { fail "MAX_CLAUDE_PROCS=abc, 10 lines (ACTIVE=9): expected non-zero, got 0"; return 1; }
}

test_gate_does_not_leak_config_into_shell() {
  local out
  out=$(
    unset PIPE BACKOFF
    GATE_AFTER='echo "LEAK:PIPE=${PIPE+set}:BACKOFF=${BACKOFF+set}:"'
    gate_case gate_rep 3 "$GATE_MATCH"
    printf '%s\n' "rc=$GATE_RC" "$GATE_OUT"
  )
  assert_contains "$out" "rc=0" "3 lines pass" || return 1
  assert_contains "$out" "LEAK:PIPE=:BACKOFF=:" "PIPE and BACKOFF still unset after the gate" || return 1
}

echo "-- orchestrator concurrency gate"
run_test test_gate_extraction_nonempty_and_no_pgrep
run_test test_gate_blocks_over_capacity
run_test test_gate_passes_under_capacity
run_test test_gate_boundary_9_lines_passes
run_test test_gate_boundary_10_lines_blocks
run_test test_gate_ignores_bash_wrappers
run_test test_gate_ignores_claude_without_skip_permissions
run_test test_gate_counts_macos_path_prefixed_comm
run_test test_gate_ignores_interactive_sessions_mixed
run_test test_gate_ignores_interactive_sessions_only
run_test test_gate_config_declares_max_claude_procs
run_test test_gate_example_config_mentions_max_claude_procs
run_test test_gate_honours_local_override
run_test test_gate_function_has_no_max_concurrent_or_16
run_test test_gate_fallback_when_config_missing
run_test test_gate_fallback_when_value_garbage
run_test test_gate_does_not_leak_config_into_shell
