#!/usr/bin/env bash
# #94: a newer-started orchestrator must not hide a live stage process
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/run-state.sh"
_rs_ps_lines() {
  printf '100\t7\tclaude --agent test-writer -p\n'
  printf '200\t7\tclaude --agent orchestrator -p\n'
}
got=$(_rs_live_stage 7 1)
[ "$got" = "test-writer" ] || { echo "FAIL: got '$got'"; exit 1; }
_rs_ps_lines() { printf '200\t7\tclaude --agent orchestrator -p\n'; }
got=$(_rs_live_stage 7 1)
[ "$got" = "orchestrator" ] || { echo "FAIL: orch-only got '$got'"; exit 1; }
echo PASS
