# Issue #29 (host half) — ACs 9-13: the ticket title + issue URL on the status board.
#
#   AC9   report-status.sh --print, title known: run carries "title" + "url" (https://github.com/
#         <owner/repo>/issues/<n>); repo is still the alias; no gh / curl call is made; exit 0.
#   AC10  title unknown / empty / unreadable: exit 0, valid JSON, run present with neither key;
#         a 300-char title file yields a 140-char title.
#   AC11  with a title file present, "example-owner/project-a" appears in the payload only inside
#         runs[].url values. (test-ac5-no-leak.sh, which has no title file, is untouched.)
#   AC12  orchestrate.sh writes $PIPE/orch-<issue>.title on the launched AND queued paths, and a
#         failing/empty fetch neither breaks the launch nor leaves a title file; supervisor.sh
#         do_launch fetches only when the title file is absent and tolerates failure.
#   AC13  build-runs-json.py makes no gh/curl call; report-status.sh's only curl is the push.
#
# Placeholder repo names only (public repo — AC5/AC17). Expected values are hand-written from the
# ticket. Bash 3.2 portable (no associative arrays).

HERE_ST=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_ST="$HERE_ST/.."
ORCH_ST="$RS_ST/orchestrate.sh"
SUP_ST="$RS_ST/supervisor.sh"

# ---- reporter helpers -----------------------------------------------------------------------

st_write_alias_config() {  # st_write_alias_config <home>
  mkdir -p "$1/.claude/pipeline"
  cat > "$1/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_REPO_ALIASES=("example-owner/project-a:project-a")
EOF
}

# st_install_fakes <home> — fake gh + fake curl on the isolated HOME's .local/bin (config.sh
# prepends it to PATH), each logging every call. Prints the bin dir.
st_install_fakes() {
  local bin="$1/.local/bin"
  mk_fake_gh "$bin"
  : > "$bin/curl-calls.log"
  cat > "$bin/curl" <<'CURL_EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$(dirname "$0")/curl-calls.log"
exit 0
CURL_EOF
  chmod +x "$bin/curl"
  echo "$bin"
}

st_print() {  # st_print <pipe> <home> — payload on stdout; exit code is report-status.sh's
  PIPE="$1" QUEUE="$1/queue" HOME="$2" "$RS_ST/report-status.sh" --print 2>/dev/null
}

# st_run_field <json> <issue> <field> — the run's field value; MISSING_FIELD if the run exists
# without that key; NORUN if the issue is absent; INVALID_JSON if the payload does not parse.
st_run_field() {
  python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print('INVALID_JSON'); sys.exit()
for r in d.get('runs', []):
    if str(r.get('issue')) == str(sys.argv[2]):
        print(r.get(sys.argv[3], 'MISSING_FIELD')); sys.exit()
print('NORUN')
" "$1" "$2" "$3" 2>/dev/null
}

# ---- AC9 ------------------------------------------------------------------------------------

test_st_ac9_title_known_emits_title_and_url_without_network() {
  local pipe home repoA bin out rc
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"
  st_write_alias_config "$home"
  bin=$(st_install_fakes "$home")
  mk_running "$pipe" 601 "$repoA"
  printf 'Fix login redirect\n' > "$pipe/orch-601.title"

  out=$(st_print "$pipe" "$home"); rc=$?
  local gh_n curl_log
  gh_n=$(gh_call_count "$bin" "")
  curl_log=$(cat "$bin/curl-calls.log")
  cleanup_running; rm -rf "$pipe" "$home"

  assert_exit0 "$rc" "AC9: report-status.sh --print exits 0" || return 1
  assert_eq "$(st_run_field "$out" 601 title)" "Fix login redirect" "AC9: title from the .title file (trailing newline stripped)" || return 1
  assert_eq "$(st_run_field "$out" 601 url)" "https://github.com/example-owner/project-a/issues/601" "AC9: url = https://github.com/<owner/repo>/issues/<issue>" || return 1
  assert_eq "$(st_run_field "$out" 601 repo)" "project-a" "AC9: repo is still the alias, not owner/repo" || return 1
  assert_eq "$gh_n" "0" "AC9: the reporter makes no gh call" || return 1
  assert_eq "$curl_log" "" "AC9: the reporter makes no curl call in --print mode" || return 1
}

