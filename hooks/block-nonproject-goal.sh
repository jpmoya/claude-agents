#!/bin/bash
# PreToolUse hook on Bash: JP's rule (2026-11-18) — every goal is registered as a GitHub Project
# (`deliver.sh project:<owner>/<n>`), never as a release milestone, label or ticket goal (the standing `owner/repo:feedback` goals keep their spec). Issue #736 / PR #745 added the project
# form, but milestone goals (#544 milestone 136, #618 Client portal V1) were still being registered afterwards.
#
# 1. Blocks a `deliver.sh` REGISTER call whose goal spec is not a project (the standing `owner/repo:feedback` goal is the one other form allowed): `owner/repo:milestone:<..>`, `:milestones:all`, `label:<x>` (or a
#    bare `--repos/--title` label registration), `owner/repo#N`, anything unparsable (also behind `register`,
#    env/nohup/bash/ssh wrappers, `bash -c '...'`, `&&`/`;`/newlines). Every other subcommand (stop, release, status, resume, priority,
#    project), `--help` and the project forms (`project:<owner>/<n>`, `owner/repo:project:<n>`) pass, and so does text that merely
#    mentions deliver.sh (echo, grep, gh comment, git commit).
# 2. Naming convention: `gh project create|edit --title "Goal: ..."` must carry exactly one "Goal: " prefix and a short human name (no repo
#    path, `#N` or spec syntax). The registry issue and the status page use the project's name, so a bad project title is stopped at the source.
# deliver.sh refuses the same registrations and titles itself (goal-lib.sh goal_nonproject_refusal / goal_title_check keep the wording in
# step). The legacy override GOAL_ALLOW_LEGACY_REGISTER=1 counts only in the hook's OWN environment, never as a prefix inside the command:
# a session cannot talk its way past it. Malformed input never wedges the session.
INPUT=$(cat)
case "$INPUT" in
  *deliver.sh*|*"gh project"*|*"gh"*"project"*"--title"*) ;;
  *) exit 0 ;;
esac
[ "${GOAL_ALLOW_LEGACY_REGISTER:-}" = 1 ] && exit 0
printf '%s' "$INPUT" | python3 -I -c '
import json, os, re, shlex, sys

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
cmd = (data.get("tool_input") or {}).get("command") or ""
if not isinstance(cmd, str) or not ("deliver.sh" in cmd or "project" in cmd):
    sys.exit(0)

OPS = "();<>|&`\n"
NON_REGISTER = {"status", "project", "stop", "release", "resume", "priority"}
PASSTHRU = {"nohup", "exec", "command", "time", "env", "sudo", "setsid", "nice", "caffeinate"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "ssh", "eval"}
FEEDBACK_SPEC = re.compile(r"^[^\s:]+/[^\s:]+:feedback$")
PROJECT_SPEC = re.compile(r"^(project:[^\s:/]+/\d+|[^\s:]+/[^\s:]+:project:\d+)$")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
GO_QUESTION = (
    "ask JP: go true or go false? Registering a goal needs his explicit choice and a session may never pick it: "
    "add --go (every ticket in the goal\x27s scope inherits agent-go) or --no-go (no agent-go is given; each ticket needs its own) to the deliver.sh command")
RECIPE = (
    "  1. gh project create --owner Benjis-Plants --title \"Goal: <short human name>\"   (note the project number <n>)\n"
    "  2. gh project item-add <n> --owner Benjis-Plants --url <issue URL>   (once per ticket)\n"
    "  3. ~/.claude/skills/orchestrate/deliver.sh project:Benjis-Plants/<n> --go|--no-go [--priority <n>] [--now] [instructions...]   (ask JP: go true or go false? never pick it yourself)\n"
    "The spec form is project:<owner>/<n> (or owner/repo:project:<n>). The project title is the goal\x27s name everywhere: the registry issue "
    "and the status page use the same \"<short human name>\" (no repo path, no #N, no second \"Goal:\"). Existing goals keep working: "
    "stop, release, status, resume and priority are not blocked. See skills/orchestrate/SKILL.md, \"Registering a goal\".\n"
    "Priority only orders the queue (and is optional: with none the goal queues in registration order; deliver.sh priority reorders it). Priority 1 does NOT make a goal start immediately or take the goal slot from a goal that is already running. To start a new goal right away you must force it: stop the goal that holds the slot (deliver.sh stop <goal>; a held or waiting-on-JP goal does not hold it), or register with --now (runs one cycle by hand; under GOAL_SERIAL=1 a --now goal that does not hold the slot returns to the queue after that cycle). There is no preempt or force-start command: stopping the holder is the only way to hand the slot over.\n")

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

