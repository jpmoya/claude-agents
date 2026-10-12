# Sentry definition of done (issue #187): the product-manager's definition makes Sentry error
# logging a standing part of every ticket. Prose contract, pinned by literal strings. Grep against
# tracked files only — no network, no gh, no ssh.

HERE_SD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_SD=$(cd "$HERE_SD/../../.." && pwd)
PM_SD="$ROOT_SD/agents/product-manager.md"

# sd_has <literal> — fixed-string search in product-manager.md; fails with the missing literal named.
sd_has() {
  grep -qF -- "$1" "$PM_SD" || { fail "product-manager.md: missing [$1]"; return 1; }
}

test_sd_ac1_section_heading() { sd_has '## Definition of done: Sentry error logging'; }
test_sd_ac1_observability_block() { sd_has 'carries an `Observability` acceptance-criteria block'; }
test_sd_ac1_placement() {
  local h d t
  h=$(grep -nF '## Definition of done: Sentry error logging' "$PM_SD" | head -1 | cut -d: -f1)
  d=$(grep -nF '## Dependency follow-ups' "$PM_SD" | head -1 | cut -d: -f1)
  t=$(grep -nF '### Fast-lane template' "$PM_SD" | head -1 | cut -d: -f1)
  [ -n "$h" ] && [ -n "$d" ] && [ -n "$t" ] && [ "$t" -lt "$h" ] && [ "$h" -lt "$d" ] \
    || { fail "section not between Ticket format and Dependency follow-ups (t=$t h=$h d=$d)"; return 1; }
}
test_sd_ac2_tags() { sd_has 'captured with release, environment and route tags'; }
test_sd_ac2_no_secrets() { sd_has 'no secrets or personal data'; }
test_sd_ac2_alert_path() { sd_has 'alert path exists (Slack)'; }
test_sd_ac2_test_proves() { sd_has 'a test proves the error is captured'; }
test_sd_ac3_commit_sha() { sd_has 'commit SHA'; }
test_sd_ac4_docs_only() { sd_has 'docs-only'; }
test_sd_ac4_justification() { sd_has 'one-line justification'; }
test_sd_ac4_no_other_exemptions() { sd_has 'no other exemptions'; }
test_sd_ac5_fast_lane_bullet() {
  sd_has '- **Observability** — the Sentry block above, or the docs-only n/a with justification.'
}
test_sd_ac5_full_lane_reference() {
  sd_has 'Every bug and feature ticket carries the **Observability** acceptance-criteria block'
}
test_sd_ac6_no_posthog() {
  if grep -qi posthog "$PM_SD"; then fail "product-manager.md mentions PostHog"; return 1; fi
}
# AC7 (negative control): the pin helper really fails on an absent literal.
test_sd_ac7_helper_fails_when_literal_absent() {
  if (sd_has 'zz-no-such-literal-zz' >/dev/null 2>&1); then
    fail "sd_has accepted a literal that is not in product-manager.md"; return 1
  fi
}

echo "-- sentry definition of done (issue #187)"
for t in test_sd_ac1_section_heading test_sd_ac1_observability_block test_sd_ac1_placement \
  test_sd_ac2_tags test_sd_ac2_no_secrets test_sd_ac2_alert_path test_sd_ac2_test_proves \
  test_sd_ac3_commit_sha test_sd_ac4_docs_only test_sd_ac4_justification \
  test_sd_ac4_no_other_exemptions test_sd_ac5_fast_lane_bullet test_sd_ac5_full_lane_reference \
  test_sd_ac6_no_posthog test_sd_ac7_helper_fails_when_literal_absent; do
  run_test "$t"
done
