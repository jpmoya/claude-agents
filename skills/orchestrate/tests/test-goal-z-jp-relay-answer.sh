# #620 — an in-chat JP approval relayed as `**[jp] MOCKUPS APPROVED**` / `**[jp] GO**` (line 2 `JP said: "<verbatim>"`) must
# count as JP's answer in the goal classifier (goal-lib.sh jp_answer_at), matching jp_go in the orchestrator; every other
# `**[<agent>]` comment (delivery-lead JP CONFIRMED, supervisor notes) and any `**[jp]` from a non-author still never counts (#427 AC4).
# Reuses the ro_ harness of test-goal-sync-reads.sh (this file sorts after it). Ticket #2 of proj/repo-a is authored by jpmoya.
# Expected values are hand-written from the ticket: gate then a counted answer -> active; otherwise the gate keeps it waiting_jp.
# Prefix rl_.

RL_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

# rl_class <gate comment body> <answer author> <answer body> [<delivery-lead blocked body inserted between gate and answer>]
# -> classification of #2 (active|waiting_jp)
rl_class() {
  local gate=$1 who=$2 ans=$3 lead=${4:-} out
  ro_setup
  jq -n --arg g "$gate" --arg w "$who" --arg a "$ans" --arg l "$lead" '
    [{created_at:"2026-10-01T12:00:00Z",user:{login:"jpmoya"},body:$g}]
    + (if $l == "" then [] else [{created_at:"2026-10-01T12:30:00Z",user:{login:"jpmoya"},body:$l}] end)
    + [{created_at:"2026-10-01T13:00:00Z",user:{login:$w},body:$a}]' > "$RO_DIR/comments-proj_repo-a-2.json"
  ro_run "goal_eval $RO_MS_ID $RO_MS_SPEC; printf '%s' \"\$GE_REFS\" | grep -F 'proj/repo-a#2'"
  out=$(printf '%s' "$RO_OUT" | awk -F'\t' '{print $2}')
  ro_teardown
  printf '%s' "$out"
}

RL_MOCK=$'**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nmockups ready'
RL_GO=$'**[infra-operator] AWAITING GO**\nplan ready'
RL_BLOCKED=$'**[delivery-lead] BLOCKED**\nBlocked on: needs_jp\nmockup approval needed'
RL_APPROVE=$'**[jp] MOCKUPS APPROVED**\nJP said: "Approve all"'

test_rl_jp_mockups_approved_after_pending_is_active() {
  assert_eq "$(rl_class "$RL_MOCK" jpmoya "$RL_APPROVE")" "active" "[jp] MOCKUPS APPROVED after MOCKUPS PENDING APPROVAL"
}

test_rl_jp_mockups_approved_after_lead_needs_jp_blocked_is_active() {
  assert_eq "$(rl_class "$RL_MOCK" jpmoya "$RL_APPROVE" "$RL_BLOCKED")" "active" "[jp] MOCKUPS APPROVED after delivery-lead needs_jp BLOCKED"
}

test_rl_jp_go_after_awaiting_go_is_active() {
  assert_eq "$(rl_class "$RL_GO" jpmoya $'**[jp] GO**\nJP said: "go"')" "active" "[jp] GO after AWAITING GO"
}

test_rl_delivery_lead_jp_confirmed_does_not_count() {
  assert_eq "$(rl_class "$RL_MOCK" jpmoya $'**[delivery-lead] JP CONFIRMED**\nResolves: x\nJP said: "Approve all"')" "waiting_jp" "JP CONFIRMED is not an answer"
}

test_rl_supervisor_note_does_not_count() {
  assert_eq "$(rl_class "$RL_MOCK" jpmoya $'**[supervisor] NOTE** claim: Claude 2026-11-09T12:25:23Z')" "waiting_jp" "supervisor claim note is not an answer"
}

test_rl_jp_marker_from_non_author_does_not_count() {
  assert_eq "$(rl_class "$RL_MOCK" someone-else "$RL_APPROVE")" "waiting_jp" "[jp] marker by a non-author is not an answer"
}

