# Issue #332 — run state must survive a reboot: PIPE defaults to $HOME/.local/state/pipeline (not /tmp), a legacy
# /tmp/pipeline is moved once, and "alive" means kill -0 AND .launched-at later than boot (pid_alive <pidfile>).
#
# Interface fixed by this file (the developer implements it; names come from the ticket plus these seams):
#   PIPE_LEGACY            env override of the legacy dir (default /tmp/pipeline) so tests never touch the host's real one
#   PIPELINE_BOOT_EPOCH    env override of host boot time in epoch seconds (default: Mac kern.boottime / Linux /proc/stat btime)
#   PIPELINE_PROC_STAT     env override of /proc/stat for the Linux boot-time reader (file holds a `btime <epoch>` line)
#   pid_alive <pidfile>    in pipeline-lib.sh; sibling file is <pidfile minus .pid>.launched-at (ISO-8601 UTC)
#   the move + its failure alert live in config.sh, run when sourced with PIPE unset
# Alert on error: SLACK_WEBHOOK_URL via curl, text carries release=<sha> environment=<host> route=<...>, no secrets.
# Expected values come from the ticket's ACs / hand arithmetic in comments. Placeholder repo names only.

HERE_PP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_PP="$HERE_PP/.."
ROOT_PP=$(cd "$HERE_PP/../../.." && pwd)
if ! declare -f sq_env >/dev/null 2>&1; then
  eval "pp_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_PP/test-supervisor-queued-not-counted.sh"
  eval "$(declare -f pp_real_run_test | sed '1s/pp_real_run_test/run_test/')"
fi

# pp_home — isolated HOME; sets PP_HOME PP_NEW (the new default) PP_OLD (stand-in for /tmp/pipeline)
pp_home() {
  PP_HOME=$(new_home); PP_NEW="$PP_HOME/.local/state/pipeline"; PP_OLD="$PP_HOME/legacy-tmp-pipeline"
}
# pp_cfg [extra env...] — source config.sh with PIPE unset in a clean shell, print the resulting PIPE
pp_cfg() {
  env -u PIPE -u QUEUE HOME="$PP_HOME" PIPE_LEGACY="$PP_OLD" "$@" bash -c '. "$0/config.sh" >/dev/null 2>&1; printf "%s" "$PIPE"' "$RS_PP"
}

# ---- AC1: one persistent default, outside /tmp, in all four files ----------------------------------------------
test_pp_config_default_pipe_is_home_local_state() {
  pp_home
  local got; got=$(pp_cfg)
  rm -rf "$PP_HOME"
  assert_eq "$got" "$PP_HOME/.local/state/pipeline" "config.sh defaults PIPE to \$HOME/.local/state/pipeline" || return 1
}
test_pp_no_tmp_pipeline_default_in_the_other_three_files() {
  local f out
  for f in skills/orchestrate/stage-run.sh hooks/require-handoff-marker.sh skills/orchestrate/install.sh; do
    out=$(grep -n '/tmp/pipeline' "$ROOT_PP/$f")
    assert_eq "$out" "" "$f must not hardcode /tmp/pipeline" || return 1
  done
}
test_pp_default_is_defined_once_in_config_sh() {
  local f out
  out=$(grep -c '\.local/state/pipeline' "$RS_PP/config.sh")
  assert_eq "$out" "1" "config.sh holds the single definition" || return 1
  for f in skills/orchestrate/stage-run.sh hooks/require-handoff-marker.sh skills/orchestrate/install.sh skills/orchestrate/supervisor.sh; do
    out=$(grep -c '\.local/state/pipeline' "$ROOT_PP/$f")
    assert_eq "$out" "0" "$f has no fourth copy of the default (sources config.sh)" || return 1
  done
}

