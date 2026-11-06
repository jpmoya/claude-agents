#!/usr/bin/env bash
# Regression: payroll skip allowlist licenses root vercel.json, nothing else at root (#541).
set -u
f="$(dirname "$0")/../agents/deployer.md"
fn="$(awk '/^ *skip_licence\(\) \{/ { on=1 } on { sub(/^ +/, ""); print } on && /^\}$/ { exit }' "$f")"
[ -n "$fn" ] || { echo "MISSING: skip_licence"; exit 1; }
fail=0
lic() { local job=$1; shift; printf '%s\n' "$@" | bash -c "$fn"$'\n''skip_licence "$1"' _ "$job" 2>&1; }
exp() { [ "$1" = "$2" ] || { echo "FAIL: got '$1', want '$2' ($3)"; fail=1; }; }
for j in payroll-sync-tests payroll-scrape-tests; do
  exp "$(lic $j vercel.json src/a.ts docs/x.md)" "licensed" "$j vercel.json"
  exp "$(lic $j vercel.json package.json)" "not licensed: package.json" "$j package.json"
  exp "$(lic $j vercel.json.bak)" "not licensed: vercel.json.bak" "$j no wildcard"
  exp "$(lic $j benjis_payroll/vercel.json)" "not licensed: benjis_payroll/vercel.json" "$j nested"
done
# other jobs unchanged
exp "$(lic migration-rehearsal vercel.json)" "not licensed: vercel.json" "rehearsal"
exp "$(lic destructive-migration-approval supabase/migrations/a.sql vercel.json)" "not licensed: vercel.json" "destructive"
# rationale bullet records evidence
b="$(grep -F -- '**`payroll-sync-tests`, `payroll-scrape-tests`** run' "$f")"
for s in 'vercel.json' 'references `vercel`'; do
  printf '%s' "$b" | grep -qF -- "$s" || { echo "MISSING in rationale: $s"; fail=1; }
done
exit $fail
