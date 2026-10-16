# Issue #304 — merge-gate waits after both PASSes go to the deployer's BLOCKED (Blocked on: dependency), not a
# markerless orchestrator hold. Expected values come from the ticket.
#   supervisor  dependency auto-retry reads bulleted / indented `Depends on #N` lines, every #N on the line
#               (#747 fixture yields 696 618); mid-sentence prose yields nothing
#   doc pins    orchestrator.md run-log comment, delivery-lead.md waiver definition, no new orchestrator marker
# Reuses the ar2_* helpers of test-supervisor-auto-retry.sh (same loading trick). Prefixed i304_.

HERE_I304=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_I304=$(cd "$HERE_I304/../../.." && pwd)
if ! declare -f ar2_fixture >/dev/null 2>&1; then
  eval "i304_real_$(declare -f run_test)"
  run_test() { :; }
  . "$HERE_I304/test-supervisor-auto-retry.sh"
  eval "$(declare -f i304_real_run_test | sed '1s/i304_real_run_test/run_test/')"
fi

I304_LINE747='- Depends on #696 for merging. Depends on #618 for merging (release train gate).'

# i304_dep <body> <state-696|77> ... : run one tick for held #42 (BLOCKED dependency) with the given body
i304_body() { printf '%s\n' "$1" > "$SQ_GH/gh-issue-body-42"; }

test_i304_bulleted_line_all_closed_relaunches() {
  ar2_fixture 'Blocked on: dependency — merge-gate #696 / #618 not merged'
  i304_body "$I304_LINE747"
  echo CLOSED > "$SQ_GH/gh-issue-state-696"; echo CLOSED > "$SQ_GH/gh-issue-state-618"
  ar2_tick
  local n calls; n=$(ar2_launches); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "1" "#304: bulleted #747 line, 696 and 618 closed -> relaunched" || return 1
  assert_contains "$calls" "auto-retry 1/3: dependency cleared" "#304: NOTE names the class" || return 1
}

test_i304_bulleted_line_checks_every_n_second_open_not_relaunched() {
  ar2_fixture 'Blocked on: dependency — merge-gate #696 / #618 not merged'
  i304_body "$I304_LINE747"
  echo CLOSED > "$SQ_GH/gh-issue-state-696"; echo OPEN > "$SQ_GH/gh-issue-state-618"
  ar2_tick
  local n calls; n=$(ar2_no_launch); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "0" "#304: 618 still open -> no relaunch" || return 1
  assert_contains "$calls" "issue view 696" "#304: first #N on the bulleted line was checked" || return 1
  assert_contains "$calls" "issue view 618" "#304: second #N on the same line was checked" || return 1
}

test_i304_star_bullet_relaunches() {
  ar2_fixture 'Blocked on: dependency — waits'
  i304_body $'Why\n* Depends on #77 for merging'
  echo CLOSED > "$SQ_GH/gh-issue-state-77"
  ar2_tick
  local n; n=$(ar2_launches)
  sq_cleanup
  assert_eq "$n" "1" "#304: '* Depends on #N' line is read" || return 1
}

test_i304_indented_line_relaunches() {
  ar2_fixture 'Blocked on: dependency — waits'
  i304_body $'Why\n   Depends on #77 for merging'
  echo CLOSED > "$SQ_GH/gh-issue-state-77"
  ar2_tick
  local n; n=$(ar2_launches)
  sq_cleanup
  assert_eq "$n" "1" "#304: whitespace-indented 'Depends on #N' line is read" || return 1
}

test_i304_bulleted_dependency_open_not_relaunched() {
  ar2_fixture 'Blocked on: dependency — waits'
  i304_body '- Depends on #77 for merging'
  echo OPEN > "$SQ_GH/gh-issue-state-77"
  ar2_tick
  local n calls; n=$(ar2_no_launch); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "0" "#304: bulleted dependency open -> no relaunch" || return 1
  assert_contains "$calls" "issue view 77" "#304: the bulleted #N was actually checked" || return 1
}

