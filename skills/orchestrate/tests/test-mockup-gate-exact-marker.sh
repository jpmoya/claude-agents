# Issue #74 — mockup gate must be a deterministic marker test, not free prose. The gate's only
# written test today is "from the issue author", but every pipeline comment is authored by the
# single account `jpmoya`, so it cannot tell JP from a delegate — the same "approved on JP's
# behalf" wording passed on scheduler#687 and was refused on scheduler#717.
#
#   AC1  agents/orchestrator.md:53 — approval is a comment whose FIRST LINE is exactly
#        `**[jp] MOCKUPS APPROVED**`, worded on the model of :98; the approved/looks good/lgtm
#        list is gone from that row.
#   AC2  agents/orchestrator.md:163-165 — same single form, no prose alternatives, cap unchanged (2).
#   AC3  agents/orchestrator.md:54 — the revision row excludes any `**[<agent>] ...**`-shaped
#        first line (marker_re() as pattern source, not a hand-rolled agent list); such a comment
#        neither approves nor requests a revision, and the run stays parked.
#   AC4  agents/orchestrator.md:166 (outcome 3, "skip mockups") is deleted outright.
#   AC5  none of the 2026-09-21 approval bodies, and no "skip mockups" / "don't need mockups"
#        comment, clears the gate.
#   AC6  the gate outcome is logged to runs.jsonl as a `"stage":"mockup-gate"` validate line on
#        both pass and fail, with a `reason` naming the marker form — never who posted it.
#   AC7  hooks/pipeline-markers.sh byte-identical; project-manager still has no MOCKUPS APPROVED
#        marker. Net new mechanisms: 0.
#
# Characterisation cases (pass BEFORE and AFTER the change — do not "fix" them to fail first):
#   AC1/AC5's marker_re() cases and AC7 (marker_re()/markers_for already discriminate an exact
#   `**[jp] MOCKUPS APPROVED**` first line from prose — that is exactly why AC7 can require zero
#   new mechanisms), and the supervisor-level "MOCKUPS PENDING APPROVAL is always a gate" behavior
#   in terminal_kind(), which does not change under this ticket.
# Every other case fails until the ticket is implemented.
#
# Doc-contract cases read tracked files only (fixed-string / literal grep). Helpers/vars are
# prefixed mg_ / MG_ (all test files share one shell).

HERE_MG=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_MG=$(cd "$HERE_MG/../../.." && pwd)
SUP_MG="$HERE_MG/../supervisor.sh"
MARKERS_MG="$ROOT_MG/hooks/pipeline-markers.sh"
ORCH_MG="$ROOT_MG/agents/orchestrator.md"

# ---------------------------------------------------------------------------------------- helpers

