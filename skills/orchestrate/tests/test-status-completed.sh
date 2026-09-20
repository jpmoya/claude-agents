# Issue #51 (host half) — closed tickets leave the active table and land in a Completed list; every
# listed ticket's status is refreshed from GitHub by a throttled reconcile pass.
#
#   AC1   reconcile-status.sh --force: a CLOSED ticket that is held / stopped / restarting / has a
#         queue entry leaves runs[] and appears in completed[] with closed_at = GitHub's closedAt
#   AC3   OPEN ticket: runs[].marker = latest real routing marker on GitHub (orch-<n>.marker)
#   AC4   throttle (600 s), exactly one `gh issue view` per in-scope ticket, 48 h scope, exit 0 and
#         silent when gh fails, supervisor calls it backgrounded and is never blocked by it
#   AC5   a reopened + relaunched ticket returns to runs[] (.closed / .marker cleared)
#   AC6   builder + reporter stay network-free (no gh call while building the payload)
#   AC8   payload v stays 1; `completed` is always present ([] when none)
#   AC9   `orchestrate.sh status` never reports a closed record as "exited (will auto-restart)"
#   AC12  docs: README.md Status board paragraph + status-page/README.md describe Completed
#   (AC2, AC7 — the Worker half — live in status-page/test/*.test.js; the rest of AC9 and AC10 are the
#    existing suites staying green; AC11 — the one-time reconcile on the VM — is a developer delivery
#    obligation, not something a test can perform.)
#
# Placeholder repo names only (public repo). Expected values are hand-written from the ticket.
# Bash 3.2 portable. Fake gh = tests/lib/fixture.sh mk_fake_gh (extended additively for closedAt,
# per-issue state/marker files and a failing `issue view`).

HERE_SC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RS_SC="$HERE_SC/.."
ROOT_SC=$(cd "$HERE_SC/../../.." && pwd)

SC_REPO_ALIAS="example-owner/project-a"

# ---- helpers ----------------------------------------------------------------------------------

sc_iso_ago() {  # sc_iso_ago <secs> -> ISO-8601Z timestamp <secs> in the past
  python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"
}

sc_touch_ago() {  # sc_touch_ago <file> <secs> — set mtime <secs> in the past
  python3 -c "import os,sys,time; t=int(time.time())-int(sys.argv[2]); os.utime(sys.argv[1], (t, t))" "$1" "$2" 2>/dev/null
}

# sc_env — SC_PIPE, SC_HOME, SC_REPO (origin = example-owner/project-a), SC_BIN (fake gh + fake curl)
sc_env() {
  SC_PIPE=$(new_pipe); SC_HOME=$(new_home)
  SC_REPO="$SC_PIPE/repo-project-a"
  fixture_repo "$SC_REPO" "$SC_REPO_ALIAS"
  SC_BIN="$SC_HOME/.local/bin"
  mk_fake_gh "$SC_BIN"
  echo "$SC_REPO_ALIAS" > "$SC_BIN/gh-name-with-owner"
  SC_ROOT=""
}

