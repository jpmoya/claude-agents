#!/bin/bash
# verify-shipped.sh <owner/repo> [--no-deploy] <PR#...> — is every merged PR really on origin/main, and is prod deployed?
#
# "Merged to staging" and "the release bot will handle it" are not done (JP, 2026-11-16). For each PR the changed files are read
# from the GitHub PR (added/modified/removed/renamed); an added or modified file must exist on origin/main with the SAME blob
# as at the PR's merge commit (or, when a LATER change moved the file on, a blob its history held after this one; a revert back to
# the earlier version is NOT shipped), a removed file (or the old name of a rename) must be absent from main. Commit SHAs are never compared: a cherry-pick
# or a squash promotion gives the same content a new SHA. When the PR's merge commit is NOT on main (a PR merged to staging and promoted by a squash
# or cherry-pick release PR), the version to look for is the file as of the first non-revert main commit that names the PR ("(#N)" in its
# message, or a "cherry picked from commit <merge sha>" line) and touched the file; if no main commit names it, the merge commit's blob is used
# and the PR reads as not shipped. A file a later change deleted from main counts as moved on (a deletion by a Revert commit does not).
# The latest prod deploy run on main (workflow file deploy.yml or named "Deploy to Vercel") must be green AND be for a commit that already carries the PR's files.
#
# Output, one line per PR:   <owner/repo>#<N>: SHIPPED | NOT SHIPPED (<file>) | DEPLOY PENDING (<why>) | DEPLOY FAILED (<why>)
# then one `deploy: ...` line. Exit 0 only when every PR is SHIPPED and the deploy is green; 1 = a PR is not on main (wins over 2);
# 2 = everything is on main but the deploy is pending / failed; 3 = usage or tooling error (treated as "not verified" by every caller).
#
# Frugal: 2 gh API calls per PR + 1 (2 when the deploy workflow file is not found) for the deploy run; file lists and blobs come from
# git on a cached bare clone.
# Env (tests): VS_GH (gh binary), VS_REMOTE (git remote, default https://github.com/<repo>.git), VS_GIT_DIR (bare clone path),
# VS_BASE (default main), VS_DEPLOY_RE (workflow path/name regex), VS_DEPLOY_FILE (default deploy.yml). --no-deploy (or VS_DEPLOY=0):
# repo has no prod deploy workflow (also detected automatically from .github/workflows on main). bash 3.2 compatible.
set -u

GH="${VS_GH:-gh}"
BASE="${VS_BASE:-main}"
DEPLOY_FILE="${VS_DEPLOY_FILE:-deploy.yml}"
DEPLOY_RE="${VS_DEPLOY_RE:-(^|/)deploy\\.yml$|^Deploy to Vercel$}"
CHECK_DEPLOY=1
[ "${VS_DEPLOY:-1}" = 0 ] && CHECK_DEPLOY=0

usage() { echo "usage: verify-shipped.sh <owner/repo> [--no-deploy] <PR#> [<PR#>...]" >&2; exit 3; }
die() { echo "verify-shipped: $*" >&2; exit 3; }

