#!/bin/bash
# PreToolUse hook (Write|Edit and Bash): while the pipeline has the tests locked,
# the implementing agent cannot modify, delete, or stage changes to the locked test files.
#
# The orchestrator exports PIPELINE_LOCKED_TESTS_FILE=<path> before launching
# fullstack-developer. The file holds one repo-relative test path per line (copied
# from the test-writer's TESTS WRITTEN comment). When the variable is unset, this
# hook does nothing — JP running an agent by hand is not locked.
#
# Three checks:
#   1. Write/Edit whose file_path resolves to a locked path → block.
#   2. Bash command that names a locked path together with a write-ish token
#      (rm, mv, sed -i, >, >>, tee, truncate, git rm, git checkout --, cp/dd onto it) → block.
#   3. `git commit` whose staged files include a locked path → block (backstop for any edit
#      that slipped past 1 and 2).
# New test files are allowed — the developer may ADD tests; the orchestrator lists them
# for the narrow post-implementation review.

[ -z "$PIPELINE_LOCKED_TESTS_FILE" ] && exit 0
[ -f "$PIPELINE_LOCKED_TESTS_FILE" ] || exit 0

INPUT=$(cat)
TOOL=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)
LOCKED=$(grep -v '^\s*$' "$PIPELINE_LOCKED_TESTS_FILE")
[ -z "$LOCKED" ] && exit 0

block() { echo "BLOCKED: $1 is a locked test file (written by test-writer, reviewed by test-reviewer). Implement until it passes; if you believe the test is wrong, post **[fullstack-developer] TEST DEFECT** on the issue and stop. Add new tests in a NEW file." >&2; exit 2; }

rel_path() {  # absolute or cwd-relative path → repo-relative, empty if not in a git repo
  local p="$1" dir
  [ -z "$p" ] && return
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  dir=$(dirname "$p")
  local top
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return
  python3 -c "import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))" "$p" "$top"
}

if [ "$TOOL" = "Write" ] || [ "$TOOL" = "Edit" ]; then
  FP=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)
  REL=$(rel_path "$FP")
  [ -n "$REL" ] && echo "$LOCKED" | grep -qxF "$REL" && block "$REL"
  exit 0
fi

if [ "$TOOL" = "Bash" ]; then
  CMD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)
  # 3. commit backstop
  if echo "$CMD" | grep -qE '\bgit\s+commit\b'; then
    STAGED=$(git diff --cached --name-only 2>/dev/null)
    while IFS= read -r f; do
      [ -n "$f" ] && echo "$STAGED" | grep -qxF "$f" && block "$f (staged)"
    done <<< "$LOCKED"
    # `git commit -a` / `-am` stage everything modified
    if echo "$CMD" | grep -qE '\bgit\s+commit\s+(-[a-zA-Z]*a|--all)'; then
      MOD=$(git diff --name-only 2>/dev/null)
      while IFS= read -r f; do
        [ -n "$f" ] && echo "$MOD" | grep -qxF "$f" && block "$f (modified, -a)"
      done <<< "$LOCKED"
    fi
  fi
  # 2. write-ish command naming a locked path
  if echo "$CMD" | grep -qE '(^|[;&|[:space:]])(rm|mv|cp|dd|tee|truncate|sed\s+(-[a-zA-Z]*i|--in-place)|perl\s+-[a-zA-Z]*i|git\s+rm|git\s+checkout\s+--|git\s+restore|>|>>)'; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      base=$(basename "$f")
      if echo "$CMD" | grep -qF -- "$f" || echo "$CMD" | grep -qF -- "$base"; then block "$f"; fi
    done <<< "$LOCKED"
  fi
fi
exit 0
