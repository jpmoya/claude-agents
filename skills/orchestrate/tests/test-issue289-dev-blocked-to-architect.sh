# Issue #289 — a developer BLOCKED of class needs_jp/other goes to the solutions-architect first.
# Text-pins on agents/orchestrator.md rows (:74/:79), fullstack-developer.md, solutions-architect.md.
# Prefix i289_ (all test files share one shell).

I289_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
I289_ORCH="$I289_ROOT/agents/orchestrator.md"
I289_DEV="$I289_ROOT/agents/fullstack-developer.md"
I289_SA="$I289_ROOT/agents/solutions-architect.md"

# the routing row that dispatches the solutions-architect on spec-questioning findings
i289_row79() { grep -F '`[solutions-architect] SPEC RESOLVED` marker' "$I289_ORCH" | grep -F 'Dispatch **solutions-architect**' | head -1; }
i289_sa_line() { grep -F -- '- Dispatched on a developer BLOCKED' "$I289_SA" | head -1; }
i289_dev_line() { grep -F -- '- `**[fullstack-developer] BLOCKED**`' "$I289_DEV" | head -1; }
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
  hits=$(cd "$I289_ROOT" && grep -rn 'SPEC CONFLICT' agents hooks skills/orchestrate 2>/dev/null \
         | grep -v '/tests/' | grep -v '/test/' | grep -v 'test-issue289')
  assert_eq "$hits" "" "AC1: nothing under agents/ hooks/ skills/orchestrate emits or routes on SPEC CONFLICT" || return 1
}

test_i289_ac1_trigger_is_code_track_only_not_other_classes() {
  local r; r=$(i289_row79)
  assert_contains "$r" 'code-track `[fullstack-developer] BLOCKED`' "AC1: trigger is the code-track developer only" || return 1
  assert_not_contains "$r" '`ci_red`' "AC1: ci_red does not trigger the SA row" || return 1
  assert_not_contains "$r" '`ci_pending`' "AC1: ci_pending does not trigger the SA row" || return 1
  assert_not_contains "$r" '`merge_conflict`' "AC1: merge_conflict does not trigger the SA row" || return 1
}

test_i289_ac2_loop_bound_by_marker_order() {
  local r; r=$(i289_row79)
  assert_contains "$r" 'with no `[solutions-architect] SPEC RESOLVED` earlier on the issue' "AC2: trigger requires no earlier SPEC RESOLVED" || return 1
  assert_contains "$r" 'A developer `BLOCKED` posted after a `[solutions-architect] SPEC RESOLVED` on the same issue stays terminal: report it to JP.' "AC2: BLOCKED after SPEC RESOLVED is terminal and reported" || return 1
}

test_i289_ac2_architect_own_blocked_is_terminal() {
  local r74; r74=$(i289_row74)
  # the any-BLOCKED row defers only for a developer BLOCKED; an architect's own BLOCKED stays under "Terminal".
  assert_contains "$r74" 'Terminal: stop and report to JP verbatim' "AC2/3: any-BLOCKED row is terminal by default" || return 1
  assert_contains "$r74" 'except a code-track developer BLOCKED of class `needs_jp` or `other`' "AC2/3: the only exception is the code-track developer BLOCKED" || return 1
  assert_not_contains "$r74" 'except a code-track developer BLOCKED of class `needs_jp` or `other` not yet answered by a `[solutions-architect] BLOCKED`' "AC2: architect BLOCKED is not an exception" || return 1
}

