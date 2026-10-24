# Issue #470 — JP is asked up front whether a new UI ticket should go through mockup review or skip
# straight to engineering. The product-manager fires one async `pm-slack.sh ask ... mockup-skip` when
# it first posts `UI change: yes`; `pm-slack.sh poll` recognizes a skip-synonym reply to that specific
# ask and echoes the canonical `**[jp] SKIP MOCKUPS**` marker onto the issue, verbatim, as a bridge —
# never the PM's own judgment, never for any other kind of ask.
#
# Reuses skills/orchestrate/tests/test-pm-slack.sh's black-box harness (pms_* helpers / PMS_* constants)
# and test-mockup-gate-exact-marker.sh's doc-grep helpers (mg_has et al, sourced earlier by run-tests.sh's
# alphabetical pass). When this file runs standalone, pull in the pm-slack harness minus its own run_test
# calls (same trick test-mockup-skip-marker.sh uses for the goal-supervisor harness).

HERE_MSA=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_MSA=$(cd "$HERE_MSA/../../.." && pwd)
PM_MSA="$ROOT_MSA/agents/product-manager.md"
MARKERS_MSA="$ROOT_MSA/hooks/pipeline-markers.sh"

if ! type pms_setup >/dev/null 2>&1; then
  . <(sed '/^run_test /d' "$HERE_MSA/test-pm-slack.sh")
fi

# msa_ask <repo> <issue> <text> <kind> — ask carrying a kind, via the shared pms_run harness
msa_ask() { pms_run ask "$1" "$2" "$3" "$4"; }

# ---------------------------------------------------------------- script behavior
test_msa_ask_with_mockup_skip_kind_posts_once_and_records_kind() {
  pms_setup
  msa_ask "$PMS_REPO_A" 42 "New UI ticket: #42 Add export button. Mockups reviewed by you first (normal), or skip straight to engineering?" mockup-skip
  assert_exit0 "$PMS_RC" "ask with kind exits 0 ($PMS_OUT)" || return 1
  assert_eq "$(pms_n chat.postMessage)" 1 "exactly one DM posted" || return 1
  local kind; kind=$(awk -F'\t' -v r="$PMS_REPO_A" -v i=42 '$1==r && $2==i {print $8}' "$PMS_PIPE/pm-slack/asks.tsv")
  assert_eq "$kind" "mockup-skip" "kind recorded as the 8th asks.tsv field" || return 1
}

test_msa_poll_skip_synonym_reply_posts_skip_mockups_marker() {
  pms_setup
  msa_ask "$PMS_REPO_A" 42 "Mockups reviewed by you first (normal), or skip straight to engineering?" mockup-skip
  pms_history "1700000101.000100|$PMS_JP|#42 skip it"
  pms_run poll
  assert_exit0 "$PMS_RC" "poll ($PMS_OUT)" || return 1
  # The marker's --body spans two lines, so the fake gh's one-line-per-call log splits across two
  # physical lines; check the whole log for containment rather than grepping a single line.
  local c; c=$(gh_calls "$PMS_BIN")
  assert_eq "$(gh_call_count "$PMS_BIN" 'SKIP MOCKUPS')" 1 "SKIP MOCKUPS marker posted as its own comment, once" || return 1
  assert_contains "$c" 'JP said: "#42 skip it"' "marker quotes JP's reply verbatim" || return 1
  assert_eq "$(pms_gh_n 'jp-reply')" 1 "the ordinary jp-reply NOTE is also posted, once" || return 1
}

test_msa_poll_skip_synonyms_variants_all_post_the_marker() {
  local variant
  for variant in "skip" "go fast" "no mockups" "skip mockups please"; do
    pms_setup
    msa_ask "$PMS_REPO_A" 42 "question" mockup-skip
    pms_history "1700000101.000100|$PMS_JP|#42 $variant"
    pms_run poll
    assert_eq "$(gh_call_count "$PMS_BIN" 'SKIP MOCKUPS')" 1 "[$variant]: marker posted" || return 1
  done
}

