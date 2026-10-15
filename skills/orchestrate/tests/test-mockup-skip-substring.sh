# #272 fix cycle 2 — a non-JP line merely containing "[jp] SKIP MOCKUPS" must not promote over MOCKUPS PENDING APPROVAL.
# Helpers prefixed ss_. Reuses ROOT_MG / MARKERS_MG from test-mockup-gate-exact-marker.sh (same shell).

test_ss_substring_line_does_not_clear_gate() {
  local out
  out=$( . "$ROOT_MG/hooks/pipeline-markers.sh"; . "$ROOT_MG/skills/orchestrate/pipeline-lib.sh"
    jq -n '{author:{login:"jpmoya"},comments:[{author:{login:"jpmoya"},body:"**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nx"},{author:{login:"jpmoya"},body:"**[code-reviewer] FAIL: [jp] SKIP MOCKUPS**"}]}' \
      | jq -r "$(marker_last_jq)" )
  [ "$out" != '**[jp] SKIP MOCKUPS**' ] || { fail "substring line promoted to a skip marker"; return 1; }
}

test_ss_valid_skip_after_gate_still_clears() {
  local out
  out=$( . "$ROOT_MG/hooks/pipeline-markers.sh"; . "$ROOT_MG/skills/orchestrate/pipeline-lib.sh"
    jq -n '{author:{login:"jpmoya"},comments:[{author:{login:"jpmoya"},body:"**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nx"},{author:{login:"jpmoya"},body:"**[jp] SKIP MOCKUPS**\nJP said: \"skip\""}]}' \
      | jq -r "$(marker_last_jq)" )
  assert_eq "$out" '**[jp] SKIP MOCKUPS**' "valid skip supersedes gate" || return 1
}

run_test test_ss_substring_line_does_not_clear_gate
run_test test_ss_valid_skip_after_gate_still_clears
