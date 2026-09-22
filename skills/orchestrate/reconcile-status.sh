#!/bin/bash
# Refresh the status board's local truth from GitHub (issue #51). Usage: reconcile-status.sh [--force]
#
# For every local record (orch-<n>.pid + orch-<n>.repo, or a queue-only entry) that is open-ish (running / restarting / held / queued)
# or finished within the last 48 h (done / stopped), and has no orch-<n>.closed yet, one
# `gh issue view <n> --json state,closedAt,comments,milestone`:
#   CLOSED -> orch-<n>.closed (line 1 = closedAt), touch .done, drop .held/.stopped/.alert and the queue
#             entry, log a line to supervisor.log
#   OPEN   -> orch-<n>.marker = the latest real routing marker name (removed when there is none)
# Each pass also refreshes two per-repo GitHub lists (issue #65) for DISPATCH_REPOS ∪ SCAN_ONLY_REPOS:
# open issues with milestone `staging` -> status-staging.json, open `agent-go` issues ->
# status-approved.json (a failed call keeps that repo's previous entries). And an OPEN issue whose
# milestone is a release (vX.Y.Z) is treated like CLOSED, with the version in orch-<n>.release.
# then ONE report_status_async if anything changed. The reporter and builder only read these files, so
# they stay network-free.
#
# Throttled to one pass per RECONCILE_INTERVAL_SECS (stamp file) unless --force. Always exits 0, never
# prints: a gh failure (offline, rate limit) is a silent no-op. bash 3.2 portable (no GNU stat/date flags).
RC_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$RC_HERE/config.sh"
. "$RC_HERE/pipeline-lib.sh"
. "$RC_HERE/run-state.sh"     # derive_runs, _rs_mtime, report_status_async
. "$RC_HERE/../../hooks/pipeline-markers.sh" 2>/dev/null || . "$HOME/.claude/hooks/pipeline-markers.sh" 2>/dev/null

RECONCILE_INTERVAL_SECS=600
RECENT_SECS=$((48 * 3600))      # done/stopped records older than this are not refreshed
STAMP="$PIPE/status-reconcile.stamp"
STAGING_LIST="$PIPE/status-staging.json"
APPROVED_LIST="$PIPE/status-approved.json"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

command -v jq >/dev/null 2>&1 && command -v gh >/dev/null 2>&1 || exit 0
mkdir -p "$PIPE" "$LOGDIR" 2>/dev/null

now=$(date +%s)
if [ "$FORCE" -eq 0 ]; then
  stamp_mtime=$(_rs_mtime "$STAMP")
  if [ -n "$stamp_mtime" ] && [ $((now - stamp_mtime)) -lt "$RECONCILE_INTERVAL_SECS" ]; then
    exit 0
  fi
fi
touch "$STAMP" 2>/dev/null

rc_log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOGDIR/supervisor.log" 2>/dev/null; }

MARKER_JQ="$(marker_last_jq)"
changed=0

# rc_repos — each configured repo once, one owner/repo per line (DISPATCH_REPOS entries are "owner/repo:path")
rc_repos() {
  local e r seen=" "
  for e in ${DISPATCH_REPOS[@]+"${DISPATCH_REPOS[@]}"} ${SCAN_ONLY_REPOS[@]+"${SCAN_ONLY_REPOS[@]}"}; do
    r="${e%%:*}"
    [ -n "$r" ] || continue
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "
    printf '%s\n' "$r"
  done
}

# rc_refresh_list <file> <gh issue list args...> — rewrite <file> atomically; sets changed=1 on a change
rc_refresh_list() {
  local file=$1; shift
  local repo out fresh merged="[]" prev tmp
  prev=$(jq -c 'if type=="array" then . else [] end' "$file" 2>/dev/null) || prev="[]"
  [ -n "$prev" ] || prev="[]"
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    if out=$(gh issue list --repo "$repo" --state open "$@" --json number,title,updatedAt 2>/dev/null </dev/null) \
       && fresh=$(printf '%s' "$out" | jq -c --arg r "$repo" \
            'map({owner_repo: $r, issue: .number, title: (.title // ""), updated_at: (.updatedAt // "")})' 2>/dev/null) \
       && [ -n "$fresh" ]; then
      :
    else
      fresh=$(printf '%s' "$prev" | jq -c --arg r "$repo" 'map(select(.owner_repo == $r))' 2>/dev/null) || fresh="[]"
    fi
    merged=$(jq -nc --argjson a "$merged" --argjson b "${fresh:-[]}" '$a + $b' 2>/dev/null) || continue
  done <<RCREPOS
$(rc_repos)
RCREPOS
  if [ "$merged" != "$prev" ] || [ ! -f "$file" ]; then
    tmp=$(mktemp "$file.XXXXXX" 2>/dev/null) || return 0
    printf '%s\n' "$merged" > "$tmp" && mv -f "$tmp" "$file" || rm -f "$tmp"
    [ "$merged" != "$prev" ] && changed=1
  fi
  return 0
}

