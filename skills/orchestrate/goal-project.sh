#!/bin/bash
# Per-goal GitHub Project (v2) mirror, sourced by goal-lib.sh. The registry issue stays the source of truth; the project is a
# mirror for JP to look at: "Goal: <readable title>", every ticket of the goal across its repos as an item, the Status field
# kept in step with the ticket. The registry block records it as `project: {owner, number, url}`.
#
# THIS IS THE ONLY FILE THAT MAY CALL `gh project` OR GraphQL (it needs the token's `project` scope; the tests pin that).
# Hosts without the scope (the VM) skip everything: goal_project_enabled is false there. Nothing here may block or fail a
# goal: every error is logged ([goal] project: ...) and skipped; callers use `|| true`.
# Needs goal-lib.sh sourced first (GOAL_REGISTRY_REPO, _goal_scope_rows, _goal_issue_to_goal, _goal_queue_body, ...).

GOAL_PROJECT_TEMPLATE="${GOAL_PROJECT_TEMPLATE-1}"     # project number (same owner) whose fields/views new projects copy; empty = plain create
GOAL_PROJECT_SECS="${GOAL_PROJECT_SECS:-900}"          # at most one background project sync per this many seconds
GP_URL_RE='^https://github\.com/(users|orgs)/[A-Za-z0-9._-]+/projects/[0-9]+$'

_gp_owner() { printf '%s' "${GOAL_PROJECT_OWNER:-${GOAL_REGISTRY_REPO%%/*}}"; }
_gp_log() { slog "[goal] project: $*"; }

# goal_project_enabled — GOAL_PROJECTS is not 0 and this host's gh token has the `project` scope (checked once per process).
goal_project_enabled() {
  local h s
  [ "${GOAL_PROJECTS:-1}" != 0 ] || return 1
  if [ -z "${_GP_SCOPE:-}" ]; then
    h=$(gh api -i user 2>/dev/null | tr -d '\r' | grep -i '^x-oauth-scopes:' || true)
    s=",$(printf '%s' "${h#*:}" | tr -d ' '),"
    case "$s" in *,project,*) _GP_SCOPE=yes ;; *) _GP_SCOPE=no ;; esac
  fi
  [ "$_GP_SCOPE" = yes ]
}

# goal_project_title <goal json> -> "Goal: <readable title>"
goal_project_title() {
  local t spec
  t=$(printf '%s' "$1" | jq -r '.block.title // ""')
  if [ -z "$t" ]; then
    spec=$(printf '%s' "$1" | jq -r '.spec // ""')
    t=$(goal_name_for "$spec" 2>/dev/null) || t="$spec"
  fi
  t=$(printf '%s' "$t" | tr '\t\n\r' '   ')
  printf 'Goal: %s\n' "$t"
}

_gp_list() { gh project list --owner "$(_gp_owner)" --closed --format json -L 200 2>/dev/null | jq -c '.projects // []'; }

# _gp_registry_set <registry issue> <project json> — re-read the issue and write its block with `project` set
_gp_registry_set() {
  local cur g
  cur=$(gh api "repos/$GOAL_REGISTRY_REPO/issues/$1" 2>/dev/null) || return 1
  g=$(printf '%s' "$cur" | _goal_issue_to_goal) || return 1
  [ -n "$g" ] && [ "$(printf '%s' "$g" | jq -r '.st')" != unreadable ] || return 1
  g=$(printf '%s' "$g" | jq -c --argjson p "$2" '.block |= (. + {project: $p})') || return 1
  _goal_patch_body "$1" "$(_goal_queue_body "$g")" >/dev/null
}

# _gp_cache_set <id> <project json> — the local goal cache the status page reads
_gp_cache_set() {
  local f="$PIPE/goal-$1.json"
  [ -f "$f" ] || return 0
  jq -c --argjson p "$2" '. + {project: $p}' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  rm -f "$f.tmp"
}

