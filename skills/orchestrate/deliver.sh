#!/bin/bash
# Goal-bound delivery lead launcher / operator CLI (#193). A goal is a registry issue on GitHub; this registers it.
# Registration only ENQUEUES the goal (#320): the supervisor starts its delivery lead when it is the goal's turn and a
# host has capacity. Keep-alive and completion are the supervisor's job (#195).
# Usage:
#   deliver.sh <goal> [--now] [--host <hostname>] [--hosts both|mac|vm] [--priority <n>] [instructions...]
#                                         --hosts (default both): both = the goal's tickets run on either machine (one lead only); mac|vm = whole goal on that machine
#                                         register (state queued). <goal> = owner/repo:milestone:<number|exact title>
#                                         | owner/repo:milestones:all | owner/repo:feedback | owner/repo#N
#                                         --now: also launch one cycle here at once (hand use, skips the queue)
#                                         (GOAL_SERIAL=1, one goal at a time: a --now goal that does not hold the slot returns to the queue after that cycle)
#                                         --priority N / --after <goal> / --before <goal>: where it goes in the start order (default: last)
#                                         --host: pin the goal to that host (advisory for single tickets, see delivery-lead.md)
#   deliver.sh --repos a/b,c/d --title "<title>" [--requirements owner/repo#N] [--include-sentry] [--mockups review|skip] [--now] [--host <hostname>] [--priority <n>] [instructions...]
#                                         cross-repo goal (#319): a `goal: <short title>` label in every repo; also
#                                         deliver.sh "label:<exact label>" --repos a/b,c/d ... to bind an existing label
#   deliver.sh status [goal|id]           one line per registry goal (open, plus closed within 7 days)
#   deliver.sh project <goal|id|all>      bind/sync the goal's existing GitHub Project (--create: make one if none binds; Mac / a host whose gh token has the project scope; register and the supervisor sync do it too)
#   deliver.sh stop <goal|id>             label goal-stopped, close the registry issue, kill the local cycle (idempotent);
#                                         its open tickets stay out of the feedback goal until `release` (#527)
#   deliver.sh release <goal|id>          hand a stopped goal's held tickets back to the feedback goal (#527)
#   deliver.sh resume <goal|id> [--here]  reopen a stopped/held goal; --here re-pins it to this host
#   deliver.sh priority <goal|id> <n> | --after <goal> | --before <goal>   move a goal in the start order
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/config.sh"
source "$HERE/pipeline-lib.sh"
source "$HERE/../../hooks/pipeline-markers.sh" 2>/dev/null || source "$HOME/.claude/hooks/pipeline-markers.sh"
source "$HERE/goal-lib.sh"

# goal_err (goal-lib.sh) logs through the supervisor's slog; here it goes to stderr
type slog >/dev/null 2>&1 || slog() { echo "$*" >&2; }
type report_status_async >/dev/null 2>&1 || report_status_async() { :; }
HOST=$(pipeline_host)

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

