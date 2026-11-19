# #778 — status-page-deploy.sh: deploys status-page/ from the supervisor tick when the status-page/ tree on origin/main differs from the last
# deployed tree. A real git fixture (a local bare "origin" + a clone, so `git fetch` is real and offline); stub npm / wrangler / curl first on
# PATH. Fixture files in the sandbox HOME drive the stubs:
#   fail-npm-install | fail-npm-test | fail-deploy   the step exits 1 (and prints a line holding a fake secret that must never reach a log or Slack)
#   deploy-sleep                                      seconds `wrangler deploy` takes (the two-instance test)
# Every npm / wrangler call is appended to calls.log ("<tool> <args> | cwd=<dir>"), every curl body to curl.log. Expected values are hand-written
# from the ticket. Placeholder names only; the tokens below are fixtures, not credentials.

HERE_SPD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SPD="$HERE_SPD/../status-page-deploy.sh"
SPD_TOKEN="cf-fixture-token-do-not-print"
SPD_HOOK="https://example.invalid/hook-secret-token"

spd_setup() {
  SPD_HOME=$(new_home); mkdir -p "$SPD_HOME/bin" "$SPD_HOME/pipe"
  : > "$SPD_HOME/calls.log"; : > "$SPD_HOME/curl.log"
  cat > "$SPD_HOME/bin/npm" <<'STUB'
#!/bin/bash
echo "npm $* | cwd=$(pwd)" >> "$HOME/calls.log"
case "$1" in
  install) [ -f "$HOME/fail-npm-install" ] && { echo "npm ERR! leaked fixture-secret-output" >&2; exit 1; } ;;
  test)    [ -f "$HOME/fail-npm-test" ] && { echo "FAIL leaked fixture-secret-output" >&2; exit 1; } ;;
esac
exit 0
STUB
  cat > "$SPD_HOME/bin/wrangler" <<'STUB'
#!/bin/bash
echo "wrangler $* | cwd=$(pwd) | token=${CLOUDFLARE_API_TOKEN:-unset}" >> "$HOME/calls.log"
[ -f "$HOME/deploy-sleep" ] && sleep "$(cat "$HOME/deploy-sleep")"
[ -f "$HOME/fail-deploy" ] && { echo "Error: leaked fixture-secret-output" >&2; exit 1; }
echo "Deployed"; exit 0
STUB
  cat > "$SPD_HOME/bin/curl" <<'STUB'
