# Issue #217 — a hand launch arbitrates the claim like shared dispatch does.
#
#   AC1  claim_winner <local_path> <issue> in pipeline-lib.sh; supervisor.sh calls it (no inline copy)
#   AC2  hand launch (no --force): post claim, sleep CLAIM_SETTLE_SECS, claim_winner; not this host ->
#        "#N lost claim to <host> — running there; use --force to take over", exit 1, nothing launched,
#        tombstones untouched, agent-in-progress not removed
#   AC4  --force skips arbitration (no settle sleep); SKILL.md documents --force as takeover
#   AC5  label guard stays
#   Obs  gh failure during arbitration -> refused (fail closed), failure recorded in events.jsonl
#
# Placeholder repo names only. Expected values hand-written from the ticket. Fake gh is local to this file
# (tests/bin/gh is the status-golden stub and answers only `issue view`).

HERE_HC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_HC="$HERE_HC/.."
ORCH_HC="$RS_HC/orchestrate.sh"
SUP_HC="$RS_HC/supervisor.sh"

hc_iso() {  # hc_iso <secs-ago> -> UTC timestamp that many seconds in the past
  python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"
}

hc_env() {  # -> HC_PIPE HC_HOME HC_REPO HC_BIN ; comments come from $HC_BIN/comments.json
  HC_PIPE=$(new_pipe); HC_HOME=$(new_home)
  HC_REPO="$HC_PIPE/repo-a"
  fixture_repo "$HC_REPO" "project-a/repo-a"
  HC_BIN="$HC_HOME/.local/bin"; mkdir -p "$HC_BIN"
  : > "$HC_BIN/gh-calls.log"; : > "$HC_BIN/sleep-calls.log"
  echo '[]' > "$HC_BIN/comments.json"
  printf 'MEM_FLOOR_MB=0\nCLAIM_SETTLE_SECS=7\nCLAIM_WINDOW_SECS=600\n' > "$HC_HOME/.claude/pipeline/config.local.sh"
  cat > "$HC_BIN/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' "$*" >> "$HERE/gh-calls.log"
jq_expr() { local p=""; for a in "$@"; do [ "$p" = "--jq" ] && { printf '%s' "$a"; return; }; p=$a; done; }
case "$*" in
  "issue comment"*|"issue edit"*) exit 0 ;;
  *"repo view"*) echo "project-a/repo-a"; exit 0 ;;
  "issue view"*)
    case "$*" in *comments*) [ -f "$HERE/comments-fail" ] && exit 1 ;; esac
    json=$(jq -n --slurpfile c "$HERE/comments.json" --argjson l "$(cat "$HERE/labels.json" 2>/dev/null || echo '[]')" \
      '{state:"OPEN",title:"t",labels:$l,comments:$c[0],updatedAt:"2026-01-01T00:00:00Z"}')
    e=$(jq_expr "$@"); if [ -n "$e" ]; then printf '%s' "$json" | jq -r "$e"; else printf '%s\n' "$json"; fi
    exit 0 ;;
esac
exit 0
GH_EOF
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/sleep-calls.log"\nexit 0\n' "$HC_BIN" > "$HC_BIN/sleep"
  printf '#!/bin/bash\nexec /bin/sleep 30\n' > "$HC_BIN/claude"
  chmod +x "$HC_BIN/gh" "$HC_BIN/sleep" "$HC_BIN/claude"
}

