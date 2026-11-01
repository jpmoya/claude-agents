# claude-agents#560: the loop-cap resume and the orchestrator's decision ordering use issuecomment ids, not createdAt.
# Fixture = the Benjis-Plants/benjis-ops-tool#1841 comment list (ids real, createdAt skewed by GitHub on 2026-11-01).
HERE_LC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -f ar2_fixture >/dev/null 2>&1; then
  eval "lc_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_LC/test-supervisor-auto-retry.sh"
  eval "$(declare -f lc_real_run_test | sed '1s/lc_real_run_test/run_test/')"
fi

LC_IMPL=6555721102; LC_DEC1=6555753899; LC_NOTE_RESUMED=6555814550; LC_NOTE_OTHER=6555869514; LC_DEC2=6555957347

# lc_fixture — held loop-cap run #42; REST comments served WITH ids (the ar2 stub drops them), `issue comment` delegated.
lc_fixture() {
  sq_env open; sq_free_slots; ar2_install_gh
  mv "$SQ_GH/gh" "$SQ_GH/gh-ar2"
  cat > "$SQ_GH/gh" <<'GH_EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
case "$*" in
  "api repos/"*"/issues/42/comments"*)
    printf '%s\n' "$*" >> "$HERE/gh-calls.log"
    jq -c 'map({id: .id, body: .body, created_at: .createdAt, user: {login: "x"}})' "$HERE/lc-comments.json"; exit 0 ;;
  "issue comment"*)
    printf '%s\n' "$*" >> "$HERE/gh-calls.log"
    [ -f "$HERE/lc-comment-fail" ] && { echo "HTTP 500" >&2; exit 1; }
    exit 0 ;;
esac
exec "$HERE/gh-ar2" "$@"
GH_EOF
  chmod +x "$SQ_GH/gh"
  mk_held "$SQ_PIPE" 42 "$SQ_REPO"
  printf 'FAIL\n' > "$(rkp "$SQ_PIPE/orch-42.marker")"
  mkdir -p "$SQ_HOME/.claude/pipeline"
  printf '{"issue":42,"event":"validate","result":"fail","stage":"loop-cap","ts":"2026-01-01T00:00:00Z"}\n' > "$SQ_HOME/.claude/pipeline/runs.jsonl"
  : > "$SQ_PIPE/claude.calls"
}
lc_comments() { printf '%s' "$1" > "$SQ_GH/lc-comments.json"; }
lc_rehold() { mk_held "$SQ_PIPE" 42 "$SQ_REPO"; rm -f "$(rkp "$SQ_PIPE/orch-42.autoretry-check")"; : > "$SQ_PIPE/claude.calls"; }
lc_c() { jq -nc --argjson id "$1" --arg b "$2" --arg t "$3" '{id:$id, body:$b, createdAt:$t}'; }

# ---- AC3: replay of the #1841 list ----
test_lc_replay_1841_resumes_once_per_decision() {
  lc_fixture
  local impl dec1 noteR noteO dec2 n h calls
  impl=$(lc_c $LC_IMPL '**[fullstack-developer] IMPLEMENTED**' 2026-11-01T10:40:00Z)      # skewed later than the decisions
  dec1=$(lc_c $LC_DEC1 $'**[delivery-lead] DECISION**\nResolves: x' 2026-11-01T09:52:21Z)
  noteR=$(lc_c $LC_NOTE_RESUMED '**[supervisor] NOTE** loop-cap hold resumed: a delegated decision was posted after the stop' 2026-11-01T09:58:41Z)
  noteO=$(lc_c $LC_NOTE_OTHER '**[supervisor] NOTE** claim: Claude 2026-11-01T08:04:00Z' 2026-11-01T09:04:17Z)
  dec2=$(lc_c $LC_DEC2 $'**[delivery-lead] DECISION**\nResolves: y' 2026-11-01T09:48:37Z)   # createdAt EARLIER than the NOTE and IMPLEMENTED

  # 1) first decision (id above the IMPLEMENTED baseline) -> resumes once
  lc_comments "[$impl,$dec1]"; ar2_tick
  n=$(ar2_launches); calls=$(gh_calls "$SQ_GH")
  assert_eq "$n" "1" "decision 6555753899 -> one relaunch" || { sq_cleanup; return 1; }
  assert_contains "$calls" "loop-cap hold resumed" "resume NOTE posted" || { sq_cleanup; return 1; }

  # 2) refused -> new hold; list now carries the resumed NOTE; same decision must not resume again (skewed createdAt is later than the hold)
  lc_rehold; lc_comments "[$impl,$dec1,$noteR,$noteO]"; ar2_tick
  n=$(ar2_no_launch); h=$(ar2_held)
  assert_eq "$n" "0" "refused decision 6555753899 does not resume again" || { sq_cleanup; return 1; }
  assert_eq "$h" "present" "hold kept" || { sq_cleanup; return 1; }

  # 3) corrected decision with a higher id (but an earlier createdAt) -> resumes once
  lc_rehold; lc_comments "[$impl,$dec1,$noteR,$noteO,$dec2]"; ar2_tick
  n=$(ar2_launches); sq_cleanup
  assert_eq "$n" "1" "decision 6555957347 -> one relaunch" || return 1
}

