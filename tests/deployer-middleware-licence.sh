#!/usr/bin/env bash
# Regression: root middleware.ts is licensed (exact path only) on the migration-rehearsal and
# destructive-migration-approval skip arms (#711, #634); scripts/lib/pg-dump-filter.sh is a rehearsal entry file (#711).
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
# PR #2550 shape (#711): middleware.ts, no migration
for j in migration-rehearsal payroll-sync-tests payroll-scrape-tests destructive-migration-approval; do
  t licensed $j middleware.ts src/a.ts docs/x.md
done
# PR #2384 shape (#634): migration plus middleware.ts
t licensed destructive-migration-approval supabase/migrations/1.sql middleware.ts src/a.ts
# no wildcard / nested widening
t "not licensed: supabase/x/middleware.ts" migration-rehearsal supabase/x/middleware.ts
t "not licensed: benjis_payroll/x/middleware.ts" payroll-sync-tests benjis_payroll/x/middleware.ts
t "not licensed: scripts/lib/middleware.ts" destructive-migration-approval supabase/migrations/1.sql scripts/lib/middleware.ts
t "not licensed: middleware.ts.bak" migration-rehearsal middleware.ts.bak
t "not licensed: middleware.ts.bak" destructive-migration-approval supabase/migrations/1.sql middleware.ts.bak
# pg-dump-filter.sh is an entry file of the rehearsal job
t "not licensed: scripts/lib/pg-dump-filter.sh" migration-rehearsal scripts/lib/pg-dump-filter.sh
t "not licensed: scripts/lib/pg-dump-filter.sh" migration-rehearsal middleware.ts scripts/lib/pg-dump-filter.sh
t licensed migration-rehearsal scripts/other.ts
# other root files still off the rehearsal / destructive lists
t "not licensed: vercel.json" migration-rehearsal vercel.json
t "not licensed: package.json" destructive-migration-approval supabase/migrations/1.sql middleware.ts package.json
# rationale records evidence
for s in '#711' 'scripts/lib/pg-dump-filter.sh' 'c05b6cff'; do
  grep -qF -- "$s" "$f" || { echo "MISSING in deployer.md: $s"; fail=1; }
done
# one note per list records the middleware.ts evidence (payroll, rehearsal, destructive)
n=$(grep -F -- '`middleware.ts` is' "$f" | grep -c -E '#634|#711')
[ "$n" -ge 1 ] || { echo "MISSING: middleware.ts evidence notes"; fail=1; }
for b in 'payroll-sync-tests`, `payroll-scrape-tests`** run' '`migration-rehearsal`** runs' '`destructive-migration-approval`** runs only'; do
  line=$(grep -F -- "$b" "$f")
  printf '%s' "$line" | grep -qF 'middleware.ts' || { echo "MISSING middleware.ts evidence in bullet: $b"; fail=1; }
done
grep -qF 'sources no other file' "$f" && { echo "STALE: 'sources no other file' still present"; fail=1; }
exit $fail
