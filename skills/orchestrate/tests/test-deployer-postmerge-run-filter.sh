# Issue #128 — deployer post-merge check selects the merge commit's deploy-staging.yml run and reads
# only its deploy job, never `gh run list --branch staging --limit 1` (which can read the E2E run).
# Tracked files only; no network.

ROOT_PRF=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
DEPL_PRF="$ROOT_PRF/agents/deployer.md"

prf_postmerge() {  # the "- **Post-merge:**" bullet, up to the next top-level bullet
  awk '/^- \*\*Post-merge:\*\*/ && !on { on=1; print; next }
       on && /^- / { exit }
       on { print }' "$DEPL_PRF"
}

test_prf_ac1_filtered_run_and_deploy_job() {
  local pm; pm=$(prf_postmerge)
  assert_ne "$pm" "" "post-merge bullet exists" || return 1
  printf '%s\n' "$pm" | grep -qF -- '--workflow deploy-staging.yml' || { fail "AC1: must filter by --workflow deploy-staging.yml"; return 1; }
  printf '%s\n' "$pm" | grep -qF -- '--commit' || { fail "AC1: must filter by --commit"; return 1; }
  printf '%s\n' "$pm" | grep -qF 'mergeCommit' || { fail "AC1: must take the merge commit SHA"; return 1; }
  printf '%s\n' "$pm" | grep -qF '^[Dd]eploy' || { fail "AC1: must select the deploy job"; return 1; }
  assert_eq 0 0 "AC1 ok"
}

test_prf_ac1_job_filter_matches_only_deploy_jobs() {
  local re='^[Dd]eploy' n
  for n in 'Deploy to Vercel (jpmoyas-projects)' 'deploy'; do
    printf '%s\n' "$n" | grep -qE "$re" || { fail "AC1: filter must match '$n'"; return 1; }
  done
  for n in 'Stamp staging milestone' 'stamp-staging-milestone' 'Smoke check' 'e2e-smoke' 'e2e-full'; do
    if printf '%s\n' "$n" | grep -qE "$re"; then fail "AC1: filter must not match '$n'"; return 1; fi
  done
  assert_eq 0 0 "job filter ok"
}

test_prf_ac2_unfiltered_command_absent() {
  local pm; pm=$(prf_postmerge)
  if printf '%s\n' "$pm" | grep -qF 'gh run list --branch staging --limit 1'; then fail "AC2: unfiltered command still in bullet"; return 1; fi
  assert_eq "$(grep -c -- '--limit 1 --json status,conclusion' "$DEPL_PRF")" 0 "AC2: no unfiltered status read anywhere"
}

run_test test_prf_ac1_filtered_run_and_deploy_job
run_test test_prf_ac1_job_filter_matches_only_deploy_jobs
run_test test_prf_ac2_unfiltered_command_absent
