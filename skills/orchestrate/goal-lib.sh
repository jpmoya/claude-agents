#!/bin/bash
# Goal-bound delivery lead library (#193), sourced by deliver.sh (and supervisor.sh from #195).
# A goal is a registry issue on GitHub (label delivery-goal); $PIPE/goal-<id>.* is only a host-local cache.
# Every GitHub call here is REST (`gh api`, writes included) — the GraphQL budget is the one that ran out in #57.
# Needs config.sh + pipeline-lib.sh (pipeline_host, SETSID) sourced first; bash 3.2 compatible.

_GOAL_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GOAL_REGISTRY_REPO="${GOAL_REGISTRY_REPO:-jpmoya/claude-agents}"
GOAL_RECENT_DAYS=7

# goal_parse <spec> -> "repo<TAB>kind<TAB>ref" (kind: ms | msall | t); exit 1 when malformed
goal_parse() {
  local spec="${1:-}" re='^([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)(.*)$' repo rest ref
  if ! [[ "$spec" =~ $re ]]; then echo "malformed goal '$spec' (want owner/repo:milestone:<n|title>, owner/repo:milestones:all or owner/repo#N)" >&2; return 1; fi
  repo="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
  case "$rest" in
    '#'*)
      ref="${rest#\#}"
      case "$ref" in ''|*[!0-9]*) echo "malformed goal '$spec': ticket number must be digits" >&2; return 1 ;; esac
      printf '%s\tt\t%s\n' "$repo" "$ref" ;;
    ':milestones:all') printf '%s\tmsall\tall\n' "$repo" ;;
    ':milestone:'*)
      ref="${rest#:milestone:}"
      [ -n "$ref" ] || { echo "malformed goal '$spec': empty milestone" >&2; return 1; }
      printf '%s\tms\t%s\n' "$repo" "$ref" ;;
    *) echo "malformed goal '$spec'" >&2; return 1 ;;
  esac
}

# _goal_get_all <rest path> -> one JSON array, all pages (no --jq: it runs per page)
_goal_get_all() {
  local raw
  raw=$(gh api --paginate "$1" 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -s 'add // []'
}

# _goal_ms_number <repo> <number|exact title> -> milestone number
_goal_ms_number() {
  local all n
  case "$2" in ''|*[!0-9]*) ;; *) printf '%s\n' "$2"; return 0 ;; esac
  all=$(_goal_get_all "repos/$1/milestones?state=all&per_page=100") || { echo "cannot list milestones of $1" >&2; return 1; }
  n=$(printf '%s' "$all" | jq -r --arg t "$2" '[.[] | select(.title == $t) | .number] | if length == 1 then (.[0] | tostring) else empty end')
  [ -n "$n" ] || { echo "no single milestone titled '$2' in $1" >&2; return 1; }
  printf '%s\n' "$n"
}

# goal_id <spec> -> <owner>_<repo>-<kind>-<ref>, chars outside [A-Za-z0-9._-] replaced by _
goal_id() {
  local line repo kind ref
  line=$(goal_parse "$1") || return 1
  IFS=$'\t' read -r repo kind ref <<< "$line"
  [ "$kind" = ms ] && { ref=$(_goal_ms_number "$repo" "$ref") || return 1; }
  printf '%s-%s-%s\n' "$repo" "$kind" "$ref" | sed 's/[^A-Za-z0-9._-]/_/g'
}

_goal_ms_rows() {  # <repo> <milestone number> -> owner/repo#N<TAB>state, issues only
  local all
  all=$(_goal_get_all "repos/$1/issues?milestone=$2&state=all&per_page=100") || return 1
  printf '%s' "$all" | jq -r --arg r "$1" '.[] | select(has("pull_request") | not) | "\($r)#\(.number)\t\(.state)"'
}

