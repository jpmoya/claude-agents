# Issue #25 — README.md's "Status board" paragraph records the deployed status page: live URL,
# Worker name, KV namespace title + id, and workers.dev subdomain (all public identifiers), and
# never a token value.

HERE_R25=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
README_R25="$HERE_R25/../../../README.md"

# The Status board entry is one line, starting with its bold lead-in.
status_board_r25() { grep -F '**Status board (issue #10' "$README_R25"; }

test_r25_status_board_links_the_live_url() {
  local section
  section=$(status_board_r25)
  assert_ne "$section" "" "AC1: README.md must have the Status board entry" || return 1
  assert_contains "$section" "https://status-page.jpmoya.workers.dev" "AC1: Status board entry must link the deployed page" || return 1
}

test_r25_status_board_records_worker_and_kv_identifiers() {
  local section
  section=$(status_board_r25)
  assert_contains "$section" '`status-page`' "AC2: Worker name" || return 1
  assert_contains "$section" '`STATUS`' "AC2: KV namespace title" || return 1
  assert_contains "$section" "251e3cc206b14ea7a78b3bb17f8ea1e3" "AC2: KV namespace id" || return 1
  assert_contains "$section" '`jpmoya`' "AC2: workers.dev subdomain" || return 1
}

test_r25_status_board_carries_no_token_value() {
  local section leak
  section=$(status_board_r25)
  # No assignment of a secret, and no long opaque string other than the (public) KV namespace id.
  leak=$(printf '%s\n' "$section" | grep -oE 'STATUS_PUSH_TOKEN[[:space:]]*=[[:space:]]*[^[:space:]]+|TOKEN_(MAC|VM)[[:space:]]*=[[:space:]]*[^[:space:]]+' || true)
  assert_eq "$leak" "" "AC3: Status board entry must not assign a token value" || return 1
  leak=$(printf '%s\n' "$section" | grep -oE '[A-Za-z0-9_-]{32,}' | grep -vxF '251e3cc206b14ea7a78b3bb17f8ea1e3' || true)
  assert_eq "$leak" "" "AC3: Status board entry must not carry any long opaque (token-shaped) string" || return 1
}

run_test test_r25_status_board_links_the_live_url
run_test test_r25_status_board_records_worker_and_kv_identifiers
run_test test_r25_status_board_carries_no_token_value
