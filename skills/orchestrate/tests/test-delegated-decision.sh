# Issue #59 — delegated decisions: `[project-manager] DECISION` / `JP CONFIRMED` resume a code-track
# BLOCKED, the TEST DEFECT cap and the loop cap. The test is the marker form plus a `Resolves:` pointer.
#
#   AC1-AC2    vocabulary (hooks/pipeline-markers.sh, evaluated the way the consumers do)
#   AC3-AC9    supervisor, one tick per fixture (fake gh, isolated HOME/PIPE/QUEUE/LOGDIR)
#   AC10-AC15  agents/orchestrator.md doc contract
#   AC16-AC18  agent definitions (Blocked on:) and agents/project-manager.md
#   AC19-AC20  README.md / CLAUDE.md / agents/README.md
#   AC21-AC22  gates: nothing outside the ticket's file list changed; no timer/counter/state file
#
# Characterisation cases (pass BEFORE and AFTER the change — do not "fix" them to fail first):
#   AC7 (all three), AC8 (a FAIL already restarts today), AC9 (one gh call per issue per tick already
#   holds), AC13's "still present" half and its byte-identical row, AC21/AC22 (guards).
# Every other case fails until the ticket is implemented.
#
# Doc-contract cases read tracked files only (fixed-string grep, per test-followup-rules-docs.sh).
# Every function/variable is prefixed dd_ / DD_ (all test files share one shell). Placeholder repo names only.

HERE_DD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DD=$(cd "$HERE_DD/../../.." && pwd)
SUP_DD="$HERE_DD/../supervisor.sh"
MARKERS_DD="$ROOT_DD/hooks/pipeline-markers.sh"
ORCH_DD="$ROOT_DD/agents/orchestrator.md"
PMGR_DD="$ROOT_DD/agents/project-manager.md"
README_DD="$ROOT_DD/README.md"
CLAUDE_DD="$ROOT_DD/CLAUDE.md"
AGREADME_DD="$ROOT_DD/agents/README.md"

# ---------------------------------------------------------------------------------------- helpers

