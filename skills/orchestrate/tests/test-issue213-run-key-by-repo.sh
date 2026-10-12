# Issue #213 — per-run state keyed by repo + issue number (run_key), so two repos holding the same issue
# number on one host never overwrite each other's pid / .repo / .held / queue entry.
#
# Key format (ticket, "Decisions"): run_key <owner/repo> <N> prints orch-<owner>_<repo>-<N> ("/" -> "_").
# Every fixture name below is therefore written out literally, e.g. orch-project-a_repo-a-196 — expected values
# are the ticket's, never produced by calling run_key (except the one test that checks run_key itself).
#
#   AC1  run_key exists once; no per-run path built from a bare number (ticket's grep)
#   AC2  hand-launch of #196 (launch AND queued path) leaves the other repo's #196 files untouched
#   AC3  supervisor drain + dispatch treat the same number of two repos as independent
#   AC4  stop <owner/repo> <N> kills only that run; one-argument stop/tail exit 2
#   AC5  derive_runs / reconcile-status.sh / build-runs-json.py: two rows for two repos with one number
#   AC6  the live stage of a run is the process whose PIPELINE_REPO *and* PIPELINE_ISSUE both match
#   AC7  migration (install.sh): unresolvable files stay, listed, exit 0, idempotent
#   AC8  cutover: no ^orch-[0-9]+\. file remains; a supervisor tick sees the live run and queued entry
#   AC9  status golden: only the log= path field changes (key-named fixture vs the checked-in golden)
#   AC10 README.md / SKILL.md updated
#   AC13 observability: migration + launch failures are `error` rows in events.jsonl and a Slack post
#
# Contract choices the ticket leaves open (defined here, the implementation must honour them):
#   * RS_PS_CMD process lines gain an additive 4th TAB column = the process's PIPELINE_REPO (owner/repo):
#       <start_epoch> TAB <PIPELINE_ISSUE> TAB <command line> TAB <PIPELINE_REPO>
#   * the cutover step honours $PIPE and $QUEUE from the environment (install.sh sources config.sh).
#   * a migration/launch failure row: event=error, route=run-key-migration|launch, release=<checkout commit SHA>.
#
# Isolated HOME + PIPE + QUEUE + LOGDIR per case; a cwd-aware fake gh (origin of the cwd decides owner/repo);
# stub claude / pmset / crontab / curl first on PATH. Placeholder repo names only (project-a/b/c). All names rk_/RK_.

HERE_RK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_RK="$HERE_RK/.."
ROOT_RK=$(cd "$HERE_RK/../../.." && pwd)
ORCH_RK="$RS_RK/orchestrate.sh"
SUP_RK="$RS_RK/supervisor.sh"
LIB_RK="$RS_RK/pipeline-lib.sh"
FAKEBIN_RK="$HERE_RK/bin"
RK_PIDS=""

# ------------------------------------------------------------------------------------------ harness

rk_mk_gh() {  # rk_mk_gh <dir> — cwd-aware fake gh
  local d=$1
  mkdir -p "$d"
  cat > "$d/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$PWD :: $*" >> "$HERE/gh-calls.log"
expr=""; prev=""
for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
emit() { if [ -n "$expr" ]; then printf '%s' "$1" | jq -r "$expr"; else printf '%s\n' "$1"; fi; }
origin() {
  local url
  url=$(git config --get remote.origin.url 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  url=${url%.git}; url=${url#https://github.com/}
  printf '%s' "$url"
}
case "$*" in
  "repo view"*)
    [ -f "$HERE/repo-view-fail" ] && exit 1
    o=$(origin) || exit 1
    emit "{\"nameWithOwner\":\"$o\"}" ;;
  "issue view"*)
    f="$HERE/view-$(basename "$PWD").json"
    if [ -f "$f" ]; then json=$(cat "$f")
    else json='{"state":"OPEN","title":"Fixture","labels":[],"comments":[],"milestone":null,"closedAt":null,"updatedAt":"2026-01-01T00:00:00Z"}'; fi
    emit "$json" ;;
  "issue list"*)
    repo=""; prev=""
    for a in "$@"; do [ "$prev" = "--repo" ] && repo=$a; prev=$a; done
    key=$(printf '%s' "$repo" | tr '/' '_')
    if [ -n "$expr" ] && [ -f "$HERE/approved-$key" ]; then cat "$HERE/approved-$key"; else emit '[]'; fi ;;
  *) exit 0 ;;
esac
GH_EOF
  chmod +x "$d/gh"
  : > "$d/gh-calls.log"
}

# rk_env — RK_PIPE RK_HOME RK_GH RK_A RK_B RK_C (checkouts: project-a/repo-a, project-b/repo-b, project-c/repo-c)
rk_env() {
  RK_PIPE=$(new_pipe); RK_HOME=$(new_home)
  RK_GH="$RK_HOME/.local/bin"; mkdir -p "$RK_GH"
  RK_A="$RK_PIPE/repo-a"; RK_B="$RK_PIPE/repo-b"; RK_C="$RK_PIPE/repo-c"
  fixture_repo "$RK_A" "project-a/repo-a"
  fixture_repo "$RK_B" "project-b/repo-b"
  fixture_repo "$RK_C" "project-c/repo-c"
  rk_mk_gh "$RK_GH"
  printf '#!/bin/bash\necho "$*" >> "$(dirname "$0")/launches"\nexit 0\n' > "$RK_GH/claude"
  printf '#!/bin/bash\necho "Now drawing from '"'"'AC Power'"'"'"\n' > "$RK_GH/pmset"
  chmod +x "$RK_GH/claude" "$RK_GH/pmset"
  RK_LOG="$RK_HOME/logs/pipeline"
  printf 'MEM_FLOOR_MB=0\nCLAIM_SETTLE_SECS=0\n' > "$RK_HOME/.claude/pipeline/config.local.sh"
}

rk_cleanup() {
  local p
  for p in $RK_PIDS; do kill "$p" 2>/dev/null; done
  RK_PIDS=""
  rm -rf "$RK_PIPE" "$RK_HOME" 2>/dev/null || { sleep 0.5; rm -rf "$RK_PIPE" "$RK_HOME" 2>/dev/null; }
}

rk_run() {  # rk_run <script> [args...] — script under test in the isolated env
  HOME="$RK_HOME" PATH="$RK_GH:/usr/bin:/bin" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" LOGDIR="$RK_LOG" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$@"
}
rk_tick() { rk_run "$SUP_RK" >/dev/null 2>&1; }

rk_conf() { printf '%s\n' "$1" >> "$RK_HOME/.claude/pipeline/config.local.sh"; }

rk_live() {  # rk_live <key> <repo_path> — a running run (live pid)
  local key=$1 repo=$2
  sleep 300 &
  local pid=$!
  RK_PIDS="$RK_PIDS $pid"
  echo "$pid" > "$RK_PIPE/$key.pid"
  echo "$repo" > "$RK_PIPE/$key.repo"
  date -u +%FT%TZ > "$RK_PIPE/$key.start"
  date -u +%FT%TZ > "$RK_PIPE/$key.launched-at"
  : > "$RK_PIPE/$key.log"
}

