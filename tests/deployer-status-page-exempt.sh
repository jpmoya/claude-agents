#!/usr/bin/env bash
# Regression: deployer exempts the unrelated Cloudflare `Workers Builds: status-page` check on claude-agents PRs not touching status-page/ (#611).
set -u
f="$(dirname "$0")/../agents/deployer.md"
fail=0
b="$(grep -F -- '**Cloudflare exemption (jpmoya/claude-agents only, #611).**' "$f")"
[ -n "$b" ] || { echo "MISSING: Cloudflare exemption bullet"; exit 1; }
chk() { printf '%s' "$b" | grep -qF -- "$1" || { echo "MISSING in bullet: $1"; fail=1; }; }
chk 'Workers Builds: status-page'
chk 'gh pr diff <N> --name-only'
chk 'no path under `status-page/`'
chk 'a failure there is `ci_red`'
chk 'not waited on'
chk 'Ignored (not touched by this PR, #611): Workers Builds: status-page'
w="$(grep -F -- '**Wait in-run**' "$f")"
printf '%s' "$w" | grep -qF 'Cloudflare exemption' || { echo "MISSING: wait rule mentions exemption"; fail=1; }
grep -qF 'Ignored (not touched by this PR, #611)' <(sed -n '/^7\. \*\*Report/,$p' "$f") || { echo "MISSING: DEPLOYED format line"; fail=1; }
exit $fail
