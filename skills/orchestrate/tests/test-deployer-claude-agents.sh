# Issue #144: the deployer supports jpmoya/claude-agents (merge to main, nothing to deploy).
# Doc-grep tests over tracked files only — no network, no gh.

HERE_DCA=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DCA=$(cd "$HERE_DCA/../../.." && pwd)
DEP_DCA="$ROOT_DCA/agents/deployer.md"
ORCH_DCA="$ROOT_DCA/agents/orchestrator.md"

# dca_section — the claude-agents subsection of deployer.md: from the `### ` heading naming
# claude-agents up to (not including) the next `## `/`### ` heading.
dca_section() {
  awk '/^### / && /claude-agents/ { on=1; print; next } /^##/ { on=0 } on' "$DEP_DCA"
}

# dca_hard_limits — text under `## Hard limits` up to the next `## ` heading.
dca_hard_limits() {
  awk '/^## Hard limits/ { on=1; next } /^## / { on=0 } on' "$DEP_DCA"
}

test_dca_ac1_subsection_exists_with_heading() {
  local s
  s=$(dca_section)
  [ -n "$s" ] || { fail "deployer.md: no '### ...claude-agents' subsection under Supported projects"; return 1; }
  assert_contains "$(echo "$s" | head -1)" "~/claude-agents" "claude-agents heading" || return 1
  assert_contains "$(echo "$s" | head -1)" "jpmoya/claude-agents" "claude-agents heading" || return 1
}

test_dca_ac1_subsection_states_model() {
  local s
  s=$(dca_section)
  [ -n "$s" ] || { fail "deployer.md: no claude-agents subsection"; return 1; }
  assert_contains "$s" "merge to \`main\`" "claude-agents subsection" || return 1
  assert_contains "$s" "no deploy job" "claude-agents subsection" || return 1
  assert_contains "$s" "no migrations" "claude-agents subsection" || return 1
  assert_contains "$s" "sync-agents.sh" "claude-agents subsection" || return 1
  assert_contains "$s" "git pull --ff-only" "claude-agents subsection" || return 1
}

test_dca_ac2_subsection_states_nevers() {
  local s
  s=$(dca_section)
  [ -n "$s" ] || { fail "deployer.md: no claude-agents subsection"; return 1; }
  assert_contains "$s" "never applies the Supabase" "claude-agents subsection" || return 1
  assert_contains "$s" "never runs the milestone check" "claude-agents subsection" || return 1
  assert_contains "$s" "never checks a deploy job" "claude-agents subsection" || return 1
}

test_dca_ac2_hard_limit_scoped_to_two_repos() {
  local h
  h=$(dca_hard_limits)
  [ -n "$h" ] || { fail "deployer.md: Hard limits section not found"; return 1; }
  # Negative: the unscoped sentence must be gone.
  assert_not_contains "$h" "Never merge to \`main\`, never push to \`main\`, never \`vercel deploy\`" "Hard limits (unscoped wording)" || return 1
  # The "never merge to main" wording must remain but name the scoped repos.
  assert_contains "$h" "scheduler" "Hard limits" || return 1
  assert_contains "$h" "quoting tool" "Hard limits" || return 1
  assert_contains "$h" "claude-agents" "Hard limits (explicit carve-out for claude-agents)" || return 1
}

test_dca_ac3_steps_2_and_4_unchanged() {
  local body
  body=$(cat "$DEP_DCA")
  assert_contains "$body" "MERGEABLE" "deployer.md" || return 1
  assert_contains "$body" "If the PR isn't mergeable, stop and report why" "deployer.md" || return 1
  assert_contains "$body" "Never force-merge" "deployer.md" || return 1
}

test_dca_ac3_deployed_template_variant() {
  local body
  body=$(cat "$DEP_DCA")
  assert_contains "$body" "PR #<N> merged to main" "deployer.md claude-agents DEPLOYED variant" || return 1
  assert_contains "$body" "Migrations: none (n/a)" "deployer.md claude-agents DEPLOYED variant" || return 1
  assert_contains "$body" "Verification: n/a — nothing to deploy" "deployer.md claude-agents DEPLOYED variant" || return 1
  assert_contains "$body" "Milestone: n/a — no staging milestone in this repo" "deployer.md" || return 1
}

test_dca_ac4_post_merge_mode_for_claude_agents() {
  local step0
  step0=$(grep -E '^0\. \*\*Deployer post-merge mode' "$DEP_DCA")
  [ -n "$step0" ] || { fail "deployer.md: step 0 not found"; return 1; }
  assert_contains "$step0" "claude-agents" "step 0 post-merge mode" || return 1
  assert_contains "$step0" "only verifies the merge" "step 0 post-merge mode (claude-agents)" || return 1
}

test_dca_ac5_orchestrator_deployer_row_mentions_claude_agents() {
  local row
  row=$(grep -E '^\| `\[code-reviewer\] PASS` ' "$ORCH_DCA" | head -1)
  [ -n "$row" ] || { fail "orchestrator.md: deployer dispatch row not found"; return 1; }
  assert_contains "$row" "claude-agents" "orchestrator deployer dispatch row" || return 1
  assert_contains "$row" "no staging/production split" "orchestrator deployer dispatch row" || return 1
}

test_dca_ac5_orchestrator_deployed_row_mentions_claude_agents() {
  local row
  row=$(grep -E '^\| `\[deployer\] DEPLOYED`' "$ORCH_DCA" | head -1)
  [ -n "$row" ] || { fail "orchestrator.md: DEPLOYED report row not found"; return 1; }
  assert_contains "$row" "claude-agents" "orchestrator DEPLOYED row" || return 1
  assert_contains "$row" "merged to \`main\`" "orchestrator DEPLOYED row" || return 1
  # Production-promotion text must stay scoped to the two staging repos.
  assert_contains "$row" "scheduler and the quoting tool" "orchestrator DEPLOYED row" || return 1
}

test_dca_ac5_orchestrator_has_no_mergeable_word() {
  # Guard from #79: do not reintroduce the word in orchestrator.md.
  assert_not_contains "$(cat "$ORCH_DCA")" "mergeable" "orchestrator.md" || return 1
  assert_not_contains "$(cat "$ORCH_DCA")" "MERGEABLE" "orchestrator.md" || return 1
}

test_dca_ac6_unsupported_still_refused() {
  assert_contains "$(cat "$DEP_DCA")" "refuse and report" "deployer.md" || return 1
  # Supported list must not become a catch-all: other repos are not named as supported.
  assert_not_contains "$(dca_section)" "any repo" "claude-agents subsection" || return 1
}

test_dca_ac6_no_repo_local_agents_dir() {
  local tracked
  tracked=$(git -C "$ROOT_DCA" ls-files .claude/agents)
  assert_eq "$tracked" "" "git ls-files .claude/agents" || return 1
}

echo "-- deployer supports claude-agents (issue #144)"
run_test test_dca_ac1_subsection_exists_with_heading
run_test test_dca_ac1_subsection_states_model
run_test test_dca_ac2_subsection_states_nevers
run_test test_dca_ac2_hard_limit_scoped_to_two_repos
run_test test_dca_ac3_steps_2_and_4_unchanged
run_test test_dca_ac3_deployed_template_variant
run_test test_dca_ac4_post_merge_mode_for_claude_agents
run_test test_dca_ac5_orchestrator_deployer_row_mentions_claude_agents
run_test test_dca_ac5_orchestrator_deployed_row_mentions_claude_agents
run_test test_dca_ac5_orchestrator_has_no_mergeable_word
run_test test_dca_ac6_unsupported_still_refused
run_test test_dca_ac6_no_repo_local_agents_dir
