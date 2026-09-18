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
gate_run() {
  local fixture=$1 dir out rc
  dir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-gate.XXXXXX")
  sed -n '/^wait_for_capacity() {/,/^}/p' "$ORCH_MD_GATE" > "$dir/gate.sh"
  printf '#!/bin/bash\ncat "%s"\n' "$fixture" > "$dir/ps"
  printf '#!/bin/bash\nexit 0\n' > "$dir/sleep"
  chmod +x "$dir/ps" "$dir/sleep"
  out=$( ( PATH="$dir:$PATH"; . "$dir/gate.sh"; wait_for_capacity ) 2>&1 ); rc=$?
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

echo "-- orchestrator concurrency gate"
run_test test_gate_extraction_nonempty_and_no_pgrep
run_test test_gate_blocks_over_capacity
run_test test_gate_passes_under_capacity
run_test test_gate_boundary_9_lines_passes
run_test test_gate_boundary_10_lines_blocks
run_test test_gate_ignores_bash_wrappers
run_test test_gate_ignores_claude_without_skip_permissions
run_test test_gate_counts_macos_path_prefixed_comm
