# #320 item 6 — scan-backlog.sh gives agent-go (not agent-proposed) to an unlabelled ticket that carries the label of an
# APPROVED goal. Same exclusions as the go machinery: never Business-Intelligence, never source:sentry, never a ticket whose
# go was already granted once (the registry's `granted` list is the loop guard); an unapproved, stopped or unreadable goal
# gives agent-proposed as before. Expected values are hand-written from the ticket.
# gh stub: `api` answers the registry list from reg-open.json / reg-closed.json (or fails); `issue list` applies the caller's --jq
# to the repo's fixture; `issue edit` is only logged.

HERE_SL=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# sl_goal <id> <label> <go true|false> <state active|queued|stopped> <repos json> <granted json> -> a registry issue (json)
sl_goal() {
  local id=$1 label=$2 go=$3 st=$4 repos=$5 granted=$6 block labels='["delivery-goal"]' state=open n
  n=$((100 + ${#id}))
  block=$(jq -nc --arg id "$id" --arg label "$label" --argjson go "$go" --argjson repos "$repos" --argjson granted "$granted" \
    '{v:2,id:$id,title:$label,label:$label,repos:$repos,order:1,go:$go,granted:$granted,host:"",host_pref:"",spec:("label:" + $label),instructions:""}')
  case "$st" in
    queued)  labels='["delivery-goal","goal-queued"]' ;;
    stopped) labels='["delivery-goal","goal-stopped"]'; state=closed ;;
  esac
  jq -nc --argjson n "$n" --arg body "$(printf 'Goal: %s\n\n```json\n%s\n```\n' "$label" "$block")" --argjson labels "$labels" --arg state "$state" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{number:$n, title:"Goal", body:$body, state:$state, labels:($labels|map({name:.})), created_at:$now, updated_at:$now,
      closed_at:(if $state == "closed" then $now else null end)}'
}

# sl_run <registry mode ok|fail> — runs scan-backlog.sh over repos o/a (dispatch) and o/Business-Intelligence (scan only); prints the gh log
sl_run() {
  local home log
  home=$(new_home); log="$home/gh.log"; : > "$log"; mkdir -p "$home/bin"
  local open closed
  open=$(jq -sc '.' <(sl_goal g-alpha "goal: Alpha" true active '["o/a","o/Business-Intelligence"]' '[]') \
                    <(sl_goal g-beta "goal: Beta" false active '["o/a"]' '[]') \
                    <(sl_goal g-delta "goal: Delta" true active '["o/a"]' '["o/a#14"]') \
                    <(sl_goal g-epsilon "goal: Epsilon" true queued '["o/a"]' '[]'))
  closed=$(jq -sc '.' <(sl_goal g-gamma "goal: Gamma" true stopped '["o/a"]' '[]'))
  printf '%s' "$open" > "$home/reg-open.json"; printf '%s' "$closed" > "$home/reg-closed.json"
  cat > "$home/o_a.json" <<'JSON'
[{"number":10,"title":"alpha ticket","labels":[{"name":"goal: Alpha"}]},
 {"number":11,"title":"beta ticket","labels":[{"name":"goal: Beta"}]},
 {"number":12,"title":"gamma ticket","labels":[{"name":"goal: Gamma"}]},
 {"number":13,"title":"sentry alpha","labels":[{"name":"goal: Alpha"},{"name":"source:sentry"}]},
 {"number":14,"title":"delta go removed","labels":[{"name":"goal: Delta"}]},
 {"number":15,"title":"no goal","labels":[]},
 {"number":16,"title":"queued goal ticket","labels":[{"name":"goal: Epsilon"}]},
 {"number":17,"title":"alpha already proposed","labels":[{"name":"goal: Alpha"},{"name":"agent-proposed"}]}]
JSON
  cat > "$home/o_Business-Intelligence.json" <<'JSON'
[{"number":20,"title":"bi alpha","labels":[{"name":"goal: Alpha"}]}]
JSON
  cat > "$home/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
if [ "$1" = "api" ]; then
  [ "$REG_MODE" = fail ] && { echo "gh: HTTP 502" >&2; exit 1; }
  case "$*" in
    *state=open*) cat "$HOME/reg-open.json" ;;
    *state=closed*) cat "$HOME/reg-closed.json" ;;
    *) echo '[]' ;;
  esac
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  case "$*" in *--search*) exit 0 ;; esac
  expr=""; repo=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && expr=$a; [ "$prev" = "--repo" ] && repo=$a; prev=$a; done
  jq -r "$expr" "$HOME/$(printf '%s' "$repo" | tr '/' '_').json"
