#!/usr/bin/env bash
# Regression: deployer prompt must record scheduler staging migrations in the ledger (#72).
set -u
f="$(dirname "$0")/../agents/deployer.md"
fail=0
chk() { grep -q -- "$1" "$f" || { echo "MISSING: $1"; fail=1; }; }
chk 'migration-ledger.ts sql'
chk '--by deployer --env staging'
chk 'scheduler_migration_ledger'
chk "environment='staging'"
chk 'owner/runbook #688'
chk 'production is never recorded by the deployer'
[ -z "$(git -C "$(dirname "$0")/.." ls-files '.claude/agents' | grep -v deployer.md)" ] || { echo "extra .claude/agents file"; fail=1; }
exit $fail
