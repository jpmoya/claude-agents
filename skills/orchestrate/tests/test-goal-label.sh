# #319 — cross-repo goal model with a `goal: <short title>` label.
# Sourced by run-tests.sh AFTER test-goal-deliver.sh (alphabetical), reusing its dg_* sandbox (dg_setup, dg_run,
# dg_lib, dg_goal, dg_reg_files, dg_block …). Helpers here are prefixed glb_ / GLB_ (all suites share one shell).
# Expected values come from the ticket or hand arithmetic in comments — never from the code. Placeholder repo names.
#
# Interface choices the ticket leaves open (listed in the handoff):
#   goal_label_name <title>           the label rule helper (stub in goal-lib.sh)
#   deliver.sh --repos a/b,c/d --title "<t>" [--requirements owner/repo#N] [--include-sentry] [instructions…]
#   deliver.sh "label:<exact label name>" --repos a/b,c/d [--requirements …]
#   goal_scope / _goal_scope_rows "label:<name>" <registry goal id>   (repos come from the registry v2 block)
#
# Fake gh: a wrapper over the stateful `gh api` fake from test-goal-deliver.sh. It fully URL-decodes paths and adds
# the repo label endpoints (GET/POST labels, GET/PATCH/DELETE labels/<name>), renaming/deleting a label on every issue
# that carries it as GitHub does. Any non-`api` call is rejected and logged (= the no-GraphQL evidence).
# Touch $DG_BIN/fail-label-patch to make label renames fail with HTTP 500.

GLB_A=example-owner_project-a
GLB_B=example-owner_project-b
GLB_BI=example-owner_Business-Intelligence
GLB_RA=example-owner/project-a
GLB_RB=example-owner/project-b
GLB_REPOS="example-owner/project-a,example-owner/project-b"

glb_install_gh() {
  mv "$DG_BIN/gh" "$DG_BIN/gh.base"
  cat > "$DG_BIN/gh" <<'GLB_GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd); S="$HERE/state"
if [ "$1" != api ]; then exec "$HERE/gh.base" "$@"; fi
dec() { python3 -I -c 'import sys,urllib.parse as u; sys.stdout.write(u.unquote(sys.argv[1]))' "$1"; }
orig="$*"
shift
method=""; path=""; expr=""; obj='{}'; stdin_json=""; newargs=(api)
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) method=$2; newargs+=("$1" "$2"); shift ;;
    --jq|-q) expr=$2; newargs+=("$1" "$2"); shift ;;
    -f|-F|--field|--raw-field)
      kv=$2; k=${kv%%=*}; v=${kv#*=}; newargs+=("$1" "$2"); shift
      case "$k" in
        *'[]') kk=${k%??}; obj=$(printf '%s' "$obj" | jq -c --arg k "$kk" --arg v "$v" '.[$k] = ((.[$k] // []) + [$v])') ;;
        *) obj=$(printf '%s' "$obj" | jq -c --arg k "$k" --arg v "$v" '.[$k] = $v') ;;
      esac ;;
    --input) stdin_json=$(cat); newargs+=("$1" "$2"); shift ;;
    -H|--header) newargs+=("$1" "$2"); shift ;;
    -*) newargs+=("$1") ;;
    *) if [ -z "$path" ]; then path=$(dec "$1"); newargs+=("$path"); else newargs+=("$1"); fi ;;
  esac
  shift
