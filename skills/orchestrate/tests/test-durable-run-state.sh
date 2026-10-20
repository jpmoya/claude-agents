# Issue #332 — run state lives in a durable per-machine dir, survives a reboot. Placeholder paths only.
#   1  PIPE defaults to $HOME/.claude/pipeline/state (config.sh, stage-run.sh, hook, install.sh): no /tmp default left
#   2  one-time move of the legacy dir when the new path is absent; symlink left behind; nothing moved when it exists
#   3  first config.sh load after a NEW boot neutralises stored pids (kill -0 cannot match a recycled pid); same boot / first deploy leave them
#   4  an explicit PIPE is never moved

HERE_DR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SK_DR="$HERE_DR/.."

dr_src() {  # dr_src <home> <legacy> [boot] [PIPE]  -> prints resulting PIPE
  ( unset PIPE; [ -z "${4:-}" ] || export PIPE="$4"; export HOME="$1" PIPE_LEGACY="$2"; [ -z "${3:-}" ] || export PIPELINE_BOOT_EPOCH="$3"
    . "$SK_DR/config.sh" >/dev/null 2>&1; printf %s "$PIPE" )
}

test_dr_1_no_tmp_default() {
  local f
  for f in "$SK_DR/config.sh" "$SK_DR/stage-run.sh" "$SK_DR/../../hooks/require-handoff-marker.sh"; do
    grep -q 'PIPE:-/tmp/pipeline' "$f" && { fail "#332/1: $f still defaults PIPE to /tmp"; return 1; }
  done
  grep -q 'tmp/pipeline' "$SK_DR/install.sh" && { fail "#332/1: install.sh still names /tmp/pipeline"; return 1; }
  return 0
}

test_dr_2_one_time_move() {
  local home legacy p
  home=$(new_home); legacy=$(mktemp -d "${TMPDIR:-/tmp}/dr-legacy.XXXXXX"); mkdir "$legacy/inner"; : > "$legacy/inner/orch-x.pid"; rm -rf "$legacy"; mkdir -p "$legacy"; : > "$legacy/sentinel"
  p=$(dr_src "$home" "$legacy" 100)
  local moved=no link=no
  [ "$p" = "$home/.claude/pipeline/state" ] || { fail "#332/2: PIPE=$p"; return 1; }
  [ -e "$p/sentinel" ] && moved=yes
  [ -L "$legacy" ] && link=yes
  # second load must not move again / clobber
  : > "$p/second"; mkdir -p "$legacy.2"; : > "$legacy.2/other"
  dr_src "$home" "$legacy.2" 100 >/dev/null
  local kept=no; [ -e "$p/second" ] && [ -e "$legacy.2/other" ] && kept=yes
  rm -rf "$home" "$legacy" "$legacy.2"
  assert_eq "$moved" "yes" "#332/2: legacy contents moved" || return 1
  assert_eq "$link" "yes" "#332/2: symlink left at the legacy path" || return 1
  assert_eq "$kept" "yes" "#332/2: no move when the new path exists" || return 1
}

test_dr_3_boot_neutralises_pids() {
  local home legacy p
  home=$(new_home); legacy="$home/none"; p="$home/.claude/pipeline/state"; mkdir -p "$p"
  echo 4242 > "$p/orch-a_b-1.pid"; echo 4242 > "$p/a_b-1-code-reviewer.pid"
  dr_src "$home" "$legacy" 100 >/dev/null          # first load: no stamp (first deploy, runs still alive) -> record only
  local first; first=$(cat "$p/orch-a_b-1.pid")
  dr_src "$home" "$legacy" 100 >/dev/null          # same boot: untouched
  local same; same=$(cat "$p/orch-a_b-1.pid")
  dr_src "$home" "$legacy" 200 >/dev/null          # new boot (stamp differs): neutralised again
  local after stage; after=$(cat "$p/orch-a_b-1.pid"); stage=$(cat "$p/a_b-1-code-reviewer.pid")
  rm -rf "$home"
  assert_eq "$first" "4242" "#332/3: first deploy (no stamp) leaves live pids alone" || return 1
  assert_eq "$same" "4242" "#332/3: same boot leaves pids alone" || return 1
  assert_eq "$after" "2147483646" "#332/3: next boot neutralises again" || return 1
  assert_eq "$stage" "2147483646" "#332/3: stage pid files too" || return 1
  kill -0 2147483646 2>/dev/null && { fail "#332/3: neutral pid must not be alive"; return 1; }
  return 0
}

test_dr_4_explicit_pipe_not_moved() {
  local home legacy exp
  home=$(new_home); legacy=$(mktemp -d "${TMPDIR:-/tmp}/dr-legacy.XXXXXX"); : > "$legacy/sentinel"; exp="$home/explicit"
  dr_src "$home" "$legacy" 100 "$exp" >/dev/null
  local kept=no; [ -e "$legacy/sentinel" ] && kept=yes
  rm -rf "$home" "$legacy"
  assert_eq "$kept" "yes" "#332/4: explicit PIPE leaves the legacy dir alone" || return 1
}

run_test test_dr_1_no_tmp_default
run_test test_dr_2_one_time_move
run_test test_dr_3_boot_neutralises_pids
run_test test_dr_4_explicit_pipe_not_moved
