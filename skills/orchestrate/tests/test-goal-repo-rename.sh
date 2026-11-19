# #792 — goals after the repo renames (scheduler -> benjis-ops-tool, benjis-quoting-tool -> benjis-sales-tool).
# New specs and ids use the current repo name; an id stored under an old name keeps resolving to the same goal through the
# alias list (skills/ticket-intake/repo-aliases.txt). The registry, $PIPE and the slot logic are never rewritten.
# Hand arithmetic: spec "Benjis-Plants/benjis-quoting-tool:milestone:112" -> id "Benjis-Plants_benjis-sales-tool-ms-112".
# Prefix gr_ / GR_. No network: _goal_registry_json is stubbed with a fixture file.

HERE_GR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_GR=$(cd "$HERE_GR/../../.." && pwd)
SKILL_GR="$HERE_GR/.."

# gr_run <shell snippet> — runs it with the libs sourced and _goal_registry_json reading $GR_DIR/registry.json
gr_run() {
  GR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-gr.XXXXXX")
  printf '%s' "${GR_REGISTRY:-[]}" > "$GR_DIR/registry.json"
  GR_OUT=$( export PIPE="$GR_DIR/pipe" LOGDIR="$GR_DIR/logs" HOST=host-test
            . "$ROOT_GR/hooks/pipeline-markers.sh"; . "$SKILL_GR/pipeline-lib.sh"; . "$SKILL_GR/goal-lib.sh"
            _goal_registry_json() { cat "$GR_DIR/registry.json"; }
            eval "$1" 2>&1 )
  rm -rf "$GR_DIR"
}

test_gr_old_specs_parse_to_current_repo() {
  local rc=0
  gr_run 'goal_parse "Benjis-Plants/benjis-quoting-tool:milestone:112"; goal_parse "Benjis-Plants/scheduler:feedback"; goal_parse "benjis-plants/SCHEDULER#1345"'
  assert_eq "$GR_OUT" "$(printf 'Benjis-Plants/benjis-sales-tool\tms\t112\nBenjis-Plants/benjis-ops-tool\tfb\tfeedback\nBenjis-Plants/benjis-ops-tool\tt\t1345')" "old names parse to the current repos (any case)" || rc=1
  return $rc
}

test_gr_current_and_foreign_specs_unchanged() {
  local rc=0
  gr_run 'goal_parse "Benjis-Plants/benjis-sales-tool#7"; goal_parse "jpmoya/claude-agents#206"; goal_parse "project:jpmoya/44"; goal_parse "label:goal: X"'
  assert_eq "$GR_OUT" "$(printf 'Benjis-Plants/benjis-sales-tool\tt\t7\njpmoya/claude-agents\tt\t206\n-\tproj\tjpmoya/44\n-\tlabel\tgoal: X')" "current, foreign, project and label specs are unchanged" || rc=1
  return $rc
}

test_gr_new_ids_use_current_names() {
  local rc=0
  gr_run 'goal_id "Benjis-Plants/benjis-quoting-tool:milestone:112"; goal_id "Benjis-Plants/scheduler:feedback"; goal_id "Benjis-Plants/benjis-ops-tool:feedback"'
  assert_eq "$GR_OUT" "$(printf 'Benjis-Plants_benjis-sales-tool-ms-112\nBenjis-Plants_benjis-ops-tool-fb-feedback\nBenjis-Plants_benjis-ops-tool-fb-feedback')" "an old-name spec gets the current-name id" || rc=1
  return $rc
}

