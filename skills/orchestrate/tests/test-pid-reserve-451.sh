# Issue #451 — launchers reserve orch-<key>.pid before the claim-settle wait, so two launches on one host cannot both start.
# Placeholder repo names only. Reuses hc_env/hc_claims from test-hand-launch-claim.sh (sourced earlier by the runner).
#
# No fixed sleeps: the settle wait is a gate. The `sleep` shim blocks a launcher's `sleep $CLAIM_SETTLE_SECS` until
# $HC_BIN/go exists (bounded), and records "<launcher pid> <pid-file content>" at that moment, so a test can hold one
# launcher inside its claim wait, start the second, then release the gate. Everything else polls with a bounded loop.

HERE_PR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_PR="${R451_DIR:-$HERE_PR/..}"
PR_SETTLE=7   # the gated value: only `sleep 7` waits on the gate, every other sleep returns at once

pr_env() {
  hc_env
  printf 'MEM_FLOOR_MB=0\nCLAIM_SETTLE_SECS=%s\nCLAIM_WINDOW_SECS=600\n' "$PR_SETTLE" > "$HC_HOME/.claude/pipeline/config.local.sh"
  hc_claims "$(hostname -s):5"
  PR_RK=$(rk "$HC_REPO" 42)
  PR_PIDF="$HC_PIPE/orch-$PR_RK.pid"
  : > "$HC_BIN/spawns.log"
  printf '#!/bin/bash\necho spawn >> "%s/spawns.log"\nexec /bin/sleep 30\n' "$HC_BIN" > "$HC_BIN/claude"
  # settle gate (see header). `usurper`: a competing launcher overwrote the pid file during the wait (verify-fail case).
  cat > "$HC_BIN/sleep" <<SLEEP_EOF
#!/bin/bash
[ "\$1" = "$PR_SETTLE" ] || exit 0
echo "\$PPID \$(cat '$PR_PIDF' 2>/dev/null || echo ABSENT)" > "$HC_BIN/pid-at-settle"
[ -f "$HC_BIN/usurper" ] && cat "$HC_BIN/usurper" > '$PR_PIDF'
i=0; while [ ! -e "$HC_BIN/go" ] && [ \$i -lt 100 ]; do /bin/sleep 0.1; i=\$((i+1)); done
exit 0
SLEEP_EOF
  # gh: the hc fake answers `issue view`; the supervisor's claim read is REST (claim_winner_rest), served here from the
  # same comments.json. Flag files fail the claim post / the claim read (do_launch's two fail-closed exits).
  mv "$HC_BIN/gh" "$HC_BIN/gh-hc"
  cat > "$HC_BIN/gh" <<GH_EOF
#!/bin/bash
case "\$*" in
  "api repos/"*"/issues/42/comments -f body="*) [ -f "$HC_BIN/claim-post-fail" ] && { echo "HTTP 502" >&2; exit 1; }; exit 0 ;;
  "api repos/"*"/issues/42/comments?per_page="*) [ -f "$HC_BIN/claim-read-fail" ] && exit 1; cat "$HC_BIN/comments.json"; exit 0 ;;
  "api repos/"*"/issues/42") echo '{"labels":[]}'; exit 0 ;;
