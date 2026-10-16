#!/usr/bin/env bash
# Hourly backlog scan: label unseen open issues `agent-proposed` and post a digest to Slack.
# Runs only where config.local.sh sets SCAN_BACKLOG=1 (one machine), over that machine's DISPATCH_REPOS
# plus SCAN_ONLY_REPOS (scanned here, never dispatched), each repo at most once.
# Folded into the repo from the VM's ~/.claude/pipeline/scan-backlog.sh on 2026-09-08.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"
source "$(cd "$(dirname "$0")" && pwd)/pipeline-lib.sh"
source "$(cd "$(dirname "$0")" && pwd)/goal-lib.sh"
[ "${SCAN_BACKLOG:-0}" = "1" ] || { echo "SCAN_BACKLOG not enabled on this machine"; exit 0; }

new_issues=()
seen=" "

# #320: labels of APPROVED goals (registry block go:true, goal still live: queued, active, held or waiting on JP), one JSON
# object per line {label, repos, granted}. A ticket that carries one of them and no pipeline label arrives with agent-go
# instead of agent-proposed. Fails closed: an unreadable registry means no goal is approved (agent-proposed, as before).
approved_goals=$(_goal_registry_json 2>/dev/null | jq -c '.[] | select(.block != null)
    | select(.st == "queued" or .st == "active" or .st == "held" or .st == "waiting_jp")
    | select((.block.v // 1) == 2 and (.block.go // false) == true and (.block.label // "") != "")
    | {label: .block.label, repos: (.block.repos // []), granted: (.block.granted // [])}' 2>/dev/null) || approved_goals=""
# goal_scan_approved <owner/repo> <issue> <labels csv> — 0 when the ticket carries the label of an approved goal of that repo
goal_scan_approved() {
  local r=$1 n=$2 lbls=$3 g label
  [ -n "$approved_goals" ] || return 1
  case "$r" in */Business-Intelligence) return 1 ;; esac
  case ",$lbls," in *",source:sentry,"*) return 1 ;; esac
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    label=$(printf '%s' "$g" | jq -r .label)
    case ",$lbls," in *",$label,"*) ;; *) continue ;; esac
    printf '%s' "$g" | jq -e --arg r "$r" '.repos | index($r) != null' >/dev/null || continue
    printf '%s' "$g" | jq -e --arg x "$r#$n" '.granted | index($x) == null' >/dev/null || continue
    return 0
  done <<< "$approved_goals"
  return 1
}

# ${arr[@]+...}: an empty or unset array is an unbound variable under `set -u` on bash 3.2 (macOS).
for entry in ${DISPATCH_REPOS[@]+"${DISPATCH_REPOS[@]}"} ${SCAN_ONLY_REPOS[@]+"${SCAN_ONLY_REPOS[@]}"}; do
  repo="${entry%%:*}"
  case "$seen" in *" $repo "*) continue ;; esac
  seen+="$repo "
  # Issues the pipeline already launched carry a claim comment; a parked run has no pipeline label, so exclude them
  # explicitly. Fail closed: a failed search skips the repo (never relabel on a failed search).
  claimed=$(gh issue list --repo "$repo" --state all --limit 1000 --search '"[supervisor] NOTE" claim in:comments' \
    --json number --jq '.[].number' 2>/dev/null) || {
    echo "claim search failed for $repo — skipping" >&2
    if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
      rel=$(git -C "$(dirname "$0")" rev-parse HEAD 2>/dev/null || echo unknown)
      curl -s -X POST -H 'Content-type: application/json' "$SLACK_WEBHOOK_URL" --data \
        "$(jq -n --arg t "scan-backlog: claim search failed for $repo (route=scan-backlog env=${PIPELINE_ENV:-prod} release=$rel)" '{text:$t}')" >/dev/null 2>&1 || true
    fi
    continue
  }
  claimed_json=$(printf '%s\n' "$claimed" | jq -Rn '[inputs | select(length>0) | tonumber]')
  issues=$(gh issue list --repo "$repo" --state open --limit 100 --json number,title,labels \
    --jq '.[] | select(.number as $n | ('"$claimed_json"' | index($n)) == null) | select(.labels | map(.name) |
      (contains(["'"$LABEL_PROPOSED"'"]) | not) and
      (contains(["'"$LABEL_GO"'"]) | not) and
      (contains(["'"$LABEL_IN_PROGRESS"'"]) | not) and
      (contains(["user-feedback-intake"]) | not) and
      (contains(["user-feedback-needs-spec"]) | not) and
      (contains(["release-watch"]) | not)
    ) | "\(.number)\t\(.title)\t\([.labels[].name] | join(","))"' 2>/dev/null) || continue
  [ -n "$issues" ] || continue
  while IFS=$'\t' read -r num title lbls; do
    new_issues+=("$repo#$num: $title")
    # an approved goal's ticket gets the go itself (never Business-Intelligence, never source:sentry; a ticket whose go was
    # already granted once and later removed is not given it again — the registry's `granted` list is the ledger)
    if goal_scan_approved "$repo" "$num" "$lbls"; then
      gh issue edit "$num" --repo "$repo" --add-label "$LABEL_GO" >/dev/null 2>&1 || true
    else
      gh issue edit "$num" --repo "$repo" --add-label "$LABEL_PROPOSED" >/dev/null 2>&1 || true
    fi
  done <<< "$issues"
done

if [ ${#new_issues[@]} -eq 0 ]; then echo "No new issues to propose."; exit 0; fi

summary="*New issues for pipeline review:*"
for issue in "${new_issues[@]}"; do summary+=$'\n'"- $issue"; done
summary+=$'\n\n'"_Add the \`$LABEL_GO\` label to issues you want the orchestrator to pick up (\`fast-lane\` / \`infra\` as needed)._"
echo "$summary"

if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  payload=$(jq -n --arg text "$summary" '{"text": $text}')
  response=$(curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL")
  [ "$response" = "ok" ] && echo "Posted to Slack." || echo "Slack post failed: $response"
fi
