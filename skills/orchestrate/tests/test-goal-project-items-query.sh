# #402: goal_project_sync_one reads project items with ONE cheap `gh api graphql` query (no `gh project item-list`, no fieldValues(
# connection), paginated by pageInfo/after. Self-contained: a fake gh on PATH, goal-project.sh sourced in a subshell with slog and
# _goal_scope_rows stubbed. Expected values are hand-written. Cursor convention: pass it as `-f after=<cursor>` / `-F after=<cursor>` (any arg containing "=c1" serves page 2, "=c2" page 3); do not pass it via --input.
GQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/goal-project.sh"

gq_setup() {
  GQ_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gq-test.XXXXXX"); mkdir -p "$GQ_DIR/bin"
  : > "$GQ_DIR/calls.log"; : > "$GQ_DIR/slog.log"
  cat > "$GQ_DIR/bin/gh" <<'GQ_GH_EOF'
#!/bin/bash
D=$(cd "$(dirname "$0")/.." && pwd)
echo "$*" >> "$D/calls.log"
if [ "$1" = api ] && [ "$2" = graphql ]; then
  echo "GRAPHQL $*" >> "$D/graphql.log"
  [ ! -f "$D/fail-graphql" ] || { echo "gh: HTTP 403 rate limit" >&2; exit 1; }
  case "$*" in *=c2*) f="$D/page3.json" ;; *=c1*) f="$D/page2.json" ;; *) f="$D/page1.json" ;; esac
  cat "$f"; exit 0
fi
[ "$1" = project ] || { echo "fake gh: unsupported $*" >&2; exit 1; }
sub=$2
case "$sub" in
  item-list) echo "ITEM-LIST CALLED" >> "$D/item-list.log"; echo "gh: item-list must not be used" >&2; exit 1 ;;
  view) echo '{"id":"PVT_5","closed":false}' ;;
  field-list) echo '{"fields":[{"id":"F_STATUS","name":"Status","options":[{"id":"o1","name":"Todo"},{"id":"o2","name":"In Progress"},{"id":"o3","name":"Done"}]}]}' ;;
  item-add)
    url=""; shift 2; while [ $# -gt 0 ]; do [ "$1" != --url ] || url=$2; shift; done
    repo=$(printf '%s' "$url" | sed -E 's#https://github.com/([^/]+/[^/]+)/issues/.*#\1#'); n=${url##*/}
    echo "ADD $repo#$n" >> "$D/adds.log"
    jq -c --arg r "$repo" --argjson n "$n" '.data.repositoryOwner.projectV2.items.nodes += [{id:"I_NEW", fieldValueByName:null, content:{number:$n, repository:{nameWithOwner:$r}, labels:{nodes:[]}}}]' "$D/page1.json" > "$D/p.tmp" && mv "$D/p.tmp" "$D/page1.json"
    echo '{}' ;;
  item-edit)
    id=""; opt=""; shift 2; while [ $# -gt 0 ]; do case "$1" in --id) id=$2 ;; --single-select-option-id) opt=$2 ;; esac; shift; done
    echo "EDIT $id:$opt" >> "$D/edits.log"; echo '{}' ;;
  *) echo '{}' ;;
esac
GQ_GH_EOF
  chmod +x "$GQ_DIR/bin/gh"
}
gq_teardown() { rm -rf "$GQ_DIR"; }

