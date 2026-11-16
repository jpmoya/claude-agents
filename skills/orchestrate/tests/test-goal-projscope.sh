# #736 — goals bound to a GitHub Project: the project's issue items ARE the goal's scope (spec `project:<owner>/<number>`).
# Part (a): grammar, scope rows, pagination, fail-closed reads, goal_eval, goal_name_for, observability of the unreadable read.
# Loaded after test-goal-deliver.sh and test-goal-project.sh (alphabetical): reuses the dg_* sandbox. Prefix gps_ / GPS_.
# Expected values are hand-written from the ticket, never taken from the code under test.
#
# World: project 12 of owner example-owner holds 5 items: project-a#101 (open), project-a#102 (closed), project-b#1 (open),
# a draft item and a pull-request item. Scope = the 3 issues; draft and PR are ignored.
# The fake gh answers `gh api graphql` (the project read) from $DG_BIN/psc/<n>.json and `gh api -i user` (token scopes), and logs
# every graphql call to $DG_BIN/psc/graphql.log. Touch $DG_BIN/psc/fail-<n> (project read exits 1, with a token-shaped string on
# stderr that must never be logged) or $DG_BIN/psc/fail-page2 (only the cursor pages fail).

GPS_SPEC="project:example-owner/12"
GPS_ALIAS="example-owner/project-a:project:12"
GPS_ID="proj-example-owner_12"
GPS_TAB=$(printf '\t')

