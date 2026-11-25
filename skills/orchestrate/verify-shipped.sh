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
# #822: a main commit can name the PR without carrying the file at all (its diff doesn't touch the path, or touches it but leaves
# it unchanged vs its own parent) — this happens when the PR's base branch (PR_BASE_REF, its .base.ref, typically "staging")
# itself renamed or rewrote the file before the promotion, so main never holds the merge commit's blob under any path it has. In
# that one case ONLY (a naming commit exists but did not carry the path), "moved on" is judged a second time against the base
# branch's own history of the SAME path, with the same deleted_later/in_history rules (a revert on the base branch still fails),
# PLUS main must actually hold content the base branch itself produced for this file (a rename: git's OWN rename detection
# (diff-tree -M) on the base branch's deleting commit must name a new path, and that exact new path must hold the blob on main —
# a blob merely existing SOMEWHERE in main's tree is not proof, since two unrelated identical blobs (e.g. two empty files) could
# coincide and make a genuine drop read as shipped, AND the rename's own commit must itself show the new path holding the PR's
# content right after the rename (#824 fourth-cycle holistic fix) — a base branch that plain-deleted the PR's file and only
# LATER renamed some OTHER, unrelated file to the same new path must not borrow a coincidental match on main; a rewrite: the
# SAME path's current main blob somewhere in the base branch's OWN history of that path, confirmed ORDERED (superseded, below)
# not just present) — the base branch merely moving the file on is not by itself proof the move reached main. The rename
# case ALSO requires the old path to be genuinely absent on the base branch's CURRENT tip, not just absent at the deleting
# commit's own history (#824 third HIGH): the base branch re-adding the old path later, or `git revert`ing the rename commit
# (itself a rename back, so it is not the "last deletion commit" the history check inspects), would otherwise read as shipped
# even though the base branch currently disagrees with main. A rewrite (content differs rather than the path moving) is proven
# with `in_history` (main's blob is not an ancestor that pre-dates the PR's content) PLUS `superseded` (the base branch's own
# history, read newest-first, must reach main's blob no later than it last reaches the PR's own content — #824 fourth HIGH,
# code-reviewer: a base branch that moved past the PR's content and then reverted BACK to it is not "moved on", even though it
# once held main's blob too). A failed fetch of the base branch (transient network error, or the branch has been deleted/renamed
# since an earlier run cached it) never falls back to a stale cached tip (#824 MEDIUM): the base-branch fallback is refused for
# that PR's files that need it, same fail-closed shape as the top-level base-branch fetch failing closed via `die`. When no
# main commit names the PR at all, behaviour is unchanged (still not shipped; the base branch is not consulted).
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

# the hash git gives every empty file — never usable as rename-proof content (see rename_target): two unrelated empty files
# are always "100% similar" to git's -M detector, so matching this blob alone proves nothing about either file.
EMPTY_BLOB=e69de29bb2d1d6434b8b29ae775ad8c2e48c5391

# hist <ref> <path> [--reverse] -> one "<commit> <blob>" line per commit (last 200, path-touching, full history), blob empty when the path is
# absent at that commit. One git process for all blobs (git cat-file --batch-check), not one per commit.
hist() {
  local cs; cs=$(git_ log --full-history ${3:+"$3"} --format=%H -n 200 "$1" -- "$2" 2>/dev/null)
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
# appeared in the path's history and the commit that deleted the path is not a revert (subject starting "Revert", or a line STARTING
# "This reverts commit "): a reverted addition is NOT shipped.
deleted_later() {
  local c b seen=0 d
  while read -r c b; do
    [ "$b" = "$3" ] && { seen=1; break; }
  done <<EOF
$(hist "$1" "$2")
EOF
  [ "$seen" = 1 ] || return 1
  d=$(git_ log --full-history --diff-filter=D -n 1 --format=%B "$1" -- "$2" 2>/dev/null)
  case "$d" in Revert*|*$'\n'"This reverts commit "*) return 1 ;; esac
  return 0
}