sc_cleanup() {
  local f pid
  for f in "$SC_PIPE"/orch-*.pid; do
    [ -e "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null)
    [ -n "$pid" ] && { pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  done
  cleanup_running
  rm -rf "$SC_PIPE" "$SC_HOME"
  [ -n "$SC_ROOT" ] && rm -rf "$SC_ROOT"
  return 0
}

sc_alias_config() {
  cat > "$SC_HOME/.claude/pipeline/config.local.sh" <<EOF
STATUS_REPO_ALIASES=("$SC_REPO_ALIAS:project-a")
EOF
}

sc_gh_closed() {  # sc_gh_closed <n> <closedAt-iso>
  echo "CLOSED" > "$SC_BIN/gh-issue-state-$1"
  echo "$2" > "$SC_BIN/gh-issue-closed-at-$1"
}

sc_gh_marker() {  # sc_gh_marker <n> <first line of the issue's only comment>
  printf '%s\n' "$2" > "$SC_BIN/gh-issue-latest-marker-$1"
}

sc_title() { printf 'Title of %s\n' "$1" > "$SC_PIPE/orch-$1.title"; }

# sc_run <script> [args] -> SC_OUT (stdout+stderr), SC_RC. The isolated env; fake gh wins on PATH.
sc_run() {
  local script=$1; shift
  SC_OUT=$(HOME="$SC_HOME" PATH="$SC_BIN:/usr/bin:/bin" PIPE="$SC_PIPE" QUEUE="$SC_PIPE/queue" LOGDIR="$SC_HOME/logs/pipeline" \
    "$script" "$@" 2>&1)
  SC_RC=$?
}
sc_reconcile() { sc_run "$RS_SC/reconcile-status.sh" "$@"; }
sc_print() {  # payload on stdout
  HOME="$SC_HOME" PATH="$SC_BIN:/usr/bin:/bin" PIPE="$SC_PIPE" QUEUE="$SC_PIPE/queue" LOGDIR="$SC_HOME/logs/pipeline" \
    "$RS_SC/report-status.sh" --print 2>/dev/null
}

sc_present() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
sc_gh_n() { gh_call_count "$SC_BIN" "issue view $1 "; }   # calls for one issue (trailing space: 21 != 210)

# jq helpers over the payload: VALUE, MISSING_FIELD, NORUN / NOITEM / NOCOMPLETED
sc_run_field() {  # sc_run_field <json> <issue> <field>
  printf '%s' "$1" | jq -r --arg n "$2" --arg f "$3" \
    '[.runs[] | select((.issue|tostring)==$n)] | if length==0 then "NORUN" else (.[0] | if has($f) then (.[$f]|tostring) else "MISSING_FIELD" end) end' 2>/dev/null || echo INVALID_JSON
}
sc_completed_field() {  # sc_completed_field <json> <index> <field>
  printf '%s' "$1" | jq -r --argjson i "$2" --arg f "$3" \
    'if (.completed|type)!="array" then "NOCOMPLETED" elif (.completed|length) <= $i then "NOITEM" else (.completed[$i] | if has($f) then (.[$f]|tostring) else "MISSING_FIELD" end) end' 2>/dev/null || echo INVALID_JSON
}
sc_completed_issues() { printf '%s' "$1" | jq -r 'if (.completed|type)=="array" then ([.completed[].issue|tostring]|join(" ")) else "NOCOMPLETED" end' 2>/dev/null || echo INVALID_JSON; }
sc_runs_issues()      { printf '%s' "$1" | jq -r '[.runs[].issue|tostring]|join(" ")' 2>/dev/null || echo INVALID_JSON; }

# sc_mk_closed_record <n> <secs-ago> — a finished ticket exactly as reconcile leaves it: dead pid,
# .repo, .title, .closed (first line = closedAt). No gh involved.
sc_mk_closed_record() {
  mk_dead_pid "$SC_PIPE" "$1"
  echo "$SC_REPO" > "$SC_PIPE/orch-$1.repo"
  date -u +%FT%TZ > "$SC_PIPE/orch-$1.start"
  : > "$SC_PIPE/orch-$1.log"
  touch "$SC_PIPE/orch-$1.done"
  sc_title "$1"
  sc_iso_ago "$2" > "$SC_PIPE/orch-$1.closed"
}

sc_derive_state() {  # sc_derive_state <issue> -> state_code from derive_runs()
  ( PIPE="$SC_PIPE" QUEUE="$SC_PIPE/queue" HOME="$SC_HOME" bash -c '. "'"$RS_SC"'/run-state.sh"; derive_runs' ) \
    | awk -F'\t' -v want="$1" '$1 == want { print $3; f=1 } END { if (!f) print "MISSING" }'
}

# sc_mirror — a copy of hooks/ + skills/orchestrate/ (siblings, like the real checkout) whose
# report-status.sh only records its calls, so "did reconcile ask for a push" is observable.
sc_mirror() {
  SC_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-root.XXXXXX")
  mkdir -p "$SC_ROOT/skills/orchestrate"
  cp -R "$ROOT_SC/hooks" "$SC_ROOT/hooks"
  cp "$RS_SC"/*.sh "$RS_SC"/*.py "$SC_ROOT/skills/orchestrate/"
  cat > "$SC_ROOT/skills/orchestrate/report-status.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SC_ROOT/report.calls"
EOF
  chmod +x "$SC_ROOT/skills/orchestrate/"*.sh
}

# sc_wait_lines <file> <min> — line count of <file> once the backgrounded writers have landed: poll
# (bounded, 5 s) until it has >= <min> lines, then until two reads 0.2 s apart agree, so a later
# unexpected extra line is still seen. No fixed sleep.
sc_wait_lines() {
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
sc_report_calls() { sc_wait_lines "$SC_ROOT/report.calls" "$1"; }   # sc_report_calls <min expected>

# =================================================================================================
# derive_runs: the new `closed` state code (Expected Behavior 3)
# =================================================================================================

test_sc_derive_dead_pid_with_closed_file_is_closed() {
  sc_env
  sc_mk_closed_record 301 3600
  local s; s=$(sc_derive_state 301)
  sc_cleanup
  assert_eq "$s" "closed" "EB3: dead pid + orch-<n>.closed -> state code closed" || return 1
}

test_sc_derive_closed_is_checked_before_stopped_held_done() {
  sc_env
  sc_mk_closed_record 302 3600
  touch "$SC_PIPE/orch-302.stopped" "$SC_PIPE/orch-302.held" "$SC_PIPE/orch-302.done"
  local s; s=$(sc_derive_state 302)
  sc_cleanup
  assert_eq "$s" "closed" "EB3: closed wins over stopped/held/done" || return 1
}

test_sc_derive_live_pid_with_closed_file_is_still_running() {
  sc_env
  mk_running "$SC_PIPE" 303 "$SC_REPO"
  sc_iso_ago 60 > "$SC_PIPE/orch-303.closed"
  sc_mk_closed_record 304 60                            # positive control: same files, dead pid -> closed
  local live dead
  live=$(sc_derive_state 303); dead=$(sc_derive_state 304)
  sc_cleanup
  assert_eq "$dead" "closed" "EB3: control — dead pid + .closed is closed" || return 1
  assert_eq "$live" "running" "EB3: a live pid still reads running (the orchestrator is finishing)" || return 1
}

# =================================================================================================
# AC1 — closed tickets leave runs[] and appear in completed[]
# =================================================================================================

test_sc_ac1_closed_held_ticket_moves_to_completed() {
  sc_env
  local closed_at; closed_at=$(sc_iso_ago 3600)
  mk_held "$SC_PIPE" 201 "$SC_REPO"; sc_title 201; touch "$SC_PIPE/orch-201.alert"
  sc_gh_closed 201 "$closed_at"
  local before; before=$(sc_print)                       # positive control: it IS in runs[] beforehand
  sc_reconcile --force
  local out; out=$(sc_print)
  local closed_first held alert done_f log
  closed_first=$(head -n1 "$SC_PIPE/orch-201.closed" 2>/dev/null)
  held=$(sc_present "$SC_PIPE/orch-201.held"); alert=$(sc_present "$SC_PIPE/orch-201.alert"); done_f=$(sc_present "$SC_PIPE/orch-201.done")
  log=$(cat "$SC_HOME/logs/pipeline/supervisor.log" 2>/dev/null)
  local rc=$SC_RC o=$SC_OUT
  local runs completed_issue c_closed c_title c_url
  runs=$(sc_runs_issues "$out"); completed_issue=$(sc_completed_field "$out" 0 issue)
  c_closed=$(sc_completed_field "$out" 0 closed_at); c_title=$(sc_completed_field "$out" 0 title); c_url=$(sc_completed_field "$out" 0 url)
  sc_cleanup
  assert_eq "$(sc_run_field "$before" 201 state)" "held" "AC1: control — #201 is a held run before the pass" || return 1
  assert_exit0 "$rc" "AC1: reconcile exits 0" || return 1
  assert_eq "$o" "" "AC1: a normal pass prints nothing" || return 1
  assert_eq "$closed_first" "$closed_at" "AC1: orch-201.closed first line = GitHub's closedAt" || return 1
  assert_eq "$held" "absent" "AC1: .held removed" || return 1
  assert_eq "$alert" "absent" "AC1: .alert removed" || return 1
  assert_eq "$done_f" "present" "AC1: .done touched" || return 1
  assert_contains "$log" "201" "AC1: a line about #201 is logged to supervisor.log" || return 1
  assert_eq "$runs" "" "AC1: #201 is no longer in runs[]" || return 1
  assert_eq "$completed_issue" "201" "AC1: completed[0].issue == 201" || return 1
  assert_eq "$c_closed" "$closed_at" "AC1: completed[0].closed_at == GitHub's closedAt" || return 1
  assert_eq "$c_title" "Title of 201" "AC1: completed[0].title" || return 1
  assert_eq "$c_url" "https://github.com/$SC_REPO_ALIAS/issues/201" "AC1: completed[0].url" || return 1
}

test_sc_ac1_closed_stopped_restarting_and_queue_entry_tickets_move_to_completed() {
  sc_env
  local closed_at; closed_at=$(sc_iso_ago 7200)
  mk_stopped "$SC_PIPE" 202 "$SC_REPO"; sc_title 202; sc_gh_closed 202 "$closed_at"
  mk_restarting "$SC_PIPE" 203 "$SC_REPO"; sc_title 203; sc_gh_closed 203 "$closed_at"
  mk_restarting "$SC_PIPE" 204 "$SC_REPO"; sc_title 204; sc_gh_closed 204 "$closed_at"
  python3 -c "
import json
json.dump({'issue': '204', 'repo': '$SC_REPO', 'extra': '', 'reason': 'auto-restart', 'queued_at': '2026-01-01T00:00:00Z', 'not_before': 0}, open('$SC_PIPE/queue/orch-204.json', 'w'))"
  local before; before=$(sc_print)
  sc_reconcile --force
  local out; out=$(sc_print)
  local n runs states="" queue stopped
  runs=$(sc_runs_issues "$out")
  queue=$(sc_present "$SC_PIPE/queue/orch-204.json"); stopped=$(sc_present "$SC_PIPE/orch-202.stopped")
  local completed; completed=$(sc_completed_issues "$out")
  local rc=$SC_RC
  local calls_202 calls_203 calls_204
  calls_202=$(sc_gh_n 202); calls_203=$(sc_gh_n 203); calls_204=$(sc_gh_n 204)
  sc_cleanup
  assert_eq "$(sc_run_field "$before" 203 state)" "restarting" "AC1: control — #203 is a restarting run before the pass" || return 1
  assert_exit0 "$rc" "AC1: reconcile exits 0" || return 1
  assert_eq "$runs" "" "AC1: none of #202/#203/#204 remain in runs[]" || return 1
  for n in 202 203 204; do
    case " $completed " in *" $n "*) ;; *) fail "AC1: #$n missing from completed[] (got: $completed)"; return 1 ;; esac
  done
  assert_eq "$queue" "absent" "AC1: the queue entry for closed #204 is removed" || return 1
  assert_eq "$stopped" "absent" "AC1: .stopped removed for #202" || return 1
  assert_eq "$calls_202:$calls_203:$calls_204" "1:1:1" "AC4: exactly one gh issue view per ticket" || return 1
}

test_sc_ac1_live_pid_closed_issue_stays_running_until_pid_dies() {
  sc_env
  local closed_at; closed_at=$(sc_iso_ago 600)
  mk_running "$SC_PIPE" 205 "$SC_REPO"; sc_title 205; sc_gh_closed 205 "$closed_at"
  local pid; pid=$(cat "$SC_PIPE/orch-205.pid")
  sc_reconcile --force
  local out1 closed_file; out1=$(sc_print); closed_file=$(sc_present "$SC_PIPE/orch-205.closed")
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  local out2; out2=$(sc_print)
  sc_cleanup
  assert_eq "$closed_file" "present" "AC1: .closed is written even though the pid is alive" || return 1
  assert_eq "$(sc_run_field "$out1" 205 state)" "running" "AC1: live pid -> still running in runs[]" || return 1
  assert_eq "$(sc_completed_issues "$out1")" "" "AC1: live pid -> not yet in completed[]" || return 1
  assert_eq "$(sc_run_field "$out2" 205 state)" "NORUN" "AC1: pid dead -> leaves runs[]" || return 1
  assert_eq "$(sc_completed_issues "$out2")" "205" "AC1: pid dead -> appears in completed[]" || return 1
}

test_sc_ac1_completed_carries_final_marker_from_github() {
  sc_env
  mk_held "$SC_PIPE" 206 "$SC_REPO"; sc_title 206
  sc_gh_closed 206 "$(sc_iso_ago 300)"; sc_gh_marker 206 '**[deployer] DEPLOYED**'
  mk_held "$SC_PIPE" 207 "$SC_REPO"; sc_title 207
  sc_gh_closed 207 "$(sc_iso_ago 600)"; sc_gh_marker 207 '**[supervisor] NOTE** nothing routable here'
  sc_reconcile --force
  local out; out=$(sc_print)
  local m206 m207 f206
  m206=$(sc_completed_field "$out" 0 marker)          # newest closed first: 206 (300 s ago)
  m207=$(sc_completed_field "$out" 1 marker)
  f206=$(cat "$SC_PIPE/orch-206.marker" 2>/dev/null)
  sc_cleanup
  assert_eq "$(sc_completed_field "$out" 0 issue)" "206" "EB4: newest closed first" || return 1
  assert_eq "$f206" "DEPLOYED" "EB1: orch-206.marker = marker name without the **[agent] prefix and trailing **" || return 1
  assert_eq "$m206" "DEPLOYED" "EB1/4: completed[].marker = the last routing marker" || return 1
  assert_eq "$(sc_completed_field "$out" 1 issue)" "207" "EB4: second entry is #207" || return 1
  assert_eq "$m207" "MISSING_FIELD" "EB4: NOTE-only comments -> no marker key on the completed item" || return 1
}

# =================================================================================================
# AC3 — OPEN tickets: marker from GitHub, state untouched
# =================================================================================================

test_sc_ac3_open_held_ticket_keeps_state_and_marker_comes_from_github() {
  sc_env
  mk_held "$SC_PIPE" 208 "$SC_REPO"; sc_title 208
  mkdir -p "$SC_HOME/.claude/pipeline"
  printf '{"event":"dispatch","repo":"%s","issue":208,"marker_after":"TESTS WRITTEN"}\n' "$SC_REPO_ALIAS" > "$SC_HOME/.claude/pipeline/runs.jsonl"
  local before; before=$(sc_print)
  sc_gh_marker 208 '**[test-reviewer] TESTS APPROVED**'
  sc_reconcile --force
  local out; out=$(sc_print)
  local mfile closed
  mfile=$(cat "$SC_PIPE/orch-208.marker" 2>/dev/null); closed=$(sc_present "$SC_PIPE/orch-208.closed")
  local rc=$SC_RC
  sc_cleanup
  assert_eq "$(sc_run_field "$before" 208 marker)" "TESTS WRITTEN" "AC3: control — runs.jsonl's (stale) value is what the page shows before the pass" || return 1
  assert_exit0 "$rc" "AC3: exit 0" || return 1
  assert_eq "$mfile" "TESTS APPROVED" "AC3: orch-208.marker = latest routing marker name" || return 1
  assert_eq "$(sc_run_field "$out" 208 marker)" "TESTS APPROVED" "AC3: runs[].marker = GitHub's marker, not runs.jsonl's" || return 1
  assert_eq "$(sc_run_field "$out" 208 state)" "held" "AC3: an OPEN held ticket stays held" || return 1
  assert_eq "$closed" "absent" "AC3: an OPEN ticket gets no .closed" || return 1
  assert_eq "$(sc_completed_issues "$out")" "" "AC3: an OPEN ticket is not in completed[]" || return 1
}

test_sc_ac3_latest_real_marker_wins_and_notes_are_inert() {
  sc_env
  mk_held "$SC_PIPE" 209 "$SC_REPO"; sc_title 209
  cat > "$SC_BIN/gh-issue-comments-json-209" <<'EOF'
[{"body":"**[product-manager] READY FOR ENGINEERING**\nspec","createdAt":"2026-01-01T00:00:00Z"},
 {"body":"**[test-writer] TESTS WRITTEN**\nbranch","createdAt":"2026-01-02T00:00:00Z"},
 {"body":"**[test-writer] NOTE** later, but inert","createdAt":"2026-01-03T00:00:00Z"}]
EOF
  sc_reconcile --force
  local mfile; mfile=$(cat "$SC_PIPE/orch-209.marker" 2>/dev/null)
  sc_cleanup
  assert_eq "$mfile" "TESTS WRITTEN" "EB1: newest REAL routing marker wins; a later NOTE is inert" || return 1
}

test_sc_ac3_no_routing_marker_removes_a_stale_marker_file() {
  sc_env
  mk_held "$SC_PIPE" 210 "$SC_REPO"; sc_title 210
  echo "TESTS WRITTEN" > "$SC_PIPE/orch-210.marker"           # stale from an earlier pass
  mk_held "$SC_PIPE" 211 "$SC_REPO"; sc_title 211               # control: has a marker -> file written
  sc_gh_marker 211 '**[product-manager] READY FOR ENGINEERING**'
  sc_gh_marker 210 '**[supervisor] NOTE** only a note here'
  sc_reconcile --force
  local f210 f211
  f210=$(sc_present "$SC_PIPE/orch-210.marker"); f211=$(cat "$SC_PIPE/orch-211.marker" 2>/dev/null)
  sc_cleanup
  assert_eq "$f211" "READY FOR ENGINEERING" "EB1: control — #211's marker file written" || return 1
  assert_eq "$f210" "absent" "EB1: none/empty marker -> orch-<n>.marker removed" || return 1
}

# =================================================================================================
# AC4 — throttle, scope, exactly one gh call per ticket, failure is silent
# =================================================================================================

test_sc_ac4_gh_failure_is_a_silent_noop_exit_0() {
  sc_env
  # positive control first: with a working gh the same fixture DOES change state
  mk_held "$SC_PIPE" 212 "$SC_REPO"; sc_title 212; sc_gh_closed 212 "$(sc_iso_ago 60)"
  sc_reconcile --force
  local ctl_closed; ctl_closed=$(sc_present "$SC_PIPE/orch-212.closed")
  # now the failing gh
  mk_held "$SC_PIPE" 213 "$SC_REPO"; sc_title 213; sc_gh_closed 213 "$(sc_iso_ago 60)"
  echo 1 > "$SC_BIN/gh-issue-view-rc"
  sc_reconcile --force
  local rc=$SC_RC o=$SC_OUT closed held state
  closed=$(sc_present "$SC_PIPE/orch-213.closed"); held=$(sc_present "$SC_PIPE/orch-213.held")
  state=$(sc_derive_state 213)
  sc_cleanup
  assert_eq "$ctl_closed" "present" "AC4: control — a working gh closes #212" || return 1
  assert_exit0 "$rc" "AC4: exit 0 when gh fails" || return 1
  assert_eq "$o" "" "AC4: no output when gh fails" || return 1
  assert_eq "$closed" "absent" "AC4: gh failure writes no .closed" || return 1
  assert_eq "$held" "present" "AC4: gh failure leaves .held alone" || return 1
  assert_eq "$state" "held" "AC4: state unchanged" || return 1
}

test_sc_ac4_throttle_one_pass_per_600_seconds_force_bypasses() {
  sc_env
  mk_held "$SC_PIPE" 214 "$SC_REPO"; sc_title 214
  local stamp="$SC_PIPE/status-reconcile.stamp" c1 c2 c3 c4 c5 has_stamp
  sc_reconcile                                            # no stamp yet: runs at first tick after deploy
  c1=$(sc_gh_n 214); has_stamp=$(sc_present "$stamp")
  sc_reconcile                                            # within 600 s: zero gh calls
  c2=$(sc_gh_n 214)
  sc_reconcile --force                                    # bypasses
  c3=$(sc_gh_n 214)
  sc_touch_ago "$stamp" 590; sc_reconcile                 # 590 s old: still throttled
  c4=$(sc_gh_n 214)
  sc_touch_ago "$stamp" 601; sc_reconcile                 # 601 s old: allowed
  c5=$(sc_gh_n 214)
  local rc=$SC_RC
  sc_cleanup
  assert_eq "$c1" "1" "AC4: first pass (no stamp) makes exactly one gh call" || return 1
  assert_eq "$has_stamp" "present" "AC4: stamp \$PIPE/status-reconcile.stamp written when a pass starts" || return 1
  assert_eq "$c2" "1" "AC4: second non-force call within 600 s makes zero gh calls" || return 1
  assert_eq "$c3" "2" "AC4: --force bypasses the throttle" || return 1
  assert_eq "$c4" "2" "AC4: stamp 590 s old -> still throttled" || return 1
  assert_eq "$c5" "3" "AC4: stamp 601 s old -> a pass runs" || return 1
  assert_exit0 "$rc" "AC4: exit 0 on a throttled/complete call" || return 1
}

test_sc_ac4_scope_is_open_states_plus_finished_within_48h_and_skips_already_closed() {
  sc_env
  mk_done "$SC_PIPE" 215 "$SC_REPO"; sc_title 215; sc_touch_ago "$SC_PIPE/orch-215.log" $((72*3600))   # 3 days: out
  mk_done "$SC_PIPE" 216 "$SC_REPO"; sc_title 216; sc_touch_ago "$SC_PIPE/orch-216.log" $((47*3600))   # 47 h: in
  mk_stopped "$SC_PIPE" 217 "$SC_REPO"; sc_title 217; sc_touch_ago "$SC_PIPE/orch-217.log" $((49*3600)) # 49 h: out
  mk_held "$SC_PIPE" 218 "$SC_REPO"; sc_title 218; sc_touch_ago "$SC_PIPE/orch-218.log" $((100*3600))   # held: always in
  sc_mk_closed_record 219 3600                                                                          # already closed: out
  sc_reconcile --force
  local c215 c216 c217 c218 c219 rc=$SC_RC
  c215=$(sc_gh_n 215); c216=$(sc_gh_n 216); c217=$(sc_gh_n 217); c218=$(sc_gh_n 218); c219=$(sc_gh_n 219)
  sc_cleanup
  assert_exit0 "$rc" "AC4: exit 0" || return 1
  assert_eq "$c216" "1" "AC4: done record 47 h old is in scope (control)" || return 1
  assert_eq "$c218" "1" "AC4: held record is always in scope (control)" || return 1
  assert_eq "$c215" "0" "AC4: done record 3 days old -> zero gh calls" || return 1
  assert_eq "$c217" "0" "AC4: stopped record 49 h old -> zero gh calls" || return 1
  assert_eq "$c219" "0" "AC4: a record that already has .closed -> zero gh calls" || return 1
}

test_sc_ac4_one_gh_issue_view_per_ticket_with_state_closedat_comments() {
  sc_env
  local n
  for n in 221 222 223; do mk_held "$SC_PIPE" $n "$SC_REPO"; sc_title $n; done
  sc_reconcile --force
  local total calls
  total=$(gh_call_count "$SC_BIN" ""); calls=$(gh_calls "$SC_BIN")
  sc_cleanup
  assert_eq "$total" "3" "AC4: exactly three gh calls for three in-scope tickets" || return 1
  assert_contains "$calls" "issue view 221 " "AC4: #221 fetched via gh issue view" || return 1
  assert_contains "$calls" "closedAt" "AC4: the fetch asks for closedAt" || return 1
  assert_contains "$calls" "state" "AC4: the fetch asks for state" || return 1
  assert_contains "$calls" "comments" "AC4: the fetch asks for comments" || return 1
}

test_sc_ac4_reconcile_asks_for_one_push_and_only_when_something_changed() {
  sc_env; sc_mirror
  # 2 closing tickets + 1 open with a new marker in one pass -> exactly ONE report call at the end
  mk_held "$SC_PIPE" 224 "$SC_REPO"; sc_title 224; sc_gh_closed 224 "$(sc_iso_ago 60)"
  mk_held "$SC_PIPE" 225 "$SC_REPO"; sc_title 225; sc_gh_closed 225 "$(sc_iso_ago 120)"
  mk_held "$SC_PIPE" 226 "$SC_REPO"; sc_title 226; sc_gh_marker 226 '**[product-manager] READY FOR ENGINEERING**'
  sc_run "$SC_ROOT/skills/orchestrate/reconcile-status.sh" --force
  local first; first=$(sc_report_calls 1)
  local rc1=$SC_RC
  # nothing changes on the next pass (same closed files, same marker) -> no further report
  sc_run "$SC_ROOT/skills/orchestrate/reconcile-status.sh" --force
  local second; second=$(sc_report_calls 1)
  # the marker changes -> one more report
  sc_gh_marker 226 '**[solutions-architect] SPEC RESOLVED**'
  sc_run "$SC_ROOT/skills/orchestrate/reconcile-status.sh" --force
  local third; third=$(sc_report_calls 2)
  local mfile; mfile=$(cat "$SC_PIPE/orch-226.marker" 2>/dev/null)
  sc_cleanup
  assert_exit0 "$rc1" "AC4: exit 0" || return 1
  assert_eq "$first" "1" "EB1: one report_status_async for the whole pass" || return 1
  assert_eq "$second" "1" "EB1: unchanged second pass -> no extra report" || return 1
  assert_eq "$mfile" "SPEC RESOLVED" "EB1: changed marker is written" || return 1
  assert_eq "$third" "2" "EB1: a changed marker triggers a report" || return 1
}

# ---- supervisor hook -----------------------------------------------------------------------

sc_tick_mirror() {  # one supervisor tick from the mirror; prints elapsed seconds; sets SC_RC
  local t0 t1
  t0=$(date +%s)
  HOME="$SC_HOME" PATH="$SC_BIN:/usr/bin:/bin" PIPE="$SC_PIPE" QUEUE="$SC_PIPE/queue" LOGDIR="$SC_HOME/logs/pipeline" \
    SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" "$SC_ROOT/skills/orchestrate/supervisor.sh" >/dev/null 2>&1
  SC_RC=$?
  t1=$(date +%s)
  echo $((t1 - t0))
}

test_sc_ac4_supervisor_tick_calls_reconcile_once_and_is_not_delayed_by_it() {
  sc_env; sc_mirror
  cat > "$SC_ROOT/skills/orchestrate/reconcile-status.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$SC_ROOT/reconcile.calls"
sleep 8
exit 1
EOF
  chmod +x "$SC_ROOT/skills/orchestrate/reconcile-status.sh"
  local elapsed calls
  elapsed=$(sc_tick_mirror)
  calls=$(sc_wait_lines "$SC_ROOT/reconcile.calls" 1)
  local rc=$SC_RC
  sc_cleanup
  assert_eq "${calls:-0}" "1" "EB2: supervisor.sh calls reconcile-status.sh exactly once per tick" || return 1
  assert_exit0 "$rc" "EB2: a failing reconcile never fails the tick" || return 1
  assert_lt "$elapsed" 5 "EB2: a slow (8 s) reconcile does not delay the tick — it is backgrounded" || return 1
}

test_sc_ac4_supervisor_reconcile_call_is_backgrounded_fd9_closed_after_dispatch_step() {
  local line ln_call ln_dispatch ln_exit
  ln_call=$(grep -n 'reconcile-status\.sh' "$RS_SC/supervisor.sh" | grep -v '^[0-9]*:[[:space:]]*#' | head -n1)
  assert_ne "$ln_call" "" "EB2: supervisor.sh invokes reconcile-status.sh" || return 1
  line=${ln_call#*:}; ln_call=${ln_call%%:*}
  case "$line" in *"&"*) ;; *) fail "EB2: the reconcile call must be backgrounded (&): $line"; return 1 ;; esac
  case "$line" in *"9>&-"*) ;; *) fail "EB2: the reconcile call must close fd 9 (9>&-) like report_status_async: $line"; return 1 ;; esac
  ln_dispatch=$(grep -n 'DISPATCH_REPOS\[@\]' "$RS_SC/supervisor.sh" | tail -n1 | cut -d: -f1)
  ln_exit=$(grep -n '^exec 9>&-' "$RS_SC/supervisor.sh" | tail -n1 | cut -d: -f1)
  assert_ne "$ln_dispatch" "" "EB2: dispatch step found (scenario sanity)" || return 1
  [ "$ln_call" -gt "$ln_dispatch" ] || { fail "EB2: reconcile must be called after step 5 (shared dispatch), not inside the launch path earlier"; return 1; }
  [ "$ln_call" -lt "$ln_exit" ] || { fail "EB2: reconcile must be called before the closing 'exec 9>&-'"; return 1; }
}

# =================================================================================================
# AC9 — `orchestrate.sh status` keeps printing sensible, non-restarting states for a closed record
# =================================================================================================

# The `closed` code is new; orchestrate.sh status must not fall into its "exited (will auto-restart)"
# branch for it. When gh does not say CLOSED (here: OPEN, e.g. the record is momentarily ahead of or
# behind GitHub), a finished record reads exactly as the old `done` did ("done"); when gh says CLOSED,
# the existing override applies ("done (issue closed)"). (A gh that exits non-zero aborts `status`
# under its `set -e` today; that is existing behaviour and out of scope here.)
test_sc_ac9_orchestrate_status_closed_record_is_not_reported_as_restarting() {
  sc_env
  sc_mk_closed_record 401 3600                                  # .closed + .done (as reconcile leaves it), gh says OPEN
  sc_mk_closed_record 402 3600; rm -f "$SC_PIPE/orch-402.done"  # .closed alone, gh says OPEN
  sc_mk_closed_record 403 3600; sc_gh_closed 403 "$(sc_iso_ago 3600)"   # gh works and says CLOSED
  sc_gh_marker 403 '**[deployer] DEPLOYED**'                   # (the fake gh only returns comments when it has some)
  mk_restarting "$SC_PIPE" 404 "$SC_REPO"                       # control: a genuinely restarting record still says so
  sc_run "$RS_SC/orchestrate.sh" status
  local out=$SC_OUT rc=$SC_RC l401 l402 l403 l404
  l401=$(printf '%s\n' "$out" | grep '^#401 '); l402=$(printf '%s\n' "$out" | grep '^#402 ')
  l403=$(printf '%s\n' "$out" | grep '^#403 '); l404=$(printf '%s\n' "$out" | grep '^#404 ')
  sc_cleanup
  assert_exit0 "$rc" "AC9: status exits 0" || return 1
  assert_contains "$l404" "#404  exited (will auto-restart)  repo=" "AC9: control — a real restarting record keeps the restart wording" || return 1
  assert_contains "$l401" "#401  done  repo=" "AC9: closed + done, gh says OPEN -> done" || return 1
  assert_contains "$l402" "#402  done  repo=" "AC9: closed alone, gh says OPEN -> done" || return 1
  assert_contains "$l403" "#403  done (issue closed)  repo=" "AC9: closed, gh says CLOSED -> done (issue closed)" || return 1
  case "$l401$l402$l403" in *"auto-restart"*) fail "AC9: a closed record must never read as 'will auto-restart'"; return 1 ;; esac
}

# =================================================================================================
# AC5 — reopen + relaunch returns the ticket to the active table
# =================================================================================================

test_sc_ac5_orchestrate_relaunch_clears_closed_and_marker_and_ticket_returns_to_runs() {
  sc_env
  echo 'MEM_FLOOR_MB=0' > "$SC_HOME/.claude/pipeline/config.local.sh"
  printf '#!/bin/bash\nexec sleep 30\n' > "$SC_BIN/claude"; chmod +x "$SC_BIN/claude"
  mk_held "$SC_PIPE" 301 "$SC_REPO"; sc_title 301
  sc_gh_closed 301 "$(sc_iso_ago 600)"; sc_gh_marker 301 '**[deployer] DEPLOYED**'
  sc_reconcile --force
  local out1; out1=$(sc_print)
  local closed_before marker_before
  closed_before=$(sc_present "$SC_PIPE/orch-301.closed"); marker_before=$(sc_present "$SC_PIPE/orch-301.marker")
  # JP reopens it and relaunches
  rm -f "$SC_BIN/gh-issue-state-301" "$SC_BIN/gh-issue-closed-at-301"
  sc_run "$RS_SC/orchestrate.sh" "$SC_REPO" 301
  local launch_out=$SC_OUT
  local out2; out2=$(sc_print)
  local closed_after marker_after
  closed_after=$(sc_present "$SC_PIPE/orch-301.closed"); marker_after=$(sc_present "$SC_PIPE/orch-301.marker")
  sc_cleanup
  assert_eq "$closed_before:$marker_before" "present:present" "AC5: control — reconcile wrote .closed and .marker" || return 1
  assert_eq "$(sc_completed_issues "$out1")" "301" "AC5: control — the closed ticket was in completed[]" || return 1
  assert_contains "$launch_out" "launched orchestrator" "AC5: relaunch took the launch path (scenario sanity)" || return 1
  assert_eq "$closed_after" "absent" "AC5: orchestrate.sh clears orch-<n>.closed on launch" || return 1
  assert_eq "$marker_after" "absent" "AC5: orchestrate.sh clears orch-<n>.marker on launch" || return 1
  assert_ne "$(sc_run_field "$out2" 301 state)" "NORUN" "AC5: the relaunched ticket is back in runs[]" || return 1
  assert_eq "$(sc_completed_issues "$out2")" "" "AC5: ...and absent from completed[]" || return 1
}

test_sc_ac5_supervisor_redispatch_rm_list_also_clears_closed_and_marker() {
  local line
  line=$(grep -n 'rm -f "\$PIPE/orch-\$num"' "$RS_SC/supervisor.sh" | grep 'label-cleared' | head -n1)
  assert_ne "$line" "" "AC5: the re-dispatch tombstone rm -f line exists in supervisor.sh (scenario sanity)" || return 1
  assert_contains "$line" "closed" "AC5: supervisor re-dispatch rm -f list includes closed" || return 1
  assert_contains "$line" "marker" "AC5: supervisor re-dispatch rm -f list includes marker" || return 1
}

# =================================================================================================
# Payload: completed key, retention / order / cap, no network (EB4, EB5, AC6, AC8)
# =================================================================================================

test_sc_eb5_payload_always_has_completed_array_and_v_stays_1() {
  sc_env
  mk_running "$SC_PIPE" 401 "$SC_REPO"                 # no closed records at all
  local out; out=$(sc_print)
  cleanup_running
  local v type len
  v=$(printf '%s' "$out" | jq -r '.v' 2>/dev/null)
  type=$(printf '%s' "$out" | jq -r '.completed|type' 2>/dev/null)
  len=$(printf '%s' "$out" | jq -r '.completed|length' 2>/dev/null)
  sc_cleanup
  assert_eq "$v" "1" "AC8: payload v stays 1" || return 1
  assert_eq "$type" "array" "EB5: completed key is always present" || return 1
  assert_eq "$len" "0" "EB5: [] when there are none" || return 1
}

test_sc_eb4_retention_order_and_cap_of_ten() {
  sc_env
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11; do sc_mk_closed_record $((500 + i)) $((i * 3600)); done   # 1 h .. 11 h ago
  sc_mk_closed_record 512 $((8 * 86400))                                                        # 8 days: out
  local out; out=$(sc_print)
  local issues n gh_n
  issues=$(sc_completed_issues "$out"); gh_n=$(gh_call_count "$SC_BIN" "")
  sc_cleanup
  # newest first (501 = 1 h ago ... 510 = 10 h ago); 511 dropped by the cap of 10, 512 by the 7-day retention
  assert_eq "$issues" "501 502 503 504 505 506 507 508 509 510" "EB4: 10 newest, closed_at descending, 8-day-old entry absent" || return 1
  assert_eq "$gh_n" "0" "AC6: building the payload makes no gh call" || return 1
}

test_sc_eb4_seven_day_boundary_6d23h_shown_7d1h_hidden() {
  sc_env
  sc_mk_closed_record 521 $((6 * 86400 + 23 * 3600))
  sc_mk_closed_record 522 $((7 * 86400 + 3600))
  local out; out=$(sc_print)
  local issues; issues=$(sc_completed_issues "$out")
  sc_cleanup
  assert_eq "$issues" "521" "EB4: closed 6d23h ago is shown, 7d1h ago is not" || return 1
}

test_sc_eb4_completed_item_shape_only_allowed_keys_and_repo_alias() {
  sc_env; sc_alias_config
  sc_mk_closed_record 531 3600
  sc_mk_closed_record 532 7200; rm -f "$SC_PIPE/orch-532.title"        # no title -> neither title nor url
  local out; out=$(sc_print)
  local extra stripped
  extra=$(printf '%s' "$out" | jq -r '[.completed[]|keys[]] | unique - ["repo","issue","title","url","closed_at","marker"] | join(",")' 2>/dev/null)
  stripped=$(printf '%s' "$out" | jq -c '.completed |= map(del(.url)) | .runs |= map(del(.url))' 2>/dev/null)
  sc_cleanup
  assert_eq "$(sc_completed_field "$out" 0 issue)" "531" "EB4: completed[0] is #531 (scenario sanity)" || return 1
  assert_eq "$extra" "" "EB4: completed items carry only repo/issue/title/url/closed_at/marker" || return 1
  assert_eq "$(sc_completed_field "$out" 0 repo)" "project-a" "EB4: repo is the alias, not owner/repo" || return 1
  assert_eq "$(sc_completed_field "$out" 0 url)" "https://github.com/$SC_REPO_ALIAS/issues/531" "EB4: url present when a title is known" || return 1
  assert_eq "$(sc_completed_field "$out" 1 title)" "MISSING_FIELD" "EB4: no title file -> no title key" || return 1
  assert_eq "$(sc_completed_field "$out" 1 url)" "MISSING_FIELD" "EB4: no title file -> no url key" || return 1
  assert_not_contains "$stripped" "$SC_REPO_ALIAS" "AC10: owner/repo appears in the payload only inside url values" || return 1
}

test_sc_ac6_reporter_and_builder_contain_no_network_call_for_completed() {
  local hits curl_code
  assert_contains "$(cat "$RS_SC/build-runs-json.py")" "completed" "AC6: builder implements the completed mode (positive half)" || return 1
  hits=$(grep -n "gh \|curl " "$RS_SC/build-runs-json.py" || true)
  assert_eq "$hits" "" "AC6: build-runs-json.py contains no 'gh ' / 'curl '" || return 1
  curl_code=$(sed 's/#.*$//' "$RS_SC/report-status.sh" | grep -cE '(^|[^[:alnum:]_])curl[[:space:]]' | tr -d ' ')
  assert_eq "$curl_code" "1" "AC6: report-status.sh's only curl is the push" || return 1
  hits=$(sed 's/#.*$//' "$RS_SC/report-status.sh" | grep -cE '(^|[^[:alnum:]_])gh[[:space:]]' | tr -d ' ')
  assert_eq "$hits" "0" "AC6: report-status.sh makes no gh call" || return 1
}

# The budget arithmetic in test-ac12-write-budget.sh stays valid only while the constants do; and
# the payload hash must now cover `completed` (a closure must trigger a beat — the ticket's
# "+~30 writes/day/host" estimate assumes it).
test_sc_budget_constants_unchanged_and_a_closure_changes_the_payload_hash() {
  local f="$RS_SC/report-status.sh" c1 c2
  assert_eq "$(grep -c '^MIN_PUSH_INTERVAL_SECS=10$' "$f")" "1" "budget: MIN_PUSH_INTERVAL_SECS still 10" || return 1
  assert_eq "$(grep -c '^KEEPALIVE_SECS=600$' "$f")" "1" "budget: KEEPALIVE_SECS still 600" || return 1
  assert_eq "$(grep -c '^MAX_PUSHES_PER_DAY=400$' "$f")" "1" "budget: MAX_PUSHES_PER_DAY still 400" || return 1

  sc_env
  cat > "$SC_HOME/.claude/pipeline/config.local.sh" <<'EOF'
STATUS_PUSH_URL="https://example.invalid/beat"
STATUS_PUSH_TOKEN="fake-token-for-test-only"
EOF
  printf '#!/bin/bash\necho 1 >> "$(dirname "$0")/curl.calls"\nprintf 204\nexit 0\n' > "$SC_BIN/curl"; chmod +x "$SC_BIN/curl"   # curl stub prints the -w http code, so the beat counts as pushed
  mk_running "$SC_PIPE" 601 "$SC_REPO"
  sc_run "$RS_SC/report-status.sh" event
  c1=$(cat "$SC_BIN/curl.calls" 2>/dev/null | wc -l | tr -d ' ')
  # move the 10 s coalescing window past, keep the 600 s keep-alive fresh, then add ONLY a closed record
  python3 -c "
import json, time
p = '$SC_PIPE/status-push.state'
d = json.load(open(p)); d['last_attempt_epoch'] = int(time.time()) - 60; d['last_push_epoch'] = int(time.time()) - 60
json.dump(d, open(p, 'w'))"
  sc_mk_closed_record 602 3600
  sc_run "$RS_SC/report-status.sh" event
  c2=$(cat "$SC_BIN/curl.calls" 2>/dev/null | wc -l | tr -d ' ')
  sc_cleanup
  assert_eq "$c1" "1" "budget: control — the first beat pushes" || return 1
  assert_eq "$c2" "2" "budget: adding a closed ticket changes the hash -> a second beat is pushed" || return 1
}

# =================================================================================================
# AC12 — docs
# =================================================================================================

test_sc_ac12_docs_describe_completed_retention_reconcile_and_throttle() {
  local readme para sp section
  readme="$ROOT_SC/README.md"
  para=$(grep -A0 '^\*\*Status board' "$readme")
  assert_ne "$para" "" "AC12: README Status board paragraph found (scenario sanity)" || return 1
  assert_contains "$para" "Completed" "AC12: README Status board paragraph mentions the Completed table" || return 1
  assert_contains "$para" "reconcile" "AC12: README Status board paragraph names the reconcile pass" || return 1
  assert_contains "$para" "600" "AC12: README states the 600 s throttle" || return 1
  case "$para" in *"7 day"*|*"7-day"*) ;; *) fail "AC12: README states the 7-day retention"; return 1 ;; esac
  case "$para" in *"10 per host"*|*"10 newest"*|*"10 most recent"*|*"ten per host"*) ;; *) fail "AC12: README states the 10-per-host cap ('10 per host' / '10 newest')"; return 1 ;; esac

  sp="$ROOT_SC/status-page/README.md"
  section=$(awk '/^## What is published/{on=1; next} /^## /{on=0} on{print}' "$sp")
  assert_contains "$section" "Completed" "AC12: status-page README 'What is published' mentions Completed" || return 1
  assert_contains "$section" "reconcile" "AC12: status-page README names the reconcile pass" || return 1
  assert_contains "$section" "600" "AC12: status-page README states the 600 s throttle" || return 1
  case "$section" in *"7 day"*|*"7-day"*) ;; *) fail "AC12: status-page README states the 7-day retention"; return 1 ;; esac
  assert_contains "$section" "Final marker" "AC12: status-page README lists the Completed columns" || return 1
}

run_test test_sc_derive_dead_pid_with_closed_file_is_closed
run_test test_sc_derive_closed_is_checked_before_stopped_held_done
run_test test_sc_derive_live_pid_with_closed_file_is_still_running
run_test test_sc_ac1_closed_held_ticket_moves_to_completed
run_test test_sc_ac1_closed_stopped_restarting_and_queue_entry_tickets_move_to_completed
run_test test_sc_ac1_live_pid_closed_issue_stays_running_until_pid_dies
run_test test_sc_ac1_completed_carries_final_marker_from_github
run_test test_sc_ac3_open_held_ticket_keeps_state_and_marker_comes_from_github
run_test test_sc_ac3_latest_real_marker_wins_and_notes_are_inert
run_test test_sc_ac3_no_routing_marker_removes_a_stale_marker_file
run_test test_sc_ac4_gh_failure_is_a_silent_noop_exit_0
run_test test_sc_ac4_throttle_one_pass_per_600_seconds_force_bypasses
run_test test_sc_ac4_scope_is_open_states_plus_finished_within_48h_and_skips_already_closed
run_test test_sc_ac4_one_gh_issue_view_per_ticket_with_state_closedat_comments
run_test test_sc_ac4_reconcile_asks_for_one_push_and_only_when_something_changed
run_test test_sc_ac4_supervisor_tick_calls_reconcile_once_and_is_not_delayed_by_it
run_test test_sc_ac4_supervisor_reconcile_call_is_backgrounded_fd9_closed_after_dispatch_step
run_test test_sc_ac9_orchestrate_status_closed_record_is_not_reported_as_restarting
run_test test_sc_ac5_orchestrate_relaunch_clears_closed_and_marker_and_ticket_returns_to_runs
run_test test_sc_ac5_supervisor_redispatch_rm_list_also_clears_closed_and_marker
run_test test_sc_eb5_payload_always_has_completed_array_and_v_stays_1
run_test test_sc_eb4_retention_order_and_cap_of_ten
run_test test_sc_eb4_seven_day_boundary_6d23h_shown_7d1h_hidden
run_test test_sc_eb4_completed_item_shape_only_allowed_keys_and_repo_alias
run_test test_sc_ac6_reporter_and_builder_contain_no_network_call_for_completed
run_test test_sc_budget_constants_unchanged_and_a_closure_changes_the_payload_hash
run_test test_sc_ac12_docs_describe_completed_retention_reconcile_and_throttle
