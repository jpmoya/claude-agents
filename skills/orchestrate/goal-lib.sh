#!/bin/bash
# Goal-bound delivery lead library (#193), sourced by deliver.sh (and supervisor.sh from #195).
# A goal is a registry issue on GitHub (label delivery-goal); $PIPE/goal-<id>.* is only a host-local cache.
# GitHub calls here are REST (`gh api`, writes included) — the GraphQL budget is the one that ran out in #57 —
# except the per-ticket marker read (latest_marker via supervisor.sh, REST since #388), once per ticket per sync.
# Needs config.sh + pipeline-lib.sh (pipeline_host, SETSID) sourced first; bash 3.2 compatible.

_GOAL_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GOAL_REGISTRY_REPO="${GOAL_REGISTRY_REPO:-jpmoya/claude-agents}"
GOAL_RECENT_DAYS=7
GOAL_LABEL_COLOR="${GOAL_LABEL_COLOR:-5319e7}"   # same colour in every repo (#319)

# goal_label_name <title> -> the goal label "goal: <short>" (#319). short = title with whitespace collapsed, commas and
# control chars removed, trimmed; over 37 chars it is cut at the last word boundary at or before 37 (hard cut at 37
# when there is no space); trailing punctuation trimmed. Max 43 chars, so " (done)" (7) still fits GitHub's 50.
goal_label_name() {
  local s head
  s=$(printf '%s' "${1:-}" | tr '\t\n\r' '   ' | tr -d '[:cntrl:]' | tr -d ',' | tr -s ' ')
  s="${s# }"; s="${s% }"
  if [ "${#s}" -gt 37 ]; then
    if [ "${s:37:1}" = " " ]; then s="${s:0:37}"
    else
      head="${s:0:37}"
      case "$head" in *" "*) s="${head% *}" ;; *) s="$head" ;; esac
    fi
  fi
  s=$(printf '%s' "$s" | sed -E 's/[[:space:].,;:!?-]+$//')
  [ -n "$s" ] || { echo "cannot build a goal label from title '${1:-}'" >&2; return 1; }
  printf 'goal: %s\n' "$s"
}

_goal_uri() { jq -rn --arg s "$1" '$s | @uri'; }
_goal_is_bi() { case "$1" in */Business-Intelligence) return 0 ;; esac; return 1; }

# goal_parse <spec> -> "repo<TAB>kind<TAB>ref" (kind: ms | msall | t | label); exit 1 when malformed.
# label:<exact label name> is the cross-repo form (#319): repo is "-" (the repos live in the registry v2 block).
goal_parse() {
  local spec="${1:-}" re='^([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)(.*)$' repo rest ref
  case "$spec" in
    label:*)
      ref="${spec#label:}"
      [ -n "$ref" ] || { echo "malformed goal '$spec': empty label name" >&2; return 1; }
      printf -- '-\tlabel\t%s\n' "$ref"; return 0 ;;
  esac
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

# goal_name_for <spec> -> a human-readable name for a milestone / ticket goal ("scheduler: Native 3.4", "scheduler #1345: Title");
# empty (exit 1) when GitHub cannot say. The status page shows it instead of the raw spec.
goal_name_for() {
  local line repo kind ref short t
  line=$(goal_parse "$1" 2>/dev/null) || return 1
  IFS=$'\t' read -r repo kind ref <<< "$line"
  short="${repo#*/}"
  case "$kind" in
    t) t=$(gh api "repos/$repo/issues/$ref" --jq .title 2>/dev/null) || return 1; [ -n "$t" ] || return 1; printf '%s #%s: %s\n' "$short" "$ref" "$t" ;;
    ms) case "$ref" in
          *[!0-9]*) t="$ref" ;;
          *) t=$(gh api "repos/$repo/milestones/$ref" --jq .title 2>/dev/null) || return 1 ;;
        esac
        [ -n "$t" ] || return 1; printf '%s: %s\n' "$short" "$t" ;;
    msall) printf '%s: all milestones\n' "$short" ;;
    *) return 1 ;;
  esac
}

# goal_names_fill <registry json> — $PIPE/goalnames.json {goal id: name} for goals whose block has no title (v1 goals), looked up
# once and kept; at most 8 lookups per sync. Best effort: the status page falls back to the spec.
goal_names_fill() {
  local f="$PIPE/goalnames.json" cur rows id spec name n=0
  cur=$(cat "$f" 2>/dev/null); [ -n "$cur" ] || cur='{}'
  printf '%s' "$cur" | jq -e 'type == "object"' >/dev/null 2>&1 || cur='{}'
  rows=$(printf '%s' "$1" | jq -r --argjson have "$cur" '.[] | select(.spec != "" and ((.block.title? // "") == "") and ($have[.id] == null)) | "\(.id)\t\(.spec)"' 2>/dev/null) || return 0
  while IFS=$'\t' read -r id spec; do
    [ -n "$id" ] || continue
    [ "$n" -lt 8 ] || break
    n=$((n + 1))
    name=$(goal_name_for "$spec") || continue
    cur=$(printf '%s' "$cur" | jq -c --arg id "$id" --arg n "$name" '. + {($id): $n}')
  done <<< "$rows"
  [ "$n" -gt 0 ] || return 0
  mkdir -p "$PIPE" 2>/dev/null
  printf '%s\n' "$cur" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" || rm -f "$f.tmp"
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
  if [ "$kind" = label ]; then printf 'label-%s\n' "$ref" | sed 's/[^A-Za-z0-9._-]/_/g'; return 0; fi
  printf '%s-%s-%s\n' "$repo" "$kind" "$ref" | sed 's/[^A-Za-z0-9._-]/_/g'
}

# _goal_label_issues <repo> <label> [open|all] -> JSON array of the issues (no PRs) carrying the label, all pages (#319).
# REST only: repos/<r>/issues?labels=<label>&state=<open|all>, paginated. No GraphQL, no project scope.
_goal_label_issues() {
  local all
  all=$(_goal_get_all "repos/$1/issues?labels=$(_goal_uri "$2")&state=${3:-all}&per_page=100") || return 1
  printf '%s' "$all" | jq -c '[.[] | select(has("pull_request") | not)]'
}

# _goal_repos <id> [explicit csv] -> the repos of a label goal, one per line: the csv, else the local cache, else the registry block
_goal_repos() {
  local r
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" | tr ',' '\n'; return 0; fi
  r=$(jq -r '(.repos // [])[]' "$PIPE/goal-$1.json" 2>/dev/null)
  if [ -z "$r" ]; then r=$(_goal_find "$1" 2>/dev/null | jq -r '(.block.repos // [])[]' 2>/dev/null); fi
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}

_goal_ms_rows() {  # <repo> <milestone number> -> owner/repo#N<TAB>state, issues only
  local all
  all=$(_goal_get_all "repos/$1/issues?milestone=$2&state=all&per_page=100") || return 1
  printf '%s' "$all" | jq -r --arg r "$1" --argjson l "${GOAL_SCOPE_LABELS:-0}" '.[] | select(has("pull_request") | not) | "\($r)#\(.number)\t\(.state)" + (if $l == 1 then "\t" + ([.labels[].name] | join(",")) else "" end)'
}

