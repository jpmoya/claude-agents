# Audit 2026-11-18: _gh_since_unmark_synced built `sed "s/ $r / /"` from an owner/repo, so the "/" in the repo name broke
# the expression ("bad flag in substitute command", 28 supervisor.log lines on 2026-11-18) and emptied the whole synced set.
# Unmarking one repo must leave every other synced repo trusted, and print nothing on stderr.
GB_SU="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../gh-budget.sh"

test_su_unmark_removes_only_that_repo() {
  local d out err
  d=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-su.XXXXXX")
  out=$(PIPE="$d" LOGDIR="$d/log" GH_BUDGET_ENABLED=1 bash -c ". '$GB_SU'
    _gh_since_mark_synced Proj-A/Repo-One; _gh_since_mark_synced proj-b/repo-two
    _gh_since_unmark_synced proj-a/repo-one
    _gh_since_synced proj-a/repo-one && echo one-trusted || echo one-untrusted
    _gh_since_synced proj-b/repo-two && echo two-trusted || echo two-untrusted" 2>"$d/err")
  err=$(cat "$d/err"); rm -rf "$d"
  assert_eq "$(echo $out)" "one-untrusted two-trusted" "unmark of one owner/repo keeps the other repo synced" || return 1
  assert_eq "$err" "" "no sed error on stderr" || return 1
}

run_test test_su_unmark_removes_only_that_repo
