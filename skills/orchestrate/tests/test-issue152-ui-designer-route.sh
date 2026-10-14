# Issue #152: orchestrator READY FOR ENGINEERING with `UI change: yes` and no `UX flow: yes`
# routes to ui-ux-designer (not test-writer directly); the prose agrees everywhere.
# Names prefixed i152_ / I152_.

HERE_I152=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCH_I152="$HERE_I152/../../../agents/orchestrator.md"

test_i152_ready_for_engineering_row_dispatches_ui_ux_designer() {
  local row; row=$(grep -F '| `[product-manager] READY FOR ENGINEERING`' "$ORCH_I152" | head -1)
  assert_contains "$row" 'without `UX flow: yes`, dispatch **ui-ux-designer**' "row 47: UI yes w/o UX flow -> ui-ux-designer" || return 1
  assert_not_contains "$row" 'without `UX flow: yes`, dispatch **test-writer**' "row 47: no direct test-writer for UI tickets" || return 1
}

test_i152_prose_does_not_offer_test_writer_directly() {
  assert_not_contains "$(cat "$ORCH_I152")" 'or test-writer directly' "no 'or test-writer directly' for UI tickets" || return 1
}

for t in $(declare -F | awk '{print $3}' | grep '^test_i152_'); do run_test "$t"; done
