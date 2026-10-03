# Issue #53 (ACs 1-2) — CLAUDE.md's "Exception — releases" paragraph names the app repos' release
# automation (close-shipped-issues.sh) as owner of post-release bookkeeping. Prose, so pinned by
# literal strings. Tracked files only: no gh, no network. AC2's "one line modified" and AC3 (no
# file under agents/, hooks/, skills/ changed) are diff properties, checked in review, not here.

HERE_RC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLAUDE_RC="$(cd "$HERE_RC/../../.." && pwd)/CLAUDE.md"

RC_SENTENCE='Post-release bookkeeping — closing the issues a release shipped (with a comment naming the version) and deleting the merged `release/*` branch — is owned by the app repos'"'"' release automation (`close-shipped-issues.sh`, run by `post-release-cleanup.yml` after a green prod deploy); agents and JP do not do it by hand.'

test_rc_ac1_sentence_verbatim_after_stamp_sentence_in_releases_paragraph() {
  local para
  para=$(grep -F '**Exception — releases**' "$CLAUDE_RC")
  assert_ne "$para" "" "AC1: releases paragraph exists" || return 1
  assert_contains "$para" "and report anything left unstamped. $RC_SENTENCE" "AC1: sentence verbatim, right after the stamp sentence" || return 1
  assert_contains "$para" "$RC_SENTENCE \`vX.Y.Z\` milestones are write-once" "AC1: milestone sentence still follows" || return 1
}

test_rc_ac2_close_shipped_issues_named_on_exactly_one_line() {
  assert_eq "$(grep -c 'close-shipped-issues.sh' "$CLAUDE_RC")" "1" "AC2: close-shipped-issues.sh appears on exactly one CLAUDE.md line"
}

run_test test_rc_ac1_sentence_verbatim_after_stamp_sentence_in_releases_paragraph
run_test test_rc_ac2_close_shipped_issues_named_on_exactly_one_line
