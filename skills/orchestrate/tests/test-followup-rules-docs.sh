# Issue #31 (ACs 1-4, 6) — ticket-authorship rule, blocking-vs-non-blocking questions, dependency
# follow-up approval inheritance, worked example. The definitions are prose, so the contract is
# pinned by literal strings (fixed-string grep, per test-incident-review-agents.sh). Every case
# reads tracked files only: no gh, no network, no /tmp/pipeline.
# AC5 (scan on the VM) and AC7 (two-week outcome) are post-merge checks, deliberately not tested.

HERE_FU=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_FU=$(cd "$HERE_FU/../../.." && pwd)
PM_FU="$ROOT_FU/agents/product-manager.md"
ORCH_FU="$ROOT_FU/agents/orchestrator.md"
SA_FU="$ROOT_FU/agents/solutions-architect.md"
CLAUDE_FU="$ROOT_FU/CLAUDE.md"

fu_has()   { grep -qF  -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }
fu_has_i() { grep -qiE -- "$2" "$1" || { fail "$(basename "$1"): missing (any case, regex) [$2]"; return 1; }; }

# fu_text_has_i <label> <text> <regex>
fu_text_has_i() { printf '%s\n' "$2" | grep -qiE -- "$3" || { fail "$1: missing (any case, regex) [$3]"; return 1; }; }

test_fu_ac1_claude_md_forbids_general_purpose_ticket_writing() {
  local sec line
  sec=$(awk '/^## Software development/ { on = 1; next } /^## Google integrations/ { on = 0 } on { print }' "$CLAUDE_FU")
  assert_ne "$sec" "" "CLAUDE.md Software development section exists" || return 1
  line=$(printf '%s\n' "$sec" | grep -F 'general-purpose' | head -1)
  assert_ne "$line" "" "AC1: the Software development section must name the ad-hoc \`general-purpose\` subagent" || return 1
  fu_text_has_i "AC1: the general-purpose sentence is a prohibition" "$line" 'never|must not|do not|not ' || return 1
  fu_text_has_i "AC1: it says a ticket is not hand-written that way" "$sec" 'hand-writ' || return 1
  fu_text_has_i "AC1: routes tickets to product-manager" "$sec" 'product-manager' || return 1
  fu_text_has_i "AC1: alternative route — brief + launch the orchestrator so the PM stage refines it" "$sec" 'brief' || return 1
  fu_text_has_i "AC1: no blocking Open questions for JP reach JP" "$sec" 'Open questions for JP' || return 1
  fu_text_has_i "AC1: non-blocking with a stated default" "$sec" 'non-blocking' || return 1
}

test_fu_ac1_pm_states_blocking_vs_non_blocking_question_rule() {
  fu_has "$PM_FU" 'Open questions for JP' || return 1
  fu_has_i "$PM_FU" 'non-blocking' || return 1
  fu_has_i "$PM_FU" 'stated default' || return 1
  fu_has "$PM_FU" 'JP-only' || return 1
  # the four JP-only categories, verbatim from the ticket
  fu_has_i "$PM_FU" 'spending money' || return 1
  fu_has_i "$PM_FU" 'prod.{0,4}go' || return 1
  fu_has_i "$PM_FU" 'artefact|artifact' || return 1
  fu_has_i "$PM_FU" 'who gets access' || return 1
  fu_has_i "$PM_FU" 'external communications' || return 1
}

test_fu_ac2_pm_defines_dependency_followup_parent_line_and_inherited_approval_note() {
  fu_has_i "$PM_FU" 'dependency follow-up' || return 1
  fu_has "$PM_FU" 'Parent: ' || return 1
  fu_has "$PM_FU" 'Parent: owner/repo#N' || return 1
  fu_has "$PM_FU" '**[product-manager] NOTE** approval inherited from' || return 1
  fu_has "$PM_FU" 'approval inherited from' || return 1
  fu_has "$PM_FU" 'agent-go' || return 1
  fu_has "$PM_FU" '--add-label agent-go' || return 1
  fu_has "$PM_FU" 'gh issue create' || return 1
  # inheritance requires the parent to have been approved by JP (ran through the pipeline)
  fu_has "$PM_FU" 'agent-in-progress' || return 1
  # R1: PM files the child at spec time — a promise of later work needs the child to exist
  fu_has_i "$PM_FU" 'promis' || return 1
  # R1: the parent's body lists the child
  fu_has "$PM_FU" 'Follow-up: ' || return 1
  fu_has "$PM_FU" 'Follow-up: owner/repo#M' || return 1
  # R1: default gate line for the child
  fu_has "$PM_FU" 'Depends on #N for merging' || return 1
}

