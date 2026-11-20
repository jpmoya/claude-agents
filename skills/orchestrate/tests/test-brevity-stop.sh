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

run_test test_bs_short_reply_under_limits_passes_untouched
run_test test_bs_long_reply_no_status_card_markers_is_rejected
run_test test_bs_multi_ticket_status_card_bypasses_the_gate
run_test test_bs_status_card_without_needed_from_you_is_still_gated
run_test test_bs_bolded_markdown_markers_still_bypass_the_gate
run_test test_bs_literal_status_alone_without_needed_from_you_is_still_gated