# _gp_items <owner> <project number> -> {"items":[{id,status,labels,content:{repository,number}}]} for the project's issue items, read with
# a paginated `gh api graphql` query that asks only for what the sync uses (id, issue repo/number, label names, Status), so each page
# costs 1 point. Exit 1 when any page fails or is unreadable.
_GP_ITEMS_Q='query($owner:String!,$number:Int!,$cursor:String){repositoryOwner(login:$owner){... on ProjectV2Owner{projectV2(number:$number){items(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{id fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}} content{... on Issue{number repository{nameWithOwner} labels(first:20){nodes{name}}}}}}}}}}'
_gp_items() {
  local o="$1" n="$2" cur="" page nodes="[]" more
  while :; do
    if [ -n "$cur" ]; then
      page=$(gh api graphql -f query="$_GP_ITEMS_Q" -f owner="$o" -F number="$n" -f cursor="$cur" 2>/dev/null) || return 1
    else
      page=$(gh api graphql -f query="$_GP_ITEMS_Q" -f owner="$o" -F number="$n" 2>/dev/null) || return 1
    fi
    nodes=$(jq -c --argjson acc "$nodes" '$acc + (.data.repositoryOwner.projectV2.items.nodes | if type == "array" then . else error("no nodes") end)' <<< "$page" 2>/dev/null) || return 1
    more=$(jq -r '.data.repositoryOwner.projectV2.items.pageInfo | if .hasNextPage == true then (.endCursor // "") else "" end' <<< "$page" 2>/dev/null) || return 1
    [ -n "$more" ] || break
    cur="$more"
  done
  jq -c '{items: [.[] | select((.content.number? // null) != null) | {id, status: (.fieldValueByName.name? // null), labels: [.content.labels.nodes[]?.name],
    content: {repository: .content.repository.nameWithOwner, number: .content.number}}]}' <<< "$nodes"
}

# _gp_find <title> <scope refs> <full 0|1> -> number of an existing project that is this goal's: the same title, or (full) the
# smallest "Goal: " project that holds every ticket of the goal (several goals may share one project).
_gp_find() {
  local title="$1" refs="$2" full="$3" list n c items best="" bestc=0 cnt
  list=$(_gp_list) || return 0
  n=$(printf '%s' "$list" | jq -r --arg t "$title" '[.[] | select((.title | ascii_downcase) == ($t | ascii_downcase)) | .number] | first // empty')
  if [ -n "$n" ]; then printf '%s\n' "$n"; return 0; fi
  [ "$full" = 1 ] && [ -n "$refs" ] || return 0
  for c in $(printf '%s' "$list" | jq -r '.[] | select(.title | startswith("Goal: ")) | .number'); do
    items=$(_gp_items "$(_gp_owner)" "$c" 2>/dev/null \
      | jq -r '.items[] | select(.content.repository != null) | "\(.content.repository)#\(.content.number)"') || continue
    [ -n "$items" ] || continue
    if [ -z "$(printf '%s\n' "$refs" | grep -vxFf <(printf '%s\n' "$items") || true)" ]; then
      cnt=$(printf '%s\n' "$items" | grep -c .)
      if [ -z "$best" ] || [ "$cnt" -lt "$bestc" ]; then best=$c; bestc=$cnt; fi
    fi
  done
  [ -z "$best" ] || printf '%s\n' "$best"
}

# goal_project_ensure <goal json> [bind|create] -> prints the project json {owner,number,url} when the block has none: binds an
# existing "Goal: ..." project (same title, or at least half of its items are this goal's tickets) and records it in the registry
# block and the local cache. `create` (register, or `deliver.sh project --create`) creates one from the template when none binds;
# `bind` (default; sync, backfill) never creates one: the projects JP already has are the goals' projects. Exit 1 when none.
goal_project_ensure() {
  local g="$1" mode="${2:-bind}" full=1 cur o title issue id spec refs n out url p repo reg_url
  goal_project_enabled || return 1
  cur=$(printf '%s' "$g" | jq -c '.block.project? // empty | select(type == "object" and (.number | type) == "number")')
  if [ -n "$cur" ]; then printf '%s\n' "$cur"; return 0; fi
  o=$(_gp_owner); issue=$(printf '%s' "$g" | jq -r '.issue'); id=$(printf '%s' "$g" | jq -r '.id'); spec=$(printf '%s' "$g" | jq -r '.spec')
  title=$(goal_project_title "$g")
  [ "$mode" != create ] || full=0
  refs=""; [ "$full" != 1 ] || refs=$(goal_scope "$spec" "$id" "$(printf '%s' "$g" | jq -r '(.block.repos // []) | join(",")')" 2>/dev/null || true)
  n=$(_gp_find "$title" "$refs" "$full") || n=""
  if [ -n "$n" ]; then
    p=$(gh project view "$n" --owner "$o" --format json 2>/dev/null) || { _gp_log "cannot read project $n"; return 1; }
    url=$(printf '%s' "$p" | jq -r .url)
  else
    [ "$mode" = create ] || return 1
    out=""
    if [ -n "$GOAL_PROJECT_TEMPLATE" ]; then
      out=$(gh project copy "$GOAL_PROJECT_TEMPLATE" --source-owner "$o" --target-owner "$o" --title "$title" --format json 2>/dev/null) || out=""
    fi
    if [ -z "$out" ]; then out=$(gh project create --owner "$o" --title "$title" --format json 2>/dev/null) || { _gp_log "cannot create project '$title'"; return 1; }; fi
    n=$(printf '%s' "$out" | jq -r '.number // empty'); url=$(printf '%s' "$out" | jq -r '.url // empty')
    [ -n "$n" ] || { _gp_log "create gave no project number for '$title'"; return 1; }
    reg_url="https://github.com/$GOAL_REGISTRY_REPO/issues/$issue"
    gh project edit "$n" --owner "$o" --description "Mirror of the delivery goal $reg_url (the registry issue is the source of truth)" >/dev/null 2>&1 \
      || _gp_log "cannot set the description of project $n"
  fi
  [[ "$url" =~ $GP_URL_RE ]] || url="https://github.com/users/$o/projects/$n"
  for repo in $(printf '%s' "$g" | jq -r '(.block.repos // [])[]' 2>/dev/null) $(printf '%s\n' "$refs" | sed -E 's/#[0-9]+$//' | sort -u); do
    gh project link "$n" --owner "$o" --repo "$repo" >/dev/null 2>&1 || true
  done
  p=$(jq -nc --arg o "$o" --argjson n "$n" --arg u "$url" '{owner:$o, number:$n, url:$u}')
  _gp_registry_set "$issue" "$p" || { _gp_log "cannot record project $n in registry issue #$issue"; return 1; }
  _gp_cache_set "$id" "$p"
  _gp_log "goal $id -> project $n"
  printf '%s\n' "$p"
}

