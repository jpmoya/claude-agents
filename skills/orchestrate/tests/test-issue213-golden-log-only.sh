# #213 AC9 — "tests/run-tests.sh green; the golden changes only in the `log=` field".
# fixtures/golden-pre213/ holds hand-copied, frozen pre-change goldens (the files as they stood at the
# parent of this ticket). With the `log=<value>` field stripped from every line, the live goldens
# under fixtures/golden/ must be byte-identical to them: any other re-baselined byte fails here.
# Placeholders only. Bash 3.2 portable.

HERE_RK5=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

rk5_strip_log() { sed -E 's/ +log=[^ ]*//' "$1"; }

rk5_check() {  # rk5_check <golden-name>
  local live="$HERE_RK5/fixtures/golden/$1.txt" frozen="$HERE_RK5/fixtures/golden-pre213/$1.txt"
  [ -f "$live" ] || { echo "missing live golden $1" >&2; return 1; }
  [ -f "$frozen" ] || { echo "missing frozen golden $1" >&2; return 1; }
  assert_eq "$(rk5_strip_log "$live")" "$(rk5_strip_log "$frozen")" "golden $1 differs from pre-#213 beyond log=" || return 1
}

test_rk5_golden_full_changes_only_log_field() { rk5_check status-full; }
test_rk5_golden_single_match_changes_only_log_field() { rk5_check status-single-match; }
test_rk5_golden_filtered_nomatch_changes_only_log_field() { rk5_check status-filtered-nomatch; }

test_rk5_golden_log_field_is_repo_keyed() {
  local f="$HERE_RK5/fixtures/golden/status-full.txt" n
  n=$(grep -c 'log=@@PIPE@@/orch-[0-9][0-9]*\.log' "$f")
  assert_eq "$n" "0" "no number-only log= path remains in status-full golden" || return 1
  n=$(grep -c ' log=@@PIPE@@/orch-' "$f")
  assert_eq "$n" "3" "the three run lines still carry a log= under orch-" || return 1
}

run_test test_rk5_golden_full_changes_only_log_field
run_test test_rk5_golden_single_match_changes_only_log_field
run_test test_rk5_golden_filtered_nomatch_changes_only_log_field
run_test test_rk5_golden_log_field_is_repo_keyed
