# Issue #314 — tickets added to an approved goal inherit agent-go.
#   AC1 dgi_doc_*   rules 1-5 in agents/product-manager.md and agents/delivery-lead.md (grep assertions)
#   AC2 dgi_help_*  goal_milestone_approved: approved / unapproved / no-goal fixtures
#   AC3 dgi_gates_* JP-only gates listed, goal grants launch permission only
#   AC5 dgi_log_*   slog line (repo, milestone, reason; no secrets) on the refused path
# Log form (AC5): `slog` with the tokens `repo=<owner/repo> milestone=<n> reason=<text>`. slog IS the existing supervisor
# Slack alert path (supervisor.sh defines it and forwards to the one existing webhook), so the helper must call slog and
# add no webhook of its own; the tests inject a capturing slog.
# AC4 = the existing suites stay green (not a new test).
# Contract chosen here (the ticket names no signature): `goal_milestone_approved <owner/repo> <milestone number>` in
# goal-lib.sh -> stdout = registry issue URL, rc 0 approved | rc 1 not approved | rc 2 registry unreadable (fail closed).
# Registry body format comes from #313: a plain line `Approved-by: JP (register <ISO date>)` next to the json block.
# Reuses the dg_ sandbox (test-goal-deliver.sh is sourced first). Expected values are hand-written from the ticket.

DGI_ROOT=$(cd "$DG_SKILL/../.." && pwd)
DGI_PM="$DGI_ROOT/agents/product-manager.md"
DGI_DL="$DGI_ROOT/agents/delivery-lead.md"
DGI_URL="https://github.com/example-owner/registry/issues/900"

# ------------------------------------------------------------------ doc helpers

# dgi_section <file> <heading regex> — the heading line through the line before the next "## " heading
dgi_section() { awk -v re="$2" '/^## /{ if (on) exit; if ($0 ~ re) on=1 } on {print}' "$1"; }

dgi_need() {  # dgi_need <text> <label> <needle>... — every needle present (case-insensitive)
  local text="$1" label="$2" n; shift 2
  [ -n "$text" ] || { fail "$label: section missing"; return 1; }
  for n in "$@"; do
    printf '%s' "$text" | grep -qiF -- "$n" || { fail "$label: missing [$n]"; return 1; }
  done
}

# dgi_line <text> <label> <needle>... — ONE line of the section holds every needle (case-insensitive). A keyword dump spread
# over several lines, or a bare mention, does not satisfy a rule. Rule sentences must therefore each sit on a single line.
dgi_line() {
  local text="$1" label="$2" n; shift 2
  [ -n "$text" ] || { fail "$label: section missing"; return 1; }
  local l ok
  while IFS= read -r l; do
    ok=1
    for n in "$@"; do printf '%s' "$l" | grep -qiF -- "$n" || { ok=0; break; }; done
    [ $ok = 1 ] && return 0
  done <<< "$text"
  fail "$label: no single line holds all of [$*]"; return 1
}

DGI_GATES=("production" "spending money" "third-party systems of record" "deleting data" "external communications" \
           "private artefact" "infra" "mockup" "risky-list")

# ------------------------------------------------------------------ AC1: product-manager.md

test_dgi_doc_pm_rule1_inherit_from_approved_goal() {
  local s; s=$(dgi_section "$DGI_PM" '[Aa]pproved goal')
  dgi_line "$s" "PM rule 1 heading rule" "child of an approved goal" "Approved-by: JP" "registry" "agent-go" || return 1
  dgi_line "$s" "PM rule 1 note" "**[product-manager] NOTE** approval inherited from goal" "registry issue URL" || return 1
  dgi_line "$s" "PM rule 1 new requirements" "new requirement" "in-progress goal" "agent-go" || return 1
}

test_dgi_doc_pm_rule2_exclusions_explicit() {
  local s; s=$(dgi_section "$DGI_PM" '[Aa]pproved goal')
  dgi_line "$s" "PM rule 2 BI" "Business-Intelligence" "never" || return 1
  dgi_line "$s" "PM rule 2 sentry" "source:sentry" "never" "--include-sentry" || return 1
  dgi_line "$s" "PM rule 2 start-gate" "start-gate" "agent-go deferred" "B3" || return 1
  dgi_line "$s" "PM rule 2 moved out" "moved out of the goal milestone" "loses nothing" || return 1
}

