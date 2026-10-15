#!/bin/bash
# Goal-bound delivery lead launcher / operator CLI (#193). A goal is a registry issue on GitHub; this registers it
# and starts one cycle of $GOAL_AGENT. Keep-alive and completion are the supervisor's job (#195).
# Usage:
#   deliver.sh <goal> [instructions...]   register + launch one cycle. <goal> = owner/repo:milestone:<number|exact title>
#                                         | owner/repo:milestones:all | owner/repo#N
#   deliver.sh status [goal|id]           one line per registry goal (open, plus closed within 7 days)
#   deliver.sh stop <goal|id>             label goal-stopped, close the registry issue, kill the local cycle (idempotent)
#   deliver.sh resume <goal|id> [--here]  reopen a stopped/held goal; --here re-pins it to this host
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/config.sh"
source "$HERE/pipeline-lib.sh"
source "$HERE/../../hooks/pipeline-markers.sh" 2>/dev/null || source "$HOME/.claude/hooks/pipeline-markers.sh"
source "$HERE/goal-lib.sh"

die() { echo "deliver.sh: $*" >&2; exit 1; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
THIS_HOST=$(pipeline_host)

ensure_label() {  # a 422 (already exists) is the normal case
  gh api -X POST "repos/$GOAL_REGISTRY_REPO/labels" -f "name=$1" >/dev/null 2>&1 || true
}
add_label() { gh api -X POST "repos/$GOAL_REGISTRY_REPO/issues/$1/labels" -f "labels[]=$2" >/dev/null; }
del_label() { gh api -X DELETE "repos/$GOAL_REGISTRY_REPO/issues/$1/labels/$2" >/dev/null 2>&1 || true; }
post_note() { gh api -X POST "repos/$GOAL_REGISTRY_REPO/issues/$1/comments" -f "body=$2" >/dev/null; }
set_state() { gh api -X PATCH "repos/$GOAL_REGISTRY_REPO/issues/$1" -f "state=$2" >/dev/null; }
api_json() {  # <method> <rest path> <json body> — body on stdin so a multi-line issue body stays one argument-free call
  printf '%s' "$3" | gh api -X "$1" "$2" --input -
}
body_for() { printf 'Goal: %s\n\n```json\n%s\n```\n' "$1" "$2"; }

# check_overlap <spec> <id> [exclude registry issue number] — dies naming the live goal that conflicts.
# Live = open registry goal (active, held or waiting on JP); judged from the registry, never the local cache.
check_overlap() {
  local spec="$1" id="$2" skip="${3:-}" reg new_repo new_kind new_rows other row o_issue o_id o_spec o_st o_repo o_kind
  reg=$(_goal_registry_json) || die "cannot read the goal registry ($GOAL_REGISTRY_REPO); refusing to go on blind"
  IFS=$'\t' read -r new_repo new_kind _ <<< "$(goal_parse "$spec")"
  new_rows=$(goal_scope "$spec" "$id") || die "cannot read the scope of $spec"
  while IFS=$'\t' read -r o_issue o_id o_spec o_st; do
    [ "$o_issue" = "$skip" ] && continue
    # empty fields arrive as "-" (a tab split would collapse them); an unreadable id/state/issue fails closed
    if [ "$o_issue" = "-" ] || [ "$o_id" = "-" ] || [ "$o_st" = "-" ] || [ -z "$o_st" ]; then
      die "cannot read a live registry entry (issue #${o_issue}); refusing to go on blind"
    fi
    case "$o_st" in
      active|held|waiting_jp) ;;
      unreadable) die "cannot read the registry block of $o_id (issue #$o_issue); refusing to go on blind" ;;
      *) continue ;;
    esac
    [ "$o_id" = "$id" ] && die "overlaps live goal $o_id (same goal)"
    o_repo=""; o_kind=""
    IFS=$'\t' read -r o_repo o_kind _ <<< "$(goal_parse "$o_spec" 2>/dev/null || true)"
    [ -n "$o_repo" ] || die "cannot read the stored spec of live goal $o_id; refusing to go on blind"
    [ "$o_repo" = "$new_repo" ] || continue
    if [ "$new_kind" = msall ] || [ "$o_kind" = msall ]; then die "overlaps live goal $o_id (milestones:all on $new_repo)"; fi
    other=$(goal_scope "$o_spec" "$o_id" 2>/dev/null) || die "cannot read the scope of $o_id; refusing to go on blind"
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      if printf '%s\n' "$new_rows" | grep -qxF -- "$row"; then die "overlaps live goal $o_id (shares $row)"; fi
    done <<< "$other"
  done <<< "$(printf '%s' "$reg" | jq -r 'def f: if . == null or . == "" then "-" else tostring end; .[] | "\(.issue | f)\t\(.id | f)\t\(.spec | f)\t\(.st | f)"')"
}

