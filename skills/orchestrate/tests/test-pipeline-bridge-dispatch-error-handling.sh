# New test file (not part of the locked/reviewed set) — covers two branches the locked suite
# doesn't pin: a `gh issue view` failure (bad issue number, permissions, transient error) and a
# `gh issue edit` failure (permissions, rate limit) once the repo/issue have already resolved.
# Without an explicit rc check on both calls, the script would fall through to its "queued"/
# whatever-state message with empty/stale data and claim success it didn't achieve — since AC10
# says that stdout line is relayed verbatim as the Slack reply, a false-positive here is a real
# bug class, just one the ticket's own AC list never enumerated (it only covers repo-level
# unreachability, AC5).
#
# `tests/lib/fixture.sh` (locked) already ships a `gh-issue-edit-rc` lever for the edit-failure
# case (used by neither locked test), so that half reuses `mk_fake_gh`/`new_gh_home` as-is. There
# is no equivalent `gh-issue-view-rc` lever, so the view-failure half installs its own small fake
# `gh` (this file's own helper, not a fixture.sh change) that fails on `issue view` specifically.

HERE_PBDE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PBDE="$HERE_PBDE/../pipeline-bridge-dispatch.sh"

# mk_view_failing_gh <dir> — a fake `gh` that succeeds on `repo view` (so reachability passes)
# but fails (exit 1, no stdout) on `issue view`, logging every call like mk_fake_gh does. Any
# other invocation (e.g. `issue edit`) is also logged and fails loudly, so a script that
# incorrectly proceeds past the view failure gets caught by the call-count assertions below.
mk_view_failing_gh() {
  local dir=$1
  mkdir -p "$dir"
  : > "$dir/gh-calls.log"
  cat > "$dir/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$HERE/gh-calls.log"
case "$*" in
  *"repo view"*"--repo "*)
    echo '{"nameWithOwner":"example-owner/project-a"}'
    exit 0
    ;;
  *"issue view"*)
    exit 1
    ;;
  *)
    echo "fake gh (view-failing): unexpected invocation: $*" >&2
    exit 1
    ;;
esac
GH_EOF
  chmod +x "$dir/gh"
}

test_issue_view_failure_never_claims_queued_or_closed() {
  local pipe home ghdir
  pipe=$(new_pipe)
  home=$(new_home)
  ghdir="$home/.local/bin"
  mk_view_failing_gh "$ghdir"
  local out rc
  out=$(PATH="$ghdir:$PATH" PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$SCRIPT_PBDE" 1001 "example-owner/project-a" 2>/dev/null)
  rc=$?
  local edit_calls
  edit_calls=$(gh_call_count "$ghdir" "issue edit")
  rm -rf "$pipe" "$home"
  assert_ne "$rc" "0" "an unreadable issue must not exit 0 (would be relayed as a false-success reply)" || return 1
  assert_not_contains "$out" "queued" "must never claim queued when gh issue view failed" || return 1
  assert_not_contains "$out" "closed" "must never claim a state when gh issue view failed" || return 1
  assert_eq "$edit_calls" "0" "must never call gh issue edit after a failed gh issue view" || return 1
}

test_issue_edit_failure_never_claims_queued() {
  local pipe home ghdir
  pipe=$(new_pipe)
  home=$(new_home)
  ghdir="$home/.local/bin"
  mk_fake_gh "$ghdir"
  echo "example-owner/project-a" > "$ghdir/gh-name-with-owner"
  echo "OPEN" > "$ghdir/gh-issue-state"
  echo "[]" > "$ghdir/gh-issue-labels-json"
  echo 1 > "$ghdir/gh-issue-edit-rc"
  local out rc
  out=$(PATH="$ghdir:$PATH" PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" "$SCRIPT_PBDE" 1002 "example-owner/project-a" 2>/dev/null)
  rc=$?
  local edit_calls
  edit_calls=$(gh_call_count "$ghdir" "issue edit")
  rm -rf "$pipe" "$home"
  assert_ne "$rc" "0" "a failed gh issue edit must not exit 0 (would be relayed as a false-success reply)" || return 1
  assert_not_contains "$out" "queued" "must never claim queued when gh issue edit failed" || return 1
  assert_eq "$edit_calls" "1" "the edit must actually have been attempted exactly once (else this test would pass vacuously)" || return 1
}

run_test test_issue_view_failure_never_claims_queued_or_closed
run_test test_issue_edit_failure_never_claims_queued