rk_dead() {  # rk_dead <key> <repo_path> [tombstone-suffix] — dead pid, optional .held/.done/.stopped
  local key=$1 repo=$2 tomb=${3:-} p=99999
  while kill -0 "$p" 2>/dev/null; do p=$((p - 1)); done
  echo "$p" > "$RK_PIPE/$key.pid"
  echo "$repo" > "$RK_PIPE/$key.repo"
  date -u +%FT%TZ > "$RK_PIPE/$key.start"
  : > "$RK_PIPE/$key.log"
  [ -z "$tomb" ] || touch "$RK_PIPE/$key.$tomb"
}

rk_queue() {  # rk_queue <key> <issue> <repo_path> <queued_at ISO> <not_before epoch>
  python3 -c "
import json, sys
json.dump({'issue': sys.argv[2], 'repo': sys.argv[3], 'extra': '', 'reason': 'queued',
           'queued_at': sys.argv[4], 'not_before': int(sys.argv[5])}, open(sys.argv[6], 'w'))
" "$1" "$2" "$3" "$4" "$5" "$RK_PIPE/queue/$1.json"
}

rk_snap() {  # rk_snap <key> — name + content of every file of that run
  ( cd "$RK_PIPE" && for f in $1.* queue/$1.json; do [ -e "$f" ] || continue; printf '== %s\n' "$f"; cat "$f"; done )
}

rk_old_names() {  # any per-run file still named by a bare number (^orch-[0-9]+\.), pipe + queue
  ( cd "$RK_PIPE" && ls -1 . queue 2>/dev/null | grep -E '^orch-[0-9]+\.' ) || true
}

rk_present() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
rk_alive() { if kill -0 "$1" 2>/dev/null; then echo alive; else echo dead; fi; }
rk_wait_dead() { local i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 40 ]; do sleep 0.1; i=$((i + 1)); done; }
rk_iso_ago() { python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
rk_jq() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# ------------------------------------------------------------------------------------------ AC1

test_rk_ac1_run_key_is_repo_scoped_and_hyphen_safe() {
  # hand-written expectations: "/" -> "_", then "-<N>"; hyphenated names stay intact.
  local out1 out2
  out1=$(bash -c ". '$LIB_RK'; run_key project-a/repo-a 196" 2>/dev/null)
  out2=$(bash -c ". '$LIB_RK'; run_key project-b/repo-b 7" 2>/dev/null)
  assert_eq "$out1" "orch-project-a_repo-a-196" "#213/AC1: run_key project-a/repo-a 196" || return 1
  assert_eq "$out2" "orch-project-b_repo-b-7" "#213/AC1: run_key project-b/repo-b 7" || return 1
  # defined exactly once, in pipeline-lib.sh
  local defs files
  defs=$(cd "$RS_RK" && grep -nE '^[[:space:]]*(function[[:space:]]+)?run_key[[:space:]]*\(\)' *.sh | wc -l | tr -d ' ')
  files=$(cd "$RS_RK" && grep -lE '^[[:space:]]*(function[[:space:]]+)?run_key[[:space:]]*\(\)' *.sh | tr '\n' ' ')
  assert_eq "$defs" "1" "#213/AC1: exactly one run_key definition" || return 1
  assert_eq "$files" "pipeline-lib.sh " "#213/AC1: defined in pipeline-lib.sh only" || return 1
}

test_rk_ac1_no_per_run_path_built_from_a_bare_number() {
  local hits
  hits=$(cd "$RS_RK" && grep -rnE 'orch-\$\{?(ISSUE|issue|num|n|q_issue|best_issue|[12])\}?[.\"]' *.sh *.py 2>/dev/null || true)
  assert_eq "$hits" "" "#213/AC1: ticket's grep must find no number-only per-run file path" || return 1
}

# ------------------------------------------------------------------------------------------ AC2

test_rk_ac2_handlaunch_leaves_other_repos_196_untouched() {
  rk_env
  local KB=orch-project-b_repo-b-196 KA=orch-project-a_repo-a-196
  rk_live "$KB" "$RK_B"; touch "$RK_PIPE/$KB.held"; echo "quoting title" > "$RK_PIPE/$KB.title"
  rk_queue "$KB" 196 "$RK_B" 2026-01-01T00:00:00Z 0
  local before after out rc old a_pid a_repo b_pid runid
  before=$(rk_snap "$KB")
  out=$(rk_run "$ORCH_RK" "$RK_A" 196 2>&1); rc=$?
  after=$(rk_snap "$KB")
  old=$(rk_old_names)
  a_pid=$(rk_present "$RK_PIPE/$KA.pid"); a_repo=$(cat "$RK_PIPE/$KA.repo" 2>/dev/null)
  b_pid=$(cat "$RK_PIPE/$KB.pid" 2>/dev/null); runid=$(cat "$RK_PIPE/$KA.run-id" 2>/dev/null)
  local a_pidval; a_pidval=$(cat "$RK_PIPE/$KA.pid" 2>/dev/null)
  rk_cleanup
  assert_exit0 "$rc" "#213/AC2: hand-launch exits 0 (out: $out)" || return 1
  assert_eq "$a_pid" "present" "#213/AC2: claude-agents run has its own $KA.pid" || return 1
  assert_eq "$a_repo" "$RK_A" "#213/AC2: own .repo holds its own checkout" || return 1
  assert_ne "$a_pidval" "$b_pid" "#213/AC2: the two runs have distinct pid files" || return 1
  assert_eq "$after" "$before" "#213/AC2: every file of the quoting run is byte-identical" || return 1
  assert_eq "$old" "" "#213/AC2: no number-only orch-<N>.* file is created" || return 1
  assert_contains "$runid" "$KA" "#213/AC13-decision: run_id embeds the run_key" || return 1
}

test_rk_ac2_queued_handlaunch_leaves_other_repos_queue_entry() {
  rk_env
  rk_conf "MAX_CONCURRENT=0"
  local KB=orch-project-b_repo-b-196 KA=orch-project-a_repo-a-196
  rk_dead "$KB" "$RK_B"            # a restarting quoting run waiting for its queue entry
  rk_queue "$KB" 196 "$RK_B" 2026-01-01T00:00:00Z 0
  local before after out rc old qa_issue qa_repo
  before=$(rk_snap "$KB")
  out=$(rk_run "$ORCH_RK" "$RK_A" 196 2>&1); rc=$?
  after=$(rk_snap "$KB")
  old=$(rk_old_names)
  qa_issue=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['issue'])" "$RK_PIPE/queue/$KA.json" 2>/dev/null)
  qa_repo=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['repo'])" "$RK_PIPE/queue/$KA.json" 2>/dev/null)
  rk_cleanup
  assert_exit0 "$rc" "#213/AC2: queued hand-launch exits 0 (out: $out)" || return 1
  assert_eq "$qa_issue" "196" "#213/AC2: own queue entry queue/$KA.json written" || return 1
  assert_eq "$qa_repo" "$RK_A" "#213/AC2: own queue entry names its own checkout" || return 1
  assert_eq "$after" "$before" "#213/AC2: quoting's queue entry and files untouched by the queued launch" || return 1
  assert_eq "$old" "" "#213/AC2: no number-only file or queue entry is created" || return 1
}

