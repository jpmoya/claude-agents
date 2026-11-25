# #827: a held ticket whose newest routing marker is JP's relayed `**[jp] GO**` (after a machine-class BLOCKED the supervisor does not
# relay) is labelled parked_reason=jp_go, so the status page stops calling it "paused, no one on it"; the payload carries the fixed label.
# Reuses the ar_ helpers of test-status-auto-retry-reconcile.sh (this file loads after it). Placeholder repo names only. Bash 3.2 portable.

jg_two_comments() {  # jg_two_comments <issue> <second marker line>
  local n=$1
  mk_held "$AR_PIPE" "$n" "$AR_REPO"; printf 'Title of %s\n' "$n" > "$(rkp "$AR_PIPE/orch-$n.title")"
  jq -nc --arg g '**[deployer] BLOCKED**
Blocked on: ci_red — finished red (real failure)' --arg a "$2" \
    '[{body:$g, createdAt:"2026-09-20T10:00:00Z", author:{login:"jp"}}, {body:$a, createdAt:"2026-09-20T11:00:00Z", author:{login:"jp"}}]' > "$AR_BIN/gh-issue-comments-json-$n"
}

test_jg_jp_go_after_machine_blocked_is_jp_go() {
  ar_env; jg_two_comments 601 '**[jp] GO**
JP said: "go on all of these blocked tickets"'
  ar_reconcile
  local r out f; r=$(ar_file "$(rkp "$AR_PIPE/orch-601.parked_reason")"); out=$(ar_print); f=$(ar_field "$out" 601 parked_reason)
  ar_cleanup
  assert_eq "$r" "jp_go" "newest marker [jp] GO on a held ticket -> parked_reason jp_go" || return 1
  assert_eq "$f" "jp_go" "the payload carries the fixed label" || return 1
}

test_jg_plain_machine_blocked_is_not_jp_go() {
  ar_env; ar_gate 602 '**[deployer] BLOCKED**' 'Blocked on: needs_jp — which vendor?'
  ar_reconcile
  local r; r=$(ar_file "$(rkp "$AR_PIPE/orch-602.parked_reason")")
  ar_cleanup
  assert_eq "$r" "ABSENT" "a ticket without a newest [jp] GO never gets jp_go" || return 1
}

run_test test_jg_jp_go_after_machine_blocked_is_jp_go
run_test test_jg_plain_machine_blocked_is_not_jp_go
