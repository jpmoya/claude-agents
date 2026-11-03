# Issue #566 (code path) — goal_fb_adopt_blockers: the SUPERVISOR adds user-feedback to a goal-less, already-agent-go blocker of an
# in-scope feedback ticket. No LLM. Sources the dg_*/dgf_* sandbox of test-goal-deliver.sh / test-goal-feedback.sh (sorted earlier).
# Fixture (project-a): feedback goal active. 301 = in-scope feedback ticket (open, user-feedback). 303 = in-scope too.
# Blocker candidates are created per test: 310 (agent-go, no user-feedback), etc. Fake gh = the REST fake; the code adds
# the label with gh api POST .../labels (counted in writes.log).

A=example-owner_project-a

dga_setup() {
  dgf_setup
  DG_GOAL_ID=$DGF_ID; dg_goal 501 "$DGF_SPEC" host-a active
}

# dga_ticket <n> <body> <label>...   (open ticket; labels added)
dga_ticket() {
  local n=$1 body=$2; shift 2
  dg_issue $A "$n" open
  local f="$DG_ST/issues/$A/$n.json" l
  jq -c --arg b "$body" '.body = $b' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  for l in "$@"; do dgf_label "$n" "$l"; done
}

dga_run() { dg_lib "goal_fb_adopt_blockers"; }
dga_has() { dg_has_label "$DG_ST/issues/$A/$1.json" "$2"; }
dga_edits() { grep -c "^POST repos/.*/issues/[0-9]*/labels" "$DG_BIN/writes.log" | tr -d ' '; }

test_dga_adopts_qualifying_blocker() {
  dga_setup
  local rc=0
  dga_ticket 311 "Depends on #310 for the schema" user-feedback
  dga_ticket 310 "the blocker" agent-go
  dga_run
  assert_eq "$DG_RC" "0" "exits 0 ($DG_ERR)" || rc=1
  assert_eq "$(printf '%s' "$DG_OUT" | tail -1)" "1" "one adoption reported" || rc=1
  dga_has 310 user-feedback || { fail "310 should carry user-feedback"; rc=1; }
  assert_contains "$DG_ERR" "[adopt] #310 adopted into the feedback goal: blocker of #311" "adoption logged" || rc=1
  assert_eq "$(grep -c 'agent-go' "$DG_BIN/writes.log")" "0" "no agent-go write" || rc=1
  dg_teardown; return $rc
}

test_dga_adopts_via_blocked_comment_and_merge_gate() {
  dga_setup
  local rc=0
  dga_ticket 311 "merge-gate: #320 lands first (PR #99)" user-feedback
  dga_ticket 312 "no dependency line" user-feedback
  dga_ticket 320 "gate" agent-go
  dga_ticket 321 "named in a BLOCKED comment" agent-go
  dg_comment $A 312 $'**[delivery-lead] BLOCKED**\nBlocked on: dependency — #321 waiting to merge'
  dga_run
  dga_has 320 user-feedback || { fail "320 (merge-gate) should be adopted"; rc=1; }
  dga_has 321 user-feedback || { fail "321 (BLOCKED comment) should be adopted"; rc=1; }
  dg_teardown; return $rc
}

test_dga_no_adoption_without_agent_go() {
  dga_setup
  local rc=0
  dga_ticket 311 "Depends on #310" user-feedback
  dga_ticket 310 "no go yet" agent-proposed
  dga_run
  assert_eq "$(dga_edits)" "0" "no label edit" || rc=1
  dga_has 310 user-feedback && { fail "310 must not be adopted"; rc=1; }
  dg_teardown; return $rc
}

test_dga_no_adoption_when_another_live_goal_covers_it() {
  dga_setup
  local rc=0
  dga_ticket 311 "Depends on #101" user-feedback
  dgf_label 101 agent-go   # 101 is in milestone 12; a live milestone-12 goal covers it
  DG_GOAL_ID=$DG_ID_MS; dg_goal 502 "$DG_SPEC_MS" host-a active
  dga_run
  assert_eq "$(dga_edits)" "0" "covered ticket untouched" || rc=1
  dg_teardown; return $rc
}

