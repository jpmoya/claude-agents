# #637 — supervisor.sh / goal-lib.sh re-read every in-scope ticket's issue + comments on every 2-min tick, whether
# or not it changed: the 60s read cache was shorter than the 120s tick AND supervisor.sh wiped it at the start of
# every tick, so no tick ever reused a previous tick's reads. Cost scaled with tickets x ticks (measured ~100
# REST calls/min at full tier, over the 5000/hr budget).
#
# Fix: gh_since_sync <owner/repo> (gh-budget.sh) makes one `issues?state=all&since=<last>` list call per repo,
# invalidates only the issues/<n> and issues/<n>/comments cache entries it reports changed, and the cache for
# everything else now has no wall-clock TTL (trusted until explicitly invalidated) instead of the old 60s expiry.
# supervisor.sh calls it once per repo in `sw_repo_list` instead of the old blanket `gh_cache_clear` every tick.
#
#   AC1  si_ac1_*  a cold sync (never-seen repo) makes no GitHub call and does not spare a repo's stale cache
#   AC2  si_ac2_*  tick1 reads are real; tick2 (nothing changed) reuses them — 0 per-ticket calls, 1 list call
#   AC2  si_ac2b_* the no-TTL rule holds even once a short TTL would otherwise have expired it
#   AC2  si_ac2_unsynced_*/si_ac2_placeholder_* the no-TTL exemption is scoped to THIS PROCESS having synced THAT
#        repo string — a process that never calls gh_since_sync, or the literal `{owner}/{repo}` placeholder, still
#        obeys the ordinary TTL (deliver.sh, a goal repo outside sw_repo_list, a slug mismatch never get stale-as-fresh)
#   AC3  si_ac3_*  a ticket the since= list reports changed is the only one re-read on the next tick
#   AC4  si_ac4_*  a failed since= list falls back to a full re-read and never advances the stored timestamp
#   AC5  si_ac5_*  static: supervisor.sh no longer wipes the whole cache every tick; it syncs sw_repo_list instead
#   si_scopelist_*  a repo's `issues?...` scope list (milestone=/labels=) also survives an unchanged tick, and is
#        invalidated (not just the changed issue) when something in the repo did change — membership may have moved
#   AC6  si_ac6_*  docs: orchestrator.md wait loop, deployer.md Checks gate, CLAUDE.md line 57
# Prefix si_ / SI_. Placeholder repo name only.

HERE_SI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_SI=$(cd "$HERE_SI/../../.." && pwd)
GB_SI="$HERE_SI/../gh-budget.sh"
SUP_SI="$HERE_SI/../supervisor.sh"

si_setup() {
  SI_DIR=$(mktemp -d "${TMPDIR:-/tmp}/orch-test-si.XXXXXX")
  mkdir -p "$SI_DIR/bin" "$SI_DIR/pipe"
  : > "$SI_DIR/calls.log"
  echo '[]' > "$SI_DIR/since-resp.json"
  echo '[{"id":1,"body":"c1"}]' > "$SI_DIR/comments-1.json"
  echo '[{"id":2,"body":"c2"}]' > "$SI_DIR/comments-2.json"
  cat > "$SI_DIR/bin/gh" <<EOF
#!/bin/bash
D="$SI_DIR"
printf '%s\n' "\$*" >> "\$D/calls.log"
if [ "\$1 \$2" = "api rate_limit" ]; then printf '5000\t9999999999\t5000\t9999999999\n'; exit 0; fi
case "\$*" in
  *"issues?state=all"*"since="*)
    [ -e "\$D/since-fail" ] && { echo "HTTP 500" >&2; exit 1; }
    cat "\$D/since-resp.json"; exit 0 ;;
  *"issues/1/comments"*) cat "\$D/comments-1.json"; exit 0 ;;
  *"issues/2/comments"*) cat "\$D/comments-2.json"; exit 0 ;;
  *"issues/1") echo '{"number":1,"state":"open"}'; exit 0 ;;
  *"issues/2") echo '{"number":2,"state":"open"}'; exit 0 ;;
  *"{owner}/{repo}/issues/1/comments"*) echo '[{"id":99,"body":"ph"}]'; exit 0 ;;
  *"issues?milestone=12"*) cat "\$D/list-milestone.json" 2>/dev/null || echo '[]'; exit 0 ;;
  *) echo "fake gh: unexpected \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$SI_DIR/bin/gh"
}
si_teardown() { rm -rf "$SI_DIR"; }

