# Issue #131 — the deployer is released only when a `[test-reviewer] TESTS APPROVED` names the Commit: of the latest
# `[test-writer] TESTS WRITTEN` (full lane). Time-based gates are wrong: the commit is the key.
#
#   AC1  da_ac1_*   routing row + validation row both require the commit-pinned approval; TESTS FAIL / older commit / none do not satisfy
#   AC2  da_ac2_*   approval missing after code-review PASS -> only existing routes (poll running reviewer; dispatch test-reviewer
#                   pre-implementation on that commit; TESTS FAIL -> existing row); no new timer/counter/state file/hook
#   AC3  da_ac3_*   the TESTS WRITTEN row no longer forbids reviewing an amended commit while a reviewer runs on the older one
#   AC4  da_ac4_*   deployer prompt names the TESTS APPROVED URL; deployer.md wording aligned, no marker check of its own
#   AC5  da_ac5_*   characterisation (pass before and after): parallel build, fast lane, post-merge mode, first-dispatch row
#   AC6  da_ac6_*   prose that restates the gate agrees with the rows
#   AC7  da_ac7_*   marker-trail replay (scheduler#1030, benjis-quoting-tool#531) through the executable gate
#
# EXECUTABLE-GATE CONTRACT (ticket AC7 says "a test replays the trail and shows the rows do not release the deployer";
# prose rows cannot be executed, so — like the "**Gate marker**" snippet — the rows must point at a bash block):
#   orchestrator.md has a paragraph starting `**Test approval gate**` followed by one ```bash block. `<N>` is the issue
#   number. The block may call only `gh issue view <N> --json comments [--jq <expr>]` (comments carry body, createdAt, url)
#   and standard tools. It prints a last non-empty line that is exactly `APPROVED` or `NOT APPROVED`.
#   APPROVED iff: the latest comment whose FIRST LINE is exactly `**[test-writer] TESTS WRITTEN**` has a `Commit: <sha>`
#   line, and some comment whose FIRST LINE is exactly `**[test-reviewer] TESTS APPROVED**` has that full sha in its body,
#   and no `**[test-reviewer] TESTS FAIL...` comment is newer than that approval. An approval posted BEFORE
#   `IMPLEMENTED` counts (the review runs in parallel with the build) — position relative to IMPLEMENTED is irrelevant.
#
# Expected values hand-written from the ticket. Helpers/vars prefixed da_ / DA_.

HERE_DA=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DA=$(cd "$HERE_DA/../../.." && pwd)
ORCH_DA="$ROOT_DA/agents/orchestrator.md"
DEPL_DA="$ROOT_DA/agents/deployer.md"

DA_SHA_OLD=1adfee42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # scheduler#1030 first TESTS WRITTEN (40 hex-ish chars)
DA_SHA_NEW=9929cb87bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb   # scheduler#1030 amended TESTS WRITTEN
DA_W_OLD=$'**[test-writer] TESTS WRITTEN**\nBranch: issue-1030-x\nCommit: '"$DA_SHA_OLD"
DA_W_NEW=$'**[test-writer] TESTS WRITTEN**\nBranch: issue-1030-x\nCommit: '"$DA_SHA_NEW"
DA_A_OLD=$'**[test-reviewer] TESTS APPROVED**\nReviewed commit: '"$DA_SHA_OLD"
DA_A_NEW=$'**[test-reviewer] TESTS APPROVED**\nReviewed commit: '"$DA_SHA_NEW"
DA_F_NEW=$'**[test-reviewer] TESTS FAIL: 2 findings**\nReviewed commit: '"$DA_SHA_NEW"
DA_TD='**[fullstack-developer] TEST DEFECT**'
DA_IMPL='**[fullstack-developer] IMPLEMENTED**'
DA_CR='**[code-reviewer] PASS**'

da_row() {  # da_row <fixed-string-needle> — every orchestrator.md table row (line starting "| ") containing the needle
  grep -F -- "$1" "$ORCH_DA" | grep '^| '
}
da_routing_row()    { grep '^| ' "$ORCH_DA" | grep -F '`[code-reviewer] PASS` **and**' | grep -F 'Dispatch the deployer'; }
da_validation_row() { grep '^| deployer |' "$ORCH_DA"; }
da_written_row()    { grep '^| `\[test-writer\] TESTS WRITTEN` |' "$ORCH_DA"; }

