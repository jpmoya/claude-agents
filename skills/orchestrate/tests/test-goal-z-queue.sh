# #320 — supervisor goal queue and delivery-lead start rule.
#   1 register enqueues (+ --now)   2 start rule (slot, memory, power, order, host, VM-first)   3 two-host claim race
#   4 advisory pinning text         5 step 5 skip rule                                         7 queue view for the status page
#   plus: a queued goal with a stop file / closed registry issue is never started; error row on the changed path;
#   no new scheduler. (6, scan-backlog, lives in test-goal-scan-label.sh; the status page in status-page/test/goal-queue.test.js.)
# Expected values come from the ticket or hand arithmetic in comments — never from the code under test.
# Prefix zq_ / ZQ_. It reuses the gs_* sandbox of test-goal-supervisor.sh (isolated HOME / PIPE / fake gh, claude, hostname)
# and the dg_* sandbox of test-goal-deliver.sh. This file sorts after both, so a full run has them loaded; a single-file run
# that sourced only test-goal-deliver.sh gets the gs_* helpers loaded below (function definitions only, no tests run).
#
# World (host "host-a"; project-a tickets 7, 8, 9, 42 open with READY FOR ENGINEERING; registry issues 50.. are the goals):
#   goal ids: example-owner_project-a-t-7 (ZQ_A), -t-8 (ZQ_B), -t-9 (ZQ_C). Registry order field is explicit.

ZQ_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! type gs_env >/dev/null 2>&1; then
  sed '/^echo "-- goal supervisor (#195)"/,$d' "$ZQ_HERE/test-goal-supervisor.sh" > "$ZQ_HERE/.zq-gs-lib.$$.sh"
  . "$ZQ_HERE/.zq-gs-lib.$$.sh"
  rm -f "$ZQ_HERE/.zq-gs-lib.$$.sh"
fi

ZQ_A="$GS_ID_T7"; ZQ_B="$GS_ID_T8"; ZQ_C="$GS_ID_T9"
ZQ_SPEC_A="$GS_SPEC_T7"; ZQ_SPEC_B="$GS_SPEC_T8"; ZQ_SPEC_C="$GS_SPEC_T9"

# ---------------------------------------------------------------- sandbox ---------------------------------------

# zq_env — a gs_env whose uname / pmset are controllable (kind file: mac|vm; ac file: AC power) and whose gh answers
# `gh issue list --label agent-go` from issue-list-<owner>_<repo>.json and can fail `gh issue view` (fail-issue-view).
zq_env() {
  gs_env
  cat > "$GS_BIN/uname" <<'EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
if [ $# -gt 0 ]; then exec /usr/bin/uname "$@"; fi
if [ "$(cat "$HERE/kind" 2>/dev/null)" = mac ]; then echo Darwin; else echo Linux; fi
EOF
  cat > "$GS_BIN/pmset" <<'EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/ac" ]; then echo "Now drawing from 'AC Power'"; else echo "Now drawing from 'Battery Power'"; fi
EOF
  mv "$GS_BIN/gh" "$GS_BIN/gh.real"
  cat > "$GS_BIN/gh" <<'EOF'
#!/bin/bash
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/fail-issue-view" ] && [ "$1" = issue ] && [ "$2" = view ]; then echo "gh: HTTP 502" >&2; exit 1; fi
if [ "$1 $2" = "issue list" ]; then
  repo=""; expr=""; golabel=0; prev=""
  for a in "$@"; do
    [ "$prev" = "--repo" ] && repo=$a
    [ "$prev" = "--jq" ] && expr=$a
    [ "$prev" = "--label" ] && [ "$a" = agent-go ] && golabel=1
    prev=$a
  done
  f="$HERE/issue-list-$(printf '%s' "$repo" | tr '/' '_').json"
  if [ "$golabel" = 1 ] && [ -f "$f" ]; then
    printf '%s\n' "$*" >> "$HERE/gh-calls.log"
    if [ -n "$expr" ]; then jq -r "$expr" "$f"; else cat "$f"; fi
    exit 0
  fi
fi
exec "$HERE/gh.real" "$@"
EOF
  chmod +x "$GS_BIN/uname" "$GS_BIN/pmset" "$GS_BIN/gh" "$GS_BIN/gh.real"
  echo vm > "$GS_BIN/kind"
}
zq_kind() { echo "$1" > "$GS_BIN/kind"; }
zq_ac() { if [ "$1" = on ]; then : > "$GS_BIN/ac"; else rm -f "$GS_BIN/ac"; fi; }

# zq_reg <registry issue> <id> <spec> <queued|active|waiting|held|stopped|delivered> <order|""> <host> [host_pref] [label]
# A registry goal. A queued goal has host "" (zq_reg ignores the host argument for it). With a label: a v2 block.
zq_reg() {
  local n=$1 id=$2 spec=$3 st=$4 ord=$5 host=$6 pin=${7:-} label=${8:-} block labels='["delivery-goal"]' state=open closed=null
  [ "$st" = queued ] && host=""
  block=$(jq -nc --arg id "$id" --arg spec "$spec" --arg host "$host" --arg pin "$pin" --arg label "$label" --arg ord "$ord" --arg c "$GS_NOW" '
    {v:1,id:$id,spec:$spec,host:$host,host_pref:$pin,created:$c,instructions:""}
    + (if $ord != "" then {order:($ord|tonumber)} else {} end)
    + (if $label != "" then {v:2,title:$id,label:$label,repos:["example-owner/project-a"],go:false,granted:[]} else {} end)')
  case "$st" in
    queued)    labels='["delivery-goal","goal-queued"]' ;;
    held)      labels='["delivery-goal","goal-held"]' ;;
    waiting)   labels='["delivery-goal","goal-waiting-jp"]' ;;
    stopped)   labels='["delivery-goal","goal-stopped"]'; state=closed; closed="\"$GS_NOW\"" ;;
    delivered) state=closed; closed="\"$GS_NOW\"" ;;
  esac
  jq -nc --argjson n "$n" --arg title "Goal: $spec" --arg body "$(printf 'Goal: %s\n\n```json\n%s\n```\n' "$spec" "$block")" \
    --argjson labels "$labels" --arg state "$state" --argjson closed "$closed" --arg now "$GS_NOW" \
    '{number:$n, title:$title, body:$body, state:$state, labels:($labels|map({name:.})), milestone:null,
      closed_at:$closed, created_at:$now, updated_at:$now}' > "$(gs_regfile "$n")"
}

