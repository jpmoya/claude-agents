# Goal-bound delivery lead capacity (claude-agents#196, parent #193). The orchestrator's `ps` gate
# counts delivery-lead/goal processes (they carry --dangerously-skip-permissions --agent), so the
# default ceiling must cover 3 orchestrators x (1 + 2 stages) - 1 caller + MAX_GOALS(2) = 10.
# Self-contained: this file sorts before test-orchestrator-gate.sh, so it defines its own helpers
# (gc_ prefix) rather than relying on that file's gate_case. Nothing here touches /tmp/pipeline.

HERE_GC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GC_ORCH_MD="$HERE_GC/../../../agents/orchestrator.md"
GC_CONFIG="$HERE_GC/../config.sh"
GC_EXAMPLE="$HERE_GC/../config.local.example.sh"
GC_LIB="$HERE_GC/../pipeline-lib.sh"

GC_PIPELINE='claude claude --dangerously-skip-permissions --agent x -p y'
GC_GOAL='claude claude --dangerously-skip-permissions --agent delivery-lead -p goal'
GC_INTERACTIVE_NOFLAG='claude claude --agent x -p y'

gc_rep() {  # gc_rep <count> <line>
  local n=$1 i=0
  while [ "$i" -lt "$n" ]; do printf '%s\n' "$2"; i=$((i + 1)); done
}

# gc_gate <fixture-file> — runs the shipped wait_for_capacity against a stub ps, shipped config.sh,
# no config.local.sh. Prints output; returns the gate's exit code.
gc_gate() {
  local fixture=$1 dir out rc
  dir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-goalcap.XXXXXX")
  mkdir -p "$dir/home/.claude/skills/orchestrate" "$dir/home/.claude/pipeline"
  cp "$GC_CONFIG" "$dir/home/.claude/skills/orchestrate/config.sh"
  sed -n '/^wait_for_capacity() {/,/^}/p' "$GC_ORCH_MD" > "$dir/gate.sh"
  printf '#!/bin/bash\ncat "%s"\n' "$fixture" > "$dir/ps"
  printf '#!/bin/bash\nexit 0\n' > "$dir/sleep"
  chmod +x "$dir/ps" "$dir/sleep"
  out=$( ( HOME="$dir/home"; PATH="$dir:$PATH"; . "$dir/gate.sh"; wait_for_capacity ) 2>&1 ); rc=$?
  rm -rf "$dir"
  printf '%s\n' "$out"
  return "$rc"
}

# gc_case <fixture-builder-cmd...> — sets GC_OUT / GC_RC.
gc_case() {
  local fixture
  fixture=$(mktemp "${TMPDIR:-/tmp}/orch-test-goalcap-fixture.XXXXXX")
  "$@" > "$fixture"
  GC_OUT=$(gc_gate "$fixture"); GC_RC=$?
  rm -f "$fixture"
}

gc_fx_9_stage_2_goal_1_interactive() { gc_rep 9 "$GC_PIPELINE"; gc_rep 2 "$GC_GOAL"; gc_rep 1 "$GC_INTERACTIVE_NOFLAG"; }
gc_fx_12_pipeline() { gc_rep 10 "$GC_PIPELINE"; gc_rep 2 "$GC_GOAL"; }

gc_fn() { sed -n '/^wait_for_capacity() {/,/^}/p' "$GC_ORCH_MD"; }

# --- AC1 / AC5(a): shipped default ------------------------------------------------------------

test_gc_ac5a_config_default_covers_goal_runs() {
  local v floor=$((3 * 3 - 1 + 2))   # 3 orchestrators x (1 + 2 stages) - 1 caller + MAX_GOALS 2 = 10
  v=$( . "$GC_CONFIG" >/dev/null 2>&1; printf '%s' "${MAX_CLAUDE_PROCS:-}" )
  case "$v" in ''|*[!0-9]*) fail "config.sh MAX_CLAUDE_PROCS is not an integer: [$v]"; return 1 ;; esac
  [ "$v" -ge "$floor" ] || { fail "config.sh MAX_CLAUDE_PROCS=$v, expected >= $floor"; return 1; }
}

test_gc_ac1_config_value_10_directly_after_max_concurrent() {
  local n after
  n=$(grep -c '^MAX_CLAUDE_PROCS=10\b' "$GC_CONFIG")
  assert_eq "$n" "1" "AC1: exactly one ^MAX_CLAUDE_PROCS=10 line" || return 1
  after=$(grep -A1 '^MAX_CONCURRENT=3' "$GC_CONFIG" | sed -n 2p)
  assert_contains "$after" "MAX_CLAUDE_PROCS=10" "AC1: directly after MAX_CONCURRENT=3" || return 1
}

test_gc_ac1_config_comment_states_formula_and_drops_agent_only() {
  local line
  line=$(grep '^MAX_CLAUDE_PROCS=' "$GC_CONFIG")
  assert_contains "$line" "must stay ≥ 3 × (1 + 2 stages) − 1 + MAX_GOALS" "AC1: comment states the floor formula" || return 1
  assert_not_contains "$line" "--agent\` processes only" "AC1: comment no longer says '--agent processes only'" || return 1
}

