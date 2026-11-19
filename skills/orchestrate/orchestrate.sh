#!/bin/bash
# Deprecated name of launcher.sh (#779): same arguments, same exit codes. Kept so old callers keep working; removal is a separate ticket.
if [ -t 2 ]; then
  echo "orchestrate.sh is deprecated: use launcher.sh (same arguments)" >&2
fi
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/launcher.sh" "$@"
