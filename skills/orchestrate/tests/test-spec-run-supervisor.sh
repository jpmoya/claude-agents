# Issue #115 — AC1 + AC3 (runtime half) + AC5: supervisor step A (PM-only spec run for `user-feedback-needs-spec` ideas)
# and the `REJECTED` done state. Whole ticks run in an isolated HOME/PIPE with stubbed `gh`, `claude`, `pmset`.
#
# Naming contract the narrowed guards (test_gm_ac8 etc.) rely on — the implementation must follow it:
#   * step A is one block in supervisor.sh whose header comment starts `# 3c. Spec` and which ends at its first blank line;
#   * the file-header step list gets one line starting `#   3c. spec: `;
#   * an existing "skip, a run owns it" line in the label reconciliation may say `a spec run (3c) owns it`;
#   * REJECTED handling in terminal_kind / the done branch: single lines mentioning REJECTED are exempt from the
#     test_gm_ac8 hash; anything else (e.g. a user-feedback label check) goes between `# #115 begin` and `# #115 end` comment lines. Nothing else in supervisor.sh may change.
#
# Stub gh keeps issue state in $D/issues.json ([{number,repo,title,labels:[{name}]}]) and comments in $D/comments.json
# ([{number,body,createdAt}]); it answers `issue list` (any --json/--jq, --label / --state filters applied) and `issue view`
# (state, title, labels, comments of that number; any --jq) in any flag shape, honours `issue edit --add/--remove-label`
# and `issue close`, and logs every call to $D/gh-calls.log. Stub claude logs "<argv> | ISSUE=.. AGENT=.. REPO=.." (newlines
# flattened) to $D/claude.log; if $D/claude-mode-ready exists it first posts `**[product-manager] READY FOR ENGINEERING**`.
# Every function/variable is prefixed sp_ / SP_. Placeholder repo names only.

HERE_SP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUP_SP="$HERE_SP/../supervisor.sh"

# sp_env [<DISPATCH entries...>; @PIPE@ expands to the pipe dir] — default dispatch = project-a/repo-a only
sp_env() {
  SP_PIPE=$(new_pipe); SP_HOME=$(new_home); SP_D="$SP_HOME/.local/bin"; mkdir -p "$SP_D"
  fixture_repo "$SP_PIPE/repo-a" "project-a/repo-a"; fixture_repo "$SP_PIPE/repo-b" "project-b/repo-b"
  echo '[]' > "$SP_D/issues.json"; echo '[]' > "$SP_D/comments.json"; : > "$SP_D/gh-calls.log"; : > "$SP_D/claude.log"
  local d=("project-a/repo-a:$SP_PIPE/repo-a"); [ $# -gt 0 ] && d=("${@//@PIPE@/$SP_PIPE}")
  { echo 'MEM_FLOOR_MB=0'; echo 'CLAIM_SETTLE_SECS=0'; printf 'DISPATCH_REPOS=('; printf '"%s" ' "${d[@]}"; echo ')'; } > "$SP_HOME/.claude/pipeline/config.local.sh"
  cat > "$SP_D/pmset" <<'X'
#!/bin/bash
echo "Now drawing from 'AC Power'"
X
  cat > "$SP_D/claude" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$* | ISSUE=${PIPELINE_ISSUE:-} AGENT=${PIPELINE_AGENT:-} REPO=${PIPELINE_REPO:-}" | tr '\n' ' ' >> "$D/claude.log"; echo >> "$D/claude.log"
if [ -f "$D/claude-mode-ready" ]; then
  jq --argjson n "${PIPELINE_ISSUE:-0}" --arg b $'**[product-manager] READY FOR ENGINEERING**\nUI change: no\nLane: full' \
    '. + [{number:$n,body:$b,createdAt:"2099-01-01T00:00:00Z"}]' "$D/comments.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/comments.json"
fi
exit 0
X
  cat > "$SP_D/gh" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$D/gh-calls.log"
jqx=""; label=""; repo=""; prev=""; addl=""; reml=""; body=""; state="open"
for a in "$@"; do
  case "$prev" in --jq|-q) jqx=$a;; --label) label=$a;; --repo) repo=$a;; --add-label) addl="$addl,$a";; --remove-label) reml="$reml,$a";; --body) body=$a;; --state) state=$a;; esac; prev=$a
