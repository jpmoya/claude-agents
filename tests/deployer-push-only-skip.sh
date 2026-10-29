#!/usr/bin/env bash
# Regression: deployer skip rule licenses push-only jobs (top-level && chain with event_name == 'push') (#531).
set -u
f="$(dirname "$0")/../agents/deployer.md"
fail=0
b="$(grep -F -- '**Any other `if:`**' "$f")"
[ -n "$b" ] || { echo "MISSING: Any other if: bullet"; exit 1; }
chk() { printf '%s' "$b" | grep -qF -- "$1" || { echo "MISSING in bullet: $1"; fail=1; }; }
chk "github.event_name == 'push'"
chk 'top-level `&&`'
chk '`||`'
chk '`!=`'
chk 'cannot read the expression as a plain `&&` chain'
chk 'file list does not hold the workflow file'
printf '%s' "$b" | grep -qF 'add one before relying on it' && { echo "STALE: 'add one before relying on it'"; fail=1; }
exit $fail
