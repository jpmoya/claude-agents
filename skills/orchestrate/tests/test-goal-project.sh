# Per-goal GitHub Project mirror (goal-project.sh). Loaded after test-goal-deliver.sh (dg_* sandbox: dg_setup, dg_run, dg_reg_file_for ...).
# The fake gh wraps the stateful `gh api` fake and adds `gh project ...` (state in $DG_BIN/proj) and the scope header of `gh api -i user`
# (present only when $DG_BIN/scope exists). touch $DG_BIN/fail-create makes project create/copy fail. Expected values are hand-written.
# World (see test-goal-deliver.sh): ms-12 scope = {project-a#101 open, project-a#102 closed}; the PR 103 is never in scope.

gp_install_gh() {
  mv "$DG_BIN/gh" "$DG_BIN/gh.base"
  mkdir -p "$DG_BIN/proj"; echo '[]' > "$DG_BIN/proj/projects.json"
  cat > "$DG_BIN/gh" <<'GP_GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd); P="$HERE/proj"
if [ "$1" = api ] && [ "$2" = -i ] && [ "$3" = user ]; then
  printf '%s\n' "$*" >> "$HERE/gh-calls.log"
  if [ -f "$HERE/scope" ]; then printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: gist, project, read:org, repo, workflow\r\n\r\n{}\n'
  else printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: gist, read:org, repo, workflow\r\n\r\n{}\n'; fi
  exit 0
fi
if [ "$1" = api ] && [ "$2" = graphql ]; then   # #402: items listing = one graphql query; project number arrives as a "number=N" or "n=N" arg (-f or -F)
  printf '%s\n' "$*" >> "$P/graphql.log"; num=""
  for a in "$@"; do case "$a" in number=[0-9]*) num=${a#number=} ;; n=[0-9]*) num=${a#n=} ;; esac; done   # accept either variable name (-f/-F)
  [ -n "$num" ] && [ -f "$P/items-$num.json" ] || { echo "fake gh: graphql without number=N or n=N" >&2; exit 1; }
  jq -c '{data:{repositoryOwner:{projectV2:{items:{pageInfo:{hasNextPage:false, endCursor:null}, nodes: map({id:.id, fieldValueByName:(if (.status // "") == "" then null else {name:.status} end), content:(if .content.repository == null then {} else {number:.content.number, repository:{nameWithOwner:.content.repository}, labels:{nodes:[(.labels // [])[] | {name:.}]}} end)})}}}}}' "$P/items-$num.json"
  exit 0
fi
if [ "$1" != project ]; then exec "$HERE/gh.base" "$@"; fi
echo "$*" >> "$P/calls.log"
sub=$2; shift 2
num=""; title=""; url=""; id=""; opt=""; undo=0
case "${1:-}" in [0-9]*) num=$1; shift ;; esac
while [ $# -gt 0 ]; do
  case "$1" in
    --title) title=$2; shift ;; --url) url=$2; shift ;; --id) id=$2; shift ;; --single-select-option-id) opt=$2; shift ;;
    --undo) undo=1 ;; --owner|--source-owner|--target-owner|--repo|--description|--format|-L|--project-id|--field-id) shift ;;
  esac
  shift