test_i289_ac3_any_blocked_row_defers() {
  local r exc; r=$(i289_row74)
  assert_ne "$r" "" "AC3: any BLOCKED row exists" || return 1
  assert_contains "$r" 'not yet answered by a `[solutions-architect] SPEC RESOLVED`: that goes to the solutions-architect row below, not to JP' "AC3: :74 defers needs_jp/other developer BLOCKED to the SA row" || return 1
  exc=${r#*except }; exc=${exc%%that goes to*}
  assert_not_contains "$exc" 'ci_red' "AC3: ci_red stays terminal (not in the exception)" || return 1
  assert_not_contains "$exc" 'ci_pending' "AC3: ci_pending stays terminal (not in the exception)" || return 1
  assert_not_contains "$exc" 'merge_conflict' "AC3: merge_conflict stays terminal (not in the exception)" || return 1
  assert_not_contains "$exc" 'dependency' "AC3: dependency stays terminal (not in the exception)" || return 1
}

test_i289_ac3_other_classes_rows_unchanged() {
  local t; t=$(cat "$I289_ORCH")
  assert_contains "$t" 'Blocked on: merge_conflict — merge touches locked test <path>` (full lane, lock file present) | Not terminal.' "AC3: :71 locked-test merge row intact" || return 1
  assert_contains "$t" 'auto-retry <n>/<max>: <cls> cleared' "AC3: :73 auto-retry row intact" || return 1
  assert_contains "$t" 'with `<cls>` in `ci_pending`, `ci_red`, `merge_conflict`, `dependency`' "AC3: auto-retry class set unchanged" || return 1
}

test_i289_ac4_architect_answers_developer_blocked() {
  local l; l=$(i289_sa_line)
  assert_ne "$l" "" "AC4: SA doc has the developer-BLOCKED dispatch bullet" || return 1
  assert_contains "$l" '`**[solutions-architect] SPEC RESOLVED**` with line 2 `Resolves: <BLOCKED URL>` for a technical answer' "AC4: SPEC RESOLVED answers a technical BLOCKED with Resolves: <BLOCKED URL>" || return 1
  assert_contains "$l" '`NEEDS PM REVISION` for a product question' "AC4: product question -> NEEDS PM REVISION" || return 1
  assert_contains "$l" 'your own `BLOCKED` (class `needs_jp`) only when the item is on the JP-only list' "AC4: SA BLOCKED needs_jp only for the JP-only list" || return 1
  assert_contains "$l" 'spending money' "AC4: JP-only list spelled out (money)" || return 1
  assert_contains "$l" 'where a private artefact is stored / who gets access' "AC4: JP-only list spelled out (artefact)" || return 1
}

test_i289_ac5_developer_needs_jp_is_jp_only_list() {
  local l; l=$(i289_dev_line)
  assert_ne "$l" "" "AC5: developer BLOCKED bullet exists" || return 1
  assert_contains "$l" '`needs_jp` means the item is on the JP-only list (production, spending money,' "AC5: needs_jp defined as the JP-only list" || return 1
  assert_contains "$l" 'A technical choice or blocker is class `other`' "AC5: technical choice is class other" || return 1
  assert_contains "$l" 'give the options and a recommendation; it is answered by the solutions-architect first' "AC5: options + recommendation, SA first" || return 1
}

test_i289_ac7_row_passes_url_only_not_blocked_text() {
  local r; r=$(i289_row79)
  assert_contains "$r" 'pass the BLOCKED comment URL only (do not copy its text verbatim into the prompt or the log)' "AC7: only the URL is passed; BLOCKED text not copied" || return 1
  assert_contains "$r" 'the reroute is recorded by the normal `stage_start` for the solutions-architect' "AC7: reroute recorded by the existing stage_start" || return 1
}

# AC7 behaviour: stage-run.sh, run for a solutions-architect dispatch carrying a BLOCKED URL, appends exactly one
# stage_start row to events.jsonl (the runs log) for that agent/repo/issue, and the BLOCKED text never reaches the row.
# REGRESSION PIN (architect decision on #289): proves a solutions-architect dispatch logs one stage_start with
# agent (=route), host (=environment), repo, issue. It does NOT prove the reroute decision (LLM orchestrator);
# the row-79 text pin carries that. release SHA is dropped for this ticket.
test_i289_ac7_regression_pin_stage_start_row_for_sa_dispatch() {
  local bin pipe home log rc row
  bin=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-i289.XXXXXX"); pipe=$(new_pipe); home=$(new_home); log="$home/logs/pipeline"
  mkdir -p "$home/.claude/projects"
  printf '#!/bin/bash\nexit 0\n' > "$bin/claude"
  printf '#!/bin/bash\necho "[]"\nexit 0\n' > "$bin/gh"
  chmod +x "$bin/claude" "$bin/gh"
  ( cd "$home" && env PIPE="$pipe" LOGDIR="$log" HOME="$home" CLAUDE_PROJECTS_DIR="$home/.claude/projects" PATH="$bin:$PATH" \
      PIPELINE_ISSUE=289 PIPELINE_AGENT=solutions-architect PIPELINE_REPO=project-a/app \
      "$I289_ROOT/skills/orchestrate/stage-run.sh" -- claude --dangerously-skip-permissions --agent solutions-architect \
      -p "Resolve developer BLOCKED https://github.com/project-a/app/issues/289#issuecomment-111. Repo: project-a/app. Issue: #289." >/dev/null 2>&1 )
  rc=$?
  row=$(jq -c 'select(.event=="stage_start")' "$log/events.jsonl" 2>/dev/null | tail -1)
  rm -rf "$bin" "$pipe" "$home"
  assert_eq "$rc" 0 "AC7: wrapper exits 0" || return 1
  assert_ne "$row" "" "AC7: a stage_start row was emitted for the reroute" || return 1
  assert_eq "$(printf '%s' "$row" | jq -r .agent)" "solutions-architect" "AC7: route (stage) field is solutions-architect" || return 1
  assert_eq "$(printf '%s' "$row" | jq -r .host)" "$(hostname -s | tr "[:upper:]" "[:lower:]")" "AC7: environment (host) field" || return 1
  assert_eq "$(printf '%s' "$row" | jq -r .repo)" "project-a/app" "AC7: repo field" || return 1
  assert_eq "$(printf '%s' "$row" | jq -r .issue)" "289" "AC7: issue field" || return 1
  assert_not_contains "$row" 'BLOCKED' "AC7: no BLOCKED text in the logged row" || return 1
  assert_not_contains "$row" 'issuecomment' "AC7: prompt/URL is not copied into the row" || return 1
}

run_test test_i289_ac1_row_fires_on_developer_blocked_needs_jp_or_other
run_test test_i289_ac1_spec_conflict_trigger_removed_everywhere
run_test test_i289_ac1_trigger_is_code_track_only_not_other_classes
run_test test_i289_ac2_loop_bound_by_marker_order
run_test test_i289_ac2_architect_own_blocked_is_terminal
run_test test_i289_ac3_any_blocked_row_defers
run_test test_i289_ac3_other_classes_rows_unchanged
run_test test_i289_ac4_architect_answers_developer_blocked
run_test test_i289_ac5_developer_needs_jp_is_jp_only_list
run_test test_i289_ac7_row_passes_url_only_not_blocked_text
run_test test_i289_ac7_regression_pin_stage_start_row_for_sa_dispatch