# _goal_scope_rows <spec> -> owner/repo#N<TAB>open|closed, one set of live REST calls
_goal_scope_rows() {
  local line repo kind ref n ms one
  line=$(goal_parse "$1") || return 1
  IFS=$'\t' read -r repo kind ref <<< "$line"
  case "$kind" in
    ms) n=$(_goal_ms_number "$repo" "$ref") || return 1; _goal_ms_rows "$repo" "$n" ;;
    msall)
      ms=$(_goal_get_all "repos/$repo/milestones?state=open&per_page=100") || return 1
      for n in $(printf '%s' "$ms" | jq -r '.[].number'); do _goal_ms_rows "$repo" "$n" || return 1; done ;;
    t)
      # only a 404 is an empty scope; any other failure (rate limit, 5xx, network) must not read as "no tickets"
      one=$(gh api "repos/$repo/issues/$ref" 2>&1) || {
        case "$one" in *"HTTP 404"*|*"Not Found"*) return 0 ;; *) return 1 ;; esac
      }
      printf '%s' "$one" | jq -r --arg r "$repo" 'select(has("pull_request") | not) | "\($r)#\(.number)\t\(.state)"' ;;
  esac
}

# goal_scope <spec> -> one owner/repo#N per line (issues only, open and closed), read live every call
goal_scope() { _goal_scope_rows "$1" | cut -f1; }

