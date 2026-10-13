# Tests for claude-agents#125 — the hold check's "since" must not depend on GNU `date -d` (macOS/BSD date rejects it).
# A `date` stub that rejects -d sits first on PATH; the structural-hold branch must still hold / still restart.
# Reuses the sq_* / ms_* helpers (same load trick as test-merged-pr-structural-hold.sh).

HERE_BD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_BD=$(cd "$HERE_BD/../../.." && pwd)

if ! declare -f ms_exited_run >/dev/null 2>&1; then
  eval "bd_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_BD/test-merged-pr-structural-hold.sh"
  eval "$(declare -f bd_real_run_test | sed '1s/bd_real_run_test/run_test/')"
fi

# BSD-like date: any -d argument is illegal, everything else goes to the real date.
bd_install_date_stub() {
  cat > "$SQ_GH/date" <<'STUB'
#!/bin/bash
for a in "$@"; do
  case "$a" in -d|-d*) echo "date: illegal option -- d" >&2; exit 1 ;; esac
done
exec /bin/date "$@"
STUB
  chmod +x "$SQ_GH/date"
}

# bd_run <stage> <secs-ago> — like ms_exited_run, with the BSD date stub installed
bd_run() {
  sq_env open
  bd_install_date_stub
  mk_restarting "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  sq_marker "$MS_IMPL"
  ms_seed_run_line "$1" "$2"
  sq_tick
  BD_LOG=$(sq_log)
  BD_HELD=$(sq_present "$SQ_PIPE/orch-42.held")
  sq_cleanup
}

test_bd_structural_fail_this_run_holds_without_gnu_date() {
  bd_run structural 60
  assert_eq "$BD_HELD" "present" "#125: held with BSD date" || return 1
  assert_contains "$BD_LOG" "[held] #42" "#125: [held] logged" || return 1
  assert_not_contains "$BD_LOG" "[queue-restart] #42" "#125: no restart" || return 1
}

test_bd_structural_fail_earlier_run_restarts_without_gnu_date() {
  bd_run structural 1200
  assert_contains "$BD_LOG" "[queue-restart] #42" "#125: stale fail still restarts" || return 1
  assert_eq "$BD_HELD" "absent" "#125: not held" || return 1
}

test_bd_no_gnu_date_flag_in_supervisor() {
  if grep -nE 'date[^|;]* -d[ "]' "$ROOT_BD/skills/orchestrate/supervisor.sh" | grep -v '^\s*#' | grep -q .; then
    fail "supervisor.sh still uses date -d"; return 1
  fi
}

run_test test_bd_structural_fail_this_run_holds_without_gnu_date
run_test test_bd_structural_fail_earlier_run_restarts_without_gnu_date
run_test test_bd_no_gnu_date_flag_in_supervisor
