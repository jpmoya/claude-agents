# #792 — state files and queue entries written before the repo renames still name the old local checkout directory
# (/Users/<u>/dev/scheduler, /Users/<u>/dev/benjis-quoting-tool). The supervisor logged
#   [answered] <path>#<N> — issue read failed: rc=1: repo name not resolvable
# because repo_slug could not read an origin URL from a directory that no longer exists. repo_slug / repo_dir_current now map the
# old directory name through skills/ticket-intake/repo-aliases.txt (the one alias list). A slug read from a live origin URL is
# never rewritten: run keys of runs already on disk are built from it.
# Hand arithmetic: scheduler -> Benjis-Plants/benjis-ops-tool, benjis-quoting-tool -> Benjis-Plants/benjis-sales-tool.
# Prefix rd_ / RD_. Placeholder paths only; no network (fake gh).

HERE_RD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_RD=$(cd "$HERE_RD/../../.." && pwd)
SUP_RD="$HERE_RD/../supervisor.sh"

rd_fn() { awk -v f="$2" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$1"; }

rd_setup() {
  RD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-rd.XXXXXX")
  mkdir -p "$RD_DIR/dev" "$RD_DIR/bin"
}
rd_teardown() { rm -rf "$RD_DIR"; }
rd_git() {  # rd_git <dir> <origin url>
  mkdir -p "$1"; ( cd "$1" && git init -q && git remote add origin "$2" ) >/dev/null 2>&1
}
# rd_run <snippet> — runs it with pipeline-lib.sh sourced
rd_run() { RD_OUT=$( . "$HERE_RD/../pipeline-lib.sh"; eval "$1" 2>&1 ); }

test_rd_missing_old_dir_maps_to_renamed_sibling() {
  local rc=0
  rd_setup; mkdir -p "$RD_DIR/dev/benjis-ops-tool" "$RD_DIR/dev/benjis-sales-tool"
  rd_run "repo_dir_current '$RD_DIR/dev/scheduler'; repo_dir_current '$RD_DIR/dev/benjis-quoting-tool/'; repo_dir_current '$RD_DIR/dev/benjis-ops-tool'"
  assert_eq "$RD_OUT" "$(printf '%s\n%s\n%s' "$RD_DIR/dev/benjis-ops-tool" "$RD_DIR/dev/benjis-sales-tool" "$RD_DIR/dev/benjis-ops-tool")" "old directory -> sibling; an existing directory is itself" || rc=1
  rd_teardown; return $rc
}

test_rd_unrelated_or_unmapped_path_is_unchanged() {
  local rc=0
  rd_setup; mkdir -p "$RD_DIR/dev/benjis-ops-tool"
  rd_run "repo_dir_current '$RD_DIR/dev/other-app'; repo_dir_current ''"
  assert_eq "$RD_OUT" "$(printf '%s\n' "$RD_DIR/dev/other-app")" "a path that is not an old name (or is empty) is returned unchanged" || rc=1
  rd_teardown; return $rc
}

test_rd_old_dir_without_sibling_still_resolves_the_current_slug() {
  local rc=0
  rd_setup
  rd_run "echo \$(repo_slug '$RD_DIR/dev/scheduler'); echo \$(repo_slug '$RD_DIR/dev/benjis-quoting-tool'); echo \$(repo_slug '$RD_DIR/dev/other-app'); echo end"
  assert_eq "$RD_OUT" "$(printf 'Benjis-Plants/benjis-ops-tool\nBenjis-Plants/benjis-sales-tool\n\nend')" "old dir name -> current owner/repo; an unknown missing dir stays unresolvable" || rc=1
  rd_teardown; return $rc
}

test_rd_slug_via_renamed_sibling_reads_its_origin() {
  local rc=0
  rd_setup; rd_git "$RD_DIR/dev/benjis-ops-tool" https://github.com/Benjis-Plants/benjis-ops-tool.git
  rd_run "repo_slug '$RD_DIR/dev/scheduler'"
  assert_eq "$RD_OUT" "Benjis-Plants/benjis-ops-tool" "the old path reads the renamed checkout's origin" || rc=1
  rd_teardown; return $rc
}

test_rd_live_origin_slug_is_never_rewritten() {
  local rc=0
  rd_setup; rd_git "$RD_DIR/dev/benjis-ops-tool" https://github.com/Benjis-Plants/scheduler.git
  rd_run "repo_slug '$RD_DIR/dev/benjis-ops-tool'"
  assert_eq "$RD_OUT" "Benjis-Plants/scheduler" "an origin URL that still says scheduler keeps its run key (not rewritten)" || rc=1
  rd_teardown; return $rc
}

test_rd_issue_info_rest_reads_issue_through_an_old_checkout_path() {
  local rc=0 out args
  rd_setup
  cat > "$RD_DIR/bin/gh" <<EOF2
#!/bin/bash
printf '%s\n' "\$*" >> "$RD_DIR/gh-args.log"
case "\$2" in
  repos/Benjis-Plants/benjis-ops-tool/issues/601) echo '{"state":"open","body":"","user":{"login":"jpmoya"},"updated_at":"2026-10-17T18:00:00Z"}' ;;
  repos/Benjis-Plants/benjis-ops-tool/issues/601/comments*) echo '[{"id":1,"created_at":"2026-10-01T12:00:00Z","body":"**[jp] GO**","user":{"login":"jpmoya"}}]' ;;
  *) echo "fake gh: unexpected \$*" >&2; exit 1 ;;
