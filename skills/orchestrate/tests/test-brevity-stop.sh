# hooks/brevity-stop.sh (#806) — the mandated multi-line status card (CLAUDE.md "Status answers")
# must bypass the length/line/bullet gate; everything else is gated exactly as before. The hook
# reads a Stop-hook payload (`transcript_path` → a JSONL transcript) from stdin; each case builds a
# throwaway one-line transcript whose last assistant message is the fixture text. Exit 2 = rejected
# (rewrite), 0 = passed through. Prefix bs_ / BS_.

HERE_BS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_BS=$(cd "$HERE_BS/../../.." && pwd)
HOOK_BS="$ROOT_BS/hooks/brevity-stop.sh"

# bs_hook <message text> -> BS_OUT (stderr), returns the hook's exit code
bs_hook() {
  local msg=$1 tmp transcript input rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bs.XXXXXX")
  transcript="$tmp/transcript.jsonl"
  jq -n --arg t "$msg" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}' > "$transcript"
  input=$(jq -n --arg tp "$transcript" '{transcript_path:$tp, stop_hook_active:false}')
  BS_OUT=$(printf '%s' "$input" | env -u PIPELINE_AGENT bash "$HOOK_BS" 2>&1)
  rc=$?
  rm -rf "$tmp"
  return $rc
}

# bs_filler <n> -> n lines of ~90 chars each, no status-card markers anywhere
bs_filler() {
  local n=$1 i out=""
  for ((i=0; i<n; i++)); do
    out="${out}Line $i of narration describing implementation steps and verbose technical detail here.
"
  done
  printf '%s' "$out"
}

# bs_card <ticket label> -> one status card (7 lines), well over 90 chars/line
bs_card() {
  local label=$1
  printf 'Example ticket title here for this run (example-owner/project-a #%s) — PR #1 · release none yet\nSTATUS:    RUNNING\nMERGED TO STAGING: No        LIVE ON PROD: No — verify-shipped.sh has not run yet for this branch\nWHATS UP: a long sentence explaining the current state of this run in plain, non-technical language for JP to read\nNEEDED FROM YOU: Nothing — this run is proceeding on its own without needing a decision right now\nTECHNICAL PROBLEM: No\nSELF-HEAL TICKETS: None\n\n' "$label"
}

test_bs_short_reply_under_limits_passes_untouched() {
  bs_hook "Done. PR #42 (fix brevity hook) opened."
  assert_eq "$?" "0" "short reply: exit 0" || return 1
  assert_eq "$BS_OUT" "" "short reply: no rejection text" || return 1
}

test_bs_long_reply_no_status_card_markers_is_rejected() {
  local msg; msg=$(bs_filler 10)
  assert_lt "600" "${#msg}" "fixture sanity: filler exceeds 600 chars" || return 1
  bs_hook "$msg"
  assert_eq "$?" "2" "long plain reply: still rejected" || return 1
  assert_contains "$BS_OUT" "replies must be short" "long plain reply: rejection message present" || return 1
}

test_bs_multi_ticket_status_card_bypasses_the_gate() {
  local msg; msg="$(bs_card 101)$(bs_card 102)"
  assert_lt "600" "${#msg}" "fixture sanity: two cards exceed 600 chars" || return 1
  local lines; lines=$(printf '%s\n' "$msg" | grep -c .)
  assert_lt "7" "$lines" "fixture sanity: two cards exceed 7 lines" || return 1
  bs_hook "$msg"
  assert_eq "$?" "0" "status-card reply: passes without rejection" || return 1
  assert_eq "$BS_OUT" "" "status-card reply: no rejection text" || return 1
}

