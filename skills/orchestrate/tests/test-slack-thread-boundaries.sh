# Issue #15 — boundaries the locked tests don't pin (test-reviewer findings 1 and 4 on the
# approved set): exact channel equality (no prefix/substring match) and exactly-four-args arity.
#
# Reuses helpers defined by the locked #15 test files (net_run, net_assert_lookup_made from the
# notify-engineering-thread file; pbdt_gh_home, pbdt_run, pbdt_capture from the
# pipeline-bridge-dispatch file). run-tests.sh sources every test-*.sh into one shell in name
# order, and this file sorts after both.

test_stb_recorded_channel_that_extends_the_configured_one_is_not_a_match() {
  net_run thread C1 0 '**[pipeline-bridge] NOTE** slack-thread: C10:111'
  net_assert_lookup_made "channel boundary" || return 1
  assert_eq "$NET_OUT" "" "recorded C10 must not thread into configured C1 (prefix match)" || return 1
}

test_stb_recorded_channel_that_is_a_prefix_of_the_configured_one_is_not_a_match() {
  net_run thread C10 0 '**[pipeline-bridge] NOTE** slack-thread: C1:111'
  net_assert_lookup_made "channel boundary" || return 1
  assert_eq "$NET_OUT" "" "recorded C1 must not thread into configured C10 (substring match)" || return 1
}

test_stb_five_arg_form_is_rejected() {
  local pipe home ghdir
  pipe=$(new_pipe); read -r home ghdir <<< "$(pbdt_gh_home)"
  echo "OPEN" > "$ghdir/gh-issue-state"; echo "[]" > "$ghdir/gh-issue-labels-json"
  pbdt_run "$ghdir" "$home" "$pipe" 1703 "example-owner/project-a" "C0PBDTEST" "1700000000.000100" "extra"
  pbdt_capture "$ghdir"
  rm -rf "$pipe" "$home"
  assert_ne "$PBDT_RC" "0" "exactly four args: a fifth arg must not exit 0" || return 1
  assert_eq "$PBDT_TOTAL_CALLS" "0" "rejected before any gh call" || return 1
}

run_test test_stb_recorded_channel_that_extends_the_configured_one_is_not_a_match
run_test test_stb_recorded_channel_that_is_a_prefix_of_the_configured_one_is_not_a_match
run_test test_stb_five_arg_form_is_rejected