esac
EOF2
  chmod +x "$RD_DIR/bin/gh"
  { rd_fn "$SUP_RD" issue_info_rest; rd_fn "$SUP_RD" gh_err_line; } > "$RD_DIR/fns.sh"
  out=$( PATH="$RD_DIR/bin:$PATH"
         . "$ROOT_RD/hooks/pipeline-markers.sh"; . "$HERE_RD/../pipeline-lib.sh"; . "$RD_DIR/fns.sh"
         issue_info_rest "$RD_DIR/dev/scheduler" 601 2>&1 )   # the directory does not exist
  args=$(cat "$RD_DIR/gh-args.log" 2>/dev/null)
  assert_eq "$(printf '%s' "$out" | jq -r .state 2>/dev/null)" "OPEN" "the issue read through the old path succeeds (was: repo name not resolvable)" || rc=1
  assert_contains "$args" "api repos/Benjis-Plants/benjis-ops-tool/issues/601" "the current repo name is read" || rc=1
  assert_not_contains "$out" "not resolvable" "no 'not resolvable' failure" || rc=1
  rd_teardown; return $rc
}

# rd_status_repo <repo path in the state file> -> the "repo" the status payload publishes for a held run, alias list "Benjis-Plants/benjis-ops-tool:ops tool"
rd_status_repo() {
  mkdir -p "$RD_DIR/pipe"
  printf '701\t%s\theld\t\t2026-10-26T00:00:00Z\t\t0\t\n' "$1" \
    | python3 "$HERE_RD/../build-runs-json.py" "Benjis-Plants/benjis-ops-tool:ops tool" "$RD_DIR/runs.jsonl" "$RD_DIR/pipe" 2>/dev/null \
    | jq -r '.[0].repo // "none"'
}

test_rd_status_page_names_the_repo_of_a_run_with_an_old_checkout_path() {
  local rc=0 a b c d
  rd_setup; rd_git "$RD_DIR/dev/benjis-ops-tool" https://github.com/Benjis-Plants/benjis-ops-tool.git
  a=$(rd_status_repo "$RD_DIR/dev/scheduler")             # missing old dir, renamed sibling exists
  b=$(rd_status_repo "$RD_DIR/gone/scheduler")            # missing old dir, no sibling: the old directory name maps through the alias list
  c=$(rd_status_repo "$RD_DIR/gone/other-app")            # unknown missing dir: still "other"
  rd_git "$RD_DIR/dev/legacy-origin" https://github.com/Benjis-Plants/scheduler.git
  d=$(rd_status_repo "$RD_DIR/dev/legacy-origin")         # origin URL still says scheduler: same repo, same alias
  assert_eq "$a/$b/$c/$d" "ops tool/ops tool/other/ops tool" "status repo for an old checkout path (was: other)" || rc=1
  rd_teardown; return $rc
}

test_rd_empty_path_keeps_its_old_meaning() {
  local rc=0
  # git -C "" is the current directory: an empty .repo file used to resolve to the slug of the cwd's repo; the alias branch must not eat that
  rd_setup; rd_git "$RD_DIR/dev/some-app" https://github.com/Benjis-Plants/some-app.git
  rd_run "cd '$RD_DIR/dev/some-app' && echo \$(repo_slug '')"
  assert_eq "$RD_OUT" "Benjis-Plants/some-app" "repo_slug of an empty path is the current directory's repo, as before" || rc=1
  rd_teardown; return $rc
}

test_rd_every_state_file_reader_maps_the_path() {
  local rc=0 n
  # static pin: each supervisor spot that reads a checkout path from a state file or queue entry goes through repo_dir_current
  n=$(grep -c 'repo=$(repo_dir_current "$(cat "$PIPE/orch-$rk.repo"' "$SUP_RD")
  assert_eq "$n" "4" "the four .repo readers (held, step 1, loop-cap, answered) map the old directory" || rc=1
  grep -q 'q_repo=$(repo_dir_current "$q_repo")' "$SUP_RD" || { fail "the queue-entry reader (q_repo) does not map the old directory"; rc=1; }
  return $rc
}

run_test test_rd_missing_old_dir_maps_to_renamed_sibling
run_test test_rd_unrelated_or_unmapped_path_is_unchanged
run_test test_rd_old_dir_without_sibling_still_resolves_the_current_slug
run_test test_rd_slug_via_renamed_sibling_reads_its_origin
run_test test_rd_live_origin_slug_is_never_rewritten
run_test test_rd_issue_info_rest_reads_issue_through_an_old_checkout_path
run_test test_rd_status_page_names_the_repo_of_a_run_with_an_old_checkout_path
run_test test_rd_empty_path_keeps_its_old_meaning
run_test test_rd_every_state_file_reader_maps_the_path