test_dgi_doc_pm_rule3_plan_change_needs_no_new_approval() {
  dgi_line "$(dgi_section "$DGI_PM" '[Aa]pproved goal')" "PM rule 3" "plan change" "needs no new approval" || return 1
}

test_dgi_doc_pm_rule5_line71_reworded() {
  # old text: "This is the only case in which an agent adds `agent-go`."
  assert_not_contains "$(cat "$DGI_PM")" "This is the only case in which an agent adds" "PM rule 5: old sentence gone" || return 1
  dgi_line "$(cat "$DGI_PM")" "PM rule 5" "only agent adding \`agent-go\` on its own authority" "deliver.sh registration" "delivery lead" || return 1
}

# ------------------------------------------------------------------ AC1: delivery-lead.md

test_dgi_doc_dl_approval_section_rule4() {
  local s; s=$(dgi_section "$DGI_DL" '^## ([0-9]+\. )?Approval')
  dgi_line "$s" "DL rule 4 approval" "hand-launches" "labels an in-scope ticket" "agent-go" "approved goal" "counts as JP's approval" || return 1
  dgi_line "$s" "DL rule 4 labelling" "in-scope open tickets" "same guards" "B1" || return 1
}

test_dgi_doc_dl_guards_explicit() {
  local s; s=$(dgi_section "$DGI_DL" '^## ([0-9]+\. )?Approval')
  dgi_line "$s" "DL guard BI" "Business-Intelligence" "never" || return 1
  dgi_line "$s" "DL guard sentry" "source:sentry" "never" "--include-sentry" || return 1
}

test_dgi_doc_dl_rule3_plan_change_needs_no_new_approval() {
  dgi_line "$(dgi_section "$DGI_DL" '^## ([0-9]+\. )?Approval')" "DL rule 3" "plan change" "needs no new approval" || return 1
}

# ------------------------------------------------------------------ AC3: JP-only gates not loosened

test_dgi_gates_pm_section_lists_gates_and_launch_permission_only() {
  local s; s=$(dgi_section "$DGI_PM" '[Aa]pproved goal')
  # AC3: one sentence ties "launch permission only" and "never answers" to the whole gate list
  dgi_line "$s" "PM gates" "launch permission" "never answers" "${DGI_GATES[@]}" || return 1
}

test_dgi_gates_dl_section_lists_gates_and_launch_permission_only() {
  local s; s=$(dgi_section "$DGI_DL" '^## ([0-9]+\. )?Approval')
  dgi_line "$s" "DL gates" "launch permission" "never answers" "${DGI_GATES[@]}" || return 1
}

# ------------------------------------------------------------------ AC2: helper fixtures

# dgi_registry <n> <spec> <id> <approved-line|""> [open|closed] — a registry issue with an optional plain approval line
dgi_registry() {
  local n=$1 spec=$2 id=$3 appr=$4 st=${5:-open} block body closed=null
  block=$(jq -nc --arg id "$id" --arg spec "$spec" --arg c "$DG_NOW" '{v:1,id:$id,spec:$spec,host:"host-a",created:$c,instructions:""}')
  body=$(printf 'Goal: %s\n\n```json\n%s\n```\n' "$spec" "$block")
  [ -z "$appr" ] || body=$(printf '%s\n%s\n' "$body" "$appr")
  [ "$st" = closed ] && closed="\"$DG_NOW\""
  jq -nc --argjson n "$n" --arg title "Goal: $spec" --arg body "$body" --arg st "$st" --argjson closed "$closed" --arg now "$DG_NOW" \
    '{number:$n, title:$title, body:$body, state:$st, labels:[{name:"delivery-goal"}], milestone:null,
      closed_at:$closed, created_at:$now, updated_at:$now}' > "$DG_ST/issues/$DG_REG/$n.json"
}

DGI_OK="Approved-by: JP (register 2026-10-16)"

# dgi_call <repo> <ms> — runs the helper; sets DG_RC / DG_OUT / DG_ERR and DGI_LOG (slog lines captured)
dgi_call() {
  DGI_LOG="$DG_HOME/slog.txt"; : > "$DGI_LOG"
  dg_lib "slog() { printf '%s\\n' \"\$*\" >> '$DGI_LOG'; }; goal_milestone_approved $1 $2"
  DGI_LOG=$(cat "$DGI_LOG")
}

