#!/bin/bash
# scheduled-triggers.sh — fires schedule-only GitHub workflows from this host's supervisor instead of GitHub's `schedule:` cron
# (#769: the app repos' auto-release router, cron every 5 min, went silent for ~6.5 h on 2026-11-19 and staging sat unreleased).
# The jobs still run on the self-hosted runners; only the clock moves here. The `schedule:` triggers stay in the app repos as a fallback.
#
# Usage: scheduled-triggers.sh [run|status]
#   run     (default) one pass: dispatch every workflow in scheduled-triggers.conf that is due. Called backgrounded by supervisor.sh each tick.
#   status  print the heartbeat JSON array the status page publishes (local files only, no network):
#           [{"repo","workflow","interval_minutes","last_fired_at"|null,"tracked_since"|null}] — one per active config line.
#           tracked_since = when this host first saw the line, so the status page can tell "never fired" from "just enabled".
#
# Config (SCHEDULED_TRIGGERS_CONF, default scheduled-triggers.conf beside this script), one workflow per line:
#   <owner/repo> <workflow file> <interval minutes> [<input>=<value> ...] [ref=<branch>]
# `#` starts a comment. Adding a workflow is one line, no code change. The inputs are passed as `-f key=value` and exist because a
# workflow_dispatch run is not always the same as its scheduled run (e.g. a dry-run default): mirror what the schedule did.
#
# Per due workflow (the due list is computed locally first; a tick with nothing due makes no gh call at all, not even the budget read):
#   1. due = this host's last-dispatch timestamp ($PIPE/scheduled-triggers/<repo>__<workflow>.last) is older than the interval.
#   2. ONE `gh run list --workflow` read (cached SCHEDULED_TRIGGERS_RUNS_TTL_SECS on disk): skip when a run is queued / in progress,
#      and skip (stamping the timestamp from that run) when the newest run, from any trigger, started less than one interval ago. That
#      read is what keeps the VM and the Mac from double-firing (a lock is per host) and the GitHub cron fallback from doubling.
#      An in-progress run counts as fired now (stamps the timestamp), so a long router run never looks silent.
#   3. ONE `gh workflow run` (no --ref: gh uses the repo's default branch). Every gh call is killed after SCHEDULED_TRIGGERS_GH_TIMEOUT_SECS (30).
#      A failed read or dispatch backs the workflow off for one interval (at most 30 min) so a workflow without workflow_dispatch is not
#      retried every tick. Success stamps the timestamp and appends
#      `<ts> <repo> <workflow> ok` to $SCHEDULED_TRIGGERS_LOG. A failure stamps nothing, appends `... failed`, and is captured
#      (log + the existing SLACK_WEBHOOK_URL, tags release=<commit SHA> environment=<host> route=scheduled-triggers, never a token)
#      once per workflow per hour; the other workflows still run.
# Guards: SCHEDULED_TRIGGERS_ENABLED=1 (default 0: exactly one machine runs it, set in that host's config.local.sh); one lock per host
# ($PIPE/scheduled-triggers.lock); gh-budget.sh (nothing runs below the `normal` quota tier). Bash 3.2 safe.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/config.sh"

MODE="${1:-run}"
case "$MODE" in run|status) ;; *) echo "usage: scheduled-triggers.sh [run|status]" >&2; exit 2 ;; esac

ST_CONF="${SCHEDULED_TRIGGERS_CONF:-$HERE/scheduled-triggers.conf}"
ST_DIR="${SCHEDULED_TRIGGERS_STATE_DIR:-$PIPE/scheduled-triggers}"
ST_LOG="${SCHEDULED_TRIGGERS_LOG:-$LOGDIR/scheduled-triggers.log}"
ST_TTL="${SCHEDULED_TRIGGERS_RUNS_TTL_SECS:-60}"
ST_ALERT_SECS="${SCHEDULED_TRIGGERS_ALERT_SECS:-3600}"
ST_GH_TIMEOUT="${SCHEDULED_TRIGGERS_GH_TIMEOUT_SECS:-30}"
ST_BACKOFF_MAX_MIN="${SCHEDULED_TRIGGERS_BACKOFF_MAX_MIN:-30}"