# gq_node <id> <repo> <num> <status|""> [label ...] — one project item node as the graphql query returns it
gq_node() {
  local id=$1 repo=$2 num=$3 st=$4; shift 4
  local labels; labels=$(printf '%s\n' "$@" | jq -R 'select(length>0) | {name:.}' | jq -sc .)
  jq -nc --arg id "$id" --arg r "$repo" --argjson n "$num" --arg st "$st" --argjson l "$labels" \
    '{id:$id, fieldValueByName:(if $st == "" then null else {name:$st} end), content:{number:$n, repository:{nameWithOwner:$r}, labels:{nodes:$l}}}'
}
# gq_page <file> <hasNext> <endCursor> <node json>...
gq_page() {
  local f=$1 more=$2 cur=$3; shift 3
  printf '%s\n' "$@" | jq -sc --argjson m "$more" --arg c "$cur" \
    '{data:{repositoryOwner:{projectV2:{items:{pageInfo:{hasNextPage:$m, endCursor:(if $c == "" then null else $c end)}, nodes:.}}}}}' > "$f"
}
# gq_sync <rows: "repo#num<TAB>open|closed" lines> — runs goal_project_sync_one for project 5 of owner "o"; sets GQ_RC
gq_sync() {
  GQ_RC=0
  GQ_ROWS="$1" GQ_DIR="$GQ_DIR" GQ_SRC="$GQ_SRC" PATH="$GQ_DIR/bin:$PATH" bash -c '
    slog() { echo "$*" >> "$GQ_DIR/slog.log"; }
    _goal_scope_rows() { printf "%s\n" "$GQ_ROWS"; }
    GOAL_PROJECTS=1; _GP_SCOPE=yes
    . "$GQ_SRC"
    goal_project_sync_one "{\"st\":\"live\",\"id\":\"g1\",\"spec\":\"s\",\"block\":{\"repos\":[\"o/r\"],\"project\":{\"owner\":\"o\",\"number\":5}}}" bind
  ' >/dev/null 2>"$GQ_DIR/err.log" || GQ_RC=$?
}
gq_edits() { sort "$GQ_DIR/edits.log" 2>/dev/null | tr '\n' ' '; }
gq_count() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"; }

test_gq_two_pages_follow_the_cursor_and_every_item_reaches_the_status_loop() {
  gq_setup; local rc=0 T=$'\t'
  gq_page "$GQ_DIR/page1.json" true c1 "$(gq_node I_1 o/r 1 "")" "$(gq_node I_2 o/r 2 "")"
  gq_page "$GQ_DIR/page2.json" false "" "$(gq_node I_3 o/r 3 "")" "$(gq_node I_4 o/r 4 "")"
  gq_sync "o/r#1${T}open
o/r#2${T}open
o/r#3${T}open
o/r#4${T}open"
  assert_eq "$GQ_RC" "0" "sync returns 0 (stderr: $(cat "$GQ_DIR/err.log"))" || rc=1
  assert_eq "$(gq_count GRAPHQL "$GQ_DIR/graphql.log")" "2" "exactly two graphql calls (one per page)" || rc=1
  assert_not_contains "$(sed -n 1p "$GQ_DIR/graphql.log" 2>/dev/null)" "=c1" "first call carries no cursor" || rc=1
  assert_contains "$(sed -n 2p "$GQ_DIR/graphql.log" 2>/dev/null)" "=c1" "second call carries the cursor c1 (after=c1)" || rc=1
  assert_eq "$(gq_count . "$GQ_DIR/adds.log")" "0" "items of page 2 are found, so none is re-added" || rc=1
  assert_eq "$(gq_edits)" "EDIT I_1:o1 EDIT I_2:o1 EDIT I_3:o1 EDIT I_4:o1 " "all four items on both pages set to Todo (o1)" || rc=1
  gq_teardown; return $rc
}

test_gq_status_mix_edits_only_items_whose_status_differs() {
  gq_setup; local rc=0 T=$'\t'
  # want: closed -> Done(o3); label agent-in-progress -> In Progress(o2); else Todo(o1)
  gq_page "$GQ_DIR/page1.json" false "" \
    "$(gq_node I_A o/r 1 Todo)" \
    "$(gq_node I_B o/r 2 Todo agent-in-progress other)" \
    "$(gq_node I_C o/r 3 Todo)" \
    "$(gq_node I_D o/r 4 Done)" \
    "$(gq_node I_E o/r 5 "In Progress" agent-in-progress)" \
    "$(gq_node I_F o/r 6 "")"
  gq_sync "o/r#1${T}closed
o/r#2${T}open
o/r#3${T}open
o/r#4${T}closed
o/r#5${T}open
o/r#6${T}open"
  assert_eq "$GQ_RC" "0" "sync returns 0 (stderr: $(cat "$GQ_DIR/err.log"))" || rc=1
  # A: Todo->Done, B: Todo->In Progress, F: absent->Todo; C, D, E already match
  assert_eq "$(gq_edits)" "EDIT I_A:o3 EDIT I_B:o2 EDIT I_F:o1 " "exactly the three differing items are edited" || rc=1
  gq_teardown; return $rc
}

