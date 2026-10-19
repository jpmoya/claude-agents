# #195 — goal-bound delivery lead, part 2: the supervisor's goal step (keep-alive, pacing, parking, completion, stop).
#   AC1 dead pid + no .exit      AC2 clean exit pacing     AC3 crash backoff / .restarts   AC4 delivered
#   AC5 waiting on JP            AC6 no-progress parking   AC7 stop propagation            AC8 host pin
#   AC9 MAX_GOALS / power / mem  AC10 empty scope          AC12 error capture + no secrets
#   plus: ticket classification table, cache state mirror (#197 reads it), cache rebuild, sync throttle, config defaults.
# Expected values come from the ticket or hand arithmetic in comments — never from the code under test.
# Everything is prefixed gs_ / GS_ (all test files share one shell). Placeholder repo names only (public repo).
#
# Isolation: every tick runs a COPY of skills/orchestrate + hooks (built once per file) in an isolated HOME / PIPE /
# LOGDIR; the copy's report-status.sh is a recorder so report_status_async calls are observable; `claude`, `gh`,
# `hostname`, `uname`, `pmset` are fakes in the isolated HOME's .local/bin (config.sh prepends it to PATH).
# Nothing here touches /tmp/pipeline or a real GitHub.
#
# Fake `gh` is stateful and answers BOTH call styles (REST `gh api` and `gh issue view/comment/edit/close/list`,
# `gh repo view`) from one store, so the test does not pin which style the implementation uses; assertions read the
# store (labels, state, comments), never call shapes.
#
# World (all on host "host-a", the fake hostname is "Host-A"):
#   project-a milestone 12 "v1.2.0 - Goal delivery": 101 (open, READY FOR ENGINEERING), 102 (closed), 103 (a PR — never scope)
#   project-a milestone 20: empty.   loose open tickets 7, 8, 9 and 42.
#   goal ids (pinned rule <owner>_<repo>-<kind>-<ref>): ms-12, ms-20, t-7, t-8, t-9.
# Clock anchors: BACKOFF=(120 300 900 1800), MIN_RUN_SECS=180, GOAL_CYCLE_SECS=1200. Backoff is anchored on
# .launched-at (the only timestamp the pinned cache schema has); fixtures keep .exit's mtime consistent with it so
# either anchor gives the same answer, and stay >= 60 s away from every boundary.

GS_SKILL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GS_ROOT=$(cd "$GS_SKILL/../.." && pwd)
GS_REG="example-owner_registry"
GS_A="example-owner_project-a"
GS_ID_MS12="example-owner_project-a-ms-12"
GS_ID_MS20="example-owner_project-a-ms-20"
GS_ID_T7="example-owner_project-a-t-7"
GS_ID_T8="example-owner_project-a-t-8"
GS_ID_T9="example-owner_project-a-t-9"
GS_SPEC_MS12="example-owner/project-a:milestone:12"
GS_SPEC_MS20="example-owner/project-a:milestone:20"
GS_SPEC_T7="example-owner/project-a#7"
GS_SPEC_T8="example-owner/project-a#8"
GS_SPEC_T9="example-owner/project-a#9"
GS_TREE=""
GS_PIDS=""
GS_TOK=""
GS_HOME=""
GS_PIPE=""

# ---------------------------------------------------------------- the isolated tree ---------------------------

gs_tree_init() {
  [ -n "$GS_TREE" ] && [ -d "$GS_TREE" ] && return 0
  GS_TREE=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-gstree.XXXXXX")
  mkdir -p "$GS_TREE/skills" "$GS_TREE/hooks"
  cp -R "$GS_SKILL" "$GS_TREE/skills/orchestrate"
  rm -rf "$GS_TREE/skills/orchestrate/tests"
  cp "$GS_ROOT/hooks/pipeline-markers.sh" "$GS_TREE/hooks/"
  # the reporter recorder: one line per report_status_async call (its argument)
  cat > "$GS_TREE/skills/orchestrate/report-status.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "${1:-event}" >> "${GS_RS_LOG:-/dev/null}"
exit 0
EOF
  chmod +x "$GS_TREE/skills/orchestrate/report-status.sh"
  ( cd "$GS_TREE" && git init -q && git add -A && git -c user.email=t@example.invalid -c user.name=t commit -q -m tree ) >/dev/null 2>&1
}

gs_tree_cleanup() { [ -n "$GS_TREE" ] && rm -rf "$GS_TREE"; GS_TREE=""; }

# ---------------------------------------------------------------- sandbox ------------------------------------

gs_install_fakes() {
  cat > "$GS_BIN/hostname" <<'EOF'
#!/bin/bash
echo "Host-A"
EOF
  # uname / pmset: "Darwin on battery" only while the file `battery` exists next to them
  cat > "$GS_BIN/uname" <<'EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/battery" ]; then echo Darwin; else exec /usr/bin/uname "$@"; fi
EOF
  cat > "$GS_BIN/pmset" <<'EOF'
#!/bin/bash
echo "Now drawing from 'Battery Power'"
EOF
  # claude: record argv + cwd, then stay alive until killed (so a launched goal is a live goal)
  cat > "$GS_BIN/claude" <<EOF
#!/bin/bash
HERE=\$(cd "\$(dirname "\$0")" && pwd)
d=\$(mktemp -d "\$HERE/claude-calls.XXXXXX")
printf '%s\n' "\$@" > "\$d/argv"
pwd -P > "\$d/cwd"
exec -a "gsclaude-$GS_TOK" sleep 300
EOF
  cat > "$GS_BIN/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/state"
printf '%s\n' "$*" >> "$HERE/gh-calls.log"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mkdir -p "$S/comments" "$S/milestones" "$S/labels"
cwd_repo() { git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##'; }
emit_jq() { if [ -n "$1" ]; then jq -r "$1"; else cat; fi; }

issue_obj() {  # <rk> <n> <owner/repo> -> compact JSON shaped like `gh issue view --json ...`
  local f="$S/issues/$1/$2.json" cm="$S/comments/$1-$2.json"
  [ -f "$f" ] || return 1
  [ -f "$cm" ] || echo '[]' > "$cm"
  jq -c --slurpfile c "$cm" --arg url "https://github.com/$3/issues/$2" '
    {number, title, body, state: (.state | ascii_upcase), labels, updatedAt: .updated_at, createdAt: .created_at,
     closedAt: .closed_at, url: $url,
     comments: ($c[0] | to_entries | map({body: .value.body, createdAt: .value.created_at,
                url: ($url + "#issuecomment-" + (.key | tostring)), author: {login: .value.user.login}}))}' "$f"
}
add_comment() {  # <rk> <n> <body>
  local f="$S/comments/$1-$2.json"; [ -f "$f" ] || echo '[]' > "$f"
  jq -c --arg b "$3" --arg now "$now" '. + [{created_at: $now, user: {login: "fake"}, body: $b}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
label_add() {  # <rk> <n> <label>
  local f="$S/issues/$1/$2.json"
  jq -c --arg l "$3" '.labels = ((.labels + [{name: $l}]) | unique_by(.name))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
label_del() {
  local f="$S/issues/$1/$2.json"
  jq -c --arg l "$3" '.labels |= map(select(.name != $l))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
set_state() {
  local f="$S/issues/$1/$2.json"
  jq -c --arg s "$3" --arg now "$now" '.state = $s | .closed_at = (if $s == "closed" then $now else null end) | .updated_at = $now' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

case "$1" in
  issue)
    sub=$2; shift 2
    n=""; repo=""; jqx=""; body=""; adds=""; rems=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo|-R) repo=$2; shift ;;
        --json) shift ;;
        --jq|-q) jqx=$2; shift ;;
        --body|-b|--comment|-c) body=$2; shift ;;
        --body-file|-F) if [ "$2" = "-" ]; then body=$(cat); else body=$(cat "$2"); fi; shift ;;
        --add-label) adds="$adds,$2"; shift ;;
        --remove-label) rems="$rems,$2"; shift ;;
        --state|--label|--limit|-s|-l|-L|--milestone|-m|--search|--title|-t|--reason|-r|--assignee|--author) shift ;;
        -*) ;;
        *) [ -z "$n" ] && n=$1 ;;
      esac
      shift
    done
    [ -n "$repo" ] || repo=$(cwd_repo)
    rk=$(printf '%s' "$repo" | tr '/' '_')
    [ "$sub" = list ] && { echo '[]' | emit_jq "$jqx"; exit 0; }
    [ -f "$S/issues/$rk/$n.json" ] || { echo "gh: Could not resolve to an issue (HTTP 404) $repo#$n" >&2; exit 1; }
    case "$sub" in
      view) issue_obj "$rk" "$n" "$repo" | emit_jq "$jqx" ;;
      comment) printf 'POST %s#%s comment\n' "$repo" "$n" >> "$HERE/writes.log"; add_comment "$rk" "$n" "$body" ;;
      edit)
        printf 'EDIT %s#%s +%s -%s\n' "$repo" "$n" "$adds" "$rems" >> "$HERE/writes.log"
        for l in $(printf '%s' "$adds" | tr ',' ' '); do label_add "$rk" "$n" "$l"; done
        for l in $(printf '%s' "$rems" | tr ',' ' '); do label_del "$rk" "$n" "$l"; done ;;
      close) printf 'CLOSE %s#%s\n' "$repo" "$n" >> "$HERE/writes.log"; [ -n "$body" ] && add_comment "$rk" "$n" "$body"; set_state "$rk" "$n" closed ;;
      reopen) printf 'REOPEN %s#%s\n' "$repo" "$n" >> "$HERE/writes.log"; set_state "$rk" "$n" open ;;
      *) echo "fake gh: unsupported issue $sub" >&2; exit 1 ;;
    esac
    exit 0 ;;
  repo)
    shift 2
    repo=""; jqx=""
    while [ $# -gt 0 ]; do
      case "$1" in --json) shift ;; --jq|-q) jqx=$2; shift ;; -*) ;; *) repo=$1 ;; esac
      shift
    done
    [ -n "$repo" ] || repo=$(cwd_repo)
    jq -nc --arg r "$repo" '{nameWithOwner: $r}' | emit_jq "$jqx"; exit 0 ;;
  label) exit 0 ;;
  api) ;;
  *) echo "fake gh: unsupported: $*" >&2; exit 1 ;;
