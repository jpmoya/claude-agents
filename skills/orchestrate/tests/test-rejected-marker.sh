# Issue #115 — AC2, AC4, AC5, AC6, AC7, AC8(docs): the `REJECTED` marker vocabulary, its agent-definition / routing-table
# text, the INTAKE_AUTO_GO default flip and the README. Doc-contract cases read tracked files only.
#
#   AC2  vocabulary: hooks/pipeline-markers.sh registers REJECTED for exactly product-manager and fullstack-developer
#   AC3  (docs half) agents/orchestrator.md routing rows: 3 terminal reasons, needs-spec, inert cases
#   AC4  agents/fullstack-developer.md + agents/product-manager.md carry the REJECTED instruction scoped to user-feedback
#   AC5  (docs half) orchestrator continues from an existing [product-manager] READY marker when agent-go is added
#   AC6  config.sh default INTAKE_AUTO_GO=1; both explicit values still behave (the explicit-value cases of #114 are untouched)
#   AC7  scan-backlog.sh never stamps agent-proposed on user-feedback-needs-spec issues (regression of #114 AC3 — this case
#        PASSES before the change by design: it pins behaviour #115 must not break)
#   AC8  README documents step A and the REJECTED marker
# Every function/variable is prefixed rj_ / RJ_. Placeholder repo names only.

HERE_RJ=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_RJ=$(cd "$HERE_RJ/../../.." && pwd)
MARKERS_RJ="$ROOT_RJ/hooks/pipeline-markers.sh"
ORCH_RJ="$ROOT_RJ/agents/orchestrator.md"
DEV_RJ="$ROOT_RJ/agents/fullstack-developer.md"
PM_RJ="$ROOT_RJ/agents/product-manager.md"
README_RJ="$ROOT_RJ/README.md"

rj_matches() {  # rj_matches <first line> [<agent>] -> true/false against marker_re
  ( . "$MARKERS_RJ" && jq -n --arg l "$1" --arg re "$(marker_re ${2:+"$2"})" '$l | test($re)' )
}
rj_lines_with() { grep -iE -- "$2" "$1" 2>/dev/null; }   # rj_lines_with <file> <ERE> -> matching lines

# ------------------------------------------------------------------------------------------------ AC2

test_rj_ac2_markers_for_has_rejected_for_exactly_pm_and_developer() {
  local a got
  for a in product-manager fullstack-developer; do
    got=$( . "$MARKERS_RJ"; markers_for "$a" )
    assert_contains "|$got|" "|REJECTED|" "AC2: markers_for $a lists REJECTED" || return 1
  done
}

test_rj_ac2_no_other_agent_has_rejected() {
  local a got
  assert_contains "|$( . "$MARKERS_RJ"; markers_for product-manager )|" "|REJECTED|" "AC2: (non-vacuity) the registration exists at all" || return 1
  for a in ux-flow-designer ui-ux-designer solutions-architect test-writer test-reviewer code-reviewer deployer \
           infra-planner infra-reviewer infra-operator intake jp project-manager; do
    got=$( . "$MARKERS_RJ"; markers_for "$a" )
    assert_not_contains "$got" "REJECTED" "AC2: markers_for $a must not list REJECTED" || return 1
  done
}

test_rj_ac2_existing_markers_of_pm_and_developer_kept_alongside_rejected() {
  local pm dev
  pm=$( . "$MARKERS_RJ"; markers_for product-manager )
  assert_contains "|$pm|" "|REJECTED|" "AC2: (non-vacuity) REJECTED is registered while the old markers stay" || return 1
  pm=$( . "$MARKERS_RJ"; markers_for product-manager ); dev=$( . "$MARKERS_RJ"; markers_for fullstack-developer )
  for m in 'READY FOR ARCHITECTURE' 'READY FOR ENGINEERING' 'EFFORT APPROVAL NEEDED' 'BLOCKED'; do
    assert_contains "|$pm|" "|$m|" "AC2: product-manager keeps $m" || return 1
  done
  for m in 'IMPLEMENTED' 'TEST DEFECT' 'BLOCKED'; do
    assert_contains "|$dev|" "|$m|" "AC2: fullstack-developer keeps $m" || return 1
  done
}

