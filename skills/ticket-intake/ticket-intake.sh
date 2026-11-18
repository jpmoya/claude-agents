#!/bin/bash
# ticket-intake.sh — the two mechanical steps of the ticket-intake skill (JP, 2026-11-18): put a ticket JP asked for into a
# registered goal's GitHub Project and give it agent-go. One command, idempotent, safe to re-run.
#
#   ticket-intake.sh goals [<owner/repo>]
#       the choices for the one question to JP: open registered goals whose scope is a GitHub Project (spec `project:<owner>/<n>`),
#       restricted to goals whose repos include <owner/repo> (a goal with no repo list fits every repo). Tab-separated:
#       <owner>/<n>  <goal name>  go=true|false|unset  <project url>. Standing feedback goals are not project-scoped and are not
#       listed (their mirror projects are not a place to add tickets): the answer for those tickets is `none`.
#   ticket-intake.sh finish <owner/repo> <issue#> (--project <owner>/<n> | --none) [--no-go <reason>]
#       --project: add the issue to that project (refused unless it is one of `goals` for the repo), then agent-go.
#       --none:    no project (standalone / feedback goal), then agent-go.
#       --no-go "<reason>": do NOT add agent-go (history-only ticket; reason required, logged).
#   agent-go is LAUNCH permission only: it never answers a JP-only gate (production, spending money, third-party systems of record,
#   deleting data, external communications, access, infra prod go, mockup approvals, risky-list migrations) — those gates still stop the run.
#
# Never touches the direct-route repo (DIRECT_ROUTE_REPOS: jpmoya/claude-agents) and never adds agent-go in Business-Intelligence
# (JP adds that one himself). Exit: 0 done / nothing to do, 2 refused (bad input, unregistered project), 3 usage or tooling,
# 4 GitHub write failed. Env (tests): TICKET_INTAKE_REGISTRY (default jpmoya/claude-agents), TICKET_INTAKE_LOG,
# TICKET_INTAKE_DIRECT_ROUTE. bash 3.2 compatible.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REGISTRY="${TICKET_INTAKE_REGISTRY:-jpmoya/claude-agents}"
LOG="${TICKET_INTAKE_LOG:-$HOME/logs/pipeline/ticket-intake.log}"

