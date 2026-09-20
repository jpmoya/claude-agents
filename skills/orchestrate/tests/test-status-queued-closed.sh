# Issue #51 fix cycle — AC1 for a ticket that exists ONLY as a queue entry (no orch-<n>.pid, no
# orch-<n>.repo): when GitHub says CLOSED, reconcile-status.sh --force moves it to completed[].
# Placeholder repo names only. Uses the shared fake gh from the lib helpers.

test_sqc_ac1_queued_only_closed_ticket_moves_to_completed() {
  local pipe home repo bin closed_at rc
  pipe=$(new_pipe); home=$(new_home)
  repo="$pipe/repo-project-a"
  fixture_repo "$repo" "example-owner/project-a"
  bin="$home/.local/bin"; mk_fake_gh "$bin"
  echo "example-owner/project-a" > "$bin/gh-name-with-owner"
  cat > "$home/.claude/pipeline/config.local.sh" <<EOT
STATUS_REPO_ALIASES=("example-owner/project-a:project-a")
EOT
  closed_at=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=7200)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  echo "CLOSED" > "$bin/gh-issue-state-301"; echo "$closed_at" > "$bin/gh-issue-closed-at-301"
  mk_queued "$pipe" 301 "$repo"
  local pid_f repo_f
  pid_f=absent; [ -e "$pipe/orch-301.pid" ] && pid_f=present
  repo_f=absent; [ -e "$pipe/orch-301.repo" ] && repo_f=present
  HOME="$home" PATH="$bin:/usr/bin:/bin" PIPE="$pipe" QUEUE="$pipe/queue" LOGDIR="$home/logs/pipeline" \
    "$ROOT_SQ/skills/orchestrate/reconcile-status.sh" --force >/dev/null 2>&1; rc=$?
  local payload runs completed c_closed queue
  payload=$(HOME="$home" PATH="$bin:/usr/bin:/bin" PIPE="$pipe" QUEUE="$pipe/queue" LOGDIR="$home/logs/pipeline" \
    "$ROOT_SQ/skills/orchestrate/report-status.sh" --print 2>/dev/null)
  runs=$(printf '%s' "$payload" | jq -r '[.runs[].issue|tostring]|join(" ")')
  completed=$(printf '%s' "$payload" | jq -r '[.completed[].issue|tostring]|join(" ")')
  c_closed=$(printf '%s' "$payload" | jq -r '.completed[0].closed_at // "none"')
  queue=absent; [ -e "$pipe/queue/orch-301.json" ] && queue=present
  rm -rf "$pipe" "$home"
  assert_eq "$pid_f/$repo_f" "absent/absent" "AC1: control — queued-only record has no .pid and no .repo" || return 1
  assert_exit0 "$rc" "AC1: reconcile exits 0" || return 1
  assert_eq "$queue" "absent" "AC1: queue entry removed" || return 1
  assert_eq "$runs" "" "AC1: #301 no longer in runs[]" || return 1
  assert_eq "$completed" "301" "AC1: #301 is in completed[]" || return 1
  assert_eq "$c_closed" "$closed_at" "AC1: completed[0].closed_at == GitHub's closedAt" || return 1
}

ROOT_SQ=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
run_test test_sqc_ac1_queued_only_closed_ticket_moves_to_completed
