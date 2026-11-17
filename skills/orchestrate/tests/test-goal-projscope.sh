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
  [ ! -f "$HERE/noscope" ] || { echo "gh: INSUFFICIENT_SCOPES: your token has not been granted the required scopes" >&2; exit 1; }
  printf '%s\n' "$*" >> "$P/graphql.log"
  num=""; cur=""; first=""
  for a in "$@"; do case "$a" in number=*) num=${a#number=} ;; cursor=*) cur=${a#cursor=} ;; first=*) first=${a#first=} ;; esac; done
  [ ! -f "$P/fail-$num" ] || { echo "gh: HTTP 502 token ghp_SECRETSECRET123 rejected" >&2; exit 1; }
  [ -z "$cur" ] || [ ! -f "$P/fail-page2" ] || { echo "gh: HTTP 502" >&2; exit 1; }
  [ -f "$P/$num.json" ] || { echo '{"data":{"repositoryOwner":{"projectV2":null}}}'; exit 0; }
  pg=0; [ -z "$cur" ] || pg=${cur#c}
  nc=false; [ ! -f "$P/no-cursor" ] || nc=true
  jq -c --argjson pg "$pg" --argjson first "${first:-100}" --argjson nc "$nc" '
    (.pagesize // $first) as $ps
    | (.items | length) as $len
    | .items[($pg * $ps):(($pg + 1) * $ps)] as $slice
    | {data:{repositoryOwner:{projectV2:{title, url, closed,
        items:{pageInfo:{hasNextPage: (($pg + 1) * $ps < $len), endCursor: (if $nc then null else "c\($pg + 1)" end)},
          nodes: ($slice | map({type, content: (
            if .type == "ISSUE" then {number, state, stateReason: (.stateReason // null), body: (.body // ""), author: {login: (.author // "gps-author")},
              labels: {nodes: [(.labels // [])[] | {name: .}]}, milestone: (.milestone // null), repository: {nameWithOwner: .repo}}
            elif .type == "REDACTED" then null else {} end)}))}}}}}' "$P/$num.json"
  exit 0
fi
if [ "$1" = project ]; then   # the mirror's calls: logged, answered, never needed by a project goal
  echo "$*" >> "$P/project-calls.log"
  case "$2" in
    list) if [ -f "$P/list.json" ]; then jq -c '{projects: .}' "$P/list.json"; else echo '{"projects":[{"number":12,"title":"Goal: Q4 Delivery","closed":false}]}'; fi ;;
    *) echo '{}' ;;
  esac
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
  # control: the same 3-page fixture reads completely when no page fails
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_eq "$(printf '%s\n' "$DG_OUT" | wc -l | tr -d ' ')" "3" "control: without a failing page all 3 issues come back" || rc=1
  : > "$DG_BIN/psc/graphql.log"
  touch "$DG_BIN/psc/fail-page2"
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_ne "$DG_RC" "0" "a non-zero gh exit on page 2: the read fails" || rc=1
  assert_eq "$DG_OUT" "" "no partial scope on stdout (page 1 had rows)" || rc=1
  assert_eq "$(grep -vc 'cursor=' "$DG_BIN/psc/graphql.log" | tr -d ' ')" "1" "page 1 was requested (and succeeded)" || rc=1
  assert_eq "$(grep -c 'cursor=c1' "$DG_BIN/psc/graphql.log" | tr -d ' ')" "1" "page 2 was requested: the failure is mid-pagination" || rc=1
  assert_contains "$(cat "$DG_HOME/slog.log")" "gh exit 1" "the failed page is logged" || rc=1
  dg_teardown; return $rc
}

# gps_fail_case <label> — each fail-closed condition in its own test; the healthy project is read first as a control
gps_control_read() {
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_eq "$(printf '%s\n' "$DG_OUT" | wc -l | tr -d ' ')" "3" "control: the healthy project reads 3 issues" || return 1
  : > "$DG_HOME/slog.log"
}

test_gps_a_page_that_has_more_but_no_cursor_fails_closed() {
  gps_setup
  local rc=0
  gps_project 12 "Q4 Delivery" false 2 "$(gps_world_items)"
  gps_control_read || rc=1
  touch "$DG_BIN/psc/no-cursor"   # page 1 says hasNextPage true and gives no endCursor
  : > "$DG_BIN/psc/graphql.log"
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_ne "$DG_RC" "0" "more items promised but no cursor: fail closed, not a silent end" || rc=1
  assert_eq "$DG_OUT" "" "no partial scope" || rc=1
  assert_eq "$(wc -l < "$DG_BIN/psc/graphql.log" | tr -d ' ')" "1" "only page 1 was requested" || rc=1
  assert_contains "$(cat "$DG_HOME/slog.log")" "gives no cursor" "logged" || rc=1
  dg_teardown; return $rc
}

test_gps_a_project_gh_cannot_read_fails_closed() {
  gps_setup
  local rc=0
  gps_control_read || rc=1
  touch "$DG_BIN/psc/fail-12"
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_ne "$DG_RC" "0" "gh exits 1: fail closed" || rc=1
  assert_eq "$DG_OUT" "" "no rows" || rc=1
  assert_contains "$(cat "$DG_HOME/slog.log")" "gh exit 1" "logged as a gh failure" || rc=1
  dg_teardown; return $rc
}

test_gps_a_missing_project_fails_closed() {
  gps_setup
  local rc=0
  gps_control_read || rc=1
  rm -f "$DG_BIN/psc/12.json"   # the project is gone: GitHub answers projectV2 null
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_ne "$DG_RC" "0" "a deleted / unknown project: fail closed" || rc=1
  assert_eq "$DG_OUT" "" "no rows" || rc=1
  assert_contains "$(cat "$DG_HOME/slog.log")" "does not exist or the token cannot read it" "logged as a missing project" || rc=1
  dg_teardown; return $rc
}

test_gps_a_closed_project_fails_closed() {
  gps_setup
  local rc=0
  gps_control_read || rc=1
  gps_project 12 "Q4 Delivery" true "" "$(gps_world_items)"   # same items, now closed
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_ne "$DG_RC" "0" "a closed project: fail closed, never an empty or stale scope" || rc=1
  assert_eq "$DG_OUT" "" "no rows although the items are readable" || rc=1
  assert_contains "$(cat "$DG_HOME/slog.log")" "the project is closed" "logged as a closed project" || rc=1
  dg_teardown; return $rc
}

test_gps_a_redacted_item_fails_the_whole_read() {
  gps_setup
  local rc=0
  gps_control_read || rc=1
  gps_project 12 "Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 101 OPEN)" '{"type":"REDACTED"}' | jq -sc .)"
  gps_lib "_goal_scope_rows $GPS_SPEC $GPS_ID"
  assert_ne "$DG_RC" "0" "an item the token cannot read: fail closed, never a partial scope" || rc=1
  assert_eq "$DG_OUT" "" "the readable item 101 is not returned alone" || rc=1
  assert_contains "$(cat "$DG_HOME/slog.log")" "an item is unreadable (redacted or not an issue)" "logged as an unreadable item" || rc=1
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


# ---------------------------------------------------------------- part (b): register, overlap, feedback, stop/release, grant, brief ---

gps_reg_file() { dg_reg_file_for "$GPS_ID"; }
gps_block() { dg_block "$(gps_reg_file)"; }
gps_agent_go() {  # <owner_repo_key> <n> -> yes|no
  if dg_has_label "$DG_ST/issues/$1/$2.json" agent-go; then echo yes; else echo no; fi
}
gps_calls() { cat "$DG_BIN/psc/project-calls.log" 2>/dev/null; }

test_gps_register_writes_a_v2_block_with_derived_repos_and_the_go() {
  gps_setup
  local rc=0 blk
  dg_run "$GPS_SPEC"
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(dg_reg_count)" "1" "one registry issue" || rc=1
  blk=$(gps_block)
  assert_eq "$(printf '%s' "$blk" | jq -c '[.v, .id, .spec, .title, .go, .repos]')" \
    '[2,"proj-example-owner_12","project:example-owner/12","Q4 Delivery",true,["example-owner/project-a","example-owner/project-b"]]' "block: v2, id, canonical spec, title, go, derived repos" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r '.project // "none"')" "none" "no mirror project binding of its own" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -c '.scope_project')" '{"owner":"example-owner","number":12,"url":"https://github.com/orgs/example-owner/projects/12"}' "the scope project is recorded apart" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -c '.granted | sort')" '["example-owner/project-a#101","example-owner/project-b#1"]' "agent-go granted to the open items (closed 102 not)" || rc=1
  assert_eq "$(gps_agent_go example-owner_project-a 101)$(gps_agent_go example-owner_project-b 1)$(gps_agent_go example-owner_project-a 102)" "yesyesno" "labels written" || rc=1
  assert_eq "$(gps_calls)" "" "no second project: not one gh project call" || rc=1
  dg_run "$GPS_ALIAS"
  assert_eq "$DG_RC" "1" "the alias is the same goal" || rc=1
  assert_contains "$DG_ERR" "same goal" "registered twice: refused as the same goal" || rc=1
  dg_teardown; return $rc
}

test_gps_register_refuses_without_the_project_scope_but_other_goals_still_register() {
  gps_setup
  local rc=0
  rm -f "$DG_BIN/scope"
  dg_run "$GPS_SPEC"
  assert_eq "$DG_RC" "1" "no project scope: refused" || rc=1
  assert_contains "$DG_ERR" 'needs the gh `project` scope' "says what is missing" || rc=1
  assert_eq "$(dg_reg_count)" "0" "no registry issue" || rc=1
  dg_run "$DG_SPEC_MS"
  assert_eq "$DG_RC" "0" "a milestone goal still registers on that host (stderr: $DG_ERR)" || rc=1
  dg_teardown; return $rc
}

test_gps_register_refuses_unreadable_empty_and_undispatched_projects() {
  gps_setup
  local rc=0
  touch "$DG_BIN/psc/fail-12"
  dg_run "$GPS_SPEC"; assert_eq "$DG_RC" "1" "unreadable: refused" || rc=1
  assert_contains "$DG_ERR" "refusing to go on blind" "unreadable: fail closed" || rc=1
  rm -f "$DG_BIN/psc/fail-12"
  gps_project 12 "Q4 Delivery" false "" '[]'
  dg_run "$GPS_SPEC"; assert_eq "$DG_RC" "1" "empty project: refused" || rc=1
  assert_contains "$DG_ERR" "empty scope" "empty: says so" || rc=1
  gps_project 12 "Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/elsewhere 3 OPEN)" | jq -sc .)"
  dg_run "$GPS_SPEC"; assert_eq "$DG_RC" "1" "an item in a repo that is not dispatched: refused" || rc=1
  assert_contains "$DG_ERR" "not in DISPATCH_REPOS" "says why" || rc=1
  assert_eq "$(dg_reg_count)" "0" "nothing registered" || rc=1
  dg_teardown; return $rc
}

test_gps_overlap_both_ways_with_every_kind_of_goal() {
  gps_setup
  local rc=0
  echo '[]' > "$DG_BIN/psc/list.json"   # no project of the owner for a milestone goal's mirror to bind (that is another test)
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "milestone goal registers (stderr: $DG_ERR)" || rc=1
  dg_run "$GPS_SPEC"
  assert_eq "$DG_RC" "1" "project over a live milestone goal's tickets: refused" || rc=1
  assert_contains "$DG_ERR" "overlaps live goal $DG_ID_MS" "names the live goal" || rc=1
  assert_contains "$DG_ERR" "route=goal-project-scope" "the refusal is captured with its route tag" || rc=1
  dg_teardown
  gps_setup
  echo '[]' > "$DG_BIN/psc/list.json"
  dg_run "$GPS_SPEC"; assert_eq "$DG_RC" "0" "project goal registers (stderr: $DG_ERR)" || rc=1
  dg_run "$DG_SPEC_MS"
  assert_eq "$DG_RC" "1" "reverse: a milestone goal over the project goal's tickets: refused" || rc=1
  assert_contains "$DG_ERR" "overlaps live goal $GPS_ID" "names the project goal" || rc=1
  dg_run "$DG_SPEC_T7"; assert_eq "$DG_RC" "0" "a ticket outside the project (#7) is fine (stderr: $DG_ERR)" || rc=1
  dg_run example-owner/project-a#101
  assert_eq "$DG_RC" "1" "a ticket goal over an item: refused" || rc=1
  dg_run "$DG_SPEC_ALL" --approve-all
  assert_eq "$DG_RC" "1" "milestones:all sharing an item: refused" || rc=1
  dg_teardown; return $rc
}

test_gps_overlap_refuses_blind_when_the_live_project_goals_scope_is_unreadable() {
  gps_setup
  local rc=0
  dg_run "$GPS_SPEC"; assert_eq "$DG_RC" "0" "registers (stderr: $DG_ERR)" || rc=1
  touch "$DG_BIN/psc/fail-12"
  dg_run "$DG_SPEC_T7"
  assert_eq "$DG_RC" "1" "a new goal while a live project goal cannot be read: refused" || rc=1
  assert_contains "$DG_ERR" "refusing to go on blind" "fail closed" || rc=1
  dg_teardown; return $rc
}

test_gps_feedback_goal_yields_the_tickets_of_a_live_project_goal() {
  gps_setup
  local rc=0
  dg_run "$GPS_SPEC"
  gps_lib "_goal_fb_covered example-owner/project-a | sort | tr '\n' ' '"
  assert_eq "$DG_OUT" "101 102 " "project-a items are covered" || rc=1
  gps_lib "_goal_fb_covered example-owner/project-b"
  assert_eq "$DG_OUT" "1" "project-b item is covered" || rc=1
  touch "$DG_BIN/psc/fail-12"
  gps_lib "_goal_fb_covered example-owner/project-a"
  assert_eq "$DG_RC" "1" "an unreadable live project goal: the feedback scope fails closed" || rc=1
  dg_teardown; return $rc
}

test_gps_stop_records_the_open_items_and_release_frees_them() {
  gps_setup
  local rc=0
  export GOAL_STOP_HOLD_RETRY_SECS=0
  dg_run "$GPS_SPEC"
  dg_run stop "$GPS_ID"; assert_eq "$DG_RC" "0" "stop exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(gps_block | jq -c '.stopped_open | sort')" '["example-owner/project-a#101","example-owner/project-b#1"]' "the open items are held" || rc=1
  gps_lib "_goal_fb_covered example-owner/project-a"
  assert_eq "$DG_OUT" "101" "a stopped goal still holds its open ticket out of the feedback goal" || rc=1
  dg_run release "$GPS_ID"; assert_eq "$DG_RC" "0" "release exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(gps_block | jq -r '.stopped_open // "gone"')" "gone" "hold removed" || rc=1
  gps_lib "_goal_fb_covered example-owner/project-a"
  assert_eq "$DG_OUT" "" "released: covered by nothing" || rc=1
  dg_run resume "$GPS_ID"; assert_eq "$DG_RC" "0" "resume works (stderr: $DG_ERR)" || rc=1
  # unreadable at stop: the goal's derived repos are held
  dg_run stop "$GPS_ID"; dg_run release "$GPS_ID"; dg_run resume "$GPS_ID"
  touch "$DG_BIN/psc/fail-12"
  dg_run stop "$GPS_ID"
  assert_eq "$(gps_block | jq -r '.stopped_open')" "unreadable" "unreadable scope at stop: recorded as unreadable" || rc=1
  gps_lib "_goal_fb_covered example-owner/project-a"
  assert_eq "$DG_RC" "1" "the feedback goal on a derived repo fails closed until release" || rc=1
  printf '%s' example-owner/elsewhere > "$DG_PIPE/repo-canon/example-owner__elsewhere"
  gps_lib "_goal_fb_covered example-owner/elsewhere"
  assert_eq "$DG_RC" "0" "a repo the goal never had is not held" || rc=1
  unset GOAL_STOP_HOLD_RETRY_SECS
  dg_teardown; return $rc
}

test_gps_sync_grants_go_to_new_items_with_the_usual_exclusions() {
  gps_setup
  local rc=0 items g
  dg_run "$GPS_SPEC"
  dg_issue example-owner_project-b 2 open; dg_issue example-owner_project-b 3 open; dg_issue example-owner_project-b 4 open
  items=$(printf '%s\n' "$(gps_world_items | jq -c '.[]')" \
    "$(gps_issue_item example-owner/project-b 2 OPEN)" \
    "$(gps_issue_item example-owner/project-b 3 OPEN | jq -c '. + {labels:["source:sentry"]}')" \
    "$(gps_issue_item example-owner/Business-Intelligence 9 OPEN)" | jq -sc .)
  gps_project 12 "Q4 Delivery" false "" "$items"
  gps_lib "g=\$(_goal_find $GPS_ID); _goal_sync_grant \"\$g\""
  assert_eq "$DG_RC" "0" "sync exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(gps_agent_go example-owner_project-b 2)" "yes" "a later item gets agent-go" || rc=1
  assert_eq "$(gps_agent_go example-owner_project-b 3)" "no" "source:sentry is skipped without --include-sentry" || rc=1
  assert_eq "$(gps_block | jq -c '.granted | index("example-owner/project-b#2") != null')" "true" "recorded in the block (loop guard)" || rc=1
  jq -c '.labels = []' "$DG_ST/issues/example-owner_project-b/2.json" > "$DG_ST/x" && mv "$DG_ST/x" "$DG_ST/issues/example-owner_project-b/2.json"
  gps_lib "g=\$(_goal_find $GPS_ID); _goal_sync_grant \"\$g\""
  assert_eq "$(gps_agent_go example-owner_project-b 2)" "no" "an agent-go removed later is never re-added" || rc=1
  dg_teardown; return $rc
}

test_gps_a_host_without_the_scope_still_works_around_a_live_project_goal() {
  gps_setup
  local rc=0
  gps_project 12 "Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 101 OPEN)" "$(gps_issue_item example-owner/project-a 102 CLOSED COMPLETED)" | jq -sc .)"
  dg_run "$GPS_SPEC"
  assert_eq "$DG_RC" "0" "registered on a host with the scope (stderr: $DG_ERR)" || rc=1
  assert_eq "$(gps_block | jq -c '[.host_pref, .repos]')" '["host-a",["example-owner/project-a"]]' "pinned to the registering host; the derived repos are recorded" || rc=1
  # now a host whose token has no project scope (the project goal cannot be read there)
  rm -f "$DG_BIN/scope"; touch "$DG_BIN/noscope"
  dg_milestone example-owner_project-b 5 "b milestone"; dg_issue example-owner_project-b 2 open 5
  dg_run example-owner/project-b:milestone:5
  assert_eq "$DG_RC" "0" "a goal on a repo the project goal never touched still registers (stderr: $DG_ERR)" || rc=1
  dg_run "$DG_SPEC_MS"
  assert_eq "$DG_RC" "1" "a goal on the project goal's own repo is refused" || rc=1
  assert_contains "$DG_ERR" "refusing to go on blind" "closed: the project goal cannot be ruled out" || rc=1
  gps_lib "_goal_fb_covered example-owner/project-b"
  assert_eq "$DG_RC" "0" "feedback goal on an unrelated repo: not blocked" || rc=1
  gps_lib "_goal_fb_covered example-owner/project-a"
  assert_eq "$DG_RC" "1" "feedback goal on the project goal's repo: fails closed" || rc=1
  dg_teardown; return $rc
}

test_gps_sync_follows_a_repo_that_joined_through_a_new_item() {
  gps_setup
  local rc=0
  gps_project 12 "Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 101 OPEN)" | jq -sc .)"
  dg_run "$GPS_SPEC"
  assert_eq "$(gps_block | jq -c .repos)" '["example-owner/project-a"]' "registered with project-a only" || rc=1
  gps_project 12 "Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 101 OPEN)" "$(gps_issue_item example-owner/project-b 1 OPEN)" | jq -sc .)"
  gps_lib "g=\$(_goal_find $GPS_ID); _goal_sync_grant \"\$g\""
  assert_eq "$(gps_block | jq -c .repos)" '["example-owner/project-a","example-owner/project-b"]' "the block now lists project-b" || rc=1
  assert_eq "$(gps_agent_go example-owner_project-b 1)" "yes" "and its item got agent-go" || rc=1
  dg_teardown; return $rc
}

