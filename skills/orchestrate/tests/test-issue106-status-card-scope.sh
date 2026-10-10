# Issue #106 — the status card (CLAUDE.md:17) must reach headless reports: CLAUDE.md trigger widened,
# orchestrator "Report to JP" ends with the card, "Comment brevity" is issue-comments only,
# project-manager covers every status it writes. Prose contract pinned by literal / regex greps on
# tracked files only (no gh, no network). No-new-mechanism is pinned by test_fu_ac6 in
# test-followup-rules-docs.sh (hooks + skills/orchestrate top-level file lists).
HERE_106=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_106=$(cd "$HERE_106/../../.." && pwd)
CLAUDE_106="$ROOT_106/CLAUDE.md"
ORCH_106="$ROOT_106/agents/orchestrator.md"
PMGR_106="$ROOT_106/agents/project-manager.md"

# i106_section <file> <exact heading line> — body up to the next "## " heading
i106_section() { awk -v h="$2" '$0==h{on=1;next} /^## /{on=0} on' "$1"; }
i106_card_line() { grep -F '**Status answers.**' "$CLAUDE_106" | head -1; }
i106_has_i() { printf '%s\n' "$2" | grep -qiE -- "$3" || { fail "$1: missing (regex, any case) [$3]"; return 1; }; }

test_i106_claude_md_trigger_covers_end_of_run_reports() {
  local l; l=$(i106_card_line)
  assert_ne "$l" "" "AC1: Status answers paragraph exists" || return 1
  i106_has_i "AC1: trigger covers end-of-run reports" "$l" 'end[- ]of[- ]run' || return 1
  i106_has_i "AC1: still scoped to pipeline work" "$l" 'pipeline work' || return 1
  i106_has_i "AC1: trigger is any status report, not only when asked" "$l" 'any (status|progress)|every (status|progress)|status report' || return 1
}

test_i106_claude_md_rest_of_card_text_unchanged() {
  local l; l=$(i106_card_line)
  assert_contains "$l" 'answer with this card' "AC1 unchanged: card instruction" || return 1
  assert_contains "$l" 'plain language, no jargon (no marker names, PIDs or stage names)' "AC1 unchanged: no jargon" || return 1
  assert_contains "$l" 'Build it from `orchestrate.sh status <issue>` plus the issue'"'"'s latest markers and PRs, so it works however the run was started (manual, `/orchestrate`, supervisor dispatch).' "AC1 unchanged: build-from sentence" || return 1
  assert_contains "$l" 'Never hand-roll a different layout.' "AC1 unchanged: closing sentence" || return 1
  local f
  for f in 'STATUS:    <RUNNING | WAITING ON YOU | BLOCKED | HELD | STALLED, retrying | DEPLOYED | DONE>' \
           'NEEDED FROM YOU:' 'TECHNICAL PROBLEM:' 'SELF-HEAL TICKETS:'; do
    grep -qF -- "$f" "$CLAUDE_106" || { fail "AC1 unchanged: card template line missing [$f]"; return 1; }
  done
}

test_i106_claude_md_twenty_line_limit_is_per_card_one_card_per_run_never_merged() {
  local l; l=$(i106_card_line)
  i106_has_i "AC7: limit is per card" "$l" '(per card|each card|every card)' || return 1
  i106_has_i "AC7: several runs -> one card per run" "$l" 'several (runs|tickets)|multiple (runs|tickets)|more than one (run|ticket)' || return 1
  i106_has_i "AC7: tickets never merged under one header" "$l" 'never[^.]*(merge|combin|group)[^.]*(header|card)|(merge|combin|group)[^.]*under one header' || return 1
}

test_i106_claude_md_trigger_covers_reports_after_acting_on_instruction() {
  local l; l=$(i106_card_line)
  i106_has_i "AC8: progress reports after acting on JP's instruction" "$l" 'after acting' || return 1
  i106_has_i "AC8: names status/progress reports" "$l" 'progress' || return 1
}

test_i106_orchestrator_report_to_jp_line_points_at_status_card() {
  local sec first
  sec=$(i106_section "$ORCH_106" '## Report to JP (end of every invocation)')
  assert_ne "$sec" "" "AC2: '## Report to JP (end of every invocation)' heading kept" || return 1
  first=$(printf '%s\n' "$sec" | grep -v '^[[:space:]]*$' | head -1)
  i106_has_i "AC2: final message is the status card" "$first" 'status card' || return 1
  i106_has_i "AC2: points to JP's CLAUDE.md" "$first" 'CLAUDE\.md' || return 1
  i106_has_i "AC2: card is for this run" "$first" '(this|the) run|per run|one card' || return 1
  assert_not_contains "$first" 'marker trail' "AC2: 'marker trail' wording removed" || return 1
  assert_not_contains "$first" 'who ran, what each produced' "AC2: 'who ran, what each produced' removed" || return 1
  assert_contains "$first" '`terminal`' "AC2 kept: terminal run-log line" || return 1
  assert_contains "$first" 'No silent exits.' "AC2 kept: No silent exits" || return 1
}

