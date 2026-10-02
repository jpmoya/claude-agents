# Issue #140 (host half) — reconcile-status.sh writes/removes orch-<n>.milestone for non-version
# milestones; build-runs-json.py emits runs[].milestone (omitted when no file).
#
#   non-version milestone -> .milestone = title (trimmed, whitespace collapsed, cut to 60 chars)
#   vX.Y.Z milestone      -> no .milestone (existing .release path)
#   no milestone / version-only -> a stale .milestone is removed
#   payload: runs[].milestone present for the first, absent for the others; v stays 1
#
# Placeholder repo names only (public repo). Expected values are hand-written from the ticket.
# Bash 3.2 portable. Fake gh = tests/lib/fixture.sh mk_fake_gh (gh-issue-milestone-<n> = title).

HERE_MS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_MS="$HERE_MS/.."

MS_A="example-owner/project-a"

ms_env() {
  MS_PIPE=$(new_pipe); MS_HOME=$(new_home)
  MS_REPO="$MS_PIPE/repo-project-a"
  fixture_repo "$MS_REPO" "$MS_A"
  MS_BIN="$MS_HOME/.local/bin"
  mk_fake_gh "$MS_BIN"
  echo "$MS_A" > "$MS_BIN/gh-name-with-owner"
  cat > "$MS_HOME/.claude/pipeline/config.local.sh" <<CFG
DISPATCH_REPOS=("$MS_A:$MS_REPO")
STATUS_REPO_ALIASES=("$MS_A:project-a")
MEM_FLOOR_MB=0
CFG
}

ms_cleanup() { cleanup_running; rm -rf "$MS_PIPE" "$MS_HOME"; return 0; }

ms_run() {  # ms_run <script> [args]
  local script=$1; shift
  MS_OUT=$(HOME="$MS_HOME" PATH="$MS_BIN:/usr/bin:/bin" PIPE="$MS_PIPE" QUEUE="$MS_PIPE/queue" LOGDIR="$MS_HOME/logs/pipeline" \
    "$script" "$@" 2>&1)
  MS_RC=$?
}
ms_print() {
  HOME="$MS_HOME" PATH="$MS_BIN:/usr/bin:/bin" PIPE="$MS_PIPE" QUEUE="$MS_PIPE/queue" LOGDIR="$MS_HOME/logs/pipeline" \
    "$RS_MS/report-status.sh" --print 2>/dev/null
}
ms_file() { head -n1 "$MS_PIPE/orch-$1.milestone" 2>/dev/null || echo ABSENT; }
ms_json() {  # ms_json <json> <issue> -> the run's milestone, or MISSING_FIELD / NORUN
  printf '%s' "$1" | jq -r --arg n "$2" \
    '[.runs[] | select((.issue|tostring)==$n)] | if length==0 then "NORUN" else (.[0] | if has("milestone") then .milestone else "MISSING_FIELD" end) end' 2>/dev/null || echo INVALID_JSON
}

test_ms_writes_milestone_file_and_payload_key() {
  ms_env
  mk_held "$MS_PIPE" 701 "$MS_REPO"; echo "Release 3" > "$MS_BIN/gh-issue-milestone-701"
  mk_held "$MS_PIPE" 702 "$MS_REPO"; echo "v1.2.3" > "$MS_BIN/gh-issue-milestone-702"
  mk_held "$MS_PIPE" 703 "$MS_REPO"                                   # no milestone (gh answers null)
  ms_run "$RS_MS/reconcile-status.sh" --force
  local f701 f702 f703 out
  f701=$(ms_file 701); f702=$(ms_file 702); f703=$(ms_file 703)
  out=$(ms_print)
  local rel702; rel702=$(head -n1 "$MS_PIPE/orch-702.release" 2>/dev/null || echo ABSENT)
  ms_cleanup
  assert_eq "$f701" "Release 3" "non-version milestone -> .milestone = title" || return 1
  assert_eq "$f702" "ABSENT" "vX.Y.Z milestone -> no .milestone" || return 1
  assert_eq "$rel702" "v1.2.3" "vX.Y.Z milestone still takes the .release path" || return 1
  assert_eq "$f703" "ABSENT" "no milestone -> no .milestone" || return 1
  assert_eq "$(ms_json "$out" 701)" "Release 3" "payload runs[].milestone present for 701" || return 1
  assert_eq "$(ms_json "$out" 703)" "MISSING_FIELD" "payload omits milestone for 703" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.v')" "1" "payload v stays 1" || return 1
}

test_ms_truncates_to_60_and_collapses_whitespace() {
  ms_env
  local long; long=$(python3 -c "print('x'*100)")
  mk_held "$MS_PIPE" 711 "$MS_REPO"; printf '%s\n' "$long" > "$MS_BIN/gh-issue-milestone-711"
  mk_held "$MS_PIPE" 712 "$MS_REPO"; printf '  Release   3 \t Cleanup  \n' > "$MS_BIN/gh-issue-milestone-712"
  ms_run "$RS_MS/reconcile-status.sh" --force
  local f711 f712 out
  f711=$(ms_file 711); f712=$(ms_file 712); out=$(ms_print)
  ms_cleanup
  assert_eq "${#f711}" "60" "100-char title cut to 60 chars" || return 1
  assert_eq "$f711" "$(python3 -c "print('x'*60)")" "first 60 chars kept" || return 1
  assert_eq "$f712" "Release 3 Cleanup" "trimmed and whitespace collapsed" || return 1
  assert_eq "$(ms_json "$out" 712)" "Release 3 Cleanup" "payload carries the cleaned title" || return 1
}

test_ms_removes_stale_file_when_milestone_gone_or_version_only() {
  ms_env
  mk_held "$MS_PIPE" 721 "$MS_REPO"; echo "Old" > "$MS_PIPE/orch-721.milestone"                      # gh: no milestone
  mk_held "$MS_PIPE" 722 "$MS_REPO"; echo "Old" > "$MS_PIPE/orch-722.milestone"; echo "v2.0.0" > "$MS_BIN/gh-issue-milestone-722"
  mk_held "$MS_PIPE" 723 "$MS_REPO"; echo "Old" > "$MS_PIPE/orch-723.milestone"; echo "New" > "$MS_BIN/gh-issue-milestone-723"
  ms_run "$RS_MS/reconcile-status.sh" --force
  local a b c; a=$(ms_file 721); b=$(ms_file 722); c=$(ms_file 723)
  ms_cleanup
  assert_eq "$a" "ABSENT" "no milestone on GitHub -> stale file removed" || return 1
  assert_eq "$b" "ABSENT" "version-only milestone -> stale file removed" || return 1
  assert_eq "$c" "New" "changed milestone -> file rewritten" || return 1
}

test_ms_building_payload_makes_no_gh_call() {
  ms_env
  mk_held "$MS_PIPE" 731 "$MS_REPO"; echo "Release 3" > "$MS_PIPE/orch-731.milestone"
  local out; out=$(ms_print)
  local calls; calls=$(gh_call_count "$MS_BIN" "")
  ms_cleanup
  assert_eq "$(ms_json "$out" 731)" "Release 3" "builder reads the file into runs[].milestone" || return 1
  assert_eq "$calls" "0" "builder stays network-free" || return 1
}

run_test test_ms_writes_milestone_file_and_payload_key
run_test test_ms_truncates_to_60_and_collapses_whitespace
run_test test_ms_removes_stale_file_when_milestone_gone_or_version_only
run_test test_ms_building_payload_makes_no_gh_call
