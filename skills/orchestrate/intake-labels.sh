#!/bin/bash
# Intake label decisions (#114). Usage: intake-labels.sh <bug|idea|unclear|noise> [sentry] → prints `add <label>` / `remove <label>`
# lines for the intake agent to apply. Anything but bug is an idea; never agent-go for ideas. A bug gets agent-go only
# when INTAKE_AUTO_GO=1 (config.sh; default 1 since #115), else agent-proposed so JP sees it in the hourly digest.
# Source `sentry` (#176): the ticket came from the Sentry poller. bug → bug + agent-go (SENTRY_AUTO_GO=1, config.sh, the
# setting since #678; with SENTRY_AUTO_GO=0 agent-proposed instead; INTAKE_AUTO_GO is ignored), never fast-lane, never
# needs-spec; idea/unclear are treated as bug;
# noise → only sentry-noise. `noise` is valid only with `sentry`; any other source is an error.
# #182: that automatic agent-go comes with sentry-auto-go, the label the daily launch cap (SENTRY_AUTO_GO_DAILY_CAP)
# counts; no other output carries it, so a ticket JP releases by hand is never throttled. For a source:sentry issue the
# supervisor (intake_apply_decision), not the intake agent, runs this helper and writes both labels in one call; its gate
# (sentry_label_gate) then sets the final labels of the issue from the handoff marker.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
src="${2:-}"
case "$src" in ''|sentry) ;; *) exit 2 ;; esac
if [ "$src" = sentry ]; then
  case "${1:-}" in
    noise) echo "remove user-feedback-intake"; echo "add sentry-noise"; exit 0 ;;
    bug|idea|unclear)
      echo "remove user-feedback-intake"; echo "add user-feedback"; echo "add bug"
      if [ "${SENTRY_AUTO_GO:-0}" = 1 ]; then echo "add $LABEL_GO"; echo "add $LABEL_SENTRY_GO"; else echo "add $LABEL_PROPOSED"; fi
      exit 0 ;;
    *) exit 2 ;;
  esac
fi
case "${1:-}" in bug|idea|unclear) ;; *) exit 2 ;; esac
echo "remove user-feedback-intake"
echo "add user-feedback"
case "${1:-}" in
  bug)
    echo "add bug"; echo "add fast-lane"
    if [ "${INTAKE_AUTO_GO:-0}" = 1 ]; then echo "add $LABEL_GO"; else echo "add $LABEL_PROPOSED"; fi ;;
  idea|unclear) echo "add user-feedback-needs-spec" ;;
  *) exit 2 ;;
esac
