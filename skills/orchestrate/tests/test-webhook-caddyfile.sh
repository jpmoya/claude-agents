# #773 — infra/webhook/Caddyfile matches what runs on the VM (checked 2026-11-19): Caddy bound to the VM's public address only, and the
# access-log filter's deletes inside `fields { }`. The address is a placeholder in the public file; the runbook's sed fills it.
CF_ROOT=$(cd "$HERE/../../.." && pwd)

test_cf_binds_to_the_vm_address_placeholder_and_the_runbook_fills_it() {
  local cf doc; cf=$(cat "$CF_ROOT/infra/webhook/Caddyfile"); doc=$(cat "$CF_ROOT/docs/webhook-events.md")
  assert_contains "$cf" "	bind @VM_PUBLIC_IP@" "bind line with the placeholder" || return 1
  assert_not_contains "$cf" "178." "no real address in the public file" || return 1
  assert_contains "$doc" 's/@VM_PUBLIC_IP@/' "runbook sed fills the address" || return 1
}
test_cf_log_filter_deletes_sit_inside_a_fields_block() {
  local inner
  inner=$(awk '/fields \{/ {f=1; next} f && /^[ \t]*\}/ {exit} f {print}' "$CF_ROOT/infra/webhook/Caddyfile")
  assert_contains "$inner" "request>headers>Authorization delete" "Authorization removed from the log" || return 1
  assert_contains "$inner" "request>headers>X-Hub-Signature-256 delete" "signature removed from the log" || return 1
  assert_contains "$inner" "request>headers>X-Hub-Signature delete" "legacy signature removed from the log" || return 1
}

for t in $(declare -F | awk '{print $3}' | grep '^test_cf_'); do run_test "$t"; done
