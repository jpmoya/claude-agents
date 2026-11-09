# #632 AC5 — the supervisor never sees a direct-route repo: with a config.local.sh that lists jpmoya/claude-agents in both
# DISPATCH_REPOS and SCAN_ONLY_REPOS, one tick logs `dropped direct-route repo jpmoya/claude-agents from DISPATCH_REPOS`
# and `… from SCAN_ONLY_REPOS`, sw_repo_list prints only the app repo, and an open agent-go + user-feedback claude-agents
# ticket returned by the fake gh is never launched, edited or commented on. A control run proves the same harness does
# dispatch such a ticket when it sits in an app repo (so the zero counts are not a broken fixture).
# Harness follows test-feedback-dispatch-bypass.sh (mk_fake_gh base + an `issue list` wrapper; SHARED_DISPATCH_ENABLED=0 so
# the user-feedback exception is the path under test). Prefix drs_ / DRS_. Placeholder app repo (public repo).

HERE_DRS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_DIR_DRS="$HERE_DRS/.."

# drs_env <repo holding the agent-go+user-feedback ticket #627> <owner/repo `repo view` resolves to> <both|app>
#   both: DISPATCH_REPOS lists claude-agents (first) and the app repo, SCAN_ONLY_REPOS lists claude-agents; app: the app repo only
drs_env() {
  DRS_PIPE=$(new_pipe); DRS_HOME=$(new_home); DRS_BIN="$DRS_HOME/.local/bin"
  DRS_A="$DRS_PIPE/repo-a"; DRS_CA="$DRS_PIPE/repo-ca"
  fixture_repo "$DRS_A" example-owner/project-a
  fixture_repo "$DRS_CA" jpmoya/claude-agents
  mk_fake_gh "$DRS_BIN"
  mv "$DRS_BIN/gh" "$DRS_BIN/gh-base"
  printf '%s' "$1" > "$DRS_BIN/ticket-repo"
  echo "$2" > "$DRS_BIN/gh-name-with-owner"
  printf '%s' "$DRS_PIPE" > "$DRS_BIN/pipe-dir"
  cat > "$DRS_BIN/gh" <<'GHW'
#!/bin/bash
# `issue list`: answered here, tagged with the fixture checkout it was run from (cwd outside the fixture tree, e.g. the test
# runner's own checkout, is tagged "-"); everything else goes to the mk_fake_gh base.
HERE=$(cd "$(dirname "$0")" && pwd)
slug="-"
case "$PWD" in "$(cat "$HERE/pipe-dir")"/*) slug=$(git remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##') ;; esac
repo=""; expr=""; prev=""
for a in "$@"; do case "$prev" in --repo|-R) repo=$a ;; --jq|-q) expr=$a ;; esac; prev=$a; done
case "$*" in
  "issue list"*)
    printf 'cwd=%s repo=%s %s\n' "$slug" "$repo" "$*" >> "$HERE/gh-calls.log"
    out='[]'
    case "$*" in *"--label agent-go"*)
      if [ "${repo:-$slug}" = "$(cat "$HERE/ticket-repo")" ]; then
        out='[{"number":627,"title":"direct-route ticket","labels":[{"name":"agent-go"},{"name":"user-feedback"}],"milestone":null}]'
      fi ;;
    esac
    if [ -n "$expr" ]; then printf '%s' "$out" | jq -r "$expr"; else printf '%s\n' "$out"; fi
    exit 0 ;;
  *) printf 'cwd=%s %s\n' "$slug" "$*" >> "$HERE/gh-calls.log"; exec "$HERE/gh-base" "$@" ;;
esac
GHW
  chmod +x "$DRS_BIN/gh"
  : > "$DRS_BIN/claude.log"
  printf '#!/bin/bash\necho "$* | ISSUE=${PIPELINE_ISSUE:-}" >> "%s/claude.log"\nexit 0\n' "$DRS_BIN" > "$DRS_BIN/claude"
  printf '#!/bin/bash\necho "Now drawing from '"'"'AC Power'"'"'"\n' > "$DRS_BIN/pmset"
  chmod +x "$DRS_BIN/claude" "$DRS_BIN/pmset"
  {
    printf 'MEM_FLOOR_MB=0\nCLAIM_SETTLE_SECS=0\nSHARED_DISPATCH_ENABLED=0\n'
    if [ "$3" = both ]; then
      printf 'DISPATCH_REPOS=("jpmoya/claude-agents:%s" "example-owner/project-a:%s")\nSCAN_ONLY_REPOS=("jpmoya/claude-agents")\n' "$DRS_CA" "$DRS_A"
    else
      printf 'DISPATCH_REPOS=("example-owner/project-a:%s")\n' "$DRS_A"
    fi
  } > "$DRS_HOME/.claude/pipeline/config.local.sh"
}

drs_tick() {
  HOME="$DRS_HOME" PATH="$DRS_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$DRS_PIPE" QUEUE="$DRS_PIPE/queue" LOGDIR="$DRS_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" /bin/bash "$ORCH_DIR_DRS/supervisor.sh" >/dev/null 2>&1
  /bin/sleep 1.5   # the launched `claude` stub and the detached wrapper record asynchronously
}

# drs_sw_repo_list — sw_repo_list as the supervisor defines it (the function is self-contained), over the fixture config
drs_sw_repo_list() {
  HOME="$DRS_HOME" PIPE="$DRS_PIPE" bash -c '. "$1/config.sh"; eval "$(sed -n "/^sw_repo_list()/,/^}/p" "$1/supervisor.sh")"; sw_repo_list' _ "$ORCH_DIR_DRS"
}

drs_cleanup() {
  local f pid
  for f in "$DRS_PIPE"/orch-*.pid; do
    [ -e "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null); [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  done
  cleanup_running; rm -rf "$DRS_PIPE" "$DRS_HOME"
}

test_drs_ac5_tick_drops_the_repo_and_never_touches_its_agent_go_ticket() {
  # the fake answers every `repo view` with one name: it must be the app repo's, or canonicalize_repo_lists would "rename"
  # the app entry into the direct-route repo (a fixture artefact, not a pipeline path)
  drs_env jpmoya/claude-agents example-owner/project-a both
  local rc=0 log calls launched lists
  drs_tick
  log=$(cat "$DRS_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  calls=$(cat "$DRS_BIN/gh-calls.log" 2>/dev/null)
  launched=$(grep -c . "$DRS_BIN/claude.log")
  lists=$(drs_sw_repo_list)
  assert_contains "$log" "[config] dropped direct-route repo jpmoya/claude-agents from DISPATCH_REPOS" "AC5: DISPATCH_REPOS drop is logged" || rc=1
  assert_contains "$log" "[config] dropped direct-route repo jpmoya/claude-agents from SCAN_ONLY_REPOS" "AC5: SCAN_ONLY_REPOS drop is logged" || rc=1
  assert_eq "$lists" "example-owner/project-a" "AC5: sw_repo_list prints only the app repo" || rc=1
  assert_eq "$launched" "0" "AC5: the claude-agents agent-go+user-feedback ticket is never launched" || rc=1
  assert_not_contains "$calls" "cwd=jpmoya/claude-agents" "AC5: no gh call is ever made from the claude-agents checkout" || rc=1
  assert_not_contains "$calls" "repo=jpmoya/claude-agents" "AC5: no gh call names the claude-agents repo" || rc=1
  assert_eq "$(printf '%s\n' "$calls" | grep -cE ' issue (edit|comment) 627 ' || true)" "0" "AC5: #627 gets no label edit and no comment" || rc=1
  assert_not_contains "$log" "jpmoya/claude-agents#627" "AC5: the supervisor never considered #627" || rc=1
  drs_cleanup; return $rc
}

test_drs_ac5_control_same_harness_dispatches_the_ticket_from_an_app_repo() {
  drs_env example-owner/project-a example-owner/project-a app
  local rc=0 launched log
  drs_tick
  launched=$(grep -c . "$DRS_BIN/claude.log")
  log=$(cat "$DRS_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  assert_eq "$launched" "1" "AC5 control: the same user-feedback ticket in an app repo is dispatched (log: $(printf '%s' "$log" | grep dispatch | tail -3 | tr '\n' '|'))" || rc=1
  assert_not_contains "$log" "dropped direct-route repo" "AC5 control: nothing dropped when no direct-route entry is configured" || rc=1
  drs_cleanup; return $rc
}

test_drs_supervisor_never_names_the_scan_only_list_outside_the_digest() {
  # test-scan-only-repos.sh 5d keeps supervisor.sh from reading SCAN_ONLY_REPOS directly; the drop happens in config.sh,
  # the supervisor only logs DIRECT_ROUTE_DROPPED — pinned here so a later "quick fix" does not move the filter into a step.
  assert_eq "$(grep -c 'direct_route_drop\|direct_route_repo' "$ORCH_DIR_DRS/supervisor.sh")" "0" "the filter lives in config.sh, not in a supervisor step" || return 1
  assert_eq "$(grep -c 'DIRECT_ROUTE_DROPPED' "$ORCH_DIR_DRS/supervisor.sh")" "1" "the supervisor logs the drops exactly once per tick" || return 1
}

echo "-- direct-route repos: supervisor (issue #632 AC5)"
run_test test_drs_ac5_tick_drops_the_repo_and_never_touches_its_agent_go_ticket
run_test test_drs_ac5_control_same_harness_dispatches_the_ticket_from_an_app_repo
run_test test_drs_supervisor_never_names_the_scan_only_list_outside_the_digest
