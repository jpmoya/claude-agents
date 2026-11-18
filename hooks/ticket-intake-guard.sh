#!/bin/bash
# PreToolUse hook on Bash (JP, 2026-11-18): a ticket must not be created bare on an application repo. Every ticket JP asks for
# is put in a registered goal's project (or explicitly none) and gets agent-go, by skills/ticket-intake. On `gh issue create`,
# `gh api repos/<o>/<r>/issues` (POST), a GraphQL `createIssue` or a curl POST to the issues API on an APPLICATION repo, the
# command (its body, a --body-file, or a shell comment) must carry the line the skill's brief sets:
#   Intake: project=<owner>/<number>            the goal project the ticket joins (skills/ticket-intake/ticket-intake.sh goals <repo>)
#   Intake: project=none                        standalone (no goal project fits; agent-go is still added)
#   Intake: project=<...> go=no — <reason>      no agent-go (history-only ticket, e.g. a "bypass pipeline" fix already done); reason required
# `gh issue create --project "<title>"` also counts as a project decision. Stateless and offline: no GitHub call, no duplicate
# search (that is hooks/dedupe-ticket-guard.sh, which runs alongside and is satisfied by its own `Dup-check:` line — put both lines
# in the body from the start). The marker says the skill's decision was made; ticket-intake.sh finish performs it afterwards.
# Not enforced: the direct-route repo (jpmoya/claude-agents: no project, no agent-go, ever), repos outside the application set
# (DISPATCH_REPOS / SCAN_ONLY_REPOS of ~/.claude/pipeline/config.local.sh, plus the ops and sales tools; renamed repos resolve through
# skills/ticket-intake/repo-aliases.txt: scheduler = ops tool, benjis-quoting-tool = sales tool), pipeline stage processes
# (PIPELINE_AGENT) and the headless orchestrator / delivery-lead / product-manager sessions (agentSetting in the transcript): they
# file under their own agent-go rules (dependency follow-ups, goal inheritance).
# Env (tests): TICKET_INTAKE_REPOS (space-separated, replaces the whole set), TICKET_INTAKE_CONFIG (config.local.sh path),
# TICKET_INTAKE_DIRECT_ROUTE (space-separated, replaces config.sh's list), TICKET_INTAKE_LOG.
INPUT=$(cat)
case "$INPUT" in
  *"gh issue create"*|*"gh api"*|*"api.github.com"*|*"issue\" \"create"*) ;;
  *) exit 0 ;;
esac
[ -n "${PIPELINE_AGENT:-}" ] && exit 0
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export TI_CONFIG="${TICKET_INTAKE_CONFIG:-$HOME/.claude/pipeline/config.local.sh}"
export TI_BASE_CONFIG="$HERE/../skills/orchestrate/config.sh"
export TI_ALIASES="$HERE/../skills/ticket-intake/repo-aliases.txt"
export TI_LOG="${TICKET_INTAKE_LOG:-$HOME/logs/pipeline/ticket-intake.log}"
printf '%s' "$INPUT" | python3 -I -c '
import json, os, re, shlex, subprocess, sys, time

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
cmd = (data.get("tool_input") or {}).get("command") or ""
cwd = data.get("cwd") or os.getcwd()
if not cmd:
    sys.exit(0)

# Headless pipeline sessions (the transcript names the main agent, same test as ship-goal-guard.sh) file under their own rules.
tp = data.get("transcript_path") or ""
if tp and os.path.isfile(tp):
    try:
        first = json.loads(open(tp, encoding="utf-8", errors="replace").readline())
        if first.get("agentSetting") in ("orchestrator", "delivery-lead", "project-manager"):
            sys.exit(0)
    except (ValueError, OSError):
        pass

def toks(s):
    try:
        return shlex.split(s, comments=False, posix=True)
    except ValueError:
        return s.split()

def opt(tl, names):
    for i, t in enumerate(tl):
        for n in names:
            if t == n and i + 1 < len(tl):
                return tl[i + 1]
            if n.startswith("--") and t.startswith(n + "="):
                return t[len(n) + 1:]
    return None

def fields(tl):
    out = {}
    for i, t in enumerate(tl):
        if t in ("-f", "-F", "--field", "--raw-field") and i + 1 < len(tl) and "=" in tl[i + 1]:
            k, v = tl[i + 1].split("=", 1)
            out[k] = v
    return out

