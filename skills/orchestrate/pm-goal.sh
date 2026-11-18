#!/bin/bash
# Launch gate for the product-manager (skills/pm-goal-assignment). Every ticket belongs to a goal; the LAUNCHER resolves
# it before the PM starts, the PM never asks anyone.
#   pm-goal.sh require "<prompt>"      exit 0 when the prompt carries a `Goal: <goal id>` or `Goal: none-confirmed-by-JP` line;
#                                      exit 2 with a one-line refusal on stderr otherwise
#   pm-goal.sh feedback <owner/repo>   print the id of the repo's live staff-feedback goal (registry read; repo slugs compared
#                                      through _goal_same_repo, so a renamed repo still matches); exit 3 when there is none,
#                                      exit 4 when the registry cannot be read
#   pm-goal.sh ticket <owner/repo> <N> print the `Goal:` line of an existing ticket's body; exit 3 when it has none
# Goal ids are the first column of `deliver.sh status`. The id grammar is the same one stage-run.sh enforces for a
# product-manager stage: a token of [A-Za-z0-9._-] starting with a letter or digit.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PM_GOAL_RE='(^|[[:space:]])Goal: [A-Za-z0-9][A-Za-z0-9._-]*'

pm_goal_require() {  # <prompt text>
  if printf '%s\n' "$1" | grep -Eq "$PM_GOAL_RE"; then return 0; fi
  echo "pm-goal.sh: refusing to start the product-manager: no 'Goal: <goal id>' line in the launch prompt (the launcher must resolve the goal first, or ask JP; 'Goal: none-confirmed-by-JP' only when JP said so)" >&2
  return 2
}

case "${1:-}" in
  require) pm_goal_require "${2:-}"; exit $? ;;
  feedback|ticket) ;;
  *) echo "usage: pm-goal.sh require <prompt> | feedback <owner/repo> | ticket <owner/repo> <N>" >&2; exit 64 ;;
esac

source "$HERE/config.sh"
source "$HERE/pipeline-lib.sh"
source "$HERE/../../hooks/pipeline-markers.sh" 2>/dev/null || source "$HOME/.claude/hooks/pipeline-markers.sh"
source "$HERE/goal-lib.sh"

case "$1" in
  feedback)
    target="${2:-}"; [ -n "$target" ] || { echo "usage: pm-goal.sh feedback <owner/repo>" >&2; exit 64; }
    reg=$(_goal_registry_json) || exit 4
    rows=$(printf '%s' "$reg" | jq -r '.[] | select(.st == "queued" or .st == "active" or .st == "held" or .st == "waiting_jp") | select((.spec // "") != "") | "\(.id)\t\(.spec)"') || exit 4
    while IFS=$'\t' read -r gid gspec; do
      [ -n "$gid" ] || continue
      IFS=$'\t' read -r grepo gkind _ <<< "$(goal_parse "$gspec" 2>/dev/null || true)"
      [ "$gkind" = fb ] || continue
      _goal_same_repo "$grepo" "$target" && { printf '%s\n' "$gid"; exit 0; }
    done <<< "$rows"
    exit 3 ;;
  ticket)
    body=$(gh issue view "${3:-0}" --repo "${2:-}" --json body --jq .body 2>/dev/null) || exit 4
    line=$(printf '%s\n' "$body" | grep -E '^Goal: [A-Za-z0-9][A-Za-z0-9._-]*[[:space:]]*$' | head -1 | sed -E 's/^Goal: //; s/[[:space:]]+$//')
    [ -n "$line" ] || exit 3
    printf '%s\n' "$line" ;;
esac
