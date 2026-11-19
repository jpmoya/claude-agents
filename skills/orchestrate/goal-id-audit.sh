#!/bin/bash
# goal-id-audit.sh (#792) — read-only. Lists registry goals whose id still carries a pre-rename repo name
# (Benjis-Plants_benjis-quoting-tool-..., Benjis-Plants_scheduler-...): "<registry issue>\t<open|closed>\t<id>\t<current id>".
# Nothing is written: not the registry, not $PIPE, not the status page. Empty output = no goal depends on the alias list
# (skills/ticket-intake/repo-aliases.txt); an old-name id keeps resolving through goal_id_current / _goal_find either way.
# Exit 0 = audit ran (empty or not), 1 = the registry could not be read.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/config.sh" 2>/dev/null
. "$HERE/pipeline-lib.sh"
. "$HERE/goal-lib.sh"
goal_id_audit
