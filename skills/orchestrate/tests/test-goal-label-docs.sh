# #319 — label-keyed go inheritance (amends #314) is written into the two agent definitions.
# Loose substrings on purpose: the exact wording is the developer's; the label key and the agent-go link are not.
GLD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

gld_check() {  # <agent file>
  local f="$GLD_ROOT/agents/$1" rc=0
  grep -q 'goal: ' "$f" || { fail "$1: no mention of the 'goal: <short title>' label"; rc=1; }
  grep -E 'goal: ' "$f" | grep -qi 'agent-go\|inherit' || { fail "$1: the goal label is not tied to agent-go / inheritance"; rc=1; }
  return $rc
}
test_gld_product_manager_label_keyed_inheritance() { gld_check product-manager.md; }
test_gld_delivery_lead_label_keyed_inheritance() { gld_check delivery-lead.md; }
run_test test_gld_product_manager_label_keyed_inheritance
run_test test_gld_delivery_lead_label_keyed_inheritance