done
case "$sub" in
  list) jq -c '{projects: .}' "$P/projects.json" ;;
  copy|create)
    [ -f "$HERE/fail-create" ] && { echo "gh: forbidden" >&2; exit 1; }
    n=$(( $(jq 'length' "$P/projects.json") + 1 ))
    jq -c --argjson n "$n" --arg t "$title" '. + [{number:$n, title:$t, closed:false, id:"PVT_\($n)", url:"https://github.com/users/example-owner/projects/\($n)"}]' "$P/projects.json" > "$P/p.tmp" && mv "$P/p.tmp" "$P/projects.json"
    echo '[]' > "$P/items-$n.json"
    jq -c --argjson n "$n" '.[] | select(.number == $n)' "$P/projects.json" ;;
  view) jq -c --argjson n "$num" '.[] | select(.number == $n)' "$P/projects.json" ;;
  edit|link) echo '{}' ;;
  field-list) echo '{"fields":[{"id":"F_STATUS","name":"Status","options":[{"id":"o1","name":"Todo"},{"id":"o2","name":"In Progress"},{"id":"o3","name":"Done"}]}]}' ;;
  item-list) jq -c '{items: .}' "$P/items-$num.json" ;;
  item-add)
    repo=$(printf '%s' "$url" | sed -E 's#https://github.com/([^/]+/[^/]+)/issues/.*#\1#'); n=${url##*/}
    jq -c --arg r "$repo" --argjson n "$n" '. + [{id:"I_\(length + 1)", status:"", labels:[], content:{repository:$r, number:$n}}]' "$P/items-$num.json" > "$P/i.tmp" && mv "$P/i.tmp" "$P/items-$num.json"
    echo '{}' ;;
  item-edit)
    case "$opt" in o1) name=Todo ;; o2) name="In Progress" ;; *) name=Done ;; esac
    for f in "$P"/items-*.json; do jq -c --arg i "$id" --arg s "$name" 'map(if .id == $i then .status = $s else . end)' "$f" > "$P/i.tmp" && mv "$P/i.tmp" "$f"; done ;;
  close)
    jq -c --argjson n "$num" --argjson c "$([ "$undo" = 1 ] && echo false || echo true)" 'map(if .number == $n then .closed = $c else . end)' "$P/projects.json" > "$P/p.tmp" && mv "$P/p.tmp" "$P/projects.json"
    echo '{}' ;;
  *) echo "fake gh: unsupported project $sub" >&2; exit 1 ;;
esac
GP_GH_EOF
  chmod +x "$DG_BIN/gh"
}

gp_setup() { dg_setup; gp_install_gh; touch "$DG_BIN/scope"; }
gp_items() { jq -r --argjson n "$1" '.[] | "\(.content.repository)#\(.content.number)=\(.status)"' "$DG_BIN/proj/items-$1.json" 2>/dev/null | sort | tr '\n' ' '; }
gp_nproj() { jq 'length' "$DG_BIN/proj/projects.json"; }

test_gp_register_creates_project_adds_tickets_and_records_it() {
  gp_setup
  local rc=0 f blk
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(gp_nproj)" "1" "one project created" || rc=1
  assert_eq "$(jq -r '.[0].title' "$DG_BIN/proj/projects.json")" "Goal: $DG_SPEC_MS" "title = Goal: + the readable goal name" || rc=1
  assert_contains "$(cat "$DG_BIN/proj/calls.log")" "copy 1 " "created by copying the template project 1" || rc=1
  assert_eq "$(gp_items 1)" "example-owner/project-a#101=Todo example-owner/project-a#102=Done " "both tickets added (not the PR), the closed one is Done" || rc=1
  f=$(dg_reg_file_for "$DG_ID_MS"); blk=$(dg_block "$f")
  assert_eq "$(printf '%s' "$blk" | jq -r '.project.number')" "1" "registry block records the project number" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r '.project.url')" "https://github.com/users/example-owner/projects/1" "and its url" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r '.spec')" "$DG_SPEC_MS" "rest of the block untouched" || rc=1
  dg_teardown; return $rc
}

test_gp_project_command_is_idempotent_and_mirrors_status() {
  gp_setup
  local rc=0 adds
  dg_run "$DG_SPEC_MS"
  adds=$(grep -c '^item-add' "$DG_BIN/proj/calls.log")
  # 101 is picked up by the pipeline: label agent-in-progress shows on the project item
  jq -c 'map(if .content.number == 101 then .labels = ["agent-in-progress"] else . end)' "$DG_BIN/proj/items-1.json" > "$DG_BIN/proj/x" && mv "$DG_BIN/proj/x" "$DG_BIN/proj/items-1.json"
  dg_run project "$DG_ID_MS"; assert_eq "$DG_RC" "0" "project <id> exits 0 (stderr: $DG_ERR)" || rc=1
  assert_contains "$DG_OUT" "https://github.com/users/example-owner/projects/1" "prints the project url" || rc=1
  assert_eq "$(grep -c '^item-add' "$DG_BIN/proj/calls.log")" "$adds" "no item added twice" || rc=1
  assert_eq "$(gp_nproj)" "1" "no second project" || rc=1
  assert_eq "$(gp_items 1)" "example-owner/project-a#101=In Progress example-owner/project-a#102=Done " "Status follows the ticket" || rc=1
  dg_teardown; return $rc
}

