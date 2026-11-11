# #645 code-review follow-up (MEDIUM finding 1) — infra/ci-runners/ci-queue-collect.sh's `oldest`
# must never be systematically wrong by construction. Two independent biases, covered separately:
#
#   test_ciqt_queued_run_not_starved_by_in_progress_runs — the run-lookup cap (5) used to be spent
#   on whichever runs had the lowest ids after a plain `unique_by(.id)` merge of queued+in_progress.
#   In_progress runs generally have lower ids (they started earlier) than queued ones, so a repo
#   with >= 5 in_progress runs plus a genuinely queued run could spend the whole cap on runs with
#   zero queued jobs and report `oldest: null` while work was actually waiting.
#
#   test_ciqt_last_page_fetch_finds_the_true_oldest_queued_run — GitHub's run-list endpoint always
#   returns newest-first (no sort/direction query param); a queued backlog deeper than one page
#   hides the genuinely oldest run on a later page that was never fetched at all.
#
# Self-contained: does not depend on test-ciqueue-collector.sh's helpers (load order between
# test-*.sh files is incidental, not a contract). Prefix _ciqt_ / CIQT. Placeholder repo names
# only (public repo).

HERE_CIQT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT_CIQT=$(cd "$HERE_CIQT/../../.." && pwd)
COLLECTOR_CIQT="$REPO_ROOT_CIQT/infra/ci-runners/ci-queue-collect.sh"

_ciqt_runners_fixtures() {  # <dir> — minimal valid runner-list fixtures (required before the repo loop runs)
  echo '{"total_count":1,"runners":[{"id":1,"busy":false}]}' > "$1/runners-org.json"
  echo '{"total_count":1,"runners":[{"id":2,"busy":false}]}' > "$1/runners-repo.json"
}

_ciqt_repos_file() {  # <dir> <repo...> -> prints a path to a repos file listing the given repos
  local dir=$1; shift
  local f="$dir/repos.txt"
  printf '%s\n' "$@" > "$f"
  printf '%s' "$f"
}

_ciqt_run() {  # _ciqt_run <pipe> <fixturedir> <reposfile> -> sets CIQT_OUT / CIQT_CALLS, returns the collector's exit code
  local pipe=$1 fixdir=$2 reposfile=$3 rc
  ( CI_QUEUE_FORCE=1 \
    CI_QUEUE_OUT="$pipe/status-ci.json" \
    CI_QUEUE_ATTEMPT_FILE="$pipe/attempt" \
    CI_QUEUE_STATE_FILE="$pipe/state.json" \
    CI_QUEUE_LOCKDIR="$pipe/lockdir" \
    CI_QUEUE_CALL_LOG="$pipe/calls.log" \
    CI_QUEUE_REPOS_FILE="$reposfile" \
    CI_QUEUE_FIXTURE_DIR="$fixdir" \
    bash "$COLLECTOR_CIQT" )
  rc=$?
  CIQT_OUT=$(cat "$pipe/status-ci.json" 2>/dev/null)
  CIQT_CALLS=$(cat "$pipe/calls.log" 2>/dev/null)
  return "$rc"
}

test_ciqt_queued_run_not_starved_by_in_progress_runs() {
  local pipe fixdir reposfile rc oldest i
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciqt_runners_fixtures "$fixdir"
  reposfile=$(_ciqt_repos_file "$fixdir" "example-owner/project-a")

  # 6 in_progress runs (ids 601-606, lower than the queued run's id) with no queued jobs at all,
  # plus exactly 1 queued run (id 701) with 1 genuinely queued job.
  local runs='['
  for i in 601 602 603 604 605 606; do
    runs="$runs{\"id\":$i,\"name\":\"CI\",\"event\":\"push\",\"actor\":{\"login\":\"someone\"}},"
    echo "{\"jobs\":[{\"id\":$((i+9000)),\"status\":\"in_progress\",\"created_at\":\"2026-11-10T00:00:00Z\"}]}" > "$fixdir/jobs-$i.json"
  done
  runs="${runs%,}]"
  echo "{\"workflow_runs\":$runs}" > "$fixdir/runs-example-owner__project-a-in_progress.json"
  echo '{"workflow_runs":[{"id":701,"name":"CI","event":"schedule","actor":{"login":"someone"}}]}' > "$fixdir/runs-example-owner__project-a-queued.json"
  echo '{"jobs":[{"id":9701,"status":"queued","created_at":"2026-01-01T00:00:00Z"}]}' > "$fixdir/jobs-701.json"

  _ciqt_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  oldest=$(printf '%s' "$CIQT_OUT" | jq -c '.oldest')
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$oldest" '{"key":"other","queued_at":"2026-01-01T00:00:00Z"}' "the queued run's job is found despite 6 lower-id in_progress runs filling most of the cap" || return 1
}