# si_run <bash text> — one "tick" worth of work: gh-budget.sh sourced fresh in a new bash process (mimics a new
# supervisor.sh run each tick), PIPE kept on disk across calls so the cache/sync state persists like it really does.
si_run() {
  PATH="$SI_DIR/bin:$PATH" PIPE="$SI_DIR/pipe" LOGDIR="$SI_DIR/log" GH_BUDGET_ENABLED=1 \
    GH_CACHE_TTL_SECS="${SI_TTL:-60}" GH_QUOTA_TTL_SECS=3600 \
    bash -c ". '$GB_SI'; $1"
}
si_calls() { grep -c . "$SI_DIR/calls.log" 2>/dev/null; }
si_reads() { grep -cF "issues/$1/comments" "$SI_DIR/calls.log" 2>/dev/null; }
si_since_file() { ls "$SI_DIR"/pipe/gh-cache/.since.* 2>/dev/null | head -1; }

si_read_both() { si_run 'gh api "repos/proj/repo-a/issues/1/comments?per_page=100" --paginate >/dev/null; gh api "repos/proj/repo-a/issues/2/comments?per_page=100" --paginate >/dev/null'; }

test_si_ac1_cold_sync_makes_no_call() {
  si_setup
  si_run 'gh_since_sync proj/repo-a' >/dev/null; local rc=$?
  assert_eq "$rc" "0" "cold sync exits 0" && assert_eq "$(si_calls)" "0" "AC1: a never-seen repo costs no GitHub call" || { si_teardown; return 1; }
  si_teardown
}

test_si_ac1_cold_sync_invalidates_leftover_cache() {
  si_setup
  si_read_both >/dev/null   # pre-existing (e.g. pre-#637) cache, never synced
  : > "$SI_DIR/calls.log"
  si_run 'gh_since_sync proj/repo-a; gh api "repos/proj/repo-a/issues/1/comments?per_page=100" --paginate >/dev/null'
  assert_eq "$(si_reads 1)" "1" "AC1: a cold sync never trusts cache that predates it as fresh" || { si_teardown; return 1; }
  si_teardown
}

test_si_ac2_unchanged_tick_reuses_previous_reads() {
  si_setup
  si_run 'gh_since_sync proj/repo-a' >/dev/null   # baseline
  si_read_both >/dev/null                          # tick1: real reads
  : > "$SI_DIR/calls.log"
  si_run 'gh_since_sync proj/repo-a; gh api "repos/proj/repo-a/issues/1/comments?per_page=100" --paginate >/dev/null; gh api "repos/proj/repo-a/issues/2/comments?per_page=100" --paginate >/dev/null'
  assert_eq "$(si_calls)" "1" "AC2: tick2 (nothing changed) makes exactly one call — the since= list" || { si_teardown; return 1; }
  assert_contains "$(cat "$SI_DIR/calls.log")" "since=" "AC2: that one call is the since list" || { si_teardown; return 1; }
  si_teardown
}

test_si_ac2b_no_ttl_survives_what_a_short_ttl_would_not() {
  si_setup
  SI_TTL=1 si_run 'gh_since_sync proj/repo-a' >/dev/null
  SI_TTL=1 si_read_both >/dev/null
  sleep 2   # longer than the 1s TTL: the old mechanism would treat this as expired
  : > "$SI_DIR/calls.log"
  SI_TTL=1 si_run 'gh_since_sync proj/repo-a; gh api "repos/proj/repo-a/issues/1/comments?per_page=100" --paginate >/dev/null'
  assert_eq "$(si_reads 1)" "0" "AC2: a single issue's comments have no wall-clock TTL, unlike the old 60s cache" || { si_teardown; return 1; }
  si_teardown
}

test_si_ac2_unsynced_process_still_uses_ttl() {
  si_setup
  SI_TTL=1 si_read_both >/dev/null   # never synced in any process
  sleep 2
  : > "$SI_DIR/calls.log"
  SI_TTL=1 si_run 'gh api "repos/proj/repo-a/issues/1/comments?per_page=100" --paginate >/dev/null'
  assert_eq "$(si_reads 1)" "1" "AC2: a process that never synced this repo still obeys the ordinary TTL, re-reading after it expires" || { si_teardown; return 1; }
  si_teardown
}

test_si_ac2_placeholder_repo_literal_never_exempt() {
  si_setup
  SI_TTL=1 si_run 'gh api "repos/{owner}/{repo}/issues/1/comments?per_page=100" --paginate >/dev/null; gh_since_sync proj/repo-a'
  sleep 2
  : > "$SI_DIR/calls.log"
  SI_TTL=1 si_run 'gh api "repos/{owner}/{repo}/issues/1/comments?per_page=100" --paginate >/dev/null'
  assert_eq "$(grep -cF '{owner}/{repo}/issues/1/comments' "$SI_DIR/calls.log")" "1" \
    "AC2: syncing a real repo never exempts the literal {owner}/{repo} placeholder" || { si_teardown; return 1; }
  si_teardown
}