# ---- AC2: one-time move ----------------------------------------------------------------------------------------
test_pp_legacy_dir_moved_once_when_new_is_absent() {
  pp_home
  mkdir -p "$PP_OLD/queue"; echo 4242 > "$PP_OLD/orch-7.pid"; echo '{}' > "$PP_OLD/queue/orch-7.json"
  local got; got=$(pp_cfg)
  local pid q old
  pid=$(cat "$PP_NEW/orch-7.pid" 2>/dev/null); q=$(sq_present "$PP_NEW/queue/orch-7.json"); old=$(sq_present "$PP_OLD")
  rm -rf "$PP_HOME"
  assert_eq "$got" "$PP_HOME/.local/state/pipeline" "PIPE is the new path" || return 1
  assert_eq "$pid" "4242" "pid file arrived at the new path" || return 1
  assert_eq "$q" "present" "queue entry arrived too" || return 1
  assert_eq "$old" "absent" "legacy dir is gone (moved, not copied)" || return 1
}
test_pp_move_is_idempotent_when_both_paths_exist() {
  pp_home
  mkdir -p "$PP_OLD" "$PP_NEW"; echo old > "$PP_OLD/a"; echo new > "$PP_NEW/b"
  local p1 p2 rc1 rc2
  p1=$(pp_cfg); rc1=$?; p2=$(pp_cfg); rc2=$?
  local a b na
  a=$(cat "$PP_OLD/a" 2>/dev/null); b=$(cat "$PP_NEW/b" 2>/dev/null); na=$(sq_present "$PP_NEW/a")
  rm -rf "$PP_HOME"
  assert_eq "$p1$p2" "$PP_NEW$PP_NEW" "PIPE resolves to the new path both times" || return 1
  assert_eq "$a" "old" "legacy side untouched" || return 1
  assert_eq "$b" "new" "new side untouched" || return 1
  assert_eq "$na" "absent" "nothing merged into the new dir" || return 1
  assert_eq "$rc1$rc2" "00" "no error on repeat" || return 1
}
test_pp_no_move_when_legacy_absent() {
  pp_home
  local got; got=$(pp_cfg)
  rm -rf "$PP_HOME"
  assert_eq "$got" "$PP_HOME/.local/state/pipeline" "still resolves the new path with nothing to move" || return 1
}
test_pp_explicit_pipe_is_never_moved_or_overridden() {
  pp_home
  mkdir -p "$PP_OLD"; echo x > "$PP_OLD/a"
  local got; got=$(env HOME="$PP_HOME" PIPE_LEGACY="$PP_OLD" PIPE="$PP_HOME/custom" bash -c '. "$0/config.sh" >/dev/null 2>&1; printf "%s" "$PIPE"' "$RS_PP")
  local old; old=$(sq_present "$PP_OLD/a")
  rm -rf "$PP_HOME"
  assert_eq "$got" "$PP_HOME/custom" "caller-set PIPE wins" || return 1
  assert_eq "$old" "present" "no move when PIPE is explicit" || return 1
}

# ---- AC3 / negative test: pid_alive ---------------------------------------------------------------------------
# pp_alive <iso launched-at> <boot-epoch> [pid] -> prints pid_alive's exit code. pid defaults to a live process ($$ of the subshell).
pp_alive() {
  local la=$1 boot=$2 d rc
  d=$(mktemp -d "${TMPDIR:-/tmp}/pp-alive.XXXXXX")
  ( echo "${3:-$$}" > "$d/orch-9.pid"; printf '%s\n' "$la" > "$d/orch-9.launched-at"
    PIPELINE_BOOT_EPOCH="$boot" bash -c '. "$0/pipeline-lib.sh" >/dev/null 2>&1; pid_alive "$1"' "$RS_PP" "$d/orch-9.pid" ) >/dev/null 2>&1
  rc=$?; rm -rf "$d"; echo "$rc"
}
# Fixed clock: boot = 2026-10-16T12:28:40Z = epoch 1792153720; before = 12:00:00Z, after = 12:30:00Z (hand-computed from the incident).
PP_BOOT=1792153720
test_pp_live_pid_launched_before_boot_is_dead() {
  # the test's own live pid, but .launched-at predates boot: a recycled pid must not count
  local rc; rc=$(pp_alive 2026-10-16T12:00:00Z $PP_BOOT)
  assert_ne "$rc" "99" "pid_alive must be implemented (stub returns 99)" || return 1
  assert_ne "$rc" "0" "live pid + launched-at before boot => not alive" || return 1
}
test_pp_live_pid_launched_after_boot_is_alive() {
  local rc; rc=$(pp_alive 2026-10-16T12:30:00Z $PP_BOOT)
  assert_eq "$rc" "0" "live pid + launched-at after boot => alive" || return 1
}
test_pp_dead_pid_launched_after_boot_is_dead() {
  local p=99999; while kill -0 "$p" 2>/dev/null; do p=$((p - 1)); done
  local rc; rc=$(pp_alive 2026-10-16T12:30:00Z $PP_BOOT "$p")
  assert_ne "$rc" "99" "pid_alive must be implemented (stub returns 99)" || return 1
  assert_ne "$rc" "0" "kill -0 failing still means dead" || return 1
}
test_pp_launched_exactly_at_boot_is_not_alive() {
  # "later than boot": equal is not later. 1792153720 = 2026-10-16T12:28:40Z
  local rc; rc=$(pp_alive 2026-10-16T12:28:40Z $PP_BOOT)
  assert_ne "$rc" "99" "pid_alive must be implemented (stub returns 99)" || return 1
  assert_ne "$rc" "0" "launched-at == boot is not after boot" || return 1
}
test_pp_supervisor_has_no_bare_kill0_left() {
  local out; out=$(grep -n 'kill -0' "$RS_PP/supervisor.sh")
  assert_eq "$out" "" "every alive check in supervisor.sh goes through pid_alive" || return 1
}
test_pp_supervisor_uses_pid_alive_at_all_six_sites() {
  local n; n=$(grep -c 'pid_alive' "$RS_PP/supervisor.sh")
  assert_le "6" "$n" "six former kill -0 sites call pid_alive" || return 1
}