esac

# ---- gh api (REST) ----
shift
method=""; path=""; expr=""; obj='{}'; stdin_json=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) method=$2; shift ;;
    --jq|-q) expr=$2; shift ;;
    -f|-F|--field|--raw-field)
      kv=$2; k=${kv%%=*}; v=${kv#*=}; shift
      case "$k" in
        *'[]') kk=${k%??}; obj=$(printf '%s' "$obj" | jq -c --arg k "$kk" --arg v "$v" '.[$k] = ((.[$k] // []) + [$v])') ;;
        *) obj=$(printf '%s' "$obj" | jq -c --arg k "$k" --arg v "$v" '.[$k] = $v') ;;
      esac ;;
    --input) stdin_json=$(cat); shift ;;
    -H|--header) shift ;;
    --paginate|--silent|-i|--include|--slurp) ;;
    -*) ;;
    *) [ -z "$path" ] && path=$1 ;;
  esac
  shift
done
[ -n "$stdin_json" ] && obj=$stdin_json
if [ -z "$method" ]; then if [ "$obj" != "{}" ]; then method=POST; else method=GET; fi; fi
path=${path#/}
p=${path%%\?*}; q=""; case "$path" in *\?*) q=${path#*\?} ;; esac
qget() { printf '%s' "$q" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 | sed 's/%3A/:/g;s/%2C/,/g'; }
if [ "$method" = GET ] && [ "$obj" != "{}" ]; then
  for k in $(printf '%s' "$obj" | jq -r 'keys[]'); do q="$q&$k=$(printf '%s' "$obj" | jq -r --arg k "$k" '.[$k]')"; done
fi
emit() { if [ -n "$expr" ]; then jq -r "$expr"; else cat; fi; }
case "$p" in repos/*/*/*) ;; *) echo "fake gh: unexpected path $p" >&2; exit 1 ;; esac
owner=$(printf '%s' "$p" | cut -d/ -f2); repo=$(printf '%s' "$p" | cut -d/ -f3); seg=$(printf '%s' "$p" | cut -d/ -f4-)
rk="${owner}_${repo}"; D="$S/issues/$rk"; mkdir -p "$D"
if [ "$method" != GET ]; then printf '%s %s %s\n' "$method" "$p" "$obj" >> "$HERE/writes.log"; fi
if [ -f "$HERE/fail-registry" ] && [ "$method $seg" = "GET issues" ] && [ "$(qget labels)" = "delivery-goal" ]; then
  echo "gh: HTTP 502 Bad Gateway" >&2; exit 1
