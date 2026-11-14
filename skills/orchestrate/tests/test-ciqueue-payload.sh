# Issue #643 AC7 — report-status.sh --print includes a well-formed `ci_queue` key when
# $PIPE/status-ci.json is present and fresh, matching the fixture; omits the key entirely
# (never null/empty) when the file is absent or older than the staleness cutoff.
#
# Exercised through `report-status.sh --print` (no lock, no network, no state write), same
# entry point ACs 1/2/5 use.

HERE_CIQP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_CIQP="$HERE_CIQP/.."

_ciqp_print() {  # _ciqp_print <pipe> <home>
  ( PIPE="$1" QUEUE="$1/queue" HOME="$2" "$RS_CIQP/report-status.sh" --print )
}

# The golden fixture — kept in sync by hand with the validate.js AC8(a) fixture
# (status-page/test/fixtures.js validCiQueue()); both encode the same Expected Behavior shape
# from the issue, independently, so a producer/validator drift shows up as a test failure on
# whichever side regresses first.
_ciqp_golden() {
  cat <<'JSON'
{"as_of":"2026-09-21T12:00:00Z","runners_busy":2,"runners_total":4,"queued_total":5,"categories":[{"key":"dependabot","count":1},{"key":"deploy_release","count":1},{"key":"pr","count":2},{"key":"other","count":1}],"oldest":{"key":"deploy_release","queued_at":"2026-09-21T11:45:00Z"}}
JSON
}

test_ciqueue_fresh_snapshot_included_verbatim() {
  local pipe home out got
  pipe=$(new_pipe); home=$(new_home)
  _ciqp_golden > "$pipe/status-ci.json"

  out=$(_ciqp_print "$pipe" "$home")
  got=$(printf '%s' "$out" | jq -c '.ci_queue')
  rm -rf "$pipe" "$home"

  assert_eq "$got" "$(_ciqp_golden | jq -c .)" "AC7: ci_queue in the printed payload matches the fixture" || return 1
}

test_ciqueue_absent_file_omits_key_entirely() {
  local pipe home out has
  pipe=$(new_pipe); home=$(new_home)

  out=$(_ciqp_print "$pipe" "$home")
  has=$(printf '%s' "$out" | jq 'has("ci_queue")')
  rm -rf "$pipe" "$home"

  assert_eq "$has" "false" "AC7: no status-ci.json -> no ci_queue key (not null, not empty)" || return 1
}

test_ciqueue_stale_file_omits_key_entirely() {
  local pipe home out has
  pipe=$(new_pipe); home=$(new_home)
  _ciqp_golden > "$pipe/status-ci.json"
  # Backdate well past the 2h staleness cutoff (issue #663 AC1a raised STATUS_CI_STALE_SECS from
  # 1200s/20min to 7200s/2h — see report-status.sh's own comment for why).
  python3 -c "import os,sys; t=__import__('time').time()-7300; os.utime(sys.argv[1], (t, t))" "$pipe/status-ci.json"

  out=$(_ciqp_print "$pipe" "$home")
  has=$(printf '%s' "$out" | jq 'has("ci_queue")')
  rm -rf "$pipe" "$home"

  assert_eq "$has" "false" "AC7: a status-ci.json older than the staleness cutoff is omitted, not sent stale" || return 1
}

test_ciqueue_just_inside_staleness_cutoff_is_included() {
  local pipe home out has
  pipe=$(new_pipe); home=$(new_home)
  _ciqp_golden > "$pipe/status-ci.json"
  python3 -c "import os,sys; t=__import__('time').time()-7100; os.utime(sys.argv[1], (t, t))" "$pipe/status-ci.json"

  out=$(_ciqp_print "$pipe" "$home")
  has=$(printf '%s' "$out" | jq 'has("ci_queue")')
  rm -rf "$pipe" "$home"

  assert_eq "$has" "true" "AC7: a status-ci.json inside the staleness cutoff is still included" || return 1
}

test_ciqueue_garbage_file_never_breaks_the_rest_of_the_beat() {
  local pipe home out running has repo
  pipe=$(new_pipe); home=$(new_home)
  repo="$pipe/repo-project-a"; fixture_repo "$repo" "example-owner/project-a"
  mk_running "$pipe" 301 "$repo"
  printf 'not { valid json at all' > "$pipe/status-ci.json"

  out=$(_ciqp_print "$pipe" "$home")
  has=$(printf '%s' "$out" | jq 'has("ci_queue")' 2>/dev/null)
  running=$(printf '%s' "$out" | jq '[.runs[] | select(.issue==301)] | length' 2>/dev/null)
  cleanup_running; rm -rf "$pipe" "$home"

  assert_eq "$has" "false" "AC7: a garbage status-ci.json omits ci_queue, does not 500/break --print" || return 1
  assert_eq "$running" "1" "AC7: the rest of the payload (runs[]) is unaffected by a garbage status-ci.json" || return 1
}

run_test test_ciqueue_fresh_snapshot_included_verbatim
run_test test_ciqueue_absent_file_omits_key_entirely
run_test test_ciqueue_stale_file_omits_key_entirely
run_test test_ciqueue_just_inside_staleness_cutoff_is_included
run_test test_ciqueue_garbage_file_never_breaks_the_rest_of_the_beat