test_gps_milestones_all_rule_holds_for_project_goals_both_ways() {
  gps_setup
  local rc=0
  # project 12 holds only project-a#7: no ticket shared with the milestones:all goal (it covers 101 and 201), but the same repo
  gps_project 12 "Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 7 OPEN)" | jq -sc .)"
  dg_run "$DG_SPEC_ALL" --approve-all; assert_eq "$DG_RC" "0" "milestones:all registers (stderr: $DG_ERR)" || rc=1
  dg_run "$GPS_SPEC"
  assert_eq "$DG_RC" "1" "a project goal touching that repo is refused" || rc=1
  assert_contains "$DG_ERR" "milestones:all on example-owner/project-a" "by the milestones:all repo rule" || rc=1
  gps_project 12 "Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-b 1 OPEN)" | jq -sc .)"
  dg_run "$GPS_SPEC"; assert_eq "$DG_RC" "0" "control: a project on another repo registers (stderr: $DG_ERR)" || rc=1
  dg_teardown
  gps_setup
  gps_project 12 "Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 7 OPEN)" | jq -sc .)"
  dg_run "$GPS_SPEC"; assert_eq "$DG_RC" "0" "project goal registers first (stderr: $DG_ERR)" || rc=1
  dg_run "$DG_SPEC_ALL" --approve-all
  assert_eq "$DG_RC" "1" "reverse: milestones:all on a repo the project goal touches is refused" || rc=1
  assert_contains "$DG_ERR" "milestones:all on example-owner/project-a" "by the same rule" || rc=1
  dg_teardown; return $rc
}

