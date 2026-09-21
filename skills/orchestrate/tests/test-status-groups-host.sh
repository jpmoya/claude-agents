# Issue #65 (host half of #62) — the hosts publish the on-staging and approved lists, queued rows are
# no longer crowded out by held ones, and released-but-open tickets count as done.
#
#   AC1  runs[] priority running < restarting < queued < held, cap 20, all running+queued survive
#   AC2  reconcile --force: two `issue list` calls per repo (once per repo), files status-staging.json /
#        status-approved.json = fixture issues; a change reports once
#   AC3  payload staging[] / approved[] shape, order, caps 60 / 20, title <= 140, [] on missing/invalid; v == 1
#   AC4  a failing list call keeps that repo's previous entries; exit 0, silent
#   AC5  a non-running row whose ticket is on this host's staging list leaves runs[]; running stays
#   AC6  OPEN + milestone ^vN.N.N$ == CLOSED (.release, completed[].release); other titles do nothing
#   AC7  one `issue view` per in-scope ticket (with milestone in --json); throttle covers the list calls
#   AC8  building the payload makes no gh call
#   AC9  orchestrate.sh relaunch cleanup removes orch-<n>.release
#   (AC10 regression gates = the existing suites staying green, golden untouched; AC12 is a delivery
#    obligation. AC3's "both arrays are part of the change hash" is not separately tested: hash_payload
#    hashes the whole payload minus sent_at / supervisor_last_tick.)
#
# Placeholder repo names only (public repo). Expected values are hand-written from the ticket.
# Bash 3.2 portable. Fake gh = tests/lib/fixture.sh mk_fake_gh (extended additively for #65).

HERE_SG=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_SG="$HERE_SG/.."
ROOT_SG=$(cd "$HERE_SG/../../.." && pwd)

SG_A="example-owner/project-a"
SG_B="example-owner/project-b"
SG_KEY_A="example-owner_project-a"
SG_KEY_B="example-owner_project-b"

# ---- helpers ----------------------------------------------------------------------------------

sg_iso_ago() {
  python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"
}

# sg_env — SG_PIPE, SG_HOME, SG_REPO (checkout of project-a), SG_BIN (fake gh). config.local.sh:
# DISPATCH_REPOS = project-a, SCAN_ONLY_REPOS = project-b, aliases for both.
sg_env() {
  SG_PIPE=$(new_pipe); SG_HOME=$(new_home); SG_ROOT=""
  SG_REPO="$SG_PIPE/repo-project-a"
  fixture_repo "$SG_REPO" "$SG_A"
  SG_BIN="$SG_HOME/.local/bin"
  mk_fake_gh "$SG_BIN"
  echo "$SG_A" > "$SG_BIN/gh-name-with-owner"
  cat > "$SG_HOME/.claude/pipeline/config.local.sh" <<EOF
DISPATCH_REPOS=("$SG_A:$SG_REPO")
SCAN_ONLY_REPOS=("$SG_B")
STATUS_REPO_ALIASES=("$SG_A:project-a" "$SG_B:project-b")
MEM_FLOOR_MB=0
EOF
}

sg_cleanup() {
  local f pid
  for f in "$SG_PIPE"/orch-*.pid; do
    [ -e "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  done
  cleanup_running
  rm -rf "$SG_PIPE" "$SG_HOME"
  [ -n "$SG_ROOT" ] && rm -rf "$SG_ROOT"
  return 0
}

sg_run() {  # sg_run <script> [args] -> SG_OUT (stdout+stderr), SG_RC
  local script=$1; shift
  SG_OUT=$(HOME="$SG_HOME" PATH="$SG_BIN:/usr/bin:/bin" PIPE="$SG_PIPE" QUEUE="$SG_PIPE/queue" LOGDIR="$SG_HOME/logs/pipeline" \
    "$script" "$@" 2>&1)
  SG_RC=$?
}
sg_reconcile() { sg_run "$RS_SG/reconcile-status.sh" "$@"; }
sg_print() {
  HOME="$SG_HOME" PATH="$SG_BIN:/usr/bin:/bin" PIPE="$SG_PIPE" QUEUE="$SG_PIPE/queue" LOGDIR="$SG_HOME/logs/pipeline" \
    "$RS_SG/report-status.sh" --print 2>/dev/null
}

sg_present() { if [ -e "$1" ]; then echo present; else echo absent; fi; }

# sg_list_fixture <staging|approved> <key> <json> — what the fake gh answers for that repo's list call
sg_list_fixture() { printf '%s\n' "$3" > "$SG_BIN/gh-list-$1-$2"; }

# sg_gen_gh_list <n> [title] — a raw `gh issue list` array of <n> issues, #1..#n, ascending in the
# file; issue i was updated i minutes after 2026-09-01T00:00Z (so #n is the newest).
sg_gen_gh_list() {
  python3 -c "
import json, sys, datetime
n = int(sys.argv[1]); t = sys.argv[2] if len(sys.argv) > 2 else ''
base = datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc)
print(json.dumps([{'number': i, 'title': t or 'Title %d' % i,
                   'updatedAt': (base + datetime.timedelta(minutes=i)).strftime('%Y-%m-%dT%H:%M:%SZ')}
                  for i in range(1, n + 1)]))" "$@"
}