# Snapshot first: the pass edits the very files derive_runs reads.
records=$(derive_runs)
while IFS=$'\t' read -r issue repo state pid started last_activity restarts stage; do
  [ -n "$issue" ] || continue
  # queued-only entries have no pid/.repo record: their repo comes from the queue JSON (derive_runs)
  { [ "$state" = "queued" ] && [ -n "$repo" ]; } || [ -f "$PIPE/orch-$issue.repo" ] || continue
  case "$state" in
    running|restarting|held|queued) ;;
    done|stopped)
      [ -n "$last_activity" ] || last_activity=$(_rs_mtime "$PIPE/orch-$issue.pid")
      [ -n "$last_activity" ] && [ $((now - last_activity)) -le "$RECENT_SECS" ] || continue ;;
    *) continue ;;                                             # closed (already reconciled) or unknown
  esac

  info=$(cd "$repo" 2>/dev/null && gh issue view "$issue" --json state,closedAt,comments,milestone 2>/dev/null </dev/null) || continue
  gh_state=$(printf '%s' "$info" | jq -r '.state // empty' 2>/dev/null) || continue
  [ -n "$gh_state" ] || continue
  marker=$(printf '%s' "$info" | jq -r "$MARKER_JQ" 2>/dev/null) || marker=""
  case "$marker" in
    none|"") marker="" ;;
    *) marker=$(printf '%s' "$marker" | sed -e 's/^\*\*\[[^]]*\] //' -e 's/\*\*.*$//' -e 's/:.*$//' -e 's/[[:space:]]*$//') ;;
  esac

  old_marker=$(head -n1 "$PIPE/orch-$issue.marker" 2>/dev/null)
  if [ -n "$marker" ]; then
    [ "$marker" = "$old_marker" ] || { printf '%s\n' "$marker" > "$PIPE/orch-$issue.marker"; changed=1; }
  elif [ -f "$PIPE/orch-$issue.marker" ]; then
    rm -f "$PIPE/orch-$issue.marker"; changed=1
  fi

  release=$(printf '%s' "$info" | jq -r '.milestone.title // empty' 2>/dev/null)
  printf '%s' "$release" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || release=""
  [ -z "$release" ] || printf '%s\n' "$release" > "$PIPE/orch-$issue.release"

  if [ "$gh_state" = "CLOSED" ] || { [ "$gh_state" = "OPEN" ] && [ -n "$release" ]; }; then
    closed_at=""
    [ "$gh_state" = "CLOSED" ] && closed_at=$(printf '%s' "$info" | jq -r '.closedAt // empty' 2>/dev/null)
    case "$closed_at" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
      *) closed_at=$(date -u +%FT%TZ) ;;
    esac
    printf '%s\n' "$closed_at" > "$PIPE/orch-$issue.closed"
    [ -f "$PIPE/orch-$issue.repo" ] || printf '%s\n' "$repo" > "$PIPE/orch-$issue.repo"   # queued-only: keep the repo for completed[]
    touch "$PIPE/orch-$issue.done"
    rm -f "$PIPE/orch-$issue.held" "$PIPE/orch-$issue.stopped" "$PIPE/orch-$issue.alert" "$QUEUE/orch-$issue.json"
    if [ "$gh_state" = "OPEN" ]; then
      rc_log "[reconcile] #$issue — released $release, moved to completed"
    else
      rc_log "[reconcile] #$issue — issue closed on GitHub ($closed_at), moved to completed"
    fi
    changed=1
  fi
done <<EOF
$records
EOF

rc_refresh_list "$STAGING_LIST" --search "milestone:staging" --limit 100
rc_refresh_list "$APPROVED_LIST" --label agent-go --limit 50

[ "$changed" -eq 1 ] && report_status_async "reconcile"
exit 0
