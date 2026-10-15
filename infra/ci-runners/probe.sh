#!/usr/bin/env bash
# Asserts the runner user cannot reach the claude user's secrets. Exit non-zero on any FAIL.
set -euo pipefail
CH=${CLAUDE_HOME:-/home/claude}
[ -z "${GHA_DRY_STUBS:-}" ] || PATH="$GHA_DRY_STUBS:$PATH"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

if sudo -n -u gha true >/dev/null 2>&1; then pass "can run commands as gha"; else fail "cannot run commands as gha"; fi
for p in .claude .config .ssh; do
  if sudo -n -u gha test -r "$CH/$p" >/dev/null 2>&1; then fail "gha can read $CH/$p"; else pass "gha cannot read $CH/$p"; fi
done
if sudo -n -u gha ls "$CH" >/dev/null 2>&1; then fail "gha can list $CH"; else pass "gha cannot list $CH"; fi
leaked=$(sudo -n -u gha -i env 2>/dev/null | sed -n 's/=.*//p' | grep -E 'TOKEN|SECRET|KEY' | tr '\n' ' ' || true)
if [ -n "$leaked" ]; then fail "gha environment has secret-like names: $leaked"; else pass "gha environment has no TOKEN/SECRET/KEY names"; fi
[ "$fails" -eq 0 ]
