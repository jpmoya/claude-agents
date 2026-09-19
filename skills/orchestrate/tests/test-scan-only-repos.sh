# Issue #31 (R2 / criteria 5a-5d, AC6) — scan-backlog.sh covers DISPATCH_REPOS + SCAN_ONLY_REPOS.
# SCAN_ONLY_REPOS entries are scanned (unlabelled issues get agent-proposed) but never dispatched.
# Fixture shape follows test-ac12-write-budget.sh: a temp HOME whose .claude/pipeline/config.local.sh
# sets SCAN_BACKLOG=1 + the arrays and no SLACK_WEBHOOK_URL; a per-test `gh` stub, first on PATH
# (config.sh prepends $HOME/bin, so the stub lives there), appends "$*" to a log and, for
# `issue list`, prints one unlabelled issue `7<TAB>some title`. Assertions read the log.
# Placeholders only (o/a, o/b, o/c): this repo is public.
# The scan runs under /bin/bash (3.2 on macOS): key-absent cases prove `set -u` safety there.

HERE_SO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_SO="$HERE_SO/.."

# so_has <file> <literal> — fixed-string, case-sensitive; names the missing literal without dumping the file.
so_has() { grep -qF -- "$2" "$1" || { fail "$(basename "$1"): missing [$2]"; return 1; }; }
# so_has_i <file> <literal> — same, case-insensitive.
so_has_i() { grep -qiF -- "$2" "$1" || { fail "$(basename "$1"): missing (any case) [$2]"; return 1; }; }

so_write_gh_stub() {  # so_write_gh_stub <home>
  mkdir -p "$1/bin"
  cat > "$1/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then printf '7\tsome title\n'; fi
exit 0
STUB
  chmod +x "$1/bin/gh"
}

# so_run_scan <home> <log> — runs the scan in the fixture home; sets SO_RC.
so_run_scan() {
  HOME="$1" GH_LOG="$2" PATH="$1/bin:/usr/bin:/bin" /bin/bash "$RS_SO/scan-backlog.sh" >/dev/null 2>&1
  SO_RC=$?
}

# so_repos <log> <verb> — the --repo values of `gh issue <verb>` calls, sorted, space-separated
# (duplicates preserved so "scanned once" is observable).
so_repos() {
  grep "^issue $2 " "$1" | sed -E 's/.*--repo ([^ ]+).*/\1/' | sort | tr '\n' ' '
}

test_so_5a_scan_only_repo_is_listed_and_labelled_alongside_dispatch_repo() {
  local home log
  home=$(new_home); log="$home/gh.log"; : > "$log"; so_write_gh_stub "$home"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF2'
SCAN_BACKLOG=1
DISPATCH_REPOS=("o/a:/tmp/a")
SCAN_ONLY_REPOS=("o/b")
EOF2
  so_run_scan "$home" "$log"
  local listed edited edit_a edit_b
  listed=$(so_repos "$log" list); edited=$(so_repos "$log" edit)
  edit_a=$(grep -c '^issue edit 7 --repo o/a .*--add-label agent-proposed' "$log")
  edit_b=$(grep -c '^issue edit 7 --repo o/b .*--add-label agent-proposed' "$log")
  rm -rf "$home"
  assert_exit0 "$SO_RC" "5a: scan exits 0" || return 1
  assert_eq "$listed" "o/a o/b " "5a: gh issue list is called for the dispatch repo AND the scan-only repo" || return 1
  assert_eq "$edit_a" "1" "5a: the unlabelled issue of o/a is labelled agent-proposed" || return 1
  assert_eq "$edit_b" "1" "5a: the unlabelled issue of o/b (scan-only) is labelled agent-proposed" || return 1
  assert_eq "$edited" "o/a o/b " "5a: exactly one label edit per repo" || return 1
}

