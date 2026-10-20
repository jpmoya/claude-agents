# #318 — run state keyed by owner/repo + issue. Scheduler #100 and quoting #100 must not share files.
# Expected values come from the ticket (key = <owner>_<repo>-<N>, files orch-<key>.*, <key>-<agent>-before.txt,
# locked-<key>.txt, run-<key>-<agent>.log) or hand arithmetic in comments — never from the code under test.
# Every "after" state is produced by running the shipped scripts (orchestrate.sh, supervisor.sh, the hook,
# reconcile-status.sh); only LEGACY orch-<N>.* files are hand-seeded.
# Everything is prefixed rk_ / RK_ (all test files share one shell). Placeholder repo names only (public repo).
# Interpretation flagged for the PM: the AC6 error row is provoked by a legacy set whose new-key files already
# exist (rename cannot be atomic) — the ticket names no trigger.

RK_SKILL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RK_ROOT=$(cd "$RK_SKILL/../.." && pwd)
RK_A="example-owner/project-a"; RK_B="example-owner/project-b"
RK_KA="example-owner_project-a"; RK_KB="example-owner_project-b"
RK_TREE=""; RK_HOME=""; RK_PIPE=""

rk_tree_init() {
  [ -n "$RK_TREE" ] && [ -d "$RK_TREE" ] && return 0
  RK_TREE=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-rktree.XXXXXX")
  mkdir -p "$RK_TREE/skills" "$RK_TREE/hooks"
  cp -R "$RK_SKILL" "$RK_TREE/skills/orchestrate"; rm -rf "$RK_TREE/skills/orchestrate/tests"
  cp "$RK_ROOT"/hooks/*.sh "$RK_TREE/hooks/"
  printf '#!/bin/bash\nexit 0\n' > "$RK_TREE/skills/orchestrate/report-status.sh"; chmod +x "$RK_TREE/skills/orchestrate/report-status.sh"
  ( cd "$RK_TREE" && git init -q && git add -A && git -c user.email=t@example.invalid -c user.name=t commit -q -m tree ) >/dev/null 2>&1
}

# rk_env [max_concurrent] — isolated HOME/PIPE, two checkouts (project-a, project-b), fakes on PATH.
rk_env() {
  rk_tree_init
  RK_HOME=$(new_home); RK_PIPE=$(new_pipe)
  RK_HOME=${RK_HOME//\/\//\/}; RK_PIPE=${RK_PIPE//\/\//\/}  # TMPDIR ending in / must not leave // in paths
  RK_REPO_A="$RK_HOME/repo-a"; RK_REPO_B="$RK_HOME/repo-b"
  fixture_repo "$RK_REPO_A" "$RK_A"; fixture_repo "$RK_REPO_B" "$RK_B"
  RK_BIN="$RK_HOME/.local/bin"; mkdir -p "$RK_BIN"
  printf 'MEM_FLOOR_MB=0\nMAX_CONCURRENT=%s\nDISPATCH_REPOS=()\n' "${1:-3}" > "$RK_HOME/.claude/pipeline/config.local.sh"
  # gh: repo resolved from the cwd's git origin (so two repos never collide); issue state per repo via gh-state-<slug> files.
  cat > "$RK_BIN/gh" <<'RKGH'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
repo=$(git config --get remote.origin.url 2>/dev/null | sed -e 's#.*github.com/##' -e 's#\.git$##')
jq=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && jq=$a; prev=$a; done
emit() { if [ -n "$jq" ]; then printf '%s' "$1" | jq -r "$jq"; else printf '%s\n' "$1"; fi; }
case "$*" in
  "issue view"*) st=$(cat "$HERE/gh-state-$(printf '%s' "$repo" | tr / _)" 2>/dev/null || echo OPEN)
    emit "{\"state\":\"$st\",\"closedAt\":\"2026-01-01T00:00:00Z\",\"labels\":[],\"comments\":[],\"title\":\"t\",\"milestone\":null}" ;;
  "repo view"*) emit "{\"nameWithOwner\":\"$repo\"}" ;;
  "issue list"*|"api"*) echo '[]' ;;
  *) exit 0 ;;
esac
RKGH
  # claude: stays alive until killed; records its pid so cleanup can reap it
  cat > "$RK_BIN/claude" <<'RKCL'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
echo $$ >> "$HERE/claude.pids"
exec sleep 300
RKCL
  printf '#!/bin/bash\necho Host-A\n' > "$RK_BIN/hostname"
  chmod +x "$RK_BIN/gh" "$RK_BIN/claude" "$RK_BIN/hostname"
}

rk_cleanup() {
  local p f
  for f in "$RK_PIPE"/orch-*.pid; do [ -e "$f" ] || continue; p=$(cat "$f" 2>/dev/null); [ -n "$p" ] && { pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; }; done
  for p in $(cat "$RK_BIN/claude.pids" 2>/dev/null); do kill "$p" 2>/dev/null; done
  rm -rf "$RK_HOME" "$RK_PIPE"
}

rk_orch() {  # rk_orch <args…> — shipped orchestrate.sh from the copied tree; stdout+stderr, rc in RK_RC
  RK_RC=0
  ( cd "$RK_HOME" && env HOME="$RK_HOME" PATH="$RK_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" LOGDIR="$RK_HOME/logs/pipeline" \
      PIPELINE_TEST_CLAIM_SETTLE_SECS=0 bash "$RK_TREE/skills/orchestrate/orchestrate.sh" "$@" ) 2>&1 || RK_RC=$?
}
# rk_orch_out <args…> — like rk_orch but sets RK_OUT and RK_RC in the CURRENT shell (no $(…) subshell, which would lose RK_RC).
rk_orch_out() {
  local f; f=$(mktemp "${TMPDIR:-/tmp}/orch-test-rkout.XXXXXX")
  rk_orch "$@" >"$f"; RK_OUT=$(cat "$f"); rm -f "$f"
}
rk_tick() {
  RK_RC=0
  ( cd "$RK_HOME" && env HOME="$RK_HOME" PATH="$RK_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" LOGDIR="$RK_HOME/logs/pipeline" \
      SLACK_BOT_TOKEN="xoxb-SENTINEL-TOKEN" SLACK_ENGINEERING_CHANNEL="" GH_TOKEN="ghp_SENTINEL" \
      bash "$RK_TREE/skills/orchestrate/supervisor.sh" >"$RK_HOME/tick.out" 2>&1 </dev/null ) || RK_RC=$?
  rk_settle
}
rk_settle() {  # bounded poll (max ~5s): wait until the PIPE file listing is unchanged for 3 consecutive 0.1s checks
  local prev cur same=0 i
  for i in $(seq 1 50); do
    cur=$(find "$RK_PIPE" -type f 2>/dev/null | sort | xargs cat 2>/dev/null | cksum; find "$RK_PIPE" -type f | sort)
    if [ "$cur" = "$prev" ]; then same=$((same+1)); [ "$same" -ge 3 ] && return 0; else same=0; fi
    prev=$cur; sleep 0.1
  done
  return 0
}
# rk_pid_alive <pid> — alive and not a zombie (a killed fixture child of this shell stays a zombie until reaped).
rk_pid_alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' '); [ -n "$st" ] && [ "${st#Z}" = "$st" ]; }
rk_alive() { local p; p=$(cat "$1" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
rk_legacy_names() {  # basenames in PIPE (recursive) that match the forbidden legacy shapes
  find "$RK_PIPE" -type f 2>/dev/null | sed 's#.*/##' | grep -E '^orch-[0-9]+\.|^[0-9]+-[a-z-]+-(before|nags)\.txt' || true
}
rk_launch2() {  # scheduler(A) #100 then quoting(B) #100, hand launches with --force
  rk_orch --force "$RK_REPO_A" 100 >/dev/null; rk_orch --force "$RK_REPO_B" 100 >/dev/null
}

