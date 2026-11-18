# JP (2026-11-18, #697): ONE concept. The goal registry (GitHub issues labelled delivery-goal, created by deliver.sh) is the single source
# of truth and the status page lists exactly the registered goals, each under its registry name: an open "Goal: ..." GitHub Project with no
# registry issue (the orphan project 36 behind #697, "Client self-service portal") is never a row, and a goal whose project still carries an
# old title ("scheduler: staff feedback") shows the registry's name ("Benji's Ops Tool feedback").
#   grl_names_*   goal-lib.sh: the registry issue title becomes the goal's `name` (prefix stripped, empty when it only repeats the spec),
#                 and goal_queue_save carries it into goalqueue.json
#   grl_list_*    build-runs-json.py `goals`: ids on the page == ids the registry lists (open, queued, recently closed), names from the registry
# Loaded after test-goal-deliver.sh (dg_* sandbox). Prefix grl_ / GRL_. Expected values are hand-written, never taken from the code.

GRL_PROJ="https://github.com/users/example-owner/projects"

# grl_issue <n> <state> <title> <block json> [labels csv] — a registry issue as GitHub returns it
grl_issue() {
  jq -nc --argjson n "$1" --arg st "$2" --arg t "$3" --argjson b "$4" --arg lb "${5:-}" --arg now "$DG_NOW" '
    {number:$n, state:$st, title:$t, labels:(["delivery-goal"] + ($lb | split(",") | map(select(length > 0))) | map({name:.})),
     body:("Goal: x\n\n```json\n" + ($b | tojson) + "\n```\n"), created_at:$now, updated_at:$now,
     closed_at:(if $st == "closed" then $now else null end)}'
}

# grl_world — the registry of the incident: ops feedback (#537, hand-renamed), sales feedback (#538, title = its spec), a label goal whose
# title carries a doubled prefix (#759), and a delivered milestone goal (#618). Sets GRL_REG (the registry's goal objects) and GRL_SAVE.
grl_world() {
  dg_setup
  GRL_ISSUES=$(jq -sc '.' \
    <(grl_issue 537 open "Goal: Benji's Ops Tool feedback" '{"v":1,"id":"ex_ops-fb-feedback","spec":"example-owner/ops:feedback","host":"","title":"ops: staff feedback","project":{"owner":"example-owner","number":37,"url":"'"$GRL_PROJ"'/37"}}') \
    <(grl_issue 538 open "Goal: example-owner/sales:feedback" '{"v":1,"id":"ex_sales-fb-feedback","spec":"example-owner/sales:feedback","host":"","title":"sales: staff feedback"}') \
    <(grl_issue 759 open "Goal: Goal: CD release hardening" '{"v":1,"id":"label-goal__CD","label":"goal: CD","title":"CD release hardening","repos":["example-owner/ops"],"host":""}' goal-queued) \
    <(grl_issue 618 closed "Goal: example-owner/ops:milestone:Client portal V1" '{"v":1,"id":"ex_ops-ms-9","spec":"example-owner/ops:milestone:9","host":"","title":"ops: Client portal V1"}'))
  export GRL_ISSUES
  dg_lib 'printf "%s" "$GRL_ISSUES" | jq -c "$_GOAL_ISSUE_JQ"" map(goal_of)" > "$PIPE/grl-registry.json"; goal_queue_save "$(cat "$PIPE/grl-registry.json")"'
}

# grl_page — the status page's `goals` list for the sandbox pipe dir
grl_page() { PATH="$PATH" python3 "$DG_SKILL/build-runs-json.py" "" "$DG_HOME/r.jsonl" "$DG_PIPE" goals </dev/null 2>/dev/null; }

test_grl_names_registry_issue_title_is_the_goal_name() {
  grl_world
  local rc=0 q="$DG_PIPE/goalqueue.json"
  assert_eq "$(jq -r '.open[] | select(.id == "ex_ops-fb-feedback") | .name' "$q")" "Benji's Ops Tool feedback" "a hand-named registry goal keeps its name" || rc=1
  assert_eq "$(jq -r '.open[] | select(.id == "ex_sales-fb-feedback") | "[\(.name)] \(.title)"' "$q")" "[] sales: staff feedback" "a title that only repeats the spec gives no name: the block's title stands" || rc=1
  assert_eq "$(jq -r '(.open + .queued)[] | select(.id == "label-goal__CD") | .name' "$q")" "CD release hardening" "a doubled Goal: prefix is stripped" || rc=1
  assert_eq "$(jq -r '.recent[] | select(.id == "ex_ops-ms-9") | .id' "$q")" "ex_ops-ms-9" "the recently closed goal is in the registry's list" || rc=1
  dg_teardown; return $rc
}

