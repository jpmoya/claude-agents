# #792 — the pipeline's docs, agent prompts, hook and skill text name the current repos (benjis-ops-tool, benjis-sales-tool), never
# the pre-rename names (scheduler, benjis-quoting-tool, "quoting tool"). An old name may stay only where it IS the alias data
# or the explanation of it: a file in the allowlist below, or a line that says it is the old name (formerly, pre-rename, then
# named, old name, alias, redirect). Tests, status-page fixtures, shell state files and the memory-sync keys are out of scope.
# Prefix on_ / ON_.

HERE_ON=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_ON=$(cd "$HERE_ON/../../.." && pwd)

# Alias data and code that must still recognise the old names (each one reads the old name on purpose):
ON_ALLOW_FILES=(
  skills/ticket-intake/repo-aliases.txt     # the alias list itself
  skills/orchestrate/find-duplicates.sh     # DEDUPE_REPO_GROUPS
  skills/orchestrate/goal-lib.sh            # goal-id alias (#792) and the repo_canon note
  skills/orchestrate/deliver.sh             # _goal_same_repo / feedback-goal overlap note (#527)
  skills/orchestrate/pipeline-lib.sh        # integration_branch_for keeps the old names (#792)
  hooks/blocked-chain-stop.sh              # run-file and remote-name regexes: live state files still carry the old names
  hooks/ticket-intake-guard.sh              # explains/uses repo-aliases.txt
  infra/host-manifest.json                  # "name" is the memory-sync store key (repo-<name>); renaming it splits the store
  infra/ci-runners/ci-queue-collect.sh      # the scheduler / benjis-ops-tool alias returns the same runs from both API paths
  scripts/ci-metrics.repos
  skills/portal-changelog/SKILL.md          # Slack channel #quoting_portal is a real channel name
  agents/deployer.md                        # #quoting-portal channel, scheduler_migration_ledger table name
  living.md                                 # Sentry project id SCHEDULER-1D
  agents/infra-planner.md                   # memory file name project_scheduler_staging.md
)
ON_MARK='formerly|pre-rename|then named|old name|alias|redirect|renamed|was named'
# what counts as an old name in prose or ids
ON_PAT='benjis-quoting-tool|quoting[ -]tool|Benjis-Plants/scheduler|jpmoya/scheduler|[Ss]cheduler ?#[0-9]|scheduler/benjis|ops tool/scheduler|[Ss]cheduler has '

on_scan() {  # prints "file:line:text" for each offending line
  local f rel
  while IFS= read -r rel; do
    f="$ROOT_ON/$rel"
    case "$rel" in
      skills/orchestrate/tests/*|status-page/*|tests/*|docs/*-20[0-9][0-9]-[0-9][0-9]*|docs/ci-efficiency-assessments-*) continue ;;
    esac
    local a skip=0
    for a in "${ON_ALLOW_FILES[@]}"; do [ "$rel" = "${a%% *}" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    grep -n -E "$ON_PAT" "$f" 2>/dev/null | grep -v -E "$ON_MARK" | sed "s#^#$rel:#"
  done < <(git -C "$ROOT_ON" ls-files -- CLAUDE.md README.md agents docs hooks skills living.md 2>/dev/null)
}

test_on_no_old_repo_names_in_human_facing_text() {
  local out; out=$(on_scan | cut -c1-200)
  assert_eq "$out" "" "old repo names left in docs/prompts/hooks (use benjis-ops-tool / benjis-sales-tool, or say 'formerly ...' on the line)" || return 1
}

test_on_allowlist_files_exist() {
  local a rc=0
  for a in "${ON_ALLOW_FILES[@]}"; do
    [ -e "$ROOT_ON/${a%% *}" ] || { fail "allowlisted file is gone: ${a%% *} (drop it from the allowlist)"; rc=1; }
  done
  return $rc
}

test_on_repo_aliases_still_map_both_old_names() {
  local rc=0 f="$ROOT_ON/skills/ticket-intake/repo-aliases.txt"
  grep -qx 'Benjis-Plants/scheduler Benjis-Plants/benjis-ops-tool' "$f" || { fail "scheduler alias missing"; rc=1; }
  grep -qx 'Benjis-Plants/benjis-quoting-tool Benjis-Plants/benjis-sales-tool' "$f" || { fail "benjis-quoting-tool alias missing"; rc=1; }
  return $rc
}

run_test test_on_no_old_repo_names_in_human_facing_text
run_test test_on_allowlist_files_exist
run_test test_on_repo_aliases_still_map_both_old_names
