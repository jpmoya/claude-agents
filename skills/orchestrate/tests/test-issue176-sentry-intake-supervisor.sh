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

test_s176_ac5_sentry_issue_with_needs_spec_label_is_spec_launched_since_678() {
  # #678 (decision 3) lifts #176's exclusion, with the flag at 0 or 1: a Sentry bug the PM or the developer rejected with
  # `Reason: needs-spec` gets its spec like any idea instead of sitting forever. Was: "...is_never_spec_launched".
  s176s_env || return 1
  # #7 (source:sentry) listed first: now eligible, so the spec step picks it before #8 (one launch per tick)
  si_issue 7 project-a/repo-a user-feedback-needs-spec source:sentry
  si_issue 8 project-a/repo-a user-feedback-needs-spec
  si_tick
  local i=0; while ! grep -q 'AGENT=product-manager' "$SI_D/claude.log" && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done   # the spec run is started detached
  local log labels7 labels8; log=$(cat "$SI_D/claude.log"); labels7=$(si_labels 7); labels8=$(si_labels 8)
  si_cleanup
  assert_contains "$log" "ISSUE=7 AGENT=product-manager" "#678: a source:sentry needs-spec issue is routed to the spec stage" || return 1
  assert_not_contains "$log" "ISSUE=8" "control: one spec launch per tick, the first eligible issue" || return 1
  assert_eq "$labels7" "agent-in-progress,source:sentry,user-feedback-needs-spec" "#678: the sentry issue is claimed by the spec step, never given agent-go" || return 1
  assert_eq "$labels8" "user-feedback-needs-spec" "control labels sane" || return 1
}

run_test test_s176_ac4_noise_run_is_cleared_not_retried_or_given_up
run_test test_s176_ac5_sentry_issue_with_needs_spec_label_is_spec_launched_since_678