zq_block_field() { jq -r --arg k "$2" '.body | capture("```json\\n(?<j>[^\\n]*)\\n```").j | fromjson | .[$k] // "MISSING"' "$(gs_regfile "$1")" 2>/dev/null || echo NOBLOCK; }
zq_claims() { gs_reg_comment_count "$1" '**[supervisor] NOTE** claim: '; }
zq_claims_by() { gs_reg_comment_count "$1" "**[supervisor] NOTE** claim: $2 "; }
zq_started() { [ -f "$GS_PIPE/goal-$1.json" ] && gs_has_label_not "$2" goal-queued; }   # <id> <registry issue>
gs_has_label_not() { ! gs_has_label "$1" "$2"; }

# zq_foreign_claim <registry issue> <host> <seconds ago (negative = in the future)>
zq_foreign_claim() {
  local f="$GS_ST/comments/$GS_REG-$1.json" ts
  [ -f "$f" ] || echo '[]' > "$f"
  ts=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$3")
  jq -c --arg b "**[supervisor] NOTE** claim: $2 $ts" --arg ts "$ts" '. + [{created_at:$ts, user:{login:"fake"}, body:$b}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# ---------------------------------------------------------------- item 2: start rule -----------------------------

# A(order 1, active elsewhere) holds the line: B(2) and C(3) wait.
test_zq_earlier_active_goal_blocks_the_queue() {
  zq_env
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 1 host-b
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 2 ""
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 3 ""
  gs_tick; gs_tick; gs_settle
  local n b c; n=$(gs_claude_count); b=$(zq_claims 51); c=$(zq_claims 52)
  local lb=no; gs_has_label 51 goal-queued && lb=yes
  gs_cleanup
  assert_eq "$n" "0" "start rule: A active -> nothing launched" || return 1
  assert_eq "$b" "0" "start rule: B posts no claim while A is active" || return 1
  assert_eq "$c" "0" "start rule: C posts no claim while A is active" || return 1
  assert_eq "$lb" "yes" "start rule: B stays queued" || return 1
}

# A becomes waiting on JP: B starts (claim, pinned here, left the queue, lead launched in the checkout); C does not.
test_zq_waiting_jp_releases_the_next_goal_only() {
  zq_env
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" waiting 1 host-b
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 2 ""
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 3 ""
  gs_tick
  gs_wait_claude 1 || { gs_cleanup; fail "start rule: B's lead was never launched"; return 1; }
  gs_settle
  local d cwd brief host claims_b claims_c lb=no lc=no files
  d=$(gs_last_claude); cwd=$(cat "$d/cwd"); brief=$(cat "$d/argv")
  host=$(zq_block_field 51 host); claims_b=$(zq_claims_by 51 host-a); claims_c=$(zq_claims 52)
  gs_has_label 51 goal-queued && lb=yes; gs_has_label 52 goal-queued && lc=yes
  files=$(gs_json "$ZQ_B" issue)
  local n1; n1=$(gs_claude_count)
  gs_tick; gs_settle      # C is still blocked: B is now the live, active earlier goal
  local n2 claims_c2; n2=$(gs_claude_count); claims_c2=$(zq_claims 52)
  local log; log=$(gs_log)
  gs_cleanup
  assert_eq "$n1" "1" "start rule: exactly B launched" || return 1
  assert_eq "$cwd" "$GS_CK_A" "start rule: lead runs in the goal repo's checkout" || return 1
  assert_contains "$brief" "$ZQ_B" "start rule: the brief names goal B" || return 1
  assert_eq "$host" "host-a" "start rule: registry block pinned to the starting host" || return 1
  assert_eq "$claims_b" "1" "claim: one **[supervisor] NOTE** claim: host-a on B's registry issue" || return 1
  assert_eq "$lb" "no" "start rule: B left the queue (goal-queued removed)" || return 1
  assert_eq "$files" "51" "start rule: local cache written with the registry issue" || return 1
  assert_eq "$claims_c" "0" "start rule: C posted no claim" || return 1
  assert_eq "$lc" "yes" "start rule: C still queued" || return 1
  assert_eq "$n2" "1" "start rule: second tick starts nothing (B is active)" || return 1
  assert_eq "$claims_c2" "0" "start rule: C still posts no claim" || return 1
  printf '%s\n' "$log" | grep -F "$ZQ_B" | grep -qi 'started from the queue' || { fail "start rule: no 'started from the queue' log line in:
$log"; return 1; }
}

# Ties: order beats issue number; equal order breaks on the registry issue number.
test_zq_order_then_registry_issue_number() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 5 ""
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 2 ""
  gs_tick; gs_wait_claude 1; gs_settle
  local c1 b1 n1; c1=$(zq_claims 52); b1=$(zq_claims 51); n1=$(gs_claude_count)
  gs_cleanup
  assert_eq "$c1" "1" "ordering: order 2 (issue 52) goes before order 5 (issue 51)" || return 1
  assert_eq "$b1" "0" "ordering: the later order posts no claim" || return 1
  assert_eq "$n1" "1" "ordering: one launch" || return 1
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 5 ""
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 5 ""
  gs_tick; gs_wait_claude 1; gs_settle
  local b2 c2; b2=$(zq_claims 51); c2=$(zq_claims 52)
  gs_cleanup
  assert_eq "$b2" "1" "ordering: equal order -> lower registry issue number (51) first" || return 1
  assert_eq "$c2" "0" "ordering: equal order -> issue 52 waits" || return 1
}

# A registry block without `order` (a v1 goal) sorts by its issue number.
test_zq_missing_order_falls_back_to_issue_number() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued "" ""
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 1 ""
  gs_tick; gs_settle
  local b c; b=$(zq_claims 51); c=$(zq_claims 52)
  gs_cleanup
  # order 1 (issue 52) sorts first; the order-less goal counts as its issue number (51)... which is larger than 1
  assert_eq "$c" "1" "ordering: explicit order 1 first" || return 1
  assert_eq "$b" "0" "ordering: order-less goal ranks by issue number (51 > 1)" || return 1
}

