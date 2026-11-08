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
# #609: vitest.config.ts (payroll + rehearsal) and supabase/hermetic/* (rehearsal) licensed; nothing wider
for j in payroll-sync-tests payroll-scrape-tests migration-rehearsal; do
  t licensed $j vitest.config.ts src/x.ts
  t "not licensed: vite.config.ts" $j vitest.config.ts vite.config.ts
  t "not licensed: tailwind.config.ts" $j tailwind.config.ts
  t "not licensed: .github/workflows/ci.yml" $j vitest.config.ts .github/workflows/ci.yml
  t "not licensed: package.json" $j vitest.config.ts package.json
  t "not licensed: .npmrc" $j .npmrc
done
t licensed migration-rehearsal supabase/hermetic/a.sql supabase/hermetic/b/c.sh vitest.config.ts
t "not licensed: supabase/rehearsal/production-shape.sql" migration-rehearsal supabase/hermetic/a.sql supabase/rehearsal/production-shape.sql
t "not licensed: supabase/migrations/x.sql" migration-rehearsal supabase/migrations/x.sql
t "not licensed: supabase/cutover/reconcile.sql" migration-rehearsal supabase/cutover/reconcile.sql
t "not licensed: scripts/rehearse-migrations.sh" migration-rehearsal vitest.config.ts scripts/rehearse-migrations.sh
t "not licensed: supabase/config.toml" migration-rehearsal supabase/config.toml
t "not licensed: benjis_payroll/sync/package.json" payroll-sync-tests vitest.config.ts benjis_payroll/sync/package.json
t "not licensed: benjis_payroll/scrape/package.json" payroll-scrape-tests benjis_payroll/scrape/package.json
exit $fail
