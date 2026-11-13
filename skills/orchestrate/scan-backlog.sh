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
gh_class optional   # gh-budget: the scan is optional work
gh_tier_allows optional || { echo "gh-quota below GH_QUOTA_OPTIONAL_BELOW: skipping the backlog scan this hour"; exit 0; }

new_issues=()
seen=" "

# #320: APPROVED goals (registry block go:true, goal still live: queued, active, held or waiting on JP), one JSON
# object per line {issue, label, repos, granted, block}. A ticket that carries one of them and no pipeline label arrives with agent-go
# instead of agent-proposed. Fails closed: an unreadable registry means no goal is approved (agent-proposed, as before).
approved_goals=$(_goal_registry_json 2>/dev/null | jq -c '.[] | select(.block != null)
    | select(.st == "queued" or .st == "active" or .st == "held" or .st == "waiting_jp")
    | select((.block.v // 1) == 2 and (.block.go // false) == true and (.block.label // "") != "")
    | {issue, label: .block.label, repos: (.block.repos // []), granted: (.block.granted // []), block}' 2>/dev/null) || approved_goals=""
# goal_scan_approved <owner/repo> <issue> <labels csv> — 0 when the ticket carries the label of an approved goal of that repo
# (the matching goal's json is left in SCAN_GOAL for goal_scan_record)
goal_scan_approved() {
  local r=$1 n=$2 lbls=$3 g label
  SCAN_GOAL=""
  [ -n "$approved_goals" ] || return 1
  case "$r" in */Business-Intelligence) return 1 ;; esac
  case ",$lbls," in *",source:sentry,"*) return 1 ;; esac
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    label=$(printf '%s' "$g" | jq -r .label)
    case ",$lbls," in *",$label,"*) ;; *) continue ;; esac
    printf '%s' "$g" | jq -e --arg r "$r" '.repos | index($r) != null' >/dev/null || continue
    printf '%s' "$g" | jq -e --arg x "$r#$n" '.granted | index($x) == null' >/dev/null || continue
    SCAN_GOAL=$g
    return 0
  done <<< "$approved_goals"
  return 1
}

# goal_scan_record <owner/repo> <issue> — the loop guard's ledger: a go given here is recorded in the goal's registry block
# (`granted`, and the Go-granted list of the body) at once, the same record goal_sync keeps, so a go JP removes later is not
# given again by the next scan. A failed write is reported on stderr (the next scan would retry the ticket's grant, not repeat it).
goal_scan_record() {
  local ref="$1#$2" block date n
  n=$(printf '%s' "$SCAN_GOAL" | jq -r .issue)
  block=$(printf '%s' "$SCAN_GOAL" | jq -c --arg x "$ref" '.block | .granted = (((.granted // []) + [$x]) | unique)')
  date=$(printf '%s' "$block" | jq -r '(.granted_at // empty)'); [ -n "$date" ] || date=$(date -u +%F)
  _goal_patch_body "$n" "$(goal_body_v2 "$block" "$date")" >/dev/null 2>&1 || echo "scan-backlog: cannot record the go of $ref on registry issue #$n" >&2
  approved_goals=$(printf '%s\n' "$approved_goals" | jq -c --arg l "$(printf '%s' "$block" | jq -r .label)" --argjson b "$block" \
    'if .label == $l then (.block = $b | .granted = $b.granted) else . end')
}

# #676: the claim search below is eventually consistent and capped at 1000 hits, so a search that succeeds with an incomplete
# list used to relabel in-flight and shipped tickets (43 on 2026-11-06). Every candidate that passed the label filter gets one
# comments read of its own: scan_inflight <owner/repo> <issue> → 0 when any comment's first line is a routing marker of any
# agent (marker_re) or a `**[supervisor] NOTE** claim: ` line (never propose it), 1 when there is none, 2 when the read failed
# or its output is not the expected JSON (fail closed: the caller skips the issue for this scan).
source "$(cd "$(dirname "$0")" && pwd)/../../hooks/pipeline-markers.sh" 2>/dev/null || source "$HOME/.claude/hooks/pipeline-markers.sh"
scan_inflight() {
  local raw n
  raw=$(GH_NOCACHE=1 gh api "repos/$1/issues/$2/comments?per_page=100" --paginate 2>/dev/null </dev/null) || return 2
  n=$(printf '%s' "$raw" | jq -s --arg re "$(marker_re)" '
    [.[] | if type == "array" then .[] else error("not a comment list") end
     | if type == "object" then ((.body // "") | tostring | split("\n")[0] // "" | rtrimstr("\r")) else error("not a comment") end
     | select(test($re) or startswith("**[supervisor] NOTE** claim: "))] | length' 2>/dev/null) || return 2
  case "$n" in ''|*[!0-9]*) return 2 ;; 0) return 1 ;; esac
  return 0
}
read_failed=()   # "<owner/repo>#<n>" of every candidate skipped on a failed comments read (one Slack alert per scan, below)

canonicalize_repo_lists
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
      (index("'"$LABEL_FEEDBACK"'") | not) and
      (contains(["release-watch"]) | not) and
      (contains(["backlog-priority-registry"]) | not)
    ) | "\(.number)\t\(.title)\t\([.labels[].name] | join(","))"' 2>/dev/null) || continue
  [ -n "$issues" ] || continue
  while IFS=$'\t' read -r num title lbls; do
    # #676: never propose (agent-proposed or the goal go) a ticket the pipeline already touched; an unreadable ticket waits
    scan_inflight "$repo" "$num"
    case $? in
      0) continue ;;
      1) ;;
      *) read_failed+=("$repo#$num")
         echo "scan-backlog: comments read failed for $repo#$num — skipped this scan: release=$(git -C "$(dirname "$0")" rev-parse HEAD 2>/dev/null || echo unknown) environment=$(hostname -s 2>/dev/null || echo unknown) route=scan-backlog" >&2
         continue ;;
    esac
    new_issues+=("$repo#$num: $title")
    # an approved goal's ticket gets the go itself (never Business-Intelligence, never source:sentry; a ticket whose go was
    # already granted once and later removed is not given it again — the registry's `granted` list is the ledger)
    if goal_scan_approved "$repo" "$num" "$lbls"; then
      if gh issue edit "$num" --repo "$repo" --add-label "$LABEL_GO" >/dev/null 2>&1; then goal_scan_record "$repo" "$num"; fi
    else
      gh issue edit "$num" --repo "$repo" --add-label "$LABEL_PROPOSED" >/dev/null 2>&1 || true
    fi
  done <<< "$issues"
done

# #676: one alert per scan for the candidates skipped on a failed comments read, however many there were (same webhook as the
# claim-search alert above; repo and issue numbers only, never issue text)
if [ ${#read_failed[@]} -gt 0 ] && [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  rel=$(git -C "$(dirname "$0")" rev-parse HEAD 2>/dev/null || echo unknown)
  shown="${read_failed[*]:0:30}"; [ ${#read_failed[@]} -le 30 ] || shown+=" +$(( ${#read_failed[@]} - 30 )) more"
  curl -s -X POST -H 'Content-type: application/json' "$SLACK_WEBHOOK_URL" --data \
    "$(jq -nc --arg t "scan-backlog: comments read failed for ${#read_failed[@]} issue(s), not proposed this scan ($shown): release=$rel environment=$(hostname -s 2>/dev/null || echo unknown) route=scan-backlog" '{text:$t}')" >/dev/null 2>&1 || true
fi

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