# ---------------------------------------------------------------- AC1: run_key ------------------------------------

rk_runkey() { ( . "$RK_SKILL/pipeline-lib.sh"; run_key "$@" ) 2>/dev/null; }

test_rk_ac1_run_key_slash_becomes_underscore() {
  local out rc=0; out=$(rk_runkey example-owner/project-a 100) || rc=$?
  assert_exit0 "$rc" "AC1: exit 0" && assert_eq "$out" "example-owner_project-a-100" "AC1: <owner>_<repo>-<N> (ticket)"
}
test_rk_ac1_run_key_keeps_dots_in_repo_name() {
  local out rc=0; out=$(rk_runkey example-owner/project.js 7) || rc=$?
  assert_exit0 "$rc" "AC1: exit 0" && assert_eq "$out" "example-owner_project.js-7" "AC1: dots kept"
}
# Leading zeros: the ticket pins no value. Octal arithmetic would print -8 for 010 and error on 08; either kept or
# normalised decimal is acceptable, anything else is not.
test_rk_ac1_run_key_leading_zeros_not_octal() {
  local out rc=0; out=$(rk_runkey example-owner/project-a 010) || rc=$?
  assert_exit0 "$rc" "AC1: exit 0 for 010" || return 1
  case "$out" in example-owner_project-a-010|example-owner_project-a-10) ;; *) fail "AC1: leading zeros: got [$out]"; return 1 ;; esac
  out=$(rk_runkey example-owner/project-a 08) || rc=$?
  assert_exit0 "$rc" "AC1: exit 0 for 08 (no octal error)"
}

