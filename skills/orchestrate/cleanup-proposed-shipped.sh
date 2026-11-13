#!/usr/bin/env bash
# One-time cleanup (#676): remove `agent-proposed` from open issues the pipeline already has in flight or has shipped.
# scan-backlog.sh relabelled in-flight and shipped tickets when its claim search came back incomplete (43 on 2026-11-06),
# and goal-lib.sh then reads such a ticket as "not approved yet". Nothing ever removed the label.
#
# Usage: cleanup-proposed-shipped.sh [--dry-run] <owner/repo>...
#
# For each open issue labelled agent-proposed, one comments read. The issue's LATEST stage marker decides (the first line of
# a comment that is a routing marker of a pipeline stage; jp / delivery-lead / orchestrator markers are answers, not stages,
# and are skipped):
#   engineering or later — test-writer, test-reviewer, fullstack-developer, code-reviewer, deployer, infra-planner,
#     infra-reviewer, infra-operator (so TESTS WRITTEN, IMPLEMENTED, PASS/FAIL, DEPLOYED, DEPLOYED TO STAGING, APPLIED …):
#     the ticket is in flight or shipped, the label is removed.
#   spec stage — product-manager, intake, ux-flow-designer, ui-ux-designer, solutions-architect — or no stage marker:
#     the label is kept. That is a specified idea waiting for JP (put there by supervisor step 3c), including a ticket that
#     shipped earlier and was re-specified since.
# One line per issue on stdout: `<owner/repo>#<n> removed | kept | would remove | read failed | write failed`. Idempotent: a second run finds nothing left to remove. --dry-run makes no write.
# Exit 1 when any read or write failed, 2 on a usage error or a refused repo (nothing is touched), else 0.
# Refuses Business-Intelligence and direct-route repos. Failure lines are tagged release (commit SHA), environment (host) and
# route=cleanup-proposed on stderr; a real run with failures posts one message to the existing SLACK_WEBHOOK_URL.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/config.sh"
# routing-marker vocabulary (marker_re), shared with the supervisor and the scan
source "$HERE/../../hooks/pipeline-markers.sh" 2>/dev/null || source "$HOME/.claude/hooks/pipeline-markers.sh"

dry=0; repos=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    -*) echo "usage: cleanup-proposed-shipped.sh [--dry-run] <owner/repo>..." >&2; exit 2 ;;
    */*) repos+=("$a") ;;
    *) echo "cleanup-proposed-shipped: not an owner/repo: $a" >&2; exit 2 ;;
  esac
done
[ ${#repos[@]} -gt 0 ] || { echo "usage: cleanup-proposed-shipped.sh [--dry-run] <owner/repo>..." >&2; exit 2; }
for repo in "${repos[@]}"; do   # every repo is checked before anything is read or written
  case "$repo" in */Business-Intelligence) echo "cleanup-proposed-shipped: refused: $repo (Business-Intelligence is never touched)" >&2; exit 2 ;; esac
  if direct_route_repo "$repo"; then echo "cleanup-proposed-shipped: refused: $repo (direct-route repo, the pipeline never labels it)" >&2; exit 2; fi
done

tags="release=$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown) environment=$(hostname -s 2>/dev/null || echo unknown) route=cleanup-proposed"
failed=()   # "<ref> <read|write> failed", for the exit code and the one Slack message
fail() {  # <ref> <read|write>
  failed+=("$1 $2 failed")
  echo "cleanup-proposed-shipped: $1 $2 failed: $tags" >&2
}

# shipped <owner/repo> <issue> → 0 when the issue's LATEST stage marker (marker_re; jp / delivery-lead / legacy project-manager
# / orchestrator markers skipped) comes from an engineering-or-later stage: in flight or shipped. 1 when it comes from a spec
# stage or there is none, 2 when the comments read failed or is not a comment list. The latest one decides, never an older
# one: a ticket that shipped and was later re-specified (a PM READY after the DEPLOYED) is waiting for JP again.
ENG_STAGES='["test-writer","test-reviewer","fullstack-developer","code-reviewer","deployer","infra-planner","infra-reviewer","infra-operator"]'
shipped() {
  local raw n
  raw=$(GH_NOCACHE=1 gh api "repos/$1/issues/$2/comments?per_page=100" --paginate 2>/dev/null </dev/null) || return 2
  n=$(printf '%s' "$raw" | jq -s --arg re "$(marker_re)" --argjson eng "$ENG_STAGES" '
    [.[] | if type == "array" then .[] else error("not a comment list") end
     | if type == "object" then ((.body // "") | tostring | split("\n")[0] // "" | rtrimstr("\r")) else error("not a comment") end
     | select(test($re)) | (capture("^\\*\\*\\[(?<a>[a-z-]+)\\]") | .a)
     | select(. != "jp" and . != "delivery-lead" and . != "project-manager" and . != "orchestrator")] | (last // "") as $stage
    | if ($eng | index($stage)) != null then 1 else 0 end' 2>/dev/null) || return 2
  case "$n" in 1) return 0 ;; 0) return 1 ;; esac
  return 2
}

for repo in "${repos[@]}"; do
  nums=$(GH_NOCACHE=1 gh issue list --repo "$repo" --state open --label "$LABEL_PROPOSED" --limit 1000 --json number --jq '.[].number' 2>/dev/null </dev/null) || {
    echo "$repo read failed"; fail "$repo" read; continue; }
  for num in $nums; do
    case "$num" in ''|*[!0-9]*) continue ;; esac
    shipped "$repo" "$num"
    case $? in
      0) if [ "$dry" = 1 ]; then echo "$repo#$num would remove"
         elif gh issue edit "$num" --repo "$repo" --remove-label "$LABEL_PROPOSED" >/dev/null 2>&1 </dev/null; then echo "$repo#$num removed"
         else echo "$repo#$num write failed"; fail "$repo#$num" write; fi ;;
      1) echo "$repo#$num kept" ;;
      *) echo "$repo#$num read failed"; fail "$repo#$num" read ;;
    esac
  done
done

[ ${#failed[@]} -gt 0 ] || exit 0
if [ "$dry" = 0 ] && [ -n "${SLACK_WEBHOOK_URL:-}" ]; then   # counts and refs only, never issue text
  shown=$(printf '%s, ' "${failed[@]:0:30}"); shown=${shown%, }; [ ${#failed[@]} -le 30 ] || shown+=", +$(( ${#failed[@]} - 30 )) more"
  curl -s --max-time 10 -X POST -H 'Content-type: application/json' "$SLACK_WEBHOOK_URL" --data \
    "$(jq -nc --arg t "cleanup-proposed-shipped: ${#failed[@]} failure(s) ($shown): $tags" '{text:$t}')" >/dev/null 2>&1 || true
fi
exit 1