test_dgi_help_approved_milestone_goal_yields_registry_url() {
  dg_setup; local rc=0
  dgi_registry 900 "$DG_SPEC_MS" "$DG_ID_MS" "$DGI_OK"
  dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "0" "approved goal: rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "$DGI_URL" "approved goal: prints the registry issue URL" || rc=1
  dg_teardown; return $rc
}

test_dgi_help_unapproved_goal_refused() {
  dg_setup; local rc=0
  dgi_registry 900 "$DG_SPEC_MS" "$DG_ID_MS" ""
  dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "1" "unapproved goal: rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "" "unapproved goal: no URL printed" || rc=1
  dg_teardown; return $rc
}

test_dgi_help_approval_line_must_say_JP() {
  dg_setup; local rc=0
  dgi_registry 900 "$DG_SPEC_MS" "$DG_ID_MS" "Approved-by: someone-else"
  dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "1" "Approved-by someone else: rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "" "Approved-by someone else: no URL" || rc=1
  dg_teardown; return $rc
}

test_dgi_help_no_goal_at_all_refused() {
  dg_setup; local rc=0
  dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "1" "no goal: rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "" "no goal: no URL" || rc=1
  dg_teardown; return $rc
}

test_dgi_help_approved_goal_of_another_milestone_refused() {
  dg_setup; local rc=0
  dgi_registry 900 "example-owner/project-a:milestone:13" "example-owner_project-a-ms-13" "$DGI_OK"
  dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "1" "other milestone's goal: rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "" "other milestone's goal: no URL" || rc=1
  dg_teardown; return $rc
}

test_dgi_help_approved_goal_of_another_repo_refused() {
  dg_setup; local rc=0
  dgi_registry 900 "example-owner/project-b:milestone:12" "example-owner_project-b-ms-12" "$DGI_OK"
  dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "1" "other repo's goal (same milestone number): rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "" "other repo's goal: no URL" || rc=1
  dg_teardown; return $rc
}

test_dgi_help_approved_single_ticket_goal_does_not_cover_a_milestone() {
  dg_setup; local rc=0
  dgi_registry 900 "$DG_SPEC_T7" "$DG_ID_T7" "$DGI_OK"
  dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "1" "ticket goal vs milestone: rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "" "ticket goal vs milestone: no URL" || rc=1
  dg_teardown; return $rc
}

test_dgi_help_approved_milestones_all_goal_covers_any_milestone_of_its_repo() {
  dg_setup; local rc=0
  dgi_registry 900 "$DG_SPEC_ALL" "$DG_ID_ALL" "$DGI_OK"
  dgi_call example-owner/project-a 13
  assert_eq "$DG_RC" "0" "msall goal: rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "$DGI_URL" "msall goal: registry URL" || rc=1
  dg_teardown; return $rc
}

test_dgi_help_goal_milestone_1_does_not_approve_milestone_12() {
  dg_setup; local rc=0
  dgi_registry 900 "example-owner/project-a:milestone:1" "example-owner_project-a-ms-1" "$DGI_OK"
  dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "1" "goal milestone:1 vs milestone 12 (no prefix match): rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "" "goal milestone:1 vs milestone 12: no URL" || rc=1
  dg_teardown; return $rc
}

test_dgi_help_goal_milestone_12_does_not_approve_milestone_1() {
  dg_setup; local rc=0
  dgi_registry 900 "$DG_SPEC_MS" "$DG_ID_MS" "$DGI_OK"
  dgi_call example-owner/project-a 1
  assert_eq "$DG_RC" "1" "goal milestone:12 vs milestone 1 (no substring match): rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "" "goal milestone:12 vs milestone 1: no URL" || rc=1
  dg_teardown; return $rc
}

test_dgi_help_picks_by_scope_not_by_any_approved_issue() {
  dg_setup; local rc=0
  # #900 approved goal for milestone 13; #901 UNapproved goal for milestone 12.
  dgi_registry 900 "example-owner/project-a:milestone:13" "example-owner_project-a-ms-13" "$DGI_OK"
  dgi_registry 901 "$DG_SPEC_MS" "$DG_ID_MS" ""
  dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "1" "ms 12 unapproved while ms 13 approved: rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "" "ms 12: no URL" || rc=1
  dgi_call example-owner/project-a 13
  assert_eq "$DG_RC" "0" "ms 13 approved: rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "https://github.com/example-owner/registry/issues/900" "ms 13: URL of its own registry issue (#900, not #901)" || rc=1
  dg_teardown; return $rc
}