# ------------------------------------------------------------------------------------------ AC3

# rk_drain_case <state of the other repo's #196: held|done|stopped|running> <repo whose entry is queued: a|b>
rk_drain_case() {
  local other_state=$1 q=$2 KA=orch-project-a_repo-a-196 KB=orch-project-b_repo-b-196 KQ KO RQ RO
  if [ "$q" = a ]; then KQ=$KA; KO=$KB; else KQ=$KB; KO=$KA; fi
  rk_env
  if [ "$q" = a ]; then RQ=$RK_A; RO=$RK_B; else RQ=$RK_B; RO=$RK_A; fi
  if [ "$other_state" = running ]; then rk_live "$KO" "$RO"; else rk_dead "$KO" "$RO" "$other_state"; fi
  rk_queue "$KQ" 196 "$RQ" "$(rk_iso_ago 120)" 0
  local o_pid_before o_pid_after o_repo o_tomb
  o_pid_before=$(cat "$RK_PIPE/$KO.pid")
  rk_tick
  o_pid_after=$(cat "$RK_PIPE/$KO.pid" 2>/dev/null)
  o_repo=$(cat "$RK_PIPE/$KO.repo" 2>/dev/null)
  o_tomb=present; [ "$other_state" = running ] || o_tomb=$(rk_present "$RK_PIPE/$KO.$other_state")
  local launched queue_left old o_alive
  launched=$(rk_present "$RK_PIPE/$KQ.pid"); queue_left=$(rk_present "$RK_PIPE/queue/$KQ.json")
  old=$(rk_old_names); o_alive=$(rk_alive "$o_pid_before")
  rk_cleanup
  assert_eq "$launched" "present" "#213/AC3[$other_state]: the other repo's #196 does not skip/purge this queue entry — it launched ($KQ.pid)" || return 1
  assert_eq "$queue_left" "absent" "#213/AC3[$other_state]: queue entry consumed by the launch" || return 1
  assert_eq "$o_pid_after" "$o_pid_before" "#213/AC3[$other_state]: the other run's pid file untouched" || return 1
  assert_eq "$o_repo" "$RO" "#213/AC3[$other_state]: the other run's .repo untouched" || return 1
  assert_eq "$o_tomb" "present" "#213/AC3[$other_state]: the other run's .$other_state state survives" || return 1
  [ "$other_state" != running ] || assert_eq "$o_alive" "alive" "#213/AC3: the other repo's live run is still alive" || return 1
  assert_eq "$old" "" "#213/AC3[$other_state]: no number-only file created by the supervisor" || return 1
}
test_rk_ac3_drain_ignores_other_repos_held()    { rk_drain_case held a; }
test_rk_ac3_drain_ignores_other_repos_done()    { rk_drain_case done a; }
test_rk_ac3_drain_ignores_other_repos_stopped() { rk_drain_case stopped a; }
test_rk_ac3_drain_ignores_other_repos_running() { rk_drain_case running a; }
test_rk_ac3_drain_mirror_b_queued_a_held()      { rk_drain_case held b; }

# rk_dispatch_case <state of project-c/repo-c #703: held|running|queued> — project-b/repo-b #703 is agent-go
rk_dispatch_case() {
  local state=$1 KC=orch-project-c_repo-c-703 KB=orch-project-b_repo-b-703
  rk_env
  rk_conf "DISPATCH_REPOS=(\"project-b/repo-b:$RK_B\")"
  echo 703 > "$RK_GH/approved-project-b_repo-b"        # already-filtered --jq output of `gh issue list`
  jq -n --arg b "**[supervisor] NOTE** claim: $(hostname -s) $(rk_iso_ago 0)" --arg t "$(rk_iso_ago 0)" \
    '{state:"OPEN",labels:[],comments:[{body:$b,createdAt:$t}],milestone:null,closedAt:null,updatedAt:$t}' > "$RK_GH/view-repo-b.json"
  case "$state" in
    held)    rk_dead "$KC" "$RK_C" held ;;
    running) rk_live "$KC" "$RK_C" ;;
    queued)  rk_queue "$KC" 703 "$RK_C" 2026-01-01T00:00:00Z "$(( $(date +%s) + 99999 ))" ;;
  esac
  local c_before c_pid_after
  c_before=$(cat "$RK_PIPE/$KC.pid" 2>/dev/null)
  rk_tick
  local b_pid b_repo c_state c_old
  b_pid=$(rk_present "$RK_PIPE/$KB.pid"); b_repo=$(cat "$RK_PIPE/$KB.repo" 2>/dev/null)
  case "$state" in
    held)    c_state=$(rk_present "$RK_PIPE/$KC.held") ;;
    running) c_state=$(rk_alive "$c_before") ;;
    queued)  c_state=$(rk_present "$RK_PIPE/queue/$KC.json") ;;
  esac
  c_pid_after=$(cat "$RK_PIPE/$KC.pid" 2>/dev/null)
  c_old=$(rk_old_names)
  rk_cleanup
  assert_eq "$b_pid" "present" "#213/AC3[$state]: the agent-go #703 of project-b is dispatched ($KB.pid) despite project-c's #703" || return 1
  assert_eq "$b_repo" "$RK_B" "#213/AC3[$state]: dispatched run records its own checkout" || return 1
  case "$state" in
    held|queued) assert_eq "$c_state" "present" "#213/AC3[$state]: project-c's $state state survives the project-b dispatch" || return 1 ;;
    running)     assert_eq "$c_state" "alive" "#213/AC3: project-c's live #703 run is not disturbed" || return 1 ;;
  esac
  assert_eq "$c_pid_after" "$c_before" "#213/AC3[$state]: project-c's pid file untouched" || return 1
  assert_eq "$c_old" "" "#213/AC3[$state]: no number-only file created by dispatch" || return 1
}
test_rk_ac3_dispatch_keeps_other_repos_held_703()    { rk_dispatch_case held; }
test_rk_ac3_dispatch_not_blocked_by_other_repos_running_703() { rk_dispatch_case running; }
test_rk_ac3_dispatch_not_blocked_by_other_repos_queued_703()  { rk_dispatch_case queued; }

# ------------------------------------------------------------------------------------------ AC4

