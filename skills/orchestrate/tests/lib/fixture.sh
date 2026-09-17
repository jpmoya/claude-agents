# Fixture builders for a fake /tmp/pipeline-shaped tree. Every test sources this, then calls
# new_pipe() to get an isolated mktemp -d PIPE for that test case — never the host's real /tmp/pipeline.
#
# Repo names used anywhere in these fixtures MUST be placeholders (project-a, project-b, ...) —
# this repo is public (AC5/AC17).

# new_pipe — creates an isolated PIPE + QUEUE dir pair, sets PIPE/QUEUE, prints the PIPE path.
new_pipe() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-pipe.XXXXXX")
  mkdir -p "$d/queue"
  echo "$d"
}

# new_home — an isolated HOME with ~/.claude/pipeline/ so config.local.sh and runs.jsonl are redirected.
new_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-home.XXXXXX")
  mkdir -p "$d/.claude/pipeline" "$d/logs/pipeline"
  echo "$d"
}

# fixture_repo <dir> <owner/repo> — a throwaway local git repo whose origin resolves to owner/repo,
# for the alias-map lookup (git config --get remote.origin.url; local, no network).
fixture_repo() {
  local dir=$1 owner_repo=$2
  mkdir -p "$dir"
  ( cd "$dir" && git init -q && git remote add origin "https://github.com/$owner_repo.git" ) >/dev/null 2>&1
}

# mk_running <pipe> <issue> <repo_path> — a "running" orchestrator: live pid, .repo, .start.
# Uses `sleep 300 &` as the live process so kill -0 succeeds for the life of the test.
RUNNING_PIDS=""
mk_running() {
  local pipe=$1 issue=$2 repo=$3
  sleep 300 &
  local pid=$!
  RUNNING_PIDS="$RUNNING_PIDS $pid"
  echo "$pid" > "$pipe/orch-$issue.pid"
  echo "$repo" > "$pipe/orch-$issue.repo"
  date -u +%FT%TZ > "$pipe/orch-$issue.start"
  date -u +%FT%TZ > "$pipe/orch-$issue.launched-at"
  : > "$pipe/orch-$issue.log"
}

# mk_dead_pid <pipe> <issue> — a .pid file pointing at a pid that is guaranteed not to be alive.
# A just-reaped subshell pid can be recycled by the kernel before derive_runs() runs `kill -0`
# on a busy host, silently turning a held/stopped/done/restarting fixture into "running" — so
# scan downward from a high number instead until we find one with no live process.
mk_dead_pid() {
  local pipe=$1 issue=$2 p=99999
  while kill -0 "$p" 2>/dev/null; do p=$((p - 1)); done
  echo "$p" > "$pipe/orch-$issue.pid"
}

# mk_held <pipe> <issue> <repo_path>
mk_held() {
  local pipe=$1 issue=$2 repo=$3
  mk_dead_pid "$pipe" "$issue"
  echo "$repo" > "$pipe/orch-$issue.repo"
  date -u +%FT%TZ > "$pipe/orch-$issue.start"
  touch "$pipe/orch-$issue.held"
  : > "$pipe/orch-$issue.log"
}

# mk_stopped <pipe> <issue> <repo_path>
mk_stopped() {
  local pipe=$1 issue=$2 repo=$3
  mk_dead_pid "$pipe" "$issue"
  echo "$repo" > "$pipe/orch-$issue.repo"
  date -u +%FT%TZ > "$pipe/orch-$issue.start"
  touch "$pipe/orch-$issue.stopped"
  : > "$pipe/orch-$issue.log"
}

# mk_done <pipe> <issue> <repo_path>
mk_done() {
  local pipe=$1 issue=$2 repo=$3
  mk_dead_pid "$pipe" "$issue"
  echo "$repo" > "$pipe/orch-$issue.repo"
  date -u +%FT%TZ > "$pipe/orch-$issue.start"
  touch "$pipe/orch-$issue.done"
  : > "$pipe/orch-$issue.log"
}

# mk_restarting <pipe> <issue> <repo_path> — exited, no terminal marker file at all.
mk_restarting() {
  local pipe=$1 issue=$2 repo=$3
  mk_dead_pid "$pipe" "$issue"
  echo "$repo" > "$pipe/orch-$issue.repo"
  date -u +%FT%TZ > "$pipe/orch-$issue.start"
  : > "$pipe/orch-$issue.log"
}

# mk_queued <pipe> <issue> <repo_path> — a queue entry with no live pid and no orch-<issue>.pid at all.
mk_queued() {
  local pipe=$1 issue=$2 repo=$3
  python3 -c "
import json, datetime
json.dump({'issue': '$issue', 'repo': '$repo', 'extra': '', 'reason': 'queued',
           'queued_at': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'not_before': 0},
          open('$pipe/queue/orch-$issue.json', 'w'))
"
}

# mk_stage_log <pipe> <issue> <agent> [age_secs_ago] — writes a stage log whose mtime is
# `age_secs_ago` seconds in the past (0 = now = newest), so stage-from-mtime is deterministic.
mk_stage_log() {
  local pipe=$1 issue=$2 agent=$3 age=${4:-0}
  local f="$pipe/run-$issue-$agent.log"
  : > "$f"
  if [ "$age" -gt 0 ]; then
    local ts
    ts=$(python3 -c "import time; print(int(time.time()) - $age)")
    python3 -c "import os; os.utime('$f', ($ts, $ts))"
  fi
}

# cleanup_running — kill every sleep placeholder mk_running started. Call in every test's trap.
cleanup_running() {
  local p
  for p in $RUNNING_PIDS; do kill "$p" 2>/dev/null; done
  RUNNING_PIDS=""
}
