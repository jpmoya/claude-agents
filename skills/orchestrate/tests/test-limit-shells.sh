# #729: hooks/limit-shells.sh per-session cap counts only real tool shells ("<shell> -c source
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
# Serve the fixture for `ps -axo pid=,ppid=,command=` (and `ps -eo pid,command` without ppid); empty otherwise.
case "$*" in
  *etimes*) ;;   # never feed the age kill: it would `kill` fixture pids that may be real host processes
  *ppid=*) sed "s/@HOOKPARENT@/$(cat "$LS_DIR/hookparent")/" "$LS_DIR/table" ;;
  *pid,command*) sed "s/@HOOKPARENT@/$(cat "$LS_DIR/hookparent")/" "$LS_DIR/table" | awk '{ $2 = ""; print }' ;;   # old-style count, so the table also reaches the pre-#729 grep
esac
exit 0
PS
  chmod +x "$LS_DIR/bin/ps"
  : > "$LS_DIR/table"
}

ls_row() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$LS_DIR/table"; }   # pid ppid command

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
  LS_ERR=$(env -i PATH="$LS_DIR/bin:$PATH" LS_DIR="$LS_DIR" CLAUDE_CODE_SESSION_ID="$SID_LS" "$@" \
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

run_test test_limit_shells_non_shell_session_processes_do_not_block
run_test test_limit_shells_four_real_shells_plus_noise_allowed
run_test test_limit_shells_five_real_shells_block
run_test test_limit_shells_grep_command_shell_is_counted
run_test test_limit_shells_other_session_shells_do_not_count
run_test test_limit_shells_claude_pid_env_used_when_it_is_an_ancestor
run_test test_limit_shells_stale_claude_pid_falls_back_to_chain
run_test test_limit_shells_nested_cli_counts_its_own_shells_not_inherited_claude_pid