# --- AC2 --------------------------------------------------------------------------------------

test_gc_ac2_example_config_shows_10() {
  local n
  n=$(grep -c '^# MAX_CLAUDE_PROCS=10$' "$GC_EXAMPLE")
  assert_eq "$n" "1" "AC2: example config has '# MAX_CLAUDE_PROCS=10'" || return 1
  n=$(grep -c 'MAX_CLAUDE_PROCS=8' "$GC_EXAMPLE")
  assert_eq "$n" "0" "AC2: example config no longer mentions MAX_CLAUDE_PROCS=8" || return 1
}

# --- AC3: orchestrator.md fallbacks + comment, filter unchanged --------------------------------

test_gc_ac3_fallback_defaults_are_10() {
  local fn n
  fn=$(gc_fn)
  [ -n "$fn" ] || { fail "wait_for_capacity not found in agents/orchestrator.md"; return 1; }
  n=$(printf '%s\n' "$fn" | grep -c 'MAX_CLAUDE_PROCS=8')
  assert_eq "$n" "0" "AC3: no MAX_CLAUDE_PROCS=8 left in the gate" || return 1
  n=$(printf '%s\n' "$fn" | grep -c 'MAX_CLAUDE_PROCS=10')
  assert_eq "$n" "2" "AC3: both fallback lines set MAX_CLAUDE_PROCS=10" || return 1
}

test_gc_ac3_comment_describes_pipeline_launched_processes() {
  local c
  c=$(gc_fn | grep '^[[:space:]]*#')
  assert_not_contains "$c" "(\`--agent\` on the command line)" "AC3: --agent no longer claimed as the pipeline discriminator" || return 1
  assert_not_contains "$c" "carry the same flag" "AC3: no claim that interactive sessions carry the same flag" || return 1
  assert_contains "$c" "--dangerously-skip-permissions" "AC3: comment names --dangerously-skip-permissions" || return 1
  assert_contains "$c" "goal" "AC3: comment says delivery-lead goal runs are counted" || return 1
  assert_contains "$c" "interactive" "AC3: comment says interactive sessions are excluded" || return 1
}

test_gc_ac3_ps_awk_filter_unchanged() {
  local fn
  fn=$(gc_fn)
  assert_contains "$fn" "awk '\$1 ~ /(^|\\/)claude\$/ && /--dangerously-skip-permissions/ && /--agent/'" "AC3: ps/awk filter byte-for-byte unchanged" || return 1
}

# --- AC5(b)/(c): gate behaviour with goal runs, shipped defaults -------------------------------

test_gc_ac5b_9_stage_2_goal_1_interactive_passes() {
  gc_case gc_fx_9_stage_2_goal_1_interactive   # 11 matching - 1 caller = ACTIVE 10 <= 10
  assert_exit0 "$GC_RC" "AC5b: 9 stage + 2 goal + 1 interactive (ACTIVE=10)" || return 1
}

test_gc_ac5c_12_pipeline_lines_blocks() {
  gc_case gc_fx_12_pipeline                    # 12 matching - 1 = ACTIVE 11 > 10
  [ "$GC_RC" -ne 0 ] || { fail "AC5c: 12 matching lines (ACTIVE=11): expected non-zero, got 0"; return 1; }
  assert_contains "$GC_OUT" "Aborting dispatch" "AC5c: refusal message" || return 1
  assert_contains "$GC_OUT" "max 10" "AC5c: reports the new ceiling" || return 1
}

# --- AC6: count_running unchanged — goal pid files are not orchestrator slots -------------------

test_gc_ac6_count_running_ignores_goal_pid_files() {
  local pipe repo before after
  pipe=$(new_pipe); repo=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX")
  mk_running "$pipe" 301 "$repo"
  before=$( . "$GC_LIB" 2>/dev/null; PIPE="$pipe"; count_running 2>/dev/null )
  sleep 300 & local gpid=$!
  echo "$gpid" > "$pipe/goal-x.pid"
  after=$( . "$GC_LIB" 2>/dev/null; PIPE="$pipe"; count_running 2>/dev/null )
  kill "$gpid" 2>/dev/null
  cleanup_running; rm -rf "$pipe" "$repo"
  assert_eq "$before" "1" "AC6: baseline count with one live orchestrator" || return 1
  assert_eq "$after" "1" "AC6: live goal-x.pid does not change count_running" || return 1
}

echo "-- goal-run capacity (#196)"
run_test test_gc_ac5a_config_default_covers_goal_runs
run_test test_gc_ac1_config_value_10_directly_after_max_concurrent
run_test test_gc_ac1_config_comment_states_formula_and_drops_agent_only
run_test test_gc_ac2_example_config_shows_10
run_test test_gc_ac3_fallback_defaults_are_10
run_test test_gc_ac3_comment_describes_pipeline_launched_processes
run_test test_gc_ac3_ps_awk_filter_unchanged
run_test test_gc_ac5b_9_stage_2_goal_1_interactive_passes
run_test test_gc_ac5c_12_pipeline_lines_blocks
run_test test_gc_ac6_count_running_ignores_goal_pid_files