# ---- AC4: ticks -----------------------------------------------------------------------------------------------
# A run whose pid is live but belongs to a pre-boot launch is restarted, not skipped.
test_pp_tick_recycled_live_pid_before_boot_is_restarted() {
  sq_env open; sq_free_slots
  mk_running "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 7200 > "$SQ_PIPE/orch-42.launched-at"      # launched 2 h ago
  sq_marker "$SQ_READY"
  PIPELINE_BOOT_EPOCH=$(( $(date +%s) - 3600 )) sq_run "$SUP_SQ" >/dev/null 2>&1   # booted 1 h ago => launch predates boot
  local log reason; log=$(sq_log); reason=$(sq_queue_field reason)
  sq_cleanup
  assert_contains "$log" "[queue-restart] #42" "pre-boot launch with a recycled live pid is restarted" || return 1
  assert_eq "$reason" "auto-restart" "queued as auto-restart" || return 1
}
test_pp_tick_live_pid_after_boot_is_left_alone() {
  sq_env open; sq_free_slots
  mk_running "$SQ_PIPE" 42 "$SQ_REPO"
  sq_iso_ago 600 > "$SQ_PIPE/orch-42.launched-at"
  PIPELINE_BOOT_EPOCH=$(( $(date +%s) - 3600 )) sq_run "$SUP_SQ" >/dev/null 2>&1
  local log reason; log=$(sq_log); reason=$(sq_queue_field reason)
  sq_cleanup
  assert_not_contains "$log" "[queue-restart] #42" "a genuinely live post-boot run is not restarted" || return 1
  assert_eq "$reason" "NO-QUEUE-ENTRY" "no queue entry" || return 1
}
# The reboot scenario end to end: state still sits in the legacy dir, PIPE unset, dead pre-boot pid, no tombstone.
test_pp_tick_after_reboot_moves_state_restarts_run_and_clears_no_label() {
  sq_env open; sq_free_slots
  local legacy=$SQ_PIPE new="$SQ_HOME/.local/state/pipeline"
  mk_restarting "$legacy" 42 "$SQ_REPO"
  sq_iso_ago 7200 > "$legacy/orch-42.launched-at"
  sq_marker "$SQ_READY"
  env -u PIPE -u QUEUE HOME="$SQ_HOME" PATH="$SQ_GH:/usr/bin:/bin" LOGDIR="$SQ_HOME/logs/pipeline" PIPE_LEGACY="$legacy" \
    PIPELINE_BOOT_EPOCH=$(( $(date +%s) - 3600 )) SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$SUP_SQ" >/dev/null 2>&1
  local log reason moved old
  log=$(sq_log)
  reason=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('reason','MISSING'))" "$new/queue/orch-42.json" 2>/dev/null || echo NO-QUEUE-ENTRY)
  moved=$(sq_present "$new/orch-42.repo"); old=$(sq_present "$legacy")
  sq_cleanup
  assert_eq "$moved" "present" "state moved to the new default before the tick read it" || return 1
  assert_eq "$old" "absent" "legacy dir moved away" || return 1
  assert_contains "$log" "[queue-restart] #42" "run restarted through the crash path" || return 1
  assert_eq "$reason" "auto-restart" "auto-restart entry queued at the new path" || return 1
  assert_not_contains "$log" "cleared orphaned agent-in-progress (no local state" "no reconcile label clear" || return 1
}