# check_overlap <spec> <id> [exclude registry issue number] [repos csv, label goals] [extra ticket refs, one per line]
# dies naming the live goal that conflicts. Live = open registry goal (active, held or waiting on JP); judged from the
# registry, never the local cache. Label goals (#319): overlap = the same label name, or a shared ticket. A feedback goal
# (#517) only conflicts with itself: its scope yields every ticket another live goal covers. Repos are compared through
# _goal_same_repo (#527): a goal stored under a pre-rename slug (Benjis-Plants/scheduler) is the same repo as one under the
# new slug, for the repo test, the milestones:all test and the shared-ticket test; a name that cannot be resolved refuses.
check_overlap() {
  local spec="$1" id="$2" skip="${3:-}" repos="${4:-}" extra="${5:-}" reg regrows new_repo new_kind new_rows other row o_issue o_id o_spec o_st o_repo o_kind
  local rc r hit cand
  reg=$(_goal_registry_json) || die "cannot read the goal registry ($GOAL_REGISTRY_REPO); refusing to go on blind"
  IFS=$'\t' read -r new_repo new_kind _ <<< "$(goal_parse "$spec")"
  new_rows=$(goal_scope "$spec" "$id" "$repos") || die "cannot read the scope of $spec"
  [ -z "$extra" ] || new_rows=$(printf '%s\n%s' "$new_rows" "$extra")
  # #527: parse first; a jq error fed straight into the loop meant zero iterations, i.e. no overlap found (fail open)
  regrows=$(printf '%s' "$reg" | jq -r 'def f: if . == null or . == "" then "-" else tostring end; .[] | "\(.issue | f)\t\(.id | f)\t\(.spec | f)\t\(.st | f)"') \
    || die "cannot parse the goal registry ($GOAL_REGISTRY_REPO); refusing to go on blind"
  while IFS=$'\t' read -r o_issue o_id o_spec o_st; do
    [ -n "$o_issue" ] || continue
    [ "$o_issue" = "$skip" ] && continue
    # empty fields arrive as "-" (a tab split would collapse them); an unreadable id/state/issue fails closed
    if [ "$o_issue" = "-" ] || [ "$o_id" = "-" ] || [ "$o_st" = "-" ] || [ -z "$o_st" ]; then
      die "cannot read a live registry entry (issue #${o_issue}); refusing to go on blind"
    fi
    case "$o_st" in
      queued|active|held|waiting_jp) ;;
      unreadable) die "cannot read the registry block of $o_id (issue #$o_issue); refusing to go on blind" ;;
      *) continue ;;
    esac
    [ "$o_id" = "$id" ] && die "overlaps live goal $o_id (same goal)"
    o_repo=""; o_kind=""
    IFS=$'\t' read -r o_repo o_kind _ <<< "$(goal_parse "$o_spec" 2>/dev/null || true)"
    [ -n "$o_repo" ] || die "cannot read the stored spec of live goal $o_id; refusing to go on blind"
    # #517: a feedback goal's scope leaves out every ticket another live goal covers, so it never overlaps one: a live
    # feedback goal yields to the goal being registered, and a new one already excludes every live goal's tickets
    # ...but two feedback goals on one repo are the same goal even when their ids differ: a goal stored under the pre-rename
    # slug (Benjis-Plants/scheduler, id ..._scheduler-fb-feedback) and one registered under the new slug (benjis-ops-tool)
    # escaped the same-id check above and ran side by side, sharing one project (registry #534 / #537, 2026-10-29).
    if [ "$new_kind" = fb ] && [ "$o_kind" = fb ]; then
      rc=0; _goal_same_repo "$o_repo" "$new_repo" || rc=$?
      case "$rc" in
        0) die "overlaps live goal $o_id (the feedback goal of the same repo, $o_repo)" ;;
        1) continue ;;
        *) die "cannot tell whether live goal $o_id ($o_repo) is on $new_repo (repo name unresolvable); refusing to go on blind" ;;
      esac
    fi
    if [ "$new_kind" = fb ] || [ "$o_kind" = fb ]; then continue; fi
    if [ "$new_kind" = label ] && [ "$o_kind" = label ] && [ "$o_spec" = "$spec" ]; then
      die "overlaps live goal $o_id (same goal label)"
    fi
    if [ "$new_kind" != label ] && [ "$o_kind" != label ]; then
      rc=0; _goal_same_repo "$o_repo" "$new_repo" || rc=$?
      case "$rc" in
        0) ;;
        1) continue ;;
        *) die "cannot tell whether live goal $o_id ($o_repo) is on $new_repo (repo name unresolvable); refusing to go on blind" ;;
      esac
      if [ "$new_kind" = msall ] || [ "$o_kind" = msall ]; then die "overlaps live goal $o_id (milestones:all on $new_repo)"; fi
    elif [ "$new_kind" = label ] && [ "$o_kind" != label ]; then
      hit=0
      for r in $(printf '%s' "$repos" | tr ',' ' '); do
        rc=0; _goal_same_repo "$r" "$o_repo" || rc=$?
        case "$rc" in
          0) hit=1; break ;;
          1) ;;
          *) die "cannot tell whether live goal $o_id ($o_repo) is on $r (repo name unresolvable); refusing to go on blind" ;;
        esac
      done
      [ "$hit" = 1 ] || continue
      if [ "$o_kind" = msall ]; then die "overlaps live goal $o_id (milestones:all on $o_repo)"; fi
    fi
    other=$(goal_scope "$o_spec" "$o_id" 2>/dev/null) || die "cannot read the scope of $o_id; refusing to go on blind"
    # shared ticket = same number in the same repo, the repo compared through _goal_same_repo (old vs renamed slug)
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      if printf '%s\n' "$new_rows" | grep -qxF -- "$row"; then die "overlaps live goal $o_id (shares $row)"; fi
      while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        rc=0; _goal_same_repo "${row%%#*}" "${cand%%#*}" || rc=$?
        case "$rc" in
          0) die "overlaps live goal $o_id (shares $cand, stored as $row)" ;;
          1) ;;
          *) die "cannot tell whether $row of live goal $o_id is $cand (repo name unresolvable); refusing to go on blind" ;;
        esac
      done <<< "$(printf '%s\n' "$new_rows" | grep -E -- "#${row##*#}\$" || true)"
    done <<< "$other"
  done <<< "$regrows"
}

clear_stale_goal_state() {  # <id>: drop local stop/held/retry state left by an earlier goal of the same id (#224)
  rm -f "$PIPE/goal-$1".stopped "$PIPE/goal-$1".held "$PIPE/goal-$1".restarts "$PIPE/goal-$1".np "$PIPE/goal-$1".snap "$PIPE/goal-$1".launchfails "$PIPE/goal-$1".launch-failed \
    "$PIPE/goal-$1".yielded "$PIPE/goal-$1".launch-scope
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
    queued) echo "queued" ;;
    *)
      if [ "$host" = "$THIS_HOST" ]; then
        pid=$(cat "$PIPE/goal-$(printf '%s' "$g" | jq -r .id).pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "running pid $pid"; else echo "between cycles"; fi
      else
        echo "active on $host"
      fi ;;
  esac
}