st_tags() { printf 'release=%s environment=%s route=scheduled-triggers' "$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)" "$(hostname -s 2>/dev/null || echo unknown)"; }

# st_key <owner/repo> <workflow> → a file-name-safe key
st_key() { printf '%s__%s' "${1//\//_}" "$2"; }

# st_read_num <file> → the file's first line when all digits, else 0
st_read_num() {
  local v; v=$(head -n 1 "$1" 2>/dev/null) || v=""
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}

# st_config → one normalized line per valid config entry on stdout: "<repo> <workflow> <interval> [<input> ...]". Bad lines go to stderr.
st_config() {
  local line n=0 repo wf iv rest tok ok
  [ -f "$ST_CONF" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    set -f; set -- $line; set +f
    [ $# -gt 0 ] || continue
    repo=$1; wf=${2:-}; iv=${3:-}
    ok=1
    case "$repo" in */*) ;; *) ok=0 ;; esac
    case "$repo" in *[!A-Za-z0-9._/-]*|*/*/*|/*|*/) ok=0 ;; esac
    case "$wf" in ''|*[!A-Za-z0-9._-]*) ok=0 ;; *.yml|*.yaml) ;; *) ok=0 ;; esac
    case "$iv" in ''|*[!0-9]*|0*) ok=0 ;; esac
    if [ "$ok" = 1 ]; then
      shift 3
      for tok in "$@"; do
        case "$tok" in
          *[!A-Za-z0-9_=.-]*|=*|*=*=*) ok=0 ;;
          *=*) ;;
          *) ok=0 ;;
        esac
      done
    fi
    if [ "$ok" = 0 ]; then echo "scheduled-triggers: ignored config line $n" >&2; continue; fi
    printf '%s %s %s' "$repo" "$wf" "$iv"
    for tok in "$@"; do printf ' %s' "$tok"; done
    printf '\n'
  done < "$ST_CONF"
}

# --- status: the heartbeat the status page reads ---------------------------------------------------------------------------------
if [ "$MODE" = status ]; then
  [ "${SCHEDULED_TRIGGERS_ENABLED:-0}" = 1 ] || { echo '[]'; exit 0; }
  out=""
  while read -r repo wf iv _; do
    [ -n "${repo:-}" ] || continue
    last=$(st_read_num "$ST_DIR/$(st_key "$repo" "$wf").last"); since=$(st_read_num "$ST_DIR/$(st_key "$repo" "$wf").since")
    out="$out$(jq -nc --arg r "$repo" --arg w "$wf" --argjson i "$iv" --argjson l "$last" --argjson s "$since" \
      '{repo: $r, workflow: $w, interval_minutes: $i, last_fired_at: (if $l > 0 then ($l | todate) else null end),
        tracked_since: (if $s > 0 then ($s | todate) else null end)}')"$'\n'
  done < <(st_config 2>/dev/null)
  printf '%s' "$out" | jq -sc '.' 2>/dev/null || echo '[]'
  exit 0
fi

# --- run -------------------------------------------------------------------------------------------------------------------------
[ "${SCHEDULED_TRIGGERS_ENABLED:-0}" = 1 ] || exit 0
[ -f "$ST_CONF" ] || exit 0

