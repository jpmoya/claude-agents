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

# mk_fake_gh <dir> — installs an executable fake `gh` at <dir>/gh. Every invocation is logged as
# one line (raw "$*") to <dir>/gh-calls.log, so a test can assert "zero calls made" or "exactly one
# call" against it (gh_calls / gh_call_count below). Responses are mechanism-agnostic (any --json
# field list, any --jq expression — piped through the real `jq` this repo already depends on)
# rather than pinned to one caller's exact flags, since pipeline-bridge-dispatch.sh doesn't exist
# yet and this fixture must not presuppose its exact argv shape. Behavior is configured by writing
# into <dir> BEFORE invoking the script under test (all optional; defaults below):
#   <dir>/gh-repo-view-rc       exit code for `gh repo view --repo <owner/repo>` (default 0)
#   <dir>/gh-name-with-owner    value for the resolved owner/repo, used both as the `repo view`
#                               response body and for `gh repo view --json nameWithOwner ...` (the
#                               "resolve owner/repo from a local checkout" form) (default "unknown/unknown")
#   <dir>/gh-issue-state        value of .state for `gh issue view ...` (default "OPEN")
#   <dir>/gh-issue-labels-json  JSON array for .labels, e.g. '[{"name":"agent-go"}]' (default "[]")
#   <dir>/gh-issue-edit-rc      exit code for `gh issue edit ...` (default 0)
# Install target is deliberately the caller's choice of <dir> (not fixed here) — callers must use
# an isolated HOME's .local/bin (see new_home) so config.sh's PATH prepend can't let a real `gh`
# installed on this machine win the lookup ahead of the fake (claude-agents#7).
mk_fake_gh() {
  local dir=$1
  mkdir -p "$dir"
  : > "$dir/gh-calls.log"
  cat > "$dir/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$HERE/gh-calls.log"

# jq_expr_of <args...> — prints the argument right after a literal --jq, if any.
jq_expr_of() {
  local prev=""
  for a in "$@"; do
    if [ "$prev" = "--jq" ]; then printf '%s' "$a"; return 0; fi
    prev=$a
  done
}

emit() {  # emit <json> <args...> — apply --jq if present, else print the raw json
  local json=$1; shift
  local expr
  expr=$(jq_expr_of "$@")
  if [ -n "$expr" ]; then
    printf '%s' "$json" | jq -r "$expr"
  else
    printf '%s\n' "$json"
  fi
}

case "$*" in
  *"repo view"*"--repo "*)
    rc=$(cat "$HERE/gh-repo-view-rc" 2>/dev/null || echo 0)
    [ "$rc" -eq 0 ] || exit "$rc"
    owner_repo=$(cat "$HERE/gh-name-with-owner" 2>/dev/null || echo "unknown/unknown")
    emit "{\"nameWithOwner\":\"$owner_repo\"}" "$@"
    exit 0
    ;;
  *"repo view"*"nameWithOwner"*)
    owner_repo=$(cat "$HERE/gh-name-with-owner" 2>/dev/null || echo "unknown/unknown")
    emit "{\"nameWithOwner\":\"$owner_repo\"}" "$@"
    exit 0
    ;;
  *"issue view"*)
    state=$(cat "$HERE/gh-issue-state" 2>/dev/null || echo "OPEN")
    labels=$(cat "$HERE/gh-issue-labels-json" 2>/dev/null || echo "[]")
    json=$(jq -n --arg state "$state" --argjson labels "$labels" '{state:$state, labels:$labels}')
    emit "$json" "$@"
    exit 0
    ;;
  *"issue edit"*)
    rc=$(cat "$HERE/gh-issue-edit-rc" 2>/dev/null || echo 0)
    exit "$rc"
    ;;
  *)
    echo "fake gh: unexpected invocation: $*" >&2
    exit 1
    ;;
esac
GH_EOF
  chmod +x "$dir/gh"
}

# gh_calls <dir> — full call log (one raw "$*" per invocation), for assert_contains/assert_eq.
gh_calls() { cat "$1/gh-calls.log" 2>/dev/null; }

# gh_call_count <dir> <grep-pattern> — number of logged invocations whose line matches <pattern>
# (basic grep, case-sensitive); pass "" to count every invocation.
gh_call_count() {
  local dir=$1 pattern=$2
  if [ -z "$pattern" ]; then
    wc -l < "$dir/gh-calls.log" 2>/dev/null | tr -d ' '
  else
    grep -c -- "$pattern" "$dir/gh-calls.log" 2>/dev/null | tr -d ' '
  fi
}
