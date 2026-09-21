# Issue #65 fix cycle — guard: the only pre-existing test files this change may touch are the ones the
# ticket's SPEC RESOLVED named (they were rescoped/rewritten deliberately). Any other modified,
# deleted or renamed file under skills/orchestrate/tests fails here. New files (status A) are free.
# Replaces the guard that test-delegated-decision.sh's AC21 used to carry.
# Every function/variable is prefixed shs_ / SHS_ (all test files share one shell).

SHS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
SHS_ALLOWED="skills/orchestrate/tests/lib/fixture.sh
skills/orchestrate/tests/test-delegated-decision.sh
skills/orchestrate/tests/test-stall-liveness-docs.sh
skills/orchestrate/tests/test-supervisor-queue-order.sh"

test_shs_no_unlisted_pre_existing_test_modified() {
  local base d
  base=$(cd "$SHS_ROOT" && git merge-base HEAD origin/main 2>/dev/null)
  if [ -z "$base" ]; then printf '    (skipped: no origin/main merge-base)\n' >&2; return 0; fi
  # --no-renames: a rename shows as D + A, so the deleted source path is checked too
  d=$(cd "$SHS_ROOT" && git diff --no-renames --name-status "$base" -- skills/orchestrate/tests \
        | grep -v '^A' | cut -f2 | grep -vxF "$SHS_ALLOWED")
  assert_eq "$d" "" "only allow-listed pre-existing tests are modified/deleted" || return 1
}

run_test test_shs_no_unlisted_pre_existing_test_modified