test_so_5b_key_absent_scans_exactly_dispatch_repos_and_config_defaults_to_empty() {
  # config.local.sh never mentions SCAN_ONLY_REPOS: the set of --repo values must equal
  # DISPATCH_REPOS exactly (today's behaviour), with no unbound-variable failure under bash 3.2 + set -u.
  local home log listed rc_default
  home=$(new_home); log="$home/gh.log"; : > "$log"; so_write_gh_stub "$home"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF2'
SCAN_BACKLOG=1
DISPATCH_REPOS=("o/a:/tmp/a" "o/c:/tmp/c")
EOF2
  so_run_scan "$home" "$log"
  listed=$(so_repos "$log" list)
  # The shared default: config.sh itself declares SCAN_ONLY_REPOS as an (empty) array — a machine
  # with no local override must not depend on the variable being unset.
  mv "$home/.claude/pipeline/config.local.sh" "$home/.claude/pipeline/config.local.sh.off"
  HOME="$home" /bin/bash -c 'source "$1/config.sh"; declare -p SCAN_ONLY_REPOS >/dev/null 2>&1 && [ "${#SCAN_ONLY_REPOS[@]}" -eq 0 ]' _ "$RS_SO"
  rc_default=$?
  rm -rf "$home"
  assert_exit0 "$SO_RC" "5b: scan exits 0 with SCAN_ONLY_REPOS never defined locally (set -u safe on bash 3.2)" || return 1
  assert_eq "$listed" "o/a o/c " "5b: --repo values equal DISPATCH_REPOS exactly" || return 1
  assert_eq "$rc_default" "0" "5b/AC6: config.sh declares SCAN_ONLY_REPOS=() as the default (empty array)" || return 1
}

test_so_5c_repo_in_both_lists_scanned_once_path_suffix_tolerated() {
  # o/a is in both lists (once bare, once with a :path suffix); o/b appears twice in SCAN_ONLY
  # (bare and with a suffix). Every repo must be listed and labelled exactly once, and the
  # ":path" suffix must be ignored (o/b:/ignored is repo o/b, not "o/b:/ignored").
  local home log listed edited
  home=$(new_home); log="$home/gh.log"; : > "$log"; so_write_gh_stub "$home"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF2'
SCAN_BACKLOG=1
DISPATCH_REPOS=("o/a:/tmp/a")
SCAN_ONLY_REPOS=("o/a" "o/a:/elsewhere" "o/b:/ignored" "o/b")
EOF2
  so_run_scan "$home" "$log"
  listed=$(so_repos "$log" list); edited=$(so_repos "$log" edit)
  rm -rf "$home"
  assert_exit0 "$SO_RC" "5c: scan exits 0" || return 1
  assert_eq "$listed" "o/a o/b " "5c: each repo is listed at most once, suffix ignored" || return 1
  assert_eq "$edited" "o/a o/b " "5c: each repo's issue is labelled once, not once per list entry" || return 1
}

test_so_5c_scan_only_key_is_scanned_when_dispatch_repos_is_empty() {
  # Boundary: DISPATCH_REPOS=() (a machine that never dispatches) + one scan-only repo.
  local home log listed
  home=$(new_home); log="$home/gh.log"; : > "$log"; so_write_gh_stub "$home"
  cat > "$home/.claude/pipeline/config.local.sh" <<'EOF2'
SCAN_BACKLOG=1
DISPATCH_REPOS=()
SCAN_ONLY_REPOS=("o/b")
EOF2
  so_run_scan "$home" "$log"
  listed=$(so_repos "$log" list)
  rm -rf "$home"
  assert_exit0 "$SO_RC" "empty DISPATCH_REPOS: scan exits 0" || return 1
  assert_eq "$listed" "o/b " "empty DISPATCH_REPOS: the scan-only repo is still scanned" || return 1
}

test_so_5d_scan_only_repos_is_referenced_only_by_config_and_scan() {
  # 5d: grep -c SCAN_ONLY_REPOS is 0 in supervisor.sh, orchestrate.sh, install.sh (never dispatched).
  # Positive control: config.sh and scan-backlog.sh DO reference it, so the zero counts are not
  # just a grep aimed at nothing.
  local f n
  for f in supervisor.sh orchestrate.sh install.sh; do
    n=$(grep -c SCAN_ONLY_REPOS "$RS_SO/$f")
    assert_eq "$n" "0" "5d: $f must not reference SCAN_ONLY_REPOS" || return 1
  done
  for f in config.sh scan-backlog.sh; do
    n=$(grep -c SCAN_ONLY_REPOS "$RS_SO/$f")
    assert_ne "$n" "0" "5d control: $f must reference SCAN_ONLY_REPOS" || return 1
  done
}