#!/bin/bash
prev=""; for a in "$@"; do [ "$prev" = "--data" ] && echo "$a" >> "$HOME/curl.log"; prev=$a; done; echo ok
STUB
  chmod +x "$SPD_HOME/bin/npm" "$SPD_HOME/bin/wrangler" "$SPD_HOME/bin/curl"
  printf 'SLACK_WEBHOOK_URL=%s\nCLOUDFLARE_API_TOKEN=%s\n' "$SPD_HOOK" "$SPD_TOKEN" > "$SPD_HOME/.claude/pipeline/config.local.sh"
  # origin (bare) + the host's checkout, with status-page/ and an unrelated top-level file
  SPD_ORIGIN="$SPD_HOME/origin.git"; SPD_REPO="$SPD_HOME/checkout"; SPD_OTHER="$SPD_HOME/other"
  git init -q --bare -b main "$SPD_ORIGIN"
  git clone -q "$SPD_ORIGIN" "$SPD_OTHER" 2>/dev/null
  ( cd "$SPD_OTHER" && git config user.email t@example.invalid && git config user.name t && git checkout -q -b main 2>/dev/null
    mkdir -p status-page/src && echo '{"name":"status-page"}' > status-page/package.json && echo v1 > status-page/src/a.js && echo docs > README.md
    git add -A && git commit -q -m init && git push -q origin main 2>/dev/null )
  git clone -q "$SPD_ORIGIN" "$SPD_REPO" 2>/dev/null
  SPD_TREE1=$(git -C "$SPD_REPO" rev-parse origin/main:status-page)
}
spd_push() {  # spd_push <file> <content> — a commit on origin/main (not yet in the host's checkout refs until the script fetches)
  ( cd "$SPD_OTHER" && mkdir -p "$(dirname "$1")" && echo "$2" > "$1" && git add -A && git commit -q -m "change $1" && git push -q origin main 2>/dev/null )
}
spd_stamp() { mkdir -p "$SPD_HOME/pipe/status-page-deploy"; printf '%s\n' "$1" > "$SPD_HOME/pipe/status-page-deploy/last-deployed-tree"; }
spd_stamp_value() { cat "$SPD_HOME/pipe/status-page-deploy/last-deployed-tree" 2>/dev/null; }
spd_env() {  # the sandbox environment, as KEY=VALUE words for `env`
  printf '%s\n' "HOME=$SPD_HOME" "PATH=$SPD_HOME/bin:/usr/bin:/bin:/usr/local/bin" "PIPE=$SPD_HOME/pipe" "LOGDIR=$SPD_HOME/logs/pipeline" \
    "STATUS_PAGE_DEPLOY_REPO=$SPD_REPO" "STATUS_PAGE_DEPLOY_ENABLED=${SPD_ENABLED:-1}" "STATUS_PAGE_DEPLOY_RETRY_SECS=${SPD_RETRY:-0}" "STATUS_PAGE_DEPLOY_MIN_INTERVAL_SECS=${SPD_MIN:-0}" \
    "STATUS_PAGE_WRANGLER=${SPD_WRANGLER:-$SPD_HOME/bin/wrangler}" "STATUS_PAGE_NPM=$SPD_HOME/bin/npm"
}
spd_run() {  # one pass in the sandbox; sets SPD_RC. The suite's test-disable marker is removed for this call only.
  local envs; envs=$(spd_env)
  # shellcheck disable=SC2086
  env -u STATUS_PAGE_DEPLOY_TEST_DISABLE $(printf '%s ' $envs) ${SPD_EXTRA_ENV:-} /bin/bash "$SPD" >"$SPD_HOME/out.log" 2>&1; SPD_RC=$?
}
spd_calls() { grep -c -- "$1" "$SPD_HOME/calls.log" 2>/dev/null | head -1; }
spd_log() { cat "$SPD_HOME/logs/pipeline/status-page-deploy.log" 2>/dev/null; }
spd_posts() { grep -c . "$SPD_HOME/curl.log" 2>/dev/null | head -1; }
spd_worktrees() { git -C "$SPD_REPO" worktree list | wc -l | tr -d ' '; }
spd_everything() { cat "$SPD_HOME/out.log" "$SPD_HOME/curl.log" "$SPD_HOME/logs/pipeline/status-page-deploy.log" 2>/dev/null; }

test_spd_unchanged_tree_is_a_no_op_beyond_the_fetch() {
  spd_setup; spd_stamp "$SPD_TREE1"; rm -f "$SPD_REPO/.git/FETCH_HEAD"
  spd_run
  assert_exit0 "$SPD_RC" "run" || return 1
  assert_eq "$(wc -c < "$SPD_HOME/calls.log" | tr -d ' ')" "0" "no npm / wrangler call" || return 1
  assert_eq "$(spd_posts)" "0" "no Slack post and no other network call" || return 1
  assert_eq "$(spd_stamp_value)" "$SPD_TREE1" "stamp unchanged" || return 1
  [ -f "$SPD_REPO/.git/FETCH_HEAD" ] || { fail "AC1: the fetch (the only network call) ran"; return 1; }
}