test_rj_ac2_marker_re_accepts_the_two_allowed_authors() {
  local l r
  for l in '**[product-manager] REJECTED**' '**[fullstack-developer] REJECTED**' '**[product-manager] REJECTED** — not-a-bug'; do
    r=$(rj_matches "$l"); assert_eq "$r" "true" "AC2: no-arg marker_re matches [$l]" || return 1
  done
  r=$(rj_matches '**[product-manager] REJECTED**' product-manager); assert_eq "$r" "true" "AC2: marker_re product-manager matches REJECTED" || return 1
  r=$(rj_matches '**[fullstack-developer] REJECTED**' fullstack-developer); assert_eq "$r" "true" "AC2: marker_re fullstack-developer matches REJECTED" || return 1
}

test_rj_ac2_marker_re_rejects_other_authors_and_malformed_forms() {
  local l r
  r=$(rj_matches '**[product-manager] REJECTED**'); assert_eq "$r" "true" "AC2: (non-vacuity) the allowed form matches" || return 1
  for l in '**[code-reviewer] REJECTED**' '**[test-reviewer] REJECTED**' '**[deployer] REJECTED**' '**[intake] REJECTED**' \
           '**[orchestrator] REJECTED**' '**[project-manager] REJECTED**' '**[jp] REJECTED**' \
           '**[product-manager] REJECTEDX**' '**[product-manager] REJECT**' '**[fullstack-developer] rejected**' '**[test-writer] REJECTED**'; do
    r=$(rj_matches "$l"); assert_eq "$r" "false" "AC2: marker_re must NOT match [$l]" || return 1
  done
  r=$(rj_matches '**[code-reviewer] REJECTED**' code-reviewer); assert_eq "$r" "false" "AC2: per-agent marker_re code-reviewer rejects REJECTED" || return 1
}

# ------------------------------------------------------------------------------------------------ AC4

test_rj_ac4_developer_instruction_scoped_to_user_feedback() {
  assert_contains "$(tr '\n' ' ' < "$DEV_RJ" | tr -s ' ' | tr 'A-Z' 'a-z')" \
    'on a `user-feedback` issue, if you cannot reproduce with a failing test, or the answer needs a business rule, schema change or new endpoint, post `rejected` with the reason instead of `blocked`' \
    "AC4: fullstack-developer.md carries the ticket's REJECTED instruction (contiguous)" || return 1
}

test_rj_ac4_developer_names_the_reasons_and_reason_line() {
  local body; body=$(cat "$DEV_RJ")
  assert_contains "$body" 'Reason: not-a-bug | cannot-reproduce | duplicate of #N | needs-spec' "AC4: developer lists the Reason vocabulary" || return 1
  [ -n "$(rj_lines_with "$DEV_RJ" 'user-feedback.*reproduce with a failing test|reproduce with a failing test.*user-feedback')" ] \
    || { fail "AC4: developer.md must say a user-feedback bug fix first reproduces with a failing test"; return 1; }
}

test_rj_ac4_pm_instruction_scoped_to_user_feedback() {
  local body; body=$(cat "$PM_RJ")
  [ -n "$(rj_lines_with "$PM_RJ" 'REJECTED.*user-feedback|user-feedback.*REJECTED')" ] \
    || { fail "AC4: product-manager.md must tie REJECTED to user-feedback issues on one line"; return 1; }
  assert_contains "$body" 'Reason: not-a-bug | cannot-reproduce | duplicate of #N | needs-spec' "AC4: PM lists the Reason vocabulary" || return 1
  [ -n "$(rj_lines_with "$PM_RJ" 'REJECTED.*(never|not|only).*(without|other|non).*user-feedback|only.*user-feedback.*REJECTED|REJECTED.*only.*user-feedback')" ] \
    || { fail "AC4: product-manager.md must say REJECTED is only for issues labelled user-feedback"; return 1; }
}

test_rj_ac4_pm_does_not_add_agent_go_or_file_followups_on_idea_issues() {
  [ -n "$(rj_lines_with "$PM_RJ" 'user-feedback-needs-spec.*agent-go|agent-go.*user-feedback-needs-spec')" ] \
    || { fail "AC4/AC1: PM definition must say that on a user-feedback-needs-spec issue it never adds agent-go (no Parent: line, no inherited approval)"; return 1; }
}

# ------------------------------------------------------------------------------------------------ AC3 (docs half)