test_dga_cap_five_per_tick() {
  dga_setup
  local rc=0 n
  dga_ticket 311 "Depends on #330" user-feedback
  dga_ticket 312 "Depends on #331" user-feedback
  dga_ticket 313 "Depends on #332" user-feedback
  dga_ticket 314 "Depends on #333" user-feedback
  dga_ticket 315 "Depends on #334" user-feedback
  dga_ticket 316 "Depends on #335" user-feedback
  dga_ticket 317 "Depends on #336" user-feedback
  for n in 330 331 332 333 334 335 336; do dga_ticket $n "blocker" agent-go; done
  dga_run
  assert_eq "$(dga_edits)" "5" "exactly 5 adoptions" || rc=1
  assert_eq "$(printf '%s' "$DG_OUT" | tail -1)" "5" "count printed" || rc=1
  dg_teardown; return $rc
}

test_dga_idempotent() {
  dga_setup
  local rc=0
  dga_ticket 311 "Depends on #310" user-feedback
  dga_ticket 310 "blocker" agent-go
  dga_run; dga_run
  assert_eq "$(dga_edits)" "1" "second pass adds nothing (310 is already in scope)" || rc=1
  assert_eq "$(printf '%s' "$DG_OUT" | tail -1)" "0" "second pass reports 0" || rc=1
  dg_teardown; return $rc
}

test_dga_refuses_non_dependency_and_held_tickets() {
  dga_setup
  local rc=0
  dga_ticket 311 $'Depends on owner/other#310 and mentions #311 and see #312\nRelated: #313' user-feedback
  dga_ticket 310 "cross-repo ref number" agent-go
  dga_ticket 312 "only mentioned, not a dependency" agent-go
  dga_ticket 313 "Related line only" agent-go
  dga_ticket 314 "Depends on #315" user-feedback
  dga_ticket 315 "held by JP" agent-go agent-stop
  dga_run
  assert_eq "$(dga_edits)" "0" "no non-dependency or held ticket adopted" || rc=1
  dg_teardown; return $rc
}

test_dga_first_ref_only_and_pr_numbers_ignored() {
  dga_setup
  local rc=0
  dga_ticket 311 "Depends on #310 (PR #316), then #312" user-feedback
  dga_ticket 310 "first ref" agent-go
  dga_ticket 312 "second ref on the line: not adopted" agent-go
  dg_issue $A 316 open "" pr
  dga_run
  dga_has 310 user-feedback || { fail "310 adopted"; rc=1; }
  dga_has 312 user-feedback && { fail "312 (second ref) must not be adopted"; rc=1; }
  assert_eq "$(dga_edits)" "1" "one edit" || rc=1
  dg_teardown; return $rc
}

test_dga_skips_business_intelligence_repo() {
  assert_contains "$(grep -n '_goal_is_bi "$repo" && continue' "$DG_SKILL/goal-lib.sh")" "_goal_is_bi" "BI repo skipped in goal_fb_adopt_blockers" || return 1
  grep -q "GH_CLASS=normal goal_fb_adopt_blockers" "$DG_SKILL/supervisor.sh" || { fail "supervisor calls it"; return 1; }; : || return 1
  assert_contains "$(cat "$DG_SKILL/SKILL.md")" "goal_fb_adopt_blockers" "SKILL.md names it" || return 1
}

test_dga_probe_strings_not_adopted() {
  dga_setup
  local rc=0 n
  dga_ticket 311 "Depends on nothing. Related: #340" user-feedback
  dga_ticket 312 "Blocked by: none (see #341)" user-feedback
  dga_ticket 313 "Depends on owner/repo #342" user-feedback
  dga_ticket 314 "Depends on PR #343" user-feedback
  dga_ticket 315 "Depends on Benjis-Plants/other#344" user-feedback
  for n in 340 341 342 343 344; do dga_ticket $n "candidate" agent-go; done
  dga_run
  assert_eq "$(dga_edits)" "0" "prose / cross-repo / PR-prefixed refs adopt nothing" || rc=1
  dg_teardown; return $rc
}

test_dga_blocked_comment_reads_only_blocked_on_line_with_slug_guard() {
  dga_setup
  local rc=0
  dga_ticket 311 "plain" user-feedback
  dga_ticket 312 "plain" user-feedback
  dga_ticket 350 "x" agent-go
  dga_ticket 351 "x" agent-go
  dga_ticket 352 "x" agent-go
  dg_comment $A 311 $'**[deployer] BLOCKED**\nBlocked on: dependency — Benjis-Plants/other#350\nThis is unrelated to #351'
  dg_comment $A 312 $'**[delivery-lead] BLOCKED**\nBlocked on: dependency — #352 waiting\nsee also #351'
  dga_run
  dga_has 350 user-feedback && { fail "350 (cross-repo slug) adopted"; rc=1; }
  dga_has 351 user-feedback && { fail "351 (outside the Blocked on line) adopted"; rc=1; }
  dga_has 352 user-feedback || { fail "352 (Blocked on line) not adopted"; rc=1; }
  assert_eq "$(dga_edits)" "1" "one edit" || rc=1
  dg_teardown; return $rc
}

