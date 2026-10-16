#!/usr/bin/env bash
# Hourly backlog scan: label unseen open issues `agent-proposed` and post a digest to Slack.
# Runs only where config.local.sh sets SCAN_BACKLOG=1 (one machine), over that machine's DISPATCH_REPOS
# plus SCAN_ONLY_REPOS (scanned here, never dispatched), each repo at most once.
# Folded into the repo from the VM's ~/.claude/pipeline/scan-backlog.sh on 2026-09-08.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"
[ "${SCAN_BACKLOG:-0}" = "1" ] || { echo "SCAN_BACKLOG not enabled on this machine"; exit 0; }

new_issues=()
seen=" "
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
    ) | "\(.number)\t\(.title)"' 2>/dev/null) || continue
  [ -n "$issues" ] || continue
  while IFS=$'\t' read -r num title; do
    new_issues+=("$repo#$num: $title")
    gh issue edit "$num" --repo "$repo" --add-label "$LABEL_PROPOSED" >/dev/null 2>&1 || true
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
