# Issue #701 — flip the mockup gate to skip-by-default: ui-ux-designer still posts mockups for the
# record, but the pipeline no longer pauses on `MOCKUPS PENDING APPROVAL` by default. It pauses only
# when JP explicitly asked to review this ticket's mockups — a `**[jp] REVIEW MOCKUPS**` comment,
# checked by `review_mockups_requested` (hooks/pipeline-markers.sh). That marker is deliberately NOT
# a routing marker and NOT an approval: it only ever answers "does the mockup gate pause?".
#
#   AC1  a UI ticket with no REVIEW MOCKUPS marker proceeds past MOCKUPS PENDING APPROVAL
#        automatically — terminal_kind is not a gate, and the pre-dispatch / structural checks treat
#        mockups as cleared. (supervisor-level terminal_kind cases live in
#        skills/orchestrate/test/terminal_kind.test.sh, run separately — not duplicated here.)
#   AC2  a ticket where JP asked to review still pauses for approval as before (same test file,
#        "review requested: still gate").
#   AC3  the REVIEW MOCKUPS marker is never an approval and never a routing marker in its own right —
#        it cannot accidentally clear a BLOCKED/AWAITING GO or become the gate marker itself.
#   AC4  SKIP MOCKUPS still supersedes the gate regardless (unaffected, test-mockup-skip-substring.sh
#        already pins marker_last_jq's override — not duplicated here).
#   AC5  docs: orchestrator.md's default-proceed row, the JP review-mockups marker paragraph, and
#        product-manager.md no longer firing the #470 up-front ask (test-mockup-skip-ask.sh).
#
# Reuses ROOT_MG / MARKERS_MG / ORCH_MG / mg_has from test-mockup-gate-exact-marker.sh (same shell,
# "gate-exact-marker" < "review-opt-in" alphabetically, so it has already run). Helpers prefixed mro_.

mro_review_requested() {  # mro_review_requested <comments-json array> -> "yes"/"no"/"err"
  ( . "$MARKERS_MG"
    if review_mockups_requested "$1"; then echo yes; else echo no; fi ) 2>/dev/null || echo err
}

# ---------------------------------------------------------------------------------------- review_mockups_requested

test_mro_exact_marker_detected_anywhere_any_author() {
  local c
  c='[{"body":"unrelated"},{"body":"**[jp] REVIEW MOCKUPS**\nJP said: \"review this one\""}]'
  assert_eq "$(mro_review_requested "$c")" yes "exact marker with a JP said line is detected" || return 1
  c='[{"body":"**[jp] REVIEW MOCKUPS**"}]'
  assert_eq "$(mro_review_requested "$c")" yes "bare exact marker (no JP said line) is enough — no author check required" || return 1
  c='[{"author":{"login":"someone-else"},"body":"**[jp] REVIEW MOCKUPS**"}]'
  assert_eq "$(mro_review_requested "$c")" yes "any author counts (same accepted-forgery-limit posture as SKIP MOCKUPS)" || return 1
}

test_mro_absent_or_prose_not_detected() {
  local c
  c='[{"body":"**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nmockups"}]'
  assert_eq "$(mro_review_requested "$c")" no "no marker at all" || return 1
  c='[{"body":"I would like to review mockups on this one please"}]'
  assert_eq "$(mro_review_requested "$c")" no "prose mentioning review/mockups is not the marker" || return 1
  c='[{"body":"**[jp] REVIEW MOCKUPS** please — this one needs a look"}]'
  assert_eq "$(mro_review_requested "$c")" no "trailing text after the marker is not an exact first line" || return 1
}

test_mro_crlf_and_trailing_whitespace_tolerated() {
  local c
  c=$(jq -nc '[{"body":"**[jp] REVIEW MOCKUPS**  \r"}]')
  assert_eq "$(mro_review_requested "$c")" yes "trailing CR/whitespace on the marker line is tolerated" || return 1
}

# ---------------------------------------------------------------------------------------- AC3: never an approval, never a routing marker

test_mro_marker_is_never_an_approval() {
  local re
  re=$( . "$MARKERS_MG"; jp_approval_re )
  printf '%s' '**[jp] REVIEW MOCKUPS**' | jq -Rs --arg re "$re" 'test($re)' | grep -qx true \
    && { fail "jp_approval_re must not match **[jp] REVIEW MOCKUPS**"; return 1; }
  return 0
}

test_mro_marker_is_never_a_routing_marker() {
  local re
  re=$( . "$MARKERS_MG"; marker_re )
  printf '%s' '**[jp] REVIEW MOCKUPS**' | jq -Rs --arg re "$re" 'test($re)' | grep -qx true \
    && { fail "marker_re() must not match **[jp] REVIEW MOCKUPS** — it must never become a routing marker"; return 1; }
  return 0
}

