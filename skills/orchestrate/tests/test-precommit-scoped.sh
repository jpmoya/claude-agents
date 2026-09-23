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

run_hook() {  # run_hook <repo_dir> <commit_cmd> -> sets RC_PC, OUT_PC, LOG_PC, HOME_PC (via
              # globals); caller is responsible for `rm -rf "$HOME_PC"` once done inspecting LOG_PC.
  local repo=$1 cmd=$2 home
  home=$(new_home)
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'tool_input':{'command': sys.argv[1]}}))" "$cmd")
  OUT_PC=$( (cd "$repo" && HOME="$home" LOGDIR="$home/logs/pipeline" bash "$HOOK_PC" <<<"$payload") 2>&1)
  RC_PC=$?
  LOG_PC="$home/logs/pipeline/enforce-tests-before-commit.log"
  HOME_PC="$home"
}

test_pc_scoped_run_is_selected_and_never_blocks() {
  local marker repo merge_base
  marker=$(mktemp -u "${TMPDIR:-/tmp}/pc-vitest-calls.XXXXXX")
  repo=$(vitest_fixture_repo "$marker")
  ( cd "$repo" && echo "b" > src/b.js && git add -A ) >/dev/null 2>&1
  merge_base=$(git -C "$repo" merge-base HEAD origin/main 2>/dev/null)

  run_hook "$repo" 'git commit -m "add b"'

  local calls; calls=$(cat "$marker" 2>/dev/null)
  rm -rf "$repo" "$HOME_PC"; rm -f "$marker"

  assert_exit0 "$RC_PC" "AC: hook never exits non-zero for a scoped run" || return 1
  assert_contains "$calls" "--changed $merge_base" "AC: vitest scoping is --changed against the actual merge-base sha, not a full run" || return 1
}

test_pc_custom_flags_in_test_script_fall_back_to_full_not_silently_dropped() {
  local marker repo
  marker=$(mktemp -u "${TMPDIR:-/tmp}/pc-vitest-calls5.XXXXXX")
  repo=$(vitest_fixture_repo "$marker")
  ( cd "$repo" && python3 - "$repo" <<'EOF'
import json, sys
p = sys.argv[1] + "/package.json"
d = json.load(open(p))
d["scripts"]["test"] = "vitest run --project=api"
json.dump(d, open(p, "w"))
EOF
    echo "b" > src/b.js && git add -A && git commit -qm "custom test script" ) >/dev/null 2>&1
  ( cd "$repo" && echo "c" > src/c.js && git add -A ) >/dev/null 2>&1

  run_hook "$repo" 'git commit -m "add c"'

  local calls; calls=$(cat "$marker" 2>/dev/null)
  rm -rf "$repo" "$HOME_PC"; rm -f "$marker"

  assert_exit0 "$RC_PC" "AC: hook never exits non-zero even for the full fallback" || return 1
  assert_not_contains "$calls" "--changed" "AC: scripts.test flags beyond a bare vitest invocation (e.g. --project=api) are not safe to scope silently — must fall back to full" || return 1
}

test_pc_config_change_falls_back_to_full_but_still_nonblocking() {
  local marker repo
  marker=$(mktemp -u "${TMPDIR:-/tmp}/pc-vitest-calls2.XXXXXX")
  repo=$(vitest_fixture_repo "$marker")
  ( cd "$repo" && touch vitest.config.js && git add -A ) >/dev/null 2>&1

  run_hook "$repo" 'git commit -m "add config"'

  local calls; calls=$(cat "$marker" 2>/dev/null)
  rm -rf "$repo" "$HOME_PC"; rm -f "$marker"

  assert_exit0 "$RC_PC" "AC: hook never exits non-zero even though the fallback-full stub fails" || return 1
  assert_not_contains "$calls" "--changed" "AC: a config-file change forces the conservative full fallback, not scoped" || return 1
}

test_pc_bypasses_skip_the_hook_and_the_runner_entirely() {
  local marker repo home1 home2 home3 payload rc1 rc2 rc3
  local log1_exists log2_exists log3_exists

  # Positive control (same repo, same commit shape, NO bypass): proves logging exists and
  # fires on this hook at all — dies (log absent) against origin/main, which has no logging,
  # so it also anchors the two bypass checks below against a real revert, not just each other.
  marker=$(mktemp -u "${TMPDIR:-/tmp}/pc-vitest-calls3.XXXXXX")
  repo=$(vitest_fixture_repo "$marker")
  ( cd "$repo" && echo "b" > src/b.js && git add -A ) >/dev/null 2>&1

  home3=$(new_home)
  payload=$(python3 -c "import json; print(json.dumps({'tool_input':{'command':'git commit -m x'}}))")
  ( cd "$repo" && HOME="$home3" LOGDIR="$home3/logs/pipeline" bash "$HOOK_PC" <<<"$payload" >/dev/null 2>&1 )
  rc3=$?
  [ -f "$home3/logs/pipeline/enforce-tests-before-commit.log" ] && log3_exists=yes || log3_exists=no
  rm -rf "$home3"
  local calls_after_control; calls_after_control=$(cat "$marker" 2>/dev/null)

  home1=$(new_home)
  payload=$(python3 -c "import json; print(json.dumps({'tool_input':{'command':'git commit -m x'}}))")
  ( cd "$repo" && HOME="$home1" LOGDIR="$home1/logs/pipeline" PIPELINE_LOCKED_TESTS_FILE="$home1/locked.txt" bash "$HOOK_PC" <<<"$payload" >/dev/null 2>&1 )
  rc1=$?
  [ -f "$home1/logs/pipeline/enforce-tests-before-commit.log" ] && log1_exists=yes || log1_exists=no
  rm -rf "$home1"

  home2=$(new_home)
  payload2=$(python3 -c "import json; print(json.dumps({'tool_input':{'command':'git commit -m \"test(#5): stub\"'}}))")
  ( cd "$repo" && HOME="$home2" LOGDIR="$home2/logs/pipeline" bash "$HOOK_PC" <<<"$payload2" >/dev/null 2>&1 )
  rc2=$?
  [ -f "$home2/logs/pipeline/enforce-tests-before-commit.log" ] && log2_exists=yes || log2_exists=no
  rm -rf "$home2"

  local calls; calls=$(cat "$marker" 2>/dev/null)
  rm -rf "$repo"; rm -f "$marker"

  assert_exit0 "$rc3" "control: an un-bypassed commit exits 0" || return 1
  assert_eq "$log3_exists" "yes" "control: an un-bypassed commit DOES write a log file — proves logging exists, so its absence below is meaningful" || return 1
  assert_exit0 "$rc1" "AC8: PIPELINE_LOCKED_TESTS_FILE bypass still exits 0" || return 1
  assert_exit0 "$rc2" "AC8: test(#N): commit-message bypass still exits 0" || return 1
  assert_eq "$calls" "$calls_after_control" "AC8: both bypasses skip the test runner entirely — no new call recorded beyond the earlier un-bypassed control run" || return 1
  assert_eq "$log1_exists" "no" "AC8: PIPELINE_LOCKED_TESTS_FILE bypass must skip logging too" || return 1
  assert_eq "$log2_exists" "no" "AC8: test(#N): bypass must skip logging too" || return 1
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
run_test test_pc_custom_flags_in_test_script_fall_back_to_full_not_silently_dropped
run_test test_pc_config_change_falls_back_to_full_but_still_nonblocking
run_test test_pc_bypasses_skip_the_hook_and_the_runner_entirely
run_test test_pc_non_vitest_repo_falls_back_to_full_selection_and_stays_nonblocking