st_log() { mkdir -p "${ST_LOG%/*}" 2>/dev/null; printf '%s\n' "$*" >> "$ST_LOG" 2>/dev/null || true; }
# st_throttle <state key> — 0 (and stamps it) when this key has not been reported for an hour, else 1
st_throttle() {
  local f="$ST_DIR/$1.alert" now last
  now=$(date +%s); last=$(st_read_num "$f")
  [ $((now - last)) -ge "$ST_ALERT_SECS" ] || return 1
  printf '%s\n' "$now" > "$f" 2>/dev/null
  return 0
}
# st_report <what> — one log line + one Slack message (the existing webhook). Tags only, never a token, a gh error text or a command line.
st_report() {
  local msg="scheduled-triggers error: $1: $(st_tags)"
  st_log "[$(date -u +%FT%TZ)] $msg"
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 0
  curl -s --max-time 10 -X POST -H 'Content-type: application/json' \
    --data "$(jq -nc --arg t "$msg" '{text:$t}')" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
}
# st_capture <state key> <what> — st_report at most once per key per hour
st_capture() { st_throttle "$1" && st_report "$2"; return 0; }

if ! mkdir -p "$ST_DIR" 2>/dev/null || [ ! -w "$ST_DIR" ]; then
  ST_DIR="$PIPE"   # the throttle stamp must live somewhere writable
  st_capture statedir "state dir not writable"
  exit 0
fi

# One lock per host, separate from the supervisor's (this runs backgrounded from every tick). A busy lock is a normal skip.
if command -v flock >/dev/null 2>&1; then
  exec 8>"$PIPE/scheduled-triggers.lock"
  flock -n 8 || exit 0