done
out() { if [ -n "$jqx" ]; then printf '%s' "$1" | jq -r "$jqx"; else printf '%s\n' "$1"; fi; }
num=$(printf '%s' "$3" | grep -E '^[0-9]+$')
withc() { jq -c --slurpfile c "$D/comments.json" '. as $i | $i + {state:($i.state // "OPEN"), comments: [$c[0][] | select(.number==$i.number)]}'; }
case "$1 $2" in
  "repo view") echo "${repo:-project-a/repo-a}"; exit 0;;
  "issue list")
    r=${repo:-$(cd "$PWD" && git config --get remote.origin.url | sed -E 's#.*github.com/(.*)\.git#\1#')}
    j=$(jq -c --arg r "$r" --arg l "$label" '[.[] | select(.repo==$r) | select(($l=="") or ([.labels[].name]|index($l)))]' "$D/issues.json" | jq -c '[.[] | {number,title,labels,state:(.state // "OPEN")}]')
    # comments are attached so a caller that filters on them in one list call also works
    j=$(printf '%s' "$j" | jq -c --slurpfile c "$D/comments.json" '[.[] | . as $i | $i + {comments: [$c[0][] | select(.number==$i.number)]}]')
    out "$j"; exit 0;;
  "issue comment") now=$(date -u +%FT%TZ)
    jq --argjson n "${num:-0}" --arg b "$body" --arg t "$now" '. + [{number:$n,body:$b,createdAt:$t}]' "$D/comments.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/comments.json"; exit 0;;
  "issue edit")
    jq --argjson n "${num:-0}" --arg a "$addl" --arg r "$reml" '
      map(if .number==$n then .labels = ((.labels|map(.name)) - ($r|split(",")) + ($a|split(",")|map(select(.!=""))) | unique | map({name:.})) else . end)' \
      "$D/issues.json" > "$D/i.tmp" && mv "$D/i.tmp" "$D/issues.json"; exit 0;;
  "issue close")
    jq --argjson n "${num:-0}" 'map(if .number==$n then . + {state:"CLOSED"} else . end)' "$D/issues.json" > "$D/i.tmp" && mv "$D/i.tmp" "$D/issues.json"; exit 0;;
  "issue view") out "$(jq -c --argjson n "${num:-0}" '.[]|select(.number==$n)' "$D/issues.json" | withc)"; exit 0;;
esac
exit 0
X
  chmod +x "$SP_D/pmset" "$SP_D/claude" "$SP_D/gh"
}

# sp_issue <num> <repo> <label>...
sp_issue() {
  local n=$1 r=$2; shift 2
  jq --argjson n "$n" --arg r "$r" --argjson l "$(printf '%s\n' "$@" | jq -R . | jq -sc 'map({name:.})')" \
    '. + [{number:$n,repo:$r,title:"fixture",labels:$l}]' "$SP_D/issues.json" > "$SP_D/i.tmp" && mv "$SP_D/i.tmp" "$SP_D/issues.json"
}
# sp_comment <num> <body>
sp_comment() {
  jq --argjson n "$1" --arg b "$2" '. + [{number:$n,body:$b,createdAt:"2026-01-01T00:00:00Z"}]' "$SP_D/comments.json" > "$SP_D/c.tmp" && mv "$SP_D/c.tmp" "$SP_D/comments.json"
}
sp_tick() { HOME="$SP_HOME" PATH="$SP_D:/usr/bin:/bin" PIPE="$SP_PIPE" QUEUE="$SP_PIPE/queue" LOGDIR="$SP_HOME/logs/pipeline" \
  SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" /bin/bash "$SUP_SP" >/dev/null 2>&1
  # poll (max ~15 s) until the detached stub claude has exited, instead of a fixed sleep
  local i; for i in $(seq 1 150); do pgrep -f "$SP_D/claude" >/dev/null 2>&1 || break; sleep 0.1; done; sleep 0.2; }
sp_pm_launches() { grep -c -- '--agent product-manager' "$SP_D/claude.log"; }
sp_labels() { jq -r --argjson n "$1" '.[]|select(.number==$n)|[.labels[].name]|sort|join(",")' "$SP_D/issues.json"; }
sp_edits_with() { grep '^issue edit' "$SP_D/gh-calls.log" | grep -c -- "$1"; }
sp_cleanup() { cleanup_running; rm -rf "$SP_PIPE" "$SP_HOME"; }

# ------------------------------------------------------------------------------------------------ AC1 step A