test_gp_stopped_goal_closes_its_project_not_the_registry_row() {
  gp_setup
  local rc=0
  dg_run "$DG_SPEC_MS"; dg_run stop "$DG_ID_MS"
  dg_run project "$DG_ID_MS"; assert_eq "$DG_RC" "0" "project on a stopped goal exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(jq -r '.[0].closed' "$DG_BIN/proj/projects.json")" "true" "project closed" || rc=1
  assert_eq "$(jq -r '.[0].title' "$DG_BIN/proj/projects.json")" "Goal: $DG_SPEC_MS" "not deleted" || rc=1
  dg_run resume "$DG_ID_MS"; dg_run project "$DG_ID_MS"
  assert_eq "$(jq -r '.[0].closed' "$DG_BIN/proj/projects.json")" "false" "reopened with the goal" || rc=1
  dg_teardown; return $rc
}

test_gp_binds_existing_project_with_the_same_title() {
  gp_setup
  local rc=0
  jq -nc --arg t "Goal: $DG_SPEC_MS" '[{number:7, title:$t, closed:false, id:"PVT_7", url:"https://github.com/users/example-owner/projects/7"}]' > "$DG_BIN/proj/projects.json"
  echo '[]' > "$DG_BIN/proj/items-7.json"
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "register exits 0" || rc=1
  assert_eq "$(gp_nproj)" "1" "no duplicate project" || rc=1
  assert_eq "$(dg_block "$(dg_reg_file_for "$DG_ID_MS")" | jq -r '.project.number')" "7" "bound to the existing project" || rc=1
  assert_eq "$(gp_items 7)" "example-owner/project-a#101=Todo example-owner/project-a#102=Done " "its items synced" || rc=1
  dg_teardown; return $rc
}

test_gp_register_joins_the_project_that_already_holds_all_its_tickets() {
  gp_setup
  local rc=0
  jq -nc '[{number:4, title:"Goal: The bigger goal", closed:false, id:"PVT_4", url:"https://github.com/users/example-owner/projects/4"}]' > "$DG_BIN/proj/projects.json"
  jq -nc '[{id:"I_1", status:"Todo", labels:[], content:{repository:"example-owner/project-a", number:101}},{id:"I_2", status:"Todo", labels:[], content:{repository:"example-owner/project-a", number:102}}]' > "$DG_BIN/proj/items-4.json"
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(gp_nproj)" "1" "a slice of a bigger goal gets no project of its own" || rc=1
  assert_eq "$(dg_block "$(dg_reg_file_for "$DG_ID_MS")" | jq -r '.project.number')" "4" "it is bound to the bigger goal's project" || rc=1
  dg_teardown; return $rc
}

test_gp_project_command_binds_but_never_creates_for_existing_goals() {
  gp_setup
  local rc=0
  dg_run "$DG_SPEC_MS" --now   # create path: project 1
  # a goal registered before projects existed: drop the binding, leave one matching project with 2 of its 2 tickets
  local f blk; f=$(dg_reg_file_for "$DG_ID_MS"); blk=$(dg_block "$f" | jq -c 'del(.project)')
  jq --arg b "$(printf 'Goal: %s\n\n```json\n%s\n```\n' "$DG_SPEC_MS" "$blk")" '.body = $b' "$f" > "$DG_BIN/x" && mv "$DG_BIN/x" "$f"
  jq -nc '[{number:4, title:"Goal: Some human title", closed:false, id:"PVT_4", url:"https://github.com/users/example-owner/projects/4"}]' > "$DG_BIN/proj/projects.json"
  jq -nc '[{id:"I_1", status:"Todo", labels:[], content:{repository:"example-owner/project-a", number:101}},{id:"I_2", status:"Todo", labels:[], content:{repository:"example-owner/project-a", number:102}}]' > "$DG_BIN/proj/items-4.json"
  dg_run project "$DG_ID_MS"; assert_eq "$DG_RC" "0" "project exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(gp_nproj)" "1" "no project created for an existing goal" || rc=1
  assert_eq "$(dg_block "$(dg_reg_file_for "$DG_ID_MS")" | jq -r '.project.number')" "4" "bound by items to the existing project" || rc=1
  dg_teardown; return $rc
}