mg_has() { grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }
mg_lacks() { if grep -qF -- "$2" "$1" 2>/dev/null; then fail "$(basename "$1"): must NOT contain [$2]"; return 1; fi; }
mg_text_has() { printf '%s\n' "$2" | grep -qF -- "$3" || { fail "$1: missing [$3] in:
$2"; return 1; }; }
mg_text_lacks() { if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1: must NOT contain [$3] in:
$2"; return 1; fi; }

# mg_row <needle> — the single orchestrator.md line containing <needle> (fails the caller if not exactly one)
mg_row() {
  local n
  n=$(grep -cF -- "$1" "$ORCH_MG")
  if [ "$n" != "1" ]; then printf ''; return 1; fi
  grep -F -- "$1" "$ORCH_MG"
}

# mg_section <file> <heading-prefix> — lines after the heading up to the next heading of the same or higher level
mg_section() {
  awk -v h="$2" '
    BEGIN { n = match(h, /[^#]/) - 1 }
    /^```/ { if (on) print; fence = !fence; next }
    !fence && index($0, h) == 1 { on = 1; next }
    on && !fence && match($0, /^#+ /) && (RLENGTH - 1) <= n { exit }
    on { print }' "$1"
}

mg_base() { (cd "$ROOT_MG" && git merge-base HEAD origin/main 2>/dev/null); }

# mg_matches <line> — prints true/false: does the no-argument marker_re match this first line?
mg_matches() {
  ( . "$MARKERS_MG" && jq -n --arg l "$1" --arg re "$(marker_re)" '$l | test($re)' )
}

# ---------------------------------------------------------------------------------------- AC1

test_mg_ac1_approval_row_is_exact_first_line_form() {
  local row s
  row=$(mg_row 'MOCKUPS PENDING APPROVAL` + JP approval comment')
  assert_ne "$row" "" "AC1: approval row exists (exactly one)" || return 1
  for s in '**[jp] MOCKUPS APPROVED**' 'first line' 'exactly'; do
    mg_text_has "AC1: approval row" "$row" "$s" || return 1
  done
  mg_text_has "AC1: approval row states the negative on the model of :98" "$row" 'not an approval' || return 1
}

test_mg_ac1_prose_alternatives_deleted_from_approval_row() {
  local row s
  row=$(mg_row 'MOCKUPS PENDING APPROVAL` + JP approval comment')
  assert_ne "$row" "" "AC1: approval row exists" || return 1
  for s in 'looks good' 'lgtm' '`approved`,'; do
    mg_text_lacks "AC1: approval row" "$row" "$s" || return 1
  done
}

# characterisation: marker_re() (unchanged, AC7) already tells an exact `**[jp] MOCKUPS APPROVED**`
# first line apart from any prose approval — this is why the fix needs zero new mechanisms.
test_mg_ac1_marker_re_already_matches_exact_form() {
  local r
  r=$(mg_matches '**[jp] MOCKUPS APPROVED**')
  assert_eq "$r" "true" "AC1 (characterisation): marker_re must match the exact jp marker" || return 1
}

test_mg_ac1_marker_re_rejects_prose_containing_approved() {
  local l r
  for l in "approved — MOCKUPS APPROVED on JP's behalf, see thread" 'approved' 'looks good' 'lgtm' \
           'LGTM, ship it' "Looks good, approved on JP's behalf"; do
    r=$(mg_matches "$l")
    assert_eq "$r" "false" "AC1 (characterisation): marker_re must NOT match prose [$l]" || return 1
  done
}

# ---------------------------------------------------------------------------------------- AC2

test_mg_ac2_outcome1_is_single_exact_form_no_prose() {
  local sec s
  sec=$(mg_section "$ORCH_MG" '### Mockup approval gate')
  assert_ne "$sec" "" "AC2: Mockup approval gate section exists" || return 1
  mg_text_has "AC2: outcome 1" "$sec" '**[jp] MOCKUPS APPROVED**' || return 1
  for s in '"approved"' 'looks good' 'lgtm'; do
    mg_text_lacks "AC2: outcome 1 must drop prose alternatives" "$sec" "$s" || return 1
  done
}

test_mg_ac2_revision_cap_unchanged_at_2() {
  local sec
  sec=$(mg_section "$ORCH_MG" '### Mockup approval gate')
  assert_ne "$sec" "" "AC2: section exists" || return 1
  mg_text_has "AC2: revision cap" "$sec" 'Maximum **2** revision cycles' || return 1
}

# ---------------------------------------------------------------------------------------- AC3

test_mg_ac3_revision_row_excludes_agent_marker_comments() {
  local row s
  row=$(mg_row 'JP revision feedback')
  assert_ne "$row" "" "AC3: revision-feedback row exists" || return 1
  for s in 'marker_re' 'parked'; do
    mg_text_has "AC3: revision row" "$row" "$s" || return 1
  done
}

# AC3 also forbids re-deriving the agent enumeration by hand: the row must not itself spell out
# two-or-more agent names joined the way a hand-rolled alternation would.
test_mg_ac3_revision_row_does_not_hand_roll_the_agent_list() {
  local row
  row=$(mg_row 'JP revision feedback')
  assert_ne "$row" "" "AC3: revision-feedback row exists" || return 1
  mg_text_lacks "AC3: revision row must not hand-roll agent alternation" "$row" 'product-manager|ux-flow-designer' || return 1
}

# ---------------------------------------------------------------------------------------- AC4

test_mg_ac4_skip_mockups_outcome_deleted() {
  local hits
  hits=$(grep -ic "skip mockups" "$ORCH_MG" || true)
  assert_eq "$hits" "0" "AC4: grep -i 'skip mockups' agents/orchestrator.md must return nothing" || return 1
  mg_lacks "$ORCH_MG" "don't need mockups" || return 1
}

test_mg_ac4_gate_section_has_exactly_two_outcomes() {
  local sec
  sec=$(mg_section "$ORCH_MG" '### Mockup approval gate')
  assert_ne "$sec" "" "AC4: section exists" || return 1
  mg_text_has "AC4: outcome 1 present" "$sec" '1. **JP approves**' || return 1
  mg_text_has "AC4: outcome 2 present" "$sec" '2. **JP requests revisions**' || return 1
  mg_text_lacks "AC4: outcome 3 must be gone" "$sec" '3. **JP' || return 1
}

# ---------------------------------------------------------------------------------------- AC5

# characterisation: marker_re() already refuses every 2026-09-21 incident body and the two
# skip-mockups phrasings, proving the exact-marker rule needs no new vocabulary to work.
test_mg_ac5_2026_09_21_bodies_do_not_clear_the_gate() {
  local l r
  for l in "approved — MOCKUPS APPROVED on JP's behalf, see thread" \
           'approved' 'looks good' 'lgtm' \
           'skip mockups' "don't need mockups"; do
    r=$(mg_matches "$l")
    assert_eq "$r" "false" "AC5 (characterisation): marker_re must NOT clear the gate for [$l]" || return 1
  done
}

# ---------------------------------------------------------------------------------------- AC5 (supervisor-level: real dd_-style behavior)

mg_env() {
  MG_PIPE=$(new_pipe); MG_HOME=$(new_home)
  MG_REPO="$MG_PIPE/repo-a"
  MG_GH="$MG_HOME/.local/bin"
  fixture_repo "$MG_REPO" "project-a/repo-a"
  mk_fake_gh "$MG_GH"
  echo "project-a/repo-a" > "$MG_GH/gh-name-with-owner"
  printf '#!/bin/bash\nexit 0\n' > "$MG_GH/claude"; chmod +x "$MG_GH/claude"   # never start a real run
}

mg_cleanup() { cleanup_running; rm -rf "$MG_PIPE" "$MG_HOME"; }

mg_tick() {
  HOME="$MG_HOME" PATH="$MG_GH:/usr/bin:/bin" PIPE="$MG_PIPE" QUEUE="$MG_PIPE/queue" LOGDIR="$MG_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$SUP_MG" >/dev/null 2>&1
}

# mg_thread <body>... — issue 74, exited, .start 1300 s old (past GRACE_PERIOD_SECS), oldest -> newest comments
mg_thread() {
  local arr='[]' b i=0
  mg_env
  mk_restarting "$MG_PIPE" 74 "$MG_REPO"
  python3 -c "
import datetime
print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=1300)).strftime('%Y-%m-%dT%H:%M:%SZ'))
" > "$MG_PIPE/orch-74.start"
  for b in "$@"; do
    i=$((i + 1))
    arr=$(printf '%s' "$arr" | jq --arg b "$b" --arg t "2026-09-21T0$i:00:00Z" '. + [{body: $b, createdAt: $t}]')
  done
  printf '%s' "$arr" > "$MG_GH/gh-issue-comments-json"
}

# mg_assert_gate <label> — after a tick: still held (gate stands), MOCKUPS PENDING APPROVAL named
mg_assert_gate() {
  local held alert log
  held=$(if [ -e "$MG_PIPE/orch-74.held" ]; then echo present; else echo absent; fi)
  alert=$(cat "$MG_PIPE/orch-74.alert" 2>/dev/null)
  log=$(cat "$MG_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  mg_cleanup
  assert_eq "$held" "present" "$1: .held" || return 1
  assert_contains "$alert" "MOCKUPS PENDING APPROVAL" "$1: alert names the gate marker" || return 1
  assert_contains "$log" "[held] #74" "$1: [held] logged" || return 1
}

# mg_assert_not_gate <label> — after a tick: no .held, normal restart path (gate lifted)
mg_assert_not_gate() {
  local held log
  held=$(if [ -e "$MG_PIPE/orch-74.held" ]; then echo present; else echo absent; fi)
  log=$(cat "$MG_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  mg_cleanup
  assert_eq "$held" "absent" "$1: .held" || return 1
  assert_contains "$log" "[queue-restart] #74" "$1: normal restart path" || return 1
}

test_mg_ac5_prose_approval_after_mockups_stays_a_gate() {
  mg_thread '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**' "approved — MOCKUPS APPROVED on JP's behalf, see thread"
  mg_tick
  mg_assert_gate "AC5: prose approval" || return 1
}

test_mg_ac5_skip_mockups_after_mockups_stays_a_gate() {
  mg_thread '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**' 'skip mockups'
  mg_tick
  mg_assert_gate "AC5: skip mockups" || return 1
}

# characterisation: the exact-form marker already lifts the gate today (jp is already a marker_re
# agent, MOCKUPS APPROVED already its vocabulary, AC7) — this is what makes the fix zero-mechanism.
test_mg_ac1_exact_marker_after_mockups_lifts_the_gate() {
  mg_thread '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**' '**[jp] MOCKUPS APPROVED**'
  mg_tick
  mg_assert_not_gate "AC1 (characterisation): exact jp marker lifts the gate" || return 1
}

# AC3: an ordinary agent NOTE comment after MOCKUPS PENDING APPROVAL must not be treated as JP
# revision feedback — the run stays parked (gate stands), it is not re-dispatched for revision.
test_mg_ac3_agent_note_after_mockups_stays_parked_not_a_revision() {
  mg_thread '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**' '**[product-manager] NOTE** relaying: JP is travelling, will review Friday.'
  mg_tick
  mg_assert_gate "AC3: agent NOTE comment" || return 1
}

# ---------------------------------------------------------------------------------------- AC6

test_mg_ac6_run_log_has_mockup_gate_pass_and_fail() {
  local log lines
  log=$(mg_section "$ORCH_MG" '## Run log')
  assert_ne "$log" "" "AC6: Run log section exists" || return 1
  mg_text_has "AC6: Run log" "$log" '"stage":"mockup-gate"' || return 1
  lines=$(printf '%s\n' "$log" | grep -F '"stage":"mockup-gate"')
  mg_text_has "AC6: mockup-gate pass example" "$lines" '"result":"pass"' || return 1
  mg_text_has "AC6: mockup-gate fail example" "$lines" '"result":"fail"' || return 1
  mg_text_has "AC6: mockup-gate examples name the marker form" "$lines" 'MOCKUPS APPROVED' || return 1
}

test_mg_ac6_reason_never_argues_about_who_posted() {
  local log lines
  log=$(mg_section "$ORCH_MG" '## Run log')
  lines=$(printf '%s\n' "$log" | grep -F '"stage":"mockup-gate"')
  assert_ne "$lines" "" "AC6: mockup-gate lines exist" || return 1
  mg_text_lacks "AC6: reason must never argue about authorship" "$lines" 'issue author' || return 1
  mg_text_lacks "AC6: reason must never argue about authorship" "$lines" 'delegate' || return 1
  mg_text_lacks "AC6: reason must never argue about authorship" "$lines" "JP's behalf" || return 1
}

# ---------------------------------------------------------------------------------------- AC7 (guards)

test_mg_ac7_pipeline_markers_byte_identical() {
  local base d
  base=$(mg_base)
  if [ -z "$base" ]; then printf '    (AC7 byte-identity skipped: no origin/main merge-base)\n' >&2; return 0; fi
  d=$(cd "$ROOT_MG" && git diff --name-only "$base" -- hooks/pipeline-markers.sh)
  assert_eq "$d" "" "AC7: hooks/pipeline-markers.sh unchanged" || return 1
}

test_mg_ac7_project_manager_still_has_no_mockups_approved_marker() {
  local pm
  pm=$( . "$MARKERS_MG" && markers_for project-manager )
  assert_eq "$pm" "DECISION|JP CONFIRMED" "AC7: markers_for project-manager unchanged (no MOCKUPS APPROVED)" || return 1
}

# ---------------------------------------------------------------------------------------- run

run_test test_mg_ac1_approval_row_is_exact_first_line_form
run_test test_mg_ac1_prose_alternatives_deleted_from_approval_row
run_test test_mg_ac1_marker_re_already_matches_exact_form
run_test test_mg_ac1_marker_re_rejects_prose_containing_approved
run_test test_mg_ac2_outcome1_is_single_exact_form_no_prose
run_test test_mg_ac2_revision_cap_unchanged_at_2
run_test test_mg_ac3_revision_row_excludes_agent_marker_comments
run_test test_mg_ac3_revision_row_does_not_hand_roll_the_agent_list
run_test test_mg_ac4_skip_mockups_outcome_deleted
run_test test_mg_ac4_gate_section_has_exactly_two_outcomes
run_test test_mg_ac5_2026_09_21_bodies_do_not_clear_the_gate
run_test test_mg_ac5_prose_approval_after_mockups_stays_a_gate
run_test test_mg_ac5_skip_mockups_after_mockups_stays_a_gate
run_test test_mg_ac1_exact_marker_after_mockups_lifts_the_gate
run_test test_mg_ac3_agent_note_after_mockups_stays_parked_not_a_revision
run_test test_mg_ac6_run_log_has_mockup_gate_pass_and_fail
run_test test_mg_ac6_reason_never_argues_about_who_posted
run_test test_mg_ac7_pipeline_markers_byte_identical
run_test test_mg_ac7_project_manager_still_has_no_mockups_approved_marker
