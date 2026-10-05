# Issue #114 — AC2 + the no-marker recovery fixture: supervisor.sh launches the `intake` agent for
# `user-feedback-intake` issues. Whole ticks run in an isolated HOME/PIPE with stubbed `gh`, `claude`, `pmset`.
# Stub gh keeps issue state in $D/issues.json ([{number,repo,labels:[{name}]}]) and comments in $D/comments.json,
# applies --label / --jq like the real CLI, honours `issue edit --add-label/--remove-label`, logs every call to
# $D/gh-calls.log. Stub claude logs "<argv> | ISSUE=.. AGENT=.. REPO=.." to $D/claude.log and exits 0 (CLAUDE_MODE=marker
# first posts a `**[intake] TRIAGED BUG**` comment, as a healthy run would). Placeholder repo names only.

HERE_SI=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SUP_SI="$HERE_SI/../supervisor.sh"

# si_env [<DISPATCH entries...>] — sets SI_D (stub dir), SI_HOME, SI_PIPE; default dispatch = project-a/repo-a
si_env() {
  SI_PIPE=$(new_pipe); SI_HOME=$(new_home); SI_D="$SI_HOME/.local/bin"; mkdir -p "$SI_D"
  fixture_repo "$SI_PIPE/repo-a" "project-a/repo-a"; fixture_repo "$SI_PIPE/repo-b" "project-b/repo-b"
  echo '[]' > "$SI_D/issues.json"; echo '[]' > "$SI_D/comments.json"; : > "$SI_D/gh-calls.log"; : > "$SI_D/claude.log"
  local d=("project-a/repo-a:$SI_PIPE/repo-a"); [ $# -gt 0 ] && d=("$@")
  { echo 'MEM_FLOOR_MB=0'; echo 'CLAIM_SETTLE_SECS=0'; printf 'DISPATCH_REPOS=('; printf '"%s" ' "${d[@]}"; echo ')'; } > "$SI_HOME/.claude/pipeline/config.local.sh"
  cat > "$SI_D/pmset" <<'X'
#!/bin/bash
echo "Now drawing from 'AC Power'"
X
  cat > "$SI_D/claude" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$* | ISSUE=${PIPELINE_ISSUE:-} AGENT=${PIPELINE_AGENT:-} REPO=${PIPELINE_REPO:-}" >> "$D/claude.log"
if [ "${CLAUDE_MODE:-}" = marker ] || [ -f "$D/claude-mode-marker" ]; then
  jq --arg b $'**[intake] TRIAGED BUG**\nok' '. + [{body:$b,createdAt:"2099-01-01T00:00:00Z"}]' "$D/comments.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/comments.json"
fi
exit 0
X
  cat > "$SI_D/gh" <<'X'
#!/bin/bash
D="$(cd "$(dirname "$0")" && pwd)"
echo "$*" >> "$D/gh-calls.log"
jqx=""; label=""; repo=""; prev=""; addl=""; reml=""; body=""
for a in "$@"; do
  case "$prev" in --jq|-q) jqx=$a;; --label) label=$a;; --repo) repo=$a;; --add-label) addl=$a;; --remove-label) reml=$a;; --body) body=$a;; esac; prev=$a
done
out() { if [ -n "$jqx" ]; then printf '%s' "$1" | jq -r "$jqx"; else printf '%s\n' "$1"; fi; }
num=$(printf '%s' "$3" | grep -E '^[0-9]+$')
case "$1 $2" in
  "repo view") echo "${repo:-project-a/repo-a}"; exit 0;;
  "issue list")
    r=${repo:-$(cd "$PWD" && git config --get remote.origin.url | sed -E 's#.*github.com/(.*)\.git#\1#')}
    j=$(jq -c --arg r "$r" --arg l "$label" '[.[] | select(.repo==$r) | select($l=="" or ([.labels[].name]|index($l)))]' "$D/issues.json")
    out "$j"; exit 0;;
  "issue comment") now=$(date -u +%FT%TZ)
    jq --arg b "$body" --arg t "$now" '. + [{body:$b,createdAt:$t}]' "$D/comments.json" > "$D/c.tmp" && mv "$D/c.tmp" "$D/comments.json"; exit 0;;
  "issue edit")
    jq --argjson n "${num:-0}" --arg a "$addl" --arg r "$reml" '
      map(if .number==$n then .labels = ((.labels|map(.name)) - ($r|split(",")) + ($a|split(",")|map(select(.!=""))) | unique | map({name:.})) else . end)' \
      "$D/issues.json" > "$D/i.tmp" && mv "$D/i.tmp" "$D/issues.json"; exit 0;;
  "issue view") out "$(jq -c '{state:"OPEN",title:"t",comments:.}' "$D/comments.json")"; exit 0;;
