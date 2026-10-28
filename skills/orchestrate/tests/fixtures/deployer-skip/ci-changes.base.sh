#!/usr/bin/env bash
# Path classifier for ci.yml job gating (#1345).
# Input: changed file paths as arguments, or one per line on stdin when no
# arguments are given. `--force-all` (diff failed / base ref unavailable) sets
# every output to true so no job is skipped.
# Output: `key=true|false` lines, one per gated job.
set -u

sync=false
scrape=false
rehearsal=false
legacy=false

all_true() { sync=true; scrape=true; rehearsal=true; legacy=true; }

classify() {
  case "$1" in
    .github/workflows/ci.yml) all_true ;;
    benjis_payroll/sync/*) sync=true ;;
    benjis_payroll/scrape/*) scrape=true ;;
    supabase/migrations/*) rehearsal=true; legacy=true ;;
    supabase/rehearsal/*|scripts/rehearse-migrations.sh) rehearsal=true ;;
    src/*|tests/legacy-readers/*|vitest.legacy-readers.config.ts|package.json|package-lock.json|next.config.*) legacy=true ;;
  esac
}

force_all=false
nfiles=0
for a in "$@"; do
  if [ "$a" = "--force-all" ]; then
    force_all=true
  else
    nfiles=$((nfiles + 1))
    classify "$a"
  fi
done

if [ "$#" -eq 0 ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] && classify "$line"
  done
fi

if [ "$force_all" = true ]; then all_true; fi

echo "payroll-sync=$sync"
echo "payroll-scrape=$scrape"
echo "migration-rehearsal=$rehearsal"
echo "legacy-readers=$legacy"
