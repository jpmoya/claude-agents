# #621 — goal classifier reads "Blocked on: needs_jp" with the same prefix rule as supervisor.sh blocked_class_of
# (^Blocked on: needs_jp( |$)): the documented "Blocked on: needs_jp — <reason>" form is waiting_jp, not active work.
# Reuses gs_check_class from test-goal-supervisor.sh; this file name sorts after it (all test files share one shell).

test_gs_621_needs_jp_forms_are_waiting_jp() {
  gs_check_class waiting_jp "bare needs_jp" open "" $'**[product-manager] BLOCKED**\nBlocked on: needs_jp\nonly JP can decide' || return 1
  gs_check_class waiting_jp "needs_jp — reason" open "" $'**[product-manager] BLOCKED**\nBlocked on: needs_jp — set the secret\ndetails' || return 1
  gs_check_class waiting_jp "needs_jp with CRLF line" open "" $'**[deployer] BLOCKED**\r\nBlocked on: needs_jp — set the secret\r\ndetails' || return 1
}

test_gs_621_other_classes_stay_active() {
  gs_check_class active "needs_jpx is not needs_jp" open "" $'**[fullstack-developer] BLOCKED**\nBlocked on: needs_jpx — nope\ndetails' || return 1
  gs_check_class active "dependency — reason" open "" $'**[fullstack-developer] BLOCKED**\nBlocked on: dependency — waits on #5\ndetails' || return 1
  gs_check_class active "ci_red — reason" open "" $'**[fullstack-developer] BLOCKED**\nBlocked on: ci_red — red\ndetails' || return 1
}

run_test test_gs_621_needs_jp_forms_are_waiting_jp
run_test test_gs_621_other_classes_stay_active
gs_tree_cleanup
