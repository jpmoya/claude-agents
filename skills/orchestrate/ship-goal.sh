#!/bin/bash
# ship-goal.sh — the ledger of "ship to prod" requests (JP, 2026-11-16). A ship goal is open until verify-shipped.sh says every
# PR is on origin/main and the prod deploy is green; hooks/ship-goal-guard.sh refuses to end a turn while one is open.
#
#   ship-goal.sh start <name> <owner/repo> [--no-deploy] <PR#...>   open a goal
#   ship-goal.sh check [<name>]                                     verify one (or every open) goal, print the result
#   ship-goal.sh done <name>                                        close it; succeeds only when verify-shipped exits 0
#   ship-goal.sh cancel <name> [reason]                             close without verifying (JP dropped it)
#   ship-goal.sh list                                               one line per goal
#
# State: $SHIP_GOALS_DIR (default ~/.claude/state/ship-goals)/<name>.json. Env (tests): SHIP_GOALS_DIR, SHIP_VERIFY (the
# verify-shipped.sh path). Exit codes of check/done: 0 verified, 1 not verified, 3 usage/tooling. bash 3.2 compatible.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DIR="${SHIP_GOALS_DIR:-$HOME/.claude/state/ship-goals}"
VERIFY="${SHIP_VERIFY:-$HERE/verify-shipped.sh}"

die() { echo "ship-goal: $*" >&2; exit 3; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
file_of() { printf '%s/%s.json' "$DIR" "$1"; }
valid_name() { case "$1" in ''|*[!A-Za-z0-9._-]*|.*) return 1 ;; esac; return 0; }
command -v jq >/dev/null 2>&1 || die "jq is required"

# run_verify <file> -> prints verify output, records last_check, returns 0 verified / 1 not verified
run_verify() {
  local f=$1 repo prs nodeploy out rc args summary
  repo=$(jq -r .repo "$f"); prs=$(jq -r '.prs | map(tostring) | join(" ")' "$f"); nodeploy=$(jq -r '.no_deploy // false' "$f")
  args=""; [ "$nodeploy" = true ] && args="--no-deploy"
  # shellcheck disable=SC2086
  out=$(bash "$VERIFY" "$repo" $args $prs 2>&1); rc=$?
  printf '%s\n' "$out"
  summary=$(printf '%s' "$out" | grep -v '^deploy:' | grep -v ': SHIPPED$' | head -n 3 | tr '\n' ' ' | cut -c1-300)
  [ -n "$summary" ] || summary="all SHIPPED"
  jq -c --argjson ts "$(date +%s)" --argjson rc "$rc" --arg s "$summary" '.last_check = {ts: $ts, rc: $rc, summary: $s}' "$f" > "$f.tmp" 2>/dev/null \
    && mv "$f.tmp" "$f" || rm -f "$f.tmp"
  [ "$rc" -eq 0 ]
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  start)
    name=${1:-}; repo=${2:-}; [ $# -ge 3 ] || die "usage: start <name> <owner/repo> [--no-deploy] <PR#...>"
    shift 2
    valid_name "$name" || die "bad goal name '$name' (letters, digits, . _ -)"
    case "$repo" in */*) ;; *) die "bad repo '$repo'" ;; esac
    nodeploy=false; prs=""
    for a in "$@"; do
      case "$a" in
        --no-deploy) nodeploy=true ;;
        *) n=${a#\#}; case "$n" in ''|*[!0-9]*) die "bad PR number '$a'" ;; esac; prs="$prs $n" ;;
      esac
    done
    [ -n "$prs" ] || die "no PR numbers given"
    mkdir -p "$DIR" || die "cannot create $DIR"
    f=$(file_of "$name")
    if [ -f "$f" ] && [ "$(jq -r .status "$f" 2>/dev/null)" = open ]; then die "ship goal '$name' is already open (cancel it first)"; fi
    jq -nc --arg name "$name" --arg repo "$repo" --arg ts "$(now_iso)" --argjson nd "$nodeploy" --arg prs "$prs" \
      '{name:$name, repo:$repo, prs:($prs | split(" ") | map(select(. != "") | tonumber)), no_deploy:$nd, status:"open", started:$ts, blocks:[]}' > "$f.tmp" \
      && mv "$f.tmp" "$f" || die "cannot write $f"
    echo "ship goal '$name' open: $repo PRs$prs (a turn cannot end until: ship-goal.sh done $name)" ;;
  check)
    rc=0; found=0
    if [ -n "${1:-}" ]; then files=$(file_of "$1"); [ -f "$files" ] || die "no ship goal '$1'"
    else files=$(ls "$DIR"/*.json 2>/dev/null); fi
    for f in $files; do
      [ -f "$f" ] || continue
      [ "$(jq -r .status "$f" 2>/dev/null)" = open ] || { [ -z "${1:-}" ] && continue; }
      found=1; echo "== ship goal $(jq -r .name "$f") ($(jq -r .repo "$f"))"
      run_verify "$f" || rc=1
    done
    [ "$found" = 1 ] || echo "no open ship goals"
    exit $rc ;;
  done)
    [ -n "${1:-}" ] || die "usage: done <name>"
    f=$(file_of "$1"); [ -f "$f" ] || die "no ship goal '$1'"
    if run_verify "$f"; then
      jq -c --arg ts "$(now_iso)" '.status = "done" | .verified_at = $ts' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      echo "ship goal '$1' done: verified on main with a green prod deploy"
    else
      echo "ship goal '$1' NOT done: not verified (see above)" >&2; exit 1
    fi ;;
  cancel)
    [ -n "${1:-}" ] || die "usage: cancel <name> [reason]"
    f=$(file_of "$1"); [ -f "$f" ] || die "no ship goal '$1'"
    jq -c --arg ts "$(now_iso)" --arg r "${2:-}" '.status = "cancelled" | .cancelled_at = $ts | .reason = $r' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "ship goal '$1' cancelled" ;;
  list)
    for f in "$DIR"/*.json; do
      [ -f "$f" ] || continue
      jq -r '"\(.name)\t\(.status)\t\(.repo) \(.prs | map("#\(.)") | join(" "))\t\(.last_check.summary // "not checked yet")"' "$f"
    done ;;
  *) echo "usage: ship-goal.sh start|check|done|cancel|list (see the header)" >&2; exit 3 ;;
esac
