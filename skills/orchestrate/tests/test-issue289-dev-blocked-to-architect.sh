# Issue #289 — a developer BLOCKED of class needs_jp/other goes to the solutions-architect first.
# Text-pins on agents/orchestrator.md rows (:74/:79), fullstack-developer.md, solutions-architect.md.
# Prefix i289_ (all test files share one shell).

I289_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
I289_ORCH="$I289_ROOT/agents/orchestrator.md"
I289_DEV="$I289_ROOT/agents/fullstack-developer.md"
I289_SA="$I289_ROOT/agents/solutions-architect.md"

# the routing row that dispatches the solutions-architect on spec-questioning findings
i289_row79() { grep -F '`[solutions-architect] SPEC RESOLVED` marker' "$I289_ORCH" | grep -F 'Dispatch **solutions-architect**' | head -1; }
i289_row74() { grep -F '| any `BLOCKED` |' "$I289_ORCH" | head -1; }

test_i289_ac1_row_fires_on_developer_blocked_needs_jp_or_other() {
  local r; r=$(i289_row79)
  assert_ne "$r" "" "AC1: the SA-dispatch row still exists" || return 1
  assert_contains "$r" '[fullstack-developer] BLOCKED' "AC1: row names developer BLOCKED" || return 1
  assert_contains "$r" '`needs_jp`' "AC1: row names needs_jp" || return 1
  assert_contains "$r" '`other`' "AC1: row names other" || return 1
  assert_contains "$r" 'reviewer finding that questions the spec' "AC1: reviewer-finding trigger kept" || return 1
  assert_contains "$r" 'URL' "AC1: SA is given the BLOCKED comment URL" || return 1
  assert_contains "$r" 'do NOT escalate to JP' "AC1: still says do not escalate" || return 1
}

test_i289_ac1_spec_conflict_trigger_removed_everywhere() {
  local hits
  hits=$(cd "$I289_ROOT" && grep -rn 'SPEC CONFLICT' agents hooks skills/orchestrate --include='*' 2>/dev/null \
         | grep -v '/tests/' )
  assert_eq "$hits" "" "AC1: nothing under agents/ hooks/ skills/orchestrate emits or routes on SPEC CONFLICT" || return 1
}

test_i289_ac2_loop_bound_by_marker_order() {
  local r; r=$(i289_row79)
  assert_contains "$r" 'after a `[solutions-architect] SPEC RESOLVED`' "AC2: BLOCKED after SPEC RESOLVED named" || return 1
  assert_contains "$r" 'terminal' "AC2: stays terminal" || return 1
  assert_contains "$r" 'report' "AC2: reported to JP" || return 1
}

test_i289_ac3_any_blocked_row_defers() {
  local r; r=$(i289_row74)
  assert_ne "$r" "" "AC3: any BLOCKED row exists" || return 1
  assert_contains "$r" 'solutions-architect' "AC3: :74 defers to the SA row for needs_jp/other developer BLOCKEDs" || return 1
  assert_contains "$r" '`needs_jp`' "AC3: :74 names needs_jp" || return 1
}

test_i289_ac3_other_classes_rows_unchanged() {
  local t; t=$(cat "$I289_ORCH")
  assert_contains "$t" 'Blocked on: merge_conflict — merge touches locked test <path>` (full lane, lock file present) | Not terminal.' "AC3: :71 locked-test merge row intact" || return 1
  assert_contains "$t" 'auto-retry <n>/<max>: <cls> cleared' "AC3: :73 auto-retry row intact" || return 1
  assert_contains "$t" 'with `<cls>` in `ci_pending`, `ci_red`, `merge_conflict`, `dependency`' "AC3: auto-retry class set unchanged" || return 1
}

test_i289_ac4_architect_answers_developer_blocked() {
  local t; t=$(cat "$I289_SA")
  assert_contains "$t" 'Resolves: <BLOCKED URL>' "AC4: SPEC RESOLVED line 2 Resolves: <BLOCKED URL>" || return 1
  assert_contains "$t" 'developer BLOCKED' "AC4: SA doc covers dispatch on a developer BLOCKED" || return 1
  assert_contains "$t" 'JP-only list' "AC4: SA BLOCKED needs_jp only on the JP-only list" || return 1
  assert_contains "$t" 'where a private artefact is stored' "AC4: JP-only list spelled out" || return 1
  assert_contains "$t" 'spending money' "AC4: JP-only list spelled out (money)" || return 1
}

test_i289_ac5_developer_needs_jp_is_jp_only_list() {
  local l12 l62
  l12=$(grep -F 'needs_jp' "$I289_DEV" | head -1)
  assert_contains "$(cat "$I289_DEV")" 'on the JP-only list' "AC5: needs_jp defined as on the JP-only list" || return 1
  assert_contains "$(cat "$I289_DEV")" 'answered by the solutions-architect first' "AC5: technical choice answered by SA first" || return 1
  assert_contains "$(cat "$I289_DEV")" 'a recommendation' "AC5: options plus a recommendation" || return 1
}

test_i289_ac7_reroute_logged_via_stage_start_no_blocked_text() {
  local r; r=$(i289_row79)
  assert_contains "$r" 'stage_start' "AC7: reroute recorded as a runs.jsonl stage_start" || return 1
  assert_contains "$r" 'URL' "AC7: only the comment URL is passed" || return 1
  assert_contains "$r" 'not' "AC7: BLOCKED text not copied" || return 1
  assert_contains "$r" 'verbatim' "AC7: rule about verbatim BLOCKED text stated" || return 1
}

run_test test_i289_ac1_row_fires_on_developer_blocked_needs_jp_or_other
run_test test_i289_ac1_spec_conflict_trigger_removed_everywhere
run_test test_i289_ac2_loop_bound_by_marker_order
run_test test_i289_ac3_any_blocked_row_defers
run_test test_i289_ac3_other_classes_rows_unchanged
run_test test_i289_ac4_architect_answers_developer_blocked
run_test test_i289_ac5_developer_needs_jp_is_jp_only_list
run_test test_i289_ac7_reroute_logged_via_stage_start_no_blocked_text
