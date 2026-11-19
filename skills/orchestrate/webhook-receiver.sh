#!/bin/bash
# Launcher for webhook-receiver.py (#773): the systemd unit (infra/webhook/webhook-receiver.service) runs this, never the .py directly.
# Loads config.sh (which loads config.local.sh: WEBHOOK_SECRET, WEBHOOK_PULL_TOKEN, WEBHOOK_STATE_DIR ...), honours the kill switch, then
# execs the receiver. Secrets travel in the environment only: never argv, never echoed.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/config.sh"
if [ "${WEBHOOK_EVENTS_ENABLED:-0}" != 1 ]; then
  echo "webhook-receiver: WEBHOOK_EVENTS_ENABLED is not 1; not starting" >&2
  exit 0   # exit 0 so the unit's Restart=on-failure leaves it down while the kill switch is off
fi
export WEBHOOK_SECRET="${WEBHOOK_SECRET:-}" WEBHOOK_PULL_TOKEN="${WEBHOOK_PULL_TOKEN:-}" PIPE
export WEBHOOK_STATE_DIR="${WEBHOOK_STATE_DIR:-$PIPE/webhook}"
export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
for _v in WEBHOOK_BIND WEBHOOK_PORT WEBHOOK_MAX_BODY_BYTES WEBHOOK_RATE_LIMIT_PER_MIN WEBHOOK_TRUSTED_PROXIES; do
  [ -n "${!_v:-}" ] && export "$_v"
done
exec python3 "$HERE/webhook-receiver.py"
