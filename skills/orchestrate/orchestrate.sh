#!/bin/bash
# Launch the pipeline orchestrator as a detached headless Claude Code process.
# Usage:
#   orchestrate.sh <repo-path> <issue> [extra instructions...]   launch
#   orchestrate.sh status [issue]                                 list running orchestrators / one issue's state
#   orchestrate.sh tail <issue> [lines]                           tail an orchestrator's log
#   orchestrate.sh stop <issue>                                   kill an orchestrator (stages it launched keep running)
set -euo pipefail
PIPE=/tmp/pipeline
mkdir -p "$PIPE"

case "${1:-}" in
  status)
    ISSUE="${2:-}"
    for f in "$PIPE"/orch-*.pid; do
      [ -e "$f" ] || { echo "no orchestrators recorded"; break; }
      n=$(basename "$f" .pid); n=${n#orch-}
      [ -n "$ISSUE" ] && [ "$n" != "$ISSUE" ] && continue
      pid=$(cat "$f"); repo=$(cat "$PIPE/orch-$n.repo" 2>/dev/null || echo "?")
      if kill -0 "$pid" 2>/dev/null; then state="running (pid $pid)"; else state="exited"; fi
      last=$( (cd "$repo" 2>/dev/null && gh issue view "$n" --json comments \
        --jq '[.comments[] | .body | split("\n")[0] | select(test("^\\*\\*\\[[a-z-]+\\] ") and (test("^\\*\\*\\[[a-z-]+\\] NOTE") | not))] | last // "none"') 2>/dev/null || echo "?")
      echo "#$n  $state  repo=$repo  latest marker: $last  log=$PIPE/orch-$n.log"
    done
    ;;
  tail)
    tail -n "${3:-20}" "$PIPE/orch-$2.log"
    ;;
  stop)
    pid=$(cat "$PIPE/orch-$2.pid"); kill "$pid" && echo "stopped orchestrator for #$2 (pid $pid)"
    ;;
  *)
    REPO="${1:?repo path required}"; ISSUE="${2:?issue number required}"; shift 2; EXTRA="$*"
    REPO=$(cd "$REPO" && pwd)
    OWNER_REPO=$(cd "$REPO" && gh repo view --json nameWithOwner --jq .nameWithOwner)
    if [ -f "$PIPE/orch-$ISSUE.pid" ] && kill -0 "$(cat "$PIPE/orch-$ISSUE.pid")" 2>/dev/null; then
      echo "orchestrator for #$ISSUE already running (pid $(cat "$PIPE/orch-$ISSUE.pid")); use 'stop' first" >&2; exit 1
    fi
    PROMPT="Use the orchestrator subagent to drive GitHub issue $OWNER_REPO#$ISSUE through the agent pipeline. Repo: $REPO. Read the latest marker on the issue and continue from there. $EXTRA"
    cd "$REPO"
    PIPELINE_HEADLESS=1 nohup claude --dangerously-skip-permissions -p "$PROMPT" > "$PIPE/orch-$ISSUE.log" 2>&1 &
    echo $! > "$PIPE/orch-$ISSUE.pid"; echo "$REPO" > "$PIPE/orch-$ISSUE.repo"; date -u +%FT%TZ > "$PIPE/orch-$ISSUE.start"
    echo "launched orchestrator for $OWNER_REPO#$ISSUE  pid=$!  log=$PIPE/orch-$ISSUE.log"
    echo "check: ~/.claude/skills/orchestrate/orchestrate.sh status $ISSUE"
    ;;
esac