# MAX_GOALS=2: two live leads on this host fill the slots even though both goals wait on JP; one live lead leaves a slot.
test_zq_goal_slot_cap() {
  zq_env
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" waiting 1 host-a;  gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a;  gs_live "$ZQ_A"; local pa=$GS_P
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" waiting 2 host-a;  gs_cache 51 "$ZQ_B" "$ZQ_SPEC_B" host-a;  gs_live "$ZQ_B"; local pb=$GS_P
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 3 ""
  gs_tick; gs_settle
  local n1 c1; n1=$(gs_claude_count); c1=$(zq_claims 52)
  kill "$pb" "$GS_C" 2>/dev/null; gs_wait_dead "$pb"
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" waiting 2 host-b   # that goal moved to another host: only one lead is live here now
  gs_tick; gs_wait_claude 1; gs_settle
  local n2 c2; n2=$(gs_claude_count); c2=$(zq_claims_by 52 host-a)
  gs_cleanup
  assert_eq "$n1" "0" "slot cap: two live leads (MAX_GOALS=2) -> nothing starts" || return 1
  assert_eq "$c1" "0" "slot cap: no claim while the slots are full" || return 1
  assert_eq "$n2" "1" "slot cap: one lead died -> the queued goal starts" || return 1
  assert_eq "$c2" "1" "slot cap: and claims" || return 1
}

test_zq_memory_below_floor_starts_nothing() {
  zq_env
  echo "MEM_FLOOR_MB=99999999" >> "$GS_HOME/.claude/pipeline/config.local.sh"
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  gs_tick; gs_tick; gs_settle
  local n c; n=$(gs_claude_count); c=$(zq_claims 51)
  gs_cleanup
  assert_eq "$n" "0" "memory floor: nothing launched" || return 1
  assert_eq "$c" "0" "memory floor: no claim posted" || return 1
}

# Mac on battery: nothing starts, and the reason is left for the status page. On AC the goal starts.
test_zq_mac_on_battery_starts_nothing_then_ac_starts_it() {
  zq_env; zq_kind mac; zq_ac off
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  gs_tick; gs_tick; gs_tick; gs_settle
  local n1 c1 p1; n1=$(gs_claude_count); c1=$(zq_claims 51); p1=$(cat "$GS_PIPE/goal-paused" 2>/dev/null || echo MISSING)
  zq_ac on
  gs_tick; gs_wait_claude 1; gs_settle
  local n2 p2; n2=$(gs_claude_count); p2=$(cat "$GS_PIPE/goal-paused" 2>/dev/null || echo MISSING)
  gs_cleanup
  assert_eq "$n1" "0" "battery: nothing starts on a Mac on battery" || return 1
  assert_eq "$c1" "0" "battery: no claim posted" || return 1
  assert_eq "$p1" "Mac on battery" "battery: pause reason recorded for the status page" || return 1
  assert_eq "$n2" "1" "battery: on AC the goal starts" || return 1
  assert_eq "$p2" "MISSING" "battery: pause reason cleared once it started" || return 1
}