PRIORITY=""; PLACE_MODE=""; PLACE_REF=""   # --priority N | --after X | --before X; none = last

# goal_place <self id, or "" for a goal not yet registered> <at|after|before|last> [<n | goal|id>]
# Priorities are dense: 1..n over the live goals in start order. Inserts <self> at the asked place, renumbers the
# others (a registry write only where a number changes) and prints <self>'s priority.
goal_place() {
  local self="$1" mode="$2" ref="${3:-}" reg plan line issue id prio g
  reg=$(_goal_registry_json) || die "cannot read the goal registry to place the goal"
  case "$mode" in after|before) ref=$(_goal_resolve "$ref") || die "goal not found: $3"
    printf '%s' "$reg" | jq -e --arg r "$ref" 'any(.[]; .id == $r and .st != "delivered" and .st != "stopped" and .st != "unreadable")' >/dev/null \
      || die "$ref is not a live goal; place the goal relative to a goal that has not finished" ;;
  esac
  plan=$(printf '%s' "$reg" | jq -r --arg self "$self" --arg mode "$mode" --arg ref "$ref" '
    def okey: [((.block.priority? // .block.order? // .issue) | if type == "number" then . else 1e12 end), .issue];
    [.[] | select(.st != "delivered" and .st != "stopped" and .st != "unreadable" and .id != $self)] | sort_by(okey) as $o
    | (if $mode == "last" then ($o | length)
       elif $mode == "at" then ((($ref | tonumber) - 1) | if . < 0 then 0 elif . > ($o | length) then ($o | length) else . end)
       else ($o | map(.id) | index($ref)) as $i | if $mode == "before" then $i else $i + 1 end end) as $pos
    | ($o[:$pos] + [null] + $o[$pos:] | to_entries[]
       | if .value == null then "SELF\t\(.key + 1)" else "\(.value.issue)\t\(.value.id)\t\(.key + 1)\t\(.value.block.priority? // 0)" end)') || die "cannot compute the goal order"
  while IFS=$'\t' read -r issue id prio old; do
    [ "$issue" != SELF ] || { printf '%s' "$id"; continue; }
    [ "$prio" != "$old" ] || continue
    g=$(printf '%s' "$reg" | jq -c --argjson i "$issue" '[.[] | select(.issue == $i)][0]')
    write_priority "$g" "$prio" >/dev/null || echo "warning: could not renumber $id" >&2
  done <<< "$plan"
}

# write_priority <registry goal json> <n> — the priority in the registry block and in this host's cache
write_priority() {
  local g="$1" n="$2" issue id
  issue=$(printf '%s' "$g" | jq -r .issue); id=$(printf '%s' "$g" | jq -r .id)
  g=$(printf '%s' "$g" | jq -c --argjson n "$n" '.block |= (. + {priority: $n})')
  api_json PATCH "repos/$GOAL_REGISTRY_REPO/issues/$issue" \
    "$(jq -nc --arg b "$(_goal_queue_body "$g")" '{body:$b}')" >/dev/null || return 1
  if [ -f "$PIPE/goal-$id.json" ]; then
    jq -c --argjson n "$n" '. + {priority: $n}' "$PIPE/goal-$id.json" > "$PIPE/goal-$id.json.tmp" && mv "$PIPE/goal-$id.json.tmp" "$PIPE/goal-$id.json"
  fi
}

# reg_priority -> the priority to write for the goal being registered (renumbers the others, see goal_place)
reg_priority() {
  if [ -n "$PLACE_MODE" ]; then goal_place "" "$PLACE_MODE" "$PLACE_REF"
  elif [ -n "$PRIORITY" ]; then goal_place "" at "$PRIORITY"
  else goal_place "" last; fi
}

cmd_register_args() {
  local spec="" repos="" title="" req="" sentry=0 mockups=review instr="" now=0 pin="" a hosts=both approve_all=0
  case "${1:-}" in --*|'') ;; *) spec="$1"; shift ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --repos) repos="${2:-}"; [ -n "$repos" ] || die "--repos needs a value (a/b,c/d)"; shift 2 ;;
      --title) title="${2:-}"; [ -n "$title" ] || die "--title needs a value"; shift 2 ;;
      --requirements) req="${2:-}"; [ -n "$req" ] || die "--requirements needs a value (owner/repo#N)"; shift 2 ;;
      --mockups) mockups="${2:-}"; case "$mockups" in review|skip) ;; *) die "--mockups takes review or skip" ;; esac; shift 2 ;;
      --include-sentry) sentry=1; shift ;;
      --now) now=1; shift ;;
      --approve-all) approve_all=1; shift ;;
      --priority) PRIORITY="${2:-}"; case "$PRIORITY" in ''|*[!0-9]*|0) die "--priority needs a whole number, 1 or more (1 starts first)" ;; esac; shift 2 ;;
      --after|--before) PLACE_MODE="${1#--}"; PLACE_REF="${2:-}"; [ -n "$PLACE_REF" ] || die "$1 needs a goal (spec or id)"; shift 2 ;;
      --hosts) hosts="${2:-}"; case "$hosts" in both|mac|vm) ;; *) die "--hosts takes both, mac or vm" ;; esac; shift 2 ;;
      --host) pin=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]'); [ -n "$pin" ] || die "--host needs a hostname"; shift 2 ;;
      *) instr="${instr:+$instr }$1"; shift ;;
    esac
  done
  PRIORITY=$(reg_priority) || exit 1; PLACE_MODE=""   # resolved once: the others are renumbered now
  case "$spec" in ''|label:*) [ "$approve_all" = 0 ] || die "--approve-all only applies to msall goals" ;; esac
  [ "$hosts" = both ] || case "$spec" in ''|label:*) ;; *) die "--hosts only applies to label goals" ;; esac
  case "$spec" in
    ''|label:*) cmd_register_label "$spec" "$repos" "$title" "$req" "$sentry" "$mockups" "$instr" "$now" "$pin" "$hosts" ;;
    *)
      if [ -n "$repos$title$req" ]; then die "--repos/--title/--requirements only apply to label goals"; fi
      cmd_register "$spec" "$instr" "$now" "$pin" "$sentry" "$approve_all" ;;
  esac
}