test_spd_changed_tree_deploys_once_from_a_throwaway_worktree_and_stamps() {
  spd_setup; spd_stamp "$SPD_TREE1"
  spd_push status-page/src/a.js v2
  local tree2; tree2=$(git -C "$SPD_OTHER" rev-parse HEAD:status-page)
  spd_run
  assert_exit0 "$SPD_RC" "run" || return 1
  assert_eq "$(spd_calls '^npm install')" "1" "one install" || return 1
  assert_eq "$(spd_calls '^npm test')" "1" "one test run (the gate)" || return 1
  assert_eq "$(spd_calls '^wrangler deploy')" "1" "one deploy" || return 1
  local cwd; cwd=$(grep '^wrangler deploy' "$SPD_HOME/calls.log" | sed 's/.*| cwd=\([^ ]*\).*/\1/')
  case "$cwd" in */status-page) ;; *) fail "deploy runs inside status-page/, got [$cwd]"; return 1 ;; esac
  case "$cwd" in "$SPD_REPO"/*) fail "never the live checkout, got [$cwd]"; return 1 ;; esac
  assert_contains "$(grep '^wrangler deploy' "$SPD_HOME/calls.log")" "token=$SPD_TOKEN" "wrangler gets the host's existing token (CLOUDFLARE_API_TOKEN)" || return 1
  assert_eq "$(spd_stamp_value)" "$tree2" "stamp = the deployed status-page tree hash" || return 1
  assert_eq "$(spd_worktrees)" "1" "the throwaway worktree is gone" || return 1
  case "$(spd_log | cut -d' ' -f1)" in *[!0-9]*|'') fail "heartbeat line starts with an epoch"; return 1 ;; esac
  assert_contains "$(spd_log)" " status-page $tree2 ok" "AC5 heartbeat: <epoch> status-page <tree> ok" || return 1
  spd_run   # same tree again: nothing more
  assert_eq "$(spd_calls '^wrangler deploy')" "1" "second pass on the same tree does not redeploy" || return 1
}

test_spd_a_first_run_with_no_stamp_deploys() {
  spd_setup
  spd_run
  assert_eq "$(spd_calls '^wrangler deploy')" "1" "no stamp = never deployed = deploy" || return 1
  assert_eq "$(spd_stamp_value)" "$SPD_TREE1" "stamped" || return 1
}

test_spd_a_commit_outside_status_page_does_not_deploy() {
  spd_setup; spd_stamp "$SPD_TREE1"
  spd_push README.md "docs only"
  spd_run
  assert_eq "$(wc -c < "$SPD_HOME/calls.log" | tr -d ' ')" "0" "a docs-only commit changes no status-page tree: no npm, no deploy" || return 1
  assert_eq "$(spd_stamp_value)" "$SPD_TREE1" "stamp unchanged" || return 1
}

test_spd_a_failing_npm_test_never_deploys_never_stamps_and_leaves_no_worktree() {
  spd_setup; spd_stamp "$SPD_TREE1"; spd_push status-page/src/a.js v2; : > "$SPD_HOME/fail-npm-test"
  spd_run
  assert_exit0 "$SPD_RC" "a failed deploy is non-fatal for the supervisor" || return 1
  assert_eq "$(spd_calls '^wrangler')" "0" "no deploy after a red test" || return 1
  assert_eq "$(spd_stamp_value)" "$SPD_TREE1" "no stamp" || return 1
  assert_eq "$(spd_worktrees)" "1" "no worktree left behind" || return 1
  assert_eq "$(spd_posts)" "1" "one alert" || return 1
  assert_contains "$(cat "$SPD_HOME/curl.log")" "npm test" "the alert names the failing step" || return 1
}

test_spd_a_failing_npm_install_never_deploys_and_never_stamps() {
  spd_setup; spd_stamp "$SPD_TREE1"; spd_push status-page/src/a.js v2; : > "$SPD_HOME/fail-npm-install"
  spd_run
  assert_eq "$(spd_calls '^npm test')$(spd_calls '^wrangler')" "00" "nothing after the failed install" || return 1
  assert_eq "$(spd_stamp_value)" "$SPD_TREE1" "no stamp" || return 1
  assert_contains "$(cat "$SPD_HOME/curl.log")" "npm install" "the alert names the failing step" || return 1
}

test_spd_a_failing_deploy_stamps_nothing_and_alerts_once_per_tree_per_hour() {
  spd_setup; spd_stamp "$SPD_TREE1"; spd_push status-page/src/a.js v2; : > "$SPD_HOME/fail-deploy"
  local tree2; tree2=$(git -C "$SPD_OTHER" rev-parse HEAD:status-page)
  spd_run; spd_run   # retry backoff is 0 in this test: the second pass really runs and fails again
  assert_eq "$(spd_calls '^wrangler deploy')" "2" "the failed deploy is retried on the next tick" || return 1
  assert_eq "$(spd_stamp_value)" "$SPD_TREE1" "no stamp after a failed deploy" || return 1
  assert_eq "$(spd_posts)" "1" "AC4: a second failure within the hour posts nothing more" || return 1
  local body; body=$(cat "$SPD_HOME/curl.log")
  assert_contains "$body" "${tree2:0:7}" "AC4: the short tree hash" || return 1
  assert_contains "$body" "wrangler deploy" "AC4: the failing step" || return 1
  assert_contains "$body" "route=status-page-deploy" "observability tags: route" || return 1
  assert_contains "$body" "environment=" "observability tags: environment" || return 1
  assert_contains "$body" "release=$(git -C "$SPD_REPO" rev-parse origin/main)" "observability tags: release = the full commit SHA of origin/main" || return 1
  assert_not_contains "$(spd_everything)" "fixture-secret-output" "no command output reaches the log, stdout or Slack" || return 1
  assert_not_contains "$(spd_everything)" "$SPD_TOKEN" "the Cloudflare token is never printed or posted" || return 1
  assert_not_contains "$(spd_everything)" "hook-secret-token" "the Slack webhook is never printed" || return 1
  # a new tree is a new failure: it gets its own post
  spd_push status-page/src/a.js v3; spd_run
  assert_eq "$(spd_posts)" "2" "a different failing tree alerts once more" || return 1
  assert_eq "$(spd_worktrees)" "1" "no worktree left behind" || return 1
}

test_spd_a_failed_deploy_backs_off_before_retrying_the_same_tree() {
  spd_setup; spd_stamp "$SPD_TREE1"; spd_push status-page/src/a.js v2; : > "$SPD_HOME/fail-deploy"
  SPD_RETRY=600 spd_run; SPD_RETRY=600 spd_run
  assert_eq "$(spd_calls '^wrangler deploy')" "1" "the second tick within the retry window does not run npm / wrangler again" || return 1
  assert_eq "$(spd_calls '^npm install')" "1" "nor install" || return 1
}

test_spd_looks_at_origin_at_most_once_per_interval() {
  spd_setup; spd_stamp "$SPD_TREE1"
  SPD_MIN=300 spd_run; spd_push status-page/src/a.js v2; SPD_MIN=300 spd_run
  assert_eq "$(spd_calls '^wrangler')" "0" "a second tick inside the interval does not even fetch, so the new tree waits" || return 1
  SPD_MIN=0 spd_run
  assert_eq "$(spd_calls '^wrangler deploy')" "1" "after the interval it deploys" || return 1
}

test_spd_the_flag_off_is_a_total_no_op_with_no_fetch() {
  spd_setup; spd_push status-page/src/a.js v2; rm -f "$SPD_REPO/.git/FETCH_HEAD"
  SPD_ENABLED=0 spd_run
  assert_exit0 "$SPD_RC" "run" || return 1
  assert_eq "$(wc -c < "$SPD_HOME/calls.log" | tr -d ' ')" "0" "nothing runs" || return 1
  [ ! -f "$SPD_REPO/.git/FETCH_HEAD" ] || { fail "AC3: not even a fetch"; return 1; }
  [ -z "$(spd_stamp_value)" ] || { fail "no stamp"; return 1; }
  # unset = off as well (default 0)
  local envs; envs=$(spd_env | grep -v STATUS_PAGE_DEPLOY_ENABLED)
  # shellcheck disable=SC2086
  env -u STATUS_PAGE_DEPLOY_ENABLED -u STATUS_PAGE_DEPLOY_TEST_DISABLE $(printf '%s ' $envs) /bin/bash "$SPD" >/dev/null 2>&1
  assert_eq "$(spd_calls '^wrangler')" "0" "default is off" || return 1
}

test_spd_the_test_harness_marker_beats_an_enabled_host_config() {
  spd_setup; spd_push status-page/src/a.js v2
  printf 'STATUS_PAGE_DEPLOY_ENABLED=1\n' >> "$SPD_HOME/.claude/pipeline/config.local.sh"
  local envs; envs=$(spd_env | grep -v STATUS_PAGE_DEPLOY_ENABLED)
  # shellcheck disable=SC2086
  env STATUS_PAGE_DEPLOY_TEST_DISABLE=1 $(printf '%s ' $envs) /bin/bash "$SPD" >/dev/null 2>&1
  assert_eq "$(spd_calls '^wrangler')" "0" "run-tests.sh's STATUS_PAGE_DEPLOY_TEST_DISABLE=1 wins over a host config.local.sh that turns it on" || return 1
  assert_contains "$(grep -n 'STATUS_PAGE_DEPLOY' "$HERE_SPD/run-tests.sh")" "STATUS_PAGE_DEPLOY_TEST_DISABLE=1" "the runner exports the marker" || return 1
}

test_spd_no_wrangler_or_no_credentials_is_a_quiet_non_fatal_no_op() {
  spd_setup; spd_push status-page/src/a.js v2; rm -f "$SPD_REPO/.git/FETCH_HEAD"
  SPD_WRANGLER="$SPD_HOME/bin/does-not-exist" spd_run
  assert_exit0 "$SPD_RC" "no wrangler: exit 0" || return 1
  assert_eq "$(spd_calls '^npm')" "0" "no wrangler: nothing runs" || return 1
  assert_eq "$(spd_posts)" "0" "no wrangler: no Slack post" || return 1
  [ -z "$(spd_stamp_value)" ] || { fail "no stamp"; return 1; }
  printf 'SLACK_WEBHOOK_URL=%s\n' "$SPD_HOOK" > "$SPD_HOME/.claude/pipeline/config.local.sh"   # now: wrangler present, no token, no login file
  spd_run
  assert_exit0 "$SPD_RC" "no credentials: exit 0" || return 1
  assert_eq "$(spd_calls '^npm')$(spd_calls '^wrangler')" "00" "no credentials: nothing runs" || return 1
  assert_eq "$(spd_posts)" "0" "no credentials: no Slack post" || return 1
}

test_spd_two_concurrent_passes_deploy_once() {
  spd_setup; spd_stamp "$SPD_TREE1"; spd_push status-page/src/a.js v2; echo 2 > "$SPD_HOME/deploy-sleep"
  local envs; envs=$(spd_env)
  # shellcheck disable=SC2086
  env -u STATUS_PAGE_DEPLOY_TEST_DISABLE $(printf '%s ' $envs) /bin/bash "$SPD" >/dev/null 2>&1 & local p1=$!
  sleep 1
  # shellcheck disable=SC2086
  env -u STATUS_PAGE_DEPLOY_TEST_DISABLE $(printf '%s ' $envs) /bin/bash "$SPD" >/dev/null 2>&1 & local p2=$!
  wait "$p1" "$p2"
  assert_eq "$(spd_calls '^wrangler deploy')" "1" "the per-host lock: one deploy" || return 1
  assert_eq "$(spd_worktrees)" "1" "no worktree left behind" || return 1
}

test_spd_wired_into_the_supervisor_tick_rotation_and_docs() {
  local sup rot readme
  sup=$(cat "$HERE_SPD/../supervisor.sh"); rot=$(cat "$HERE_SPD/../rotate-logs.sh"); readme=$(cat "$HERE_SPD/../../../status-page/README.md")
  assert_contains "$sup" 'status-page-deploy.sh' "AC1: the supervisor tick calls it" || return 1
  assert_contains "$(grep -n 'status-page-deploy.sh' "$HERE_SPD/../supervisor.sh")" '9>&-' "backgrounded without the tick's lock fd" || return 1
  assert_contains "$(grep -n 'status-page-deploy.sh' "$HERE_SPD/../supervisor.sh")" 'STATUS_PAGE_DEPLOY_ENABLED' "only when the flag is on" || return 1
  assert_contains "$rot" 'status-page-deploy.log' "AC5: rotated by rotate-logs.sh" || return 1
  assert_not_contains "$readme" 'deploy-status-page.yml' "AC7: no stale workflow reference" || return 1
  assert_contains "$readme" 'status-page-deploy.sh' "AC7: the deploy section describes the supervisor step" || return 1
  [ ! -e "$HERE_SPD/../../../.github/workflows/deploy-status-page.yml" ] || { fail "the dead workflow stays gone"; return 1; }
}

run_test test_spd_unchanged_tree_is_a_no_op_beyond_the_fetch
run_test test_spd_changed_tree_deploys_once_from_a_throwaway_worktree_and_stamps
run_test test_spd_a_first_run_with_no_stamp_deploys
run_test test_spd_a_commit_outside_status_page_does_not_deploy
run_test test_spd_a_failing_npm_test_never_deploys_never_stamps_and_leaves_no_worktree
run_test test_spd_a_failing_npm_install_never_deploys_and_never_stamps
run_test test_spd_a_failing_deploy_stamps_nothing_and_alerts_once_per_tree_per_hour
run_test test_spd_a_failed_deploy_backs_off_before_retrying_the_same_tree
run_test test_spd_looks_at_origin_at_most_once_per_interval
run_test test_spd_the_flag_off_is_a_total_no_op_with_no_fetch
run_test test_spd_the_test_harness_marker_beats_an_enabled_host_config
run_test test_spd_no_wrangler_or_no_credentials_is_a_quiet_non_fatal_no_op
run_test test_spd_two_concurrent_passes_deploy_once
run_test test_spd_wired_into_the_supervisor_tick_rotation_and_docs