test_sp_ac1_launches_pm_once_with_env_claim_and_prompt_guards() {
  sp_env; touch "$SP_D/claude-mode-ready"; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec
  sp_tick
  local n log calls labels1; n=$(sp_pm_launches); log=$(cat "$SP_D/claude.log"); calls=$(cat "$SP_D/gh-calls.log"); labels1=$(sp_labels 7)
  sp_cleanup
  assert_eq "$n" "1" "AC1: first tick launches the product-manager once" || return 1
  assert_contains "$log" "ISSUE=7 AGENT=product-manager REPO=project-a/repo-a" "AC1: PIPELINE_ISSUE/AGENT/REPO exported for the handoff hook" || return 1
  assert_contains "$calls" "issue comment 7" "AC1: claim comment posted before launch" || return 1
  assert_contains "$calls" "claim:" "AC1: claim uses the existing claim-comment format" || return 1
  assert_contains "$log" "do not add agent-go" "AC1: launch prompt forbids agent-go (no Parent: line on idea issues)" || return 1
  assert_contains "$log" "do not file dependency follow-ups" "AC1: launch prompt forbids dependency follow-ups" || return 1
  case "$labels1" in
    *agent-in-progress*|"agent-proposed,user-feedback") ;;   # swapped in at launch, or already finished by a fast stub exit
    *) fail "AC1: after launch #7 carries agent-in-progress (got [$labels1])"; return 1 ;;
  esac
}

test_sp_ac1_after_pm_ready_labels_become_agent_proposed_and_never_agent_go() {
  sp_env; touch "$SP_D/claude-mode-ready"; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec
  sp_tick; sp_tick
  local labels n edits_go orch_pid orch_log; labels=$(sp_labels 7); n=$(sp_pm_launches)
  edits_go=$(sp_edits_with 'agent-go'); orch_pid=$(ls "$SP_PIPE" | grep -c '^orch-7\.pid$'); orch_log=$(grep -c -- '--agent orchestrator' "$SP_D/claude.log")
  sp_tick; local n3; n3=$(sp_pm_launches); local labels3; labels3=$(sp_labels 7)
  sp_cleanup
  assert_eq "$labels" "agent-proposed,user-feedback" "AC1: after the PM's READY marker: agent-in-progress and user-feedback-needs-spec removed, agent-proposed added" || return 1
  assert_eq "$n" "1" "AC1: the PM ran once" || return 1
  assert_eq "$n3" "1" "AC1: a further tick launches nothing" || return 1
  assert_eq "$labels3" "agent-proposed,user-feedback" "AC1: labels stable on the third tick" || return 1
  assert_eq "$edits_go" "0" "AC1: no issue edit ever mentions agent-go" || return 1
  assert_eq "$orch_pid" "0" "AC1: no orchestrator run state (orch-7.pid) is created" || return 1
  assert_eq "$orch_log" "0" "AC1: the orchestrator is never launched" || return 1
}

test_sp_ac1_agent_go_alongside_needs_spec_is_left_to_the_orchestrator_path() {
  sp_env; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec agent-go; sp_issue 8 project-a/repo-a user-feedback user-feedback-needs-spec
  sp_tick; local n labels log; n=$(sp_pm_launches); labels=$(sp_labels 7); log=$(cat "$SP_D/claude.log"); sp_cleanup
  assert_eq "$n" "1" "AC1: exactly one launch (the control #8)" || return 1
  assert_contains "$log" "ISSUE=8 AGENT=product-manager" "AC1: control #8 launched" || return 1
  assert_not_contains "$log" "ISSUE=7" "AC1: needs-spec + agent-go (#7) is not launched by step A" || return 1
  assert_not_contains ",$labels," ",agent-proposed," "AC1: step A does not stamp it" || return 1
}

test_sp_ac1_issues_without_the_needs_spec_label_are_not_launched() {
  sp_env; sp_issue 7 project-a/repo-a; sp_issue 8 project-a/repo-a user-feedback
  sp_issue 10 project-a/repo-a user-feedback user-feedback-needs-spec   # positive control
  sp_tick; local n log; n=$(sp_pm_launches); log=$(cat "$SP_D/claude.log"); local l7 l8; l7=$(sp_labels 7); l8=$(sp_labels 8); sp_cleanup
  assert_eq "$n" "1" "AC1: exactly one launch (the control #10)" || return 1
  assert_contains "$log" "ISSUE=10 AGENT=product-manager" "AC1: control #10 launched" || return 1
  assert_not_contains "$log" "ISSUE=7 " "AC1: unlabelled #7 not launched" || return 1
  assert_not_contains "$log" "ISSUE=8 " "AC1: user-feedback-only #8 not launched" || return 1
  assert_eq "$l7" "" "AC1: #7 untouched" || return 1
  assert_eq "$l8" "user-feedback" "AC1: #8 untouched" || return 1
}