# _goal_scope_rows <spec> [id] [repos csv] -> owner/repo#N<TAB>open|closed, one set of live REST calls.
# With the id of an already-registered milestone goal, scope by the number in the id (ms-<n>): the title is only
# resolved at register time, so a milestone renamed at ship does not break resume, brief or the overlap guard.
_goal_scope_rows() {
  local line repo kind ref n ms one repos r js
  line=$(goal_parse "$1") || return 1
  IFS=$'\t' read -r repo kind ref <<< "$line"
  case "$kind" in
    label)
      repos=$(_goal_repos "${2:-}" "${3:-}") || { echo "cannot find the repos of label goal ${2:-$1}" >&2; return 1; }
      for r in $repos; do
        js=$(_goal_label_issues "$r" "$ref" all) || return 1
        printf '%s' "$js" | jq -r --arg r "$r" '.[] | "\($r)#\(.number)\t\(.state)"'
      done ;;
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
      printf '%s' "$one" | jq -r --arg r "$repo" --argjson l "${GOAL_SCOPE_LABELS:-0}" 'select(has("pull_request") | not) | "\($r)#\(.number)\t\(.state)" + (if $l == 1 then "\t" + ([.labels[].name] | join(",")) else "" end)' ;;
  esac
}

# goal_scope <spec> [id] -> one owner/repo#N per line (issues only, open and closed), read live every call
goal_scope() { local r; r=$(_goal_scope_rows "$@") || return 1; [ -z "$r" ] || printf '%s\n' "$r" | cut -f1; }

