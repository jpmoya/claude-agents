# Release shaping (issue #189): the product-manager cuts work into small, independently shippable
# tickets and never picks a version. The definitions are prose, so the contract is pinned by literal
# strings. Grep against tracked files only — no network, no gh, no ssh.

HERE_RS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_RS=$(cd "$HERE_RS/../../.." && pwd)
PM_RS="$ROOT_RS/agents/product-manager.md"

# rs_has <literal> — fixed-string search in product-manager.md; fails with the missing literal named.
rs_has() {
  grep -qF -- "$1" "$PM_RS" || { fail "product-manager.md: missing [$1]"; return 1; }
}

# AC1: each of the five literals is individually pinned, so removing any one fails exactly one test.
test_rs_ac1_one_independently_shippable_pr() {
  rs_has 'one independently shippable PR'
}
test_rs_ac1_expand_contract_sequence() {
  rs_has 'expand → backfill → cut over → contract'
}
test_rs_ac1_destructive_migration() {
  rs_has 'destructive migration'
}
test_rs_ac1_jp_only_approver() {
  rs_has 'JP is the only approver'
}
test_rs_ac1_agents_never_write_a_version() {
  rs_has 'agents never choose or write a version'
}

# AC2: the existing milestone guardrail must survive the edit.
test_rs_ac2_milestone_rule_still_present() {
  rs_has 'never pre-assign a release milestone'
}

# AC3 (negative control): the pin helper really fails on an absent literal.
test_rs_ac3_helper_fails_when_literal_absent() {
  if (rs_has 'zz-no-such-literal-zz' >/dev/null 2>&1); then
    fail "rs_has accepted a literal that is not in product-manager.md"; return 1
  fi
}

# #215: CLAUDE.md tells sessions to run the bump script, never to choose a version.
test_rs_215_claude_md_bump_script() {
  grep -qF 'bump-version.sh' "$ROOT_RS/CLAUDE.md" && grep -qF 'never choose a version' "$ROOT_RS/CLAUDE.md" \
    || { fail "CLAUDE.md: missing bump-version.sh / never choose a version"; return 1; }
}

echo "-- release shaping (issue #189)"
run_test test_rs_215_claude_md_bump_script
run_test test_rs_ac1_one_independently_shippable_pr
run_test test_rs_ac1_expand_contract_sequence
run_test test_rs_ac1_destructive_migration
run_test test_rs_ac1_jp_only_approver
run_test test_rs_ac1_agents_never_write_a_version
run_test test_rs_ac2_milestone_rule_still_present
run_test test_rs_ac3_helper_fails_when_literal_absent