# promoted_blob <ref> <path> <PR#> <merge commit> — when the PR's merge commit is not on <ref>, the file's blob at the oldest non-revert
# <ref> commit that names the PR and changed <path> (and still has it); empty when the merge commit is on <ref>, or no commit names the PR.
# A commit "names the PR" when ONE line carries both the PR number and the PR's title: its subject, or a squash-release bullet in its body
# ("* <title> (#N)", how GitHub lists the PRs a release squash carries), where the line contains "(#N)" and, compared case- and
# whitespace-insensitively with every "(#digits)" marker dropped, the PR's title (PR_TITLE, from the PR JSON; with no title nothing matches).
# Or when its message has an explicit "cherry picked from commit <merge sha>" line. A line that only mentions "(#N)" in prose
# ("Follow-up to (#N)") does not count. A revert (subject "Revert...", or a line STARTING "This reverts commit ", git revert's own) never
# counts. The commits naming the PR are listed once per (ref, PR) and reused for every file.
# Exit status distinguishes the two "no blob" cases the caller (check_at, #822) must tell apart: 1 = no commit on <ref> names the PR at
# all (or the merge commit is already on <ref>, so naming does not apply) — behaviour must stay exactly as before. 2 = at least one
# commit names the PR, but none of them actually carried <path> (not present, or present unchanged from its parent) — this is the
# #822 gap, where the caller falls back to judging "moved on" against the PR's base branch too.
PR_TITLE=""
PB_KEY=""; PB_COMMITS=""
promoted_blob() {
  local ref=$1 path=$2 n=$3 mc=$4 c b
  if [ "$PB_KEY" != "$ref $n $mc" ]; then
    PB_KEY="$ref $n $mc"; PB_COMMITS=""
    if ! git_ merge-base --is-ancestor "$mc" "$ref" 2>/dev/null; then
      PB_COMMITS=$(git_ log --reverse --format='%x01%H%n%B' -F --grep="(#$n)" --grep="cherry picked from commit $mc" "$ref" 2>/dev/null |
        PB_TITLE="$PR_TITLE" awk -v pat="(#$n)" -v cp="cherry picked from commit $mc" '
          function norm(x) { x = tolower(x); gsub(/\(#[0-9]+\)/, " ", x); gsub(/[ \t]+/, " ", x); sub(/^ /, "", x); sub(/ $/, "", x); return x }
          function flush() { if (h != "" && !rev && (named || trail)) print h; h = ""; rev = 0; named = 0; trail = 0 }
          BEGIN { title = norm(ENVIRON["PB_TITLE"]) }
          index($0, "\001") == 1 { flush(); h = substr($0, 2); first = 1; next }
          {
            line = $0; sub(/[ \t\r]+$/, "", line)
            if (first && line ~ /^Revert/) rev = 1
            if (line ~ /^This reverts commit /) rev = 1
            if (index(line, cp)) trail = 1
            if (title != "" && index(line, pat) && (first || (line ~ /^\* / && substr(line, length(line) - length(pat) + 1) == pat)) && index(norm(line), title)) named = 1
            first = 0
          }
          END { flush() }')
    fi
  fi
  for c in $PB_COMMITS; do
    b=$(blob_at "$c" "$path"); [ -n "$b" ] || continue
    [ "$b" != "$(blob_at "$c^" "$path")" ] || continue
    printf '%s\n' "$b"; return 0
  done
  [ -n "$PB_COMMITS" ] && return 2
  return 1
}

# rename_target <ref> <path> <want blob> — the commit on <ref> that deleted <path> (the same commit deleted_later inspects): does
# THAT commit's OWN diff (git's -M rename detection, run on the deleting commit itself) show a rename FROM <path>? Prints the new
# path on stdout when yes; nothing (status 1) when the deletion is a plain drop, -M finds no match, or (see below) the rename did
# not actually carry <want blob>. This is the #822 HIGH fix (code-reviewer): "the blob exists somewhere in main" was not proof of
# a rename — two unrelated identical blobs (e.g. two empty files, or duplicate boilerplate) could coincide and make a
# genuinely-dropped file read as shipped.
# <want blob> is the content the caller needs this rename to prove moved on: when it is $EMPTY_BLOB this function always refuses
# (#824 second HIGH, code-reviewer) — git's -M detector treats any two empty files as 100% similar (there is no content to
# differ), so a commit that deletes one empty file and adds a different, unrelated empty file reads as a rename even though the
# two files are unrelated; "same empty content" is never proof a deletion was really a rename.
# The new path's blob AT THE DELETING COMMIT ITSELF must equal <want blob> (#824 fourth-cycle holistic fix): git's -M pairing
# only proves THIS commit paired <path> with some new path, not that the content it carried there was the PR's own content — a
# base branch that plain-deleted <path> (its own non-revert commit) and only LATER, in a SEPARATE commit, renamed some OTHER,
# unrelated file onto that same new path would otherwise pass merely because main's current blob at the new path happens to
# equal <want blob> by coincidence (the very gap the #822 HIGH fix closed for "anywhere in main", reopened here one commit over
# for "anywhere in the new path's own history", since the caller's own tip-blob check on <ref> only confirms the CURRENT state,
# not that the rename event itself is what produced <want blob>). Checking the blob at the deleting commit itself ties the
# rename's own diff to the content it actually moved.
# Uses -z (NUL-terminated, unquoted) rather than the default --name-status, whose quoting of non-ASCII paths (e.g. a wrapped,
# escaped path) would otherwise make a REAL rename of a non-ASCII filename fail to match <path> (#824 LOW). Parsed with a plain
# `read -d ''` state machine (not `mapfile -d`, a bash 4.4+ builtin) to stay bash 3.2 compatible, like the rest of this file.
rename_target() {
  local ref=$1 path=$2 want=$3 d tok state=status old new
  [ "$want" != "$EMPTY_BLOB" ] || return 1
  d=$(git_ log --full-history --diff-filter=D -n 1 --format=%H "$ref" -- "$path" 2>/dev/null)
  [ -n "$d" ] || return 1
  while IFS= read -r -d '' tok; do
    case "$state" in
      status) case "$tok" in R*|C*) state=old ;; *) state=path ;; esac ;;
      path) state=status ;;
      old) old=$tok; state=new ;;
      new) new=$tok; state=status
           if [ "$old" = "$path" ]; then
             [ "$(blob_at "$d" "$new")" = "$want" ] || return 1
             printf '%s\n' "$new"; return 0
           fi ;;
    esac
  done < <(git_ diff-tree -r -M -z --name-status "$d^" "$d" 2>/dev/null)
  return 1
}

