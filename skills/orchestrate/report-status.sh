#!/bin/bash
# STUB — see jpmoya/claude-agents#10. Not implemented yet.
#
# Contract (issue #10 Design):
#   1. source config.sh; STATUS_PUSH_URL or STATUS_PUSH_TOKEN unset -> exit 0 silently, no network (AC6).
#   2. `--print`: build and print the v1 payload; no lock, no network, no state write (ACs 1/2/5).
#   3. mkdir $PIPE/status-push.lockdir (stale >60s reclaimed, trap ... EXIT); lock lost -> exit 0 (AC10).
#   4. payload from derive_runs + capacity + supervisor_last_tick, via jq -n; truncate to 20 runs.
#   5. hash the payload minus sent_at/supervisor_last_tick.
#   6. push if (hash changed && >=MIN_PUSH_INTERVAL_SECS since last attempt) || >=KEEPALIVE_SECS since
#      last push, and count < MAX_PUSHES_PER_DAY.
#   7. curl -sS -X POST --connect-timeout 3 --max-time 5 ...; never echo the command or the token;
#      log decision + HTTP status only, at most once per keep-alive window on failure.
#   8. on 2xx: atomic cache rewrite, bump count, reset on UTC day change, clear fails.
#      On failure: advance last_attempt_epoch, bump fails, leave last_hash/last_push_epoch alone.
#      Always exit 0.
#
# Deliberately not implemented: this stub exits 97 (loud NotImplemented) on every path rather than
# silently succeeding or silently doing nothing, so tests that need real push/skip/log/exit-0
# behavior fail on an assertion instead of passing vacuously against a no-op.
echo "NotImplemented: report-status.sh" >&2
exit 97
