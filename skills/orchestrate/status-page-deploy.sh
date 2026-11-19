#!/bin/bash
# status-page-deploy.sh — deploys the status page Worker (status-page/) from this host when the status-page/ tree on origin/main differs from
# the last tree this host deployed (#778). Replaces the dead GitHub Actions workflow (deploy-status-page.yml, failing since 2026-10-28) and the
# Cloudflare "Workers Builds" git integration: no GitHub Actions minutes, no `gh` call, only a local `git fetch origin main`.
#
# Called backgrounded from the supervisor tick (supervisor.sh), only where STATUS_PAGE_DEPLOY_ENABLED=1 (default 0; exactly ONE host sets it
# in config.local.sh: the one that already holds the Cloudflare login / CLOUDFLARE_API_TOKEN used for a manual `wrangler deploy`).
#
# One pass:
#   1. no-op (exit 0, no fetch) unless enabled, wrangler is installed and a Cloudflare credential exists (token variable or wrangler login file).
#   2. per-host lock; at most one look per STATUS_PAGE_DEPLOY_MIN_INTERVAL_SECS (300); `git fetch origin main`; tree = `git rev-parse origin/main:status-page` (the tree hash, so commits outside status-page/
#      never redeploy). Equal to $PIPE/status-page-deploy/last-deployed-tree: exit 0, nothing else.
#   3. different: a throwaway detached worktree of that origin/main commit (never the live checkout), then in status-page/:
#      `npm install`, `npm test`, `wrangler deploy`. The stamp is written only after all three succeed, with that tree hash.
#      A failed step stamps nothing, retries after STATUS_PAGE_DEPLOY_RETRY_SECS (600), and the worktree is always removed.
#   4. failure: one log line plus one Slack post per tree per hour (existing SLACK_WEBHOOK_URL), tags only: step name, short tree hash,
#      release=<full SHA of origin/main> environment=<host> route=status-page-deploy. Command output is discarded, never logged or posted.
#   5. success: `<epoch> status-page <tree> ok` appended to $LOGDIR/status-page-deploy.log (rotated by rotate-logs.sh).
# Deviations from the ticket text, on purpose: `npm install --no-package-lock` (status-page/package-lock.json is gitignored, so `npm ci` cannot
# work); wrangler is the host's installed binary (STATUS_PAGE_WRANGLER or `command -v wrangler`), not an unpinned `npx` download; the test gate
# skips the doc-drift suites that already fail on main (STATUS_PAGE_DEPLOY_TEST_ARGS, #500). Never fatal: always exits 0. Bash 3.2 safe.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/config.sh"

[ "${STATUS_PAGE_DEPLOY_ENABLED:-0}" = 1 ] || exit 0

SP_REPO="${STATUS_PAGE_DEPLOY_REPO:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)}"
SP_DIR="${STATUS_PAGE_DEPLOY_STATE_DIR:-$PIPE/status-page-deploy}"
SP_LOG="${STATUS_PAGE_DEPLOY_LOG:-$LOGDIR/status-page-deploy.log}"
SP_MIN_INTERVAL="${STATUS_PAGE_DEPLOY_MIN_INTERVAL_SECS:-300}"
SP_RETRY="${STATUS_PAGE_DEPLOY_RETRY_SECS:-600}"
SP_ALERT_SECS="${STATUS_PAGE_DEPLOY_ALERT_SECS:-3600}"
SP_TEST_ARGS="${STATUS_PAGE_DEPLOY_TEST_ARGS---exclude test/deployer-ci-wait.test.js --exclude test/release-merge-rule-text.test.js --exclude test/stage-marker-blank.test.js}"
SP_WRANGLER="${STATUS_PAGE_WRANGLER:-$(command -v wrangler 2>/dev/null)}"
SP_NPM="${STATUS_PAGE_NPM:-npm}"   # config.sh puts the pinned node (and its npm) first on PATH, so a test stub needs this override

[ -n "$SP_REPO" ] && [ -d "$SP_REPO/.git" -o -f "$SP_REPO/.git" ] || exit 0
[ -n "$SP_WRANGLER" ] && [ -x "$SP_WRANGLER" ] || exit 0
sp_have_credentials() {
  [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && return 0
  local f
  for f in "$HOME/Library/Preferences/.wrangler/config/default.toml" "$HOME/.config/.wrangler/config/default.toml" \
           "$HOME/.wrangler/config/default.toml" "${XDG_CONFIG_HOME:-$HOME/.config}/.wrangler/config/default.toml"; do
    [ -f "$f" ] && return 0
  done
  return 1
}
sp_have_credentials || exit 0

sp_read_num() { local v; v=$(head -n 1 "$1" 2>/dev/null) || v=""; case "$v" in ''|*[!0-9]*) v=0 ;; esac; printf '%s' "$v"; }
sp_log() { mkdir -p "${SP_LOG%/*}" 2>/dev/null; printf '%s\n' "$*" >> "$SP_LOG" 2>/dev/null || true; }

mkdir -p "$SP_DIR" 2>/dev/null && [ -w "$SP_DIR" ] || exit 0

