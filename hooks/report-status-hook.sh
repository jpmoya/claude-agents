#!/bin/bash
# SessionStart / Stop / SubagentStop hook: pushes a status event (stage start, stage end / marker
# change) whenever the orchestrator launched this stage with PIPELINE_ISSUE set — the same guard
# require-handoff-marker.sh uses (issue #10 Design §4.4). Must never fail or delay the session it's
# attached to, and must not read stdin (the Claude Code hook payload on stdin is irrelevant here,
# and consuming it would risk blocking if nothing is piped in).
[ -n "${PIPELINE_ISSUE:-}" ] || exit 0

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HOOK_DIR/../skills/orchestrate/run-state.sh" 2>/dev/null || . "$HOME/.claude/skills/orchestrate/run-state.sh" 2>/dev/null || exit 0

report_status_async "${PIPELINE_AGENT:-stage}"
exit 0
