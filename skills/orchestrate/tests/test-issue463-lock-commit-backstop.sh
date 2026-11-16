# #463: hooks/protect-locked-tests.sh blocks `git commit` whenever a locked test file differs from HEAD,
# staged or not (PreToolUse runs before the same command's `git add`), and agents/orchestrator.md scopes the
# "Delegated decision … terminal" rule to the three stops a [delivery-lead] marker can resume.

HERE_463=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_463=$(cd "$HERE_463/../../.." && pwd)
HOOK_463="$ROOT_463/hooks/protect-locked-tests.sh"

l463_setup() {  # temp repo with locked e2e/a.spec.ts and unlocked src/b.ts, committed; sets L463_DIR
  L463_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-lock463.XXXXXX")
  (
    cd "$L463_DIR" || exit 1
    git init -q . && git config user.email t@t && git config user.name t
    mkdir e2e src
    echo one > e2e/a.spec.ts; echo one > src/b.ts
    git add -A && git commit -qm init
  ) >/dev/null 2>&1
  printf 'e2e/a.spec.ts\n' > "$L463_DIR/locked.txt"
}

l463_run() {  # l463_run <bash command> — runs the hook as a Bash PreToolUse call in the temp repo; sets L463_RC, L463_ERR
  local payload rc=0
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1")
  L463_ERR=$(cd "$L463_DIR" && printf '%s' "$payload" | PIPELINE_LOCKED_TESTS_FILE="$L463_DIR/locked.txt" bash "$HOOK_463" 2>&1 >/dev/null) || rc=$?
  L463_RC=$rc
}

test_lock_commit_blocks_unstaged_locked_change_with_add_and_commit() {
  l463_setup
  echo two > "$L463_DIR/e2e/a.spec.ts"   # modified, NOT staged: the command's own `git add` has not run yet
  l463_run 'git add -A e2e && git commit -qm x'
  assert_eq "$L463_RC" "2" "unstaged locked change + add && commit" || return 1
  assert_contains "$L463_ERR" "is a locked test file" "message"
}

test_lock_commit_blocks_staged_locked_change() {
  l463_setup
  echo two > "$L463_DIR/e2e/a.spec.ts"; (cd "$L463_DIR" && git add e2e/a.spec.ts)
  l463_run 'git commit -qm x'
  assert_eq "$L463_RC" "2" "staged locked change" || return 1
  assert_contains "$L463_ERR" "is a locked test file" "message"
}

test_lock_commit_blocks_commit_am() {
  l463_setup
  echo two > "$L463_DIR/e2e/a.spec.ts"
  l463_run 'git commit -am x'
  assert_eq "$L463_RC" "2" "git commit -am with a modified locked file" || return 1
  assert_contains "$L463_ERR" "is a locked test file" "message"
}

test_lock_commit_allows_unchanged_locked_files_and_new_tests() {
  l463_setup
  echo two > "$L463_DIR/src/b.ts"; echo new > "$L463_DIR/e2e/new.spec.ts"   # unlocked edit + a NEW test file
  l463_run 'git add -A && git commit -qm x'
  assert_eq "$L463_RC" "0" "locked files unchanged from HEAD, new unlocked test file" || return 1
}

test_orchestrator_delegated_decision_terminal_rule_is_scoped() {
  local line
  line=$(grep -F -- '- **Delegated decision** (any check in that row fails)' "$ROOT_463/agents/orchestrator.md")
  assert_contains "$line" "applies only when the gate marker is" "scoping sentence present" || return 1
  assert_contains "$line" "code-track \`BLOCKED\`, the TEST DEFECT cap or the loop cap" "names the three resumable stops" || return 1
  assert_contains "$line" "**Look-through rule** governs" "defers to the look-through rule" || return 1
  assert_contains "$line" "IMPLEMENTED" "names IMPLEMENTED as a non-resumable gate marker"
}

run_test test_lock_commit_blocks_unstaged_locked_change_with_add_and_commit
run_test test_lock_commit_blocks_staged_locked_change
run_test test_lock_commit_blocks_commit_am
run_test test_lock_commit_allows_unchanged_locked_files_and_new_tests
run_test test_orchestrator_delegated_decision_terminal_rule_is_scoped
