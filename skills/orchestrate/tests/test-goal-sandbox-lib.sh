# #628 — the gs_* sandbox lives in lib/goal-sandbox.sh so GS_SKILL is always derived from the real in-tree file.
# Incident: a copy of the helpers sourced from /tmp derived GS_SKILL="/" and gs_tree_init ran `cp -R / <tmpfs>`.
# Expected values: the real path comes from this file's own location; the copy cases from the mktemp dir we build;
# the consumer list and helper names from the ticket (#628 AC2 + PM scope, #625's test file).
# None of these tests ever calls gs_tree_init on a copy.

GSL_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GSL_LIB="$GSL_HERE/lib/goal-sandbox.sh"
GSL_CONSUMERS="test-goal-supervisor.sh test-goal-limit-exit.sh test-goal-z-queue.sh test-goal-z-serial.sh test-goal-z-unstartable.sh
test-issue514-goal-queue-held.sh test-mockup-skip-marker.sh test-goal-sync-reregister.sh test-goal-sync-repin.sh
test-goal-supervisors-needs-jp-class.sh"

test_gsl_gs_skill_is_the_real_skill_dir() {
  local got want; want=$(cd "$GSL_HERE/.." && pwd)
  got=$(bash -c '. "$1"; echo "$GS_SKILL"' _ "$GSL_LIB")
  assert_eq "$got" "$want" "GS_SKILL from the in-tree lib" || return 1
}

# A copy elsewhere derives from ITS location (two levels up), never "/" — and the test never calls gs_tree_init on it.
# (No sanity guard, per the ticket: the fix is the in-tree location plus the "do not copy" header note.)
test_gsl_copy_elsewhere_is_not_root() {
  local d got; d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-gslcopy.XXXXXX")
  mkdir -p "$d/a/b/lib"; cp "$GSL_LIB" "$d/a/b/lib/goal-sandbox.sh"
  got=$(bash -c '. "$1" 2>/dev/null; echo "$GS_SKILL"' _ "$d/a/b/lib/goal-sandbox.sh")
  rm -rf "$d"
  assert_ne "$got" "/" "GS_SKILL of a copy" || return 1
  assert_eq "$got" "$d/a" "GS_SKILL of a copy follows the copy's location" || return 1
}

# Standalone (`bash tests/<file>`): the lib brings in assert.sh and fixture.sh itself, so run_test and new_pipe exist.
test_gsl_lib_loads_assert_and_fixture_when_missing() {
  local got
  got=$(bash -c '. "$1" || exit 9; t=""; for f in run_test assert_eq fail new_pipe new_home fixture_repo; do type "$f" >/dev/null 2>&1 || t="$t $f"; done; printf "%s" "$t"' _ "$GSL_LIB")
  assert_eq "$got" "" "helpers missing after sourcing the lib on its own" || return 1
}

# Under run-tests.sh both libs are already loaded: the lib must not load assert.sh again (it resets the pass/fail counters).
test_gsl_lib_does_not_reset_counters_when_assert_is_loaded() {
  local got
  got=$(bash -c '. "$1/assert.sh"; . "$1/fixture.sh"; ASSERT_PASS=7; ASSERT_FAIL=3; . "$1/goal-sandbox.sh" || exit 9; printf "%s/%s" "$ASSERT_PASS" "$ASSERT_FAIL"' _ "$GSL_HERE/lib")
  assert_eq "$got" "7/3" "ASSERT_PASS/ASSERT_FAIL after sourcing the lib with assert.sh already loaded" || return 1
}