# ---- AC4: lower id, later createdAt than the gate marker -> no resume ----
test_lc_lower_id_later_createdat_stays_held() {
  lc_fixture
  local gate dec n h
  gate=$(lc_c 200 '**[fullstack-developer] IMPLEMENTED**' 2020-01-01T00:00:00Z)
  dec=$(lc_c 100 $'**[delivery-lead] DECISION**\nResolves: x' 2099-01-01T00:00:00Z)
  lc_comments "[$dec,$gate]"; ar2_tick
  n=$(ar2_no_launch); h=$(ar2_held); sq_cleanup
  assert_eq "$n" "0" "decision id 100 < gate id 200 -> no relaunch despite later createdAt" || return 1
  assert_eq "$h" "present" "still held" || return 1
}

# ---- hold mtime no longer matters: higher id, createdAt long before the hold -> resumes ----
test_lc_higher_id_older_createdat_resumes() {
  lc_fixture
  local gate dec n
  gate=$(lc_c 100 '**[fullstack-developer] IMPLEMENTED**' 2026-01-01T00:00:00Z)
  dec=$(lc_c 200 $'**[delivery-lead] JP CONFIRMED**\nResolves: x' 2020-01-01T00:00:00Z)
  lc_comments "[$gate,$dec]"; ar2_tick
  n=$(ar2_launches); sq_cleanup
  assert_eq "$n" "1" "id 200 > gate 100 -> relaunch although createdAt predates the hold" || return 1
}

# ---- AC1: baseline is the newest "loop-cap hold resumed" NOTE when one exists (even over a newer other marker's older id) ----
test_lc_resumed_note_is_baseline_over_gate_marker() {
  lc_fixture
  local gate dec note n
  gate=$(lc_c 100 '**[fullstack-developer] IMPLEMENTED**' 2026-01-01T00:00:00Z)
  dec=$(lc_c 150 $'**[project-manager] DECISION**\nResolves: x' 2099-01-01T00:00:00Z)       # legacy spelling, above gate, below the resumed NOTE
  note=$(lc_c 160 '**[supervisor] NOTE** loop-cap hold resumed: a delegated decision was posted after the stop' 2026-10-01T00:00:00Z)
  lc_comments "[$gate,$dec,$note]"; ar2_tick
  n=$(ar2_no_launch); sq_cleanup
  assert_eq "$n" "0" "decision already consumed by the resumed NOTE -> no relaunch" || return 1
}

# ---- AC1 baseline: other supervisor NOTEs and delivery-lead markers are not the gate marker ----
test_lc_baseline_ignores_supervisor_notes_and_delivery_lead() {
  lc_fixture
  local gate note dec n
  gate=$(lc_c 100 '**[fullstack-developer] IMPLEMENTED**' 2026-01-01T00:00:00Z)
  note=$(lc_c 300 '**[supervisor] NOTE** claim: Claude 2026-11-01T08:00:00Z' 2026-11-01T08:00:00Z)
  dec=$(lc_c 200 $'**[delivery-lead] DECISION**\nResolves: x' 2026-11-01T08:01:00Z)       # above the gate, below an unrelated NOTE
  lc_comments "[$gate,$dec,$note]"; ar2_tick
  n=$(ar2_launches); sq_cleanup
  assert_eq "$n" "1" "a claim NOTE (id 300) is not a baseline -> decision 200 resumes" || return 1
}