# Proves the card fixture above is only exempt BECAUSE of the NEEDED FROM YOU: line — remove it and
# the same oversized text is gated exactly like any other long reply.
test_bs_status_card_without_needed_from_you_is_still_gated() {
  local msg; msg=$(printf '%s%s' "$(bs_card 101)" "$(bs_card 102)" | grep -v '^NEEDED FROM YOU:')
  assert_lt "600" "${#msg}" "fixture sanity: two cards minus NEEDED FROM YOU still exceed 600 chars" || return 1
  bs_hook "$msg"
  assert_eq "$?" "2" "cards missing NEEDED FROM YOU: gated, not a false exemption" || return 1
}

test_bs_bolded_markdown_markers_still_bypass_the_gate() {
  local msg; msg="$(printf '%s%s' "$(bs_card 101)" "$(bs_card 102)" | sed -e 's/^STATUS:/**STATUS:**/' -e 's/^NEEDED FROM YOU:/**NEEDED FROM YOU:**/')"
  assert_lt "600" "${#msg}" "fixture sanity: bolded two-card fixture exceeds 600 chars" || return 1
  bs_hook "$msg"
  assert_eq "$?" "0" "bolded markers: still recognized as a status card" || return 1
}

# AC: a reply with the literal text "STATUS:" but no "NEEDED FROM YOU:" line is NOT a false
# exemption — it stays gated by length like any other long reply.
test_bs_literal_status_alone_without_needed_from_you_is_still_gated() {
  local msg; msg=$(bs_filler 10)
  msg="STATUS: this word happens to appear in an otherwise ordinary long reply with no card.
$msg"
  assert_lt "600" "${#msg}" "fixture sanity: STATUS-only long reply exceeds 600 chars" || return 1
  bs_hook "$msg"
  assert_eq "$?" "2" "STATUS: alone (no NEEDED FROM YOU:): still gated" || return 1
}

# #807 code-review spoof case: a reply carrying only the two original marker lines (STATUS: and
# NEEDED FROM YOU:, no TECHNICAL PROBLEM:) followed by a long block of unrelated narration must
# not be exempted — the missing third required label alone sends it back through the ordinary gate.
test_bs_spoof_two_markers_plus_long_narration_is_rejected() {
  local msg; msg="STATUS:    RUNNING
NEEDED FROM YOU: Nothing right now
$(bs_filler 60)"
  assert_lt "600" "${#msg}" "fixture sanity: spoof (2 markers + narration) exceeds 600 chars" || return 1
  bs_hook "$msg"
  assert_eq "$?" "2" "spoof with 2 markers + 60 lines narration: rejected, not exempted" || return 1
  assert_contains "$BS_OUT" "replies must be short" "spoof with 2 markers: rejection message present" || return 1
}

# Same spoof, but now with all three required labels present (STATUS:, NEEDED FROM YOU:,
# TECHNICAL PROBLEM:) — the reviewer's literal case. Labels alone are no longer enough: the
# message claims only one card (one of each label) yet runs ~60 lines of unrelated narration, far
# past the ~12-line-per-card cap, so it must still be rejected.
test_bs_spoof_three_markers_plus_long_narration_is_rejected() {
  local msg; msg="STATUS:    RUNNING
NEEDED FROM YOU: Nothing right now
TECHNICAL PROBLEM: No
$(bs_filler 60)"
  assert_lt "600" "${#msg}" "fixture sanity: spoof (3 markers + narration) exceeds 600 chars" || return 1
  local lines; lines=$(printf '%s\n' "$msg" | grep -c .)
  assert_lt "10" "$lines" "fixture sanity: spoof (3 markers + narration) exceeds the one-card line cap" || return 1
  bs_hook "$msg"
  assert_eq "$?" "2" "spoof with all 3 markers + 60 lines narration: rejected, not exempted" || return 1
  assert_contains "$BS_OUT" "replies must be short" "spoof with 3 markers: rejection message present" || return 1
}

