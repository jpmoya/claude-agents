# Issue #701 — flip the mockup gate to skip-by-default; a new `**[jp] REVIEW MOCKUPS**` marker is the only
# way to opt a ticket back into the old terminal gate. Sorted after test-mockup-gate-exact-marker.sh (reuses
# its mg_* harness: ROOT_MG, MARKERS_MG, SUP_MG, HERE_MG, mg_thread/mg_tick/mg_assert_gate/mg_assert_not_gate)
# and before test-mockup-skip-marker.sh. Helpers/vars prefixed mro_ / MRO_ (not ro_/RO_ — already used by
# test-goal-sync-reads.sh, which every test file shares one shell with via run-tests.sh).
#
# `**[jp] REVIEW MOCKUPS**` is deliberately NEVER added to `markers_for jp` / `marker_re`: it must never be
# readable as a routing marker (which would displace the gate marker) or as an approval word (`jp_approval_re`
# builds its legacy alternation from `markers_for jp`). It is a flag read straight off raw comments, exactly
# like the `**[jp] SKIP MOCKUPS**` validity test it mirrors (any author, any channel, exact first line).

MRO_LIB="$ROOT_MG/skills/orchestrate/pipeline-lib.sh"
MRO_PEND='**[ui-ux-designer] MOCKUPS PENDING APPROVAL**'
MRO_REVIEW='**[jp] REVIEW MOCKUPS**'
MRO_SKIP='**[jp] SKIP MOCKUPS**'

# mro_mlj <comments-json-array> — marker_last_jq over a bare comments array, no gh call
mro_mlj() {
  ( . "$MARKERS_MG"; . "$MRO_LIB"
    jq -n --argjson c "$1" '{comments: $c}' | jq -r "$(marker_last_jq)" )
}

# ------------------------------------------------------------------ marker_last_jq unit cases
test_mro_pending_alone_defaults_to_skip() {
  local out; out=$(mro_mlj "$(jq -nc --arg b "$MRO_PEND" '[{body:$b,author:{login:"ui-ux-designer-bot"}}]')")
  assert_eq "$out" "$MRO_SKIP" "AC1: PENDING alone defaults to skip" || return 1
}
test_mro_review_before_pending_stays_pending() {
  local out; out=$(mro_mlj "$(jq -nc --arg r "$MRO_REVIEW" --arg b "$MRO_PEND" \
    '[{body:$r,author:{login:"jpmoya"}},{body:$b,author:{login:"x"}}]')")
  assert_eq "$out" "$MRO_PEND" "AC2: REVIEW MOCKUPS before PENDING stays a gate" || return 1
}
test_mro_review_and_pending_and_skip_still_skips() {
  local out; out=$(mro_mlj "$(jq -nc --arg r "$MRO_REVIEW" --arg b "$MRO_PEND" --arg s "$MRO_SKIP" \
    '[{body:$r,author:{login:"jpmoya"}},{body:$b,author:{login:"x"}},{body:$s,author:{login:"jpmoya"}}]')")
  assert_eq "$out" "$MRO_SKIP" "explicit SKIP MOCKUPS wins over a standing REVIEW MOCKUPS" || return 1
}
test_mro_non_exact_review_line_still_defaults_to_skip() {
  local out; out=$(mro_mlj "$(jq -nc --arg b "$MRO_PEND" \
    '[{body:"please review mockups before engineering",author:{login:"jpmoya"}},{body:$b,author:{login:"x"}}]')")
  assert_eq "$out" "$MRO_SKIP" "a prose sentence is not the REVIEW MOCKUPS marker" || return 1
}
test_mro_review_only_in_issue_body_still_defaults_to_skip() {
  local out; out=$( . "$MARKERS_MG"; . "$MRO_LIB"
    jq -n --arg r "$MRO_REVIEW" --arg b "$MRO_PEND" '{body:$r,comments:[{body:$b,author:{login:"x"}}]}' \
      | jq -r "$(marker_last_jq)" )
  assert_eq "$out" "$MRO_SKIP" "REVIEW MOCKUPS only in the issue body is never read" || return 1
}
test_mro_review_trailing_text_is_not_exact() {
  local out; out=$(mro_mlj "$(jq -nc --arg b "$MRO_PEND" \
    '[{body:"**[jp] REVIEW MOCKUPS** please",author:{login:"jpmoya"}},{body:$b,author:{login:"x"}}]')")
  assert_eq "$out" "$MRO_SKIP" "trailing text after the marker is not exact — defaults to skip" || return 1
}

# ------------------------------------------------------------------ never an approval / never a routing marker
test_mro_review_mockups_is_not_an_approval_word() {
  local re; re=$( . "$MARKERS_MG"; marker_re jp )
  local hit; hit=$(jq -n --arg l "$MRO_REVIEW" --arg re "$re" '$l | test($re)')
  assert_eq "$hit" "false" "REVIEW MOCKUPS must never match jp_approval_re (marker_re jp)" || return 1
}
test_mro_markers_for_jp_unchanged() {
  local v; v=$( . "$MARKERS_MG"; markers_for jp )
  assert_eq "$v" "GO|MOCKUPS APPROVED|SKIP MOCKUPS" "#701: markers_for jp must stay unchanged (REVIEW MOCKUPS is never added)" || return 1
}
test_mro_review_mockups_does_not_match_any_agent_marker_re() {
  local re; re=$( . "$MARKERS_MG"; marker_re )
  local hit; hit=$(jq -n --arg l "$MRO_REVIEW" --arg re "$re" '$l | test($re)')
  assert_eq "$hit" "false" "REVIEW MOCKUPS must never be a routing marker (would displace the gate)" || return 1
}

# ------------------------------------------------------------------ supervisor gate (integration, real mg_tick)
test_mro_pending_alone_is_not_held() {
  mg_thread "$MRO_PEND"
  mg_tick
  mg_assert_not_gate "AC1: PENDING alone is not held (skip-by-default)" || return 1
}
test_mro_review_then_pending_is_held() {
  mg_thread "$MRO_REVIEW" "$MRO_PEND"
  mg_tick
  mg_assert_gate "AC2: REVIEW MOCKUPS then PENDING is held" || return 1
}

# ------------------------------------------------------------------ docs (orchestrator.md)
ORCH_MRO="$ROOT_MG/agents/orchestrator.md"
test_mro_orchestrator_documents_skip_by_default() {
  mg_has "$ORCH_MRO" "skip-by-default" || return 1
  mg_has "$ORCH_MRO" '**[jp] REVIEW MOCKUPS**' || return 1
}
test_mro_orchestrator_review_marker_never_an_approval() {
  local t; t=$(grep -A2 'Mockup gate default' "$ORCH_MRO" | tr '\n' ' ')
  mg_text_has "review marker doc" "$t" "never" || return 1
}

run_test test_mro_pending_alone_defaults_to_skip
run_test test_mro_review_before_pending_stays_pending
run_test test_mro_review_and_pending_and_skip_still_skips
run_test test_mro_non_exact_review_line_still_defaults_to_skip
run_test test_mro_review_only_in_issue_body_still_defaults_to_skip
run_test test_mro_review_trailing_text_is_not_exact
run_test test_mro_review_mockups_is_not_an_approval_word
run_test test_mro_markers_for_jp_unchanged
run_test test_mro_review_mockups_does_not_match_any_agent_marker_re
run_test test_mro_pending_alone_is_not_held
run_test test_mro_review_then_pending_is_held
run_test test_mro_orchestrator_documents_skip_by_default
run_test test_mro_orchestrator_review_marker_never_an_approval