hc_claims() {  # hc_claims <host:secs-ago>... -> comments.json with one claim comment per arg
  local out="[" sep="" a h s
  for a in "$@"; do
    h=${a%%:*}; s=${a##*:}
    out="$out$sep{\"body\":\"**[supervisor] NOTE** claim: $h $(hc_iso "$s")\",\"createdAt\":\"$(hc_iso "$s")\"}"; sep=","
  done
  printf '%s]' "$out" > "$HC_BIN/comments.json"
}

hc_cleanup() {
  local f pid
  for f in "$HC_PIPE"/orch-*.pid; do
    [ -e "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null); [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  done
  rm -rf "$HC_PIPE" "$HC_HOME"
}

hc_launch() {  # hc_launch <issue> [--force]
  local n=$1; shift
  HOME="$HC_HOME" PATH="$HC_BIN:/usr/bin:/bin" PIPE="$HC_PIPE" QUEUE="$HC_PIPE/queue" LOGDIR="$HC_HOME/logs/pipeline" \
    "$ORCH_HC" "$@" "$HC_REPO" "$n" 2>&1
}

hc_claim_winner() {  # hc_claim_winner <issue> -> stdout of claim_winner
  ( export HOME="$HC_HOME" PATH="$HC_BIN:/usr/bin:/bin" PIPE="$HC_PIPE" QUEUE="$HC_PIPE/queue" LOGDIR="$HC_HOME/logs/pipeline"
    . "$RS_HC/config.sh"; . "$RS_HC/pipeline-lib.sh"
    claim_winner "$HC_REPO" "$1" )
}

test_hc_claim_winner_earliest_in_window() {
  hc_env
  # earliest in-window claim is hostb (30s ago); hosta is 20s ago; hostc (900s) is outside the 600s window
  hc_claims hosta:20 hostc:900 hostb:30
  local w; w=$(hc_claim_winner 42)
  hc_cleanup
  assert_eq "$w" "hostb" "#217: claim_winner = earliest claim inside CLAIM_WINDOW_SECS" || return 1
}

test_hc_claim_winner_ignores_non_claim_comments() {
  hc_env
  printf '[{"body":"see **[supervisor] NOTE** claim: evil 1","createdAt":"%s"},{"body":"**[supervisor] NOTE** claim: hosta %s","createdAt":"%s"}]' \
    "$(hc_iso 50)" "$(hc_iso 10)" "$(hc_iso 10)" > "$HC_BIN/comments.json"
  local w; w=$(hc_claim_winner 42)
  hc_cleanup
  assert_eq "$w" "hosta" "#217: only comments STARTING with the claim prefix count" || return 1
}

test_hc_a_other_host_earlier_claim_refuses() {
  hc_env
  local me; me=$(hostname -s)
  # hostb claimed 3s before this host (hand arithmetic: 13s ago vs 10s ago)
  hc_claims otherhost:13 "$me:10"
  touch "$HC_PIPE/orch-42.stopped"
  local out rc
  out=$(hc_launch 42); rc=$?
  local stopped=gone extra=present pidf=present q=present ev=0
  [ -f "$HC_PIPE/orch-42.stopped" ] && stopped=kept
  [ -f "$HC_PIPE/orch-42.extra" ] || extra=absent
  [ -f "$HC_PIPE/orch-42.pid" ] || pidf=absent
  [ -f "$HC_PIPE/queue/orch-42.json" ] || q=absent
  [ -f "$HC_HOME/logs/pipeline/events.jsonl" ] && ev=$(grep -c run_launch "$HC_HOME/logs/pipeline/events.jsonl")
  local removed=0; grep -q -- "--remove-label agent-in-progress" "$HC_BIN/gh-calls.log" && removed=1
  hc_cleanup
  assert_eq "$rc" "1" "#217(a): exit 1" || return 1
  assert_contains "$out" "#42 lost claim to otherhost — running there; use --force to take over" "#217(a): exact refusal message" || return 1
  assert_not_contains "$out" "launched orchestrator" "#217(a): nothing launched" || return 1
  assert_eq "$stopped" "kept" "#217(a): tombstone untouched" || return 1
  assert_eq "$extra" "absent" "#217(a): .extra not written" || return 1
  assert_eq "$pidf" "absent" "#217(a): no pid" || return 1
  assert_eq "$q" "absent" "#217(a): not queued" || return 1
  assert_eq "$ev" "0" "#217(a): no run_launch row" || return 1
  assert_eq "$removed" "0" "#217(a): agent-in-progress not removed (winner owns it)" || return 1
}

test_hc_b_only_own_claim_launches() {
  hc_env
  hc_claims "$(hostname -s):1"
  local out rc settle
  out=$(hc_launch 42); rc=$?
  settle=$(cat "$HC_BIN/sleep-calls.log")
  hc_cleanup
  assert_exit0 "$rc" "#217(b): launch exits 0" || return 1
  assert_contains "$out" "launched orchestrator" "#217(b): launched" || return 1
  assert_contains "$settle" "7" "#217(b): slept CLAIM_SETTLE_SECS (7) before arbitrating" || return 1
}

test_hc_old_foreign_claim_outside_window_ignored() {
  hc_env
  # other host's claim is 900s old (window 600s): not a rival; own claim wins
  hc_claims otherhost:900 "$(hostname -s):1"
  local out rc
  out=$(hc_launch 42); rc=$?
  hc_cleanup
  assert_exit0 "$rc" "#217: stale foreign claim does not block" || return 1
  assert_contains "$out" "launched orchestrator" "#217: launched despite stale foreign claim" || return 1
}

test_hc_c_force_skips_arbitration() {
  hc_env
  hc_claims otherhost:13 "$(hostname -s):10"
  local out rc settle
  out=$(hc_launch 42 --force); rc=$?
  settle=$(cat "$HC_BIN/sleep-calls.log")
  hc_cleanup
  assert_exit0 "$rc" "#217(c): --force exits 0" || return 1
  assert_contains "$out" "launched orchestrator" "#217(c): --force launches despite rival claim" || return 1
  assert_not_contains "$settle" "7" "#217(c): no settle wait under --force" || return 1
  assert_not_contains "$out" "lost claim" "#217(c): no refusal" || return 1
}

test_hc_label_guard_stays() {
  hc_env
  echo '[{"name":"agent-in-progress"}]' > "$HC_BIN/labels.json"
  hc_claims "$(hostname -s):1"
  local out rc
  out=$(hc_launch 42); rc=$?
  hc_cleanup
  assert_eq "$rc" "1" "#217: label guard still refuses (nothing running here)" || return 1
  assert_contains "$out" "carries agent-in-progress but nothing is running here" "#217: label guard message unchanged" || return 1
}

test_hc_gh_failure_fails_closed_and_is_recorded() {
  hc_env
  hc_claims "$(hostname -s):1"
  : > "$HC_BIN/comments-fail"   # gh issue view --json comments exits 1
  touch "$HC_PIPE/orch-42.stopped"
  local out rc stopped=gone ev=""
  out=$(hc_launch 42); rc=$?
  [ -f "$HC_PIPE/orch-42.stopped" ] && stopped=kept
  [ -f "$HC_HOME/logs/pipeline/events.jsonl" ] && ev=$(grep -i claim "$HC_HOME/logs/pipeline/events.jsonl")
  hc_cleanup
  assert_eq "$rc" "1" "#217(obs): comment read failure refuses the launch" || return 1
  assert_not_contains "$out" "launched orchestrator" "#217(obs): nothing launched on gh failure" || return 1
  assert_eq "$stopped" "kept" "#217(obs): tombstone untouched on gh failure" || return 1
  assert_contains "$ev" "42" "#217(obs): failure recorded in events.jsonl with the issue number" || return 1
  assert_not_contains "$ev" "token" "#217(obs): no secrets in the recorded event" || return 1
}

test_hc_supervisor_uses_shared_function() {
  local n_call n_inline n_orch n_lib
  n_call=$(grep -c 'claim_winner' "$SUP_HC")
  n_inline=$(grep -c 'sort_by(.createdAt) | first | .body' "$SUP_HC")
  n_orch=$(grep -c 'claim_winner' "$ORCH_HC")
  n_lib=$(grep -c '^claim_winner()' "$RS_HC/pipeline-lib.sh")
  assert_eq "$n_lib" "1" "#217: claim_winner defined once in pipeline-lib.sh" || return 1
  assert_eq "$n_inline" "0" "#217: no inline winner query left in supervisor.sh" || return 1
  [ "$n_call" -ge 1 ] || { fail "#217: supervisor.sh does not call claim_winner"; return 1; }
  [ "$n_orch" -ge 1 ] || { fail "#217: orchestrate.sh does not call claim_winner"; return 1; }
}

test_hc_skill_documents_force_takeover() {
  local s; s=$(grep -i -- '--force' "$RS_HC/SKILL.md")
  assert_contains "$s" "takeover" "#217: SKILL.md documents --force as the deliberate takeover" || return 1
}

run_test test_hc_claim_winner_earliest_in_window
run_test test_hc_claim_winner_ignores_non_claim_comments
run_test test_hc_a_other_host_earlier_claim_refuses
run_test test_hc_b_only_own_claim_launches
run_test test_hc_old_foreign_claim_outside_window_ignored
run_test test_hc_c_force_skips_arbitration
run_test test_hc_label_guard_stays
run_test test_hc_gh_failure_fails_closed_and_is_recorded
run_test test_hc_supervisor_uses_shared_function
run_test test_hc_skill_documents_force_takeover