cmd_register() {
  local spec="$1" instr="$2" now="${3:-0}" pin="${4:-}" sentry="${5:-0}" approve_all="${6:-0}"
  local line repo id checkout rows block body resp n host="" kind go=false granted='[]' granted_at=""
  line=$(goal_parse "$spec") || exit 1
  repo=$(printf '%s' "$line" | cut -f1); kind=$(printf '%s' "$line" | cut -f2)
  checkout=$(_goal_checkout "$repo") || die "$repo is not in DISPATCH_REPOS; goals only run on dispatched repos"
  [ -e "$checkout/.git" ] || die "checkout $checkout for $repo is not a git checkout"
  id=$(goal_id "$spec") || exit 1
  rows=$(_goal_scope_rows "$spec") || die "cannot read the scope of $spec"
  [ -n "$rows" ] || die "empty scope: $spec has no tickets; a goal must start with at least one"
  check_overlap "$spec" "$id"
  [ "$now" = 1 ] && host="$THIS_HOST"   # queued goals have no host until the supervisor starts them (#320)
  block=$(jq -nc --arg id "$id" --arg spec "$spec" --arg host "$host" --arg pin "$pin" --arg created "$(now_utc)" --arg ins "$instr" \
    --argjson prio "$PRIORITY" --arg name "$(goal_name_for "$spec" 2>/dev/null)" \
    '{v:1,id:$id,spec:$spec,host:$host,host_pref:$pin,priority:$prio,created:$created,instructions:$ins} + (if $name != "" then {title:$name} else {} end)')
  # #410: registering the goal is JP's go. It is recorded in the block (go/granted/granted_at), which every body rewrite keeps.
  if [ "$kind" = fb ]; then
    echo "no go granted: $spec only clears technical blocks; feedback tickets keep their own intake/PM approval" >&2
  elif [ "$kind" = msall ] && [ "$approve_all" != 1 ]; then
    echo "no go granted: $spec covers every open milestone; re-register with --approve-all to give agent-go to all of them" >&2
  else
    go=true; granted_at=$(date -u +%F)
    block=$(printf '%s' "$block" | jq -c --argjson s "$([ "$sentry" = 1 ] && echo true || echo false)" '. + {include_sentry:$s}')
  fi
  # go:true is in the create body, so a failed grant or launch can never leave agent-go labels without a live goal
  [ "$go" = true ] && block=$(printf '%s' "$block" | jq -c --arg d "$granted_at" '. + {go:true, granted:[], granted_at:$d}')
  body=$(body_for "$spec" "$block")
  ensure_label delivery-goal
  [ "$now" = 1 ] || ensure_label goal-queued
  resp=$(api_json POST "repos/$GOAL_REGISTRY_REPO/issues" \
    "$(jq -nc --arg t "Goal: $spec" --arg b "$body" --argjson now "$now" \
       '{title:$t, body:$b, labels:(["delivery-goal"] + (if $now == 1 then [] else ["goal-queued"] end))}')") \
    || die "could not create the registry issue"
  n=$(printf '%s' "$resp" | jq -r .number)
  if [ "$go" = true ]; then
    granted=$(_goal_grant_scope "$spec" "$id" "$sentry" '[]') \
      || goal_err "cannot grant go on every in-scope ticket of $id"
    block=$(printf '%s' "$block" | jq -c --argjson g "${granted:-[]}" '.granted = $g')
    # non-fatal: the goal sync reconciles a missed record (already-labelled tickets are recorded without re-adding)
    api_json PATCH "repos/$GOAL_REGISTRY_REPO/issues/$n" \
      "$(jq -nc --arg b "$(body_for "$spec" "$block")" '{body:$b}')" >/dev/null \
      || goal_err "could not record the granted tickets of $id; the next goal sync reconciles them"
  fi
  clear_stale_goal_state "$id"   # #224: a re-registered goal keeps its id, so it must not inherit the old goal's stop/held files
  [ "$kind" = fb ] || fb_yield_here   # #527: the new goal is live: a feedback lead running here over its tickets ends now
  if [ "$now" != 1 ]; then register_project "$resp"; echo "queued $id (issue #$n)"; return 0; fi
  mkdir -p "$LOGDIR/goals"
  write_cache "$id" "$block" "$n"
  register_project "$resp"   # before the lead starts, so its brief names the project it is pinned to
  if ! goal_launch "$id" "$(launch_goal_for "$id" "$n" "$resp")"; then
    launch_alert "$id" "$n"
    # don't leave a ghost active goal behind
    if [ "$go" = true ]; then   # take the dispatchable labels back with the goal
      local gr; for gr in $(printf '%s' "$granted" | jq -r '.[]' 2>/dev/null); do
        _goal_issue_label_del "${gr%%#*}" "${gr##*#}" agent-go 2>/dev/null || true
      done
    fi
    if { add_label "$n" goal-stopped && set_state "$n" closed; } 2>/dev/null; then
      die "registered $id (issue #$n) but the launch failed; closed it as stopped"
    fi
    die "registered $id (issue #$n) but the launch failed and I could not close it; run 'deliver.sh stop $id'"
  fi
  echo "registered $id (issue #$n)"
  echo "log=$PIPE/goal-$id.log"
}