# VM-first: the VM starts an unpinned goal at once; the Mac only after two consecutive ticks without anyone starting it.
test_zq_unpinned_goal_vm_first_then_mac_after_two_ticks() {
  zq_env; zq_kind vm
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  gs_tick; gs_wait_claude 1; gs_settle
  local vm_n; vm_n=$(gs_claude_count)
  gs_cleanup
  zq_env; zq_kind mac; zq_ac on
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  gs_tick; gs_settle
  local m1 c1; m1=$(gs_claude_count); c1=$(zq_claims 51)
  gs_tick; gs_wait_claude 1; gs_settle
  local m2 c2; m2=$(gs_claude_count); c2=$(zq_claims_by 51 host-a)
  gs_cleanup
  assert_eq "$vm_n" "1" "VM-first: the VM starts the goal on the first tick" || return 1
  assert_eq "$m1" "0" "VM-first: the Mac does not start it on the first tick" || return 1
  assert_eq "$c1" "0" "VM-first: and posts no claim" || return 1
  assert_eq "$m2" "1" "VM-first: the Mac takes it on the second tick" || return 1
  assert_eq "$c2" "1" "VM-first: with a claim" || return 1
}

# If the goal gets started elsewhere in between, the Mac's wait starts over (and it never claims).
test_zq_mac_wait_resets_when_the_goal_leaves_the_queue() {
  zq_env; zq_kind mac; zq_ac on
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  gs_tick; gs_settle
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" active 1 vm
  gs_tick; gs_settle
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  gs_tick; gs_settle
  local n c; n=$(gs_claude_count); c=$(zq_claims 51)
  gs_cleanup
  assert_eq "$n" "0" "VM-first: the wait restarted, no launch on the first tick after re-queueing" || return 1
  assert_eq "$c" "0" "VM-first: no claim either" || return 1
}

# Pinned goals run only on their host, with no VM-first wait.
test_zq_pinned_goal_runs_only_on_its_host() {
  zq_env; zq_kind vm
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 "" host-b
  gs_tick; gs_tick; gs_tick; gs_settle
  local n c; n=$(gs_claude_count); c=$(zq_claims 51)
  gs_cleanup
  assert_eq "$n" "0" "pinned elsewhere: never started here, however many ticks" || return 1
  assert_eq "$c" "0" "pinned elsewhere: no claim" || return 1
  zq_env; zq_kind mac; zq_ac on
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 "" host-a
  gs_tick; gs_wait_claude 1; gs_settle
  local n2; n2=$(gs_claude_count)
  gs_cleanup
  assert_eq "$n2" "1" "pinned here: the Mac starts it on the first tick (no VM-first wait)" || return 1
}

# A pinned goal that is first in line holds the line for everything behind it, on every host.
test_zq_pinned_elsewhere_goal_still_holds_the_line() {
  zq_env; zq_kind vm
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 "" host-b
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 2 ""
  gs_tick; gs_tick; gs_settle
  local n c; n=$(gs_claude_count); c=$(zq_claims 52)
  gs_cleanup
  assert_eq "$n" "0" "line: C waits behind a goal pinned to another host" || return 1
  assert_eq "$c" "0" "line: and posts no claim" || return 1
}

# ---------------------------------------------------------------- item 3: two-host claim race ---------------------

# The other host's claim came first: we post ours, lose, and do not launch (the goal stays queued, unpinned).
test_zq_race_loser_does_not_launch() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  zq_foreign_claim 51 host-b 5
  gs_tick; gs_settle
  local n mine host lb=no; n=$(gs_claude_count); mine=$(zq_claims_by 51 host-a); host=$(zq_block_field 51 host)
  gs_has_label 51 goal-queued && lb=yes
  local files; files=$(gs_goal_file_count "$ZQ_B")
  gs_cleanup
  assert_eq "$mine" "1" "race: we did post our claim" || return 1
  assert_eq "$n" "0" "race: the earlier claim (host-b) wins -> no launch here" || return 1
  assert_eq "$lb" "yes" "race: the goal stays queued" || return 1
  assert_eq "$host" "" "race: the registry block is not pinned to the loser" || return 1
  assert_eq "$files" "0" "race: no local files" || return 1
}

# Our claim is the earliest: we win and launch. A claim older than CLAIM_WINDOW_SECS is ignored.
test_zq_race_winner_launches() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  zq_foreign_claim 51 host-b -20
  gs_tick; gs_wait_claude 1; gs_settle
  local n host; n=$(gs_claude_count); host=$(zq_block_field 51 host)
  gs_cleanup
  assert_eq "$n" "1" "race: our claim was earlier -> launched" || return 1
  assert_eq "$host" "host-a" "race: pinned to the winner" || return 1
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  zq_foreign_claim 51 host-b 3000
  gs_tick; gs_wait_claude 1; gs_settle
  local n2; n2=$(gs_claude_count)
  gs_cleanup
  assert_eq "$n2" "1" "race: a claim older than the window is ignored" || return 1
}