test_mro_jp_vocabulary_unchanged() {
  # markers_for jp must still be exactly the pre-#701 set — REVIEW MOCKUPS deliberately kept out of it
  # (see test_mg_ac7_pipeline_markers_byte_identical: markers_for/marker_re are untouched by this ticket).
  assert_eq "$( . "$MARKERS_MG"; markers_for jp )" "GO|MOCKUPS APPROVED|SKIP MOCKUPS" "jp vocabulary unchanged by #701" || return 1
}

test_mro_marker_last_jq_never_promotes_review_mockups() {
  # Unlike SKIP MOCKUPS (which marker_last_jq promotes over a stale MOCKUPS PENDING APPROVAL gate),
  # REVIEW MOCKUPS must never become "the newest real marker" — it is read only by review_mockups_requested,
  # never by the gate-marker computation itself.
  local out
  out=$( . "$MARKERS_MG"; . "$ROOT_MG/skills/orchestrate/pipeline-lib.sh"
    jq -n '{author:{login:"jpmoya"},comments:[{author:{login:"jpmoya"},body:"**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nx"},{author:{login:"jpmoya"},body:"**[jp] REVIEW MOCKUPS**"}]}' \
      | jq -r "$(marker_last_jq)" )
  assert_eq "$out" '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**' "REVIEW MOCKUPS never supersedes the gate marker the way SKIP MOCKUPS does" || return 1
}

# ---------------------------------------------------------------------------------------- AC1/AC2: supervisor tick (real dd/mg-style behavior)
# Reuses mg_thread / mg_tick / mg_assert_gate / mg_assert_not_gate from test-mockup-gate-exact-marker.sh
# (same shell), and test_mg_202's awk-extraction trick for a direct terminal_kind call.

test_mro_ac1_tick_default_restarts_not_held() {
  mg_thread '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**'
  mg_tick
  mg_assert_not_gate "AC1: no REVIEW MOCKUPS marker, tick restarts (no Slack/chat ask, no pause)" || return 1
}

test_mro_ac2_tick_review_requested_stays_held() {
  mg_thread '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**' '**[jp] REVIEW MOCKUPS**'
  mg_tick
  mg_assert_gate "AC2: JP asked to review, tick holds and waits on JP" || return 1
}

test_mro_terminal_kind_default_is_not_a_gate() {
  local sup="$ROOT_MG/skills/orchestrate/supervisor.sh" kind
  kind=$( eval "$(awk '/^terminal_kind\(\) \{/ {p=1} p {print} p && /^}/ {exit}' "$sup")"
    terminal_kind '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**' 1 "" . 0 )
  assert_eq "$kind" "" "AC1: terminal_kind with review_requested=0 is not a gate" || return 1
}

test_mro_terminal_kind_requested_is_a_gate() {
  local sup="$ROOT_MG/skills/orchestrate/supervisor.sh" kind
  kind=$( eval "$(awk '/^terminal_kind\(\) \{/ {p=1} p {print} p && /^}/ {exit}' "$sup")"
    terminal_kind '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**' 1 "" . 1 )
  assert_eq "$kind" "gate" "AC2: terminal_kind with review_requested=1 stays a gate" || return 1
}

# ---------------------------------------------------------------------------------------- docs (AC5)

test_mro_orchestrator_doc_default_is_not_a_gate() {
  mg_has "$ORCH_MG" "JP review-mockups marker (#701)" || return 1
  mg_has "$ORCH_MG" "no longer pauses on it by default" || return 1
  mg_has "$ORCH_MG" "Not terminal, no gate" || return 1
}

test_mro_orchestrator_doc_review_marker_still_gates() {
  mg_has "$ORCH_MG" "a valid \`**[jp] REVIEW MOCKUPS**\` marker is present" || return 1
  mg_has "$ORCH_MG" "**Terminal — human gate.**" || return 1
}

test_mro_orchestrator_doc_structural_check_qualified() {
  mg_has "$ORCH_MG" "mockups unapproved while a valid \`**[jp] REVIEW MOCKUPS**\` marker is present" || return 1
}

test_mro_orchestrator_doc_default_pass_logged() {
  mg_has "$ORCH_MG" '"reason":"no review requested; proceeding by default"' || return 1
}

run_test test_mro_ac1_tick_default_restarts_not_held
run_test test_mro_ac2_tick_review_requested_stays_held
run_test test_mro_terminal_kind_default_is_not_a_gate
run_test test_mro_terminal_kind_requested_is_a_gate
run_test test_mro_exact_marker_detected_anywhere_any_author
run_test test_mro_absent_or_prose_not_detected
run_test test_mro_crlf_and_trailing_whitespace_tolerated
run_test test_mro_marker_is_never_an_approval
run_test test_mro_marker_is_never_a_routing_marker
run_test test_mro_jp_vocabulary_unchanged
run_test test_mro_marker_last_jq_never_promotes_review_mockups
run_test test_mro_orchestrator_doc_default_is_not_a_gate
run_test test_mro_orchestrator_doc_review_marker_still_gates
run_test test_mro_orchestrator_doc_structural_check_qualified
run_test test_mro_orchestrator_doc_default_pass_logged