[ $# -ge 2 ] || usage
REPO=$1; shift
case "$REPO" in */*) ;; *) usage ;; esac
PRS=""
for a in "$@"; do
  case "$a" in
    --no-deploy) CHECK_DEPLOY=0 ;;
    '#'[0-9]*|[0-9]*) n=${a#\#}; case "$n" in *[!0-9]*) usage ;; esac; PRS="$PRS $n" ;;
    *) usage ;;
  esac
done
[ -n "$PRS" ] || usage
command -v jq >/dev/null 2>&1 || die "jq is required"

REMOTE="${VS_REMOTE:-https://github.com/$REPO.git}"
GD="${VS_GIT_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-agents/verify-shipped/$(printf '%s' "$REPO" | tr '/' '_').git}"
git_() { git --git-dir="$GD" "$@"; }
if [ ! -d "$GD" ]; then
  mkdir -p "$GD" 2>/dev/null || die "cannot create $GD"
  git init -q --bare "$GD" || die "git init failed"
fi
# gh credentials for private remotes; harmless for a local path remote
git_fetch() { git_ -c credential.helper='!gh auth git-credential' -c protocol.version=2 fetch -q --no-tags origin "$@" 2>/dev/null; }
if git_ remote get-url origin >/dev/null 2>&1; then git_ remote set-url origin "$REMOTE"; else git_ remote add origin "$REMOTE"; fi || die "git remote failed"
git_fetch "+refs/heads/$BASE:refs/remotes/origin/$BASE" || die "cannot fetch $BASE from $REMOTE"
MAIN="refs/remotes/origin/$BASE"

have() { git_ cat-file -e "$1^{commit}" 2>/dev/null; }
ensure() { have "$1" || git_fetch "$1"; have "$1"; }

# blob_at <ref> <path> -> blob sha or empty
blob_at() { git_ rev-parse -q --verify "$1:$2" 2>/dev/null; }

# hist <ref> <path> [--reverse] -> one "<commit> <blob>" line per commit (last 200, path-touching, full history), blob empty when the path is
# absent at that commit. One git process for all blobs (git cat-file --batch-check), not one per commit.
hist() {
  local cs; cs=$(git_ log --full-history ${3:-} --format=%H -n 200 "$1" -- "$2" 2>/dev/null)
  [ -n "$cs" ] || return 0
  paste -d' ' <(printf '%s\n' "$cs") <(printf '%s\n' "$cs" | awk -v p="$2" '{print $0 ":" p}' | git_ cat-file --batch-check='%(objectname)' 2>/dev/null | sed 's/^.* missing$//')
}

# in_history <ref> <path> <want blob> <current blob> — may <path> legitimately differ from <want> on <ref>? Yes when a LATER change
# moved it on: the want blob appeared in the path's history and the current blob is not one the file held BEFORE it first appeared
# (a revert back to an earlier version is NOT shipped). The history is walked with --full-history so a blob that reached <ref> only through
# a merge's second parent counts; "before" means the path's history reachable from the PARENTS of the first commit that held the want blob
# (not date order, which is arbitrary across parallel branches).
in_history() {
  local c b first="" p
  while read -r c b; do
    if [ "$b" = "$3" ]; then first=$c; break; fi
  done <<EOF
$(hist "$1" "$2" --reverse)
EOF
  [ -n "$first" ] || return 1
  for p in $(git_ rev-list --parents -n 1 "$first" 2>/dev/null | cut -d' ' -f2-); do
    [ "$(blob_at "$p" "$2")" = "$4" ] && return 1
    while read -r c b; do
      [ "$b" = "$4" ] && return 1
    done <<EOF
$(hist "$p" "$2")
EOF
  done
  return 0
}

# deleted_later <ref> <path> <want blob> — the path is absent on <ref>: was that a later change moving the file on? Yes when the want blob
# appeared in the path's history and the commit that deleted the path is not a Revert (a reverted addition is NOT shipped).
deleted_later() {
  local c b seen=0 d
  while read -r c b; do
    [ "$b" = "$3" ] && { seen=1; break; }
  done <<EOF
$(hist "$1" "$2")
EOF
  [ "$seen" = 1 ] || return 1
  d=$(git_ log --full-history --diff-filter=D -n 1 --format=%s "$1" -- "$2" 2>/dev/null)
  case "$d" in Revert*) return 1 ;; esac
  return 0
}

# promoted_blob <ref> <path> <PR#> <merge commit> — when the PR's merge commit is not on <ref>, the file's blob at the oldest non-Revert
# <ref> commit that names the PR and changed <path> (and still has it); empty when the merge commit is on <ref>, or no commit names the PR.
# The commits naming the PR are listed once per (ref, PR) and reused for every file.
PB_KEY=""; PB_COMMITS=""
promoted_blob() {
  local ref=$1 path=$2 n=$3 mc=$4 c b
  if [ "$PB_KEY" != "$ref $n $mc" ]; then
    PB_KEY="$ref $n $mc"; PB_COMMITS=""
    git_ merge-base --is-ancestor "$mc" "$ref" 2>/dev/null || PB_COMMITS=$(git_ log --reverse --format='%H %s' -F --grep="(#$n)" --grep="cherry picked from commit $mc" "$ref" 2>/dev/null | awk '$2 != "" && $2 !~ /^Revert/ {print $1}')
  fi
  for c in $PB_COMMITS; do
    b=$(blob_at "$c" "$path"); [ -n "$b" ] || continue
    [ "$b" != "$(blob_at "$c^" "$path")" ] || continue
    printf '%s\n' "$b"; return 0
  done
  return 0
}

# check_at <ref> <changes file> -> prints the first offending file (and returns 1), or returns 0.
# Each change row: <status>\t<path>\t<merge commit>\t<PR#>. Added/modified/renamed: same blob; removed/gone: absent.
check_at() {
  local ref=$1 f=$2 st path mc n want got
  while IFS="$(printf '\t')" read -r st path mc n; do
    [ -n "$path" ] || continue
    got=$(blob_at "$ref" "$path")
    case "$st" in
      removed|gone) [ -z "$got" ] || { printf '%s (still on %s)' "$path" "$BASE"; return 1; } ;;
      *) want=$(promoted_blob "$ref" "$path" "$n" "$mc")
         [ -n "$want" ] || want=$(blob_at "$mc" "$path")
         [ -n "$want" ] || { printf '%s (missing at merge commit)' "$path"; return 1; }
         if [ -z "$got" ]; then
           deleted_later "$ref" "$path" "$want" || { printf '%s (absent on %s)' "$path" "$BASE"; return 1; }
         else
           [ "$got" = "$want" ] || in_history "$ref" "$path" "$want" "$got" || { printf '%s (differs on %s)' "$path" "$BASE"; return 1; }
         fi ;;
    esac
  done < "$f"
  return 0
}

# has_deploy_workflow: is there a prod deploy workflow on main at all? (deploy.yml, or any workflow named "Deploy to Vercel").
# A repo without one (jpmoya/claude-agents) has no deploy to wait for: the deploy check is skipped, not "pending forever".
has_deploy_workflow() {
  local f
  for f in $(git_ ls-tree -r --name-only "$MAIN" .github/workflows/ 2>/dev/null); do
    case "$f" in */"$DEPLOY_FILE") return 0 ;; esac
    git_ show "$MAIN:$f" 2>/dev/null | grep -Eq '^name:[[:space:]]*"?Deploy to Vercel' && return 0
  done
  return 1
}
NODEPLOY_WHY="not checked (--no-deploy)"
if [ "$CHECK_DEPLOY" = 1 ] && ! has_deploy_workflow; then CHECK_DEPLOY=0; NODEPLOY_WHY="no prod deploy workflow on $BASE (not checked)"; fi

