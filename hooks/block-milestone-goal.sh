#!/bin/bash
# PreToolUse hook on Bash: JP's rule (2026-11-18) — every new goal is registered as a GitHub Project
# (`deliver.sh project:<owner>/<n>`), never as a release milestone. Issue #736 / PR #745 added the project form,
# but milestone goals (#544 milestone 136, #618 Client portal V1) were still being registered afterwards.
#
# Blocks a `deliver.sh` REGISTER call whose goal spec is `owner/repo:milestone:<..>` or `owner/repo:milestones:all`
# (also behind `register`, env/nohup/bash/ssh wrappers, `bash -c '...'`, `&&`/`;`/newlines). Every other
# subcommand (stop, release, status, resume, priority, project) and every other goal form (project, label, #N,
# :feedback) passes, and so does text that merely mentions deliver.sh (echo, grep, gh comment, git commit).
# deliver.sh refuses the same registration itself (goal-lib.sh goal_milestone_refusal keeps the wording in step).
# The legacy override GOAL_ALLOW_MILESTONE_REGISTER=1 counts only in the hook's OWN environment, never as a
# prefix inside the command: a session cannot talk its way past it. Malformed input never wedges the session.
INPUT=$(cat)
case "$INPUT" in
  *deliver.sh*milestone*) ;;
  *) exit 0 ;;
esac
[ "${GOAL_ALLOW_MILESTONE_REGISTER:-}" = 1 ] && exit 0
printf '%s' "$INPUT" | python3 -I -c '
import json, os, re, shlex, sys

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
cmd = (data.get("tool_input") or {}).get("command") or ""
if not isinstance(cmd, str) or "deliver.sh" not in cmd:
    sys.exit(0)

OPS = "();<>|&`\n"
NON_REGISTER = {"status", "project", "stop", "release", "resume", "priority"}
PASSTHRU = {"nohup", "exec", "command", "time", "env", "sudo", "setsid", "nice", "caffeinate"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ssh", "eval"}
SPEC = re.compile(r"^[^\s:]+/[^\s:]+:milestones?:")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

def tokens(s):
    lex = shlex.shlex(s, posix=True, punctuation_chars=OPS)
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    out = []
    try:
        for t in lex:
            out.append(t)
    except ValueError:
        pass  # unbalanced quote: keep what was read before it
    return out

def segments(toks):
    seg = []
    for t in toks:
        if t and all(c in OPS for c in t):
            if seg:
                yield seg
            seg = []
        else:
            seg.append(t)
    if seg:
        yield seg

def is_deliver(t):
    return os.path.basename(t) == "deliver.sh"

def register_spec_is_milestone(args):
    if args and args[0] == "register":
        args = args[1:]
    if not args or args[0].startswith("-") or args[0] in NON_REGISTER:
        return False
    return bool(SPEC.match(args[0]))

def check_string(s, depth=0):
    if depth > 4:
        return False
    for seg in segments(tokens(s)):
        if check_seg(seg, depth):
            return True
    return False

def check_seg(seg, depth):
    i = 0
    while i < len(seg) and (ASSIGN.match(seg[i]) or os.path.basename(seg[i]) in PASSTHRU):
        i += 1
    if i >= len(seg):
        return False
    head = seg[i]
    if is_deliver(head):
        return register_spec_is_milestone(seg[i + 1:])
    if os.path.basename(head) in SHELLS:
        for j in range(i + 1, len(seg)):
            t = seg[j]
            if is_deliver(t):
                if register_spec_is_milestone(seg[j + 1:]):
                    return True
            elif "deliver.sh" in t and check_string(t, depth + 1):
                return True
    return False

if check_string(cmd):
    sys.stderr.write(
        "BLOCKED: milestone goals are no longer registered (JP, 2026-11-18). Register every new goal as a GitHub Project:\n"
        "  1. gh project create --owner Benjis-Plants --title \"<goal title>\"   (note the project number <n>)\n"
        "  2. gh project item-add <n> --owner Benjis-Plants --url <issue URL>   (once per ticket)\n"
        "  3. ~/.claude/skills/orchestrate/deliver.sh project:Benjis-Plants/<n> [--now] [instructions...]\n"
        "The spec form is project:<owner>/<n> (or owner/repo:project:<n>). Existing milestone goals keep working: "
        "stop, release, status, resume and priority are not blocked. See skills/orchestrate/SKILL.md, \"Registering a goal\".\n")
    sys.exit(2)
sys.exit(0)
'
exit $?