test_sp_ac1_in_progress_needs_spec_issue_not_relaunched() {
  sp_env; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec agent-in-progress; sp_issue 8 project-a/repo-a user-feedback user-feedback-needs-spec
  sp_tick; local n log; n=$(sp_pm_launches); log=$(cat "$SP_D/claude.log"); sp_cleanup
  assert_eq "$n" "1" "AC1: only the eligible issue launches (positive control #8)" || return 1
  assert_contains "$log" "ISSUE=8 AGENT=product-manager" "AC1: control #8 launched" || return 1
  assert_not_contains "$log" "ISSUE=7" "AC1: needs-spec + agent-in-progress (#7) is not launched" || return 1
}

test_sp_ac1_repo_outside_dispatch_repos_is_skipped() {
  sp_env; sp_issue 8 project-b/repo-b user-feedback user-feedback-needs-spec; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec
  sp_tick; local n log l8; n=$(sp_pm_launches); log=$(cat "$SP_D/claude.log"); l8=$(sp_labels 8); sp_cleanup
  assert_eq "$n" "1" "AC1/E: exactly one launch (the dispatched repo's #7 — positive control)" || return 1
  assert_not_contains "$log" "project-b/repo-b" "AC1/E: a repo missing from DISPATCH_REPOS is never launched (quoting tool on the VM)" || return 1
  assert_eq "$l8" "user-feedback,user-feedback-needs-spec" "AC1/E: its labels are untouched" || return 1
}

test_sp_ac1_existing_pm_marker_blocks_relaunch() {
  local m
  for m in '**[product-manager] READY FOR ENGINEERING**' '**[product-manager] READY FOR ARCHITECTURE**' '**[product-manager] BLOCKED**'; do
    sp_env; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec; sp_issue 8 project-a/repo-a user-feedback user-feedback-needs-spec
    sp_comment 7 "$m"$'\nUI change: no\nLane: full'
    sp_tick; local n log; n=$(sp_pm_launches); log=$(cat "$SP_D/claude.log"); sp_cleanup
    assert_eq "$n" "1" "AC1: with [$m] on #7 only the control #8 launches" || return 1
    assert_not_contains "$log" "ISSUE=7" "AC1: an existing [product-manager] routing marker => no relaunch ([$m])" || return 1
  done
}

test_sp_ac1_pm_note_without_routing_marker_does_not_block() {
  sp_env; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec
  sp_comment 7 $'**[product-manager] NOTE**\nnot a routing marker'
  sp_tick; local n; n=$(sp_pm_launches); sp_cleanup
  assert_eq "$n" "1" "AC1: only a routing marker counts — a PM NOTE does not stop the spec run" || return 1
}

test_sp_ac1_step_a_block_is_small_and_labelled() {
  local blk; blk=$(awk '/^# 3c\. Spec/ {p=1} p {print} p && /^$/ {exit}' "$SUP_SP")
  assert_ne "$blk" "" "AC1: supervisor.sh carries a block headed '# 3c. Spec' (guard contract)" || return 1
  local n; n=$(printf '%s\n' "$blk" | grep -c .)
  assert_le "$n" "60" "AC1: step A is ~50 lines (got $n)" || return 1
  assert_contains "$(head -20 "$SUP_SP")" "#   3c. spec: " "AC1: file-header step list names 3c (guard contract)" || return 1
  assert_not_contains "$blk" "orchestrate.sh" "AC1: step A never starts an orchestrator" || return 1
  assert_not_contains "$blk" "--add-label \"\$LABEL_GO\"" "AC1: step A never adds agent-go" || return 1
}

# ------------------------------------------------------------------------------------------------ AC1 (amended 2026-10-08): REJECTED needs-spec