# A project that is a goal's scope belongs to its owner: another goal's mirror sync must never adopt it (by title or by shared items), and a
# project that is a live goal's mirror cannot become a scope.
test_gps_another_goals_mirror_never_adopts_a_scope_project() {
  gps_setup
  local rc=0 f
  # the milestone goal's mirror title is "Goal: <spec>"; project 12 carries exactly that title
  jq -nc '[{number:12,title:"Goal: example-owner/project-a:milestone:12",closed:false}]' > "$DG_BIN/psc/list.json"
  gps_project 12 "Goal: example-owner/project-a:milestone:12" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 7 OPEN)" | jq -sc .)"
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "control: with no scope project, the mirror binds the same-titled project 12 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(dg_block "$(dg_reg_file_for "$DG_ID_MS")" | jq -r '.project.number // "none"')" "12" "control bound" || rc=1
  dg_teardown
  gps_setup
  jq -nc '[{number:12,title:"Goal: example-owner/project-a:milestone:12",closed:false}]' > "$DG_BIN/psc/list.json"
  gps_project 12 "Goal: example-owner/project-a:milestone:12" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 7 OPEN)" | jq -sc .)"
  dg_run "$GPS_SPEC"; assert_eq "$DG_RC" "0" "project 12 registered as a scope (stderr: $DG_ERR)" || rc=1
  : > "$DG_BIN/psc/project-calls.log"
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "milestone goal registers (stderr: $DG_ERR)" || rc=1
  assert_eq "$(dg_block "$(dg_reg_file_for "$DG_ID_MS")" | jq -r '.project.number // "none"')" "none" "its mirror did not adopt the scope project" || rc=1
  assert_not_contains "$(gps_calls)" "item-add" "no item was added to the scope project" || rc=1
  assert_not_contains "$(gps_calls)" "edit" "nothing was edited" || rc=1
  dg_teardown
  # the other way: a live goal's mirror cannot be registered as a scope
  gps_setup
  jq -nc '[{number:12,title:"Goal: example-owner/project-a:milestone:12",closed:false}]' > "$DG_BIN/psc/list.json"
  gps_project 12 "Goal: example-owner/project-a:milestone:12" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 7 OPEN)" | jq -sc .)"
  dg_run "$DG_SPEC_MS"
  dg_run "$GPS_SPEC"
  assert_eq "$DG_RC" "1" "a live goal's mirror project is refused as a scope" || rc=1
  assert_contains "$DG_ERR" "mirror project of live goal $DG_ID_MS" "says whose mirror it is" || rc=1
  dg_teardown; return $rc
}

