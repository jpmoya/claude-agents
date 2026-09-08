#!/usr/bin/env bash
# Hourly backlog scan: label unseen open issues `agent-proposed` and post a digest to Slack.
# Runs only where config.local.sh sets SCAN_BACKLOG=1 (one machine), over that machine's DISPATCH_REPOS.
# Folded into the repo from the VM's ~/.claude/pipeline/scan-backlog.sh on 2026-09-08.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"
[ "${SCAN_BACKLOG:-0}" = "1" ] || { echo "SCAN_BACKLOG not enabled on this machine"; exit 0; }

new_issues=()
for entry in "${DISPATCH_REPOS[@]}"; do
  repo="${entry%%:*}"
  issues=$(gh issue list --repo "$repo" --state open --limit 100 --json number,title,labels \
    --jq '.[] | select(.labels | map(.name) |
      (contains(["'"$LABEL_PROPOSED"'"]) | not) and
      (contains(["'"$LABEL_GO"'"]) | not) and
      (contains(["'"$LABEL_IN_PROGRESS"'"]) | not)
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