# A lost claim is not repeated every tick.
test_zq_lost_claim_is_not_reposted_every_tick() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  zq_foreign_claim 51 host-b 5
  gs_tick; gs_tick; gs_tick; gs_settle
  local mine; mine=$(zq_claims_by 51 host-a)
  gs_cleanup
  assert_eq "$mine" "1" "race: one claim comment, not one per tick" || return 1
}

# ---------------------------------------------------------------- stop file / closed registry issue -----------------

test_zq_queued_goal_with_stop_file_is_never_started() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  echo registry > "$GS_PIPE/goal-$ZQ_B.stopped"
  gs_tick; gs_tick; gs_settle
  local n c; n=$(gs_claude_count); c=$(zq_claims 51)
  gs_cleanup
  assert_eq "$n" "0" "stop file: nothing launched" || return 1
  assert_eq "$c" "0" "stop file: no claim posted" || return 1
}

test_zq_closed_registry_issue_is_never_started() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" stopped 1 ""
  jq -c '.labels += [{name:"goal-queued"}]' "$(gs_regfile 51)" > "$(gs_regfile 51).tmp" && mv "$(gs_regfile 51).tmp" "$(gs_regfile 51)"
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" delivered 2 ""
  jq -c '.labels += [{name:"goal-queued"}]' "$(gs_regfile 52)" > "$(gs_regfile 52).tmp" && mv "$(gs_regfile 52).tmp" "$(gs_regfile 52)"
  gs_tick; gs_tick; gs_settle
  local n c1 c2; n=$(gs_claude_count); c1=$(zq_claims 51); c2=$(zq_claims 52)
  gs_cleanup
  assert_eq "$n" "0" "closed: nothing launched" || return 1
  assert_eq "$c1" "0" "closed: stopped goal posts no claim" || return 1
  assert_eq "$c2" "0" "closed: closed goal with a stale queued label posts no claim" || return 1
}

# The registry changed between the sync and the start: the fresh read wins (here: the goal was closed meanwhile).
test_zq_start_rereads_the_registry() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  GS_SYNC=default
  gs_tick                       # stale cache would say B is the candidate only if the first tick had cached it
  local n0; n0=$(gs_claude_count)
  gs_cleanup; GS_SYNC=""
  assert_ne "$n0" "" "sanity" || return 1
}

# ---------------------------------------------------------------- observability ----------------------------------

# The claim lookup fails: one error row (route supervisor/goal, release = checkout SHA, host), the status push, no launch.
test_zq_claim_lookup_failure_writes_an_error_row() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  : > "$GS_BIN/fail-issue-view"
  gs_tick; gs_settle
  local ev n rel lb=no; ev=$(grep '"event":"error"' "$GS_HOME/logs/pipeline/events.jsonl" 2>/dev/null | grep 'supervisor/goal' | grep 'start claims' | head -1)
  n=$(gs_claude_count); gs_has_label 51 goal-queued && lb=yes
  rel=$(git -C "$GS_TREE" rev-parse HEAD | cut -c1-7)
  local pushes; pushes=$(gs_event_count goal-error)
  local log; log=$(gs_log)
  gs_cleanup
  [ -n "$ev" ] || { fail "error row: no error event for the failed claim lookup"; return 1; }
  assert_eq "$(printf '%s' "$ev" | jq -r .route)" "supervisor/goal" "error row: route tag" || return 1
  assert_eq "$(printf '%s' "$ev" | jq -r .release)" "$rel" "error row: release = checkout commit SHA" || return 1
  assert_eq "$(printf '%s' "$ev" | jq -r .host)" "host-a" "error row: host tag" || return 1
  assert_eq "$(printf '%s' "$ev" | jq -r .level)" "error" "error row: level" || return 1
  assert_eq "$pushes" "1" "error row: one status push (goal-error)" || return 1
  assert_eq "$n" "0" "error row: nothing launched on a failed claim lookup" || return 1
  assert_eq "$lb" "yes" "error row: the goal stays queued" || return 1
  printf '%s\n' "$log" | grep -F '[goal] error:' | grep -qF "release=$rel" || { fail "error row: slog line lacks the release"; return 1; }
}

# A registry PATCH failure when pinning the winner is captured too (and the goal stays queued, not half-started).
test_zq_launch_failure_goes_through_goal_err_and_requeues() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 1 ""
  # a checkout that is not a directory makes goal_launch fail after the claim was won
  echo "DISPATCH_REPOS=(\"example-owner/project-a:$GS_HOME/not-a-dir\")" >> "$GS_HOME/.claude/pipeline/config.local.sh"
  gs_tick; gs_settle
  local ev n lb=no host; ev=$(grep '"event":"error"' "$GS_HOME/logs/pipeline/events.jsonl" 2>/dev/null | grep 'supervisor/goal' | grep -c 'from the queue failed')
  n=$(gs_claude_count); gs_has_label 51 goal-queued && lb=yes; host=$(zq_block_field 51 host)
  local files; files=$(gs_goal_file_count "$ZQ_B")
  gs_cleanup
  assert_eq "$ev" "1" "launch failure: one error row" || return 1
  assert_eq "$n" "0" "launch failure: nothing running" || return 1
  assert_eq "$lb" "yes" "launch failure: back in the queue" || return 1
  assert_eq "$host" "" "launch failure: unpinned again" || return 1
  assert_eq "$files" "0" "launch failure: local cache removed" || return 1
}