# superseded <ref> <path> <want blob> <got blob> — scanning <ref>'s OWN history of <path> children-before-parents (`--topo-order`,
# NOT calendar/commit-date order, which `in_history`'s own header above already notes is "arbitrary across parallel branches" —
# plain `git log`'s default newest-commit-date-first order is not reliably "last changed" across merges), is the FIRST of
# <want>/<got> encountered <got>, not <want>? Confirms the base branch itself produced <got> for this path (not just that <got>
# isn't provably older than <want> — that half is `in_history`'s job, which walks the OTHER direction, from <want>'s first
# appearance backward) AND that the base branch has not, since producing <got>, reverted BACK to <want> (the PR's own content)
# — replaces a bare "does <ref> ever hold <got> anywhere" (the prior `held_after`), which said nothing about order and would
# wrongly pass a base branch that moved past <want> and then reverted to it (#824 fourth HIGH, code-reviewer): base holds
# <got>, main's current blob, is a real detour, but base's own history AFTER that detour shows a later return to <want> — main
# is now stale relative to base's own timeline, not "moved on" from it. Deliberately NOT "any later <want> anywhere
# disqualifies": a base branch that oscillates and settles back on <got> (e.g. <want> -> <got> -> <want> -> <got>, base's
# CURRENT tip is <got>) must still pass — only the MOST RECENT of the two blobs to appear matters, which is exactly what
# scanning children-before-parents and stopping at the first match gives. Neither blob appearing within the window `hist` caps
# at (200 commits) fails closed.
superseded() {
  local ref=$1 path=$2 want=$3 got=$4 c b
  while read -r c b; do
    [ "$b" = "$got" ] && return 0
    [ "$b" = "$want" ] && return 1
  done <<EOF
$(hist "$ref" "$path" --topo-order)
EOF
  return 1
}