test_rk_ac4_stop_with_repo_kills_only_that_run() {
  rk_env
  local KA=orch-project-a_repo-a-198 KB=orch-project-b_repo-b-198
  rk_live "$KA" "$RK_A"; rk_live "$KB" "$RK_B"
  rk_queue "$KB" 198 "$RK_B" 2026-01-01T00:00:00Z 0
  local pa pb out rc
  pa=$(cat "$RK_PIPE/$KA.pid"); pb=$(cat "$RK_PIPE/$KB.pid")
  out=$(rk_run "$ORCH_RK" stop project-a/repo-a 198 2>&1); rc=$?
  rk_wait_dead "$pa"
  local a_alive b_alive a_tomb b_tomb b_queue old
  a_alive=$(rk_alive "$pa"); b_alive=$(rk_alive "$pb")
  a_tomb=$(rk_present "$RK_PIPE/$KA.stopped"); b_tomb=$(rk_present "$RK_PIPE/$KB.stopped")
  b_queue=$(rk_present "$RK_PIPE/queue/$KB.json"); old=$(rk_old_names)
  rk_cleanup
  assert_exit0 "$rc" "#213/AC4: stop <owner/repo> <N> exits 0 (out: $out)" || return 1
  assert_eq "$a_alive" "dead" "#213/AC4: project-a's #198 process is killed" || return 1
  assert_eq "$b_alive" "alive" "#213/AC4: project-b's #198 process is NOT killed" || return 1
  assert_eq "$a_tomb" "present" "#213/AC4: tombstone $KA.stopped written" || return 1
  assert_eq "$b_tomb" "absent" "#213/AC4: no tombstone for the other repo's #198" || return 1
  assert_eq "$b_queue" "present" "#213/AC4: the other repo's queue entry is left alone" || return 1
  assert_eq "$old" "" "#213/AC4: no number-only tombstone written" || return 1
}

test_rk_ac4_one_argument_stop_exits_2_without_side_effects() {
  rk_env
  rk_live orch-project-a_repo-a-198 "$RK_A"
  local pa out rc stopped alive
  pa=$(cat "$RK_PIPE/orch-project-a_repo-a-198.pid")
  out=$(rk_run "$ORCH_RK" stop 198 2>&1); rc=$?
  stopped=$(ls "$RK_PIPE" | grep -c '\.stopped$' || true); alive=$(rk_alive "$pa")
  rk_cleanup
  assert_eq "$rc" "2" "#213/AC4: stop 198 exits 2 (out: $out)" || return 1
  assert_contains "$out" "owner/repo" "#213/AC4: usage line names <owner/repo>" || return 1
  assert_eq "$stopped" "0" "#213/AC4: no tombstone of any name written" || return 1
  assert_eq "$alive" "alive" "#213/AC4: nothing killed" || return 1
}

test_rk_ac4_tail_takes_repo_and_one_argument_exits_2() {
  rk_env
  printf 'a1\na2\na3\na4\na5\n' > "$RK_PIPE/orch-project-a_repo-a-198.log"
  printf 'b1\nb2\nb3\nb4\nb5\n' > "$RK_PIPE/orch-project-b_repo-b-198.log"
  local good out1 out2 rc2
  good=$(rk_run "$ORCH_RK" tail project-a/repo-a 198 3 2>&1)
  out1=$(rk_run "$ORCH_RK" tail 198 2>&1); rc2=$?
  rk_cleanup
  assert_eq "$good" "$(printf 'a3\na4\na5')" "#213/AC4: tail <owner/repo> <N> 3 prints that run's last 3 lines" || return 1
  assert_eq "$rc2" "2" "#213/AC4: tail 198 exits 2 (out: $out1)" || return 1
  assert_contains "$out1" "owner/repo" "#213/AC4: usage line names <owner/repo>" || return 1
}

test_rk_status_lists_both_repos_for_one_number_and_filters_by_number() {
  rk_env
  rk_live orch-project-a_repo-a-196 "$RK_A"
  rk_dead orch-project-b_repo-b-196 "$RK_B" held
  local out hit
  out=$(rk_run "$ORCH_RK" status 196 2>&1)
  hit=$(rk_run "$ORCH_RK" status 19 2>&1)
  rk_cleanup
  assert_eq "$(printf '%s\n' "$out" | grep -c '^#196 ')" "2" "#213/decision: status 196 prints one line per repo" || return 1
  assert_contains "$out" "running (pid " "#213: running line" || return 1
  assert_contains "$out" "held (needs JP)  repo=$RK_B" "#213: held line carries its own repo=" || return 1
  assert_contains "$out" "repo=$RK_A  latest marker: none  log=$RK_PIPE/orch-project-a_repo-a-196.log" "#213: log= path uses the run_key" || return 1
  assert_not_contains "$hit" "#196" "#213: status 19 is an exact-number filter" || return 1
}

test_rk_queue_listing_is_ordered_by_queued_at_oldest_first() {
  rk_env
  # name order would put project-a (#5) first; queued_at says project-b (#1) is older.
  rk_queue orch-project-a_repo-a-5 5 "$RK_A" 2026-01-02T00:00:00Z 0
  rk_queue orch-project-b_repo-b-1 1 "$RK_B" 2026-01-01T00:00:00Z 0
  local q s ql1 ql2 sl1 sl2
  q=$(rk_run "$ORCH_RK" queue 2>&1); s=$(rk_run "$ORCH_RK" status 2>&1)
  rk_cleanup
  ql1=$(printf '%s\n' "$q" | grep -n '^#1 ' | head -1 | cut -d: -f1); ql2=$(printf '%s\n' "$q" | grep -n '^#5 ' | head -1 | cut -d: -f1)
  sl1=$(printf '%s\n' "$s" | grep -n '^#1 ' | head -1 | cut -d: -f1); sl2=$(printf '%s\n' "$s" | grep -n '^#5 ' | head -1 | cut -d: -f1)
  [ -n "$ql1" ] && [ -n "$ql2" ] || { fail "#213: queue must list both entries, got: $q"; return 1; }
  assert_lt "$ql1" "$ql2" "#213/decision: queue lists the oldest queued_at (#1) first" || return 1
  [ -n "$sl1" ] && [ -n "$sl2" ] || { fail "#213: status must list both queued entries, got: $s"; return 1; }
  assert_lt "$sl1" "$sl2" "#213/decision: status --- queued --- lists the oldest queued_at first" || return 1
}

# ------------------------------------------------------------------------------------------ AC9 golden