test_dga_depth_one_no_chaining() {
  dga_setup
  local rc=0
  dga_ticket 311 "Depends on #310" user-feedback
  dga_ticket 310 "Depends on #309" agent-go
  dga_ticket 309 "second level" agent-go
  dga_run; dga_run
  dga_has 310 user-feedback || { fail "310 adopted"; rc=1; }
  dga_has 309 user-feedback && { fail "309 chained from adopted 310"; rc=1; }
  assert_eq "$(dga_edits)" "1" "only the first level" || rc=1
  dg_teardown; return $rc
}

test_dga_comment_read_failure_adopts_nothing_for_that_ticket() {
  dga_setup
  local rc=0
  dga_ticket 311 "Depends on #310" user-feedback
  dga_ticket 310 "blocker" agent-go
  printf 'x' > "$DG_ST/comments/$A-311.json"   # not JSON: the comments read fails
  dga_run
  assert_eq "$(dga_edits)" "0" "unreadable comments: the body path does not adopt either" || rc=1
  dg_teardown; return $rc
}

test_dga_body_markdown_forms_adopt() {
  dga_setup
  local rc=0
  dga_ticket 311 '**Depends on:** #360' user-feedback
  dga_ticket 312 '- [ ] Depends on #361' user-feedback
  dga_ticket 313 '* [x] **merge-gate**: #362' user-feedback
  local n; for n in 360 361 362; do dga_ticket $n "blocker" agent-go; done
  dga_run
  for n in 360 361 362; do dga_has $n user-feedback || { fail "$n (markdown form) not adopted"; rc=1; }; done
  dga_has 360 adopted-blocker || { fail "adopted-blocker marker label missing"; rc=1; }
  dg_teardown; return $rc
}

test_dga_blocked_on_line_probes() {
  dga_setup
  local rc=0 n
  dga_ticket 311 plain user-feedback; dga_ticket 312 plain user-feedback; dga_ticket 313 plain user-feedback
  for n in 370 371 372; do dga_ticket $n "candidate" agent-go; done
  dg_comment $A 311 $'**[deployer] BLOCKED**\nBlocked on: dependency \xe2\x80\x94 none (see #370)'
  dg_comment $A 312 $'**[deployer] BLOCKED**\nBlocked on: dependency \xe2\x80\x94 owner/repo #371'
  dg_comment $A 313 $'**[deployer] BLOCKED**\nBlocked on: dependency \xe2\x80\x94 merge-gate dependency #372 (button consistency) is still OPEN'
  dga_run
  dga_has 370 user-feedback && { fail "370 (none, see #) adopted"; rc=1; }
  dga_has 371 user-feedback && { fail "371 (owner/repo #N) adopted"; rc=1; }
  dga_has 372 user-feedback || { fail "372 (merge-gate dependency #N) not adopted"; rc=1; }
  assert_eq "$(dga_edits)" "1" "one edit" || rc=1
  dg_teardown; return $rc
}

test_dga_adopted_label_blocks_scanning_across_hosts() {
  dga_setup
  local rc=0
  dga_ticket 311 "plain" user-feedback
  dga_ticket 310 "Depends on #309" user-feedback adopted-blocker   # adopted earlier, possibly by the other host
  dga_ticket 309 "second level" agent-go
  dga_run
  assert_eq "$(dga_edits)" "0" "a ticket carrying adopted-blocker is not scanned" || rc=1
  dg_teardown; return $rc
}

run_test test_dga_adopts_qualifying_blocker
run_test test_dga_adopts_via_blocked_comment_and_merge_gate
run_test test_dga_no_adoption_without_agent_go
run_test test_dga_no_adoption_when_another_live_goal_covers_it
run_test test_dga_cap_five_per_tick
run_test test_dga_idempotent
run_test test_dga_refuses_non_dependency_and_held_tickets
run_test test_dga_first_ref_only_and_pr_numbers_ignored
run_test test_dga_skips_business_intelligence_repo
run_test test_dga_probe_strings_not_adopted
run_test test_dga_blocked_comment_reads_only_blocked_on_line_with_slug_guard
run_test test_dga_depth_one_no_chaining
run_test test_dga_comment_read_failure_adopts_nothing_for_that_ticket
run_test test_dga_body_markdown_forms_adopt
run_test test_dga_blocked_on_line_probes
run_test test_dga_adopted_label_blocks_scanning_across_hosts