esac
exec "$HC_BIN/gh-hc" "\$@"
GH_EOF
  chmod +x "$HC_BIN/claude" "$HC_BIN/sleep" "$HC_BIN/gh"
}
pr_launch() {  # pr_launch <issue> [args] — the hand launcher under test
  local n=$1; shift
  HOME="$HC_HOME" PATH="$HC_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$HC_PIPE" QUEUE="$HC_PIPE/queue" LOGDIR="$HC_HOME/logs/pipeline" \
    "$RS_PR/orchestrate.sh" "$@" "$HC_REPO" "$n" 2>&1
}
pr_launch_bg() {  # pr_launch_bg <issue> — same launcher in the background; PR_BG_PID is orchestrate.sh's own pid (exec'd)
  local n=$1; shift
  ( HOME="$HC_HOME" PATH="$HC_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$HC_PIPE" QUEUE="$HC_PIPE/queue" LOGDIR="$HC_HOME/logs/pipeline" \
    exec "$RS_PR/orchestrate.sh" "$@" "$HC_REPO" "$n" ) >/dev/null 2>&1 &
  PR_BG_PID=$!
}
pr_stop() {  # pr_stop <issue>
  HOME="$HC_HOME" PATH="$HC_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$HC_PIPE" QUEUE="$HC_PIPE/queue" LOGDIR="$HC_HOME/logs/pipeline" \
    "$RS_PR/orchestrate.sh" stop "project-a/repo-a#$1" 2>&1
}
pr_tick() {  # one supervisor tick (drains the queue -> do_launch)
  HOME="$HC_HOME" PATH="$HC_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$HC_PIPE" QUEUE="$HC_PIPE/queue" LOGDIR="$HC_HOME/logs/pipeline" \
    "$RS_PR/supervisor.sh" >/dev/null 2>&1
}
pr_do_launch() {  # supervisor.sh's do_launch on #42 in isolation (the script is not sourceable: it runs a tick on source)
  cat > "$HC_BIN/do-launch" <<DL_EOF
#!/bin/bash
set -u
. "$RS_PR/config.sh"; . "$RS_PR/pipeline-lib.sh"
SLOG="\$LOGDIR/supervisor.log"; HOST=\$(hostname -s); mkdir -p "\$PIPE" "\$QUEUE" "\$LOGDIR"
slog() { printf '[%s] %s\n' "\$(date -u +%FT%TZ)" "\$*" >> "\$SLOG"; }
eval "\$(awk '/^gh_err_line\(\)/,/^}/' "$RS_PR/supervisor.sh")"
eval "\$(awk '/^do_launch\(\)/,/^}/' "$RS_PR/supervisor.sh")"
echo \$\$ > "$HC_BIN/launcher.pid"
do_launch "$HC_REPO" 42 "" 0 queued ""
DL_EOF
  chmod +x "$HC_BIN/do-launch"
  if [ "${1:-}" = bg ]; then   # PR_BG_PID is the harness's own pid (exec'd), i.e. the pid do_launch reserves with
    ( HOME="$HC_HOME" PATH="$HC_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$HC_PIPE" QUEUE="$HC_PIPE/queue" LOGDIR="$HC_HOME/logs/pipeline" \
      exec "$HC_BIN/do-launch" ) >/dev/null 2>&1 &
    PR_BG_PID=$!; return 0
  fi
  HOME="$HC_HOME" PATH="$HC_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$HC_PIPE" QUEUE="$HC_PIPE/queue" LOGDIR="$HC_HOME/logs/pipeline" \
    "$HC_BIN/do-launch" >/dev/null 2>&1
}
pr_spawns() { wc -l < "$HC_BIN/spawns.log" | tr -d ' '; }
pr_slog() { cat "$HC_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }
pr_events() { cat "$HC_HOME/logs/pipeline/events.jsonl" 2>/dev/null; }
pr_pidf() { cat "$PR_PIDF" 2>/dev/null || echo ABSENT; }
pr_wait_until() {  # pr_wait_until <max tenths> <cmd...> — bounded poll; 0 when the condition held
  local max=$1 i=0; shift
  while ! "$@" 2>/dev/null; do [ $i -ge "$max" ] && return 1; /bin/sleep 0.1; i=$((i + 1)); done
}
pr_reserved() { local p; p=$(cat "$PR_PIDF" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
pr_in_settle() { [ -f "$HC_BIN/pid-at-settle" ]; }   # a launcher is blocked inside its claim wait
pr_held_at_settle() {  # "held" when, inside the claim wait, orch-<key>.pid held that launcher's own pid; else the raw snapshot
  local at; at=$(cat "$HC_BIN/pid-at-settle" 2>/dev/null)
  if [ -n "$at" ] && [ "${at%% *}" = "${at#* }" ]; then echo held; else echo "[${at:-no snapshot}]"; fi
}
pr_spawned() { [ "$(pr_spawns)" -ge 1 ]; }
pr_wait_spawns() {  # spawns are written by the detached child: wait for the first, then a short grace for any second
  pr_wait_until 50 pr_spawned; /bin/sleep 0.5; pr_spawns
}
pr_release() { touch "$HC_BIN/go"; }

# --- hand launcher (orchestrate.sh) ------------------------------------------------------------------------------

test_pr451_manual_manual_one_spawn() {
  pr_env
  pr_launch 42 > /dev/null & local a=$!
  pr_wait_until 100 pr_in_settle
  local out rc; out=$(pr_launch 42); rc=$?       # inside the first launcher's claim wait
  local held; held=$(pr_held_at_settle)
  pr_release; wait "$a"
  local n; n=$(pr_wait_spawns)
  hc_cleanup
  assert_eq "$held" "held" "#451: the first launcher's pid is in orch-<key>.pid during its claim wait" || return 1
  assert_eq "$n" "1" "#451: exactly one orchestrator spawned" || return 1
  assert_eq "$rc" "1" "#451: second manual launch exits non-zero" || return 1
  assert_contains "$out" "already running" "#451: second launcher reports already running" || return 1
}

test_pr451_second_force_launch_also_refused_during_wait() {
  pr_env
  pr_launch 42 > /dev/null & local a=$!
  pr_wait_until 100 pr_in_settle
  local out; out=$(pr_launch 42 --force)
  pr_release; wait "$a"
  local n; n=$(pr_wait_spawns)
  hc_cleanup
  assert_eq "$n" "1" "#451: --force during another launcher's wait does not double-spawn" || return 1
  assert_contains "$out" "already running" "#451: --force sees the reservation" || return 1
}

test_pr451_manual_then_drain_entry_dropped() {  # the drain tick lands inside a hand launcher's claim wait
  pr_env
  pr_launch 42 > /dev/null & local a=$!
  pr_wait_until 100 pr_in_settle
  local held; held=$(pr_held_at_settle)
  mk_queued "$HC_PIPE" 42 "$HC_REPO"
  pr_tick                                        # a drain that wrongly reaches do_launch waits out the gate, then spawns
  local q=gone; [ -f "$HC_PIPE/queue/orch-$PR_RK.json" ] && q=kept
  local log; log=$(pr_slog)
  pr_release; wait "$a"
  local n; n=$(pr_wait_spawns)
  hc_cleanup
  assert_eq "$held" "held" "#451: hand launcher holds the pid file during its wait" || return 1
  assert_contains "$log" "[drain-skip] #42 — already running" "#451: the drain sees the reservation as a live run" || return 1
  assert_eq "$q" "gone" "#451: drain drops the queue entry (existing live-pid behaviour kept)" || return 1
  assert_eq "$n" "1" "#451: manual + drain spawn exactly one orchestrator" || return 1
}

test_pr451_drain_then_manual_one_spawn() {  # the hand launch lands inside the drain's do_launch claim wait
  pr_env
  mk_queued "$HC_PIPE" 42 "$HC_REPO"
  pr_tick & local t=$!
  pr_wait_until 300 pr_in_settle                 # the tick's start-up precedes do_launch
  local held; held=$(pr_held_at_settle)
  local out rc; out=$(pr_launch 42); rc=$?
  pr_release; wait "$t"
  local n; n=$(pr_wait_spawns)
  local live=no; pr_reserved && live=yes
  hc_cleanup
  assert_eq "$held" "held" "#451: do_launch holds the pid file during its claim wait" || return 1
  assert_eq "$rc" "1" "#451: hand launch during the drain's wait exits non-zero" || return 1
  assert_contains "$out" "already running" "#451: hand launch sees the drain's reservation" || return 1
  assert_eq "$n" "1" "#451: drain + manual spawn exactly one orchestrator" || return 1
  assert_eq "$live" "yes" "#451: after the spawn the pid file holds the live child" || return 1
}

test_pr451_lost_claim_restores_earlier_pid_content() {
  pr_env; pr_release
  hc_claims otherhost:30 "$(hostname -s):5"
  echo 999999 > "$PR_PIDF"    # earlier, dead pid
  local out rc; out=$(pr_launch 42); rc=$?
  local held content; held=$(pr_held_at_settle); content=$(pr_pidf)
  hc_cleanup
  assert_eq "$rc" "1" "#451: lost claim refuses" || return 1
  assert_eq "$held" "held" "#451: during the wait the file held the launcher's own pid" || return 1
  assert_eq "$content" "999999" "#451: lost claim puts the earlier pid content back" || return 1
}

test_pr451_lost_claim_without_earlier_file_leaves_none() {
  pr_env; pr_release
  hc_claims otherhost:30 "$(hostname -s):5"
  pr_launch 42 >/dev/null
  local held content; held=$(pr_held_at_settle); content=$(pr_pidf)
  hc_cleanup
  assert_eq "$held" "held" "#451: during the wait the file held the launcher's own pid" || return 1
  assert_eq "$content" "ABSENT" "#451: no launcher pid left behind after a refused launch" || return 1
}

# --- supervisor.sh do_launch ---------------------------------------------------------------------------------------

test_pr451_do_launch_control_spawns() {  # harness sanity: nothing holds the key -> do_launch spawns and leaves the child pid
  pr_env; pr_release
  pr_do_launch; local rc=$?
  local n; n=$(pr_wait_spawns)
  local live=no; pr_reserved && live=yes
  local own; own=$(cat "$HC_BIN/launcher.pid")
  local content; content=$(pr_pidf)
  hc_cleanup
  assert_eq "$rc" "0" "#451: control — do_launch returns 0" || return 1
  assert_eq "$n" "1" "#451: control — do_launch spawned one orchestrator" || return 1
  assert_eq "$live" "yes" "#451: control — orch-<key>.pid holds a live pid" || return 1
  assert_ne "$content" "$own" "#451: after the spawn the file holds the child, not the launcher" || return 1
}

test_pr451_do_launch_refuses_live_pid_and_logs_skip() {
  pr_env; pr_release
  /bin/sleep 20 & local other=$!    # another launcher's reservation (or a run) — live, not ours
  echo "$other" > "$PR_PIDF"
  pr_do_launch; local rc=$?
  local n log ev content; n=$(pr_spawns); log=$(pr_slog); ev=$(pr_events); content=$(pr_pidf)
  hc_cleanup
  assert_eq "$rc" "1" "#451: do_launch returns 1 when a live pid holds the key" || return 1
  assert_eq "$n" "0" "#451: nothing spawned" || return 1
  assert_contains "$log" "[launch-skip] #42 — another launcher holds the pid file" "#451: one [launch-skip] log line" || return 1
  assert_eq "$(printf '%s\n' "$log" | grep -c '\[launch-skip\]')" "1" "#451: exactly one [launch-skip] line" || return 1
  assert_contains "$ev" '"event":"launch_skip"' "#451: launch_skip row emitted" || return 1
  assert_contains "$ev" '"route":"supervisor"' "#451: route supervisor" || return 1
  assert_eq "$content" "$other" "#451: the other launcher's pid is left untouched" || return 1
}

test_pr451_do_launch_lost_claim_restores_pid() {
  pr_env; pr_release
  hc_claims otherhost:30 "$(hostname -s):5"
  echo 999999 > "$PR_PIDF"
  pr_do_launch; local rc=$?
  local held n content; held=$(pr_held_at_settle); n=$(pr_spawns); content=$(pr_pidf)
  hc_cleanup
  assert_eq "$rc" "1" "#451: lost claim -> do_launch returns 1" || return 1
  assert_eq "$held" "held" "#451: during the claim wait the file held do_launch's own pid" || return 1
  assert_eq "$content" "999999" "#451: lost claim puts the earlier content back" || return 1
  assert_eq "$n" "0" "#451: nothing spawned" || return 1
}

test_pr451_do_launch_claim_failures_restore_pid() {  # claim post fails (rc 2) / claim read fails (rc 2): earlier content back
  pr_env; pr_release
  echo 999999 > "$PR_PIDF"
  touch "$HC_BIN/claim-post-fail"
  pr_do_launch; local rc_post=$? c_post; c_post=$(pr_pidf)
  rm -f "$HC_BIN/claim-post-fail"; touch "$HC_BIN/claim-read-fail"; rm -f "$HC_BIN/pid-at-settle"
  pr_do_launch; local rc_read=$? c_read held; c_read=$(pr_pidf); held=$(pr_held_at_settle)
  local n; n=$(pr_spawns)
  hc_cleanup
  assert_eq "$rc_post" "2" "#451: claim post failure -> rc 2" || return 1
  assert_eq "$c_post" "999999" "#451: claim post failure puts the earlier content back" || return 1
  assert_eq "$rc_read" "2" "#451: claim read failure -> rc 2" || return 1
  assert_eq "$held" "held" "#451: the read-failure path had reserved first" || return 1
  assert_eq "$c_read" "999999" "#451: claim read failure puts the earlier content back" || return 1
  assert_eq "$n" "0" "#451: nothing spawned" || return 1
}

test_pr451_do_launch_lost_reservation_skips_spawn() {  # the file no longer holds our pid after the wait -> no spawn, [launch-skip]
  pr_env; pr_release
  /bin/sleep 20 & local other=$!
  echo "$other" > "$HC_BIN/usurper"     # the sleep shim writes it over our reservation during the wait
  pr_do_launch; local rc=$?
  local n log ev content; n=$(pr_spawns); log=$(pr_slog); ev=$(pr_events); content=$(pr_pidf)
  hc_cleanup
  assert_eq "$rc" "1" "#451: lost reservation -> do_launch returns 1" || return 1
  assert_eq "$n" "0" "#451: nothing spawned" || return 1
  assert_contains "$log" "[launch-skip] #42 — another launcher holds the pid file" "#451: [launch-skip] logged" || return 1
  assert_contains "$ev" '"event":"launch_skip"' "#451: launch_skip row emitted" || return 1
  assert_contains "$ev" '"reason":"pid-held"' "#451: reason pid-held" || return 1
  assert_contains "$ev" '"route":"supervisor"' "#451: route supervisor" || return 1
  assert_eq "$content" "$other" "#451: the holder's pid is left in place, not restored over" || return 1
}

# --- stop and signals during a reservation ------------------------------------------------------------------------

test_pr451_stop_refuses_supervisor_reservation() {  # the pid file holds a supervisor's pid: stop must not kill it
  pr_env
  printf '#!/bin/bash\n/bin/sleep 20\n' > "$HC_HOME/supervisor.sh"   # command line "bash .../supervisor.sh", like the real tick
  bash "$HC_HOME/supervisor.sh" >/dev/null 2>&1 & local sup=$!
  echo "$sup" > "$PR_PIDF"
  local out rc; out=$(pr_stop 42); rc=$?
  /bin/sleep 0.2
  local alive=no tomb=no content; kill -0 "$sup" 2>/dev/null && alive=yes; [ -f "$HC_PIPE/orch-$PR_RK.stopped" ] && tomb=yes; content=$(pr_pidf)
  hc_cleanup
  assert_eq "$alive" "yes" "#451: stop leaves the supervisor's reservation pid alive" || return 1
  assert_eq "$rc" "1" "#451: stop exits 1 during a supervisor reservation" || return 1
  assert_contains "$out" "launch in progress (supervisor reservation), retry in a moment" "#451: stop says to retry" || return 1
  assert_eq "$tomb" "no" "#451: no tombstone written for a refused stop" || return 1
  assert_eq "$content" "$sup" "#451: the reservation is left in place" || return 1
}

test_pr451_term_during_manual_wait_restores_pid() {  # TERM inside the claim wait: earlier content back (EXIT trap alone would not run)
  pr_env
  echo 999999 > "$PR_PIDF"
  pr_launch_bg 42
  pr_wait_until 100 pr_in_settle
  local held; held=$(pr_held_at_settle)
  kill -TERM "$PR_BG_PID"; pr_release          # the trap runs once the settle sleep returns
  wait "$PR_BG_PID"; local rc=$?
  local content n; content=$(pr_pidf); n=$(pr_spawns)
  hc_cleanup
  assert_eq "$held" "held" "#451: launcher held the file during its wait" || return 1
  assert_eq "$rc" "130" "#451: TERM during the wait exits 130" || return 1
  assert_eq "$content" "999999" "#451: TERM during the wait puts the earlier pid content back" || return 1
  assert_eq "$n" "0" "#451: nothing spawned" || return 1
}

test_pr451_term_during_do_launch_wait_restores_pid() {  # same for the supervisor's do_launch; no earlier file -> none left
  pr_env
  pr_do_launch bg
  pr_wait_until 100 pr_in_settle
  local held; held=$(pr_held_at_settle)
  kill -TERM "$PR_BG_PID"; pr_release
  wait "$PR_BG_PID"; local rc=$?
  local content n; content=$(pr_pidf); n=$(pr_spawns)
  hc_cleanup
  assert_eq "$held" "held" "#451: do_launch held the file during its wait" || return 1
  assert_eq "$rc" "143" "#451: TERM during do_launch's wait exits 143" || return 1
  assert_eq "$content" "ABSENT" "#451: no supervisor pid left behind after a TERM" || return 1
  assert_eq "$n" "0" "#451: nothing spawned" || return 1
}

# --- shared helpers --------------------------------------------------------------------------------------------------

test_pr451_count_running_skips_own_key() {
  pr_env
  /bin/sleep 20 & local sp=$!   # not $$: hc_cleanup kills every pid it finds
  echo "$sp" > "$PR_PIDF"
  local all own
  all=$( . "$RS_PR/config.sh"; . "$RS_PR/pipeline-lib.sh"; PIPE="$HC_PIPE"; count_running )
  own=$( . "$RS_PR/config.sh"; . "$RS_PR/pipeline-lib.sh"; PIPE="$HC_PIPE"; count_running "$PR_RK" )
  hc_cleanup
  assert_eq "$all" "1" "#451: control — a live reservation counts without the own-key argument" || return 1
  assert_eq "$own" "0" "#451: the launcher's own key is excluded" || return 1
}

test_pr451_launch_skip_event_tags() {
  pr_env
  local row
  ( . "$RS_PR/config.sh"; . "$RS_PR/pipeline-lib.sh"; PIPE="$HC_PIPE"; LOGDIR="$HC_HOME/logs/pipeline"; unset SLACK_WEBHOOK_URL
    launch_skip 42 orchestrate )
  row=$(pr_events)
  hc_cleanup
  assert_contains "$row" '"event":"launch_skip"' "#451: launch_skip row emitted" || return 1
  assert_contains "$row" '"reason":"pid-held"' "#451: reason pid-held" || return 1
  assert_contains "$row" '"route":"orchestrate"' "#451: route tag" || return 1
  assert_contains "$row" '"release":' "#451: release tag" || return 1
  assert_contains "$row" '"environment":' "#451: environment tag" || return 1
}

run_test test_pr451_manual_manual_one_spawn
run_test test_pr451_second_force_launch_also_refused_during_wait
run_test test_pr451_manual_then_drain_entry_dropped
run_test test_pr451_drain_then_manual_one_spawn
run_test test_pr451_lost_claim_restores_earlier_pid_content
run_test test_pr451_lost_claim_without_earlier_file_leaves_none
run_test test_pr451_do_launch_control_spawns
run_test test_pr451_do_launch_refuses_live_pid_and_logs_skip
run_test test_pr451_do_launch_lost_claim_restores_pid
run_test test_pr451_do_launch_claim_failures_restore_pid
run_test test_pr451_do_launch_lost_reservation_skips_spawn
run_test test_pr451_stop_refuses_supervisor_reservation
run_test test_pr451_term_during_manual_wait_restores_pid
run_test test_pr451_term_during_do_launch_wait_restores_pid
run_test test_pr451_count_running_skips_own_key
run_test test_pr451_launch_skip_event_tags