# _goal_registry_json [all] -> JSON array of registry goals: open ones plus those closed within GOAL_RECENT_DAYS
# (`all`: every closed one). state: active | held | waiting_jp | stopped | delivered.
_goal_registry_json() {
  local open closed cut since=""
  cut=$(jq -nr --argjson d "$GOAL_RECENT_DAYS" '(now - $d * 86400) | strftime("%Y-%m-%dT%H:%M:%SZ")')
  open=$(_goal_get_all "repos/$GOAL_REGISTRY_REPO/issues?labels=delivery-goal&state=open&per_page=100") || return 1
  if [ "${1:-}" = all ]; then cut="0000"; else since="&since=$cut"; fi
  closed=$(_goal_get_all "repos/$GOAL_REGISTRY_REPO/issues?labels=delivery-goal&state=closed&per_page=100$since") || return 1
  jq -nc --argjson a "$open" --argjson b "$closed" --arg cut "$cut" '
    ($a + $b)
    | map(select(has("pull_request") | not)
          | select(any(.labels[]; .name == "delivery-goal"))
          | select(.state == "open" or (.closed_at != null and .closed_at >= $cut)))
    | map(. as $i
          | (try (($i.body // "") | capture("```json\\n(?<j>[^\\n]*)\\n```") | .j | fromjson) catch null) as $b
          | select($b != null)
          | ([$i.labels[].name]) as $l
          | {issue: $i.number, id: $b.id, spec: $b.spec, host: ($b.host // ""), instructions: ($b.instructions // ""),
             state: $i.state, closed_at: $i.closed_at, block: $b,
             st: (if $i.state == "closed" then (if ($l | index("goal-stopped")) then "stopped" else "delivered" end)
                  elif ($l | index("goal-stopped")) then "stopped"
                  elif ($l | index("goal-held")) then "held"
                  elif ($l | index("goal-waiting-jp")) then "waiting_jp"
                  else "active" end)})'
}

# goal_registry_list -> <registry issue number>\t<id>\t<state>
goal_registry_list() {
  local j
  j=$(_goal_registry_json) || return 1
  printf '%s' "$j" | jq -r '.[] | "\(.issue)\t\(.id)\t\(.st)"'
}

# _goal_find <id> -> one registry goal JSON: the open issue with that id, else the newest closed one; exit 1 if none
_goal_find() {
  local j g
  j=$(_goal_registry_json all) || return 1
  g=$(printf '%s' "$j" | jq -c --arg id "$1" '[.[] | select(.id == $id)] | ((map(select(.state == "open")) | first) // (sort_by(.issue) | last) // empty)')
  [ -n "$g" ] || return 1
  printf '%s\n' "$g"
}

# _goal_resolve <spec|id> -> id
_goal_resolve() {
  if goal_parse "$1" >/dev/null 2>&1; then goal_id "$1"; else printf '%s\n' "$1"; fi
}

# _goal_checkout <owner/repo> -> the DISPATCH_REPOS checkout path (~ expanded); exit 1 if not dispatched
_goal_checkout() {
  local entry p
  for entry in ${DISPATCH_REPOS[@]+"${DISPATCH_REPOS[@]}"}; do
    if [ "${entry%%:*}" = "$1" ]; then p="${entry#*:}"; printf '%s\n' "${p/#\~/$HOME}"; return 0; fi
  done
  return 1
}

_goal_have_marker_re() { type marker_re >/dev/null 2>&1 || . "$_GOAL_LIB_DIR/../../hooks/pipeline-markers.sh" 2>/dev/null || . "$HOME/.claude/hooks/pipeline-markers.sh"; }

# goal_brief <id> -> the delivery-lead launch prompt, generated from live registry + ticket state (never the cache)
goal_brief() {
  local id="$1" g spec instr repo checkout rows row ref st n owner_repo cm last
  g=$(_goal_find "$id") || { echo "goal $id not found in the registry" >&2; return 1; }
  spec=$(printf '%s' "$g" | jq -r .spec); instr=$(printf '%s' "$g" | jq -r .instructions)
  repo=$(goal_parse "$spec" | cut -f1)
  checkout=$(_goal_checkout "$repo") || checkout="(not in DISPATCH_REPOS)"
  rows=$(_goal_scope_rows "$spec") || { echo "cannot read the scope of $spec" >&2; return 1; }
  _goal_have_marker_re
  printf 'You are the delivery lead for goal %s.\n' "$id"
  printf 'Goal: %s\nGoal id: %s\n' "$spec" "$id"
  printf 'Checkout: %s\n' "$checkout"
  printf 'Instructions: %s\n' "${instr:-(none)}"
  printf 'Your memory (read first, append to it): %s/goals/%s.md\n' "$LOGDIR" "$id"
  printf '\nScope (live from GitHub):\n'
  while IFS=$'\t' read -r ref st; do
    [ -n "$ref" ] || continue
    last="-"
    if [ "$st" = open ]; then
      owner_repo="${ref%%#*}"; n="${ref##*#}"
      cm=$(_goal_get_all "repos/$owner_repo/issues/$n/comments?per_page=100" 2>/dev/null) || cm='[]'
      last=$(printf '%s' "$cm" | jq -r "{comments: .} | $(marker_last_jq)" 2>/dev/null) || last="?"
    fi
    printf '%s  %s  latest marker: %s\n' "$ref" "$st" "$last"
  done <<< "$rows"
  cat <<RULES

Rules:
- Run exactly one cycle, then end the turn. Never sleep, wait or schedule your own wakeup (#109: they die when the turn ends).
- Completion is decided by the supervisor from GitHub state, never by you. Never unload, create or edit launchd/cron/loop schedulers.
- JP-only items (a prod go, spending money, external communications, private-artefact access) park the ticket and are reported, never decided.
- Goals only run on repos listed in DISPATCH_REPOS; never act outside the scope above.
RULES
}

# goal_kill <id> — SIGTERM the wrapper's direct children, then the wrapper (orchestrators the lead started survive)
goal_kill() {
  local pid
  pid=$(cat "$PIPE/goal-$1.pid" 2>/dev/null) || return 0
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  fi
  return 0
}

# goal_launch <id> — one detached cycle of $GOAL_AGENT in the repo's checkout; records .pid/.start/.launched-at
goal_launch() {
  local id="$1" g repo checkout brief
  g=$(_goal_find "$id") || { echo "goal $id not found in the registry" >&2; return 1; }
  repo=$(goal_parse "$(printf '%s' "$g" | jq -r .spec)" | cut -f1)
  checkout=$(_goal_checkout "$repo") || { echo "$repo is not in DISPATCH_REPOS" >&2; return 1; }
  brief=$(goal_brief "$id") || return 1
  mkdir -p "$PIPE" "$LOGDIR/goals"
  rm -f "$PIPE/goal-$id.exit"
  printf '\n===== [%s] LAUNCH goal=%s =====\n' "$(date -u +%FT%TZ)" "$id" >> "$PIPE/goal-$id.log"
  (
    cd "$checkout" || exit 1
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 nohup $SETSID bash -c '
      claude --dangerously-skip-permissions --agent "$1" -p "$2"
      echo $? > "$3"
    ' _ "$GOAL_AGENT" "$brief" "$PIPE/goal-$id.exit" >> "$PIPE/goal-$id.log" 2>&1 9>&- &
    echo $! > "$PIPE/goal-$id.pid"
  ) || return 1
  date -u +%FT%TZ > "$PIPE/goal-$id.start"; date -u +%FT%TZ > "$PIPE/goal-$id.launched-at"
}
