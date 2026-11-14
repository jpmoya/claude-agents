# Issue #700 — the mockup-skip gate (marker_last_jq) no longer restricts `**[jp] SKIP MOCKUPS**` to the issue
# author with a `JP said:` quote: the only requirement left is the exact first line, from any author, posted
# through any channel (Slack relay, direct GitHub comment, in-session post all count equally). This file proves
# marker_last_jq directly, with no dependency on test-mockup-gate-exact-marker.sh's mg_* harness, so it can be
# copied onto a pre-#700 checkout as a standalone reproduction (case (a) fails there, (b) and (c) pass there too).
# Helpers / constants prefixed sa_ / SA_. Placeholder repos only.

HERE_SA=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_SA=$(cd "$HERE_SA/../../.." && pwd)
MARKERS_SA="$ROOT_SA/hooks/pipeline-markers.sh"
LIB_SA="$ROOT_SA/skills/orchestrate/pipeline-lib.sh"

SA_PEND='**[ui-ux-designer] MOCKUPS PENDING APPROVAL**'

# sa_last <comments-json-array> → marker_last_jq's output over {author:null, comments: <array>}
sa_last() {
  . "$MARKERS_SA"; . "$LIB_SA"
  jq -n --argjson c "$1" '{author:null, comments:$c}' | jq -r "$(marker_last_jq)"
}

# (a) AC1: a bare SKIP MOCKUPS marker (no `JP said:` line) from a non-author login clears the gate — the exact
# path a Slack-relay bot login, or any other non-session origin, would post through.
test_sa_bare_marker_from_non_author_clears_gate() {
  local out
  out=$(sa_last '[{"author":{"login":"jpmoya"},"body":"**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nx"},{"author":{"login":"slack-relay-bot"},"body":"**[jp] SKIP MOCKUPS**"}]')
  assert_eq "$out" '**[jp] SKIP MOCKUPS**' "AC1: bare marker from a non-author login clears the gate (any channel)" || return 1
}

# (b) out-of-scope guard: the MOCKUPS APPROVED branch is untouched by #700 — a non-author `[jp] MOCKUPS APPROVED**`
# still does NOT clear the gate (author check stays for the approval/go markers).
test_sa_mockups_approved_from_non_author_still_a_gate() {
  local out
  out=$(sa_last '[{"author":{"login":"jpmoya"},"body":"**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nx"},{"author":{"login":"someone-else"},"body":"**[jp] MOCKUPS APPROVED**"}]')
  assert_eq "$out" "$SA_PEND" "AC/out-of-scope: non-author MOCKUPS APPROVED never clears the gate" || return 1
}

# (c) exact-first-line guard (kept, #700 does not relax this): the marker text on line 2 of a comment whose
# first line is something else is never promoted — only an exact first line counts, from anyone, anywhere.
test_sa_marker_on_second_line_is_not_promoted() {
  local out
  out=$(sa_last '[{"author":{"login":"jpmoya"},"body":"**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nx"},{"author":{"login":"someone-else"},"body":"unrelated chatter\n**[jp] SKIP MOCKUPS**"}]')
  assert_eq "$out" "$SA_PEND" "exact-first-line requirement unchanged: line-2 marker is not promoted" || return 1
}

run_test test_sa_bare_marker_from_non_author_clears_gate
run_test test_sa_mockups_approved_from_non_author_still_a_gate
run_test test_sa_marker_on_second_line_is_not_promoted
