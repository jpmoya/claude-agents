# canonicalize_repo_lists: a renamed repo is rewritten to its canonical name with a WARN; an unresolvable one warns and stays.
HERE_RC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RC_HOME=$(mktemp -d); mkdir -p "$RC_HOME/bin" "$RC_HOME/pipe"
cat > "$RC_HOME/bin/gh" <<'STUB'
#!/bin/bash
case "$*" in *"repo view o/old "*) echo o/new ;; *"repo view o/same "*) echo o/same ;; esac
exit 0
STUB
chmod +x "$RC_HOME/bin/gh"
out=$(PATH="$RC_HOME/bin:$PATH" PIPE="$RC_HOME/pipe" bash -c '
  source "'"$HERE_RC"'/../pipeline-lib.sh" 2>/dev/null
  DISPATCH_REPOS=("o/old:/p/old" "o/same:/p/same" "o/gone:/p/gone"); SCAN_ONLY_REPOS=("o/old")
  canonicalize_repo_lists 2>&1
  echo "${DISPATCH_REPOS[*]} | ${SCAN_ONLY_REPOS[*]}"')
case "$out" in *"o/new:/p/old o/same:/p/same o/gone:/p/gone | o/new"*) ;; *) fail "rewrite wrong: $out" ;; esac
case "$out" in *"WARN [repo-canon] DISPATCH_REPOS entry 'o/old' was renamed to 'o/new'"*) ;; *) fail "no rename WARN: $out" ;; esac
case "$out" in *"'o/gone' does not resolve"*) ;; *) fail "no unresolved WARN: $out" ;; esac
rm -rf "$RC_HOME"
