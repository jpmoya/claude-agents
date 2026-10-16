#!/bin/bash
# Goal-bound delivery lead library (#193), sourced by deliver.sh (and supervisor.sh from #195).
# A goal is a registry issue on GitHub (label delivery-goal); $PIPE/goal-<id>.* is only a host-local cache.
# GitHub calls here are REST (`gh api`, writes included) — the GraphQL budget is the one that ran out in #57 —
# except the per-ticket marker read (latest_marker via supervisor.sh, a GraphQL call), once per ticket per sync.
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

# _goal_scope_rows <spec> [id] -> owner/repo#N<TAB>open|closed, one set of live REST calls.
# With the id of an already-registered milestone goal, scope by the number in the id (ms-<n>): the title is only
# resolved at register time, so a milestone renamed at ship does not break resume, brief or the overlap guard.
_goal_scope_rows() {
  local line repo kind ref n ms one
  line=$(goal_parse "$1") || return 1
  IFS=$'\t' read -r repo kind ref <<< "$line"
  case "$kind" in
    ms)
      case "${2:-}" in
        *-ms-[0-9]*) n="${2##*-ms-}"; case "$n" in *[!0-9]*) n="" ;; esac ;;
        *) n="" ;;
      esac
      [ -n "$n" ] || n=$(_goal_ms_number "$repo" "$ref") || return 1
      _goal_ms_rows "$repo" "$n" ;;
    msall)
      ms=$(_goal_get_all "repos/$repo/milestones?state=open&per_page=100") || return 1
      for n in $(printf '%s' "$ms" | jq -r '.[].number'); do _goal_ms_rows "$repo" "$n" || return 1; done ;;
    t)
      # only a 404 is an empty scope; any other failure (rate limit, 5xx, network) must not read as "no tickets"
      one=$(gh api "repos/$repo/issues/$ref" 2>&1) || {
        case "$one" in *"HTTP 404"*|*"Not Found"*|*"HTTP 410"*|*"Gone"*) return 0 ;; *) return 1 ;; esac
      }
      printf '%s' "$one" | jq -r --arg r "$repo" 'select(has("pull_request") | not) | "\($r)#\(.number)\t\(.state)"' ;;
  esac
}

# goal_scope <spec> [id] -> one owner/repo#N per line (issues only, open and closed), read live every call
goal_scope() { local r; r=$(_goal_scope_rows "$@") || return 1; [ -z "$r" ] || printf '%s\n' "$r" | cut -f1; }