# launch_goal_for <id> <issue n> <POST response> — the goal to launch. The registry read is used only when it is the issue just
# created (keeps the project binding); a lagging list returns a closed same-id predecessor, so otherwise use the POST response (#440).
launch_goal_for() {
  local g
  g=$(_goal_find "$1" 2>/dev/null) || g=""
  if [ -n "$g" ] && [ "$(printf '%s' "$g" | jq -r '.issue // empty' 2>/dev/null)" = "$2" ]; then printf '%s\n' "$g"; return 0; fi
  printf '%s' "$3" | _goal_issue_to_goal
}

# register_project <registry issue JSON> — the goal's GitHub Project (goal-project.sh): created, linked, recorded in the registry block,
# tickets added. Best effort: skipped without the `project` scope, any error is only logged, never fails the register.
register_project() {
  local g
  g=$(printf '%s' "$1" | _goal_issue_to_goal 2>/dev/null) || return 0
  [ -n "$g" ] || return 0
  goal_project_sync_one "$g" create >/dev/null 2>&1 || true
  return 0
}

# register_rollback <registry issue> <message> — don't leave a ghost active goal behind
register_rollback() {
  if { add_label "$1" goal-stopped && set_state "$1" closed; } 2>/dev/null; then die "$2; closed registry issue #$1 as stopped"; fi
  die "$2, and I could not close registry issue #$1; run 'deliver.sh stop' on it"
}