esac
exit 0
X
  chmod +x "$SI_D/pmset" "$SI_D/claude" "$SI_D/gh"
}

# si_issue <num> <repo> <label>...
si_issue() {
  local n=$1 r=$2; shift 2
  jq --argjson n "$n" --arg r "$r" --argjson l "$(printf '%s\n' "$@" | jq -R . | jq -sc 'map({name:.})')" \
    '. + [{number:$n,repo:$r,labels:$l}]' "$SI_D/issues.json" > "$SI_D/i.tmp" && mv "$SI_D/i.tmp" "$SI_D/issues.json"
}
si_tick() { HOME="$SI_HOME" PATH="$SI_D:/usr/bin:/bin" PIPE="$SI_PIPE" QUEUE="$SI_PIPE/queue" LOGDIR="$SI_HOME/logs/pipeline" \
  SLACK_BOT_TOKEN="" SLACK_ENGINEERING_CHANNEL="" /bin/bash "$SUP_SI" >/dev/null 2>&1; sleep 1.5; }
si_launches() { grep -c -- '--agent intake' "$SI_D/claude.log"; }
si_labels() { jq -r --argjson n "$1" '.[]|select(.number==$n)|[.labels[].name]|sort|join(",")' "$SI_D/issues.json"; }
si_cleanup() { cleanup_running; rm -rf "$SI_PIPE" "$SI_HOME"; }

test_si_ac2_launches_once_with_env_claim_and_label_swap() {
  si_env; si_issue 7 project-a/repo-a user-feedback-intake
  si_tick
  local n log labels calls before; n=$(si_launches); log=$(cat "$SI_D/claude.log"); labels=$(si_labels 7); calls=$(cat "$SI_D/gh-calls.log")
  before=$(cat "$SI_PIPE/7-intake-before.txt" 2>/dev/null)
  si_tick; local n2; n2=$(si_launches)
  si_cleanup
  assert_eq "$n" "1" "AC2: first tick launches intake once" || return 1
  assert_contains "$log" "ISSUE=7 AGENT=intake REPO=project-a/repo-a" "AC2: PIPELINE_ISSUE/AGENT/REPO exported for the handoff hook" || return 1
  assert_contains "$calls" "issue comment 7" "AC2: claim comment posted before launch" || return 1
  assert_contains "$calls" "claim:" "AC2: claim comment uses the existing claim format" || return 1
  assert_eq "$labels" "agent-in-progress" "AC2: user-feedback-intake swapped for agent-in-progress" || return 1
  assert_eq "$before" "0" "AC2: hook before-count file written (0) so the handoff hook applies" || return 1
  assert_eq "$n2" "1" "AC2: second tick does not launch again" || return 1
}

test_si_ac2_in_progress_issue_not_launched() {
  si_env; si_issue 7 project-a/repo-a user-feedback-intake agent-in-progress; si_issue 8 project-a/repo-a user-feedback-intake
  si_tick; local n log; n=$(si_launches); log=$(cat "$SI_D/claude.log"); si_cleanup
  assert_eq "$n" "1" "AC2: only the eligible issue launches (positive control #8)" || return 1
  assert_contains "$log" "ISSUE=8 AGENT=intake" "AC2: control #8 launched" || return 1
  assert_not_contains "$log" "ISSUE=7" "AC2: user-feedback-intake + agent-in-progress (#7) is not launched" || return 1
}

test_si_ac2_repo_not_in_dispatch_repos_not_launched() {
  si_env; si_issue 8 project-b/repo-b user-feedback-intake; si_issue 7 project-a/repo-a user-feedback-intake   # models the VM: only repo-a is dispatched here
  si_tick; local n labels log; n=$(si_launches); labels=$(si_labels 8); log=$(cat "$SI_D/claude.log"); si_cleanup
  assert_eq "$n" "1" "AC2: exactly one launch (the dispatched repo's #7 — positive control)" || return 1
  assert_not_contains "$log" "project-b/repo-b" "AC2: repo outside DISPATCH_REPOS is never launched" || return 1
  assert_eq "$labels" "user-feedback-intake" "AC2: its labels are untouched" || return 1
}