# ---- Observability: NOTE post fails -> logged, hold kept, no relaunch ----
test_lc_note_post_failure_stays_held_and_logs() {
  lc_fixture
  local gate dec n h log
  gate=$(lc_c 100 '**[fullstack-developer] IMPLEMENTED**' 2026-01-01T00:00:00Z)
  dec=$(lc_c 200 $'**[delivery-lead] DECISION**\nResolves: x' 2026-01-02T00:00:00Z)
  lc_comments "[$gate,$dec]"; : > "$SQ_GH/lc-comment-fail"; ar2_tick
  n=$(ar2_no_launch); h=$(ar2_held); log=$(sq_log); sq_cleanup
  assert_eq "$n" "0" "NOTE post failed -> no relaunch" || return 1
  assert_eq "$h" "present" "hold file kept" || return 1
  assert_contains "$log" "NOTE post failed, staying held" "failure branch logged" || return 1
}

# ---- AC5 / AC2: source text ----
test_lc_supervisor_has_no_mtime_compare_and_states_invariant() {
  local sup="$HERE_LC/../supervisor.sh" blk
  blk=$(sed -n '/if \[ "\$is_lc" -eq 1 \]; then/,/^    continue$/p' "$sup")
  assert_contains "$blk" "id" "block present" || return 1
  case "$blk" in *held_at*|*fromdateiso8601*|*file_mtime*) echo "FAIL: resume block still compares createdAt with the hold mtime"; return 1 ;; esac
  assert_contains "$blk" "issuecomment id" "comment states the id-ordering invariant" || return 1
}
test_lc_issue_info_rest_keeps_comment_ids() {
  local d out; d=$(mktemp -d); mkdir -p "$d/bin"
  cat > "$d/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"/comments"*) echo '[{"id":6555753899,"body":"b","created_at":"2026-11-01T09:52:21Z","user":{"login":"x"}}]' ;;
  *) echo '{"state":"open","body":"","updated_at":"2026-11-01T00:00:00Z","user":{"login":"x"}}' ;;
esac
EOF
  chmod +x "$d/bin/gh"
  out=$( export PATH="$d/bin:$PATH"; slog() { :; }; repo_slug() { echo o/r; }; gh_err_line() { :; }
    eval "$(sed -n '/^issue_info_rest() {/,/^}/p' "$HERE_LC/../supervisor.sh")"; issue_info_rest "$d" 1 | jq -r '.comments[0].id' )
  rm -rf "$d"
  assert_eq "$out" "6555753899" "issue_info_rest exposes the numeric comment id" || return 1
}
test_lc_orchestrator_orders_by_comment_id() {
  local f="$HERE_LC/../../../agents/orchestrator.md" row gate
  row=$(grep -n '^| blocked stage / test-writer / fix cycle (resume on a delegated decision)' "$f" | head -1)
  assert_contains "$row" "issuecomment id" "line ~229 orders by issuecomment id" || return 1
  case "$row" in *"it is dated after that comment"*) echo "FAIL: :229 still says dated after"; return 1 ;; esac
  gate=$(grep -n 'A decision comment that is' "$f" | head -1)
  assert_contains "$gate" "issuecomment id" "line ~125 orders by issuecomment id" || return 1
  case "$gate" in *"older than the gate marker"*) echo "FAIL: :125 still says older than the gate marker"; return 1 ;; esac
}

run_test test_lc_replay_1841_resumes_once_per_decision
run_test test_lc_lower_id_later_createdat_stays_held
run_test test_lc_higher_id_older_createdat_resumes
run_test test_lc_resumed_note_is_baseline_over_gate_marker
run_test test_lc_baseline_ignores_supervisor_notes_and_delivery_lead
run_test test_lc_note_post_failure_stays_held_and_logs
run_test test_lc_supervisor_has_no_mtime_compare_and_states_invariant
run_test test_lc_issue_info_rest_keeps_comment_ids
run_test test_lc_orchestrator_orders_by_comment_id
