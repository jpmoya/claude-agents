#!/bin/bash
# Deterministic resolve + dispatch for a Slack @mention relay (issue #7).
#
# Usage: pipeline-bridge-dispatch.sh <issue> <repo-or-dash> <channel> <ts>
#   <issue>          must match ^[0-9]+$ — validated before any `gh` call.
#   <repo-or-dash>   explicit "owner/repo", or literal "-" to resolve from this machine's local
#                     $PIPE/orch-<issue>.repo checkout. Required, never omittable.
#   <channel>        Slack channel id of the mention (chat_id with its "channel:" prefix stripped).
#   <ts>             Slack thread ts of the mention (message_id). Both are required.
#
# Resolution order (Expected Behavior #1):
#   1. explicit owner/repo arg, if reachable via `gh repo view --repo`.
#   2. else (arg is "-"): the local $PIPE/orch-<issue>.repo checkout's real git remote, if this
#      machine has run that issue before.
#   3. else: print a one-line prompt asking which repo, and stop. Zero `gh` calls in that case.
#
# Once resolved: `gh issue view --json state,labels` — closed, already agent-in-progress, or
# already agent-go each report status and take no action (idempotent, no `gh issue edit` call);
# otherwise add the label via exactly one `gh issue edit --repo <owner/repo> <issue> --add-label
# agent-go` call (never call orchestrate.sh directly — the shared claim/dispatch protocol in
# supervisor.sh §5 is what actually launches it).
#
# Every outcome tied to a real issue in a real repo (closed / already running / already queued /
# newly queued) also posts one `gh issue comment` whose first line is
# "**[pipeline-bridge] NOTE** slack-thread: <channel>:<ts>" — supervisor.sh's slack_thread_for reads
# it to thread later pipeline events into this Slack thread. NOTE is outside pipeline-markers.sh's
# vocabulary, so it is inert to routing. "repo not found" / "which repo?" post nothing.
#
# On any exit 0, stdout is exactly one line — the verbatim Slack reply. The caller (the
# pipeline-bridge relay agent) composes nothing itself; see pipeline-bridge-prompt.md.

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/config.sh"

usage() {
  echo "usage: pipeline-bridge-dispatch.sh <issue> <repo-or-dash> <channel> <ts>" >&2
}

if [ "$#" -ne 4 ]; then
  usage
  exit 1
fi

ISSUE=$1
REPO_ARG=$2
SLACK_CHANNEL=$3
SLACK_TS=$4

case "$ISSUE" in
  ''|*[!0-9]*)
    echo "invalid issue number: [$ISSUE] — expected digits only" >&2
    exit 1
    ;;
esac

# resolve_from_checkout <issue> — prints owner/repo parsed from $PIPE/orch-<issue>.repo's real git
# remote (local, no network — same mechanism build-runs-json.py / report-status.sh use for the
# status-board alias lookup); exits non-zero if no mapping is on file or the remote can't be
# parsed as a github.com URL.
resolve_from_checkout() {
  local issue=$1 repo_file checkout url
  repo_file="$PIPE/orch-$issue.repo"
  [ -f "$repo_file" ] || return 1
  checkout=$(cat "$repo_file" 2>/dev/null)
  [ -n "$checkout" ] || return 1
  url=$(git -C "$checkout" config --get remote.origin.url 2>/dev/null)
  [ -n "$url" ] || return 1
  case "$url" in *"/") url=${url%/} ;; esac
  case "$url" in *".git") url=${url%.git} ;; esac
  case "$url" in
    https://github.com/*) printf '%s\n' "${url#https://github.com/}"; return 0 ;;
    http://github.com/*) printf '%s\n' "${url#http://github.com/}"; return 0 ;;
    git@github.com:*) printf '%s\n' "${url#git@github.com:}"; return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$REPO_ARG" = "-" ]; then
  if ! OWNER_REPO=$(resolve_from_checkout "$ISSUE") || [ -z "$OWNER_REPO" ]; then
    echo "which repo is this for? reply with the owner/repo too, e.g. \"#$ISSUE owner/repo\""
    exit 0
  fi
else
  OWNER_REPO=$REPO_ARG
fi

if ! gh repo view --repo "$OWNER_REPO" >/dev/null 2>&1; then
  echo "repo $OWNER_REPO couldn't be found (or isn't accessible) — check the name and try again"
  exit 0
fi

# Genuine `gh issue view` failure (bad issue number, permissions, network) is not one of the
# idempotent-status branches below — it's a real error, so it gets prompt.md's non-zero-exit
# ("generic failure line") contract rather than a false "queued"/"closed" claim.
if ! ISSUE_JSON=$(gh issue view "$ISSUE" --repo "$OWNER_REPO" --json state,labels 2>/dev/null) || [ -z "$ISSUE_JSON" ]; then
  echo "couldn't read #$ISSUE in $OWNER_REPO — check the issue number and try again" >&2
  exit 1
fi
STATE=$(printf '%s' "$ISSUE_JSON" | jq -r '.state // empty' 2>/dev/null)
HAS_IN_PROGRESS=$(printf '%s' "$ISSUE_JSON" | jq -r --arg l "$LABEL_IN_PROGRESS" '([.labels[].name] | index($l)) != null' 2>/dev/null)
HAS_GO=$(printf '%s' "$ISSUE_JSON" | jq -r --arg l "$LABEL_GO" '([.labels[].name] | index($l)) != null' 2>/dev/null)

# post_thread_note — records the Slack thread on the issue (see header). Best-effort: a failed
# comment must not turn a correct status reply into a failure, and its stdout must not leak into
# the one-line reply.
post_thread_note() {
  gh issue comment "$ISSUE" --repo "$OWNER_REPO" \
    --body "**[pipeline-bridge] NOTE** slack-thread: $SLACK_CHANNEL:$SLACK_TS" >/dev/null 2>&1 \
    || echo "warning: couldn't record the Slack thread on #$ISSUE ($OWNER_REPO)" >&2
}

if [ "$STATE" = "CLOSED" ]; then
  post_thread_note
  echo "#$ISSUE ($OWNER_REPO) is already closed — nothing to do"
  exit 0
fi

if [ "$HAS_IN_PROGRESS" = "true" ]; then
  post_thread_note
  echo "#$ISSUE ($OWNER_REPO) is already running ($LABEL_IN_PROGRESS) — nothing to do"
  exit 0
fi

if [ "$HAS_GO" = "true" ]; then
  post_thread_note
  echo "#$ISSUE ($OWNER_REPO) is already queued ($LABEL_GO already set) — nothing to do"
  exit 0
fi

# Never claim "queued" unless the label actually landed — a failed edit (permissions, rate
# limit) gets the same non-zero "generic failure" contract as an unreadable issue above.
if ! gh issue edit --repo "$OWNER_REPO" "$ISSUE" --add-label "$LABEL_GO" >/dev/null 2>&1; then
  echo "couldn't add $LABEL_GO to #$ISSUE ($OWNER_REPO) — check permissions and try by hand" >&2
  exit 1
fi
post_thread_note
echo "#$ISSUE ($OWNER_REPO) queued — added $LABEL_GO, the shared dispatcher will pick it up"
exit 0