# ---- AC10 -----------------------------------------------------------------------------------

test_st_ac10_no_empty_or_blank_title_file_emits_neither_field() {
  local pipe home repoA out rc
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"
  st_write_alias_config "$home"
  mk_running "$pipe" 601 "$repoA"; printf 'Fix login redirect\n' > "$pipe/orch-601.title"   # positive control
  mk_running "$pipe" 602 "$repoA"                                                            # no title file
  mk_running "$pipe" 603 "$repoA"; : > "$pipe/orch-603.title"                                # empty file
  mk_running "$pipe" 604 "$repoA"; printf '   \n' > "$pipe/orch-604.title"                    # blank after strip

  out=$(st_print "$pipe" "$home"); rc=$?
  cleanup_running; rm -rf "$pipe" "$home"

  assert_exit0 "$rc" "AC10: exit 0 with title-less runs" || return 1
  assert_eq "$(st_run_field "$out" 601 title)" "Fix login redirect" "AC10: control run still carries its title" || return 1
  local n
  for n in 602 603 604; do
    assert_eq "$(st_run_field "$out" $n state)" "running" "AC10: #$n is still present in valid JSON" || return 1
    assert_eq "$(st_run_field "$out" $n title)" "MISSING_FIELD" "AC10: #$n (no/empty/blank title file) has no title key" || return 1
    assert_eq "$(st_run_field "$out" $n url)" "MISSING_FIELD" "AC10: #$n (no title) has no url key" || return 1
  done
}

test_st_ac10_unreadable_title_file_emits_neither_field() {
  if [ "$(id -u)" = "0" ]; then return 0; fi   # chmod 000 does not stop root — skip as the ticket says
  local pipe home repoA out rc
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"
  st_write_alias_config "$home"
  mk_running "$pipe" 601 "$repoA"; printf 'Fix login redirect\n' > "$pipe/orch-601.title"   # positive control
  mk_running "$pipe" 605 "$repoA"; printf 'Secret unreadable\n' > "$pipe/orch-605.title"; chmod 000 "$pipe/orch-605.title"

  out=$(st_print "$pipe" "$home"); rc=$?
  chmod 644 "$pipe/orch-605.title"
  cleanup_running; rm -rf "$pipe" "$home"

  assert_exit0 "$rc" "AC10: exit 0 with an unreadable title file" || return 1
  assert_eq "$(st_run_field "$out" 601 title)" "Fix login redirect" "AC10: control run still carries its title" || return 1
  assert_eq "$(st_run_field "$out" 605 state)" "running" "AC10: #605 is still present in valid JSON" || return 1
  assert_eq "$(st_run_field "$out" 605 title)" "MISSING_FIELD" "AC10: unreadable title file -> no title key" || return 1
  assert_eq "$(st_run_field "$out" 605 url)" "MISSING_FIELD" "AC10: unreadable title file -> no url key" || return 1
}