test_si_scopelist_served_from_cache_when_unchanged() {
  si_setup
  echo '[{"number":1,"state":"open"},{"number":2,"state":"open"}]' > "$SI_DIR/list-milestone.json"
  si_run 'gh_since_sync proj/repo-a' >/dev/null
  si_run 'gh api --paginate "repos/proj/repo-a/issues?milestone=12&state=all&per_page=100" >/dev/null'
  : > "$SI_DIR/calls.log"
  si_run 'gh_since_sync proj/repo-a; gh api --paginate "repos/proj/repo-a/issues?milestone=12&state=all&per_page=100" >/dev/null'
  assert_eq "$(si_calls)" "1" "an unchanged tick's scope list is served from cache, only the since= list call is made" \
    && assert_contains "$(cat "$SI_DIR/calls.log")" "since=" "that one call is the since list" || { si_teardown; return 1; }
  si_teardown
}

test_si_scopelist_invalidated_when_something_changed() {
  si_setup
  echo '[{"number":1,"state":"open"},{"number":2,"state":"open"}]' > "$SI_DIR/list-milestone.json"
  si_run 'gh_since_sync proj/repo-a' >/dev/null
  si_run 'gh api --paginate "repos/proj/repo-a/issues?milestone=12&state=all&per_page=100" >/dev/null'
  echo '[{"number":1}]' > "$SI_DIR/since-resp.json"
  : > "$SI_DIR/calls.log"
  si_run 'gh_since_sync proj/repo-a; gh api --paginate "repos/proj/repo-a/issues?milestone=12&state=all&per_page=100" >/dev/null'
  assert_eq "$(si_calls)" "2" "a changed issue forces the scope list to be refetched too — membership may have moved" \
    && assert_contains "$(cat "$SI_DIR/calls.log")" "milestone=12" "the scope list really was refetched" || { si_teardown; return 1; }
  si_teardown
}

test_si_ac3_only_the_changed_ticket_is_reread() {
  si_setup
  si_run 'gh_since_sync proj/repo-a' >/dev/null
  si_read_both >/dev/null
  echo '[{"number":1}]' > "$SI_DIR/since-resp.json"   # #1 changed, #2 did not
  : > "$SI_DIR/calls.log"
  si_run 'gh_since_sync proj/repo-a; gh api "repos/proj/repo-a/issues/1/comments?per_page=100" --paginate >/dev/null; gh api "repos/proj/repo-a/issues/2/comments?per_page=100" --paginate >/dev/null'
  assert_eq "$(si_calls)" "2" "AC3: the since list plus exactly one re-read" \
    && assert_eq "$(si_reads 1)" "1" "AC3: the changed #1 is re-read" \
    && assert_eq "$(si_reads 2)" "0" "AC3: unchanged #2 still served from cache" || { si_teardown; return 1; }
  si_teardown
}

test_si_ac4_failed_list_falls_back_and_never_advances() {
  si_setup
  si_run 'gh_since_sync proj/repo-a' >/dev/null
  si_run 'gh api "repos/proj/repo-a/issues/1/comments?per_page=100" --paginate >/dev/null'
  local sf before after rc
  sf=$(si_since_file); before=$(cat "$sf" 2>/dev/null)
  touch "$SI_DIR/since-fail"
  si_run 'gh_since_sync proj/repo-a' >/dev/null 2>&1; rc=$?
  after=$(cat "$sf" 2>/dev/null)
  assert_eq "$rc" "1" "AC4: a failed since= list is reported as a failure" \
    && assert_eq "$after" "$before" "AC4: the stored timestamp never advances on a failed list" || { si_teardown; return 1; }
  rm -f "$SI_DIR/since-fail"
  : > "$SI_DIR/calls.log"
  si_run 'gh api "repos/proj/repo-a/issues/1/comments?per_page=100" --paginate >/dev/null'
  assert_eq "$(si_reads 1)" "1" "AC4: a failed sync falls back to a real re-read, never a stale hit" || { si_teardown; return 1; }
  si_teardown
}