test_gps_milestone_approval_is_unchanged_by_a_project_goal() {
  gps_setup
  local rc=0
  dg_run "$GPS_SPEC"
  gps_lib "goal_milestone_approved example-owner/project-a 12"
  assert_eq "$DG_RC" "1" "a project goal does not approve a milestone" || rc=1
  dg_teardown
  gps_setup
  dg_run "$DG_SPEC_MS"
  gps_lib "goal_milestone_approved example-owner/project-a 12"
  assert_eq "$DG_RC" "0" "a milestone goal still does" || rc=1
  dg_teardown; return $rc
}

test_gps_brief_names_the_project_and_never_milestones_or_labels() {
  gps_setup
  local rc=0 brief
  dg_run "$GPS_SPEC"
  gps_lib "goal_brief $GPS_ID"
  brief=$DG_OUT
  assert_eq "$DG_RC" "0" "brief builds (stderr: $DG_ERR)" || rc=1
  assert_contains "$brief" "https://github.com/orgs/example-owner/projects/12" "the project URL" || rc=1
  assert_contains "$brief" "issue items" "scope is the issue items" || rc=1
  assert_eq "$(printf '%s' "$brief" | grep -ciE 'milestone|label' || true)" "0" "no mention of milestones or labels" || rc=1
  dg_teardown; return $rc
}