# da_gate <body>... — runs the executable gate against a thread (oldest -> newest); prints last non-empty line
da_gate() {
  local block arr='[]' b i=0 f
  block=$(awk '/^\*\*Test approval gate\*\*/ {on=1; next} on && /^```bash/ {inb=1; next} on && inb && /^```/ {exit} on && inb {print}' "$ORCH_DA" | sed 's/<N>/42/g')
  [ -n "$block" ] || { echo "NO-SNIPPET"; return 0; }
  for b in "$@"; do
    i=$((i + 1))
    arr=$(printf '%s' "$arr" | jq --arg b "$b" --arg t "$(printf '2026-10-01T07:%02d:00Z' "$i")" --arg u "https://example.test/c/$i" '. + [{body: $b, createdAt: $t, url: $u}]')
  done
  f=$(mktemp)
  printf '{"comments":%s}' "$arr" > "$f"
  ( gh() {  # only `gh issue view N --json comments [--jq EXPR]`
      local prev="" expr="" a
      for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
      if [ -n "$expr" ]; then jq -r "$expr" "$f"; else cat "$f"; fi
    }
    eval "$block" 2>/dev/null | grep -v '^$' | tail -1 )
  rm -f "$f"
}

# ------------------------------------------------------------------ AC1

test_da_ac1_routing_row_requires_commit_pinned_approval() {
  local r; r=$(da_routing_row)
  assert_contains "$r" 'TESTS APPROVED' "AC1: routing row names TESTS APPROVED" || return 1
  assert_contains "$r" 'Commit:' "AC1: routing row pins to the Commit: of the latest TESTS WRITTEN" || return 1
}

test_da_ac1_validation_row_requires_commit_pinned_approval() {
  local r; r=$(da_validation_row)
  assert_contains "$r" 'TESTS APPROVED' "AC1: validation row names TESTS APPROVED" || return 1
  assert_contains "$r" 'Commit:' "AC1: validation row pins to the Commit: of the latest TESTS WRITTEN" || return 1
}

test_da_ac1_older_commit_fail_or_no_verdict_do_not_satisfy() {
  local r; r=$(da_routing_row)
  assert_contains "$r" 'TESTS FAIL' "AC1: routing row says TESTS FAIL does not satisfy" || return 1
  case "$r" in *"older commit"*|*"older \`TESTS WRITTEN\`"*|*"another commit"*|*"not the latest"*) ;;
    *) fail "AC1: routing row must say an approval of an older commit does not satisfy"; return 1 ;; esac
}

# ------------------------------------------------------------------ AC2

test_da_ac2_missing_approval_uses_only_existing_routes() {
  local r; r=$(da_routing_row)
  assert_contains "$r" 'poll' "AC2: still-running pre-implementation reviewer is polled" || return 1
  assert_contains "$r" 'pre-implementation' "AC2: no reviewer + no verdict -> test-reviewer in pre-implementation mode" || return 1
  assert_contains "$r" 'reviewer cap' "AC2: poll under the existing reviewer cap" || return 1
}

# ------------------------------------------------------------------ AC3

test_da_ac3_tests_written_row_reviews_a_commit_with_no_verdict() {
  local r; r=$(da_written_row)
  [ -n "$r" ] || { fail "AC3: TESTS WRITTEN row not found"; return 1; }
  case "$r" in *"no verdict"*|*"has no verdict"*|*"without a verdict"*) ;;
    *) fail "AC3: TESTS WRITTEN row must say a commit with no verdict gets its own review once the running reviewer (older commit) has finished"; return 1 ;; esac
  case "$r" in *"older commit"*) ;; *) fail "AC3: row must mention the reviewer running on the older commit"; return 1 ;; esac
}

# ------------------------------------------------------------------ AC4