# ---- AC1 (behavioral, per file): each consumer resolves the SAME default with PIPE unset ------------------------
# stage-run.sh: reads $PIPE/<issue>-<agent>-before.txt to decide whether a handoff marker is new. With PIPE unset and
# before.txt (=0) only at the new default, a new PASS comment is recognised iff the wrapper resolved the new path.
test_pp_stage_run_resolves_new_default_pipe() {
  pp_home
  local bin="$PP_HOME/bin"; mkdir -p "$bin" "$PP_NEW" "$PP_HOME/logs/pipeline"
  printf '#!/bin/bash\nexit 0\n' > "$bin/claude"
  printf '#!/bin/bash\nprintf %%s '"'"'[{"id":5001,"created_at":"2099-01-01T00:00:00Z","user":{"login":"x"},"body":"**[code-reviewer] PASS**\\nok"}]'"'"'\n' > "$bin/gh"
  chmod +x "$bin/claude" "$bin/gh"; echo 0 > "$PP_NEW/42-code-reviewer-before.txt"
  ( cd "$PP_HOME" && env -u PIPE -u QUEUE -u LOGDIR HOME="$PP_HOME" PIPE_LEGACY="$PP_OLD" PATH="$bin:$PATH" CLAUDE_PROJECTS_DIR="$PP_HOME/proj" \
      PIPELINE_ISSUE=42 PIPELINE_AGENT=code-reviewer PIPELINE_REPO=project-a/app \
      "$RS_PP/stage-run.sh" -- claude -p x >/dev/null 2>&1 )
  local row; row=$(grep stage_end "$PP_HOME/logs/pipeline/events.jsonl" 2>/dev/null | tail -1 | jq -r '.marker_after // "none"' 2>/dev/null)
  rm -rf "$PP_HOME"
  assert_eq "$row" "**[code-reviewer] PASS**" "stage-run.sh found before.txt under \$HOME/.local/state/pipeline" || return 1
}
# hooks/require-handoff-marker.sh: with before.txt (=0) only at the new default and no new marker, it nags (exit 2)
# and writes its nag file beside before.txt. A different default => it would exit 0 (no before.txt) and write nothing.
test_pp_handoff_hook_resolves_new_default_pipe() {
  pp_home
  local bin="$PP_HOME/bin"; mkdir -p "$bin" "$PP_NEW"
  printf '#!/bin/bash\nexit 0\n' > "$bin/gh"; chmod +x "$bin/gh"; echo 0 > "$PP_NEW/42-code-reviewer-before.txt"
  local rc; echo '{}' | env -u PIPE -u QUEUE HOME="$PP_HOME" PIPE_LEGACY="$PP_OLD" PATH="$bin:$PATH" \
      PIPELINE_ISSUE=42 PIPELINE_AGENT=code-reviewer PIPELINE_REPO=project-a/app "$ROOT_PP/hooks/require-handoff-marker.sh" >/dev/null 2>&1
  rc=$?
  local nag; nag=$(cat "$PP_NEW/42-code-reviewer-nags.txt" 2>/dev/null)
  rm -rf "$PP_HOME"
  assert_eq "$rc" "2" "hook refused to let the stage finish (it saw before.txt at the new default)" || return 1
  assert_eq "$nag" "1" "first nag recorded at the new default" || return 1
}
# install.sh runs crontab/symlinks, so it is not executed here. Its queue dir must come from the shared default:
# config.sh is sourced before the mkdir, and the mkdir names $QUEUE or $PIPE, not a literal path.
test_pp_install_creates_queue_from_shared_default() {
  local f="$ROOT_PP/skills/orchestrate/install.sh" src mk
  src=$(grep -n 'config\.sh"' "$f" | grep -E 'source|^[0-9]+:\.' | head -1 | cut -d: -f1)
  mk=$(grep -n 'mkdir -p' "$f" | grep -E 'queue|QUEUE' | head -1)
  assert_contains "$mk" 'QUEUE' "queue mkdir uses \$QUEUE (or \$PIPE/queue) from config.sh" || return 1
  assert_ne "${src:-}" "" "install.sh sources config.sh" || return 1
  assert_le "${src:-999}" "${mk%%:*}" "config.sh is sourced before the queue mkdir" || return 1
}

