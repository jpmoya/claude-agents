# hooks/ticket-description-check.sh — JP's rule that a ticket/issue/PR number must carry a short
# description. Exercises the hook as the real Stop hook does: build a one-line transcript with the
# assistant's final text, feed it stdin JSON with transcript_path, check the exit code (0 = pass,
# 2 = blocked). Covers the false positives this hook must not trip (markdown headers, hex colors,
# code spans, bold/link formatting) and the mandated status-card shape from CLAUDE.md.

HERE_TD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_TD=$(cd "$HERE_TD/../../.." && pwd)
HOOK_TD="$ROOT_TD/hooks/ticket-description-check.sh"

td_run() {  # td_run <assistant text> -> prints the hook's stderr, returns its exit code.
  # Explicitly clears PIPELINE_AGENT: the orchestrator exports it for every real pipeline-stage
  # process (agents/orchestrator.md), and a fullstack-developer fixing something under hooks/ or
  # skills/orchestrate/ would run this very suite from inside such a process — PIPELINE_AGENT
  # inherited from run-tests.sh's caller must not silently make every case here pass.
  local text=$1 dir transcript input rc out
  dir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-td.XXXXXX")
  transcript="$dir/transcript.jsonl"
  python3 -c "
import json, sys
print(json.dumps({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': sys.argv[1]}]}}))
" "$text" > "$transcript"
  input=$(python3 -c "
import json, sys
print(json.dumps({'stop_hook_active': False, 'transcript_path': sys.argv[1]}))
" "$transcript")
  out=$(printf '%s' "$input" | PIPELINE_AGENT= bash "$HOOK_TD" 2>&1)
  rc=$?
  rm -rf "$dir"
  TD_LAST_OUT=$out
  return "$rc"
}

td_run_as_pipeline_agent() {  # same as td_run but with PIPELINE_AGENT set, like a real stage process
  local text=$1 dir transcript input rc out
  dir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-td.XXXXXX")
  transcript="$dir/transcript.jsonl"
  python3 -c "
import json, sys
print(json.dumps({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': sys.argv[1]}]}}))
" "$text" > "$transcript"
  input=$(python3 -c "
import json, sys
print(json.dumps({'stop_hook_active': False, 'transcript_path': sys.argv[1]}))
" "$transcript")
  out=$(printf '%s' "$input" | PIPELINE_AGENT=fullstack-developer bash "$HOOK_TD" 2>&1)
  rc=$?
  rm -rf "$dir"
  TD_LAST_OUT=$out
  return "$rc"
}

test_td_bare_ticket_numbers_block() {
  td_run "Filed #1959 and #1960 for this."
  assert_eq "$?" "2" "bare ticket numbers with no description must block" || return 1
}

test_td_paren_after_description_passes() {
  td_run "Filed #1184 (remove technician self-revert) for this."
  assert_eq "$?" "0" "JP's own example format must pass" || return 1
}

test_td_colon_after_description_passes() {
  td_run "Filed #1184: remove technician self-revert for this."
  assert_eq "$?" "0" "colon-separated description must pass" || return 1
}

test_td_description_before_enclosing_parens_passes() {
  td_run "I merged the remove-technician-self-revert fix (#1184)."
  assert_eq "$?" "0" "description phrase right before the enclosing parens must pass" || return 1
}

test_td_markdown_headers_never_trip() {
  td_run "# Summary
Here is some ## Subheading text, no ticket refs."
  assert_eq "$?" "0" "markdown headers must never be treated as ticket refs" || return 1
}

test_td_hex_colors_in_code_spans_ignored() {
  td_run "Use color \`#123456\` for the background."
  assert_eq "$?" "0" "a hex color inside a code span must not be treated as a ticket ref" || return 1
}

test_td_owner_repo_ref_needs_description() {
  td_run "See jpmoya/claude-agents#415 for context."
  assert_eq "$?" "2" "an owner/repo#n ref needs a description too" || return 1
  td_run "See jpmoya/claude-agents#415 (never ask JP unless his call) for context."
  assert_eq "$?" "0" "...and passes once one is given" || return 1
}

test_td_short_clean_reply_passes() {
  td_run "Done."
  assert_eq "$?" "0" "a reply with no ticket ref at all must pass" || return 1
}

test_td_status_card_template_passes() {
  # The exact mandated shape from CLAUDE.md's status-card section: the ticket title describes
  # the issue number, and the trailing 'PR #<n>' doesn't need its own separate description.
  td_run "Remove technician self-revert (scheduler #1184) — PR #1190 · release none yet"
  assert_eq "$?" "0" "the mandated status-card line must pass as-is" || return 1
}

test_td_status_card_long_title_passes() {
  td_run "Customer/Company refactor phase 3: move payer to sales tool (scheduler #1201) — PR #1210 · release none yet"
  assert_eq "$?" "0" "a status card with a long (9+ word) ticket title must still pass" || return 1
}

test_td_long_lead_in_sentence_before_parens_passes() {
  td_run "The scheduler no longer lets a technician revert their own visit status once a supervisor has signed off on it (#1184)."
  assert_eq "$?" "0" "a long descriptive sentence ending in the bare ref in parens must pass" || return 1
}

test_td_bold_and_link_formatting_still_detected() {
  td_run "**#1184** (remove technician self-revert) is done."
  assert_eq "$?" "0" "bold formatting around a described ref must still read as described" || return 1
  td_run "Filed **#1959** and **#1960**."
  assert_eq "$?" "2" "bold formatting must not hide a genuinely bare ref" || return 1
}

test_td_inheritance_is_narrow_to_the_card_shape() {
  # Only the specific 'Title (repo #n) — PR #n' shape is exempted — a line that merely has one
  # described ref earlier does not let an unrelated bare ref on the same line ride along.
  td_run "Filed #1959 (fix the retry logic bug) and #1960."
  assert_eq "$?" "2" "a second, unrelated ref on the same line still needs its own description" || return 1
}

test_td_card_with_owner_slash_repo_label_passes() {
  td_run "Remove technician self-revert (Benjis-Plants/benjis-scheduler #1184) — PR #1190 · release none yet"
  assert_eq "$?" "0" "a full owner/repo label (with a slash) inside the parens must still pass" || return 1
}

test_td_card_with_apostrophe_label_passes() {
  td_run "Remove technician self-revert (Benji's scheduler #1184) — PR #1190 · release none yet"
  assert_eq "$?" "0" "a label with an apostrophe inside the parens must still pass" || return 1
}

test_td_same_ref_repeated_later_in_message_inherits_coverage() {
  # A status card's header line describes the PR; a later line in the same report
  # ('WHAT'S UP: ...') re-mentions the same PR number with no parenthetical of its own —
  # that's the same thing already named higher up, not a second undescribed reference.
  td_run "Remove technician self-revert (scheduler #1184) — PR #1190 · release none yet
STATUS:    RUNNING
WHAT'S UP: PR #1190 is waiting on CI."
  assert_eq "$?" "0" "the same ref repeated on a later line inherits the earlier line's coverage" || return 1
}

test_td_different_uncovered_ref_on_another_line_still_blocks() {
  td_run "Remove technician self-revert (scheduler #1184) — PR #1190 · release none yet
NEEDED FROM YOU: also check #1959."
  assert_eq "$?" "2" "a different, never-described ref elsewhere in the message still blocks" || return 1
}

test_td_pipeline_agent_set_always_skips() {
  td_run_as_pipeline_agent "Filed #1959 and #1960 for this."
  assert_eq "$?" "0" "with PIPELINE_AGENT set (a real pipeline-stage process), the hook must not check at all" || return 1
}

run_test test_td_bare_ticket_numbers_block
run_test test_td_paren_after_description_passes
run_test test_td_colon_after_description_passes
run_test test_td_description_before_enclosing_parens_passes
run_test test_td_markdown_headers_never_trip
run_test test_td_hex_colors_in_code_spans_ignored
run_test test_td_owner_repo_ref_needs_description
run_test test_td_short_clean_reply_passes
run_test test_td_status_card_template_passes
run_test test_td_status_card_long_title_passes
run_test test_td_long_lead_in_sentence_before_parens_passes
run_test test_td_bold_and_link_formatting_still_detected
run_test test_td_inheritance_is_narrow_to_the_card_shape
run_test test_td_card_with_owner_slash_repo_label_passes
run_test test_td_card_with_apostrophe_label_passes
run_test test_td_same_ref_repeated_later_in_message_inherits_coverage
run_test test_td_different_uncovered_ref_on_another_line_still_blocks
run_test test_td_pipeline_agent_set_always_skips
