# Issue #328 — the infra PLAN FAIL loop cap gets one exit besides "report to JP": a later JP go (found
# with `jp_go`, dated after the capped PLAN FAIL) buys exactly one more infra-planner round. Delivery-lead
# decisions still cannot extend it. The orchestrator is instruction text, so these are doc-contract pins
# scoped to the specific row/paragraph (never a whole-file grep that another row could satisfy).
# Every function/variable is prefixed p328_ / P328_ (all test files share one shell).

HERE_P328=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_P328=$(cd "$HERE_P328/../../.." && pwd)
ORCH_P328="$ROOT_P328/agents/orchestrator.md"

# the PLAN FAIL routing row of the infra track table
p328_row() { grep -F '| `[infra-reviewer] PLAN FAIL' "$ORCH_P328" | head -1; }
# the paragraph that ends the infra track ("Nothing on this track ever creates a branch")
p328_para() { grep -F 'Nothing on this track ever creates a branch' "$ORCH_P328" | head -1; }
# the loop-cap section sentence about the infra PLAN FAIL cap
p328_cap_sentence() { grep -F 'The infra `PLAN FAIL` loop cap' "$ORCH_P328" | head -1; }
# the validation-table row for the JP-go resume after a capped PLAN FAIL
p328_val_row() { grep -F '| infra-planner (resume on JP go after a capped PLAN FAIL)' "$ORCH_P328" | head -1; }

test_p328_ac1_plan_fail_row_resumes_on_jp_go() {
  local row; row=$(p328_row)
  assert_ne "$row" "" "#328 AC1: PLAN FAIL row exists" || return 1
  assert_contains "$row" 'jp_go <N> <created_at of the capped PLAN FAIL>' "#328 AC1: go found with jp_go dated from the capped FAIL" || return 1
  # infra-planner must appear in the NEW resume clause (after the jp_go lookup), not merely elsewhere in the row
  assert_contains "${row#*'jp_go <N>'}" 'infra-planner' "#328 AC1: go re-dispatches infra-planner" || return 1
  assert_contains "$row" 'go URL in the prompt' "#328 AC1: go URL passed in the prompt" || return 1
  assert_contains "$row" 'One go = one extra revision round' "#328 AC1: one go = one extra round" || return 1
}

test_p328_ac1_go_may_name_a_stage_like_the_blocked_row() {
  local row; row=$(p328_row)
  assert_contains "$row" 'names a stage' "#328 AC1: go may name a stage to run instead (e.g. \"Planner: revise\")" || return 1
}

test_p328_ac1_next_fail_recaps_and_needs_new_go() {
  local row; row=$(p328_row)
  assert_contains "$row" 'cap is hit again' "#328 AC1: next FAIL hits the cap again" || return 1
  assert_contains "$row" 'log the loop-cap line again' "#328 AC1: loop-cap line logged again" || return 1
  assert_contains "$row" 'new go dated after that FAIL' "#328 AC1: a go dated before the new FAIL does not count" || return 1
}

test_p328_ac1_no_loop_cap_row_when_go_exists() {
  # The loop-cap validate line is logged only when no qualifying go exists (IF IT WORKS: no loop-cap row after an exact go).
  local row; row=$(p328_row)
  assert_contains "$row" 'no qualifying go' "#328 AC6: loop-cap logged only when no qualifying go" || return 1
}

test_p328_ac5_go_dated_before_capped_fail_does_not_count() {
  # First cap: a go that predates the capped FAIL must not resume; loop-cap row is logged instead.
  local row; row=$(p328_row)
  assert_contains "$row" 'go dated before the capped' "#328 AC5: a go dated before the capped PLAN FAIL does not count (first cap)" || return 1
}

test_p328_ac2_delivery_lead_cannot_extend_plan_fail_cap() {
  local row sent
  row=$(p328_row); sent=$(p328_cap_sentence)
  assert_contains "$row" '[delivery-lead]' "#328 AC2: PLAN FAIL row names delivery-lead" || return 1
  assert_contains "$row" 'never extend' "#328 AC2: PLAN FAIL row says delivery-lead never extends the cap" || return 1
  assert_contains "$sent" 'no `[delivery-lead]` marker extends it' "#328 AC2: loop-cap section keeps the exclusion" || return 1
}