test_gps_mirror_never_touches_a_scope_project() {
  gps_setup
  local rc=0 g reg
  dg_run "$GPS_SPEC"
  g=$(cd "$DG_CWD" && env HOME="$DG_HOME" PIPE="$DG_PIPE" PATH="$DG_BIN:$PATH" bash -c '. "$1/config.sh"; . "$1/pipeline-lib.sh"; . "$1/../../hooks/pipeline-markers.sh"; . "$1/goal-lib.sh"; _goal_find "$2"' _ "$DG_SKILL" "$GPS_ID")
  gps_lib "slog() { :; }; goal_project_sync_one '$g' create; echo rc=\$?; deliver_project=1"
  assert_eq "$DG_OUT" "rc=0" "the mirror sync is a no-op for a project goal" || rc=1
  dg_run project "$GPS_ID"
  assert_eq "$DG_RC" "0" "deliver.sh project exits 0 (stderr: $DG_ERR)" || rc=1
  assert_contains "$DG_OUT" "https://github.com/orgs/example-owner/projects/12" "and shows the scope project" || rc=1
  assert_eq "$(gps_calls)" "" "no create, copy, edit, item-add or close" || rc=1
  # the sweep: an all-closed "Goal: " project that is a scope project is not closed; an unrelated one is
  gps_project 12 "Goal: Q4 Delivery" false "" "$(printf '%s\n' "$(gps_issue_item example-owner/project-a 102 CLOSED COMPLETED)" | jq -sc .)"
  reg=$(printf '%s' "[$g]")
  gps_lib "slog() { :; }; GOAL_PROJECT_OWNER=example-owner; _GP_REG='$reg'; goal_project_sweep_done"
  assert_not_contains "$(gps_calls)" "project close" "a scope project is never swept closed" || rc=1
  gps_lib "slog() { :; }; GOAL_PROJECT_OWNER=example-owner; _GP_REG='[]'; goal_project_sweep_done"
  assert_contains "$(gps_calls)" "close 12" "control: an unbound all-closed Goal: project is closed as before" || rc=1
  dg_teardown; return $rc
}