test_rk_ac9_status_golden_changes_only_the_log_field() {
  local pipe repo_a repo_b fake_home actual expected pid101
  pipe=$(new_pipe); repo_a=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX"); repo_b=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX")
  fake_home=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-home.XXXXXX"); mkdir -p "$fake_home/.claude/pipeline"
  # same fixture as test-ac14-status-golden.sh, files named by run_key (repo-a = project-a/repo-a, repo-b = project-b/repo-b)
  sleep 300 & pid101=$!
  echo "$pid101" > "$pipe/orch-project-a_repo-a-101.pid"; echo "$repo_a" > "$pipe/orch-project-a_repo-a-101.repo"
  ( : ) & local p102=$!; wait "$p102" 2>/dev/null
  echo "$p102" > "$pipe/orch-project-b_repo-b-102.pid"; echo "$repo_b" > "$pipe/orch-project-b_repo-b-102.repo"
  ( : ) & local p103=$!; wait "$p103" 2>/dev/null
  echo "$p103" > "$pipe/orch-project-a_repo-a-103.pid"; echo "$repo_a" > "$pipe/orch-project-a_repo-a-103.repo"
  touch "$pipe/orch-project-a_repo-a-103.held"
  printf '2026-09-17T00:00:00Z Pipeline #103 waiting on JP\n' > "$pipe/orch-project-a_repo-a-103.alert"
  python3 -c "
import json
json.dump({'issue':'104','repo':'$repo_b','extra':'','reason':'queued','queued_at':'2026-09-17T00:00:00Z','not_before':0}, open('$pipe/queue/orch-project-b_repo-b-104.json','w'))
"
  actual=$( ( HOME="$fake_home" PATH="$FAKEBIN_RK:/usr/bin:/bin" PIPE="$pipe" QUEUE="$pipe/queue" "$ORCH_RK" status ) 2>&1 \
    | sed -e "s#$pipe#@@PIPE@@#g" -e "s#$repo_a#@@REPOA@@#g" -e "s#$repo_b#@@REPOB@@#g" -e "s/pid [0-9][0-9]*/pid @@PID@@/g" )
  expected=$(sed -e 's#orch-101\.log#orch-project-a_repo-a-101.log#' -e 's#orch-102\.log#orch-project-b_repo-b-102.log#' \
                 -e 's#orch-103\.log#orch-project-a_repo-a-103.log#' "$HERE_RK/fixtures/golden/status-full.txt")
  kill "$pid101" 2>/dev/null
  rm -rf "$pipe" "$repo_a" "$repo_b" "$fake_home"
  assert_eq "$actual" "$expected" "#213/AC9: status output = golden with only the log= path field re-keyed" || return 1
}

# ------------------------------------------------------------------------------------------ AC5

test_rk_ac5_derive_runs_two_repos_same_number_give_separate_rows() {
  rk_env
  local KA=orch-project-a_repo-a-196 KB=orch-project-b_repo-b-196 KC=orch-project-c_repo-c-196
  rk_queue "$KA" 196 "$RK_A" 2026-01-01T00:00:00Z 0                  # queued-only (project-a)
  rk_live "$KB" "$RK_B"                                              # running (project-b)
  echo "$RK_C" > "$RK_PIPE/$KC.repo"; date -u +%FT%TZ > "$RK_PIPE/$KC.closed"   # closed, no pid (project-c)
  local tsv
  tsv=$( HOME="$RK_HOME" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" bash -c '. "'"$RS_RK"'/run-state.sh"; derive_runs' 2>/dev/null )
  rk_cleanup
  assert_eq "$(printf '%s\n' "$tsv" | awk -F'\t' '$1 == "196"' | wc -l | tr -d ' ')" "3" "#213/AC5: three rows for the three repos' #196" || return 1
  assert_eq "$(printf '%s\n' "$tsv" | awk -F'\t' -v r="$RK_A" '$1 == "196" && $2 == r {print $3}')" "queued" "#213/AC5: project-a #196 is queued (not masked by project-b's pid)" || return 1
  assert_eq "$(printf '%s\n' "$tsv" | awk -F'\t' -v r="$RK_B" '$1 == "196" && $2 == r {print $3}')" "running" "#213/AC5: project-b #196 is running" || return 1
  assert_eq "$(printf '%s\n' "$tsv" | awk -F'\t' -v r="$RK_C" '$1 == "196" && $2 == r {print $3}')" "closed" "#213/AC5: project-c #196 is closed" || return 1
}

# rk_reconcile_payload — reconcile (forced) then the reporter's --print payload
rk_reconcile_payload() {
  rk_conf 'STATUS_REPO_ALIASES=("project-a/repo-a:alias-a" "project-b/repo-b:alias-b")'
  rk_run "$RS_RK/reconcile-status.sh" --force >/dev/null 2>&1
  rk_run "$RS_RK/report-status.sh" --print 2>/dev/null
}

test_rk_ac5_reconcile_and_runs_json_keep_two_open_rows_apart() {
  rk_env
  local KA=orch-project-a_repo-a-196 KB=orch-project-b_repo-b-196
  rk_dead "$KA" "$RK_A" held; echo "Alpha title" > "$RK_PIPE/$KA.title"
  rk_dead "$KB" "$RK_B" held; echo "Beta title" > "$RK_PIPE/$KB.title"
  jq -n '{state:"OPEN",labels:[],comments:[{body:"**[product-manager] READY FOR ENGINEERING**\nx",createdAt:"2026-10-01T00:00:00Z"}],
          milestone:{title:"Plan Alpha"},closedAt:null,updatedAt:"2026-10-01T00:00:00Z"}' > "$RK_GH/view-repo-a.json"
  jq -n '{state:"OPEN",labels:[],comments:[{body:"**[fullstack-developer] BLOCKED**\nneeds a decision",createdAt:"2026-10-01T00:00:00Z"}],
          milestone:{title:"Plan Beta"},closedAt:null,updatedAt:"2026-10-01T00:00:00Z"}' > "$RK_GH/view-repo-b.json"
  local out ra rb
  out=$(rk_reconcile_payload)
  rk_cleanup
  [ "$(rk_jq "$out" '[.runs[] | select(.issue==196)] | length')" = "2" ] || { fail "#213/AC5: expected two runs[] rows for #196, got: $out"; return 1; }
  ra=$(rk_jq "$out" '[.runs[] | select(.issue==196 and .repo=="alias-a")][0] | [.title, .marker, .milestone] | join("|")')
  rb=$(rk_jq "$out" '[.runs[] | select(.issue==196 and .repo=="alias-b")][0] | [.title, .marker, .milestone] | join("|")')
  assert_eq "$ra" "Alpha title|READY FOR ENGINEERING|Plan Alpha" "#213/AC5: project-a row's own title, marker, milestone" || return 1
  assert_eq "$rb" "Beta title|BLOCKED|Plan Beta" "#213/AC5: project-b row's own title, marker, milestone" || return 1
}

