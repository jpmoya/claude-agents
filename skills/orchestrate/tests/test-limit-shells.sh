# #729/#803: hooks/limit-shells.sh per-session cap counts only real tool shells ("<shell> -c source
# …/.claude/shell-snapshots/snapshot-…") whose parent is this session's claude CLI — not every process
# whose argv names the session id. Offline: a fake `ps` on PATH serves a fixture process table (and
# feeds nothing to the age kill).

HERE_LS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_LS="$(cd "$HERE_LS/../../.." && pwd)/hooks/limit-shells.sh"
SID_LS="c3fbcf2e-40f1-4c4c-be68-341c779faaa5"
OTHER_SID_LS="0aa11bb2-0000-4000-8000-000000000000"
CLI_LS='/Users/x/Library/Application Support/Claude/claude-code/2.1.321/claude.app/Contents/MacOS/claude --output-format stream-json --resume='
TOOL_LS='/bin/zsh -c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1794817270487-otha0l.sh 2>/dev/null || true && eval '

ls_setup() {  # fresh fake ps + table; sets LS_DIR
  LS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-limitshells.XXXXXX")
  mkdir -p "$LS_DIR/bin"
  cat > "$LS_DIR/bin/ps" <<'PS'
#!/bin/bash
# Serve the fixture for `ps -axo pid=,ppid=,stat=,etime=,command=`; empty otherwise.
case "$*" in
  *etimes*) ;;   # never feed the age kill: it would `kill` fixture pids that may be real host processes
  *ppid=*) sed "s/@HOOKPARENT@/$(cat "$LS_DIR/hookparent")/" "$LS_DIR/table" ;;
esac
exit 0
PS
  chmod +x "$LS_DIR/bin/ps"
  : > "$LS_DIR/table"
}