# Every gs_* helper a consumer file calls is defined by the lib alone (names pinned: moving is fine, renaming is not).
test_gsl_lib_defines_every_helper_consumers_use() {
  local missing
  missing=$(bash -c '. "$1" || exit 9; for f in gs_tree_init gs_tree_cleanup gs_install_fakes gs_env gs_cleanup gs_issue gs_comment gs_body gs_reg gs_regfile gs_reg_state gs_has_label gs_reg_comment_count gs_cache gs_own gs_live gs_launch_state gs_tick gs_log gs_file gs_json gs_goal_file_count gs_claude_count gs_wait_claude gs_wait_dead gs_settle gs_last_claude gs_touch_ago gs_iso_ago gs_classify gs_check_class gs_classify_sr gs_classify_ms gs_gate_class gs_held_seed; do type "$f" >/dev/null 2>&1 || printf "%s " "$f"; done; [ -n "${GS_DEP_STAGING:-}" ] || printf "GS_DEP_STAGING "' _ "$GSL_LIB")
  assert_eq "$missing" "" "helpers missing from lib/goal-sandbox.sh" || return 1
}

# Each consumer sources the lib itself (so it runs standalone), and test-goal-supervisor.sh keeps no gs_*/GS_* definition.
test_gsl_every_consumer_sources_the_lib() {
  local f missing="" defs
  for f in $GSL_CONSUMERS; do
    grep -q '^\. "\$(dirname "\${BASH_SOURCE\[0\]}")/lib/goal-sandbox.sh"' "$GSL_HERE/$f" || missing="$missing $f"
  done
  assert_eq "$missing" "" "consumers not sourcing lib/goal-sandbox.sh" || return 1
  defs=$(grep -c '^gs_[a-z_0-9]*()\|^GS_[A-Z_0-9]*=' "$GSL_HERE/test-goal-supervisor.sh")
  assert_eq "$defs" "0" "gs_*/GS_* definitions left in test-goal-supervisor.sh (AC1: all of them live in the lib)" || return 1
}

test_gsl_no_extract_workarounds_remain() {
  local hits
  hits=$(grep -ln 'sed .*/^echo "-- goal supervisor\|<(sed' "$GSL_HERE"/test-goal-*.sh "$GSL_HERE"/test-issue514-*.sh "$GSL_HERE"/test-mockup-skip-marker.sh 2>/dev/null | grep -v test-goal-sandbox-lib.sh)
  assert_eq "$hits" "" "files still extracting the supervisor harness" || return 1
  hits=$(grep -ln '^ *GS_SKILL=' "$GSL_HERE"/*.sh | grep -v test-goal-sandbox-lib.sh)
  assert_eq "$hits" "" "GS_SKILL assigned outside lib/goal-sandbox.sh" || return 1
}

test_gsl_supervisor_cleans_its_tree_instead_of_blanking() {
  assert_eq "$(grep -c '^GS_TREE=""' "$GSL_HERE/test-goal-supervisor.sh")" "0" "GS_TREE blanked in supervisor suite" || return 1
  assert_eq "$(tail -1 "$GSL_HERE/test-goal-limit-exit.sh")" "gs_tree_cleanup" "limit-exit ends with cleanup" || return 1
}

# Leak: run limit-exit alone in a fresh TMPDIR; no orch-test-gstree.* may be left behind.
test_gsl_limit_exit_leaves_no_tree() {
  local t left; t=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-gsl.XXXXXX")
  TMPDIR="$t" CODE_SYNC_ENABLED=0 GH_BUDGET_ENABLED=0 bash -c 'cd "$1"; . lib/assert.sh; . lib/fixture.sh; . ./test-goal-limit-exit.sh' _ "$GSL_HERE" >/dev/null 2>&1
  left=$(ls -d "$t"/orch-test-gstree.* 2>/dev/null | wc -l | tr -d ' ')
  rm -rf "$t"
  assert_eq "$left" "0" "orch-test-gstree.* left after test-goal-limit-exit.sh" || return 1
}

run_test test_gsl_gs_skill_is_the_real_skill_dir
run_test test_gsl_copy_elsewhere_is_not_root
run_test test_gsl_lib_loads_assert_and_fixture_when_missing
run_test test_gsl_lib_does_not_reset_counters_when_assert_is_loaded
run_test test_gsl_lib_defines_every_helper_consumers_use
run_test test_gsl_every_consumer_sources_the_lib
run_test test_gsl_no_extract_workarounds_remain
run_test test_gsl_supervisor_cleans_its_tree_instead_of_blanking
run_test test_gsl_limit_exit_leaves_no_tree
