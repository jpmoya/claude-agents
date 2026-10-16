#!/bin/bash
# Goal-bound delivery lead launcher / operator CLI (#193). A goal is a registry issue on GitHub; this registers it
# and starts one cycle of $GOAL_AGENT. Keep-alive and completion are the supervisor's job (#195).
# Usage:
#   deliver.sh <goal> [instructions...]   register + launch one cycle. <goal> = owner/repo:milestone:<number|exact title>
#                                         | owner/repo:milestones:all | owner/repo#N
#   deliver.sh --repos a/b,c/d --title "<title>" [--requirements owner/repo#N] [--include-sentry] [--mockups review|skip] [instructions...]
#                                         cross-repo goal (#319): a `goal: <short title>` label in every repo; also
#                                         deliver.sh "label:<exact label>" --repos a/b,c/d ... to bind an existing label
#   deliver.sh status [goal|id]           one line per registry goal (open, plus closed within 7 days)
#   deliver.sh stop <goal|id>             label goal-stopped, close the registry issue, kill the local cycle (idempotent)
#   deliver.sh resume <goal|id> [--here]  reopen a stopped/held goal; --here re-pins it to this host
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
# registry, never the local cache. Label goals (#319): overlap = the same label name, or a shared ticket.
check_overlap() {
  local spec="$1" id="$2" skip="${3:-}" repos="${4:-}" extra="${5:-}" reg new_repo new_kind new_rows other row o_issue o_id o_spec o_st o_repo o_kind
  reg=$(_goal_registry_json) || die "cannot read the goal registry ($GOAL_REGISTRY_REPO); refusing to go on blind"
  IFS=$'\t' read -r new_repo new_kind _ <<< "$(goal_parse "$spec")"
  new_rows=$(goal_scope "$spec" "$id" "$repos") || die "cannot read the scope of $spec"
  [ -z "$extra" ] || new_rows=$(printf '%s\n%s' "$new_rows" "$extra")
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
    if [ "$new_kind" = label ] && [ "$o_kind" = label ] && [ "$o_spec" = "$spec" ]; then
      die "overlaps live goal $o_id (same goal label)"
    fi
    if [ "$new_kind" != label ] && [ "$o_kind" != label ]; then
      [ "$o_repo" = "$new_repo" ] || continue
      if [ "$new_kind" = msall ] || [ "$o_kind" = msall ]; then die "overlaps live goal $o_id (milestones:all on $new_repo)"; fi
    elif [ "$new_kind" = label ] && [ "$o_kind" != label ]; then
      case ",$repos," in *",$o_repo,"*) ;; *) continue ;; esac
      if [ "$o_kind" = msall ]; then die "overlaps live goal $o_id (milestones:all on $o_repo)"; fi
    fi
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

cmd_register_args() {
  local spec="" repos="" title="" req="" sentry=0 mockups=review instr="" a
  case "${1:-}" in --*|'') ;; *) spec="$1"; shift ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --repos) repos="${2:-}"; [ -n "$repos" ] || die "--repos needs a value (a/b,c/d)"; shift 2 ;;
      --title) title="${2:-}"; [ -n "$title" ] || die "--title needs a value"; shift 2 ;;
      --requirements) req="${2:-}"; [ -n "$req" ] || die "--requirements needs a value (owner/repo#N)"; shift 2 ;;
      --mockups) mockups="${2:-}"; case "$mockups" in review|skip) ;; *) die "--mockups takes review or skip" ;; esac; shift 2 ;;
      --include-sentry) sentry=1; shift ;;
      *) instr="${instr:+$instr }$1"; shift ;;
    esac
  done
  case "$spec" in
    ''|label:*) cmd_register_label "$spec" "$repos" "$title" "$req" "$sentry" "$mockups" "$instr" ;;
    *)
      if [ -n "$repos$title$req" ] || [ "$sentry" = 1 ]; then die "--repos/--title/--requirements/--include-sentry only apply to label goals"; fi
      cmd_register "$spec" "$instr" ;;
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

# register_rollback <registry issue> <message> — don't leave a ghost active goal behind
register_rollback() {
  if { add_label "$1" goal-stopped && set_state "$1" closed; } 2>/dev/null; then die "$2; closed registry issue #$1 as stopped"; fi
  die "$2, and I could not close registry issue #$1; run 'deliver.sh stop' on it"
}

# cmd_register_label — a cross-repo goal (#319): the label "goal: <short title>" in every repo + the registry issue.
cmd_register_label() {
  local spec=$1 repos_in=$2 title=$3 req=$4 sentry=$5 mockups=$6 instr=$7
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
  block=$(jq -nc --arg id "$id" --arg spec "$spec" --arg host "$THIS_HOST" --arg created "$(now_utc)" --arg ins "$instr" \
    --arg title "$title" --arg label "$label" --argjson repos "$repos_json" --arg mockups "$mockups" --arg req "$req" \
    --argjson sentry "$([ "$sentry" = 1 ] && echo true || echo false)" \
    '{v:2,id:$id,title:$title,label:$label,repos:$repos,order:0,mockups:$mockups,go:false,host_pref:"",requirements:$req,
      include_sentry:$sentry,spec:$spec,host:$host,created:$created,instructions:$ins}')
  ensure_label delivery-goal
  resp=$(api_json POST "repos/$GOAL_REGISTRY_REPO/issues" \
    "$(jq -nc --arg t "Goal: $title" --arg b "$(goal_body_v2 "$block" "")" '{title:$t, body:$b, labels:["delivery-goal"]}')") \
    || die "could not create the registry issue"
  n=$(printf '%s' "$resp" | jq -r .number)
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
  if [ "$go" = true ]; then
    post_note "$n" "**[supervisor] NOTE** go granted: label \`$label\` on the requirements ticket, agent-go on $(printf '%s' "$granted" | jq 'length') open ticket(s) in $kept" || true

  fi
  mkdir -p "$LOGDIR/goals"
  write_cache "$id" "$block" "$n"
  if ! goal_launch "$id" "$(printf '%s' "$resp" | _goal_issue_to_goal)"; then
    launch_alert "$id" "$n"
    register_rollback "$n" "registered $id but the launch failed"
  fi
  echo "registered $id (issue #$n)"
  echo "label=$label repos=$kept go=$go"
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
  case "$spec" in label:*) die "$id is a label goal: its label was stripped at close; register a new goal instead" ;; esac
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
  *) cmd_register_args "$@" ;;
esac