# cmd_register_label — a cross-repo goal (#319): the label "goal: <short title>" in every repo + the registry issue.
cmd_register_label() {
  local spec=$1 repos_in=$2 title=$3 req=$4 sentry=$5 mockups=$6 instr=$7 now=${8:-0} pin=${9:-} hosts=${10:-both} host=""
  local label id r kept="" checkout seed_ok=0 req_ok=0 seed_repo="" seed_n="" rows block body resp n url room desc
  local granted='[]' granted_at="" go=false repos_json out
  [ -n "$repos_in" ] || die "a label goal needs --repos owner/repo,owner/repo"
  if [ -z "$spec" ]; then
    [ -n "$title" ] || die "--title is required when no label: spec is given"
    label=$(goal_label_name "$title") || exit 1
  else
    label="${spec#label:}"
    [ -n "$title" ] || title="${label#goal: }"
  fi
  [ "${#label}" -le 43 ] || die "label '$label' is longer than 43 chars; \"$label (done)\" would not fit GitHub's 50-char limit"
  spec="label:$label"
  for r in $(printf '%s' "$repos_in" | tr ',' ' '); do
    [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "malformed repo '$r' in --repos (want owner/repo)"
    if _goal_is_bi "$r"; then echo "skipping $r: Business-Intelligence is never part of a goal" >&2; continue; fi
    checkout=$(_goal_checkout "$r") || die "$r is not in DISPATCH_REPOS; goals only run on dispatched repos"
    [ -e "$checkout/.git" ] || die "checkout $checkout for $r is not a git checkout"
    case ",$kept," in *",$r,"*) ;; *) kept="${kept:+$kept,}$r" ;; esac
  done
  [ -n "$kept" ] || die "no repo left in --repos"
  repos_json=$(printf '%s' "$kept" | jq -Rc 'split(",")')
  if [ -n "$req" ]; then
    case "$req" in */*#[0-9]*) ;; *) die "malformed --requirements '$req' (want owner/repo#N)" ;; esac
    seed_repo="${req%%#*}"; seed_n="${req##*#}"
    case ",$kept," in *",$seed_repo,"*) ;; *) die "--requirements ticket $req is not in one of the goal's repos" ;; esac
    if gh api "repos/$seed_repo/issues/$seed_n" >/dev/null 2>&1; then seed_ok=1; fi
    if goal_requirements_ok "$req"; then req_ok=1; else echo "no go granted: requirements ticket $req is missing or empty" >&2; fi
  else
    echo "no go granted: no --requirements ticket given (go needs a non-empty requirements ticket)" >&2
  fi
  id=$(goal_id "$spec") || exit 1
  check_overlap "$spec" "$id" "" "$kept" "$([ "$seed_ok" = 1 ] && printf '%s' "$req")"
  rows=$(_goal_scope_rows "$spec" "$id" "$kept") || die "cannot read the scope of $spec"
  { [ -n "$rows" ] || [ "$seed_ok" = 1 ]; } || die "empty scope: no ticket carries '$label' and there is no requirements ticket to label; a goal must start with at least one"
  [ "$now" = 1 ] && host="$THIS_HOST"   # queued goals have no host until the supervisor starts them (#320)
  block=$(jq -nc --arg id "$id" --arg spec "$spec" --arg host "$host" --arg pin "$pin" --arg created "$(now_utc)" --arg ins "$instr" \
    --arg title "$title" --arg label "$label" --argjson repos "$repos_json" --arg mockups "$mockups" --arg req "$req" --arg hosts "$hosts" \
    --argjson sentry "$([ "$sentry" = 1 ] && echo true || echo false)" --argjson prio "$PRIORITY" \
    '{v:2,id:$id,title:$title,label:$label,repos:$repos,order:0,priority:$prio,mockups:$mockups,go:false,host_pref:$pin,hosts:$hosts,requirements:$req,
      include_sentry:$sentry,spec:$spec,host:$host,created:$created,instructions:$ins}')
  ensure_label delivery-goal
  [ "$now" = 1 ] || ensure_label goal-queued
  resp=$(api_json POST "repos/$GOAL_REGISTRY_REPO/issues" \
    "$(jq -nc --arg t "Goal: $title" --arg b "$(goal_body_v2 "$block" "")" --argjson now "$now" \
       '{title:$t, body:$b, labels:(["delivery-goal"] + (if $now == 1 then [] else ["goal-queued"] end))}')") \
    || die "could not create the registry issue"
  n=$(printf '%s' "$resp" | jq -r .number)
  clear_stale_goal_state "$id"   # #224: a re-registered goal keeps its id, so it must not inherit the old goal's stop/held files
  # the label: full title (cut to fit) then the registry issue URL, same colour in every repo
  url="https://github.com/$GOAL_REGISTRY_REPO/issues/$n"
  room=$((100 - ${#url} - 1))
  desc="${title:0:$room} $url"
  for r in $(printf '%s' "$kept" | tr ',' ' '); do
    out=$(gh api -X POST "repos/$r/labels" -f "name=$label" -f "color=$GOAL_LABEL_COLOR" -f "description=$desc" 2>&1) \
      || gh api "repos/$r/labels/$(_goal_uri "$label")" >/dev/null 2>&1 \
      || { goal_err "cannot create the goal label in $r"; register_rollback "$n" "could not create the goal label in $r"; }
  done
  if [ "$seed_ok" = 1 ]; then
    _goal_issue_label_add "$seed_repo" "$seed_n" "$label" || register_rollback "$n" "could not label the requirements ticket $req"
  fi
  if [ "$req_ok" = 1 ]; then
    go=true; granted_at=$(date -u +%F)
    # shellcheck disable=SC2046
    granted=$(_goal_grant_go "$label" "$sentry" '[]' $(printf '%s' "$kept" | tr ',' ' ')) \
      || echo "some tickets could not be given agent-go; the next goal sync retries them" >&2
  fi
  block=$(printf '%s' "$block" | jq -c --argjson n "$n" --argjson go "$go" --argjson g "${granted:-[]}" --arg d "$granted_at" \
    '. + {order:$n, go:$go, granted:$g} + (if $d != "" then {granted_at:$d} else {} end)')
  resp=$(api_json PATCH "repos/$GOAL_REGISTRY_REPO/issues/$n" \
    "$(jq -nc --arg b "$(goal_body_v2 "$block" "$granted_at")" '{body:$b}')") || register_rollback "$n" "could not write the registry block"
  fb_yield_here   # #527: the new goal is live: a feedback lead running here over its tickets ends now
  if [ "$go" = true ]; then
    post_note "$n" "**[supervisor] NOTE** go granted: label \`$label\` on the requirements ticket, agent-go on $(printf '%s' "$granted" | jq 'length') open ticket(s) in $kept" || true

  fi
  if [ "$now" != 1 ]; then
    register_project "$resp"
    echo "queued $id (issue #$n)"
    echo "label=$label repos=$kept go=$go"
    return 0
  fi
  mkdir -p "$LOGDIR/goals"
  write_cache "$id" "$block" "$n"
  register_project "$resp"   # before the lead starts, so its brief names the project it is pinned to
  if ! goal_launch "$id" "$(launch_goal_for "$id" "$n" "$resp")"; then
    launch_alert "$id" "$n"
    register_rollback "$n" "registered $id but the launch failed"
  fi
  echo "registered $id (issue #$n)"
  echo "label=$label repos=$kept go=$go"
  echo "log=$PIPE/goal-$id.log"
}

# cmd_project <goal|id|all> [--create] — bind and sync the goal's existing GitHub Project (goal-project.sh): a "Goal: ..." project that is
# this goal's (never creates one unless --create; register creates); add every ticket; mirror Status; close it for a delivered/stopped goal.
cmd_project() {
  local arg="${1:?goal, id or all required}" reg g id n=0 p mode=bind
  [ "${2:-}" != --create ] || mode=create
  goal_project_enabled || die "this host's gh token lacks the project scope (run: gh auth refresh -s project) or GOAL_PROJECTS=0; run it on the Mac"
  reg=$(_goal_registry_json) || die "cannot read the goal registry"
  if [ "$arg" != all ]; then id=$(_goal_resolve "$arg") || die "goal not found: $arg"; fi
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    [ "$arg" = all ] || [ "$(printf '%s' "$g" | jq -r .id)" = "$id" ] || continue
    [ "$(printf '%s' "$g" | jq -r .st)" != unreadable ] || continue
    if [ "$arg" = all ] && [ "$(printf '%s' "$g" | jq -r .state)" != open ]; then continue; fi
    goal_project_sync_one "$g" "$mode" || echo "warning: project sync of $(printf '%s' "$g" | jq -r .id) had errors (see the log)" >&2
    p=$(_goal_find "$(printf '%s' "$g" | jq -r .id)" 2>/dev/null | jq -r '.block.project.url? // "no project"')
    printf '%s  %s\n' "$(printf '%s' "$g" | jq -r .id)" "$p"
    n=$((n + 1))
  done <<< "$(printf '%s' "$reg" | jq -c '.[]')"
  [ "$n" -gt 0 ] || die "goal not found: $arg"
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
    printf '%s  %s  host=%s  %s  %s/%s%s\n' "$id" "$spec" "$(printf '%s' "$g" | jq -r .host)" "$(goal_state_label "$g")" "$closed" "$total" \
      "$(printf '%s' "$g" | jq -r 'if (.block.priority? | type) == "number" then "  priority=\(.block.priority)" else "" end')"
    n=$((n + 1))
  done <<< "$(printf '%s' "$reg" | jq -c '.[]')"
  [ "$n" -gt 0 ] || echo "no goals"
}

# cmd_priority <goal|id> <n> — change a registered goal's priority (1 starts first); takes effect at the next supervisor sync
cmd_priority() {
  local id g n mode=at ref=""
  id=$(_goal_resolve "${1:?goal or id required}") || die "goal not found: $1"
  case "${2:-}" in
    --after|--before) mode="${2#--}"; ref="${3:-}"; [ -n "$ref" ] || die "$2 needs a goal (spec or id)" ;;
    ''|*[!0-9]*|0) die "usage: deliver.sh priority <goal|id> <n> | --after <goal> | --before <goal>" ;;
    *) ref="$2" ;;
  esac
  g=$(_goal_find "$id") || die "goal not found: $id"
  [ "$(printf '%s' "$g" | jq -r .state)" = open ] || die "$id is closed; its priority cannot change"
  [ "$(printf '%s' "$g" | jq -r .st)" != unreadable ] || die "cannot read the registry block of $id"
  [ "$mode" = at ] || [ "$(_goal_resolve "$ref")" != "$id" ] || die "a goal cannot go before or after itself"
  n=$(goal_place "$id" "$mode" "$ref") || exit 1
  write_priority "$g" "$n" || die "could not write the registry block"
  post_note "$(printf '%s' "$g" | jq -r .issue)" "**[deliver] NOTE** priority set to $n by $THIS_HOST" || true
  echo "$id priority $n"
}

cmd_stop() {
  local id g issue st host istate spec hold n_held
  id=$(_goal_resolve "${1:?goal or id required}") || die "goal not found: $1"
  g=$(_goal_find "$id") || die "goal not found: $id"
  issue=$(printf '%s' "$g" | jq -r .issue); st=$(printf '%s' "$g" | jq -r .st); host=$(printf '%s' "$g" | jq -r .host)
  istate=$(printf '%s' "$g" | jq -r .state); spec=$(printf '%s' "$g" | jq -r .spec)
  # kill locally first: the kill switch must work even when a GitHub write fails
  if [ "$st" != delivered ] && [ "$host" = "$THIS_HOST" ]; then
    goal_kill "$id"
    mkdir -p "$PIPE"; touch "$PIPE/goal-$id.stopped"
  fi
  # gate the writes on the registry issue's own state: it is closed last, so open means the stop is not finished
  if [ "$istate" = open ]; then
    # #527: a stop never hands the goal's open tickets back to a feedback goal on its own. Record them in the block as a
    # hold BEFORE the stop lands: until the issue closes the goal is still live and covers them, so a failed write here
    # leaves nothing uncovered (re-run stop). `deliver.sh release` hands them back; a resume or a new goal covers them.
    if [ "$st" != unreadable ] && [ "$(goal_parse "$spec" 2>/dev/null | cut -f2)" != fb ]; then
      hold=$(goal_stop_hold "$spec" "$id")
      api_json PATCH "repos/$GOAL_REGISTRY_REPO/issues/$issue" \
        "$(jq -nc --arg b "$(_goal_queue_body "$(printf '%s' "$g" | jq -c --argjson h "$hold" --arg at "$(now_utc)" \
            '.block = ((.block | del(.released_at)) + {stopped_open: $h, stopped_at: $at})')")" '{body:$b}')" >/dev/null \
        || die "could not record the held tickets of $id; it is still live (registry issue #$issue open): re-run 'deliver.sh stop $id'"
      if [ "$hold" = '"unreadable"' ]; then
        echo "could not list the open tickets of $id: the feedback goal on its repo stays unreadable until 'deliver.sh release $id'" >&2
      else
        n_held=$(printf '%s' "$hold" | jq 'length')
        [ "$n_held" -eq 0 ] || echo "$n_held open ticket(s) of $id stay out of the feedback goal; 'deliver.sh release $id' hands them back" >&2
      fi
    fi
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

# cmd_release <goal|id> (#527) — JP's explicit hand-back: the open tickets a stopped goal holds (block `stopped_open`) may
# go back to the feedback goal. Every stopped registry entry of that id that still holds tickets is released.
cmd_release() {
  local id reg rows issue g n=0
  id=$(_goal_resolve "${1:?goal or id required}") || die "goal not found: $1"
  reg=$(_goal_registry_json all) || die "cannot read the goal registry ($GOAL_REGISTRY_REPO)"
  rows=$(printf '%s' "$reg" | jq -c --arg id "$id" '.[] | select(.id == $id and .st == "stopped" and ((.block.stopped_open? // null) != null))') \
    || die "cannot parse the goal registry ($GOAL_REGISTRY_REPO)"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    issue=$(printf '%s' "$g" | jq -r .issue)
    api_json PATCH "repos/$GOAL_REGISTRY_REPO/issues/$issue" \
      "$(jq -nc --arg b "$(_goal_queue_body "$(printf '%s' "$g" | jq -c --arg at "$(now_utc)" '.block = ((.block | del(.stopped_open)) + {released_at: $at})')")" '{body:$b}')" >/dev/null \
      || die "could not release the tickets held by $id (registry issue #$issue)"
    post_note "$issue" "**[deliver] NOTE** held tickets released to the feedback goal by $THIS_HOST" || true
    echo "released the tickets held by $id (issue #$issue)"
    n=$((n + 1))
  done <<< "$rows"
  [ "$n" -gt 0 ] || echo "$id holds no tickets (not stopped, stopped before #527, or already released)"
}

# fb_yield_here (#527) — a goal was just registered or resumed: a feedback lead running on this host whose cycle was
# launched with one of that goal's tickets ends now (goal_fb_yield), instead of at the next goal sync. Best effort.
fb_yield_here() {
  local f id h
  for f in "$PIPE"/goal-*.json; do
    [ -e "$f" ] || break
    id=$(basename "$f" .json); id=${id#goal-}
    h=$(jq -r '(.host // "") | ascii_downcase' "$f" 2>/dev/null)
    [ "$h" = "$(printf '%s' "$THIS_HOST" | tr '[:upper:]' '[:lower:]')" ] || continue
    goal_fb_yield "$id" || echo "could not re-read the feedback scope of $id; the next goal sync re-checks it" >&2
  done
  return 0
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
    queued|active|waiting_jp) echo "$id is already $st"; return 0 ;;
  esac
  # #419: the label is stripped only when a goal closes, so only a stopped (closed) label goal is unresumable; a held one is open
  case "$spec" in label:*) [ "$st" = stopped ] && die "$id is a label goal: its label was stripped at close; register a new goal instead" ;; esac
  check_overlap "$spec" "$id" "$issue"
  set_state "$issue" open
  del_label "$issue" goal-stopped; del_label "$issue" goal-held
  rm -f "$PIPE/goal-$id".stopped "$PIPE/goal-$id".held "$PIPE/goal-$id".restarts "$PIPE/goal-$id".np "$PIPE/goal-$id".snap "$PIPE/goal-$id".launchfails "$PIPE/goal-$id".launch-failed \
    "$PIPE/goal-$id".yielded "$PIPE/goal-$id".launch-scope
  [ "$(goal_parse "$spec" 2>/dev/null | cut -f2)" = fb ] || fb_yield_here   # #527: live again, the feedback goal yields now
  if [ -z "$host" ] && [ "$here" != 1 ]; then   # stopped while still queued (#320): back in the queue, no host yet
    add_label "$issue" goal-queued
    echo "resumed $id (issue #$issue); queued again"
    return 0
  fi
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
  priority) shift; cmd_priority "$@" ;;
  project) shift; cmd_project "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  release) shift; cmd_release "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  ''|-h|--help) sed -n '2,23p' "$0"; exit 2 ;;
  *) cmd_register_args "$@" ;;
esac