# base_ref_fetch_failed <branch name> — did the per-run fetch of <branch name> (done once per run, see the main loop below) fail?
# Tracked separately from "already fetched" so a failure is remembered for the rest of the run (#824 MEDIUM, code-reviewer): a
# transient fetch error must not silently fall back to whatever tip a PRIOR run already cached in $GD under the same ref name —
# that would trust stale content exactly where freshness is the whole point of the third-HIGH and fourth-HIGH tip/order checks.
BASE_REFS_FAILED=""
base_ref_fetch_failed() { case " $BASE_REFS_FAILED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# base_ref_of <branch name> -> a usable ref for <branch name> on stdout (the already-fetched refs/remotes/origin/<name>, or
# $MAIN when it IS $BASE), or nothing with status 1 when it cannot be resolved (never fetches: the main loop fetches each
# PR_BASE_REF once, before check_at runs, so this stays a cheap local lookup). Refuses (even when a stale ref object is still
# present in the cache from an earlier run) when this run's own fetch of <branch name> failed — see base_ref_fetch_failed.
base_ref_of() {
  local b=$1
  [ -n "$b" ] || return 1
  if [ "$b" = "$BASE" ]; then printf '%s' "$MAIN"; return 0; fi
  base_ref_fetch_failed "$b" && return 1
  have "refs/remotes/origin/$b" || return 1
  printf '%s' "refs/remotes/origin/$b"
}

# check_at <ref> <changes file> -> prints the first offending file (and returns 1), or returns 0.
# Each change row: <status>\t<path>\t<merge commit>\t<PR#>. Added/modified/renamed: same blob; removed/gone: absent.
# PR_BASE_REF (set per PR by the caller) is the #822 fallback: only consulted when promoted_blob's exit status is 2 (a commit
# names the PR but did not carry this path — see promoted_blob's header comment).
check_at() {
  local ref=$1 f=$2 st path mc n want got named_only pb_rc base_ref new_path
  while IFS="$(printf '\t')" read -r st path mc n; do
    [ -n "$path" ] || continue
    got=$(blob_at "$ref" "$path")
    case "$st" in
      removed|gone) [ -z "$got" ] || { printf '%s (still on %s)' "$path" "$BASE"; return 1; } ;;
      *) want=$(promoted_blob "$ref" "$path" "$n" "$mc"); pb_rc=$?
         named_only=0
         if [ -z "$want" ]; then
           [ "$pb_rc" = 2 ] && named_only=1
           want=$(blob_at "$mc" "$path")
         fi
         [ -n "$want" ] || { printf '%s (missing at merge commit)' "$path"; return 1; }
         if [ -z "$got" ]; then
           if deleted_later "$ref" "$path" "$want"; then :
           # #824 third HIGH (code-reviewer): the base branch's rename proof below (deleted_later + rename_target, both read
           # from the LAST commit that deleted <path>) only ever looked at base branch HISTORY — it never confirmed <path> is
           # still actually absent on the base branch's CURRENT tip. Two false positives this missed: (1) the base branch
           # re-adds <path> under the old name after the rename (the same, or any, content under the old path again); (2) the rename commit itself
           # is later `git revert`ed on the base branch (the revert is itself a RENAME back to <path>, so it is never the
           # "last deletion commit" deleted_later's own revert-detection inspects, and slips past it). In both cases the base
           # branch's tip disagrees with main (it holds <path> again) even though the stale history-only proof would pass.
           # `[ -z "$(blob_at "$base_ref" "$path")" ]` requires the old path to be genuinely gone RIGHT NOW before the
           # rename-based verdict is trusted at all.
           elif [ "$named_only" = 1 ] && base_ref=$(base_ref_of "$PR_BASE_REF") && [ -z "$(blob_at "$base_ref" "$path")" ] &&
                deleted_later "$base_ref" "$path" "$want" &&
                new_path=$(rename_target "$base_ref" "$path" "$want") && [ -n "$new_path" ] && [ "$(blob_at "$ref" "$new_path")" = "$want" ]; then :
           elif [ "$named_only" = 1 ] && base_ref_fetch_failed "$PR_BASE_REF"; then
                printf '%s (cannot refresh base branch %s)' "$path" "$PR_BASE_REF"; return 1
           else printf '%s (absent on %s)' "$path" "$BASE"; return 1
           fi
         else
           if [ "$got" = "$want" ]; then :
           elif in_history "$ref" "$path" "$want" "$got"; then :
           # #824 fourth HIGH (code-reviewer): `in_history` alone only proves <got> is not an ancestor that pre-dates <want>'s
           # first appearance on the base branch — it says nothing about what happened to the file AFTER the base branch
           # produced <got>. A base branch that moved on to <got> and then reverted BACK to <want> (the PR's own content) would
           # still pass `in_history`, and the prior `held_after` (bare "does <got> ever appear") would also pass, since <got>
           # genuinely did appear at some point — just not most recently. `superseded` (newest-first scan) adds the missing
           # ordering: main's blob must still be the LAST of the two the base branch actually settled on.
           elif [ "$named_only" = 1 ] && base_ref=$(base_ref_of "$PR_BASE_REF") && in_history "$base_ref" "$path" "$want" "$got" && superseded "$base_ref" "$path" "$want" "$got"; then :
           elif [ "$named_only" = 1 ] && base_ref_fetch_failed "$PR_BASE_REF"; then
                printf '%s (cannot refresh base branch %s)' "$path" "$PR_BASE_REF"; return 1
           else printf '%s (differs on %s)' "$path" "$BASE"; return 1
           fi
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
BASE_REFS_FETCHED=""   # #822: branch names already fetched this run, so a shared base branch (e.g. "staging") is fetched once