# _goal_registry_json [all] -> JSON array of registry goals: open ones plus those closed within GOAL_RECENT_DAYS
# (`all`: every closed one). state: queued | active | held | waiting_jp | stopped | delivered.
# Per-issue mapping shared by _goal_registry_json and register (#292): one issue -> goal object (empty for an unreadable closed one).
_GOAL_ISSUE_JQ='def goal_of: . as $i
          | ([try (($i.body // "") | capture("```json\\n(?<j>[^\\n]*)\\n```") | .j | fromjson) catch null] | .[0]) as $b
          | ([$i.labels[].name]) as $l
          | if $b == null then
              (select($i.state == "open")
               | {issue: $i.number, id: "registry-issue-\($i.number)", spec: "", host: "", instructions: "",
                  state: $i.state, closed_at: $i.closed_at, block: null, st: "unreadable"})
            else
            {issue: $i.number, id: $b.id, spec: ($b.spec // (if ($b.label // "") != "" then "label:\($b.label)" else "" end)), host: ($b.host // ""), instructions: ($b.instructions // ""),
             state: $i.state, closed_at: $i.closed_at, block: $b,
             st: (if $i.state == "closed" then (if ($l | index("goal-stopped")) then "stopped" else "delivered" end)
                  elif ($l | index("goal-stopped")) then "stopped"
                  elif ($l | index("goal-held")) then "held"
                  elif ($l | index("goal-waiting-jp")) then "waiting_jp"
                  elif ($l | index("goal-queued")) then "queued"
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
  local entry p c
  for entry in ${DISPATCH_REPOS[@]+"${DISPATCH_REPOS[@]}"}; do
    if [ "${entry%%:*}" = "$1" ]; then p="${entry#*:}"; printf '%s\n' "${p/#\~/$HOME}"; return 0; fi
  done
  # a goal written before a GitHub rename still names the old slug: match through the canonical name
  c=$(repo_canon "$1" 2>/dev/null)
  if [ -n "$c" ] && [ "$c" != "$1" ]; then
    for entry in ${DISPATCH_REPOS[@]+"${DISPATCH_REPOS[@]}"}; do
      if [ "${entry%%:*}" = "$c" ]; then p="${entry#*:}"; printf '%s\n' "${p/#\~/$HOME}"; return 0; fi
    done
  fi
  return 1
}

_goal_have_marker_re() { type marker_re >/dev/null 2>&1 || . "$_GOAL_LIB_DIR/../../hooks/pipeline-markers.sh" 2>/dev/null || . "$HOME/.claude/hooks/pipeline-markers.sh"; }

# _goal_primary_repo <goal json> -> the repo whose checkout hosts the lead (a label goal: the first of its repos)
_goal_primary_repo() {
  local spec line
  spec=$(printf '%s' "$1" | jq -r .spec)
  line=$(goal_parse "$spec") || return 1
  if [ "$(printf '%s' "$line" | cut -f2)" = label ]; then printf '%s' "$1" | jq -r '(.block.repos // [])[0] // empty'
  else printf '%s' "$line" | cut -f1; fi
}

# goal_brief <id> [goal-json] -> the delivery-lead launch prompt, generated from live registry + ticket state (never the cache)
goal_brief() {
  local id="$1" g spec instr repo checkout rows row ref st n owner_repo cm last proj ia
  if [ $# -ge 2 ] && [ -n "$2" ]; then g=$2; else g=$(_goal_find "$id") || { echo "goal $id not found in the registry" >&2; return 1; }; fi
  spec=$(printf '%s' "$g" | jq -r .spec); instr=$(printf '%s' "$g" | jq -r .instructions)
  repo=$(_goal_primary_repo "$g")
  checkout=$(_goal_checkout "$repo") || checkout="(not in DISPATCH_REPOS)"
  rows=$(_goal_scope_rows "$spec" "$id") || { echo "cannot read the scope of $spec" >&2; return 1; }
  _goal_have_marker_re
  printf 'You are the delivery lead for goal %s.\n' "$id"
  printf 'Goal: %s\nGoal id: %s\n' "$spec" "$id"
  printf 'Checkout: %s\n' "$checkout"
  if [ "$(goal_parse "$spec" | cut -f2)" = label ]; then
    printf 'Cross-repo goal: tickets carry the label "%s" in %s\n' "$(printf '%s' "$g" | jq -r '.block.label')" "$(printf '%s' "$g" | jq -r '(.block.repos // []) | join(", ")')"
  fi
  proj=$(printf '%s' "$g" | jq -r '.block.project? // empty | select(type == "object") | "\(.url) (owner \(.owner), number \(.number))"' 2>/dev/null)
  if [ -n "$proj" ]; then
    printf 'GitHub Project: %s\n' "$proj"
    printf '  This goal is bound to that project: read its ticket list from the project items (the project item list of that number and owner), keep their Status current, and never work from or create another project.\n'
  fi
  printf 'Instructions: %s\n' "${instr:-(none)}"
  printf 'Your memory (read first, append to it): %s/goals/%s.md\n' "$LOGDIR" "$id"
  printf '\nScope (live from GitHub):\n'
  while IFS=$'\t' read -r ref st; do
    [ -n "$ref" ] || continue
    last="-"
    if [ "$st" = open ]; then
      owner_repo="${ref%%#*}"; n="${ref##*#}"
      cm=$(_goal_get_all "repos/$owner_repo/issues/$n/comments?per_page=100" 2>/dev/null) || cm='[]'
      ia=$(gh api "repos/$owner_repo/issues/$n" --jq '.user.login // empty' 2>/dev/null </dev/null) || ia=""
      last=$(printf '%s' "$cm" | jq -r --arg ia "$ia" "{author: (if \$ia == \"\" then null else {login: \$ia} end), comments: .} | $(marker_last_jq)" 2>/dev/null) || last="?"
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
  repo=$(_goal_primary_repo "$g")
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
# whose registry block records `go:true` (set by `deliver.sh register`, #410)? Prints the registry issue URL and returns 0 when so;
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
      | {n: .issue, appr: ((.block.go // false) == true)}]
    | (map(select(.appr)) | first // null) as $a | (first // null) as $f
    | if $a then "yes\t\($a.n)" elif $f then "no\t\($f.n)" else "none\t" end') || {
    slog "goal_milestone_approved: repo=$repo milestone=$ms reason=registry-unparseable (fail closed)"; return 2; }
  case "$url" in
    yes*) rid="${url#*$'\t'}"; printf 'https://github.com/%s/issues/%s\n' "$GOAL_REGISTRY_REPO" "$rid"
          return 0 ;;
    no*)  why="goal-not-approved (registry issue ${url#*$'\t'} has no go:true in its block)" ;;
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
  [ "$m" != "?" ] || { goal_err "cannot evaluate $repo#$n: latest_marker read failed"; return 1; }
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
          *"SKIP MOCKUPS") why="mockups skipped by JP" ;;   # #272: not a gate; kept for display
          *"AWAITING GO") why="the plan needs your go" ;;
          *"EFFORT APPROVAL NEEDED") why="the effort estimate needs your approval" ;;
          *) why="needs your decision" ;;
        esac ;;
    esac
  fi
  # #456 (goal-lib/gate-answer-unseen): two gaps in the classifier above, fixed together since the second undoes the first
  # if applied alone. (a) a delivery-lead "Blocked on: needs_jp" BLOCKED is not a routing marker (markers_for
  # delivery-lead only knows DECISION/JP CONFIRMED, hooks/pipeline-markers.sh) so latest_marker drops it; it never
  # reaches $first/$mk above and the ticket keeps reading whatever it was before the lead got stuck, forever.
  # (b) a gate (MOCKUPS PENDING, AWAITING GO, …) or the lead's needs_jp above never looks past itself for JP's answer:
  # once JP posts a plain "approved" / "go" / revision feedback, the gate marker itself never changes (the orchestrator
  # clears it by relaunching the pipeline, which only happens once the goal reads active), so without this check a
  # goal can sit held, re-evaluate every sync, and never unhold even after JP answers (#390, 2026-10-23). One extra
  # comments read, author-checked (an agent-tag comment, "**[...] ...**", never counts, so this cannot loop on the
  # pipeline's own supervisor/claim notes — #427 AC4).
  if [ "$cls" != delivered ]; then
    local author gate_at lead_blocked_at jp_answer_at all_c newest
    author=$(printf '%s' "$info" | jq -r '.user.login // empty')
    all_c=$(_goal_get_all "repos/$repo/issues/$n/comments?per_page=100" 2>/dev/null) || all_c="[]"
    gate_at=""
    [ "$first" != none ] && [ -n "$first" ] && gate_at=$(printf '%s' "$all_c" \
      | jq -r --arg f "$first" '[.[] | select((.body | split("\n")[0] | rtrimstr("\r")) == $f)] | last | .created_at // empty')
    lead_blocked_at=$(printf '%s' "$all_c" \
      | jq -r '[.[] | select((.body | split("\n")[0] | rtrimstr("\r")) == "**[delivery-lead] BLOCKED**")
                     | select((.body | split("\n")[1] // "" | rtrimstr("\r")) == "Blocked on: needs_jp")]
               | last | .created_at // empty')
    jp_answer_at=""
    [ -n "$author" ] && jp_answer_at=$(printf '%s' "$all_c" \
      | jq -r --arg a "$author" '[.[] | select(.user.login == $a) | select((.body | startswith("**[")) | not)]
               | last | .created_at // empty')
    if [ -n "$lead_blocked_at" ] && { [ -z "$gate_at" ] || [[ "$lead_blocked_at" > "$gate_at" ]]; } \
       && { [ -z "$jp_answer_at" ] || [[ "$lead_blocked_at" > "$jp_answer_at" ]]; }; then
      cls=waiting_jp; why="blocked on a decision only you can make"
    fi
    if [ "$cls" = waiting_jp ] && [ -n "$jp_answer_at" ]; then
      newest=$gate_at
      [ -n "$lead_blocked_at" ] && { [ -z "$newest" ] || [[ "$lead_blocked_at" > "$newest" ]]; } && newest=$lead_blocked_at
      if [ -z "$newest" ] || [[ "$jp_answer_at" > "$newest" ]]; then cls=active; why="you answered — the pipeline will re-check"; fi
    fi
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
  # #428: an approved ticket that has not started (no routing marker) and whose "Depends on <ref> for starting work"
  # gate is still open cannot move (same parse as supervisor.sh promote_deferred): waiting, not active.
  if [ "$cls" = active ] && [ "$first" = none ]; then
    local g gr gn gst
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      case "$g" in "#"*) gr="$repo"; gn="${g#\#}" ;; *) gr="${g%#*}"; gn="${g##*#}" ;; esac
      gst=$(gh api "repos/$gr/issues/$gn" --jq '(.state // "") | ascii_upcase' 2>/dev/null) || return 1
      case "$gst" in
        OPEN|REOPENED) cls=waiting_jp; why="waits on $g (start-gate still open)"; break ;;
        CLOSED) ;;
        *) return 1 ;;
      esac
    done < <(printf '%s' "$info" | jq -r '.body // ""' | grep -oE 'Depends on [A-Za-z0-9._/-]*#[0-9]+ for starting work' | sed -E 's/^Depends on ([^ ]+) for starting work$/\1/')
  fi
  printf '%s\t%s\t%s\t%s\n' "$cls" "$st" "${first:--}" "$why"
}

# goal_ticket_state <owner/repo> <issue> -> delivered | waiting_jp | active
goal_ticket_state() {
  local r
  r=$(_goal_ticket_eval "$1" "$2") || return 1
  printf '%s\n' "${r%%$'\t'*}"
}

# goal_snapshot — stdin: "<owner/repo#N>\t<issue state>\t<marker first line>\t<ticket class>" lines (#456: class included so a
# gate-answered/lead-blocked flip from _goal_ticket_eval changes the hash even when the marker itself never moves); prints
# the sha of the sorted lines
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
  pipeline_event error --arg level error --arg route supervisor/goal --arg release "$(goal_release)" --arg message "$*"
  if [ "$GOAL_ERR_PUSHED" -eq 0 ]; then GOAL_ERR_PUSHED=1; report_status_async "goal-error"; fi
}

# ---- cross-repo label goals (#319) ----------------------------------------------------------------------------
# Label lifecycle and go-granting. REST only. Shared by deliver.sh (register) and goal_sync / goal_deliver.

_goal_issue_label_add() { gh api -X POST "repos/$1/issues/$2/labels" -f "labels[]=$3" >/dev/null 2>&1; }
_goal_issue_label_del() { gh api -X DELETE "repos/$1/issues/$2/labels/$(_goal_uri "$3")" >/dev/null 2>&1 || true; }

# goal_body_v2 <block json> <granted date> -> the registry issue body: first line, the one fenced json block (the machine
# source, `granted` list included) and, once go was granted, the human-readable "Go-granted:" record.
goal_body_v2() {
  printf 'Goal: %s\n\n```json\n%s\n```\n' "$(printf '%s' "$1" | jq -r .title)" "$1"
  if [ "$(printf '%s' "$1" | jq -r '(.go // false)')" = true ]; then
    printf '\nGo-granted: %s\n' "$2"
    printf '%s' "$1" | jq -r '(.granted // [])[] | "- " + .'
  fi
}

_goal_patch_body() {  # <registry issue> <body> -> the updated issue JSON
  jq -nc --arg b "$2" '{body:$b}' | gh api -X PATCH "repos/$GOAL_REGISTRY_REPO/issues/$1" --input -
}

# goal_requirements_ok <owner/repo#N> -> 0 when the requirements ticket exists (open or closed) and its body is non-empty
goal_requirements_ok() {
  local ref="${1:-}" repo n body
  case "$ref" in */*#[0-9]*) ;; *) return 1 ;; esac
  repo="${ref%%#*}"; n="${ref##*#}"
  body=$(gh api "repos/$repo/issues/$n" --jq '.body // ""' 2>/dev/null) || return 1
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ]
}

# _goal_grant_rows <include_sentry 0|1> <granted json array> — reads "owner/repo<TAB>n<TAB>state<TAB>labels-csv" lines on stdin
# and prints the new granted array. Open tickets get agent-go (agent-proposed removed) unless Business-Intelligence, source:sentry
# (without include_sentry) or already in the granted list: the grant is applied once per ticket, so an agent-go JP removed later
# is never re-added. Every refusal or failed write logs `repo=<owner/repo> issue=<n> reason=<text>` (no ticket text).
# Exit 1 when a label write failed; that ticket is not recorded (retried next sync).
_goal_grant_rows() {
  local sentry=$1 granted=$2 r n labels st ref rc=0
  while IFS=$'\t' read -r r n st labels; do
    [ -n "$n" ] || continue
    [ "$st" = open ] || continue
    ref="$r#$n"
    if printf '%s' "$granted" | jq -e --arg x "$ref" 'index($x) != null' >/dev/null; then continue; fi
    if _goal_is_bi "$r"; then slog "repo=$r issue=$n reason=Business-Intelligence is never part of a goal, no agent-go"; continue; fi
    case ",$labels," in *",source:sentry,"*) [ "$sentry" = 1 ] || { slog "repo=$r issue=$n reason=source:sentry ticket skipped (goal has no --include-sentry)"; continue; } ;; esac
    case ",$labels," in
      *",agent-go,"*) ;;
      *)
        _goal_issue_label_add "$r" "$n" agent-go || { slog "repo=$r issue=$n reason=agent-go label write failed, retried at the next sync"; rc=1; continue; }
        case ",$labels," in *",agent-proposed,"*) _goal_issue_label_del "$r" "$n" agent-proposed ;; esac ;;
    esac
    granted=$(printf '%s' "$granted" | jq -c --arg x "$ref" '. + [$x]')
  done
  printf '%s\n' "$granted"
  return $rc
}

# _goal_grant_go <label> <include_sentry 0|1> <granted json array> <repo>… -> prints the new granted array (label goals).
# Exit 1 when a read failed or a label write failed.
_goal_grant_go() {
  local label=$1 sentry=$2 granted=$3 r js rows="" rc=0
  shift 3
  for r in "$@"; do
    _goal_is_bi "$r" && continue
    js=$(_goal_label_issues "$r" "$label" open) || return 1
    rows+=$(printf '%s' "$js" | jq -r --arg r "$r" '.[] | "\($r)\t\(.number)\topen\t\([.labels[].name] | join(","))"')$'\n'
  done
  _goal_grant_rows "$sentry" "$granted" <<< "$rows" || rc=1
  return $rc
}

# _goal_grant_scope <spec> <id> <include_sentry 0|1> <granted json array> -> prints the new granted array (milestone / #N / msall
# goals, #410): the open tickets of the goal's scope (_goal_scope_rows) go through the same _goal_grant_rows.
# Exit 1 when the scope or a ticket could not be read, or a label write failed.
_goal_grant_scope() {
  local spec=$1 id=$2 sentry=$3 granted=$4 srows lines="" ref st labels r n rc=0
  srows=$(GOAL_SCOPE_LABELS=1 _goal_scope_rows "$spec" "$id") || return 1   # rows carry the label CSV: no per-ticket GET
  while IFS=$'\t' read -r ref st labels; do
    [ "$st" = open ] || continue
    r="${ref%%#*}"; n="${ref##*#}"
    if printf '%s' "$granted" | jq -e --arg x "$ref" 'index($x) != null' >/dev/null; then continue; fi
    lines+="$r"$'\t'"$n"$'\topen\t'"$labels"$'\n'   # BI / sentry refusals are logged by _goal_grant_rows
  done <<< "$srows"
  _goal_grant_rows "$sentry" "$granted" <<< "$lines" || rc=1
  return $rc
}

# _goal_sync_grant <goal json> — an approved goal (go:true in its block: label, milestone or #N) gives agent-go to in-scope tickets that arrived since
# (any repo of the goal); the registry block and body record each grant.
_goal_sync_grant() {
  local g=$1 block id issue label sentry granted new repos body date
  block=$(printf '%s' "$g" | jq -c '.block // empty'); [ -n "$block" ] || return 0
  [ "$(printf '%s' "$block" | jq -r '(.go // false) == true')" = true ] || return 0
  id=$(printf '%s' "$g" | jq -r .id); issue=$(printf '%s' "$g" | jq -r .issue)
  sentry=0; [ "$(printf '%s' "$block" | jq -r '(.include_sentry // false)')" = true ] && sentry=1
  granted=$(printf '%s' "$block" | jq -c '.granted // []')
  if [ "$(printf '%s' "$block" | jq -r '((.v // 1) == 2) and ((.label // "") != "")')" = true ]; then
    label=$(printf '%s' "$block" | jq -r .label)
    repos=$(printf '%s' "$block" | jq -r '(.repos // [])[]')
    # shellcheck disable=SC2086
    new=$(_goal_grant_go "$label" "$sentry" "$granted" $repos) || { goal_err "cannot grant go on every labelled ticket of $id"; }
  else   # milestone / #N / msall goal (#410): go lives in the block, the scope is read live
    new=$(_goal_grant_scope "$(printf '%s' "$block" | jq -r '.spec // empty')" "$id" "$sentry" "$granted") || { goal_err "cannot grant go on every in-scope ticket of $id"; }
  fi
  [ -n "$new" ] || return 0
  [ "$new" != "$granted" ] || return 0
  block=$(printf '%s' "$block" | jq -c --argjson n "$new" '.granted = $n')
  date=$(printf '%s' "$block" | jq -r '(.granted_at // empty)'); [ -n "$date" ] || date=$(date -u +%F)
  body=$(goal_body_v2 "$block" "$date")
  _goal_patch_body "$issue" "$body" >/dev/null 2>&1 || goal_err "cannot record the go grants of $id on the registry issue"
}

# _goal_label_cleanup <label> <repo>… — close-time lifecycle: strip the label from every remaining OPEN ticket, then rename
# the label to "<label> (done)" (or delete it when a "(done)" label already exists). Idempotent: reads only once done.
# Returns 1 (after goal_err) when any step failed; the caller keeps a retry marker.
_goal_label_cleanup() {
  local label=$1 r js n out rc=0 done_label
  shift
  done_label="$label (done)"
  for r in "$@"; do
    _goal_is_bi "$r" && continue
    if js=$(_goal_label_issues "$r" "$label" open); then
      for n in $(printf '%s' "$js" | jq -r '.[].number'); do
        out=$(gh api -X DELETE "repos/$r/issues/$n/labels/$(_goal_uri "$label")" 2>&1) \
          || case "$out" in *"404"*|*"Not Found"*) ;; *) goal_err "cannot strip the goal label from $r#$n"; rc=1 ;; esac
      done
    else goal_err "cannot list the open tickets of the goal label in $r"; rc=1; continue; fi
    out=$(gh api "repos/$r/labels/$(_goal_uri "$label")" 2>&1) || {
      case "$out" in *"404"*|*"Not Found"*) continue ;; *) goal_err "cannot read the goal label in $r"; rc=1; continue ;; esac
    }
    if gh api "repos/$r/labels/$(_goal_uri "$done_label")" >/dev/null 2>&1; then
      gh api -X DELETE "repos/$r/labels/$(_goal_uri "$label")" >/dev/null 2>&1 || { goal_err "cannot delete the stripped goal label in $r"; rc=1; }
    else
      gh api -X PATCH "repos/$r/labels/$(_goal_uri "$label")" -f "new_name=$done_label" >/dev/null 2>&1 \
        || { goal_err "cannot rename the goal label in $r"; rc=1; }
    fi
  done
  return $rc
}

# goal_label_close <id> <label> <repos csv> — run the close-time lifecycle; a failure leaves $PIPE/goalclean-<id>.json so
# goal_sync retries it (the goal's own files are removed at close).
goal_label_close() {
  local repos
  repos=$(printf '%s' "$3" | tr ',' ' ')
  # shellcheck disable=SC2086
  if _goal_label_cleanup "$2" $repos; then rm -f "$PIPE/goalclean-$1.json"
  else jq -nc --arg l "$2" --arg r "$3" '{label:$l, repos:$r}' > "$PIPE/goalclean-$1.json" 2>/dev/null || goal_err "cannot write the cleanup marker of $1"; fi
}

# _goal_cleanup_retry <registry json> — retry markers left by a failed close; dropped when an active goal reuses the label
_goal_cleanup_retry() {
  local f id label repos
  for f in "$PIPE"/goalclean-*.json; do
    [ -e "$f" ] || break
    id=$(basename "$f" .json); id=${id#goalclean-}
    label=$(jq -r '.label // empty' "$f" 2>/dev/null); repos=$(jq -r '.repos // empty' "$f" 2>/dev/null)
    if [ -z "$label" ] || [ -z "$repos" ]; then rm -f "$f"; continue; fi
    if printf '%s' "$1" | jq -e --arg l "$label" 'any(.[]; (.block.label // "") == $l and (.st == "queued" or .st == "active" or .st == "held" or .st == "waiting_jp"))' >/dev/null; then
      rm -f "$f"; continue
    fi
    goal_label_close "$id" "$label" "$repos"
  done
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
  goal_queue_save "$reg"
  goal_queue_derive "$reg"
  goal_names_fill "$reg"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    host=$(printf '%s' "$g" | jq -r '(.host // "") | ascii_downcase')
    id=$(printf '%s' "$g" | jq -r '.id // empty'); n=$(printf '%s' "$g" | jq -r '.issue // empty'); st=$(printf '%s' "$g" | jq -r '.st')
    block=$(printf '%s' "$g" | jq -c '.block // {}')
    if [ -n "$id" ] && [ -n "$host" ] && [ "$host" != "$GOAL_THIS_HOST" ] \
       && [ "$(jq -r '(.host // "") | ascii_downcase' "$PIPE/goal-$id.json" 2>/dev/null)" = "$GOAL_THIS_HOST" ] \
       && [ "$(jq -r '.issue // empty' "$PIPE/goal-$id.json" 2>/dev/null)" = "$n" ]; then
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
        # a label goal (#319): strip the label from the open tickets and mark it done, before its cache is dropped
        if [ "$(printf '%s' "$block" | jq -r '((.v // 1) == 2) and ((.label // "") != "")')" = true ]; then
          goal_label_close "$id" "$(printf '%s' "$block" | jq -r .label)" "$(printf '%s' "$block" | jq -r '(.repos // []) | join(",")')"
        fi
        # drop the local files (as the re-pin branch does) so the next sync does not match this goal again; resume rebuilds the cache
        rm -f "$PIPE"/goal-"$id".* || goal_err "cannot remove the local files of $id"
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
        # the project recorded in the registry block (goal-project.sh) reaches the cache the status page reads
        if [ -f "$f" ] && [ "$(jq -c '.project // null' "$f" 2>/dev/null)" != "$(printf '%s' "$block" | jq -c '.project // null')" ]; then
          jq -c --argjson p "$(printf '%s' "$block" | jq -c '.project // null')" '. + {project: $p}' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
          rm -f "$f.tmp"
        fi
        if [ "$st" = held ]; then touch "$PIPE/goal-$id.held"; else
          rm -f "$PIPE/goal-$id.held"
          # lift .stopped only when the registry itself confirmed that stop (resumed elsewhere); an unconfirmed local stop
          # whose registry write failed stays in force
          [ "$(cat "$PIPE/goal-$id.stopped" 2>/dev/null)" = registry ] && rm -f "$PIPE/goal-$id.stopped"
        fi
        if [ "$st" = waiting_jp ] && [ ! -f "$PIPE/goal-$id.waiting" ]; then echo "(from registry)" > "$PIPE/goal-$id.waiting"; fi
        _goal_sync_grant "$g" ;;
    esac
  done <<< "$(printf '%s' "$reg" | jq -c '.[]')"
  _goal_cleanup_retry "$reg"
  goal_project_tick "$reg" || true   # per-goal GitHub Project mirror, background and throttled; never blocks or fails the sync
}

# goal_eval <id> <spec> — live scope + ticket classes into GE_* (current shell); exit 1 on any failed read
goal_eval() {
  local rows ref st repo n r cls istate marker why
  GE_TOTAL=0; GE_DELIVERED=0; GE_ACTIVE=0; GE_WAITING=0; GE_SNAP=""; GE_REFS=""
  if [ -n "${3:-}" ]; then rows=$3; else rows=$(_goal_scope_rows "$2" "$1") || return 1; fi   # $3: explicit "ref<TAB>state" rows
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
    GE_SNAP="$GE_SNAP$ref	$istate	$marker	$cls
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
  local id=$1 issue=$2 spec=$3 body lb
  if [ ! -f "$PIPE/goal-$id.carded" ]; then
    body="**[deliver] NOTE** card

Goal $spec: everything in scope is delivered ($GE_DELIVERED of $GE_TOTAL tickets).

$(goal_cards delivered)"
    _goal_note "$issue" "$body" || { goal_err "cannot post the delivery card of $id"; return 0; }
    touch "$PIPE/goal-$id.carded"
  fi
  _goal_label_del "$issue" goal-held
  _goal_close "$issue" || { goal_err "cannot close the registry issue of $id"; return 0; }
  lb=$(jq -r '.label // empty' "$PIPE/goal-$id.json" 2>/dev/null)
  [ -z "$lb" ] || goal_label_close "$id" "$lb" "$(jq -r '(.repos // []) | join(",")' "$PIPE/goal-$id.json")"
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
  local id=$1 cache="$PIPE/goal-$1.json" spec issue pid alive=0 now la age restarts ec clean=0 run em idx wait_secs new old np seg lk=""
  spec=$(jq -r '.spec // empty' "$cache" 2>/dev/null); issue=$(jq -r '.issue // empty' "$cache" 2>/dev/null)
  [ -n "$spec" ] && [ -n "$issue" ] || return 0
  pid=$(cat "$PIPE/goal-$id.pid" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=1; fi
  if [ -f "$PIPE/goal-$id.stopped" ]; then [ "$alive" -eq 0 ] || goal_kill "$id"; return 0; fi
  if [ -f "$PIPE/goal-$id.held" ]; then
    # #427: a held goal is looked at once per sync: delivered when its scope is done, unheld when the snapshot moved
    if [ "$GOAL_SYNC_DUE" -eq 1 ]; then
      if goal_eval "$id" "$spec"; then
        if [ "$GE_TOTAL" -gt 0 ] && [ "$GE_DELIVERED" -eq "$GE_TOTAL" ]; then goal_deliver "$id" "$issue" "$spec"; return 0; fi
        # #443: a held goal whose every open ticket waits on JP is "waiting on JP", not "no progress": it stops holding the queue line
        if [ "$GE_TOTAL" -gt 0 ] && [ "$GE_ACTIVE" -eq 0 ] && [ "$GE_WAITING" -gt 0 ]; then
          rm -f "$PIPE/goal-$id.held"; echo 0 > "$PIPE/goal-$id.np"
          _goal_label_del "$issue" goal-held
          slog "[goal] $id unheld — waiting on JP"
          goal_mirror "$id" waiting_jp "$GE_TOTAL" "$GE_DELIVERED"
          goal_waiting "$id" "$issue" "$spec"; return 0
        fi
        new=$(printf '%s' "$GE_SNAP" | goal_snapshot); old=$(cat "$PIPE/goal-$id.snap" 2>/dev/null)
        if [ "$GE_TOTAL" -gt 0 ] && [ -n "$old" ] && [ "$new" != "$old" ]; then
          rm -f "$PIPE/goal-$id.held"; echo 0 > "$PIPE/goal-$id.np"
          _goal_label_del "$issue" goal-held
          slog "[goal] $id unheld — scope changed"
          goal_mirror "$id" active "$GE_TOTAL" "$GE_DELIVERED"; return 0
        fi
      else goal_err "goal $id evaluation failed (see the preceding error for the ticket and step)"; fi
    fi
    goal_mirror "$id" held; return 0
  fi

  if [ "$alive" -eq 1 ]; then   # alive: leave it alone; re-evaluate (mirror only) once per sync
    if [ "$GOAL_SYNC_DUE" -eq 1 ]; then
      if goal_eval "$id" "$spec"; then
        if [ "$GE_TOTAL" -gt 0 ] && [ "$GE_ACTIVE" -eq 0 ] && [ "$GE_WAITING" -gt 0 ]; then
          goal_mirror "$id" waiting_jp "$GE_TOTAL" "$GE_DELIVERED"
        else goal_mirror "$id" active "$GE_TOTAL" "$GE_DELIVERED"; fi
      else goal_err "goal $id evaluation failed (see the preceding error for the ticket and step)"; fi
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
  # a usage-limit exit (last launch segment only) is not a crash: wait RATE_LIMIT_BACKOFF_SECS and never count it (#417)
  seg=$(mktemp "${TMPDIR:-/tmp}/goal-exit.XXXXXX" 2>/dev/null) || seg=""
  if [ -n "$seg" ]; then
    last_launch_segment_line "$PIPE/goal-$id.log" > "$seg" 2>/dev/null
    lk=$(limit_kind_of "$seg"); rm -f "$seg"
    [ -n "$lk" ] && [ "$RATE_LIMIT_BACKOFF_SECS" -gt "$wait_secs" ] && wait_secs=$RATE_LIMIT_BACKOFF_SECS
  fi
  [ "$age" -ge "$wait_secs" ] || return 0
  # evaluating costs one gh read per ticket: a goal parked on JP is looked at once per sync, others whenever they could launch
  if [ "$GOAL_SYNC_DUE" -ne 1 ]; then
    [ "$GOAL_CAN_LAUNCH" -eq 1 ] && [ ! -f "$PIPE/goal-$id.waiting" ] || return 0
  fi
  if ! goal_eval "$id" "$spec"; then goal_err "goal $id evaluation failed (see the preceding error for the ticket and step)"; return 0; fi

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
  if [ -n "$lk" ]; then   # usage-limit exit: np and snap stay as they were
    slog "[goal] $id rate-limited limit=$lk backoff=${RATE_LIMIT_BACKOFF_SECS}s"
  else
    if [ "$GE_TOTAL" -eq 0 ] || { [ -n "$old" ] && [ "$new" = "$old" ]; }; then np=$((np + 1)); else np=0; fi
    echo "$np" > "$PIPE/goal-$id.np"; echo "$new" > "$PIPE/goal-$id.snap"
    if [ "$np" -ge "$GOAL_MAX_NO_PROGRESS" ]; then goal_park "$id" "$issue"; return 0; fi
  fi

  [ -f "$PIPE/goal-$id.stopped" ] && return 0   # a stop that landed during the scope reads
  if goal_launch "$id" >/dev/null 2>&1; then
    echo "$((restarts + 1 - clean))" > "$PIPE/goal-$id.restarts"
    slog "[goal] $id launched pid=$(cat "$PIPE/goal-$id.pid" 2>/dev/null) restarts=$(cat "$PIPE/goal-$id.restarts") np=$np mem=$(mem_available_mb)MB"
    GOAL_CAN_LAUNCH=0   # one launch per tick
  else
    goal_err "launch of $id failed"
  fi
}

# ---- goal queue (#320) ------------------------------------------------------------------------------------------
# deliver.sh register only enqueues (registry label goal-queued, st "queued", block host ""). The supervisor starts the
# lead of the next queued goal when it is that goal's turn and this host can take it. Everything is read from the
# registry (order, host_pref, state); $PIPE/goalqueue.json is only a prefilter the sync refreshes, never the authority:
# the start re-reads the registry, posts a claim on the registry issue and launches only if claim_winner names this host.

GOAL_QUEUE_FILE_NAME=goalqueue.json

# _GOAL_QUEUE_JQ: registry goals (array) -> {queued: [goals in queue order], candidate: goal | null}. Goals sort by the
# block's `order` (the registry issue number when absent), then by registry issue number. The candidate is the FIRST goal
# in that order that is not delivered / stopped / waiting on JP, provided it is queued: any earlier goal that is active,
# held, queued or unreadable holds the line.
_GOAL_QUEUE_JQ='def okey: [((.block.priority? // .block.order? // .issue) | if type == "number" then . else 1e12 end), .issue];
  sort_by(okey) as $all
  | ($all | map(select(.st == "queued"))) as $q
  | ($all | map(select((.st == "delivered" or .st == "stopped" or .st == "waiting_jp") | not)) | first // null) as $f
  | {queued: $q, candidate: (if $f != null and $f.st == "queued" then $f else null end),
     recent: ($all | map(select(.st == "delivered" or .st == "stopped")) | sort_by(.closed_at // "") | reverse | .[:5]),
     open: ($all | map(select(.st == "active" or .st == "held" or .st == "waiting_jp")))}'

# goal_queue_save <registry json> — the sync's prefilter and the status page's queue view (id, issue, title/spec, order,
# host_pref, label per queued goal, in queue order; plus the 5 most recently closed goals as `recent`). Best effort: a write failure is only an error row.
goal_queue_save() {
  local f="$PIPE/$GOAL_QUEUE_FILE_NAME" v
  v=$(printf '%s' "$1" | jq -c "$_GOAL_QUEUE_JQ"'
    | {at: (now | floor),
       candidate: (.candidate.id // null),
       recent: (.recent | map({id, issue, spec, title: (.block.title // ""), label: (.block.label // ""), repos: (.block.repos // []), st, closed_at, priority: (.block.priority? // null), project_url: (.block.project?.url? // "")})),
       open: (.open | map({id, issue, spec, title: (.block.title // ""), label: (.block.label // ""), repos: (.block.repos // []),
                           st, host: (.host // ""), priority: (.block.priority? // null), hosts: (.block.hosts? // "both"), project_url: (.block.project?.url? // "")})),
       queued: (.queued | map({id, issue, spec, title: (.block.title // ""), label: (.block.label // ""), priority: (.block.priority? // null),
                               repos: (.block.repos // []), order: (.block.order? // .issue), host_pref: (.block.host_pref // ""),
                               hosts: (.block.hosts? // "both"), project_url: (.block.project?.url? // "")}))}' 2>/dev/null) \
    || { goal_err "cannot compute the goal queue"; return 0; }
  mkdir -p "$PIPE" 2>/dev/null
  printf '%s\n' "$v" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" || { rm -f "$f.tmp"; goal_err "cannot write the goal queue cache"; }
  return 0
}

# goal_queue_derive <registry json> — display only: the registry state of a live goal is "active" until its lead writes
# goal-waiting-jp, and a goal with no lead running (re-pinned, between cycles) never gets that. For each open "active"
# goal whose lead is not alive on this host, read the tickets (goal_eval: the same marker rules the lead's own mirror uses)
# and, when none is progressable and at least one waits on JP, add needs_jp {waiting, active, total} to its row in
# goalqueue.json; build-runs-json.py shows such a goal as waiting on JP. Needs the supervisor's latest_marker; best effort.
goal_queue_derive() {
  local f="$PIPE/$GOAL_QUEUE_FILE_NAME" ids g id spec pid out="{}" tmp rows
  declare -F latest_marker >/dev/null 2>&1 || return 0
  [ -f "$f" ] || return 0
  ids=$(printf '%s' "$1" | jq -c '.[] | select(.st == "active") | {id, spec, granted: (.block.granted // [])}' 2>/dev/null) || return 0
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    id=$(printf '%s' "$g" | jq -r '.id // empty'); spec=$(printf '%s' "$g" | jq -r '.spec // empty')
    [ -n "$id" ] && [ -n "$spec" ] || continue
    pid=$(cat "$PIPE/goal-$id.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi   # a live lead mirrors its own state
    goal_eval "$id" "$spec" || continue
    if [ "$GE_TOTAL" -eq 0 ]; then   # the label can be gone from the tickets (stripped by an earlier goal's close): fall back to the go-granted list
      rows=$(printf '%s' "$g" | jq -r '(.granted // [])[] | "\(.)\topen"')
      [ -n "$rows" ] || continue
      goal_eval "$id" "$spec" "$rows" || continue
    fi
    [ "$GE_TOTAL" -gt 0 ] && [ "$GE_WAITING" -gt 0 ] || continue
    out=$(printf '%s' "$out" | jq -c --arg id "$id" --argjson w "$GE_WAITING" --argjson a "$GE_ACTIVE" --argjson t "$GE_TOTAL" \
      '. + {($id): {waiting: $w, active: $a, total: $t}}') || continue
  done <<< "$ids"
  tmp="$f.tmp"
  jq -c --argjson d "$out" '.open |= map(. + (if $d[.id] then {needs_jp: $d[.id]} else {} end))' "$f" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$f" || { rm -f "$tmp"; goal_err "cannot record the JP-gate evidence of the open goals"; }
  return 0
}

# goal_next_priority — 1 + the highest priority among the live (not delivered / stopped) registry goals; 1 when none has one.
# Priority 1 starts first; the block's `priority` (set by deliver.sh register --priority / deliver.sh priority) outranks `order`.
goal_next_priority() {
  local j
  j=$(_goal_registry_json) || return 1
  printf '%s' "$j" | jq -r '[.[] | select(.st != "delivered" and .st != "stopped") | (.block.priority? // empty) | select(type == "number")] | ((max // 0) + 1)'
}

# goal_is_mac — the laptop (battery rules, VM-first). Same test as power_ok.
goal_is_mac() { [ "$(uname)" = "Darwin" ]; }

# goal_role — this host's role for a goal's `hosts` field: mac or vm.
goal_role() { if goal_is_mac; then echo mac; else echo vm; fi; }

# goal_foreign_labels — labels of open goals whose `hosts` restricts their tickets to the OTHER host (hosts: mac|vm). A goal with
# `hosts: both` (the default, also when the field is absent) has its tickets dispatched by whichever host is free: the lead's host
# through the lead, the other host through step 5, and the claim comment keeps any ticket from running on both.
goal_foreign_labels() {
  jq -r --arg r "$(goal_role)" '.open[]? | select((.hosts // "both") as $h | ($h == "mac" or $h == "vm") and $h != $r) | (.label // empty)' \
    "$PIPE/$GOAL_QUEUE_FILE_NAME" 2>/dev/null
}

# goal_live_labels — the goal labels (cross-repo goals, #319) whose delivery lead is alive on THIS host, one per line.
goal_live_labels() {
  local f id h pid l
  for f in "$PIPE"/goal-*.json; do
    [ -e "$f" ] || break
    id=$(basename "$f" .json); id=${id#goal-}
    h=$(jq -r '(.host // "") | ascii_downcase' "$f" 2>/dev/null)
    [ "$h" = "$(pipeline_host)" ] || continue
    [ -f "$PIPE/goal-$id.stopped" ] && continue
    pid=$(cat "$PIPE/goal-$id.pid" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
    l=$(jq -r '.label // empty' "$f" 2>/dev/null)
    [ -z "$l" ] || printf '%s\n' "$l"
  done
}

# goal_queued_labels — the goal labels of goals still waiting in the queue (from the sync's goalqueue.json prefilter), one per
# line. Their tickets must not start before the goal does (JP 2026-10-17).
goal_queued_labels() {
  jq -r '.queued[]? | (.label // empty)' "$PIPE/$GOAL_QUEUE_FILE_NAME" 2>/dev/null
}

# _goal_queue_wait <id> — bumps and prints the number of consecutive ticks this host has seen <id> next in line and still
# unclaimed (reset by _goal_queue_wait_reset whenever it is not).
_goal_queue_wait() {
  local f="$PIPE/goalq-wait" cur_id cur_n
  read -r cur_id cur_n < "$f" 2>/dev/null || { cur_id=""; cur_n=0; }
  case "$cur_n" in ''|*[!0-9]*) cur_n=0 ;; esac
  if [ "$cur_id" = "$1" ]; then cur_n=$((cur_n + 1)); else cur_n=1; fi
  printf '%s %s\n' "$1" "$cur_n" > "$f" 2>/dev/null
  printf '%s\n' "$cur_n"
}
_goal_queue_wait_reset() { rm -f "$PIPE/goalq-wait"; }

_goal_queue_body() {  # <goal json with the new block> -> the registry issue body for that block
  local g=$1 block date
  block=$(printf '%s' "$g" | jq -c '.block')
  if [ "$(printf '%s' "$block" | jq -r '(.v // 1)')" = 2 ]; then
    date=$(printf '%s' "$block" | jq -r '(.granted_at // empty)'); [ -n "$date" ] || date=$(date -u +%F)
    goal_body_v2 "$block" "$date"
  else
    printf 'Goal: %s\n\n```json\n%s\n```\n' "$(printf '%s' "$g" | jq -r .spec)" "$block"
  fi
}

# goal_queue_fail <registry issue> <id> <message> — a failed start attempt: the error row (goal_err), no new attempt within the
# claim window, and one #engineering alert per goal through the existing notify_engineering path (no new webhook). The alert
# carries the release (checkout SHA) and the goal id only.
goal_queue_fail() {
  goal_err "$3"
  date +%s > "$PIPE/goalq-lost-$2" 2>/dev/null
  if [ ! -e "$PIPE/goalq-alerted-$2" ]; then
    : > "$PIPE/goalq-alerted-$2" 2>/dev/null
    command -v notify_engineering >/dev/null 2>&1 \
      && notify_engineering "$1" ":warning:" "Goal queue: $3 (goal $2, release $(goal_release))" "$GOAL_REGISTRY_REPO" || true
  fi
  return 0
}

# goal_queue_step — called from goal_step once per tick, after the live goals were ticked.
goal_queue_step() {
  local qf="$PIPE/$GOAL_QUEUE_FILE_NAME" cand pin hosts n fresh g id issue winner rc ts lost now g2 body
  rm -f "$PIPE/goal-paused"
  [ -f "$qf" ] || return 0
  cand=$(jq -r '.candidate // empty' "$qf" 2>/dev/null)
  if [ -z "$cand" ]; then _goal_queue_wait_reset; return 0; fi
  pin=$(jq -r --arg c "$cand" '[.queued[] | select(.id == $c)][0].host_pref // "" | ascii_downcase' "$qf" 2>/dev/null)
  if [ -f "$PIPE/goal-$cand.stopped" ]; then _goal_queue_wait_reset; return 0; fi
  # pinned goals run only on their host; unpinned ones are VM-first: the Mac waits two ticks for the VM to take it
  hosts=$(jq -r --arg c "$cand" '[.queued[] | select(.id == $c)][0].hosts // "both"' "$qf" 2>/dev/null)
  if [ "$hosts" = mac ] || [ "$hosts" = vm ]; then   # hosts: mac|vm confines the whole goal (lead and tickets) to that machine
    [ "$hosts" = "$(goal_role)" ] || { _goal_queue_wait_reset; return 0; }
  fi
  if [ -n "$pin" ]; then
    [ "$pin" = "$GOAL_THIS_HOST" ] || { _goal_queue_wait_reset; return 0; }
  elif [ "$hosts" = mac ] || [ "$hosts" = vm ]; then
    :
  elif goal_is_mac; then
    n=$(_goal_queue_wait "$cand")
    [ "$n" -ge 2 ] || return 0
  fi
  # capacity: a free goal slot, memory above the floor, AC power on the Mac (GOAL_CAN_LAUNCH folds the three together)
  if [ "$GOAL_CAN_LAUNCH" -ne 1 ]; then
    if goal_is_mac && ! power_ok && [ "$(mem_available_mb)" -ge "$MEM_FLOOR_MB" ] 2>/dev/null && [ "$GOAL_LIVE" -lt "$MAX_GOALS" ]; then
      echo "Mac on battery" > "$PIPE/goal-paused"
    fi
    return 0
  fi
  # a failed or lost attempt is not repeated within the claim window (no claim comment spam on the registry issue)
  now=$(date +%s)
  lost=$(cat "$PIPE/goalq-lost-$cand" 2>/dev/null); case "$lost" in ''|*[!0-9]*) lost=0 ;; esac
  [ $((now - lost)) -ge "${CLAIM_WINDOW_SECS:-600}" ] || return 0

  # the registry is the authority: re-read it, and start only if this goal is still the queued candidate
  fresh=$(_goal_registry_json) || { goal_err "cannot read the goal registry to start $cand"; return 0; }
  g=$(printf '%s' "$fresh" | jq -c "$_GOAL_QUEUE_JQ"' | .candidate // empty')
  if [ -z "$g" ] || [ "$(printf '%s' "$g" | jq -r .id)" != "$cand" ]; then
    goal_queue_save "$fresh"; _goal_queue_wait_reset; return 0
  fi
  id=$cand; issue=$(printf '%s' "$g" | jq -r .issue)
  [ -f "$PIPE/goal-$id.stopped" ] && return 0
  _goal_checkout "$(_goal_primary_repo "$g")" >/dev/null 2>&1 || { goal_err "$id: its repo is not in DISPATCH_REPOS on this host"; return 0; }

  # two-host race: post a claim on the registry issue and go on only if claim_winner names this host
  ts=$(date -u +%FT%TZ)
  _goal_note "$issue" "**[supervisor] NOTE** claim: $GOAL_THIS_HOST $ts" || { goal_queue_fail "$issue" "$id" "cannot post the start claim of $id"; return 0; }
  sleep "${CLAIM_SETTLE_SECS:-15}"
  winner=$(claim_winner "$_GOAL_LIB_DIR" "$issue" "$GOAL_REGISTRY_REPO") \
    || { goal_queue_fail "$issue" "$id" "cannot read the start claims of $id"; return 0; }
  if [ "$winner" != "$GOAL_THIS_HOST" ]; then
    slog "[goal] $id — lost the start claim to ${winner:-?}"
    echo "$now" > "$PIPE/goalq-lost-$id"
    return 0
  fi
  [ -f "$PIPE/goal-$id.stopped" ] && return 0

  # won: pin the goal here (block host), leave the queue, write the cache and launch
  g2=$(printf '%s' "$g" | jq -c --arg h "$GOAL_THIS_HOST" '.block.host = $h | .host = $h')
  body=$(_goal_queue_body "$g2")
  _goal_patch_body "$issue" "$body" >/dev/null 2>&1 || { goal_queue_fail "$issue" "$id" "cannot pin $id to $GOAL_THIS_HOST on the registry issue"; return 0; }
  _goal_label_del "$issue" goal-queued
  printf '%s' "$g2" | jq -c --argjson n "$issue" '.block + {issue: $n}' > "$PIPE/goal-$id.json" 2>/dev/null \
    || { goal_err "cannot write the cache of $id"; return 0; }
  mkdir -p "$LOGDIR/goals" 2>/dev/null
  if goal_launch "$id" "$g2" >/dev/null 2>&1; then
    slog "[goal] $id started from the queue on $GOAL_THIS_HOST (issue #$issue) pid=$(cat "$PIPE/goal-$id.pid" 2>/dev/null) mem=$(mem_available_mb)MB"
    GOAL_CAN_LAUNCH=0; GOAL_LIVE=$((GOAL_LIVE + 1))
    _goal_queue_wait_reset
    rm -f "$PIPE/goalq-alerted-$id" "$PIPE/goalq-lost-$id"
    report_status_async "goal"
  else
    goal_queue_fail "$issue" "$id" "launch of $id from the queue failed"
    # back to the queue: unpin, re-label, drop the cache
    rc=0
    _goal_patch_body "$issue" "$(_goal_queue_body "$g")" >/dev/null 2>&1 || rc=1
    _goal_label_add "$issue" goal-queued || rc=1
    [ "$rc" -eq 0 ] || goal_err "cannot put $id back in the queue"
    rm -f "$PIPE"/goal-"$id".*
  fi
  return 0
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
  GOAL_LIVE=$live
  for id in $GOAL_OWNED; do goal_tick_one "$id"; done
  goal_queue_step
}

# per-goal GitHub Project mirror: the only file that calls `gh project` / GraphQL (needs the `project` scope; skipped without it)
. "$_GOAL_LIB_DIR/goal-project.sh"