# Boundary: 139/140 kept whole, 141 and the ticket's 300 capped to 140 characters.
test_st_ac10_title_capped_at_140_characters() {
  local pipe home repoA out rc n title len expected
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"
  st_write_alias_config "$home"
  mk_running "$pipe" 701 "$repoA"; python3 -c "print('a'*139)"  > "$pipe/orch-701.title"
  mk_running "$pipe" 702 "$repoA"; python3 -c "print('a'*140)"  > "$pipe/orch-702.title"
  mk_running "$pipe" 703 "$repoA"; python3 -c "print('a'*141)"  > "$pipe/orch-703.title"
  mk_running "$pipe" 704 "$repoA"; python3 -c "print('a'*300)"  > "$pipe/orch-704.title"

  out=$(st_print "$pipe" "$home"); rc=$?
  cleanup_running; rm -rf "$pipe" "$home"

  assert_exit0 "$rc" "AC10: exit 0" || return 1
  for n in 701:139 702:140 703:140 704:140; do
    title=$(st_run_field "$out" "${n%%:*}" title)
    expected=${n##*:}
    len=${#title}
    assert_eq "$len" "$expected" "AC10: #${n%%:*} title length (hand arithmetic: min(input, 140))" || return 1
  done
}

test_st_ac10_title_is_first_line_stripped() {
  local pipe home repoA out
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"
  st_write_alias_config "$home"
  mk_running "$pipe" 601 "$repoA"
  printf '  Fix login redirect  \nsecond line must not appear\n' > "$pipe/orch-601.title"

  out=$(st_print "$pipe" "$home")
  cleanup_running; rm -rf "$pipe" "$home"

  assert_eq "$(st_run_field "$out" 601 title)" "Fix login redirect" "AC10/design 4: first line only, surrounding whitespace stripped" || return 1
}

test_st_design4_title_without_resolvable_owner_repo_has_no_url() {
  local pipe home nogit out rc
  pipe=$(new_pipe); home=$(new_home)
  nogit="$pipe/not-a-git-repo"; mkdir -p "$nogit"    # no remote.origin.url -> owner_repo unresolved
  st_write_alias_config "$home"
  mk_running "$pipe" 601 "$nogit"
  printf 'Fix login redirect\n' > "$pipe/orch-601.title"

  out=$(st_print "$pipe" "$home"); rc=$?
  cleanup_running; rm -rf "$pipe" "$home"

  assert_exit0 "$rc" "design 4: exit 0 when owner/repo cannot be resolved" || return 1
  assert_eq "$(st_run_field "$out" 601 title)" "Fix login redirect" "design 4: title still emitted" || return 1
  assert_eq "$(st_run_field "$out" 601 url)" "MISSING_FIELD" "design 4: url only when owner/repo resolved" || return 1
}

# ---- AC11 -----------------------------------------------------------------------------------

test_st_ac11_owner_repo_appears_only_inside_run_urls() {
  local pipe home repoA out stripped
  pipe=$(new_pipe); home=$(new_home)
  repoA="$pipe/repo-project-a"; fixture_repo "$repoA" "example-owner/project-a"
  st_write_alias_config "$home"
  mk_running "$pipe" 601 "$repoA"
  printf 'Fix login redirect\n' > "$pipe/orch-601.title"

  out=$(st_print "$pipe" "$home")
  cleanup_running; rm -rf "$pipe" "$home"

  # Positive half first: the absence check below is vacuous unless the url really is there.
  assert_contains "$out" "example-owner/project-a/issues/601" "AC11: owner/repo is present in runs[].url when a title is known" || return 1
  stripped=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
for r in d['runs']:
    r.pop('url', None)
print(json.dumps(d))
" "$out" 2>/dev/null)
  assert_ne "$stripped" "" "AC11: payload parses and re-serialises" || return 1
  assert_not_contains "$stripped" "example-owner/project-a" "AC11: with every url key deleted, owner/repo appears nowhere else" || return 1
}

# ---- AC13 -----------------------------------------------------------------------------------

test_st_ac13_builder_reads_title_file_and_makes_no_network_call() {
  local hits curl_code
  # Positive half: the builder must actually consume the per-run title file (else the negative
  # greps below are vacuously true of today's file).
  assert_contains "$(cat "$RS_ST/build-runs-json.py")" ".title" "AC13: build-runs-json.py must read orch-<issue>.title" || return 1
  hits=$(grep -n "gh \|curl " "$RS_ST/build-runs-json.py" || true)
  assert_eq "$hits" "" "AC13: build-runs-json.py contains no 'gh ' / 'curl ' (no network call to fetch a title)" || return 1
  # report-status.sh: exactly one curl invocation in code (comments excluded) — the existing push.
  curl_code=$(sed 's/#.*$//' "$RS_ST/report-status.sh" | grep -cE '(^|[^[:alnum:]_])curl[[:space:]]' | tr -d ' ')
  assert_eq "$curl_code" "1" "AC13: report-status.sh's only curl is the existing push" || return 1
}

# ---- AC12: orchestrate.sh launch capture ----------------------------------------------------

# st_env <full|open> -> ST_PIPE, ST_HOME, ST_REPO, ST_BIN. "full" fills every slot so the launch
# queues; "open" zeroes the memory floor so it launches (claude is a no-op stub).
st_env() {
  local mode=$1 i
  ST_PIPE=$(new_pipe); ST_HOME=$(new_home)
  ST_REPO="$ST_PIPE/repo-a"
  fixture_repo "$ST_REPO" "project-a/repo-a"
  ST_BIN="$ST_HOME/.local/bin"
  mk_fake_gh "$ST_BIN"
  echo "project-a/repo-a" > "$ST_BIN/gh-name-with-owner"
  if [ "$mode" = "full" ]; then
    for i in 1 2 3; do mk_running "$ST_PIPE" "$i" "$ST_REPO"; done
  else
    echo 'MEM_FLOOR_MB=0' > "$ST_HOME/.claude/pipeline/config.local.sh"
    printf '#!/bin/bash\nexit 0\n' > "$ST_BIN/claude"
    chmod +x "$ST_BIN/claude"
  fi
}

st_cleanup() {
  local f pid
  for f in "$ST_PIPE"/orch-*.pid; do
    [ -e "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  done
  cleanup_running; rm -rf "$ST_PIPE" "$ST_HOME"
}

# st_sleepy_claude — the claude stub stays alive (30s) so a launched run keeps a live pid and the
# next supervisor tick does not treat it as an exited run to restart.
st_sleepy_claude() {
  printf '#!/bin/bash\nexec sleep 30\n' > "$ST_BIN/claude"
  chmod +x "$ST_BIN/claude"
}

st_launch() {  # st_launch <issue> — orchestrate.sh in the isolated env; combined output on stdout
  HOME="$ST_HOME" PATH="$ST_BIN:/usr/bin:/bin" PIPE="$ST_PIPE" QUEUE="$ST_PIPE/queue" \
    "$ORCH_ST" "$ST_REPO" "$1" 2>&1
}

st_title_file_content() {  # content of $ST_PIPE/orch-<issue>.title, or ABSENT
  if [ -f "$ST_PIPE/orch-$1.title" ]; then printf '%s' "$(cat "$ST_PIPE/orch-$1.title")"; else printf 'ABSENT'; fi
}

test_st_ac12_launched_path_writes_title_file() {
  st_env open
  local out rc title calls
  out=$(st_launch 42); rc=$?
  title=$(st_title_file_content 42)
  calls=$(gh_calls "$ST_BIN")
  st_cleanup
  assert_exit0 "$rc" "AC12: launch exits 0" || return 1
  assert_contains "$out" "launched orchestrator" "AC12: took the launch path" || return 1
  assert_eq "$title" "Fixture title" "AC12: orch-42.title holds the fixture title (launched path)" || return 1
  assert_contains "$calls" "issue view 42 --json title" "AC12: title fetched via gh issue view <n> --json title" || return 1
}

test_st_ac12_queued_path_writes_title_file() {
  st_env full
  local out rc title queued=absent
  out=$(st_launch 42); rc=$?
  title=$(st_title_file_content 42)
  [ -f "$ST_PIPE/queue/orch-42.json" ] && queued=present
  st_cleanup
  assert_exit0 "$rc" "AC12: queued launch exits 0" || return 1
  assert_contains "$out" "queued #42" "AC12: launch was queued" || return 1
  assert_eq "$queued" "present" "AC12: queue entry written" || return 1
  assert_eq "$title" "Fixture title" "AC12: orch-42.title holds the fixture title (queued path — fetched before the capacity check)" || return 1
}

test_st_ac12_relaunch_overwrites_stale_title_file() {
  st_env open
  printf 'old title\n' > "$ST_PIPE/orch-42.title"
  local rc title
  st_launch 42 >/dev/null; rc=$?
  title=$(st_title_file_content 42)
  st_cleanup
  assert_exit0 "$rc" "AC12: relaunch exits 0" || return 1
  assert_eq "$title" "Fixture title" "AC12: a successful fetch replaces a stale title file" || return 1
}

test_st_ac12_failed_fetch_launched_path_still_launches_without_title_file() {
  st_env open
  echo 1 > "$ST_BIN/gh-issue-title-rc"
  printf 'old title\n' > "$ST_PIPE/orch-42.title"     # stale file from a previous run must be removed
  local out rc title pid=absent
  out=$(st_launch 42); rc=$?
  title=$(st_title_file_content 42)
  [ -f "$ST_PIPE/orch-42.pid" ] && pid=present
  st_cleanup
  assert_exit0 "$rc" "AC12: launch still exits 0 when the title fetch fails (set -euo pipefail must not abort it)" || return 1
  assert_contains "$out" "launched orchestrator" "AC12: launch proceeded normally" || return 1
  assert_eq "$pid" "present" "AC12: .pid written despite the failed fetch" || return 1
  assert_eq "$title" "ABSENT" "AC12: failed fetch leaves no .title file (stale one removed)" || return 1
}

test_st_ac12_failed_fetch_queued_path_still_queues_without_title_file() {
  st_env full
  local ctl out rc title queued=absent
  st_launch 41 >/dev/null                                # positive control: a good fetch does write a file
  ctl=$(st_title_file_content 41)
  echo 1 > "$ST_BIN/gh-issue-title-rc"
  out=$(st_launch 42); rc=$?
  title=$(st_title_file_content 42)
  [ -f "$ST_PIPE/queue/orch-42.json" ] && queued=present
  st_cleanup
  assert_eq "$ctl" "Fixture title" "AC12: control — #41 (successful fetch) has its title file" || return 1
  assert_exit0 "$rc" "AC12: queued launch still exits 0 when the title fetch fails" || return 1
  assert_eq "$queued" "present" "AC12: queue file written despite the failed fetch" || return 1
  assert_eq "$title" "ABSENT" "AC12: failed fetch leaves no .title file" || return 1
}

test_st_ac12_empty_fetch_leaves_no_title_file() {
  st_env open
  local ctl rc title
  st_launch 41 >/dev/null                                # positive control: a good fetch does write a file
  ctl=$(st_title_file_content 41)
  : > "$ST_BIN/gh-issue-title"                          # gh succeeds but prints an empty title
  st_launch 42 >/dev/null; rc=$?
  title=$(st_title_file_content 42)
  st_cleanup
  assert_eq "$ctl" "Fixture title" "AC12: control — #41 (non-empty fetch) has its title file" || return 1
  assert_exit0 "$rc" "AC12: launch exits 0 on an empty title" || return 1
  assert_eq "$title" "ABSENT" "AC12: empty fetch output writes no .title file" || return 1
}

# ---- AC12: supervisor.sh do_launch ----------------------------------------------------------

# st_supervisor_tick — one supervisor tick in the isolated env (drains the queue -> do_launch).
st_supervisor_tick() {
  HOME="$ST_HOME" PATH="$ST_BIN:/usr/bin:/bin" PIPE="$ST_PIPE" QUEUE="$ST_PIPE/queue" LOGDIR="$ST_HOME/logs/pipeline" \
    "$SUP_ST" >/dev/null 2>&1
}

test_st_ac12_supervisor_do_launch_fetches_title_when_file_absent() {
  st_env open
  mk_queued "$ST_PIPE" 42 "$ST_REPO"
  st_supervisor_tick
  local title pid=absent
  title=$(st_title_file_content 42)
  [ -f "$ST_PIPE/orch-42.pid" ] && pid=present
  st_cleanup
  assert_eq "$pid" "present" "AC12: supervisor drained the queue entry and launched #42 (scenario sanity)" || return 1
  assert_eq "$title" "Fixture title" "AC12: do_launch fetches the title when no .title file exists" || return 1
}

test_st_ac12_supervisor_do_launch_reuses_existing_title_file() {
  st_env open; st_sleepy_claude
  printf 'Kept title\n' > "$ST_PIPE/orch-42.title"
  echo "Different title from gh" > "$ST_BIN/gh-issue-title"
  mk_queued "$ST_PIPE" 42 "$ST_REPO"
  st_supervisor_tick                                     # tick 1: launches #42 (title file exists)
  mk_queued "$ST_PIPE" 43 "$ST_REPO"
  st_supervisor_tick                                     # tick 2: launches #43 (no title file yet)
  local kept ctl pid42=absent pid43=absent calls42
  kept=$(st_title_file_content 42)
  ctl=$(st_title_file_content 43)
  [ -f "$ST_PIPE/orch-42.pid" ] && pid42=present
  [ -f "$ST_PIPE/orch-43.pid" ] && pid43=present
  calls42=$(gh_call_count "$ST_BIN" "issue view 42 --json title")
  st_cleanup
  assert_eq "$pid42" "present" "AC12: supervisor launched #42 (scenario sanity)" || return 1
  assert_eq "$pid43" "present" "AC12: supervisor launched #43 (scenario sanity)" || return 1
  assert_eq "$ctl" "Different title from gh" "AC12: control — #43 (no .title file) had its title fetched" || return 1
  assert_eq "$kept" "Kept title" "AC12: #42's existing .title file is reused untouched on restart" || return 1
  assert_eq "$calls42" "0" "AC12: no title fetch for #42 when its file already exists" || return 1
}

test_st_ac12_supervisor_do_launch_tolerates_failed_fetch() {
  st_env open; st_sleepy_claude
  mk_queued "$ST_PIPE" 41 "$ST_REPO"
  st_supervisor_tick                                     # control: a good fetch writes a file
  local ctl
  ctl=$(st_title_file_content 41)
  echo 1 > "$ST_BIN/gh-issue-title-rc"
  mk_queued "$ST_PIPE" 42 "$ST_REPO"
  st_supervisor_tick
  local title pid=absent
  title=$(st_title_file_content 42)
  [ -f "$ST_PIPE/orch-42.pid" ] && pid=present
  st_cleanup
  assert_eq "$ctl" "Fixture title" "AC12: control — #41 (successful fetch) has its title file" || return 1
  assert_eq "$pid" "present" "AC12: a failed title fetch does not stop do_launch from launching" || return 1
  assert_eq "$title" "ABSENT" "AC12: failed fetch leaves no .title file" || return 1
}

test_st_ac12_supervisor_do_launch_has_existence_guarded_fetch() {
  local body
  body=$(awk '/^do_launch\(\) \{/{on=1} on{print} on && /^}/{exit}' "$SUP_ST")
  assert_ne "$body" "" "AC12: do_launch found in supervisor.sh" || return 1
  printf '%s\n' "$body" | grep -qE -- '-f[[:space:]]+"\$PIPE/orch-\$issue\.title"' \
    || { fail "AC12: do_launch must guard the fetch with a [ -f \"\$PIPE/orch-\$issue.title\" ]-style existence check"; return 1; }
  printf '%s\n' "$body" | grep -q -- '--json title' \
    || { fail "AC12: do_launch must fetch the title via gh issue view --json title"; return 1; }
}

run_test test_st_ac9_title_known_emits_title_and_url_without_network
run_test test_st_ac10_no_empty_or_blank_title_file_emits_neither_field
run_test test_st_ac10_unreadable_title_file_emits_neither_field
run_test test_st_ac10_title_capped_at_140_characters
run_test test_st_ac10_title_is_first_line_stripped
run_test test_st_design4_title_without_resolvable_owner_repo_has_no_url
run_test test_st_ac11_owner_repo_appears_only_inside_run_urls
run_test test_st_ac13_builder_reads_title_file_and_makes_no_network_call
run_test test_st_ac12_launched_path_writes_title_file
run_test test_st_ac12_queued_path_writes_title_file
run_test test_st_ac12_relaunch_overwrites_stale_title_file
run_test test_st_ac12_failed_fetch_launched_path_still_launches_without_title_file
run_test test_st_ac12_failed_fetch_queued_path_still_queues_without_title_file
run_test test_st_ac12_empty_fetch_leaves_no_title_file
run_test test_st_ac12_supervisor_do_launch_fetches_title_when_file_absent
run_test test_st_ac12_supervisor_do_launch_reuses_existing_title_file
run_test test_st_ac12_supervisor_do_launch_tolerates_failed_fetch
run_test test_st_ac12_supervisor_do_launch_has_existence_guarded_fetch
