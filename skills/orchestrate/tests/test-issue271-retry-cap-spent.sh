# claude-agents#271 fix cycle 2 — once the auto-retry cap (3) is spent, a BLOCKED ci_red hold says "waiting on JP",
# not "parked, auto-retry". Prefixed i271c_.
HERE_I271C=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f ar2_install_gh >/dev/null 2>&1; then
  eval "i271c_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_I271C/test-supervisor-auto-retry.sh"
  eval "$(declare -f i271c_real_run_test | sed '1s/i271c_real_run_test/run_test/')"
fi

# i271c_run <retries-spent>
i271c_run() {
  local body="$AR2_BLK"$'\n''Blocked on: ci_red — checks failing'
  sq_env open; sq_free_slots; ar2_install_gh
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"; sq_iso_ago 7200 > "$SQ_PIPE/orch-42.start"
  echo "$1" > "$SQ_PIPE/orch-42.autoretry"
  jq -nc --arg b "$body" '[{body:$b, createdAt:"2026-09-20T10:00:00Z", author:{login:"x"}}]' > "$SQ_GH/gh-issue-comments-json-42"
  echo fail > "$SQ_GH/gh-pr-checks"
  sq_tick
  I271C_ALERT=$(cat "$SQ_PIPE/orch-42.alert" 2>/dev/null)
  sq_cleanup
}

test_i271c_cap_spent_waits_on_jp() {
  i271c_run 3
  assert_contains "$I271C_ALERT" "waiting on JP" "#271: cap spent -> waiting on JP" || return 1
  assert_not_contains "$I271C_ALERT" "parked" "#271: cap spent -> not parked" || return 1
}

test_i271c_retries_remaining_parks() {
  i271c_run 2
  assert_contains "$I271C_ALERT" "parked, auto-retry (ci_red)" "#271: retries left -> parked" || return 1
}

run_test test_i271c_cap_spent_waits_on_jp
run_test test_i271c_retries_remaining_parks