# ---- latest prod deploy run on main (one API call, a second only when the workflow file is not found) ----
DEP_ID=""; DEP_SHA=""; DEP_STATE="none"   # none | success | running | failed
if [ "$CHECK_DEPLOY" = 1 ]; then
  pick_run() {  # stdin: runs JSON -> "<id>\t<sha>\t<status>\t<conclusion>" of the newest deploy run, or nothing
    jq -r --arg re "$DEPLOY_RE" \
      '[.workflow_runs[]? | select(((.path // "") | test($re)) or ((.name // "") | test($re)))] | first // empty
       | "\(.id)\t\(.head_sha)\t\(.status)\t\(.conclusion // "")"' 2>/dev/null
  }
  row=$($GH api "repos/$REPO/actions/workflows/$DEPLOY_FILE/runs?branch=$BASE&per_page=5" 2>/dev/null | pick_run)
  [ -n "$row" ] || row=$($GH api "repos/$REPO/actions/runs?branch=$BASE&per_page=50" 2>/dev/null | pick_run)
  if [ -n "$row" ]; then
    IFS="$(printf '\t')" read -r DEP_ID DEP_SHA dstatus dconc <<EOF
$row
EOF
    if [ "$dstatus" != completed ]; then DEP_STATE=running
    elif [ "$dconc" = success ]; then DEP_STATE=success
    else DEP_STATE=failed; fi
  fi
