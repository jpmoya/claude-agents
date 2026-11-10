# Shared goal-supervisor sandbox (gs_* helpers, GS_* vars). Sourced by test-goal-supervisor.sh and every file that reuses gs_*.
# Do not copy this file; source it in place. It lives in lib/ so BASH_SOURCE is always the real in-tree file: GS_SKILL is
# derived from here, never from a copy (#628: a copy in /tmp derived "/" and gs_tree_init copied the whole disk).
# Function/variable definitions only; safe to source twice (GS_TREE keeps an already-built tree).

# The helpers below call run_test / assert_* and new_pipe / new_home / fixture_repo. run-tests.sh loads both libs first (and
# assert.sh resets the pass/fail counters when sourced, so it must not be loaded again); a consumer run on its own gets them here.
type run_test >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
type new_pipe >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/fixture.sh"

GS_SKILL=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
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
GS_TREE="${GS_TREE:-}"
GS_PIDS="${GS_PIDS:-}"
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
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/battery" ]; then echo "Now drawing from 'Battery Power'"; else echo "Now drawing from 'AC Power'"; fi
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
    echo "GOAL_SERIAL=0"   # #442: these cases pin the per-host goal rules; GOAL_SERIAL=1 (#554 default) is covered by test-goal-z-serial.sh
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
gs_issue() {  # <n> <state> [milestone number] [pr] [labels csv] [milestone state, default open] [milestone title, default m] [state_reason]
  local n=$1 st=$2 ms=${3:-} pr=${4:-} lb=${5:-} mss=${6:-open} mst=${7:-m} sr=${8:-}
  jq -nc --argjson n "$n" --arg st "$st" --arg ms "$ms" --arg pr "$pr" --arg lb "$lb" --arg now "$GS_NOW" --arg mss "$mss" --arg mst "$mst" --arg sr "$sr" '
    {number:$n, title:("ticket " + ($n|tostring)), body:"", state:$st,
     labels:($lb | split(",") | map(select(length > 0)) | map({name:.})),
     created_at:$now, updated_at:$now, closed_at:(if $st == "closed" then $now else null end),
     milestone:(if $ms == "" then null else {number:($ms|tonumber), title:$mst, state:$mss} end)}
    + (if $pr != "" then {pull_request:{url:"x"}} else {} end)
    + (if $sr != "" then {state_reason:$sr} else {} end)' > "$GS_ST/issues/$GS_A/$n.json"
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
  while [ "$i" -lt 125 ] && [ -z "$c" ]; do c=$(pgrep -P "$GS_P" 2>/dev/null | head -1); [ -n "$c" ] || sleep 0.04; i=$((i + 1)); done
  GS_C=$c; GS_PIDS="$GS_PIDS $GS_C"
  echo "$GS_P" > "$GS_PIPE/goal-$1.pid"
  gs_iso_ago 600 > "$GS_PIPE/goal-$1.launched-at"; gs_iso_ago 600 > "$GS_PIPE/goal-$1.start"
}

gs_alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' '); [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
gs_wait_dead() { local i=0; while [ "$i" -lt 125 ]; do gs_alive "$1" || return 0; sleep 0.04; i=$((i + 1)); done; return 1; }
gs_claude_count() { ls -d "$GS_BIN"/claude-calls.* 2>/dev/null | wc -l | tr -d ' '; }
gs_wait_claude() { local i=0; while [ "$i" -lt 125 ]; do [ "$(gs_claude_count)" -ge "$1" ] && return 0; sleep 0.04; i=$((i + 1)); done; return 1; }
gs_settle() { sleep 0.3; }   # let any (wrongly) launched detached claude show up before asserting "none"
gs_last_claude() { ls -d "$GS_BIN"/claude-calls.* 2>/dev/null | tail -1; }
gs_argv_after() { awk -v k="$2" 'p{print;exit} $0==k{p=1}' "$1/argv"; }

gs_tick() {
  GS_RC=0
  ( cd "$GS_HOME" && env HOME="$GS_HOME" PATH="$GS_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$GS_PIPE" QUEUE="$GS_PIPE/queue" \
      LOGDIR="$GS_HOME/logs/pipeline" GS_RS_LOG="$GS_RS_LOG" \
      SLACK_BOT_TOKEN="${GS_SLACK_TOKEN:-}" SLACK_ENGINEERING_CHANNEL="" \
      STATUS_PUSH_URL="${GS_PUSH_URL:-}" STATUS_PUSH_TOKEN="${GS_PUSH_TOKEN:-}" GH_TOKEN="${GS_GH_TOKEN:-}" \
      bash "$GS_TREE/skills/orchestrate/supervisor.sh" >"$GS_HOME/tick.out" 2>&1 </dev/null ) || GS_RC=$?
  sleep 0.1   # the reporter recorder is backgrounded
}
gs_log() { cat "$GS_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }
gs_events() { cat "$GS_RS_LOG" 2>/dev/null; }
gs_event_count() { grep -cxF -- "$1" "$GS_RS_LOG" 2>/dev/null; }
gs_file() { cat "$GS_PIPE/goal-$1.$2" 2>/dev/null || echo "MISSING"; }
gs_json() { jq -r --arg k "$2" '.[$k] // "MISSING"' "$GS_PIPE/goal-$1.json" 2>/dev/null || echo "NOJSON"; }
gs_goal_file_count() { ls "$GS_PIPE"/goal-"$1".* 2>/dev/null | wc -l | tr -d ' '; }

# ---------------------------------------------------------------- classification drivers ---------------------

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

# gs_classify_sr <issue state> <state_reason> — same as gs_classify, but sets the ticket's state_reason (#557)
gs_classify_sr() {
  local st=$1 sr=$2 out=none
  gs_env
  gs_issue 7 "$st" "" "" "" open m "$sr"
  rm -f "$GS_ST/comments/$GS_A-7.json"
  gs_own "$GS_ID_T7" 50 "$GS_SPEC_T7" 3600 ""
  gs_tick
  if [ "$(gs_reg_state 50)" = closed ] && ! gs_has_label 50 goal-stopped; then out=delivered
  elif gs_has_label 50 goal-waiting-jp; then out=waiting_jp
  elif gs_wait_claude 1; then out=active
  fi
  gs_cleanup
  printf '%s' "$out"
}

# gs_classify_ms <issue state> <milestone state> <milestone title> <comment body…> — gs_classify with a milestone on t-7
gs_classify_ms() {
  local st=$1 mss=$2 mst=$3 b out=none
  shift 3
  gs_env
  gs_issue 7 "$st" 99 "" "" "$mss" "$mst"
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

# the deployer's plain DEPLOYED bodies (staging merge is not delivery; see test-goal-supervisor.sh for the source examples)
GS_DEP_STAGING=$'**[deployer] DEPLOYED**\n- PR #1973 merged to staging\n- Migrations: none\nProduction deploy pending JP\'s review on staging.'
GS_DEP_DIRECT=$'**[deployer] DEPLOYED**\n- PR #12 merged to staging (abc1234)\n- Migrations: none\n- Route: direct — the auto-release workflow promotes it when enabled; otherwise production deploy pending JP\'s review.'
GS_DEP_MAIN=$'**[deployer] DEPLOYED**\n- PR #9 merged to main\n- Migrations: none (n/a)'

# gs_gate_class <gate issue state|missing> <ticket comments…> — t-7 whose body names "Depends on #42 for starting work" (#428).
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

# gs_held_seed <snap|"-"> — ms-12 parked: .held + goal-held label + np=3; "-" leaves the .snap a normal launch tick wrote (#427).
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
