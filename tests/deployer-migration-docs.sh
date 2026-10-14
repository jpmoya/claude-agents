#!/usr/bin/env bash
# Regression for #107: docs must not say promotion applies production migrations.
set -u
cd "$(dirname "$0")/.."
fail=0
if grep -rn "happens when JP promotes\|happens at promotion" agents/ README.md; then echo "FAIL: stale promotion wording"; fail=1; fi
grep -q "migration-gate" agents/deployer.md || { echo "FAIL: migration-gate rule missing"; fail=1; }
grep -q "do not type a migration list" agents/deployer.md || { echo "FAIL: ledger-check checklist line missing"; fail=1; }
exit $fail
