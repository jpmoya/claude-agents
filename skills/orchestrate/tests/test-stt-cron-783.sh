# #783 — scheduled-triggers.sh runs from its own 1-minute cron job, not from the supervisor tick.
# Reuses helpers from earlier-sorted files (test-install-backfill-cron.sh: ic_*, test-scheduled-triggers.sh: stt_*); this file's name
# sorts after both on purpose. Placeholder repo names only.

STG_LINE_RE='^\* \* \* \* \* .*/\.claude/skills/orchestrate/scheduled-triggers\.sh run >> .*/logs/pipeline/scheduled-triggers-cron\.log 2>&1$'

stg_enable() { printf 'SCHEDULED_TRIGGERS_ENABLED=1\n' >> "$IC_HOME/.claude/pipeline/config.local.sh"; }
stg_lines() { grep -c 'orchestrate/scheduled-triggers\.sh' "$IC_TAB"; }

test_stt783_ac1_install_adds_exactly_one_line_when_enabled_and_twice_leaves_one() {
  ic_setup; mkdir -p "$IC_HOME/.claude/pipeline"; stg_enable
  ic_install --minute even; local rc=$?
  [ "$rc" -ne 99 ] || { fail "refused to run (crontab not stubbed)"; rm -rf "$IC_HOME"; return 1; }
  ic_install --minute even
  local r=0
  assert_eq "$(stg_lines)" "1" "one scheduled-triggers line after two installs" || r=1
  assert_eq "$(grep -c -E "$STG_LINE_RE" "$IC_TAB")" "1" "the line is '* * * * * <path>/scheduled-triggers.sh run >> <logs>/scheduled-triggers-cron.log 2>&1'" || r=1
  assert_contains "$(cat "$IC_TAB")" "0 14 * * 1 /usr/bin/true" "unrelated seeded line kept" || r=1
  assert_eq "$(grep -c 'orchestrate/session-backfill\.sh' "$IC_TAB")" "1" "other managed lines unchanged" || r=1
  rm -rf "$IC_HOME"; return $r
}

test_stt783_ac1_no_line_when_disabled_and_it_is_removed_when_switched_off() {
  ic_setup; mkdir -p "$IC_HOME/.claude/pipeline"
  ic_install --minute even; local rc=$?
  [ "$rc" -ne 99 ] || { fail "refused to run (crontab not stubbed)"; rm -rf "$IC_HOME"; return 1; }
  local r=0
  assert_eq "$(stg_lines)" "0" "absent by default (no flag)" || r=1
  stg_enable; ic_install --minute even
  assert_eq "$(stg_lines)" "1" "added once the flag is on" || r=1
  : > "$IC_HOME/.claude/pipeline/config.local.sh"; printf 'SCHEDULED_TRIGGERS_ENABLED=0\n' > "$IC_HOME/.claude/pipeline/config.local.sh"
  ic_install --minute even
  assert_eq "$(stg_lines)" "0" "removed when the flag is turned off" || r=1
  rm -rf "$IC_HOME"; return $r
}

test_stt783_ac1_a_stale_copy_at_another_path_collapses_to_one() {
  ic_setup; mkdir -p "$IC_HOME/.claude/pipeline"; stg_enable
  printf '* * * * * /old/orchestrate/scheduled-triggers.sh run >/dev/null 2>&1\n' >> "$IC_TAB"
  ic_install --minute even
  local r=0
  assert_eq "$(stg_lines)" "1" "old copy replaced, one left" || r=1
  assert_not_contains "$(cat "$IC_TAB")" "/old/orchestrate" "old path gone" || r=1
  rm -rf "$IC_HOME"; return $r
}

test_stt783_ac2_supervisor_does_not_call_scheduled_triggers() {
  local sup="$HERE_STT/../supervisor.sh"
  assert_eq "$(grep -c 'scheduled-triggers' "$sup")" "0" "supervisor.sh never mentions scheduled-triggers" || return 1
}

test_stt783_ac3_a_pass_right_after_a_dispatch_dispatches_nothing_more() {
  stt_home
  stt_conf 'example-owner/project-a auto-release.yml 5'
  stt_run; stt_run; stt_run
  assert_eq "$(stt_calls '^workflow run')" "1" "three passes in a row, one dispatch" || return 1
  assert_eq "$(grep -c ' ok$' "$STT_HOME/logs/pipeline/scheduled-triggers.log")" "1" "one log line" || return 1
}

test_stt783_ac3_three_concurrent_passes_dispatch_once() {
  stt_home
  stt_conf 'example-owner/project-a auto-release.yml 5'
  echo 1 > "$STT_HOME/dispatch-sleep"
  ( stt_run ) & ( stt_run ) & ( stt_run ) & wait
  assert_eq "$(stt_calls '^workflow run')" "1" "exactly one gh workflow run" || return 1
}

