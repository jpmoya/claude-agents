# #154 — hooks/sync-agents.sh must recover a detached HEAD (switch to main, then ff-pull) and must
# surface (not swallow) failures with one `claude-config:` line, always exiting 0.
# Real hook, mktemp fixtures only; HOME is a fake home whose claude-agents/ is the clone under test.

HERE_SAD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_SAD="$HERE_SAD/../../../hooks/sync-agents.sh"

# sad_setup -> sets SAD_TMP, SAD_HOME, SAD_REPO, SAD_A, SAD_B. Clone sits at A; origin/main is at B.
sad_setup() {
  SAD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sad-test.XXXXXX")
  SAD_HOME="$SAD_TMP/home"; SAD_REPO="$SAD_HOME/claude-agents"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  mkdir -p "$SAD_HOME"
  git init -q --bare -b main "$SAD_TMP/origin.git"
  git clone -q "$SAD_TMP/origin.git" "$SAD_TMP/work" 2>/dev/null
  ( cd "$SAD_TMP/work" && git checkout -q -b main 2>/dev/null; echo a > f.txt && git add f.txt \
    && git commit -q -m A && git push -q origin main ) || return 1
  SAD_A=$(git -C "$SAD_TMP/work" rev-parse HEAD)
  git clone -q "$SAD_TMP/origin.git" "$SAD_REPO" 2>/dev/null
  ( cd "$SAD_TMP/work" && echo b > f.txt && git commit -q -am B && git push -q origin main ) || return 1
  SAD_B=$(git -C "$SAD_TMP/work" rev-parse HEAD)
}

sad_run() { SAD_OUT=$(HOME="$SAD_HOME" bash "$HOOK_SAD" 2>&1); SAD_RC=$?; }

test_sad_detached_clean_recovers_to_main() {
  sad_setup || return 1
  git -C "$SAD_REPO" checkout -q --detach "$SAD_A"
  sad_run
  local ref head; ref=$(git -C "$SAD_REPO" symbolic-ref -q HEAD); head=$(git -C "$SAD_REPO" rev-parse HEAD)
  rm -rf "$SAD_TMP"
  assert_exit0 "$SAD_RC" "detached clean: exit" || return 1
  assert_eq "$ref" "refs/heads/main" "detached clean: HEAD on main" || return 1
  assert_eq "$head" "$SAD_B" "detached clean: HEAD == origin/main" || return 1
  assert_not_contains "$SAD_OUT" "did not update" "detached clean: no warning" || return 1
}

test_sad_detached_conflicting_change_warns() {
  sad_setup || return 1
  git -C "$SAD_REPO" checkout -q --detach "$SAD_A"
  echo local > "$SAD_REPO/f.txt"
  sad_run
  rm -rf "$SAD_TMP"
  assert_exit0 "$SAD_RC" "detached conflict: exit" || return 1
  assert_contains "$SAD_OUT" "claude-config:" "detached conflict: prefix" || return 1
  assert_contains "$SAD_OUT" "did not update" "detached conflict: message" || return 1
}

test_sad_on_main_behind_fast_forwards_silently() {
  sad_setup || return 1
  sad_run
  local head; head=$(git -C "$SAD_REPO" rev-parse HEAD)
  rm -rf "$SAD_TMP"
  assert_exit0 "$SAD_RC" "on main: exit" || return 1
  assert_eq "$head" "$SAD_B" "on main: fast-forwarded" || return 1
  assert_not_contains "$SAD_OUT" "did not update" "on main: silent" || return 1
}

test_sad_origin_unreachable_warns_head_unchanged() {
  sad_setup || return 1
  git -C "$SAD_REPO" remote set-url origin "$SAD_TMP/nonexistent.git"
  sad_run
  local head; head=$(git -C "$SAD_REPO" rev-parse HEAD)
  rm -rf "$SAD_TMP"
  assert_exit0 "$SAD_RC" "unreachable: exit" || return 1
  assert_contains "$SAD_OUT" "claude-config:" "unreachable: prefix" || return 1
  assert_contains "$SAD_OUT" "did not update" "unreachable: message" || return 1
  assert_eq "$head" "$SAD_A" "unreachable: HEAD unchanged" || return 1
}

run_test test_sad_detached_clean_recovers_to_main
run_test test_sad_detached_conflicting_change_warns
run_test test_sad_on_main_behind_fast_forwards_silently
run_test test_sad_origin_unreachable_warns_head_unchanged