test_si_ac2_business_intelligence_never_eligible() {
  si_env "project-a/repo-a:$SI_PIPE/repo-a" "project-c/Business-Intelligence:$SI_PIPE/repo-b"
  si_issue 9 project-c/Business-Intelligence user-feedback-intake; si_issue 7 project-a/repo-a user-feedback-intake
  si_tick; local n log; n=$(si_launches); log=$(cat "$SI_D/claude.log"); si_cleanup
  assert_eq "$n" "1" "AC2: exactly one launch (#7 — positive control)" || return 1
  assert_not_contains "$log" "Business-Intelligence" "AC2: Business-Intelligence is never eligible even if listed" || return 1
}

test_si_ac2_one_per_tick() {
  si_env; si_issue 7 project-a/repo-a user-feedback-intake; si_issue 8 project-a/repo-a user-feedback-intake
  si_tick; local n1; n1=$(si_launches)
  si_tick; local n2; n2=$(si_launches)
  si_cleanup
  assert_eq "$n1" "1" "AC2: one intake launch per tick" || return 1
  assert_eq "$n2" "2" "AC2: the next tick launches the other" || return 1
}

test_si_ac2_counts_against_max_concurrent() {
  si_env; echo 'MAX_CONCURRENT=1' >> "$SI_HOME/.claude/pipeline/config.local.sh"
  mk_running "$SI_PIPE" 1 "$SI_PIPE/repo-a"
  si_issue 7 project-a/repo-a user-feedback-intake
  si_tick; local n_full labels_full; n_full=$(si_launches); labels_full=$(si_labels 7)
  # positive control in the same test: free the slot, the same issue must now launch
  cleanup_running; rm -f "$SI_PIPE"/orch-1.*; si_tick
  local n_free; n_free=$(si_launches); si_cleanup
  assert_eq "$n_full" "0" "AC2: no launch when MAX_CONCURRENT slots are full" || return 1
  assert_eq "$labels_full" "user-feedback-intake" "AC2: issue stays queued for intake (label kept)" || return 1
  assert_eq "$n_free" "1" "AC2: with a free slot the same issue launches" || return 1
}

test_si_ac2_in_progress_cleared_when_run_exits() {
  si_env; touch "$SI_D/claude-mode-marker"; si_issue 7 project-a/repo-a user-feedback-intake
  si_tick; si_tick
  local labels n calls; labels=$(si_labels 7); n=$(si_launches); calls=$(cat "$SI_D/gh-calls.log")
  si_cleanup
  assert_eq "$n" "1" "AC2: healthy run (marker posted) is not relaunched" || return 1
  assert_contains "$calls" "--remove-label agent-in-progress" "AC2: agent-in-progress removed after the run exits" || return 1
  assert_not_contains "$labels" "agent-in-progress" "AC2: label gone from the issue" || return 1
}

test_si_no_marker_run_gets_one_recovery_then_note_and_no_loop() {
  si_env; si_issue 7 project-a/repo-a user-feedback-intake     # stub claude exits without any [intake] marker
  local i; for i in 1 2 3 4 5 6; do si_tick; done
  local n_mid notes; n_mid=$(si_launches)
  for i in 1 2 3 4; do si_tick; done
  local n_end readds; n_end=$(si_launches)
  notes=$(jq -r '.[].body | select(startswith("**[supervisor] NOTE**") and (contains("claim:")|not))' "$SI_D/comments.json" | grep -c .)
  readds=$(grep -c -- '--add-label user-feedback-intake' "$SI_D/gh-calls.log")
  si_cleanup
  [ "$n_mid" -ge 2 ] || { fail "recovery: expected >=2 launches (original + one recovery), got $n_mid"; return 1; }
  [ "$n_end" -le 4 ] || { fail "recovery: relaunch loop — $n_end launches"; return 1; }
  assert_eq "$n_end" "$n_mid" "recovery: launches stop growing after the NOTE (no infinite relaunch)" || return 1
  assert_eq "$notes" "1" "recovery: exactly one [supervisor] NOTE after the second failure" || return 1
  [ "$readds" -le 1 ] || { fail "recovery: user-feedback-intake re-added $readds times (max once)"; return 1; }
}

run_test test_si_ac2_launches_once_with_env_claim_and_label_swap
run_test test_si_ac2_in_progress_issue_not_launched
run_test test_si_ac2_repo_not_in_dispatch_repos_not_launched
run_test test_si_ac2_business_intelligence_never_eligible
run_test test_si_ac2_one_per_tick
run_test test_si_ac2_counts_against_max_concurrent
run_test test_si_ac2_in_progress_cleared_when_run_exits
run_test test_si_no_marker_run_gets_one_recovery_then_note_and_no_loop