# One lock per host. A long deploy (install + tests + deploy) must not be overlapped; a busy lock is a normal skip.
SP_WT=""
sp_cleanup() {
  if [ -n "$SP_WT" ]; then
    git -C "$SP_REPO" worktree remove --force "$SP_WT" >/dev/null 2>&1
    rm -rf "$SP_WT" 2>/dev/null
    git -C "$SP_REPO" worktree prune >/dev/null 2>&1
    SP_WT=""
  fi
  [ -z "${SP_LOCKDIR:-}" ] || rmdir "$SP_LOCKDIR" 2>/dev/null
}
trap sp_cleanup EXIT
if command -v flock >/dev/null 2>&1; then
  exec 8>"$PIPE/status-page-deploy.lock"
  flock -n 8 || exit 0
else
  SP_LOCKDIR="$PIPE/status-page-deploy.lockdir"
  if ! mkdir "$SP_LOCKDIR" 2>/dev/null; then   # macOS has no flock; a lock older than 45 min is a dead pass
    SP_LOCKDIR=""
    if [ -n "$(find "$PIPE/status-page-deploy.lockdir" -maxdepth 0 -mmin +45 2>/dev/null)" ]; then
      rmdir "$PIPE/status-page-deploy.lockdir" 2>/dev/null && mkdir "$PIPE/status-page-deploy.lockdir" 2>/dev/null && SP_LOCKDIR="$PIPE/status-page-deploy.lockdir"
    fi
    [ -n "$SP_LOCKDIR" ] || exit 0
  fi
fi

# throttle: the supervisor calls this every tick; look at origin at most once per SP_MIN_INTERVAL
NOW=$(date +%s)
[ $((NOW - $(sp_read_num "$SP_DIR/last-pass"))) -ge "$SP_MIN_INTERVAL" ] || exit 0
printf '%s\n' "$NOW" > "$SP_DIR/last-pass" 2>/dev/null

# 1. the only network call: a fetch. A failed fetch is a quiet skip (the next tick retries).
git -C "$SP_REPO" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 fetch --quiet origin main >/dev/null 2>&1 \
  || { sp_log "$(date +%s) status-page fetch-failed"; exit 0; }
SP_SHA=$(git -C "$SP_REPO" rev-parse --verify -q origin/main 2>/dev/null) || exit 0
SP_TREE=$(git -C "$SP_REPO" rev-parse --verify -q "origin/main:status-page" 2>/dev/null) || exit 0
[ -n "$SP_TREE" ] || exit 0
[ "$SP_TREE" != "$(head -n 1 "$SP_DIR/last-deployed-tree" 2>/dev/null)" ] || exit 0

# a failed attempt on this same tree backs off
FAIL_AT=0; FAIL_TREE=""
[ -f "$SP_DIR/last-fail" ] && read -r FAIL_AT FAIL_TREE < "$SP_DIR/last-fail"
case "$FAIL_AT" in ''|*[!0-9]*) FAIL_AT=0 ;; esac
if [ "$FAIL_TREE" = "$SP_TREE" ] && [ $((NOW - FAIL_AT)) -lt "$SP_RETRY" ]; then exit 0; fi

sp_alert() {  # <step> — tags only: never command output, a token or the webhook URL
  local step=$1 short=${SP_TREE:0:7} host msg f last now
  host=$(hostname -s 2>/dev/null | tr -c 'A-Za-z0-9._-' '_'); [ -n "$host" ] || host=unknown
  msg="status-page deploy failed at step ${step}: tree=${short} release=${SP_SHA} environment=${host} route=status-page-deploy"
  sp_log "$(date +%s) status-page $SP_TREE failed $step"
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 0
  f="$SP_DIR/alert-$SP_TREE.last"; now=$(date +%s); last=$(sp_read_num "$f")
  [ $((now - last)) -ge "$SP_ALERT_SECS" ] || return 0
  printf '%s\n' "$now" > "$f" 2>/dev/null
  curl -s --max-time 10 -X POST -H 'Content-type: application/json' --data "{\"text\":\"$msg\"}" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
}
sp_fail() { printf '%s %s\n' "$(date +%s)" "$SP_TREE" > "$SP_DIR/last-fail" 2>/dev/null; sp_alert "$1"; exit 0; }

# 2. the throwaway worktree of the exact commit that was just compared
SP_WT=$(mktemp -d "${TMPDIR:-/tmp}/status-page-deploy.XXXXXX" 2>/dev/null) || sp_fail "mktemp"
git -C "$SP_REPO" worktree add --detach "$SP_WT" "$SP_SHA" >/dev/null 2>&1 || sp_fail "worktree"

# 3. steps run in status-page/, output discarded (it may carry account details); only the step name is ever reported
( cd "$SP_WT/status-page" && "$SP_NPM" install --no-audit --no-fund --no-package-lock ) >/dev/null 2>&1 </dev/null || sp_fail "npm install"
# shellcheck disable=SC2086
( cd "$SP_WT/status-page" && "$SP_NPM" test -- $SP_TEST_ARGS ) >/dev/null 2>&1 </dev/null || sp_fail "npm test"
(
  cd "$SP_WT/status-page" || exit 1
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then export CLOUDFLARE_API_TOKEN; fi
  "$SP_WRANGLER" deploy
) >/dev/null 2>&1 </dev/null || sp_fail "wrangler deploy"

# 4. only now: stamp, heartbeat
printf '%s\n' "$SP_TREE" > "$SP_DIR/last-deployed-tree.$$" && mv "$SP_DIR/last-deployed-tree.$$" "$SP_DIR/last-deployed-tree"
rm -f "$SP_DIR/last-fail" 2>/dev/null
sp_log "$(date +%s) status-page $SP_TREE ok"
exit 0
