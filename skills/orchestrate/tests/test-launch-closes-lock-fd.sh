# Regression for claude-agents#56 — the supervisor holds its single-flight lock as file descriptor 9
# and dispatches orchestrate.sh under it. The background launch must close fd 9 (9>&-), or the
# orchestrator inherits the lock for its whole life and every later supervisor tick exits silently.
#
# The stub `claude` records whether fd 9 is open in its own process. Every case runs in an isolated
# PIPE + HOME (config.sh prepends $HOME/.local/bin to PATH, so the fake gh/claude installed there win
# over any real binary). Placeholder repo names only.

HERE_LFD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_LFD="$HERE_LFD/../orchestrate.sh"

# lfd_env -> sets LFD_PIPE, LFD_HOME, LFD_REPO, LFD_TMP, LFD_OUT. Capacity is open (memory floor
# zeroed) so orchestrate.sh takes the launch path, not the queue.
lfd_env() {
  LFD_PIPE=$(new_pipe); LFD_HOME=$(new_home)
  LFD_REPO="$LFD_PIPE/repo-a"
  fixture_repo "$LFD_REPO" "project-a/repo-a"
  mk_fake_gh "$LFD_HOME/.local/bin"
  echo "project-a/repo-a" > "$LFD_HOME/.local/bin/gh-name-with-owner"
  echo 'MEM_FLOOR_MB=0' > "$LFD_HOME/.claude/pipeline/config.local.sh"
  LFD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-lfd.XXXXXX")
  LFD_OUT="$LFD_TMP/fd9-state"
  # stub claude: reports whether fd 9 is open in its own process, then exits
  cat > "$LFD_HOME/.local/bin/claude" <<EOF
#!/bin/bash
if { : >&9; } 2>/dev/null; then echo open; else echo closed; fi > "$LFD_OUT"
exit 0
EOF
  chmod +x "$LFD_HOME/.local/bin/claude"
}

lfd_cleanup() { cleanup_running; rm -rf "$LFD_PIPE" "$LFD_HOME" "$LFD_TMP"; }

# lfd_wait_for <file> -> 0 once the file is non-empty, 1 after ~5 s
lfd_wait_for() {
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -s "$1" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_lfd_launch_closes_inherited_fd9() {
  lfd_env
  local out rc state=missing
  out=$(HOME="$LFD_HOME" PATH="$LFD_HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$LFD_PIPE" QUEUE="$LFD_PIPE/queue" \
    "$ORCH_LFD" "$LFD_REPO" 42 2>&1 9>"$LFD_TMP/lock"); rc=$?
  lfd_wait_for "$LFD_OUT" && state=$(cat "$LFD_OUT")
  lfd_cleanup
  assert_exit0 "$rc" "#56/AC2: launch with fd 9 open in the caller exits 0" || return 1
  assert_contains "$out" "launched orchestrator" "#56/AC2: took the launch path" || return 1
  assert_eq "$state" "closed" "#56/AC2: the launched orchestrator must not inherit the caller's fd 9" || return 1
}

test_lfd_launch_without_fd9_is_unchanged() {
  lfd_env
  local out rc state=missing pidfile=absent
  out=$(HOME="$LFD_HOME" PATH="$LFD_HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$LFD_PIPE" QUEUE="$LFD_PIPE/queue" \
    "$ORCH_LFD" "$LFD_REPO" 42 2>&1 9>&-); rc=$?
  lfd_wait_for "$LFD_OUT" && state=$(cat "$LFD_OUT")
  [ -s "$(rkp "$LFD_PIPE/orch-42.pid")" ] && pidfile=present
  lfd_cleanup
  assert_exit0 "$rc" "#56/AC3: hand launch with no fd 9 open exits 0" || return 1
  assert_contains "$out" "launched orchestrator" "#56/AC3: took the launch path" || return 1
  assert_eq "$pidfile" "present" "#56/AC3: orch-42.pid written" || return 1
  assert_eq "$state" "closed" "#56/AC3: the stub ran and saw no fd 9" || return 1
}

run_test test_lfd_launch_closes_inherited_fd9
run_test test_lfd_launch_without_fd9_is_unchanged

# Regression for #603 — keep_awake's caffeinate inherited fd 9 and held the lock for 300 s. Every
# backgrounded launch in supervisor.sh (line ending/continuing with a lone `&`) must carry 9>&-.
test_lfd_every_supervisor_background_launch_closes_fd9() {
  local sup="$HERE_LFD/../supervisor.sh" bad
  bad=$(grep -nE '[^&>|]&( |$)' "$sup" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '&&' | grep -vF '9>&-')
  assert_eq "$bad" "" "#603: backgrounded launches in supervisor.sh missing 9>&-" || return 1
}

# Behavioural: run keep_awake with fd 9 held; the caffeinate it starts must not have fd 9 open.
test_lfd_keep_awake_caffeinate_does_not_inherit_fd9() {
  local t out state=missing
  t=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-lfd603.XXXXXX")
  mkdir -p "$t/bin"
  printf '#!/bin/bash\nif { : >&9; } 2>/dev/null; then echo open; else echo closed; fi > "%s/state"\n' "$t" > "$t/bin/caffeinate"
  chmod +x "$t/bin/caffeinate"
  mkdir -p "$t/q"; echo '{}' > "$t/q/orch-1.json"
  # extract keep_awake and run it with fd 9 open
  ( sed -n '/^keep_awake()/,/^}/p' "$HERE_LFD/../supervisor.sh" > "$t/fn.sh"
    QUEUE="$t/q" PIPE="$t/p" PATH="$t/bin:$PATH" bash -c 'slog(){ :; }; uname(){ echo Darwin; }; . "$1"; keep_awake; sleep 0.5' _ "$t/fn.sh" ) 9>"$t/lock" >/dev/null 2>&1
  lfd_wait_for "$t/state" && state=$(cat "$t/state")
  rm -rf "$t"
  assert_eq "$state" "closed" "#603: caffeinate launched by keep_awake must not inherit fd 9" || return 1
}

run_test test_lfd_every_supervisor_background_launch_closes_fd9
run_test test_lfd_keep_awake_caffeinate_does_not_inherit_fd9