test_gq_missing_item_is_added_then_relisted_with_the_graphql_query() {
  gq_setup; local rc=0 T=$'\t'
  gq_page "$GQ_DIR/page1.json" false "" "$(gq_node I_1 o/r 1 Todo)"
  gq_sync "o/r#1${T}open
o/r#2${T}open"
  assert_eq "$GQ_RC" "0" "sync returns 0 (stderr: $(cat "$GQ_DIR/err.log"))" || rc=1
  assert_eq "$(cat "$GQ_DIR/adds.log" 2>/dev/null)" "ADD o/r#2" "the missing ticket is added" || rc=1
  assert_eq "$(gq_count GRAPHQL "$GQ_DIR/graphql.log")" "2" "one list before the add, one cheap re-list after" || rc=1
  assert_eq "$(gq_edits)" "EDIT I_NEW:o1 " "the new item (seen only in the re-list) gets Status Todo; the matching one is untouched" || rc=1
  assert_eq "$(gq_count . "$GQ_DIR/item-list.log")" "0" "gh project item-list is never called" || rc=1
  gq_teardown; return $rc
}

test_gq_three_pages_follow_the_cursor_chain() {
  gq_setup; local rc=0 T=$'\t'
  gq_page "$GQ_DIR/page1.json" true c1 "$(gq_node I_1 o/r 1 "")"
  gq_page "$GQ_DIR/page2.json" true c2 "$(gq_node I_2 o/r 2 "")"
  gq_page "$GQ_DIR/page3.json" false "" "$(gq_node I_3 o/r 3 "")"
  gq_sync "o/r#1${T}open
o/r#2${T}open
o/r#3${T}open"
  assert_eq "$GQ_RC" "0" "sync returns 0 (stderr: $(cat "$GQ_DIR/err.log"))" || rc=1
  assert_eq "$(gq_count GRAPHQL "$GQ_DIR/graphql.log")" "3" "three graphql calls (one per page)" || rc=1
  assert_contains "$(sed -n 3p "$GQ_DIR/graphql.log" 2>/dev/null)" "=c2" "third call carries the cursor c2" || rc=1
  assert_eq "$(gq_edits)" "EDIT I_1:o1 EDIT I_2:o1 EDIT I_3:o1 " "items of all three pages are set to Todo" || rc=1
  gq_teardown; return $rc
}

test_gq_empty_project_adds_every_ticket_then_relists() {
  gq_setup; local rc=0 T=$'\t'
  gq_page "$GQ_DIR/page1.json" false ""
  gq_sync "o/r#1${T}open
o/r#2${T}open"
  assert_eq "$GQ_RC" "0" "sync returns 0 (stderr: $(cat "$GQ_DIR/err.log"))" || rc=1
  assert_eq "$(sort "$GQ_DIR/adds.log" 2>/dev/null | tr '\n' ' ')" "ADD o/r#1 ADD o/r#2 " "0 items listed: both tickets are added" || rc=1
  assert_eq "$(gq_count GRAPHQL "$GQ_DIR/graphql.log")" "2" "one list, one re-list after the adds" || rc=1
  assert_eq "$(gq_count . "$GQ_DIR/edits.log")" "2" "the re-listed (new) items each get a Status edit" || rc=1
  gq_teardown; return $rc
}

test_gq_graphql_failure_logs_cannot_list_and_changes_nothing() {
  gq_setup; local rc=0 T=$'\t'
  touch "$GQ_DIR/fail-graphql"
  gq_page "$GQ_DIR/page1.json" false "" "$(gq_node I_1 o/r 1 "")"
  gq_sync "o/r#1${T}open
o/r#2${T}open"
  assert_eq "$GQ_RC" "1" "sync returns 1" || rc=1
  assert_eq "$(gq_count GRAPHQL "$GQ_DIR/graphql.log")" "1" "the failing read was the one graphql query" || rc=1
  assert_contains "$(cat "$GQ_DIR/slog.log")" "[goal] project: cannot list project 5" "failure is logged through _gp_log" || rc=1
  assert_eq "$(gq_count . "$GQ_DIR/edits.log")" "0" "no item-edit" || rc=1
  assert_eq "$(gq_count . "$GQ_DIR/adds.log")" "0" "no item-add" || rc=1
  gq_teardown; return $rc
}