# _goal_registry_json [all] -> JSON array of registry goals: open ones plus those closed within GOAL_RECENT_DAYS
# (`all`: every closed one). state: active | held | waiting_jp | stopped | delivered.
# Per-issue mapping shared by _goal_registry_json and register (#292): one issue -> goal object (empty for an unreadable closed one).
_GOAL_ISSUE_JQ='def goal_of: . as $i
          | ([try (($i.body // "") | capture("```json\\n(?<j>[^\\n]*)\\n```") | .j | fromjson) catch null] | .[0]) as $b
          | ([$i.labels[].name]) as $l
          | if $b == null then
              (select($i.state == "open")
               | {issue: $i.number, id: "registry-issue-\($i.number)", spec: "", host: "", instructions: "",
                  state: $i.state, closed_at: $i.closed_at, block: null, st: "unreadable"})
            else
            {issue: $i.number, id: $b.id, spec: $b.spec, host: ($b.host // ""), instructions: ($b.instructions // ""),
             state: $i.state, closed_at: $i.closed_at, block: $b,
             st: (if $i.state == "closed" then (if ($l | index("goal-stopped")) then "stopped" else "delivered" end)
                  elif ($l | index("goal-stopped")) then "stopped"
                  elif ($l | index("goal-held")) then "held"
                  elif ($l | index("goal-waiting-jp")) then "waiting_jp"
                  else "active" end)}
            end;'

# _goal_issue_to_goal — one registry issue JSON on stdin -> its goal JSON on stdout
_goal_issue_to_goal() { jq -c "$_GOAL_ISSUE_JQ goal_of"; }

_goal_registry_json() {
  local open closed cut since=""
  cut=$(jq -nr --argjson d "$GOAL_RECENT_DAYS" '(now - $d * 86400) | strftime("%Y-%m-%dT%H:%M:%SZ")')
  open=$(_goal_get_all "repos/$GOAL_REGISTRY_REPO/issues?labels=delivery-goal&state=open&per_page=100") || return 1
  if [ "${1:-}" = all ]; then cut="0000"; else since="&since=$cut"; fi
  closed=$(_goal_get_all "repos/$GOAL_REGISTRY_REPO/issues?labels=delivery-goal&state=closed&per_page=100$since") || return 1
  jq -nc --argjson a "$open" --argjson b "$closed" --arg cut "$cut" "$_GOAL_ISSUE_JQ"'
    ($a + $b)
    | map(select(has("pull_request") | not)
          | select(any(.labels[]; .name == "delivery-goal"))
          | select(.state == "open" or (.closed_at != null and .closed_at >= $cut)))
    | map(goal_of)'
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

# goal_brief <id> [goal-json] -> the delivery-lead launch prompt, generated from live registry + ticket state (never the cache)
goal_brief() {
  local id="$1" g spec instr repo checkout rows row ref st n owner_repo cm last
  if [ $# -ge 2 ] && [ -n "$2" ]; then g=$2; else g=$(_goal_find "$id") || { echo "goal $id not found in the registry" >&2; return 1; }; fi
  spec=$(printf '%s' "$g" | jq -r .spec); instr=$(printf '%s' "$g" | jq -r .instructions)
  repo=$(goal_parse "$spec" | cut -f1)
  checkout=$(_goal_checkout "$repo") || checkout="(not in DISPATCH_REPOS)"
  rows=$(_goal_scope_rows "$spec" "$id") || { echo "cannot read the scope of $spec" >&2; return 1; }
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

# goal_launch <id> [goal-json] — one detached cycle of $GOAL_AGENT in the repo's checkout; records .pid/.start/.launched-at
goal_launch() {
  local id="$1" g="${2:-}" repo checkout brief
  [ -n "$g" ] || g=$(_goal_find "$id") || { echo "goal $id not found in the registry" >&2; return 1; }
  repo=$(goal_parse "$(printf '%s' "$g" | jq -r .spec)" | cut -f1)
  checkout=$(_goal_checkout "$repo") || { echo "$repo is not in DISPATCH_REPOS" >&2; return 1; }
  brief=$(goal_brief "$id" "$g") || return 1
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

# goal_milestone_approved <owner/repo> <milestone number> (#314) — is this milestone the scope of a registered, live goal
# whose registry issue carries the plain line `Approved-by: JP`? Prints the registry issue URL and returns 0 when so;
# returns 1 when not (no goal / goal without approval / other scope / goal closed); returns 2 when the registry cannot be read
# (fail closed). Refusals (1 with a goal present but unapproved, and 2) emit a `slog` line with repo, milestone and reason.
goal_milestone_approved() {
  local repo="${1:-}" ms="${2:-}" open url rid why
  if [ -z "$repo" ] || [ -z "$ms" ]; then
    slog "goal_milestone_approved: repo=$repo milestone=$ms reason=missing-argument"; return 2
  fi
  open=$(_goal_get_all "repos/$GOAL_REGISTRY_REPO/issues?labels=delivery-goal&state=open&per_page=100") || {
    slog "goal_milestone_approved: repo=$repo milestone=$ms reason=registry-unreadable (fail closed)"; return 2; }
  # open registry issues whose spec covers this milestone: "repo:milestone:<n>" (spec or id ms-<n>) or "repo:milestones:all"
  url=$(printf '%s' "$open" | jq -r --arg repo "$repo" --arg ms "$ms" "$_GOAL_ISSUE_JQ"'
    def covers: .spec == "\($repo):milestone:\($ms)" or .spec == "\($repo):milestones:all"
                or ((.spec | startswith("\($repo):milestone:")) and (.id | endswith("-ms-\($ms)")));
    [.[] | select(has("pull_request") | not) | . as $i | goal_of | select(.st != "unreadable" and covers)
      | {n: .issue, appr: (($i.body // "") | test("(^|\n)Approved-by: JP([^A-Za-z0-9_-]|$)"))}]
    | (map(select(.appr)) | first // null) as $a | (first // null) as $f
    | if $a then "yes\t\($a.n)" elif $f then "no\t\($f.n)" else "none\t" end') || {
    slog "goal_milestone_approved: repo=$repo milestone=$ms reason=registry-unparseable (fail closed)"; return 2; }
  case "$url" in
    yes*) rid="${url#*$'\t'}"; printf 'https://github.com/%s/issues/%s\n' "$GOAL_REGISTRY_REPO" "$rid"
          return 0 ;;
    no*)  why="goal-not-approved (registry issue ${url#*$'\t'} has no 'Approved-by: JP' line)" ;;
    *)    why="no-open-goal-covers-milestone" ;;
  esac
  slog "goal_milestone_approved: repo=$repo milestone=$ms reason=$why"
  return 1
}

# ---- supervisor goal step (#195) ------------------------------------------------------------------------------
# Everything from here down runs from supervisor.sh only: it relies on slog, report_status_async, power_ok, to_epoch,
# file_mtime, latest_marker, terminal_kind and $HOST defined there. REST (`gh api`) for every read of ours, like above.

# _goal_ticket_eval <owner/repo> <issue> -> "<delivered|waiting_jp|active>\t<issue state>\t<latest marker first line>\t<reason>"
# One REST issue read plus latest_marker; exit 1 when either read fails (a failed read is never "delivered").
_goal_ticket_eval() {
  local repo="$1" n="$2" info st labels checkout m first mk tk l2 cls="active" why="-"
  info=$(gh api "repos/$repo/issues/$n" 2>/dev/null) || return 1
  st=$(printf '%s' "$info" | jq -r '(.state // empty) | ascii_upcase') || return 1
  [ -n "$st" ] || return 1
  if [ "$st" = CLOSED ]; then printf 'delivered\tCLOSED\t-\t-\n'; return 0; fi
  labels=$(printf '%s' "$info" | jq -r '[.labels[].name] | join(" ")')
  checkout=$(_goal_checkout "$repo") || return 1
  m=$(latest_marker "$checkout" "$n")
  [ "$m" != "?" ] || return 1
  first=${m%%$'\n'*}; first=${first%$'\r'}
  first=$(printf '%s' "$first" | tr '\t' ' ')
  mk=${first%%\*\*}
  if [[ "$mk" =~ \]\ DEPLOYED\ TO\ STAGING$ ]]; then
    cls=waiting_jp; why="landed on staging, waiting for your promotion"
  elif [[ "$mk" =~ \]\ BLOCKED ]]; then
    l2=$(_goal_get_all "repos/$repo/issues/$n/comments?per_page=100" 2>/dev/null \
      | jq -r --arg f "$first" '[.[] | select((.body | split("\n")[0] | rtrimstr("\r")) == $f)] | last | .body | split("\n")[1] // "" | rtrimstr("\r")' 2>/dev/null) || l2=""
    if [ "$l2" = "Blocked on: needs_jp" ]; then cls=waiting_jp; why="blocked on a decision only you can make"; fi
  else
    tk=$(terminal_kind "$first" "$n" "" "$checkout")
    case "$tk" in
      done) cls=delivered ;;
      gate)
        cls=waiting_jp
        case "$mk" in
          *"MOCKUPS PENDING APPROVAL") why="mockups need your approval" ;;
          *"AWAITING GO") why="the plan needs your go" ;;
          *"EFFORT APPROVAL NEEDED") why="the effort estimate needs your approval" ;;
          *) why="needs your decision" ;;
        esac ;;
    esac
  fi
  if [ "$cls" = active ]; then
    case " $labels " in
      *" agent-proposed "*)
        case " $labels " in
          *" agent-go "*|*" agent-in-progress "*) ;;
          *) cls=waiting_jp; why="not approved yet" ;;
        esac ;;
    esac
  fi
  printf '%s\t%s\t%s\t%s\n' "$cls" "$st" "${first:--}" "$why"
}

