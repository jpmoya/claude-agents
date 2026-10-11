# #193 — goal-bound delivery lead, part 1: registry + goal-lib.sh + deliver.sh (register / status / stop / resume).
#   AC1 register 3 kinds   AC2 title→number   AC3 refusals   AC4 overlap   AC5 brief   AC6 status
#   AC7 stop               AC8 resume         AC9 library contract   AC10 portability / config / no-agents-write
# Expected values come from the ticket / SA design or hand arithmetic in comments — never from the code.
# Everything is prefixed dg_ / DG_ (all test files share one shell). Placeholder repo names only (public repo).
# Isolation: the fake gh / claude / hostname live in an isolated HOME's .local/bin (config.sh prepends it to
# PATH), so no real claude is ever launched and /tmp/pipeline is never touched.
#
# Fake `gh api` is stateful (issues / milestones / comments / labels as files) so what `register` creates is
# visible to the next `status` / overlap lookup. Only `gh api` (REST) is understood: any other invocation
# (gh issue / gh pr / gh repo = GraphQL) exits 1 and is logged — tests assert none happened.
#
# Fixture world (project-a): milestone 12 "v1.2.0 - Goal delivery" with issues 101 (open), 102 (closed) and
# 103 (a PR — never in scope); milestone 13 (title is a superset of 12's) with 201 (open); milestone 20 empty;
# loose open tickets 7, 8, 9. project-b: ticket 1 open. Hand arithmetic: ms-12 scope = {101,102}, 1 closed / 2.

DG_SKILL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DG_REG="example-owner_registry"
DG_SPEC_MS="example-owner/project-a:milestone:12"
DG_SPEC_ALL="example-owner/project-a:milestones:all"
DG_SPEC_T7="example-owner/project-a#7"
DG_ID_MS="example-owner_project-a-ms-12"
DG_ID_ALL="example-owner_project-a-msall-all"
DG_ID_T7="example-owner_project-a-t-7"
DG_TITLE="v1.2.0 - Goal delivery"

# ---------------------------------------------------------------- sandbox ------------------------------------