test_gq_failure_on_a_later_page_also_fails_without_edits() {
  gq_setup; local rc=0 T=$'\t'
  gq_page "$GQ_DIR/page1.json" true c1 "$(gq_node I_1 o/r 1 "")"
  echo 'not json' > "$GQ_DIR/page2.json"   # page 2 unparsable
  gq_sync "o/r#1${T}open"
  assert_eq "$GQ_RC" "1" "sync returns 1 when page 2 is unusable" || rc=1
  assert_eq "$(gq_count GRAPHQL "$GQ_DIR/graphql.log")" "2" "page 2 was requested" || rc=1
  assert_contains "$(cat "$GQ_DIR/slog.log")" "cannot list project 5" "logged" || rc=1
  assert_eq "$(gq_count . "$GQ_DIR/edits.log")" "0" "no edits from a partial read" || rc=1
  gq_teardown; return $rc
}

test_gq_draft_and_non_issue_nodes_are_skipped_without_error() {
  gq_setup; local rc=0 T=$'\t'
  gq_page "$GQ_DIR/page1.json" false "" \
    '{"id":"I_DRAFT","fieldValueByName":null,"content":{}}' \
    "$(gq_node I_1 o/r 1 "")"
  gq_sync "o/r#1${T}open"
  assert_eq "$GQ_RC" "0" "sync returns 0 (stderr: $(cat "$GQ_DIR/err.log"))" || rc=1
  assert_eq "$(gq_edits)" "EDIT I_1:o1 " "only the issue item is edited; the draft is ignored" || rc=1
  assert_eq "$(gq_count "cannot" "$GQ_DIR/slog.log")" "0" "nothing logged as an error" || rc=1
  gq_teardown; return $rc
}

test_gq_query_text_is_cheap_and_item_list_is_gone() {
  local rc=0 code
  code=$(grep -vE '^[[:space:]]*#' "$GQ_SRC")
  assert_eq "$(printf '%s' "$code" | grep -c 'fieldValues(')" "0" "no fieldValues( connection requested (that is what costs 101 points)" || rc=1
  assert_contains "$code" 'fieldValueByName' "Status read through fieldValueByName" || rc=1
  assert_contains "$code" 'pageInfo' "paginated with pageInfo" || rc=1
  assert_contains "$code" 'hasNextPage' "loops until hasNextPage is false" || rc=1
  assert_contains "$code" 'endCursor' "cursor taken from endCursor" || rc=1
  assert_contains "$code" 'repositoryOwner' "owner-agnostic query (user and org projects)" || rc=1
  assert_eq "$(grep -c 'gh project item-list' "$GQ_SRC")" "0" "gh project item-list appears nowhere in goal-project.sh" || rc=1
  return $rc
}

test_gq_no_new_throttle_and_interval_unchanged() {
  local rc=0 code
  code=$(grep -vE '^[[:space:]]*#' "$GQ_SRC")
  assert_contains "$code" 'GOAL_PROJECT_SECS="${GOAL_PROJECT_SECS:-900}"' "GOAL_PROJECT_SECS default unchanged (900)" || rc=1
  assert_eq "$(printf '%s' "$code" | grep -ciE 'rate_?limit|x-ratelimit|backoff|back-off|budget' || true)" "0" "no rate-limit pre-check, back-off or budget counter" || rc=1
  return $rc
}

for t in test_gq_three_pages_follow_the_cursor_chain test_gq_empty_project_adds_every_ticket_then_relists test_gq_two_pages_follow_the_cursor_and_every_item_reaches_the_status_loop test_gq_status_mix_edits_only_items_whose_status_differs \
         test_gq_missing_item_is_added_then_relisted_with_the_graphql_query test_gq_graphql_failure_logs_cannot_list_and_changes_nothing \
         test_gq_failure_on_a_later_page_also_fails_without_edits test_gq_draft_and_non_issue_nodes_are_skipped_without_error \
         test_gq_query_text_is_cheap_and_item_list_is_gone test_gq_no_new_throttle_and_interval_unchanged; do
  run_test "$t"
done
