#!/bin/bash
# Intake label decisions (#114). Usage: intake-labels.sh <bug|idea|unclear|noise> [sentry] → prints `add <label>` / `remove <label>`
# lines for the intake agent to apply. Anything but bug is an idea; never agent-go for ideas. A bug gets agent-go only
# when INTAKE_AUTO_GO=1 (config.sh; default 1 since #115), else agent-proposed so JP sees it in the hourly digest.
# Source `sentry` (#176): the ticket came from the Sentry poller. bug → bug + agent-proposed (agent-go only when
# SENTRY_AUTO_GO=1; INTAKE_AUTO_GO is ignored), never fast-lane, never needs-spec; idea/unclear are treated as bug;
# noise → only sentry-noise. `noise` is valid only with `sentry`; any other source is an error.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
src="${2:-}"
case "$src" in ''|sentry) ;; *) exit 2 ;; esac
if [ "$src" = sentry ]; then
  case "${1:-}" in
    noise) echo "remove user-feedback-intake"; echo "add sentry-noise"; exit 0 ;;
    bug|idea|unclear)
      echo "remove user-feedback-intake"; echo "add user-feedback"; echo "add bug"
      if [ "${SENTRY_AUTO_GO:-0}" = 1 ]; then echo "add $LABEL_GO"; else echo "add $LABEL_PROPOSED"; fi
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