test_rk_ac5_reconcile_and_completed_json_keep_closed_and_release_apart() {
  rk_env
  local KA=orch-project-a_repo-a-196 KB=orch-project-b_repo-b-196 closed
  closed=$(rk_iso_ago 86400)
  rk_dead "$KA" "$RK_A" held; echo "Alpha title" > "$RK_PIPE/$KA.title"
  rk_dead "$KB" "$RK_B" held; echo "Beta title" > "$RK_PIPE/$KB.title"
  jq -n --arg c "$closed" '{state:"CLOSED",labels:[],comments:[{body:"**[deployer] DEPLOYED**\nx",createdAt:$c}],
          milestone:null,closedAt:$c,updatedAt:$c}' > "$RK_GH/view-repo-a.json"
  jq -n '{state:"OPEN",labels:[],comments:[],milestone:{title:"v9.9.9"},closedAt:null,updatedAt:"2026-10-01T00:00:00Z"}' > "$RK_GH/view-repo-b.json"
  local out
  out=$(rk_reconcile_payload)
  rk_cleanup
  [ "$(rk_jq "$out" '[.completed[] | select(.issue==196)] | length')" = "2" ] || { fail "#213/AC5: expected two completed[] rows for #196, got: $out"; return 1; }
  assert_eq "$(rk_jq "$out" '[.completed[] | select(.repo=="alias-a")][0] | .closed_at')" "$closed" "#213/AC5: project-a closed_at is its own closedAt" || return 1
  assert_eq "$(rk_jq "$out" '[.completed[] | select(.repo=="alias-a")][0] | .release // "none"')" "none" "#213/AC5: project-a has no release" || return 1
  assert_eq "$(rk_jq "$out" '[.completed[] | select(.repo=="alias-b")][0] | .release')" "v9.9.9" "#213/AC5: project-b carries its own release" || return 1
  assert_eq "$(rk_jq "$out" '[.completed[] | select(.repo=="alias-a")][0] | .title')" "Alpha title" "#213/AC5: project-a completed title" || return 1
  assert_eq "$(rk_jq "$out" '[.completed[] | select(.repo=="alias-b")][0] | .title')" "Beta title" "#213/AC5: project-b completed title" || return 1
}

# ------------------------------------------------------------------------------------------ AC6

rk_stage_rows() {  # rk_stage_rows <ps fixture file> -> derive_runs TSV with RS_PS_CMD reading it
  HOME="$RK_HOME" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" RS_PS_CMD="cat $1" bash -c '. "'"$RS_RK"'/run-state.sh"; derive_runs' 2>/dev/null
}

test_rk_ac6_live_stage_ignores_same_number_process_of_another_repo() {
  rk_env
  rk_live orch-project-a_repo-a-196 "$RK_A"; rk_live orch-project-b_repo-b-196 "$RK_B"
  local now; now=$(date +%s)
  # project-b's stage process is NEWER; without the PIPELINE_REPO match project-a would wrongly show code-reviewer.
  printf '%s\t196\tclaude --dangerously-skip-permissions --agent test-writer -p x\tproject-a/repo-a\n%s\t196\tclaude --dangerously-skip-permissions --agent code-reviewer -p x\tproject-b/repo-b\n' \
    "$((now - 60))" "$((now - 5))" > "$RK_PIPE/ps.fixture"
  local tsv
  tsv=$(rk_stage_rows "$RK_PIPE/ps.fixture")
  rk_cleanup
  assert_eq "$(printf '%s\n' "$tsv" | awk -F'\t' -v r="$RK_A" '$1 == "196" && $2 == r {print $8}')" "test-writer" "#213/AC6: project-a stage = its own process" || return 1
  assert_eq "$(printf '%s\n' "$tsv" | awk -F'\t' -v r="$RK_B" '$1 == "196" && $2 == r {print $8}')" "code-reviewer" "#213/AC6: project-b stage = its own process" || return 1
}

test_rk_ac6_run_without_own_stage_process_is_orchestrator_not_the_other_repos_stage() {
  rk_env
  rk_live orch-project-a_repo-a-196 "$RK_A"; rk_live orch-project-b_repo-b-196 "$RK_B"
  printf '%s\t196\tclaude --dangerously-skip-permissions --agent fullstack-developer -p x\tproject-a/repo-a\n' \
    "$(( $(date +%s) - 5 ))" > "$RK_PIPE/ps.fixture"
  local tsv
  tsv=$(rk_stage_rows "$RK_PIPE/ps.fixture")
  rk_cleanup
  assert_eq "$(printf '%s\n' "$tsv" | awk -F'\t' -v r="$RK_A" '$1 == "196" && $2 == r {print $8}')" "fullstack-developer" "#213/AC6: project-a stage" || return 1
  assert_eq "$(printf '%s\n' "$tsv" | awk -F'\t' -v r="$RK_B" '$1 == "196" && $2 == r {print $8}')" "orchestrator" "#213/AC6: project-b alive with no stage process of its own -> orchestrator" || return 1
}

# ------------------------------------------------------------------------------------------ AC7 / AC8 migration

# rk_install_env — rk_env plus install.sh's extra externals stubbed (crontab above all: it writes the real user crontab).
# A checkout with no origin (unresolvable) at RK_PIPE/norepo.
rk_install_env() {
  rk_env
  printf '#!/bin/bash\ncase "$1" in -l) exit 0 ;; -) cat > /dev/null; exit 0 ;; *) exit 1 ;; esac\n' > "$RK_GH/crontab"
  printf '#!/bin/bash\nexit 0\n' > "$RK_GH/vercel"
  printf '#!/bin/bash\necho "$*" >> "$(dirname "$0")/curl.log"\necho "{\\"ok\\":true}"\n' > "$RK_GH/curl"
  chmod +x "$RK_GH/crontab" "$RK_GH/vercel" "$RK_GH/curl"
  mkdir -p "$RK_PIPE/norepo"; ( cd "$RK_PIPE/norepo" && git init -q ) >/dev/null 2>&1
}

rk_install() {  # runs the repo's install.sh; refuses unless crontab is the stub
  local resolved
  resolved=$(HOME="$RK_HOME" PATH="$RK_GH:$PATH" bash -c 'command -v crontab')
  if [ "$resolved" != "$RK_GH/crontab" ]; then echo "REFUSING: crontab resolves to [$resolved]" >&2; return 99; fi
  HOME="$RK_HOME" PATH="$RK_GH:$PATH" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" LOGDIR="$RK_LOG" \
    "$ROOT_RK/skills/orchestrate/install.sh" --minute even > "$RK_HOME/install.out" 2>&1
}

rk_tree() {  # rk_tree — deterministic listing + content of the whole pipe dir
  ( cd "$RK_PIPE" && find . -type f | sort | while read -r f; do printf '== %s\n' "$f"; cat "$f"; done )
}

