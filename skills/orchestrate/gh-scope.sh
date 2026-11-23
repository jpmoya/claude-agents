#!/bin/bash
# gh-scope.sh — the host's gh token must keep the scopes the pipeline needs. Sourced by supervisor.sh; CLI: gh-scope.sh [check|status].
# Incident 2026-11-23: an interactive `gh auth login -w` re-issued the Mac's token WITHOUT `project`; from 15:13Z every goal read failed
# (94 identical lines in supervisor.log, nothing else), so a delivered goal could not close or free the slot for hours and nobody was told.
#
# No extra call: gh-budget.sh's `gh api rate_limit -i` (free, no quota) already runs once per tick and saves the X-OAuth-Scopes header to
# $PIPE/gh-scopes ("<epoch> known <csv>" | "<epoch> unknown"). This file only reads that and compares it to GH_REQUIRED_SCOPES (config.sh).
#   gh_scope_check : run at the start of each supervisor tick, after gh_quota_line.
#     all required scopes present -> silent; clears a standing alert (log line only, no second Slack post)
#     one or more missing         -> ONE alert per outage: $PIPE/gh-scope.alert (shown by `launcher.sh status` and, through
#                                    build-runs-json.py goalstall, as a banner on the status page) + one Slack post on the existing
#                                    SLACK_WEBHOOK_URL (code-sync.sh's _cs_slack). Later ticks only rewrite the files and log ONE line.
#                                    A different missing set is a new problem and posts once more.
#     unknown (no header: fine-grained/app token; no or stale scopes file; budget off) -> nothing changes, so one flaky read neither
#                                    clears an outage nor starts a second one.
# State: $PIPE/gh-scope.alert-state = "<since epoch> <ticks> <missing csv>".
# A host that is MEANT to lack a scope (e.g. no project mirror on a host) sets GH_REQUIRED_SCOPES without it in config.local.sh.
GH_SCOPE_FIX_CMD_BASE="gh auth refresh -h github.com -s"
GH_SCOPES_STALE_SECS=${GH_SCOPES_STALE_SECS:-600}

# _gs_missing <csv of scopes held> -> missing required scopes, one per line. `admin:org`/`write:org` cover `read:org`.
_gs_missing() {
  local have=",$1," s
  for s in $GH_REQUIRED_SCOPES; do
    case "$have" in *",$s,"*) continue ;; esac
    [ "$s" = read:org ] && case "$have" in *,write:org,*|*,admin:org,*) continue ;; esac
    printf '%s\n' "$s"
  done
}

# gh_scope_check — see the header. Returns 0 always (never fails a tick).
gh_scope_check() {
  [ "${GH_SCOPE_CHECK_ENABLED:-1}" = 1 ] || return 0
  [ -n "${PIPE:-}" ] || return 0
  type slog >/dev/null 2>&1 || slog() { echo "$*" >&2; }
  local f="${GH_SCOPES_FILE:-$PIPE/gh-scopes}" at kind csv now missing csvm st="$PIPE/gh-scope.alert-state" since=0 n=0 old="" host fix tags
  [ -s "$f" ] || return 0
  read -r at kind csv < "$f" 2>/dev/null || return 0
  now=$(date +%s)
  case "$at" in ''|*[!0-9]*) return 0 ;; esac
  [ "$kind" = known ] && [ $((now - at)) -le "$GH_SCOPES_STALE_SECS" ] || return 0
  missing=$(_gs_missing "$csv")
  csvm=$(printf '%s' "$missing" | tr '\n' ',' | sed 's/,$//')
  host=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'); [ -n "$host" ] || host=unknown
  if [ -z "$csvm" ]; then
    if [ -e "$st" ] || [ -e "$PIPE/gh-scope.alert" ]; then
      rm -f "$st" "$PIPE/gh-scope.alert"
      slog "[gh-scope] token on $host has every required scope again; alert cleared"
    fi
    return 0
  fi
  [ -s "$st" ] && read -r since n old < "$st"
  case "$since" in ''|*[!0-9]*) since=0 ;; esac; case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$since" -gt 0 ] || since=$now
  n=$((n + 1))
  fix="$GH_SCOPE_FIX_CMD_BASE $csvm"   # one refresh command with every missing scope (gh takes -s a,b)
  mkdir -p "$PIPE" 2>/dev/null
  printf '%s gh-scope: the GitHub login on %s is missing the %s permission since %s (%s ticks), so goals and project updates fail there. Fix on that machine: %s\n' \
    "$(date -u +%FT%TZ)" "$host" "$(printf '%s' "$csvm" | sed 's/,/, /g')" "$(_gs_iso "$since")" "$n" "$fix" > "$PIPE/gh-scope.alert"
  printf '%s %s %s\n' "$since" "$n" "$csvm" > "$st"
  slog "[gh-scope] token on $host is missing scope(s): $csvm (alert since $(_gs_iso "$since"), $n ticks); fix: $fix"
  if [ "$old" != "$csvm" ]; then   # first tick of the outage, or a different missing set
    type _cs_slack >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/code-sync.sh"
    tags=$(_cs_tags 2>/dev/null) || tags=""
    _cs_slack "The GitHub login on $host is missing the $(printf '%s' "$csvm" | sed 's/,/, /g') permission, so goals and project updates fail there until it is fixed. Fix on that machine: $fix. $tags route=supervisor/gh-scope"
  fi
  return 0
}

_gs_iso() { python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1" 2>/dev/null || date -u +%FT%TZ; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-check}" in
    check) . "$(dirname "$0")/config.sh" >/dev/null 2>&1; gh_quota_read; gh_scope_check; cat "${PIPE:-/dev/null}/gh-scope.alert" 2>/dev/null || echo ok ;;
    *) echo "usage: gh-scope.sh [check]" >&2; exit 2 ;;
  esac
fi