test_so_config_sh_declares_the_key_next_to_dispatch_repos_with_comment() {
  local code_line disp_line key_line comment
  disp_line=$(grep -n '^DISPATCH_REPOS=()' "$RS_SO/config.sh" | head -1 | cut -d: -f1)
  key_line=$(grep -n '^SCAN_ONLY_REPOS=()' "$RS_SO/config.sh" | head -1 | cut -d: -f1)
  assert_ne "$key_line" "" "R2: config.sh must contain a line SCAN_ONLY_REPOS=()" || return 1
  assert_ne "$disp_line" "" "R2: config.sh keeps DISPATCH_REPOS=()" || return 1
  [ "$key_line" -gt "$disp_line" ] && [ $((key_line - disp_line)) -le 4 ] || { fail "R2: SCAN_ONLY_REPOS=() must sit next to DISPATCH_REPOS=() (lines $disp_line / $key_line)"; return 1; }
  # comment (same or preceding line) says: scanned, never dispatched
  comment=$(sed -n "${disp_line},$((key_line + 1))p" "$RS_SO/config.sh" | grep '#' | tr '[:upper:]' '[:lower:]')
  assert_contains "$comment" "scan-backlog.sh" "R2: comment names scan-backlog.sh" || return 1
  assert_contains "$comment" "never dispatched" "R2: comment says never dispatched" || return 1
}

test_so_scan_backlog_header_comment_mentions_scan_only_repos() {
  local header
  header=$(sed -n '1,5p' "$RS_SO/scan-backlog.sh")
  assert_contains "$header" "SCAN_ONLY_REPOS" "R2: scan-backlog.sh header comment (line 3 area) names SCAN_ONLY_REPOS" || return 1
  assert_contains "$header" "DISPATCH_REPOS" "R2: header still names DISPATCH_REPOS" || return 1
}

test_so_example_config_has_commented_placeholder_under_scan_backlog_block() {
  local f="$RS_SO/config.local.example.sh" scan_ln key_ln next_ln
  scan_ln=$(grep -n '^# SCAN_BACKLOG=1' "$f" | head -1 | cut -d: -f1)
  key_ln=$(grep -nxF '# SCAN_ONLY_REPOS=("example-owner/project-6")' "$f" | head -1 | cut -d: -f1)
  next_ln=$(grep -n '^# Engineering notifications' "$f" | head -1 | cut -d: -f1)
  assert_ne "$key_ln" "" "R2: example must contain the exact commented placeholder line # SCAN_ONLY_REPOS=(\"example-owner/project-6\")" || return 1
  [ "$key_ln" -gt "$scan_ln" ] && [ "$key_ln" -lt "$next_ln" ] || { fail "R2: placeholder must sit inside the SCAN_BACKLOG block (SCAN_BACKLOG=$scan_ln key=$key_ln next-block=$next_ln)"; return 1; }
  assert_eq "$(grep -c '^SCAN_ONLY_REPOS=' "$f")" "0" "R2: no uncommented SCAN_ONLY_REPOS assignment in the example" || return 1
}

test_so_skill_md_and_readme_describe_dispatch_eligibility_and_scan_coverage_separately() {
  local f txt
  for f in "$RS_SO/SKILL.md" "$RS_SO/../../README.md"; do
    so_has "$f" "SCAN_ONLY_REPOS" || return 1
    so_has_i "$f" "dispatch eligibility" || return 1
    so_has_i "$f" "scan coverage" || return 1
    so_has "$f" "Business-Intelligence" || return 1
  done
  # the SKILL.md Config line no longer states scan coverage as part of the dispatch list:
  # SCAN_ONLY_REPOS and DISPATCH_REPOS both appear, and the quoting-tool split (scanned on VM, dispatched from Mac) is stated
  txt=$(grep -i 'quoting tool' "$RS_SO/SKILL.md" | grep -i 'scan' | grep -i 'mac' || true)
  assert_ne "$txt" "" "R2: SKILL.md has a line saying the quoting tool is scanned (on the VM) and dispatched only from the Mac" || return 1
}

run_test test_so_5a_scan_only_repo_is_listed_and_labelled_alongside_dispatch_repo
run_test test_so_5b_key_absent_scans_exactly_dispatch_repos_and_config_defaults_to_empty
run_test test_so_5c_repo_in_both_lists_scanned_once_path_suffix_tolerated
run_test test_so_5c_scan_only_key_is_scanned_when_dispatch_repos_is_empty
run_test test_so_5d_scan_only_repos_is_referenced_only_by_config_and_scan
run_test test_so_config_sh_declares_the_key_next_to_dispatch_repos_with_comment
run_test test_so_scan_backlog_header_comment_mentions_scan_only_repos
run_test test_so_example_config_has_commented_placeholder_under_scan_backlog_block
run_test test_so_skill_md_and_readme_describe_dispatch_eligibility_and_scan_coverage_separately