test_rk_ac8_cutover_renames_everything_and_supervisor_sees_live_and_queued() {
  rk_install_env
  rk_conf "MAX_CONCURRENT=1"
  # live #198 (project-a), queued-only #196 (project-b) with its queue entry — bare-number names, as on the hosts today
  sleep 300 & local pid=$!; RK_PIDS="$RK_PIDS $pid"
  echo "$pid" > "$RK_PIPE/orch-198.pid"; echo "$RK_A" > "$RK_PIPE/orch-198.repo"
  date -u +%FT%TZ > "$RK_PIPE/orch-198.start"; echo "Alpha title" > "$RK_PIPE/orch-198.title"; : > "$RK_PIPE/orch-198.log"
  echo "$RK_B" > "$RK_PIPE/orch-196.repo"; echo "extra words" > "$RK_PIPE/orch-196.extra"; echo "Beta title" > "$RK_PIPE/orch-196.title"
  rk_queue orch-196 196 "$RK_B" "$(rk_iso_ago 300)" 0
  rk_install; local rc=$?
  local old a_pid a_repo a_title b_extra b_queue_issue status
  old=$(rk_old_names)
  a_pid=$(cat "$RK_PIPE/orch-project-a_repo-a-198.pid" 2>/dev/null); a_repo=$(cat "$RK_PIPE/orch-project-a_repo-a-198.repo" 2>/dev/null)
  a_title=$(cat "$RK_PIPE/orch-project-a_repo-a-198.title" 2>/dev/null)
  b_extra=$(cat "$RK_PIPE/orch-project-b_repo-b-196.extra" 2>/dev/null)
  b_queue_issue=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['issue'])" "$RK_PIPE/queue/orch-project-b_repo-b-196.json" 2>/dev/null)
  status=$(rk_run "$ORCH_RK" status 2>&1)
  rk_tick
  local b_launched b_queue_left
  b_launched=$(rk_present "$RK_PIPE/orch-project-b_repo-b-196.pid"); b_queue_left=$(rk_present "$RK_PIPE/queue/orch-project-b_repo-b-196.json")
  rk_cleanup
  assert_exit0 "$rc" "#213/AC8: install.sh exits 0" || return 1
  assert_eq "$old" "" "#213/AC8: no ^orch-[0-9]+\\. file remains after the step" || return 1
  assert_eq "$a_pid" "$pid" "#213/AC8: the live run's pid file keeps its pid under the new key" || return 1
  assert_eq "$a_repo" "$RK_A" "#213/AC8: .repo content unchanged (checkout path)" || return 1
  assert_eq "$a_title" "Alpha title" "#213/AC8: .title moved with the run" || return 1
  assert_eq "$b_extra" "extra words" "#213/AC8: the queued run's .extra moved" || return 1
  assert_eq "$b_queue_issue" "196" "#213/AC8: queue entry moved to queue/orch-project-b_repo-b-196.json" || return 1
  assert_contains "$status" "#198  running (pid $pid)" "#213/AC8: status sees the live run" || return 1
  assert_contains "$status" "#196  queued" "#213/AC8: status sees the queued entry" || return 1
  assert_eq "$b_launched" "absent" "#213/AC8: tick saw the live run (1/1 slots) and did not launch the queued one" || return 1
  assert_eq "$b_queue_left" "present" "#213/AC8: tick left the queued entry in place" || return 1
}

# fixtures that cannot be resolved: no .repo at all (#77), .repo -> checkout without origin (#78), queue JSON -> same (#79)
rk_unresolvable_fixture() {
  rk_dead orch-77 "$RK_PIPE/norepo"; rm -f "$RK_PIPE/orch-77.repo"
  rk_dead orch-78 "$RK_PIPE/norepo"
  rk_queue orch-79 79 "$RK_PIPE/norepo" 2026-01-01T00:00:00Z 0
  # one resolvable run so the step demonstrably did work
  sleep 300 & local pid=$!; RK_PIDS="$RK_PIDS $pid"
  echo "$pid" > "$RK_PIPE/orch-198.pid"; echo "$RK_A" > "$RK_PIPE/orch-198.repo"
}

test_rk_ac7_unresolvable_files_stay_are_listed_and_exit_0() {
  rk_install_env
  rk_unresolvable_fixture
  rk_install; local rc=$?
  local out left77 left78 left79 renamed gone
  out=$(cat "$RK_HOME/install.out" 2>/dev/null)
  left77=$(rk_present "$RK_PIPE/orch-77.pid"); left78=$(rk_present "$RK_PIPE/orch-78.pid"); left79=$(rk_present "$RK_PIPE/queue/orch-79.json")
  renamed=$(rk_present "$RK_PIPE/orch-project-a_repo-a-198.pid"); gone=$(rk_present "$RK_PIPE/orch-198.pid")
  rk_cleanup
  assert_exit0 "$rc" "#213/AC7: install.sh still exits 0" || return 1
  assert_eq "$renamed" "present" "#213/AC7: the resolvable run was renamed" || return 1
  assert_eq "$gone" "absent" "#213/AC7: its old name is gone" || return 1
  assert_eq "$left77" "present" "#213/AC7: file with no .repo left in place (never deleted)" || return 1
  assert_eq "$left78" "present" "#213/AC7: file whose .repo has no origin left in place" || return 1
  assert_eq "$left79" "present" "#213/AC7: queue entry whose repo cannot be resolved left in place" || return 1
  assert_contains "$out" "orch-77" "#213/AC7: install output lists the unresolved #77 file" || return 1
  assert_contains "$out" "orch-78" "#213/AC7: install output lists the unresolved #78 file" || return 1
  assert_contains "$out" "orch-79" "#213/AC7: install output lists the unresolved #79 queue entry" || return 1
}

test_rk_ac7_migration_is_idempotent() {
  rk_install_env
  rk_unresolvable_fixture
  rk_install; local rc1=$?
  local first renamed; first=$(rk_tree); renamed=$(rk_present "$RK_PIPE/orch-project-a_repo-a-198.pid")
  rk_install; local rc2=$?
  local second; second=$(rk_tree)
  rk_cleanup
  assert_exit0 "$rc1" "#213/AC7: first install exits 0" || return 1
  assert_eq "$renamed" "present" "#213/AC7: the first run did rename (so the second-run comparison is not vacuous)" || return 1
  assert_exit0 "$rc2" "#213/AC7: second install exits 0" || return 1
  assert_eq "$second" "$first" "#213/AC7: a second run changes nothing" || return 1
}

# ------------------------------------------------------------------------------------------ AC13 observability

# rk_error_row <route> — the first events.jsonl row with event=error and that route
rk_error_row() {
  jq -c --arg r "$1" 'select(.event=="error" and .route==$r)' "$RK_LOG/events.jsonl" 2>/dev/null | head -1
}

# rk_check_error_row <route> <row> <label> — release is the checkout's commit SHA (not vX.Y.Z), host, no secrets
rk_check_error_row() {
  local route=$1 row=$2 label=$3 rel head resolved
  [ -n "$row" ] || { fail "$label: no error row with route=$route in events.jsonl"; return 1; }
  rel=$(rk_jq "$row" .release)
  head=$(git -C "$ROOT_RK" rev-parse HEAD 2>/dev/null)
  resolved=$(git -C "$ROOT_RK" rev-parse --verify "${rel}^{commit}" 2>/dev/null)
  case "$rel" in v[0-9]*) fail "$label: release must be a commit SHA, got $rel"; return 1 ;; esac
  assert_ne "$rel" "" "$label: release present" || return 1
  assert_eq "$resolved" "$head" "$label: release resolves to the claude-agents checkout commit" || return 1
  assert_eq "$(rk_jq "$row" .host)" "$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')" "$label: host" || return 1
  assert_eq "$(rk_jq "$row" .v)" "1" "$label: standard v:1 row" || return 1
}

