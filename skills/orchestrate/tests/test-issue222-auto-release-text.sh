# Issue #222 — pipeline text allows the kill-switched auto-release workflow to promote direct-route changes.
# Docs-only: text checks. Expected strings are verbatim from the ticket ACs. Prefixed ar222_.
# Sourced by run-tests.sh (lib/assert.sh already loaded).

ROOT_AR222=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
CL_AR222="$ROOT_AR222/CLAUDE.md"
DEP_AR222="$ROOT_AR222/agents/deployer.md"
ORCH_AR222="$ROOT_AR222/agents/orchestrator.md"
PM_AR222="$ROOT_AR222/agents/product-manager.md"
DL_AR222="$ROOT_AR222/agents/delivery-lead.md"
PMALIAS_AR222="$ROOT_AR222/agents/project-manager.md"

ar222_front() { awk '/^---$/ { n++; next } n == 1 { print } n >= 2 { exit }' "$1"; }
ar222_line() { grep -F -- "$2" "$1" | head -1; }

# AC1
test_ar222_ac1_claude_md_auto_release_sentence() {
  local l
  l=$(ar222_line "$CL_AR222" "A release whose changes are not on the risky list merges to main without JP.")
  assert_contains "$l" "release/auto-" "AC1: sentence on the same paragraph line mentions release/auto-" || return 1
  assert_contains "$l" "kill-switch" "AC1: kill-switched workflow" || return 1
  assert_contains "$l" "agents still never merge to \`main\` themselves" "AC1: agents never merge" || return 1
}

# AC3
test_ar222_ac3_deployer_route_aware_final_line() {
  local t; t=$(cat "$DEP_AR222")
  assert_contains "$t" "Production deploy pending JP's review on staging." "AC3: staging text unchanged" || return 1
  assert_contains "$t" "Route: direct — the auto-release workflow promotes it when enabled; otherwise production deploy pending JP's review." "AC3: direct line verbatim" || return 1
  assert_contains "$t" "route:direct" "AC3: names route:direct label" || return 1
  assert_contains "$t" "route:staging" "AC3: names route:staging label" || return 1
}

test_ar222_ac3_deployer_description_mentions_auto_release() {
  local f; f=$(ar222_front "$DEP_AR222")
  assert_contains "$f" "auto-release workflow" "AC3: frontmatter description mentions auto-release on the direct route" || return 1
  assert_contains "$f" "JP's review" "AC3: still says JP's review" || return 1
}

# AC4
test_ar222_ac4_orchestrator_relays_deployer_line() {
  local l; l=$(grep -F '| `[deployer] DEPLOYED`' "$ORCH_AR222" | head -1)
  assert_contains "$l" "final line" "AC4: relays the deployer's final line" || return 1
  assert_not_contains "$l" "pending JP's review" "AC4: no hard-coded pending-JP wording" || return 1
}

# AC5
test_ar222_ac5_product_manager_wording() {
  assert_contains "$(cat "$PM_AR222")" "JP's staging→main promotion on the staging route" "AC5" || return 1
}

# AC6
test_ar222_ac6_delivery_lead_jp_lines_jp_only() {
  local l; l=$(grep -F '**JP-only, these may block' "$DL_AR222" | head -1)
  assert_contains "$l" 'posting any comment whose first line starts `**[jp]`' "AC6: JP-only list" || return 1
  assert_contains "$l" "ROUTE direct" "AC6: names ROUTE direct" || return 1
  assert_contains "$l" '`**[delivery-lead] JP CONFIRMED**`' "AC6: relay with JP CONFIRMED" || return 1
  assert_contains "$l" "merge to \`main\` of any change on the risky list" "AC6: existing risky-list wording kept" || return 1
}

test_ar222_ac6_orchestrator_never_posts_jp_lines() {
  assert_contains "$(cat "$ORCH_AR222")" 'never posts a comment whose first line starts `**[jp]`' "AC6: orchestrator sentence" || return 1
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ar222_'); do run_test "$t"; done