ls_row() { printf '%s %s Ss 00:05 %s\n' "$1" "$2" "$3" >> "$LS_DIR/table"; }   # pid ppid command (live, 5s old)
ls_rowx() { printf '%s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" >> "$LS_DIR/table"; }   # pid ppid stat etime command

ls_cli() {  # ls_cli <pid> <session id> [ppid=1] — a claude CLI (+ its disclaimer wrapper, as the app runs it)
  ls_row "$(($1 - 1))" 819 "/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup -- ${CLI_LS}$2"
  ls_row "$1" "$(($1 - 1))" "${CLI_LS}$2"
}

ls_shells() {  # ls_shells <n> <parent pid> <first pid> — n real tool shells; the first one mentions grep
  local i
  for i in $(seq 1 "$1"); do
    if [ "$i" -eq 1 ]; then ls_row "$(($3 + i))" "$2" "${TOOL_LS}'ps -eo pid,command | grep -F foo'"
    else ls_row "$(($3 + i))" "$2" "${TOOL_LS}'echo $i'"; fi
  done
}

ls_noise() {  # everything the old grep counted that is NOT a tool shell of CLI 9000
  ls_row 9100 1 "bash /private/tmp/claude-501/-Users-x-dev/$SID_LS/scratchpad/run-one.sh test-a.sh"   # detached script
  ls_row 9101 9100 "bash /private/tmp/claude-501/-Users-x-dev/$SID_LS/scratchpad/run-one.sh test-a.sh" # its subshell
  ls_row 9201 9301 "${TOOL_LS}'echo 1'"   # forked subshell of tool shell 9301 (shares its argv)
  ls_row 9202 9301 "${TOOL_LS}'echo 1'"
}

ls_run() {  # ls_run [env assignments...] — runs the hook; sets LS_RC, LS_ERR. Hook's parent = a launcher bash (@HOOKPARENT@).
  local rc=0
  LS_ERR=$(env -i PATH="$LS_DIR/bin:$PATH" LS_DIR="$LS_DIR" CLAUDE_CODE_SESSION_ID="$SID_LS" LIMIT_SHELLS_LOG="$LS_DIR/log" "$@" \
    bash -c 'printf "%s" "$$" > "$LS_DIR/hookparent"; bash "$0"; echo $? > "$LS_DIR/rc"' "$HOOK_LS" 2>&1 >/dev/null)
  LS_RC=$(cat "$LS_DIR/rc")
}

ls_chain_base() {  # CLI 9000 (resume) -> launcher @HOOKPARENT@ (the hook's parent)
  ls_cli 9000 "$SID_LS"
  ls_row @HOOKPARENT@ 9000 "bash -c hook-launcher"
}

test_limit_shells_non_shell_session_processes_do_not_block() {
  ls_setup; ls_chain_base; ls_noise
  ls_row 9102 1 "node /private/tmp/claude-501/x/$SID_LS/scratchpad/worker.js"
  ls_row 9103 9102 "python3 /private/tmp/claude-501/x/$SID_LS/scratchpad/t.py"
  ls_run
  assert_eq "$LS_RC" "0" "6 non-shell processes naming the session id are not shells" || return 1
  assert_eq "$LS_ERR" "" "no BLOCKED message"
}

test_limit_shells_four_real_shells_plus_noise_allowed() {
  ls_setup; ls_chain_base; ls_noise; ls_shells 4 9000 9300
  ls_run
  assert_eq "$LS_RC" "0" "4 tool shells (one mentions grep) + resume/detached/subshell noise: count 4, allowed" || return 1
}

test_limit_shells_five_real_shells_block() {
  ls_setup; ls_chain_base; ls_noise; ls_shells 5 9000 9300
  ls_run
  assert_eq "$LS_RC" "2" "5 tool shells of this CLI block" || return 1
  assert_contains "$LS_ERR" "BLOCKED: 5 shells in this session (max 5)" "message"
}

test_limit_shells_grep_command_shell_is_counted() {
  ls_setup; ls_chain_base; ls_shells 5 9000 9300   # shell 1 contains "grep"
  ls_run
  assert_contains "$LS_ERR" "BLOCKED: 5 shells" "the grep shell is not filtered out" || return 1
}

test_limit_shells_other_session_shells_do_not_count() {
  ls_setup; ls_chain_base; ls_shells 2 9000 9300
  ls_cli 9500 "$OTHER_SID_LS"; ls_shells 6 9500 9600
  ls_run
  assert_eq "$LS_RC" "0" "2 own + 6 of another session: allowed" || return 1
  ls_setup; ls_chain_base; ls_shells 5 9000 9300
  ls_cli 9500 "$OTHER_SID_LS"; ls_shells 3 9500 9600
  ls_run
  assert_eq "$LS_RC" "2" "5 own block" || return 1
  assert_contains "$LS_ERR" "BLOCKED: 5 shells" "count is own shells only (not 8)"
}

test_limit_shells_claude_pid_env_used_when_it_is_an_ancestor() {
  ls_setup; ls_row 9000 1 "node /opt/cli/cli.js"; ls_row @HOOKPARENT@ 9000 "bash -c hook-launcher"   # CLI not recognisable by name
  ls_shells 5 9000 9300
  ls_run CLAUDE_PID=9000
  assert_eq "$LS_RC" "2" "CLAUDE_PID is an ancestor: used" || return 1
  ls_run CLAUDE_PID=
  assert_eq "$LS_RC" "0" "no CLAUDE_PID and no claude ancestor: fail open" || return 1
}

test_limit_shells_stale_claude_pid_falls_back_to_chain() {
  ls_setup; ls_chain_base; ls_shells 5 9000 9300
  ls_run CLAUDE_PID=4242
  assert_eq "$LS_RC" "2" "CLAUDE_PID not in the process table: parent chain used" || return 1
}

test_limit_shells_nested_cli_counts_its_own_shells_not_inherited_claude_pid() {
  # A pipeline stage (`claude -p`, CLI 9700) launched from a tool shell (9301) of the orchestrator CLI 9000
  # inherits CLAUDE_PID=9000 but must be capped on its own 5 shells, not on 9000's 2.
  ls_setup; ls_cli 9000 "$OTHER_SID_LS"; ls_shells 2 9000 9300
  ls_cli 9700 "$SID_LS"; ls_row @HOOKPARENT@ 9700 "bash -c hook-launcher"; ls_shells 5 9700 9800
  ls_run CLAUDE_PID=9000
  assert_eq "$LS_RC" "2" "blocks on the nested CLI's own 5" || return 1
  assert_contains "$LS_ERR" "BLOCKED: 5 shells" "not the parent's count"
  ls_setup; ls_cli 9000 "$OTHER_SID_LS"; ls_shells 5 9000 9300
  ls_cli 9700 "$SID_LS"; ls_row @HOOKPARENT@ 9700 "bash -c hook-launcher"; ls_shells 2 9700 9800
  ls_run CLAUDE_PID=9000
  assert_eq "$LS_RC" "0" "parent's 5 shells do not block the nested CLI's 2" || return 1
}

test_limit_shells_global_counts_only_tool_shells_of_claude_clis() {  # #803: 19 shells + noise -> allowed; 20 -> blocked
  ls_setup; ls_chain_base; ls_noise
  ls_cli 9500 "$OTHER_SID_LS"; ls_shells 4 9500 9600
  ls_shells 15 9000 9700   # per-session cap is lifted below so only the global cap is exercised
  ls_run LIMIT_SHELLS_MAX_PER_SESSION=100
  assert_eq "$LS_RC" "0" "19 tool shells + scratchpad script + subshells + orphan: allowed" || return 1
  assert_eq "$LS_ERR" "" "no BLOCKED message" || return 1
  ls_shells 1 9500 9800
  ls_run LIMIT_SHELLS_MAX_PER_SESSION=100
  assert_eq "$LS_RC" "2" "20 tool shells block" || return 1
  assert_contains "$LS_ERR" "BLOCKED: 20 background shells globally (max 20)" "message names the real count"
}

test_limit_shells_orphaned_and_scratchpad_processes_do_not_count_globally() {
  ls_setup; ls_chain_base
  local i
  for i in $(seq 1 25); do ls_row $((9100 + i)) 1 "bash /private/tmp/claude-501/x/scratchpad/s$i.sh"; done   # orphaned scripts
  for i in $(seq 1 25); do ls_row $((9200 + i)) 1 "${TOOL_LS}'sleep $i'"; done   # orphaned tool shells (ppid 1)
  ls_run
  assert_eq "$LS_RC" "0" "25 orphan scripts + 25 orphaned tool shells: not counted" || return 1
}

test_limit_shells_zombie_and_stale_shells_do_not_count() {
  ls_setup; ls_chain_base; ls_shells 3 9000 9300
  ls_rowx 9400 9000 Z 00:30 "${TOOL_LS}'dead'"          # zombie
  ls_rowx 9401 9000 S 01:00:00 "${TOOL_LS}'old test run'"   # 1h: stale
  ls_rowx 9402 9000 S 2-03:04:05 "${TOOL_LS}'older'"       # 2 days: stale
  ls_run
  assert_eq "$LS_RC" "0" "3 live + zombie + 2 stale: count 3, allowed" || return 1
  ls_rowx 9403 9000 S 29:59 "${TOOL_LS}'just under the bound'"
  ls_rowx 9404 9000 S 00:00 "${TOOL_LS}'fresh'"
  ls_run
  assert_eq "$LS_RC" "2" "5 live shells (one 29:59 old) block" || return 1
  assert_contains "$LS_ERR" "BLOCKED: 5 shells in this session (max 5)" "message"
}

test_limit_shells_stale_bound_is_configurable() {
  ls_setup; ls_chain_base; ls_shells 4 9000 9300
  ls_rowx 9400 9000 S 05:00 "${TOOL_LS}'five minutes'"
  ls_run LIMIT_SHELLS_STALE_SECONDS=60
  assert_eq "$LS_RC" "0" "bound 60s: the 5-minute shell is stale" || return 1
  ls_run LIMIT_SHELLS_STALE_SECONDS=0
  assert_eq "$LS_RC" "2" "bound 0 disables the bound" || return 1
}

test_limit_shells_cap_is_configurable() {
  ls_setup; ls_chain_base; ls_shells 5 9000 9300
  ls_run LIMIT_SHELLS_MAX_PER_SESSION=6
  assert_eq "$LS_RC" "0" "cap 6: 5 shells allowed" || return 1
  ls_run LIMIT_SHELLS_MAX_PER_SESSION=3
  assert_eq "$LS_RC" "2" "cap 3: 5 shells block" || return 1
  assert_contains "$LS_ERR" "(max 3)" "message shows configured cap" || return 1
  ls_run LIMIT_SHELLS_MAX_PER_SESSION=banana
  assert_eq "$LS_RC" "2" "garbage cap falls back to 5" || return 1
}

test_limit_shells_fails_open_and_logs_when_undecidable() {
  ls_setup; ls_row 9000 1 "node /opt/cli/cli.js"; ls_row @HOOKPARENT@ 9000 "bash -c hook-launcher"; ls_shells 9 9000 9300
  ls_run CLAUDE_PID= LIMIT_SHELLS_LOG="$LS_DIR/log"
  assert_eq "$LS_RC" "0" "CLI not found: allowed" || return 1
  assert_contains "$(cat "$LS_DIR/log")" "fail-open: claude CLI of this session not found" "one log line" || return 1
  rm -f "$LS_DIR/log" "$LS_DIR"/log.*; : > "$LS_DIR/table"
  ls_run LIMIT_SHELLS_LOG="$LS_DIR/log"
  assert_eq "$LS_RC" "0" "empty process table: allowed" || return 1
  assert_contains "$(cat "$LS_DIR/log")" "fail-open: ps returned no process table" "logged"
}

test_limit_shells_ceiling_counts_stale_shells_and_names_them() {
  ls_setup; ls_chain_base; ls_shells 2 9000 9300
  local i
  for i in $(seq 1 37); do ls_rowx $((9400 + i)) 9000 S 02:00:00 "${TOOL_LS}'leaked $i'"; done
  ls_run LIMIT_SHELLS_MAX_GLOBAL=100
  assert_eq "$LS_RC" "0" "2 live + 37 stale = 39 < 40: stale exempt from the per-session cap, allowed" || return 1
  ls_rowx 9500 9000 S 03:00:00 "${TOOL_LS}'leaked 38'"
  ls_run LIMIT_SHELLS_MAX_GLOBAL=100
  assert_eq "$LS_RC" "2" "2 live + 38 stale = 40: ceiling blocks" || return 1
  assert_contains "$LS_ERR" "BLOCKED: 40 shells in total (38 stale" "message gives total and stale count" || return 1
  assert_contains "$LS_ERR" "kill 9401 9402" "message lists the stale pids to reap" || return 1
  ls_run LIMIT_SHELLS_MAX_GLOBAL=100 LIMIT_SHELLS_MAX_TOTAL=100
  assert_eq "$LS_RC" "0" "ceiling is configurable" || return 1
}

test_limit_shells_fail_open_log_is_throttled() {
  ls_setup; ls_row 9000 1 "node /opt/cli/cli.js"; ls_row @HOOKPARENT@ 9000 "bash -c hook-launcher"
  ls_run CLAUDE_PID=; ls_run CLAUDE_PID=; ls_run CLAUDE_PID=
  assert_eq "$(wc -l < "$LS_DIR/log" | tr -d ' ')" "1" "three fail-opens inside 10 minutes: one log line" || return 1
  touch -t 200001010000 "$LS_DIR/log.failopen"
  ls_run CLAUDE_PID=
  assert_eq "$(wc -l < "$LS_DIR/log" | tr -d ' ')" "2" "after 10 minutes: logged again"
}

test_limit_shells_logs_once_when_no_claude_parent_matches() {
  ls_setup; ls_chain_base; ls_row 9700 4242 "${TOOL_LS}'orphan-ish'"   # tool shell whose parent is not a claude CLI
  ls_run; ls_run
  assert_eq "$LS_RC" "0" "allowed" || return 1
  assert_eq "$(grep -c 'none has a claude CLI parent' "$LS_DIR/log")" "1" "logged once across two runs"
}

run_test test_limit_shells_non_shell_session_processes_do_not_block
run_test test_limit_shells_four_real_shells_plus_noise_allowed
run_test test_limit_shells_five_real_shells_block
run_test test_limit_shells_grep_command_shell_is_counted
run_test test_limit_shells_other_session_shells_do_not_count
run_test test_limit_shells_claude_pid_env_used_when_it_is_an_ancestor
run_test test_limit_shells_stale_claude_pid_falls_back_to_chain
run_test test_limit_shells_nested_cli_counts_its_own_shells_not_inherited_claude_pid
run_test test_limit_shells_global_counts_only_tool_shells_of_claude_clis
run_test test_limit_shells_orphaned_and_scratchpad_processes_do_not_count_globally
run_test test_limit_shells_zombie_and_stale_shells_do_not_count
run_test test_limit_shells_stale_bound_is_configurable
run_test test_limit_shells_cap_is_configurable
run_test test_limit_shells_fails_open_and_logs_when_undecidable
run_test test_limit_shells_ceiling_counts_stale_shells_and_names_them
run_test test_limit_shells_fail_open_log_is_throttled
run_test test_limit_shells_logs_once_when_no_claude_parent_matches