# sg_gen_list_file <file> <owner/repo> <n> [title] — the host-side list file (already reconciled shape)
sg_gen_list_file() {
  python3 -c "
import json, sys, datetime
path, repo, n = sys.argv[1], sys.argv[2], int(sys.argv[3]); t = sys.argv[4] if len(sys.argv) > 4 else ''
base = datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc)
json.dump([{'owner_repo': repo, 'issue': i, 'title': t or 'Title %d' % i,
            'updated_at': (base + datetime.timedelta(minutes=i)).strftime('%Y-%m-%dT%H:%M:%SZ')}
           for i in range(1, n + 1)], open(path, 'w'))" "$@"
}

sg_states() { printf '%s' "$1" | jq -r '[.runs[].state]|join(" ")' 2>/dev/null || echo INVALID_JSON; }
sg_runs_issues() { printf '%s' "$1" | jq -r '[.runs[].issue|tostring]|join(" ")' 2>/dev/null || echo INVALID_JSON; }
sg_completed_issues() { printf '%s' "$1" | jq -r 'if (.completed|type)=="array" then ([.completed[].issue|tostring]|join(" ")) else "NOCOMPLETED" end' 2>/dev/null || echo INVALID_JSON; }
sg_completed_field() {  # sg_completed_field <json> <issue> <field>
  printf '%s' "$1" | jq -r --arg n "$2" --arg f "$3" \
    '[.completed[]? | select((.issue|tostring)==$n)] | if length==0 then "NOITEM" else (.[0] | if has($f) then (.[$f]|tostring) else "MISSING_FIELD" end) end' 2>/dev/null || echo INVALID_JSON
}