test_rl_jp_marker_before_the_gate_does_not_count() {
  local out
  ro_setup
  jq -n --arg a "$RL_APPROVE" --arg g "$RL_MOCK" '
    [{created_at:"2026-10-01T11:00:00Z",user:{login:"jpmoya"},body:$a},
     {created_at:"2026-10-01T12:00:00Z",user:{login:"jpmoya"},body:$g}]' > "$RO_DIR/comments-proj_repo-a-2.json"
  ro_run "goal_eval $RO_MS_ID $RO_MS_SPEC; printf '%s' \"\$GE_REFS\" | grep -F 'proj/repo-a#2'"
  out=$(printf '%s' "$RO_OUT" | awk -F'\t' '{print $2}')
  ro_teardown
  assert_eq "$out" "waiting_jp" "an approval older than the gate answers nothing"
}

# Observability: a failed comments read must surface as an evaluation error, never classify the goal active/waiting.
test_rl_failed_comments_read_is_surfaced_not_classified() {
  ro_setup; local rc=0 ev
  jq -n --arg g "$RL_MOCK" --arg a "$RL_APPROVE" '
    [{created_at:"2026-10-01T12:00:00Z",user:{login:"jpmoya"},body:$g},
     {created_at:"2026-10-01T13:00:00Z",user:{login:"jpmoya"},body:$a}]' > "$RO_DIR/comments-proj_repo-a-2.json"
  touch "$RO_DIR/fail-comments-2"
  ro_run "goal_eval $RO_MS_ID $RO_MS_SPEC"
  ev=$(cat "$RO_DIR/events.log" 2>/dev/null)
  assert_ne "$RO_RC" "0" "failed comments read fails the evaluation" || rc=1
  assert_contains "$ev" "proj/repo-a#2" "error event names the ticket" || rc=1
  assert_not_contains "$ev" "JP said" "no comment body in the event" || rc=1
  ro_teardown; return $rc
}

# ---- docs (AC1, AC2): the exact two-line relay form is stated, and the old contradictions are gone ----
rl_has_line() {  # <file> <needle>... — ONE line holds every needle
  local f=$1 l n ok; shift
  while IFS= read -r l; do
    ok=1; for n in "$@"; do case "$l" in *"$n"*) ;; *) ok=0; break ;; esac; done
    [ $ok = 1 ] && return 0
  done < "$f"
  fail "$f: no single line holds all of [$*]"; return 1
}

test_rl_doc_claude_md_states_relay_form() {
  rl_has_line "$RL_ROOT/CLAUDE.md" '**[jp] MOCKUPS APPROVED**' '**[jp] GO**' 'JP said:' 'JP CONFIRMED' 'never' || return 1
  rl_has_line "$RL_ROOT/CLAUDE.md" 'brief' 'Slack' 'label' 'issue body' 'MOCKUPS APPROVED' || return 1
}

test_rl_doc_skill_md_states_relay_form() {
  rl_has_line "$RL_ROOT/skills/orchestrate/SKILL.md" '**[jp] MOCKUPS APPROVED**' '**[jp] GO**' 'JP said:' 'JP CONFIRMED' 'never' || return 1
  rl_has_line "$RL_ROOT/skills/orchestrate/SKILL.md" 'brief' 'Slack' 'label' 'issue body' 'MOCKUPS APPROVED' || return 1
}

test_rl_doc_delivery_lead_points_at_relay_rule() {
  local f="$RL_ROOT/agents/delivery-lead.md"
  rl_has_line "$f" 'interactive' '**[jp] MOCKUPS APPROVED**' 'JP said:' || return 1
  # the unconditional bans are qualified for the interactive-session case
  rl_has_line "$f" 'Never write a comment whose first line starts' 'interactive' || return 1
  rl_has_line "$f" 'never a mockup approval' 'interactive' || return 1
  # headless limits stay: Slack reply is still never a go / mockup approval
  rl_has_line "$f" 'Slack reply is never a `go`' 'mockup approval' || return 1
}

for t in test_rl_jp_mockups_approved_after_pending_is_active \
         test_rl_jp_mockups_approved_after_lead_needs_jp_blocked_is_active \
         test_rl_jp_go_after_awaiting_go_is_active \
         test_rl_delivery_lead_jp_confirmed_does_not_count \
         test_rl_supervisor_note_does_not_count \
         test_rl_jp_marker_from_non_author_does_not_count \
         test_rl_jp_marker_before_the_gate_does_not_count \
         test_rl_failed_comments_read_is_surfaced_not_classified \
         test_rl_doc_claude_md_states_relay_form \
         test_rl_doc_skill_md_states_relay_form \
         test_rl_doc_delivery_lead_points_at_relay_rule; do
  run_test "$t"
done