# A REJECTED marker is not a "PM marker already present" for step A; two needs-spec REJECTEDs stop the loop.
test_sp_ac1_single_needs_spec_rejected_is_not_a_pm_marker_so_pm_runs_once() {
  local who
  for who in product-manager fullstack-developer; do
    sp_env; touch "$SP_D/claude-mode-ready"; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec
    sp_comment 7 "**[$who] REJECTED**"$'\nReason: needs-spec'
    sp_tick; sp_tick; local n log labels; n=$(sp_pm_launches); log=$(cat "$SP_D/claude.log"); labels=$(sp_labels 7); sp_cleanup
    assert_eq "$n" "1" "AC1: one needs-spec REJECTED [$who] only => step A launches the PM once" || return 1
    assert_contains "$log" "ISSUE=7 AGENT=product-manager" "AC1: the PM is launched on #7 ([$who] REJECTED)" || return 1
    assert_eq "$labels" "agent-proposed,user-feedback" "AC1: after the PM's READY, labels become agent-proposed only ([$who])" || return 1
  done
}

test_sp_ac1_two_needs_spec_rejected_markers_skip_step_a() {
  local pair a b
  for pair in "product-manager fullstack-developer" "fullstack-developer fullstack-developer" "product-manager product-manager"; do
    set -- $pair; a=$1; b=$2
    sp_env; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec; sp_issue 8 project-a/repo-a user-feedback user-feedback-needs-spec
    sp_comment 7 "**[$a] REJECTED**"$'\nReason: needs-spec'; sp_comment 7 "**[$b] REJECTED**"$'\nReason: needs-spec'
    sp_tick; local n log l7; n=$(sp_pm_launches); log=$(cat "$SP_D/claude.log"); l7=$(sp_labels 7); sp_cleanup
    assert_eq "$n" "1" "AC1: with two needs-spec REJECTEDs ($a, $b) on #7 only the control #8 launches" || return 1
    assert_not_contains "$log" "ISSUE=7" "AC1: two REJECTED needs-spec => step A skips (no re-reject loop) ($a, $b)" || return 1
    assert_eq "$l7" "user-feedback,user-feedback-needs-spec" "AC1: #7 labels untouched ($a, $b)" || return 1
  done
}

test_sp_ac1_needs_spec_rejected_plus_other_pm_marker_still_blocks() {
  sp_env; sp_issue 7 project-a/repo-a user-feedback user-feedback-needs-spec; sp_issue 8 project-a/repo-a user-feedback user-feedback-needs-spec
  sp_comment 7 $'**[product-manager] REJECTED**\nReason: needs-spec'; sp_comment 7 $'**[product-manager] READY FOR ENGINEERING**\nUI change: no\nLane: full'
  sp_tick; local n log; n=$(sp_pm_launches); log=$(cat "$SP_D/claude.log"); sp_cleanup
  assert_eq "$n" "1" "AC1: REJECTED + a PM READY marker on #7 => only control #8 launches" || return 1
  assert_not_contains "$log" "ISSUE=7" "AC1: any other PM routing marker still blocks step A" || return 1
}

# ------------------------------------------------------------------------------------------------ AC3 REJECTED done state

# sp_rejected <repo-label-json> <comment body> — issue 42, exited orchestrator, .start 1300 s old (past the BLOCKED grace)
sp_rejected() {
  sp_env
  mk_restarting "$SP_PIPE" 42 "$SP_PIPE/repo-a"
  python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=1300)).strftime('%Y-%m-%dT%H:%M:%SZ'))" > "$SP_PIPE/orch-42.start"
  echo "project-a/repo-a" > "$SP_D/gh-name-with-owner"
  SP_LBL="$1"; shift
  local labels; labels=$(printf '%s\n' $SP_LBL | jq -R . | jq -sc 'map({name:.})')
  jq -n --argjson l "$labels" '[{number:42,repo:"project-a/repo-a",title:"fixture",labels:$l}]' > "$SP_D/issues.json"
  sp_comment 42 "$1"
}
sp_present() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
sp_slog() { cat "$SP_HOME/logs/pipeline/supervisor.log" 2>/dev/null; }