gps_install_gh() {
  mv "$DG_BIN/gh" "$DG_BIN/gh.base"
  mkdir -p "$DG_BIN/psc"
  cat > "$DG_BIN/gh" <<'GPS_GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd); P="$HERE/psc"
if [ "$1" = api ] && [ "$2" = -i ] && [ "$3" = user ]; then
  if [ -f "$HERE/scope" ]; then printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: gist, project, read:org, repo\r\n\r\n{}\n'
  else printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: gist, read:org, repo\r\n\r\n{}\n'; fi
  exit 0
fi
if [ "$1" = api ] && [ "$2" = graphql ]; then
  printf '%s\n' "$*" >> "$P/graphql.log"
  num=""; cur=""; first=""
  for a in "$@"; do case "$a" in number=*) num=${a#number=} ;; cursor=*) cur=${a#cursor=} ;; first=*) first=${a#first=} ;; esac; done
  [ ! -f "$P/fail-$num" ] || { echo "gh: HTTP 502 token ghp_SECRETSECRET123 rejected" >&2; exit 1; }
  [ -z "$cur" ] || [ ! -f "$P/fail-page2" ] || { echo "gh: HTTP 502" >&2; exit 1; }
  [ -f "$P/$num.json" ] || { echo '{"data":{"repositoryOwner":{"projectV2":null}}}'; exit 0; }
  pg=0; [ -z "$cur" ] || pg=${cur#c}
  jq -c --argjson pg "$pg" --argjson first "${first:-100}" '
    (.pagesize // $first) as $ps
    | (.items | length) as $len
    | .items[($pg * $ps):(($pg + 1) * $ps)] as $slice
    | {data:{repositoryOwner:{projectV2:{title, url, closed,
        items:{pageInfo:{hasNextPage: (($pg + 1) * $ps < $len), endCursor: "c\($pg + 1)"},
          nodes: ($slice | map({type, content: (
            if .type == "ISSUE" then {number, state, stateReason: (.stateReason // null), body: (.body // ""), author: {login: (.author // "gps-author")},
              labels: {nodes: [(.labels // [])[] | {name: .}]}, milestone: (.milestone // null), repository: {nameWithOwner: .repo}}
            elif .type == "REDACTED" then null else {} end)}))}}}}}' "$P/$num.json"
  exit 0
fi
exec "$HERE/gh.base" "$@"
GPS_GH_EOF
  chmod +x "$DG_BIN/gh"
}

# gps_project <number> <title> <closed true|false> <pagesize or ""> <items json array>
gps_project() {
  jq -nc --arg t "$2" --argjson c "$3" --arg ps "$4" --argjson items "$5" --arg n "$1" \
    '{title:$t, url:"https://github.com/orgs/example-owner/projects/\($n)", closed:$c, items:$items} + (if $ps == "" then {} else {pagesize: ($ps|tonumber)} end)' > "$DG_BIN/psc/$1.json"
}
gps_issue_item() {  # <repo> <n> <OPEN|CLOSED> [stateReason]
  jq -nc --arg r "$1" --argjson n "$2" --arg s "$3" --arg sr "${4:-}" \
    '{type:"ISSUE", repo:$r, number:$n, state:$s, stateReason:(if $sr == "" then null else $sr end)}'
}
GPS_DRAFT='{"type":"DRAFT_ISSUE"}'
GPS_PR='{"type":"PULL_REQUEST"}'

gps_world_items() {  # the standard 5 items as a JSON array
  printf '%s\n' "$(gps_issue_item example-owner/project-a 101 OPEN)" "$(gps_issue_item example-owner/project-a 102 CLOSED COMPLETED)" \
    "$GPS_DRAFT" "$GPS_PR" "$(gps_issue_item example-owner/project-b 1 OPEN)" | jq -sc .
}

gps_setup() {
  dg_setup; gps_install_gh; touch "$DG_BIN/scope"
  gps_project 12 "Q4 Delivery" false "" "$(gps_world_items)"
}

# gps_lib '<snippet>' — dg_lib with slog captured to $DG_HOME/slog.log
gps_lib() {
  dg_lib "slog() { printf '%s\\n' \"\$*\" >> \"$DG_HOME/slog.log\"; }; $1"
}

# ---------------------------------------------------------------- AC1: grammar ---------------------------------------------

test_gps_parse_canonical_and_alias() {
  gps_setup
  local rc=0
  gps_lib 'goal_parse project:example-owner/12'
  assert_eq "$DG_RC" "0" "canonical form parses (stderr: $DG_ERR)" || rc=1
  assert_eq "$DG_OUT" "-${GPS_TAB}proj${GPS_TAB}example-owner/12" "canonical: repo -, kind proj, ref owner/number" || rc=1
  gps_lib 'goal_parse example-owner/project-a:project:12'
  assert_eq "$DG_OUT" "-${GPS_TAB}proj${GPS_TAB}example-owner/12" "alias owner/repo:project:<n> = the repo's owner's project <n>" || rc=1
  dg_teardown; return $rc
}

test_gps_parse_malformed_forms_are_refused_naming_the_accepted_forms() {
  gps_setup
  local rc=0 s
  for s in 'project:' 'project:example-owner' 'project:example-owner/abc' 'project:example-owner/12/extra' 'project:/12' \
           'example-owner/project-a:project:' 'example-owner/project-a:project:abc' 'example-owner/project-a:project:1/2'; do
    gps_lib "goal_parse '$s'"
    assert_eq "$DG_RC" "1" "'$s' is malformed (exit 1)" || rc=1
    assert_contains "$DG_ERR" "malformed goal" "'$s': the message says malformed goal" || rc=1
    assert_contains "$DG_ERR" "project:<owner>/<number>" "'$s': the message names the accepted form" || rc=1
  done
  gps_lib 'goal_parse not-a-spec'
  assert_contains "$DG_ERR" "project:<owner>/<number>" "the general malformed-goal message lists the project form" || rc=1
  dg_teardown; return $rc
}

test_gps_goal_id_has_no_leading_dashes() {
  gps_setup
  local rc=0
  gps_lib "goal_id $GPS_SPEC"; assert_eq "$DG_OUT" "$GPS_ID" "canonical id" || rc=1
  gps_lib "goal_id $GPS_ALIAS"; assert_eq "$DG_OUT" "$GPS_ID" "the alias gives the same id" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC2: scope rows -----------------------------------------

test_gps_scope_rows_are_the_three_issue_items() {
  gps_setup
  local rc=0
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_eq "$DG_RC" "0" "scope read exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(printf '%s\n' "$DG_OUT" | sort)" "$(printf 'example-owner/project-a#101\topen\nexample-owner/project-a#102\tclosed\nexample-owner/project-b#1\topen')" \
    "exactly the 3 issue items, draft and PR absent" || rc=1
  gps_lib "goal_scope $GPS_SPEC $GPS_ID"
  assert_eq "$(printf '%s\n' "$DG_OUT" | sort | tr '\n' ' ')" "example-owner/project-a#101 example-owner/project-a#102 example-owner/project-b#1 " "goal_scope lists the refs" || rc=1
  gps_lib "_goal_scope_rows $GPS_ALIAS"
  assert_eq "$(printf '%s\n' "$DG_OUT" | wc -l | tr -d ' ')" "3" "the alias reads the same project" || rc=1
  dg_teardown; return $rc
}

test_gps_scope_rows_full_shape_maps_graphql_values_to_rest_values() {
  gps_setup
  local rc=0 items row
  items=$(printf '%s\n' "$(jq -nc '{type:"ISSUE", repo:"example-owner/project-a", number:7, state:"CLOSED", stateReason:"NOT_PLANNED", author:"jp-author",
      labels:["bug","agent-go"], milestone:{state:"CLOSED", title:"v1.2.3 - Done"}, body:"Depends on example-owner/project-b#9 for starting work"}')" | jq -sc .)
  gps_project 12 "Q4 Delivery" false "" "$items"
  gps_lib "GOAL_SCOPE_FULL=1 _goal_scope_rows $GPS_SPEC $GPS_ID"
  row=$DG_OUT
  # columns: ref, state, labels csv, author, start-gate refs, state_reason, milestone "state|title" (all lower-case, REST values)
  assert_eq "$row" "$(printf 'example-owner/project-a#7\tclosed\tbug,agent-go\tjp-author\texample-owner/project-b#9\tnot_planned\tclosed|v1.2.3 - Done')" "full row (REST-shaped values)" || rc=1
  gps_lib "GOAL_SCOPE_LABELS=1 _goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_eq "$DG_OUT" "$(printf 'example-owner/project-a#7\tclosed\tbug,agent-go')" "labels mode: ref, state, labels" || rc=1
  dg_teardown; return $rc
}

test_gps_item_status_field_never_decides_the_state() {
  gps_setup
  local rc=0 items
  items=$(printf '%s\n' "$(jq -nc '{type:"ISSUE", repo:"example-owner/project-a", number:101, state:"OPEN", status:"Done"}')" | jq -sc .)
  gps_project 12 "Q4 Delivery" false "" "$items"
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_eq "$DG_OUT" "$(printf 'example-owner/project-a#101\topen')" "an open issue on a project item whose Status is Done reads open" || rc=1
  assert_not_contains "$(cat "$DG_BIN/psc/graphql.log")" "Status" "the query does not ask for the Status field" || rc=1
  dg_teardown; return $rc
}

test_gps_business_intelligence_items_are_never_in_scope() {
  gps_setup
  local rc=0 items
  items=$(printf '%s\n' "$(gps_issue_item example-owner/project-a 101 OPEN)" "$(gps_issue_item example-owner/Business-Intelligence 5 OPEN)" | jq -sc .)
  gps_project 12 "Q4 Delivery" false "" "$items"
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_eq "$DG_OUT" "$(printf 'example-owner/project-a#101\topen')" "Business-Intelligence is never part of a goal" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC3: pagination, fail closed -----------------------------

test_gps_more_than_one_page_is_read_completely() {
  gps_setup
  local rc=0
  gps_project 12 "Q4 Delivery" false 2 "$(gps_world_items)"   # 5 items, 2 per page: 3 pages
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_eq "$DG_RC" "0" "paginated read exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(printf '%s\n' "$DG_OUT" | wc -l | tr -d ' ')" "3" "all three issues, across the pages" || rc=1
  assert_eq "$(wc -l < "$DG_BIN/psc/graphql.log" | tr -d ' ')" "3" "one query per page" || rc=1
  dg_teardown; return $rc
}

test_gps_a_failed_page_fails_the_whole_read() {
  gps_setup
  local rc=0
  gps_project 12 "Q4 Delivery" false 2 "$(gps_world_items)"
  touch "$DG_BIN/psc/fail-page2"
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_ne "$DG_RC" "0" "a non-zero gh exit on page 2: the read fails" || rc=1
  assert_eq "$DG_OUT" "" "no partial scope on stdout" || rc=1
  dg_teardown; return $rc
}

test_gps_unreadable_closed_missing_and_redacted_projects_fail_closed() {
  gps_setup
  local rc=0
  touch "$DG_BIN/psc/fail-12"
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_ne "$DG_RC" "0" "gh exits 1: fail closed" || rc=1
  assert_eq "$DG_OUT" "" "no rows" || rc=1
  rm -f "$DG_BIN/psc/fail-12"
  gps_lib "_goal_scope_rows project:example-owner/99 x"
  assert_ne "$DG_RC" "0" "a deleted / unknown project (null): fail closed" || rc=1
  gps_project 12 "Q4 Delivery" true "" "$(gps_world_items)"
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_ne "$DG_RC" "0" "a closed project: fail closed, never an empty or stale scope" || rc=1
  gps_project 12 "Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 101 OPEN)" '{"type":"REDACTED"}' | jq -sc .)"
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_ne "$DG_RC" "0" "an item the token cannot read (redacted): fail closed, never a partial scope" || rc=1
  dg_teardown; return $rc
}

test_gps_the_read_does_not_depend_on_the_mirror_switch() {
  gps_setup
  local rc=0
  gps_lib "GOAL_PROJECTS=0 _goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_eq "$DG_RC" "0" "GOAL_PROJECTS=0 turns the mirror off, not the scope" || rc=1
  assert_eq "$(printf '%s\n' "$DG_OUT" | wc -l | tr -d ' ')" "3" "still 3 rows" || rc=1
  dg_teardown; return $rc
}

test_gps_an_empty_project_reads_as_an_empty_scope_not_an_error() {
  gps_setup
  local rc=0
  gps_project 12 "Q4 Delivery" false "" '[]'
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_eq "$DG_RC" "0" "a readable project with no issue items: rc 0" || rc=1
  assert_eq "$DG_OUT" "" "no rows (callers refuse an empty scope: it is never delivered)" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC4: goal_eval ------------------------------------------

# gps_eval — goal_eval on the project goal with every open ticket stubbed "active"; prints "rc total delivered active"
gps_eval() {
  gps_lib "_goal_ticket_eval() { printf 'active\\tOPEN\\t-\\t-\\n'; }
    report_status_async() { :; }
    goal_eval $GPS_ID $GPS_SPEC; rc=\$?; echo \"\$rc \$GE_TOTAL \$GE_DELIVERED \$GE_ACTIVE\""
}

test_gps_goal_eval_open_while_any_item_is_open_and_delivered_when_all_closed() {
  gps_setup
  local rc=0
  gps_eval
  assert_eq "$DG_OUT" "0 3 1 2" "1 closed of 3: open (2 active)" || rc=1
  gps_project 12 "Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 101 CLOSED COMPLETED)" "$(gps_issue_item example-owner/project-b 1 CLOSED COMPLETED)" | jq -sc .)"
  gps_eval
  assert_eq "$DG_OUT" "0 2 2 0" "all items closed: delivered" || rc=1
  gps_project 12 "Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 101 CLOSED COMPLETED)" "$(gps_issue_item example-owner/project-b 1 CLOSED COMPLETED)" "$(gps_issue_item example-owner/project-b 2 OPEN)" | jq -sc .)"
  gps_eval
  assert_eq "$DG_OUT" "0 3 2 1" "an item added later makes the goal open again" || rc=1
  dg_teardown; return $rc
}

test_gps_goal_eval_an_empty_project_is_not_delivered_and_an_unreadable_one_fails() {
  gps_setup
  local rc=0
  gps_project 12 "Q4 Delivery" false "" '[]'
  gps_eval
  assert_eq "$DG_OUT" "0 0 0 0" "empty scope: total 0, so never delivered (#605 rule)" || rc=1
  touch "$DG_BIN/psc/fail-12"
  gps_eval
  assert_eq "$(printf '%s' "$DG_OUT" | cut -d' ' -f1)" "1" "unreadable project: goal_eval exits 1 (the caller keeps the goal as it was)" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC5 (part): goal_name_for -------------------------------

test_gps_goal_name_is_the_project_title_and_exits_1_when_github_cannot_say() {
  gps_setup
  local rc=0
  gps_lib "goal_name_for $GPS_SPEC"
  assert_eq "$DG_OUT" "Q4 Delivery" "the project's title" || rc=1
  gps_lib "goal_name_for $GPS_ALIAS"
  assert_eq "$DG_OUT" "Q4 Delivery" "alias: the same title" || rc=1
  touch "$DG_BIN/psc/fail-12"
  gps_lib "goal_name_for $GPS_SPEC"
  assert_eq "$DG_RC" "1" "unreadable: exit 1" || rc=1
  assert_eq "$DG_OUT" "" "and no name" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC14: observability ------------------------------------

test_gps_an_unreadable_project_is_captured_with_release_environment_and_route_and_no_secret() {
  gps_setup
  local rc=0 log ev
  touch "$DG_BIN/psc/fail-12"
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  log=$(cat "$DG_HOME/slog.log" 2>/dev/null)
  assert_contains "$log" "project scope" "slog names the failed read" || rc=1
  assert_contains "$log" "example-owner/12" "slog names the project (owner/number only)" || rc=1
  assert_contains "$log" "release=" "slog carries the release tag" || rc=1
  assert_contains "$log" "environment=" "slog carries the environment tag" || rc=1
  assert_contains "$log" "route=goal-project-scope" "slog carries the route tag" || rc=1
  assert_not_contains "$log$DG_ERR" "ghp_SECRETSECRET123" "no token in the log or on stderr" || rc=1
  ev=$(cat "$DG_HOME/logs/pipeline/events.jsonl" 2>/dev/null | grep goal-project-scope | head -1)
  assert_ne "$ev" "" "an error event row is recorded" || rc=1
  assert_eq "$(printf '%s' "$ev" | jq -r '[.event, .level, .route, (.release | length > 0), (.environment | length > 0)] | join(",")')" "error,error,goal-project-scope,true,true" \
    "event: error with route, release and environment" || rc=1
  assert_not_contains "$ev" "ghp_SECRETSECRET123" "no token in the event" || rc=1
  dg_teardown; return $rc
}

for t in test_gps_parse_canonical_and_alias \
         test_gps_parse_malformed_forms_are_refused_naming_the_accepted_forms \
         test_gps_goal_id_has_no_leading_dashes \
         test_gps_scope_rows_are_the_three_issue_items \
         test_gps_scope_rows_full_shape_maps_graphql_values_to_rest_values \
         test_gps_item_status_field_never_decides_the_state \
         test_gps_business_intelligence_items_are_never_in_scope \
         test_gps_more_than_one_page_is_read_completely \
         test_gps_a_failed_page_fails_the_whole_read \
         test_gps_unreadable_closed_missing_and_redacted_projects_fail_closed \
         test_gps_the_read_does_not_depend_on_the_mirror_switch \
         test_gps_an_empty_project_reads_as_an_empty_scope_not_an_error \
         test_gps_goal_eval_open_while_any_item_is_open_and_delivered_when_all_closed \
         test_gps_goal_eval_an_empty_project_is_not_delivered_and_an_unreadable_one_fails \
         test_gps_goal_name_is_the_project_title_and_exits_1_when_github_cannot_say \
         test_gps_an_unreadable_project_is_captured_with_release_environment_and_route_and_no_secret; do
  run_test "$t"
done