test_i106_orchestrator_report_to_jp_has_no_card_template_copy_and_keeps_followup_paragraph() {
  local sec; sec=$(i106_section "$ORCH_106" '## Report to JP (end of every invocation)')
  assert_not_contains "$sec" 'SELF-HEAL TICKETS' "AC2: no copy of the template" || return 1
  assert_not_contains "$sec" 'NEEDED FROM YOU' "AC2: no copy of the template" || return 1
  assert_contains "$sec" '**Filing a follow-up ticket is never a next action for JP.**' "AC9: follow-up paragraph kept" || return 1
  assert_not_contains "$sec" 'marker trail' "AC2: 'marker trail' not in the Report to JP section" || return 1
}

test_i106_orchestrator_comment_brevity_is_issue_comments_only() {
  local sec; sec=$(i106_section "$ORCH_106" '## Comment brevity')
  assert_ne "$sec" "" "AC3: Comment brevity section kept" || return 1
  assert_not_contains "$sec" 'When reporting to JP' "AC3: no longer sets a format for reports to JP" || return 1
  assert_not_contains "$sec" 'Three to five lines' "AC3: competing 3-5 line format gone" || return 1
  i106_has_i "AC3: scoped to issue comments" "$sec" 'issue comments?' || return 1
}

test_i106_project_manager_every_status_is_one_card_per_run() {
  local l
  l=$(grep -E '^(Status requests mid-run|Every status the project-manager writes)' "$PMGR_106" | head -1)
  assert_ne "$l" "" "AC4: PM status-card line exists" || return 1
  assert_not_contains "$l" 'Status requests mid-run' "AC4: no longer limited to mid-run requests" || return 1
  i106_has_i "AC4: every status the PM writes" "$l" 'every status' || return 1
  i106_has_i "AC4: covers end-of-turn messages" "$l" 'end-of-turn' || return 1
  i106_has_i "AC4: covers log status messages" "$l" 'log status' || return 1
  i106_has_i "AC4: one card per run" "$l" 'card per run|one card' || return 1
  i106_has_i "AC4: points to JP's CLAUDE.md" "$l" 'CLAUDE\.md' || return 1
}

test_i106_project_manager_seven_section_report_not_restructured() {
  local body
  body=$(awk '/^## 8\. Reporting/{on=1} on' "$PMGR_106")
  assert_contains "$body" '7. **Pipeline health** — incidents, verdicts, config you changed (with where the old values are saved).' "AC4: 7-section end-of-plan report kept" || return 1
}

# Self-contained no-new-mechanism guard (test_fu_ac6/test_sl_ac7 are red on main for unrelated reasons).
# The change may touch only the 3 doc files + tests under skills/orchestrate/tests/.
test_i106_no_new_mechanism_only_doc_files_and_tests_touched() {
  local base changed f bad=""
  base=$(git -C "$ROOT_106" merge-base HEAD origin/main 2>/dev/null) || { fail "AC5: cannot resolve origin/main merge-base"; return 1; }
  changed=$(git -C "$ROOT_106" diff --name-only "$base" HEAD)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      CLAUDE.md|agents/orchestrator.md|agents/project-manager.md|agents/deployer.md|status-page/test/deployer-ci-wait.test.js|skills/orchestrate/tests/*) ;;
      # #114: exactly its Files-table paths
      agents/intake.md|agents/README.md|README.md|hooks/pipeline-markers.sh|hooks/require-handoff-marker.sh) ;;
      skills/orchestrate/intake-labels.sh|skills/orchestrate/scan-backlog.sh|skills/orchestrate/config.sh|skills/orchestrate/pipeline-lib.sh|skills/orchestrate/supervisor.sh) ;;
      # #115: exactly its Files-table paths not already listed (agents/fullstack-developer.md, agents/product-manager.md, skills/orchestrate/test/*)
      agents/fullstack-developer.md|agents/product-manager.md|skills/orchestrate/test/*) ;;
      *) bad="$bad $f" ;;
    esac
  done <<< "$changed"
  assert_eq "$bad" "" "AC5/AC6: no hook, skill, script or state file added/changed (unexpected:$bad)" || return 1
}

# Nothing parses the orchestrator's final report text: no runtime script references the report heading/card.
test_i106_no_runtime_script_parses_final_report() {
  local hits
  hits=$(grep -lE 'Report to JP|STATUS: +<|NEEDED FROM YOU|SELF-HEAL TICKETS|marker trail' \
    "$ROOT_106"/skills/orchestrate/*.sh "$ROOT_106"/hooks/* 2>/dev/null)
  assert_eq "$hits" "" "AC6: no runtime script/hook parses the final report" || return 1
}

run_test test_i106_claude_md_trigger_covers_end_of_run_reports
run_test test_i106_claude_md_rest_of_card_text_unchanged
run_test test_i106_claude_md_twenty_line_limit_is_per_card_one_card_per_run_never_merged
run_test test_i106_claude_md_trigger_covers_reports_after_acting_on_instruction
run_test test_i106_orchestrator_report_to_jp_line_points_at_status_card
run_test test_i106_orchestrator_report_to_jp_has_no_card_template_copy_and_keeps_followup_paragraph
run_test test_i106_orchestrator_comment_brevity_is_issue_comments_only
run_test test_i106_project_manager_every_status_is_one_card_per_run
run_test test_i106_project_manager_seven_section_report_not_restructured
run_test test_i106_no_new_mechanism_only_doc_files_and_tests_touched
run_test test_i106_no_runtime_script_parses_final_report