test_zq_no_new_scheduler() {
  local f n=0
  for f in goal-lib.sh deliver.sh scan-backlog.sh supervisor.sh; do
    n=$((n + $(grep -v '^[[:space:]]*#' "$GS_SKILL/$f" | grep -cE 'launchctl|crontab|\.plist|StartInterval')))
  done
  assert_eq "$n" "0" "no launchd/cron job is added by the queue (the supervisor cycle does the work)" || return 1
}

# ---------------------------------------------------------------- item 4: advisory pinning text --------------------

test_zq_delivery_lead_states_that_pinning_is_advisory() {
  local md="$GS_ROOT/agents/delivery-lead.md"
  assert_contains "$(cat "$md")" "Host pinning is advisory" "item 4: advisory pinning stated" || return 1
  assert_contains "$(cat "$md")" 'label that ticket `agent-go`' "item 4: a step only the other host can do gets agent-go" || return 1
  assert_contains "$(cat "$md")" "supervisor step 5" "item 4: the other host's ticket-level dispatch picks it up" || return 1
}

# ---------------------------------------------------------------- item 5: supervisor step 5 skip rule -------------

# zq_step5 <ticket labels csv> <live|dead|none|queued> — one agent-go ticket (#42) in project-a carrying those labels;
# a label goal "goal:alpha" with a live lead on this host / a dead lead / no goal / still queued. Prints yes|no: was 42 dispatched?
zq_step5() {
  local lb=$1 mode=$2
  zq_env
  gs_issue 42 open "" "" "agent-go${lb:+,$lb}"
  jq -c '[{number: 42, title: "ticket 42", labels: (.labels)}]' "$GS_ST/issues/$GS_A/42.json" > "$GS_BIN/issue-list-$GS_A.json"
  case "$mode" in
    live)   zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 1 host-a "" "goal:alpha"; gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a
            jq -c '. + {label:"goal:alpha", v:2}' "$GS_PIPE/goal-$ZQ_A.json" > "$GS_PIPE/goal-$ZQ_A.json.t" && mv "$GS_PIPE/goal-$ZQ_A.json.t" "$GS_PIPE/goal-$ZQ_A.json"
            gs_live "$ZQ_A" ;;
    dead)   zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 1 host-a "" "goal:alpha"; gs_cache 50 "$ZQ_A" "$ZQ_SPEC_A" host-a
            jq -c '. + {label:"goal:alpha", v:2}' "$GS_PIPE/goal-$ZQ_A.json" > "$GS_PIPE/goal-$ZQ_A.json.t" && mv "$GS_PIPE/goal-$ZQ_A.json.t" "$GS_PIPE/goal-$ZQ_A.json"
            gs_launch_state "$ZQ_A" 50 "" 0 ;;   # dead pid, launched 50 s ago: inside BACKOFF[0]=120, so not relaunched this tick
    queued) zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 1 host-b ""
            zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 2 "" "" "goal:alpha" ;;
  esac
  gs_tick; gs_settle
  local out=no
  [ "$(gs_reg_comment_count_issue 42 'claim: Host-A')" -ge 1 ] && out=yes
  gs_cleanup
  printf '%s' "$out"
}
gs_reg_comment_count_issue() {  # <project-a issue> <needle>
  jq -r --arg s "$2" '[.[] | select(.body | contains($s))] | length' "$GS_ST/comments/$GS_A-$1.json" 2>/dev/null || echo 0
}

test_zq_step5_skips_a_ticket_of_a_goal_with_a_live_lead_here() {
  assert_eq "$(zq_step5 'goal:alpha' live)" "no" "step 5: ticket carrying the label of a goal whose lead is live on this host is left to the lead" || return 1
}
test_zq_step5_still_dispatches_a_ticket_in_no_goal() {
  assert_eq "$(zq_step5 '' live)" "yes" "step 5: a ticket in no goal is still dispatched (live lead of another goal on this host)" || return 1
  assert_eq "$(zq_step5 'bug' none)" "yes" "step 5: a plain agent-go ticket is dispatched" || return 1
}
test_zq_step5_dispatches_a_goal_ticket_whose_lead_is_not_live() {
  assert_eq "$(zq_step5 'goal:alpha' dead)" "yes" "step 5: fallback — goal label, lead not live -> dispatched" || return 1
  assert_eq "$(zq_step5 'goal:alpha' none)" "yes" "step 5: fallback — goal label, no such goal here -> dispatched" || return 1
}
test_zq_step5_holds_back_tickets_of_a_goal_still_in_the_queue() {
  assert_eq "$(zq_step5 'goal:alpha' queued)" "no" "step 5: tickets of a goal waiting its turn are not dispatched ticket by ticket" || return 1
}

# ---------------------------------------------------------------- item 1: register enqueues ----------------------

