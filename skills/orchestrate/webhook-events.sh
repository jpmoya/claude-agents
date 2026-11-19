#!/bin/bash
# webhook-events.sh — supervisor read path for the GitHub webhook queue (#773). Sourced by config.sh (after gh-budget.sh), so every
# orchestrate script has it; everything is a no-op unless WEBHOOK_EVENTS_ENABLED=1 (kill switch, default 0, checked on every call).
# Bash 3.2 safe (macOS).
#
# State (all under $WEBHOOK_STATE_DIR, default $PIPE/webhook):
#   events.jsonl      the queue. VM: written by webhook-receiver.py. Mac: a mirror this file appends to from the VM's GET /events.
#   pull.cursor       Mac only: last VM seq appended to the mirror (advanced only after a successful append)
#   consumer.cursor   last seq applied to the read cache
#   full.<repo>       epoch of the repo's last full since-sync (the fallback poll); older than WEBHOOK_FALLBACK_POLL_MINUTES = due again
#   applied           epoch of the last tick that applied the queue to the cache (other processes trust the cache only while it is fresh)
#   gap               a dropped / reset / compacted-away range was seen: every repo does a full sync on its next call
#   enabled-since     epoch the feature was first seen on (an empty queue is measured from here for the stale banner)
#
# Contract with gh-budget.sh: gh_since_sync <repo> first asks webhook_sync_repo <repo>; 0 = "served from events, no API call".
# Otherwise (disabled, not prepared, fallback due, gap) it falls through to the unchanged full since-sync, and calls webhook_full_done
# on success. Queue lines carry only validated tags (event, action, repo, number, sender login); they are read with jq, never eval'd.

_wh_dir() { printf '%s' "${WEBHOOK_STATE_DIR:-${PIPE:-$HOME/.claude/pipeline/state}/webhook}"; }
webhook_enabled() { [ "${WEBHOOK_EVENTS_ENABLED:-0}" = 1 ]; }
_wh_num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "${2:-0}" ;; *) printf '%s' "$1" ;; esac; }
_wh_slug() { printf '%s' "$1" | tr 'A-Z/' 'a-z_'; }
_wh_iso() {
  TZ=UTC date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || TZ=UTC date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}
