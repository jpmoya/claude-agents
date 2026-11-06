#!/usr/bin/env bash
# Regression: deployer admin-merges claude-agents PRs blocked only by the review-count rule (#564).
set -u
f="$(dirname "$0")/../agents/deployer.md"
fail=0
b="$(grep -F -- '**Admin merge (jpmoya/claude-agents only, #564).**' "$f")"
[ -n "$b" ] || { echo "MISSING: admin merge bullet"; exit 1; }
chk() { printf '%s' "$b" | grep -qF -- "$1" || { echo "MISSING in bullet: $1"; fail=1; }; }
chk 'REVIEW_REQUIRED'
chk '--admin'
chk 'bypasses required status checks'
chk 'never to get past a red check, a conflict or a dependency'
chk 'Every other repo'
g="$(grep -F -- 'Class guide for deployer BLOCKEDs' "$f")"
printf '%s' "$g" | grep -qF 'a review-count block on `jpmoya/claude-agents` is not `needs_jp`' || { echo "MISSING: class guide review-count exclusion"; fail=1; }
exit $fail
