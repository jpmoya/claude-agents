# #632 — direct-route repos, AC1: config.sh defines DIRECT_ROUTE_REPOS (containing jpmoya/claude-agents) and the helper
# direct_route_repo, and drops direct-route entries from DISPATCH_REPOS / SCAN_ONLY_REPOS when it loads, whatever the host's
# config.local.sh says. Expected values come from the ticket: the repo matches in any case and with a ":path" suffix; an app
# repo does not. Prefix drc_ / DRC_ (all suites share one shell). Placeholder repo names otherwise (public repo).

HERE_DRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_DRC="$HERE_DRC/.."

# drc_cfg <config.local.sh body> <snippet> [bash] — sources config.sh in an isolated HOME (the host's config.local.sh is
# never read; PIPE points at a dir that does not exist so no state is written) and evals the snippet under `set -u`.
# Sets DRC_RC / DRC_OUT.
drc_cfg() {
  local home sh=${3:-bash}
  home=$(new_home)
  printf '%s\n' "$1" > "$home/.claude/pipeline/config.local.sh"
  DRC_OUT=$(HOME="$home" PIPE="$home/no-such-pipe" "$sh" -c 'set -u; . "$1/config.sh"; eval "$2"' _ "$RS_DRC" "$2" 2>&1); DRC_RC=$?
  rm -rf "$home"
}

test_drc_ac1_constant_lists_claude_agents_with_the_pinned_comment() {
  drc_cfg "" 'printf "%s\n" ${DIRECT_ROUTE_REPOS[@]+"${DIRECT_ROUTE_REPOS[@]}"}'
  assert_eq "$DRC_RC" "0" "AC1: config.sh loads (output: $DRC_OUT)" || return 1
  printf '%s\n' "$DRC_OUT" | grep -qxF 'jpmoya/claude-agents' || { fail "AC1: DIRECT_ROUTE_REPOS must contain jpmoya/claude-agents, got [$DRC_OUT]"; return 1; }
  grep -qF -- '# Changed only by an interactive session with subagents — never orchestrate.sh, agent-go, a goal or the supervisor (#632).' "$RS_DRC/config.sh" \
    || { fail "AC1: config.sh is missing the ticket's comment line on DIRECT_ROUTE_REPOS"; return 1; }
  grep -q '^DIRECT_ROUTE_REPOS=(' "$RS_DRC/config.sh" || { fail "AC1: DIRECT_ROUTE_REPOS is not assigned at top level of config.sh"; return 1; }
}

test_drc_ac1_helper_matches_any_case_and_path_suffix_only_for_listed_repos() {
  local r
  for r in jpmoya/claude-agents JPMoya/Claude-Agents "jpmoya/claude-agents:/some/path"; do
    drc_cfg "" "direct_route_repo $(printf '%q' "$r")"
    assert_eq "$DRC_RC" "0" "AC1: direct_route_repo $r returns 0 (output: $DRC_OUT)" || return 1
  done
  for r in Benjis-Plants/scheduler example-owner/project-a "example-owner/project-a:/x" "" "claude-agents" "jpmoya/claude-agents-fork"; do
    drc_cfg "" "direct_route_repo $(printf '%q' "$r")"
    assert_eq "$DRC_RC" "1" "AC1: direct_route_repo [$r] returns 1 (output: $DRC_OUT)" || return 1
  done
}

test_drc_helper_works_under_bin_bash_3_2_with_set_u() {
  drc_cfg "" 'direct_route_repo jpmoya/claude-agents && direct_route_repo example-owner/project-a; echo "rc=$?"' /bin/bash
  assert_eq "$DRC_RC" "0" "portability: /bin/bash + set -u does not error (output: $DRC_OUT)" || return 1
  assert_eq "$DRC_OUT" "rc=1" "portability: listed -> 0, unlisted -> 1 under /bin/bash" || return 1
}

test_drc_host_override_cannot_clear_the_list() {
  # the tracked list is set after config.local.sh is sourced: a host that empties or replaces it changes nothing
  drc_cfg 'DIRECT_ROUTE_REPOS=()' 'direct_route_repo jpmoya/claude-agents'
  assert_eq "$DRC_RC" "0" "DIRECT_ROUTE_REPOS=() in config.local.sh does not clear the rule" || return 1
  drc_cfg 'DIRECT_ROUTE_REPOS=("example-owner/project-a")' 'direct_route_repo jpmoya/claude-agents; a=$?; direct_route_repo example-owner/project-a; echo "$a $?"'
  assert_eq "$DRC_OUT" "0 1" "a replaced list in config.local.sh is overridden by the tracked one" || return 1
}

test_drc_load_drops_direct_route_entries_from_both_repo_lists_and_records_them() {
  local cfg
  cfg='DISPATCH_REPOS=("jpmoya/claude-agents:/x" "example-owner/project-a:/y")
SCAN_ONLY_REPOS=("JPMoya/Claude-Agents" "example-owner/project-b")'
  drc_cfg "$cfg" 'printf "D:%s\n" ${DISPATCH_REPOS[@]+"${DISPATCH_REPOS[@]}"}; printf "S:%s\n" ${SCAN_ONLY_REPOS[@]+"${SCAN_ONLY_REPOS[@]}"}; printf "X:%s\n" "$DIRECT_ROUTE_DROPPED"'
  assert_eq "$DRC_RC" "0" "load with direct-route entries (output: $DRC_OUT)" || return 1
  assert_contains "$DRC_OUT" "D:example-owner/project-a:/y" "the app repo stays in DISPATCH_REPOS" || return 1
  assert_not_contains "$DRC_OUT" "D:jpmoya" "jpmoya/claude-agents is dropped from DISPATCH_REPOS" || return 1
  assert_contains "$DRC_OUT" "S:example-owner/project-b" "the app repo stays in SCAN_ONLY_REPOS" || return 1
  assert_not_contains "$DRC_OUT" "S:JPMoya" "JPMoya/Claude-Agents (any case) is dropped from SCAN_ONLY_REPOS" || return 1
  assert_contains "$DRC_OUT" "DISPATCH_REPOS jpmoya/claude-agents" "DIRECT_ROUTE_DROPPED records the DISPATCH_REPOS drop (owner/repo, no path)" || return 1
  assert_contains "$DRC_OUT" "SCAN_ONLY_REPOS JPMoya/Claude-Agents" "DIRECT_ROUTE_DROPPED records the SCAN_ONLY_REPOS drop" || return 1
  # a host with no such entry: nothing dropped, lists untouched, arrays still declared (set -u safe on bash 3.2)
  drc_cfg 'DISPATCH_REPOS=("example-owner/project-a:/y")' 'printf "%s|%s|%s" "${#DISPATCH_REPOS[@]}" "${#SCAN_ONLY_REPOS[@]}" "$DIRECT_ROUTE_DROPPED"' /bin/bash
  assert_eq "$DRC_OUT" "1|0|" "no direct-route entry: nothing dropped, nothing recorded" || return 1
}

echo "-- direct-route repos: config (issue #632 AC1)"
run_test test_drc_ac1_constant_lists_claude_agents_with_the_pinned_comment
run_test test_drc_ac1_helper_matches_any_case_and_path_suffix_only_for_listed_repos
run_test test_drc_helper_works_under_bin_bash_3_2_with_set_u
run_test test_drc_host_override_cannot_clear_the_list
run_test test_drc_load_drops_direct_route_entries_from_both_repo_lists_and_records_them