test_da_ac4_deployer_prompt_names_the_approval_url() {
  local t; t=$(grep -nE 'deployer' "$ORCH_DA" | grep -F 'TESTS APPROVED' | grep -iE 'url|link' || true)
  [ -n "$t" ] || { fail "AC4: no orchestrator.md line puts the TESTS APPROVED comment URL in the deployer prompt"; return 1; }
}

test_da_ac4_deployer_md_input_wording_names_the_test_approval() {
  local l; l=$(grep -n 'Validate inputs' "$DEPL_DA")
  assert_contains "$l" 'TESTS APPROVED' "AC4: deployer.md inputs line names the TESTS APPROVED confirmation" || return 1
}

test_da_ac4_deployer_md_has_no_marker_check_of_its_own() {
  local d; d=$(cd "$ROOT_DA" && git diff "$(git merge-base HEAD origin/main)" -- agents/deployer.md | grep '^+' | grep -v '^+++' | grep -iE 'gh issue view|jq|--json|latest .*TESTS WRITTEN' || true)
  assert_eq "$d" "" "AC4: deployer.md must not gain its own marker check" || return 1
  # and the wording change must exist (this test fails until deployer.md is touched)
  local n; n=$(cd "$ROOT_DA" && git diff --name-only "$(git merge-base HEAD origin/main)" -- agents/deployer.md)
  assert_eq "$n" "agents/deployer.md" "AC4: deployer.md wording aligned" || return 1
}

# ------------------------------------------------------------------ AC5 (characterisation)

test_da_ac5_developer_still_starts_in_parallel_on_tests_written() {
  local r; r=$(da_written_row)
  assert_contains "$r" 'dispatch **both** in parallel' "AC5: parallel dispatch kept" || return 1
  assert_contains "$r" 'no longer gates the build' "AC5: review does not gate the build" || return 1
}

test_da_ac5_first_dispatch_row_does_not_require_approval() {
  local r; r=$(grep '^| fullstack-developer (first dispatch, full lane) |' "$ORCH_DA")
  assert_contains "$r" '`TESTS APPROVED` is not required' "AC5: developer first-dispatch unchanged" || return 1
}

test_da_ac5_postmerge_route_to_deployer_unchanged() {
  local r; r=$(grep -F 'has `state` `MERGED`' "$ORCH_DA" | grep '^| ' | head -1)
  assert_contains "$r" 'The' "AC5: post-merge row present" || return 1
  assert_contains "$r" 'post-merge' "AC5: post-merge mode kept" || return 1
}

# ------------------------------------------------------------------ AC6

test_da_ac6_prose_restating_the_gate_agrees_with_the_rows() {
  local a b
  a=$(grep -F 'When both reviewers PASS, dispatch the deployer' "$ORCH_DA")
  b=$(grep -F 'The only exits are:' "$ORCH_DA")
  assert_contains "$a" 'TESTS APPROVED' "AC6: hard-limit bullet 'both reviewers PASS' names the test approval" || return 1
  assert_contains "$b" 'TESTS APPROVED' "AC6: 'never skip a stage' bullet names the test approval" || return 1
}

test_da_ac6_one_statement_of_the_rule() {
  # the unqualified old wording ("[test-reviewer] PASS or no narrow review ... since the latest IMPLEMENTED" as the whole gate) is gone
  local r; r=$(da_routing_row)
  assert_not_contains "$r" 'all since the latest IMPLEMENTED' "AC6: old since-IMPLEMENTED variant removed from the routing row" || return 1
}

# ------------------------------------------------------------------ AC7 — marker-trail replays

test_da_ac7_rows_point_at_the_executable_gate() {
  assert_contains "$(da_routing_row)" 'Test approval gate' "AC7: routing row points at the gate block" || return 1
  assert_contains "$(da_validation_row)" 'Test approval gate' "AC7: validation row points at the gate block" || return 1
}

test_da_ac7_scheduler_1030_trail_without_verdict_is_not_released() {
  local g; g=$(da_gate "$DA_W_OLD" "$DA_TD" "$DA_W_NEW" "$DA_IMPL" "$DA_CR")
  assert_eq "$g" "NOT APPROVED" "AC7: 1030 trail, no test verdict" || return 1
}