rk_secrets() {
  rk_conf 'SLACK_BOT_TOKEN="rk213-fake-bot-sentinel"'
  rk_conf 'SLACK_ENGINEERING_CHANNEL="CRK213"'
  rk_conf 'STATUS_PUSH_TOKEN="rk213-fake-push-sentinel"'
}

test_rk_obs_migration_failure_writes_error_row_and_posts_to_slack() {
  rk_install_env
  rk_secrets
  rk_unresolvable_fixture
  rk_install >/dev/null
  local row events curl
  row=$(rk_error_row run-key-migration)
  events=$(cat "$RK_LOG/events.jsonl" 2>/dev/null); curl=$(cat "$RK_GH/curl.log" 2>/dev/null)
  rk_check_error_row run-key-migration "$row" "#213/obs: migration" ; local r=$?
  rk_cleanup
  [ "$r" -eq 0 ] || return 1
  assert_not_contains "$events" "rk213-fake-bot-sentinel" "#213/obs: no bot token in events.jsonl" || return 1
  assert_not_contains "$events" "rk213-fake-push-sentinel" "#213/obs: no push token in events.jsonl" || return 1
  assert_not_contains "$events" "hooks.slack.com" "#213/obs: no webhook URL in events.jsonl" || return 1
  assert_contains "$curl" "chat.postMessage" "#213/obs: failure posted through the existing Slack path (notify_engineering)" || return 1
}

test_rk_obs_launch_failure_writes_error_row_and_posts_to_slack() {
  rk_install_env
  rk_secrets
  touch "$RK_GH/repo-view-fail"        # owner/repo cannot be resolved -> no run_key -> the launch fails
  local out rc row events curl old
  out=$(HOME="$RK_HOME" PATH="$RK_GH:/usr/bin:/bin" PIPE="$RK_PIPE" QUEUE="$RK_PIPE/queue" LOGDIR="$RK_LOG" "$ORCH_RK" "$RK_A" 196 2>&1); rc=$?
  row=$(rk_error_row launch)
  events=$(cat "$RK_LOG/events.jsonl" 2>/dev/null); curl=$(cat "$RK_GH/curl.log" 2>/dev/null); old=$(rk_old_names)
  rk_check_error_row launch "$row" "#213/obs: launch"; local r=$?
  rk_cleanup
  assert_ne "$rc" "0" "#213/obs: a launch that cannot derive its run_key fails (out: $out)" || return 1
  [ "$r" -eq 0 ] || return 1
  assert_eq "$old" "" "#213/obs: a failed launch falls back to no number-only file" || return 1
  assert_not_contains "$events" "rk213-fake-bot-sentinel" "#213/obs: no bot token in events.jsonl" || return 1
  assert_not_contains "$events" "rk213-fake-push-sentinel" "#213/obs: no push token in events.jsonl" || return 1
  assert_contains "$curl" "chat.postMessage" "#213/obs: launch failure posted through the existing Slack path" || return 1
}

# ------------------------------------------------------------------------------------------ AC10 docs

test_rk_ac10_docs_no_longer_describe_number_only_keys() {
  local f hits stop_old pos
  for f in "$ROOT_RK/README.md" "$ROOT_RK/skills/orchestrate/SKILL.md"; do
    hits=$(grep -nE 'orch-<(issue|n)>' "$f" 2>/dev/null || true)
    assert_eq "$hits" "" "#213/AC10: $(basename "$f") still mentions orch-<issue>/orch-<n>" || return 1
  done
  stop_old=$(grep -nE 'orchestrate\.sh (stop|tail) [0-9]+' "$ROOT_RK/skills/orchestrate/SKILL.md" 2>/dev/null || true)
  assert_eq "$stop_old" "" "#213/AC10: SKILL.md still shows the one-argument stop/tail" || return 1
  pos=$(grep -cE 'orchestrate\.sh stop (<owner/repo>|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) ' "$ROOT_RK/skills/orchestrate/SKILL.md" 2>/dev/null || true)
  assert_ne "${pos:-0}" "0" "#213/AC10: SKILL.md documents stop <owner/repo> <N>" || return 1
}

run_test test_rk_ac1_run_key_is_repo_scoped_and_hyphen_safe
run_test test_rk_ac1_no_per_run_path_built_from_a_bare_number
run_test test_rk_ac2_handlaunch_leaves_other_repos_196_untouched
run_test test_rk_ac2_queued_handlaunch_leaves_other_repos_queue_entry
run_test test_rk_ac3_drain_ignores_other_repos_held
run_test test_rk_ac3_drain_ignores_other_repos_done
run_test test_rk_ac3_drain_ignores_other_repos_stopped
run_test test_rk_ac3_drain_ignores_other_repos_running
run_test test_rk_ac3_drain_mirror_b_queued_a_held
run_test test_rk_ac3_dispatch_keeps_other_repos_held_703
run_test test_rk_ac3_dispatch_not_blocked_by_other_repos_running_703
run_test test_rk_ac3_dispatch_not_blocked_by_other_repos_queued_703
run_test test_rk_ac4_stop_with_repo_kills_only_that_run
run_test test_rk_ac4_one_argument_stop_exits_2_without_side_effects
run_test test_rk_ac4_tail_takes_repo_and_one_argument_exits_2
run_test test_rk_status_lists_both_repos_for_one_number_and_filters_by_number
run_test test_rk_queue_listing_is_ordered_by_queued_at_oldest_first
run_test test_rk_ac9_status_golden_changes_only_the_log_field
run_test test_rk_ac5_derive_runs_two_repos_same_number_give_separate_rows
run_test test_rk_ac5_reconcile_and_runs_json_keep_two_open_rows_apart
run_test test_rk_ac5_reconcile_and_completed_json_keep_closed_and_release_apart
run_test test_rk_ac6_live_stage_ignores_same_number_process_of_another_repo
run_test test_rk_ac6_run_without_own_stage_process_is_orchestrator_not_the_other_repos_stage
run_test test_rk_ac8_cutover_renames_everything_and_supervisor_sees_live_and_queued
run_test test_rk_ac7_unresolvable_files_stay_are_listed_and_exit_0
run_test test_rk_ac7_migration_is_idempotent
run_test test_rk_obs_migration_failure_writes_error_row_and_posts_to_slack
run_test test_rk_obs_launch_failure_writes_error_row_and_posts_to_slack
run_test test_rk_ac10_docs_no_longer_describe_number_only_keys