# ---------------------------------------------------------------- two runs coexist ---------------------------------

test_rk_two_runs_coexist_under_own_keys() {
  rk_env; rk_launch2
  local a="$RK_PIPE/orch-$RK_KA-100" b="$RK_PIPE/orch-$RK_KB-100" ok=0 n legacy ra rb
  rk_alive "$a.pid" && rk_alive "$b.pid" && ok=1
  n=$( . "$RK_SKILL/pipeline-lib.sh"; PIPE="$RK_PIPE" count_running )
  legacy=$(rk_legacy_names)
  ra=$(cat "$a.repo" 2>/dev/null); rb=$(cat "$b.repo" 2>/dev/null)
  rk_cleanup
  assert_eq "$ok" "1" "both pid files exist under their own key and both are alive" || return 1
  assert_eq "$ra" "$RK_REPO_A" "A's repo file is A's" || return 1
  assert_eq "$rb" "$RK_REPO_B" "B's repo file is B's" || return 1
  assert_eq "$n" "2" "count_running counts both (hand: 2 live pids)" || return 1
  assert_eq "$legacy" "" "AC2: new writes never create legacy names"
}

test_rk_stop_by_owner_repo_leaves_the_other_running() {
  rk_env; rk_launch2
  rk_orch stop "$RK_A#100" >/dev/null
  local a_alive=no b_alive=no ta=no tb=no
  rk_alive "$RK_PIPE/orch-$RK_KA-100.pid" && a_alive=yes; rk_alive "$RK_PIPE/orch-$RK_KB-100.pid" && b_alive=yes
  [ -e "$RK_PIPE/orch-$RK_KA-100.stopped" ] && ta=yes; [ -e "$RK_PIPE/orch-$RK_KB-100.stopped" ] && tb=yes
  rk_cleanup
  assert_eq "$a_alive" "no" "AC3: A stopped" || return 1
  assert_eq "$b_alive" "yes" "AC3: B untouched" || return 1
  assert_eq "$ta" "yes" "A tombstone under A's key" || return 1
  assert_eq "$tb" "no" "no tombstone for B" || return 1
}

test_rk_stop_bare_number_ambiguous_refuses_and_lists_candidates() {
  rk_env; rk_launch2
  local out rc; rk_orch_out stop 100; out=$RK_OUT; rc=$RK_RC
  local a_alive=no b_alive=no stopped
  rk_alive "$RK_PIPE/orch-$RK_KA-100.pid" && a_alive=yes; rk_alive "$RK_PIPE/orch-$RK_KB-100.pid" && b_alive=yes
  stopped=$(ls "$RK_PIPE"/orch-*.stopped 2>/dev/null | wc -l | tr -d ' ')
  rk_cleanup
  assert_ne "$rc" "0" "AC3: ambiguous bare number is refused (non-zero)" || return 1
  assert_contains "$out" "$RK_A" "AC3: lists candidate A" || return 1
  assert_contains "$out" "$RK_B" "AC3: lists candidate B" || return 1
  assert_eq "$a_alive$b_alive" "yesyes" "AC3: nothing stopped" || return 1
  assert_eq "$stopped" "0" "AC3: no tombstone written"
}

test_rk_stop_bare_number_single_match_resolves() {
  rk_env; rk_orch --force "$RK_REPO_A" 100 >/dev/null
  rk_orch stop 100 >/dev/null
  local alive=yes t=no
  rk_alive "$RK_PIPE/orch-$RK_KA-100.pid" || alive=no
  [ -e "$RK_PIPE/orch-$RK_KA-100.stopped" ] && t=yes
  rk_cleanup
  assert_eq "$alive" "no" "AC3: exactly one match → stopped" && assert_eq "$t" "yes" "AC3: tombstone under the key"
}