die() { echo "ticket-intake: $*" >&2; exit "${2:-3}"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
elog() { mkdir -p "$(dirname "$LOG")" 2>/dev/null; printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null; return 0; }
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v gh >/dev/null 2>&1 || die "gh is required"

direct_route_list() {
  if [ "${TICKET_INTAKE_DIRECT_ROUTE+set}" = set ]; then printf '%s\n' $TICKET_INTAKE_DIRECT_ROUTE; return; fi
  local l
  l=$(grep -E '^DIRECT_ROUTE_REPOS=\(' "$HERE/../orchestrate/config.sh" 2>/dev/null | head -n 1 | grep -oE '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+')
  printf '%s\n' "${l:-jpmoya/claude-agents}"
}
is_direct_route() { local want e; want=$(lower "$1"); for e in $(direct_route_list); do [ "$(lower "$e")" = "$want" ] && return 0; done; return 1; }

# registry_goals <owner/repo|""> -> TSV lines: <owner>/<n> \t name \t go \t url
registry_goals() {
  local raw rc
  raw=$(gh api -X GET "repos/$REGISTRY/issues" -f labels=delivery-goal -f state=open -f per_page=100 --paginate 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || { echo "ticket-intake: cannot read the goal registry $REGISTRY (gh api exit $rc)" >&2; return 1; }
  printf '%s' "$raw" | jq -rs --arg repo "$(lower "${1:-}")" '
    [ .[] | (if type == "array" then .[] else . end) ]
    | map(select(has("pull_request") | not)
          | select(any(.labels[]; .name == "goal-stopped") | not)
          | . as $i
          | ([try (($i.body // "") | capture("```json\\n(?<j>[^\\n]*)\\n```") | .j | fromjson) catch null] | .[0]) as $b
          | select($b != null and (($b.spec // "") | startswith("project:")) and ($b.scope_project.number? != null))
          | select($repo == "" or (($b.repos // []) | length == 0) or (($b.repos // []) | map(ascii_downcase) | index($repo)))
          | "\($b.scope_project.owner)/\($b.scope_project.number)\t\($i.title | sub("^Goal: "; ""))\tgo=\(if ($b.go == true) then "true" elif ($b.go == false) then "false" else "unset" end)\t\($b.scope_project.url // "")")
    | .[]'
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  goals)
    repo=${1:-}
    if [ -n "$repo" ] && is_direct_route "$repo"; then
      echo "ticket-intake: $repo is a direct-route repo: no project, no agent-go. Nothing to choose." >&2; exit 0
    fi
    rows=$(registry_goals "$repo") || exit 3
    if [ -n "$rows" ]; then printf '%s\n' "$rows"; else echo "(no open registered project goal fits${repo:+ $repo}: the answer is none)" >&2; fi
    ;;
  finish)
    repo=${1:-}; issue=${2:-}; [ $# -ge 3 ] || die "usage: finish <owner/repo> <issue#> (--project <owner>/<n> | --none) [--no-go <reason>]"
    shift 2
    project=""; none=0; nogo=0; reason=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --project) [ $# -ge 2 ] || die "--project needs <owner>/<number>"; project=$2; shift 2 ;;
        --none) none=1; shift ;;
        --no-go) nogo=1; [ $# -ge 2 ] || die "--no-go needs a reason"; reason=$2; shift 2 ;;
        *) die "unknown argument '$1'" ;;
      esac
    done
    case "$repo" in */*) ;; *) die "bad repo '$repo'" ;; esac
    issue=${issue#\#}; case "$issue" in ''|*[!0-9]*) die "bad issue number '$issue'" ;; esac
    if [ -n "$project" ] && [ "$none" = 1 ]; then die "give --project or --none, not both"; fi
    if [ -z "$project" ] && [ "$none" = 0 ]; then die "the project step is never skipped silently: give --project <owner>/<n> or --none"; fi
    if [ "$nogo" = 1 ] && [ "$(printf '%s' "$reason" | grep -oE '[A-Za-z]{2,}' | wc -l | tr -d ' ')" -lt 3 ]; then
      die "--no-go needs a reason of a few words (why this ticket must not get agent-go)" 2
    fi
    if is_direct_route "$repo"; then
      echo "ticket-intake: $repo#$issue is in a direct-route repo: no project, no agent-go (the interactive session implements it). Nothing done."
      exit 0
    fi
    info=$(gh issue view "$issue" -R "$repo" --json state,labels,url,projectItems 2>/dev/null) || die "cannot read $repo#$issue (gh issue view failed)" 3
    url=$(printf '%s' "$info" | jq -r .url)
    state=$(printf '%s' "$info" | jq -r .state)

    # ---- project ----
    pres="none"
    if [ -n "$project" ]; then
      case "$project" in */*) ;; *) die "bad project '$project' (want <owner>/<number>)" ;; esac
      powner=${project%%/*}; pnum=${project#*/}
      case "$pnum" in ''|*[!0-9]*) die "bad project number in '$project'" ;; esac
      rows=$(registry_goals "$repo") || exit 3
      goalname=$(printf '%s\n' "$rows" | awk -F'\t' -v p="$project" 'tolower($1) == tolower(p) { print $2; exit }')
      if [ -z "$goalname" ]; then
        { echo "ticket-intake: project $project is not an open registered goal's project for $repo. Registered choices:"; printf '%s\n' "$rows" | cut -f1,2,3; echo "(or use --none)"; } >&2
        exit 2
      fi
      if printf '%s' "$info" | jq -e --argjson n "$pnum" 'any((.projectItems // [])[]?; ((.project.number? // .number? // -1) == $n))' >/dev/null 2>&1; then
        pres="already in $project ($goalname)"
      else
        err=$(gh project item-add "$pnum" --owner "$powner" --url "$url" 2>&1 >/dev/null) || {
          echo "ticket-intake: could not add $repo#$issue to project $project: $err" >&2
          echo "ticket-intake: the gh token needs the project scope (gh auth refresh -s project) and write access to the project" >&2
          elog "FAIL project repo=$repo issue=$issue project=$project"
          exit 4
        }
        pres="added to $project ($goalname)"
      fi
    fi

    # ---- agent-go ----
    labels=$(printf '%s' "$info" | jq -r '[.labels[].name] | join(",")')
    case ",$labels," in *,agent-go,*) has_go=1 ;; *) has_go=0 ;; esac
    case ",$labels," in *,agent-in-progress,*) running=1 ;; *) running=0 ;; esac
    gores=""
    if [ "$nogo" = 1 ]; then
      gores="no agent-go (go=no: $reason)"
    elif [ "$(lower "${repo#*/}")" = "business-intelligence" ]; then
      gores="no agent-go (Business-Intelligence: only JP adds it)"
    elif [ "$state" != "OPEN" ]; then
      gores="no agent-go (issue is $state)"
    elif [ "$has_go" = 1 ] || [ "$running" = 1 ]; then
      gores="agent-go already there"
    else
      err=$(gh issue edit "$issue" -R "$repo" --add-label agent-go 2>&1 >/dev/null) || {
        echo "ticket-intake: could not add agent-go to $repo#$issue: $err" >&2
        elog "FAIL label repo=$repo issue=$issue"
        exit 4
      }
      gores="agent-go added"
    fi
    echo "ticket-intake: $repo#$issue ($url): project: $pres; $gores"
    case ",$labels," in *,infra,*) echo "ticket-intake: note: infra ticket, agent-go is launch permission only; every prod step still waits for JP's go on the issue" ;; esac
    elog "OK repo=$repo issue=$issue project=${project:-none} go=$([ "$nogo" = 1 ] && echo no || echo yes)${reason:+ reason=$reason}"
    ;;
  ""|-h|--help|help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; ;;
  *) die "unknown command '$cmd' (goals | finish)" ;;
esac