def readf(p):
    if not p or p == "-":
        return None
    p = os.path.expanduser(p)
    if not os.path.isabs(p):
        p = os.path.join(cwd, p)
    try:
        return open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return None

def remote_repo():
    try:
        u = subprocess.run(["git", "-C", cwd, "remote", "get-url", "origin"], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return None
    m = re.search(r"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?$", u)
    return m.group(1) if m else None

# ---- find the create operation (same detection as dedupe-ticket-guard.sh) ----------------------------------------
def mask(s):
    out, i, n = list(s), 0, len(s)
    def blank(a, b):
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = "x"
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2; continue
        if c == "\x27":
            j = s.find("\x27", i + 1); j = n if j < 0 else j
            blank(i + 1, j); i = j + 1; continue
        if c == "\"":
            j = i + 1
            while j < n and s[j] != "\"":
                j += 2 if s[j] == "\\" else 1
            blank(i + 1, j); i = j + 1; continue
        m = re.match(r"<<-?\s*[\x27\"]?([A-Za-z_][A-Za-z0-9_]*)[\x27\"]?", s[i:])
        if m:
            nl = s.find("\n", i)
            if nl >= 0:
                end = re.compile(r"^[ \t]*" + re.escape(m.group(1)) + r"[ \t]*$", re.M).search(s, nl + 1)
                stop = end.start() if end else n
                blank(nl + 1, stop); i = stop; continue
        i += 1
    return "".join(out)

masked = mask(cmd)
POS = r"(?:^|[;&|(\n]|\$\()\s*(?:(?:if|then|else|elif|do|time|exec|command|env|!)\s+)*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"
op = None
m = re.search(POS + r"gh\s+issue\s+create\b", masked)
if m:
    tl = toks(cmd[m.end():])
    if "--help" in tl[:3] or "-h" in tl[:3]:
        sys.exit(0)
    body = opt(tl, ["--body", "-b"])
    bf = opt(tl, ["--body-file", "-F"])
    if bf:
        body = readf(bf) if bf != "-" else cmd
    op = dict(repo=opt(tl, ["--repo", "-R"]) or remote_repo(), title=opt(tl, ["--title", "-t"]), body=body,
              project_flag=opt(tl, ["--project", "-p"]))
if op is None:
    for m in re.finditer(POS + r"gh\s+api\b", masked):
        tl = toks(cmd[m.end():].split("\n|")[0])
        path = next((t for t in tl if re.match(r"^/?repos/[^/\s]+/[^/\s]+/issues/?(\?.*)?$", t)), None)
        meth = (opt(tl, ["-X", "--method"]) or "").upper()
        if path:
            f = fields(tl)
            implicit = meth == "" and (f or opt(tl, ["--input"]))
            if meth == "POST" or implicit:
                inp = readf(opt(tl, ["--input"]))
                if inp:
                    try:
                        j = json.loads(inp); f.setdefault("title", j.get("title")); f.setdefault("body", j.get("body"))
                    except ValueError:
                        pass
                f2 = re.match(r"^/?repos/([^/\s]+/[^/\s]+)/issues", path)
                op = dict(repo=f2.group(1), title=f.get("title"), body=f.get("body"), project_flag=None); break
        elif "graphql" in tl and re.search(r"\bcreateIssue\b", cmd):
            op = dict(repo=None, title=None, body=None, project_flag=None); break
if op is None:
    c0 = re.search(POS + r"curl\b", masked)
    m = c0 and re.compile(r"api\.github\.com/repos/([\w.-]+/[\w.-]+)/issues(?![/\w])").search(cmd, c0.end())
    if m and re.search(r"(-X\s*POST|--request\s+POST|\s-d\s|--data)", cmd):
        op = dict(repo=m.group(1), title=None, body=None, project_flag=None)
if op is None:
    sys.exit(0)

# ---- which repos are enforced -----------------------------------------------------------------------------------
DEFAULT_REPOS = ["Benjis-Plants/benjis-ops-tool", "Benjis-Plants/benjis-sales-tool"]
def config_repos():
    out = []
    try:
        for ln in open(os.environ["TI_CONFIG"], encoding="utf-8", errors="replace"):
            ln = ln.strip()
            if ln.startswith("#"):
                continue
            m = re.match(r"^(?:\"|\x27)([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)(?::[^\"\x27]*)?(?:\"|\x27)", ln)
            if m:
                out.append(m.group(1))
            m = re.match(r"^(?:DISPATCH_REPOS|SCAN_ONLY_REPOS)\+?=\(?\s*(?:\"|\x27)([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)", ln)
            if m:
                out.append(m.group(1))
    except OSError:
        pass
    return out
def direct_route():
    if "TICKET_INTAKE_DIRECT_ROUTE" in os.environ:
        return os.environ["TICKET_INTAKE_DIRECT_ROUTE"].split()
    try:
        for ln in open(os.environ["TI_BASE_CONFIG"], encoding="utf-8", errors="replace"):
            m = re.match(r"^DIRECT_ROUTE_REPOS=\((.*)\)", ln.strip())
            if m:
                return re.findall(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", m.group(1))
    except OSError:
        pass
    return ["jpmoya/claude-agents"]
if "TICKET_INTAKE_REPOS" in os.environ:
    enforced = os.environ["TICKET_INTAKE_REPOS"].split()
else:
    enforced = DEFAULT_REPOS + config_repos()
# Renamed repos (skills/ticket-intake/repo-aliases.txt): `gh issue create -R Benjis-Plants/scheduler` is the ops tool.
aliases = {}
try:
    for ln in open(os.environ["TI_ALIASES"], encoding="utf-8", errors="replace"):
        w = ln.split()
        if len(w) == 2 and not ln.lstrip().startswith("#"):
            aliases[w[0].lower()] = w[1]
except OSError:
    pass
canon = lambda r: aliases.get(r.lower(), r)
lc = lambda xs: {canon(x).lower() for x in xs}
repo = canon((op.get("repo") or "").strip())
known = bool(repo) and not repo.startswith("$")
if known:
    if repo.lower() in lc(direct_route()):
        sys.exit(0)                      # direct route: never a project, never agent-go
    if repo.lower() not in lc(enforced):
        sys.exit(0)                      # not an application repo

# ---- the marker -------------------------------------------------------------------------------------------------
text = cmd + "\n" + (op.get("body") or "")
MARK = re.compile(r"(?im)^[ \t#>*-]*intake:[ \t]*project=(?:none|[A-Za-z0-9._-]+/\d+|\d+)\b[^\n]*")
mk = MARK.search(text)
go_no = False
if mk:
    gm = re.search(r"(?i)\bgo=no\b\s*(?:[—–-]+|:)?\s*([^\n]*)", mk.group(0))
    if gm:
        go_no = True
        reason = gm.group(1).strip()
        if len(re.findall(r"[A-Za-z]{2,}", reason)) < 3:
            sys.stderr.write("TICKET INTAKE (JP rule): `go=no` needs a reason of a few words (why this ticket must not get agent-go), e.g.\n"
                             "  Intake: project=none go=no — fix already shipped by a bypass-pipeline hotfix, history only\n")
            sys.exit(2)
def log(outcome):
    try:
        os.makedirs(os.path.dirname(os.environ["TI_LOG"]), exist_ok=True)
        with open(os.environ["TI_LOG"], "a") as fh:
            fh.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "repo": repo, "title": (op.get("title") or "")[:120],
                                 "outcome": outcome, "go_no": go_no, "agent": os.environ.get("PIPELINE_AGENT") or "interactive"}) + "\n")
    except Exception:
        pass