fi

NS=0   # a PR is not on main
DP=0   # on main, deploy pending / failed
TMP=$(mktemp -d "${TMPDIR:-/tmp}/verify-shipped.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

for n in $PRS; do
  tag="$REPO#$n"
  pj=$($GH api "repos/$REPO/pulls/$n" 2>/dev/null) || { echo "$tag: NOT SHIPPED (cannot read the PR from GitHub)"; NS=1; continue; }
  merged=$(printf '%s' "$pj" | jq -r '.merged // false')
  mc=$(printf '%s' "$pj" | jq -r '.merge_commit_sha // empty')
  if [ "$merged" != true ] || [ -z "$mc" ]; then echo "$tag: NOT SHIPPED (PR is not merged)"; NS=1; continue; fi
  files=$($GH api --paginate "repos/$REPO/pulls/$n/files?per_page=100" 2>/dev/null) || { echo "$tag: NOT SHIPPED (cannot read the PR files)"; NS=1; continue; }
  # rows: status, path, merge commit, PR number; a rename is the new path plus the old path (gone)
  printf '%s' "$files" | jq -r --arg mc "$mc" --arg n "$n" '.[] |
      (if .status == "removed" then "removed\t\(.filename)\t\($mc)\t\($n)"
       elif .status == "renamed" then "renamed\t\(.filename)\t\($mc)\t\($n)", "gone\t\(.previous_filename)\t\($mc)\t\($n)"
       else "\(.status)\t\(.filename)\t\($mc)\t\($n)" end)' > "$TMP/changes" 2>/dev/null || { echo "$tag: NOT SHIPPED (cannot parse the PR files)"; NS=1; continue; }
  if ! ensure "$mc"; then echo "$tag: NOT SHIPPED (cannot fetch merge commit ${mc:0:7})"; NS=1; continue; fi
  if bad=$(check_at "$MAIN" "$TMP/changes"); then :; else
    echo "$tag: NOT SHIPPED ($bad)"; NS=1; continue
  fi
  # on main: now the deploy must cover it
  if [ "$CHECK_DEPLOY" = 0 ]; then echo "$tag: SHIPPED"; continue; fi
  if [ "$DEP_STATE" = none ]; then echo "$tag: DEPLOY PENDING (no prod deploy run found on $BASE)"; DP=1; continue; fi
  if ! ensure "$DEP_SHA" || ! check_at "$DEP_SHA" "$TMP/changes" >/dev/null; then
    echo "$tag: DEPLOY PENDING (latest deploy run $DEP_ID is for ${DEP_SHA:0:7}, which predates this change)"; DP=1; continue
  fi
  case "$DEP_STATE" in
    success) echo "$tag: SHIPPED" ;;
    running) echo "$tag: DEPLOY PENDING (deploy run $DEP_ID is still running)"; DP=1 ;;
    *) echo "$tag: DEPLOY FAILED (deploy run $DEP_ID did not succeed)"; DP=1 ;;
  esac
done

if [ "$CHECK_DEPLOY" = 0 ]; then echo "deploy: $NODEPLOY_WHY"
elif [ "$DEP_STATE" = none ]; then echo "deploy: no prod deploy run found on $BASE"
else echo "deploy: run $DEP_ID on ${DEP_SHA:0:7} is $DEP_STATE"; fi
[ "$NS" = 0 ] || exit 1
[ "$DP" = 0 ] || exit 2
exit 0