# ---- AC3: the DEFAULT boot-time sources (PIPELINE_BOOT_EPOCH unset) ------------------------------------------
# pp_alive_stub <darwin|linux> <iso launched-at> — prints pid_alive's rc with the platform tools stubbed on PATH.
# darwin: uname -> Darwin, sysctl -n kern.boottime -> "{ sec = 1792153720, usec = 0 } Fri Oct 16 12:28:40 2026"
# linux : uname -> Linux, sysctl failing, PIPELINE_PROC_STAT -> file with "btime 1792153720"
pp_alive_stub() {
  local kind=$1 la=$2 d bin rc; d=$(mktemp -d "${TMPDIR:-/tmp}/pp-boot.XXXXXX"); bin="$d/bin"; mkdir -p "$bin"
  if [ "$kind" = darwin ]; then
    printf '#!/bin/bash\necho Darwin\n' > "$bin/uname"
    printf '#!/bin/bash\n[ "$*" = "-n kern.boottime" ] && echo "{ sec = 1792153720, usec = 0 } Fri Oct 16 12:28:40 2026" || exit 1\n' > "$bin/sysctl"
  else
    printf '#!/bin/bash\necho Linux\n' > "$bin/uname"; printf '#!/bin/bash\nexit 1\n' > "$bin/sysctl"
    printf 'cpu  1 2 3\nbtime 1792153720\nprocesses 5\n' > "$d/stat"
  fi
  chmod +x "$bin/uname" "$bin/sysctl"
  echo $$ > "$d/orch-9.pid"; printf '%s\n' "$la" > "$d/orch-9.launched-at"
  env -u PIPELINE_BOOT_EPOCH PATH="$bin:/usr/bin:/bin" PIPELINE_PROC_STAT="$d/stat" \
    bash -c '. "$0/pipeline-lib.sh" >/dev/null 2>&1; pid_alive "$1"' "$RS_PP" "$d/orch-9.pid" >/dev/null 2>&1
  rc=$?; rm -rf "$d"; echo "$rc"
}
test_pp_default_boot_time_mac_sysctl_before_boot_is_dead() {
  local rc; rc=$(pp_alive_stub darwin 2026-10-16T12:00:00Z)
  assert_ne "$rc" "99" "pid_alive must be implemented (stub returns 99)" || return 1
  assert_ne "$rc" "0" "kern.boottime 12:28:40Z; launched 12:00:00Z => not alive" || return 1
}
test_pp_default_boot_time_mac_sysctl_after_boot_is_alive() {
  local rc; rc=$(pp_alive_stub darwin 2026-10-16T12:30:00Z)
  assert_eq "$rc" "0" "kern.boottime 12:28:40Z; launched 12:30:00Z => alive" || return 1
}
test_pp_default_boot_time_linux_proc_stat_before_boot_is_dead() {
  local rc; rc=$(pp_alive_stub linux 2026-10-16T12:00:00Z)
  assert_ne "$rc" "99" "pid_alive must be implemented (stub returns 99)" || return 1
  assert_ne "$rc" "0" "btime 1792153720 (12:28:40Z); launched 12:00:00Z => not alive" || return 1
}
test_pp_default_boot_time_linux_proc_stat_after_boot_is_alive() {
  local rc; rc=$(pp_alive_stub linux 2026-10-16T12:30:00Z)
  assert_eq "$rc" "0" "btime 1792153720; launched 12:30:00Z => alive" || return 1
}

