# #628 — the gs_* sandbox lives in lib/goal-sandbox.sh so GS_SKILL is always derived from the real in-tree file.
# Incident: a copy of the helpers sourced from /tmp derived GS_SKILL="/" and gs_tree_init ran `cp -R / <tmpfs>`.
# Expected values: the real path comes from this file's own location; the copy case from the mktemp dir we build.

GSL_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GSL_LIB="$GSL_HERE/lib/goal-sandbox.sh"

test_gsl_gs_skill_is_the_real_skill_dir() {
  local got want; want=$(cd "$GSL_HERE/.." && pwd)
  got=$(bash -c '. "$1"; echo "$GS_SKILL"' _ "$GSL_LIB")
  assert_eq "$got" "$want" "GS_SKILL from the in-tree lib" || return 1
}

# A copy elsewhere derives from ITS location (two levels up), never "/" — and the test never calls gs_tree_init on it.
test_gsl_copy_elsewhere_is_not_root() {
  local d got; d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-gslcopy.XXXXXX")
  mkdir -p "$d/a/b/lib"; cp "$GSL_LIB" "$d/a/b/lib/goal-sandbox.sh"
  got=$(bash -c '. "$1"; echo "$GS_SKILL"' _ "$d/a/b/lib/goal-sandbox.sh")
  rm -rf "$d"
  assert_ne "$got" "/" "GS_SKILL of a copy" || return 1
  assert_eq "$got" "$d/a" "GS_SKILL of a copy follows the copy's location" || return 1
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
run_test test_gsl_no_extract_workarounds_remain
run_test test_gsl_supervisor_cleans_its_tree_instead_of_blanking
run_test test_gsl_limit_exit_leaves_no_tree