# goal_ticket_state <owner/repo> <issue> -> delivered | waiting_jp | active
goal_ticket_state() {
  local r
  r=$(_goal_ticket_eval "$1" "$2") || return 1
  printf '%s\n' "${r%%$'\t'*}"
}

# goal_snapshot — stdin: "<owner/repo#N>\t<issue state>\t<marker first line>" lines; prints the sha of the sorted lines
goal_snapshot() {
  sort | { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1
}

# REST writes on the registry issue (same calls as deliver.sh; separate names so deliver.sh's own helpers stay untouched)
_goal_ensure_label() { gh api -X POST "repos/$GOAL_REGISTRY_REPO/labels" -f "name=$1" >/dev/null 2>&1 || true; }
_goal_label_add() { _goal_ensure_label "$2"; gh api -X POST "repos/$GOAL_REGISTRY_REPO/issues/$1/labels" -f "labels[]=$2" >/dev/null 2>&1; }
_goal_label_del() { gh api -X DELETE "repos/$GOAL_REGISTRY_REPO/issues/$1/labels/$2" >/dev/null 2>&1 || true; }
_goal_note() { gh api -X POST "repos/$GOAL_REGISTRY_REPO/issues/$1/comments" -f "body=$2" >/dev/null 2>&1; }
_goal_close() { gh api -X PATCH "repos/$GOAL_REGISTRY_REPO/issues/$1" -f "state=closed" >/dev/null 2>&1; }

# Goal step (#195) — keep the delivery lead of every goal pinned to this host alive until its scope is delivered:
#     registry sync (throttled), cache mirror, completion / waiting-on-JP / no-progress parking, relaunch pacing.
#     goal_step is called from supervisor.sh step 3d. Goal pids are coordinators: not counted in count_running, gated by power_ok, MEM_FLOOR_MB and MAX_GOALS only, and a
#     goal launch never sets the orchestrator `launched` flag. Registry state lives on GitHub; $PIPE/goal-<id>.* is a cache.
GOAL_ERR_PUSHED=0
GOAL_CAN_LAUNCH=1
GOAL_SYNC_DUE=0
GOAL_RELEASE=""

goal_release() {  # commit SHA of the checkout (release tag for captured errors)
  [ -n "$GOAL_RELEASE" ] || GOAL_RELEASE=$(git -C "$HERE" rev-parse HEAD 2>/dev/null | cut -c1-7)
  printf '%s' "${GOAL_RELEASE:-unknown}"
}
goal_err() {  # slog with the [goal] route, release + host; one status push per tick. Never put tokens or brief text in $*.
  slog "[goal] error: $* (release=$(goal_release) host=$HOST)"
  if [ "$GOAL_ERR_PUSHED" -eq 0 ]; then GOAL_ERR_PUSHED=1; report_status_async "goal-error"; fi
}

goal_mirror() {  # <id> <state> [<scope_total> <scope_delivered>] — the cache fields the status page (#197) reads
  local f="$PIPE/goal-$1.json" ts
  [ -f "$f" ] || return 0
  ts=$(date -u +%FT%TZ)
  if [ -n "${3:-}" ]; then
    jq -c --arg s "$2" --arg t "$ts" --argjson n "$3" --argjson d "$4" \
      '. + {state:$s, last_cycle_at:$t, scope_total:$n, scope_delivered:$d}' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  else
    jq -c --arg s "$2" --arg t "$ts" '. + {state:$s, last_cycle_at:$t}' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  fi
  rm -f "$f.tmp"
  return 0
}

goal_sync() {  # registry -> local: rebuild missing caches, propagate stop/close; goals pinned to another host are ignored
  local reg g id n st host block f cur
  reg=$(_goal_registry_json) || { goal_err "cannot read the goal registry"; return 0; }
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    host=$(printf '%s' "$g" | jq -r '(.host // "") | ascii_downcase')
    id=$(printf '%s' "$g" | jq -r '.id // empty'); n=$(printf '%s' "$g" | jq -r '.issue // empty'); st=$(printf '%s' "$g" | jq -r '.st')
    if [ -n "$id" ] && [ -n "$host" ] && [ "$host" != "$GOAL_THIS_HOST" ] \
       && [ "$(jq -r '(.host // "") | ascii_downcase' "$PIPE/goal-$id.json" 2>/dev/null)" = "$GOAL_THIS_HOST" ]; then
      goal_kill "$id"   # re-pinned to another host: drop the lead and the cache so only the new owner runs it
      rm -f "$PIPE"/goal-"$id".*
      slog "[goal] $id re-pinned to $host — local lead and cache dropped"
      continue
    fi
    [ "$host" = "$GOAL_THIS_HOST" ] || continue
    [ -n "$id" ] && [ -n "$n" ] || continue
    case "$st" in
      stopped|delivered)
        ls "$PIPE"/goal-"$id".* >/dev/null 2>&1 || continue
        # act only on the issue the cache tracks: an old closed issue sharing the id must not kill a re-registered goal
        [ "$(jq -r '.issue // empty' "$PIPE/goal-$id.json" 2>/dev/null)" = "$n" ] || continue
        goal_kill "$id"
        echo registry > "$PIPE/goal-$id.stopped"   # confirmed by the registry
        slog "[goal] $id closed in the registry ($st) — stopped" ;;
      unreadable) ;;
      *)
        f="$PIPE/goal-$id.json"
        cur=$(jq -r '.issue // empty' "$f" 2>/dev/null)
        if [ "$cur" != "$n" ]; then
          block=$(printf '%s' "$g" | jq -c '.block')
          printf '%s' "$block" | jq -c --argjson n "$n" '. + {issue: $n}' > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" \
            || goal_err "cannot write the cache of $id"
          rm -f "$f.tmp"
        fi
        if [ "$st" = held ]; then touch "$PIPE/goal-$id.held"; else
          rm -f "$PIPE/goal-$id.held"
          # lift .stopped only when the registry itself confirmed that stop (resumed elsewhere); an unconfirmed local stop
          # whose registry write failed stays in force
          [ "$(cat "$PIPE/goal-$id.stopped" 2>/dev/null)" = registry ] && rm -f "$PIPE/goal-$id.stopped"
        fi
        if [ "$st" = waiting_jp ] && [ ! -f "$PIPE/goal-$id.waiting" ]; then echo "(from registry)" > "$PIPE/goal-$id.waiting"; fi ;;
    esac
  done <<< "$(printf '%s' "$reg" | jq -c '.[]')"
}