test_fu_ac2_pm_defers_agent_go_when_a_start_gate_is_open() {
  fu_has "$PM_FU" 'agent-go deferred' || return 1
  fu_has "$PM_FU" 'agent-go deferred: start-gate #N open' || return 1
  fu_has "$PM_FU" '**[product-manager] NOTE** approval inherited from owner/repo#N — agent-go deferred: start-gate #N open' || return 1
}

test_fu_ac2_pm_exclusions_and_business_intelligence_exception() {
  local bi_lines
  # does NOT inherit: new scope, nice-to-haves, reviewer MEDIUM/LOW findings
  fu_has_i "$PM_FU" 'new scope' || return 1
  fu_has_i "$PM_FU" 'nice-to-have' || return 1
  fu_has_i "$PM_FU" 'MEDIUM' || return 1
  fu_has_i "$PM_FU" 'agent-proposed' || return 1
  # unchanged human gates inside the child run: inheritance starts the run, never skip a gate
  fu_has_i "$PM_FU" 'never skip' || return 1
  # BI: no automatic pipeline work, ever — the sentence naming it must be a prohibition
  fu_has "$PM_FU" 'Business-Intelligence' || return 1
  bi_lines=$(grep -F 'Business-Intelligence' "$PM_FU")
  fu_text_has_i "AC2: Business-Intelligence line is an exclusion" "$bi_lines" 'never|not|no ' || return 1
}

test_fu_ac2_orchestrator_never_hands_filing_a_followup_to_jp() {
  local report rows
  report=$(awk '/^## Report to JP/ { on = 1; next } on && /^## / { exit } on { print }' "$ORCH_FU")
  assert_ne "$report" "" "orchestrator.md has a Report to JP section" || return 1
  fu_text_has_i "AC2: Report to JP section covers follow-up tickets" "$report" 'follow-up' || return 1
  fu_text_has_i "AC2: filing a follow-up is never a next action for JP" "$report" 'never' || return 1
  fu_text_has_i "AC2: the only route is the PM via NEEDS PM REVISION" "$report" 'NEEDS PM REVISION' || return 1
  fu_text_has_i "AC2: orchestrator does not judge — it routes to the product-manager" "$report" 'product-manager' || return 1
  # R1: no new routing-table row. Baseline at main = 28 table rows starting with "| `[".
  rows=$(grep -c '^| `\[' "$ORCH_FU")
  assert_eq "$rows" "28" "R1: orchestrator routing table gains no new row" || return 1
}

test_fu_ac2_solutions_architect_hygiene_findings_are_new_scope_not_dependency_followups() {
  local blk
  # item 3's hygiene paragraph: from "Anything found" up to item 4
  blk=$(awk '/Anything found is \*\*not folded/ { on = 1 } /^4\. \*\*Read related repos/ { on = 0 } on { print }' "$SA_FU")
  assert_ne "$blk" "" "solutions-architect.md still has the 'Anything found is not folded into this design' paragraph" || return 1
  fu_text_has_i "AC2: SA still files it and tags JP for approval (behaviour kept)" "$blk" 'tag JP' || return 1
  fu_text_has_i "AC2: SA still opens it with gh issue create" "$blk" 'gh issue create' || return 1
  fu_text_has_i "AC2: hygiene findings are new scope" "$blk" 'new scope' || return 1
  fu_text_has_i "AC2: ...not dependency follow-ups" "$blk" 'dependency follow-up' || return 1
  fu_text_has_i "AC2: no Parent: line" "$blk" 'Parent:' || return 1
  fu_text_has_i "AC2: no agent-go" "$blk" 'agent-go' || return 1
  fu_text_has_i "AC2: if the parent cannot complete without the work -> NEEDS PM REVISION" "$blk" 'NEEDS PM REVISION' || return 1
}

test_fu_ac3_pipeline_markers_unchanged_and_note_route_is_used() {
  local got want
  . "$ROOT_FU/hooks/pipeline-markers.sh"
  got=$(markers_for product-manager)
  want='READY FOR ARCHITECTURE|READY FOR ENGINEERING|EFFORT APPROVAL NEEDED|BLOCKED'
  assert_eq "$got" "$want" "AC3: markers_for product-manager is byte-identical (no new marker)" || return 1
  # The inherited-approval message travels as a NOTE — inert by the marker vocabulary. Control:
  # the PM definition actually uses that NOTE (so this is not a vacuous 'nothing changed' check).
  fu_has "$PM_FU" '**[product-manager] NOTE** approval inherited from' || return 1
}