test_gp_brief_names_the_bound_project() {
  gp_setup
  local rc=0
  dg_run "$DG_SPEC_MS" --now; assert_eq "$DG_RC" "0" "register --now (stderr: $DG_ERR)" || rc=1
  dg_wait_claude 1
  assert_contains "$(cat "$(dg_last_claude_dir)/argv")" "https://github.com/users/example-owner/projects/1" "the lead's brief names its project" || rc=1
  dg_teardown; return $rc
}

test_gp_without_project_scope_nothing_runs_and_register_succeeds() {
  gp_setup; rm -f "$DG_BIN/scope"
  local rc=0
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "register exits 0 without the scope" || rc=1
  assert_eq "$(gp_nproj)" "0" "no project created" || rc=1
  assert_eq "$(dg_block "$(dg_reg_file_for "$DG_ID_MS")" | jq -r '.project // "none"')" "none" "no project in the block" || rc=1
  dg_run project "$DG_ID_MS"; assert_ne "$DG_RC" "0" "the explicit command says why it cannot run" || rc=1
  assert_contains "$DG_ERR" "project scope" "and names the missing scope" || rc=1
  dg_teardown; return $rc
}

test_gp_project_failure_never_fails_the_goal() {
  gp_setup; touch "$DG_BIN/fail-create"
  local rc=0
  dg_run "$DG_SPEC_MS" --now; assert_eq "$DG_RC" "0" "register --now exits 0 though project create fails (stderr: $DG_ERR)" || rc=1
  assert_eq "$(dg_reg_count)" "1" "registry issue written" || rc=1
  assert_eq "$(gp_nproj)" "0" "no project" || rc=1
  assert_file_exists "$DG_PIPE/goal-$DG_ID_MS.pid" "goal launched" || rc=1
  dg_teardown; return $rc
}

test_gp_status_page_link_prefers_the_project() {
  local rc=0 d out
  d=$(mktemp -d "${TMPDIR:-/tmp}/gp-pipe.XXXXXX")
  jq -nc '{id:"g1", host:"mac", spec:"o/r#4", state:"active", project:{owner:"x",number:3,url:"https://github.com/users/x/projects/3"}}' > "$d/goal-g1.json"
  jq -nc '{id:"g2", host:"mac", spec:"o/r#4", state:"active", project:{owner:"x",number:3,url:"https://evil.com/users/x/projects/3"}}' > "$d/goal-g2.json"
  jq -nc '{id:"g3", host:"mac", spec:"o/r#4", state:"active"}' > "$d/goal-g3.json"
  out=$(python3 "$DG_SKILL/build-runs-json.py" "" "$d/runs.jsonl" "$d" goals </dev/null 2>/dev/null)
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id == "g1") | .url')" "https://github.com/users/x/projects/3" "project url wins" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id == "g2") | .url')" "https://github.com/o/r/issues/4" "a non-GitHub project url is ignored, fallback link" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id == "g3") | .url')" "https://github.com/o/r/issues/4" "no project: ticket link as before" || rc=1
  rm -rf "$d"; return $rc
}