test_gr_goal_id_current_maps_only_goal_ids_of_old_repos() {
  local rc=0
  gr_run 'for i in Benjis-Plants_benjis-quoting-tool-ms-112 Benjis-Plants_scheduler-fb-feedback Benjis-Plants_scheduler-t-1345 benjis-plants_SCHEDULER-msall-all Benjis-Plants_benjis-sales-tool-ms-148 Benjis-Plants_scheduler-extras-ms-1 label-goal__Sales_Workflow_3.0 proj-jpmoya_41 jpmoya_claude-agents-t-206; do goal_id_current "$i"; done'
  assert_eq "$GR_OUT" "$(printf '%s\n' Benjis-Plants_benjis-sales-tool-ms-112 Benjis-Plants_benjis-ops-tool-fb-feedback Benjis-Plants_benjis-ops-tool-t-1345 Benjis-Plants_benjis-ops-tool-msall-all Benjis-Plants_benjis-sales-tool-ms-148 Benjis-Plants_scheduler-extras-ms-1 label-goal__Sales_Workflow_3.0 proj-jpmoya_41 jpmoya_claude-agents-t-206)" "old-name ids map; current, other-repo, label and project ids stay" || rc=1
  return $rc
}

test_gr_find_matches_old_id_from_new_id_and_back() {
  local rc=0
  GR_REGISTRY='[{"issue":396,"id":"Benjis-Plants_benjis-quoting-tool-ms-112","state":"closed"},{"issue":537,"id":"Benjis-Plants_benjis-ops-tool-fb-feedback","state":"open"}]'
  gr_run '_goal_find Benjis-Plants_benjis-sales-tool-ms-112 | jq -r .issue; _goal_find Benjis-Plants_benjis-quoting-tool-ms-112 | jq -r .issue; _goal_find Benjis-Plants_scheduler-fb-feedback | jq -r .issue; _goal_find Benjis-Plants_benjis-ops-tool-fb-feedback | jq -r .issue'
  assert_eq "$GR_OUT" "$(printf '396\n396\n537\n537')" "old and current ids find the same registry goal" || rc=1
  return $rc
}

test_gr_find_unrelated_id_is_not_found() {
  local rc=0
  GR_REGISTRY='[{"issue":396,"id":"Benjis-Plants_benjis-quoting-tool-ms-112","state":"closed"}]'
  gr_run '_goal_find Benjis-Plants_benjis-sales-tool-ms-113 >/dev/null 2>&1; echo "rc=$?"; _goal_find Benjis-Plants_other-tool-ms-112 >/dev/null 2>&1; echo "rc=$?"'
  assert_eq "$GR_OUT" "$(printf 'rc=1\nrc=1')" "another milestone or another repo never matches" || rc=1
  return $rc
}

test_gr_find_open_entry_beats_closed_twin() {
  local rc=0
  # same goal registered twice (once before the rename): the open one is the live goal, whichever name was asked for
  GR_REGISTRY='[{"issue":500,"id":"Benjis-Plants_scheduler-fb-feedback","state":"closed"},{"issue":537,"id":"Benjis-Plants_benjis-ops-tool-fb-feedback","state":"open"}]'
  gr_run '_goal_find Benjis-Plants_scheduler-fb-feedback | jq -r .issue; _goal_find Benjis-Plants_benjis-ops-tool-fb-feedback | jq -r .issue'
  assert_eq "$GR_OUT" "$(printf '537\n537')" "open current-name entry wins over a closed old-name one" || rc=1
  GR_REGISTRY='[{"issue":500,"id":"Benjis-Plants_scheduler-fb-feedback","state":"open"},{"issue":537,"id":"Benjis-Plants_benjis-ops-tool-fb-feedback","state":"open"}]'
  gr_run '_goal_find Benjis-Plants_scheduler-fb-feedback | jq -r .issue; _goal_find Benjis-Plants_benjis-ops-tool-fb-feedback | jq -r .issue'
  assert_eq "$GR_OUT" "$(printf '500\n537')" "two open twins: the exact id asked for wins" || rc=1
  return $rc
}

test_gr_find_exact_id_unchanged_without_aliases() {
  local rc=0
  GR_REGISTRY='[{"issue":10,"id":"proj-jpmoya_41","state":"open"},{"issue":11,"id":"label-goal__X","state":"closed"}]'
  gr_run '_goal_find proj-jpmoya_41 | jq -r .issue; _goal_find label-goal__X | jq -r .issue'
  assert_eq "$GR_OUT" "$(printf '10\n11')" "ids that carry no repo name resolve as before" || rc=1
  return $rc
}

