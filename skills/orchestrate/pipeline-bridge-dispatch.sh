#!/bin/bash
# STUB — see jpmoya/claude-agents#7. Not implemented yet.
#
# Contract (issue #7 Expected Behavior / Acceptance Criteria):
#   usage: pipeline-bridge-dispatch.sh <issue> <repo-or-dash>   — arg 2 is required ("-" means
#     "resolve automatically"), never omittable.
#   1. validate <issue> matches ^[0-9]+$ before any `gh` call; otherwise exit non-zero with a
#      diagnostic and make zero `gh` calls.
#   2. resolve owner/repo: the explicit arg 2 if given and reachable via `gh`; else the local
#      $PIPE/orch-<issue>.repo checkout's remote, if this machine has run that issue before; else
#      print a one-line prompt asking which repo, and stop (zero `gh` calls in that case).
#   3. once resolved: `gh issue view <issue> --repo <owner/repo> --json state,labels` — closed,
#      already agent-in-progress, or already agent-go each report status and take no action
#      (idempotent, no `gh issue edit` call); otherwise add the label via exactly one
#      `gh issue edit --repo <owner/repo> <issue> --add-label agent-go` call.
#   4. on any exit 0, stdout is exactly one line — the verbatim Slack reply; the caller composes
#      nothing itself.
#
# Deliberately: this stub exits 0 with a fixed placeholder line on every invocation, regardless of
# arguments, and never calls `gh` — the inverse of a "loud NotImplemented" sentinel, chosen because
# almost every acceptance criterion here expects exit 0 with scenario-specific stdout content (not
# exit-0-silently, as in the report-status.sh ticket where a loud non-zero sentinel was the right
# choice). A fixed exit-0/no-op response necessarily mismatches every scenario's expected wording
# and every non-zero-exit / call-count expectation (including the one AC that wants a non-zero
# exit on invalid input), so every locked test fails on an assertion here, not vacuously.
echo "NotImplemented: pipeline-bridge-dispatch.sh (issue #7)"
exit 0
