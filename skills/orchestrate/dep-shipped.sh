#!/bin/bash
# dep-shipped.sh <owner/repo> <N> — has dependency issue #N shipped to the repo's integration branch? (#677)
# Exit 0 = shipped, 1 = not shipped, 2 = read error (or bad arguments). One reason line on stdout.
# Self-contained: gh + jq only, no config.sh, so the orchestrator agent, the supervisor and goal-lib all run the same test.
#   Integration branch: `staging` when the repo has that branch (a 404 on it means it has none), else the default branch.
#   The dependency's latest `**[fullstack-developer] IMPLEMENTED**` comment names a `PR #<n>` (the first one on it):
#     shipped only when that PR is MERGED into the integration branch. An unmerged PR there is "not shipped", no fallback.
#   No IMPLEMENTED comment names a PR: shipped when a merged PR into the integration branch has a head `issue-<N>-…`.
# Any failed gh call is exit 2; gh's own stderr is never printed (it can carry a token).
set -u
repo=${1:-}; n=${2:-}
usage() { echo "usage: dep-shipped.sh <owner/repo> <issue number>"; exit 2; }
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage   # exactly owner/repo: the value goes into API paths
case "/$repo/" in */./*|*/../*) usage ;; esac
case "$n" in ''|*[!0-9]*) usage ;; esac
err() { echo "read error: $1 ($repo#$n)"; exit 2; }

berr=$(gh api "repos/$repo/branches/staging" 2>&1 >/dev/null </dev/null) && base=staging || {
  case "$berr" in
    *"HTTP 404"*|*"Not Found"*)
      base=$(gh api "repos/$repo" 2>/dev/null </dev/null | jq -r '.default_branch // empty' 2>/dev/null) || base=""
      [ -n "$base" ] || err "default branch" ;;
    *) err "staging branch lookup" ;;
  esac
}

comments=$(gh api "repos/$repo/issues/$n/comments?per_page=100" --paginate 2>/dev/null </dev/null) || err "issue comments"
pr=$(printf '%s' "$comments" | jq -rs '
  [.[] | if type == "array" then .[] else . end
   | select((.body | type) == "string" and (.body | startswith("**[fullstack-developer] IMPLEMENTED**")))] | last
  | if . == null then "" else ((.body | capture("PR #(?<n>[0-9]+)") | .n) // "") end' 2>/dev/null) || err "issue comments (unparseable)"

if [ -n "$pr" ]; then
  info=$(gh pr view "$pr" --repo "$repo" --json state,baseRefName 2>/dev/null </dev/null) || err "PR #$pr"
  state=$(printf '%s' "$info" | jq -r '"\(.state // "?") \(.baseRefName // "?")"' 2>/dev/null) || err "PR #$pr (unparseable)"
  if [ "$state" = "MERGED $base" ]; then echo "shipped: PR #$pr of $repo#$n is merged into $base"; exit 0; fi
  echo "not shipped: PR #$pr of $repo#$n is ${state%% *} (base ${state#* }), not merged into $base"; exit 1
fi

list=$(gh pr list --repo "$repo" --state merged --base "$base" --limit 100 --json number,headRefName 2>/dev/null </dev/null) || err "merged PR list"
hit=$(printf '%s' "${list:-[]}" | jq -r --arg p "issue-$n-" '[.[] | select((.headRefName // "") | startswith($p)) | .number][0] // empty' 2>/dev/null) \
  || err "merged PR list (unparseable)"
if [ -n "$hit" ]; then echo "shipped: PR #$hit (issue-$n-…) is merged into $base"; exit 0; fi
echo "not shipped: $repo#$n has no merged PR into $base"; exit 1
