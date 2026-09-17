#!/bin/bash
# STUB — see jpmoya/claude-agents#10.
# SessionStart / Stop / SubagentStop hook: pushes a status event (stage start, stage end / marker
# change) when the orchestrator launched this stage with PIPELINE_ISSUE set — the same guard
# require-handoff-marker.sh uses. Must never fail or delay the session it's attached to.
#
# Not implemented yet: does not source run-state.sh or call report_status_async. Left this way
# (rather than a silent no-op that would make AC9's non-blocking test pass vacuously) so the test
# can assert the expected side effect — the reporter actually being invoked — and see it fail.
echo "NotImplemented: report-status-hook.sh" >&2
exit 97