test_ciqt_last_page_fetch_finds_the_true_oldest_queued_run() {
  local pipe fixdir reposfile rc oldest calls
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciqt_runners_fixtures "$fixdir"
  reposfile=$(_ciqt_repos_file "$fixdir" "example-owner/project-b")

  # Page 1 (what a plain per_page fetch returns): total_count says there are more pages; the one
  # run on this page is recent. The true oldest queued run (id 1001, far lower) only exists on the
  # last page (page 2 at PER_PAGE=100) — a fixture the OLD code never requested at all.
  echo '{"total_count":101,"workflow_runs":[{"id":9001,"name":"CI","event":"schedule","actor":{"login":"someone"}}]}' > "$fixdir/runs-example-owner__project-b-queued.json"
  echo '{"workflow_runs":[{"id":1001,"name":"CI","event":"schedule","actor":{"login":"someone"}}]}' > "$fixdir/runs-example-owner__project-b-queued-lastpage.json"
  echo '{"workflow_runs":[]}' > "$fixdir/runs-example-owner__project-b-in_progress.json"
  echo '{"jobs":[{"id":99001,"status":"queued","created_at":"2026-11-10T23:00:00Z"}]}' > "$fixdir/jobs-9001.json"
  echo '{"jobs":[{"id":91001,"status":"queued","created_at":"2020-01-01T00:00:00Z"}]}' > "$fixdir/jobs-1001.json"

  _ciqt_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  oldest=$(printf '%s' "$CIQT_OUT" | jq -c '.oldest')
  calls=$CIQT_CALLS
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  assert_eq "$oldest" '{"key":"other","queued_at":"2020-01-01T00:00:00Z"}' "oldest comes from the last-page run (id 1001), not the recent page-1 run (id 9001)" || return 1
  # 2 (runners) + 2 (queued + in_progress page-1 lists) + 1 (the extra last-page fetch) + 2 (job lookups for both runs) = 7
  assert_eq "$calls" "7" "exactly one extra call was made for the last-page fetch" || return 1
}

test_ciqt_no_extra_call_when_backlog_fits_one_page() {
  local pipe fixdir reposfile rc calls
  pipe=$(mktemp -d); fixdir=$(mktemp -d)
  _ciqt_runners_fixtures "$fixdir"
  reposfile=$(_ciqt_repos_file "$fixdir" "example-owner/project-c")

  # No total_count key at all (as the plain fixtures elsewhere in this suite look) -> treated as
  # "this page is everything" -> no last-page fetch, no extra call.
  echo '{"workflow_runs":[{"id":1,"name":"CI","event":"schedule","actor":{"login":"someone"}}]}' > "$fixdir/runs-example-owner__project-c-queued.json"
  echo '{"workflow_runs":[]}' > "$fixdir/runs-example-owner__project-c-in_progress.json"
  echo '{"jobs":[{"id":2,"status":"queued","created_at":"2026-11-10T00:00:00Z"}]}' > "$fixdir/jobs-1.json"

  _ciqt_run "$pipe" "$fixdir" "$reposfile"; rc=$?
  calls=$CIQT_CALLS
  rm -rf "$pipe" "$fixdir"

  assert_exit0 "$rc" "collector still exits 0" || return 1
  # 2 (runners) + 2 (queued + in_progress) + 1 (job lookup) = 5 — no last-page call made
  assert_eq "$calls" "5" "a backlog within one page never triggers the extra last-page fetch" || return 1
}

run_test test_ciqt_queued_run_not_starved_by_in_progress_runs
run_test test_ciqt_last_page_fetch_finds_the_true_oldest_queued_run
run_test test_ciqt_no_extra_call_when_backlog_fits_one_page