# ---- observability --------------------------------------------------------------------------------------------
pp_curl_stub() {  # <dir> — records every curl call
  printf '#!/bin/bash\necho "CALL $*" >> "%s/curl.calls"\nexit 0\n' "$1" > "$1/curl"; chmod +x "$1/curl"
}
test_pp_failed_move_alerts_slack_with_tags_and_no_secret() {
  pp_home
  mkdir -p "$PP_OLD"; echo "token=ghp_FAKESECRET123" > "$PP_OLD/a"
  mkdir -p "$PP_HOME/.local"; echo block > "$PP_HOME/.local/state"      # a FILE where the parent dir must go: the move cannot succeed
  local bin="$PP_HOME/bin"; mkdir -p "$bin"; pp_curl_stub "$bin"
  env -u PIPE -u QUEUE HOME="$PP_HOME" PIPE_LEGACY="$PP_OLD" PATH="$bin:/usr/bin:/bin" SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X" \
    bash -c '. "$0/config.sh" >/dev/null 2>&1' "$RS_PP"
  local calls; calls=$(grep 'hooks.slack.test' "$bin/curl.calls" 2>/dev/null)
  local kept; kept=$(sq_present "$PP_OLD/a")
  rm -rf "$PP_HOME"
  assert_contains "$calls" "release=" "alert carries the release tag" || return 1
  case "$calls" in *release=unknown*|*release=\ *) fail "release must be the commit SHA: $calls"; return 1 ;; esac
  case "$calls" in *environment=[a-zA-Z0-9]*) ;; *) fail "environment tag needs a value: $calls"; return 1 ;; esac
  assert_contains "$calls" "route=" "alert carries a route tag" || return 1
  assert_not_contains "$calls" "ghp_FAKESECRET123" "alert carries no secret" || return 1
  assert_eq "$kept" "present" "a failed move leaves the legacy state in place" || return 1
}
test_pp_unreadable_boot_time_alerts_slack() {
  local d bin; d=$(mktemp -d "${TMPDIR:-/tmp}/pp-bt.XXXXXX"); bin="$d/bin"; mkdir -p "$bin"; pp_curl_stub "$bin"
  echo $$ > "$d/orch-9.pid"; sq_iso_ago 60 > "$d/orch-9.launched-at"
  PATH="$bin:/usr/bin:/bin" SLACK_WEBHOOK_URL="https://hooks.slack.test/T/B/X" PIPELINE_BOOT_EPOCH=not-a-number \
    bash -c '. "$0/pipeline-lib.sh" >/dev/null 2>&1; pid_alive "$1"' "$RS_PP" "$d/orch-9.pid" >/dev/null 2>&1
  local calls; calls=$(grep 'hooks.slack.test' "$bin/curl.calls" 2>/dev/null)
  rm -rf "$d"
  assert_contains "$calls" "route=" "unreadable boot time is reported with a route tag" || return 1
  assert_contains "$calls" "release=" "and a release tag" || return 1
}

# ---- docs -----------------------------------------------------------------------------------------------------
test_pp_readme_states_run_state_is_persistent_new_path() {
  local line; line=$(grep -n 'Machine-local, by design' "$ROOT_PP/README.md")
  assert_contains "$line" ".local/state/pipeline" "README machine-local line names the new path" || return 1
  assert_not_contains "$line" "/tmp/pipeline" "README no longer says run state is in /tmp/pipeline" || return 1
}

run_test test_pp_config_default_pipe_is_home_local_state
run_test test_pp_no_tmp_pipeline_default_in_the_other_three_files
run_test test_pp_default_is_defined_once_in_config_sh
run_test test_pp_legacy_dir_moved_once_when_new_is_absent
run_test test_pp_move_is_idempotent_when_both_paths_exist
run_test test_pp_no_move_when_legacy_absent
run_test test_pp_explicit_pipe_is_never_moved_or_overridden
run_test test_pp_live_pid_launched_before_boot_is_dead
run_test test_pp_live_pid_launched_after_boot_is_alive
run_test test_pp_dead_pid_launched_after_boot_is_dead
run_test test_pp_launched_exactly_at_boot_is_not_alive
run_test test_pp_supervisor_has_no_bare_kill0_left
run_test test_pp_supervisor_uses_pid_alive_at_all_six_sites
run_test test_pp_tick_recycled_live_pid_before_boot_is_restarted
run_test test_pp_tick_live_pid_after_boot_is_left_alone
run_test test_pp_tick_after_reboot_moves_state_restarts_run_and_clears_no_label
run_test test_pp_stage_run_resolves_new_default_pipe
run_test test_pp_handoff_hook_resolves_new_default_pipe
run_test test_pp_install_creates_queue_from_shared_default
run_test test_pp_default_boot_time_mac_sysctl_before_boot_is_dead
run_test test_pp_default_boot_time_mac_sysctl_after_boot_is_alive
run_test test_pp_default_boot_time_linux_proc_stat_before_boot_is_dead
run_test test_pp_default_boot_time_linux_proc_stat_after_boot_is_alive
run_test test_pp_failed_move_alerts_slack_with_tags_and_no_secret
run_test test_pp_unreadable_boot_time_alerts_slack
run_test test_pp_readme_states_run_state_is_persistent_new_path