test_si_ac4_failed_list_invalidates_rather_than_trusts() {
  si_setup
  si_run 'gh_since_sync proj/repo-a' >/dev/null
  si_read_both >/dev/null
  touch "$SI_DIR/since-fail"
  si_run 'gh_since_sync proj/repo-a' >/dev/null 2>&1
  rm -f "$SI_DIR/since-fail"
  : > "$SI_DIR/calls.log"
  si_read_both >/dev/null
  assert_eq "$(si_reads 1)" "1" "AC4: #1 re-read after a failed list" \
    && assert_eq "$(si_reads 2)" "1" "AC4: #2 re-read after a failed list (never stale-as-fresh)" || { si_teardown; return 1; }
  si_teardown
}

# ---- AC5: static — supervisor.sh wiring ------------------------------------------------------------------------
test_si_ac5_no_blanket_cache_clear_at_tick_start() {
  local tick; tick=$(awk '/^# --- Main tick ---/{on=1} on' "$SUP_SI" | head -40)
  if printf '%s\n' "$tick" | grep -qE '^gh_cache_clear$'; then fail "AC5: supervisor.sh still wipes the whole cache at tick start"; return 1; fi
  printf '%s\n' "$tick" | grep -qF 'gh_since_sync' || { fail "AC5: supervisor.sh's main tick must call gh_since_sync"; return 1; }
  printf '%s\n' "$tick" | grep -qF 'sw_repo_list' || { fail "AC5: the sync must cover sw_repo_list (DISPATCH_REPOS + SCAN_ONLY_REPOS)"; return 1; }
  assert_eq 0 0 "AC5 ok"
}

# ---- AC6: docs --------------------------------------------------------------------------------------------------
test_si_ac6_orchestrator_wait_loop_throttles_comments_reads() {
  local orch="$ROOT_SI/agents/orchestrator.md"
  local loop; loop=$(awk '/^BEFORE=\$\(count/{on=1} on; on && /^done$/{exit}' "$orch")
  assert_contains "$loop" 'kill -0 "$PID"' "AC6: PID liveness check stays in the loop" || return 1
  assert_contains "$loop" 'sleep 15' "AC6: the 15s poll step is unchanged" || return 1
  if ! printf '%s\n' "$loop" | grep -qE '% *8|120|2 min'; then fail "AC6: comments read must be throttled to ~2 min, not every 15s"; return 1; fi
  assert_eq 0 0 "AC6 orchestrator ok"
}

test_si_ac6_deployer_checks_poll_interval() {
  local depl="$ROOT_SI/agents/deployer.md"
  local gate; gate=$(sed -n '/\*\*Wait in-run\*\*/,/^   - \*\*Pin the head/p' "$depl")
  if ! printf '%s\n' "$gate" | grep -qiE '2[- ]min(ute)?'; then fail "AC6: deployer Checks-gate wait must name a ~2-minute poll interval"; return 1; fi
  assert_contains "$gate" "Wait at most **30 min**" "AC6: 30-min wait cap unchanged" || return 1
  assert_eq 0 0 "AC6 deployer ok"
}

test_si_ac6_claude_md_line57_reworded() {
  local f="$ROOT_SI/CLAUDE.md"
  if grep -qF 'must keep polling with `gh`/`gh api` as they already do — this guidance does not apply to them and is not a reason to change their logic' "$f"; then
    fail "AC6: CLAUDE.md line 57 still tells headless agents to keep polling as-is"; return 1
  fi
  grep -qiE '2[- ]min(ute)?' "$f" || { fail "AC6: CLAUDE.md must tell headless agents to poll GitHub at most every ~2 min"; return 1; }
  assert_eq 0 0 "AC6 CLAUDE.md ok"
}

run_test test_si_ac1_cold_sync_makes_no_call
run_test test_si_ac1_cold_sync_invalidates_leftover_cache
run_test test_si_ac2_unchanged_tick_reuses_previous_reads
run_test test_si_ac2b_no_ttl_survives_what_a_short_ttl_would_not
run_test test_si_ac2_unsynced_process_still_uses_ttl
run_test test_si_ac2_placeholder_repo_literal_never_exempt
run_test test_si_scopelist_served_from_cache_when_unchanged
run_test test_si_scopelist_invalidated_when_something_changed
run_test test_si_ac3_only_the_changed_ticket_is_reread
run_test test_si_ac4_failed_list_falls_back_and_never_advances
run_test test_si_ac4_failed_list_invalidates_rather_than_trusts
run_test test_si_ac5_no_blanket_cache_clear_at_tick_start
run_test test_si_ac6_orchestrator_wait_loop_throttles_comments_reads
run_test test_si_ac6_deployer_checks_poll_interval
run_test test_si_ac6_claude_md_line57_reworded