test_stt783_ac4_a_pass_dispatches_while_the_supervisor_lock_is_held() {
  stt_home
  stt_conf 'example-owner/project-a auto-release.yml 5'
  # a long supervisor tick: its lock directory is held (the portable lock form; the pass has its own lock and never looks at this one)
  mkdir -p "$STT_HOME/pipe/supervisor.lockdir"
  stt_run
  assert_exit0 "$STT_RC" "pass" || return 1
  assert_eq "$(stt_calls '^workflow run')" "1" "the due workflow was dispatched during the tick" || return 1
}

test_stt783_the_status_beat_reads_local_state_not_the_tick() {
  # AC5/observability: `status` is local files only (no gh) and works with no supervisor having run
  stt_home
  stt_conf 'example-owner/project-a auto-release.yml 5'
  stt_run; stt_run status
  assert_eq "$(printf '%s' "$STT_OUT" | jq -r '.[0].last_fired_at != null')" "true" "the cron pass alone publishes a fire time" || return 1
  assert_eq "$(stt_calls '^run list')" "1" "status itself made no gh call (only the dispatch pass read runs)" || return 1
}

test_stt783_report_status_publishes_full_repo_only_for_aliased_repos() {
  stt_home
  stt_conf 'example-owner/project-a auto-release.yml 5' 'example-owner/project-b auto-release.yml 5'
  printf 'STATUS_REPO_ALIASES=("example-owner/project-a:project-a")\nSCHEDULED_TRIGGERS_ENABLED=1\nSCHEDULED_TRIGGERS_CONF="%s"\n' "$STT_CONF" >> "$STT_HOME/.claude/pipeline/config.local.sh"
  local out; out=$(HOME="$STT_HOME" PATH="$STT_HOME/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$STT_HOME/pipe" LOGDIR="$STT_HOME/logs/pipeline" STATUS_CRON_CMD=true \
    SCHEDULED_TRIGGERS_ENABLED=1 /bin/bash "$HERE_STT/../report-status.sh" --print 2>/dev/null)
  assert_eq "$(printf '%s' "$out" | jq -c '.scheduled_triggers | map([.repo, .full_repo])')" '[["project-a","example-owner/project-a"],["other",null]]' "aliased repo carries owner/repo, unaliased publishes only 'other'" || return 1
}

test_stt783_host_drift_reports_a_missing_cron_line_only_when_enabled() {
  local h; h=$(new_home); mkdir -p "$h/bin"
  printf '#!/bin/bash\ncat "$HOME/crontab.table" 2>/dev/null\n' > "$h/bin/crontab"; chmod +x "$h/bin/crontab"
  local drift_py="$HERE_STT/../../../bin/host-drift.py"
  chk() { HOME="$h" PATH="$h/bin:$PATH" python3 -I - "$drift_py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hd", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.check_scheduled_triggers(); print(",".join(d["id"] for d in m.D))
PY
  }
  local r=0
  assert_eq "$(chk)" "" "flag off: nothing to report" || r=1
  printf 'SCHEDULED_TRIGGERS_ENABLED=1\n' > "$h/.claude/pipeline/config.local.sh"
  assert_eq "$(chk)" "sched:scheduled-triggers" "flag on, no cron line: drift" || r=1
  printf '* * * * * %s/.claude/skills/orchestrate/scheduled-triggers.sh run >/dev/null 2>&1\n' "$h" > "$h/crontab.table"
  assert_eq "$(chk)" "" "flag on, line present: clean" || r=1
  rm -rf "$h"; return $r
}

run_test test_stt783_ac1_install_adds_exactly_one_line_when_enabled_and_twice_leaves_one
run_test test_stt783_ac1_no_line_when_disabled_and_it_is_removed_when_switched_off
run_test test_stt783_ac1_a_stale_copy_at_another_path_collapses_to_one
run_test test_stt783_ac2_supervisor_does_not_call_scheduled_triggers
run_test test_stt783_ac3_a_pass_right_after_a_dispatch_dispatches_nothing_more
run_test test_stt783_ac3_three_concurrent_passes_dispatch_once
run_test test_stt783_ac4_a_pass_dispatches_while_the_supervisor_lock_is_held
run_test test_stt783_the_status_beat_reads_local_state_not_the_tick
run_test test_stt783_report_status_publishes_full_repo_only_for_aliased_repos
run_test test_stt783_host_drift_reports_a_missing_cron_line_only_when_enabled
