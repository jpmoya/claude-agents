# Issue #136 (Phase 1 of #134), AC10 + AC18 (vocabulary part): `Blocked on: <class> — …` in the nine code-track
# agents, the single `block_classes` enum in hooks/pipeline-markers.sh, infra agents untouched, markers_for untouched.
# Asserts the enum CONTAINS the seven classes (not equals): #141 adds an eighth.
# Every function/variable is prefixed bc_ / BC_ (all test files share one shell).

HERE_BC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_BC=$(cd "$HERE_BC/../../.." && pwd)
BC_CLASSES="ci_pending ci_red merge_conflict unsupported_project needs_jp dependency other"
BC_NINE="product-manager ux-flow-designer ui-ux-designer solutions-architect test-writer test-reviewer fullstack-developer code-reviewer deployer"

test_bc_ac10_each_code_track_agent_has_class_sentence_and_all_seven_names() {
  local a c body
  for a in $BC_NINE; do
    body=$(cat "$ROOT_BC/agents/$a.md")
    assert_contains "$body" 'Blocked on: <class> — <the gate or question, one line>' "AC10: $a.md carries the new sentence" || return 1
    for c in $BC_CLASSES; do
      assert_contains "$body" "\`$c\`" "AC10: $a.md names class $c" || return 1
    done
  done
}

test_bc_ac10_infra_agents_still_lack_blocked_on() {
  local a
  for a in infra-planner infra-reviewer infra-operator; do
    assert_not_contains "$(cat "$ROOT_BC/agents/$a.md")" 'Blocked on:' "AC10: $a.md must stay untouched" || return 1
  done
}

test_bc_ac10_block_classes_defined_and_contains_the_seven() {
  local out c
  out=$( . "$ROOT_BC/hooks/pipeline-markers.sh"; block_classes 2>/dev/null )
  assert_ne "$out" "" "AC10: block_classes prints the enum" || return 1
  for c in $BC_CLASSES; do
    case "|$out|" in *"|$c|"*) ;; *) fail "AC10: block_classes lacks [$c]: $out"; return 1 ;; esac
  done
}

test_bc_ac10_class_list_spelled_only_in_pipeline_markers() {
  local hits
  hits=$(cd "$ROOT_BC" && grep -rlE 'ci_pending|ci_red' hooks skills --include='*.sh' --include='*.py' 2>/dev/null \
         | grep -vE '(^|/)tests?/' | sort)
  assert_eq "$hits" "hooks/pipeline-markers.sh" "AC10: the list is code in exactly one file" || return 1
}

test_bc_ac10_deployer_guide_maps_gate_to_class() {
  local body; body=$(cat "$ROOT_BC/agents/deployer.md")
  local pair
  for pair in '→ `ci_pending`' '→ `ci_red`' '→ `merge_conflict`' '→ `unsupported_project`' '→ `dependency`'; do
    assert_contains "$body" "$pair" "AC10: deployer.md guide line [$pair]" || return 1
  done
}

test_bc_ac18_markers_for_byte_identical_to_main() {
  local ext='/^markers_for\(\)/ {p=1} p {print} p && /^}/ {exit}' now base
  # #114: strip only the `intake)` case line (and, in marker_re, the ` intake` token) from both sides
  now=$(awk "$ext" "$ROOT_BC/hooks/pipeline-markers.sh" | sed -e '/^ *intake) /d' -e 's/ intake; do/; do/')
  base=$(cd "$ROOT_BC" && git show origin/main:hooks/pipeline-markers.sh | awk "$ext" | sed -e '/^ *intake) /d' -e 's/ intake; do/; do/')
  assert_ne "$base" "" "AC18: markers_for found on origin/main" || return 1
  assert_eq "$now" "$base" "AC18: markers_for unchanged" || return 1
}

for t in $(declare -F | awk '{print $3}' | grep '^test_bc_'); do run_test "$t"; done