test_gp_new_project_appears_on_the_status_page_without_manual_steps() {
  gp_setup
  local rc=0 out
  jq -nc '[{number:3, title:"Goal: Brand new", closed:false, id:"PVT_3", url:"https://github.com/users/example-owner/projects/3"},
           {number:4, title:"Goal: Done one", closed:true, id:"PVT_4", url:"https://github.com/users/example-owner/projects/4"},
           {number:5, title:"Old", closed:true, id:"PVT_5", url:"https://github.com/users/example-owner/projects/5"},
           {number:6, title:"quoting-tool: v1.35.0 - Sales Workflow 2.0: Won/Lost stages", closed:false, id:"PVT_6", url:"https://github.com/users/example-owner/projects/6"}]' > "$DG_BIN/proj/projects.json"
  jq -nc '{owner:"example-owner", projects:[{number:5,title:"Old",url:"https://github.com/users/example-owner/projects/5",closed:true,closed_seen:"2020-01-01T00:00:00Z"}]}' > "$DG_PIPE/goalprojects.json"
  dg_lib 'goal_project_refresh_list'; assert_eq "$DG_RC" "0" "refresh exits 0 (stderr: $DG_ERR)" || rc=1
  out=$(PATH="$PATH" python3 "$DG_SKILL/build-runs-json.py" "" "$DG_HOME/r.jsonl" "$DG_PIPE" goals </dev/null 2>/dev/null)
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id == "project-3") | "\(.state) \(.title) \(.url)"')" "queued Brand new https://github.com/users/example-owner/projects/3" "an open project with no goal is a not-started row linking to the project" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id == "project-4") | .state')" "delivered" "a freshly closed project is recently closed" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.id == "project-5")] | length')" "0" "a project closed long ago is not listed" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.id == "project-6")] | length')" "0" "a release-milestone project is not a goal row" || rc=1
  # goals are the projects: a bound goal gives its project row state/host/priority; an unbound goal is not a row
  jq -nc '{id:"g1", host:"mac", spec:"o/r#5", state:"waiting_jp", priority:2, project:{owner:"x",number:3,url:"https://github.com/users/example-owner/projects/3"}}' > "$DG_PIPE/goal-g1.json"
  jq -nc '{id:"g2", host:"mac", spec:"o/r#6", state:"active", priority:1}' > "$DG_PIPE/goal-g2.json"
  out=$(PATH="$PATH" python3 "$DG_SKILL/build-runs-json.py" "" "$DG_HOME/r.jsonl" "$DG_PIPE" goals </dev/null 2>/dev/null)
  assert_eq "$(printf '%s' "$out" | jq -r '.[] | select(.id == "project-3") | "\(.state) \(.host) \(.priority)"')" "waiting_jp mac 2" "the project row carries its goal's state, host and priority" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '[.[] | select(.id == "g1" or .id == "g2")] | length')" "0" "ticket goals are not rows of their own" || rc=1
  # nothing manual: the registry has no goal for it
  assert_eq "$(dg_reg_count)" "0" "no registry goal needed" || rc=1
  dg_teardown; return $rc
}

test_gp_gh_project_and_graphql_only_in_goal_project_sh() {
  local rc=0 f hits
  for f in "$DG_SKILL"/*.sh; do
    [ "$(basename "$f")" != goal-project.sh ] || continue
    case "$(basename "$f")" in deliver.sh|goal-lib.sh|supervisor.sh|scan-backlog.sh) ;; *) continue ;; esac
    hits=$(grep -vE '^[[:space:]]*#' "$f" | grep -Ei 'graphql|gh project' || true)
    assert_eq "$hits" "" "$(basename "$f"): no gh project / GraphQL call outside goal-project.sh" || rc=1
  done
  assert_ne "$(grep -c 'gh project' "$DG_SKILL/goal-project.sh")" "0" "goal-project.sh is where they live" || rc=1
  return $rc
}

for t in test_gp_register_creates_project_adds_tickets_and_records_it test_gp_project_command_is_idempotent_and_mirrors_status \
         test_gp_stopped_goal_closes_its_project_not_the_registry_row test_gp_project_command_binds_but_never_creates_for_existing_goals test_gp_brief_names_the_bound_project test_gp_binds_existing_project_with_the_same_title test_gp_register_joins_the_project_that_already_holds_all_its_tickets \
         test_gp_without_project_scope_nothing_runs_and_register_succeeds test_gp_project_failure_never_fails_the_goal \
         test_gp_status_page_link_prefers_the_project test_gp_new_project_appears_on_the_status_page_without_manual_steps test_gp_gh_project_and_graphql_only_in_goal_project_sh; do
  run_test "$t"
done
