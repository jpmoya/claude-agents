# #780 — held_answer (hooks/pipeline-markers.sh), the one detector of "JP answered the question that paused this ticket".
# Pure function over an issue JSON; expected values come from the ticket's acceptance criteria 1 and 2. Comment ids are what order
# the comments (never createdAt, #560); every comment is posted from the same account, as in production.
HA_ROOT=$(cd "$HERE/../../.." && pwd)
HA_BLOCK='**[fullstack-developer] BLOCKED**'

# ha_issue <author> <comments-jq-array> — {author, comments}
ha_run() {  # <issue json> → "<id>|<marker>" or "none"
  local out; out=$(bash -c '. "$1/hooks/pipeline-markers.sh"; held_answer "$2"' _ "$HA_ROOT" "$1" 2>/dev/null) || { printf 'none'; return 0; }
  printf '%s' "$out" | awk -F'\t' '{printf "%s|%s", $1, $2}'
}
# ha_json <issue author> then id|author|body triples via jq args: build with jq from a compact list "id<TAB>author<TAB>body"
ha_json() {  # <issue author> <file of tab-separated id, author, body (\n escaped as \\n)>
  jq -Rn --arg a "$1" '{author: {login: $a}, comments: [inputs | split("\t") | {id: (.[0] | tonumber), createdAt: "2026-11-19T10:00:00Z", author: {login: .[1]}, body: (.[2] | gsub("\\\\n"; "\n"))}]}' < "$2"
}
ha_case() {  # <issue author> <line>... each line "id<TAB>author<TAB>body"
  local a=$1 f; shift; f=$(mktemp "${TMPDIR:-/tmp}/ha.XXXXXX")
  printf '%s\n' "$@" > "$f"; ha_run "$(ha_json "$a" "$f")"; rm -f "$f"
}
T=$'\t'
HA_BLK_NEEDS="100${T}bot${T}$HA_BLOCK\\nBlocked on: needs_jp — pick one"
HA_BLK_OTHER="100${T}bot${T}$HA_BLOCK\\nBlocked on: other — design call"
HA_URL="https://github.com/o/r/issues/5#issuecomment-100"

