# Regression for claude-agents#603 (same class as #56) — supervisor.sh holds its single-flight lock as fd 9 for the whole
# tick. Any command it backgrounds (`... &`) inherits that fd unless the launch closes it (9>&-), and then the lock stays
# held after the tick for as long as the child lives: every launchd firing in that window exits silently at `flock -n 9`.
# #56 fixed one launch line and tested only that line; #603 was the keep-awake caffeinate, added later without 9>&-.
# This test reads every backgrounded command in supervisor.sh (continuation lines joined) and requires 9>&- on each.

HERE_BFD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUP_BFD="$HERE_BFD/../supervisor.sh"

# bfd_backgrounded_lines -> "<line>: <joined command>" for every logical line that backgrounds a command: a `&` that is
# not part of `&&`, `>&N`, `<&N` or `>&-`. Comment-only lines are skipped.
bfd_backgrounded_lines() {
  awk '{ if (sub(/\\$/, "")) { if (start == 0) start = NR; buf = buf $0; next }
         if (start == 0) start = NR; print start ": " buf $0; buf = ""; start = 0 }' "$SUP_BFD" \
    | grep -vE '^[0-9]+: *#' \
    | grep -E '(^|[^&<>])&([^&]|$)'
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
