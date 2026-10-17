# #319 — label-keyed go inheritance (amends #314) is written into the two agent definitions.
# The behaviour itself is tested through goal_sync in test-goal-label.sh (test_glb_sync_*); this checks the docs say
# the same rules, near the label rule: a line with the `goal: ` label and `agent-go`, and within 6 lines of it the
# exclusions (Business-Intelligence, source:sentry, closed) and the loop guard (a removed agent-go is not re-added).
GLD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

gld_check() {  # <agent file>
  local f="$GLD_ROOT/agents/$1" rc=0 ln win
  ln=$(grep -nE 'goal: ' "$f" | grep -E 'agent-go' | head -1 | cut -d: -f1)
  if [ -z "$ln" ]; then fail "$1: no line ties the 'goal: <short title>' label to agent-go"; return 1; fi
  win=$(sed -n "$((ln > 6 ? ln - 6 : 1)),$((ln + 6))p" "$f")
  case "$win" in *Business-Intelligence*) ;; *) fail "$1: Business-Intelligence exclusion missing near the goal-label rule"; rc=1 ;; esac
  case "$win" in *source:sentry*) ;; *) fail "$1: source:sentry exclusion missing near the goal-label rule"; rc=1 ;; esac
  printf '%s' "$win" | grep -qi 'closed' || { fail "$1: closed-ticket exclusion missing near the goal-label rule"; rc=1; }
  printf '%s' "$win" | grep -qiE 're-?add|Go-granted|once per ticket' || { fail "$1: loop guard (a removed agent-go is not re-added) missing near the goal-label rule"; rc=1; }
  return $rc
}
test_gld_product_manager_label_keyed_inheritance() { gld_check product-manager.md; }
test_gld_delivery_lead_label_keyed_inheritance() { gld_check delivery-lead.md; }
run_test test_gld_product_manager_label_keyed_inheritance
run_test test_gld_delivery_lead_label_keyed_inheritance
