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
#   3. `git commit` while any locked path differs from HEAD (staged or unstaged) → block
#      (backstop for any edit that slipped past 1 and 2).
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
    # A locked file already staged blocks any commit. A locked file changed but NOT yet staged
    # blocks only when this same command would stage or commit it: PreToolUse runs before the
    # command's own `git add` (`git add -A e2e && git commit`), `commit -a` takes every tracked
    # modification, and `git commit <path>` / `git add <path>` take the named path (#463).
    # An unrelated commit while a locked file is dirty is allowed.
    STAGED=$(git diff --cached --name-only 2>/dev/null)
    while IFS= read -r f; do
      [ -n "$f" ] && echo "$STAGED" | grep -qxF "$f" && block "$f (staged)"
    done <<< "$LOCKED"
    CHANGED=$(git diff HEAD --name-only 2>/dev/null)
    HIT=$(CMD="$CMD" LOCKED="$LOCKED" CHANGED="$CHANGED" python3 - <<'PY' 2>/dev/null
import os, re, shlex
cmd = os.environ["CMD"]
changed = [l for l in os.environ["CHANGED"].splitlines() if l]
locked = set(l for l in os.environ["LOCKED"].splitlines() if l)
dirty = [f for f in changed if f in locked]
ARG_SHORT = set("mFCc")   # commit short options that take a value
def hit(paths, everything):
    for f in dirty:
        if everything and not paths:
            return f
        for p in paths:
            p = os.path.normpath(p) if p else p
            if p == "." or f == p or f.startswith(p.rstrip("/") + "/"):
                return f
    return None
for seg in re.split(r"&&|\|\||;|\|", cmd):
    try: toks = shlex.split(seg)
    except ValueError: toks = seg.split()
    for i, t in enumerate(toks):
        if t != "git": continue
        j = i + 1
        while j < len(toks) and toks[j].startswith("-"):
            j += 2 if toks[j] in ("-C", "-c") else 1
        if j >= len(toks) or toks[j] not in ("add", "commit"): continue
        sub, args = toks[j], toks[j + 1:]
        paths, everything, k = [], False, 0
        while k < len(args):
            a = args[k]
            if a == "--":
                paths += args[k + 1:]; break
            if a.startswith("--"):
                if a in ("--all", "--update"): everything = True
                elif sub == "commit" and a in ("--message", "--file", "--author", "--date", "--reuse-message", "--reedit-message"): k += 1
            elif a.startswith("-") and len(a) > 1:
                letters = a[1:]
                if sub == "add" and re.search("[Au]", letters): everything = True
                if sub == "commit":
                    if "a" in letters: everything = True
                    if letters[-1] in ARG_SHORT: k += 1
            else:
                paths.append(a)
            k += 1
        f = hit(paths, everything)
        if f is None and sub == "add" and "." in paths: f = hit(["."], True)
        if f: print(f); raise SystemExit
PY
)
    [ -n "$HIT" ] && block "$HIT (changed, and this command would stage or commit it)"
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