# goal_project_sync_one <goal json> [bind|create] — ensure the project, add every ticket of the goal (idempotent), mirror Status, and
# close the project when the goal is delivered or stopped (reopen it when the goal is live again). Never closes the registry.
goal_project_sync_one() {
  local g="$1" mode="${2:-bind}" st id spec repos p o n rows items ref s repo num want have item pid fid oid view closed added=0 rc=0 live=1
  goal_project_enabled || return 1
  st=$(printf '%s' "$g" | jq -r '.st'); id=$(printf '%s' "$g" | jq -r '.id'); spec=$(printf '%s' "$g" | jq -r '.spec')
  case "$st" in unreadable) return 0 ;; stopped|delivered) live=0 ;; esac
  p=$(printf '%s' "$g" | jq -c '.block.project? // empty | select(type == "object" and (.number | type) == "number")')
  if [ -z "$p" ]; then
    [ "$live" = 1 ] || return 0
    p=$(goal_project_ensure "$g" "$mode") || return 0   # no project bound and none to create: nothing to mirror
  fi
  o=$(printf '%s' "$p" | jq -r '.owner // empty'); [ -n "$o" ] || o=$(_gp_owner)
  n=$(printf '%s' "$p" | jq -r '.number')
  repos=$(printf '%s' "$g" | jq -r '(.block.repos // []) | join(",")')
  rows=$(_goal_scope_rows "$spec" "$id" "$repos" 2>/dev/null) || { _gp_log "cannot read the scope of $id"; return 1; }
  items=$(_gp_items "$o" "$n") || { _gp_log "cannot list project $n"; return 1; }
  while IFS=$'\t' read -r ref s; do
    [ -n "$ref" ] || continue
    repo=${ref%%#*}; num=${ref##*#}
    if [ -z "$(printf '%s' "$items" | jq -r --arg r "$repo" --argjson n "$num" '.items[] | select(.content.repository == $r and .content.number == $n) | .id' | head -1)" ]; then
      if gh project item-add "$n" --owner "$o" --url "https://github.com/$repo/issues/$num" >/dev/null 2>&1; then added=1; else _gp_log "cannot add $ref to project $n"; rc=1; fi
    fi
  done <<< "$rows"
  [ "$added" = 0 ] || items=$(_gp_items "$o" "$n") || items='{"items":[]}'
  pid=""
  while IFS=$'\t' read -r ref s; do
    [ -n "$ref" ] || continue
    repo=${ref%%#*}; num=${ref##*#}
    item=$(printf '%s' "$items" | jq -c --arg r "$repo" --argjson n "$num" '[.items[] | select(.content.repository == $r and .content.number == $n)] | first // empty')
    [ -n "$item" ] || continue
    if [ "$s" = closed ]; then want="Done"
    elif [ "$(printf '%s' "$item" | jq -r '(.labels // []) | index("agent-in-progress") != null')" = true ]; then want="In Progress"
    else want="Todo"; fi
    have=$(printf '%s' "$item" | jq -r '.status // ""')
    [ "$have" != "$want" ] || continue
    if [ -z "$pid" ]; then
      pid=$(gh project view "$n" --owner "$o" --format json 2>/dev/null | jq -r '.id // empty')
      fid=$(gh project field-list "$n" --owner "$o" --format json 2>/dev/null | jq -c '[.fields[] | select(.name == "Status")] | first // empty')
      [ -n "$pid" ] && [ -n "$fid" ] || { _gp_log "cannot read the Status field of project $n"; return 1; }
    fi
    oid=$(printf '%s' "$fid" | jq -r --arg w "$want" '[.options[]? | select(.name == $w) | .id] | first // empty')
    [ -n "$oid" ] || continue
    gh project item-edit --id "$(printf '%s' "$item" | jq -r .id)" --project-id "$pid" --field-id "$(printf '%s' "$fid" | jq -r .id)" \
      --single-select-option-id "$oid" >/dev/null 2>&1 || { _gp_log "cannot set the Status of $ref"; rc=1; }
  done <<< "$rows"
  view=$(gh project view "$n" --owner "$o" --format json 2>/dev/null) || return 1
  closed=$(printf '%s' "$view" | jq -r '.closed // false')
  if [ "$live" = 0 ] && [ "$closed" != true ]; then
    gh project close "$n" --owner "$o" >/dev/null 2>&1 || { _gp_log "cannot close project $n"; rc=1; }
  elif [ "$live" = 1 ] && [ "$closed" = true ]; then
    gh project close "$n" --owner "$o" --undo >/dev/null 2>&1 || { _gp_log "cannot reopen project $n"; rc=1; }
  fi
  return $rc
}

# goal_project_sync_all <registry json> — every goal of the registry, one failure never stops the rest
goal_project_sync_all() {
  local g
  goal_project_enabled || return 0
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    goal_project_sync_one "$g" bind || _gp_log "sync of $(printf '%s' "$g" | jq -r '.id // "?"') skipped"
  done <<< "$(printf '%s' "$1" | jq -c '.[]')"
  return 0
}

# goal_project_refresh_list — $PIPE/goalprojects.json {at, owner, projects:[{number,title,url,closed,closed_seen}]}: every project of the
# owner, open and closed, so the status page lists each one as a goal row with no registry edit (build-runs-json.py reads it).
# closed_seen = when this cache first saw the project closed (gh gives no close time); it keeps the "recently closed" window honest.
# Calls report_status_async when the list changed, so the page picks a new project up at once.
goal_project_refresh_list() {
  local f="$PIPE/goalprojects.json" o list prev new now
  if ! goal_project_enabled; then   # no project scope here: an empty list, so this host lists no goal rows of its own (the Mac's report has them)
    [ "$(jq -c '.projects' "$f" 2>/dev/null)" = "[]" ] || { mkdir -p "$PIPE" 2>/dev/null; echo '{"projects":[]}' > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"; }
    return 0
  fi
  o=$(_gp_owner); now=$(date -u +%FT%TZ)
  list=$(gh project list --owner "$o" --closed --format json -L 200 2>/dev/null | jq -c '.projects // empty') || list=""
  [ -n "$list" ] || { _gp_log "cannot list the projects of $o"; return 1; }
  prev=$(jq -c '.projects // []' "$f" 2>/dev/null) || prev='[]'
  [ -n "$prev" ] || prev='[]'
  new=$(jq -nc --argjson l "$list" --argjson p "$prev" --arg o "$o" --arg now "$now" \
    '{owner:$o, projects: [$l[] | . as $x | {number, title, url, closed: (.closed // false),
        closed_seen: (if (.closed // false) then (([$p[] | select(.number == $x.number) | .closed_seen] | first) // $now) else null end)}]}') || return 1
  if [ "$(printf '%s' "$new" | jq -c .projects)" != "$(printf '%s' "$prev")" ]; then
    printf '%s' "$new" | jq -c --arg now "$now" '. + {at:$now}' > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" || { rm -f "$f.tmp"; return 1; }
    type report_status_async >/dev/null 2>&1 && report_status_async "goal-projects"
  fi
  return 0
}

# goal_project_tick <registry json> — called from goal_sync, every call: the project list refresh; at most every GOAL_PROJECT_SECS: the
# per-goal sync. Runs in the background (one at a time), so a slow or failing GitHub Projects call can never hold up the supervisor.
goal_project_tick() {
  local last now pf="$PIPE/goal-project.pid" dosync=0
  [ "${GOAL_PROJECTS:-1}" != 0 ] || return 0
  now=$(date +%s)
  last=$(cat "$PIPE/goal-project.last" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -ge "$GOAL_PROJECT_SECS" ]; then dosync=1; fi
  if kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then return 0; fi
  [ "$dosync" = 0 ] || echo "$now" > "$PIPE/goal-project.last" 2>/dev/null
  ( goal_project_refresh_list; [ "$dosync" = 0 ] || goal_project_sync_all "$1" ) >>"$PIPE/goal-project.log" 2>&1 </dev/null &
  echo $! > "$pf" 2>/dev/null
  disown 2>/dev/null || true
  return 0
}