done
[ -n "$stdin_json" ] && obj=$stdin_json
[ -n "$method" ] || { if [ "$obj" != "{}" ]; then method=POST; else method=GET; fi; }
path=${path#/}; p=${path%%\?*}
emit() { if [ -n "$expr" ]; then jq -r "$expr"; else cat; fi; }
case "$p" in
  repos/*/*/labels|repos/*/*/labels/*)
    printf '%s\n' "$orig" >> "$HERE/gh-calls.log"
    owner=$(printf '%s' "$p" | cut -d/ -f2); repo=$(printf '%s' "$p" | cut -d/ -f3); rk="${owner}_${repo}"
    name=$(printf '%s' "$p" | cut -d/ -f5-)
    LF="$S/labels/$rk.json"; D="$S/issues/$rk"; mkdir -p "$S/labels" "$D"; [ -f "$LF" ] || echo '[]' > "$LF"
    [ "$method" = GET ] || printf '%s %s %s\n' "$method" "$p" "$obj" >> "$HERE/writes.log"
    exists() { jq -e --arg n "$1" 'any(.[]; .name == $n)' "$LF" >/dev/null; }
    if [ -z "$name" ]; then
      case "$method" in
        GET) emit < "$LF" ;;
        POST)
          n=$(printf '%s' "$obj" | jq -r '.name // empty')
          if exists "$n"; then echo "gh: Validation Failed (HTTP 422) already_exists" >&2; exit 1; fi
          jq -c --argjson o "$obj" '. + [{name:$o.name, color:($o.color // ""), description:($o.description // "")}]' "$LF" > "$LF.tmp" && mv "$LF.tmp" "$LF"
          echo '{}' | emit ;;
        *) echo "fake gh: unsupported $method $p" >&2; exit 1 ;;
      esac
    else
      case "$method" in
        GET) if exists "$name"; then jq -c --arg n "$name" '.[] | select(.name == $n)' "$LF" | emit; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
        PATCH)
          if [ -f "$HERE/fail-label-patch" ]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
          exists "$name" || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
          new=$(printf '%s' "$obj" | jq -r '.new_name // empty')
          if [ -n "$new" ] && exists "$new"; then echo "gh: Validation Failed (HTTP 422) already_exists" >&2; exit 1; fi
          jq -c --arg o "$name" --argjson b "$obj" 'map(if .name == $o then (.name = ($b.new_name // .name) | .color = ($b.color // .color) | .description = ($b.description // .description)) else . end)' "$LF" > "$LF.tmp" && mv "$LF.tmp" "$LF"
          if [ -n "$new" ]; then
            for f in "$D"/*.json; do [ -e "$f" ] || continue
              jq -c --arg o "$name" --arg n "$new" '.labels |= map(if .name == $o then .name = $n else . end)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done
          fi
          echo '{}' | emit ;;
        DELETE)
          exists "$name" || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
          jq -c --arg n "$name" 'map(select(.name != $n))' "$LF" > "$LF.tmp" && mv "$LF.tmp" "$LF"
          for f in "$D"/*.json; do [ -e "$f" ] || continue
            jq -c --arg n "$name" '.labels |= map(select(.name != $n))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done
          echo '' | emit ;;
        *) echo "fake gh: unsupported $method $p" >&2; exit 1 ;;
      esac
    fi ;;
  *)
    if [ -n "$stdin_json" ]; then printf '%s' "$stdin_json" | "$HERE/gh.base" "${newargs[@]}"; else "$HERE/gh.base" "${newargs[@]}"; fi ;;
esac
GLB_GH_EOF
  chmod +x "$DG_BIN/gh"
}

glb_setup() {
  dg_setup
  local bi="$DG_HOME/checkouts/bi"
  fixture_repo "$bi" example-owner/Business-Intelligence
  echo "DISPATCH_REPOS+=(\"example-owner/Business-Intelligence:$bi\")" >> "$DG_HOME/.claude/pipeline/config.local.sh"
  mkdir -p "$DG_ST/issues/$GLB_BI" "$DG_ST/labels"
  rm -f "$DG_ST/issues/$GLB_A"/*.json "$DG_ST/issues/$GLB_B"/*.json   # start from an empty world; tests seed what they need
  ( cd "$DG_CK_A" && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init )
  GLB_SHA=$(git -C "$DG_CK_A" rev-parse HEAD | cut -c1-7)
  glb_install_gh
  unset GH_TOKEN
}
glb_teardown() { unset GH_TOKEN; dg_teardown; }

# glb_ticket <rk> <n> <open|closed> [labels-csv] [body] [pr]
glb_ticket() {
  local rk=$1 n=$2 st=$3 lb=${4:-} body=${5:-} pr=${6:-}
  jq -nc --argjson n "$n" --arg st "$st" --arg lb "$lb" --arg body "$body" --arg pr "$pr" --arg now "$DG_NOW" '
    {number:$n, title:("ticket " + ($n|tostring)), body:$body, state:$st,
     labels:($lb | split(",") | map(select(length > 0)) | map({name:.})),
     milestone:null, created_at:$now, updated_at:$now, closed_at:(if $st == "closed" then $now else null end)}
    + (if $pr != "" then {pull_request:{url:"x"}} else {} end)' > "$DG_ST/issues/$rk/$n.json"
}
# glb_label <rk> <name> [color] [description]
glb_label() {
  local f="$DG_ST/labels/$1.json"; [ -f "$f" ] || echo '[]' > "$f"
  jq -c --arg n "$2" --arg c "${3:-ededed}" --arg d "${4:-}" '. + [{name:$n, color:$c, description:$d}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
glb_label_names() { jq -r '.[].name' "$DG_ST/labels/$1.json" 2>/dev/null; }          # <rk>
glb_has_label() { jq -e --arg l "$3" 'any(.labels[]; .name == $l)' "$DG_ST/issues/$1/$2.json" >/dev/null 2>&1; }   # <rk> <n> <label>
glb_strip_label() {                                                                   # <rk> <n> <label>
  local f="$DG_ST/issues/$1/$2.json"
  jq -c --arg l "$3" '.labels |= map(select(.name != $l))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
glb_count_label() {                                                                   # <label> -> number of issues in a,b carrying it
  local c=0 f
  for f in "$DG_ST/issues/$GLB_A"/*.json "$DG_ST/issues/$GLB_B"/*.json; do
    [ -e "$f" ] || continue
    jq -e --arg l "$1" 'any(.labels[]; .name == $l)' "$f" >/dev/null 2>&1 && c=$((c + 1))
  done
  echo "$c"
}
glb_calls_not_api() { awk '$1 != "api" && NF > 0' "$DG_BIN/gh-calls.log" | wc -l | tr -d ' '; }
glb_comments_all() { cat "$DG_ST"/comments/*.json 2>/dev/null; }

# glb_v2 <registry issue n> <label> <title> <repos-csv> <active|stopped|delivered> <id> [requirements]
# A v2 registry issue (the block shape from the ticket, plus spec/host for the existing consumers).
glb_v2() {
  local n=$1 label=$2 title=$3 repos=$4 st=$5 id=$6 req=${7:-} labels='["delivery-goal"]' state=open closed=null block
  block=$(jq -nc --arg id "$id" --arg t "$title" --arg l "$label" --arg r "$repos" --argjson o "$n" --arg req "$req" --arg c "$DG_NOW" \
    '{v:2,id:$id,title:$t,label:$l,repos:($r|split(",")),order:$o,mockups:"review",go:true,host_pref:"host-a",host:"host-a",
      spec:("label:"+$l),requirements:$req,created:$c}')
  case "$st" in
    stopped)   labels='["delivery-goal","goal-stopped"]'; state=closed; closed="\"$DG_NOW\"" ;;
    delivered) state=closed; closed="\"$DG_NOW\"" ;;
  esac
  jq -nc --argjson n "$n" --arg title "Goal: $title" --arg body "$(printf 'Goal: %s\n\n```json\n%s\n```\n' "$title" "$block")" \
    --argjson labels "$labels" --arg state "$state" --argjson closed "$closed" --arg now "$DG_NOW" \
    '{number:$n, title:$title, body:$body, state:$state, labels:($labels|map({name:.})), milestone:null,
      closed_at:$closed, created_at:$now, updated_at:$now}' > "$DG_ST/issues/$DG_REG/$n.json"
}
glb_cache() { echo "{\"id\":\"$2\",\"issue\":$1,\"host\":\"host-a\"}" > "$DG_PIPE/goal-$2.json"; }   # <registry n> <id>

# glb_sync — goal_sync in the sandbox; slog / report_status_async live in supervisor.sh, so they are recorded here.
glb_sync() {
  dg_lib 'slog(){ printf "%s\n" "$*" >> "$HOME/slog.txt"; }; report_status_async(){ printf "%s\n" "$*" >> "$HOME/rs.txt"; }
          HERE="$HOME/checkouts/project-a"; GOAL_THIS_HOST=host-a; GOAL_ERR_PUSHED=0; goal_sync'
}
glb_events() { cat "$DG_HOME/logs/pipeline/events.jsonl" 2>/dev/null; }

# ------------------------------------------------------------------ label rule (table-driven) -----------------
# Hand arithmetic for every row (1-based positions, short = title after normalising):
#  r1 "Cross-repo goal model for the pipeline" = 38 chars; spaces at 11,16,22,26,30; last space <= 37 is 30 -> keep 29 chars.
#  r2 comma removed: "Quotes invoices and payments" = 6+1+8+1+3+1+8 = 28 chars (<= 37, untouched).
#  r3 9+1+9+1+9+1+7 = 37 chars exactly -> unchanged.
#  r4 r3 + " eee": the space is char 38, so cutting at 37 sits on a word boundary -> keeps all 37.
#  r5 60 'x' no spaces -> hard cut at 37.
#  r6 36 'x' + "." + 10 'y' (47, no spaces) -> hard cut at 37 = 36 x + "." -> trailing punctuation trimmed -> 36 x.
#  r7 "Ship it." -> trailing "." trimmed.   r8 whitespace collapsed and trimmed.   r9 control char \001 removed (not a space).
#  r10 9+1+9+1+9+1+8 = 38 chars; space at 30 is the last <= 37 -> "aaaaaaaaa bbbbbbbbb ccccccccc" (29).
# Label = "goal: " (6) + short (<= 37) -> <= 43; + " (done)" (7) -> <= 50 (GitHub's limit).
test_glb_label_rule_table() {
  glb_setup
  local x37 x36 x60 y10 rc=0 title want got row=0 len
  x37="aaaaaaaaa bbbbbbbbb ccccccccc ddddddd"
  x36=$(printf 'x%.0s' $(seq 1 36)); x60=$(printf 'x%.0s' $(seq 1 60)); y10=$(printf 'y%.0s' $(seq 1 10))
  while IFS='|' read -r title want; do
    [ -n "$title$want" ] || continue
    row=$((row + 1))
    title=$(printf '%b' "$title")
    dg_lib "goal_label_name $(printf '%q' "$title")"
    got=$DG_OUT; len=${#got}
    assert_eq "$got" "$want" "label row $row for [$title]" || rc=1
    [ "$len" -le 43 ] || { fail "row $row: label is $len chars, max 43"; rc=1; }
    [ $((len + 7)) -le 50 ] || { fail "row $row: label + ' (done)' is $((len + 7)) chars, max 50"; rc=1; }
  done <<EOF
Cross-repo goal model for the pipeline|goal: Cross-repo goal model for the
Quotes, invoices and payments|goal: Quotes invoices and payments
$x37|goal: $x37
$x37 eee|goal: $x37
$x60|goal: ${x60:0:37}
$x36.$y10|goal: $x36
Ship it.|goal: Ship it
  Quotes   tool  |goal: Quotes tool
Quotes\001tool|goal: Quotestool
aaaaaaaaa bbbbbbbbb ccccccccc dddddddd|goal: aaaaaaaaa bbbbbbbbb ccccccccc
EOF
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ spec forms / parser -----------------------
test_glb_parse_label_spec_and_rejects_empty() {
  glb_setup
  local rc=0
  dg_lib 'goal_parse "label:goal: Foo bar"'
  assert_eq "$DG_RC" "0" "label spec parses (stderr: $DG_ERR)" || rc=1
  assert_eq "$(printf '%s' "$DG_OUT" | cut -f2)" "label" "kind is label" || rc=1
  assert_eq "$(printf '%s' "$DG_OUT" | cut -f3)" "goal: Foo bar" "ref is the exact label name" || rc=1
  dg_lib 'goal_parse "label:"'
  assert_eq "$DG_RC" "1" "empty label name is malformed" || rc=1
  assert_contains "$DG_ERR" "malformed" "empty label name: message" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ membership --------------------------------
# 2 repos, 3 labelled issues (a#101 open, a#102 closed, b#1 open). Not members: a#103 (a PR), a#7 (unlabelled),
# b#2 (other goal's label), c#5 (repo not in the goal).
test_glb_membership_scope_rows_from_both_repos() {
  glb_setup
  local L="goal: Membership test" rc=0 rows want pa pb
  mkdir -p "$DG_ST/issues/example-owner_project-c"
  glb_label $GLB_A "$L"; glb_label $GLB_B "$L"; glb_label $GLB_B "goal: Other"
  glb_ticket $GLB_A 101 open "$L"; glb_ticket $GLB_A 102 closed "$L"; glb_ticket $GLB_A 103 open "$L" "" pr
  glb_ticket $GLB_A 7 open; glb_ticket $GLB_B 1 open "$L"; glb_ticket $GLB_B 2 open "goal: Other"
  glb_ticket example-owner_project-c 5 open "$L"
  glb_v2 900 "$L" "Membership test" "$GLB_REPOS" active glb-member
  dg_lib "_goal_scope_rows $(printf '%q' "label:$L") glb-member"
  assert_eq "$DG_RC" "0" "scope rows rc (stderr: $DG_ERR)" || rc=1
  rows=$(printf '%s\n' "$DG_OUT" | sort)
  want=$(printf '%s\n' "$GLB_RA#101	open" "$GLB_RA#102	closed" "$GLB_RB#1	open" | sort)
  assert_eq "$rows" "$want" "scope rows" || rc=1
  dg_lib "goal_scope $(printf '%q' "label:$L") glb-member"
  assert_eq "$(printf '%s\n' "$DG_OUT" | sort | tr '\n' ' ')" "$GLB_RA#101 $GLB_RA#102 $GLB_RB#1 " "goal_scope refs" || rc=1
  # REST only: one issues?labels=…&state=all lookup per repo, and nothing but `gh api` calls.
  pa=$(grep -cE 'repos/example-owner/project-a/issues\?.*labels=.*state=all|repos/example-owner/project-a/issues\?.*state=all.*labels=' "$DG_BIN/gh-calls.log")
  pb=$(grep -cE 'repos/example-owner/project-b/issues\?.*labels=.*state=all|repos/example-owner/project-b/issues\?.*state=all.*labels=' "$DG_BIN/gh-calls.log")
  [ "$pa" -ge 1 ] || { fail "no state=all label lookup on project-a"; rc=1; }
  [ "$pb" -ge 1 ] || { fail "no state=all label lookup on project-b"; rc=1; }
  assert_eq "$(glb_calls_not_api)" "0" "no non-REST (GraphQL/project) gh call" || rc=1
  glb_teardown; return $rc
}

# v:1 and v:2 registry blocks side by side: both listed, and the v2 label goal's scope resolves.
test_glb_registry_lists_v1_and_v2_blocks() {
  glb_setup
  local L="goal: Mixed" rc=0
  glb_label $GLB_A "$L"; glb_ticket $GLB_A 101 open "$L"
  DG_GOAL_ID=$DG_ID_MS; dg_goal 901 "$DG_SPEC_MS" host-a active
  glb_v2 900 "$L" "Mixed" "$GLB_REPOS" active glb-mixed
  dg_lib 'goal_registry_list'
  assert_contains "$DG_OUT" "$DG_ID_MS" "v:1 goal listed" || rc=1
  assert_contains "$DG_OUT" "glb-mixed" "v:2 goal listed" || rc=1
  dg_lib "goal_scope $(printf '%q' "label:$L") glb-mixed"
  assert_eq "$DG_OUT" "$GLB_RA#101" "v:2 goal scope resolves while a v:1 goal is registered" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ overlap / reuse guard ----------------------
# glb_reg <title> [extra args…] — register a label goal for project-a + project-b seeded by a#7.
glb_reg() { local t=$1; shift; dg_run --repos "$GLB_REPOS" --title "$t" --requirements "$GLB_RA#7" "$@"; }
glb_seed7() { glb_ticket $GLB_A 7 open "" "Requirements: build the thing."; }

test_glb_reuse_guard_refuses_same_label_of_active_goal() {
  glb_setup
  local rc=0
  glb_seed7
  glb_label $GLB_A "goal: Foo bar"; glb_label $GLB_B "goal: Foo bar"
  glb_v2 900 "goal: Foo bar" "Foo bar" "$GLB_REPOS" active glb-existing
  glb_reg "Foo bar"
  assert_eq "$DG_RC" "1" "same label as an active goal is refused (stderr: $DG_ERR)" || rc=1
  assert_contains "$DG_ERR" "glb-existing" "message names the clashing goal" || rc=1
  assert_eq "$(dg_reg_count)" "1" "no second registry issue" || rc=1
  glb_has_label $GLB_A 7 "goal: Foo bar" && { fail "refused goal must not label the seed ticket"; rc=1; }
  glb_teardown; return $rc
}

test_glb_same_title_allowed_after_old_goal_closed() {
  glb_setup
  local rc=0 f
  glb_seed7
  glb_v2 900 "goal: Foo bar" "Foo bar" "$GLB_REPOS" stopped glb-old
  glb_reg "Foo bar"
  assert_eq "$DG_RC" "0" "re-registering the same title after the old goal closed (stderr: $DG_ERR)" || rc=1
  assert_eq "$(dg_reg_count)" "2" "old closed + new registry issue" || rc=1
  glb_has_label $GLB_A 7 "goal: Foo bar" || { fail "seed ticket carries the label"; rc=1; }
  glb_teardown; return $rc
}

test_glb_overlap_refuses_shared_ticket_of_other_goal() {
  glb_setup
  local rc=0
  glb_seed7
  glb_label $GLB_A "goal: One"; glb_label $GLB_B "goal: One"; glb_label $GLB_A "goal: Two"
  glb_ticket $GLB_A 101 open "goal: One,goal: Two"
  glb_v2 900 "goal: One" "One" "$GLB_REPOS" active glb-one
  glb_reg "Two"
  assert_eq "$DG_RC" "1" "a ticket shared with a live goal is refused (stderr: $DG_ERR)" || rc=1
  assert_contains "$DG_ERR" "glb-one" "message names the overlapping goal" || rc=1
  assert_eq "$(dg_reg_count)" "1" "no second registry issue" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ register v2 --------------------------------
test_glb_register_creates_labels_block_and_seed() {
  glb_setup
  local T="Cross-repo goal model for the pipeline" L="goal: Cross-repo goal model for the" rc=0 f n blk ca cb da
  glb_seed7; glb_ticket $GLB_B 1 open
  glb_reg "$T"
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  glb_label_names $GLB_A | grep -qxF -- "$L" || { fail "label $L missing in project-a"; rc=1; }
  glb_label_names $GLB_B | grep -qxF -- "$L" || { fail "label $L missing in project-b"; rc=1; }
  ca=$(jq -r --arg l "$L" '.[] | select(.name == $l) | .color' "$DG_ST/labels/$GLB_A.json")
  cb=$(jq -r --arg l "$L" '.[] | select(.name == $l) | .color' "$DG_ST/labels/$GLB_B.json")
  assert_ne "$ca" "" "label colour is set" || rc=1
  assert_eq "$ca" "$cb" "same colour in every repo" || rc=1
  glb_has_label $GLB_A 7 "$L" || { fail "the requirements ticket carries the label"; rc=1; }
  f=$(dg_reg_files | head -1); n=$(basename "$f" .json)
  da=$(jq -r --arg l "$L" '.[] | select(.name == $l) | .description' "$DG_ST/labels/$GLB_A.json")
  [ "${#da}" -le 100 ] || { fail "label description is ${#da} chars, max 100"; rc=1; }
  case "$da" in "$T"*) ;; *) fail "description starts with the full title, got [$da]"; rc=1 ;; esac
  case "$da" in *"example-owner/registry/issues/$n") ;; *) fail "description ends with the registry issue URL, got [$da]"; rc=1 ;; esac
  blk=$(dg_block "$f")
  assert_eq "$(printf '%s' "$blk" | jq -r .v)" "2" "block v" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r .title)" "$T" "block title" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r .label)" "$L" "block label" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -c .repos)" "[\"$GLB_RA\",\"$GLB_RB\"]" "block repos" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r .order)" "$n" "order defaults to the registry issue number" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r .mockups)" "review" "mockups defaults to review" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r .go)" "true" "go (requirements present)" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r 'has("host_pref")')" "true" "host_pref key" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r .requirements)" "$GLB_RA#7" "requirements ref" || rc=1
  assert_eq "$(glb_calls_not_api)" "0" "register made no non-REST (GraphQL/project) gh call" || rc=1
  glb_teardown; return $rc
}

test_glb_register_skips_business_intelligence() {
  glb_setup
  local rc=0
  glb_seed7
  dg_run --repos "$GLB_RA,example-owner/Business-Intelligence" --title "BI skip" --requirements "$GLB_RA#7"
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  glb_label_names $GLB_A | grep -qxF -- "goal: BI skip" || { fail "label created in project-a"; rc=1; }
  assert_eq "$(glb_label_names $GLB_BI | wc -l | tr -d ' ')" "0" "no label created in Business-Intelligence" || rc=1
  assert_contains "$(printf '%s\n%s' "$DG_OUT" "$DG_ERR" | tr '[:upper:]' '[:lower:]')" "skip" "a skip is logged" || rc=1
  assert_contains "$DG_OUT$DG_ERR" "Business-Intelligence" "the skip names the repo" || rc=1
  glb_teardown; return $rc
}

test_glb_label_spec_binds_existing_label() {
  glb_setup
  local rc=0 f blk
  glb_seed7
  glb_label $GLB_A "goal: Existing one"; glb_label $GLB_B "goal: Existing one"
  glb_ticket $GLB_A 8 open "goal: Existing one"
  dg_run "label:goal: Existing one" --repos "$GLB_REPOS" --requirements "$GLB_RA#7"
  assert_eq "$DG_RC" "0" "register by label (stderr: $DG_ERR)" || rc=1
  f=$(dg_reg_files | head -1); blk=$(dg_block "$f")
  assert_eq "$(printf '%s' "$blk" | jq -r .label)" "goal: Existing one" "block label is the exact bound label" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -c .repos)" "[\"$GLB_RA\",\"$GLB_RB\"]" "block repos" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ go grant (amends #313) ---------------------
# Label "goal: Go test" already on: a#8 open, a#9 closed, a#10 open + source:sentry, a#12 open + agent-proposed,
# b#1 open, b#2 open + agent-go. Seed a#7 (non-empty body) is labelled by register.
glb_go_world() {
  local L="goal: Go test"
  glb_label $GLB_A "$L"; glb_label $GLB_B "$L"
  glb_seed7
  glb_ticket $GLB_A 8 open "$L"; glb_ticket $GLB_A 9 closed "$L"; glb_ticket $GLB_A 10 open "$L,source:sentry"
  glb_ticket $GLB_A 12 open "$L,agent-proposed"; glb_ticket $GLB_B 1 open "$L"; glb_ticket $GLB_B 2 open "$L,agent-go"
}
glb_has_go() { glb_has_label "$1" "$2" agent-go; }

test_glb_register_grants_go_with_guards() {
  glb_setup
  local rc=0 f body
  glb_go_world
  glb_reg "Go test"
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  for t in "$GLB_A 7" "$GLB_A 8" "$GLB_A 12" "$GLB_B 1" "$GLB_B 2"; do
    glb_has_go $t || { fail "agent-go missing on ${t}"; rc=1; }
  done
  glb_has_go $GLB_A 9 && { fail "closed ticket must not get agent-go"; rc=1; }
  glb_has_go $GLB_A 10 && { fail "source:sentry ticket must not get agent-go without --include-sentry"; rc=1; }
  glb_has_label $GLB_A 12 agent-proposed && { fail "agent-proposed removed from a#12"; rc=1; }
  grep -qF "POST repos/example-owner/project-b/issues/2/labels" "$DG_BIN/writes.log" && { fail "b#2 already had agent-go: no edit"; rc=1; }
  f=$(dg_reg_files | head -1); body=$(jq -r .body "$f")
  printf '%s' "$body" | grep -Eq 'Go-granted: 20[0-9]{2}-[0-9]{2}-[0-9]{2}' || { fail "registry body has 'Go-granted: <ISO date>'"; rc=1; }
  for ref in "$GLB_RA#7" "$GLB_RA#8" "$GLB_RA#12" "$GLB_RB#1"; do
    assert_contains "$body" "$ref" "per-ticket grant list names $ref" || rc=1
  done
  assert_not_contains "$body" "$GLB_RA#10" "sentry ticket not in the grant list" || rc=1
  assert_contains "$(glb_comments_all)" "**[supervisor] NOTE**" "ticket comment uses the non-routing marker" || rc=1
  assert_not_contains "$(glb_comments_all)" "[delivery-lead]" "no delivery-lead marker posted by a script" || rc=1
  glb_teardown; return $rc
}

test_glb_register_include_sentry_labels_sentry_ticket() {
  glb_setup
  local rc=0
  glb_go_world
  glb_reg "Go test" --include-sentry
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  glb_has_go $GLB_A 10 || { fail "--include-sentry: a#10 gets agent-go"; rc=1; }
  glb_has_go $GLB_A 8 || { fail "--include-sentry: a#8 still gets agent-go"; rc=1; }
  glb_teardown; return $rc
}

test_glb_register_closed_requirements_ticket_counts() {
  glb_setup
  local rc=0
  glb_go_world
  glb_ticket $GLB_A 7 closed "" "Requirements: build the thing."
  glb_reg "Go test"
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  glb_has_go $GLB_A 8 || { fail "a closed non-empty requirements ticket still grants go"; rc=1; }
  glb_teardown; return $rc
}

# glb_nogo_check <label> <args…> — shared body: registered, zero agent-go anywhere, reason printed.
glb_nogo_check() {
  local what=$1 rc=0 f
  assert_eq "$DG_RC" "0" "$what: still registers (stderr: $DG_ERR)" || rc=1
  assert_eq "$(dg_reg_count)" "1" "$what: registry issue exists" || rc=1
  assert_eq "$(glb_count_label agent-go)" "0" "$what: zero agent-go applied" || rc=1
  assert_contains "$(printf '%s\n%s' "$DG_OUT" "$DG_ERR" | tr '[:upper:]' '[:lower:]')" "requirements" "$what: says why (requirements)" || rc=1
  f=$(dg_reg_files | head -1)
  assert_not_contains "$(jq -r .body "$f")" "Go-granted:" "$what: no grant record" || rc=1
  return $rc
}
glb_nogo_world() {
  local L="goal: Go test"
  glb_label $GLB_A "$L"; glb_label $GLB_B "$L"
  glb_ticket $GLB_A 8 open "$L"; glb_ticket $GLB_B 1 open "$L"
  glb_ticket $GLB_A 13 open "" ""     # exists but empty
}
test_glb_missing_requirements_registers_without_go() {
  glb_setup
  local rc=0
  glb_nogo_world
  dg_run --repos "$GLB_REPOS" --title "Go test"
  glb_nogo_check "no --requirements" || rc=1
  glb_teardown; return $rc
}
test_glb_requirements_ticket_not_found_registers_without_go() {
  glb_setup
  local rc=0
  glb_nogo_world
  dg_run --repos "$GLB_REPOS" --title "Go test" --requirements "$GLB_RA#999"
  glb_nogo_check "requirements ticket does not exist" || rc=1
  glb_teardown; return $rc
}
test_glb_requirements_ticket_empty_registers_without_go() {
  glb_setup
  local rc=0
  glb_nogo_world
  dg_run --repos "$GLB_REPOS" --title "Go test" --requirements "$GLB_RA#13"
  glb_nogo_check "requirements ticket is empty" || rc=1
  glb_teardown; return $rc
}

# Loop guard: JP removes agent-go from a#8 after the grant; the next goal sync must not put it back.
test_glb_loop_guard_removed_go_not_readded() {
  glb_setup
  local rc=0 f
  glb_go_world
  glb_reg "Go test"
  assert_eq "$DG_RC" "0" "register exits 0 (stderr: $DG_ERR)" || rc=1
  glb_has_go $GLB_A 8 || { fail "precondition: a#8 granted at register"; rc=1; }
  f=$(dg_reg_files | head -1)
  assert_contains "$(jq -r .body "$f")" "$GLB_RA#8" "grant recorded per ticket in the registry" || rc=1
  glb_strip_label $GLB_A 8 agent-go
  glb_sync
  glb_has_go $GLB_A 8 && { fail "sync re-added agent-go that JP removed"; rc=1; }
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ close-time strip + rename -----------------
# World: stopped goal glb-foo (label "goal: Foo", repos a,b). Open tickets a#1, a#2 (+keep), b#1 carry it; a#3 closed
# carries it; b#2 does not.
glb_closed_world() {
  glb_label $GLB_A "goal: Foo"; glb_label $GLB_B "goal: Foo"; glb_label $GLB_A keep
  glb_ticket $GLB_A 1 open "goal: Foo"; glb_ticket $GLB_A 2 open "goal: Foo,keep"; glb_ticket $GLB_A 3 closed "goal: Foo"
  glb_ticket $GLB_B 1 open "goal: Foo"; glb_ticket $GLB_B 2 open ""
  glb_v2 900 "goal: Foo" "Foo" "$GLB_REPOS" "${1:-stopped}" glb-foo
  glb_cache 900 glb-foo
}

test_glb_close_strips_open_tickets_and_renames_label() {
  glb_setup
  local rc=0
  glb_closed_world stopped
  glb_sync
  assert_eq "$DG_RC" "0" "goal_sync exits 0 (stderr: $DG_ERR)" || rc=1
  glb_has_label $GLB_A 1 "goal: Foo" && { fail "open a#1 still labelled"; rc=1; }
  glb_has_label $GLB_A 2 "goal: Foo" && { fail "open a#2 still labelled"; rc=1; }
  glb_has_label $GLB_B 1 "goal: Foo" && { fail "open b#1 still labelled"; rc=1; }
  glb_has_label $GLB_A 2 keep || { fail "unrelated label on a#2 must stay"; rc=1; }
  for rk in $GLB_A $GLB_B; do
    glb_label_names $rk | grep -qxF -- "goal: Foo" && { fail "$rk: stripped label still exists"; rc=1; }
    glb_label_names $rk | grep -qxF -- "goal: Foo (done)" || { fail "$rk: 'goal: Foo (done)' missing"; rc=1; }
  done
  glb_has_label $GLB_A 3 "goal: Foo (done)" || { fail "closed a#3 carries the renamed label"; rc=1; }
  glb_teardown; return $rc
}

test_glb_delivered_goal_also_cleaned() {
  glb_setup
  local rc=0
  glb_closed_world delivered
  glb_sync
  glb_has_label $GLB_A 1 "goal: Foo" && { fail "delivered goal: open a#1 still labelled"; rc=1; }
  glb_label_names $GLB_B | grep -qxF -- "goal: Foo (done)" || { fail "delivered goal: label not renamed in project-b"; rc=1; }
  glb_teardown; return $rc
}

test_glb_existing_done_label_means_delete_stripped_label() {
  glb_setup
  local rc=0 n
  glb_closed_world stopped
  glb_label $GLB_B "goal: Foo (done)"; glb_ticket $GLB_B 9 closed "goal: Foo (done)"
  glb_sync
  glb_label_names $GLB_B | grep -qxF -- "goal: Foo" && { fail "stripped label must be deleted in project-b"; rc=1; }
  n=$(glb_label_names $GLB_B | grep -cxF -- "goal: Foo (done)")
  assert_eq "$n" "1" "exactly one '(done)' label in project-b" || rc=1
  glb_has_label $GLB_B 1 "goal: Foo" && { fail "open b#1 still labelled"; rc=1; }
  glb_has_label $GLB_B 9 "goal: Foo (done)" || { fail "old closed b#9 keeps its (done) label"; rc=1; }
  glb_label_names $GLB_A | grep -qxF -- "goal: Foo (done)" || { fail "project-a (no clash) renamed"; rc=1; }
  glb_teardown; return $rc
}

test_glb_close_cleanup_is_idempotent() {
  glb_setup
  local rc=0 w1 w2
  glb_closed_world stopped
  glb_sync
  glb_label_names $GLB_A | grep -qxF -- "goal: Foo (done)" || { fail "precondition: first sync renamed"; rc=1; }
  w1=$(dg_writes)
  glb_sync
  assert_eq "$DG_RC" "0" "second sync exits 0 (stderr: $DG_ERR)" || rc=1
  w2=$(dg_writes)
  assert_eq "$w2" "$w1" "second sync writes nothing to the repos" || rc=1
  assert_eq "$(grep -c 'error' "$DG_HOME/slog.txt" 2>/dev/null)" "0" "second sync logs no error" || rc=1
  glb_teardown; return $rc
}

test_glb_active_goal_label_is_left_alone() {
  glb_setup
  local rc=0
  glb_closed_world active
  glb_ticket $GLB_A 4 open "goal: Foo"
  glb_sync
  glb_has_label $GLB_A 1 "goal: Foo" || { fail "active goal: a#1 keeps its label"; rc=1; }
  glb_label_names $GLB_A | grep -qxF -- "goal: Foo" || { fail "active goal: label stays"; rc=1; }
  # positive: a closed goal in the same registry IS cleaned (keeps this test red until the lifecycle exists)
  glb_label $GLB_A "goal: Bar"; glb_ticket $GLB_A 5 open "goal: Bar"
  glb_v2 901 "goal: Bar" "Bar" "$GLB_REPOS" stopped glb-bar; glb_cache 901 glb-bar
  glb_sync
  glb_has_label $GLB_A 5 "goal: Bar" && { fail "closed goal a#5 stripped"; rc=1; }
  glb_has_label $GLB_A 1 "goal: Foo" || { fail "active goal still untouched after 2nd sync"; rc=1; }
  glb_teardown; return $rc
}

test_glb_same_title_after_close_gets_fresh_label_and_no_old_members() {
  glb_setup
  local rc=0 f
  glb_closed_world stopped
  glb_sync
  glb_seed7
  glb_reg "Foo"
  assert_eq "$DG_RC" "0" "re-register 'Foo' after the old goal closed (stderr: $DG_ERR)" || rc=1
  glb_label_names $GLB_A | grep -qxF -- "goal: Foo" || { fail "fresh 'goal: Foo' label in project-a"; rc=1; }
  glb_label_names $GLB_B | grep -qxF -- "goal: Foo" || { fail "fresh 'goal: Foo' label in project-b"; rc=1; }
  assert_eq "$(glb_count_label 'goal: Foo')" "1" "only the new seed ticket carries the fresh label" || rc=1
  glb_has_label $GLB_A 7 "goal: Foo" || { fail "seed a#7 carries it"; rc=1; }
  glb_has_label $GLB_A 3 "goal: Foo" && { fail "old closed a#3 must not be a member of the new goal"; rc=1; }
  glb_has_label $GLB_A 3 "goal: Foo (done)" || { fail "old a#3 keeps '(done)'"; rc=1; }
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ observability -----------------------------
test_glb_error_row_written_when_label_rename_fails() {
  glb_setup
  local rc=0 row
  export GH_TOKEN=glb-secret-token-value
  glb_closed_world stopped
  : > "$DG_BIN/fail-label-patch"
  glb_sync
  assert_eq "$DG_RC" "0" "sync survives a failed rename (stderr: $DG_ERR)" || rc=1
  row=$(glb_events | jq -c 'select(.event == "error")' | head -1)
  assert_ne "$row" "" "an event=error row is written to events.jsonl" || rc=1
  if [ -n "$row" ]; then
    assert_eq "$(printf '%s' "$row" | jq -r .release)" "$GLB_SHA" "release = first 7 chars of the checkout HEAD" || rc=1
    assert_eq "$(printf '%s' "$row" | jq -r .host)" "host-a" "host tag" || rc=1
    assert_eq "$(printf '%s' "$row" | jq -r '(.route // "") | test("goal")')" "true" "route tag mentions goal" || rc=1
    assert_not_contains "$row" "glb-secret-token-value" "no token in the event" || rc=1
    assert_not_contains "$row" "Foo" "no goal title in the event" || rc=1
  fi
  assert_contains "$(cat "$DG_HOME/slog.txt" 2>/dev/null)" "[goal] error" "goal_err slog line" || rc=1
  assert_contains "$(cat "$DG_HOME/rs.txt" 2>/dev/null)" "goal-error" "existing status-push alert path used" || rc=1
  glb_teardown; return $rc
}

# ------------------------------------------------------------------ static guards ------------------------------
test_glb_no_graphql_no_project_scope_in_goal_scripts() {
  local rc=0 f hits
  for f in goal-lib.sh deliver.sh; do
    hits=$(grep -vE '^[[:space:]]*#' "$DG_SKILL/$f" | grep -Ei 'graphql|read:project|gh project|gh issue |gh pr |--scopes' || true)
    assert_eq "$hits" "" "$f: no GraphQL / project-scope call in code" || rc=1
  done
  # positive (red until implemented): the label rule helper exists and works
  glb_setup
  dg_lib 'goal_label_name "Probe"'
  assert_eq "$DG_OUT" "goal: Probe" "goal_label_name implemented" || rc=1
  glb_teardown
  return $rc
}

test_glb_no_delivery_lead_marker_emitted_from_shell() {
  local rc=0 f
  for f in goal-lib.sh deliver.sh; do
    grep -vE '^[[:space:]]*#' "$DG_SKILL/$f" | grep -qF '[delivery-lead]' && { fail "$f emits a [delivery-lead] marker"; rc=1; }
  done
  grep -qF '[supervisor] NOTE' "$DG_SKILL/deliver.sh" "$DG_SKILL/goal-lib.sh" || { fail "no **[supervisor] NOTE** emitter in deliver.sh/goal-lib.sh"; rc=1; }
  return $rc
}

# ------------------------------------------------------------------ status page cache (python) ---------------
test_glb_status_goals_mode_exposes_title_repos_order() {
  local pipe home out rc=0
  pipe=$(new_pipe); home=$(new_home)
  # v2 cache: no `spec`; host is the pinned host.
  jq -nc '{v:2,id:"label-goal-1",title:"Cross-repo goal model for the pipeline",label:"goal: Cross-repo goal model for the",
           repos:["example-owner/project-a","example-owner/project-b"],order:319,mockups:"review",go:true,host:"mac",
           state:"active",scope_total:3,scope_delivered:1,issue:319}' > "$pipe/goal-label-goal-1.json"
  out=$(PATH="$PATH" python3 "$DG_SKILL/build-runs-json.py" "" "$home/.claude/pipeline/runs.jsonl" "$pipe" goals </dev/null 2>/dev/null)
  rm -rf "$pipe" "$home"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].id // "none"')" "label-goal-1" "v2 goal (no spec) is emitted" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].title')" "Cross-repo goal model for the pipeline" "title" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -c '.[0].repos')" '["example-owner/project-a","example-owner/project-b"]' "repos" || rc=1
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].order')" "319" "order" || rc=1
  return $rc
}

for t in test_glb_label_rule_table test_glb_parse_label_spec_and_rejects_empty \
         test_glb_membership_scope_rows_from_both_repos test_glb_registry_lists_v1_and_v2_blocks \
         test_glb_reuse_guard_refuses_same_label_of_active_goal test_glb_same_title_allowed_after_old_goal_closed \
         test_glb_overlap_refuses_shared_ticket_of_other_goal \
         test_glb_register_creates_labels_block_and_seed test_glb_register_skips_business_intelligence \
         test_glb_label_spec_binds_existing_label \
         test_glb_register_grants_go_with_guards test_glb_register_include_sentry_labels_sentry_ticket \
         test_glb_register_closed_requirements_ticket_counts \
         test_glb_missing_requirements_registers_without_go test_glb_requirements_ticket_not_found_registers_without_go \
         test_glb_requirements_ticket_empty_registers_without_go test_glb_loop_guard_removed_go_not_readded \
         test_glb_close_strips_open_tickets_and_renames_label test_glb_delivered_goal_also_cleaned \
         test_glb_existing_done_label_means_delete_stripped_label test_glb_close_cleanup_is_idempotent \
         test_glb_active_goal_label_is_left_alone test_glb_same_title_after_close_gets_fresh_label_and_no_old_members \
         test_glb_error_row_written_when_label_rename_fails \
         test_glb_no_graphql_no_project_scope_in_goal_scripts test_glb_no_delivery_lead_marker_emitted_from_shell \
         test_glb_status_goals_mode_exposes_title_repos_order; do
  run_test "$t"
done