sp_assert_done() {  # after a tick: .done, no .alert/.held, no restart
  local done_ alert held log; done_=$(sp_present "$SP_PIPE/orch-42.done"); alert=$(sp_present "$SP_PIPE/orch-42.alert"); held=$(sp_present "$SP_PIPE/orch-42.held"); log=$(sp_slog)
  sp_cleanup
  assert_eq "$done_" "present" "$1: run marked done" || return 1
  assert_eq "$alert" "absent" "$1: no .alert file (no alert to JP)" || return 1
  assert_eq "$held" "absent" "$1: not held" || return 1
  assert_contains "$log" "[done] #42" "$1: [done] logged" || return 1
  assert_not_contains "$log" "[queue-restart] #42" "$1: no restart" || return 1
  assert_not_contains "$log" "[held] #42" "$1: no [held] line" || return 1
}

sp_assert_inert() {  # after a tick: REJECTED changed nothing — not done, not held, no alert; normal restart path
  local done_ alert held log; done_=$(sp_present "$SP_PIPE/orch-42.done"); alert=$(sp_present "$SP_PIPE/orch-42.alert"); held=$(sp_present "$SP_PIPE/orch-42.held"); log=$(sp_slog)
  sp_cleanup
  assert_eq "$done_" "absent" "$1: not marked done" || return 1
  assert_eq "$alert" "absent" "$1: no alert" || return 1
  assert_eq "$held" "absent" "$1: not held" || return 1
  assert_not_contains "$log" "[done] #42" "$1: no [done]" || return 1
  assert_contains "$log" "[queue-restart] #42" "$1: routing unchanged — the normal restart path" || return 1
}


# sp_pos_control — the same marker on a user-feedback issue from an allowed author IS done: keeps every inert case non-vacuous
sp_pos_control() {
  sp_rejected "user-feedback bug fast-lane" "**[product-manager] REJECTED**"$'\nReason: not-a-bug'
  sp_tick
  sp_assert_done "positive control (user-feedback + product-manager + not-a-bug)" || return 1
}

# one test per author x reason (generated), so a failure names the case
sp_terminal_case() {  # <who> <reason>
  sp_rejected "user-feedback bug fast-lane" "**[$1] REJECTED**"$'\n'"Reason: $2"
  sp_tick
  sp_assert_done "AC3 [$1] Reason: $2" || return 1
}
for sp_who in product-manager fullstack-developer; do
  for sp_reason in 'not-a-bug' 'cannot-reproduce' 'duplicate of #12' 'needs-spec'; do
    sp_slug=$(printf '%s' "$sp_reason" | tr -c 'a-z0-9\n' '_')
    eval "test_sp_ac3_terminal_${sp_who//-/_}_${sp_slug}_is_done_without_alert() { sp_terminal_case '$sp_who' '$sp_reason'; }"
  done
done

test_sp_ac3_rejected_without_user_feedback_label_is_inert() {
  sp_pos_control || return 1
  local who
  for who in product-manager fullstack-developer; do
    sp_rejected "bug fast-lane agent-go" "**[$who] REJECTED**"$'\nReason: not-a-bug'
    sp_tick
    sp_assert_inert "AC3 no user-feedback label [$who]" || return 1
  done
}

test_sp_ac3_rejected_from_a_disallowed_agent_is_inert() {
  sp_pos_control || return 1
  local who
  for who in code-reviewer test-reviewer deployer intake; do
    sp_rejected "user-feedback bug fast-lane" "**[$who] REJECTED**"$'\nReason: not-a-bug'
    sp_tick
    sp_assert_inert "AC3 disallowed author [$who]" || return 1
  done
}

test_sp_ac3_unknown_reason_is_inert_and_logged() {
  sp_pos_control || return 1
  local reason log
  for reason in 'bogus' 'duplicate of' 'duplicate of #' 'Not-A-Bug' ''; do
    sp_rejected "user-feedback bug fast-lane" "**[product-manager] REJECTED**"$'\n'"Reason: $reason"
    sp_tick
    log=$(sp_slog)
    sp_assert_inert "AC3 Reason: [$reason]" || return 1
    printf '%s\n' "$log" | grep -E 'REJECTED' | grep -qiE 'inert|ignored|unknown|unrecogni' \
      || { fail "AC3: supervisor.log must record that the REJECTED marker (Reason: [$reason]) was treated as inert; log:
$log"; return 1; }
  done
}

test_sp_ac3_rejected_without_reason_line_is_inert() {
  sp_pos_control || return 1
  sp_rejected "user-feedback bug fast-lane" "**[product-manager] REJECTED**"
  sp_tick
  sp_assert_inert "AC3 no Reason line" || return 1
}

for t in $(declare -F | awk '{print $3}' | grep '^test_sp_'); do run_test "$t"; done