def bad_register(args):
    """The reason a deliver.sh register call is refused, or None."""
    if args and args[0] == "register":
        args = args[1:]
    if not args or args[0] in ("-h", "--help") or args[0] in NON_REGISTER:
        return None
    if FEEDBACK_SPEC.match(args[0]):
        return None   # the standing staff-feedback goal keeps its spec (slot exemption and scope are keyed on it); it has no go choice
    if PROJECT_SPEC.match(args[0]):
        missing = []
        if "--go" not in args and "--no-go" not in args:
            missing.append(GO_QUESTION)
        return "; ".join(missing) if missing else None
    what = "a label goal" if args[0].startswith("-") else args[0]
    return "refusing to register %s: every goal is registered as a GitHub Project (milestone, label and ticket goals are no longer registered)" % what

def title_problem(title):
    """Why a goal project title breaks the naming convention, or None. Only titles that claim to be goals ("Goal:...") are judged."""
    if not re.match(r"^\s*[Gg]oal:", title):
        return None
    if not title.startswith("Goal: "):
        return "must start with exactly \"Goal: \""
    n = title[len("Goal: "):]
    if not n or n != n.strip():
        return "needs a name after \"Goal: \" with no leading or trailing space"
    if re.match(r"^[Gg]oal:", n):
        return "repeats the \"Goal:\" prefix"
    if len(n) > 80:
        return "is longer than 80 characters"
    if "/" in n or re.search(r"#\d", n) or re.search(r":(milestones?|feedback|project)(:|$)", n) or re.match(r"^(label|project):", n):
        return "carries repo-path or spec syntax (use a short human name)"
    return None

def bad_title(seg, i):
    """gh project create|edit --title "Goal: ..." -> the reason, or None."""
    rest = seg[i + 1:]
    if len(rest) < 2 or rest[0] != "project" or rest[1] not in ("create", "edit"):
        return None
    for j, t in enumerate(rest):
        val = None
        if t == "--title" and j + 1 < len(rest):
            val = rest[j + 1]
        elif t.startswith("--title="):
            val = t[len("--title="):]
        if val is not None:
            why = title_problem(val)
            if why:
                return "the project title \"%s\" %s" % (val, why)
    return None

def check_string(s, depth=0):
    if depth > 4:
        return None
    for seg in segments(tokens(s)):
        r = check_seg(seg, depth)
        if r:
            return r
    return None

def check_seg(seg, depth):
    i = 0
    while i < len(seg) and (ASSIGN.match(seg[i]) or os.path.basename(seg[i]) in PASSTHRU):
        i += 1
    if i >= len(seg):
        return None
    head = seg[i]
    if is_deliver(head):
        return bad_register(seg[i + 1:])
    if os.path.basename(head) == "gh":
        return bad_title(seg, i)
    if os.path.basename(head) in SHELLS:
        for j in range(i + 1, len(seg)):
            t = seg[j]
            if is_deliver(t):
                r = bad_register(seg[j + 1:])
                if r:
                    return r
            elif ("deliver.sh" in t or "project" in t) and " " in t:
                r = check_string(t, depth + 1)
                if r:
                    return r
    return None

why = check_string(cmd)
if why:
    sys.stderr.write("BLOCKED: " + why + " (JP, 2026-11-18). Register every goal as a GitHub Project:\n" + RECIPE)
    sys.exit(2)
sys.exit(0)
'
exit $?
