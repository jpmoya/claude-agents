#!/bin/bash
# STUB — see jpmoya/claude-agents#10. Sourced by orchestrate.sh, supervisor.sh and
# hooks/report-status-hook.sh. Not implemented yet: every entry point below fails loudly
# (NotImplemented, exit 97) instead of silently no-op-ing, so tests that need it to actually
# do something fail on an assertion rather than passing vacuously.
#
# Contract (issue #10 Design, plus the solutions-architect's NOTE correction on #10):
#   derive_runs() — prints one tab-separated record per recorded orchestrator:
#     issue, repo_path, state_code, pid, started_at, last_activity_at, restarts, stage
#   report_status_async() — the one fire-and-forget call pattern used by all three call sites.
#     MUST resolve its own directory from its own BASH_SOURCE (not the caller's $HERE) and
#     source config.sh itself (not rely on the caller's $LOGDIR) — the hook call site has neither.

derive_runs() {
  echo "NotImplemented: run-state.sh derive_runs" >&2
  return 97
}

report_status_async() {
  echo "NotImplemented: run-state.sh report_status_async" >&2
  return 97
}