test_gr_audit_lists_only_old_name_ids() {
  local rc=0
  GR_REGISTRY='[{"issue":396,"id":"Benjis-Plants_benjis-quoting-tool-ms-112","state":"closed"},{"issue":537,"id":"Benjis-Plants_benjis-ops-tool-fb-feedback","state":"open"},{"issue":534,"id":"Benjis-Plants_scheduler-fb-feedback","state":"open"},{"issue":10,"id":"proj-jpmoya_41","state":"open"}]'
  gr_run 'goal_id_audit'
  assert_eq "$GR_OUT" "$(printf '396\tclosed\tBenjis-Plants_benjis-quoting-tool-ms-112\tBenjis-Plants_benjis-sales-tool-ms-112\n534\topen\tBenjis-Plants_scheduler-fb-feedback\tBenjis-Plants_benjis-ops-tool-fb-feedback')" "audit prints issue, state, id and current id of old-name goals only" || rc=1
  return $rc
}

test_gr_audit_is_empty_when_no_goal_uses_an_old_name() {
  local rc=0
  GR_REGISTRY='[{"issue":537,"id":"Benjis-Plants_benjis-ops-tool-fb-feedback","state":"open"},{"issue":10,"id":"proj-jpmoya_41","state":"open"}]'
  gr_run 'goal_id_audit; echo "rc=$?"'
  assert_eq "$GR_OUT" "rc=0" "no old-name id: empty list, exit 0" || rc=1
  return $rc
}

test_gr_missing_alias_file_is_identity() {
  local rc=0
  gr_run 'GOAL_REPO_ALIASES_FILE=/nonexistent/aliases.txt; goal_repo_current Benjis-Plants/scheduler; goal_id_current Benjis-Plants_scheduler-fb-feedback'
  assert_eq "$GR_OUT" "$(printf 'Benjis-Plants/scheduler\nBenjis-Plants_scheduler-fb-feedback')" "no alias list: nothing is renamed, nothing fails" || rc=1
  return $rc
}

test_gr_audit_wrapper_runs_read_only() {
  local rc=0 w="$SKILL_GR/goal-id-audit.sh"
  [ -x "$w" ] || { fail "goal-id-audit.sh missing or not executable"; return 1; }
  grep -q 'goal_id_audit' "$w" || { fail "wrapper does not call goal_id_audit"; rc=1; }
  if grep -E 'gh api (-X|--method) *(POST|PATCH|PUT|DELETE)|--input|gh issue (edit|comment|close)' "$w" >/dev/null; then fail "audit wrapper must not write"; rc=1; fi
  return $rc
}

test_gr_integration_branch_for_current_and_old_names() {
  local rc=0
  gr_run 'for r in benjis-ops-tool scheduler benjis-sales-tool benjis-quoting-tool claude-agents benjis-newwebsite; do integration_branch_for "$r"; done'
  assert_eq "$GR_OUT" "$(printf 'staging\nstaging\nstaging\nstaging\nmain\nmain')" "ops tool and sales tool (either name) land on staging, others on main" || rc=1
  return $rc
}

run_test test_gr_old_specs_parse_to_current_repo
run_test test_gr_current_and_foreign_specs_unchanged
run_test test_gr_new_ids_use_current_names
run_test test_gr_goal_id_current_maps_only_goal_ids_of_old_repos
run_test test_gr_find_matches_old_id_from_new_id_and_back
run_test test_gr_find_unrelated_id_is_not_found
run_test test_gr_find_open_entry_beats_closed_twin
run_test test_gr_find_exact_id_unchanged_without_aliases
run_test test_gr_audit_lists_only_old_name_ids
run_test test_gr_audit_is_empty_when_no_goal_uses_an_old_name
run_test test_gr_missing_alias_file_is_identity
run_test test_gr_audit_wrapper_runs_read_only
run_test test_gr_integration_branch_for_current_and_old_names