test_da_ac7_scheduler_1030_trail_with_approval_of_old_commit_is_not_released() {
  # the approval for 1adfee42 lands AFTER the new TESTS WRITTEN (the verdict was posted late) — time-based gate would pass
  local g; g=$(da_gate "$DA_W_OLD" "$DA_TD" "$DA_W_NEW" "$DA_IMPL" "$DA_CR" "$DA_A_OLD")
  assert_eq "$g" "NOT APPROVED" "AC7: approval names 1adfee42, latest commit is 9929cb87" || return 1
}

test_da_ac7_quoting_tool_531_late_tests_fail_is_not_released() {
  local g; g=$(da_gate "$DA_W_NEW" "$DA_CR" "$DA_F_NEW")
  assert_eq "$g" "NOT APPROVED" "AC7: 531 trail, TESTS FAIL as the only verdict" || return 1
}

test_da_ac7_approval_of_the_latest_commit_releases_even_before_implemented() {
  # parallel review landed before IMPLEMENTED: position vs IMPLEMENTED is irrelevant, the commit is the key
  local g; g=$(da_gate "$DA_W_OLD" "$DA_TD" "$DA_W_NEW" "$DA_A_NEW" "$DA_IMPL" "$DA_CR")
  assert_eq "$g" "APPROVED" "AC7: approval names 9929cb87" || return 1
}

test_da_ac7_approval_of_latest_commit_after_code_review_releases() {
  local g; g=$(da_gate "$DA_W_NEW" "$DA_IMPL" "$DA_CR" "$DA_A_NEW")
  assert_eq "$g" "APPROVED" "AC7: approval for the latest commit posted last" || return 1
}

test_da_ac7_tests_fail_after_the_approval_is_not_released() {
  local g; g=$(da_gate "$DA_W_NEW" "$DA_A_NEW" "$DA_F_NEW" "$DA_IMPL" "$DA_CR")
  assert_eq "$g" "NOT APPROVED" "AC7: newer TESTS FAIL supersedes approval" || return 1
}

test_da_ac7_non_marker_comment_quoting_the_sha_is_not_an_approval() {
  local g; g=$(da_gate "$DA_W_NEW" "$DA_IMPL" "$DA_CR" $'**[test-reviewer] NOTE**\nStill reviewing '"$DA_SHA_NEW")
  assert_eq "$g" "NOT APPROVED" "AC7: only a first-line-exact TESTS APPROVED counts" || return 1
}

run_test test_da_ac1_routing_row_requires_commit_pinned_approval
run_test test_da_ac1_validation_row_requires_commit_pinned_approval
run_test test_da_ac1_older_commit_fail_or_no_verdict_do_not_satisfy
run_test test_da_ac2_missing_approval_uses_only_existing_routes
run_test test_da_ac3_tests_written_row_reviews_a_commit_with_no_verdict
run_test test_da_ac4_deployer_prompt_names_the_approval_url
run_test test_da_ac4_deployer_md_input_wording_names_the_test_approval
run_test test_da_ac4_deployer_md_has_no_marker_check_of_its_own
run_test test_da_ac5_developer_still_starts_in_parallel_on_tests_written
run_test test_da_ac5_first_dispatch_row_does_not_require_approval
run_test test_da_ac5_postmerge_route_to_deployer_unchanged
run_test test_da_ac6_prose_restating_the_gate_agrees_with_the_rows
run_test test_da_ac6_one_statement_of_the_rule
run_test test_da_ac7_rows_point_at_the_executable_gate
run_test test_da_ac7_scheduler_1030_trail_without_verdict_is_not_released
run_test test_da_ac7_scheduler_1030_trail_with_approval_of_old_commit_is_not_released
run_test test_da_ac7_quoting_tool_531_late_tests_fail_is_not_released
run_test test_da_ac7_approval_of_the_latest_commit_releases_even_before_implemented
run_test test_da_ac7_approval_of_latest_commit_after_code_review_releases
run_test test_da_ac7_tests_fail_after_the_approval_is_not_released
run_test test_da_ac7_non_marker_comment_quoting_the_sha_is_not_an_approval
