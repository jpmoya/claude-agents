# Regression for claude-agents#341 — the runner must pin PIPE_LEGACY away from the host's real /tmp/pipeline,
# or a suite that sources config.sh with PIPE unset moves live run state (scheduler#1372 incident).
#
#   1  runner env: PIPE_LEGACY is set, is not /tmp/pipeline, and does not exist yet
#   2  sentinel in a legacy dir survives sourcing config.sh with PIPE unset under the runner's env
#   3  run-tests.sh with PIPE_LEGACY=/tmp/pipeline exits 2 and says so on stderr
#   4  supervisor: a tick that defers on a live stage logs live_stage + pid + argv (no full command line)
#   5  supervisor: touch_held logs the .held path and the caller

HERE_PL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_PL=$(cd "$HERE_PL/.." && pwd)
if ! declare -f ls_fixture >/dev/null 2>&1; then
  eval "pl_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_PL/test-supervisor-live-stage-defers.sh"
  eval "$(declare -f pl_real_run_test | sed '1s/pl_real_run_test/run_test/')"
fi

test_pl_1_runner_pins_legacy() {
  assert_ne "${PIPE_LEGACY:-}" "" "#341/1: PIPE_LEGACY exported" || return 1
  assert_ne "$PIPE_LEGACY" "/tmp/pipeline" "#341/1: not the real dir" || return 1
  [ ! -e "$PIPE_LEGACY" ] || { fail "#341/1: pinned legacy path should not exist"; return 1; }
}

test_pl_2_sentinel_survives_config_source() {
  local legacy home
  legacy=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-legacy.XXXXXX"); : > "$legacy/sentinel"
  home=$(new_home)
  ( unset PIPE; export HOME="$home" PIPE_LEGACY="$legacy"; . "$SKILL_PL/config.sh" ) >/dev/null 2>&1
  local kept=no moved=no
  [ -e "$legacy/sentinel" ] && kept=yes
  [ -e "$home/.local/state/pipeline/sentinel" ] && moved=yes
  rm -rf "$legacy" "$home"
  assert_eq "$kept" "yes" "#341/2: sentinel stays" || return 1
  assert_eq "$moved" "no" "#341/2: nothing moved into HOME" || return 1
}

test_pl_3_runner_refuses_real_legacy() {
  local err rc
  err=$(PIPE_LEGACY=/tmp/pipeline "$HERE_PL/run-tests.sh" 2>&1 >/dev/null); rc=$?
  assert_eq "$rc" "2" "#341/3: exit code" || return 1
  assert_contains "$err" "PIPE_LEGACY=/tmp/pipeline" "#341/3: stderr message" || return 1
}

test_pl_4_defer_logs_stage_pid_argv() {
  ls_fixture
  ls_tick "printf '1000\t42\tclaude --agent test-writer -p SECRET\t4321\n'"
  local log; log=$(sq_log); sq_cleanup
  assert_contains "$log" "live_stage=test-writer pid=4321 argv=claude --agent test-writer" "#341/4: defer line" || return 1
  case "$log" in *SECRET*) fail "#341/4: full argv leaked"; return 1 ;; esac
}

test_pl_5_touch_held_logs_path_and_caller() {
  local d; d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-held.XXXXXX")
  local out
  out=$(SLOG="$d/log"; eval "$(sed -n '/^slog()/p;/^touch_held()/p' "$SKILL_PL/supervisor.sh")"
        f() { touch_held "$d/orch-x-1.held"; }; f; cat "$d/log")
  local present=no; [ -f "$d/orch-x-1.held" ] && present=yes
  rm -rf "$d"
  assert_eq "$present" "yes" "#341/5: .held created" || return 1
  assert_contains "$out" "[held-touch] path=$d/orch-x-1.held caller=f:" "#341/5: log line" || return 1
}

run_test test_pl_1_runner_pins_legacy
run_test test_pl_2_sentinel_survives_config_source
run_test test_pl_3_runner_refuses_real_legacy
run_test test_pl_4_defer_logs_stage_pid_argv
run_test test_pl_5_touch_held_logs_path_and_caller