else
  ST_LOCKDIR="$PIPE/scheduled-triggers.lockdir"
  if ! mkdir "$ST_LOCKDIR" 2>/dev/null; then   # macOS has no flock; a lock older than 5 min is a dead pass
    if [ -n "$(find "$ST_LOCKDIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then rmdir "$ST_LOCKDIR" 2>/dev/null; mkdir "$ST_LOCKDIR" 2>/dev/null || exit 0
    else exit 0; fi
  fi
  trap 'rmdir "$ST_LOCKDIR" 2>/dev/null' EXIT
fi

# 1. the due list, from local files only (no gh call, no budget read when nothing is due)
NOW=$(date +%s)
DUE=""
while read -r repo wf iv rest; do
  [ -n "${repo:-}" ] || continue
  key=$(st_key "$repo" "$wf")
  [ -f "$ST_DIR/$key.since" ] || printf '%s\n' "$NOW" > "$ST_DIR/$key.since" 2>/dev/null   # first sighting of this line
  last=$(st_read_num "$ST_DIR/$key.last"); failed=$(st_read_num "$ST_DIR/$key.fail")
  # a failed attempt backs off for one interval (at most ST_BACKOFF_MAX_MIN): a workflow without workflow_dispatch is not retried every tick
  back=$iv; [ "$back" -le "$ST_BACKOFF_MAX_MIN" ] || back=$ST_BACKOFF_MAX_MIN
  [ $((NOW - last)) -ge $((iv * 60)) ] && [ $((NOW - failed)) -ge $((back * 60)) ] && DUE="$DUE$repo $wf $iv $rest"$'\n'
done < <(st_config 2>/dev/null)
[ -n "$DUE" ] || exit 0

gh_class normal
gh_tier_allows normal || exit 0   # budget low: no GitHub call this pass

# st_timeout <secs> <cmd...> — run a command (a shell function such as gh() works) and kill it after <secs>; rc 124 on a timeout.
# No `timeout` binary on macOS, and `timeout` cannot run the gh() budget wrapper anyway.
st_timeout() {
  local secs=$1 pid wd rc; shift
  "$@" & pid=$!
  ( sleep "$secs"; pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; touch "$ST_DIR/.timeout.$pid" ) >/dev/null 2>&1 & wd=$!
  wait "$pid" 2>/dev/null; rc=$?
  pkill -P "$wd" 2>/dev/null; kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  if [ -e "$ST_DIR/.timeout.$pid" ]; then rm -f "$ST_DIR/.timeout.$pid"; return 124; fi
  return $rc
}

# st_runs <owner/repo> <workflow> → the workflow's newest runs as JSON ([{status,createdAt}]), from the disk cache when fresh. rc 1 = unreadable.
st_runs() {
  local cf="$ST_DIR/runs-$(st_key "$1" "$2").json" t out
  t=$(st_read_num "$cf")
  if [ "$t" -gt 0 ] && [ $((NOW - t)) -lt "$ST_TTL" ]; then tail -n +2 "$cf"; return 0; fi
  out=$(st_timeout "$ST_GH_TIMEOUT" gh run list --repo "$1" --workflow "$2" --limit 5 --json status,createdAt 2>/dev/null </dev/null) || return 1
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  { printf '%s\n' "$NOW"; printf '%s\n' "$out"; } > "$cf.$$" 2>/dev/null && mv "$cf.$$" "$cf" 2>/dev/null
  printf '%s\n' "$out"
}

while read -r repo wf iv rest; do
  [ -n "${repo:-}" ] || continue
  key=$(st_key "$repo" "$wf")
  if ! runs=$(st_runs "$repo" "$wf"); then
    printf '%s\n' "$NOW" > "$ST_DIR/$key.fail" 2>/dev/null
    st_capture "$key" "run list failed for $repo $wf"
    continue
  fi
  # a run still queued / in progress: never overlap. A run created within the last interval (any trigger, this or the other host,
  # GitHub's own cron): it has fired, stamp the timestamp from it and wait for the next interval.
  active=$(printf '%s' "$runs" | jq '[.[] | select(.status != "completed")] | length' 2>/dev/null) || active=0
  newest=$(printf '%s' "$runs" | jq '[.[] | .createdAt | fromdateiso8601? // 0] | max // 0' 2>/dev/null) || newest=0
  case "$active" in ''|*[!0-9]*) active=0 ;; esac
  case "$newest" in ''|*[!0-9]*) newest=0 ;; esac
  if [ "$active" -gt 0 ]; then
    # never overlap, but a running router is a live one: an in-progress run counts as fired now (else a run longer than 3 intervals
    # trips the status page alert while it works); a run still queued counts from the time it was created (a stuck queue is not a fire)
    inprog=$(printf '%s' "$runs" | jq '[.[] | select(.status == "in_progress")] | length' 2>/dev/null) || inprog=0
    case "$inprog" in ''|*[!0-9]*) inprog=0 ;; esac
    stamp=$newest; [ "$inprog" -gt 0 ] && stamp=$NOW
    [ "$stamp" -gt "$(st_read_num "$ST_DIR/$key.last")" ] && printf '%s\n' "$stamp" > "$ST_DIR/$key.last" 2>/dev/null
    continue
  fi
  if [ "$newest" -gt 0 ] && [ $((NOW - newest)) -lt $((iv * 60)) ]; then
    [ "$newest" -gt "$(st_read_num "$ST_DIR/$key.last")" ] && printf '%s\n' "$newest" > "$ST_DIR/$key.last" 2>/dev/null
    continue
  fi
  args=()
  for tok in $rest; do
    case "$tok" in ref=*) args+=(--ref "${tok#ref=}") ;; *) args+=(-f "$tok") ;; esac
  done
  if st_timeout "$ST_GH_TIMEOUT" gh workflow run "$wf" --repo "$repo" ${args[@]+"${args[@]}"} >/dev/null 2>&1 </dev/null; then
    printf '%s\n' "$(date +%s)" > "$ST_DIR/$key.last" 2>/dev/null || st_capture "$key.state" "state write failed for $repo $wf"
    rm -f "$ST_DIR/$key.alert" "$ST_DIR/$key.fail" "$ST_DIR/runs-$key.json" 2>/dev/null   # the next read must see the run we just started
    st_log "$(date +%s) $repo $wf ok"
  else
    printf '%s\n' "$(date +%s)" > "$ST_DIR/$key.fail" 2>/dev/null
    # logged once per workflow per hour, like its Slack message (a workflow that lacks workflow_dispatch fails on every pass)
    if st_throttle "$key"; then
      st_log "$(date +%s) $repo $wf failed"
      st_report "workflow dispatch failed for $repo $wf"
    fi
  fi
done <<< "$DUE"
exit 0