# _wh_owner_ok <owner/repo> — only repos whose owner has a webhook (WEBHOOK_OWNERS, space separated, case-insensitive) are served from
# events; any other repo keeps the plain 2-minute since-sync, so a repo with no hook never silently drops to 20-minute freshness.
_wh_owner_ok() {
  local o w owner; owner=$(printf '%s' "${1%%/*}" | tr 'A-Z' 'a-z')
  for w in ${WEBHOOK_OWNERS:-Benjis-Plants}; do
    o=$(printf '%s' "$w" | tr 'A-Z' 'a-z'); [ "$o" = "$owner" ] && return 0
  done
  return 1
}
_wh_valid_repo() { case "$1" in */*/*|*[!A-Za-z0-9._/-]*|''|/*|*/) return 1 ;; */*) return 0 ;; esac; return 1; }

# _wh_alert <what> — error on the changed path: a log line plus at most one Slack post per hour through the existing
# SLACK_WEBHOOK_URL. Tags only (release = commit SHA, environment = host, route); never command output, a response body or a token.
_wh_alert() {
  local dir stamp now last rel msg
  dir=$(_wh_dir); mkdir -p "$dir" 2>/dev/null
  rel=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --short HEAD 2>/dev/null || echo unknown)
  msg="webhook events error: $1: release=$rel environment=$(hostname -s 2>/dev/null || echo unknown) route=webhook-events"
  if type slog >/dev/null 2>&1; then slog "[webhook] $msg"; else printf '%s\n' "$msg" >&2; fi
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 0
  stamp="$dir/alert.last"; now=$(date +%s)
  last=$(_wh_num "$(cat "$stamp" 2>/dev/null)" 0)
  [ $(( now - last )) -ge 3600 ] || return 0
  echo "$now" > "$stamp" 2>/dev/null
  curl -s --max-time 10 -X POST -H 'Content-type: application/json' \
    --data "$(jq -nc --arg t "$msg" '{text:$t}')" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
}

# webhook_events_since <seq> — queue lines newer than <seq>, one compact JSON object per line. A torn last line is skipped.
webhook_events_since() {
  local q; q="$(_wh_dir)/events.jsonl"
  [ -f "$q" ] || return 0
  tail -n 5000 "$q" | jq -cR --argjson s "$(_wh_num "${1:-0}" 0)" 'fromjson? | select(type=="object" and (.seq|type)=="number" and .seq > $s)' 2>/dev/null
}
_wh_latest_seq() { local q; q="$(_wh_dir)/events.jsonl"; [ -f "$q" ] && tail -n 20 "$q" | jq -rR 'fromjson? | select(type=="object") | .seq | numbers' 2>/dev/null | tail -n 1; }
_wh_oldest_seq() { local q; q="$(_wh_dir)/events.jsonl"; [ -f "$q" ] && head -n 1 "$q" | jq -rR 'fromjson? | select(type=="object") | .seq | numbers' 2>/dev/null | head -n 1; }
_wh_newest_ts() { local q; q="$(_wh_dir)/events.jsonl"; [ -f "$q" ] && tail -n 20 "$q" | jq -rR 'fromjson? | select(type=="object") | .ts | numbers' 2>/dev/null | tail -n 1; }

_wh_write() { printf '%s\n' "$2" > "$1.$$" 2>/dev/null && mv "$1.$$" "$1" 2>/dev/null; }

# webhook_pull — Mac: append the VM's newer events (GET /events?since=) to the local mirror. No-op when WEBHOOK_RECEIVER_URL is empty
# (the VM reads the receiver's own file). The bearer token goes to curl on stdin (-K -), never argv; the cursor moves only after the append.
webhook_pull() {
  local url="${WEBHOOK_RECEIVER_URL:-}" tok="${WEBHOOK_PULL_TOKEN:-}" dir q cur page resp latest oldest lines max pages=0
  [ -n "$url" ] || return 0
  case "$url" in https://*|http://127.0.0.1*|http://localhost*) ;; *) _wh_alert "pull: WEBHOOK_RECEIVER_URL must be https"; return 1 ;; esac
  case "$tok" in ''|*[!A-Za-z0-9._~+/=-]*) _wh_alert "pull: WEBHOOK_PULL_TOKEN missing or has unsupported characters"; return 1 ;; esac
  dir=$(_wh_dir); q="$dir/events.jsonl"; mkdir -p "$dir" 2>/dev/null
  cur=$(_wh_num "$(cat "$dir/pull.cursor" 2>/dev/null)" 0)
  while [ "$pages" -lt 5 ]; do
    pages=$(( pages + 1 ))
    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" \
      | curl -sS --fail --max-time 20 --proto '=http,https' -K - "${url%/}/events?since=$cur&limit=${WEBHOOK_PULL_LIMIT:-500}" 2>/dev/null) \
      || { _wh_alert "pull: request to the receiver failed"; return 1; }
    latest=$(printf '%s' "$resp" | jq -er '.latest | numbers' 2>/dev/null) && oldest=$(printf '%s' "$resp" | jq -er '.oldest | numbers' 2>/dev/null) \
      || { _wh_alert "pull: unreadable receiver response"; return 1; }
    if [ "$latest" -lt "$cur" ]; then   # the VM's queue was reset: start over and force a full sync
      rm -f "$q"; touch "$dir/gap"; _wh_write "$dir/pull.cursor" 0; cur=0; continue
    fi
    [ "$cur" -gt 0 ] && [ "$oldest" -gt $(( cur + 1 )) ] && touch "$dir/gap"   # unread events were compacted away on the VM
    lines=$(printf '%s' "$resp" | jq -c '.events[]? | select(type=="object" and (.seq|type)=="number")' 2>/dev/null)
    [ -n "$lines" ] || return 0
    max=$(printf '%s\n' "$lines" | jq -r '.seq' | sort -n | tail -n 1)
    printf '%s\n' "$lines" >> "$q" || { _wh_alert "pull: cannot append to the local queue"; return 1; }
    _wh_write "$dir/pull.cursor" "$max"; cur=$max
    [ "$cur" -ge "$latest" ] && break
  done
  if [ "$(wc -c < "$q" 2>/dev/null | tr -d ' ')" -gt "${WEBHOOK_QUEUE_MAX_BYTES:-8388608}" ] 2>/dev/null; then   # mirror only; the VM compacts its own
    tail -n 5000 "$q" > "$q.$$" 2>/dev/null && mv "$q.$$" "$q" 2>/dev/null
  fi
  return 0
}

# _wh_canon_repo <owner/repo> — the spelling the read cache was indexed under (callers' case can differ from GitHub's full_name)
_wh_canon_repo() {
  local want f slug; want=$(_wh_slug "$1")
  for f in "${GH_CACHE_DIR:-}"/.since.*; do
    [ -e "$f" ] || continue
    slug="${f##*/.since.}"
    [ "$(printf '%s' "$slug" | tr 'A-Z' 'a-z')" = "$want" ] && { printf '%s' "${slug/_//}"; return 0; }
  done
  printf '%s' "$1"
}

