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

# Issue #236 — a cancelled deploy (concurrency cancel-in-progress) is followed along the chain of
# newer staging deploys containing the merge, never reported as a failure.
test_prf_236_follows_cancel_chain() {
  local pm; pm=$(prf_postmerge)
  local want
  for want in 'cancelled' 'compare/' 'identical' 'ahead' 'every further' 'cancelled → cancelled → success' 'never re-runs'; do
    printf '%s\n' "$pm" | grep -qF -- "$want" || { fail "#236: post-merge bullet must mention '$want'"; return 1; }
  done
  printf '%s\n' "$pm" | grep -qiE 'run URL.*followed|followed.*run URL' || { fail "#236: handoff must name every followed run URL"; return 1; }
  printf '%s\n' "$pm" | grep -qiE 'no new timer|same wait|existing wait' || { fail "#236: must stay inside the existing wait"; return 1; }
  assert_eq 0 0 "#236 chain rule present"
}

test_prf_236_delivery_lead_no_blocked_relaunch_promise() {
  local dl="$ROOT_PRF/agents/delivery-lead.md" line
  line=$(grep -F 'Deployer merged but posted no marker' "$dl")
  assert_ne "$line" "" "playbook row exists" || return 1
  if printf '%s\n' "$line" | grep -qF 'verification "incomplete"'; then fail "#236: delivery-lead must not promise a no-decision relaunch for a deployer BLOCKED"; return 1; fi
  printf '%s\n' "$line" | grep -qF 'No decision comment' && { fail "#236: 'No decision comment' promise still present"; return 1; }
  assert_eq 0 0 "#236 delivery-lead narrowed"
}

run_test test_prf_236_follows_cancel_chain
run_test test_prf_236_delivery_lead_no_blocked_relaunch_promise

# Issue #296 — every staging DEPLOYED / DEPLOYED TO STAGING comment carries the JP-required
# "E2E: deferred" line (claude-agents variant: n/a); smoke stays non-blocking, no wait added.
test_prf_296_e2e_line_in_templates() {
  local want='- E2E: deferred to the final suite run (JP 2026-09-22)' rep
  rep=$(awk '/^7\. \*\*Report\.\*\*/{on=1} on&&/^## Comment protocol/{exit} on{print}' "$DEPL_PRF")
  assert_ne "$rep" "" "step 7 exists" || return 1
  printf '%s\n' "$rep" | grep -qF -- "$want" || { fail "#296: step-7 template lacks the E2E deferred line"; return 1; }
  printf '%s\n' "$rep" | grep -qF -- '- E2E: n/a' || { fail "#296: claude-agents variant lacks '- E2E: n/a'"; return 1; }
  local s0; s0=$(grep -E '^0\. \*\*Deployer post-merge mode' "$DEPL_PRF")
  printf '%s\n' "$s0" | grep -qF -- 'E2E: deferred to the final suite run (JP 2026-09-22)' || { fail "#296: post-merge mode lacks the E2E line"; return 1; }
  assert_eq 0 0 "#296 E2E line present"
}

test_prf_296_smoke_still_non_blocking() {
  grep -qF 'A still-running or failed E2E/smoke job in the same run, or a separate E2E workflow, does not block.' "$DEPL_PRF" || { fail "#296: :39 non-blocking sentence changed"; return 1; }
  grep -qF 'NOT merge gates on `staging`' "$DEPL_PRF" || { fail "#296: :77 exception changed"; return 1; }
  grep -qF 'Never poll a workflow to completion.' "$DEPL_PRF" || { fail "#296: poll ban removed"; return 1; }
  assert_eq 0 0 "#296 no wait added"
}

run_test test_prf_296_e2e_line_in_templates
run_test test_prf_296_smoke_still_non_blocking
