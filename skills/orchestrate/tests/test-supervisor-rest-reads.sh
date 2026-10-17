# #388 — the supervisor's marker/issue reads go over REST, not GraphQL (the shared GraphQL budget runs out hourly).
# Same decision as claude-agents#57 (7f12211) for the handoff hook. Fake `gh` below REJECTS every GraphQL-backed call
# (`issue view`, `repo view`, `api graphql`) and serves only `gh api repos/...` REST paths, like the real one under --paginate
# (each page is a separate JSON array, concatenated). Expected values are hand-derived from the ticket.
#   AC1  sr_ac1_*   latest_marker: multi-page comments -> the same gate marker, zero GraphQL calls
#   AC3  sr_ac3_*   a failed read logs gh's one-line, token-free error naming ticket + step, and calls the Slack alert
#   AC2/5 sr_ac2_*  static pins: no `gh issue view` left on the three supervisor read paths; goal wording names ticket + step
# Every function/variable is prefixed sr_ / SR_. Placeholder repo names only.

HERE_SR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_SR=$(cd "$HERE_SR/../../.." && pwd)
SUP_SR="$HERE_SR/../supervisor.sh"
GOAL_SR="$HERE_SR/../goal-lib.sh"

sr_fn() { awk -v f="$2" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$1"; }

sr_setup() {
  SR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-sr.XXXXXX")
  mkdir -p "$SR_DIR/bin" "$SR_DIR/repo"
  ( cd "$SR_DIR/repo" && git init -q && git remote add origin https://github.com/project-a/repo-a.git ) >/dev/null 2>&1
  cat > "$SR_DIR/bin/gh" <<EOF2
#!/bin/bash
D="$SR_DIR"
TOK="ghp_\$(printf 'x%.0s' \$(seq 36))"
printf '%s\n' "\$*" >> "\$D/gh-args.log"
[ "\$1" = "api" ] && [ "\$2" != "graphql" ] || { echo "GraphQL: API rate limit already exceeded for user ID 1" >&2; exit 1; }
[ -e "\$D/rest-fail" ] && { echo "HTTP 403: API rate limit exceeded token=\$TOK Bearer xyz" >&2; echo "second line" >&2; exit 1; }
case "\$2" in
  repos/project-a/repo-a/issues/601/comments*) for p in "\$D"/pages/page*.json; do cat "\$p"; done ;;
  *) echo "fake gh: unexpected \$*" >&2; exit 1 ;;
esac
EOF2
  chmod +x "$SR_DIR/bin/gh"
  printf '#!/bin/bash\necho curl "$@" >> "%s/curl.log"\n' "$SR_DIR" > "$SR_DIR/bin/curl"; chmod +x "$SR_DIR/bin/curl"
  mkdir -p "$SR_DIR/pages"
  jq -n '[{created_at:"2026-10-01T12:00:00Z",body:"**[product-manager] READY FOR ENGINEERING**"},
          {created_at:"2026-10-01T12:01:00Z",body:"**[test-writer] TESTS WRITTEN**"}]' > "$SR_DIR/pages/page1.json"
  jq -n '[{created_at:"2026-10-01T12:02:00Z",body:"**[fullstack-developer] NOTE**\nprogress"},
          {created_at:"2026-10-01T12:03:00Z",body:"**[fullstack-developer] IMPLEMENTED**"}]' > "$SR_DIR/pages/page2.json"
}
sr_teardown() { rm -rf "$SR_DIR"; }

# sr_run_lm <repo> <issue> — runs the shipped latest_marker (+ its helpers) against the fake gh. Sets SR_OUT; log in $SR_DIR/slog.
sr_run_lm() {
  { sr_fn "$SUP_SR" latest_marker; sr_fn "$SUP_SR" gh_err_line; sr_fn "$SUP_SR" autoretry_alert; } > "$SR_DIR/fns.sh"
  SR_OUT=$( PATH="$SR_DIR/bin:$PATH" SLACK_WEBHOOK_URL=https://hooks.example.test/x SLOG="$SR_DIR/slog"
    . "$ROOT_SR/hooks/pipeline-markers.sh"; . "$HERE_SR/../pipeline-lib.sh"
    slog() { printf '%s\n' "$*" >> "$SLOG"; }
    . "$SR_DIR/fns.sh"; latest_marker "$1" "$2" )
}

test_sr_ac1_latest_marker_reads_rest_pages() {
  sr_setup
  sr_run_lm "$SR_DIR/repo" 601
  local args; args=$(cat "$SR_DIR/gh-args.log" 2>/dev/null) rc=0
  assert_eq "$SR_OUT" "**[fullstack-developer] IMPLEMENTED**" "AC1: newest real marker across 2 pages" \
    && assert_contains "$args" "api repos/project-a/repo-a/issues/601/comments?per_page=100" "AC1: REST comments endpoint" \
    && assert_contains "$args" "--paginate" "AC1: paginated" \
    && assert_not_contains "$args" "issue view" "AC1: no GraphQL issue view" || rc=1
  sr_teardown; return $rc
}

test_sr_ac3_failed_read_is_logged_and_alerted() {
  sr_setup; touch "$SR_DIR/rest-fail"
  sr_run_lm "$SR_DIR/repo" 601
  local log; log=$(cat "$SR_DIR/slog" 2>/dev/null) rc=0
  assert_eq "$SR_OUT" "?" "AC3: a failed read still answers ?" \
    && assert_contains "$log" "#601" "AC3: log names the ticket" \
    && assert_contains "$log" "latest_marker" "AC3: log names the step" \
    && assert_contains "$log" "API rate limit exceeded" "AC3: log carries gh's error text" \
    && assert_not_contains "$log" "ghp_x" "AC3: token redacted" \
    && assert_not_contains "$log" "second line" "AC3: one line only" \
    && assert_contains "$(cat "$SR_DIR/curl.log" 2>/dev/null)" "hooks.example.test" "AC3: Slack alert called" || rc=1
  sr_teardown; return $rc
}

test_sr_ac2_supervisor_reads_have_no_graphql_issue_view() {
  local n
  n=$(sed -n '/^latest_marker()/,/^}/p' "$SUP_SR" | grep -c 'gh issue view')
  assert_eq "$n" "0" "AC1: latest_marker must not call gh issue view" || return 1
  n=$(grep -c 'gh issue view "\$issue" --json state,body,comments' "$SUP_SR")
  assert_eq "$n" "0" "AC2: auto-retry read must be REST" || return 1
  n=$(grep -c 'gh issue view "\$num" --json comments,updatedAt' "$SUP_SR")
  assert_eq "$n" "0" "AC2: reconcile read must be REST" || return 1
}

test_sr_ac3_goal_wording_names_ticket_and_step() {
  local n
  n=$(sed -n '/^_goal_ticket_eval()/,/^}/p' "$GOAL_SR" | grep -c 'latest_marker read failed')
  [ "$n" -ge 1 ] || { echo "_goal_ticket_eval must say which ticket's latest_marker read failed"; return 1; }
  n=$(grep -c 'goal_err "cannot read the scope of \$id"' "$GOAL_SR")
  assert_eq "$n" "0" "AC3: the misleading 'cannot read the scope' wording is gone from the two goal_err sites" || return 1
}