# webhook_tick_prepare — once per supervisor tick, before the gh_since_sync loop: pull (Mac), then apply every event since the consumer
# cursor to the read cache (invalidate the touched issue / PR and the repo's list entries). Sets WEBHOOK_TICK_READY=1 only on success.
webhook_tick_prepare() {
  WEBHOOK_TICK_READY=0
  local dir cur latest oldest gap=0 n=0 events repo number ev now
  dir=$(_wh_dir)
  if ! webhook_enabled; then rm -f "$dir/enabled-since" 2>/dev/null; return 0; fi
  type _gh_budget_paths >/dev/null 2>&1 && _gh_budget_paths
  mkdir -p "$dir" 2>/dev/null || { _wh_alert "state dir not writable"; return 0; }
  now=$(date +%s)
  [ -f "$dir/enabled-since" ] || echo "$now" > "$dir/enabled-since"
  webhook_pull || true   # a failed pull is alerted inside; the fallback poll covers the gap
  latest=$(_wh_num "$(_wh_latest_seq)" 0); oldest=$(_wh_num "$(_wh_oldest_seq)" 0)
  if [ -f "$dir/consumer.cursor" ]; then cur=$(_wh_num "$(cat "$dir/consumer.cursor" 2>/dev/null)" 0); else cur=$latest; gap=1; fi
  [ -f "$dir/gap" ] && { gap=1; rm -f "$dir/gap"; }
  [ "$cur" -gt "$latest" ] && gap=1
  [ "$cur" -gt 0 ] && [ "$oldest" -gt $(( cur + 1 )) ] && gap=1
  if [ "$gap" = 1 ]; then
    rm -f "$dir"/full.* 2>/dev/null
  else
    events=$(webhook_events_since "$cur")
    while IFS='|' read -r repo number ev; do   # not a tab: IFS whitespace collapses an empty number field
      [ -n "$repo" ] || continue
      n=$(( n + 1 ))
      _wh_valid_repo "$repo" || continue
      repo=$(_wh_canon_repo "$repo")
      case "$number" in ''|*[!0-9]*) ;; *) type _gh_since_invalidate_issue >/dev/null 2>&1 && _gh_since_invalidate_issue "$repo" "$number" ;; esac
      type _gh_since_invalidate_lists >/dev/null 2>&1 && _gh_since_invalidate_lists "$repo"
    done <<< "$(printf '%s\n' "$events" | jq -r 'select(type=="object") | [.repo // "", (.number // "" | tostring), .event // ""] | join("|")' 2>/dev/null)"
  fi
  _wh_write "$dir/consumer.cursor" "$latest" || { _wh_alert "cannot write the consumer cursor"; return 0; }
  _wh_write "$dir/applied" "$now"
  WEBHOOK_TICK_READY=1
  type slog >/dev/null 2>&1 && slog "[webhook] applied events=$n gap=$gap latest=$latest"
  return 0
}

_wh_age_ok() {  # <file> <max secs> — exists and is younger than that
  local t; t=$(_wh_num "$(cat "$1" 2>/dev/null)" 0)
  [ "$t" -gt 0 ] && [ $(( $(date +%s) - t )) -lt "$2" ]
}

# webhook_sync_repo <owner/repo> — 0 when this repo needs no API read this tick (events already applied, its fallback poll not due)
webhook_sync_repo() {
  webhook_enabled || return 1
  [ "${WEBHOOK_TICK_READY:-0}" = 1 ] || return 1
  _wh_owner_ok "$1" || return 1
  local dir; dir=$(_wh_dir)
  _wh_age_ok "$dir/full.$(_wh_slug "$1")" $(( $(_wh_num "${WEBHOOK_FALLBACK_POLL_MINUTES:-20}" 20) * 60 )) || return 1
  type _gh_since_mark_synced >/dev/null 2>&1 && _gh_since_mark_synced "$1"
  return 0
}

# webhook_full_done <owner/repo> — the full since-sync (cold start or fallback poll) succeeded for this repo
webhook_full_done() {
  webhook_enabled || return 0
  local dir; dir=$(_wh_dir); mkdir -p "$dir" 2>/dev/null
  _wh_write "$dir/full.$(_wh_slug "$1")" "$(date +%s)"
}

# webhook_trusted <owner/repo> — other processes (goal sync, reconcile, pipeline-lib): may a cached single-issue / issues-list read be
# served with no wall-clock expiry? Only while the supervisor applied the queue recently and this repo's fallback poll is not overdue.
webhook_trusted() {
  webhook_enabled || return 1
  _wh_owner_ok "$1" || return 1
  local dir; dir=$(_wh_dir)
  [ ! -f "$dir/gap" ] || return 1
  _wh_age_ok "$dir/applied" "$(_wh_num "${WEBHOOK_TRUST_SECS:-600}" 600)" || return 1
  _wh_age_ok "$dir/full.$(_wh_slug "$1")" $(( $(_wh_num "${WEBHOOK_FALLBACK_POLL_MINUTES:-20}" 20) * 60 ))
}

# webhook_stale_json — {"since":"<ISO>"} when the feature is on and the newest event (or, for an empty queue, the enable time) is older
# than WEBHOOK_STALE_MINUTES; nothing otherwise. Published as the beat's webhook_stale; constant during an outage (no hash churn), the
# status page computes the minutes itself.
webhook_stale_json() {
  webhook_enabled || return 0
  local dir t now; dir=$(_wh_dir); now=$(date +%s)
  t=$(_wh_num "$(_wh_newest_ts)" 0)
  [ "$t" -gt 0 ] || t=$(_wh_num "$(cat "$dir/enabled-since" 2>/dev/null)" 0)
  [ "$t" -gt 0 ] || return 0
  [ $(( now - t )) -ge $(( $(_wh_num "${WEBHOOK_STALE_MINUTES:-30}" 30) * 60 )) ] || return 0
  printf '{"since":"%s"}' "$(_wh_iso "$t")"
}
