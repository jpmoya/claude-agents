# claude-agents#567 — goal and launch failures say why (DISPATCH_REPOS miss, registry read, claim comment/lookup).
HERE_G=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUP_G="$HERE_G/../supervisor.sh"; GL_G="$HERE_G/../goal-lib.sh"
g_fn() { awk -v f="$2" '$0 ~ "^"f"\\(\\) \\{" {on=1} on {print} on && /^}/ {exit}' "$1"; }

g_setup() {
  G_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-g.XXXXXX"); mkdir -p "$G_DIR/bin"
  cat > "$G_DIR/bin/gh" <<'EOF2'
#!/bin/bash
echo "HTTP 403: API rate limit exceeded for user ID 1 token=ghp_abcdefghijklmnopqrstuvwxyz0123456789" >&2
echo "second line" >&2
exit 1
EOF2
  chmod +x "$G_DIR/bin/gh"
}

test_g_get_all_reports_gh_error_line() {
  g_setup
  local out rc=0
  out=$( PATH="$G_DIR/bin:$PATH"; eval "$(g_fn "$GL_G" _goal_get_all)"; _goal_get_all repos/x/y/z 2>&1 >/dev/null ) && rc=1
  assert_contains "$out" "API rate limit exceeded" "gh error line surfaced" \
    && assert_not_contains "$out" "second line" "first line only" \
    && assert_not_contains "$out" "ghp_abc" "token redacted" || rc=1
  rm -rf "$G_DIR"; return $rc
}

test_g_claim_comment_failure_carries_gh_error() {
  g_setup
  local log rc=0
  log=$( PATH="$G_DIR/bin:$PATH" CLAIM_SETTLE_SECS=0 HOST=h
    slog() { printf '%s\n' "$*"; }; rk_of() { echo k; }
    { g_fn "$SUP_G" gh_err_line; g_fn "$SUP_G" do_launch; } > "$G_DIR/f.sh"; . "$G_DIR/f.sh"
    cd "$G_DIR" && do_launch "$G_DIR" 77 "" 0 manual; echo "rc=$?" )
  assert_contains "$log" "claim comment failed rc=1: HTTP 403: API rate limit exceeded" "claim error text" \
    && assert_contains "$log" "rc=2" "still returns 2" \
    && assert_not_contains "$log" "ghp_abc" "token redacted" || rc=1
  rm -rf "$G_DIR"; return $rc
}

test_g_dispatch_repos_miss_is_named() {
  local body
  body=$(g_fn "$GL_G" _goal_ticket_eval)
  assert_contains "$body" "not in DISPATCH_REPOS on this host" "checkout failure is logged" || return 1
  assert_contains "$body" 'cannot evaluate $repo#$n: repo not in' "names repo and ticket"
}

run_test test_g_get_all_reports_gh_error_line
run_test test_g_claim_comment_failure_carries_gh_error
run_test test_g_dispatch_repos_miss_is_named