fi
issue_file() { printf '%s/%s.json' "$D" "$1"; }
case "$method $seg" in
  "GET milestones")
    f="$S/milestones/$rk.json"; [ -f "$f" ] || echo '[]' > "$f"
    jq --arg st "$(qget state)" 'if $st == "open" then map(select(.state == "open")) else . end' "$f" | emit ;;
  "GET issues")
    ls "$D"/*.json >/dev/null 2>&1 || { echo '[]' | emit; exit 0; }
    jq -s --arg ms "$(qget milestone)" --arg lb "$(qget labels)" --arg st "$(qget state)" --arg since "$(qget since)" '
      map(select(
        ($st == "" or $st == "open" and .state == "open" or $st == "closed" and .state == "closed" or $st == "all")
        and ($ms == "" or ($ms == "*" and .milestone != null) or ($ms == "none" and .milestone == null)
             or (.milestone != null and ((.milestone.number | tostring) == $ms)))
        and ($lb == "" or ([.labels[].name] as $have | ($lb | split(",")) | all(. as $w | $have | index($w) != null)))
        and ($since == "" or .updated_at >= $since)))
      | sort_by(.number)' "$D"/*.json | emit ;;
  "GET issues/"*"/comments")
    n=$(printf '%s' "$seg" | cut -d/ -f2); f="$S/comments/$rk-$n.json"
    if [ -f "$f" ]; then emit < "$f"; else echo '[]' | emit; fi ;;
  "GET issues/"*)
    n=${seg#issues/}; f=$(issue_file "$n")
    if [ -f "$f" ]; then emit < "$f"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  "PATCH issues/"*)
    n=${seg#issues/}; f=$(issue_file "$n"); [ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    jq -c --argjson o "$obj" --arg now "$now" '
      (if $o.state then .state = $o.state | .closed_at = (if $o.state == "closed" then $now else null end) else . end)
      | (if $o.body then .body = $o.body else . end) | (if $o.title then .title = $o.title else . end)
      | .updated_at = $now' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    emit < "$f" ;;
  "POST issues/"*"/labels")
    n=$(printf '%s' "$seg" | cut -d/ -f2); f=$(issue_file "$n"); [ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    jq -c --argjson o "$obj" '.labels = (.labels + (($o.labels // []) | map({name:.})) | unique_by(.name))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    jq -c '.labels' "$f" | emit ;;
  "DELETE issues/"*"/labels/"*)
    n=$(printf '%s' "$seg" | cut -d/ -f2); name=$(printf '%s' "$seg" | cut -d/ -f4-); f=$(issue_file "$n")
    [ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    jq -e --arg l "$name" 'any(.labels[]; .name == $l)' "$f" >/dev/null || { echo "gh: Label does not exist (HTTP 404)" >&2; exit 1; }
    jq -c --arg l "$name" '.labels |= map(select(.name != $l))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo '[]' | emit ;;
  "POST issues/"*"/comments")
    n=$(printf '%s' "$seg" | cut -d/ -f2); add_comment "$rk" "$n" "$(printf '%s' "$obj" | jq -r '.body // ""')"
    echo '{}' | emit ;;
  "POST labels") echo '{}' | emit ;;
  *) echo "fake gh: unsupported REST call: $method $p" >&2; exit 1 ;;
esac
GH_EOF
  chmod +x "$GS_BIN/hostname" "$GS_BIN/uname" "$GS_BIN/pmset" "$GS_BIN/claude" "$GS_BIN/gh"
}

# gs_env — fresh HOME / PIPE / fake world. GS_SYNC=default keeps the shipped GOAL_SYNC_SECS; otherwise 0.
gs_env() {
  gs_tree_init
  GS_PIPE=$(new_pipe); GS_HOME=$(new_home); GS_TOK=$(basename "$GS_HOME")
  GS_BIN="$GS_HOME/.local/bin"; GS_ST="$GS_BIN/state"
  mkdir -p "$GS_BIN" "$GS_ST/issues/$GS_REG" "$GS_ST/issues/$GS_A" "$GS_ST/milestones" "$GS_ST/comments"
  GS_CK_A="$GS_HOME/checkouts/project-a"
  fixture_repo "$GS_CK_A" example-owner/project-a
  GS_CK_A=$(cd "$GS_CK_A" && pwd -P)
  : > "$GS_BIN/gh-calls.log"; : > "$GS_BIN/writes.log"
  GS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gs_install_fakes
  {
    echo "DISPATCH_REPOS=(\"example-owner/project-a:$GS_CK_A\")"
    echo "GOAL_REGISTRY_REPO=example-owner/registry"
    echo "MEM_FLOOR_MB=0"
    [ "${GS_SYNC:-}" = default ] || echo "GOAL_SYNC_SECS=0"
  } > "$GS_HOME/.claude/pipeline/config.local.sh"
  GS_RS_LOG="$GS_HOME/rs-calls.log"; : > "$GS_RS_LOG"
  # world
  gs_milestone 12 "v1.2.0 - Goal delivery"; gs_milestone 20 "empty"
  gs_issue 101 open 12; gs_issue 102 closed 12; gs_issue 103 open 12 pr
  gs_issue 7 open; gs_issue 8 open; gs_issue 9 open; gs_issue 42 open
  gs_comment 101 $'**[product-manager] READY FOR ENGINEERING**\nLane: fast'
  gs_comment 7 $'**[product-manager] READY FOR ENGINEERING**\nLane: fast'
  gs_comment 8 $'**[product-manager] READY FOR ENGINEERING**\nLane: fast'
  gs_comment 9 $'**[product-manager] READY FOR ENGINEERING**\nLane: fast'
  gs_comment 42 $'**[product-manager] READY FOR ENGINEERING**\nLane: fast'
}

gs_cleanup() {
  local p
  cleanup_running
  for p in $GS_PIDS; do kill "$p" 2>/dev/null; done
  GS_PIDS=""
  pkill -f "gsclaude-$GS_TOK" 2>/dev/null
  # goal wrappers launched by a tick: take their direct children down too
  for p in "$GS_PIPE"/goal-*.pid; do
    [ -e "$p" ] || continue
    pkill -TERM -P "$(cat "$p" 2>/dev/null)" 2>/dev/null
    kill "$(cat "$p" 2>/dev/null)" 2>/dev/null
  done
  rm -rf "$GS_PIPE" "$GS_HOME"
}

# ---------------------------------------------------------------- fixture builders ---------------------------

gs_milestone() {  # <number> <title>
  local f="$GS_ST/milestones/$GS_A.json"; [ -f "$f" ] || echo '[]' > "$f"
  jq -c --argjson n "$1" --arg t "$2" '. + [{number:$n, title:$t, state:"open"}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# gs_issue <n> <open|closed> [milestone number|""] [pr] [labels-csv]
gs_issue() {
  local n=$1 st=$2 ms=${3:-} pr=${4:-} lb=${5:-}
  jq -nc --argjson n "$n" --arg st "$st" --arg ms "$ms" --arg pr "$pr" --arg lb "$lb" --arg now "$GS_NOW" '
    {number:$n, title:("ticket " + ($n|tostring)), body:"", state:$st,
     labels:($lb | split(",") | map(select(length > 0)) | map({name:.})),
     created_at:$now, updated_at:$now, closed_at:(if $st == "closed" then $now else null end),
     milestone:(if $ms == "" then null else {number:($ms|tonumber), title:"m"} end)}
    + (if $pr != "" then {pull_request:{url:"x"}} else {} end)' > "$GS_ST/issues/$GS_A/$n.json"
}

gs_body() {  # <n> <body> — set a project-a ticket body
  local f="$GS_ST/issues/$GS_A/$1.json"
  jq -c --arg b "$2" '.body = $b' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

gs_comment() {  # <n> <body>  (project-a ticket comment, chronological append)
  local f="$GS_ST/comments/$GS_A-$1.json"; [ -f "$f" ] || echo '[]' > "$f"
  jq -c --arg b "$2" --arg now "$GS_NOW" '. + [{created_at:$now, user:{login:"fixture"}, body:$b}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# gs_reg <registry issue number> <spec> <id> <host> <active|held|waiting|stopped|delivered> [instructions]
gs_reg() {
  local n=$1 spec=$2 id=$3 host=$4 st=$5 instr=${6:-} block labels='["delivery-goal"]' state=open closed=null
  block=$(jq -nc --arg id "$id" --arg spec "$spec" --arg host "$host" --arg ins "$instr" --arg c "$GS_NOW" \
    '{v:1,id:$id,spec:$spec,host:$host,created:$c,instructions:$ins}')
  case "$st" in
    held)      labels='["delivery-goal","goal-held"]' ;;
    waiting)   labels='["delivery-goal","goal-waiting-jp"]' ;;
    stopped)   labels='["delivery-goal","goal-stopped"]'; state=closed; closed="\"$GS_NOW\"" ;;
    delivered) state=closed; closed="\"$GS_NOW\"" ;;
  esac
  jq -nc --argjson n "$n" --arg title "Goal: $spec" --arg body "$(printf 'Goal: %s\n\n```json\n%s\n```\n' "$spec" "$block")" \
    --argjson labels "$labels" --arg state "$state" --argjson closed "$closed" --arg now "$GS_NOW" \
    '{number:$n, title:$title, body:$body, state:$state, labels:($labels|map({name:.})), milestone:null,
      closed_at:$closed, created_at:$now, updated_at:$now}' > "$GS_ST/issues/$GS_REG/$n.json"
}

gs_regfile() { printf '%s/issues/%s/%s.json' "$GS_ST" "$GS_REG" "$1"; }
gs_reg_state() { jq -r .state "$(gs_regfile "$1")"; }
gs_has_label() { jq -e --arg l "$2" 'any(.labels[]; .name == $l)' "$(gs_regfile "$1")" >/dev/null 2>&1; }
gs_reg_comments() { jq -r '.[].body' "$GS_ST/comments/$GS_REG-$1.json" 2>/dev/null; }
gs_reg_comment_count() {  # <n> <needle> -> number of comments whose body contains the needle
  jq -r --arg s "$2" '[.[] | select(.body | contains($s))] | length' "$GS_ST/comments/$GS_REG-$1.json" 2>/dev/null || echo 0
}

# gs_cache <id> <issue> <spec> <host> [instr] — the host-local copy of the registry block plus "issue"
gs_cache() {
  jq -nc --arg id "$2" --argjson n "$1" --arg spec "$3" --arg host "$4" --arg ins "${5:-}" --arg c "$GS_NOW" \
    '{v:1,id:$id,spec:$spec,host:$host,created:$c,instructions:$ins,issue:$n}' > "$GS_PIPE/goal-$2.json"
}

gs_dead_pid() { local p=99999; while kill -0 "$p" 2>/dev/null; do p=$((p - 1)); done; echo "$p"; }
gs_iso_ago() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
gs_touch_ago() { python3 -c "import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1], (t, t))" "$1" "$2"; }

# gs_launch_state <id> <launched-secs-ago> <exit: ""|code> [exit-secs-ago] — dead pid + timestamps (+ .exit)
gs_launch_state() {
  local id=$1 ago=$2 ex=${3:-} exago=${4:-0}
  gs_dead_pid > "$GS_PIPE/goal-$id.pid"
  gs_iso_ago "$ago" > "$GS_PIPE/goal-$id.launched-at"
  gs_iso_ago "$ago" > "$GS_PIPE/goal-$id.start"
  rm -f "$GS_PIPE/goal-$id.exit"
  if [ -n "$ex" ]; then echo "$ex" > "$GS_PIPE/goal-$id.exit"; gs_touch_ago "$GS_PIPE/goal-$id.exit" "$exago"; fi
}

# gs_own <id> <registry issue> <spec> <launched-secs-ago> <exit> [exit-secs-ago] [instr] — an owned, launch-eligible goal
gs_own() {
  gs_reg "$2" "$3" "$1" host-a active "${7:-}"
  gs_cache "$2" "$1" "$3" host-a "${7:-}"
  gs_launch_state "$1" "$4" "${5:-}" "${6:-0}"
}

# gs_live <id> — a live process tree (bash + sleep child) as the goal's pid; sets GS_P (bash) / GS_C (sleep child)
gs_live() {
  bash -c 'sleep 300 & wait' >/dev/null 2>&1 &
  GS_P=$!; disown "$GS_P" 2>/dev/null
  GS_PIDS="$GS_PIDS $GS_P"
  local i=0 c=""
  while [ "$i" -lt 25 ] && [ -z "$c" ]; do c=$(pgrep -P "$GS_P" 2>/dev/null | head -1); [ -n "$c" ] || sleep 0.2; i=$((i + 1)); done
  GS_C=$c; GS_PIDS="$GS_PIDS $GS_C"
  echo "$GS_P" > "$GS_PIPE/goal-$1.pid"
  gs_iso_ago 600 > "$GS_PIPE/goal-$1.launched-at"; gs_iso_ago 600 > "$GS_PIPE/goal-$1.start"
}

gs_alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' '); [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
gs_wait_dead() { local i=0; while [ "$i" -lt 25 ]; do gs_alive "$1" || return 0; sleep 0.2; i=$((i + 1)); done; return 1; }
gs_claude_count() { ls -d "$GS_BIN"/claude-calls.* 2>/dev/null | wc -l | tr -d ' '; }
gs_wait_claude() { local i=0; while [ "$i" -lt 25 ]; do [ "$(gs_claude_count)" -ge "$1" ] && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }
gs_settle() { sleep 1; }   # let any (wrongly) launched detached claude show up before asserting "none"
gs_last_claude() { ls -d "$GS_BIN"/claude-calls.* 2>/dev/null | tail -1; }
gs_argv_after() { awk -v k="$2" 'p{print;exit} $0==k{p=1}' "$1/argv"; }

gs_tick() {
  GS_RC=0
  ( cd "$GS_HOME" && env HOME="$GS_HOME" PATH="$GS_BIN:/usr/bin:/bin" PIPE="$GS_PIPE" QUEUE="$GS_PIPE/queue" \
      LOGDIR="$GS_HOME/logs/pipeline" GS_RS_LOG="$GS_RS_LOG" \
      SLACK_BOT_TOKEN="${GS_SLACK_TOKEN:-}" SLACK_ENGINEERING_CHANNEL="" \
      STATUS_PUSH_URL="${GS_PUSH_URL:-}" STATUS_PUSH_TOKEN="${GS_PUSH_TOKEN:-}" GH_TOKEN="${GS_GH_TOKEN:-}" \
      bash "$GS_TREE/skills/orchestrate/supervisor.sh" >"$GS_HOME/tick.out" 2>&1 </dev/null ) || GS_RC=$?
  sleep 0.4   # the reporter recorder is backgrounded
}
gs_log() { cat "$GS_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }
gs_events() { cat "$GS_RS_LOG" 2>/dev/null; }
gs_event_count() { grep -cxF -- "$1" "$GS_RS_LOG" 2>/dev/null; }
gs_file() { cat "$GS_PIPE/goal-$1.$2" 2>/dev/null || echo "MISSING"; }
gs_json() { jq -r --arg k "$2" '.[$k] // "MISSING"' "$GS_PIPE/goal-$1.json" 2>/dev/null || echo "NOJSON"; }
gs_goal_file_count() { ls "$GS_PIPE"/goal-"$1".* 2>/dev/null | wc -l | tr -d ' '; }

# ---------------------------------------------------------------- AC1: crash / kill ---------------------------

# Hand arithmetic: no .restarts (=0) -> BACKOFF[0]=120 s; launched 3600 s ago -> far past it -> relaunch this tick.
test_gs_ac1_dead_pid_no_exit_file_is_relaunched() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 "" 0 "focus on quotes"
  local old; old=$(cat "$GS_PIPE/goal-$GS_ID_MS12.pid")
  gs_tick
  gs_wait_claude 1 || { gs_cleanup; fail "AC1: fake claude was never launched"; return 1; }
  gs_settle
  local d new log agent cwd brief
  d=$(gs_last_claude); new=$(cat "$GS_PIPE/goal-$GS_ID_MS12.pid" 2>/dev/null)
  agent=$(gs_argv_after "$d" --agent); cwd=$(cat "$d/cwd"); brief=$(cat "$d/argv")
  log=$(gs_log)
  local alive=no; kill -0 "$new" 2>/dev/null && alive=yes
  local count; count=$(gs_claude_count)
  local la; la=$(gs_file "$GS_ID_MS12" launched-at)
  gs_cleanup
  assert_eq "$count" "1" "AC1: claude launched exactly once" || return 1
  assert_eq "$agent" "project-manager" "AC1: --agent \$GOAL_AGENT" || return 1
  assert_contains "$brief" "--dangerously-skip-permissions" "AC1: launch wrapper shape" || return 1
  assert_contains "$brief" "$GS_ID_MS12" "AC1: the brief names the goal id" || return 1
  assert_contains "$brief" "focus on quotes" "AC1: the brief carries the instructions" || return 1
  assert_eq "$cwd" "$GS_CK_A" "AC1: cwd = the repo's DISPATCH_REPOS checkout" || return 1
  assert_ne "$new" "$old" "AC1: a new pid file" || return 1
  assert_eq "$alive" "yes" "AC1: the new pid is the live launched cycle" || return 1
  assert_ne "$la" "MISSING" "AC1: .launched-at rewritten" || return 1
  printf '%s\n' "$log" | grep -F "$GS_ID_MS12" | grep -qi 'launch' || { fail "AC1: no launch log line naming $GS_ID_MS12 in:
$log"; return 1; }
  printf '%s\n' "$log" | grep -F '[goal]' | grep -qF "$GS_ID_MS12" || { fail "AC1: launch line lacks the [goal] route prefix"; return 1; }
}

# Alive pid -> nothing; the same goal once the pid is dead -> relaunched (positive control).
test_gs_ac1_alive_pid_is_left_alone_until_it_dies() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  gs_live "$GS_ID_MS12"
  local live=$GS_P
  gs_tick; gs_settle
  local c1 pid1
  c1=$(gs_claude_count); pid1=$(cat "$GS_PIPE/goal-$GS_ID_MS12.pid")
  kill "$GS_P" "$GS_C" 2>/dev/null; gs_wait_dead "$live"
  gs_tick
  gs_wait_claude 1
  local c2; c2=$(gs_claude_count)
  gs_cleanup
  assert_eq "$c1" "0" "AC1: live pid -> no launch" || return 1
  assert_eq "$pid1" "$live" "AC1: live pid file untouched" || return 1
  assert_eq "$c2" "1" "AC1: once the pid is dead the goal is relaunched" || return 1
}

# ---------------------------------------------------------------- AC2: clean cycle end ------------------------

# Hand arithmetic: GOAL_CYCLE_SECS=1200 = 20 min. 5 min = 300 s < 1200 -> wait. 21 min = 1260 s >= 1200 -> relaunch.
test_gs_ac2_clean_exit_waits_for_cycle_secs_then_relaunches() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 300 0 60
  gs_tick; gs_settle
  local c1 pid1; c1=$(gs_claude_count); pid1=$(cat "$GS_PIPE/goal-$GS_ID_MS12.pid")
  gs_launch_state "$GS_ID_MS12" 1260 0 60
  local deadpid; deadpid=$(cat "$GS_PIPE/goal-$GS_ID_MS12.pid")
  gs_tick
  gs_wait_claude 1
  local c2 pid2; c2=$(gs_claude_count); pid2=$(cat "$GS_PIPE/goal-$GS_ID_MS12.pid")
  gs_cleanup
  assert_eq "$c1" "0" "AC2: 5 min after a clean exit -> not relaunched" || return 1
  assert_eq "$c2" "1" "AC2: 21 min after a clean exit -> relaunched" || return 1
  assert_ne "$pid2" "$deadpid" "AC2: relaunch wrote a new pid" || return 1
  assert_ne "$pid1" "" "AC2: pid file kept while waiting" || return 1
}

# ---------------------------------------------------------------- AC3: crash backoff / .restarts --------------

# Hand arithmetic: BACKOFF[1]=300. Run of 240 s (launched 250 s ago, exited 10 s ago): >= MIN_RUN 180 so not transient,
# 250 < 300 -> wait, .restarts stays 1. Run of 400 s (launched 800 s ago, exited 400 s ago): 400 >= 300 -> relaunch, 1 -> 2.
# Then a clean exit (launched 1260 s ago, exit 0) -> next relaunch resets .restarts to 0.
test_gs_ac3_crash_backoff_indexed_by_restarts_then_clean_exit_resets() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 250 1 10
  echo 1 > "$GS_PIPE/goal-$GS_ID_MS12.restarts"
  gs_tick; gs_settle
  local c1 r1; c1=$(gs_claude_count); r1=$(gs_file "$GS_ID_MS12" restarts)
  gs_launch_state "$GS_ID_MS12" 800 1 400
  gs_tick
  gs_wait_claude 1
  local c2 r2; c2=$(gs_claude_count); r2=$(gs_file "$GS_ID_MS12" restarts)
  gs_launch_state "$GS_ID_MS12" 1260 0 60
  gs_tick
  gs_wait_claude 2
  local c3 r3; c3=$(gs_claude_count); r3=$(gs_file "$GS_ID_MS12" restarts)
  gs_cleanup
  assert_eq "$c1" "0" "AC3: 250 s < BACKOFF[1]=300 -> not relaunched" || return 1
  assert_eq "$r1" "1" "AC3: .restarts unchanged while waiting" || return 1
  assert_eq "$c2" "1" "AC3: 800 s >= BACKOFF[1] -> relaunched" || return 1
  assert_eq "$r2" "2" "AC3: .restarts 1 -> 2" || return 1
  assert_eq "$c3" "2" "AC3: clean exit past the cycle pace -> relaunched" || return 1
  assert_eq "$r3" "0" "AC3: a clean exit resets .restarts to 0" || return 1
}

# Hand arithmetic: a 150 s run (< MIN_RUN_SECS 180) is transient -> TRANSIENT_BACKOFF[0]=300 > 150 elapsed -> wait.
# (A non-transient 150 s-old failure with .restarts=0 would pass BACKOFF[0]=120 and relaunch.)
# Control: a 300 s run exited 300 s ago, launched 700 s ago -> non-transient, 700 >= 120 -> relaunch.
test_gs_ac3_short_run_is_transient() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 150 1 0
  gs_tick; gs_settle
  local c1; c1=$(gs_claude_count)
  gs_launch_state "$GS_ID_MS12" 700 1 300
  gs_tick
  gs_wait_claude 1
  local c2; c2=$(gs_claude_count)
  gs_cleanup
  assert_eq "$c1" "0" "AC3: a run shorter than MIN_RUN_SECS is transient and backs off TRANSIENT_BACKOFF[0]" || return 1
  assert_eq "$c2" "1" "AC3: control — a non-transient failure past BACKOFF[0] relaunches" || return 1
}

# ---------------------------------------------------------------- AC4: delivered ------------------------------

# Scope ms-12 = {101, 102}: 101 open with a DEPLOYED marker (delivered), 102 closed -> delivered.
test_gs_ac4_all_delivered_closes_registry_with_card_and_removes_cache() {
  gs_env
  gs_comment 101 $'**[deployer] DEPLOYED**\nrelease v1.2.0'
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 0 1300
  gs_tick; gs_settle
  local st labels_stopped=no cards c1 files card ev
  st=$(gs_reg_state 50); gs_has_label 50 goal-stopped && labels_stopped=yes
  cards=$(gs_reg_comment_count 50 '**[deliver] NOTE** card')
  card=$(gs_reg_comments 50); files=$(gs_goal_file_count "$GS_ID_MS12"); c1=$(gs_claude_count)
  ev=$(gs_event_count goal)
  # second tick: nothing fires again
  gs_tick; gs_settle
  local c2 cards2; c2=$(gs_claude_count); cards2=$(gs_reg_comment_count 50 '**[deliver] NOTE** card')
  local st2; st2=$(gs_reg_state 50)
  gs_cleanup
  assert_eq "$st" "closed" "AC4: registry issue closed" || return 1
  assert_eq "$labels_stopped" "no" "AC4: delivered is closed WITHOUT goal-stopped" || return 1
  assert_eq "$cards" "1" "AC4: exactly one **[deliver] NOTE** card comment" || return 1
  assert_contains "$card" "STATUS:" "AC4: standard status card format" || return 1
  assert_contains "$card" "NEEDED FROM YOU:" "AC4: standard status card format (needed from you)" || return 1
  assert_eq "$files" "0" "AC4: every \$PIPE/goal-<id>.* removed" || return 1
  assert_eq "$c1" "0" "AC4: a delivered goal is not relaunched" || return 1
  [ "$ev" -ge 1 ] || { fail "AC4: report_status_async \"goal\" not invoked (events: $(gs_events | tr '\n' ' '))"; return 1; }
  assert_eq "$c2" "0" "AC4: second tick launches nothing" || return 1
  assert_eq "$cards2" "1" "AC4: second tick posts no further card" || return 1
  assert_eq "$st2" "closed" "AC4: stays closed" || return 1
}

# ---------------------------------------------------------------- classification table -----------------------

# gs_classify <issue state> <labels-csv> <comment body…> — one single-ticket goal (t-7) in a launch-eligible shape;
# prints delivered | waiting_jp | active | none. Outcome read from the registry store / launch, never from call shapes.
gs_classify() {
  local st=$1 lb=$2 b out=none
  shift 2
  gs_env
  gs_issue 7 "$st" "" "" "$lb"
  rm -f "$GS_ST/comments/$GS_A-7.json"
  for b in "$@"; do gs_comment 7 "$b"; done
  gs_own "$GS_ID_T7" 50 "$GS_SPEC_T7" 3600 ""
  gs_tick
  if [ "$(gs_reg_state 50)" = closed ] && ! gs_has_label 50 goal-stopped; then out=delivered
  elif gs_has_label 50 goal-waiting-jp; then out=waiting_jp
  elif gs_wait_claude 1; then out=active
  fi
  gs_cleanup
  printf '%s' "$out"
}

gs_check_class() {  # <expected> <label> <state> <labels> <comments…>
  local want=$1 label=$2 got
  shift 2
  got=$(gs_classify "$@")
  assert_eq "$got" "$want" "classification: $label" || return 1
}

test_gs_classify_delivered() {
  gs_check_class delivered "issue CLOSED, no marker" closed "" || return 1
  gs_check_class delivered "CLOSED with a lookalike DEPLOYED TO STAGING" closed "" $'**[deployer] DEPLOYED TO STAGING**\nstaging up' || return 1
  gs_check_class delivered "open + [deployer] DEPLOYED" open "" $'**[deployer] DEPLOYED**\nrelease' || return 1
  gs_check_class delivered "open + [infra-operator] APPLIED" open "" $'**[infra-operator] APPLIED**\ndone' || return 1
  gs_check_class delivered "open + [solutions-architect] SPLIT" open "" $'**[solutions-architect] SPLIT**\nchildren filed' || return 1
  gs_check_class delivered "open + valid REJECTED (user-feedback, Reason:)" open "user-feedback" $'**[product-manager] REJECTED**\nReason: not-a-bug' || return 1
}

test_gs_classify_waiting_jp() {
  gs_check_class waiting_jp "MOCKUPS PENDING APPROVAL" open "" $'**[ui-ux-designer] MOCKUPS PENDING APPROVAL**\nsee mockups' || return 1
  gs_check_class waiting_jp "AWAITING GO" open "" $'**[infra-operator] AWAITING GO**\nplan ready' || return 1
  gs_check_class waiting_jp "EFFORT APPROVAL NEEDED" open "" $'**[product-manager] EFFORT APPROVAL NEEDED**\nbig' || return 1
  gs_check_class waiting_jp "DEPLOYED TO STAGING while still open" open "" $'**[deployer] DEPLOYED TO STAGING**\nstaging up' || return 1
  gs_check_class waiting_jp "BLOCKED, Blocked on: needs_jp" open "" $'**[fullstack-developer] BLOCKED**\nBlocked on: needs_jp\nneeds JP to decide' || return 1
  gs_check_class waiting_jp "agent-proposed, no agent-go / agent-in-progress" open "agent-proposed" $'**[product-manager] READY FOR ENGINEERING**\nLane: fast' || return 1
}

test_gs_classify_active() {
  gs_check_class active "plain READY FOR ENGINEERING" open "" $'**[product-manager] READY FOR ENGINEERING**\nLane: fast' || return 1
  gs_check_class active "no marker at all" open "" || return 1
  gs_check_class active "BLOCKED, Blocked on: ci_red" open "" $'**[fullstack-developer] BLOCKED**\nBlocked on: ci_red\nCI is red' || return 1
  gs_check_class active "BLOCKED with no class line" open "" $'**[fullstack-developer] BLOCKED**\nstuck' || return 1
  gs_check_class active "agent-proposed + agent-go" open "agent-proposed,agent-go" $'**[product-manager] READY FOR ENGINEERING**\nLane: fast' || return 1
  gs_check_class active "agent-proposed + agent-in-progress" open "agent-proposed,agent-in-progress" $'**[product-manager] READY FOR ENGINEERING**\nLane: fast' || return 1
  gs_check_class active "REJECTED without the user-feedback label is inert" open "" $'**[product-manager] REJECTED**\nReason: not-a-bug' || return 1
}


# ---------------------------------------------------------------- #428: start-gated, never-started ticket -------

# gs_gate_class <gate issue state|missing> <ticket comments…> — t-7 whose body names "Depends on #42 for starting work".
gs_gate_class() {
  local gst=$1 b out=none
  shift
  gs_env
  gs_issue 7 open
  gs_body 7 $'Do the thing.\n\nDepends on #42 for starting work'
  rm -f "$GS_ST/comments/$GS_A-7.json"
  for b in "$@"; do gs_comment 7 "$b"; done
  if [ "$gst" = missing ]; then rm -f "$GS_ST/issues/$GS_A/42.json"; else gs_issue 42 "$gst"; fi
  gs_own "$GS_ID_T7" 50 "$GS_SPEC_T7" 3600 ""
  gs_tick
  if [ "$(gs_reg_state 50)" = closed ] && ! gs_has_label 50 goal-stopped; then out=delivered
  elif gs_has_label 50 goal-waiting-jp; then out=waiting_jp
  elif gs_wait_claude 1; then out=active
  fi
  gs_cleanup
  printf '%s' "$out"
}

test_gs_428_open_start_gate_without_marker_is_waiting() {   # AC1
  assert_eq "$(gs_gate_class open)" "waiting_jp" "428 AC1: open gate, no marker" || return 1
}
test_gs_428_closed_start_gate_is_active() {   # AC2
  assert_eq "$(gs_gate_class closed)" "active" "428 AC2: gate closed" || return 1
}
test_gs_428_open_gate_with_marker_is_classified_as_today() {   # AC3
  assert_eq "$(gs_gate_class open $'**[product-manager] READY FOR ENGINEERING**\nLane: fast')" "active" "428 AC3: marker present, gate ignored" || return 1
}
test_gs_428_unreadable_gate_is_neither_waiting_nor_delivered() {   # AC4
  local out
  out=$(gs_gate_class missing)
  assert_eq "$out" "none" "428 AC4: failed gate read: not waiting, not delivered, no launch" || return 1
}
test_gs_428_goal_with_start_gated_ticket_reaches_waiting_branch() {   # AC6 (hand: 102 delivered, 101 waiting, 104 gated -> 0 active)
  gs_env
  gs_comment 101 $'**[deployer] DEPLOYED TO STAGING**\nstaging up'
  gs_issue 104 open 12; gs_body 104 'Depends on #42 for starting work'
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  gs_tick; gs_settle
  local lab held c cards
  gs_has_label 50 goal-waiting-jp && lab=yes || lab=no
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=yes || held=no
  c=$(gs_claude_count); cards=$(gs_reg_comment_count 50 '**[deliver] NOTE** card')
  gs_cleanup
  assert_eq "$lab" "yes" "428 AC6: goal-waiting-jp label" || return 1
  assert_eq "$held" "no" "428 AC6: not parked" || return 1
  assert_eq "$c" "0" "428 AC6: no launch" || return 1
  assert_eq "$cards" "1" "428 AC6: waiting card posted" || return 1
}

# ---------------------------------------------------------------- #427: a held goal is looked at again -----------

# gs_held_seed <snap|"-"> — ms-12 parked: .held + goal-held label + np=3; "-" leaves the .snap a normal launch tick wrote.
gs_held_seed() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  if [ "$1" = "-" ]; then
    gs_tick; gs_wait_claude 1; gs_settle   # a normal tick stores the real snapshot of the current scope
    gs_launch_state "$GS_ID_MS12" 3600 0 60
  else
    echo "$1" > "$GS_PIPE/goal-$GS_ID_MS12.snap"
  fi
  touch "$GS_PIPE/goal-$GS_ID_MS12.held"; echo 3 > "$GS_PIPE/goal-$GS_ID_MS12.np"
  gs_reg 50 "$GS_SPEC_MS12" "$GS_ID_MS12" host-a held
}

test_gs_427_held_goal_with_all_tickets_closed_is_delivered() {   # AC2 (hand: 101 and 102 closed -> 2 of 2)
  gs_held_seed stale
  gs_issue 101 closed 12
  gs_tick; gs_settle
  local st lab c log; st=$(gs_reg_state 50); gs_has_label 50 goal-held && lab=yes || lab=no
  c=$(gs_claude_count); log=$(gs_log | grep -c "$GS_ID_MS12 delivered")
  gs_cleanup
  assert_eq "$st" "closed" "427 AC2: registry issue closed" || return 1
  assert_eq "$lab" "no" "427 AC2: goal-held label removed" || return 1
  assert_eq "$log" "1" "427 AC2: delivered line logged" || return 1
  assert_eq "$c" "0" "427 AC2: nothing launched" || return 1
}

test_gs_427_held_goal_with_changed_snapshot_is_unheld() {   # AC3
  gs_held_seed stale
  gs_tick; gs_settle
  local held lab np log st
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=yes || held=no
  gs_has_label 50 goal-held && lab=yes || lab=no
  np=$(gs_file "$GS_ID_MS12" np); log=$(gs_log | grep -c "$GS_ID_MS12 unheld — scope changed"); st=$(gs_reg_state 50)
  gs_cleanup
  assert_eq "$held" "no" "427 AC3: .held removed" || return 1
  assert_eq "$lab" "no" "427 AC3: goal-held label removed" || return 1
  assert_eq "$np" "0" "427 AC3: .np reset" || return 1
  assert_eq "$log" "1" "427 AC3: unheld line logged" || return 1
  assert_eq "$st" "open" "427 AC3: registry issue stays open" || return 1
}

test_gs_427_held_goal_with_unchanged_snapshot_stays_held_and_is_not_launched() {   # AC4
  gs_held_seed -
  gs_tick; gs_settle
  local held lab c
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=yes || held=no
  gs_has_label 50 goal-held && lab=yes || lab=no
  c=$(gs_claude_count)
  gs_cleanup
  assert_eq "$held" "yes" "427 AC4: still held" || return 1
  assert_eq "$lab" "yes" "427 AC4: label kept" || return 1
  assert_eq "$c" "1" "427 AC4: no relaunch (the one launch is the seeding tick)" || return 1
}

test_gs_427_held_goal_costs_no_reads_between_syncs() {   # AC5
  GS_SYNC=default gs_held_seed stale
  gs_issue 101 closed 12
  date +%s > "$GS_PIPE/goal-sync.last"
  gs_tick; gs_settle
  local held st; [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=yes || held=no; st=$(gs_reg_state 50)
  gs_cleanup
  assert_eq "$held" "yes" "427 AC5: not re-evaluated when the sync is not due" || return 1
  assert_eq "$st" "open" "427 AC5: not delivered when the sync is not due" || return 1
}

test_gs_427_held_goal_with_unreadable_scope_stays_held() {   # AC1 (failed read: ticket 7 answers 404)
  gs_env
  gs_own "$GS_ID_T7" 50 "$GS_SPEC_T7" 3600 ""
  echo stale > "$GS_PIPE/goal-$GS_ID_T7.snap"; touch "$GS_PIPE/goal-$GS_ID_T7.held"
  gs_reg 50 "$GS_SPEC_T7" "$GS_ID_T7" host-a held
  rm -f "$GS_ST/issues/$GS_A/7.json"
  gs_tick; gs_settle
  local held st; [ -e "$GS_PIPE/goal-$GS_ID_T7.held" ] && held=yes || held=no; st=$(gs_reg_state 50)
  gs_cleanup
  assert_eq "$held" "yes" "427 AC1: a failed read leaves the goal held" || return 1
  assert_eq "$st" "open" "427 AC1: and not delivered" || return 1
}

# ---------------------------------------------------------------- AC5: waiting on JP --------------------------

# Hand arithmetic: 101 DEPLOYED TO STAGING (waiting), 102 closed (delivered) -> no active, 1 waiting -> waiting on JP,
# scope_total 2, scope_delivered 1. Adding 104 (open, READY) -> active again: scope_total 3, scope_delivered 1.
test_gs_ac5_waiting_on_jp_parks_then_resumes_when_ticket_becomes_active() {
  gs_env
  gs_comment 101 $'**[deployer] DEPLOYED TO STAGING**\nstaging up'
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  gs_tick; gs_settle
  local lab c1 cards1 state1 tot1 del1
  gs_has_label 50 goal-waiting-jp && lab=yes || lab=no
  c1=$(gs_claude_count); cards1=$(gs_reg_comment_count 50 '**[deliver] NOTE** card')
  state1=$(gs_json "$GS_ID_MS12" state); tot1=$(gs_json "$GS_ID_MS12" scope_total); del1=$(gs_json "$GS_ID_MS12" scope_delivered)
  gs_tick; gs_settle
  local c2 cards2; c2=$(gs_claude_count); cards2=$(gs_reg_comment_count 50 '**[deliver] NOTE** card')
  gs_issue 104 open 12; gs_comment 104 $'**[product-manager] READY FOR ENGINEERING**\nLane: fast'
  gs_tick
  gs_wait_claude 1
  local lab3 c3 state3 tot3 del3 regstate
  gs_has_label 50 goal-waiting-jp && lab3=yes || lab3=no
  c3=$(gs_claude_count); state3=$(gs_json "$GS_ID_MS12" state); tot3=$(gs_json "$GS_ID_MS12" scope_total); del3=$(gs_json "$GS_ID_MS12" scope_delivered)
  regstate=$(gs_reg_state 50)
  gs_cleanup
  assert_eq "$lab" "yes" "AC5: label goal-waiting-jp added" || return 1
  assert_eq "$c1" "0" "AC5: waiting on JP -> no launch" || return 1
  assert_eq "$cards1" "1" "AC5: one card comment" || return 1
  assert_eq "$state1" "waiting_jp" "AC5: cache mirror state" || return 1
  assert_eq "$tot1" "2" "AC5: scope_total (101,102; the PR 103 is never scope)" || return 1
  assert_eq "$del1" "1" "AC5: scope_delivered (102)" || return 1
  assert_eq "$c2" "0" "AC5: still no launch on the next tick" || return 1
  assert_eq "$cards2" "1" "AC5: card re-posted only if the set changed" || return 1
  assert_eq "$regstate" "open" "AC5: registry issue stays open" || return 1
  assert_eq "$lab3" "no" "AC5: label removed once a ticket is active again" || return 1
  assert_eq "$c3" "1" "AC5: relaunching resumes" || return 1
  assert_eq "$state3" "active" "AC5: cache mirror state active" || return 1
  assert_eq "$tot3" "3" "AC5: scope re-resolved live — the new ticket joined" || return 1
  assert_eq "$del3" "1" "AC5: scope_delivered still 1" || return 1
}

# ---------------------------------------------------------------- AC6: no-progress parking --------------------

# Hand arithmetic (.snap cannot be seeded: its hash is not pinned): decision k with an unchanged scope gives
# .np = k-1 (decision 1 has no .snap -> "different" -> 0). GOAL_MAX_NO_PROGRESS=3 -> parked at decision 4, which
# does not launch. A [project-manager] DECISION comment between cycles must not change the snapshot.
test_gs_ac6_three_unchanged_cycles_park_the_goal() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 1500 0 60
  local k np c held=absent
  for k in 1 2 3; do
    [ "$k" = 3 ] && gs_comment 101 $'**[project-manager] DECISION**\nResolves: https://example.invalid/1\nkeep going'
    [ "$k" -gt 1 ] && gs_launch_state "$GS_ID_MS12" 1500 0 60
    gs_tick; gs_wait_claude "$k"; gs_settle
    np=$(gs_file "$GS_ID_MS12" np); c=$(gs_claude_count)
    assert_eq "$c" "$k" "AC6: decision $k launches (not parked yet)" || { gs_cleanup; return 1; }
    assert_eq "$np" "$((k - 1))" "AC6: .np after decision $k" || { gs_cleanup; return 1; }
    [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && { gs_cleanup; fail "AC6: parked too early (decision $k)"; return 1; }
  done
  gs_launch_state "$GS_ID_MS12" 1500 0 60
  gs_tick; gs_settle
  [ -e "$GS_PIPE/goal-$GS_ID_MS12.held" ] && held=present
  local c4 np4 lab notes state ev
  c4=$(gs_claude_count); np4=$(gs_file "$GS_ID_MS12" np)
  gs_has_label 50 goal-held && lab=yes || lab=no
  notes=$(gs_reg_comment_count 50 'held: no progress in 3 cycles')
  state=$(gs_json "$GS_ID_MS12" state); ev=$(gs_event_count held)
  gs_launch_state "$GS_ID_MS12" 1500 0 60
  gs_tick; gs_settle
  local c5 notes5; c5=$(gs_claude_count); notes5=$(gs_reg_comment_count 50 'held: no progress in 3 cycles')
  gs_cleanup
  assert_eq "$held" "present" "AC6: .held written at the third unchanged cycle" || return 1
  assert_eq "$np4" "3" "AC6: .np reached GOAL_MAX_NO_PROGRESS" || return 1
  assert_eq "$c4" "3" "AC6: the parking decision does not launch" || return 1
  assert_eq "$lab" "yes" "AC6: label goal-held" || return 1
  assert_eq "$notes" "1" "AC6: one held NOTE" || return 1
  assert_eq "$state" "held" "AC6: cache mirror state held" || return 1
  [ "$ev" -ge 1 ] || { fail "AC6: report_status_async \"held\" not invoked (events: $(gs_events | tr '\n' ' '))"; return 1; }
  assert_eq "$c5" "3" "AC6: a held goal is never relaunched" || return 1
  assert_eq "$notes5" "1" "AC6: the held NOTE is posted once" || return 1
}

# A real scope change between cycles resets .np (the other half of "equal -> +1, different -> 0").
test_gs_ac6_changed_snapshot_resets_no_progress() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 1500 0 60
  gs_tick; gs_wait_claude 1
  gs_launch_state "$GS_ID_MS12" 1500 0 60
  gs_tick; gs_wait_claude 2; gs_settle
  local np2; np2=$(gs_file "$GS_ID_MS12" np)
  gs_comment 101 $'**[test-writer] TESTS WRITTEN**\nbranch x'
  gs_launch_state "$GS_ID_MS12" 1500 0 60
  gs_tick; gs_wait_claude 3; gs_settle
  local np3; np3=$(gs_file "$GS_ID_MS12" np)
  gs_cleanup
  assert_eq "$np2" "1" "AC6: unchanged -> .np 1" || return 1
  assert_eq "$np3" "0" "AC6: a new routing marker changes the snapshot -> .np reset to 0" || return 1
}

# ---------------------------------------------------------------- AC7: stop propagation ----------------------

test_gs_ac7_stopped_registry_kills_pid_and_child_and_never_relaunches() {
  gs_env
  gs_reg 50 "$GS_SPEC_T7" "$GS_ID_T7" host-a stopped
  gs_cache 50 "$GS_ID_T7" "$GS_SPEC_T7" host-a
  gs_live "$GS_ID_T7"
  local p=$GS_P c=$GS_C
  gs_tick
  local pd cd=no; gs_wait_dead "$p" && pd=yes || pd=no
  gs_wait_dead "$c" && cd=yes || cd=no
  local left; left=$(gs_goal_file_count "$GS_ID_T7")
  gs_launch_state "$GS_ID_T7" 3600 ""   # launch-eligible shape, to prove the tombstone is what holds it
  gs_tick; gs_settle
  local cnt; cnt=$(gs_claude_count)
  gs_cleanup
  assert_eq "$pd" "yes" "AC7: the goal pid is killed" || return 1
  assert_eq "$cd" "yes" "AC7: its child is killed" || return 1
  assert_eq "$left" "0" "AC7: local files dropped once the registry confirms the stop" || return 1
  assert_eq "$cnt" "0" "AC7: never relaunched" || return 1
}

# "closed in the registry" kills a live local pid even without goal-stopped (closed by hand).
test_gs_ac7_registry_closed_without_goal_stopped_also_kills() {
  gs_env
  gs_reg 50 "$GS_SPEC_T7" "$GS_ID_T7" host-a delivered
  gs_cache 50 "$GS_ID_T7" "$GS_SPEC_T7" host-a
  gs_live "$GS_ID_T7"
  local p=$GS_P r
  gs_tick
  gs_wait_dead "$p" && r=yes || r=no
  gs_cleanup
  assert_eq "$r" "yes" "AC7: a goal closed in the registry loses its live local pid" || return 1
}

# #302: a closed registry goal is acted on once — first sync kills and drops the local files, the second finds nothing.
test_gs_302_closed_goal_logs_once_and_leaves_no_files() {
  gs_env
  gs_reg 50 "$GS_SPEC_T7" "$GS_ID_T7" host-a stopped
  gs_cache 50 "$GS_ID_T7" "$GS_SPEC_T7" host-a
  gs_live "$GS_ID_T7"
  local p=$GS_P
  gs_tick; gs_tick
  local n left dead=no; n=$(gs_log | grep -c "$GS_ID_T7 closed in the registry"); left=$(gs_goal_file_count "$GS_ID_T7")
  gs_wait_dead "$p" && dead=yes
  gs_cleanup
  assert_eq "$n" "1" "#302: one 'closed in the registry' line over two syncs" || return 1
  assert_eq "$left" "0" "#302: no goal-<id>.* file remains" || return 1
  assert_eq "$dead" "yes" "#302: the pid was still killed" || return 1
}

# #302: after the stop, the registry goal reopening (deliver.sh resume) rebuilds the cache and the goal relaunches.
test_gs_302_reopened_goal_rebuilds_cache_and_relaunches() {
  gs_env
  gs_reg 50 "$GS_SPEC_T7" "$GS_ID_T7" host-a stopped
  gs_cache 50 "$GS_ID_T7" "$GS_SPEC_T7" host-a
  gs_tick
  gs_reg 50 "$GS_SPEC_T7" "$GS_ID_T7" host-a active
  gs_tick
  local issue; issue=$(gs_json "$GS_ID_T7" issue)
  gs_launch_state "$GS_ID_T7" 3600 ""
  gs_tick; gs_settle
  local cnt; cnt=$(gs_claude_count)
  gs_cleanup
  assert_eq "$issue" "50" "#302: cache rebuilt from the reopened registry goal" || return 1
  [ "$cnt" -ge 1 ] || { fail "#302: the reopened goal never relaunched"; return 1; }
}

# #302: a closed issue that is not the one the cache tracks (re-registered goal) kills and deletes nothing.
test_gs_302_closed_issue_not_matching_cache_is_left_alone() {
  gs_env
  gs_reg 49 "$GS_SPEC_T7" "$GS_ID_T7" host-a stopped
  gs_cache 50 "$GS_ID_T7" "$GS_SPEC_T7" host-a
  gs_live "$GS_ID_T7"
  local p=$GS_P alive=no
  gs_tick
  gs_alive "$p" && alive=yes
  local left; left=$(gs_goal_file_count "$GS_ID_T7")
  gs_cleanup
  assert_eq "$alive" "yes" "#302: the re-registered goal's pid survives" || return 1
  [ "$left" -ge 1 ] || { fail "#302: the re-registered goal's files were deleted"; return 1; }
}

# ---------------------------------------------------------------- AC8: host pin ------------------------------

# Own goals: ms-12 (dead, eligible -> must launch) and t-7 (alive). Pinned to host-b: t-8 open (dead, eligible — must be
# ignored) and t-9 closed+stopped with a live local pid (must not be killed, and must not count toward MAX_GOALS=2:
# live own = 1, so ms-12 launches; counted it would be 2 and ms-12 would not).
test_gs_ac8_goal_pinned_to_other_host_is_ignored() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  gs_reg 51 "$GS_SPEC_T7" "$GS_ID_T7" host-a active; gs_cache 51 "$GS_ID_T7" "$GS_SPEC_T7" host-a; gs_live "$GS_ID_T7"
  gs_reg 52 "$GS_SPEC_T8" "$GS_ID_T8" host-b active; gs_cache 52 "$GS_ID_T8" "$GS_SPEC_T8" host-b; gs_launch_state "$GS_ID_T8" 3600 ""
  local t8pid; t8pid=$(cat "$GS_PIPE/goal-$GS_ID_T8.pid")
  gs_reg 53 "$GS_SPEC_T9" "$GS_ID_T9" host-b stopped; gs_cache 53 "$GS_ID_T9" "$GS_SPEC_T9" host-b; gs_live "$GS_ID_T9"
  local t9=$GS_P
  gs_tick
  gs_wait_claude 1; gs_settle
  local cnt brief t8now t9alive=no stopped=absent
  cnt=$(gs_claude_count); brief=$(cat "$(gs_last_claude)/argv" 2>/dev/null)
  t8now=$(cat "$GS_PIPE/goal-$GS_ID_T8.pid"); gs_alive "$t9" && t9alive=yes
  [ -e "$GS_PIPE/goal-$GS_ID_T9.stopped" ] && stopped=present
  gs_cleanup
  assert_eq "$cnt" "1" "AC8: exactly the own goal launched (host-b pin not counted against MAX_GOALS, not launched)" || return 1
  assert_contains "$brief" "$GS_ID_MS12" "AC8: the launched goal is the own one" || return 1
  assert_eq "$t8now" "$t8pid" "AC8: host-b goal's pid file untouched" || return 1
  assert_eq "$t9alive" "yes" "AC8: host-b goal's live pid is not killed here" || return 1
  assert_eq "$stopped" "absent" "AC8: no .stopped written for another host's goal" || return 1
}

# ---------------------------------------------------------------- AC9: MAX_GOALS / power / memory --------------

# Three eligible own goals, MAX_GOALS=2, fake claude stays alive: one launch per tick, never a third live goal.
test_gs_ac9_max_goals_and_one_launch_per_tick() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  gs_own "$GS_ID_T7" 51 "$GS_SPEC_T7" 3600 ""
  gs_own "$GS_ID_T8" 52 "$GS_SPEC_T8" 3600 ""
  gs_tick; gs_wait_claude 1; gs_settle
  local c1 c2 c3
  c1=$(gs_claude_count)
  gs_tick; gs_wait_claude 2; gs_settle
  c2=$(gs_claude_count)
  gs_tick; gs_settle
  c3=$(gs_claude_count)
  gs_cleanup
  assert_eq "$c1" "1" "AC9: one launch per tick" || return 1
  assert_eq "$c2" "2" "AC9: second tick launches the second goal" || return 1
  assert_eq "$c3" "2" "AC9: MAX_GOALS=2 reached -> third goal not launched" || return 1
}

test_gs_ac9_power_off_ac_blocks_launch_then_ac_power_launches() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  : > "$GS_BIN/battery"
  gs_tick; gs_settle
  local c1; c1=$(gs_claude_count)
  rm -f "$GS_BIN/battery"
  gs_tick; gs_wait_claude 1
  local c2; c2=$(gs_claude_count)
  gs_cleanup
  assert_eq "$c1" "0" "AC9: power_ok false -> no launch" || return 1
  assert_eq "$c2" "1" "AC9: control — on AC power the same goal launches" || return 1
}

test_gs_ac9_memory_floor_blocks_launch() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  echo 'MEM_FLOOR_MB=99999999' >> "$GS_HOME/.claude/pipeline/config.local.sh"
  gs_tick; gs_settle
  local c1; c1=$(gs_claude_count)
  echo 'MEM_FLOOR_MB=0' >> "$GS_HOME/.claude/pipeline/config.local.sh"
  gs_tick; gs_wait_claude 1
  local c2; c2=$(gs_claude_count)
  gs_cleanup
  assert_eq "$c1" "0" "AC9: mem_available_mb < MEM_FLOOR_MB -> no launch" || return 1
  assert_eq "$c2" "1" "AC9: control — with the floor lifted the goal launches" || return 1
}

# Two orchestrators running + one live goal pid = 2 + 1; MAX_CONCURRENT=3. If goal pids counted in count_running the
# queued orchestrator #42 would not drain (3 >= 3). It must. And the dead own goal ms-12 must still launch (over two
# ticks — one launch per tick): goals are gated by power / memory / MAX_GOALS only, never by orchestrator capacity.
test_gs_ac9_goal_pids_do_not_consume_orchestrator_slots() {
  gs_env
  mk_running "$GS_PIPE" 1 "$GS_CK_A"; mk_running "$GS_PIPE" 2 "$GS_CK_A"
  gs_reg 51 "$GS_SPEC_T7" "$GS_ID_T7" host-a active; gs_cache 51 "$GS_ID_T7" "$GS_SPEC_T7" host-a; gs_live "$GS_ID_T7"
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  mk_queued "$GS_PIPE" 42 "$GS_CK_A"
  gs_tick; gs_settle
  gs_tick; gs_settle
  local pid42=absent d agents="" log
  [ -e "$(rkp "$GS_PIPE/orch-42.pid")" ] && pid42=present
  for d in "$GS_BIN"/claude-calls.*; do [ -e "$d" ] && agents="$agents $(gs_argv_after "$d" --agent)"; done
  log=$(gs_log)
  gs_cleanup
  assert_eq "$pid42" "present" "AC9: queued orchestrator #42 launched despite a live goal pid" || return 1
  assert_contains "$log" "[launch] #42" "AC9: orchestrator launch logged" || return 1
  assert_contains "$agents" "project-manager" "AC9: the goal launched although 2 of 3 orchestrator slots are taken (agents:$agents)" || return 1
}

# ---------------------------------------------------------------- AC10: empty scope ---------------------------

# Hand arithmetic: milestone 20 has no issues. .np seeded 1 (no .snap) -> after one decision 2, not delivered.
test_gs_ac10_empty_scope_is_never_delivered_and_counts_as_no_progress() {
  gs_env
  gs_own "$GS_ID_MS20" 50 "$GS_SPEC_MS20" 1500 0 60
  echo 1 > "$GS_PIPE/goal-$GS_ID_MS20.np"
  gs_tick; gs_settle
  local st np cards files
  st=$(gs_reg_state 50); np=$(gs_file "$GS_ID_MS20" np)
  cards=$(gs_reg_comment_count 50 '**[deliver] NOTE** card'); files=$(gs_goal_file_count "$GS_ID_MS20")
  gs_cleanup
  assert_eq "$st" "open" "AC10: an empty scope is not delivered" || return 1
  assert_eq "$cards" "0" "AC10: no delivery card" || return 1
  assert_ne "$files" "0" "AC10: cache files kept" || return 1
  assert_eq "$np" "2" "AC10: .np incremented 1 -> 2" || return 1
}

# ---------------------------------------------------------------- cache state mirror (#197 reads it) ----------

# Hand arithmetic: ms-12 = 101 (open) + 102 (closed) -> scope_total 2, scope_delivered 1, state active (pid alive).
test_gs_mirror_state_scope_counts_and_last_cycle_at() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  gs_live "$GS_ID_MS12"
  gs_tick
  local st tot del ts issue id
  st=$(gs_json "$GS_ID_MS12" state); tot=$(gs_json "$GS_ID_MS12" scope_total); del=$(gs_json "$GS_ID_MS12" scope_delivered)
  ts=$(gs_json "$GS_ID_MS12" last_cycle_at); issue=$(gs_json "$GS_ID_MS12" issue); id=$(gs_json "$GS_ID_MS12" id)
  gs_cleanup
  assert_eq "$st" "active" "mirror: state" || return 1
  assert_eq "$tot" "2" "mirror: scope_total" || return 1
  assert_eq "$del" "1" "mirror: scope_delivered" || return 1
  printf '%s' "$ts" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || { fail "mirror: last_cycle_at not ISO UTC: [$ts]"; return 1; }
  assert_eq "$issue" "50" "mirror: the registry block copy keeps \"issue\"" || return 1
  assert_eq "$id" "$GS_ID_MS12" "mirror: the registry block copy keeps \"id\"" || return 1
}

# ---------------------------------------------------------------- registry sync -------------------------------

# A goal that is only in the registry (cache lost to a reboot) gets $PIPE/goal-<id>.json; a cache json with no
# "issue", or pointing at a registry issue that does not exist, is rebuilt from the registry (issue 50). No crash.
test_gs_sync_rebuilds_missing_or_stale_cache() {
  local variant rc issue
  for variant in missing no_issue wrong_issue; do
    gs_env
    gs_reg 50 "$GS_SPEC_MS12" "$GS_ID_MS12" host-a active
    case "$variant" in
      no_issue) jq -nc --arg id "$GS_ID_MS12" --arg spec "$GS_SPEC_MS12" '{v:1,id:$id,spec:$spec,host:"host-a"}' > "$GS_PIPE/goal-$GS_ID_MS12.json" ;;
      wrong_issue) gs_cache 999 "$GS_ID_MS12" "$GS_SPEC_MS12" host-a ;;
    esac
    [ "$variant" = missing ] || gs_live "$GS_ID_MS12"
    gs_tick; gs_settle
    rc=$GS_RC; issue=$(gs_json "$GS_ID_MS12" issue)
    gs_cleanup
    assert_eq "$rc" "0" "sync ($variant): the tick does not crash" || return 1
    assert_eq "$issue" "50" "sync ($variant): cache rebuilt with the registry issue number" || return 1
  done
}

# GOAL_SYNC_SECS=300: with the shipped default, a second tick right after the first reads the registry no more.
test_gs_sync_is_throttled_to_once_per_goal_sync_secs() {
  GS_SYNC=default gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  gs_live "$GS_ID_MS12"
  gs_tick
  local r1 r2
  r1=$(grep -c 'labels=delivery-goal' "$GS_BIN/gh-calls.log")
  gs_tick
  r2=$(grep -c 'labels=delivery-goal' "$GS_BIN/gh-calls.log")
  gs_cleanup
  [ "$r1" -ge 1 ] || { fail "sync: the first tick never read the registry"; return 1; }
  assert_eq "$r2" "$r1" "sync: no second registry read within GOAL_SYNC_SECS" || return 1
}

# ---------------------------------------------------------------- AC12: error capture, no secrets -------------

# With the registry read failing, the tick must still end (exit 0), write a [goal] error line carrying the release
# (commit SHA of the checkout) and the host, and call report_status_async once more than the per-tick "tick" push.
test_gs_ac12_registry_read_failure_is_captured_and_does_not_crash_the_tick() {
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 ""
  gs_live "$GS_ID_MS12"
  : > "$GS_BIN/fail-registry"
  gs_tick
  local rc=$GS_RC log sha total errline
  log=$(gs_log); sha=$(cd "$GS_TREE" && git rev-parse HEAD)
  total=$(gs_events | grep -c .)
  errline=$(printf '%s\n' "$log" | grep -F '[goal]' | grep -Ei 'error|fail|cannot|unable|registry' | head -1)
  gs_cleanup
  assert_eq "$rc" "0" "AC12: the tick survives a failing registry read" || return 1
  assert_ne "$errline" "" "AC12: a [goal] error line is logged. Log was:
$log" || return 1
  assert_contains "$errline" "${sha:0:7}" "AC12: the release tag is the checkout's commit SHA" || return 1
  printf '%s' "$errline" | grep -qi 'host-a' || { fail "AC12: the environment tag (host) is missing from [$errline]"; return 1; }
  assert_eq "$total" "2" "AC12: report_status_async: the per-tick push + exactly one error push" || return 1
}

# No token, webhook URL, instructions text or brief text reaches the log or the status payloads — with positive
# controls: a launch line and an error line must be present.
test_gs_ac12_no_secrets_or_brief_text_in_logs() {
  GS_SLACK_TOKEN="xoxb-GSCANARY-slack-token" GS_PUSH_TOKEN="GSCANARY-push-token" \
    GS_PUSH_URL="https://hooks.example.invalid/GSCANARY-webhook" GS_GH_TOKEN="ghp_GSCANARY"
  export GS_SLACK_TOKEN GS_PUSH_TOKEN GS_PUSH_URL GS_GH_TOKEN
  gs_env
  gs_own "$GS_ID_MS12" 50 "$GS_SPEC_MS12" 3600 "" 0 "GSCANARY-instructions-text"
  gs_tick; gs_wait_claude 1
  : > "$GS_BIN/fail-registry"
  gs_tick
  local all log launch=no err=no
  log=$(gs_log)
  all=$(cat "$GS_HOME"/logs/pipeline/* "$GS_RS_LOG" "$GS_HOME/tick.out" 2>/dev/null)
  printf '%s\n' "$log" | grep -F '[goal]' | grep -qi 'launch' && launch=yes
  printf '%s\n' "$log" | grep -F '[goal]' | grep -Eqi 'error|fail|cannot|unable|registry' && err=yes
  unset GS_SLACK_TOKEN GS_PUSH_TOKEN GS_PUSH_URL GS_GH_TOKEN
  gs_cleanup
  assert_eq "$launch" "yes" "AC12: control — a [goal] launch line exists" || return 1
  assert_eq "$err" "yes" "AC12: control — a [goal] error line exists" || return 1
  assert_not_contains "$all" "GSCANARY" "AC12: no token / webhook URL / instructions text in logs or status payloads" || return 1
  assert_not_contains "$all" "You are the delivery lead" "AC12: no brief text in logs" || return 1
}

# ---------------------------------------------------------------- config + library surface --------------------

test_gs_config_ships_the_four_goal_settings() {
  local h v
  h=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-gshome.XXXXXX")
  v=$( HOME="$h"; unset MAX_GOALS GOAL_CYCLE_SECS GOAL_SYNC_SECS GOAL_MAX_NO_PROGRESS
       . "$GS_SKILL/config.sh" >/dev/null 2>&1
       printf '%s/%s/%s/%s' "${MAX_GOALS:-unset}" "${GOAL_CYCLE_SECS:-unset}" "${GOAL_SYNC_SECS:-unset}" "${GOAL_MAX_NO_PROGRESS:-unset}" )
  rm -rf "$h"
  assert_eq "$v" "2/1200/300/3" "config.sh: MAX_GOALS/GOAL_CYCLE_SECS/GOAL_SYNC_SECS/GOAL_MAX_NO_PROGRESS" || return 1
}

test_gs_goal_lib_defines_the_ticket_classifier() {
  local n
  n=$(grep -c '^goal_ticket_state()' "$GS_SKILL/goal-lib.sh")
  assert_eq "$n" "1" "goal-lib.sh defines goal_ticket_state()" || return 1
}

echo "-- goal supervisor (#195)"
run_test test_gs_ac1_dead_pid_no_exit_file_is_relaunched
run_test test_gs_ac1_alive_pid_is_left_alone_until_it_dies
run_test test_gs_ac2_clean_exit_waits_for_cycle_secs_then_relaunches
run_test test_gs_ac3_crash_backoff_indexed_by_restarts_then_clean_exit_resets
run_test test_gs_ac3_short_run_is_transient
run_test test_gs_ac4_all_delivered_closes_registry_with_card_and_removes_cache
run_test test_gs_classify_delivered
run_test test_gs_classify_waiting_jp
run_test test_gs_classify_active
run_test test_gs_428_open_start_gate_without_marker_is_waiting
run_test test_gs_428_closed_start_gate_is_active
run_test test_gs_428_open_gate_with_marker_is_classified_as_today
run_test test_gs_428_unreadable_gate_is_neither_waiting_nor_delivered
run_test test_gs_428_goal_with_start_gated_ticket_reaches_waiting_branch
run_test test_gs_427_held_goal_with_all_tickets_closed_is_delivered
run_test test_gs_427_held_goal_with_changed_snapshot_is_unheld
run_test test_gs_427_held_goal_with_unchanged_snapshot_stays_held_and_is_not_launched
run_test test_gs_427_held_goal_costs_no_reads_between_syncs
run_test test_gs_427_held_goal_with_unreadable_scope_stays_held
run_test test_gs_ac5_waiting_on_jp_parks_then_resumes_when_ticket_becomes_active
run_test test_gs_ac6_three_unchanged_cycles_park_the_goal
run_test test_gs_ac6_changed_snapshot_resets_no_progress
run_test test_gs_ac7_stopped_registry_kills_pid_and_child_and_never_relaunches
run_test test_gs_ac7_registry_closed_without_goal_stopped_also_kills
run_test test_gs_302_closed_goal_logs_once_and_leaves_no_files
run_test test_gs_302_reopened_goal_rebuilds_cache_and_relaunches
run_test test_gs_302_closed_issue_not_matching_cache_is_left_alone
run_test test_gs_ac8_goal_pinned_to_other_host_is_ignored
run_test test_gs_ac9_max_goals_and_one_launch_per_tick
run_test test_gs_ac9_power_off_ac_blocks_launch_then_ac_power_launches
run_test test_gs_ac9_memory_floor_blocks_launch
run_test test_gs_ac9_goal_pids_do_not_consume_orchestrator_slots
run_test test_gs_ac10_empty_scope_is_never_delivered_and_counts_as_no_progress
run_test test_gs_mirror_state_scope_counts_and_last_cycle_at
run_test test_gs_sync_rebuilds_missing_or_stale_cache
run_test test_gs_sync_is_throttled_to_once_per_goal_sync_secs
run_test test_gs_ac12_registry_read_failure_is_captured_and_does_not_crash_the_tick
run_test test_gs_ac12_no_secrets_or_brief_text_in_logs
run_test test_gs_config_ships_the_four_goal_settings
run_test test_gs_goal_lib_defines_the_ticket_classifier
gs_tree_cleanup