test_msa_poll_non_skip_reply_does_not_post_marker() {
  pms_setup
  msa_ask "$PMS_REPO_A" 42 "question" mockup-skip
  pms_history "1700000101.000100|$PMS_JP|#42 let's review the mockups first"
  pms_run poll
  assert_exit0 "$PMS_RC" "poll ($PMS_OUT)" || return 1
  assert_eq "$(gh_call_count "$PMS_BIN" 'SKIP MOCKUPS')" 0 "no marker for a non-skip reply" || return 1
  assert_eq "$(pms_gh_n 'jp-reply')" 1 "the reply is still recorded as an ordinary jp-reply NOTE" || return 1
}

test_msa_ordinary_ask_skip_text_never_posts_marker() {
  pms_setup
  pms_ask "$PMS_REPO_A" 42 "Blocked: pick A or B."   # no kind — an ordinary free-text ask
  pms_history "1700000101.000100|$PMS_JP|#42 skip it"
  pms_run poll
  assert_exit0 "$PMS_RC" "poll ($PMS_OUT)" || return 1
  assert_eq "$(gh_call_count "$PMS_BIN" 'SKIP MOCKUPS')" 0 "a skip-sounding reply to an unrelated ask never writes the marker" || return 1
}

test_msa_poll_negated_skip_reply_never_posts_marker() {
  local variant
  for variant in "don't skip" "do not skip mockups" "no, review them, don't skip" "I don't want to skip, let's review" \
                 "I'd normally skip but review them this time" "Review mockups first, then skip to eng" "Skip? No, review them"; do
    pms_setup
    msa_ask "$PMS_REPO_A" 42 "question" mockup-skip
    pms_history "1700000101.000100|$PMS_JP|#42 $variant"
    pms_run poll
    assert_exit0 "$PMS_RC" "poll ($PMS_OUT)" || return 1
    assert_eq "$(gh_call_count "$PMS_BIN" 'SKIP MOCKUPS')" 0 "[$variant]: a negated skip never writes the marker" || return 1
  done
}

test_msa_reask_with_new_kind_overwrites_stale_kind() {
  # A mockup-skip ask later re-asked (same open record, text changed, no reminder due yet) as an
  # ordinary blocker must drop the mockup-skip kind — otherwise a later "skip it" answers the NEW,
  # unrelated question and still fires the SKIP MOCKUPS bridge (#470).
  pms_setup
  msa_ask "$PMS_REPO_A" 42 "Mockups reviewed by you first, or skip straight to engineering?" mockup-skip
  pms_ask "$PMS_REPO_A" 42 "Actually: pick A or B for the export format."   # re-ask, no kind — same open record
  local kind; kind=$(awk -F'\t' -v r="$PMS_REPO_A" -v i=42 '$1==r && $2==i {print $8}' "$PMS_PIPE/pm-slack/asks.tsv")
  assert_eq "$kind" "" "kind cleared on re-ask without one" || return 1
  pms_history "1700000101.000100|$PMS_JP|#42 skip it"
  pms_run poll
  assert_eq "$(gh_call_count "$PMS_BIN" 'SKIP MOCKUPS')" 0 "a skip reply to the re-asked (now ordinary) question never writes the marker" || return 1
}

# ---------------------------------------------------------------- hook vocabulary
test_msa_skip_mockups_regex_matches_synonyms_and_rejects_glued_words() {
  local t
  for t in "skip" "skip it" "skip mockups" "skip the mockups" "go fast" "go faster" "no mockups" "faster route"; do
    ( . "$MARKERS_MSA"; is_jp_skip_mockups_reply "#42 $t" ) || { fail "must match: $t"; return 1; }
  done
  for t in "skipped" "skipping" "mockups" "approved" "go ahead and review the mockups" \
           "don't skip" "do not skip mockups" "no, review them, don't skip" "I don't want to skip, let's review" \
           "I'd normally skip but review them this time" "Review mockups first, then skip to eng" "Skip? No, review them"; do
    ( . "$MARKERS_MSA"; is_jp_skip_mockups_reply "#42 $t" ) && { fail "must not match: $t"; return 1; }
  done
  return 0
}