test_dgi_help_closed_goal_no_longer_approves() {
  dg_setup; local rc=0
  dgi_registry 900 "$DG_SPEC_MS" "$DG_ID_MS" "$DGI_OK" closed
  dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "1" "closed (delivered/stopped) goal: rc (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "" "closed goal: no URL" || rc=1
  dg_teardown; return $rc
}

# ------------------------------------------------------------------ AC5: observability on the refused path

test_dgi_log_unapproved_goal_writes_slog_line() {
  dg_setup; local rc=0
  dgi_registry 900 "$DG_SPEC_MS" "$DG_ID_MS" ""
  GH_TOKEN="ghp_SECRETSECRET" dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "1" "refused: rc" || rc=1
  assert_contains "$DGI_LOG" "repo=example-owner/project-a" "slog line has the exact repo= token" || rc=1
  assert_contains "$DGI_LOG" "milestone=12" "slog line has the exact milestone= token" || rc=1
  assert_contains "$DGI_LOG" "reason=" "slog line carries a reason" || rc=1
  assert_not_contains "$DGI_LOG" "SECRET" "slog line has no secrets" || rc=1
  dg_teardown; return $rc
}

test_dgi_log_unreadable_registry_fails_closed_and_logs() {
  dg_setup; local rc=0
  printf '#!/bin/bash\necho "gh: HTTP 502" >&2\nexit 1\n' > "$DG_BIN/gh"   # every gh call fails
  dgi_registry 900 "$DG_SPEC_MS" "$DG_ID_MS" "$DGI_OK" 2>/dev/null
  dgi_call example-owner/project-a 12
  assert_eq "$DG_RC" "2" "unreadable registry: rc 2 (fail closed, never 0)" || rc=1
  assert_eq "$DG_OUT" "" "unreadable registry: no URL" || rc=1
  assert_contains "$DGI_LOG" "repo=example-owner/project-a" "slog line has the exact repo= token" || rc=1
  assert_contains "$DGI_LOG" "milestone=12" "slog line has the exact milestone= token" || rc=1
  assert_contains "$DGI_LOG" "reason=" "slog line carries a reason" || rc=1
  assert_not_contains "$DGI_LOG" "SECRET" "slog line has no secrets" || rc=1
  dg_teardown; return $rc
}

for t in test_dgi_doc_pm_rule1_inherit_from_approved_goal \
         test_dgi_doc_pm_rule2_exclusions_explicit \
         test_dgi_doc_pm_rule3_plan_change_needs_no_new_approval \
         test_dgi_doc_pm_rule5_line71_reworded \
         test_dgi_doc_dl_approval_section_rule4 \
         test_dgi_doc_dl_guards_explicit \
         test_dgi_doc_dl_rule3_plan_change_needs_no_new_approval \
         test_dgi_gates_pm_section_lists_gates_and_launch_permission_only \
         test_dgi_gates_dl_section_lists_gates_and_launch_permission_only \
         test_dgi_help_approved_milestone_goal_yields_registry_url \
         test_dgi_help_unapproved_goal_refused \
         test_dgi_help_approval_line_must_say_JP \
         test_dgi_help_no_goal_at_all_refused \
         test_dgi_help_approved_goal_of_another_milestone_refused \
         test_dgi_help_approved_goal_of_another_repo_refused \
         test_dgi_help_approved_single_ticket_goal_does_not_cover_a_milestone \
         test_dgi_help_approved_milestones_all_goal_covers_any_milestone_of_its_repo \
         test_dgi_help_goal_milestone_1_does_not_approve_milestone_12 \
         test_dgi_help_goal_milestone_12_does_not_approve_milestone_1 \
         test_dgi_help_picks_by_scope_not_by_any_approved_issue \
         test_dgi_help_closed_goal_no_longer_approves \
         test_dgi_log_unapproved_goal_writes_slog_line \
         test_dgi_log_unreadable_registry_fails_closed_and_logs; do
  run_test "$t"
done