# goal_eval <id> <spec> — live scope + ticket classes into GE_* (current shell); exit 1 on any failed read
goal_eval() {
  local rows ref st repo n r cls istate marker why
  GE_TOTAL=0; GE_DELIVERED=0; GE_ACTIVE=0; GE_WAITING=0; GE_SNAP=""; GE_REFS=""
  rows=$(_goal_scope_rows "$2" "$1") || return 1
  while IFS=$'\t' read -r ref st; do
    [ -n "$ref" ] || continue
    if [ "$st" = closed ]; then
      cls=delivered; istate=CLOSED; marker="-"; why="-"
    else
      repo=${ref%%#*}; n=${ref##*#}
      r=$(_goal_ticket_eval "$repo" "$n") || return 1
      IFS=$'\t' read -r cls istate marker why <<< "$r"
    fi
    GE_TOTAL=$((GE_TOTAL + 1))
    case "$cls" in
      delivered) GE_DELIVERED=$((GE_DELIVERED + 1)) ;;
      waiting_jp) GE_WAITING=$((GE_WAITING + 1)) ;;
      *) GE_ACTIVE=$((GE_ACTIVE + 1)) ;;
    esac
    GE_SNAP="$GE_SNAP$ref	$istate	$marker
"
    GE_REFS="$GE_REFS$ref	$cls	$why
