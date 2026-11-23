# #808 AC2 — clear_in_progress makes ONE label-removal attempt per run key: the .label-cleared marker is written after the attempt
# whatever the result (before, a failing `gh issue edit` — e.g. the label does not exist in the repo — was retried every tick and each
# failure flushed the gh-budget read cache). Success logs "removed", failure logs one "remove failed" line. Fake gh records its calls.
# Every function/variable is prefixed ci_ / CI_. Placeholder names only.

CI_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CI_SUP="$CI_HERE/../supervisor.sh"

ci_fn() { awk -v f="$2" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$1"; }

ci_setup() {  # ci_setup <edit exit code>
  CI_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-ci.XXXXXX")
  mkdir -p "$CI_DIR/bin" "$CI_DIR/pipe" "$CI_DIR/repo"
  printf '#!/bin/bash\necho "$*" >> "%s/gh.log"\n[ "$1 $2" = "issue edit" ] && { echo "label not found" >&2; exit %s; }\nexit 0\n' "$CI_DIR" "$1" > "$CI_DIR/bin/gh"
  chmod +x "$CI_DIR/bin/gh"
  { ci_fn "$CI_SUP" clear_in_progress; ci_fn "$CI_SUP" gh_err_line; } > "$CI_DIR/fn.sh"
}
ci_teardown() { rm -rf "$CI_DIR"; }
ci_run() {  # one clear_in_progress call for run key rk1 / issue 12
  ( PATH="$CI_DIR/bin:$PATH" PIPE="$CI_DIR/pipe" LABEL_IN_PROGRESS=agent-in-progress
    slog() { printf '%s\n' "$*" >> "$CI_DIR/slog"; }
    . "$CI_DIR/fn.sh"; clear_in_progress "$CI_DIR/repo" 12 "run ended" rk1 )
}
ci_edits() { local n; n=$(grep -c '^issue edit' "$CI_DIR/gh.log" 2>/dev/null); echo "${n:-0}"; }

test_ci_failed_edit_writes_marker_and_is_not_retried() {
  ci_setup 1
  ci_run; ci_run; ci_run
  assert_eq "$(ci_edits)" 1 "three ticks, one gh issue edit" || { ci_teardown; return 1; }
  [ -f "$CI_DIR/pipe/orch-rk1.label-clear-tried" ] || { ci_teardown; fail "tried-marker written after a failed attempt"; return 1; }
  # launcher.sh refuses a manual relaunch when .label-cleared exists and the label is still on the issue: a failed removal must not set it
  [ ! -f "$CI_DIR/pipe/orch-rk1.label-cleared" ] || { ci_teardown; fail ".label-cleared must NOT be written by a failed attempt (blocks manual relaunch)"; return 1; }
  assert_eq "$(grep -c 'remove failed' "$CI_DIR/slog")" 1 "one failure line" || { ci_teardown; return 1; }
  assert_contains "$(cat "$CI_DIR/slog")" "[label] #12 — remove failed (label not found)" "failure line shape, gh error text included" || { ci_teardown; return 1; }
  assert_not_contains "$(cat "$CI_DIR/slog")" "removed agent-in-progress" "no success line" || { ci_teardown; return 1; }
  ci_teardown
}

test_ci_successful_edit_writes_marker_and_logs_removed() {
  ci_setup 0
  ci_run; ci_run
  assert_eq "$(ci_edits)" 1 "one gh issue edit" || { ci_teardown; return 1; }
  [ -f "$CI_DIR/pipe/orch-rk1.label-cleared" ] || { ci_teardown; fail "marker written"; return 1; }
  assert_contains "$(cat "$CI_DIR/slog")" "[label] #12 — removed agent-in-progress (run ended)" "success line" || { ci_teardown; return 1; }
  assert_not_contains "$(cat "$CI_DIR/slog")" "remove failed" "no failure line" || { ci_teardown; return 1; }
  ci_teardown
}

test_ci_success_does_not_write_tried_marker() {
  ci_setup 0
  ci_run
  [ ! -f "$CI_DIR/pipe/orch-rk1.label-clear-tried" ] || { ci_teardown; fail "success writes only .label-cleared"; return 1; }
  ci_teardown
}

test_ci_relaunch_paths_reset_the_tried_marker() {
  # a launch (supervisor do_launch, dispatch re-launch, manual launcher.sh) starts a fresh attempt budget for the run key
  local f n
  for f in supervisor.sh launcher.sh; do
    n=$(grep -c 'label-clear-tried' "$CI_HERE/../$f")
    [ "$n" -ge 1 ] || { fail "$f resets label-clear-tried"; return 1; }
  done
  assert_eq "$(grep -c 'rm -f.*label-clear-tried' "$CI_SUP")" 2 "do_launch and the dispatch tombstone clear both remove the tried marker" || return 1
  assert_contains "$(grep 'rm -f' "$CI_HERE/../launcher.sh" | grep label-cleared)" "label-clear-tried" "manual launcher clears it" || return 1
}

test_ci_existing_marker_means_no_call() {
  ci_setup 0
  touch "$CI_DIR/pipe/orch-rk1.label-cleared"
  ci_run
  assert_eq "$(ci_edits)" 0 "marker present: no call" || { ci_teardown; return 1; }
  rm -f "$CI_DIR/pipe/orch-rk1.label-cleared"; touch "$CI_DIR/pipe/orch-rk1.label-clear-tried"
  ci_run
  assert_eq "$(ci_edits)" 0 "tried-marker present: no call" || { ci_teardown; return 1; }
  ci_teardown
}

for t in test_ci_failed_edit_writes_marker_and_is_not_retried test_ci_successful_edit_writes_marker_and_logs_removed test_ci_existing_marker_means_no_call test_ci_success_does_not_write_tried_marker test_ci_relaunch_paths_reset_the_tried_marker; do
  run_test "$t"
done