test_rk_stop_bare_number_no_match_refuses_without_tombstone() {
  rk_env; rk_orch --force "$RK_REPO_A" 100 >/dev/null
  local out rc n alive=no
  rk_orch_out stop 999; out=$RK_OUT; rc=$RK_RC
  n=$(ls "$RK_PIPE"/*999*.stopped 2>/dev/null | wc -l | tr -d ' ')
  rk_alive "$RK_PIPE/orch-$RK_KA-100.pid" && alive=yes
  rk_cleanup
  assert_ne "$rc" "0" "AC3: zero matches refused" && assert_eq "$n" "0" "no tombstone for an unknown run" && assert_eq "$alive" "yes" "A untouched"
}

test_rk_status_by_owner_repo_shows_only_that_run() {
  rk_env; rk_launch2
  local out; out=$(rk_orch status "$RK_A#100")
  rk_cleanup
  assert_contains "$out" "orch-$RK_KA-100.log" "AC3: A's run listed (log path under A's key)" || return 1
  assert_not_contains "$out" "orch-$RK_KB-100.log" "AC3: B's run filtered out"
}

test_rk_status_bare_number_ambiguous_lists_candidates() {
  rk_env; rk_launch2
  local out rc; rk_orch_out status 100; out=$RK_OUT; rc=$RK_RC
  rk_cleanup
  assert_ne "$rc" "0" "AC3: ambiguous bare number refused" || return 1
  assert_contains "$out" "$RK_A" "lists A" && assert_contains "$out" "$RK_B" "lists B"
}

# ---------------------------------------------------------------- tombstone survives other repo's launch ------------

test_rk_held_tombstone_survives_other_repo_same_number() {
  rk_env
  mk_held "$RK_PIPE" 703 "$RK_REPO_A"          # legacy A #703, held
  rk_orch --force "$RK_REPO_B" 703 >/dev/null  # B #703 launched on the same host
  rk_tick                                      # supervisor must neither restart A's held run nor drop its tombstone
  local held=no b=no a_run=no st
  { [ -e "$RK_PIPE/orch-703.held" ] || [ -e "$RK_PIPE/orch-$RK_KA-703.held" ]; } && held=yes
  [ -e "$RK_PIPE/orch-$RK_KB-703.pid" ] && b=yes
  rk_alive "$RK_PIPE/orch-$RK_KA-703.pid" && a_run=yes
  rk_alive "$RK_PIPE/orch-703.pid" && a_run=yes
  st=$(rk_orch status "$RK_A#703")
  rk_cleanup
  assert_eq "$held" "yes" "A's held tombstone survives" || return 1
  assert_eq "$a_run" "no" "A's held run is not auto-restarted" || return 1
  assert_contains "$st" "held" "status for A #703 still reports it held" || return 1
  assert_eq "$b" "yes" "B's run is keyed to B"
}

# ---------------------------------------------------------------- migration ----------------------------------------

test_rk_migration_renames_legacy_set_on_tick_and_later_launch_leaves_it() {
  rk_env
  mk_held "$RK_PIPE" 100 "$RK_REPO_A"; echo "log-line" > "$RK_PIPE/orch-100.log"
  rk_tick
  local k="$RK_PIPE/orch-$RK_KA-100" f missing="" left repo log still=yes
  for f in pid repo held log start; do [ -e "$k.$f" ] || missing="$missing $f"; done
  left=$(ls "$RK_PIPE"/orch-100.* 2>/dev/null | tr '\n' ' ')
  repo=$(cat "$k.repo" 2>/dev/null); log=$(cat "$k.log" 2>/dev/null)
  rk_orch --force "$RK_REPO_B" 100 >/dev/null
  { [ -e "$k.held" ] && [ -e "$k.repo" ]; } || still=no
  rk_cleanup
  assert_eq "$missing" "" "all files of the run moved to the new key" || return 1
  assert_eq "$left" "" "no legacy file left" || return 1
  assert_eq "$repo" "$RK_REPO_A" "content intact (.repo)" || return 1
  assert_eq "$log" "log-line" "content intact (.log)" || return 1
  assert_eq "$still" "yes" "a later B #100 launch does not touch the migrated set"
}

# legacy set: repo file missing -> never read or renamed for A (nothing under A's key, legacy stays)
test_rk_migration_negative_missing_repo_file() {
  rk_env
  mk_held "$RK_PIPE" 100 "$RK_REPO_A"; rm -f "$RK_PIPE/orch-100.repo"
  mk_held "$RK_PIPE" 101 "$RK_REPO_A"          # control: a well-formed legacy set that the same tick must migrate
  rk_tick
  local a legacy=no ctl=no
  a=$(ls "$RK_PIPE"/orch-$RK_KA-100.* 2>/dev/null | tr '\n' ' ')
  [ -e "$RK_PIPE/orch-100.held" ] && legacy=yes
  [ -e "$RK_PIPE/orch-$RK_KA-101.held" ] && ctl=yes
  rk_cleanup
  assert_eq "$ctl" "yes" "control: well-formed #101 set migrated on the same tick" || return 1
  assert_eq "$a" "" "no scheduler-keyed file appears" && assert_eq "$legacy" "yes" "legacy set left untouched"
}

# legacy set naming B: must not become A's (it may legitimately migrate to B's key)
test_rk_migration_negative_repo_file_names_other_repo() {
  rk_env
  mk_held "$RK_PIPE" 100 "$RK_REPO_B"
  rk_tick
  local a out b=no
  a=$(ls "$RK_PIPE"/orch-$RK_KA-100.* 2>/dev/null | tr '\n' ' ')
  [ -e "$RK_PIPE/orch-$RK_KB-100.held" ] && b=yes
  out=$(rk_orch status "$RK_A#100")
  rk_cleanup
  assert_eq "$b" "yes" "B's own legacy set migrates to B's key" || return 1
  assert_eq "$a" "" "no scheduler-keyed file appears" || return 1
  assert_not_contains "$out" "repo=$RK_REPO_B" "status for A #100 does not read B's legacy set (no B run line)" || return 1
  assert_not_contains "$out" "#100  " "status for A #100 shows no #100 run line at all"
}


# ---------------------------------------------------------------- read-both fallback (pre-migration) ---------------

# Legacy orch-100.* whose .repo names A, BEFORE any supervisor tick: A-scoped readers must still see and act on it.
test_rk_legacy_fallback_status_and_stop_read_matching_legacy_set() {
  rk_env
  mk_running "$RK_PIPE" 100 "$RK_REPO_A"
  local out stopped=no alive=yes pid; pid=$(cat "$RK_PIPE/orch-100.pid")
  out=$(rk_orch status "$RK_A#100")
  rk_orch stop "$RK_A#100" >/dev/null
  local i; for i in $(seq 1 30); do rk_pid_alive "$pid" || break; sleep 0.1; done
  rk_pid_alive "$pid" || alive=no
  { [ -e "$RK_PIPE/orch-100.stopped" ] || [ -e "$RK_PIPE/orch-$RK_KA-100.stopped" ]; } && stopped=yes
  cleanup_running; rk_cleanup
  assert_contains "$out" "running (pid $pid)" "fallback: status for A #100 reads the legacy set whose .repo is A" || return 1
  assert_eq "$alive" "no" "fallback: stop A#100 stops the legacy-named run" || return 1
  assert_eq "$stopped" "yes" "fallback: tombstone written"
}

# The same legacy set must NOT be visible to B #100 (repo file names A).
test_rk_legacy_fallback_not_read_for_other_repo() {
  rk_env
  mk_running "$RK_PIPE" 100 "$RK_REPO_A"
  local out alive=no
  local ctl pid; pid=$(cat "$RK_PIPE/orch-100.pid")
  ctl=$(rk_orch status "$RK_A#100")             # positive control: the same set IS visible to A
  out=$(rk_orch status "$RK_B#100")
  rk_orch stop "$RK_B#100" >/dev/null
  rk_alive "$RK_PIPE/orch-100.pid" && alive=yes
  cleanup_running; rk_cleanup
  assert_contains "$ctl" "running (pid $pid)" "control: A #100 sees its own legacy set" || return 1
  assert_not_contains "$out" "running (pid" "B #100 query does not read A's legacy set" || return 1
  assert_eq "$alive" "yes" "stop B#100 does not stop A's legacy run"
}

# ---------------------------------------------------------------- status page payload -------------------------------

# Two same-numbered runs from different repos both appear in the payload, each with its own repo alias and state.
test_rk_status_payload_two_same_number_runs() {
  rk_env; rk_launch2
  local pa pb
  pa=$(cat "$RK_PIPE/orch-$RK_KA-100.pid" 2>/dev/null); pb=$(cat "$RK_PIPE/orch-$RK_KB-100.pid" 2>/dev/null)
  if [ -z "$pa" ] || [ -z "$pb" ]; then rk_cleanup; fail "both runs must have pid files under their own keys"; return 1; fi
  kill "$pb" 2>/dev/null; pkill -TERM -P "$pb" 2>/dev/null
  local i; for i in $(seq 1 50); do kill -0 "$pb" 2>/dev/null || break; sleep 0.1; done   # B's process dies, then it is held
  touch "$RK_PIPE/orch-$RK_KB-100.held"
  printf 'STATUS_REPO_ALIASES=("%s:alias-a" "%s:alias-b")\n' "$RK_A" "$RK_B" >> "$RK_HOME/.claude/pipeline/config.local.sh"
  local out sa sb n
  # rk_tree_init stubs report-status.sh to a no-op; run the shipped script under a side name (same dir, same relative sourcing).
  cp "$RK_SKILL/report-status.sh" "$RK_TREE/skills/orchestrate/report-status-real.sh"
  out=$( cd "$RK_HOME" && env HOME="$RK_HOME" PATH="$RK_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" LOGDIR="$RK_HOME/logs/pipeline" \
      bash "$RK_TREE/skills/orchestrate/report-status-real.sh" --print 2>/dev/null )
  n=$(printf '%s' "$out" | jq '[.runs[] | select(.issue==100)] | length' 2>/dev/null)
  sa=$(printf '%s' "$out" | jq -r '[.runs[] | select(.issue==100 and .repo=="alias-a")][0].state' 2>/dev/null)
  sb=$(printf '%s' "$out" | jq -r '[.runs[] | select(.issue==100 and .repo=="alias-b")][0].state' 2>/dev/null)
  rk_cleanup
  assert_eq "$n" "2" "both #100 runs are in runs[] (hand: 2 distinct repos)" || return 1
  assert_eq "$sa" "running" "A's #100 is running" || return 1
  assert_eq "$sb" "held" "B's #100 is held (its own state, not A's)"
}

# ---------------------------------------------------------------- AC2: full cycle leaves no legacy names ------------

test_rk_full_cycle_creates_no_legacy_names() {
  rk_env 1                                     # one slot: B queues, then drains when A stops
  rk_orch --force "$RK_REPO_A" 100 >/dev/null
  rk_orch --force "$RK_REPO_B" 100 >/dev/null  # queued
  rk_tick                                      # supervisor adopts / restarts / reconciles
  rk_orch stop "$RK_A#100" >/dev/null
  rk_tick                                      # drain
  rk_orch stop "$RK_B#100" >/dev/null
  rk_tick
  local legacy keyed
  legacy=$(rk_legacy_names); keyed=$(ls "$RK_PIPE"/orch-$RK_KA-100.* "$RK_PIPE"/orch-$RK_KB-100.* 2>/dev/null | wc -l | tr -d ' ')
  rk_cleanup
  assert_ne "$keyed" "0" "the cycle really ran and wrote keyed files" && assert_eq "$legacy" "" "no orch-<N>.* / <N>-<agent>-before|nags.txt file in PIPE"
}

# ---------------------------------------------------------------- read side: reconcile ------------------------------

test_rk_reconcile_reads_new_keys_per_repo() {
  rk_env; rk_launch2
  echo CLOSED > "$RK_BIN/gh-state-$(printf '%s' "$RK_A" | tr / _)"   # only A's #100 is closed on GitHub
  ( cd "$RK_HOME" && env HOME="$RK_HOME" PATH="$RK_BIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" LOGDIR="$RK_HOME/logs/pipeline" \
      bash "$RK_TREE/skills/orchestrate/reconcile-status.sh" --force ) >/dev/null 2>&1
  local ca=no cb=no legacy
  [ -e "$RK_PIPE/orch-$RK_KA-100.closed" ] && ca=yes; [ -e "$RK_PIPE/orch-$RK_KB-100.closed" ] && cb=yes
  legacy=$(rk_legacy_names)
  rk_cleanup
  assert_eq "$ca" "yes" "A's closed marker under A's key" && assert_eq "$cb" "no" "B (open) not closed by A's state" && assert_eq "$legacy" "" "no legacy names written"
}

# ---------------------------------------------------------------- stage hook ----------------------------------------

# own fake gh for the hook: one page per repo (<owner>_<repo>.json), chosen from the api path
rk_hook_setup() {
  RK_HD=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-rkhook.XXXXXX"); mkdir -p "$RK_HD/bin" "$RK_HD/pipe" "$RK_HD/pages"
  cat > "$RK_HD/bin/gh" <<RKHGH
#!/bin/bash
D="$RK_HD"
[ "\$1" = "api" ] || exit 1
slug=\$(printf '%s' "\$2" | sed -e 's#^repos/##' -e 's#/issues/.*##' | tr / _)
expr=""; while [ \$# -gt 0 ]; do case "\$1" in --jq) expr=\$2; shift ;; esac; shift; done
jq -r "\$expr" "\$D/pages/\$slug.json"
RKHGH
  chmod +x "$RK_HD/bin/gh"
  echo '[{"created_at":"2026-09-20T23:30:00Z","user":{"login":"x"},"body":"**[deployer] DEPLOYED**\nPR #1 merged"}]' > "$RK_HD/pages/${RK_KA}.json"
  echo '[]' > "$RK_HD/pages/${RK_KB}.json"
  echo 0 > "$RK_HD/pipe/$RK_KA-600-deployer-before.txt"; echo 0 > "$RK_HD/pipe/$RK_KB-600-deployer-before.txt"
}
rk_hook() {  # rk_hook <owner/repo> -> RK_HRC
  PATH="$RK_HD/bin:$PATH" PIPE="$RK_HD/pipe" PIPELINE_ISSUE=600 PIPELINE_AGENT=deployer PIPELINE_REPO="$1" \
    bash "$RK_ROOT/hooks/require-handoff-marker.sh" </dev/null >/dev/null 2>&1; RK_HRC=$?
}

test_rk_hook_same_issue_different_repo_uses_different_files() {
  rk_hook_setup
  local ra rb na nb nbv na_exists=no legacy
  rk_hook "$RK_A"; ra=$RK_HRC
  rk_hook "$RK_B"; rb=$RK_HRC
  na="$RK_HD/pipe/$RK_KA-600-deployer-nags.txt"; nb="$RK_HD/pipe/$RK_KB-600-deployer-nags.txt"
  nbv=$(cat "$nb" 2>/dev/null); [ -e "$na" ] && na_exists=yes
  legacy=$(ls "$RK_HD"/pipe/600-* 2>/dev/null)
  rm -rf "$RK_HD"
  assert_eq "$ra" "0" "A has its handoff (1 > 0) → released" || return 1
  assert_eq "$rb" "2" "B has none: A's handoff must not release B" || return 1
  assert_eq "$nbv" "1" "B's nag file keyed by B (hand: first refusal = 1)" || return 1
  assert_eq "$na_exists" "no" "A's nag file not created (released)" || return 1
  assert_eq "$legacy" "" "no <N>-<agent>-* legacy file"
}

# Preservation guard (green by design on base): the hook stays inert when PIPELINE_REPO is unset.
test_rk_hook_inert_without_pipeline_repo() {
  rk_hook_setup
  local rc
  ( unset PIPELINE_REPO; PATH="$RK_HD/bin:$PATH" PIPE="$RK_HD/pipe" PIPELINE_ISSUE=600 PIPELINE_AGENT=deployer \
      bash "$RK_ROOT/hooks/require-handoff-marker.sh" </dev/null >/dev/null 2>&1 ); rc=$?
  rm -rf "$RK_HD"
  assert_eq "$rc" "0" "PIPELINE_REPO unset → exit 0"
}

# ---------------------------------------------------------------- stage files / docs (static pins) ------------------

test_rk_stage_run_and_run_state_use_run_key() {
  local sr="$RK_SKILL/stage-run.sh" rs="$RK_SKILL/run-state.sh" n
  n=$(grep -c 'PIPE/\$ISSUE-\$AGENT-before.txt' "$sr"); assert_eq "$n" "0" "stage-run.sh: no <N>-<agent>-before.txt" || return 1
  grep -q 'run_key' "$sr" || { fail "stage-run.sh must use run_key"; return 1; }
  n=$(grep -c 'run-"\$issue"-\*\|run-\$issue-\*' "$rs"); assert_eq "$n" "0" "run-state.sh: no run-<N>-* glob" || return 1
  grep -q 'run_key' "$rs" || { fail "run-state.sh must use run_key"; return 1; }
}

test_rk_orchestrator_md_snippets_use_run_key() {
  local md="$RK_ROOT/agents/orchestrator.md" n
  n=$(grep -c 'locked-<issue>.txt' "$md"); assert_eq "$n" "0" "no locked-<issue>.txt" || return 1
  n=$(grep -c '/tmp/pipeline/<N>-' "$md"); assert_eq "$n" "0" "no /tmp/pipeline/<N>-<agent>-before|nags.txt" || return 1
  grep -q 'locked-<run_key>.txt' "$md" || { fail "locked-<run_key>.txt missing"; return 1; }
  grep -q '<run_key>-<agent-name>-before.txt' "$md" || { fail "<run_key>-<agent-name>-before.txt missing"; return 1; }
  grep -q 'run-<run_key>-<agent>.log' "$md" || { fail "run-<run_key>-<agent>.log missing"; return 1; }
}

# ---------------------------------------------------------------- AC6: error row -----------------------------------

# A legacy set whose new-key files already exist cannot be renamed atomically: leave both untouched and record an
# error row (event=error, release = checkout SHA, host, route; no tokens) in events.jsonl.
test_rk_ac6_migration_conflict_writes_error_row() {
  rk_env
  mk_held "$RK_PIPE" 100 "$RK_REPO_A"
  echo conflict > "$RK_PIPE/orch-$RK_KA-100.repo"
  rk_tick
  local ev="$RK_HOME/logs/pipeline/events.jsonl" head n bad rel host route legacy=no
  head=$(git -C "$RK_TREE" rev-parse HEAD)
  n=$(jq -s '[.[] | select(.event=="error")] | length' "$ev" 2>/dev/null || echo 0)
  rel=$(jq -rs '[.[] | select(.event=="error")][0].release // ""' "$ev" 2>/dev/null)
  host=$(jq -rs '[.[] | select(.event=="error")][0].host // ""' "$ev" 2>/dev/null)
  route=$(jq -rs '[.[] | select(.event=="error")][0].route // ""' "$ev" 2>/dev/null)
  bad=$(grep -c 'SENTINEL' "$ev" 2>/dev/null); [ -e "$RK_PIPE/orch-100.held" ] && legacy=yes
  rk_cleanup
  assert_eq "$n" "1" "exactly one error row" || return 1
  if [ "${#rel}" -lt 7 ]; then fail "release [$rel] shorter than 7 chars"; return 1; fi
  case "$head" in "$rel"*) ;; *) fail "release [$rel] is not a prefix of HEAD [$head]"; return 1 ;; esac
  assert_ne "$host" "" "host tag" || return 1
  assert_ne "$route" "" "route tag" || return 1
  assert_eq "$bad" "0" "no token in the event" || return 1
  assert_eq "$legacy" "yes" "conflicting legacy set left untouched"
}

run_test test_rk_ac1_run_key_slash_becomes_underscore
run_test test_rk_ac1_run_key_keeps_dots_in_repo_name
run_test test_rk_ac1_run_key_leading_zeros_not_octal
run_test test_rk_two_runs_coexist_under_own_keys
run_test test_rk_stop_by_owner_repo_leaves_the_other_running
run_test test_rk_stop_bare_number_ambiguous_refuses_and_lists_candidates
run_test test_rk_stop_bare_number_single_match_resolves
run_test test_rk_stop_bare_number_no_match_refuses_without_tombstone
run_test test_rk_status_by_owner_repo_shows_only_that_run
run_test test_rk_status_bare_number_ambiguous_lists_candidates
run_test test_rk_held_tombstone_survives_other_repo_same_number
run_test test_rk_migration_renames_legacy_set_on_tick_and_later_launch_leaves_it
run_test test_rk_migration_negative_missing_repo_file
run_test test_rk_migration_negative_repo_file_names_other_repo
run_test test_rk_legacy_fallback_status_and_stop_read_matching_legacy_set
run_test test_rk_legacy_fallback_not_read_for_other_repo
run_test test_rk_status_payload_two_same_number_runs
run_test test_rk_full_cycle_creates_no_legacy_names
run_test test_rk_reconcile_reads_new_keys_per_repo
run_test test_rk_hook_same_issue_different_repo_uses_different_files
run_test test_rk_hook_inert_without_pipeline_repo
run_test test_rk_stage_run_and_run_state_use_run_key
run_test test_rk_orchestrator_md_snippets_use_run_key
run_test test_rk_ac6_migration_conflict_writes_error_row