"
  done <<< "$rows"
  return 0
}

goal_card() {  # <title> <status> <what's up> <needed> — the standard status card (CLAUDE.md "Status answers"), composed here, never parsed
  printf '%s\nSTATUS:    %s\nWHAT'"'"'S UP: %s\nNEEDED FROM YOU: %s\nTECHNICAL PROBLEM: No\nSELF-HEAL TICKETS: None\n\n' "$1" "$2" "$3" "$4"
}

goal_cards() {  # <delivered|waiting_jp> — one card block per ticket of that class (max 10)
  local want=$1 ref cls why repo n title k=0 total=0
  while IFS=$'\t' read -r ref cls why; do
    [ "$cls" = "$want" ] || continue
    total=$((total + 1))
    [ "$k" -lt 10 ] || continue
    k=$((k + 1))
    repo=${ref%%#*}; n=${ref##*#}
    title=$(gh api "repos/$repo/issues/$n" --jq .title 2>/dev/null | head -1)
    [ -n "$title" ] || title="ticket"
    if [ "$want" = delivered ]; then
      goal_card "$title ($repo #$n)" "DONE" "Delivered." "Nothing"
    else
      goal_card "$title ($repo #$n)" "WAITING ON YOU" "Paused until you act." "- $why"
    fi
  done <<< "$GE_REFS"
  [ "$total" -le 10 ] || printf '(and %s more)\n' "$((total - 10))"
}

goal_deliver() {  # <id> <issue> <spec>
  local id=$1 issue=$2 spec=$3 body
  if [ ! -f "$PIPE/goal-$id.carded" ]; then
    body="**[deliver] NOTE** card

Goal $spec: everything in scope is delivered ($GE_DELIVERED of $GE_TOTAL tickets).

$(goal_cards delivered)"
    _goal_note "$issue" "$body" || { goal_err "cannot post the delivery card of $id"; return 0; }
    touch "$PIPE/goal-$id.carded"
  fi
  _goal_close "$issue" || { goal_err "cannot close the registry issue of $id"; return 0; }
  rm -f "$PIPE/goal-$id".*
  slog "[goal] $id delivered — registry issue #$issue closed ($GE_DELIVERED/$GE_TOTAL)"
  report_status_async "goal"
}

goal_waiting() {  # <id> <issue> <spec>
  local id=$1 issue=$2 spec=$3 set prev body
  set=$(printf '%s' "$GE_REFS" | awk -F'\t' '$2 == "waiting_jp" {print $1 " " $3}' | sort)
  prev=$(cat "$PIPE/goal-$id.waiting" 2>/dev/null)
  [ "$prev" = "$set" ] && return 0
  body="**[deliver] NOTE** card

Goal $spec is waiting on you; nothing is running until you act.

$(goal_cards waiting_jp)"
  _goal_label_add "$issue" goal-waiting-jp || { goal_err "cannot label the registry issue of $id"; return 0; }
  _goal_note "$issue" "$body" || { goal_err "cannot post the waiting card of $id"; return 0; }
  printf '%s' "$set" > "$PIPE/goal-$id.waiting"
  slog "[goal] $id waiting on JP ($GE_WAITING ticket(s))"
}

goal_park() {  # <id> <issue>
  local id=$1 issue=$2
  touch "$PIPE/goal-$id.held"
  _goal_label_add "$issue" goal-held || goal_err "cannot label the registry issue of $id held"
  _goal_note "$issue" "**[deliver] NOTE** held: no progress in $GOAL_MAX_NO_PROGRESS cycles" || goal_err "cannot post the held note of $id"
  goal_mirror "$id" held
  slog "[goal] $id held — no progress in $GOAL_MAX_NO_PROGRESS cycles"
  report_status_async "held"
}

goal_tick_one() {  # <id>
  local id=$1 cache="$PIPE/goal-$1.json" spec issue pid alive=0 now la age restarts ec clean=0 run em idx wait_secs new old np
  spec=$(jq -r '.spec // empty' "$cache" 2>/dev/null); issue=$(jq -r '.issue // empty' "$cache" 2>/dev/null)
  [ -n "$spec" ] && [ -n "$issue" ] || return 0
  pid=$(cat "$PIPE/goal-$id.pid" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=1; fi
  if [ -f "$PIPE/goal-$id.stopped" ]; then [ "$alive" -eq 0 ] || goal_kill "$id"; return 0; fi
  if [ -f "$PIPE/goal-$id.held" ]; then goal_mirror "$id" held; return 0; fi

  if [ "$alive" -eq 1 ]; then   # alive: leave it alone; re-evaluate (mirror only) once per sync
    if [ "$GOAL_SYNC_DUE" -eq 1 ]; then
      if goal_eval "$id" "$spec"; then
        if [ "$GE_TOTAL" -gt 0 ] && [ "$GE_ACTIVE" -eq 0 ] && [ "$GE_WAITING" -gt 0 ]; then
          goal_mirror "$id" waiting_jp "$GE_TOTAL" "$GE_DELIVERED"
        else goal_mirror "$id" active "$GE_TOTAL" "$GE_DELIVERED"; fi
      else goal_err "cannot read the scope of $id"; fi
    fi
    return 0
  fi

  # dead: is a relaunch decision due? clean end -> GOAL_CYCLE_SECS after the launch; crash/kill -> BACKOFF[.restarts]
  now=$(date +%s)
  la=$(to_epoch "$(cat "$PIPE/goal-$id.launched-at" 2>/dev/null || cat "$PIPE/goal-$id.start" 2>/dev/null)")
  if [ "${la:-0}" -gt 0 ] 2>/dev/null; then age=$((now - la)); else la=0; age=999999999; fi
  restarts=$(cat "$PIPE/goal-$id.restarts" 2>/dev/null); case "$restarts" in ''|*[!0-9]*) restarts=0 ;; esac
  if [ -f "$PIPE/goal-$id.exit" ]; then
    ec=$(tr -dc '0-9' < "$PIPE/goal-$id.exit"); [ "$ec" = 0 ] && clean=1
  fi
  if [ "$clean" -eq 1 ]; then
    restarts=0; wait_secs=$GOAL_CYCLE_SECS
  else
    run=$age
    if [ -f "$PIPE/goal-$id.exit" ] && [ "$la" -gt 0 ]; then
      em=$(file_mtime "$PIPE/goal-$id.exit")
      if [ -n "$em" ]; then run=$((em - la)); [ "$em" -le "$now" ] && age=$((now - em)); fi   # backoff counts from the crash
    fi
    if [ "$run" -lt "$MIN_RUN_SECS" ]; then   # transient (rate limit, OOM, API error): the longer backoff
      idx=$restarts; [ "$idx" -ge "${#TRANSIENT_BACKOFF[@]}" ] && idx=$(( ${#TRANSIENT_BACKOFF[@]} - 1 ))
      wait_secs=${TRANSIENT_BACKOFF[$idx]}
    else
      idx=$restarts; [ "$idx" -ge "${#BACKOFF[@]}" ] && idx=$(( ${#BACKOFF[@]} - 1 ))
      wait_secs=${BACKOFF[$idx]}
    fi
  fi
  [ "$age" -ge "$wait_secs" ] || return 0
  # evaluating costs one gh read per ticket: a goal parked on JP is looked at once per sync, others whenever they could launch
  if [ "$GOAL_SYNC_DUE" -ne 1 ]; then
    [ "$GOAL_CAN_LAUNCH" -eq 1 ] && [ ! -f "$PIPE/goal-$id.waiting" ] || return 0
  fi
  if ! goal_eval "$id" "$spec"; then goal_err "cannot read the scope of $id"; return 0; fi

  if [ "$GE_TOTAL" -gt 0 ] && [ "$GE_DELIVERED" -eq "$GE_TOTAL" ]; then   # an empty scope never lands here
    goal_deliver "$id" "$issue" "$spec"; return 0
  fi
  if [ "$GE_TOTAL" -gt 0 ] && [ "$GE_ACTIVE" -eq 0 ] && [ "$GE_WAITING" -gt 0 ]; then
    goal_mirror "$id" waiting_jp "$GE_TOTAL" "$GE_DELIVERED"
    goal_waiting "$id" "$issue" "$spec"; return 0
  fi
  goal_mirror "$id" active "$GE_TOTAL" "$GE_DELIVERED"
  if [ -f "$PIPE/goal-$id.waiting" ]; then   # a ticket is active again: resume
    _goal_label_del "$issue" goal-waiting-jp
    rm -f "$PIPE/goal-$id.waiting"
  fi

  [ "$GOAL_CAN_LAUNCH" -eq 1 ] || return 0
  # progress: unchanged snapshot (or an empty scope) = no progress; GOAL_MAX_NO_PROGRESS of them in a row parks the goal
  new=$(printf '%s' "$GE_SNAP" | goal_snapshot)
  old=$(cat "$PIPE/goal-$id.snap" 2>/dev/null)
  np=$(cat "$PIPE/goal-$id.np" 2>/dev/null); case "$np" in ''|*[!0-9]*) np=0 ;; esac
  if [ "$GE_TOTAL" -eq 0 ] || { [ -n "$old" ] && [ "$new" = "$old" ]; }; then np=$((np + 1)); else np=0; fi
  echo "$np" > "$PIPE/goal-$id.np"; echo "$new" > "$PIPE/goal-$id.snap"
  if [ "$np" -ge "$GOAL_MAX_NO_PROGRESS" ]; then goal_park "$id" "$issue"; return 0; fi

  [ -f "$PIPE/goal-$id.stopped" ] && return 0   # a stop that landed during the scope reads
  if goal_launch "$id" >/dev/null 2>&1; then
    echo "$((restarts + 1 - clean))" > "$PIPE/goal-$id.restarts"
    slog "[goal] $id launched pid=$(cat "$PIPE/goal-$id.pid" 2>/dev/null) restarts=$(cat "$PIPE/goal-$id.restarts") np=$np mem=$(mem_available_mb)MB"
    GOAL_CAN_LAUNCH=0   # one launch per tick
  else
    goal_err "launch of $id failed"
  fi
}

goal_step() {
  local last now f id h live=0
  GOAL_THIS_HOST=$(pipeline_host)
  now=$(date +%s)
  last=$(cat "$PIPE/goal-sync.last" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -ge "$GOAL_SYNC_SECS" ]; then
    GOAL_SYNC_DUE=1
    echo "$now" > "$PIPE/goal-sync.last"
    goal_sync
  fi
  GOAL_OWNED=""
  for f in "$PIPE"/goal-*.json; do
    [ -e "$f" ] || break
    id=$(basename "$f" .json); id=${id#goal-}
    h=$(jq -r '(.host // "") | ascii_downcase' "$f" 2>/dev/null)
    [ "$h" = "$GOAL_THIS_HOST" ] || continue
    GOAL_OWNED="$GOAL_OWNED $id"
    [ -f "$PIPE/goal-$id.stopped" ] && continue
    if kill -0 "$(cat "$PIPE/goal-$id.pid" 2>/dev/null)" 2>/dev/null; then live=$((live + 1)); fi
  done
  GOAL_CAN_LAUNCH=1
  power_ok || GOAL_CAN_LAUNCH=0
  [ "$(mem_available_mb)" -ge "$MEM_FLOOR_MB" ] 2>/dev/null || GOAL_CAN_LAUNCH=0
  [ "$live" -lt "$MAX_GOALS" ] || GOAL_CAN_LAUNCH=0
  for id in $GOAL_OWNED; do goal_tick_one "$id"; done
}