test_rj_ac3_orchestrator_has_routing_row_per_terminal_reason() {
  local r
  for r in 'not-a-bug' 'cannot-reproduce' 'duplicate of #N'; do
    [ -n "$(rj_lines_with "$ORCH_RJ" "REJECTED.*$r|$r.*REJECTED")" ] || { fail "AC3: orchestrator.md routing row must name REJECTED + [$r] on one line"; return 1; }
  done
  [ -n "$(rj_lines_with "$ORCH_RJ" 'REJECTED.*not planned|not planned.*REJECTED')" ] || { fail "AC3: terminal REJECTED row closes the issue as not planned"; return 1; }
}

test_rj_ac3_terminal_row_posts_note_removes_labels_and_does_not_alert() {
  local row; row=$(rj_lines_with "$ORCH_RJ" 'REJECTED.*not planned')
  assert_contains "$row" '**[orchestrator] NOTE**' "AC3: terminal row posts an orchestrator NOTE with the reason" || return 1
  assert_contains "$row" 'agent-go' "AC3: terminal row removes agent-go" || return 1
  assert_contains "$row" 'agent-in-progress' "AC3: terminal row removes agent-in-progress" || return 1
  printf '%s\n' "$row" | grep -qiE 'no BLOCKED|never BLOCKED|not (a )?BLOCKED|without (a )?BLOCKED|no alert' \
    || { fail "AC3: terminal row must say there is no BLOCKED alert to JP"; return 1; }
}

test_rj_ac3_needs_spec_row_swaps_labels_and_stops() {
  local row; row=$(rj_lines_with "$ORCH_RJ" 'REJECTED.*needs-spec.*user-feedback-needs-spec|user-feedback-needs-spec.*REJECTED.*needs-spec')
  [ -n "$row" ] || { fail "AC3: orchestrator.md needs-spec row (REJECTED + needs-spec + user-feedback-needs-spec) missing"; return 1; }
  for l in '`bug`' '`fast-lane`' 'agent-go'; do
    assert_contains "$row" "$l" "AC3: needs-spec row removes $l" || return 1
  done
  printf '%s\n' "$row" | grep -qiE 'stop' || { fail "AC3: needs-spec row stops the run"; return 1; }
  printf '%s\n' "$row" | grep -qiE 'open|not clos|stays' || { fail "AC3: needs-spec row leaves the issue open"; return 1; }
}

test_rj_ac3_inert_cases_are_documented() {
  local inert; inert=$(rj_lines_with "$ORCH_RJ" 'REJECTED.*inert|inert.*REJECTED')
  [ -n "$inert" ] || { fail "AC3: orchestrator.md must document when REJECTED is inert"; return 1; }
  printf '%s\n' "$inert" | grep -qE 'user-feedback' || { fail "AC3: inert case — no user-feedback label"; return 1; }
  printf '%s\n' "$inert" | grep -qiE 'product-manager.*fullstack-developer|fullstack-developer.*product-manager|other agent|any other|only from' \
    || { fail "AC3: inert case — author other than product-manager / fullstack-developer"; return 1; }
  printf '%s\n' "$inert" | grep -qiE 'unknown|unrecogni[sz]ed|other reason|bogus|not one of|outside' \
    || { fail "AC3: inert case — unrecognised Reason value"; return 1; }
}

# ------------------------------------------------------------------------------------------------ AC5 (docs half)

test_rj_ac5_orchestrator_continues_from_existing_pm_spec() {
  local row; row=$(rj_lines_with "$ORCH_RJ" 'agent-go.*(existing|already).*(product-manager|READY FOR)|(existing|already).*(product-manager|READY FOR).*agent-go')
  [ -n "$row" ] || { fail "AC5: orchestrator.md needs a continue-from-spec note (agent-go added on an issue that already has a [product-manager] READY marker)"; return 1; }
  printf '%s\n' "$row" | grep -qiE 'not re-?(run|dispatch|launch)|never re-?(run|dispatch|launch)|do not re-?(run|dispatch|launch)|without re-?(running|dispatching|launching)|skip' \
    || { fail "AC5: note must say the product-manager is NOT re-dispatched"; return 1; }
  printf '%s\n' "$row" | grep -qiE 'user-feedback-needs-spec|agent-proposed|spec' || { fail "AC5: note ties to the spec-only (idea) flow"; return 1; }
}

