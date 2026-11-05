#!/bin/bash
# backlog-priority.sh — JP's drag-and-reorder priority for standalone (non-goal) agent-go backlog
# tickets. Lets him set the order supervisor.sh's shared-dispatch step (around line 1687) picks
# among non-goal agent-go candidates to fill an available individual-ticket slot. It does not
# change which tickets are candidates (goal filtering, GOAL_SERIAL slot semantics are untouched)
# and it never reorders a goal-labelled ticket.
#
# Source of truth is a single machine-managed GitHub issue (label backlog-priority-registry) in
# $GOAL_REGISTRY_REPO, same pattern as the goal registry (goal-lib.sh line 3): "A goal is a
# registry issue on GitHub ...; $PIPE/goal-<id>.* is only a host-local cache." Here the registry
# issue's body is a JSON array of "owner/repo#issue" keys, lowest index = highest priority. Both
# hosts cache it the same way, at $PIPE/backlog-priority.json, as a rank map:
#   {"owner/repo#issue": <0-based rank>, ...}
#
# Usage:
#   backlog-priority.sh pull                       refresh the local cache from the registry issue
#                                                    (silent, always exits 0 — meant for a supervisor
#                                                    tick; see reconcile-status.sh)
#   backlog-priority.sh set <key> [<key> ...]       JP: write a full ordered list of
#                                                    "owner/repo#issue" keys (lowest priority
#                                                    first); updates the registry issue, then the
#                                                    local cache. This is the command the status
#                                                    page's "Backlog priority" section prints
#                                                    (pre-filled with today's order) for JP to
#                                                    reorder by hand and paste back — the page
#                                                    itself has no drag-and-drop (it emits no JS).
#   backlog-priority.sh show                        print the current local cache (debugging)
#
# A ticket absent from the store sorts after every ranked ticket, in today's milestone+issue order
# (supervisor.sh); it is never dropped. bash 3.2 portable where practical; uses [[ =~ ]] and a
# here-string, both fine on the pipeline's bash (>= 3.2 has both).
BP_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$BP_HERE/config.sh"

BP_LABEL="backlog-priority-registry"
BP_TITLE="Backlog priority order (machine-managed; do not edit by hand)"
BP_BODY_PLACEHOLDER='[]'
BP_KEY_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$'
BP_STORE="$PIPE/backlog-priority.json"

bp_err() { printf '[backlog-priority] %s\n' "$*" >&2; }

command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { [ "${1:-}" = "pull" ] && exit 0; bp_err "gh and jq are required"; exit 1; }

# bp_lookup_issue — prints the registry issue number over REST (never GraphQL: goal-lib.sh's
# comment notes the GraphQL budget is the one that ran out in #57, and this is called from every
# host's reconcile pass, far more often than `set`). Prints nothing on "none exists yet" AND on a
# failed call alike (both are "I don't know" to the caller) and never creates anything — a GraphQL
# outage must never look like "zero issues found" (it would, via `gh issue list`, and `pull`
# creating a fresh empty registry issue on every such outage raced the real one and could overwrite
# JP's order once the API recovered and `.[0]` picked the wrong, newer, empty issue).
bp_lookup_issue() {
  gh api "repos/$GOAL_REGISTRY_REPO/issues?labels=$BP_LABEL&state=open&per_page=1" --jq '.[0].number // empty' 2>/dev/null
}

# bp_find_issue — like bp_lookup_issue, but creates the registry issue (body []) when the lookup
# found none. Only `set` (a hand-run, JP-initiated command, not a 10-minutes-per-host poll) calls
# this — `pull` never creates, see bp_lookup_issue above.
bp_find_issue() {
  local n
  n=$(bp_lookup_issue)
  if [ -n "$n" ] && [ "$n" != "null" ]; then printf '%s\n' "$n"; return 0; fi
  gh api -X POST "repos/$GOAL_REGISTRY_REPO/labels" -f "name=$BP_LABEL" >/dev/null 2>&1 || true
  n=$(printf '%s' "$(jq -nc --arg t "$BP_TITLE" --arg b "$BP_BODY_PLACEHOLDER" --arg l "$BP_LABEL" '{title:$t, body:$b, labels:[$l]}')" \
    | gh api -X POST "repos/$GOAL_REGISTRY_REPO/issues" --input - --jq .number 2>/dev/null)
  [ -n "$n" ] && [ "$n" != "null" ] && printf '%s\n' "$n"
}

# bp_write_store <json array of keys> — atomically overwrite the local rank-map cache (same
# tmp-then-mv pattern as goal-lib.sh's goal_names_fill).
bp_write_store() {
  jq -c 'to_entries | map({(.value): .key}) | add // {}' <<<"$1" > "$BP_STORE.tmp" 2>/dev/null \
    && mv "$BP_STORE.tmp" "$BP_STORE" || { rm -f "$BP_STORE.tmp"; return 1; }
}

cmd_pull() {
  mkdir -p "$PIPE" 2>/dev/null
  local n body arr
  n=$(bp_lookup_issue)
  # Nothing found, or the lookup call itself failed (rate limit, offline) -- these look the same
  # from here, and both mean "leave the existing cache exactly as it is", never "wipe it to {}".
  [ -n "$n" ] && [ "$n" != "null" ] || return 0
  body=$(gh issue view "$n" --repo "$GOAL_REGISTRY_REPO" --json body --jq .body 2>/dev/null) || return 0
  arr=$(jq -c 'if (type=="array") then [.[] | select(type=="string")] else [] end' <<<"$body" 2>/dev/null) || return 0
  [ -n "$arr" ] || arr='[]'
  bp_write_store "$arr" || bp_err "could not write the local cache"
  return 0
}

cmd_set() {
  [ $# -ge 1 ] || { bp_err "set needs at least one owner/repo#issue key"; return 1; }
  local k arr='[]'
  for k in "$@"; do
    [[ "$k" =~ $BP_KEY_RE ]] || { bp_err "malformed key '$k' (want owner/repo#issue)"; return 1; }
    arr=$(jq -c --arg k "$k" '. + [$k]' <<<"$arr") || return 1
  done
  arr=$(jq -c 'reduce .[] as $k ([]; if any(.[]; . == $k) then . else . + [$k] end)' <<<"$arr") || return 1
  local n
  n=$(bp_find_issue) || true
  [ -n "$n" ] || { bp_err "could not find or create the registry issue"; return 1; }
  if ! printf '%s' "$(jq -nc --arg b "$arr" '{body:$b}')" | gh api -X PATCH "repos/$GOAL_REGISTRY_REPO/issues/$n" --input - >/dev/null 2>&1; then
    bp_err "could not write registry issue #$n"
    return 1
  fi
  bp_write_store "$arr" || bp_err "could not write the local cache"
  printf 'backlog priority updated (%s tickets), registry issue #%s\n' "$(jq 'length' <<<"$arr")" "$n"
}

cmd_show() { cat "$BP_STORE" 2>/dev/null || echo '{}'; }

case "${1:-}" in
  pull) cmd_pull ;;
  set) shift; cmd_set "$@" ;;
  show) cmd_show ;;
  *) echo "usage: backlog-priority.sh {pull|set <owner/repo#issue>...|show}" >&2; exit 1 ;;
esac
