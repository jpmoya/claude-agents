#!/bin/bash
# verify-shipped.sh <owner/repo> [--no-deploy] <PR#...> — is every merged PR really on origin/main, and is prod deployed?
#
# "Merged to staging" and "the release bot will handle it" are not done (JP, 2026-11-16). For each PR the changed files are read
# from the GitHub PR (added/modified/removed/renamed); an added or modified file must exist on origin/main with the SAME blob
# as at the PR's merge commit (or a blob that main's history for that path once held: a later PR may have changed the file
# again), a removed file (or the old name of a rename) must be absent from main. Commit SHAs are never compared: a cherry-pick
# or a squash promotion gives the same content a new SHA. The latest prod deploy run on main (workflow file deploy.yml or named
# "Deploy to Vercel") must be green AND be for a commit that already carries the PR's files.
#
# Output, one line per PR:   <owner/repo>#<N>: SHIPPED | NOT SHIPPED (<file>) | DEPLOY PENDING (<why>) | DEPLOY FAILED (<why>)
# then one `deploy: ...` line. Exit 0 only when every PR is SHIPPED and the deploy is green; 1 = a PR is not on main (wins over 2);
# 2 = everything is on main but the deploy is pending / failed; 3 = usage or tooling error (treated as "not verified" by every caller).
#
# Frugal: 2 gh API calls per PR + 1 (2 when the deploy workflow file is not found) for the deploy run; file lists and blobs come from
# git on a cached bare clone.
# Env (tests): VS_GH (gh binary), VS_REMOTE (git remote, default https://github.com/<repo>.git), VS_GIT_DIR (bare clone path),
# VS_BASE (default main), VS_DEPLOY_RE (workflow path/name regex), VS_DEPLOY_FILE (default deploy.yml). --no-deploy (or VS_DEPLOY=0):
# repo has no prod deploy workflow. bash 3.2 compatible.
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

# in_history <ref> <path> <blob> — did <path> ever hold <blob> in <ref>'s (last 200 path-touching) history? A later PR that changed
# the same file again must not make an earlier PR look unshipped.
in_history() {
  local c
  for c in $(git_ log --format=%H -n 200 "$1" -- "$2" 2>/dev/null); do
    [ "$(blob_at "$c" "$2")" = "$3" ] && return 0
  done
  return 1
}

# check_at <ref> <changes file> -> prints the first offending file (and returns 1), or returns 0.
# Each change row: <status>\t<path>\t<merge commit>. Added/modified/renamed: same blob; removed/gone: absent.
check_at() {
  local ref=$1 f=$2 st path mc want got
  while IFS="$(printf '\t')" read -r st path mc; do
    [ -n "$path" ] || continue
    got=$(blob_at "$ref" "$path")
    case "$st" in
      removed|gone) [ -z "$got" ] || { printf '%s (still on %s)' "$path" "$BASE"; return 1; } ;;
      *) want=$(blob_at "$mc" "$path")
         [ -n "$want" ] || { printf '%s (missing at merge commit)' "$path"; return 1; }
         [ -n "$got" ] || { printf '%s (absent on %s)' "$path" "$BASE"; return 1; }
         [ "$got" = "$want" ] || in_history "$ref" "$path" "$want" || { printf '%s (differs on %s)' "$path" "$BASE"; return 1; } ;;
    esac
  done < "$f"
  return 0
}

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
  # rows: status, path, merge commit; a rename is the new path plus the old path (gone)
  printf '%s' "$files" | jq -r --arg mc "$mc" '.[] |
      (if .status == "removed" then "removed\t\(.filename)\t\($mc)"
       elif .status == "renamed" then "renamed\t\(.filename)\t\($mc)", "gone\t\(.previous_filename)\t\($mc)"
       else "\(.status)\t\(.filename)\t\($mc)" end)' > "$TMP/changes" 2>/dev/null || { echo "$tag: NOT SHIPPED (cannot parse the PR files)"; NS=1; continue; }
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

if [ "$CHECK_DEPLOY" = 0 ]; then echo "deploy: not checked (--no-deploy)"
elif [ "$DEP_STATE" = none ]; then echo "deploy: no prod deploy run found on $BASE"
else echo "deploy: run $DEP_ID on ${DEP_SHA:0:7} is $DEP_STATE"; fi
[ "$NS" = 0 ] || exit 1
[ "$DP" = 0 ] || exit 2
exit 0
