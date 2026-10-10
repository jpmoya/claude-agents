# Issue #176 — AC4 + AC5, supervisor half. Reuses the si_* harness of test-intake-supervisor.sh (sourced earlier by the
# runner; this file's name sorts after it). Stub claude is replaced after si_env: it logs argv and, when
# $D/claude-mode-noise exists, posts `**[intake] NOISE** <reason>` as a healthy sentry-noise run would.

s176s_env() {
  type si_env >/dev/null 2>&1 || { fail "si_env harness missing (test-intake-supervisor.sh must be sourced first)"; return 1; }
  si_env
  cat > "$SI_D/claude" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$* | ISSUE=${PIPELINE_ISSUE:-} AGENT=${PIPELINE_AGENT:-} REPO=${PIPELINE_REPO:-}" >> "$D/claude.log"
if [ -f "$D/claude-mode-noise" ]; then
  jq --arg b $'**[intake] NOISE** hydration mismatch\nclosed as not planned' '. + [{body:$b,createdAt:"2099-01-01T00:00:00Z"}]' "$D/comments.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/comments.json"
fi
exit 0
X
  chmod +x "$SI_D/claude"
}

test_s176_ac4_noise_run_is_cleared_not_retried_or_given_up() {
  s176s_env || return 1
  touch "$SI_D/claude-mode-noise"
  si_issue 7 project-a/repo-a user-feedback-intake source:sentry
  local i; for i in 1 2 3 4 5 6; do si_tick; done
  local n calls labels notes readds
  n=$(si_launches); calls=$(cat "$SI_D/gh-calls.log"); labels=$(si_labels 7)
  notes=$(jq -r '.[].body | select(startswith("**[supervisor] NOTE**") and (contains("claim:")|not))' "$SI_D/comments.json" | grep -c .)
  readds=$(grep -c -- '--add-label user-feedback-intake' "$SI_D/gh-calls.log")
  si_cleanup
  assert_eq "$n" "1" "AC4: a run ending in [intake] NOISE is not relaunched" || return 1
  assert_eq "$notes" "0" "AC4: no 'ran twice without a marker' supervisor NOTE" || return 1
  assert_eq "$readds" "0" "AC4: user-feedback-intake is not put back" || return 1
  assert_contains "$calls" "--remove-label agent-in-progress" "AC4: agent-in-progress cleared after the run" || return 1
  assert_not_contains "$labels" "agent-in-progress" "AC4: label gone from the issue" || return 1
}

test_s176_ac5_sentry_issue_with_needs_spec_label_is_never_spec_launched() {
  s176s_env || return 1
  # #7 (source:sentry) listed first: if it were eligible the spec step would pick it before #8 (positive control)
  si_issue 7 project-a/repo-a user-feedback-needs-spec source:sentry
  si_issue 8 project-a/repo-a user-feedback-needs-spec
  si_tick
  local log labels7 labels8; log=$(cat "$SI_D/claude.log"); labels7=$(si_labels 7); labels8=$(si_labels 8)
  si_cleanup
  assert_not_contains "$log" "ISSUE=7" "AC5: source:sentry issue is never routed to the spec stage" || return 1
  assert_contains "$log" "ISSUE=8 AGENT=product-manager" "control: a plain needs-spec issue launches the spec run" || return 1
  assert_eq "$labels7" "source:sentry,user-feedback-needs-spec" "AC5: sentry issue labels untouched by the spec step" || return 1
  assert_not_contains "$labels8" "source:sentry" "control labels sane" || return 1
}

run_test test_s176_ac4_noise_run_is_cleared_not_retried_or_given_up
run_test test_s176_ac5_sentry_issue_with_needs_spec_label_is_never_spec_launched
