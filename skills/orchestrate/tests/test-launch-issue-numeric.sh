# Issue #123: orchestrate.sh's launch branch rejects a non-numeric issue (^[0-9]+$, same rule as
# pipeline-bridge-dispatch.sh) before any gh call, state file, queue entry or process.
ROOT_LN=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
LAUNCHER_LN="$ROOT_LN/skills/orchestrate/orchestrate.sh"

# ln_run <bad-issue> — runs the launcher against an isolated HOME/PIPE with a stub gh; sets LN_* vars.
ln_run() {
  LN_HOME=$(new_home); LN_PIPE=$(new_pipe); LN_REPO="$LN_HOME/repo"
  fixture_repo "$LN_REPO" project-a/repo
  mkdir -p "$LN_HOME/.local/bin"
  mk_fake_gh "$LN_HOME/.local/bin"
  printf '#!/bin/bash\nexit 0\n' > "$LN_HOME/.local/bin/claude"; chmod +x "$LN_HOME/.local/bin/claude"   # never start a real session
  LN_OUT=$(HOME="$LN_HOME" PIPE="$LN_PIPE" QUEUE="$LN_PIPE/queue" bash "$LAUNCHER_LN" "$LN_REPO" "$1" 2>&1)
  LN_RC=$?
}

test_ln_rejects_non_numeric() {
  local bad
  for bad in stop abc 12x "" "1 2" "-5"; do
    ln_run "$bad"
    assert_ne "$LN_RC" "0" "rc for [$bad]" || return 1
    assert_contains "$LN_OUT" "issue must be a number (got \"$bad\")" "message for [$bad]" || return 1
    assert_eq "$(printf '%s\n' "$LN_OUT" | wc -l | tr -d ' ')" "1" "one-line message for [$bad]" || return 1
    assert_eq "$(gh_call_count "$LN_HOME/.local/bin" "")" "0" "gh calls for [$bad]" || return 1
    assert_eq "$(ls -A "$LN_PIPE" | grep -v '^queue$' | wc -l | tr -d ' ')" "0" "state files for [$bad]" || return 1
    assert_eq "$(ls -A "$LN_PIPE/queue" | wc -l | tr -d ' ')" "0" "queue entries for [$bad]" || return 1
  done
}

test_ln_stop_hint() {
  ln_run stop
  assert_contains "$LN_OUT" "did you mean 'orchestrate.sh stop <N>'?" "hint" || return 1
}

test_ln_numeric_still_launches() {
  ln_run 123   # numeric: passes the check and reaches gh (stub); anything but the format rejection is fine
  assert_not_contains "$LN_OUT" "issue must be a number" "numeric accepted" || return 1
  assert_ne "$(gh_call_count "$LN_HOME/.local/bin" "")" "0" "numeric reaches gh" || return 1
}

run_test test_ln_rejects_non_numeric
run_test test_ln_stop_hint
run_test test_ln_numeric_still_launches