# negative fixture: "depends on" mid-sentence is not a dependency line; closed #77 must not trigger a relaunch
test_i304_prose_mid_sentence_yields_nothing() {
  ar2_fixture 'Blocked on: dependency — waits'
  i304_body $'Why\nThis ticket depends on #77 for merging, see the release notes.'
  echo CLOSED > "$SQ_GH/gh-issue-state-77"
  ar2_tick
  local n calls; n=$(ar2_no_launch); calls=$(gh_calls "$SQ_GH")
  sq_cleanup
  assert_eq "$n" "0" "#304: mid-sentence 'depends on' is not read" || return 1
  assert_not_contains "$calls" "issue view 77" "#304: mid-sentence #N never looked up" || return 1
}

test_i304_bullet_with_mid_sentence_depends_yields_nothing() {
  ar2_fixture 'Blocked on: dependency — waits'
  i304_body $'- Note: this depends on #77 eventually'
  echo CLOSED > "$SQ_GH/gh-issue-state-77"
  ar2_tick
  local n; n=$(ar2_no_launch)
  sq_cleanup
  assert_eq "$n" "0" "#304: bullet whose 'depends on' is not at the line start yields nothing" || return 1
}

# ---- doc pins ----
test_i304_orchestrator_no_merge_gate_hand_to_jp_reason() {
  local f="$ROOT_I304/agents/orchestrator.md"
  if grep -qE 'merge gate: Depends on|merge-gate wait ' "$f"; then
    fail "orchestrator.md: still names a merge-gate hand-to-jp reason/wait"; return 1
  fi
  if grep -n 'post-PASS hand to JP' "$f" | grep -qi 'merge-gate'; then
    fail "orchestrator.md: run-log comment still lists merge-gate wait"; return 1
  fi
}

test_i304_orchestrator_other_hand_to_jp_exits_unchanged() {
  local row
  row=$(grep -F 'One post-PASS hand-to-JP rule' "$ROOT_I304/agents/orchestrator.md" | head -1)
  assert_contains "$row" 'base is `main`' "#304: main-base promotion exit kept" || return 1
  assert_contains "$row" "unsupported project" "#304: unsupported project exit kept" || return 1
  assert_contains "$row" '"stage":"hand-to-jp","result":"fail"' "#304: log line kept" || return 1
}

test_i304_delivery_lead_defines_waiver() {
  local f="$ROOT_I304/agents/delivery-lead.md" txt
  txt=$(grep -iE 'merge.gate' "$f")
  assert_contains "$txt" "prose" "#304: waiver = move the Depends line to prose" || return 1
  assert_contains "$txt" "Depends on #N for merging" "#304: names the body line" || return 1
  assert_contains "$txt" "Resolves" "#304: decision carries Resolves:" || return 1
  assert_contains "$txt" "BLOCKED" "#304: Resolves points at the deployer's BLOCKED" || return 1
  assert_contains "$txt" "deployer" "#304: BLOCKED is the deployer's" || return 1
}

test_i304_no_new_orchestrator_marker() {
  if grep -q 'orchestrator\]' "$ROOT_I304/hooks/pipeline-markers.sh"; then
    fail "pipeline-markers.sh: an orchestrator marker was added (net new mechanisms must be 0)"; return 1
  fi
}

run_test test_i304_bulleted_line_all_closed_relaunches
run_test test_i304_bulleted_line_checks_every_n_second_open_not_relaunched
run_test test_i304_star_bullet_relaunches
run_test test_i304_indented_line_relaunches
run_test test_i304_bulleted_dependency_open_not_relaunched
run_test test_i304_prose_mid_sentence_yields_nothing
run_test test_i304_bullet_with_mid_sentence_depends_yields_nothing
run_test test_i304_orchestrator_no_merge_gate_hand_to_jp_reason
run_test test_i304_orchestrator_other_hand_to_jp_exits_unchanged
run_test test_i304_delivery_lead_defines_waiver
run_test test_i304_no_new_orchestrator_marker