test_fu_ac4_pm_worked_example_216_to_229() {
  local win ln
  fu_has "$PM_FU" 'Benjis-Plants/benjis-quoting-tool#216' || return 1
  fu_has "$PM_FU" 'Parent: Benjis-Plants/benjis-quoting-tool#216' || return 1
  fu_has "$PM_FU" 'Depends on #216 for merging' || return 1
  fu_has "$PM_FU" 'Follow-up: Benjis-Plants/benjis-quoting-tool#229' || return 1
  ln=$(grep -nF 'Parent: Benjis-Plants/benjis-quoting-tool#216' "$PM_FU" | head -1 | cut -d: -f1)
  win=$(sed -n "$((ln > 25 ? ln - 25 : 1)),$((ln + 25))p" "$PM_FU")
  fu_text_has_i "AC4: example is filed with agent-go" "$win" 'agent-go' || return 1
  fu_text_has_i "AC4: example has no blocking questions" "$win" 'no blocking' || return 1
  fu_text_has_i "AC4: the snapshot-location question..." "$win" 'snapshot' || return 1
  fu_text_has_i "AC4: ...is the single JP-only item" "$win" 'JP-only' || return 1
  fu_text_has_i "AC4: names the table being dropped" "$win" 'pricing_users' || return 1
}

test_fu_ac6_no_new_hook_daemon_timer_or_state_file_and_single_config_key() {
  local hooks top keys
  # hand-written baseline of tracked hook files and top-level orchestrate files at main (2026-09-19),
  # plus reconcile-status.sh, which issue #51 (Expected Behavior 2) adds to the orchestrate dir
  hooks=$(ls "$ROOT_FU/hooks" | tr '\n' ' ')
  assert_eq "$hooks" "block-orchestrator-agent.sh bug-fix-skill-reminder.sh cap-heavy-commands.py email-send-guard.sh enforce-tests-before-commit.sh limit-shells.sh pipeline-markers.sh protect-locked-tests.sh report-status-hook.sh require-handoff-marker.sh sync-agents.sh " "AC6: no new hook" || return 1
  top=$(ls "$ROOT_FU/skills/orchestrate" | tr '\n' ' ')
  assert_eq "$top" "SKILL.md build-runs-json.py config.local.example.sh config.sh install.sh orchestrate.sh pipeline-bridge-dispatch.sh pipeline-bridge-prompt.md pipeline-lib.sh reconcile-status.sh report-status.sh run-state.sh scan-backlog.sh supervisor.sh tests " "AC6: no new daemon/timer/state-file script under skills/orchestrate" || return 1
  # the one allowed config key exists and defaults to today's behaviour (empty)
  assert_eq "$(grep -c '^SCAN_ONLY_REPOS=()' "$ROOT_FU/skills/orchestrate/config.sh")" "1" "AC6: config.sh carries the single new key, defaulting to empty" || return 1
  # ...and it is the only new key: no other *_REPOS / SCAN_* assignment beyond the baseline
  keys=$(grep -oE '^[A-Z_]*(REPOS|SCAN)[A-Z_]*=' "$ROOT_FU/skills/orchestrate/config.sh" | sort | tr '\n' ' ')
  assert_eq "$keys" "DISPATCH_REPOS= SCAN_ONLY_REPOS= " "AC6: exactly one new config key" || return 1
}

run_test test_fu_ac1_claude_md_forbids_general_purpose_ticket_writing
run_test test_fu_ac1_pm_states_blocking_vs_non_blocking_question_rule
run_test test_fu_ac2_pm_defines_dependency_followup_parent_line_and_inherited_approval_note
run_test test_fu_ac2_pm_defers_agent_go_when_a_start_gate_is_open
run_test test_fu_ac2_pm_exclusions_and_business_intelligence_exception
run_test test_fu_ac2_orchestrator_never_hands_filing_a_followup_to_jp
run_test test_fu_ac2_solutions_architect_hygiene_findings_are_new_scope_not_dependency_followups
run_test test_fu_ac3_pipeline_markers_unchanged_and_note_route_is_used
run_test test_fu_ac4_pm_worked_example_216_to_229
run_test test_fu_ac6_no_new_hook_daemon_timer_or_state_file_and_single_config_key