# A legitimate multi-card status reply (three real tickets, each with all three required labels,
# correctly sized — no stray narration) must still pass untouched under the new per-card cap.
test_bs_real_three_card_status_reply_within_cap_passes() {
  local msg; msg="$(bs_card 101)$(bs_card 102)$(bs_card 103)"
  local lines; lines=$(printf '%s\n' "$msg" | grep -c .)
  assert_lt "600" "${#msg}" "fixture sanity: three cards exceed 600 chars" || return 1
  assert_lt "7" "$lines" "fixture sanity: three cards exceed the single-card line limit" || return 1
  bs_hook "$msg"
  assert_eq "$?" "0" "three legitimate cards within the per-card cap: still passes" || return 1
  assert_eq "$BS_OUT" "" "three legitimate cards within the per-card cap: no rejection text" || return 1
}

# The card count must be the MINIMUM of the three label counts, not just STATUS: occurrences —
# otherwise the spoof just moves: repeat STATUS: a bunch of times (no extra NEEDED FROM YOU: /
# TECHNICAL PROBLEM: lines) to buy a bigger line cap for one real "card" and a pile of narration.
test_bs_spoof_repeated_status_lines_does_not_inflate_the_cap() {
  local msg; msg="STATUS: RUNNING
STATUS: RUNNING
STATUS: RUNNING
STATUS: RUNNING
STATUS: RUNNING
STATUS: RUNNING
STATUS: RUNNING
NEEDED FROM YOU: Nothing right now
TECHNICAL PROBLEM: No
$(bs_filler 50)"
  assert_lt "600" "${#msg}" "fixture sanity: repeated-STATUS spoof exceeds 600 chars" || return 1
  bs_hook "$msg"
  assert_eq "$?" "2" "repeated STATUS: lines don't inflate the per-card cap: still rejected" || return 1
  assert_contains "$BS_OUT" "replies must be short" "repeated STATUS: spoof: rejection message present" || return 1
}

# A real card's NEEDED FROM YOU: is a bulleted list and SELF-HEAL TICKETS: can run multiple lines
# (CLAUDE.md "Status answers"), so a single legitimate card can exceed the template's bare 7 lines
# without being narration. The per-card cap must have headroom for that.
test_bs_real_card_with_bulleted_needed_from_you_passes() {
  local msg; msg="Example ticket title here for this run (example-owner/project-a #101) — PR #1 · release none yet
STATUS:    RUNNING
MERGED TO STAGING: No        LIVE ON PROD: No — verify-shipped.sh has not run yet for this branch
WHATS UP: a long sentence explaining the current state of this run in plain, non-technical language for JP to read
NEEDED FROM YOU:
- staging review is ready
- missing: A, B
- confirm the copy change
TECHNICAL PROBLEM: No
SELF-HEAL TICKETS: owner/repo #201 (3-5 word description) — open
owner/repo #202 (3-5 word description) — queued
"
  local lines; lines=$(printf '%s\n' "$msg" | grep -c .)
  assert_eq "$lines" "11" "fixture sanity: one card with bullets is 11 lines (over the bare 7-line template)" || return 1
  bs_hook "$msg"
  assert_eq "$?" "0" "one real card with a bulleted NEEDED FROM YOU: still passes" || return 1
  assert_eq "$BS_OUT" "" "one real card with a bulleted NEEDED FROM YOU: no rejection text" || return 1
}

run_test test_bs_short_reply_under_limits_passes_untouched
run_test test_bs_long_reply_no_status_card_markers_is_rejected
run_test test_bs_multi_ticket_status_card_bypasses_the_gate
run_test test_bs_status_card_without_needed_from_you_is_still_gated
run_test test_bs_bolded_markdown_markers_still_bypass_the_gate
run_test test_bs_literal_status_alone_without_needed_from_you_is_still_gated
run_test test_bs_spoof_two_markers_plus_long_narration_is_rejected
run_test test_bs_spoof_three_markers_plus_long_narration_is_rejected
run_test test_bs_real_three_card_status_reply_within_cap_passes
run_test test_bs_spoof_repeated_status_lines_does_not_inflate_the_cap
run_test test_bs_real_card_with_bulleted_needed_from_you_passes
