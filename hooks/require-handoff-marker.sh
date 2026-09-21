#!/bin/bash
# Stop / SubagentStop hook for pipeline stage runs. Active only when the orchestrator launched the
# stage with PIPELINE_ISSUE / PIPELINE_AGENT / PIPELINE_REPO set. Refuses to let the stage finish until
# the issue carries a NEW routing marker from this agent (count > the before-count the orchestrator wrote).
# Only markers in the agent's vocabulary (pipeline-markers.sh) count: a first line like `**[deployer] MARKER** PASS`
# or `**[deployer] COMPLETED**` is inert and does not satisfy the hook (claude-agents#5).
# Bounded: after 2 refusals it lets the run stop so a truly stuck agent can't loop forever.
[ -n "${PIPELINE_ISSUE:-}" ] && [ -n "${PIPELINE_AGENT:-}" ] && [ -n "${PIPELINE_REPO:-}" ] || exit 0
INPUT=$(cat)
PIPE="${PIPE:-/tmp/pipeline}"
BEFORE_FILE="$PIPE/$PIPELINE_ISSUE-$PIPELINE_AGENT-before.txt"
NAG_FILE="$PIPE/$PIPELINE_ISSUE-$PIPELINE_AGENT-nags.txt"
[ -f "$BEFORE_FILE" ] || exit 0
BEFORE=$(cat "$BEFORE_FILE")
. "$(dirname "$0")/pipeline-markers.sh" || exit 0
VALID=$(markers_for "$PIPELINE_AGENT"); VALID=${VALID:-BLOCKED}
# gh --jq takes no --arg, so the regex is spliced into the filter as a JSON string
# REST, not GraphQL: the GraphQL budget is shared per account and runs out first (#57).
# --paginate runs the filter once per page, so it emits one line per match and the lines are counted here.
# A failed read still fails open, but moves the nag file first — its mtime is the orchestrator's liveness
# signal — without consuming a nag.
HITS=$(gh api "repos/$PIPELINE_REPO/issues/$PIPELINE_ISSUE/comments?per_page=100" --paginate \
  --jq ".[] | select(.body | split(\"\n\")[0] | test($(marker_re "$PIPELINE_AGENT" | jq -Rs .))) | 1" 2>/dev/null) \
  || { if [ -f "$NAG_FILE" ]; then touch "$NAG_FILE"; else echo 0 > "$NAG_FILE"; fi; exit 0; }
NOW=$(printf '%s' "$HITS" | grep -c .)
if [ "${NOW:-0}" -gt "$BEFORE" ]; then rm -f "$NAG_FILE"; exit 0; fi
NAGS=$(cat "$NAG_FILE" 2>/dev/null || echo 0)
if [ "$NAGS" -ge 2 ]; then exit 0; fi
echo $((NAGS+1)) > "$NAG_FILE"
echo "BLOCKED: $PIPELINE_REPO#$PIPELINE_ISSUE has no new handoff comment from $PIPELINE_AGENT, so the orchestrator cannot see this run. If the work is still going (a background task or subagent has not finished), keep working and wait for it — post nothing yet. When it is finished, write the handoff comment to a file and post it with gh api repos/$PIPELINE_REPO/issues/$PIPELINE_ISSUE/comments -F body=@<file>: line 1 is **[$PIPELINE_AGENT] then the one routing marker that is true of this run, then ** — and the only routing markers $PIPELINE_AGENT has are: ${VALID//|/, }. Any other first line (NOTE, an invented word, a status sentence) is ignored. Use BLOCKED, with the exact reason underneath, only if you could not finish. Then stop." >&2
exit 2