test_grl_list_the_status_page_lists_exactly_the_registered_goals_under_registry_names() {
  grl_world
  local rc=0 out
  # what the old page showed: both projects titled like the stale name, an unregistered open project, a local cache of the renamed goal
  jq -nc --arg p "$GRL_PROJ" '{owner:"example-owner", projects:[
      {number:36,title:"Goal: ops: staff feedback",url:($p+"/36"),closed:false,closed_seen:null},
      {number:37,title:"Goal: ops: staff feedback",url:($p+"/37"),closed:false,closed_seen:null},
      {number:50,title:"Goal: Client self-service portal",url:($p+"/50"),closed:false,closed_seen:null}]}' > "$DG_PIPE/goalprojects.json"
  jq -nc --arg p "$GRL_PROJ" '{id:"ex_ops-fb-feedback", host:"mac", spec:"example-owner/ops:feedback", state:"active", title:"ops: staff feedback", project:{owner:"example-owner",number:37,url:($p+"/37")}}' > "$DG_PIPE/goal-ex_ops-fb-feedback.json"
  jq -nc '{id:"ghost-goal", host:"mac", spec:"example-owner/ops#77", state:"active"}' > "$DG_PIPE/goal-ghost-goal.json"
  out=$(grl_page)
  assert_eq "$(printf '%s' "$out" | jq -c '[.[].id] | sort')" '["ex_ops-fb-feedback","ex_ops-ms-9","ex_sales-fb-feedback","label-goal__CD"]' \
    "the page lists exactly the registry's open, queued and recently closed goals: no project row, no goal the registry never heard of" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id == "ex_ops-fb-feedback") | .title')" "Benji's Ops Tool feedback" "the live goal shows its registry name, not its project's old title" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id == "ex_ops-fb-feedback") | .url')" "$GRL_PROJ/37" "its project is only the link" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id == "ex_sales-fb-feedback") | .title')" "sales: staff feedback" "a goal with no registry name keeps its block title" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id == "ex_ops-ms-9") | .state')" "delivered" "a registered milestone goal is listed like any other" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select((.title // "") | test("Client self-service|scheduler"))] | length')" "0" "neither the unregistered project nor the stale title" || rc=1
  dg_teardown; return $rc
}

test_grl_list_equals_the_registry_whatever_the_projects_hold() {
  grl_world
  local rc=0 out reg page
  rm -f "$DG_PIPE/goalprojects.json"
  out=$(grl_page)
  reg=$(jq -c '[(.open + .queued + .recent)[].id] | unique' "$DG_PIPE/goalqueue.json")
  page=$(printf '%s' "$out" | jq -c '[.[].id] | unique')
  assert_eq "$page" "$reg" "page ids == goalqueue.json (registry) ids" || rc=1
  assert_eq "$(jq -c '[.[] | select(.st != "delivered" and .st != "stopped") | .id] | sort' "$DG_PIPE/grl-registry.json")" \
    "$(printf '%s' "$out" | jq -c '[.[] | select(.state != "delivered" and .state != "stopped") | .id] | sort')" "open registry goals == open rows on the page" || rc=1
  dg_teardown; return $rc
}

test_grl_list_a_host_that_never_synced_keeps_its_local_goal_rows() {
  dg_setup
  local rc=0 out
  jq -nc '{id:"g1", host:"mac", spec:"example-owner/ops#7", state:"active"}' > "$DG_PIPE/goal-g1.json"
  out=$(grl_page)
  assert_eq "$(printf '%s' "$out" | jq -c '[.[].id]')" '["g1"]' "no goalqueue.json: nothing to compare with, the local rows stay" || rc=1
  dg_teardown; return $rc
}

for t in test_grl_names_registry_issue_title_is_the_goal_name \
         test_grl_list_the_status_page_lists_exactly_the_registered_goals_under_registry_names \
         test_grl_list_equals_the_registry_whatever_the_projects_hold \
         test_grl_list_a_host_that_never_synced_keeps_its_local_goal_rows; do
  run_test "$t"
done