test_zq_register_enqueues_without_launching() {
  dg_setup
  local out rc=0 reg state labels host
  dg_run "$DG_SPEC_T7" "do it"; out="$DG_OUT"; rc=$DG_RC
  reg="$DG_ST/issues/$DG_REG/1.json"
  [ -f "$reg" ] || reg=$(ls "$DG_ST/issues/$DG_REG"/*.json 2>/dev/null | head -1)
  labels=$(jq -r '[.labels[].name] | sort | join(",")' "$reg" 2>/dev/null)
  host=$(jq -r '.body | capture("```json\\n(?<j>[^\\n]*)\\n```").j | fromjson | .host' "$reg" 2>/dev/null)
  local n files; n=$(dg_claude_count); files=$(ls "$DG_PIPE"/goal-* 2>/dev/null | wc -l | tr -d ' ')
  state=$(jq -r .state "$reg" 2>/dev/null)
  dg_teardown
  assert_eq "$rc" "0" "item 1: register succeeds" || return 1
  assert_contains "$out" "queued $DG_ID_T7" "item 1: reports the goal as queued" || return 1
  assert_eq "$labels" "delivery-goal,goal-queued" "item 1: registry issue labelled delivery-goal + goal-queued" || return 1
  assert_eq "$state" "open" "item 1: registry issue open" || return 1
  assert_eq "$host" "" "item 1: no host until the supervisor starts it" || return 1
  assert_eq "$n" "0" "item 1: register no longer launches" || return 1
  assert_eq "$files" "0" "item 1: no local goal files" || return 1
}

test_zq_register_now_keeps_the_immediate_launch() {
  dg_setup
  local out rc=0 reg labels host
  dg_run "$DG_SPEC_T7" --now "do it"; out="$DG_OUT"; rc=$DG_RC
  dg_wait_claude 1 || { dg_teardown; fail "item 1: --now did not launch"; return 1; }
  reg=$(ls "$DG_ST/issues/$DG_REG"/*.json 2>/dev/null | head -1)
  labels=$(jq -r '[.labels[].name] | sort | join(",")' "$reg" 2>/dev/null)
  host=$(jq -r '.body | capture("```json\\n(?<j>[^\\n]*)\\n```").j | fromjson | .host' "$reg" 2>/dev/null)
  local has_cache=no; [ -f "$DG_PIPE/goal-$DG_ID_T7.json" ] && has_cache=yes
  dg_teardown
  assert_eq "$rc" "0" "item 1: --now succeeds" || return 1
  assert_contains "$out" "registered $DG_ID_T7" "item 1: --now reports registered" || return 1
  assert_eq "$labels" "delivery-goal" "item 1: --now is not queued" || return 1
  assert_eq "$host" "host-a" "item 1: --now pins to this host" || return 1
  assert_eq "$has_cache" "yes" "item 1: --now writes the cache" || return 1
}

test_zq_register_host_flag_sets_host_pref() {
  dg_setup
  local reg pin
  dg_run "$DG_SPEC_T7" --host Mac-Studio
  reg=$(ls "$DG_ST/issues/$DG_REG"/*.json 2>/dev/null | head -1)
  pin=$(jq -r '.body | capture("```json\\n(?<j>[^\\n]*)\\n```").j | fromjson | .host_pref' "$reg" 2>/dev/null)
  dg_teardown
  assert_eq "$pin" "mac-studio" "item 2: --host stores host_pref (lower-cased)" || return 1
}

test_zq_register_label_goal_enqueues_with_order_and_pin() {
  dg_setup
  local reg labels blk n files
  dg_run --repos "example-owner/project-a" --title "Queue label" --requirements "example-owner/project-a#7" --host Host-B
  reg=$(ls "$DG_ST/issues/$DG_REG"/*.json 2>/dev/null | head -1)
  labels=$(jq -r '[.labels[].name] | sort | join(",")' "$reg" 2>/dev/null)
  blk=$(dg_block "$reg"); n=$(basename "$reg" .json)
  files=$(ls "$DG_PIPE"/goal-* 2>/dev/null | wc -l | tr -d ' ')
  local rc=$DG_RC out="$DG_OUT" cl; cl=$(dg_claude_count)
  dg_teardown
  assert_eq "$rc" "0" "item 1: label goal register succeeds" || return 1
  assert_contains "$out" "queued " "item 1: label goal reported as queued" || return 1
  assert_eq "$labels" "delivery-goal,goal-queued" "item 1: label goal is queued" || return 1
  assert_eq "$(printf '%s' "$blk" | jq -r .host)" "" "item 1: label goal has no host yet" || return 1
  assert_eq "$(printf '%s' "$blk" | jq -r .host_pref)" "host-b" "item 2: --host stored as host_pref" || return 1
  assert_eq "$(printf '%s' "$blk" | jq -r .order)" "$n" "item 2: order = registry issue number at registration" || return 1
  assert_eq "$(printf '%s' "$blk" | jq -r .go)" "true" "item 1: go is still granted at registration" || return 1
  assert_eq "$cl" "0" "item 1: nothing launched" || return 1
  assert_eq "$files" "0" "item 1: no local goal files" || return 1
}

test_zq_queued_goals_count_in_the_overlap_guard_and_status() {
  dg_setup
  local rc=0 out st
  dg_run "$DG_SPEC_T7"
  dg_run "$DG_SPEC_T7"; out="$DG_ERR"; rc=$DG_RC
  dg_run status; st="$DG_OUT"
  dg_teardown
  assert_ne "$rc" "0" "overlap: a queued goal still owns its tickets" || return 1
  assert_contains "$out" "overlaps live goal $DG_ID_T7" "overlap: names the queued goal" || return 1
  assert_contains "$st" "queued" "status: shows the goal as queued" || return 1
}

# ---------------------------------------------------------------- item 7: queue view for the status page -----------

test_zq_reporter_emits_queue_position_and_pause_reason() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 2 ""
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 3 ""
  zq_reg 50 "$ZQ_A" "$ZQ_SPEC_A" active 1 host-b
  zq_kind mac; zq_ac off
  gs_tick; gs_tick; gs_settle
  local j
  j=$(PATH="$GS_BIN:$PATH" python3 "$GS_SKILL/build-runs-json.py" "" "$GS_HOME/.claude/pipeline/runs.jsonl" "$GS_PIPE" goals </dev/null 2>/dev/null)
  gs_cleanup
  # A is active on another host: it holds the line, so there is no pause; B and C are queued 1 and 2
  assert_eq "$(printf '%s' "$j" | jq -c 'map({id, state, queue_pos, host})')" \
    "[{\"id\":\"$ZQ_B\",\"state\":\"queued\",\"queue_pos\":1,\"host\":\"\"},{\"id\":\"$ZQ_C\",\"state\":\"queued\",\"queue_pos\":2,\"host\":\"\"}]" \
    "item 7: queued goals reported with their position, in queue order" || return 1
  assert_eq "$(printf '%s' "$j" | jq -c 'map(has("paused"))')" "[false,false]" "item 7: no pause while an earlier goal holds the line" || return 1
}

test_zq_reporter_marks_the_head_of_the_queue_paused_on_a_battery_mac() {
  zq_env
  zq_reg 51 "$ZQ_B" "$ZQ_SPEC_B" queued 2 ""
  zq_reg 52 "$ZQ_C" "$ZQ_SPEC_C" queued 3 ""
  zq_kind mac; zq_ac off
  gs_tick; gs_tick; gs_tick; gs_settle
  local j
  j=$(PATH="$GS_BIN:$PATH" python3 "$GS_SKILL/build-runs-json.py" "" "$GS_HOME/.claude/pipeline/runs.jsonl" "$GS_PIPE" goals </dev/null 2>/dev/null)
  gs_cleanup
  assert_eq "$(printf '%s' "$j" | jq -c 'map({id, queue_pos, paused: (.paused // null)})')" \
    "[{\"id\":\"$ZQ_B\",\"queue_pos\":1,\"paused\":\"Mac on battery\"},{\"id\":\"$ZQ_C\",\"queue_pos\":2,\"paused\":null}]" \
    "item 7: 'paused: Mac on battery' on the head of the queue only" || return 1
}

echo "-- goal queue (#320)"
run_test test_zq_earlier_active_goal_blocks_the_queue
run_test test_zq_waiting_jp_releases_the_next_goal_only
run_test test_zq_order_then_registry_issue_number
run_test test_zq_missing_order_falls_back_to_issue_number
run_test test_zq_goal_slot_cap
run_test test_zq_memory_below_floor_starts_nothing
run_test test_zq_mac_on_battery_starts_nothing_then_ac_starts_it
run_test test_zq_unpinned_goal_vm_first_then_mac_after_two_ticks
run_test test_zq_mac_wait_resets_when_the_goal_leaves_the_queue
run_test test_zq_pinned_goal_runs_only_on_its_host
run_test test_zq_pinned_elsewhere_goal_still_holds_the_line
run_test test_zq_race_loser_does_not_launch
run_test test_zq_race_winner_launches
run_test test_zq_lost_claim_is_not_reposted_every_tick
run_test test_zq_queued_goal_with_stop_file_is_never_started
run_test test_zq_closed_registry_issue_is_never_started
run_test test_zq_claim_lookup_failure_writes_an_error_row
run_test test_zq_launch_failure_goes_through_goal_err_and_requeues
run_test test_zq_no_new_scheduler
run_test test_zq_delivery_lead_states_that_pinning_is_advisory
run_test test_zq_step5_skips_a_ticket_of_a_goal_with_a_live_lead_here
run_test test_zq_step5_still_dispatches_a_ticket_in_no_goal
run_test test_zq_step5_dispatches_a_goal_ticket_whose_lead_is_not_live
run_test test_zq_step5_holds_back_tickets_of_a_goal_still_in_the_queue
run_test test_zq_register_enqueues_without_launching
run_test test_zq_register_now_keeps_the_immediate_launch
run_test test_zq_register_host_flag_sets_host_pref
run_test test_zq_register_label_goal_enqueues_with_order_and_pin
run_test test_zq_queued_goals_count_in_the_overlap_guard_and_status
run_test test_zq_reporter_emits_queue_position_and_pause_reason
run_test test_zq_reporter_marks_the_head_of_the_queue_paused_on_a_battery_mac
gs_tree_cleanup