test_p328_ac3_para_no_longer_leaves_plan_fail_cap_with_jp() {
  local para; para=$(p328_para)
  assert_ne "$para" "" "#328 AC3: closing infra-track paragraph exists" || return 1
  # The old wording listed the PLAN FAIL cap among rows that "stay with JP whatever follows them".
  case "$para" in
    *'PLAN FAIL'*'whatever follows them'*) fail "#328 AC3: PLAN FAIL cap must not be listed as staying with JP whatever follows"; return 1 ;;
  esac
  assert_contains "$para" 'PLAN FAIL' "#328 AC3: paragraph still names the PLAN FAIL cap" || return 1
  assert_contains "$para" 'JP go' "#328 AC3: paragraph names the JP-go resume for the PLAN FAIL cap" || return 1
}

test_p328_ac3_stale_line_96_pointer_replaced() {
  local full sent; full=$(p328_cap_sentence)
  assert_ne "$full" "" "#328 AC3: infra cap sentence exists" || return 1
  # scope to the PLAN FAIL clause only (the code-track text earlier on the same line is out of scope)
  sent="${full#*'The infra `PLAN FAIL` loop cap'}"
  assert_not_contains "$sent" ':96' "#328 AC3: stale :96 pointer gone" || return 1
  assert_contains "$sent" 'PLAN FAIL row' "#328 AC3: pointer names the PLAN FAIL row" || return 1
  assert_not_contains "$sent" 'is unchanged' "#328 AC3: cap is no longer 'unchanged' (JP go now extends it)" || return 1
  assert_contains "$sent" 'JP go' "#328 AC3: PLAN FAIL clause names the JP-go exit" || return 1
}

test_p328_ac4_validation_row_for_jp_go_resume() {
  local row; row=$(p328_val_row)
  assert_ne "$row" "" "#328 AC4: validation row 'infra-planner (resume on JP go after a capped PLAN FAIL)' exists" || return 1
  assert_contains "$row" 'gh api' "#328 AC4: go resolves" || return 1
  assert_contains "$row" 'issue author' "#328 AC4: by the issue author" || return 1
  assert_contains "$row" 'after that capped' "#328 AC4: dated after the capped FAIL" || return 1
  assert_contains "$row" '`jp_go`' "#328 AC4: matched by jp_go" || return 1
}

test_p328_ac7_no_new_marker_or_state_and_supervisor_unchanged() {
  local base diff
  base=$(cd "$ROOT_P328" && git merge-base HEAD origin/main 2>/dev/null)
  assert_ne "$base" "" "#328 AC7: origin/main merge-base must resolve (fetch origin main); cannot verify supervisor.sh unchanged otherwise" || return 1
  diff=$(cd "$ROOT_P328" && git diff --stat "$base" -- skills/orchestrate/supervisor.sh)
  assert_eq "$diff" "" "#328 AC7: supervisor.sh unchanged" || return 1
  # the resume clause must name no new marker / counter / state file
  local row; row=$(p328_row)
  assert_contains "$row" 'No new marker' "#328 AC7: row states no new marker/counter/state file" || return 1
}

run_test test_p328_ac1_plan_fail_row_resumes_on_jp_go
run_test test_p328_ac1_go_may_name_a_stage_like_the_blocked_row
run_test test_p328_ac1_next_fail_recaps_and_needs_new_go
run_test test_p328_ac1_no_loop_cap_row_when_go_exists
run_test test_p328_ac5_go_dated_before_capped_fail_does_not_count
run_test test_p328_ac2_delivery_lead_cannot_extend_plan_fail_cap
run_test test_p328_ac3_para_no_longer_leaves_plan_fail_cap_with_jp
run_test test_p328_ac3_stale_line_96_pointer_replaced
run_test test_p328_ac4_validation_row_for_jp_go_resume
run_test test_p328_ac7_no_new_marker_or_state_and_supervisor_unchanged