# ---------------------------------------------------------------- product-manager.md docs
test_msa_pm_doc_describes_the_mockup_skip_ask() {
  mg_has "$PM_MSA" "pm-slack.sh ask" || return 1
  mg_has "$PM_MSA" "mockup-skip" || return 1
  mg_has "$PM_MSA" "UI change: yes" || return 1
  mg_has "$PM_MSA" "non-blocking" || return 1
  mg_has "$PM_MSA" "is_jp_skip_mockups_reply" || return 1
}
test_msa_pm_doc_never_fires_for_ui_change_no() {
  mg_has "$PM_MSA" "Never fire it for \`UI change: no\`" || return 1
}
test_msa_pm_doc_marker_is_posted_by_the_script_not_the_pm() {
  local t; t=$(grep -F 'written by the script' "$PM_MSA")
  [ -n "$t" ] || { fail "doc must say the marker is written by the script, not the PM"; return 1; }
  assert_contains "$t" "never by you" "doc keeps the PM-never-writes invariant explicit here too" || return 1
}

run_test test_msa_ask_with_mockup_skip_kind_posts_once_and_records_kind
run_test test_msa_poll_skip_synonym_reply_posts_skip_mockups_marker
run_test test_msa_poll_skip_synonyms_variants_all_post_the_marker
run_test test_msa_poll_non_skip_reply_does_not_post_marker
run_test test_msa_ordinary_ask_skip_text_never_posts_marker
run_test test_msa_poll_negated_skip_reply_never_posts_marker
run_test test_msa_reask_with_new_kind_overwrites_stale_kind
run_test test_msa_skip_mockups_regex_matches_synonyms_and_rejects_glued_words
run_test test_msa_pm_doc_describes_the_mockup_skip_ask
run_test test_msa_pm_doc_never_fires_for_ui_change_no
msa_gate_accepts() {  # msa_gate_accepts <jp-reply-text> — builds the comment via the SAME skip_mockups_marker_body
  # pm-slack.sh calls, feeds it to the real gate matcher (marker_last_jq) and prints what the gate resolves to.
  local body; body=$( . "$MARKERS_MSA"; skip_mockups_marker_body "$1" )
  jq -n --arg pending '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**' --arg bridge "$body" \
    '{author: {login: "jpmoya"},
      comments: [ {author: {login: "jpmoya"}, body: $pending},
                  {author: {login: "jpmoya"}, body: $bridge} ]}' \
    | ( . "$MARKERS_MSA"; . "$ROOT_MSA/skills/orchestrate/pipeline-lib.sh"; jq -r "$(marker_last_jq)" )
}

test_msa_bridge_posted_body_clears_the_real_gate() {
  # Proves the gate's own matcher (marker_last_jq, hooks/pipeline-markers.sh + skills/orchestrate/pipeline-lib.sh)
  # accepts the EXACT body cmd_poll posts via skip_mockups_marker_body — not just that the fake gh log
  # contains the right strings, and not a hand-typed copy that could drift from what poll actually posts.
  # The gate requires the comment's author to be the issue author (jpmoya) with an exact
  # `**[jp] SKIP MOCKUPS**` first line and a `JP said: "<non-empty>"` second line.
  assert_eq "$(msa_gate_accepts '#42 skip it')" '**[jp] SKIP MOCKUPS**' "the real gate matcher accepts the bridge-posted comment" || return 1
}
run_test test_msa_bridge_posted_body_clears_the_real_gate

test_msa_bridge_posted_body_clears_the_real_gate_for_a_multiline_reply() {
  # A Slack reply can itself contain a newline ("#42\nskip it"); skip_mockups_marker_body must collapse it so
  # line 2 of the posted comment stays a single, closed `JP said: "..."` line — otherwise the gate's
  # single-line check rejects it and JP's skip silently never takes effect.
  assert_eq "$(msa_gate_accepts $'#42\nskip it')" '**[jp] SKIP MOCKUPS**' "a multi-line JP reply still clears the real gate" || return 1
}
run_test test_msa_bridge_posted_body_clears_the_real_gate_for_a_multiline_reply

run_test test_msa_pm_doc_marker_is_posted_by_the_script_not_the_pm