test_gps_only_one_function_reads_the_project_and_it_lives_in_goal_project_sh() {
  local rc=0 f n=0
  for f in goal-lib.sh deliver.sh supervisor.sh; do
    n=$((n + $(grep -vE '^[[:space:]]*#' "$DG_SKILL/$f" | grep -c 'goal_project_read')))
  done
  assert_eq "$n" "1" "exactly one call of the reader outside goal-project.sh (the _goal_proj_read wrapper)" || rc=1
  assert_eq "$(grep -c '^goal_project_read()' "$DG_SKILL/goal-project.sh")" "1" "defined once, in goal-project.sh" || rc=1
  return $rc
}

test_gps_product_manager_doc_ties_project_goals_to_the_project_not_the_milestone() {
  local rc=0 pm="$DG_SKILL/../../agents/product-manager.md" sec
  sec=$(awk '/^### Project-bound goals/{f=1;next} /^#{1,3} /{f=0} f' "$pm")
  assert_contains "$sec" "added to the Project" "a ticket joins a project goal by being added to the Project" || rc=1
  assert_contains "$sec" "gh project item-add" "the PM adds it when the brief names the project" || rc=1
  assert_contains "$sec" "delivery lead adds it" "otherwise the delivery lead" || rc=1
  assert_contains "$sec" "never needs one" "no milestone is a goal-scope requirement" || rc=1
  # the goal-label and milestone-goal rules are untouched
  assert_contains "$(cat "$pm")" 'is a *child of an approved goal*' "milestone-goal rule kept" || rc=1
  assert_contains "$(cat "$pm")" 'A cross-repo goal is a GitHub label `goal: <short title>`' "goal-label rule kept" || rc=1
  assert_contains "$(cat "$pm")" '`goal_milestone_approved <owner/repo> <milestone number>`' "milestone resolver kept" || rc=1
  return $rc
}