for n in $PRS; do
  tag="$REPO#$n"
  pj=$($GH api "repos/$REPO/pulls/$n" 2>/dev/null) || { echo "$tag: NOT SHIPPED (cannot read the PR from GitHub)"; NS=1; continue; }
  merged=$(printf '%s' "$pj" | jq -r '.merged // false')
  mc=$(printf '%s' "$pj" | jq -r '.merge_commit_sha // empty')
  PR_TITLE=$(printf '%s' "$pj" | jq -r '.title // empty')
  PR_BASE_REF=$(printf '%s' "$pj" | jq -r '.base.ref // empty')
  if [ -n "$PR_BASE_REF" ] && [ "$PR_BASE_REF" != "$BASE" ]; then
    # #824 MEDIUM (code-reviewer): dedupe against BOTH lists, not just BASE_REFS_FETCHED — a ref whose fetch already failed
    # this run must stay refused for every later PR that shares it too, not get silently retried (or, worse, resolved via
    # `have()` against a stale object some EARLIER run already cached under this ref name).
    case " $BASE_REFS_FETCHED $BASE_REFS_FAILED " in
      *" $PR_BASE_REF "*) ;;
      *) if git_fetch "+refs/heads/$PR_BASE_REF:refs/remotes/origin/$PR_BASE_REF"; then
           BASE_REFS_FETCHED="$BASE_REFS_FETCHED $PR_BASE_REF"
         else
           BASE_REFS_FAILED="$BASE_REFS_FAILED $PR_BASE_REF"
         fi ;;
    esac
  fi
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
