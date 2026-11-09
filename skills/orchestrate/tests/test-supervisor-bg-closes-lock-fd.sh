# Regression for claude-agents#603 (same class as #56) — supervisor.sh holds its single-flight lock as fd 9 for the whole
# tick. Any command it backgrounds (`... &`) inherits that fd unless the launch closes it (9>&-), and then the lock stays
# held after the tick for as long as the child lives: every launchd firing in that window exits silently at the lock-acquire call.
# #56 fixed one launch line and tested only that line; #603 was the keep-awake caffeinate, added later without 9>&-.
# This test reads every backgrounded command in supervisor.sh and the files it sources (continuation lines joined) and requires 9>&- on each.

HERE_BFD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUP_BFD="$HERE_BFD/../supervisor.sh"
# #624: the lock is inherited by anything backgrounded in a file supervisor.sh sources too (goal-project.sh:320 leaked),
# so the detector reads supervisor.sh plus every file it sources, transitively (`source`/`. "<path>"` lines; $HERE,
# $RS_DIR and $_GOAL_LIB_DIR all resolve to the orchestrate dir).
ORCH_BFD=$(cd "$HERE_BFD/.." && pwd)
bfd_sourced_files() {
  local queue="$SUP_BFD" seen="" f ref
  while [ -n "$queue" ]; do
    f=${queue%%$'\n'*}; case "$queue" in *$'\n'*) queue=${queue#*$'\n'} ;; *) queue= ;; esac
    case "$seen" in *"|$f|"*) continue ;; esac
    [ -f "$f" ] || continue
    seen="$seen|$f|"; printf '%s\n' "$f"
    while IFS= read -r ref; do
      ref=${ref//\$HERE/$ORCH_BFD}; ref=${ref//\$RS_DIR/$ORCH_BFD}; ref=${ref//\$_GOAL_LIB_DIR/$ORCH_BFD}
      case "$ref" in /*) queue="${queue:+$queue$'\n'}$ref" ;; esac
    done < <(grep -hoE '^[[:space:]]*(source|\.) +"[^"]+"' "$f" | sed -E 's/^[[:space:]]*(source|\.) +"//; s/"$//')
  done
}

# bfd_backgrounded_lines -> "<file>:<line>: <joined command>" for every logical line that backgrounds a command: a `&` that is
# not part of `&&`, `>&N`, `<&N` or `>&-`. Comment-only lines are skipped.
bfd_backgrounded_lines() {
  local f
  for f in $(bfd_sourced_files); do
    awk -v F="${f#$ORCH_BFD/}" '
      function emit(   t) {   # test the line with quoted strings and trailing comments removed (a URL `&` or a prose `&` is not a launch)
        t = buf $0; gsub(/"[^"]*"/, "", t); gsub(/\047[^\047]*\047/, "", t); sub(/[ \t]#.*$/, "", t)
        if (t !~ /^[ \t]*#/ && t ~ /(^|[^&<>])&([^&]|$)/) print F ":" start ": " buf $0
      }
      { if (sub(/\\$/, "")) { if (start == 0) start = NR; buf = buf $0; next }
        if (start == 0) start = NR; emit(); buf = ""; start = 0 }' "$f"
  done
}

test_bfd_every_backgrounded_launch_closes_fd9() {
  local lines leaks n
  lines=$(bfd_backgrounded_lines)
  n=$(printf '%s\n' "$lines" | grep -c .)
  leaks=$(printf '%s\n' "$lines" | grep -v '9>&-' || true)
  [ "$n" -ge 3 ] || { fail "#603: detector found only $n backgrounded commands in supervisor.sh (expected several); detector broken?"; return 1; }
  assert_eq "$leaks" "" "#603: every backgrounded command in supervisor.sh must close fd 9 (9>&-); leaking:
$leaks" || return 1
}

test_bfd_keep_awake_launch_closes_fd9() {
  local line
  line=$(bfd_backgrounded_lines | grep -F 'caffeinate -i -t 300')
  assert_contains "$line" "caffeinate" "#603: the keep-awake caffeinate launch is a backgrounded command" || return 1
  assert_contains "$line" "9>&-" "#603: the keep-awake caffeinate launch closes fd 9" || return 1
}

run_test test_bfd_every_backgrounded_launch_closes_fd9
run_test test_bfd_keep_awake_launch_closes_fd9
