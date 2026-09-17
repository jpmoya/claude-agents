# AC14 — `orchestrate.sh status` output is byte-for-byte identical, against a fixture /tmp/pipeline
# tree, before and after the shared state-derivation refactor. Editing the golden to make this pass
# is not an acceptable way to satisfy the criterion (ticket text, verbatim).
#
# This is a regression guard, not a feature test: it is expected to be GREEN right now, since
# `orchestrate.sh` on this branch is still the pre-refactor script the golden was captured from.
# It goes red the moment the state-derivation refactor changes a byte of `status` output that
# isn't the one documented addition (the "!! status push failing" line, which needs >=3
# consecutive push failures in the cache — a state this fixture never reaches, so the golden has
# no such line and none should appear).
#
# Golden capture command (re-run this to regenerate the goldens under fixtures/golden/ if the
# fixture below changes — never hand-edit the golden files):
#   HOME=<fresh empty dir with .claude/pipeline/> \
#   PATH=<repo>/skills/orchestrate/tests/bin:/usr/bin:/bin \
#   PIPE=<fixture pipe dir> QUEUE=$PIPE/queue \
#   ./orchestrate.sh status [<issue>] \
#   | sed -e "s#$PIPE#@@PIPE@@#g" -e "s#$REPO_A#@@REPOA@@#g" -e "s#$REPO_B#@@REPOB@@#g" \
#         -e "s/pid [0-9][0-9]*/pid @@PID@@/g"
# (captured against this repo's pre-refactor orchestrate.sh at HEAD; fixture: #101 running,
#  #102 exited/will-auto-restart, #103 held with an .alert, #104 queued — see build_golden_fixture()).

HERE_AC14=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GOLDEN_DIR="$HERE_AC14/fixtures/golden"
FAKEBIN="$HERE_AC14/bin"
ORCH="$HERE_AC14/../orchestrate.sh"

AC14_PIDS=""

# build_golden_fixture <pipe> <repo_a> <repo_b> — the exact fixture the goldens were captured
# against. #101 running, #102 exited (no marker files, dead pid, no .stopped/.held/.done),
# #103 held with an alert, #104 queued. Repo names are placeholders (project-a/-b), never real.
build_golden_fixture() {
  local pipe=$1 repo_a=$2 repo_b=$3
  mkdir -p "$pipe/queue"

  sleep 300 &
  local pid101=$!
  AC14_PIDS="$AC14_PIDS $pid101"
  echo "$pid101" > "$pipe/orch-101.pid"
  echo "$repo_a" > "$pipe/orch-101.repo"

  ( : ) & local pid102=$!; wait "$pid102" 2>/dev/null
  echo "$pid102" > "$pipe/orch-102.pid"
  echo "$repo_b" > "$pipe/orch-102.repo"

  ( : ) & local pid103=$!; wait "$pid103" 2>/dev/null
  echo "$pid103" > "$pipe/orch-103.pid"
  echo "$repo_a" > "$pipe/orch-103.repo"
  touch "$pipe/orch-103.held"
  printf '2026-09-17T00:00:00Z Pipeline #103 waiting on JP\n' > "$pipe/orch-103.alert"

  python3 -c "
import json
json.dump({'issue':'104','repo':'$repo_b','extra':'','reason':'queued','queued_at':'2026-09-17T00:00:00Z','not_before':0}, open('$pipe/queue/orch-104.json','w'))
"
}

