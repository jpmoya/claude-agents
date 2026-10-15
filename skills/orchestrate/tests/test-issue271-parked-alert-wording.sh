# Tests for claude-agents#271 — a supervisor hold on a BLOCKED whose class is auto-retried (ci_pending/ci_red/
# merge_conflict/dependency) says "parked, auto-retry (<class>)", never "waiting on JP"; other classes keep today's text.
# Reuses the auto-retry test's fake gh (ar2_*), loaded below. Prefixed i271_.
HERE_I271=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f ar2_install_gh >/dev/null 2>&1; then
  eval "i271_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_I271/test-supervisor-auto-retry.sh"
  eval "$(declare -f i271_real_run_test | sed '1s/i271_real_run_test/run_test/')"
fi

# i271_run <line2> — restarting run #42 whose latest gate is a BLOCKED with that line 2; ticks once.
# Sets I271_ALERT / I271_LOG / I271_HELD.
i271_run() {
  local body="$AR2_BLK"
  [ -n "$1" ] && body="$body"$'\n'"$1"
  sq_env open; sq_free_slots; ar2_install_gh
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"; sq_iso_ago 7200 > "$SQ_PIPE/orch-42.start"
  jq -nc --arg b "$body" '[{body:$b, createdAt:"2026-09-20T10:00:00Z", author:{login:"x"}}]' > "$SQ_GH/gh-issue-comments-json-42"
  echo fail > "$SQ_GH/gh-pr-checks"
  sq_tick
  I271_ALERT=$(cat "$SQ_PIPE/orch-42.alert" 2>/dev/null)
  I271_LOG=$(sq_log); [ -n "${I271_DEBUG:-}" ] && echo "LOG: $I271_LOG" >&2
  I271_HELD=$(sq_present "$SQ_PIPE/orch-42.held")
  sq_cleanup
}

test_i271_ci_red_is_parked_not_waiting_on_jp() {
  i271_run 'Blocked on: ci_red — checks failing'
  assert_eq "$I271_HELD" "present" "#271: still held" || return 1
  assert_contains "$I271_ALERT" "parked, auto-retry (ci_red)" "#271: alert says parked + class" || return 1
  assert_contains "$I271_ALERT" "BLOCKED" "#271: alert keeps BLOCKED (auto-retry pre-filter)" || return 1
  assert_not_contains "$I271_ALERT" "waiting on JP" "#271: alert never says waiting on JP" || return 1
  assert_contains "$I271_LOG" "[held] #42 — parked for auto-retry (ci_red)" "#271: log line" || return 1
  assert_not_contains "$I271_LOG" "waiting on JP" "#271: log never says waiting on JP" || return 1
}

test_i271_dependency_is_parked() {
  i271_run 'Blocked on: dependency — needs #9'
  assert_contains "$I271_ALERT" "parked, auto-retry (dependency)" "#271: dependency parked" || return 1
}

test_i271_needs_jp_keeps_waiting_text() {
  i271_run 'Blocked on: needs_jp — pick one'
  assert_contains "$I271_ALERT" "waiting on JP" "#271: needs_jp alert" || return 1
  assert_contains "$I271_LOG" "[held] #42 — waiting on JP" "#271: needs_jp log" || return 1
  assert_not_contains "$I271_ALERT" "parked" "#271: needs_jp not parked" || return 1
}

test_i271_no_class_line_keeps_waiting_text() {
  i271_run ''
  assert_contains "$I271_ALERT" "waiting on JP" "#271: missing class alert" || return 1
  assert_not_contains "$I271_ALERT" "parked" "#271: missing class not parked" || return 1
}

run_test test_i271_ci_red_is_parked_not_waiting_on_jp
run_test test_i271_dependency_is_parked
run_test test_i271_needs_jp_keeps_waiting_text
run_test test_i271_no_class_line_keeps_waiting_text