write_cache() {  # <id> <block json> <issue number>
  mkdir -p "$PIPE"
  printf '%s' "$2" | jq -c --argjson n "$3" '. + {issue: $n}' > "$PIPE/goal-$1.json"
}

goal_state_label() {  # <registry goal json> -> status word
  local g="$1" st host pid
  st=$(printf '%s' "$g" | jq -r .st); host=$(printf '%s' "$g" | jq -r .host)
  case "$st" in
    stopped|delivered|held|unreadable) echo "$st" ;;
    waiting_jp) echo "waiting on JP" ;;
    *)
      if [ "$host" = "$THIS_HOST" ]; then
        pid=$(cat "$PIPE/goal-$(printf '%s' "$g" | jq -r .id).pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "running pid $pid"; else echo "between cycles"; fi
      else
        echo "active on $host"
      fi ;;
  esac
}

cmd_register() {
  local spec="$1"; shift
  local instr="$*" line repo id checkout rows block body resp n
  line=$(goal_parse "$spec") || exit 1
  repo=$(printf '%s' "$line" | cut -f1)
  checkout=$(_goal_checkout "$repo") || die "$repo is not in DISPATCH_REPOS; goals only run on dispatched repos"
  [ -e "$checkout/.git" ] || die "checkout $checkout for $repo is not a git checkout"
  id=$(goal_id "$spec") || exit 1
  rows=$(_goal_scope_rows "$spec") || die "cannot read the scope of $spec"
  [ -n "$rows" ] || die "empty scope: $spec has no tickets; a goal must start with at least one"
  check_overlap "$spec" "$id"
  block=$(jq -nc --arg id "$id" --arg spec "$spec" --arg host "$THIS_HOST" --arg created "$(now_utc)" --arg ins "$instr" \
    '{v:1,id:$id,spec:$spec,host:$host,created:$created,instructions:$ins}')
  body=$(body_for "$spec" "$block")
  ensure_label delivery-goal
  resp=$(api_json POST "repos/$GOAL_REGISTRY_REPO/issues" \
    "$(jq -nc --arg t "Goal: $spec" --arg b "$body" '{title:$t, body:$b, labels:["delivery-goal"]}')") \
    || die "could not create the registry issue"
  n=$(printf '%s' "$resp" | jq -r .number)
  mkdir -p "$LOGDIR/goals"
  write_cache "$id" "$block" "$n"
  if ! goal_launch "$id" "$(printf '%s' "$resp" | _goal_issue_to_goal)"; then
    launch_alert "$id" "$n"
    # don't leave a ghost active goal behind
    if { add_label "$n" goal-stopped && set_state "$n" closed; } 2>/dev/null; then
      die "registered $id (issue #$n) but the launch failed; closed it as stopped"
    fi
    die "registered $id (issue #$n) but the launch failed and I could not close it; run 'deliver.sh stop $id'"
  fi
  echo "registered $id (issue #$n)"
  echo "log=$PIPE/goal-$id.log"
}

cmd_status() {
  local want="" reg g rows total closed spec id n
  if [ -n "${1:-}" ]; then want=$(_goal_resolve "$1") || want="$1"; fi
  reg=$(_goal_registry_json) || die "cannot read the goal registry"
  n=0
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    id=$(printf '%s' "$g" | jq -r .id)
    if [ -n "$want" ] && [ "$id" != "$want" ]; then continue; fi
    spec=$(printf '%s' "$g" | jq -r .spec)
    if rows=$(_goal_scope_rows "$spec" "$id" 2>/dev/null); then
      total=$(printf '%s\n' "$rows" | grep -c . || true)
      closed=$(printf '%s\n' "$rows" | grep -c "$(printf '\t')closed\$" || true)
    else
      total="?"; closed="?"
    fi
    printf '%s  %s  host=%s  %s  %s/%s\n' "$id" "$spec" "$(printf '%s' "$g" | jq -r .host)" "$(goal_state_label "$g")" "$closed" "$total"
    n=$((n + 1))
  done <<< "$(printf '%s' "$reg" | jq -c '.[]')"
  [ "$n" -gt 0 ] || echo "no goals"
}

