# Issue #324 — scan-backlog.sh never labels agent-proposed on an issue carrying `release-watch`.

_scan324() { # → echoes gh log
  local home log
  home=$(new_home); log="$home/gh.log"; : > "$log"; mkdir -p "$home/bin"
  cat > "$home/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  case "$*" in *--search*) exit 0 ;; esac
  expr=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
  json='[{"number":1,"title":"rolling watch","labels":[{"name":"release-watch"}]},
         {"number":2,"title":"plain","labels":[]}]'
  printf '%s' "$json" | jq -r "$expr"
fi
exit 0
STUB
  chmod +x "$home/bin/gh"
  printf 'SCAN_BACKLOG=1\nDISPATCH_REPOS=("o/a:/tmp/a")\n' > "$home/.claude/pipeline/config.local.sh"
  HOME="$home" GH_LOG="$log" PATH="$home/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" /bin/bash "$HERE_324/../scan-backlog.sh" >/dev/null 2>&1
  cat "$log"; rm -rf "$home"
}
HERE_324=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

test_i324_release_watch_issue_not_labelled_plain_one_is() {
  local edits
  edits=$(_scan324 | grep '^issue edit ')
  assert_eq "$(printf '%s\n' "$edits" | grep -c .)" "1" "only one edit" || return 1
  assert_contains "$edits" "issue edit 2 --repo o/a" "plain issue labelled" || return 1
  assert_contains "$edits" "--add-label agent-proposed" "adds agent-proposed" || return 1
}
run_test test_i324_release_watch_issue_not_labelled_plain_one_is