# sg_wait_lines <file> <min> — poll (bounded) until <file> has >= <min> lines, then until two reads agree.
sg_wait_lines() {
  local f=$1 min=$2 n=0 prev i=0
  while [ "$i" -lt 25 ]; do
    n=$(cat "$f" 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" -ge "$min" ] && break
    sleep 0.2; i=$((i + 1))
  done
  while :; do
    prev=$n; sleep 0.2
    n=$(cat "$f" 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = "$prev" ] && break
  done
  echo "$n"
}

# sg_mirror — hooks/ + skills/orchestrate/ copy whose report-status.sh only records its calls.
sg_mirror() {
  SG_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-root.XXXXXX")
  mkdir -p "$SG_ROOT/skills/orchestrate"
  cp -R "$ROOT_SG/hooks" "$SG_ROOT/hooks"
  cp "$RS_SG"/*.sh "$RS_SG"/*.py "$SG_ROOT/skills/orchestrate/"
  cat > "$SG_ROOT/skills/orchestrate/report-status.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SG_ROOT/report.calls"
EOF
  chmod +x "$SG_ROOT/skills/orchestrate/"*.sh
}

# =================================================================================================
# AC1 — priority + cap
# =================================================================================================

test_sg_ac1_queued_survive_cap_and_sort_before_held() {
  sg_env
  local i
  for i in 1 2; do mk_running "$SG_PIPE" "$i" "$SG_REPO"; done
  for i in 11 12 13; do mk_queued "$SG_PIPE" "$i" "$SG_REPO"; done
  i=101; while [ "$i" -le 125 ]; do mk_held "$SG_PIPE" "$i" "$SG_REPO"; i=$((i + 1)); done
  local out; out=$(sg_print)
  sg_cleanup
  # hand arithmetic: 2 running + 3 queued + 15 held = 20 (cap), held is what gets cut
  assert_eq "$(printf '%s' "$out" | jq '.runs|length')" "20" "AC1: cap stays 20" || return 1
  assert_eq "$(sg_states "$out")" \
    "running running queued queued queued held held held held held held held held held held held held held held held" \
    "AC1: 2 running, then all 3 queued, then held" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.capacity.queued')" "3" "AC1: capacity.queued unchanged" || return 1
}

test_sg_ac1_priority_running_restarting_queued_held() {
  sg_env
  mk_held "$SG_PIPE" 21 "$SG_REPO"
  mk_queued "$SG_PIPE" 22 "$SG_REPO"
  mk_restarting "$SG_PIPE" 23 "$SG_REPO"
  mk_running "$SG_PIPE" 24 "$SG_REPO"
  local out; out=$(sg_print)
  sg_cleanup
  assert_eq "$(sg_states "$out")" "running restarting queued held" "EB1: running 0, restarting 1, queued 2, held 3" || return 1
}

# =================================================================================================
# AC2 — list calls + files
# =================================================================================================

test_sg_ac2_reconcile_writes_both_lists_from_both_repos() {
  sg_env
  sg_list_fixture staging "$SG_KEY_A" '[{"number":5,"title":"Staged five","updatedAt":"2026-09-20T10:00:00Z"},{"number":6,"title":"Staged six","updatedAt":"2026-09-20T11:00:00Z"}]'
  sg_list_fixture staging "$SG_KEY_B" '[{"number":7,"title":"Staged seven","updatedAt":"2026-09-19T09:00:00Z"}]'
  sg_list_fixture approved "$SG_KEY_A" '[{"number":8,"title":"Approved eight","updatedAt":"2026-09-18T08:00:00Z"}]'
  sg_list_fixture approved "$SG_KEY_B" '[{"number":9,"title":"Approved nine","updatedAt":"2026-09-17T07:00:00Z"},{"number":10,"title":"Approved ten","updatedAt":"2026-09-17T08:00:00Z"}]'
  sg_reconcile --force
  local rc=$SG_RC
  local staging approved
  staging=$(jq -c 'sort_by(.owner_repo, .issue)' "$SG_PIPE/status-staging.json" 2>/dev/null)
  approved=$(jq -c 'sort_by(.owner_repo, .issue)' "$SG_PIPE/status-approved.json" 2>/dev/null)
  sg_cleanup
  assert_exit0 "$rc" "AC2: exit 0" || return 1
  assert_eq "$staging" '[{"owner_repo":"example-owner/project-a","issue":5,"title":"Staged five","updated_at":"2026-09-20T10:00:00Z"},{"owner_repo":"example-owner/project-a","issue":6,"title":"Staged six","updated_at":"2026-09-20T11:00:00Z"},{"owner_repo":"example-owner/project-b","issue":7,"title":"Staged seven","updated_at":"2026-09-19T09:00:00Z"}]' "AC2: status-staging.json = the fixture issues, exact keys" || return 1
  assert_eq "$approved" '[{"owner_repo":"example-owner/project-a","issue":8,"title":"Approved eight","updated_at":"2026-09-18T08:00:00Z"},{"owner_repo":"example-owner/project-b","issue":9,"title":"Approved nine","updated_at":"2026-09-17T07:00:00Z"},{"owner_repo":"example-owner/project-b","issue":10,"title":"Approved ten","updated_at":"2026-09-17T08:00:00Z"}]' "AC2: status-approved.json = the fixture issues, exact keys" || return 1
}

test_sg_ac2_exactly_two_list_calls_per_repo_with_the_specified_flags() {
  sg_env
  sg_reconcile --force
  local total a b
  total=$(gh_call_count "$SG_BIN" "issue list")
  a=$(gh_call_count "$SG_BIN" "issue list --repo $SG_A ")
  b=$(gh_call_count "$SG_BIN" "issue list --repo $SG_B ")
  local calls; calls=$(gh_calls "$SG_BIN")
  sg_cleanup
  assert_eq "$total" "4" "AC2: two repos x two calls" || return 1
  assert_eq "$a" "2" "AC2: two calls for project-a" || return 1
  assert_eq "$b" "2" "AC2: two calls for project-b" || return 1
  assert_contains "$calls" "--state open --search milestone:staging --limit 100 --json number,title,updatedAt" "AC2: staging call flags (--search, not --milestone)" || return 1
  assert_contains "$calls" "--state open --label agent-go --limit 50 --json number,title,updatedAt" "AC2: approved call flags" || return 1
  assert_not_contains "$calls" "--milestone" "AC2: never the --milestone form (errors on repos without it)" || return 1
}

test_sg_ac2_repo_in_both_config_lists_is_queried_once() {
  sg_env
  cat > "$SG_HOME/.claude/pipeline/config.local.sh" <<EOF
DISPATCH_REPOS=("$SG_A:$SG_REPO" "$SG_B:$SG_REPO")
SCAN_ONLY_REPOS=("$SG_A" "$SG_B:/ignored/path")
MEM_FLOOR_MB=0
EOF
  sg_reconcile --force
  local total a b
  total=$(gh_call_count "$SG_BIN" "issue list")
  a=$(gh_call_count "$SG_BIN" "issue list --repo $SG_A ")
  b=$(gh_call_count "$SG_BIN" "issue list --repo $SG_B ")
  sg_cleanup
  assert_eq "$a:$b:$total" "2:2:4" "AC2: each repo once even when listed in DISPATCH_REPOS and SCAN_ONLY_REPOS" || return 1
}

test_sg_ac2_list_change_reports_once_and_no_change_does_not() {
  sg_env; sg_mirror
  sg_list_fixture staging "$SG_KEY_A" "$(sg_gen_gh_list 1)"
  sg_run "$SG_ROOT/skills/orchestrate/reconcile-status.sh" --force
  local first; first=$(sg_wait_lines "$SG_ROOT/report.calls" 1)
  sg_run "$SG_ROOT/skills/orchestrate/reconcile-status.sh" --force          # same lists -> no change
  local second; second=$(sg_wait_lines "$SG_ROOT/report.calls" 1)
  sg_list_fixture approved "$SG_KEY_B" "$(sg_gen_gh_list 2)"
  sg_run "$SG_ROOT/skills/orchestrate/reconcile-status.sh" --force          # approved list changed
  local third; third=$(sg_wait_lines "$SG_ROOT/report.calls" 2)
  sg_cleanup
  assert_eq "$first" "1" "AC2: a changed list file sets changed=1 -> one report" || return 1
  assert_eq "$second" "1" "AC2: identical lists -> no further report" || return 1
  assert_eq "$third" "2" "AC2: a change in the approved file alone -> one more report" || return 1
}

# =================================================================================================
# AC3 — payload arrays
# =================================================================================================

test_sg_ac3_payload_items_shape_order_and_alias() {
  sg_env
  cat > "$SG_PIPE/status-staging.json" <<EOF
[{"owner_repo":"$SG_A","issue":5,"title":"Older","updated_at":"2026-09-20T10:00:00Z"},
 {"owner_repo":"$SG_B","issue":7,"title":"Newest","updated_at":"2026-09-21T09:00:00Z"},
 {"owner_repo":"example-owner/project-z","issue":9,"title":"Unmapped","updated_at":"2026-09-20T12:00:00Z"}]
EOF
  cat > "$SG_PIPE/status-approved.json" <<EOF
[{"owner_repo":"$SG_A","issue":8,"title":"Approved","updated_at":"2026-09-18T08:00:00Z"}]
EOF
  local out; out=$(sg_print)
  sg_cleanup
  assert_eq "$(printf '%s' "$out" | jq -c '.staging')" '[{"repo":"project-b","issue":7,"title":"Newest","url":"https://github.com/example-owner/project-b/issues/7","updated_at":"2026-09-21T09:00:00Z"},{"repo":"other","issue":9,"title":"Unmapped","url":"https://github.com/example-owner/project-z/issues/9","updated_at":"2026-09-20T12:00:00Z"},{"repo":"project-a","issue":5,"title":"Older","url":"https://github.com/example-owner/project-a/issues/5","updated_at":"2026-09-20T10:00:00Z"}]' "AC3: staging items {repo(alias|other), issue, title, url, updated_at}, newest first" || return 1
  assert_eq "$(printf '%s' "$out" | jq -c '.approved')" '[{"repo":"project-a","issue":8,"title":"Approved","url":"https://github.com/example-owner/project-a/issues/8","updated_at":"2026-09-18T08:00:00Z"}]' "AC3: approved items" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.v')" "1" "AC3: v stays 1" || return 1
}

test_sg_ac3_caps_60_staging_20_approved_newest_kept() {
  sg_env
  sg_gen_list_file "$SG_PIPE/status-staging.json" "$SG_A" 70
  sg_gen_list_file "$SG_PIPE/status-approved.json" "$SG_A" 25
  local out; out=$(sg_print)
  sg_cleanup
  # hand arithmetic: 70 issues, #70 newest -> keep #70..#11 (60); 25 issues -> keep #25..#6 (20)
  assert_eq "$(printf '%s' "$out" | jq -r '[.staging[].issue]|"\(length) \(first) \(last)"')" "60 70 11" "AC3: staging capped at 60 newest" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '[.approved[].issue]|"\(length) \(first) \(last)"')" "20 25 6" "AC3: approved capped at 20 newest" || return 1
}

test_sg_ac3_cap_boundaries_60_and_20_are_not_cut() {
  sg_env
  sg_gen_list_file "$SG_PIPE/status-staging.json" "$SG_A" 60
  sg_gen_list_file "$SG_PIPE/status-approved.json" "$SG_A" 20
  local out; out=$(sg_print)
  sg_cleanup
  assert_eq "$(printf '%s' "$out" | jq -r '"\(.staging|length) \(.approved|length)"')" "60 20" "AC3: exactly at the caps nothing is dropped" || return 1
}

test_sg_ac3_title_capped_at_140_chars() {
  sg_env
  sg_gen_list_file "$SG_PIPE/status-staging.json" "$SG_A" 1 "$(python3 -c "print('x'*200)")"
  sg_gen_list_file "$SG_PIPE/status-approved.json" "$SG_A" 1 "$(python3 -c "print('y'*140)")"
  local out; out=$(sg_print)
  sg_cleanup
  assert_eq "$(printf '%s' "$out" | jq -r '.staging[0].title|length')" "140" "AC3: 200-char title cut to 140" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.approved[0].title|length')" "140" "AC3: 140-char title untouched" || return 1
}

test_sg_ac3_missing_or_invalid_files_give_empty_arrays() {
  sg_env
  local none; none=$(sg_print)
  printf 'not json {' > "$SG_PIPE/status-staging.json"
  printf '{"an":"object"}' > "$SG_PIPE/status-approved.json"
  local bad; bad=$(sg_print)
  local rc=$?
  sg_cleanup
  assert_eq "$(printf '%s' "$none" | jq -c '[.staging,.approved]')" '[[],[]]' "AC3: no files -> [] and [] (keys present)" || return 1
  assert_eq "$(printf '%s' "$bad" | jq -c '[.staging,.approved]')" '[[],[]]' "AC3: invalid content -> [] and []" || return 1
  assert_eq "$(printf '%s' "$bad" | jq '.v')" "1" "AC3: v still 1 with invalid files" || return 1
  assert_exit0 "$rc" "AC3: exit 0 with invalid files" || return 1
}

# =================================================================================================
# AC4 — failed list call keeps previous entries
# =================================================================================================

test_sg_ac4_failed_list_call_keeps_that_repos_previous_entries() {
  sg_env
  sg_list_fixture staging "$SG_KEY_A" '[{"number":5,"title":"A five","updatedAt":"2026-09-20T10:00:00Z"}]'
  sg_list_fixture staging "$SG_KEY_B" '[{"number":7,"title":"B seven","updatedAt":"2026-09-20T10:00:00Z"}]'
  sg_list_fixture approved "$SG_KEY_A" '[{"number":8,"title":"A eight","updatedAt":"2026-09-20T10:00:00Z"}]'
  sg_reconcile --force                                                   # good pass
  : > "$SG_BIN/gh-list-fail-$SG_KEY_A"                                   # project-a now fails ...
  sg_list_fixture staging "$SG_KEY_B" '[{"number":17,"title":"B seventeen","updatedAt":"2026-09-21T10:00:00Z"}]'   # ... project-b moves on
  sg_reconcile --force
  local rc=$SG_RC out=$SG_OUT
  local staging approved
  staging=$(jq -c 'map([.owner_repo,.issue])|sort' "$SG_PIPE/status-staging.json" 2>/dev/null)
  approved=$(jq -c 'map([.owner_repo,.issue])|sort' "$SG_PIPE/status-approved.json" 2>/dev/null)
  sg_cleanup
  assert_exit0 "$rc" "AC4: pass exits 0" || return 1
  assert_eq "$out" "" "AC4: pass prints nothing" || return 1
  assert_eq "$staging" '[["example-owner/project-a",5],["example-owner/project-b",17]]' "AC4: project-a kept its previous staging entry, project-b updated" || return 1
  assert_eq "$approved" '[["example-owner/project-a",8]]' "AC4: project-a kept its previous approved entry" || return 1
}

test_sg_ac4_failed_call_with_no_previous_entries_leaves_other_repo_intact() {
  sg_env
  sg_list_fixture staging "$SG_KEY_B" '[{"number":7,"title":"B seven","updatedAt":"2026-09-20T10:00:00Z"}]'
  : > "$SG_BIN/gh-list-fail-$SG_KEY_A"
  sg_reconcile --force
  local rc=$SG_RC out=$SG_OUT
  local staging; staging=$(jq -c 'map([.owner_repo,.issue])' "$SG_PIPE/status-staging.json" 2>/dev/null)
  sg_cleanup
  assert_exit0 "$rc" "AC4: exit 0" || return 1
  assert_eq "$out" "" "AC4: silent" || return 1
  assert_eq "$staging" '[["example-owner/project-b",7]]' "AC4: only the working repo's entries are written" || return 1
}

# =================================================================================================
# AC5 — staging exclusion
# =================================================================================================

test_sg_ac5_non_running_rows_on_staging_list_are_left_out_running_stays() {
  sg_env
  mk_held "$SG_PIPE" 201 "$SG_REPO"          # on staging list -> out
  mk_held "$SG_PIPE" 203 "$SG_REPO"          # not on the list -> stays
  mk_running "$SG_PIPE" 202 "$SG_REPO"       # on the list but running -> stays
  mk_queued "$SG_PIPE" 204 "$SG_REPO"        # queued and on the list -> out
  mk_restarting "$SG_PIPE" 205 "$SG_REPO"    # restarting and on the list -> out
  mk_held "$SG_PIPE" 206 "$SG_REPO"          # same number on the list, but in ANOTHER repo -> stays
  cat > "$SG_PIPE/status-staging.json" <<EOF
[{"owner_repo":"$SG_A","issue":201,"title":"t","updated_at":"2026-09-20T10:00:00Z"},
 {"owner_repo":"$SG_A","issue":202,"title":"t","updated_at":"2026-09-20T10:00:00Z"},
 {"owner_repo":"$SG_A","issue":204,"title":"t","updated_at":"2026-09-20T10:00:00Z"},
 {"owner_repo":"$SG_A","issue":205,"title":"t","updated_at":"2026-09-20T10:00:00Z"},
 {"owner_repo":"$SG_B","issue":206,"title":"t","updated_at":"2026-09-20T10:00:00Z"}]
EOF
  local out; out=$(sg_print)
  sg_cleanup
  # running first, then held by newest activity; only the set matters here
  local issues; issues=$(printf '%s' "$out" | jq -r '[.runs[].issue]|sort|map(tostring)|join(" ")')
  assert_eq "$issues" "202 203 206" "AC5: held/queued/restarting on the staging list are absent; running and other-repo rows stay" || return 1
  assert_eq "$(printf '%s' "$out" | jq -r '.runs[]|select(.issue==202)|.state')" "running" "AC5: the running record stays running" || return 1
}

# =================================================================================================
# AC6 — released-but-open
# =================================================================================================

test_sg_ac6_open_issue_with_release_milestone_becomes_done_with_release() {
  sg_env
  mk_held "$SG_PIPE" 401 "$SG_REPO"; touch "$SG_PIPE/orch-401.alert" "$SG_PIPE/orch-401.stopped"
  printf 'Title of 401\n' > "$SG_PIPE/orch-401.title"
  echo "v1.3.0" > "$SG_BIN/gh-issue-milestone-401"
  local before; before=$(sg_print)
  sg_reconcile --force
  local out; out=$(sg_print)
  local age
  age=$(python3 -c "
import datetime, sys
t = datetime.datetime.strptime(open(sys.argv[1]).readline().strip(), '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
print(int(abs((datetime.datetime.now(datetime.timezone.utc) - t).total_seconds())))" "$SG_PIPE/orch-401.closed" 2>/dev/null || echo BAD)
  local log; log=$(cat "$SG_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  local rel; rel=$(head -n1 "$SG_PIPE/orch-401.release" 2>/dev/null)
  local st; st="$(sg_present "$SG_PIPE/orch-401.done"):$(sg_present "$SG_PIPE/orch-401.held"):$(sg_present "$SG_PIPE/orch-401.stopped"):$(sg_present "$SG_PIPE/orch-401.alert")"
  sg_cleanup
  assert_eq "$(sg_runs_issues "$before")" "401" "AC6: control — it is a held row beforehand" || return 1
  assert_eq "$rel" "v1.3.0" "AC6: orch-<n>.release = the milestone title" || return 1
  assert_eq "$st" "present:absent:absent:absent" "AC6: .done touched; .held/.stopped/.alert removed" || return 1
  case "$age" in ''|BAD|*[!0-9]*) fail "AC6: .closed must hold an ISO timestamp (got '$age')"; return 1 ;; esac
  assert_lt "$age" 300 "AC6: .closed = the time of this pass" || return 1
  assert_contains "$log" "released v1.3.0" "AC6: supervisor.log gets a 'released <version>' line" || return 1
  assert_eq "$(sg_runs_issues "$out")" "" "AC6: absent from runs[]" || return 1
  assert_eq "$(sg_completed_issues "$out")" "401" "AC6: present in completed[]" || return 1
  assert_eq "$(sg_completed_field "$out" 401 release)" "v1.3.0" "AC6: completed[].release" || return 1
}

test_sg_ac6_open_release_queued_ticket_drops_its_queue_entry() {
  sg_env
  mk_queued "$SG_PIPE" 402 "$SG_REPO"; printf 'Title of 402\n' > "$SG_PIPE/orch-402.title"
  echo "v2.0.1" > "$SG_BIN/gh-issue-milestone-402"
  sg_reconcile --force
  local out; out=$(sg_print)
  local q; q=$(sg_present "$SG_PIPE/queue/orch-402.json")
  sg_cleanup
  assert_eq "$q" "absent" "AC6: queue entry removed" || return 1
  assert_eq "$(sg_completed_issues "$out")" "402" "AC6: queued-only ticket lands in completed[]" || return 1
  assert_eq "$(sg_completed_field "$out" 402 release)" "v2.0.1" "AC6: with its release" || return 1
}

test_sg_ac6_closed_issue_with_release_milestone_carries_release() {
  sg_env
  mk_held "$SG_PIPE" 403 "$SG_REPO"; printf 'Title of 403\n' > "$SG_PIPE/orch-403.title"
  echo "CLOSED" > "$SG_BIN/gh-issue-state-403"
  sg_iso_ago 3600 > "$SG_BIN/gh-issue-closed-at-403"
  echo "v1.3.0" > "$SG_BIN/gh-issue-milestone-403"
  mk_held "$SG_PIPE" 404 "$SG_REPO"; printf 'Title of 404\n' > "$SG_PIPE/orch-404.title"
  echo "CLOSED" > "$SG_BIN/gh-issue-state-404"
  sg_iso_ago 3600 > "$SG_BIN/gh-issue-closed-at-404"          # closed, no milestone
  sg_reconcile --force
  local out; out=$(sg_print)
  sg_cleanup
  assert_eq "$(sg_completed_field "$out" 403 release)" "v1.3.0" "AC6: CLOSED + release milestone -> release" || return 1
  assert_eq "$(sg_completed_field "$out" 404 release)" "MISSING_FIELD" "AC6: CLOSED without milestone -> no release key" || return 1
}

test_sg_ac6_non_release_milestone_titles_do_nothing() {
  sg_env
  local n=0 t
  for t in "v1.3" "staging" "release-1" "v1.3.0-rc1" "1.3.0" "v1.3.0.1"; do
    n=$((n + 1)); local issue=$((500 + n))
    mk_held "$SG_PIPE" "$issue" "$SG_REPO"; printf 'Title %s\n' "$issue" > "$SG_PIPE/orch-$issue.title"
    printf '%s\n' "$t" > "$SG_BIN/gh-issue-milestone-$issue"
  done
  mk_held "$SG_PIPE" 520 "$SG_REPO"; echo "v9.9.9" > "$SG_BIN/gh-issue-milestone-520"   # positive control
  sg_reconcile --force
  local out; out=$(sg_print)
  local files; files=$(ls "$SG_PIPE" | grep -c '\.release$' | tr -d ' ')
  local ctl; ctl=$(sg_present "$SG_PIPE/orch-520.release")
  sg_cleanup
  assert_eq "$ctl" "present" "AC6: control — a v9.9.9 milestone in the same pass does write .release" || return 1
  assert_eq "$files" "1" "AC6: none of v1.3 / staging / release-1 / v1.3.0-rc1 / 1.3.0 / v1.3.0.1 writes .release (only the control does)" || return 1
  assert_eq "$(sg_completed_issues "$out")" "520" "AC6: none of them is treated as done (only the control is)" || return 1
  assert_eq "$(printf '%s' "$out" | jq '.runs|length')" "6" "AC6: all six stay in runs[]" || return 1
}

test_sg_ac6_null_milestone_leaves_open_ticket_alone() {
  sg_env
  mk_held "$SG_PIPE" 510 "$SG_REPO"                        # gh answers milestone: null
  mk_held "$SG_PIPE" 511 "$SG_REPO"; echo "v1.0.0" > "$SG_BIN/gh-issue-milestone-511"   # positive control
  sg_reconcile --force
  local out; out=$(sg_print)
  local r; r=$(sg_present "$SG_PIPE/orch-510.release")
  local ctl; ctl=$(sg_present "$SG_PIPE/orch-511.release")
  sg_cleanup
  assert_eq "$ctl" "present" "AC6: control — the v1.0.0 ticket in the same pass gets .release" || return 1
  assert_eq "$r" "absent" "AC6: no milestone -> no .release" || return 1
  assert_eq "$(sg_runs_issues "$out")" "510" "AC6: still in runs[]" || return 1
}

# =================================================================================================
# AC7 — one view per ticket, throttle covers the lists
# =================================================================================================

test_sg_ac7_one_issue_view_per_ticket_with_milestone_field() {
  sg_env
  mk_held "$SG_PIPE" 601 "$SG_REPO"; mk_held "$SG_PIPE" 602 "$SG_REPO"
  echo "v1.3.0" > "$SG_BIN/gh-issue-milestone-601"
  sg_reconcile --force
  local c1 c2 calls
  c1=$(gh_call_count "$SG_BIN" "issue view 601 "); c2=$(gh_call_count "$SG_BIN" "issue view 602 ")
  calls=$(gh_calls "$SG_BIN" | grep 'issue view 601 ')
  sg_cleanup
  assert_eq "$c1:$c2" "1:1" "AC7: exactly one issue view per in-scope ticket" || return 1
  assert_contains "$calls" "--json state,closedAt,comments,milestone" "AC7: the call asks for milestone too" || return 1
}

test_sg_ac7_throttle_covers_list_calls() {
  sg_env
  mk_held "$SG_PIPE" 603 "$SG_REPO"
  sg_reconcile                                              # first non-forced pass: runs (no stamp)
  local after_first; after_first=$(gh_call_count "$SG_BIN" "")
  local lists; lists=$(gh_call_count "$SG_BIN" "issue list")
  sg_reconcile                                              # second within 600 s: nothing
  local after_second; after_second=$(gh_call_count "$SG_BIN" "")
  sg_cleanup
  assert_eq "$lists" "4" "AC7: control — the first pass made the four list calls" || return 1
  assert_eq "$after_second" "$after_first" "AC7: second non-forced run inside the window makes zero gh calls" || return 1
}

# =================================================================================================
# AC8 — builder is network-free
# =================================================================================================

test_sg_ac8_print_makes_no_gh_call() {
  sg_env
  mk_held "$SG_PIPE" 701 "$SG_REPO"
  sg_gen_list_file "$SG_PIPE/status-staging.json" "$SG_A" 3
  sg_gen_list_file "$SG_PIPE/status-approved.json" "$SG_A" 3
  local out; out=$(sg_print)
  local n; n=$(gh_call_count "$SG_BIN" "")
  sg_cleanup
  assert_eq "$(printf '%s' "$out" | jq '.staging|length')" "3" "AC8: control — the payload does carry the lists" || return 1
  assert_eq "$n" "0" "AC8: call log empty after --print" || return 1
}

# =================================================================================================
# AC9 — relaunch cleanup
# =================================================================================================

test_sg_ac9_relaunch_cleanup_line_lists_release() {
  local line; line=$(grep -n 'rm -f "\$PIPE/orch-\$ISSUE"' "$RS_SG/orchestrate.sh" | head -n1)
  assert_contains "$line" "release" "AC9: the relaunch rm -f brace list contains release" || return 1
}

test_sg_ac9_relaunch_removes_release_file() {
  sg_env
  printf '#!/bin/bash\nexec sleep 30\n' > "$SG_BIN/claude"; chmod +x "$SG_BIN/claude"
  mk_held "$SG_PIPE" 801 "$SG_REPO"
  echo "v1.3.0" > "$SG_PIPE/orch-801.release"
  local before; before=$(sg_present "$SG_PIPE/orch-801.release")
  sg_run "$RS_SG/orchestrate.sh" "$SG_REPO" 801
  local launch=$SG_OUT
  local after; after=$(sg_present "$SG_PIPE/orch-801.release")
  sg_cleanup
  assert_contains "$launch" "launched orchestrator" "AC9: relaunch took the launch path (scenario sanity)" || return 1
  assert_eq "$before:$after" "present:absent" "AC9: orch-<n>.release is gone after relaunch" || return 1
}

# =================================================================================================
# AC11 — docs
# =================================================================================================

sg_readme_section() { grep -E '^\*\*Status board' "$ROOT_SG/README.md" 2>/dev/null; }

# sg_check_docs <label> <text> — the #65 statements
sg_check_docs() {
  local label=$1 text=$2 w
  assert_ne "$text" "" "AC11: $label — text must be found (scoping sanity)" || return 1
  for w in DISPATCH_REPOS SCAN_ONLY_REPOS; do
    printf '%s' "$text" | grep -qF "$w" || { fail "AC11: $label must name $w (which repos are covered)"; return 1; }
  done
  printf '%s' "$text" | grep -qi 'released' || { fail "AC11: $label must describe the released-but-open rule ('released')"; return 1; }
  printf '%s' "$text" | grep -qi 'milestone' || { fail "AC11: $label must say the rule reads the issue's milestone"; return 1; }
  printf '%s' "$text" | grep -qiE 'running.{1,12}restarting.{1,12}queued.{1,12}held' \
    || { fail "AC11: $label must state the runs[] priority 'running, restarting, queued, held'"; return 1; }
}

test_sg_ac11_readme_status_board_describes_lists_and_rules() {
  local t; t=$(sg_readme_section)
  sg_check_docs "README.md Status board paragraph" "$t" || return 1
  printf '%s' "$t" | grep -qF 'status-staging.json' || { fail "AC11: README must name status-staging.json"; return 1; }
  printf '%s' "$t" | grep -qF 'status-approved.json' || { fail "AC11: README must name status-approved.json"; return 1; }
}

test_sg_ac11_status_page_readme_describes_lists_and_rules() {
  local t; t=$(cat "$ROOT_SG/status-page/README.md" 2>/dev/null)
  sg_check_docs "status-page/README.md" "$t" || return 1
  printf '%s' "$t" | grep -qF 'approved[]' || { fail "AC11: status-page/README.md must describe the payload's approved[] list"; return 1; }
  printf '%s' "$t" | grep -qF 'staging[]' || { fail "AC11: status-page/README.md must describe the payload's staging[] list"; return 1; }
}

run_test test_sg_ac1_queued_survive_cap_and_sort_before_held
run_test test_sg_ac1_priority_running_restarting_queued_held
run_test test_sg_ac2_reconcile_writes_both_lists_from_both_repos
run_test test_sg_ac2_exactly_two_list_calls_per_repo_with_the_specified_flags
run_test test_sg_ac2_repo_in_both_config_lists_is_queried_once
run_test test_sg_ac2_list_change_reports_once_and_no_change_does_not
run_test test_sg_ac3_payload_items_shape_order_and_alias
run_test test_sg_ac3_caps_60_staging_20_approved_newest_kept
run_test test_sg_ac3_cap_boundaries_60_and_20_are_not_cut
run_test test_sg_ac3_title_capped_at_140_chars
run_test test_sg_ac3_missing_or_invalid_files_give_empty_arrays
run_test test_sg_ac4_failed_list_call_keeps_that_repos_previous_entries
run_test test_sg_ac4_failed_call_with_no_previous_entries_leaves_other_repo_intact
run_test test_sg_ac5_non_running_rows_on_staging_list_are_left_out_running_stays
run_test test_sg_ac6_open_issue_with_release_milestone_becomes_done_with_release
run_test test_sg_ac6_open_release_queued_ticket_drops_its_queue_entry
run_test test_sg_ac6_closed_issue_with_release_milestone_carries_release
run_test test_sg_ac6_non_release_milestone_titles_do_nothing
run_test test_sg_ac6_null_milestone_leaves_open_ticket_alone
run_test test_sg_ac7_one_issue_view_per_ticket_with_milestone_field
run_test test_sg_ac7_throttle_covers_list_calls
run_test test_sg_ac8_print_makes_no_gh_call
run_test test_sg_ac9_relaunch_cleanup_line_lists_release
run_test test_sg_ac9_relaunch_removes_release_file
run_test test_sg_ac11_readme_status_board_describes_lists_and_rules
run_test test_sg_ac11_status_page_readme_describes_lists_and_rules