dd_has() { grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }
dd_lacks() { if grep -qF -- "$2" "$1" 2>/dev/null; then fail "$(basename "$1"): must NOT contain [$2]"; return 1; fi; }
dd_text_has() { printf '%s\n' "$2" | grep -qF -- "$3" || { fail "$1: missing [$3] in:
$2"; return 1; }; }
dd_text_has_i() { printf '%s\n' "$2" | grep -qiE -- "$3" || { fail "$1: missing (any case, regex) [$3] in:
$2"; return 1; }; }
dd_text_lacks() { if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1: must NOT contain [$3]"; return 1; fi; }

# dd_section <file> <heading-prefix> — lines after the heading up to the next heading of the same or higher level
dd_section() {
  awk -v h="$2" 'index($0, h) == 1 { on = 1; next } on && /^#+ / { exit } on { print }' "$1"
}

dd_sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1; else sha256sum | cut -d' ' -f1; fi; }

dd_base() { (cd "$ROOT_DD" && git merge-base HEAD origin/main 2>/dev/null); }

# dd_matches <line> — prints true/false: does the no-argument marker_re match this first line?
dd_matches() {
  ( . "$MARKERS_DD" && jq -n --arg l "$1" --arg re "$(marker_re)" '$l | test($re)' )
}

# ---------------------------------------------------------------------------------------- AC1-AC2

test_dd_ac1_markers_for_project_manager_and_jp() {
  local pm jp
  pm=$( . "$MARKERS_DD" && markers_for project-manager )
  jp=$( . "$MARKERS_DD" && markers_for jp )
  assert_eq "$pm" "DECISION|JP CONFIRMED" "AC1: markers_for project-manager" || return 1
  assert_eq "$jp" "GO|MOCKUPS APPROVED" "AC1: markers_for jp unchanged" || return 1
}

test_dd_ac2_marker_re_matches_the_two_new_markers() {
  local l r
  for l in '**[project-manager] DECISION**' '**[project-manager] JP CONFIRMED**' '**[project-manager] DECISION** — merge first'; do
    r=$(dd_matches "$l")
    assert_eq "$r" "true" "AC2: marker_re must match [$l]" || return 1
  done
}

test_dd_ac2_marker_re_rejects_wrong_authority_and_off_vocabulary() {
  local l r
  for l in '**[project-manager] GO**' '**[project-manager] MOCKUPS APPROVED**' '**[project-manager] BLOCKED**' \
           '**[jp] DECISION**' "**Decision on JP's behalf (2026-09-21)**" '**JP: confirmed**' '**[project-manager] NOTE**'; do
    r=$(dd_matches "$l")
    assert_eq "$r" "false" "AC2: marker_re must NOT match [$l]" || return 1
  done
}

# ---------------------------------------------------------------------------------------- AC3-AC9 supervisor

# dd_env — sets DD_PIPE, DD_HOME, DD_REPO, DD_GH
dd_env() {
  DD_PIPE=$(new_pipe); DD_HOME=$(new_home)
  DD_REPO="$DD_PIPE/repo-a"
  DD_GH="$DD_HOME/.local/bin"
  fixture_repo "$DD_REPO" "project-a/repo-a"
  mk_fake_gh "$DD_GH"
  echo "project-a/repo-a" > "$DD_GH/gh-name-with-owner"
  printf '#!/bin/bash\nexit 0\n' > "$DD_GH/claude"; chmod +x "$DD_GH/claude"   # never start a real run
}

dd_cleanup() { cleanup_running; rm -rf "$DD_PIPE" "$DD_HOME"; }

dd_tick() {
  HOME="$DD_HOME" PATH="$DD_GH:/usr/bin:/bin" PIPE="$DD_PIPE" QUEUE="$DD_PIPE/queue" LOGDIR="$DD_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$SUP_DD" >/dev/null 2>&1
}

dd_log() { cat "$DD_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }
dd_present() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
dd_iso_ago() {
  python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"
}

# dd_thread <body>... — issue 42, exited, .start 1300 s old (past GRACE_PERIOD_SECS), comments oldest -> newest
dd_thread() {
  local arr='[]' b i=0
  dd_env
  mk_restarting "$DD_PIPE" 42 "$DD_REPO"
  dd_iso_ago 1300 > "$DD_PIPE/orch-42.start"
  for b in "$@"; do
    i=$((i + 1))
    arr=$(printf '%s' "$arr" | jq --arg b "$b" --arg t "2026-09-21T0$i:00:00Z" '. + [{body: $b, createdAt: $t}]')
  done
  printf '%s' "$arr" > "$DD_GH/gh-issue-comments-json"
}

# dd_assert_not_gate <label> — after a tick: no .held/.alert/[held], restart path taken
dd_assert_not_gate() {
  local held alert log
  held=$(dd_present "$DD_PIPE/orch-42.held"); alert=$(dd_present "$DD_PIPE/orch-42.alert"); log=$(dd_log)
  dd_cleanup
  assert_eq "$held" "absent" "$1: .held" || return 1
  assert_eq "$alert" "absent" "$1: .alert" || return 1
  assert_not_contains "$log" "[held] #42" "$1: no [held] line" || return 1
  assert_contains "$log" "[queue-restart] #42" "$1: normal restart path" || return 1
}

# dd_assert_gate <label> <expected-name-in-alert> [<name-that-must-not-be-in-alert>]
dd_assert_gate() {
  local held alert log queued
  held=$(dd_present "$DD_PIPE/orch-42.held"); alert=$(cat "$DD_PIPE/orch-42.alert" 2>/dev/null); log=$(dd_log)
  queued=$(dd_present "$DD_PIPE/queue/orch-42.json")
  dd_cleanup
  assert_eq "$held" "present" "$1: .held" || return 1
  assert_contains "$alert" "waiting on JP" "$1: alert says waiting on JP" || return 1
  assert_contains "$alert" "$2" "$1: alert names the gate marker" || return 1
  [ -z "${3:-}" ] || assert_not_contains "$alert" "$3" "$1: alert must not name the decision" || return 1
  assert_contains "$log" "[held] #42" "$1: [held] logged" || return 1
  assert_not_contains "$log" "[queue-restart] #42" "$1: no restart" || return 1
  assert_eq "$queued" "absent" "$1: nothing queued" || return 1
}

test_dd_ac3_blocked_then_decision_is_not_a_gate() {
  dd_thread '**[deployer] BLOCKED**' $'**[project-manager] DECISION**\nResolves: https://example.test/c/1\nDo X.'
  dd_tick
  dd_assert_not_gate "AC3 DECISION" || return 1
}

test_dd_ac3_blocked_then_jp_confirmed_is_not_a_gate() {
  dd_thread '**[deployer] BLOCKED**' $'**[project-manager] JP CONFIRMED**\nResolves: https://example.test/c/1\nDo X.'
  dd_tick
  dd_assert_not_gate "AC3 JP CONFIRMED" || return 1
}

test_dd_ac4_awaiting_go_then_decision_stays_a_gate() {
  dd_thread '**[infra-operator] AWAITING GO**' $'**[project-manager] DECISION**\nResolves: https://example.test/c/1'
  dd_tick
  dd_assert_gate "AC4 AWAITING GO" "AWAITING GO" "DECISION" || return 1
}

test_dd_ac4_mockups_pending_then_jp_confirmed_stays_a_gate() {
  dd_thread '**[ui-ux-designer] MOCKUPS PENDING APPROVAL**' $'**[project-manager] JP CONFIRMED**\nResolves: https://example.test/c/1'
  dd_tick
  dd_assert_gate "AC4 MOCKUPS" "MOCKUPS PENDING APPROVAL" "JP CONFIRMED" || return 1
}

test_dd_ac5_infra_operator_blocked_then_decision_stays_a_gate() {
  dd_thread '**[infra-operator] BLOCKED**' $'**[project-manager] DECISION**\nResolves: https://example.test/c/1'
  dd_tick
  dd_assert_gate "AC5 infra-operator" "BLOCKED" "DECISION" || return 1
}

test_dd_ac5_infra_planner_blocked_then_decision_stays_a_gate() {
  dd_thread '**[infra-planner] BLOCKED**' $'**[project-manager] DECISION**\nResolves: https://example.test/c/1'
  dd_tick
  dd_assert_gate "AC5 infra-planner" "BLOCKED" "DECISION" || return 1
}

test_dd_ac5_infra_reviewer_blocked_then_decision_stays_a_gate() {
  dd_thread '**[infra-reviewer] BLOCKED**' $'**[project-manager] DECISION**\nResolves: https://example.test/c/1'
  dd_tick
  dd_assert_gate "AC5 infra-reviewer" "BLOCKED" "DECISION" || return 1
}

test_dd_ac6_decision_older_than_the_block_stays_a_gate() {
  dd_thread $'**[project-manager] DECISION**\nResolves: https://example.test/c/1' '**[deployer] BLOCKED**'
  dd_tick
  dd_assert_gate "AC6 older decision" "BLOCKED" || return 1
}

test_dd_ac6_decision_on_jps_behalf_form_is_inert() {
  dd_thread '**[deployer] BLOCKED**' "**Decision on JP's behalf (2026-09-21)**"
  dd_tick
  dd_assert_gate "AC6 off-vocabulary decision" "BLOCKED" || return 1
}

test_dd_ac6_jp_confirmed_prose_form_is_inert() {
  dd_thread '**[deployer] BLOCKED**' '**JP: confirmed**'
  dd_tick
  dd_assert_gate "AC6 off-vocabulary JP: confirmed" "BLOCKED" || return 1
}

test_dd_ac7_blocked_alone_is_a_gate() {   # characterisation
  dd_thread '**[deployer] BLOCKED**'
  dd_tick
  dd_assert_gate "AC7 BLOCKED alone" "BLOCKED" || return 1
}

test_dd_ac7_awaiting_go_then_jp_go_is_not_a_gate() {   # characterisation
  dd_thread '**[infra-operator] AWAITING GO**' '**[jp] GO**'
  dd_tick
  dd_assert_not_gate "AC7 AWAITING GO + jp GO" || return 1
}

test_dd_ac7_deployed_then_decision_is_done() {   # characterisation
  dd_thread '**[deployer] DEPLOYED**' $'**[project-manager] DECISION**\nResolves: https://example.test/c/1'
  dd_tick
  local done_f held
  done_f=$(dd_present "$DD_PIPE/orch-42.done"); held=$(dd_present "$DD_PIPE/orch-42.held")
  dd_cleanup
  assert_eq "$done_f" "present" "AC7: DEPLOYED then DECISION -> .done" || return 1
  assert_eq "$held" "absent" "AC7: not held" || return 1
}

test_dd_ac8_fail_then_decision_takes_the_restart_path() {   # characterisation
  dd_thread '**[code-reviewer] FAIL: 3 findings**' $'**[project-manager] DECISION**\nResolves: https://example.test/c/1'
  dd_tick
  dd_assert_not_gate "AC8 FAIL + DECISION" || return 1
}

test_dd_ac9_one_comments_call_per_issue_per_tick() {
  dd_thread '**[deployer] BLOCKED**' $'**[project-manager] DECISION**\nResolves: https://example.test/c/1'
  dd_tick
  local n
  n=$(grep -F 'issue view 42' "$DD_GH/gh-calls.log" | grep -cF -- '--json comments')
  dd_cleanup
  assert_eq "$n" "1" "AC9: exactly one 'issue view 42 ... --json comments' call in the tick" || return 1
}

# ---------------------------------------------------------------------------------------- AC10-AC15 orchestrator

# dd_blocked_row_next — the line directly after the `| any `BLOCKED` |` routing row
dd_blocked_row_next() {
  awk 'found { print; exit } index($0, "| any `BLOCKED` |") == 1 { found = 1 }' "$ORCH_DD"
}

test_dd_ac10_resume_row_directly_after_any_blocked() {
  local row s
  row=$(dd_blocked_row_next)
  assert_ne "$row" "" "AC10: a row directly follows the any BLOCKED row" || return 1
  case "$row" in '|'*) ;; *) fail "AC10: the next line is a table row, got: $row"; return 1 ;; esac
  for s in '[project-manager] DECISION' 'JP CONFIRMED' 'Resolves:' 'relaying a recorded decision, not making one' \
           'the operative test is the marker form, not authorship' 'AWAITING GO' 'MOCKUPS PENDING APPROVAL'; do
    dd_text_has "AC10: resume row" "$row" "$s" || return 1
  done
  dd_text_has_i "AC10: resume row says never" "$row" '\bnever\b' || return 1
}

test_dd_ac11_resume_row_names_every_jp_only_class() {
  local row s
  row=$(dd_blocked_row_next)
  assert_ne "$row" "" "AC11: resume row exists" || return 1
  for s in production 'money' 'third-party' 'delet' 'external communications' 'artefact'; do
    dd_text_has_i "AC11: JP-only class" "$row" "$s" || return 1
  done
}

test_dd_ac12_test_defect_row_has_the_companion() {
  local row
  row=$(grep -F '| `[fullstack-developer] TEST DEFECT` |' "$ORCH_DD" | head -1)
  assert_ne "$row" "" "AC12: TEST DEFECT row exists" || return 1
  dd_text_has "AC12: TEST DEFECT row" "$row" '[project-manager] DECISION' || return 1
  dd_text_has "AC12: TEST DEFECT row" "$row" 'Resolves:' || return 1
}

test_dd_ac12_loop_cap_section_has_the_companion() {
  local sec
  sec=$(dd_section "$ORCH_DD" '## Loop cap')
  assert_ne "$sec" "" "AC12: Loop cap section exists" || return 1
  dd_text_has "AC12: Loop cap" "$sec" '[project-manager] DECISION' || return 1
  dd_text_has "AC12: Loop cap" "$sec" 'Resolves:' || return 1
  dd_text_has "AC12: Loop cap" "$sec" 'one extra' || return 1
  dd_text_has "AC12: Loop cap keeps the cap" "$sec" 'Maximum **2** fix cycles per phase' || return 1
}

test_dd_ac13_issue_author_clauses_and_awaiting_go_row_untouched() {   # characterisation
  local base cur old
  dd_has "$ORCH_DD" 'from the issue author' || return 1
  dd_has "$ORCH_DD" 'issue author, posted after the `AWAITING GO`' || return 1
  base=$(dd_base)
  if [ -z "$base" ]; then printf '    (AC13 byte-identity skipped: no origin/main merge-base)\n' >&2; return 0; fi
  cur=$(grep -F '| `[infra-operator] AWAITING GO` + JP go comment' "$ORCH_DD")
  old=$(cd "$ROOT_DD" && git show "$base:agents/orchestrator.md" | grep -F '| `[infra-operator] AWAITING GO` + JP go comment')
  assert_ne "$cur" "" "AC13: AWAITING GO + go row present" || return 1
  assert_eq "$cur" "$old" "AC13: AWAITING GO + go row byte-identical to origin/main" || return 1
}

test_dd_ac14_validation_row_and_run_log() {
  local tbl row log lines
  tbl=$(dd_section "$ORCH_DD" '## Pre-dispatch validation' | grep '^|')
  row=$(printf '%s\n' "$tbl" | grep -F 'delegated decision' | head -1)
  assert_ne "$row" "" "AC14: a validation-table row contains 'delegated decision'" || return 1
  dd_text_has "AC14: validation row" "$row" 'Resolves:' || return 1
  dd_text_has "AC14: validation row" "$row" '[project-manager] DECISION' || return 1

  log=$(dd_section "$ORCH_DD" '## Run log')
  dd_text_has "AC14: Run log" "$log" '"stage":"delegated-decision"' || return 1
  lines=$(printf '%s\n' "$log" | grep -F '"stage":"delegated-decision"')
  dd_text_has "AC14: validate example (pass)" "$lines" '"result":"pass"' || return 1
  dd_text_has "AC14: validate example (fail)" "$lines" '"result":"fail"' || return 1
  dd_text_has "AC14: dispatch example carries the decision as marker_before" "$log" '"marker_before":"[project-manager] DECISION"' || return 1
  dd_text_has "AC14: Run log keeps the three event types" "$log" 'Events: `validate`, `dispatch`, `terminal`' || return 1
  dd_lacks "$ORCH_DD" 'off-table-route' || return 1
  dd_lacks "$ORCH_DD" 'test-defect-cap' || return 1
  dd_lacks "$ORCH_DD" '"event":"note"' || return 1
}

test_dd_ac15_infra_track_sentence_and_hard_limits() {
  local infra line hard
  infra=$(awk '/^### Infra track/ { on = 1; next } on && /^### Opt-in/ { exit } on { print }' "$ORCH_DD")
  assert_ne "$infra" "" "AC15: Infra track section exists" || return 1
  line=$(printf '%s\n' "$infra" | grep -F '[project-manager]' | grep -F 'resume nothing on the infra track' | head -1)
  assert_ne "$line" "" "AC15: a sentence has [project-manager] and 'resume nothing on the infra track'" || return 1
  hard=$(grep -F 'The only exits are:' "$ORCH_DD" | head -1)
  assert_ne "$hard" "" "AC15: Hard limits 'only exits' line exists" || return 1
  dd_text_has "AC15: Hard limits line" "$hard" '[project-manager]' || return 1
}

# ---------------------------------------------------------------------------------------- AC16-AC18 agents

test_dd_ac16_nine_code_track_agents_have_blocked_on() {
  local a
  for a in product-manager ux-flow-designer ui-ux-designer solutions-architect test-writer test-reviewer fullstack-developer code-reviewer deployer; do
    dd_has "$ROOT_DD/agents/$a.md" 'Blocked on:' || return 1
  done
  for a in infra-planner infra-reviewer infra-operator; do
    dd_lacks "$ROOT_DD/agents/$a.md" 'Blocked on:' || return 1
  done
}

test_dd_ac17_project_manager_agent_contents() {
  local s
  (cd "$ROOT_DD" && git ls-files --error-unmatch agents/project-manager.md >/dev/null 2>&1) \
    || { fail "AC17: agents/project-manager.md must exist and be tracked"; return 1; }
  dd_has "$PMGR_DD" 'name: project-manager' || return 1
  for s in '**[project-manager] DECISION**' '**[project-manager] JP CONFIRMED**' 'Resolves:' '**[project-manager] NOTE**' \
           'AWAITING GO' 'orchestrate.sh' 'VM cannot read'; do
    dd_has "$PMGR_DD" "$s" || return 1
  done
  for s in "**Decision on JP's behalf" '**JP: ' 'Never start a comment with' 'give them a file they can read'; do
    dd_lacks "$PMGR_DD" "$s" || return 1
  done
}

test_dd_ac18_project_manager_sections_and_untouched_parts_byte_identical() {
  local n head tail
  [ -f "$PMGR_DD" ] || { fail "AC18: agents/project-manager.md missing"; return 1; }
  for n in 1 2 3 4 5 6 7 8; do
    grep -q "^## $n\\. " "$PMGR_DD" || { fail "AC18: heading '## $n.' missing"; return 1; }
  done
  # hashes pinned from the source comment (issue #59 comment 5758640117), no network
  head=$(awk '/^## 2\. How to decide/{exit} {print}' "$PMGR_DD" | dd_sha)
  tail=$(awk '/^## 3\. Start-up/{f=1} f' "$PMGR_DD" | dd_sha)
  assert_eq "$head" "25d77b367bb6ecb6b9762340ffdb1a654b8c09a5e9aaff36f9ba972d4466d50e" "AC18: frontmatter + section 1" || return 1
  assert_eq "$tail" "e34f6e335d9fb8481cf702dd06e19ddb940147907b64504f69360669728e82a2" "AC18: sections 3-8" || return 1
}

# ---------------------------------------------------------------------------------------- AC19-AC20 docs

test_dd_ac19_readme_paragraph() {
  local p s
  p=$(grep -F '**Project manager (delivery lead).**' "$README_DD" | grep '^\*\*Project manager (delivery lead)\.\*\*' | head -1)
  assert_ne "$p" "" "AC19: README has a paragraph starting **Project manager (delivery lead).**" || return 1
  for s in 'main agent of its own session' '[project-manager] DECISION' 'JP CONFIRMED' 'Resolves:' 'AWAITING GO'; do
    dd_text_has "AC19: README paragraph" "$p" "$s" || return 1
  done
}

test_dd_ac19_claude_md_paragraph() {
  local p s
  p=$(grep '^\*\*Project manager (delivery lead)\.\*\*' "$CLAUDE_DD" | head -1)
  assert_ne "$p" "" "AC19: CLAUDE.md has a paragraph starting **Project manager (delivery lead).**" || return 1
  for s in 'main agent of its own session' '[project-manager] DECISION'; do
    dd_text_has "AC19: CLAUDE.md paragraph" "$p" "$s" || return 1
  done
}

test_dd_ac20_agents_readme_roster_row() {
  dd_has "$AGREADME_DD" '| project-manager | fable | high |' || return 1
}

# ---------------------------------------------------------------------------------------- AC21-AC22 gates

# Guards (pass now, must keep passing). Skipped where there is no origin/main merge-base.
test_dd_ac21_untouched_paths_have_no_diff() {
  local base d
  base=$(dd_base)
  if [ -z "$base" ]; then printf '    (AC21 skipped: no origin/main merge-base)\n' >&2; return 0; fi
  d=$(cd "$ROOT_DD" && git diff --name-only "$base" -- status-page settings.json hooks/require-handoff-marker.sh \
        skills/orchestrate/tests/lib skills/orchestrate/tests/fixtures/golden)
  assert_eq "$d" "" "AC21: status-page, settings.json, require-handoff-marker.sh, tests/lib, golden unchanged" || return 1
}

test_dd_ac21_no_pre_existing_test_modified() {
  local base d
  base=$(dd_base)
  if [ -z "$base" ]; then printf '    (AC21 skipped: no origin/main merge-base)\n' >&2; return 0; fi
  d=$(cd "$ROOT_DD" && git diff --name-status "$base" -- skills/orchestrate/tests | grep -v 'test-delegated-decision.sh')
  assert_eq "$d" "" "AC21: only test-delegated-decision.sh changes under skills/orchestrate/tests" || return 1
}

test_dd_ac22_no_timer_counter_or_new_state_file() {
  local base d added bad
  base=$(dd_base)
  if [ -z "$base" ]; then printf '    (AC22 skipped: no origin/main merge-base)\n' >&2; return 0; fi
  d=$(cd "$ROOT_DD" && git diff --name-only "$base" -- skills/orchestrate/config.sh)
  assert_eq "$d" "" "AC22: config.sh unchanged" || return 1
  added=$(cd "$ROOT_DD" && git diff -U0 "$base" -- skills/orchestrate/supervisor.sh | grep '^+' | grep -v '^+++')
  bad=$(printf '%s\n' "$added" | grep -oE 'orch-\$\{?issue\}?\.[A-Za-z_-]+' | grep -vE '\.(held|alert|done|start)$')
  assert_eq "$bad" "" "AC22: supervisor.sh adds no new orch-\$issue.<suffix> file" || return 1
}

run_test test_dd_ac1_markers_for_project_manager_and_jp
run_test test_dd_ac2_marker_re_matches_the_two_new_markers
run_test test_dd_ac2_marker_re_rejects_wrong_authority_and_off_vocabulary
run_test test_dd_ac3_blocked_then_decision_is_not_a_gate
run_test test_dd_ac3_blocked_then_jp_confirmed_is_not_a_gate
run_test test_dd_ac4_awaiting_go_then_decision_stays_a_gate
run_test test_dd_ac4_mockups_pending_then_jp_confirmed_stays_a_gate
run_test test_dd_ac5_infra_operator_blocked_then_decision_stays_a_gate
run_test test_dd_ac5_infra_planner_blocked_then_decision_stays_a_gate
run_test test_dd_ac5_infra_reviewer_blocked_then_decision_stays_a_gate
run_test test_dd_ac6_decision_older_than_the_block_stays_a_gate
run_test test_dd_ac6_decision_on_jps_behalf_form_is_inert
run_test test_dd_ac6_jp_confirmed_prose_form_is_inert
run_test test_dd_ac7_blocked_alone_is_a_gate
run_test test_dd_ac7_awaiting_go_then_jp_go_is_not_a_gate
run_test test_dd_ac7_deployed_then_decision_is_done
run_test test_dd_ac8_fail_then_decision_takes_the_restart_path
run_test test_dd_ac9_one_comments_call_per_issue_per_tick
run_test test_dd_ac10_resume_row_directly_after_any_blocked
run_test test_dd_ac11_resume_row_names_every_jp_only_class
run_test test_dd_ac12_test_defect_row_has_the_companion
run_test test_dd_ac12_loop_cap_section_has_the_companion
run_test test_dd_ac13_issue_author_clauses_and_awaiting_go_row_untouched
run_test test_dd_ac14_validation_row_and_run_log
run_test test_dd_ac15_infra_track_sentence_and_hard_limits
run_test test_dd_ac16_nine_code_track_agents_have_blocked_on
run_test test_dd_ac17_project_manager_agent_contents
run_test test_dd_ac18_project_manager_sections_and_untouched_parts_byte_identical
run_test test_dd_ac19_readme_paragraph
run_test test_dd_ac19_claude_md_paragraph
run_test test_dd_ac20_agents_readme_roster_row
run_test test_dd_ac21_untouched_paths_have_no_diff
run_test test_dd_ac21_no_pre_existing_test_modified
run_test test_dd_ac22_no_timer_counter_or_new_state_file
