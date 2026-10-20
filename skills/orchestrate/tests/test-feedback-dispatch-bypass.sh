# Test for claude-agents (JP, 2026-10-19): SHARED_DISPATCH_ENABLED=0 turns off step 5 (shared dispatch)
# for ordinary agent-go tickets, but a user-feedback ticket (a staff-reported bug/idea) must still
# dispatch — feedback bugs keep auto-fixing even while the pipeline is otherwise goal-only.
#
#   AC1  SHARED_DISPATCH_ENABLED=0, no extra label      -> gh issue list --search carries no
#                                                           label:"user-feedback" filter is irrelevant;
#                                                           nothing is restricted when enabled (default)
#   AC2  SHARED_DISPATCH_ENABLED=0                       -> the --search passed to `gh issue list`
#                                                           requires label:"user-feedback"
#   AC3  SHARED_DISPATCH_ENABLED=1 (default/unset)       -> --search does NOT require user-feedback

HERE_FD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_DIR_FD="$HERE_FD/.."

fd_env() {
  FD_PIPE=$(new_pipe); FD_HOME=$(new_home)
  FD_REPO="$FD_PIPE/repo-a"
  FD_GH="$FD_HOME/.local/bin"
  fixture_repo "$FD_REPO" "project-a/repo-a"
  mk_fake_gh "$FD_GH"
  mv "$FD_GH/gh" "$FD_GH/gh-base"
  cat > "$FD_GH/gh" <<'GHW'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in
  "issue list"*"--label agent-go"*)
    printf '%s\n' "$*" >> "$HERE/gh-calls.log"
    exit 0 ;;
  "issue list"*)
    printf '%s\n' "$*" >> "$HERE/gh-calls.log"
    exit 0 ;;
  *) exec "$HERE/gh-base" "$@" ;;
esac
GHW
  chmod +x "$FD_GH/gh"
  echo "project-a/repo-a" > "$FD_GH/gh-name-with-owner"
  printf '#!/bin/bash\nexit 0\n' > "$FD_GH/claude"; chmod +x "$FD_GH/claude"
  printf '#!/bin/bash\necho "Now drawing from '"'"'AC Power'"'"'"\n' > "$FD_GH/pmset"; chmod +x "$FD_GH/pmset"
  printf 'MEM_FLOOR_MB=0\nCLAIM_SETTLE_SECS=0\nDISPATCH_REPOS=("project-a/repo-a:%s")\n' "$FD_REPO" > "$FD_HOME/.claude/pipeline/config.local.sh"
}

fd_cleanup() { cleanup_running; rm -rf "$FD_PIPE" "$FD_HOME"; }

fd_run() {
  HOME="$FD_HOME" PATH="$FD_GH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$FD_PIPE" QUEUE="$FD_PIPE/queue" LOGDIR="$FD_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "${1:-$ORCH_DIR_FD/supervisor.sh}" >/dev/null 2>&1
}

fd_search_arg() {
  # the logged `gh issue list --label agent-go ...` call (the one dispatch step 5 makes); $* loses
  # exact argument boundaries, but the label:"user-feedback" substring survives either way.
  grep "issue list.*--label agent-go" "$FD_GH/gh-calls.log" 2>/dev/null | tail -1
}

test_fd_1_shared_dispatch_disabled_requires_feedback_label() {
  fd_env
  printf 'SHARED_DISPATCH_ENABLED=0\n' >> "$FD_HOME/.claude/pipeline/config.local.sh"
  fd_run
  local search; search=$(fd_search_arg)
  fd_cleanup
  assert_contains "$search" 'label:"user-feedback"' "SHARED_DISPATCH_ENABLED=0: dispatch must still search for user-feedback tickets" || return 1
}

test_fd_2_shared_dispatch_enabled_default_has_no_feedback_restriction() {
  fd_env
  fd_run
  local search; search=$(fd_search_arg)
  fd_cleanup
  assert_not_contains "$search" "user-feedback" "SHARED_DISPATCH_ENABLED unset (default on): no user-feedback restriction added" || return 1
}

test_fd_3_shared_dispatch_explicitly_enabled_has_no_feedback_restriction() {
  fd_env
  printf 'SHARED_DISPATCH_ENABLED=1\n' >> "$FD_HOME/.claude/pipeline/config.local.sh"
  fd_run
  local search; search=$(fd_search_arg)
  fd_cleanup
  assert_not_contains "$search" "user-feedback" "SHARED_DISPATCH_ENABLED=1: no user-feedback restriction added" || return 1
}

run_test test_fd_1_shared_dispatch_disabled_requires_feedback_label
run_test test_fd_2_shared_dispatch_enabled_default_has_no_feedback_restriction
run_test test_fd_3_shared_dispatch_explicitly_enabled_has_no_feedback_restriction
