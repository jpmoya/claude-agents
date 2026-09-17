# AC17 — no token or secret value appears in the repo, the PR, the issue, or supervisor.log; a
# secret-pattern/gitleaks-style check runs as part of the PR.
#
# Two halves:
#   (a) gitleaks (available on this host) scans the real files this ticket adds/touches — a check
#       against an artifact that exists right now, so it's expected to be clean today; it becomes
#       a real regression gate the moment the developer's implementation lands.
#   (b) the reporter must log its push decision (per design: "log the decision and HTTP status
#       only... never echo the command or the token") without ever writing a real token into its
#       log file — paired with a positive requirement (the captured log body must be non-empty)
#       so a no-op stub that logs nothing can't pass by never having anything to grep.
#
# The developer's PR-level re-verification (running this same gitleaks check in CI against the
# actual diff/PR/issue text) is a separate obligation, called out in the handoff — this test can
# only scan the working tree it has.

HERE_AC17=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_AC17="$HERE_AC17/.."
ROOT_AC17=$(cd "$HERE_AC17/../../.." && pwd)

test_ac17_gitleaks_clean_on_new_files() {
  command -v gitleaks >/dev/null 2>&1 || { fail "AC17: gitleaks not on PATH — test infra requirement, install it to run this check"; return 1; }
  local report rc
  report=$(mktemp "${TMPDIR:-/tmp}/orch-gitleaks.XXXXXX.json")
  gitleaks detect --no-git --source "$RS_AC17" --report-path "$report" --exit-code 1 >/dev/null 2>&1
  rc=$?
  local findings
  findings=$(cat "$report" 2>/dev/null || echo "[]")
  rm -f "$report"
  assert_exit0 "$rc" "AC17: gitleaks found a potential secret in skills/orchestrate — findings: $findings" || return 1
}

test_ac17_hook_gitleaks_clean() {
  command -v gitleaks >/dev/null 2>&1 || { fail "AC17: gitleaks not on PATH"; return 1; }
  local report rc
  report=$(mktemp "${TMPDIR:-/tmp}/orch-gitleaks.XXXXXX.json")
  gitleaks detect --no-git --source "$ROOT_AC17/hooks/report-status-hook.sh" --report-path "$report" --exit-code 1 >/dev/null 2>&1
  rc=$?
  local findings
  findings=$(cat "$report" 2>/dev/null || echo "[]")
  rm -f "$report"
  assert_exit0 "$rc" "AC17: gitleaks found a potential secret in hooks/report-status-hook.sh — findings: $findings" || return 1
}

test_ac17_reporter_log_never_contains_the_real_token() {
  local pipe home fake_token log_file log_body
  pipe=$(new_pipe); home=$(new_home)
  fake_token="unmistakable-fake-token-value-for-ac17-do-not-leak-1234567890"
  mkdir -p "$home/.claude/pipeline"
  cat > "$home/.claude/pipeline/config.local.sh" <<EOF
STATUS_PUSH_URL="https://example.invalid/beat"
STATUS_PUSH_TOKEN="$fake_token"
EOF
  mk_running "$pipe" 701 "$pipe/repo-project-a"

  ( PIPE="$pipe" QUEUE="$pipe/queue" HOME="$home" LOGDIR="$home/logs/pipeline" "$RS_AC17/report-status.sh" event ) >/dev/null 2>&1
  cleanup_running

  log_file="$home/logs/pipeline/report-status.log"
  log_body=$(cat "$log_file" 2>/dev/null || echo "")
  rm -rf "$pipe" "$home"

  # log_body is "" both when the file is missing and when it exists but is empty, so this one
  # assertion also serves as the positive non-vacuous guard: a no-op stub that never logs
  # anything can't pass by having nothing to grep.
  assert_ne "$log_body" "" "AC17: the reporter must write a non-empty decision/status log entry for this event — a no-op stub that never logs would make the token check vacuous" || return 1
  assert_not_contains "$log_body" "$fake_token" "AC17: STATUS_PUSH_TOKEN must never appear in report-status.log" || return 1
}

run_test test_ac17_gitleaks_clean_on_new_files
run_test test_ac17_hook_gitleaks_clean
run_test test_ac17_reporter_log_never_contains_the_real_token