for t in test_gps_parse_canonical_and_alias \
         test_gps_register_writes_a_v2_block_with_derived_repos_and_the_go \
         test_gps_register_refuses_without_the_project_scope_but_other_goals_still_register \
         test_gps_register_refuses_unreadable_empty_and_undispatched_projects \
         test_gps_overlap_both_ways_with_every_kind_of_goal \
         test_gps_overlap_refuses_blind_when_the_live_project_goals_scope_is_unreadable \
         test_gps_feedback_goal_yields_the_tickets_of_a_live_project_goal \
         test_gps_stop_records_the_open_items_and_release_frees_them \
         test_gps_sync_grants_go_to_new_items_with_the_usual_exclusions \
         test_gps_a_host_without_the_scope_still_works_around_a_live_project_goal \
         test_gps_sync_follows_a_repo_that_joined_through_a_new_item \
         test_gps_milestones_all_rule_holds_for_project_goals_both_ways \
         test_gps_another_goals_mirror_never_adopts_a_scope_project \
         test_gps_milestone_approval_is_unchanged_by_a_project_goal \
         test_gps_brief_names_the_project_and_never_milestones_or_labels \
         test_gps_mirror_never_touches_a_scope_project \
         test_gps_only_one_function_reads_the_project_and_it_lives_in_goal_project_sh \
         test_gps_product_manager_doc_ties_project_goals_to_the_project_not_the_milestone \
         test_gps_parse_malformed_forms_are_refused_naming_the_accepted_forms \
         test_gps_goal_id_has_no_leading_dashes \
         test_gps_scope_rows_are_the_three_issue_items \
         test_gps_scope_rows_full_shape_maps_graphql_values_to_rest_values \
         test_gps_item_status_field_never_decides_the_state \
         test_gps_business_intelligence_items_are_never_in_scope \
         test_gps_more_than_one_page_is_read_completely \
         test_gps_a_failed_page_fails_the_whole_read \
         test_gps_a_page_that_has_more_but_no_cursor_fails_closed \
         test_gps_a_project_gh_cannot_read_fails_closed \
         test_gps_a_missing_project_fails_closed \
         test_gps_a_closed_project_fails_closed \
         test_gps_a_redacted_item_fails_the_whole_read \
         test_gps_the_read_does_not_depend_on_the_mirror_switch \
         test_gps_an_empty_project_reads_as_an_empty_scope_not_an_error \
         test_gps_goal_eval_open_while_any_item_is_open_and_delivered_when_all_closed \
         test_gps_goal_eval_an_empty_project_is_not_delivered_and_an_unreadable_one_fails \
         test_gps_goal_name_is_the_project_title_and_exits_1_when_github_cannot_say \
         test_gps_an_unreadable_project_is_captured_with_release_environment_and_route_and_no_secret; do
  run_test "$t"
done
