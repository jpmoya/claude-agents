# #720: hooks/limit-shells.sh's age kill selects only real Claude Code tool shells
# ("<path>/<shell> -c source …/.claude/shell-snapshots/snapshot-…") older than 600s — not any process
# whose command line merely mentions claude and bash (pipeline stages whose prompt says "bash").
# Offline: a fake `ps` mimics macOS (no `etimes` keyword; `etime` as [[dd-]hh:]mm:ss) and serves a fixture
# `ps -axo pid=,etime=,command=` table whose pids are harmless
# `sleep` processes the test spawns itself; a pid that is no longer alive afterwards was selected.

HERE_720=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK_720="$(cd "$HERE_720/../../.." && pwd)/hooks/limit-shells.sh"
SNAP_720='-c source /Users/x/.claude/shell-snapshots/snapshot-zsh-1794817270487-otha0l.sh 2>/dev/null || true && eval '

l720_setup() {  # sets L720_DIR; empties the pid list
  L720_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-limitshells720.XXXXXX")
  mkdir -p "$L720_DIR/bin"
  : > "$L720_DIR/table"
  L720_PIDS=""
  cat > "$L720_DIR/bin/ps" <<'PS'
#!/bin/bash
case "$*" in
  *etimes*) echo "ps: etimes: keyword not found" >&2; exit 1 ;;
  *etime=*) cat "$L720_DIR/table" ;;
esac
exit 0
PS
  chmod +x "$L720_DIR/bin/ps"
}

l720_proc() {  # l720_proc <name> <etime> <command> — spawns a sleeper and lists it in the fixture table
  sleep 60 </dev/null >/dev/null 2>&1 &
  local pid=$!
  eval "L720_PID_$1=$pid"
  L720_PIDS="$L720_PIDS $pid"
  printf '%s %s %s\n' "$pid" "$2" "$3" >> "$L720_DIR/table"
}

l720_run() {
  env -i PATH="$L720_DIR/bin:$PATH" L720_DIR="$L720_DIR" bash "$HOOK_720" >/dev/null 2>&1
  sleep 0.2
}

l720_alive() {  # l720_alive <name> — running (a killed child may linger as a zombie until reaped)
  local pid st
  eval "pid=\$L720_PID_$1"
  st=$(command ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "$st" ] && [ "${st#Z}" = "$st" ]
}

l720_cleanup() { local p; for p in $L720_PIDS; do kill "$p" 2>/dev/null; done; wait $L720_PIDS 2>/dev/null; return 0; }

l720_expect() {  # l720_expect <name> alive|dead <message>
  local want=$2 got=dead
  l720_alive "$1" && got=alive
  [ "$got" = "$want" ] || { l720_cleanup; fail "$3"; return 1; }
}

test_limit_shells_age_kill_selects_only_old_snapshot_tool_shells() {
  l720_setup
  l720_proc stage 11:40 'claude --agent fullstack-developer -p Fix it. run bash .github/scripts/x.test.sh then push'
  l720_proc wrapper 11:40 'bash /Users/x/.claude/skills/orchestrate/stage-run.sh a b -- claude --agent fullstack-developer -p run bash x.sh'
  l720_proc oldbash 10:01 "/bin/bash $SNAP_720'sleep 1'"
  l720_proc oldzsh 01:11:40 "/bin/zsh $SNAP_720'sleep 1'"
  l720_proc oldgrep 1-02:03:04 "/bin/bash $SNAP_720'until grep -q done f; do sleep 5; done'"
  l720_proc young 09:59 "/bin/bash $SNAP_720'sleep 1'"
  l720_run
  l720_expect stage alive "a claude stage whose prompt says bash must not be selected" || return 1
  l720_expect wrapper alive "the stage-run.sh wrapper must not be selected" || return 1
  l720_expect young alive "a snapshot tool shell under 600s must not be selected" || return 1
  l720_expect oldbash dead "an old bash snapshot tool shell must be selected" || return 1
  l720_expect oldzsh dead "an old zsh snapshot tool shell must be selected" || return 1
  l720_expect oldgrep dead "an old tool shell whose command contains grep must be selected" || return 1
  l720_cleanup
}

run_test test_limit_shells_age_kill_selects_only_old_snapshot_tool_shells