fi
exit 0
STUB
  chmod +x "$home/bin/gh"
  printf 'SCAN_BACKLOG=1\nDISPATCH_REPOS=("o/a:/tmp/a")\nSCAN_ONLY_REPOS=("o/Business-Intelligence")\nGOAL_REGISTRY_REPO=o/registry\n' > "$home/.claude/pipeline/config.local.sh"
  HOME="$home" GH_LOG="$log" REG_MODE="$1" PATH="$home/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" /bin/bash "$HERE_SL/../scan-backlog.sh" >/dev/null 2>&1
  grep '^issue edit ' "$log"; rm -rf "$home"
}

sl_label_of() {  # <edit log> <repo> <issue> -> the label added ("none" when the ticket was not edited)
  local l; l=$(printf '%s\n' "$1" | grep "^issue edit $3 --repo $2 " | head -1)
  case "$l" in *"--add-label agent-go"*) echo agent-go ;; *"--add-label agent-proposed"*) echo agent-proposed ;; *) echo none ;; esac
}

test_sl_approved_goal_ticket_gets_agent_go() {
  local e; e=$(sl_run ok)
  assert_eq "$(sl_label_of "$e" o/a 10)" "agent-go" "approved goal label -> agent-go" || return 1
  assert_eq "$(sl_label_of "$e" o/a 16)" "agent-go" "a queued (approved) goal's ticket also gets agent-go" || return 1
}
test_sl_unapproved_or_stopped_goal_label_gets_agent_proposed() {
  local e; e=$(sl_run ok)
  assert_eq "$(sl_label_of "$e" o/a 11)" "agent-proposed" "go:false goal -> agent-proposed" || return 1
  assert_eq "$(sl_label_of "$e" o/a 12)" "agent-proposed" "stopped goal -> agent-proposed" || return 1
  assert_eq "$(sl_label_of "$e" o/a 15)" "agent-proposed" "no goal label -> agent-proposed (unchanged)" || return 1
}
test_sl_exclusions_and_loop_guard() {
  local e; e=$(sl_run ok)
  assert_eq "$(sl_label_of "$e" o/a 13)" "agent-proposed" "source:sentry never gets the goal go" || return 1
  assert_eq "$(sl_label_of "$e" o/a 14)" "agent-proposed" "a go granted once and removed is never re-added" || return 1
  assert_eq "$(sl_label_of "$e" o/Business-Intelligence 20)" "agent-proposed" "Business-Intelligence never gets agent-go from a goal" || return 1
  assert_eq "$(sl_label_of "$e" o/a 17)" "none" "an already proposed ticket is not touched" || return 1
}
test_sl_unreadable_registry_fails_closed() {
  local e; e=$(sl_run fail)
  assert_eq "$(sl_label_of "$e" o/a 10)" "agent-proposed" "registry unreadable -> no goal is approved -> agent-proposed" || return 1
}

echo "-- scan-backlog approved goal go (#320)"
run_test test_sl_approved_goal_ticket_gets_agent_go
run_test test_sl_unapproved_or_stopped_goal_label_gets_agent_proposed
run_test test_sl_exclusions_and_loop_guard
run_test test_sl_unreadable_registry_fails_closed