if mk or op.get("project_flag"):
    log("allowed-go-no" if go_no else "allowed"); sys.exit(0)

log("blocked")
sys.stderr.write(
    "TICKET INTAKE (JP rule): this creates a ticket on an application repo (" + (repo if known else "repo unreadable") + ") without the project/agent-go decision.\n"
    "Every ticket JP asks for goes into a registered goal\x27s project (or explicitly none) and gets agent-go. Use the ticket-intake skill (skills/ticket-intake/SKILL.md):\n"
    "  1. ~/.claude/skills/ticket-intake/ticket-intake.sh goals <owner/repo>      (the open goal projects; ask JP ONE short question if more than one fits)\n"
    "  2. re-run this command with a body line (a shell comment also counts):\n"
    "       Intake: project=<owner>/<number>     or     Intake: project=none\n"
    "     (history-only ticket that must NOT get agent-go: Intake: project=none go=no — <reason>)\n"
    "  3. then: ~/.claude/skills/ticket-intake/ticket-intake.sh finish <owner/repo> <issue#> --project <owner>/<number> | --none\n"
    "Pipeline stage processes and jpmoya/claude-agents (direct route) are not subject to this. The Dup-check line (dedupe-ticket-guard.sh) is a separate requirement: put both lines in the body.\n")
sys.exit(2)
'
