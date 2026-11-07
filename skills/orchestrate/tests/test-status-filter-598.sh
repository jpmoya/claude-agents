# Issue #598 — `status <N>` derives only the requested run; the process scan runs once per derive_runs call.
HERE_SF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SK_SF="$HERE_SF/.."

# sf_fixture <pipe> <repo> <count> — <count> dead-pid keyed records for tickets 1..count in <repo>
sf_fixture() {
  local pipe=$1 repo=$2 n=$3 i k
  for i in $(seq 1 "$n"); do
    k=$(rk "$repo" "$i")
    echo 999999 > "$pipe/orch-$k.pid"; echo "$repo" > "$pipe/orch-$k.repo"
  done
}

sf_ps_stub() {  # sf_ps_stub <counter file> -> RS_PS_CMD string
  printf 'echo x >> %s' "$1"
}

test_sf_1_derive_runs_key_and_scan_once() {
  local pipe repo cnt k all one none c_all c_one c_none
  pipe=$(new_pipe); repo=$(mktemp -d "${TMPDIR:-/tmp}/sf-repo.XXXXXX"); fixture_repo "$repo" project-a/app
  sf_fixture "$pipe" "$repo" 60; cnt=$(mktemp "${TMPDIR:-/tmp}/sf-cnt.XXXXXX"); k=$(rk "$repo" 7)
  all=$( PIPE=$pipe QUEUE=$pipe/queue RS_PS_CMD=$(sf_ps_stub "$cnt") bash -c ". '$SK_SF/run-state.sh'; derive_runs" ); c_all=$(wc -l < "$cnt"); : > "$cnt"
  one=$( PIPE=$pipe QUEUE=$pipe/queue RS_PS_CMD=$(sf_ps_stub "$cnt") bash -c ". '$SK_SF/run-state.sh'; derive_runs '$k'" ); c_one=$(wc -l < "$cnt"); : > "$cnt"
  none=$( PIPE=$pipe QUEUE=$pipe/queue RS_PS_CMD=$(sf_ps_stub "$cnt") bash -c ". '$SK_SF/run-state.sh'; derive_runs __no-match__" ); c_none=$(wc -l < "$cnt")
  rm -rf "$pipe" "$repo" "$cnt"
  assert_eq "$(printf '%s\n' "$all" | wc -l | tr -d ' ')" "60" "#598: unfiltered derives all 60" || return 1
  assert_eq "$(printf '%s\n' "$all" | grep -c "^7	")" "1" "#598: unfiltered has ticket 7 once" || return 1
  assert_eq "$one" "$(printf '%s\n' "$all" | grep "^7	")" "#598: keyed record identical to unfiltered row" || return 1
  assert_eq "$none" "" "#598: no-match key derives nothing" || return 1
  [ "$c_all" -le 1 ] || { fail "#598: unfiltered scanned $c_all times"; return 1; }
  [ "$c_one" -le 1 ] || { fail "#598: keyed scanned $c_one times"; return 1; }
  [ "$c_none" -le 1 ] || { fail "#598: no-match scanned $c_none times"; return 1; }
  [ "$c_all" -eq 1 ] || { fail "#598: unfiltered should scan exactly once, got $c_all"; return 1; }
}

test_sf_2_status_single_ticket_scans_once() {
  local pipe repo home cnt out
  pipe=$(new_pipe); home=$(new_home); repo=$(mktemp -d "${TMPDIR:-/tmp}/sf-repo.XXXXXX"); fixture_repo "$repo" project-a/app
  sf_fixture "$pipe" "$repo" 60; cnt=$(mktemp "${TMPDIR:-/tmp}/sf-cnt.XXXXXX")
  out=$( HOME="$home" PATH="$HERE_SF/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" PIPE="$pipe" QUEUE="$pipe/queue" RS_PS_CMD="$(sf_ps_stub "$cnt")" "$SK_SF/orchestrate.sh" status 7 2>&1 )
  local c; c=$(wc -l < "$cnt")
  rm -rf "$pipe" "$repo" "$home" "$cnt"
  assert_eq "$(printf '%s\n' "$out" | grep -c '^#')" "1" "#598: status 7 prints one run row" || return 1
  printf '%s\n' "$out" | grep -q '^#7  ' || { fail "#598: row is not #7: $out"; return 1; }
  [ "$c" -le 1 ] || { fail "#598: status <N> scanned $c times"; return 1; }
}

run_test test_sf_1_derive_runs_key_and_scan_once
run_test test_sf_2_status_single_ticket_scans_once