test_ha_jp_go_after_needs_jp_block_is_the_answer() {
  assert_eq "$(ha_case jp "$HA_BLK_NEEDS" "105${T}jp${T}**[jp] GO**\\nJP said: \"go\"")" "105|GO" "AC1: [jp] GO after the BLOCKED answers it" || return 1
}
test_ha_plain_approval_phrase_by_the_issue_author_is_the_answer() {
  assert_eq "$(ha_case jp "$HA_BLK_NEEDS" "105${T}jp${T}approved - option B")" "105|JP reply" "AC2: JP's resolving comment answers" || return 1
}
test_ha_delegate_decision_with_matching_resolves_answers_an_other_block() {
  assert_eq "$(ha_case jp "$HA_BLK_OTHER" "110${T}jp${T}**[delivery-lead] DECISION**\\nResolves: $HA_URL\\nuse option A")" "110|DECISION" "AC2: DECISION + Resolves answers a class-other BLOCKED" || return 1
}
test_ha_decision_resolving_another_comment_is_not_an_answer() {
  assert_eq "$(ha_case jp "$HA_BLK_OTHER" "110${T}jp${T}**[delivery-lead] DECISION**\\nResolves: https://github.com/o/r/issues/5#issuecomment-99")" "none" "AC2 negative: Resolves names another comment" || return 1
}
test_ha_decision_without_resolves_is_not_an_answer() {
  assert_eq "$(ha_case jp "$HA_BLK_OTHER" "110${T}jp${T}**[delivery-lead] DECISION**\\nuse option A")" "none" "AC2 negative: no Resolves line" || return 1
}
test_ha_go_posted_before_the_block_is_not_an_answer() {
  assert_eq "$(ha_case jp "90${T}jp${T}**[jp] GO**" "$HA_BLK_NEEDS")" "none" "AC2 negative: a GO with a lower id than the BLOCKED" || return 1
}
test_ha_go_from_another_account_is_not_an_answer() {
  assert_eq "$(ha_case jp "$HA_BLK_NEEDS" "105${T}stranger${T}**[jp] GO**")" "none" "AC2 negative: not the issue author's account" || return 1
}
test_ha_chatty_jp_comment_is_not_an_answer() {
  assert_eq "$(ha_case jp "$HA_BLK_NEEDS" "105${T}jp${T}hmm let me think about this, will get back to you" "106${T}jp${T}go ahead and look at the logs first")" "none" "AC2 negative: a chatty comment, even one with 'go' in it" || return 1
}
test_ha_agent_marker_comment_from_the_same_account_is_not_a_jp_answer() {
  assert_eq "$(ha_case jp "$HA_BLK_NEEDS" "105${T}jp${T}**[supervisor] NOTE** go\\napproved" "106${T}jp${T}**[delivery-lead] JP CONFIRMED**\\napproved")" "none" "agent-marker comments never count as JP's approval" || return 1
}
test_ha_decision_never_answers_a_jp_only_gate() {
  assert_eq "$(ha_case jp "$HA_BLK_NEEDS" "110${T}jp${T}**[delivery-lead] DECISION**\\nResolves: $HA_URL")" "none" "needs_jp BLOCKED: a DECISION is not JP" || return 1
  assert_eq "$(ha_case jp "100${T}bot${T}**[infra-operator] AWAITING GO**\\nstep 4 is prod" "110${T}jp${T}**[delivery-lead] DECISION**\\nResolves: $HA_URL")" "none" "AWAITING GO: a DECISION is not a go" || return 1
  assert_eq "$(ha_case jp "100${T}bot${T}**[ui-ux-designer] MOCKUPS PENDING APPROVAL**" "110${T}jp${T}**[delivery-lead] JP CONFIRMED**\\nResolves: $HA_URL")" "none" "MOCKUPS PENDING APPROVAL: JP CONFIRMED is not an approval" || return 1
}
test_ha_awaiting_go_resumes_on_jps_own_word() {
  assert_eq "$(ha_case jp "100${T}bot${T}**[infra-operator] AWAITING GO**" "105${T}jp${T}go")" "105|JP reply" "a standalone 'go' line from the issue author answers an AWAITING GO" || return 1
}
test_ha_mockup_gate_accepts_approval_and_skip_but_other_gates_not_skip() {
  assert_eq "$(ha_case jp "100${T}bot${T}**[ui-ux-designer] MOCKUPS PENDING APPROVAL**" "105${T}jp${T}**[jp] MOCKUPS APPROVED**")" "105|MOCKUPS APPROVED" "mockup gate: MOCKUPS APPROVED" || return 1
  assert_eq "$(ha_case jp "100${T}bot${T}**[ui-ux-designer] MOCKUPS PENDING APPROVAL**" "105${T}jp${T}**[jp] SKIP MOCKUPS**\\nJP said: \"skip\"")" "105|SKIP MOCKUPS" "mockup gate: SKIP MOCKUPS" || return 1
  assert_eq "$(ha_case jp "$HA_BLK_NEEDS" "105${T}jp${T}**[jp] SKIP MOCKUPS**")" "none" "SKIP MOCKUPS answers only a mockup gate" || return 1
}
test_ha_machine_clearable_blocks_and_non_gates_are_left_to_their_own_paths() {
  assert_eq "$(ha_case jp "100${T}bot${T}$HA_BLOCK\\nBlocked on: ci_red — checks" "105${T}jp${T}**[jp] GO**")" "none" "auto-retry classes belong to step 1b" || return 1
  assert_eq "$(ha_case jp "100${T}bot${T}**[code-reviewer] PASS**" "105${T}jp${T}**[jp] GO**")" "none" "a PASS is not a gate" || return 1
  assert_eq "$(ha_case jp "100${T}bot${T}**[fullstack-developer] TEST DEFECT**" "105${T}jp${T}**[jp] GO**")" "none" "TEST DEFECT is not a gate this answers" || return 1
}
test_ha_newest_answer_wins_and_a_newer_gate_moves_the_baseline() {
  assert_eq "$(ha_case jp "$HA_BLK_NEEDS" "105${T}jp${T}**[jp] GO**" "108${T}jp${T}approved")" "108|JP reply" "newest valid answer id" || return 1
  assert_eq "$(ha_case jp "$HA_BLK_NEEDS" "105${T}jp${T}**[jp] GO**" "120${T}bot${T}$HA_BLOCK\\nBlocked on: needs_jp — again")" "none" "an answer older than the newest gate answers nothing" || return 1
}
test_ha_reads_gh_issue_view_shape_ids_from_the_comment_url() {
  local j out
  j=$(jq -nc '{author:{login:"jp"}, comments:[{url:"https://github.com/o/r/issues/5#issuecomment-100", body:"**[fullstack-developer] BLOCKED**\nBlocked on: needs_jp", author:{login:"bot"}, createdAt:"2026-11-19T09:00:00Z"},{url:"https://github.com/o/r/issues/5#issuecomment-105", body:"**[jp] GO**", author:{login:"jp"}, createdAt:"2026-11-19T10:00:00Z"}]}')
  out=$(ha_run "$j")
  assert_eq "$out" "105|GO" "gh issue view --json comments shape (url, no numeric id)" || return 1
}
test_ha_malformed_input_is_no_answer_not_a_crash() {
  assert_eq "$(ha_run 'not json')" "none" "garbage" || return 1
  assert_eq "$(ha_run '{"comments":null}')" "none" "no comments" || return 1
  assert_eq "$(ha_run '{"author":null,"comments":[{"id":1,"body":"**[fullstack-developer] BLOCKED**\nBlocked on: needs_jp"},{"id":2,"body":"**[jp] GO**"}]}')" "none" "no issue author: fail closed" || return 1
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ha_'); do run_test "$t"; done