dg_setup() {
  DG_PIPE=$(new_pipe); DG_HOME=$(new_home)
  DG_BIN="$DG_HOME/.local/bin"; DG_ST="$DG_BIN/state"
  DG_CWD="$DG_HOME/cwd"; DG_CK_A="$DG_HOME/checkouts/project-a"; DG_CK_B="$DG_HOME/checkouts/project-b"
  mkdir -p "$DG_BIN" "$DG_ST/issues/$DG_REG" "$DG_ST/issues/example-owner_project-a" \
           "$DG_ST/issues/example-owner_project-b" "$DG_ST/milestones" "$DG_ST/comments" "$DG_CWD"
  fixture_repo "$DG_CK_A" example-owner/project-a
  fixture_repo "$DG_CK_B" example-owner/project-b
  DG_CK_A=$(cd "$DG_CK_A" && pwd -P)
  DG_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  DG_OLD=$(python3 -c "import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(days=10)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  : > "$DG_BIN/gh-calls.log"; : > "$DG_BIN/writes.log"
  dg_install_fakes
  cat > "$DG_HOME/.claude/pipeline/config.local.sh" <<EOF
DISPATCH_REPOS=("example-owner/project-a:$DG_CK_A" "example-owner/project-b:$DG_CK_B")
GOAL_REGISTRY_REPO=example-owner/registry
${DG_EXTRA_CFG:-}
EOF
  DG_HOST="Host-A"
  dg_seed
}

dg_teardown() {
  cleanup_running
  local p
  for p in $DG_PIDS; do kill "$p" 2>/dev/null; done
  DG_PIDS=""
  rm -rf "$DG_PIPE" "$DG_HOME"
}
DG_PIDS=""

dg_install_fakes() {
  cat > "$DG_BIN/hostname" <<'EOF'
#!/bin/bash
echo "${DG_HOST:-Host-A}"
EOF
  cat > "$DG_BIN/claude" <<'EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
d=$(mktemp -d "$HERE/claude-calls.XXXXXX")
printf '%s\n' "$@" > "$d/argv"
pwd -P > "$d/cwd"
exit 0
EOF
  cat > "$DG_BIN/gh" <<'GH_EOF'
#!/bin/bash
# Stateful fake `gh api` (REST only). State: $S/issues/<owner_repo>/<n>.json, $S/milestones/<owner_repo>.json,
# $S/comments/<owner_repo>-<n>.json, $S/labels/<owner_repo>.
HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/state"
printf '%s\n' "$*" >> "$HERE/gh-calls.log"
if [ "$1" != "api" ]; then echo "fake gh: non-REST (GraphQL) call: $*" >&2; exit 1; fi
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
if [ -z "$method" ]; then
  if [ "$obj" != "{}" ]; then method=POST; else method=GET; fi
fi
path=${path#/}
p=${path%%\?*}; q=""; case "$path" in *\?*) q=${path#*\?} ;; esac
qget() { printf '%s' "$q" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 | sed 's/%3A/:/g;s/%2C/,/g'; }
if [ "$method" = GET ] && [ "$obj" != "{}" ]; then   # gh sends -f fields as query params on GET
  for k in $(printf '%s' "$obj" | jq -r 'keys[]'); do q="$q&$k=$(printf '%s' "$obj" | jq -r --arg k "$k" '.[$k]')"; done
fi
emit() { if [ -n "$expr" ]; then jq -r "$expr"; else cat; fi; }
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
case "$p" in repos/*/*/*) ;; *) echo "fake gh: unexpected path $p" >&2; exit 1 ;; esac
owner=$(printf '%s' "$p" | cut -d/ -f2); repo=$(printf '%s' "$p" | cut -d/ -f3); seg=$(printf '%s' "$p" | cut -d/ -f4-)
rk="${owner}_${repo}"; D="$S/issues/$rk"; mkdir -p "$D" "$S/comments" "$S/milestones" "$S/labels"
if [ "$method" != GET ]; then printf '%s %s %s\n' "$method" "$p" "$obj" >> "$HERE/writes.log"; fi
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
  "POST issues")
    max=899; for f in "$D"/*.json; do [ -e "$f" ] || continue; b=$(basename "$f" .json); [ "$b" -gt "$max" ] && max=$b; done
    n=$((max + 1))
    printf '%s' "$obj" | jq -c --argjson n "$n" --arg now "$now" '{number:$n, title:(.title // ""), body:(.body // ""),
      state:"open", labels:((.labels // []) | map({name:.})), milestone:null, closed_at:null, created_at:$now, updated_at:$now}' > "$(issue_file "$n")"
    emit < "$(issue_file "$n")" ;;
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
    n=$(printf '%s' "$seg" | cut -d/ -f2); f="$S/comments/$rk-$n.json"; [ -f "$f" ] || echo '[]' > "$f"
    jq -c --argjson o "$obj" --arg now "$now" '. + [{created_at:$now, user:{login:"fake"}, body:($o.body // "")}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo '{}' | emit ;;
  "POST labels")
    name=$(printf '%s' "$obj" | jq -r '.name // empty')
    if grep -qxF -- "$name" "$S/labels/$rk" 2>/dev/null; then echo "gh: Validation Failed (HTTP 422) already_exists" >&2; exit 1; fi
    printf '%s\n' "$name" >> "$S/labels/$rk"; echo '{}' | emit ;;
  *) echo "fake gh: unsupported REST call: $method $p" >&2; exit 1 ;;
esac
GH_EOF
  chmod +x "$DG_BIN/hostname" "$DG_BIN/claude" "$DG_BIN/gh"
}

# ---------------------------------------------------------------- fixture builders ---------------------------

# dg_milestone <owner_repo_key> <number> <title> [state]
dg_milestone() {
  local f="$DG_ST/milestones/$1.json"; [ -f "$f" ] || echo '[]' > "$f"
  jq -c --argjson n "$2" --arg t "$3" --arg s "${4:-open}" '. + [{number:$n, title:$t, state:$s}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# dg_issue <owner_repo_key> <n> <open|closed> [milestone_number|""] [pr]
dg_issue() {
  local rk=$1 n=$2 st=$3 ms=${4:-} pr=${5:-}
  jq -nc --argjson n "$n" --arg st "$st" --arg ms "$ms" --arg pr "$pr" --arg now "$DG_NOW" '
    {number:$n, title:("ticket " + ($n|tostring)), body:"", state:$st, labels:[], created_at:$now, updated_at:$now,
     closed_at:(if $st == "closed" then $now else null end),
     milestone:(if $ms == "" then null else {number:($ms|tonumber), title:"m"} end)}
    + (if $pr != "" then {pull_request:{url:"x"}} else {} end)' > "$DG_ST/issues/$rk/$n.json"
}

# dg_set_state <owner_repo_key> <n> <open|closed>
dg_set_state() {
  local f="$DG_ST/issues/$1/$2.json"
  jq -c --arg st "$3" --arg now "$DG_NOW" '.state = $st | .closed_at = (if $st == "closed" then $now else null end)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# dg_comment <owner_repo_key> <n> <body>
dg_comment() {
  local f="$DG_ST/comments/$1-$2.json"; [ -f "$f" ] || echo '[]' > "$f"
  jq -c --arg b "$3" --arg now "$DG_NOW" '. + [{created_at:$now, user:{login:"fixture"}, body:$b}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

dg_seed() {
  local a=example-owner_project-a b=example-owner_project-b
  dg_milestone $a 12 "$DG_TITLE"; dg_milestone $a 13 "$DG_TITLE 2"; dg_milestone $a 20 "empty"
  dg_issue $a 101 open 12; dg_issue $a 102 closed 12; dg_issue $a 103 open 12 pr
  dg_issue $a 201 open 13
  dg_issue $a 7 open; dg_issue $a 8 open; dg_issue $a 9 open
  dg_issue $b 1 open
  dg_comment $a 101 $'**[product-manager] READY FOR ENGINEERING**\nLane: fast'
}

# dg_goal <registry issue number> <spec> <host> <active|held|waiting|stopped|delivered|delivered_old> [instructions]
# A registry issue exactly as the pinned schema describes it (title, body line 1 + one fenced json block, labels).
# The id is derived here by hand from the pinned rule for the specs used in tests (passed via DG_GOAL_ID).
dg_goal() {
  local n=$1 spec=$2 host=$3 st=$4 instr=${5:-} id=$DG_GOAL_ID block labels='["delivery-goal"]' state=open closed=null upd=$DG_NOW
  block=$(jq -nc --arg id "$id" --arg spec "$spec" --arg host "$host" --arg ins "$instr" --arg c "$DG_NOW" \
    '{v:1,id:$id,spec:$spec,host:$host,created:$c,instructions:$ins}')
  case "$st" in
    held)          labels='["delivery-goal","goal-held"]' ;;
    waiting)       labels='["delivery-goal","goal-waiting-jp"]' ;;
    stopped)       labels='["delivery-goal","goal-stopped"]'; state=closed; closed="\"$DG_NOW\"" ;;
    delivered)     state=closed; closed="\"$DG_NOW\"" ;;
    delivered_old) state=closed; closed="\"$DG_OLD\""; upd=$DG_OLD ;;
  esac
  jq -nc --argjson n "$n" --arg title "Goal: $spec" --arg body "$(printf 'Goal: %s\n\n```json\n%s\n```\n' "$spec" "$block")" \
    --argjson labels "$labels" --arg state "$state" --argjson closed "$closed" --arg now "$DG_NOW" --arg upd "$upd" \
    '{number:$n, title:$title, body:$body, state:$state, labels:($labels|map({name:.})), milestone:null,
      closed_at:$closed, created_at:$now, updated_at:$upd}' > "$DG_ST/issues/$DG_REG/$n.json"
}

# dg_block <registry issue file> — the fenced json block of the registry body
dg_block() { jq -r .body "$1" | awk '/^```json$/{f=1;next} /^```$/{f=0} f'; }

# dg_reg_files — every registry issue file carrying the delivery-goal label
dg_reg_files() {
  local f
  for f in "$DG_ST/issues/$DG_REG"/*.json; do
    [ -e "$f" ] || continue
    jq -e 'any(.labels[]; .name == "delivery-goal")' "$f" >/dev/null 2>&1 && echo "$f"
  done
}
dg_reg_count() { dg_reg_files | wc -l | tr -d ' '; }
dg_reg_file_for() {  # dg_reg_file_for <id>
  local f
  for f in $(dg_reg_files); do [ "$(dg_block "$f" | jq -r .id 2>/dev/null)" = "$1" ] && { echo "$f"; return 0; }; done
  return 1
}
dg_has_label() { jq -e --arg l "$2" 'any(.labels[]; .name == $l)' "$1" >/dev/null 2>&1; }
dg_goal_files() { ls "$DG_PIPE"/goal-* 2>/dev/null | wc -l | tr -d ' '; }
dg_claude_count() { ls -d "$DG_BIN"/claude-calls.* 2>/dev/null | wc -l | tr -d ' '; }
dg_wait_claude() {  # dg_wait_claude <n> — poll up to ~6 s for n fake-claude launches
  local i=0; while [ "$i" -lt 30 ]; do [ "$(dg_claude_count)" -ge "$1" ] && return 0; sleep 0.2; i=$((i + 1)); done; return 1
}
dg_last_claude_dir() { ls -d "$DG_BIN"/claude-calls.* 2>/dev/null | tail -1; }
dg_writes() { wc -l < "$DG_BIN/writes.log" | tr -d ' '; }
dg_alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' '); [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
dg_wait_dead() {  # dg_wait_dead <pid> — up to ~4 s
  local i=0; while [ "$i" -lt 20 ]; do dg_alive "$1" || return 0; sleep 0.2; i=$((i + 1)); done; return 1
}
dg_dead_pid() { local p=99999; while kill -0 "$p" 2>/dev/null; do p=$((p - 1)); done; echo "$p"; }
dg_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# dg_run <args…> — runs deliver.sh in the sandbox. Sets DG_RC / DG_OUT / DG_ERR.
dg_run() {
  local errf="$DG_HOME/stderr.txt"
  DG_OUT=$(cd "$DG_CWD" && env HOME="$DG_HOME" PIPE="$DG_PIPE" LOGDIR="$DG_HOME/logs/pipeline" DG_HOST="$DG_HOST" \
    PATH="$DG_BIN:$PATH" bash "$DG_SKILL/deliver.sh" "$@" 2>"$errf" </dev/null); DG_RC=$?
  DG_ERR=$(cat "$errf")
}

# dg_lib '<snippet>' — runs a snippet with config.sh + pipeline-lib.sh + markers + goal-lib.sh sourced (same env as dg_run)
dg_lib() {
  local errf="$DG_HOME/stderr.txt"
  DG_OUT=$(cd "$DG_CWD" && env HOME="$DG_HOME" PIPE="$DG_PIPE" LOGDIR="$DG_HOME/logs/pipeline" DG_HOST="$DG_HOST" \
    PATH="$DG_BIN:$PATH" bash -c '. "$1/config.sh"; . "$1/pipeline-lib.sh"; . "$1/../../hooks/pipeline-markers.sh"; . "$1/goal-lib.sh"; eval "$2"' \
    _ "$DG_SKILL" "$1" 2>"$errf" </dev/null); DG_RC=$?
  DG_ERR=$(cat "$errf")
}

# dg_pidfile <id> <pid>
dg_pidfile() { echo "$2" > "$DG_PIPE/goal-$1.pid"; }

# dg_live_tree — starts `bash -c 'sleep 300 & wait'`; sets DG_P (the bash pid) and DG_C (its sleep child).
dg_live_tree() {
  bash -c 'sleep 300 & wait' >/dev/null 2>&1 &
  DG_P=$!; disown "$DG_P" 2>/dev/null
  DG_PIDS="$DG_PIDS $DG_P"
  local i=0 c=""
  while [ "$i" -lt 25 ] && [ -z "$c" ]; do c=$(pgrep -P "$DG_P" 2>/dev/null | head -1); [ -n "$c" ] || sleep 0.2; i=$((i + 1)); done
  DG_C=$c; DG_PIDS="$DG_PIDS $DG_C"
}

# ---------------------------------------------------------------- AC1: register the three goal kinds ---------

# dg_check_register <spec> <id> <expected scope count> — shared body for the three kinds
dg_check_register() {
  local spec=$1 id=$2 f blk n d line
  dg_run "$spec" "focus on quotes"
  assert_eq "$DG_RC" "0" "AC1: register exits 0 (stderr: $DG_ERR)" || return 1
  assert_contains "$DG_OUT" "$id" "AC1: stdout prints the goal id" || return 1
  assert_contains "$DG_OUT" "goal-$id.log" "AC1: stdout prints the log path" || return 1
  assert_eq "$(dg_reg_count)" "1" "AC1: exactly one registry issue" || return 1
  f=$(dg_reg_file_for "$id"); assert_ne "$f" "" "AC1: registry block carries id $id" || return 1
  assert_eq "$(jq -r .title "$f")" "Goal: $spec" "AC1: title" || return 1
  assert_eq "$(jq -r .body "$f" | head -1)" "Goal: $spec" "AC1: body line 1" || return 1
  assert_eq "$(jq -r .state "$f")" "open" "AC1: registry issue is open (= active)" || return 1
  dg_has_label "$f" delivery-goal || { fail 'AC1: label delivery-goal'; return 1; }
  blk=$(dg_block "$f")
  assert_eq "$(printf '%s' "$blk" | jq -r .v)" "1" "AC1: block v" || return 1
  assert_eq "$(printf '%s' "$blk" | jq -r .spec)" "$spec" "AC1: block spec" || return 1
  assert_eq "$(printf '%s' "$blk" | jq -r .host)" "host-a" "AC1: block host = lowercased short hostname" || return 1
  assert_eq "$(printf '%s' "$blk" | jq -r .instructions)" "focus on quotes" "AC1: block instructions" || return 1
  printf '%s' "$(printf '%s' "$blk" | jq -r .created)" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || { fail "AC1: created is ISO UTC, got $(printf '%s' "$blk" | jq -r .created)"; return 1; }
  n=$(basename "$f" .json)
  assert_file_exists "$DG_PIPE/goal-$id.json" "AC1: cache json" || return 1
  assert_eq "$(jq -r .issue "$DG_PIPE/goal-$id.json")" "$n" "AC1: cache json carries the registry issue number" || return 1
  assert_eq "$(jq -r .id "$DG_PIPE/goal-$id.json")" "$id" "AC1: cache json carries the block" || return 1
  assert_file_exists "$DG_PIPE/goal-$id.start" "AC1: .start" || return 1
  assert_file_exists "$DG_PIPE/goal-$id.launched-at" "AC1: .launched-at" || return 1
  assert_file_exists "$DG_PIPE/goal-$id.pid" "AC1: .pid" || return 1
  dg_wait_claude 1 || { fail 'AC1: fake claude was never launched'; return 1; }
  sleep 1
  assert_eq "$(dg_claude_count)" "1" "AC1: claude launched exactly once" || return 1
  d=$(dg_last_claude_dir)
  assert_eq "$(awk 'p{print;exit} $0=="--agent"{p=1}' "$d/argv")" "project-manager" "AC1: --agent project-manager" || return 1
  assert_contains "$(cat "$d/argv")" "--dangerously-skip-permissions" "AC1: launch flags" || return 1
  assert_contains "$(cat "$d/argv")" "$id" "AC1: the prompt (brief) names the goal id" || return 1
  assert_eq "$(cat "$d/cwd")" "$DG_CK_A" "AC1: cwd = the repo's DISPATCH_REPOS checkout" || return 1
  local i=0; while [ "$i" -lt 25 ] && [ ! -s "$DG_PIPE/goal-$id.exit" ]; do sleep 0.2; i=$((i + 1)); done
  assert_eq "$(cat "$DG_PIPE/goal-$id.exit" 2>/dev/null)" "0" "AC1: wrapper writes the cycle exit code to goal-<id>.exit" || return 1
}

test_dg_register_milestone_number() { dg_setup; dg_check_register "$DG_SPEC_MS" "$DG_ID_MS"; local rc=$?; dg_teardown; return $rc; }
test_dg_register_milestones_all()   { dg_setup; dg_check_register "$DG_SPEC_ALL" "$DG_ID_ALL"; local rc=$?; dg_teardown; return $rc; }
test_dg_register_ticket()           { dg_setup; dg_check_register "$DG_SPEC_T7" "$DG_ID_T7"; local rc=$?; dg_teardown; return $rc; }

test_dg_register_instructions_survive_json_escaping() {
  dg_setup
  local ins f rc=0
  ins=$'say "hi" `code`\nline2 ``` end \\ back'
  dg_run "$DG_SPEC_T7" "$ins"
  assert_eq "$DG_RC" "0" "AC1: exits 0 (stderr: $DG_ERR)" \
    && f=$(dg_reg_file_for "$DG_ID_T7") && assert_ne "$f" "" "AC1: registry block still parses" \
    && assert_eq "$(dg_block "$f" | jq -r .instructions)" "$ins" "AC1: instructions with quotes/newlines/backticks round-trip" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC2: milestone by exact title -------------

test_dg_milestone_title_resolves_to_number() {
  dg_setup
  local f rc=0
  dg_run "example-owner/project-a:milestone:$DG_TITLE"
  assert_eq "$DG_RC" "0" "AC2: exact title registers (stderr: $DG_ERR)" || rc=1
  # hand: title "v1.2.0 - Goal delivery" is milestone 12 (13's title only has a suffix) → id …-ms-12
  if [ "$rc" = 0 ]; then
    f=$(dg_reg_file_for "$DG_ID_MS")
    assert_ne "$f" "" "AC2: id uses the resolved number 12, not the title" \
      && assert_eq "$(dg_block "$f" | jq -r .spec)" "example-owner/project-a:milestone:$DG_TITLE" "AC2: spec kept as typed" || rc=1
  fi
  dg_lib "goal_scope 'example-owner/project-a:milestone:$DG_TITLE' | sort"
  assert_eq "$DG_OUT" "$(printf 'example-owner/project-a#101\nexample-owner/project-a#102')" \
    "AC2: scope of a title goal = milestone 12's issues (PR 103 excluded)" || rc=1
  dg_teardown; return $rc
}

test_dg_unknown_milestone_title_refused() {
  dg_setup
  local rc=0
  dg_run "example-owner/project-a:milestone:No such milestone"
  assert_eq "$DG_RC" "1" "AC2: unknown title exits 1" \
    && assert_contains "$DG_ERR" "No such milestone" "AC2: refusal names the unresolvable title (wording unpinned by ticket; a gh error would not name it)" \
    && assert_eq "$(dg_reg_count)" "0" "AC2: no registry issue" \
    && assert_eq "$(dg_goal_files)" "0" "AC2: no goal-* files" \
    && assert_eq "$(dg_writes)" "0" "AC2: no GitHub write at all" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC3: every negative input is refused ------

# dg_check_refused <spec> <reason-fragment> — exit 1, the named reason on stderr, nothing created anywhere
# (fragments are the ticket's / SA contract's refusal wording: malformed | DISPATCH_REPOS | empty scope)
dg_check_refused() {
  dg_run "$1"
  assert_eq "$DG_RC" "1" "AC3: [$1] must exit 1 (stderr: $DG_ERR)" || return 1
  assert_ne "$DG_ERR" "" "AC3: [$1] must print a reason on stderr" || return 1
  assert_contains "$DG_ERR" "$2" "AC3: [$1] must refuse for the right reason ($2)" || return 1
  assert_not_contains "$DG_OUT" "registered" "AC3: [$1] must not claim registration" || return 1
  assert_eq "$(dg_reg_count)" "0" "AC3: [$1] no registry issue" || return 1
  assert_eq "$(dg_goal_files)" "0" "AC3: [$1] no goal-* files" || return 1
  assert_eq "$(dg_writes)" "0" "AC3: [$1] nothing written to GitHub (no label, no issue)" || return 1
  assert_eq "$(dg_claude_count)" "0" "AC3: [$1] nothing launched" || return 1
}

test_dg_refuse_repo_outside_dispatch_repos() { dg_setup; dg_check_refused "example-owner/not-dispatched:milestone:1" "not in DISPATCH_REPOS"; local rc=$?; dg_teardown; return $rc; }
test_dg_refuse_empty_milestone_ref()         { dg_setup; dg_check_refused "example-owner/project-a:milestone:" "malformed"; local rc=$?; dg_teardown; return $rc; }
test_dg_refuse_bogus_kind()                  { dg_setup; dg_check_refused "example-owner/project-a:bogus:1" "malformed"; local rc=$?; dg_teardown; return $rc; }
test_dg_refuse_non_numeric_ticket()          { dg_setup; dg_check_refused "example-owner/project-a#abc" "malformed"; local rc=$?; dg_teardown; return $rc; }
test_dg_refuse_milestone_with_zero_issues()  { dg_setup; dg_check_refused "example-owner/project-a:milestone:20" "empty scope"; local rc=$?; dg_teardown; return $rc; }
test_dg_refuse_ticket_that_is_a_pr()         { dg_setup; dg_check_refused "example-owner/project-a#103" "empty scope"; local rc=$?; dg_teardown; return $rc; }
test_dg_refuse_missing_ticket()              { dg_setup; dg_check_refused "example-owner/project-a#999" "empty scope"; local rc=$?; dg_teardown; return $rc; }
test_dg_refuse_repo_with_empty_milestones_all() {
  dg_setup
  # project-b has no milestones at all → milestones:all has an empty scope
  dg_check_refused "example-owner/project-b:milestones:all" "empty scope"; local rc=$?
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC4: overlap -------------------------------

test_dg_overlap_shared_ticket_refused_naming_conflict() {
  dg_setup
  local rc=0
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "AC4 setup: first goal registers" || rc=1
  dg_wait_claude 1
  dg_run "example-owner/project-a#101"
  assert_eq "$DG_RC" "1" "AC4: ticket 101 is in live goal ms-12 → refused" \
    && assert_contains "$DG_ERR" "$DG_ID_MS" "AC4: stderr names the conflicting goal id" \
    && assert_eq "$(dg_reg_count)" "1" "AC4: no second registry issue" \
    && assert_eq "$(dg_claude_count)" "1" "AC4: no second launch" || rc=1
  dg_teardown; return $rc
}

test_dg_overlap_disjoint_goal_same_repo_accepted() {
  dg_setup
  local rc=0
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "AC4 setup: first goal registers" || rc=1
  dg_run "$DG_SPEC_T7"
  assert_eq "$DG_RC" "0" "AC4: disjoint ticket 7 on the same repo is accepted (stderr: $DG_ERR)" \
    && assert_eq "$(dg_reg_count)" "2" "AC4: two registry goals" || rc=1
  dg_teardown; return $rc
}

test_dg_overlap_judged_from_registry_with_empty_pipe() {
  dg_setup
  local rc=0
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "AC4 setup: registered on host-a" || rc=1
  rm -rf "$DG_PIPE"; DG_PIPE=$(new_pipe); DG_HOST="Host-B"      # a second host: empty cache, other hostname
  dg_run "example-owner/project-a#102"
  assert_eq "$DG_RC" "1" "AC4: second host with an empty \$PIPE still sees the live goal" \
    && assert_contains "$DG_ERR" "$DG_ID_MS" "AC4: names the conflicting id" \
    && assert_eq "$(dg_goal_files)" "0" "AC4: refusal creates no local files" || rc=1
  dg_teardown; return $rc
}

test_dg_overlap_ticket_goal_then_milestone_containing_it() {
  dg_setup
  local rc=0
  dg_run "example-owner/project-a#101"; assert_eq "$DG_RC" "0" "AC4 setup: ticket goal registers" || rc=1
  dg_run "$DG_SPEC_MS"
  assert_eq "$DG_RC" "1" "AC4: milestone 12 contains live ticket 101 → refused" \
    && assert_contains "$DG_ERR" "example-owner_project-a-t-101" "AC4: names the ticket goal" || rc=1
  dg_teardown; return $rc
}

test_dg_overlap_same_goal_twice_refused() {
  dg_setup
  local rc=0
  dg_run "$DG_SPEC_T7"; assert_eq "$DG_RC" "0" "AC4 setup" || rc=1
  dg_run "$DG_SPEC_T7"
  assert_eq "$DG_RC" "1" "AC4: identical goal while live → refused" \
    && assert_contains "$DG_ERR" "$DG_ID_T7" "AC4: names the id" \
    && assert_eq "$(dg_reg_count)" "1" "AC4: still one registry issue" || rc=1
  dg_teardown; return $rc
}

test_dg_overlap_milestones_all_refused_while_other_goal_open() {
  dg_setup
  local rc=0
  # ticket 7 is in no milestone, so scopes are disjoint — the spec rule alone must refuse (ticket: "either spec is
  # milestones:all for the same repo while the other is open").
  dg_run "$DG_SPEC_T7"; assert_eq "$DG_RC" "0" "AC4 setup" || rc=1
  dg_run "$DG_SPEC_ALL"
  assert_eq "$DG_RC" "1" "AC4: milestones:all while another goal of that repo is open → refused" \
    && assert_contains "$DG_ERR" "$DG_ID_T7" "AC4: names the open goal" || rc=1
  dg_teardown; return $rc
}

test_dg_overlap_goal_refused_while_milestones_all_open() {
  dg_setup
  local rc=0
  dg_run "$DG_SPEC_ALL"; assert_eq "$DG_RC" "0" "AC4 setup: msall registers (stderr: $DG_ERR)" || rc=1
  dg_run "example-owner/project-a#8"      # 8 is in no open milestone: disjoint scope, same repo
  assert_eq "$DG_RC" "1" "AC4: any goal of the repo while milestones:all is open → refused" \
    && assert_contains "$DG_ERR" "$DG_ID_ALL" "AC4: names the msall goal" || rc=1
  dg_teardown; return $rc
}

test_dg_overlap_other_repo_unaffected_by_milestones_all() {
  dg_setup
  local rc=0
  dg_run "$DG_SPEC_ALL"; assert_eq "$DG_RC" "0" "AC4 setup" || rc=1
  dg_run "example-owner/project-b#1"
  assert_eq "$DG_RC" "0" "AC4: a goal on another repo is not blocked (stderr: $DG_ERR)" || rc=1
  dg_teardown; return $rc
}

test_dg_overlap_held_goal_is_live_closed_goals_are_not() {
  dg_setup
  local rc=0
  DG_GOAL_ID=$DG_ID_T7; dg_goal 501 "$DG_SPEC_T7" host-a held
  DG_GOAL_ID=example-owner_project-a-t-8; dg_goal 502 "example-owner/project-a#8" host-a delivered
  DG_GOAL_ID=example-owner_project-a-t-9; dg_goal 503 "example-owner/project-a#9" host-a stopped
  dg_run "$DG_SPEC_T7"
  assert_eq "$DG_RC" "1" "AC4: a parked (goal-held) goal still owns its tickets" \
    && assert_contains "$DG_ERR" "$DG_ID_T7" "AC4: names the held goal" || rc=1
  dg_run "example-owner/project-a#8"
  assert_eq "$DG_RC" "0" "AC4: delivered (closed) goal no longer blocks (stderr: $DG_ERR)" || rc=1
  dg_run "example-owner/project-a#9"
  assert_eq "$DG_RC" "0" "AC4: stopped (closed) goal no longer blocks (stderr: $DG_ERR)" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC5: brief ---------------------------------

test_dg_brief_contents_from_live_state() {
  dg_setup
  local out line rc=0
  DG_GOAL_ID=$DG_ID_MS; dg_goal 501 "$DG_SPEC_MS" host-a active "prefer small PRs"
  dg_lib "goal_brief $DG_ID_MS"
  out=$DG_OUT
  assert_eq "$DG_RC" "0" "AC5: goal_brief exits 0 (stderr: $DG_ERR)" || rc=1
  assert_contains "$out" "$DG_SPEC_MS" "AC5: spec" || rc=1
  assert_contains "$out" "$DG_ID_MS" "AC5: id" || rc=1
  assert_contains "$out" "prefer small PRs" "AC5: the user's instructions" || rc=1
  assert_contains "$out" "$DG_CK_A" "AC5: checkout path" || rc=1
  assert_contains "$out" "$DG_HOME/logs/pipeline/goals/$DG_ID_MS.md" "AC5: the lead's memory log path" || rc=1
  line=$(printf '%s\n' "$out" | grep -F 'example-owner/project-a#101' | head -1)
  assert_contains "$line" "open" "AC5: ticket 101 line shows open" || rc=1
  assert_contains "$line" "READY FOR ENGINEERING" "AC5: ticket 101 line shows its latest marker" || rc=1
  line=$(printf '%s\n' "$out" | grep -F 'example-owner/project-a#102' | head -1)
  assert_contains "$(dg_lc "$line")" "closed" "AC5: ticket 102 line shows closed" || rc=1
  assert_not_contains "$out" "project-a#103" "AC5: PR 103 is not scope" || rc=1
  out=$(dg_lc "$out")
  assert_contains "$out" "one cycle" "AC5: the one-cycle rule" || rc=1
  assert_contains "$out" "jp-only" "AC5: the JP-only rule" || rc=1
  assert_contains "$out" "supervisor" "AC5: completion is decided by the supervisor" || rc=1
  assert_contains "$out" "dispatch_repos" "AC5: goals only on DISPATCH_REPOS" || rc=1
  dg_teardown; return $rc
}

test_dg_brief_follows_live_state_not_cache() {
  dg_setup
  local first second rc=0
  DG_GOAL_ID=$DG_ID_MS; dg_goal 501 "$DG_SPEC_MS" host-a active "real instructions"
  # a cache that disagrees with the registry on everything
  echo '{"v":1,"id":"'"$DG_ID_MS"'","spec":"STALE-SPEC","host":"host-a","instructions":"STALE-CACHE","issue":501}' > "$DG_PIPE/goal-$DG_ID_MS.json"
  dg_lib "goal_brief $DG_ID_MS"; first=$DG_OUT
  assert_contains "$first" "real instructions" "AC5: instructions come from the registry" || rc=1
  assert_not_contains "$first" "STALE-CACHE" "AC5: cache is not read" || rc=1
  assert_contains "$(printf '%s\n' "$first" | grep -F 'project-a#101' | head -1)" "open" "AC5: 101 open before" || rc=1
  dg_set_state example-owner_project-a 101 closed          # GitHub changes between the two calls
  dg_issue example-owner_project-a 104 open 12             # …and a new ticket joins the milestone
  rm -f "$DG_PIPE/goal-$DG_ID_MS.json"                     # …and the cache is gone altogether
  dg_lib "goal_brief $DG_ID_MS"; second=$DG_OUT
  assert_eq "$DG_RC" "0" "AC5: brief works with no cache (stderr: $DG_ERR)" || rc=1
  assert_contains "$(dg_lc "$(printf '%s\n' "$second" | grep -F 'project-a#101' | head -1)")" "closed" "AC5: 101 now closed" || rc=1
  assert_contains "$second" "project-a#104" "AC5: the new ticket appears" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC6: status --------------------------------

# dg_status_fixture <with_pids 1|0> — eight registry goals covering every state (hand arithmetic below)
dg_status_fixture() {
  local a=example-owner_project-a
  dg_issue $a 31 open; dg_issue $a 32 open; dg_issue $a 33 open; dg_issue $a 34 closed
  dg_issue $a 35 closed; dg_issue $a 36 closed; dg_issue $a 37 open
  DG_GOAL_ID=$DG_ID_MS;        dg_goal 501 "$DG_SPEC_MS" host-a active          # 101 open, 102 closed → 1/2
  DG_GOAL_ID=$a-t-31;          dg_goal 502 "example-owner/project-a#31" host-a active      # 0/1
  DG_GOAL_ID=$a-t-32;          dg_goal 503 "example-owner/project-a#32" host-a held        # 0/1
  DG_GOAL_ID=$a-t-33;          dg_goal 504 "example-owner/project-a#33" host-a waiting     # 0/1
  DG_GOAL_ID=$a-t-34;          dg_goal 505 "example-owner/project-a#34" host-a stopped     # 1/1
  DG_GOAL_ID=$a-t-35;          dg_goal 506 "example-owner/project-a#35" host-a delivered   # 1/1
  DG_GOAL_ID=$a-t-36;          dg_goal 507 "example-owner/project-a#36" host-a delivered_old
  DG_GOAL_ID=$a-t-37;          dg_goal 508 "example-owner/project-a#37" host-b active      # 0/1
  if [ "$1" = 1 ]; then
    sleep 300 & DG_LIVE=$!; DG_PIDS="$DG_PIDS $DG_LIVE"
    dg_pidfile "$DG_ID_MS" "$DG_LIVE"
    dg_pidfile "$a-t-31" "$(dg_dead_pid)"
  fi
}

# dg_line <id> — the status line for <id>
dg_line() { printf '%s\n' "$DG_OUT" | grep -F -- "$1" | head -1; }

test_dg_status_every_state_with_local_pids() {
  dg_setup
  local a=example-owner_project-a l rc=0
  dg_status_fixture 1
  dg_run status
  assert_eq "$DG_RC" "0" "AC6: status exits 0 (stderr: $DG_ERR)" || rc=1
  l=$(dg_line "$DG_ID_MS")
  assert_contains "$l" "running pid $DG_LIVE" "AC6: live pid" || rc=1
  assert_contains "$l" "1/2" "AC6: closed/total = 1/2 (PR 103 not counted)" || rc=1
  assert_contains "$l" "$DG_SPEC_MS" "AC6: line shows the spec" || rc=1
  assert_contains "$l" "host-a" "AC6: line shows the host" || rc=1
  l=$(dg_line "$a-t-31"); assert_contains "$l" "between cycles" "AC6: dead pid" || rc=1
  assert_contains "$l" "0/1" "AC6: 0/1" || rc=1
  l=$(dg_line "$a-t-32"); assert_contains "$l" "held" "AC6: goal-held" || rc=1
  l=$(dg_line "$a-t-33"); assert_contains "$l" "waiting on JP" "AC6: goal-waiting-jp" || rc=1
  l=$(dg_line "$a-t-34"); assert_contains "$l" "stopped" "AC6: closed + goal-stopped" || rc=1
  assert_contains "$l" "1/1" "AC6: 1/1" || rc=1
  l=$(dg_line "$a-t-35"); assert_contains "$l" "delivered" "AC6: closed without goal-stopped" || rc=1
  assert_eq "$(dg_line "$a-t-36")" "" "AC6: delivered > 7 days ago is not listed" || rc=1
  l=$(dg_line "$a-t-37"); assert_contains "$l" "active on host-b" "SA: active goal pinned elsewhere" || rc=1
  assert_eq "$(printf '%s\n' "$DG_OUT" | grep -c .)" "7" "AC6: one line per goal (7 listed)" || rc=1
  dg_teardown; return $rc
}

test_dg_status_with_empty_pipe_still_lists_registry_goals() {
  dg_setup
  local a=example-owner_project-a l rc=0
  dg_status_fixture 0                                   # no pid files, empty $PIPE
  dg_run status
  assert_eq "$DG_RC" "0" "AC6: exits 0 (stderr: $DG_ERR)" || rc=1
  assert_contains "$(dg_line "$DG_ID_MS")" "between cycles" "AC6: active, no pid file → between cycles" || rc=1
  assert_not_contains "$DG_OUT" "running" "AC6: nothing is running with an empty PIPE" || rc=1
  assert_contains "$(dg_line "$a-t-32")" "held" "AC6: held from the registry" || rc=1
  assert_contains "$(dg_line "$a-t-33")" "waiting on JP" "AC6: waiting from the registry" || rc=1
  assert_contains "$(dg_line "$a-t-34")" "stopped" "AC6: stopped from the registry" || rc=1
  assert_contains "$(dg_line "$a-t-35")" "delivered" "AC6: delivered from the registry" || rc=1
  assert_eq "$(dg_goal_files)" "0" "AC6: status writes no cache files" || rc=1
  dg_teardown; return $rc
}

test_dg_status_single_goal_and_no_goals() {
  dg_setup
  local rc=0
  dg_run status
  assert_eq "$DG_RC" "0" "AC6: status with no goals exits 0" \
    && assert_contains "$DG_OUT" "no goals" "SA: prints 'no goals'" || rc=1
  dg_status_fixture 0
  dg_run status "example-owner/project-a#32"
  assert_eq "$DG_RC" "0" "AC6: status <goal> exits 0 (stderr: $DG_ERR)" \
    && assert_eq "$(printf '%s\n' "$DG_OUT" | grep -c .)" "1" "AC6: exactly one line" \
    && assert_contains "$DG_OUT" "example-owner_project-a-t-32" "AC6: it is that goal" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC7: stop ----------------------------------

test_dg_stop_on_pinned_host_kills_tree_labels_and_closes() {
  dg_setup
  local f rc=0
  DG_GOAL_ID=$DG_ID_T7; dg_goal 501 "$DG_SPEC_T7" host-a active
  dg_live_tree; dg_pidfile "$DG_ID_T7" "$DG_P"
  assert_ne "$DG_C" "" "AC7 setup: live child" || { dg_teardown; return 1; }
  dg_run stop "$DG_SPEC_T7"
  assert_eq "$DG_RC" "0" "AC7: stop exits 0 (stderr: $DG_ERR)" || rc=1
  dg_wait_dead "$DG_P" || { fail "AC7: wrapper pid $DG_P still alive"; rc=1; }
  dg_wait_dead "$DG_C" || { fail "AC7: child pid $DG_C still alive"; rc=1; }
  assert_file_exists "$DG_PIPE/goal-$DG_ID_T7.stopped" "AC7: .stopped written" || rc=1
  f="$DG_ST/issues/$DG_REG/501.json"
  dg_has_label "$f" goal-stopped || { fail "AC7: registry issue lacks goal-stopped"; rc=1; }
  assert_eq "$(jq -r .state "$f")" "closed" "AC7: registry issue closed" || rc=1
  assert_contains "$(jq -r '.[].body' "$DG_ST/comments/$DG_REG-501.json" 2>/dev/null)" "**[deliver] NOTE** stopped by host-a" \
    "AC7: stop comment" || rc=1
  dg_teardown; return $rc
}

test_dg_stop_is_idempotent() {
  dg_setup
  local rc=0
  DG_GOAL_ID=$DG_ID_T7; dg_goal 501 "$DG_SPEC_T7" host-a active
  dg_run stop "$DG_ID_T7"; assert_eq "$DG_RC" "0" "AC7: first stop (by id) exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(jq -r .state "$DG_ST/issues/$DG_REG/501.json")" "closed" "AC7: closed after first stop" || rc=1
  dg_run stop "$DG_ID_T7"; assert_eq "$DG_RC" "0" "AC7: second stop exits 0 (stderr: $DG_ERR)" || rc=1
  assert_eq "$(jq 'length' "$DG_ST/comments/$DG_REG-501.json")" "1" "SA: a repeated stop posts no duplicate comment" || rc=1
  dg_teardown; return $rc
}

test_dg_stop_on_other_host_only_labels_and_closes() {
  dg_setup
  local f rc=0
  DG_GOAL_ID=$DG_ID_T7; dg_goal 501 "$DG_SPEC_T7" host-b active      # pinned elsewhere; we are Host-A
  dg_live_tree; dg_pidfile "$DG_ID_T7" "$DG_P"                       # a local pid that must NOT be touched
  dg_run stop "$DG_SPEC_T7"
  assert_eq "$DG_RC" "0" "AC7: stop on a non-pinned host exits 0 (stderr: $DG_ERR)" || rc=1
  f="$DG_ST/issues/$DG_REG/501.json"
  dg_has_label "$f" goal-stopped || { fail "AC7: labelled goal-stopped"; rc=1; }
  assert_eq "$(jq -r .state "$f")" "closed" "AC7: closed" || rc=1
  dg_alive "$DG_P" || { fail "AC7: non-pinned host must not kill the pid"; rc=1; }
  assert_file_absent "$DG_PIPE/goal-$DG_ID_T7.stopped" "AC7: non-pinned host writes no .stopped" || rc=1
  dg_teardown; return $rc
}

test_dg_stop_unknown_goal_fails() {
  dg_setup
  local rc=0
  dg_run stop "example-owner/project-a#7"
  assert_eq "$DG_RC" "1" "SA: stop of an unregistered goal exits 1" \
    && assert_contains "$(dg_lc "$DG_ERR")" "not found" "SA: 'not found' on stderr" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC8: resume --------------------------------

dg_touch_local() {  # dg_touch_local <id> — every local state file resume must clear
  local s; for s in stopped held restarts np snap; do echo 1 > "$DG_PIPE/goal-$1.$s"; done
}
dg_assert_cleared() {
  local s; for s in stopped held restarts np snap; do assert_file_absent "$DG_PIPE/goal-$1.$s" "AC8: .$s cleared" || return 1; done
}

test_dg_resume_stopped_goal_pinned_here_reopens_and_launches() {
  dg_setup
  local f rc=0
  DG_GOAL_ID=$DG_ID_T7; dg_goal 501 "$DG_SPEC_T7" host-a stopped
  dg_touch_local "$DG_ID_T7"
  dg_run resume "$DG_SPEC_T7"
  assert_eq "$DG_RC" "0" "AC8: resume exits 0 (stderr: $DG_ERR)" || rc=1
  f="$DG_ST/issues/$DG_REG/501.json"
  assert_eq "$(jq -r .state "$f")" "open" "AC8: registry issue reopened" || rc=1
  dg_has_label "$f" goal-stopped && { fail "AC8: goal-stopped label must be removed"; rc=1; }
  dg_assert_cleared "$DG_ID_T7" || rc=1
  dg_wait_claude 1 || { fail "AC8: pinned here → one cycle launched"; rc=1; }
  assert_eq "$(cat "$(dg_last_claude_dir)/cwd" 2>/dev/null)" "$DG_CK_A" "AC8: launched in the repo checkout" || rc=1
  dg_teardown; return $rc
}

test_dg_resume_held_goal_removes_held_label() {
  dg_setup
  local f rc=0
  DG_GOAL_ID=$DG_ID_T7; dg_goal 501 "$DG_SPEC_T7" host-a held
  dg_touch_local "$DG_ID_T7"
  dg_run resume "$DG_ID_T7"
  assert_eq "$DG_RC" "0" "AC8: resume held exits 0 (stderr: $DG_ERR)" || rc=1
  f="$DG_ST/issues/$DG_REG/501.json"
  dg_has_label "$f" goal-held && { fail "AC8: goal-held label must be removed"; rc=1; }
  assert_eq "$(jq -r .state "$f")" "open" "AC8: stays open" || rc=1
  dg_assert_cleared "$DG_ID_T7" || rc=1
  dg_teardown; return $rc
}

test_dg_resume_pinned_elsewhere_without_here_does_not_launch() {
  dg_setup
  local f rc=0
  DG_GOAL_ID=$DG_ID_T7; dg_goal 501 "$DG_SPEC_T7" host-b stopped
  dg_touch_local "$DG_ID_T7"
  dg_run resume "$DG_SPEC_T7"
  assert_eq "$DG_RC" "0" "AC8: exits 0 (stderr: $DG_ERR)" || rc=1
  f="$DG_ST/issues/$DG_REG/501.json"
  assert_eq "$(jq -r .state "$f")" "open" "AC8: reopened" || rc=1
  dg_has_label "$f" goal-stopped && { fail "AC8: goal-stopped removed"; rc=1; }
  assert_eq "$(dg_block "$f" | jq -r .host)" "host-b" "AC8: host unchanged without --here" || rc=1
  dg_assert_cleared "$DG_ID_T7" || rc=1
  sleep 1
  assert_eq "$(dg_claude_count)" "0" "AC8: pinned elsewhere → no launch" || rc=1
  dg_teardown; return $rc
}

test_dg_resume_here_repins_host_and_launches() {
  dg_setup
  local f blk rc=0
  DG_GOAL_ID=$DG_ID_T7; dg_goal 501 "$DG_SPEC_T7" host-b stopped "keep me"
  dg_run resume "$DG_SPEC_T7" --here
  assert_eq "$DG_RC" "0" "AC8: resume --here exits 0 (stderr: $DG_ERR)" || rc=1
  f="$DG_ST/issues/$DG_REG/501.json"
  blk=$(dg_block "$f")
  assert_eq "$(printf '%s' "$blk" | jq -r .host)" "host-a" "AC8: --here rewrites host to this host" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r .id)" "$DG_ID_T7" "AC8: id preserved" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r .spec)" "$DG_SPEC_T7" "AC8: spec preserved" || rc=1
  assert_eq "$(printf '%s' "$blk" | jq -r .instructions)" "keep me" "AC8: instructions preserved" || rc=1
  assert_eq "$(jq -r .body "$f" | head -1)" "Goal: $DG_SPEC_T7" "AC8: body line 1 preserved" || rc=1
  assert_eq "$(jq -r .state "$f")" "open" "AC8: reopened" || rc=1
  dg_wait_claude 1 || { fail "AC8: re-pinned here → launched"; rc=1; }
  assert_file_exists "$DG_PIPE/goal-$DG_ID_T7.json" "SA: missing cache rebuilt from the registry" || rc=1
  assert_eq "$(jq -r .issue "$DG_PIPE/goal-$DG_ID_T7.json" 2>/dev/null)" "501" "SA: rebuilt cache carries the issue number" || rc=1
  dg_teardown; return $rc
}

test_dg_resume_delivered_goal_refused() {
  dg_setup
  local rc=0
  DG_GOAL_ID=$DG_ID_T7; dg_goal 501 "$DG_SPEC_T7" host-a delivered
  dg_run resume "$DG_SPEC_T7"
  assert_eq "$DG_RC" "1" "SA: resume of a delivered goal exits 1" \
    && assert_ne "$DG_ERR" "" "SA: reason on stderr" \
    && assert_eq "$(jq -r .state "$DG_ST/issues/$DG_REG/501.json")" "closed" "SA: stays closed" || rc=1
  dg_teardown; return $rc
}

test_dg_resume_refused_when_tickets_now_overlap_a_live_goal() {
  dg_setup
  local rc=0
  DG_GOAL_ID=$DG_ID_MS; dg_goal 501 "$DG_SPEC_MS" host-a stopped
  dg_run "example-owner/project-a#101"; assert_eq "$DG_RC" "0" "AC8 setup: ticket 101 taken by another goal" || rc=1
  dg_run resume "$DG_SPEC_MS"
  assert_eq "$DG_RC" "1" "SA: resume re-runs the overlap check" \
    && assert_contains "$DG_ERR" "example-owner_project-a-t-101" "SA: names the conflicting goal" \
    && assert_eq "$(jq -r .state "$DG_ST/issues/$DG_REG/501.json")" "closed" "SA: stays closed" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC9: library contract ----------------------

test_dg_goal_parse_valid_specs() {
  dg_setup
  local tab rc=0; tab=$(printf '\t')
  dg_lib "goal_parse example-owner/project-a:milestone:12"
  assert_eq "$DG_RC" "0" "AC9: milestone parse exits 0" && assert_eq "$DG_OUT" "example-owner/project-a${tab}ms${tab}12" "AC9: repo/kind/ref for a milestone number" || rc=1
  dg_lib "goal_parse example-owner/project-a:milestones:all"
  assert_eq "$DG_OUT" "example-owner/project-a${tab}msall${tab}all" "AC9: milestones:all" || rc=1
  dg_lib "goal_parse example-owner/project-a#7"
  assert_eq "$DG_OUT" "example-owner/project-a${tab}t${tab}7" "AC9: ticket" || rc=1
  dg_teardown; return $rc
}

test_dg_goal_parse_malformed_exit_1() {
  dg_setup
  local s rc=0
  for s in "example-owner/project-a:milestone:" "example-owner/project-a:bogus:1" "example-owner/project-a#abc" \
           "example-owner/project-a#12abc" "example-owner/project-a" "example-owner/project-a:milestones:12" "" "just-text"; do
    dg_lib "goal_parse '$s'"
    assert_eq "$DG_RC" "1" "AC9: goal_parse [$s] exits 1" || rc=1
    assert_eq "$DG_OUT" "" "AC9: goal_parse [$s] prints nothing on stdout" || rc=1
  done
  dg_teardown; return $rc
}

test_dg_goal_id_pinned_rule() {
  dg_setup
  local rc=0
  # ticket's own example, numeric milestone → no title lookup involved
  dg_lib "goal_id Benjis-Plants/scheduler:milestone:12"
  assert_eq "$DG_OUT" "Benjis-Plants_scheduler-ms-12" "AC1/AC9: pinned example id" || rc=1
  dg_lib "goal_id example-owner/project-a:milestones:all"; assert_eq "$DG_OUT" "$DG_ID_ALL" "AC9: msall id" || rc=1
  dg_lib "goal_id example-owner/project-a#7"; assert_eq "$DG_OUT" "$DG_ID_T7" "AC9: ticket id" || rc=1
  dg_lib "goal_id 'example-owner/project-a:milestone:$DG_TITLE'"
  assert_eq "$DG_OUT" "$DG_ID_MS" "AC2/AC9: title resolved to its number in the id" || rc=1
  dg_lib "goal_id 'example-owner/project-a:milestone:No such milestone'"
  assert_ne "$DG_RC" "0" "AC2: unknown title is an error" || rc=1
  dg_teardown; return $rc
}

test_dg_goal_scope_issues_only_and_live() {
  dg_setup
  local rc=0
  # a cache that disagrees: must be ignored
  echo '{"v":1,"id":"'"$DG_ID_MS"'","spec":"'"$DG_SPEC_MS"'","scope":["example-owner/project-a#999"],"issue":501}' > "$DG_PIPE/goal-$DG_ID_MS.json"
  dg_lib "goal_scope '$DG_SPEC_MS' | sort"
  assert_eq "$DG_OUT" "$(printf 'example-owner/project-a#101\nexample-owner/project-a#102')" \
    "AC9: milestone scope = open + closed issues, never the PR (103)" || rc=1
  dg_issue example-owner_project-a 104 closed 12; dg_issue example-owner_project-a 105 open 12 pr
  dg_lib "goal_scope '$DG_SPEC_MS' | sort"
  assert_eq "$DG_OUT" "$(printf 'example-owner/project-a#101\nexample-owner/project-a#102\nexample-owner/project-a#104')" \
    "AC9: re-read live on every call (104 closed appears, PR 105 does not)" || rc=1
  dg_lib "goal_scope example-owner/project-a#7"
  assert_eq "$DG_OUT" "example-owner/project-a#7" "AC9: ticket scope is the ticket" || rc=1
  dg_lib "goal_scope example-owner/project-a#103"
  assert_eq "$DG_OUT" "" "AC9: a PR number has an empty scope" || rc=1
  dg_teardown; return $rc
}

test_dg_goal_scope_milestones_all_covers_open_milestones() {
  dg_setup
  local rc=0
  # hand: open milestones 12, 13, 20 → issues 101, 102 (12), 201 (13), none (20); PR 103 excluded
  dg_lib "goal_scope '$DG_SPEC_ALL' | sort"
  assert_eq "$DG_OUT" "$(printf 'example-owner/project-a#101\nexample-owner/project-a#102\nexample-owner/project-a#201')" \
    "AC9: milestones:all = issues of every open milestone" || rc=1
  dg_teardown; return $rc
}

test_dg_goal_registry_list_format() {
  dg_setup
  local a=example-owner_project-a tab want rc=0; tab=$(printf '\t')
  DG_GOAL_ID=$a-t-31; dg_goal 502 "example-owner/project-a#31" host-a active
  DG_GOAL_ID=$a-t-32; dg_goal 503 "example-owner/project-a#32" host-a held
  DG_GOAL_ID=$a-t-33; dg_goal 504 "example-owner/project-a#33" host-a waiting
  DG_GOAL_ID=$a-t-34; dg_goal 505 "example-owner/project-a#34" host-a stopped
  DG_GOAL_ID=$a-t-35; dg_goal 506 "example-owner/project-a#35" host-a delivered
  DG_GOAL_ID=$a-t-36; dg_goal 507 "example-owner/project-a#36" host-a delivered_old     # closed 10 days ago: not listed
  dg_issue $DG_REG 508 open                                                              # an unrelated, unlabelled issue
  dg_lib "goal_registry_list | sort"
  want=$(printf '502\t%s\tactive\n503\t%s\theld\n504\t%s\twaiting_jp\n505\t%s\tstopped\n506\t%s\tdelivered\n' \
    $a-t-31 $a-t-32 $a-t-33 $a-t-34 $a-t-35)
  assert_eq "$DG_RC" "0" "AC9: exits 0 (stderr: $DG_ERR)" && assert_eq "$DG_OUT" "$want" "AC9: <issue>\\t<id>\\t<state> per open / recently closed goal (SA state tokens)" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- AC10 + NFR ---------------------------------

test_dg_goal_agent_default_and_registry_in_config() {
  local out rc=0
  out=$(env -i HOME=/nonexistent-dg PATH="$PATH" bash -c ". '$DG_SKILL/config.sh'; printf '%s|%s' \"\${GOAL_AGENT:-}\" \"\${GOAL_REGISTRY_REPO:-}\"")
  assert_eq "$out" "project-manager|jpmoya/claude-agents" "AC10/SA: config.sh defaults GOAL_AGENT and GOAL_REGISTRY_REPO" || rc=1
  return $rc
}

test_dg_goal_agent_name_comes_from_config_only() {
  DG_EXTRA_CFG='GOAL_AGENT=custom-lead'
  dg_setup
  DG_EXTRA_CFG=""
  local rc=0
  dg_run "$DG_SPEC_T7"
  assert_eq "$DG_RC" "0" "AC10: register exits 0 (stderr: $DG_ERR)" || rc=1
  dg_wait_claude 1 || { fail "launched"; rc=1; }
  assert_eq "$(awk 'p{print;exit} $0=="--agent"{p=1}' "$(dg_last_claude_dir)/argv" 2>/dev/null)" "custom-lead" \
    "ticket: nothing else hard-codes the agent name — --agent follows GOAL_AGENT" || rc=1
  assert_eq "$(grep -c 'project-manager' "$DG_SKILL/deliver.sh" "$DG_SKILL/goal-lib.sh" | awk -F: '{s+=$2} END{print s+0}')" "0" \
    "ticket: no literal agent name in deliver.sh / goal-lib.sh" || rc=1
  dg_teardown; return $rc
}

test_dg_rest_only_no_graphql() {
  dg_setup
  local n rc=0
  dg_run "$DG_SPEC_MS"; assert_eq "$DG_RC" "0" "NFR setup: register (stderr: $DG_ERR)" || rc=1
  dg_run status; dg_run stop "$DG_ID_MS"; dg_run resume "$DG_ID_MS"
  n=$(grep -vc '^api ' "$DG_BIN/gh-calls.log")
  assert_eq "$n" "0" "NFR: every gh call is 'gh api' (no gh issue/pr/repo = GraphQL)" || rc=1
  assert_ne "$(grep -c '^api ' "$DG_BIN/gh-calls.log")" "0" "NFR: and it made REST calls" || rc=1
  n=$(grep -cE 'gh (issue|repo|pr) ' "$DG_SKILL/deliver.sh" "$DG_SKILL/goal-lib.sh" | awk -F: '{s+=$2} END{print s+0}')
  assert_eq "$n" "0" "NFR: no GraphQL gh subcommand in the sources" || rc=1
  dg_teardown; return $rc
}

test_dg_bash32_syntax_and_no_agents_write() {
  dg_setup
  local f hits rc=0
  dg_run "$DG_SPEC_T7"; assert_eq "$DG_RC" "0" "AC10 setup: register (stderr: $DG_ERR)" || rc=1
  for f in deliver.sh goal-lib.sh; do
    bash -n "$DG_SKILL/$f" 2>/dev/null || { fail "AC10: bash -n $f"; rc=1; }
    hits=$(grep -nE 'declare[[:space:]]+-A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)\}' "$DG_SKILL/$f" || true)
    assert_eq "$hits" "" "AC10: $f is bash 3.2 syntax (no assoc arrays / mapfile / case-mod expansions)" || rc=1
    hits=$(grep -n '\.claude/agents' "$DG_SKILL/$f" || true)
    assert_eq "$hits" "" "AC10: $f never references .claude/agents" || rc=1
  done
  assert_file_absent "$DG_HOME/.claude/agents" "AC10: a run creates nothing under .claude/agents" || rc=1
  dg_teardown; return $rc
}

# ---------------------------------------------------------------- registration ------------------------------

for t in \
  test_dg_register_milestone_number test_dg_register_milestones_all test_dg_register_ticket \
  test_dg_register_instructions_survive_json_escaping \
  test_dg_milestone_title_resolves_to_number test_dg_unknown_milestone_title_refused \
  test_dg_refuse_repo_outside_dispatch_repos test_dg_refuse_empty_milestone_ref test_dg_refuse_bogus_kind \
  test_dg_refuse_non_numeric_ticket test_dg_refuse_milestone_with_zero_issues test_dg_refuse_ticket_that_is_a_pr \
  test_dg_refuse_missing_ticket test_dg_refuse_repo_with_empty_milestones_all \
  test_dg_overlap_shared_ticket_refused_naming_conflict test_dg_overlap_disjoint_goal_same_repo_accepted \
  test_dg_overlap_judged_from_registry_with_empty_pipe test_dg_overlap_ticket_goal_then_milestone_containing_it \
  test_dg_overlap_same_goal_twice_refused test_dg_overlap_milestones_all_refused_while_other_goal_open \
  test_dg_overlap_goal_refused_while_milestones_all_open test_dg_overlap_other_repo_unaffected_by_milestones_all \
  test_dg_overlap_held_goal_is_live_closed_goals_are_not \
  test_dg_brief_contents_from_live_state test_dg_brief_follows_live_state_not_cache \
  test_dg_status_every_state_with_local_pids test_dg_status_with_empty_pipe_still_lists_registry_goals \
  test_dg_status_single_goal_and_no_goals \
  test_dg_stop_on_pinned_host_kills_tree_labels_and_closes test_dg_stop_is_idempotent \
  test_dg_stop_on_other_host_only_labels_and_closes test_dg_stop_unknown_goal_fails \
  test_dg_resume_stopped_goal_pinned_here_reopens_and_launches test_dg_resume_held_goal_removes_held_label \
  test_dg_resume_pinned_elsewhere_without_here_does_not_launch test_dg_resume_here_repins_host_and_launches \
  test_dg_resume_delivered_goal_refused test_dg_resume_refused_when_tickets_now_overlap_a_live_goal \
  test_dg_goal_parse_valid_specs test_dg_goal_parse_malformed_exit_1 \
  test_dg_goal_id_pinned_rule test_dg_goal_scope_issues_only_and_live \
  test_dg_goal_scope_milestones_all_covers_open_milestones test_dg_goal_registry_list_format \
  test_dg_goal_agent_default_and_registry_in_config test_dg_goal_agent_name_comes_from_config_only \
  test_dg_rest_only_no_graphql test_dg_bash32_syntax_and_no_agents_write; do
  run_test "$t"
done
