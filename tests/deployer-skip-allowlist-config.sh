#!/usr/bin/env bash
# Regression: deployer skip_licence licenses .github/dependabot.yml and .github/migration-policy/shared-tables.txt
# on payroll/rehearsal jobs only, and nothing wider (#550).
set -u
f="$(dirname "$0")/../agents/deployer.md"
fail=0
eval "$(awk '/^         skip_licence\(\) \{/{p=1} p{print} p&&/^         \}$/{exit}' "$f")"
declare -F skip_licence >/dev/null || { echo "MISSING: skip_licence"; exit 1; }
t() { # want job files...
  local want=$1 job=$2; shift 2
  local out; out=$(printf '%s\n' "$@" | skip_licence "$job")
  [ "$out" = "$want" ] || { echo "FAIL $job [$*]: got '$out', want '$want'"; fail=1; }
}
for j in payroll-sync-tests payroll-scrape-tests migration-rehearsal; do
  t licensed $j .github/dependabot.yml scripts/x.test.ts
  t licensed $j .github/migration-policy/shared-tables.txt scripts/x.ts
  t "not licensed: .github/ci-image/Dockerfile" $j .github/dependabot.yml .github/ci-image/Dockerfile
  t "not licensed: .github/workflows/ci.yml" $j .github/dependabot.yml .github/workflows/ci.yml
  t "not licensed: .github/other.yml" $j .github/other.yml
done
t "not licensed: .github/dependabot.yml" destructive-migration-approval supabase/migrations/1.sql .github/dependabot.yml
exit $fail
