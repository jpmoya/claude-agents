#!/bin/bash
# Intake label decisions (#114). Usage: intake-labels.sh <bug|idea|unclear> → prints `add <label>` / `remove <label>`
# lines for the intake agent to apply. Anything but bug is an idea; never agent-go for ideas. A bug gets agent-go only
# when INTAKE_AUTO_GO=1 (config.sh; default 1 since #115), else agent-proposed so JP sees it in the hourly digest.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
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