cmd_stop() {
  local id g issue st host istate
  id=$(_goal_resolve "${1:?goal or id required}") || die "goal not found: $1"
  g=$(_goal_find "$id") || die "goal not found: $id"
  issue=$(printf '%s' "$g" | jq -r .issue); st=$(printf '%s' "$g" | jq -r .st); host=$(printf '%s' "$g" | jq -r .host)
  istate=$(printf '%s' "$g" | jq -r .state)
  # kill locally first: the kill switch must work even when a GitHub write fails
  if [ "$st" != delivered ] && [ "$host" = "$THIS_HOST" ]; then
    goal_kill "$id"
    mkdir -p "$PIPE"; touch "$PIPE/goal-$id.stopped"
  fi
  # gate the writes on the registry issue's own state: it is closed last, so open means the stop is not finished
  if [ "$istate" = open ]; then
    ensure_label goal-stopped
    add_label "$issue" goal-stopped
    post_note "$issue" "**[deliver] NOTE** stopped by $THIS_HOST"
    set_state "$issue" closed
    # registry write landed: mark the local stop as confirmed (goal_sync only lifts a confirmed .stopped)
    [ "$host" = "$THIS_HOST" ] && echo registry > "$PIPE/goal-$id.stopped" 2>/dev/null
    echo "stopped $id (issue #$issue)"
  else
    echo "$id is already $st"
  fi
}

cmd_resume() {
  local arg="" here=0 a id g issue st host spec block
  for a in "$@"; do if [ "$a" = "--here" ]; then here=1; else arg="$a"; fi; done
  [ -n "$arg" ] || die "goal or id required"
  id=$(_goal_resolve "$arg") || die "goal not found: $arg"
  g=$(_goal_find "$id") || die "goal not found: $id"
  issue=$(printf '%s' "$g" | jq -r .issue); st=$(printf '%s' "$g" | jq -r .st)
  host=$(printf '%s' "$g" | jq -r .host); spec=$(printf '%s' "$g" | jq -r .spec); block=$(printf '%s' "$g" | jq -c .block)
  case "$st" in
    delivered) die "$id is delivered; register a new goal instead" ;;
    unreadable) die "cannot read the registry block of $id; fix or close its issue by hand" ;;
    active|waiting_jp) echo "$id is already $st"; return 0 ;;
  esac
  check_overlap "$spec" "$id" "$issue"
  set_state "$issue" open
  del_label "$issue" goal-stopped; del_label "$issue" goal-held
  rm -f "$PIPE/goal-$id".stopped "$PIPE/goal-$id".held "$PIPE/goal-$id".restarts "$PIPE/goal-$id".np "$PIPE/goal-$id".snap
  if [ "$here" = 1 ] && [ "$host" != "$THIS_HOST" ]; then
    block=$(printf '%s' "$block" | jq -c --arg h "$THIS_HOST" '.host = $h')
    api_json PATCH "repos/$GOAL_REGISTRY_REPO/issues/$issue" \
      "$(jq -nc --arg b "$(body_for "$spec" "$block")" '{body:$b}')" >/dev/null
    host="$THIS_HOST"
  fi
  echo "resumed $id (issue #$issue)"
  if [ "$host" = "$THIS_HOST" ]; then
    write_cache "$id" "$block" "$issue"
    mkdir -p "$LOGDIR/goals"
    if ! goal_launch "$id"; then
      # same rollback as register: don't leave a reopened goal reading active with nothing running
      if { add_label "$issue" goal-stopped && set_state "$issue" closed; } 2>/dev/null; then
        die "resumed $id but the launch failed; closed it as stopped"
      fi
      die "resumed $id but the launch failed and I could not close it; run 'deliver.sh stop $id'"
    fi
    echo "log=$PIPE/goal-$id.log"
  else
    echo "pinned to $host; run 'deliver.sh resume $id --here' to run it here"
  fi
}

case "${1:-}" in
  status) shift; cmd_status "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  ''|-h|--help) sed -n '2,10p' "$0"; exit 2 ;;
  *) cmd_register "$@" ;;
esac
