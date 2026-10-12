# #213 — run-state.sh / build-runs-json.py / reconcile-status.sh give two same-number tickets of two
# repos two independent rows, each with its own title, marker, milestone, closed and release; and the
# live-stage lookup matches on PIPELINE_REPO as well as PIPELINE_ISSUE.
#
#   AC5  report-status.sh --print / reconcile-status.sh with repo-1 #196 and repo-2 #196
#   AC6  derive_runs' stage column ignores a same-number stage process of another repo
# Files are hand-written under repo-keyed names (lib/runkey.sh). Expected values are hand-written below.
# Placeholder repos only. Bash 3.2 portable.

HERE_RK3=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE_RK3/lib/runkey.sh"
RS_RK3="$HERE_RK3/.."

rk3_print() { rk_env_run "$RS_RK3/report-status.sh" --print; }

# rk3_field <payload> <array> <alias> <field> -> value of the row for issue 196 with that repo alias, or NOROW / NOFIELD
rk3_field() {
  printf '%s' "$1" | jq -r --arg arr "$2" --arg a "$3" --arg f "$4" '
    [(.[$arr] // [])[] | select(.repo == $a and ((.issue|tostring) == "196"))]
    | if length == 0 then "NOROW" else (.[0] | if has($f) then (.[$f]|tostring) else "NOFIELD" end) end' 2>/dev/null || echo INVALID_JSON
}

test_rk3_payload_has_two_rows_with_their_own_title_marker_milestone() {
  rk_env
  rk_run_files "$RK_KA" "$RK_REPO_A" live 196 >/dev/null
  rk_run_files "$RK_KB" "$RK_REPO_B" live 196 >/dev/null
  printf 'Title A\n' > "$RK_PIPE/$RK_KA-196.title"; printf 'Title B\n' > "$RK_PIPE/$RK_KB-196.title"
  printf 'TESTS WRITTEN\n' > "$RK_PIPE/$RK_KA-196.marker"; printf 'IMPLEMENTED\n' > "$RK_PIPE/$RK_KB-196.marker"
  printf 'Phase A\n' > "$RK_PIPE/$RK_KA-196.milestone"; printf 'Phase B\n' > "$RK_PIPE/$RK_KB-196.milestone"
  local out n
  out=$(rk3_print)
  rk_cleanup
  n=$(printf '%s' "$out" | jq '[.runs[] | select((.issue|tostring)=="196")] | length' 2>/dev/null || echo 0)
  assert_eq "$n" "2" "#213 AC5: two runs[] rows for #196 (one per repo)" || return 1
  assert_eq "$(rk3_field "$out" runs alias-a title)" "Title A" "#213 AC5: repo-1 row's own title" || return 1
  assert_eq "$(rk3_field "$out" runs alias-b title)" "Title B" "#213 AC5: repo-2 row's own title" || return 1
  assert_eq "$(rk3_field "$out" runs alias-a marker)" "TESTS WRITTEN" "#213 AC5: repo-1 row's own marker" || return 1
  assert_eq "$(rk3_field "$out" runs alias-b marker)" "IMPLEMENTED" "#213 AC5: repo-2 row's own marker" || return 1
  assert_eq "$(rk3_field "$out" runs alias-a milestone)" "Phase A" "#213 AC5: repo-1 row's own milestone" || return 1
  assert_eq "$(rk3_field "$out" runs alias-b milestone)" "Phase B" "#213 AC5: repo-2 row's own milestone" || return 1
  assert_eq "$(rk3_field "$out" runs alias-a url)" "https://github.com/$RK_OWNER_A/issues/196" "#213 AC5: repo-1 url" || return 1
  assert_eq "$(rk3_field "$out" runs alias-b url)" "https://github.com/$RK_OWNER_B/issues/196" "#213 AC5: repo-2 url" || return 1
}

# reconcile-status.sh: repo-1 #196 open (marker + non-version milestone), repo-2 #196 closed in release v2.0.0.
test_rk3_reconcile_writes_each_repos_marker_milestone_closed_release_to_its_own_key() {
  rk_env
  local now; now=$(date -u +%FT%TZ)
  rk_run_files "$RK_KA" "$RK_REPO_A" live 196 >/dev/null
  rk_run_files "$RK_KB" "$RK_REPO_B" held 196 >/dev/null
  printf 'Title A\n' > "$RK_PIPE/$RK_KA-196.title"; printf 'Title B\n' > "$RK_PIPE/$RK_KB-196.title"
  rk_gh_set A comments-196 '[{"body":"**[test-writer] TESTS WRITTEN**","createdAt":"2026-01-01T00:00:00Z"}]'
  rk_gh_set A milestone-196 "Phase A"
  rk_gh_set B comments-196 '[{"body":"**[deployer] DEPLOYED**","createdAt":"2026-01-01T00:00:00Z"}]'
  rk_gh_set B state-196 CLOSED
  rk_gh_set B closed-at-196 "$now"
  rk_gh_set B milestone-196 "v2.0.0"
  rk_env_run "$RS_RK3/reconcile-status.sh" --force >/dev/null
  local a_marker a_ms a_closed b_closed b_release b_done a_release
  a_marker=$(head -n1 "$RK_PIPE/$RK_KA-196.marker" 2>/dev/null || echo ABSENT)
  a_ms=$(head -n1 "$RK_PIPE/$RK_KA-196.milestone" 2>/dev/null || echo ABSENT)
  a_closed=$(head -n1 "$RK_PIPE/$RK_KA-196.closed" 2>/dev/null || echo ABSENT)
  a_release=$(head -n1 "$RK_PIPE/$RK_KA-196.release" 2>/dev/null || echo ABSENT)
  b_closed=$(head -n1 "$RK_PIPE/$RK_KB-196.closed" 2>/dev/null || echo ABSENT)
  b_release=$(head -n1 "$RK_PIPE/$RK_KB-196.release" 2>/dev/null || echo ABSENT)
  b_done=ABSENT; [ -e "$RK_PIPE/$RK_KB-196.done" ] && b_done=present
  local out; out=$(rk3_print)
  rk_cleanup
  assert_eq "$a_marker" "TESTS WRITTEN" "#213 AC5: repo-1 marker from its own GitHub issue" || return 1
  assert_eq "$a_ms" "Phase A" "#213 AC5: repo-1 milestone" || return 1
  assert_eq "$a_closed" "ABSENT" "#213 AC5: repo-1 is not marked closed because repo-2's #196 is" || return 1
  assert_eq "$a_release" "ABSENT" "#213 AC5: repo-1 has no release" || return 1
  assert_eq "$b_closed" "$now" "#213 AC5: repo-2 closed = its closedAt" || return 1
  assert_eq "$b_release" "v2.0.0" "#213 AC5: repo-2 release" || return 1
  assert_eq "$b_done" "present" "#213 AC5: repo-2 run marked done" || return 1
  # payload: repo-1 stays in runs[] with its own fields; repo-2 is in completed[] with title + release
  assert_eq "$(rk3_field "$out" runs alias-a marker)" "TESTS WRITTEN" "#213 AC5: runs[] row of repo-1" || return 1
  assert_eq "$(rk3_field "$out" runs alias-a title)" "Title A" "#213 AC5: runs[] row title of repo-1" || return 1
  assert_eq "$(rk3_field "$out" runs alias-b title)" "NOROW" "#213 AC5: repo-2's #196 is no longer in runs[]" || return 1
  assert_eq "$(rk3_field "$out" completed alias-b title)" "Title B" "#213 AC5: completed[] row title of repo-2" || return 1
  assert_eq "$(rk3_field "$out" completed alias-b release)" "v2.0.0" "#213 AC5: completed[] release of repo-2" || return 1
  assert_eq "$(rk3_field "$out" completed alias-b closed_at)" "$now" "#213 AC5: completed[] closed_at of repo-2" || return 1
  assert_eq "$(rk3_field "$out" completed alias-a title)" "NOROW" "#213 AC5: repo-1's #196 is not in completed[]" || return 1
}

# --- AC6: live stage ---------------------------------------------------------------------------
# rk3_stage_proc <issue> <owner/repo> <agent> — a live process named `claude`, with PIPELINE_ISSUE /
# PIPELINE_REPO in its environment and `--agent <agent>` on its command line (what _rs_ps_lines reads).
rk3_stage_proc() {
  local p
  p=$( ( PIPELINE_ISSUE="$1" PIPELINE_REPO="$2" bash -c 'exec -a claude python3 -c "import time; time.sleep(300)" --agent "$1"' _ "$3" >/dev/null 2>&1 & echo $! ) )
  RK_PIDS="$RK_PIDS $p"
  sleep 0.3
}

rk3_derive_stage() {  # rk3_derive_stage <tsv-output-from-derive_runs> <repo checkout> -> stage column
  printf '%s\n' "$1" | awk -F'\t' -v r="$2" '$2 == r { print $8 }'
}

test_rk3_live_stage_is_the_stage_of_the_matching_repo_not_the_same_number_elsewhere() {
  rk_env
  rk_run_files "$RK_KA" "$RK_REPO_A" live 196 >/dev/null
  rk_run_files "$RK_KB" "$RK_REPO_B" live 196 >/dev/null
  rk3_stage_proc 196 "$RK_OWNER_A" test-writer
  local out
  out=$(rk_env_run bash -c '. "'"$RS_RK3"'/run-state.sh"; derive_runs')
  rk_cleanup
  assert_eq "$(rk3_derive_stage "$out" "$RK_REPO_A")" "test-writer" "#213 AC6: repo-1's row shows its own stage process" || return 1
  assert_eq "$(rk3_derive_stage "$out" "$RK_REPO_B")" "orchestrator" "#213 AC6: repo-2's row ignores repo-1's same-number stage process" || return 1
}

test_rk3_live_stage_other_direction() {
  rk_env
  rk_run_files "$RK_KA" "$RK_REPO_A" live 196 >/dev/null
  rk_run_files "$RK_KB" "$RK_REPO_B" live 196 >/dev/null
  rk3_stage_proc 196 "$RK_OWNER_B" code-reviewer
  local out
  out=$(rk_env_run bash -c '. "'"$RS_RK3"'/run-state.sh"; derive_runs')
  rk_cleanup
  assert_eq "$(rk3_derive_stage "$out" "$RK_REPO_B")" "code-reviewer" "#213 AC6: repo-2's row shows its own stage process" || return 1
  assert_eq "$(rk3_derive_stage "$out" "$RK_REPO_A")" "orchestrator" "#213 AC6: repo-1's row ignores repo-2's same-number stage process" || return 1
}

# derive_runs itself: one record per repo for a shared number, N decoded from the key's last '-'.
test_rk3_derive_runs_emits_one_record_per_repo_with_the_plain_issue_number() {
  rk_env
  rk_run_files "$RK_KA" "$RK_REPO_A" held 196 >/dev/null
  rk_run_files "$RK_KB" "$RK_REPO_B" done 196 >/dev/null
  rk_queue_entry "$RK_KA" "$RK_REPO_A" 12
  local out
  out=$(rk_env_run bash -c '. "'"$RS_RK3"'/run-state.sh"; derive_runs')
  rk_cleanup
  assert_eq "$(printf '%s\n' "$out" | awk -F'\t' '$1=="196" && $2=="'"$RK_REPO_A"'" {print $3}')" "held" "#213: repo-1 #196 record is held, issue field is the bare number" || return 1
  assert_eq "$(printf '%s\n' "$out" | awk -F'\t' '$1=="196" && $2=="'"$RK_REPO_B"'" {print $3}')" "done" "#213: repo-2 #196 record is done" || return 1
  assert_eq "$(printf '%s\n' "$out" | awk -F'\t' '$1=="12" {print $3}')" "queued" "#213: a repo-keyed queue entry yields a queued record for its number" || return 1
}

run_test test_rk3_payload_has_two_rows_with_their_own_title_marker_milestone
run_test test_rk3_reconcile_writes_each_repos_marker_milestone_closed_release_to_its_own_key
run_test test_rk3_live_stage_is_the_stage_of_the_matching_repo_not_the_same_number_elsewhere
run_test test_rk3_live_stage_other_direction
run_test test_rk3_derive_runs_emits_one_record_per_repo_with_the_plain_issue_number