test_rj_ac5_markers_helper_sees_pm_ready_as_latest_marker_for_a_spec_only_thread() {
  # the routing starts from the latest routing marker: a spec-only thread's newest marker is the PM's READY (+ NOTEs are inert)
  local out
  out=$( . "$MARKERS_RJ"; printf '%s\n' \
    '**[product-manager] READY FOR ENGINEERING**' '**[supervisor] NOTE** claim: host' '**[product-manager] REJECTED**' |
    jq -R --arg re "$(marker_re)" 'select(test($re))' | tail -1 )
  assert_eq "$out" '"**[product-manager] REJECTED**"' "AC5: after a PM REJECTED the latest routing marker is REJECTED (NOTEs inert)" || return 1
  out=$( . "$MARKERS_RJ"; printf '%s\n' '**[product-manager] READY FOR ENGINEERING**' '**[supervisor] NOTE** claim: host' |
    jq -R --arg re "$(marker_re)" 'select(test($re))' | tail -1 )
  assert_eq "$out" '"**[product-manager] READY FOR ENGINEERING**"' "AC5: a spec-only thread's latest routing marker is the PM READY" || return 1
}

# ------------------------------------------------------------------------------------------------ AC6

rj_auto_go() {  # rj_auto_go <none|0|1> -> INTAKE_AUTO_GO as config.sh leaves it (isolated HOME)
  local home out; home=$(new_home)
  [ "$1" = none ] || echo "INTAKE_AUTO_GO=$1" > "$home/.claude/pipeline/config.local.sh"
  out=$(env -u INTAKE_AUTO_GO HOME="$home" PATH="/usr/bin:/bin" /bin/bash -c ". '$ROOT_RJ/skills/orchestrate/config.sh' >/dev/null 2>&1; printf %s \"\${INTAKE_AUTO_GO-unset}\"")
  rm -rf "$home"; printf '%s' "$out"
}

test_rj_ac6_config_default_is_one() {
  assert_eq "$(rj_auto_go none)" "1" "AC6: config.sh INTAKE_AUTO_GO defaults to 1" || return 1
  local line; line=$(grep -E '^INTAKE_AUTO_GO=' "$ROOT_RJ/skills/orchestrate/config.sh")
  assert_eq "${line%%[[:space:]#]*}" "INTAKE_AUTO_GO=1" "AC6: config.sh assignment is INTAKE_AUTO_GO=1" || return 1
}

test_rj_ac6_config_local_can_still_turn_it_off() {
  assert_eq "$(rj_auto_go none)" "1" "AC6: (non-vacuity) the default is 1 while the override still works" || return 1
  assert_eq "$(rj_auto_go 0)" "0" "AC6: config.local.sh INTAKE_AUTO_GO=0 still overrides" || return 1
  assert_eq "$(rj_auto_go 1)" "1" "AC6: config.local.sh INTAKE_AUTO_GO=1 still honoured" || return 1
}

test_rj_ac6_intake_labels_bug_default_gets_agent_go() {
  local home out; home=$(new_home)
  out=$(env -u INTAKE_AUTO_GO HOME="$home" PATH="/usr/bin:/bin" /bin/bash "$ROOT_RJ/skills/orchestrate/intake-labels.sh" bug 2>/dev/null | sort | tr '\n' ',')
  rm -rf "$home"
  assert_eq "$out" "add agent-go,add bug,add fast-lane,add user-feedback,remove user-feedback-intake," "AC6: a bug with no override gets agent-go (default 1), not agent-proposed" || return 1
}

test_rj_ac6_intake_labels_both_values_and_ideas_never_agent_go() {
  local v home out
  home=$(new_home); out=$(env -u INTAKE_AUTO_GO HOME="$home" PATH="/usr/bin:/bin" /bin/bash "$ROOT_RJ/skills/orchestrate/intake-labels.sh" bug 2>/dev/null | grep -c 'add agent-go'); rm -rf "$home"
  assert_eq "$out" "1" "AC6: (non-vacuity) default bug gets agent-go while explicit values behave" || return 1
  home=$(new_home); echo "INTAKE_AUTO_GO=0" > "$home/.claude/pipeline/config.local.sh"
  out=$(HOME="$home" PATH="/usr/bin:/bin" /bin/bash "$ROOT_RJ/skills/orchestrate/intake-labels.sh" bug 2>/dev/null | sort | tr '\n' ','); rm -rf "$home"
  assert_eq "$out" "add agent-proposed,add bug,add fast-lane,add user-feedback,remove user-feedback-intake," "AC6: explicit INTAKE_AUTO_GO=0 still adds agent-proposed, not agent-go" || return 1
  for v in 0 1; do
    home=$(new_home); echo "INTAKE_AUTO_GO=$v" > "$home/.claude/pipeline/config.local.sh"
    out=$(HOME="$home" PATH="/usr/bin:/bin" /bin/bash "$ROOT_RJ/skills/orchestrate/intake-labels.sh" idea 2>/dev/null | sort | tr '\n' ','); rm -rf "$home"
    assert_eq "$out" "add user-feedback,add user-feedback-needs-spec,remove user-feedback-intake," "AC6: idea with INTAKE_AUTO_GO=$v never gets agent-go" || return 1
  done
}