# run_status_normalized <pipe> <repo_a> <repo_b> [issue] — runs the real orchestrate.sh status
# against the fixture, with the fake `gh` on PATH (a true external, mocked at the wrapper
# boundary the script already uses) and a HOME with no real ~/.local/bin/gh to shadow it, then
# applies the same normalization the golden was captured with.
run_status_normalized() {
  local pipe=$1 repo_a=$2 repo_b=$3 issue=${4:-}
  local fake_home resolved_gh
  fake_home=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-home.XXXXXX")
  mkdir -p "$fake_home/.claude/pipeline"
  # Guard against the real gh silently shadowing the fake one (e.g. if HOME/.local/bin ever
  # reappears on some future host) — a golden test that quietly hit the network would prove
  # nothing and could leak a real repo name (AC5/AC17).
  resolved_gh=$(HOME="$fake_home" PATH="$FAKEBIN:/usr/bin:/bin" command -v gh)
  if [ "$resolved_gh" != "$FAKEBIN/gh" ]; then
    echo "AC14 test infra broken: real gh ($resolved_gh) shadows the fake one ($FAKEBIN/gh)" >&2
    rm -rf "$fake_home"
    return 1
  fi
  ( HOME="$fake_home" PATH="$FAKEBIN:/usr/bin:/bin" PIPE="$pipe" QUEUE="$pipe/queue" "$ORCH" status $issue ) 2>&1 \
    | sed -e "s#$pipe#@@PIPE@@#g" -e "s#$repo_a#@@REPOA@@#g" -e "s#$repo_b#@@REPOB@@#g" \
          -e "s/pid [0-9][0-9]*/pid @@PID@@/g"
  rm -rf "$fake_home"
}

test_ac14_status_golden_full() {
  local pipe repo_a repo_b actual expected
  pipe=$(new_pipe); repo_a=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX"); repo_b=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX")
  build_golden_fixture "$pipe" "$repo_a" "$repo_b"
  actual=$(run_status_normalized "$pipe" "$repo_a" "$repo_b")
  expected=$(cat "$GOLDEN_DIR/status-full.txt")
  for p in $AC14_PIDS; do kill "$p" 2>/dev/null; done; AC14_PIDS=""
  rm -rf "$pipe" "$repo_a" "$repo_b"
  assert_eq "$actual" "$expected" "status (no filter) byte-identical to pre-refactor golden" || return 1
}

test_ac14_status_golden_single_match() {
  local pipe repo_a repo_b actual expected
  pipe=$(new_pipe); repo_a=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX"); repo_b=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX")
  build_golden_fixture "$pipe" "$repo_a" "$repo_b"
  actual=$(run_status_normalized "$pipe" "$repo_a" "$repo_b" 101)
  expected=$(cat "$GOLDEN_DIR/status-single-match.txt")
  for p in $AC14_PIDS; do kill "$p" 2>/dev/null; done; AC14_PIDS=""
  rm -rf "$pipe" "$repo_a" "$repo_b"
  assert_eq "$actual" "$expected" "status <matching issue> byte-identical to pre-refactor golden" || return 1
}

# The subtle byte: filtering to an issue with NO matching orch-*.pid does not print
# "no orchestrators recorded" (that only fires when the glob itself is empty) and prints no
# per-run line — but the alert and queued sections are NOT issue-filtered and still print.
# This is the exact "found=1-after-the-issue-filter behaviour" the design says must survive
# the refactor verbatim.
test_ac14_status_golden_filtered_no_match() {
  local pipe repo_a repo_b actual expected
  pipe=$(new_pipe); repo_a=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX"); repo_b=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-repo.XXXXXX")
  build_golden_fixture "$pipe" "$repo_a" "$repo_b"
  actual=$(run_status_normalized "$pipe" "$repo_a" "$repo_b" 999999)
  expected=$(cat "$GOLDEN_DIR/status-filtered-nomatch.txt")
  for p in $AC14_PIDS; do kill "$p" 2>/dev/null; done; AC14_PIDS=""
  rm -rf "$pipe" "$repo_a" "$repo_b"
  assert_eq "$actual" "$expected" "status <non-matching issue> byte-identical to pre-refactor golden (no false 'no orchestrators recorded')" || return 1
}

run_test test_ac14_status_golden_full
run_test test_ac14_status_golden_single_match
run_test test_ac14_status_golden_filtered_no_match
