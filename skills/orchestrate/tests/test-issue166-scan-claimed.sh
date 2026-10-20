# Issue #166 — scan-backlog.sh skips issues carrying a launch claim comment; orchestrate.sh launch drops agent-proposed.
# gh stub: `issue list --search` returns the claim hits; plain `issue list` applies the caller's --jq to the fixture.

_scan166() { # $1=claim-search mode (ok|fail) → echoes gh log + curl log
  local home log
  home=$(new_home); log="$home/gh.log"; : > "$log"; mkdir -p "$home/bin"
  cat > "$home/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  case "$*" in *--search*) [ "$CLAIM_MODE" = fail ] && exit 1; echo 1; exit 0 ;; esac
  expr=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
  json='[{"number":1,"title":"parked","labels":[]},{"number":2,"title":"brand new","labels":[]},
         {"number":3,"title":"proposed","labels":[{"name":"agent-proposed"}]}]'
  printf '%s' "$json" | jq -r "$expr"
fi
exit 0
STUB
  cat > "$home/bin/curl" <<'STUB'
#!/bin/bash
echo "curl $*" >> "$GH_LOG"; echo ok
STUB
  chmod +x "$home/bin/gh" "$home/bin/curl"
  printf 'SCAN_BACKLOG=1\nSLACK_WEBHOOK_URL=https://example.invalid/hook\nDISPATCH_REPOS=("o/a:/tmp/a")\n' > "$home/.claude/pipeline/config.local.sh"
  HOME="$home" GH_LOG="$log" CLAIM_MODE="$1" PATH="$home/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" /bin/bash "$HERE_166/../scan-backlog.sh" >/dev/null 2>&1
  cat "$log"; rm -rf "$home"
}
HERE_166=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

test_i166_claimed_issue_not_labelled_new_one_is() {
  local out edits
  out=$(_scan166 ok); edits=$(printf '%s\n' "$out" | grep '^issue edit ')
  assert_eq "$(printf '%s\n' "$edits" | grep -c .)" "1" "only one edit" || return 1
  assert_contains "$edits" "issue edit 2 --repo o/a" "brand-new issue labelled" || return 1
}
test_i166_failed_claim_search_fails_closed_and_alerts() {
  local out
  out=$(_scan166 fail)
  assert_eq "$(printf '%s\n' "$out" | grep -c '^issue edit ')" "0" "no relabel on failed search" || return 1
  assert_contains "$out" "curl " "Slack alert posted" || return 1
}
test_i166_launch_removes_agent_proposed() {
  local line
  line=$(grep -n 'add-label "$LABEL_IN_PROGRESS" --remove-label "$LABEL_GO"' "$HERE_166/../orchestrate.sh" | head -1)
  assert_contains "$line" '--remove-label "$LABEL_PROPOSED"' "launch edit drops agent-proposed" || return 1
}
run_test test_i166_claimed_issue_not_labelled_new_one_is
run_test test_i166_failed_claim_search_fails_closed_and_alerts
run_test test_i166_launch_removes_agent_proposed
