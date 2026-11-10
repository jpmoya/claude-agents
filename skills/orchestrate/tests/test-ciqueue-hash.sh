# Issue #643 AC9 — report-status.sh's hash_payload excludes `ci_queue.as_of` the same way it
# already excludes sent_at/supervisor_last_tick, so an unchanged CI-queue snapshot (same counts,
# new as_of) doesn't look like a payload change and doesn't force an extra KV write. Sits
# alongside test-ac12-write-budget.sh's write-budget suite, reusing its fixture helpers
# (setup_pushable_fixture, count_curl_calls, now_epoch).
#
# Exercised end-to-end through the real push path (report-status.sh event, with a counting fake
# curl on PATH) rather than by reimplementing hash_payload's formula in the test — that way a
# regression in the actual function (e.g. popping the whole ci_queue object instead of just
# as_of) shows up as a wrong curl-call count, not as a test that merely agrees with itself.
#
# Unlike AC12's write_counting_fake_curl (which only needs to prove a call did/didn't happen),
# this test chains three real pushes and needs each successful one to actually update last_hash —
# so the stub must also emit a 2xx status for `-w '%{http_code}'` to capture, or every push
# "fails" (status 000) and the next one always retries regardless of the hash.

HERE_CIQH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_CIQH="$HERE_CIQH/.."

_ciqh_write_ok_curl() {  # <bindir> — records each call AND reports a 204 so the push is treated as successful
  cat > "$1/curl" <<'EOF'
#!/bin/bash
echo "1" >> "$(dirname "$0")/curl.calls"
printf '%s' "204"
exit 0
EOF
  chmod +x "$1/curl"
}

_ciqh_golden() {  # <as_of> [queued_total] -> the golden ci_queue JSON with that as_of/queued_total
  jq -n --arg t "$1" --argjson qt "${2:-5}" '{as_of:$t, runners_busy:2, runners_total:4, queued_total:$qt,
    categories:[{key:"dependabot",count:1},{key:"deploy_release",count:1},{key:"pr",count:2},{key:"other",count:1}],
    oldest:{key:"deploy_release",queued_at:"2026-09-21T11:45:00Z"}}'
}

_ciqh_push() {  # _ciqh_push <pipe> <home> <bindir> -> runs one `report-status.sh event`
  ( PIPE="$1" QUEUE="$1/queue" HOME="$2" PATH="$3:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" "$RS_CIQH/report-status.sh" event )
}

_ciqh_age_last_attempt() {  # _ciqh_age_last_attempt <pipe> <secs> — backdate last_attempt_epoch so only the hash decides
  local pipe=$1 secs=$2 t
  t=$(now_epoch)
  python3 -c "
import json
d = json.load(open('$pipe/status-push.state'))
d['last_attempt_epoch'] = $t - $secs
json.dump(d, open('$pipe/status-push.state', 'w'))
"
}

test_ciqueue_as_of_only_change_coalesces_then_a_real_count_change_pushes() {
  local pipe home bindir calls1 calls2 calls3
  pipe=$(new_pipe); home=$(new_home); bindir=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-bin.XXXXXX")
  setup_pushable_fixture "$pipe" "$home"
  _ciqh_golden "2026-09-21T12:00:00Z" > "$pipe/status-ci.json"
  _ciqh_write_ok_curl "$bindir"

  _ciqh_push "$pipe" "$home" "$bindir"
  calls1=$(count_curl_calls "$bindir")

  # Same counts, new as_of only: must NOT push again once the interval alone would otherwise allow it.
  _ciqh_golden "2026-09-21T12:10:00Z" > "$pipe/status-ci.json"
  _ciqh_age_last_attempt "$pipe" 300
  _ciqh_push "$pipe" "$home" "$bindir"
  calls2=$(count_curl_calls "$bindir")

  # A real count change (queued_total 5 -> 9): must push.
  _ciqh_golden "2026-09-21T12:20:00Z" 9 > "$pipe/status-ci.json"
  _ciqh_age_last_attempt "$pipe" 300
  _ciqh_push "$pipe" "$home" "$bindir"
  calls3=$(count_curl_calls "$bindir")

  cleanup_running; rm -rf "$pipe" "$home" "$bindir"

  assert_eq "$calls1" "1" "AC9: initial push (first-ever hash) pushes once" || return 1
  assert_eq "$calls2" "1" "AC9: ci_queue.as_of-only change makes no new curl call (still coalesced)" || return 1
  assert_eq "$calls3" "2" "AC9 (negative case): a real ci_queue count change still pushes" || return 1
}

run_test test_ciqueue_as_of_only_change_coalesces_then_a_real_count_change_pushes
