#!/bin/bash
# Prints the payload's `sentry_cap` array (#781): one {repo,count,max,resets_at,held} object per repo whose daily Sentry launch
# cap is holding tickets right now, `[]` otherwise. Read by report-status.sh; local files only, never a GitHub call.
# The supervisor leaves the held ticket numbers ($PIPE/sentry-cap-held.<repo>.json); the count and the reset time are recounted
# here from sentry-launches.log, so a hold that has since freed (or a file a stopped supervisor left behind) is not published.
# Any failure prints `[]`: the status page must never fail a push over this.
SCS_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCS_HERE/config.sh" 2>/dev/null
. "$SCS_HERE/pipeline-lib.sh" 2>/dev/null
out=""
for f in "$PIPE"/sentry-cap-held.*.json; do
  [ -f "$f" ] || continue
  repo=$(jq -r '.repo // empty' "$f" 2>/dev/null) || continue
  case "$repo" in */*) ;; *) continue ;; esac
  case "$repo" in *[!A-Za-z0-9._/-]*) continue ;; esac
  held=$(jq -r '(.held // [])[] | tostring' "$f" 2>/dev/null) || continue
  # shellcheck disable=SC2086
  rec=$(sentry_cap_record "$repo" $held 2>/dev/null) || continue
  [ -z "$rec" ] || out="$out$rec"$'\n'
done
printf '%s' "$out" | jq -sc '.' 2>/dev/null || echo '[]'