# ------------------------------------------------------------------------------------------------ AC7

test_rj_ac7_scan_never_stamps_agent_proposed_on_needs_spec_issues() {
  # regression of #114 AC3 for #115's flow: while step A runs (agent-in-progress + needs-spec) or before it starts, the scan stays off
  local home log edits
  home=$(new_home); log="$home/gh.log"; : > "$log"; mkdir -p "$home/bin"
  cat > "$home/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  expr=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
  json='[{"number":1,"title":"idea awaiting spec","labels":[{"name":"user-feedback"},{"name":"user-feedback-needs-spec"}]},
         {"number":2,"title":"idea, PM running","labels":[{"name":"user-feedback"},{"name":"user-feedback-needs-spec"},{"name":"agent-in-progress"}]},
         {"number":3,"title":"control","labels":[]}]'
  if [ -n "$expr" ]; then printf '%s' "$json" | jq -r "$expr"; else printf '%s' "$json"; fi
fi
exit 0
STUB
  chmod +x "$home/bin/gh"
  printf 'SCAN_BACKLOG=1\nDISPATCH_REPOS=("o/a:/tmp/a")\n' > "$home/.claude/pipeline/config.local.sh"
  HOME="$home" GH_LOG="$log" PATH="$home/bin:/usr/bin:/bin" /bin/bash "$ROOT_RJ/skills/orchestrate/scan-backlog.sh" >/dev/null 2>&1
  edits=$(grep '^issue edit ' "$log"); rm -rf "$home"
  assert_contains "$edits" "issue edit 3 --repo o/a" "AC7: the unlabelled control is stamped" || return 1
  assert_eq "$(printf '%s\n' "$edits" | grep -c .)" "1" "AC7: only the control is edited (needs-spec issues #1 and #2 are not)" || return 1
}

# ------------------------------------------------------------------------------------------------ AC8 (docs)

test_rj_ac8_readme_documents_step_a_and_the_rejected_marker() {
  local body; body=$(tr '\n' ' ' < "$README_RJ" | tr -s ' ')
  assert_contains "$body" '`user-feedback-needs-spec`' "AC8: README names the needs-spec label" || return 1
  [ -n "$(rj_lines_with "$README_RJ" 'user-feedback-needs-spec.*(product-manager|PM-only).*agent-proposed|(product-manager|PM-only).*user-feedback-needs-spec.*agent-proposed')" ] \
    || { fail "AC8: README documents step A (needs-spec -> PM-only run -> agent-proposed) on one line"; return 1; }
  [ -n "$(rj_lines_with "$README_RJ" 'REJECTED.*(not-a-bug|cannot-reproduce).*needs-spec|REJECTED.*Reason')" ] \
    || { fail "AC8: README documents the REJECTED marker and its Reason values"; return 1; }
}

test_rj_ac8_readme_and_agents_readme_no_longer_say_auto_go_defaults_to_zero() {
  assert_not_contains "$(cat "$README_RJ")" 'default 0' "AC6/AC8: README must not say INTAKE_AUTO_GO defaults to 0" || return 1
  assert_not_contains "$(cat "$ROOT_RJ/agents/README.md")" 'default 0' "AC6/AC8: agents/README.md must not say default 0" || return 1
  assert_not_contains "$(cat "$ROOT_RJ/skills/orchestrate/config.sh")" "needs #115" "AC6: config.sh comment no longer says it needs #115" || return 1
}

for t in $(declare -F | awk '{print $3}' | grep '^test_rj_'); do run_test "$t"; done
