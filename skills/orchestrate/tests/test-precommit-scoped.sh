# Regression for issue #82 — enforce-tests-before-commit.sh must scope local test selection to
# the change instead of always running the full project suite, and must NEVER block the commit
# on a test failure (scoped or fallback-full). CI's full-suite job remains the only merge gate.
#
# Exercises the REAL hooks/enforce-tests-before-commit.sh against a throwaway git repo with a
# stub node_modules/.bin/vitest that records its argv and behaves differently for a `--changed`
# invocation (passes) vs. a full `run` invocation (fails) — proves selection AND non-blocking
# deterministically, offline (no real vitest install, no network).

HERE_PC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_PC=$(cd "$HERE_PC/../../.." && pwd)
HOOK_PC="$ROOT_PC/hooks/enforce-tests-before-commit.sh"

# vitest_fixture_repo <marker_dir> -> prints the repo dir
# A git repo whose main branch is committed, plus one working-tree change (b.js) so a scoped
# --changed run against merge-base has something to select. package.json's "test" script is a
# safe single-command `vitest run` (no &&/;/||), so the hook treats it as vitest-safe.
vitest_fixture_repo() {
  local marker=$1 dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/pc-repo.XXXXXX")
  ( cd "$dir" && git init -q && git config user.email a@b.com && git config user.name a
    mkdir -p node_modules/.bin src
    cat > package.json <<'EOF'
{ "name": "fixture", "scripts": { "test": "vitest run" } }
EOF
    cat > node_modules/.bin/vitest <<EOF
#!/bin/bash
echo "\$@" >> "$marker"
if echo "\$@" | grep -q -- "--changed"; then
  echo "Test Files  1 passed (1)"; echo "Tests  1 passed (1)"; exit 0
else
  echo "Test Files  1 failed | 1 passed (2)"; echo "Tests  1 failed | 1 passed (2)"; exit 1
fi
EOF
    chmod +x node_modules/.bin/vitest
    echo "a" > src/a.js
    git add -A && git commit -qm init >/dev/null
    git branch -M main
    git remote add origin . 2>/dev/null
    git update-ref refs/remotes/origin/main main
  ) >/dev/null 2>&1
  echo "$dir"
}

run_hook() {  # run_hook <repo_dir> <commit_cmd> -> sets RC_PC, OUT_PC (via globals)
  local repo=$1 cmd=$2 home
  home=$(new_home)
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'tool_input':{'command': sys.argv[1]}}))" "$cmd")
  OUT_PC=$( (cd "$repo" && HOME="$home" LOGDIR="$home/logs/pipeline" bash "$HOOK_PC" <<<"$payload") 2>&1)
  RC_PC=$?
  LOG_PC="$home/logs/pipeline/enforce-tests-before-commit.log"
  rm -rf "$home"
}

test_pc_scoped_run_is_selected_and_never_blocks() {
  local marker repo
  marker=$(mktemp -u "${TMPDIR:-/tmp}/pc-vitest-calls.XXXXXX")
  repo=$(vitest_fixture_repo "$marker")
  ( cd "$repo" && echo "b" > src/b.js && git add -A ) >/dev/null 2>&1

  run_hook "$repo" 'git commit -m "add b"'

  local calls; calls=$(cat "$marker" 2>/dev/null)
  rm -rf "$repo"; rm -f "$marker"

  assert_exit0 "$RC_PC" "AC: hook never exits non-zero for a scoped run" || return 1
  assert_contains "$calls" "--changed" "AC: vitest scoping is used (merge-base --changed), not a full run" || return 1
}

test_pc_config_change_falls_back_to_full_but_still_nonblocking() {
  local marker repo
  marker=$(mktemp -u "${TMPDIR:-/tmp}/pc-vitest-calls2.XXXXXX")
  repo=$(vitest_fixture_repo "$marker")
  ( cd "$repo" && touch vitest.config.js && git add -A ) >/dev/null 2>&1

  run_hook "$repo" 'git commit -m "add config"'

  local calls; calls=$(cat "$marker" 2>/dev/null)
  rm -rf "$repo"; rm -f "$marker"

  assert_exit0 "$RC_PC" "AC: hook never exits non-zero even though the fallback-full stub fails" || return 1
  assert_not_contains "$calls" "--changed" "AC: a config-file change forces the conservative full fallback, not scoped" || return 1
}

test_pc_bypasses_skip_the_hook_and_the_runner_entirely() {
  local marker repo home payload rc1 rc2
  marker=$(mktemp -u "${TMPDIR:-/tmp}/pc-vitest-calls3.XXXXXX")
  repo=$(vitest_fixture_repo "$marker")
  ( cd "$repo" && echo "b" > src/b.js && git add -A ) >/dev/null 2>&1

  home=$(new_home)
  payload=$(python3 -c "import json; print(json.dumps({'tool_input':{'command':'git commit -m x'}}))")
  ( cd "$repo" && HOME="$home" PIPELINE_LOCKED_TESTS_FILE="$home/locked.txt" bash "$HOOK_PC" <<<"$payload" >/dev/null 2>&1 )
  rc1=$?

  payload2=$(python3 -c "import json; print(json.dumps({'tool_input':{'command':'git commit -m \"test(#5): stub\"'}}))")
  ( cd "$repo" && HOME="$home" bash "$HOOK_PC" <<<"$payload2" >/dev/null 2>&1 )
  rc2=$?

  local calls; calls=$(cat "$marker" 2>/dev/null)
  rm -rf "$repo" "$home"; rm -f "$marker"

  assert_exit0 "$rc1" "AC8: PIPELINE_LOCKED_TESTS_FILE bypass still exits 0" || return 1
  assert_exit0 "$rc2" "AC8: test(#N): commit-message bypass still exits 0" || return 1
  assert_eq "$calls" "" "AC8: both bypasses skip the test runner entirely, including new scoped-selection logic" || return 1
}

test_pc_non_vitest_repo_falls_back_to_full_selection_and_stays_nonblocking() {
  local repo home payload rc out
  repo=$(mktemp -d "${TMPDIR:-/tmp}/pc-repo-nonvitest.XXXXXX")
  ( cd "$repo" && git init -q && git config user.email a@b.com && git config user.name a
    cat > package.json <<'EOF'
{ "name": "f2", "scripts": { "test": "echo running && exit 1" } }
EOF
    git add -A && git commit -qm init ) >/dev/null 2>&1

  home=$(new_home)
  payload=$(python3 -c "import json; print(json.dumps({'tool_input':{'command':'git commit -m x'}}))")
  out=$( (cd "$repo" && HOME="$home" bash "$HOOK_PC" <<<"$payload") 2>&1)
  rc=$?
  rm -rf "$repo" "$home"

  assert_exit0 "$rc" "AC4/AC5: no regression — full-suite selection for non-vitest repos still never blocks" || return 1
  assert_contains "$out" "running" "AC4: today's full-suite command still actually ran for selection" || return 1
}

run_test test_pc_scoped_run_is_selected_and_never_blocks
run_test test_pc_config_change_falls_back_to_full_but_still_nonblocking
run_test test_pc_bypasses_skip_the_hook_and_the_runner_entirely
run_test test_pc_non_vitest_repo_falls_back_to_full_selection_and_stays_nonblocking
