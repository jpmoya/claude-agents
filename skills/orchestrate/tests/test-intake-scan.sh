# Issue #114 — AC3: scan-backlog.sh never stamps agent-proposed on user-feedback-intake / user-feedback-needs-spec issues.
# Fixture: issues 1 (user-feedback-intake), 2 (user-feedback-needs-spec), 3 (unlabelled control). The gh stub applies the
# caller's --jq to that JSON, so the real filter runs. Placeholder repo names only.

HERE_IS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

test_is_scan_skips_feedback_labelled_issues() {
  local home log edits
  home=$(new_home); log="$home/gh.log"; : > "$log"; mkdir -p "$home/bin"
  cat > "$home/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  expr=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; prev=$a; done
  json='[{"number":1,"title":"raw feedback","labels":[{"name":"user-feedback-intake"}]},
         {"number":2,"title":"idea awaiting spec","labels":[{"name":"user-feedback-needs-spec"}]},
         {"number":3,"title":"control","labels":[]}]'
  if [ -n "$expr" ]; then printf '%s' "$json" | jq -r "$expr"; else printf '%s' "$json"; fi
fi
exit 0
STUB
  chmod +x "$home/bin/gh"
  printf 'SCAN_BACKLOG=1\nDISPATCH_REPOS=("o/a:/tmp/a")\n' > "$home/.claude/pipeline/config.local.sh"
  HOME="$home" GH_LOG="$log" PATH="$home/bin:/usr/bin:/bin" /bin/bash "$HERE_IS/../scan-backlog.sh" >/dev/null 2>&1
  edits=$(grep '^issue edit ' "$log")
  rm -rf "$home"
  assert_contains "$edits" "issue edit 3 --repo o/a" "AC3: the unlabelled control is stamped" || return 1
  assert_contains "$edits" "agent-proposed" "AC3: control gets agent-proposed" || return 1
  assert_eq "$(printf '%s\n' "$edits" | grep -c .)" "1" "AC3: only the control is edited (raw and needs-spec issues are skipped)" || return 1
}

run_test test_is_scan_skips_feedback_labelled_issues
