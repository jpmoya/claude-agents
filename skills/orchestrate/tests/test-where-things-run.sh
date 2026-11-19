# #770: where-things-run.sh — live runner variables and runners, never workflow YAML. Fake gh (bin/gh-wtr) serves fixtures;
# placeholder repo names only (this repo is public).

WTR_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../where-things-run.sh"
WTR_GH_STUB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/gh-wtr"
WTR_SPEC="example-owner/project-a:CI_RUNNER_JSON,PROD_DEPLOY_RUNNER_JSON"

# wtr_vars <NAME=value ...> -> {"variables":[...]} (a value is raw JSON text of the variable, e.g. '"benjis-ci"')
wtr_vars() {
  local a n v out="[]"
  for a in "$@"; do
    n=${a%%=*}; v=${a#*=}
    out=$(printf '%s' "$out" | jq -c --arg n "$n" --arg v "$v" '. + [{name:$n,value:$v}]')
  done
  printf '{"total_count":0,"variables":%s}' "$out"
}
# wtr_runners <name:status:label+label ...> -> {"runners":[...]}
wtr_runners() {
  local a i=${WTR_ID_BASE:-0} name rest status labels out="[]"
  for a in "$@"; do
    i=$((i + 1)); name=${a%%:*}; rest=${a#*:}; status=${rest%%:*}; labels=${rest#*:}
    out=$(printf '%s' "$out" | jq -c --argjson id "$i" --arg n "$name" --arg s "$status" --arg l "$labels" \
      '. + [{id:$id,name:$n,status:$s,busy:false,labels:([{name:"self-hosted"}] + ($l | split("+") | map({name:.})))}]')
  done
  printf '{"total_count":0,"runners":%s}' "$out"
}
# wtr_fixture <dir> — a healthy world: org var CI_RUNNER_JSON, repo var PROD_DEPLOY_RUNNER_JSON, a pool + bulk + prod-deploy runner
wtr_fixture() {
  local d=$1
  wtr_vars 'PROD_DEPLOY_RUNNER_JSON=["self-hosted","ci-prod-deploy"]' > "$d/repos_example-owner_project-a_actions_variables.json"
  wtr_vars 'CI_RUNNER_JSON="ci-pool"' > "$d/repos_example-owner_project-a_actions_organization-variables.json"
  wtr_runners > "$d/repos_example-owner_project-a_actions_runners.json"
  wtr_runners slot-1:online:ci-pool slot-2:online:ci-pool+ci-pool-bulk slot-3:online:ci-prod-deploy > "$d/orgs_example-owner_actions_runners.json"
}
WTR_OUT=""; WTR_ERR=""; WTR_RC=0
wtr_run() {  # wtr_run <fixture dir> [args...] — fills WTR_OUT / WTR_ERR / WTR_RC
  local d=$1; shift
  WTR_OUT=$(WTR_FIX="$d" WTR_GH="$WTR_GH_STUB" WTR_TARGETS="$WTR_SPEC" bash "$WTR_BIN" "$@" 2> "$d/stderr"); WTR_RC=$?
  WTR_ERR=$(cat "$d/stderr")
}
wtr_dir() { mktemp -d "${TMPDIR:-/tmp}/wtr-test.XXXXXX"; }

test_wtr_healthy_exit0() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  wtr_run "$d"
  assert_eq "$WTR_RC" 0 "exit" || return 1
  assert_contains "$WTR_OUT" "RESULT: OK" "result" || return 1
  assert_contains "$WTR_OUT" "CI_RUNNER_JSON" "lists the variable" || return 1
  assert_contains "$WTR_OUT" "org " "source org" || return 1
  assert_not_contains "$WTR_OUT" "FLAG:" "no flags" || return 1
}
test_wtr_unset_org_variable_flagged() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  wtr_vars > "$d/repos_example-owner_project-a_actions_organization-variables.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 1 "exit" || return 1
  assert_contains "$WTR_OUT" "FLAG: example-owner/project-a: CI_RUNNER_JSON is unset or empty" "flag" || return 1
  assert_contains "$WTR_OUT" "NOT SET" "table row" || return 1
}
test_wtr_empty_value_flagged() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  wtr_vars 'PROD_DEPLOY_RUNNER_JSON=' > "$d/repos_example-owner_project-a_actions_variables.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 1 "exit" || return 1
  assert_contains "$WTR_OUT" "FLAG: example-owner/project-a: PROD_DEPLOY_RUNNER_JSON is unset or empty" "flag" || return 1
}
test_wtr_repo_variable_overrides_org() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  # org says self-hosted, the repo overrides it with a GitHub-hosted label: the repo value wins
  wtr_vars 'PROD_DEPLOY_RUNNER_JSON=["self-hosted","ci-prod-deploy"]' 'CI_RUNNER_JSON="ubuntu-latest"' > "$d/repos_example-owner_project-a_actions_variables.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 1 "exit" || return 1
  assert_contains "$WTR_OUT" "FLAG: example-owner/project-a: CI_RUNNER_JSON is \"ubuntu-latest\", a GitHub-hosted runner label" "flag" || return 1
  assert_contains "$WTR_OUT" "repo " "source repo" || return 1
}
test_wtr_repo_override_can_fix_org() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  # org says hosted, the repo overrides it with the pool: no flag
  wtr_vars 'CI_RUNNER_JSON="ubuntu-latest"' > "$d/repos_example-owner_project-a_actions_organization-variables.json"
  wtr_vars 'PROD_DEPLOY_RUNNER_JSON=["self-hosted","ci-prod-deploy"]' 'CI_RUNNER_JSON="ci-pool"' > "$d/repos_example-owner_project-a_actions_variables.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 0 "exit" || return 1
}
test_wtr_offline_runner_flagged() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  wtr_runners slot-1:online:ci-pool slot-2:online:ci-pool+ci-pool-bulk slot-3:online:ci-prod-deploy slot-4:offline:ci-pool > "$d/orgs_example-owner_actions_runners.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 1 "exit" || return 1
  assert_contains "$WTR_OUT" "FLAG: example-owner/project-a: runner slot-4 is offline" "flag" || return 1
}
test_wtr_no_online_runner_for_label_queues() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  wtr_runners slot-1:online:ci-pool slot-2:online:ci-pool+ci-pool-bulk > "$d/orgs_example-owner_actions_runners.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 1 "exit" || return 1
  assert_contains "$WTR_OUT" "PROD_DEPLOY_RUNNER_JSON needs labels" "flag" || return 1
  assert_contains "$WTR_OUT" "QUEUE" "says queue" || return 1
  assert_contains "$WTR_OUT" "do not fall back to GitHub-hosted" "says no fallback" || return 1
}
test_wtr_offline_runner_does_not_satisfy_label() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  wtr_runners slot-1:online:ci-pool slot-2:online:ci-pool+ci-pool-bulk slot-3:offline:ci-prod-deploy > "$d/orgs_example-owner_actions_runners.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 1 "exit" || return 1
  assert_contains "$WTR_OUT" "PROD_DEPLOY_RUNNER_JSON needs labels" "flag" || return 1
}
test_wtr_repo_level_runner_counts() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  wtr_runners slot-1:online:ci-pool slot-2:online:ci-pool+ci-pool-bulk > "$d/orgs_example-owner_actions_runners.json"
  WTR_ID_BASE=100 wtr_runners repo-prod:online:ci-prod-deploy > "$d/repos_example-owner_project-a_actions_runners.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 0 "exit" || return 1
  assert_contains "$WTR_OUT" "repo-prod" "repo runner listed" || return 1
}
test_wtr_bulk_label_missing_flagged() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  # the real pool label is "benjis-ci": jobs then also ask for benjis-ci-bulk
  wtr_vars 'CI_RUNNER_JSON="benjis-ci"' > "$d/repos_example-owner_project-a_actions_organization-variables.json"
  wtr_runners slot-1:online:benjis-ci slot-3:online:ci-prod-deploy > "$d/orgs_example-owner_actions_runners.json"
  WTR_SPEC="example-owner/project-a:CI_RUNNER_JSON+bulk,PROD_DEPLOY_RUNNER_JSON" wtr_run "$d"
  assert_eq "$WTR_RC" 1 "exit" || return 1
  assert_contains "$WTR_OUT" "benjis-ci-bulk" "bulk flag" || return 1
}
test_wtr_bulk_check_is_opt_in() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  # a repo whose jobs never ask for the bulk label must not be flagged when no bulk runner is online
  wtr_vars 'CI_RUNNER_JSON="benjis-ci"' > "$d/repos_example-owner_project-a_actions_organization-variables.json"
  wtr_runners slot-1:online:benjis-ci slot-3:online:ci-prod-deploy > "$d/orgs_example-owner_actions_runners.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 0 "exit" || return 1
  assert_not_contains "$WTR_OUT" "benjis-ci-bulk" "no bulk flag" || return 1
}
test_wtr_mobile_mac_unset_wording() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  WTR_SPEC="example-owner/project-a:CI_RUNNER_JSON,MOBILE_MAC_RUNNER_JSON" wtr_run "$d"
  local out=$WTR_OUT rc=$WTR_RC
  assert_eq "$rc" 1 "exit" || return 1
  assert_contains "$out" "MOBILE_MAC_RUNNER_JSON is unset or empty. The iOS job has no YAML fallback" "wording" || return 1
  assert_contains "$out" "does not move to GitHub-hosted" "not hosted" || return 1
}
test_wtr_invalid_json_flagged() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  wtr_vars 'PROD_DEPLOY_RUNNER_JSON={"a":1}' > "$d/repos_example-owner_project-a_actions_variables.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 1 "exit" || return 1
  assert_contains "$WTR_OUT" "is not a JSON string or array of strings" "flag" || return 1
}
test_wtr_api_failure_is_exit2_not_unset() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  rm "$d/orgs_example-owner_actions_runners.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 2 "exit" || return 1
  assert_contains "$WTR_ERR" "NO verdict" "says no verdict" || return 1
  assert_not_contains "$WTR_OUT" "FLAG:" "no false flag" || return 1
  assert_not_contains "$WTR_OUT" "unset" "never says unset" || return 1
}
test_wtr_variable_api_failure_is_exit2() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  rm "$d/repos_example-owner_project-a_actions_organization-variables.json"
  wtr_run "$d"
  assert_eq "$WTR_RC" 2 "exit" || return 1
  assert_not_contains "$WTR_OUT" "NOT SET" "not reported as unset" || return 1
}
test_wtr_only_reads() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  wtr_run "$d"
  local calls; calls=$(cat "$d/calls.log")
  assert_contains "$calls" "api repos/example-owner/project-a/actions/organization-variables" "reads org variables" || return 1
  assert_not_contains "$calls" "-X" "no -X" || return 1
  assert_not_contains "$calls" "--method" "no --method" || return 1
  assert_not_contains "$calls" " -f " "no fields" || return 1
  assert_not_contains "$calls" "--input" "no input" || return 1
  assert_eq "$(grep -vc '^api ' "$d/calls.log")" 0 "only api calls" || return 1
}
test_wtr_only_named_variables_printed() {
  local d; d=$(wtr_dir); wtr_fixture "$d"
  wtr_vars 'PROD_DEPLOY_RUNNER_JSON=["self-hosted","ci-prod-deploy"]' 'SOME_DSN=https://secret.example/1' > "$d/repos_example-owner_project-a_actions_variables.json"
  wtr_run "$d"
  assert_not_contains "$WTR_OUT" "SOME_DSN" "unrelated variable name" || return 1
  assert_not_contains "$WTR_OUT" "secret.example" "unrelated variable value" || return 1
}

echo "-- where-things-run (issue #770)"
run_test test_wtr_healthy_exit0
run_test test_wtr_unset_org_variable_flagged
run_test test_wtr_empty_value_flagged
run_test test_wtr_repo_variable_overrides_org
run_test test_wtr_repo_override_can_fix_org
run_test test_wtr_offline_runner_flagged
run_test test_wtr_no_online_runner_for_label_queues
run_test test_wtr_offline_runner_does_not_satisfy_label
run_test test_wtr_repo_level_runner_counts
run_test test_wtr_bulk_label_missing_flagged
run_test test_wtr_bulk_check_is_opt_in
run_test test_wtr_mobile_mac_unset_wording
run_test test_wtr_invalid_json_flagged
run_test test_wtr_api_failure_is_exit2_not_unset
run_test test_wtr_variable_api_failure_is_exit2
run_test test_wtr_only_reads
run_test test_wtr_only_named_variables_printed
